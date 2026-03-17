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
    for pair in flatten([
      for node in var.storage_nodes : [
        for device in node.devices : {
          node_name   = node.name
          device_path = device
        }
      ]
    ]) : "${pair.node_name}:${pair.device_path}" => pair
  } : {}
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
    command = <<-EOT
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
    command = <<-EOT
      set -euo pipefail
      NODE="${each.value.node_name}"
      DEVICE="${each.value.device_path}"
      # Derive image filename from device basename: /dev/loop10 → loop10.img
      DEV_BASENAME=$(basename "$DEVICE")
      IMG_PATH="${var.data_dir_host_path}/$DEV_BASENAME.img"
      SIZE_GB="${var.loop_device_image_size_gb}"

      if ! docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
        echo "✗ Node $NODE not found"
        exit 1
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

      # Check if this image is already attached to any loop device
      EXISTING_LOOP=$(docker exec "$NODE" losetup -j "$IMG_PATH" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
      if [ -n "$EXISTING_LOOP" ]; then
        if [ "$EXISTING_LOOP" = "$DEVICE" ]; then
          echo "  $DEVICE already attached to $IMG_PATH on $NODE — nothing to do"
        else
          echo "  $IMG_PATH is attached to $EXISTING_LOOP (expected $DEVICE) on $NODE — using existing attachment"
        fi
      else
        # Target loop device might be in use by something else — detach it first
        if docker exec "$NODE" losetup "$DEVICE" >/dev/null 2>&1; then
          echo "⚠ $DEVICE is already in use on $NODE, detaching..."
          docker exec "$NODE" losetup -d "$DEVICE" 2>/dev/null || true
        fi

        echo "Attaching $IMG_PATH to $DEVICE on $NODE..."
        docker exec "$NODE" losetup "$DEVICE" "$IMG_PATH"
        echo "✓ Attached $IMG_PATH to $DEVICE on $NODE"
      fi

      # Verify the result is a usable block device
      if docker exec "$NODE" test -b "$DEVICE" 2>/dev/null; then
        echo "✓ OSD block device $DEVICE is ready on $NODE (backed by $IMG_PATH)"
      else
        echo "✗ $DEVICE is not a block device on $NODE after setup"
        exit 1
      fi
    EOT
  }

  depends_on = [null_resource.create_rook_data_dir]
}
