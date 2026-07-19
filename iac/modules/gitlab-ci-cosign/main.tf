# Wire COSIGN_* as GitLab instance CI variables (from Vault) and ensure org group
# maze is shared with engineers (+ admins Owner). Cleans up obsolete algo groups.
# Requires VAULT_ADDR + VAULT_TOKEN in the apply environment.

terraform {
  required_providers {
    null = {
      source = "hashicorp/null"
    }
  }
}

resource "null_resource" "gitlab_cosign_instance_vars" {
  triggers = {
    org_group       = var.org_group_path
    engineers_group = var.engineers_gitlab_group
    admin_group     = var.admin_gitlab_group
    delete_groups   = join(",", var.delete_group_paths)
    vault_path      = "${var.vault_kv_mount}/${var.vault_secret_path}"
    generation      = "7"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      GITLAB_NS          = var.gitlab_namespace
      ORG_GROUP_PATH     = var.org_group_path
      ORG_GROUP_NAME     = var.org_group_name
      ENGINEERS_GROUP    = var.engineers_gitlab_group
      ADMIN_GROUP        = var.admin_gitlab_group
      DELETE_GROUP_PATHS = join(",", var.delete_group_paths)
      VAULT_KV_MOUNT     = var.vault_kv_mount
      VAULT_SECRET_PATH  = var.vault_secret_path
      API_TOKEN_SECRET   = var.api_token_secret_name
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
org_path = os.environ["ORG_GROUP_PATH"].strip()
org_name = os.environ["ORG_GROUP_NAME"].strip() or org_path
engineers = os.environ.get("ENGINEERS_GROUP", "").strip()
admins = os.environ.get("ADMIN_GROUP", "").strip()
delete_paths = [p.strip() for p in os.environ.get("DELETE_GROUP_PATHS", "").split(",") if p.strip()]

ACCESS_MAINTAINER = 40
ACCESS_OWNER = 50

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

def ensure_group(path, name, parent_id=None, visibility="private", acl_only=False):
    """Create/update a group. acl_only=True → no project/subgroup creation (OIDC roster)."""
    settings = {"visibility": visibility}
    if acl_only:
        settings.update(
            {
                "project_creation_level": "noone",
                "subgroup_creation_level": "owner",
                "request_access_enabled": False,
                "description": "OIDC ACL roster only — do not create projects here; use group maze.",
            }
        )
    existing = get_group(path)
    if existing:
        print(f"group {path} exists id={existing['id']}")
        req("PUT", f"/groups/{existing['id']}", settings)
        return existing["id"]
    payload = {"name": name, "path": path.split("/")[-1], **settings}
    if parent_id is not None:
        payload["parent_id"] = int(parent_id)
    code, body = req("POST", "/groups", payload)
    if code not in (200, 201):
        raise SystemExit(f"create group {path} failed: {code} {body}")
    print(f"created group {path} id={body['id']} acl_only={acl_only}")
    return body["id"]

def delete_group(path):
    g = get_group(path)
    if not g:
        print(f"delete skip missing group {path}")
        return
    code, body = req("DELETE", f"/groups/{g['id']}")
    if code not in (200, 202, 204):
        raise SystemExit(f"delete group {path} failed: {code} {body}")
    print(f"deleted group {path} id={g['id']}")

def share_group(group_id, shared_with_path, access_level):
    shared = get_group(shared_with_path)
    if not shared:
        shared_id = ensure_group(
            shared_with_path, shared_with_path.split("/")[-1], None, "private", acl_only=True
        )
    else:
        shared_id = shared["id"]
    req("DELETE", f"/groups/{group_id}/share/{shared_id}")
    code, body = req(
        "POST",
        f"/groups/{group_id}/share",
        {"group_id": shared_id, "group_access": access_level},
    )
    if code not in (200, 201):
        raise SystemExit(f"share {group_id} with {shared_with_path} failed: {code} {body}")
    print(f"shared group {group_id} with {shared_with_path} access={access_level}")

def put_instance_variable(key, value, masked=True):
    enc = urllib.parse.quote(key, safe="")
    # Prefer update; create if missing
    code, body = req(
        "PUT",
        f"/admin/ci/variables/{enc}",
        {
            "value": value,
            "masked": masked,
            "protected": True,
            "variable_type": "env_var",
        },
    )
    if code in (200, 201):
        print(f"updated instance variable {key}")
        return
    code, body = req(
        "POST",
        "/admin/ci/variables",
        {
            "key": key,
            "value": value,
            "masked": masked,
            "protected": True,
            "variable_type": "env_var",
        },
    )
    if code not in (200, 201):
        raise SystemExit(f"set instance variable {key} failed: {code} {body}")
    print(f"created instance variable {key}")

# Delete obsolete groups (deepest paths first)
for path in sorted(delete_paths, key=lambda p: p.count("/"), reverse=True):
    if path == org_path:
        print(f"refusing to delete org group {path}")
        continue
    delete_group(path)

org_id = ensure_group(org_path, org_name, None, "private", acl_only=False)
if engineers:
    ensure_group(engineers, engineers, None, "private", acl_only=True)
    share_group(org_id, engineers, ACCESS_MAINTAINER)
if admins:
    ensure_group(admins, admins, None, "private", acl_only=True)
    share_group(org_id, admins, ACCESS_OWNER)

# PEM keys contain newlines/spaces — GitLab masked vars reject those.
priv_b64 = base64.b64encode(os.environ["PRIVATE_KEY"].encode()).decode()
pub_b64 = base64.b64encode(os.environ["PUBLIC_KEY"].encode()).decode()

put_instance_variable("COSIGN_PRIVATE_KEY", priv_b64, True)
put_instance_variable("COSIGN_PASSWORD", os.environ["COSIGN_PASSWORD_VALUE"], True)
put_instance_variable("COSIGN_PUBLIC_KEY", pub_b64, True)
print(f"gitlab-ci-cosign: instance COSIGN_* wired; org={org_path} engineers={engineers} admins={admins}")
PY
    EOT
  }
}
