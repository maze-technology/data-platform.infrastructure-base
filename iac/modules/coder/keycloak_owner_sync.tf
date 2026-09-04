# Live Keycloak → Coder Owner sync (OSS substitute for Premium IdP role sync).
# Same pattern as kellnr-keycloak-sync: Admin API membership reconcile + optional webhook.
# Desired owners = current members of Keycloak group `admins` (not an OpenTofu static list).

resource "random_password" "keycloak_owner_sync_webhook" {
  count   = var.keycloak_owner_sync != null ? 1 : 0
  length  = 32
  special = false
}

resource "kubernetes_config_map_v1" "keycloak_owner_sync" {
  count = var.keycloak_owner_sync != null ? 1 : 0

  metadata {
    name      = "coder-keycloak-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      app         = "coder-keycloak-owner-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    "sync.py" = <<-PY
      #!/usr/bin/env python3
      import hashlib
      import hmac
      import json
      import logging
      import os
      import threading
      import time
      import urllib.parse
      import urllib.request
      from http.server import BaseHTTPRequestHandler, HTTPServer

      logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
      log = logging.getLogger("coder-keycloak-owner-sync")

      REALM = os.environ["KEYCLOAK_REALM"]
      KC_BASE = os.environ["KEYCLOAK_ADMIN_BASE_URL"].rstrip("/")
      KC_USER = os.environ["KEYCLOAK_ADMIN_USERNAME"]
      KC_PASS = os.environ["KEYCLOAK_ADMIN_PASSWORD"]
      ADMIN_GROUP = os.environ.get("KEYCLOAK_ADMIN_GROUP", "admins")
      PROTECTED = {
          u.strip()
          for u in os.environ.get("PROTECTED_USERNAMES", "coder-bootstrap,prebuilds").split(",")
          if u.strip()
      }
      PG = dict(
          host=os.environ["CODER_PG_HOST"],
          db=os.environ["CODER_PG_DB"],
          user=os.environ["CODER_PG_USER"],
          password=os.environ["CODER_PG_PASSWORD"],
      )
      WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
      RECONCILE_EVERY = int(os.environ.get("RECONCILE_INTERVAL_SECONDS", "300"))

      try:
          import psycopg2
      except ImportError as exc:
          raise SystemExit(f"psycopg2 required: {exc}") from exc

      _token = {"value": None, "exp": 0}

      def kc_token():
          now = time.time()
          if _token["value"] and _token["exp"] > now + 30:
              return _token["value"]
          data = urllib.parse.urlencode({
              "client_id": "admin-cli",
              "username": KC_USER,
              "password": KC_PASS,
              "grant_type": "password",
          }).encode()
          req = urllib.request.Request(
              f"{KC_BASE}/realms/master/protocol/openid-connect/token",
              data=data,
              method="POST",
          )
          with urllib.request.urlopen(req, timeout=30) as resp:
              body = json.load(resp)
          _token["value"] = body["access_token"]
          _token["exp"] = now + int(body.get("expires_in", 60))
          return _token["value"]

      def kc_get(path):
          req = urllib.request.Request(
              f"{KC_BASE}/admin{path}",
              headers={"Authorization": f"Bearer {kc_token()}"},
          )
          with urllib.request.urlopen(req, timeout=60) as resp:
              raw = resp.read().decode()
              return json.loads(raw) if raw else {}

      def kc_find_group(group_name):
          groups = kc_get(
              f"/realms/{REALM}/groups?search={urllib.parse.quote(group_name)}&exact=true&max=50"
          )

          def walk(nodes):
              for g in nodes or []:
                  if g.get("name") == group_name:
                      return g
                  found = walk(g.get("subGroups") or [])
                  if found:
                      return found
              return None

          match = walk(groups)
          if match:
              return match
          tops = kc_get(f"/realms/{REALM}/groups?max=200")
          for top in tops:
              children = kc_get(f"/realms/{REALM}/groups/{top['id']}/children?max=200")
              for g in children:
                  if g.get("name") == group_name:
                      return g
          return None

      def kc_admin_idents():
          """Live Keycloak admins: usernames + emails (for matching Coder OIDC users)."""
          match = kc_find_group(ADMIN_GROUP)
          if not match:
              log.warning("keycloak group missing: %s", ADMIN_GROUP)
              return set()
          members = kc_get(f"/realms/{REALM}/groups/{match['id']}/members?max=500")
          idents = set()
          for m in members:
              if m.get("username"):
                  idents.add(m["username"])
              if m.get("email"):
                  idents.add(m["email"])
          return idents

      def pg_conn():
          return psycopg2.connect(
              host=PG["host"],
              dbname=PG["db"],
              user=PG["user"],
              password=PG["password"],
          )

      def reconcile():
          desired = kc_admin_idents()
          log.info("keycloak %s members: %d idents", ADMIN_GROUP, len(desired))
          with pg_conn() as conn:
              conn.autocommit = False
              with conn.cursor() as cur:
                  cur.execute(
                      """
                      SELECT id, username, email, login_type, rbac_roles
                      FROM users
                      WHERE deleted = false
                        AND is_system = false
                        AND username <> ALL(%s)
                      """,
                      (list(PROTECTED),),
                  )
                  users = cur.fetchall()
                  promoted = demoted = 0
                  for uid, username, email, login_type, roles in users:
                      roles = list(roles or [])
                      is_desired = username in desired or (email and email in desired)
                      is_owner = "owner" in roles
                      if is_desired and not is_owner:
                          cur.execute(
                              "UPDATE users SET rbac_roles = ARRAY['owner']::text[] WHERE id = %s",
                              (uid,),
                          )
                          cur.execute(
                              """
                              UPDATE organization_members
                              SET roles = ARRAY['organization-admin']::text[]
                              WHERE user_id = %s
                              """,
                              (uid,),
                          )
                          promoted += 1
                          log.info("promote %s (%s) -> owner", username, login_type)
                      elif (not is_desired) and is_owner and login_type == "oidc":
                          cur.execute(
                              "UPDATE users SET rbac_roles = '{}'::text[] WHERE id = %s",
                              (uid,),
                          )
                          cur.execute(
                              """
                              UPDATE organization_members
                              SET roles = '{}'::text[]
                              WHERE user_id = %s
                              """,
                              (uid,),
                          )
                          demoted += 1
                          log.info("demote %s -> member (left keycloak %s)", username, ADMIN_GROUP)
              conn.commit()
          log.info("reconcile done promoted=%d demoted=%d", promoted, demoted)

      class Handler(BaseHTTPRequestHandler):
          def log_message(self, fmt, *args):
              log.info("http " + fmt, *args)

          def do_POST(self):
              if self.path != "/webhook":
                  self.send_response(404)
                  self.end_headers()
                  return
              length = int(self.headers.get("Content-Length", "0"))
              body = self.rfile.read(length)
              if WEBHOOK_SECRET:
                  sig = self.headers.get("X-Keycloak-Signature") or self.headers.get("X-Webhook-Signature")
                  if not sig:
                      self.send_response(401)
                      self.end_headers()
                      return
                  digest = hmac.new(WEBHOOK_SECRET.encode(), body, hashlib.sha256).hexdigest()
                  if not hmac.compare_digest(digest, sig.replace("sha256=", "")):
                      self.send_response(401)
                      self.end_headers()
                      return
              try:
                  reconcile()
                  self.send_response(202)
                  self.end_headers()
                  self.wfile.write(b"ok")
              except Exception as exc:
                  log.exception("webhook reconcile failed: %s", exc)
                  self.send_response(500)
                  self.end_headers()

          def do_GET(self):
              if self.path == "/healthz":
                  self.send_response(200)
                  self.end_headers()
                  self.wfile.write(b"ok")
                  return
              self.send_response(404)
              self.end_headers()

      def periodic():
          while True:
              time.sleep(max(RECONCILE_EVERY, 60))
              try:
                  reconcile()
              except Exception:
                  log.exception("periodic reconcile failed")

      if __name__ == "__main__":
          try:
              reconcile()
          except Exception:
              log.exception("initial reconcile failed")
          if RECONCILE_EVERY > 0:
              threading.Thread(target=periodic, daemon=True).start()
          HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
  }
}

