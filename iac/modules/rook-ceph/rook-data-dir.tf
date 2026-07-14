# Create Rook data directory on Kind nodes and host with proper permissions
# This is required for Rook to store cluster data on the host filesystem
# For Kind clusters with extraMounts, we need to create the directory on:
# 1. The host filesystem (where extraMounts points to)
# 2. Inside each Kind node container (as a fallback and for initial setup)
#
# SAFETY: When create_loop_devices = true, sparse image files are created inside each
# kind worker node and attached as loop devices. This ensures Rook OSDs write to files
# rather than real disk partitions — preventing accidental data loss on the host.

locals {
  # All kind nodes that need the Rook data directory
  # Must match the nodes defined in config/kind-config.yaml
  kind_nodes = [
    "local-control-plane",
    "local-worker",
    "local-worker2",
    "local-worker3",
  ]

  # Derive (node, device) pairs from storage_nodes for loop device setup.
  # Only populated when create_loop_devices = true.
  osd_device_pairs = var.create_loop_devices ? {
    for node in var.storage_nodes : "${node.name}:${coalesce(node.loop_device, try(node.devices[0], ""))}" => {
      node_name   = node.name
      device_path = coalesce(node.loop_device, try(node.devices[0], ""))
    } if coalesce(node.loop_device, try(node.devices[0], "")) != ""
  } : {}

  # Derive (node, directory) pairs from storage_nodes for directory OSD setup.
  osd_directory_pairs = {
    for pair in flatten([
      for node in var.storage_nodes : [
        for dir in coalesce(node.directories, []) : {
          node_name = node.name
          dir_path  = dir
        }
      ]
    ]) : "${pair.node_name}:${pair.dir_path}" => pair
  }
}

# Data source to check if data directory exists on each node
data "external" "check_rook_dir" {
  for_each = toset(local.kind_nodes)
  program = ["sh", "-c", <<-EOT
    NODE="${each.key}"
    DIR="${var.data_dir_host_path}"
    if docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
      if docker exec "$NODE" test -d "$DIR" 2>/dev/null; then
        echo "{\"exists\":\"true\",\"node\":\"$NODE\",\"path\":\"$DIR\"}"
      else
        echo "{\"exists\":\"false\",\"node\":\"$NODE\",\"path\":\"$DIR\"}"
      fi
    else
      echo "{\"exists\":\"unknown\",\"node\":\"$NODE\",\"path\":\"$DIR\"}"
    fi
  EOT
  ]
}

# Data source to check whether a loop device is currently attached on a kind node.
# Used as a trigger so that tofu apply re-runs setup if devices are lost (e.g. after reboot).
data "external" "check_osd_loop_device" {
  for_each = local.osd_device_pairs

  program = ["sh", "-c", <<-EOT
    NODE="${each.value.node_name}"
    DEVICE="${each.value.device_path}"
    if docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
      if docker exec "$NODE" losetup "$DEVICE" >/dev/null 2>&1; then
        echo "{\"attached\":\"true\",\"node\":\"$NODE\",\"device\":\"$DEVICE\"}"
      else
        echo "{\"attached\":\"false\",\"node\":\"$NODE\",\"device\":\"$DEVICE\"}"
      fi
    else
      echo "{\"attached\":\"unknown\",\"node\":\"$NODE\",\"device\":\"$DEVICE\"}"
    fi
  EOT
  ]
}

