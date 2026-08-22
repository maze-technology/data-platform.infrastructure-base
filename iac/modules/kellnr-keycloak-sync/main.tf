terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

locals {
  sync_groups_json = jsonencode(var.sync_group_names)
}

resource "kubernetes_config_map" "sync_app" {
  metadata {
    name      = "kellnr-keycloak-sync"
    namespace = var.namespace
    labels = {
      app         = "kellnr-keycloak-sync"
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
      log = logging.getLogger("kellnr-keycloak-sync")

      REALM = os.environ["KEYCLOAK_REALM"]
      KC_BASE = os.environ["KEYCLOAK_ADMIN_BASE_URL"].rstrip("/")
      KC_USER = os.environ["KEYCLOAK_ADMIN_USERNAME"]
      KC_PASS = os.environ["KEYCLOAK_ADMIN_PASSWORD"]
      PG = dict(
          host=os.environ["KELLNR_PG_HOST"],
          db=os.environ["KELLNR_PG_DB"],
          user=os.environ["KELLNR_PG_USER"],
          password=os.environ["KELLNR_PG_PASSWORD"],
      )
      GROUPS = json.loads(os.environ.get("SYNC_GROUP_NAMES", "[]"))
      WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
      RECONCILE_EVERY = int(os.environ.get("RECONCILE_INTERVAL_SECONDS", "300"))

      try:
          import psycopg2
          import psycopg2.extras
      except ImportError as exc:
          raise SystemExit(f"psycopg2 required (install into PYTHONPATH): {exc}") from exc

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

      def kc_group_members(group_name):
          groups = kc_get(f"/realms/{REALM}/groups?search={urllib.parse.quote(group_name)}&max=20")
          match = next((g for g in groups if g.get("name") == group_name), None)
          if not match:
              log.warning("keycloak group missing: %s", group_name)
              return []
          members = kc_get(f"/realms/{REALM}/groups/{match['id']}/members?max=500")
          return [m.get("username") for m in members if m.get("username")]

      def pg_conn():
          return psycopg2.connect(
              host=PG["host"],
              dbname=PG["db"],
              user=PG["user"],
              password=PG["password"],
          )

      def ensure_kellnr_group(cur, name):
          cur.execute('INSERT INTO "group" (name) VALUES (%s) ON CONFLICT DO NOTHING', (name,))
          cur.execute('SELECT id FROM "group" WHERE name = %s', (name,))
          row = cur.fetchone()
          return row[0] if row else None

      def ensure_kellnr_user(cur, username):
          cur.execute('SELECT id FROM "user" WHERE name = %s', (username,))
          row = cur.fetchone()
          return row[0] if row else None

      def reconcile_group(cur, group_name):
          gid = ensure_kellnr_group(cur, group_name)
          if not gid:
              return
          desired = set(kc_group_members(group_name))
          cur.execute(
              'SELECT u.name FROM group_user gu JOIN "user" u ON u.id = gu.user_fk WHERE gu.group_fk = %s',
              (gid,),
          )
          current = {r[0] for r in cur.fetchall()}
          for username in desired - current:
              uid = ensure_kellnr_user(cur, username)
              if uid is None:
                  log.info("skip %s (not provisioned in Kellnr yet)", username)
                  continue
              cur.execute(
                  "INSERT INTO group_user (group_fk, user_fk) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                  (gid, uid),
              )
              log.info("added %s -> %s", username, group_name)
          for username in current - desired:
              cur.execute(
                  'DELETE FROM group_user gu USING "user" u WHERE gu.user_fk = u.id AND gu.group_fk = %s AND u.name = %s',
                  (gid, username),
              )
              log.info("removed %s -> %s", username, group_name)

      def reconcile_all():
          if not GROUPS:
              log.info("no sync groups configured")
              return
          with pg_conn() as conn:
              conn.autocommit = False
              with conn.cursor() as cur:
                  for name in GROUPS:
                      reconcile_group(cur, name)
              conn.commit()
          log.info("reconcile complete for %d groups", len(GROUPS))

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
                  reconcile_all()
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
                  reconcile_all()
              except Exception:
                  log.exception("periodic reconcile failed")

      if __name__ == "__main__":
          if RECONCILE_EVERY > 0:
              threading.Thread(target=periodic, daemon=True).start()
          try:
              reconcile_all()
          except Exception:
              log.exception("startup reconcile failed")
          HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
    PY
  }
}

resource "kubernetes_secret" "sync_env" {
  metadata {
    name      = "kellnr-keycloak-sync"
    namespace = var.namespace
    labels = {
      app         = "kellnr-keycloak-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  data = {
    KEYCLOAK_REALM             = var.keycloak_realm
    KEYCLOAK_ADMIN_BASE_URL    = var.keycloak_admin_base_url
    KEYCLOAK_ADMIN_USERNAME    = var.keycloak_admin_username
    KEYCLOAK_ADMIN_PASSWORD    = var.keycloak_admin_password
    KELLNR_PG_HOST             = var.kellnr_postgresql_host
    KELLNR_PG_DB               = var.kellnr_postgresql_database
    KELLNR_PG_USER             = var.kellnr_postgresql_username
    KELLNR_PG_PASSWORD         = var.kellnr_postgresql_password
    SYNC_GROUP_NAMES           = local.sync_groups_json
    WEBHOOK_SECRET             = var.webhook_secret
    RECONCILE_INTERVAL_SECONDS = tostring(var.reconcile_interval_seconds)
  }

  type = "Opaque"
}

resource "kubernetes_deployment" "sync" {
  metadata {
    name      = "kellnr-keycloak-sync"
    namespace = var.namespace
    labels = {
      app         = "kellnr-keycloak-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "kellnr-keycloak-sync"
      }
    }

    template {
      metadata {
        labels = {
          app = "kellnr-keycloak-sync"
        }
      }

      spec {
        container {
          name  = "sync"
          image = var.image
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
              name = kubernetes_secret.sync_env.metadata[0].name
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
            name         = kubernetes_config_map.sync_app.metadata[0].name
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
}

resource "kubernetes_service" "sync" {
  metadata {
    name      = "kellnr-keycloak-sync"
    namespace = var.namespace
    labels = {
      app         = "kellnr-keycloak-sync"
      environment = var.environment
      managed-by  = "opentofu"
    }
  }

  spec {
    selector = {
      app = "kellnr-keycloak-sync"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