resource "kubernetes_secret_v1" "keycloak_owner_sync" {
  count = var.keycloak_owner_sync != null ? 1 : 0

  metadata {
    name      = "coder-keycloak-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      app         = "coder-keycloak-owner-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    KEYCLOAK_REALM          = var.keycloak_owner_sync.realm
    KEYCLOAK_ADMIN_BASE_URL = var.keycloak_owner_sync.admin_base_url
    KEYCLOAK_ADMIN_USERNAME = var.keycloak_owner_sync.admin_username
    KEYCLOAK_ADMIN_PASSWORD = var.keycloak_owner_sync.admin_password
    KEYCLOAK_ADMIN_GROUP    = var.keycloak_owner_sync.admin_group
    CODER_PG_HOST           = local.postgresql_host
    CODER_PG_DB             = var.postgresql_database
    CODER_PG_USER           = var.postgresql_username
    CODER_PG_PASSWORD       = local.postgresql_password
    PROTECTED_USERNAMES = join(",", compact([
      try(var.bootstrap_owner.username, ""),
      "prebuilds",
    ]))
    WEBHOOK_SECRET             = random_password.keycloak_owner_sync_webhook[0].result
    RECONCILE_INTERVAL_SECONDS = tostring(var.keycloak_owner_sync.reconcile_interval_seconds)
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "keycloak_owner_sync" {
  count = var.keycloak_owner_sync != null ? 1 : 0

  metadata {
    name      = "coder-keycloak-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      app         = "coder-keycloak-owner-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "coder-keycloak-owner-sync"
      }
    }

    template {
      metadata {
        labels = {
          app = "coder-keycloak-owner-sync"
        }
      }

      spec {
        container {
          name  = "sync"
          image = var.keycloak_owner_sync.image
          command = [
            "/bin/sh",
            "-c",
            "pip install --target=/tmp/deps -q psycopg2-binary && PYTHONPATH=/tmp/deps exec python3 /app/sync.py",
          ]

          port {
            name           = "http"
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.keycloak_owner_sync[0].metadata[0].name
            }
          }

          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65534
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "app"
          config_map {
            name         = kubernetes_config_map_v1.keycloak_owner_sync[0].metadata[0].name
            default_mode = "0555"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }

        security_context {
          run_as_non_root = true
          fs_group        = 65534
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
      }
    }
  }

  depends_on = [
    module.coder_postgresql,
    helm_release.coder,
  ]
}

resource "kubernetes_service_v1" "keycloak_owner_sync" {
  count = var.keycloak_owner_sync != null ? 1 : 0

  metadata {
    name      = "coder-keycloak-owner-sync"
    namespace = kubernetes_namespace.coder.metadata[0].name
    labels = {
      app         = "coder-keycloak-owner-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    selector = {
      app = "coder-keycloak-owner-sync"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