# Create the Rook data directory on each Kind node
resource "null_resource" "create_rook_data_dir" {
  for_each = toset(local.kind_nodes)

  triggers = {
    data_dir_host_path = var.data_dir_host_path
    node_name          = each.key
    dir_exists         = try(data.external.check_rook_dir[each.key].result.exists, "unknown")
    dir_path           = try(data.external.check_rook_dir[each.key].result.path, var.data_dir_host_path)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NODE="${each.key}"
      DIR="${var.data_dir_host_path}"

      # Create directory on the host filesystem first (required for Kind extraMounts)
      echo "Creating host directory: $DIR"
      if sudo mkdir -p "$DIR" 2>/dev/null; then
        sudo chmod 777 "$DIR" || sudo chmod 755 "$DIR"
        echo "✓ Created $DIR on host"
      elif mkdir -p "$DIR" 2>/dev/null; then
        chmod 777 "$DIR" 2>/dev/null || chmod 755 "$DIR" 2>/dev/null || true
        echo "✓ Created $DIR on host (without sudo)"
      else
        echo "⚠ Cannot create host directory $DIR, will create inside node container only"
      fi

      # Check if node container is running
      if ! docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
        echo "⚠ Node $NODE not found, skipping directory creation in container"
        exit 1
      fi

      # Create directory inside the Kind node container
      echo "Creating directory inside node container: $NODE:$DIR"

      docker exec "$NODE" mkdir -p "$(dirname "$DIR")" || {
        echo "✗ Failed to create parent directory $(dirname "$DIR") on node $NODE"
        exit 1
      }

      docker exec "$NODE" mkdir -p "$DIR" || {
        echo "✗ Failed to create $DIR on node $NODE"
        exit 1
      }

      docker exec "$NODE" chmod 777 "$DIR" || {
        echo "⚠ Failed to set permissions on $DIR, trying 755"
        docker exec "$NODE" chmod 755 "$DIR" || {
          echo "✗ Failed to set permissions on $DIR on node $NODE"
          exit 1
        }
      }

      # Verify write access
      if docker exec "$NODE" touch "$DIR/.write-test" 2>/dev/null; then
        docker exec "$NODE" rm -f "$DIR/.write-test" 2>/dev/null || true
        echo "✓ Created $DIR on node $NODE with write permissions"
      else
        echo "⚠ Directory $DIR exists but may not be writable on node $NODE"
        docker exec "$NODE" ls -ld "$DIR" || true
      fi
    EOT
  }
}

