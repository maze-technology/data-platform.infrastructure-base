# Create Rook data directory on Kind nodes and host with proper permissions
# This is required for Rook to store cluster data on the host filesystem
# For Kind clusters with extraMounts, we need to create the directory on:
# 1. The host filesystem (where extraMounts points to)
# 2. Inside each Kind node container (as a fallback and for initial setup)

locals {
  # Detect Kind nodes by checking for nodes with "kind" in their name
  # This works for standard Kind setups (local-control-plane, local-worker, etc.)
  kind_nodes = [
    "local-control-plane",
    "local-worker"
  ]
}

# Data source to check if directory exists on each node
# This ensures the null_resource is recreated if the directory is missing
data "external" "check_rook_dir" {
  for_each = toset(local.kind_nodes)
  program  = ["sh", "-c", <<-EOT
    NODE="${each.key}"
    DIR="${var.data_dir_host_path}"
    if docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
      # Check if parent directory exists (we don't check for rook-ceph subdirectory
      # as Rook will create it)
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

# Create the Rook data directory on each Kind node
# Uses null_resource with local-exec to run commands inside the Kind node containers
resource "null_resource" "create_rook_data_dir" {
  for_each = toset(local.kind_nodes)

  # Trigger recreation if:
  # - The data_dir_host_path changes
  # - The directory existence check changes (directory missing or node state changes)
  triggers = {
    data_dir_host_path = var.data_dir_host_path
    node_name          = each.key
    # Include directory existence check in trigger to force recreation if missing
    dir_exists         = try(data.external.check_rook_dir[each.key].result.exists, "unknown")
    dir_path           = try(data.external.check_rook_dir[each.key].result.path, var.data_dir_host_path)
  }

  provisioner "local-exec" {
    # Use a simple script that checks node existence and creates directory
    # This avoids complex heredoc interpolation issues
    command = <<-EOT
      set -euo pipefail
      NODE="${each.key}"
      DIR="${var.data_dir_host_path}"

      # First, create directory on the host filesystem
      # This is required when Kind uses extraMounts to mount hostPath volumes
      # The host directory must exist before Kind mounts it into node containers
      # Note: We do NOT create the rook-ceph subdirectory - Rook will create it
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

      # Check if node exists
      if ! docker ps --format '{{.Names}}' | grep -qxF "$NODE"; then
        echo "⚠ Node $NODE not found, skipping directory creation in container"
        exit 1
      fi

      # Create directory inside the Kind node container
      # This is critical because Kind mounts the host directory, and if it doesn't exist
      # on the host, the mount might not work. But we also create it inside the container
      # to ensure it exists regardless of mount status.
      echo "Creating directory inside node container: $NODE:$DIR"
      
      # Create parent directory first if it doesn't exist
      docker exec "$NODE" mkdir -p "$(dirname "$DIR")" || {
        echo "✗ Failed to create parent directory $(dirname "$DIR") on node $NODE"
        exit 1
      }
      
      # Create the main directory
      docker exec "$NODE" mkdir -p "$DIR" || {
        echo "✗ Failed to create $DIR on node $NODE"
        exit 1
      }
      
      # Set permissions (777 = rwxrwxrwx)
      # Using 777 as a workaround because MON pods may run as non-root user
      # and need write access. This is safe in Kind containers which are isolated.
      docker exec "$NODE" chmod 777 "$DIR" || {
        echo "⚠ Failed to set permissions on $DIR, trying 755"
        docker exec "$NODE" chmod 755 "$DIR" || {
          echo "✗ Failed to set permissions on $DIR on node $NODE"
          exit 1
        }
      }
      
      # Note: We do NOT pre-create the rook-ceph subdirectory
      # Rook expects to create /var/lib/rook/rook-ceph itself, and pre-creating it
      # can cause permission issues or conflicts. We only ensure the parent directory
      # /var/lib/rook exists with proper permissions so Rook can create the subdirectory.
      
      # Verify creation and permissions of parent directory
      if ! docker exec "$NODE" test -d "$DIR"; then
        echo "✗ Directory $DIR does not exist on node $NODE after creation"
        exit 1
      fi
      
      # Verify write permissions by attempting to create a test file
      if docker exec "$NODE" touch "$DIR/.write-test" 2>/dev/null; then
        docker exec "$NODE" rm -f "$DIR/.write-test" 2>/dev/null || true
        echo "✓ Created $DIR on node $NODE with write permissions"
        echo "  Note: Rook will create $DIR/rook-ceph subdirectory when needed"
      else
        echo "⚠ Directory $DIR exists but may not be writable on node $NODE"
        echo "  This might cause issues. Checking permissions..."
        docker exec "$NODE" ls -ld "$DIR" || true
      fi
    EOT
  }

  # Cleanup: remove directory when resource is destroyed (optional)
  # Commented out to preserve data during teardown
  # provisioner "local-exec" {
  #   when    = destroy
  #   command = "docker exec ${each.key} rm -rf '${var.data_dir_host_path}' 2>/dev/null || true"
  # }
}
