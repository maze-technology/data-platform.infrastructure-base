# Ensure GitLab group maze/algos exists and wire COSIGN_* group CI/CD variables
# from Vault secret/cosign/gitlab. Uses toolbox + webservice port-forward.
# Requires VAULT_ADDR + VAULT_TOKEN in the apply environment.

terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "null_resource" "gitlab_cosign_group_vars" {
  triggers = {
    group_path = var.group_full_path
    vault_path = "${var.vault_kv_mount}/${var.vault_secret_path}"
    generation = "4"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GITLAB_NS         = var.gitlab_namespace
      GROUP_FULL_PATH   = var.group_full_path
      PARENT_GROUP_NAME = var.parent_group_name
      LEAF_GROUP_NAME   = var.group_name
      VAULT_KV_MOUNT    = var.vault_kv_mount
      VAULT_SECRET_PATH = var.vault_secret_path
      API_TOKEN_SECRET  = var.api_token_secret_name
    }
    command = <<-EOT
      set -euo pipefail
      if [ -z "$${VAULT_ADDR:-}" ] || [ -z "$${VAULT_TOKEN:-}" ]; then
        echo "VAULT_ADDR and VAULT_TOKEN must be set to read cosign keys" >&2
        exit 1
      fi

      NS="$${GITLAB_NS}"
      kubectl -n "$NS" wait --for=condition=available deploy/gitlab-webservice-default --timeout=900s
      kubectl -n "$NS" wait --for=condition=ready pod -l app=toolbox --timeout=300s

      POD=""
      for i in $(seq 1 30); do
        POD="$(kubectl -n "$NS" get pod -l app=toolbox --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        [ -n "$POD" ] && break
        sleep 10
      done
      [ -n "$POD" ] || { echo "gitlab-ci-cosign: no toolbox pod" >&2; exit 1; }

      TOKEN=""
      if kubectl -n "$NS" get secret "$${API_TOKEN_SECRET}" >/dev/null 2>&1; then
        TOKEN="$(kubectl -n "$NS" get secret "$${API_TOKEN_SECRET}" -o jsonpath='{.data.token}' | base64 -d)"
      fi
      if [ -z "$TOKEN" ]; then
        TOKEN="$(kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "$(cat <<'RUBY'
user = User.find_by_username('root')
raise 'root missing' if user.nil?
existing = user.personal_access_tokens.find_by(name: 'opentofu-ci-vars')
existing.destroy! if existing
pat = user.personal_access_tokens.create!(
  name: 'opentofu-ci-vars',
  scopes: %w[api read_api],
  expires_at: 1.year.from_now
)
puts pat.token
RUBY
)" 2>/dev/null | tail -n 1 | tr -d '\r')"
        [ "$${#TOKEN}" -ge 16 ] || { echo "gitlab-ci-cosign: failed to create PAT" >&2; exit 1; }
        kubectl -n "$NS" create secret generic "$${API_TOKEN_SECRET}" \
          --from-literal=token="$TOKEN" \
          --dry-run=client -o yaml | kubectl apply -f -
        kubectl -n "$NS" label secret "$${API_TOKEN_SECRET}" managed-by=opentofu purpose=gitlab-api --overwrite
      fi

      PF_LOCAL=18181
      if ss -ltn 2>/dev/null | grep -q ":$${PF_LOCAL} " || netstat -ltn 2>/dev/null | grep -q ":$${PF_LOCAL} "; then
        PF_LOCAL=18182
      fi
      kubectl -n "$NS" port-forward svc/gitlab-webservice-default "$${PF_LOCAL}:8181" >/tmp/gitlab-pf-cosign.log 2>&1 &
      PF_PID=$!
      trap 'kill $PF_PID 2>/dev/null || true' EXIT
      code=""
      TOKEN_RECREATED=0
      for i in $(seq 1 60); do
        code="$(curl -s -o /tmp/gitlab-ver.json -w '%%{http_code}' \
          -H "PRIVATE-TOKEN: $${TOKEN}" \
          "http://127.0.0.1:$${PF_LOCAL}/api/v4/version" || true)"
        if [ "$code" = "200" ]; then
          break
        fi
        if [ "$code" = "401" ] && [ "$TOKEN_RECREATED" != "1" ]; then
          echo "gitlab-ci-cosign: PAT rejected, recreating..."
          kubectl -n "$NS" delete secret "$${API_TOKEN_SECRET}" --ignore-not-found
          TOKEN="$(kubectl -n "$NS" exec "$POD" -- gitlab-rails runner "$(cat <<'RUBY'
User.find_by_username('root').personal_access_tokens.where(name: 'opentofu-ci-vars').destroy_all
pat = User.find_by_username('root').personal_access_tokens.create!(
  name: 'opentofu-ci-vars',
  scopes: %w[api read_api],
  expires_at: 1.year.from_now
)
puts pat.token
RUBY
)" 2>/dev/null | tail -n 1 | tr -d '\r')"
          kubectl -n "$NS" create secret generic "$${API_TOKEN_SECRET}" \
            --from-literal=token="$TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
          TOKEN_RECREATED=1
        fi
        sleep 2
      done
      if [ "$${code:-}" != "200" ]; then
        echo "gitlab-ci-cosign: API not ready code=$${code:-none} (see /tmp/gitlab-pf-cosign.log /tmp/gitlab-ver.json)" >&2
        cat /tmp/gitlab-ver.json 2>/dev/null || true
        exit 1
      fi

      export GITLAB_TOKEN="$TOKEN"
      export GITLAB_API="http://127.0.0.1:$${PF_LOCAL}/api/v4"
      export PRIVATE_KEY="$(vault kv get -mount="$${VAULT_KV_MOUNT}" -field=private_key "$${VAULT_SECRET_PATH}")"
      export PUBLIC_KEY="$(vault kv get -mount="$${VAULT_KV_MOUNT}" -field=public_key "$${VAULT_SECRET_PATH}")"
      export COSIGN_PASSWORD_VALUE="$(vault kv get -mount="$${VAULT_KV_MOUNT}" -field=password "$${VAULT_SECRET_PATH}")"

      python3 <<'PY'
import base64
import json, os, urllib.parse, urllib.request

api = os.environ["GITLAB_API"].rstrip("/")
token = os.environ["GITLAB_TOKEN"]
group_full = os.environ["GROUP_FULL_PATH"]
parent_name = os.environ["PARENT_GROUP_NAME"]
leaf_name = os.environ["LEAF_GROUP_NAME"]
parent_path, leaf_path = group_full.split("/", 1)

def req(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    r = urllib.request.Request(
        f"{api}{path}",
        data=data,
        method=method,
        headers={
            "PRIVATE-TOKEN": token,
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            payload = json.loads(raw) if raw else {}
        except Exception:
            payload = {"message": raw}
        return e.code, payload

def get_group(path):
    enc = urllib.parse.quote(path, safe="")
    code, body = req("GET", f"/groups/{enc}")
    return body if code == 200 else None

def ensure_group(path, name, parent_id=None):
    existing = get_group(path)
    if existing:
        print(f"group {path} exists id={existing['id']}")
        return existing["id"]
    payload = {"name": name, "path": path.split("/")[-1], "visibility": "private"}
    if parent_id is not None:
        payload["parent_id"] = int(parent_id)
    code, body = req("POST", "/groups", payload)
    if code not in (200, 201):
        raise SystemExit(f"create group {path} failed: {code} {body}")
    print(f"created group {path} id={body['id']}")
    return body["id"]

def put_variable(group_id, key, value, masked):
    enc = urllib.parse.quote(key, safe="")
    req("DELETE", f"/groups/{group_id}/variables/{enc}")
    code, body = req(
        "POST",
        f"/groups/{group_id}/variables",
        {
            "key": key,
            "value": value,
            "masked": masked,
            "protected": True,
            "variable_type": "env_var",
        },
    )
    if code not in (200, 201):
        raise SystemExit(f"set variable {key} failed: {code} {body}")
    print(f"set group variable {key}")

parent_id = ensure_group(parent_path, parent_name)
group_id = ensure_group(group_full, leaf_name, parent_id)

# PEM keys contain newlines/spaces — GitLab masked vars reject those.
# Store base64; CI template decodes before cosign.
priv_b64 = base64.b64encode(os.environ["PRIVATE_KEY"].encode()).decode()
pub_b64 = base64.b64encode(os.environ["PUBLIC_KEY"].encode()).decode()

put_variable(group_id, "COSIGN_PRIVATE_KEY", priv_b64, True)
put_variable(group_id, "COSIGN_PASSWORD", os.environ["COSIGN_PASSWORD_VALUE"], True)
put_variable(group_id, "COSIGN_PUBLIC_KEY", pub_b64, True)
print(f"gitlab-ci-cosign: COSIGN_* (base64 keys) wired on group {group_full}")
PY
    EOT
  }
}
