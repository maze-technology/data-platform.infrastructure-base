# Install kubernetes-sigs/agent-sandbox controller + Sandbox CRD (required for sandbox-cr).
resource "null_resource" "agent_sandbox" {
  triggers = {
    version = var.agent_sandbox_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      VERSION='${var.agent_sandbox_version}'
      URL="https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$${VERSION}/sandbox.yaml"
      echo "Applying agent-sandbox $${VERSION} from $${URL}"
      kubectl apply --server-side --force-conflicts -f "$${URL}"
      kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=300s
      kubectl get crd sandboxes.agents.x-k8s.io >/dev/null
    EOT
  }
}
