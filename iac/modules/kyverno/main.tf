# Kyverno admission: enforce cosign signatures on opted-in namespaces.
# Opt-in: label the namespace with <cluster_domain>/require-signed-images=true
# (e.g. maze.local/... locally, maze.tech/... in production).
# Platform namespaces (gitlab, keycloak, …) stay unsigned and unaffected.

terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    helm = {
      source = "hashicorp/helm"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = var.namespace
    labels = {
      name        = var.namespace
      environment = var.environment
      managed-by  = "opentofu"
    }
  }
}

resource "kubernetes_secret" "cosign_public_key" {
  metadata {
    name      = var.cosign_secret_name
    namespace = kubernetes_namespace.kyverno.metadata[0].name
    labels = {
      managed-by  = "opentofu"
      purpose     = "cosign-verify"
      environment = var.environment
    }
  }

  data = {
    "cosign.pub" = var.cosign_public_key
  }

  type = "Opaque"
}

resource "helm_release" "kyverno" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  version    = var.helm_chart_version
  namespace  = kubernetes_namespace.kyverno.metadata[0].name

  timeout = 600

  values = [
    yamlencode({
      admissionController = {
        replicas = 1
        container = {
          resources = {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }
        }
      }
      backgroundController = {
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
        }
      }
      cleanupController = {
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
        }
      }
      reportsController = {
        resources = {
          requests = {
            cpu    = "25m"
            memory = "64Mi"
          }
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace.kyverno]
}

locals {
  image_references = [for h in var.registry_hosts : "${h}/*"]
  policy_yaml = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata = {
      name = var.policy_name
      labels = {
        managed-by  = "opentofu"
        environment = var.environment
        purpose     = "cosign-verify"
      }
      annotations = {
        "policies.kyverno.io/title"       = "Verify Maze algo image signatures"
        "policies.kyverno.io/category"    = "Software Supply Chain Security"
        "policies.kyverno.io/severity"    = "high"
        "policies.kyverno.io/description" = "Require cosign signatures on images from Maze registry in namespaces labeled ${var.namespace_label_key}=${var.namespace_label_value}."
      }
    }
    spec = {
      background              = false
      validationFailureAction = "Enforce"
      failurePolicy           = "Fail"
      webhookTimeoutSeconds   = 30
      rules = [
        {
          name = "verify-maze-registry-images"
          match = {
            any = [
              {
                resources = {
                  kinds = ["Pod"]
                  namespaceSelector = {
                    matchLabels = {
                      (var.namespace_label_key) = var.namespace_label_value
                    }
                  }
                }
              }
            ]
          }
          verifyImages = [
            {
              imageReferences = local.image_references
              required        = true
              mutateDigest    = true
              verifyDigest    = false
              failureAction   = "Enforce"
              attestors = [
                {
                  count = 1
                  entries = [
                    {
                      keys = {
                        secret = {
                          name      = var.cosign_secret_name
                          namespace = var.namespace
                        }
                        rekor = {
                          ignoreTlog = true
                        }
                        ctlog = {
                          ignoreSCT = true
                        }
                      }
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  })
}

# Applied after Helm so ClusterPolicy CRDs exist (avoids plan-time CRD requirement).
resource "null_resource" "verify_signed_images_policy" {
  triggers = {
    policy_hash = sha256(local.policy_yaml)
    chart       = helm_release.kyverno.id
    pubkey      = sha256(var.cosign_public_key)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      POLICY_YAML = local.policy_yaml
    }
    command = <<-EOT
      set -euo pipefail
      for i in $(seq 1 60); do
        if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      kubectl get crd clusterpolicies.kyverno.io >/dev/null
      kubectl wait --for condition=established --timeout=180s crd/clusterpolicies.kyverno.io
      printf '%s\n' "$POLICY_YAML" | kubectl apply -f -
    EOT
  }

  depends_on = [
    helm_release.kyverno,
    kubernetes_secret.cosign_public_key,
  ]
}
