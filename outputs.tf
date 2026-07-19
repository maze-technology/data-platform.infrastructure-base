output "environment" {
  description = "Environment name passed into the module"
  value       = var.environment
}

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = var.cluster_name
}

output "cluster_domain" {
  description = "Base domain for cluster services"
  value       = var.cluster_domain
}

output "hosts" {
  description = "Feature hostnames derived from cluster_domain"
  value       = local.hosts
}

output "service_urls" {
  description = "Service URLs (VPN-gated; trust Maze CA locally or Let's Encrypt in production)"
  value = {
    auth_admin   = "${module.keycloak.admin_console_url}/admin"
    auth_realm   = module.keycloak.issuer_url
    scm          = "https://${local.hosts.scm}"
    registry     = "https://${local.hosts.registry}"
    grafana      = "https://${local.hosts.grafana}"
    argocd       = "https://${local.hosts.argocd}"
    vault        = "https://${local.hosts.vault}"
    vpn_endpoint = var.wireguard_service_type == "NodePort" ? "${local.hosts.vpn}:${var.wireguard_node_port}/udp" : "${local.wireguard_server}/udp"
  }
}

output "etc_hosts" {
  description = "Lines to add to /etc/hosts — set cluster_public_ip for ready-to-paste output"
  value = var.cluster_public_ip != "" ? join("\n", [
    for host in values(local.hosts) : "${var.cluster_public_ip}  ${host}"
  ]) : <<-EOT
    # Set cluster_public_ip to generate ready-to-paste lines
    # Example (replace VPS_IP):
    ${join("\n", [for host in values(local.hosts) : "# VPS_IP  ${host}"])}
  EOT
}

output "maze_ca_install_hint" {
  description = "How to export the Maze CA for trusting local HTTPS (empty when create_maze_ca is false)"
  value       = var.create_maze_ca ? "kubectl get secret maze-ca -n cert-manager -o jsonpath='{.data.ca\\.crt}' | base64 -d > maze-ca.crt" : ""
}

output "wireguard_peer_config_command" {
  description = "Retrieve WireGuard config for bootstrap admin (run on a machine with kubectl access)"
  value       = "kubectl exec -n wireguard deploy/wireguard -- cat /config/peer_${nonsensitive(var.bootstrap_admin.username)}/peer_${nonsensitive(var.bootstrap_admin.username)}.conf"
}

output "vpn_subnet" {
  description = "WireGuard VPN subnet CIDR"
  value       = module.wireguard.vpn_subnet
}

output "storage_class_name" {
  description = "Rook-Ceph RBD StorageClass (unencrypted)"
  value       = module.rook_ceph.storage_class_name
}

output "encrypted_storage_class_name" {
  description = "Rook-Ceph encrypted RBD StorageClass"
  value       = module.rook_ceph.encrypted_storage_class_name
}

output "rgw_endpoint" {
  description = "In-cluster S3 endpoint for Rook-Ceph RGW"
  value       = module.rook_ceph.rgw_endpoint
}

output "loki_bucket_name" {
  description = "S3 bucket used by Loki"
  value       = local.loki_bucket_name
}

output "gitlab_bucket_name" {
  description = "S3 bucket used by GitLab object storage"
  value       = local.gitlab_bucket_name
}

output "gitlab_url" {
  description = "GitLab web UI URL"
  value       = module.gitlab.gitlab_url
}

output "registry_url" {
  description = "GitLab Container Registry URL"
  value       = module.gitlab.registry_url
}

output "gitlab_gateway_cluster_ip" {
  description = "Envoy Gateway ClusterIP for scm/registry DNS"
  value       = module.gitlab.gateway_cluster_ip
}

output "keycloak_issuer_url" {
  description = "OIDC issuer URL"
  value       = module.keycloak.issuer_url
}

output "tls_cluster_issuer" {
  description = "cert-manager ClusterIssuer name used for ingress TLS"
  value       = module.cert_manager.cluster_issuer_name
}

output "cosign_vault_path" {
  description = "Vault path for cosign signing keys (private_key, public_key, password)"
  value       = module.cosign_keys.vault_path
}

output "cosign_ci_scope" {
  description = "COSIGN_* CI variables are instance-level (available to all projects)"
  value       = module.gitlab_ci_cosign.cosign_scope
}

output "gitlab_org_group" {
  description = "GitLab org group shared with engineers"
  value       = module.gitlab_ci_cosign.org_group_path
}

output "kyverno_signed_images_label" {
  description = "Label namespaces with this to require cosign-verified images from the Maze registry"
  value       = module.kyverno.namespace_opt_in_label
}

output "bootstrap_credentials" {
  description = "Initial credentials — day-to-day login is Keycloak SSO; Keycloak master is break-glass only"
  sensitive   = true
  value = {
    sso = {
      username = var.bootstrap_admin.username
      password = var.bootstrap_admin.password
      realm    = module.keycloak.realm
      note     = "Use Keycloak SSO on GitLab, Grafana, and Argo CD (local passwords disabled)"
    }
    keycloak_master = {
      username = var.keycloak_admin_username
      url      = "${module.keycloak.admin_console_url}/admin"
      note     = "Break-glass IdP admin only"
    }
  }
}

output "backup_namespace" {
  description = "Velero namespace when backups are enabled"
  value       = module.backup.namespace
}

output "backup_schedule" {
  description = "Configured Velero schedule name, cron, retention TTL, and RGW object mirror"
  sensitive   = true
  value = var.backup_enabled ? {
    name                = module.backup.schedule_name
    cron                = module.backup.schedule_cron
    ttl                 = module.backup.backup_ttl
    bucket              = module.backup.s3_bucket
    prefix              = module.backup.s3_prefix
    object_sync_enabled = module.backup.object_sync_enabled
    object_sync_cron    = module.backup.object_sync_schedule_cron
    object_sync_prefix  = module.backup.object_sync_dest_prefix
    object_sync_sources = module.backup.object_sync_source_names
  } : null
}
