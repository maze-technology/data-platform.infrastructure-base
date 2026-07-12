realm: ${realm}
enabled: true
displayName: Maze Platform
registrationAllowed: false
resetPasswordAllowed: true
loginWithEmailAllowed: true
duplicateEmailsAllowed: false

groups:
  - name: vpn-users
    attributes:
      description: ["Users allowed to connect via WireGuard VPN"]
  - name: developers
    attributes:
      description: ["Standard developer access — GitLab, Grafana, Argo CD"]
  - name: admins
    attributes:
      description: ["Platform administrators"]

roles:
  realm:
    - name: platform-admin
      description: Platform administrator role

clients:
  - clientId: gitlab
    name: GitLab
    enabled: true
    clientAuthenticatorType: client-secret
    secret: ${gitlab_client_secret}
    redirectUris:
      - "${gitlab_redirect_uri}"
    webOrigins:
      - "+"
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    publicClient: false
    protocol: openid-connect
    fullScopeAllowed: true
    defaultClientScopes:
      - basic
      - email
      - profile
      - roles
    protocolMappers:
      - name: groups
        protocol: openid-connect
        protocolMapper: oidc-group-membership-mapper
        config:
          claim.name: groups
          full.path: "false"
          id.token.claim: "true"
          access.token.claim: "true"
          userinfo.token.claim: "true"

  - clientId: argocd
    name: Argo CD
    enabled: true
    clientAuthenticatorType: client-secret
    secret: ${argocd_client_secret}
    redirectUris:
      - "${argocd_redirect_uri}"
    webOrigins:
      - "+"
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    publicClient: false
    protocol: openid-connect
    fullScopeAllowed: true
    defaultClientScopes:
      - basic
      - email
      - profile
      - roles
    protocolMappers:
      - name: groups
        protocol: openid-connect
        protocolMapper: oidc-group-membership-mapper
        config:
          claim.name: groups
          full.path: "false"
          id.token.claim: "true"
          access.token.claim: "true"
          userinfo.token.claim: "true"

  - clientId: grafana
    name: Grafana
    enabled: true
    clientAuthenticatorType: client-secret
    secret: ${grafana_client_secret}
    redirectUris:
      - "${grafana_redirect_uri}"
    webOrigins:
      - "+"
    standardFlowEnabled: true
    directAccessGrantsEnabled: false
    publicClient: false
    protocol: openid-connect
    fullScopeAllowed: true
    defaultClientScopes:
      - basic
      - email
      - profile
      - roles

users:
${realm_users_yaml}