# Set up OSD loop devices on kind worker nodes.
# Creates a sparse image file for each (node, device) pair in storage_nodes and
# attaches it as a loop device. Sparse files consume no real disk space until written,
# so this is safe and avoids Rook touching real block devices on the host.
#
# Only runs when create_loop_devices = true.
# Re-runs automatically if the loop device is detected as missing (e.g. after a reboot).
resource "null_resource" "setup_osd_loop_devices" {
  for_each = local.osd_device_pairs

  triggers = {
    node_name          = each.value.node_name
    device_path        = each.value.device_path
    data_dir_host_path = var.data_dir_host_path
    image_size_gb      = var.loop_device_image_size_gb
    # Re-run if device is no longer attached (e.g. after cluster restart or reboot)
    loop_device_attached = try(data.external.check_osd_loop_device[each.key].result.attached, "unknown")
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NODE="${each.value.node_name}"
      DEVICE="${each.value.device_path}"
      DEVICE="/dev/$${DEVICE#/dev/}"
      # Derive image filename from device basename: /dev/loop10 → loop10.img
      DEV_BASENAME=$(basename "$DEVICE")
      IMG_PATH="${var.data_dir_host_path}/$NODE-osd.img"
      SIZE_GB="${var.loop_device_image_size_gb}"

      if ! docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
        echo "✗ Node $NODE not found"
        exit 1
      fi

      # Kind node containers may not ship with high-numbered /dev/loopN nodes
      LOOP_NUM="$${DEVICE#/dev/loop}"
      if ! docker exec "$NODE" test -e "$DEVICE" 2>/dev/null; then
        echo "Creating loop device node $DEVICE (7:$LOOP_NUM) on $NODE..."
        docker exec "$NODE" mknod -m 660 "$DEVICE" b 7 "$LOOP_NUM"
      fi

      # Create sparse image file if it doesn't exist.
      # truncate creates a sparse file — no real disk space is consumed until data is written.
      if docker exec "$NODE" test -f "$IMG_PATH" 2>/dev/null; then
        echo "  OSD image $IMG_PATH already exists on $NODE"
      else
        echo "Creating sparse OSD image $IMG_PATH ($${SIZE_GB}GB) on $NODE..."
        docker exec "$NODE" truncate -s "$${SIZE_GB}G" "$IMG_PATH"
        echo "✓ Created sparse OSD image $IMG_PATH on $NODE"
      fi

      # Detach ghost loops and wrong-path attachments for this node's device only.
      docker exec "$NODE" bash -c '
        set -euo pipefail
        IMG="'"$IMG_PATH"'"
        DEV="'"$DEVICE"'"
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          loop="$${line%%:*}"
          if echo "$line" | grep -q "(deleted)"; then
            echo "  Detaching ghost loop $loop"
            losetup -d "$loop" 2>/dev/null || true
          fi
        done < <(losetup -a 2>/dev/null || true)
        if losetup "$DEV" >/dev/null 2>&1; then
          backing=$(losetup -n -O BACK-FILE "$DEV" 2>/dev/null || true)
          if [ -n "$backing" ] && [ "$backing" != "$IMG" ]; then
            echo "  Detaching $DEV (was backed by $backing, want $IMG)"
            losetup -d "$DEV" 2>/dev/null || true
          fi
        fi
        # Drop stale LVM on this loop before re-attach (kind nodes share the host loop table).
        VG="rookosd-$(echo "'"$NODE"'" | tr -cd "[:alnum:]")"
        vgchange -an "$VG" 2>/dev/null || true
        vgremove -f "$VG" 2>/dev/null || true
      '

      # Attach image to the expected loop device.
      EXISTING_LOOP=$(docker exec "$NODE" losetup -j "$IMG_PATH" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
      if [ -n "$EXISTING_LOOP" ] && [ "$EXISTING_LOOP" = "$DEVICE" ]; then
        echo "  $DEVICE already attached to $IMG_PATH on $NODE"
      else
        if docker exec "$NODE" losetup "$DEVICE" >/dev/null 2>&1; then
          echo "⚠ $DEVICE in use on $NODE, detaching..."
          docker exec "$NODE" losetup -d "$DEVICE" 2>/dev/null || true
        fi
        echo "Attaching $IMG_PATH to $DEVICE on $NODE..."
        docker exec "$NODE" losetup "$DEVICE" "$IMG_PATH"
        echo "✓ Attached $IMG_PATH to $DEVICE on $NODE"
      fi

      if ! docker exec "$NODE" test -b "$DEVICE" 2>/dev/null; then
        echo "✗ $DEVICE is not a block device on $NODE after setup"
        exit 1
      fi
      echo "✓ OSD block device $DEVICE is ready on $NODE (backed by $IMG_PATH)"

      # Ceph-volume on kind needs LVM + /dev/mapper symlinks (no udev in containers).
      echo "Ensuring LVM volume on $NODE..."
      docker exec "$NODE" bash -c '
        set -euo pipefail
        NODE="'"$NODE"'"
        VG="rookosd-$(echo "$NODE" | tr -cd "[:alnum:]")"
        LV=data
        DEV="'"$DEVICE"'"
        MAPPER="rookosd--$(echo "$NODE" | sed "s/-//g")-data"

        refresh_dm_nodes() {
          mkdir -p /dev/mapper
          dmsetup mknodes 2>/dev/null || true
          for d in $(dmsetup ls 2>/dev/null | cut -f1); do
            major=$(dmsetup info -c --noheadings -o major "$d")
            minor=$(dmsetup info -c --noheadings -o minor "$d")
            node="/dev/dm-$minor"
            [ -e "$node" ] || mknod -m 660 "$node" b "$major" "$minor"
            ln -sf "../dm-$minor" "/dev/mapper/$d"
          done
        }

        refresh_lvm_dev_nodes() {
          for d in $(dmsetup ls 2>/dev/null | cut -f1); do
            case "$d" in
              rookosd--*-data)
                nodepart=$(echo "$d" | sed "s/^rookosd--//; s/-data$//")
                vg="rookosd-$nodepart"
                lv=data
                minor=$(dmsetup info -c --noheadings -o minor "$d")
                mkdir -p "/dev/$vg"
                ln -sf "../dm-$minor" "/dev/$vg/$lv"
                ;;
            esac
          done
        }

        # kind has no udevd (/sys is ro) — ceph-volume v20 requires /run/udev/data stubs.
        refresh_udev_stubs() {
          mkdir -p /run/udev/data
          for devpath in /sys/block/*; do
            [ -f "$devpath/dev" ] || continue
            dev=$(basename "$devpath")
            majmin=$(tr -d " \n" < "$devpath/dev")
            major=$${majmin%%:*}
            minor=$${majmin##*:}
            file="/run/udev/data/b$${major}:$${minor}"
            cat > "$file" <<EOF
S:disk/by-diskseq/$${dev}
E:DEVTYPE=disk
E:ID_FS_TYPE=
EOF
            for part in "$devpath"/*; do
              [ -f "$part/dev" ] || continue
              pname=$(basename "$part")
              majmin=$(tr -d " \n" < "$part/dev")
              major=$${majmin%%:*}
              minor=$${majmin##*:}
              file="/run/udev/data/b$${major}:$${minor}"
              cat > "$file" <<EOF
S:disk/by-diskseq/$${dev}-$${pname}
E:DEVTYPE=partition
E:ID_FS_TYPE=
EOF
            done
          done
          for d in $(dmsetup ls 2>/dev/null | cut -f1); do
            minor=$(dmsetup info -c --noheadings -o minor "$d")
            major=$(dmsetup info -c --noheadings -o major "$d")
            file="/run/udev/data/b$${major}:$${minor}"
            cat > "$file" <<EOF
S:disk/by-id/dm-name-$${d}
S:mapper/$${d}
E:DEVTYPE=disk
E:DM_NAME=$${d}
E:ID_FS_TYPE=
E:ID_PART_TABLE=
EOF
          done
        }

        if ! command -v pvcreate >/dev/null 2>&1; then
          apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lvm2
        fi

        needs_create=true
        if lvs "$VG/$LV" &>/dev/null; then
          pv_dev=$(pvs --noheadings -o pv_name -S vg_name="$VG" 2>/dev/null | tr -d " " | head -1 || true)
          if [ "$pv_dev" = "$DEV" ] && [ -e "/dev/mapper/$MAPPER" ]; then
            echo "  LVM $VG/$LV already valid on $NODE"
            needs_create=false
          else
            echo "  Recreating LVM $VG/$LV (pv=$pv_dev dev=$DEV mapper=$MAPPER)"
            vgremove -f "$VG" 2>/dev/null || true
          fi
        fi

        if [ "$needs_create" = true ]; then
          if vgs "$VG" &>/dev/null; then
            vgremove -f "$VG" || true
          fi
          wipefs -a "$DEV" 2>/dev/null || true
          pvcreate --yes -ff "$DEV"
          vgcreate "$VG" "$DEV"
          lvcreate --yes --noudevsync -Zn -l 100%FREE -n "$LV" "$VG"
          vgchange -ay "$VG"
          echo "  Created LVM $VG/$LV on $NODE"
        fi

        refresh_dm_nodes
        refresh_lvm_dev_nodes
        refresh_udev_stubs
        if [ ! -e "/dev/mapper/$MAPPER" ]; then
          echo "✗ /dev/mapper/$MAPPER missing after LVM setup on $NODE"
          dmsetup ls
          ls -la /dev/mapper/ || true
          exit 1
        fi
        echo "  ✓ /dev/mapper/$MAPPER ready on $NODE"
      '
      echo "✓ LVM ready on $NODE"
    EOT
  }

  depends_on = [null_resource.create_rook_data_dir]
}

# Create directory-backed OSD paths on kind worker nodes (used when create_loop_devices = false).
resource "null_resource" "setup_osd_directories" {
  for_each = local.osd_directory_pairs

  triggers = {
    node_name = each.value.node_name
    dir_path  = each.value.dir_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      NODE="${each.value.node_name}"
      DIR="${each.value.dir_path}"

      if ! docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
        echo "✗ Node $NODE not found"
        exit 1
      fi

      docker exec "$NODE" mkdir -p "$DIR"
      docker exec "$NODE" chmod 777 "$DIR"
      echo "✓ Created OSD directory $DIR on $NODE"
    EOT
  }

  depends_on = [null_resource.create_rook_data_dir]
}
