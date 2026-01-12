resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.vault.metadata[0].name

  timeout = 1800  # 30 minutes to allow for large image pulls

  # Don't wait for all resources to be ready - let them start in background
  # This prevents timeout during image pulls
  # wait = false
  # wait_for_jobs = false

  values = [
    yamlencode({
      global = {
        tlsDisable = !var.enable_tls
      }
      server = {
        replicas = var.enable_ha ? var.replica_count : 1
        image = {
          repository = "hashicorp/vault"
          tag        = var.vault_version
        }
        resources = {
          requests = var.resource_requests.server
          limits   = var.resource_limits.server
        }
        # Data storage configuration
        dataStorage = {
          enabled      = var.storage_backend != "kubernetes"
          size         = var.storage_size
          storageClass = var.storage_class != "" ? var.storage_class : null
        }
        # Dev mode for local development (ephemeral storage)
        # For production, use file or raft storage backend
        extraArgs = var.storage_backend == "kubernetes" ? "-dev -dev-listen-address=0.0.0.0:8200" : ""
        # Ingress configuration
        ingress = {
          enabled          = var.ingress_enabled
          ingressClassName = var.ingress_class
          hosts = var.ingress_enabled ? [
            {
              host  = var.ingress_host
              paths = ["/"]
            }
          ] : []
          tls = var.enable_tls && var.ingress_enabled ? [
            {
              hosts      = [var.ingress_host]
              secretName = var.tls_secret_name
            }
          ] : []
        }
        # Service configuration
        service = merge(
          {
            type = var.service_type
          },
          var.service_type == "NodePort" ? {
            nodePort = {
              http  = var.node_port_http
              https = var.node_port_https
            }
          } : {}
        )
        # UI enabled
        ui = {
          enabled = true
        }
        # Standalone mode for single replica (dev)
        # HA mode for multiple replicas with Raft storage
        ha = {
          enabled = var.enable_ha
          replicas = var.enable_ha ? var.replica_count : 1
          # Raft storage for HA mode
          raft = var.enable_ha ? {
            enabled = true
            setNodeId = true
          } : {}
        }
      }
      # Injector for automatic secret injection into pods
      injector = {
        enabled = true
        resources = {
          requests = var.resource_requests.injector
          limits   = var.resource_limits.injector
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.vault]
}
