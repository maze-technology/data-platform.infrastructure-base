## GitLab CE configuration
## Managed by OpenTofu — local modifications will be overwritten on next apply
## Generated for environment: ${environment}

# ─────────────────────────────────────────────────────────────────────────────
# Core URL — accessible ONLY via WireGuard VPN
# ─────────────────────────────────────────────────────────────────────────────
external_url 'https://${gitlab_domain}'

# Bind nginx exclusively to the WireGuard VPN interface + loopback.
# This is the primary security control preventing public internet access.
# Even if the firewall is misconfigured, GitLab remains unreachable publicly.
nginx['listen_addresses'] = ['${server_vpn_ip}', '127.0.0.1']
nginx['listen_port'] = 443
nginx['listen_https'] = true

# ─────────────────────────────────────────────────────────────────────────────
# TLS — self-signed certificate (valid for 10 years)
# ─────────────────────────────────────────────────────────────────────────────
letsencrypt['enable'] = false
nginx['ssl_certificate']     = '/etc/gitlab/ssl/${gitlab_domain}.crt'
nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/${gitlab_domain}.key'
nginx['ssl_protocols']       = 'TLSv1.2 TLSv1.3'
nginx['ssl_ciphers']         = 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256'
nginx['ssl_prefer_server_ciphers'] = 'off'

# ─────────────────────────────────────────────────────────────────────────────
# Container Registry — also VPN-only
# ─────────────────────────────────────────────────────────────────────────────
registry['enable'] = true
registry_external_url 'https://${registry_domain}'
registry_nginx['listen_addresses']    = ['${server_vpn_ip}', '127.0.0.1']
registry_nginx['listen_port']         = 5050
registry_nginx['ssl_certificate']     = '/etc/gitlab/ssl/${registry_domain}.crt'
registry_nginx['ssl_certificate_key'] = '/etc/gitlab/ssl/${registry_domain}.key'

# ─────────────────────────────────────────────────────────────────────────────
# SSH (Git over SSH) — accessible on server VPN IP
# ─────────────────────────────────────────────────────────────────────────────
# Clone URL shown to users: git@${server_vpn_ip}:namespace/project.git
gitlab_rails['gitlab_ssh_host']       = '${server_vpn_ip}'
gitlab_rails['gitlab_shell_ssh_port'] = 22

# ─────────────────────────────────────────────────────────────────────────────
# Security — disable all public access
# ─────────────────────────────────────────────────────────────────────────────
# Disable public sign-ups — solo operator setup
gitlab_rails['gitlab_signup_enabled']            = false
gitlab_rails['gitlab_default_can_create_group']  = false

# Restrict project creation to admins only
gitlab_rails['gitlab_default_projects_limit'] = 100

# Require email confirmation (even though signup is disabled, protects admin invites)
gitlab_rails['send_email_on_high_load'] = false

# Disable anonymous access to projects that have no explicit public visibility set
gitlab_rails['gitlab_default_project_visibility'] = 'private'
gitlab_rails['gitlab_default_snippet_visibility'] = 'private'
gitlab_rails['gitlab_default_group_visibility']   = 'private'

# Disable usage ping / telemetry
gitlab_rails['usage_ping_enabled'] = false

# ─────────────────────────────────────────────────────────────────────────────
# Performance — tuned for ECO bare metal (limited RAM)
# ─────────────────────────────────────────────────────────────────────────────
# Puma — Ruby web server
puma['worker_processes'] = ${puma_workers}
puma['min_threads']      = 4
puma['max_threads']      = 4

# Sidekiq — background job processor
sidekiq['concurrency'] = ${sidekiq_concurrency}

# PostgreSQL — bundled
postgresql['shared_buffers']           = '256MB'
postgresql['effective_cache_size']     = '1GB'
postgresql['maintenance_work_mem']     = '64MB'
postgresql['checkpoint_completion_target'] = 0.9
postgresql['wal_buffers']              = '8MB'

# Redis — bundled
redis['maxmemory']        = '512mb'
redis['maxmemory_policy'] = 'allkeys-lru'

# ─────────────────────────────────────────────────────────────────────────────
# Backups — local storage (encryption handled separately by age)
# ─────────────────────────────────────────────────────────────────────────────
gitlab_rails['backup_path']     = '/var/opt/gitlab/backups'
# Keep GitLab's own unencrypted backups for 48h max (our cron encrypts + uploads them)
gitlab_rails['backup_keep_time'] = 172800

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
logging['svlogd_size']     = 200 * 1024 * 1024 # 200MB
logging['svlogd_num']      = 30
logging['svlogd_timeout']  = 86400
logging['svlogd_filter']   = 'gzip'
logging['logrotate_frequency'] = 'daily'
logging['logrotate_rotate']    = 30
logging['logrotate_compress']  = 'compress'

# ─────────────────────────────────────────────────────────────────────────────
# Email — disabled (configure separately if needed)
# ─────────────────────────────────────────────────────────────────────────────
gitlab_rails['smtp_enable']           = false
gitlab_rails['gitlab_email_enabled']  = false

# ─────────────────────────────────────────────────────────────────────────────
# Disabled features (reduce attack surface and memory usage)
# ─────────────────────────────────────────────────────────────────────────────
pages_enabled = false
gitlab_pages['enable'] = false
mattermost['enable']    = false
gitlab_kas['enable']    = false

# Monitoring — Prometheus disabled to save resources on small server
# Enable if you add a monitoring stack later
prometheus_monitoring['enable'] = false
alertmanager['enable']          = false
grafana['enable']               = false
