realm: ${realm}
enabled: true
displayName: Maze Platform
registrationAllowed: false
resetPasswordAllowed: true
loginWithEmailAllowed: true
duplicateEmailsAllowed: false
# Allow Admin API / config-cli username changes (e.g. bootstrap_admin rename).
editUsernameAllowed: true

# Password + MFA hardening
passwordPolicy: "length(12) and digits(1) and upperCase(1) and lowerCase(1) and specialChars(1) and notUsername"
otpPolicyType: totp
otpPolicyAlgorithm: HmacSHA256
otpPolicyDigits: 6
otpPolicyInitialCounter: 0
otpPolicyLookAheadWindow: 1
otpPolicyPeriod: 30

# Temporary lockout after failed password/OTP (not permanent — avoids easy DoS lockouts)
bruteForceProtected: true
permanentLockout: false
failureFactor: 5
waitIncrementSeconds: 60
maxFailureWaitSeconds: 900
maxDeltaTimeSeconds: 43200
quickLoginCheckMilliSeconds: 1000
minimumQuickLoginWaitSeconds: 60

# Admin events retained for audit; group sync is CronJob-based (no Keycloak webhook —
# p2-inc/keycloak-events supports only one WEBHOOK_URI).
eventsEnabled: true
eventsListeners:
  - jboss-logging
%{ if event_webhook_enabled ~}
  - ext-event-webhook
%{ endif ~}
adminEventsEnabled: true
adminEventsDetailsEnabled: true

# Force TOTP enrollment on first login; browser flow requires OTP every login
browserFlow: browser with otp
requiredActions:
  - alias: CONFIGURE_TOTP
    name: Configure OTP
    providerId: CONFIGURE_TOTP
    enabled: true
    defaultAction: true
    priority: 10

authenticationFlows:
  - alias: browser with otp
    description: Browser based authentication with mandatory TOTP
    providerId: basic-flow
    topLevel: true
    builtIn: false
    authenticationExecutions:
      - authenticator: auth-cookie
        requirement: ALTERNATIVE
        priority: 10
        authenticatorFlow: false
        userSetupAllowed: false
      - authenticator: identity-provider-redirector
        requirement: ALTERNATIVE
        priority: 20
        authenticatorFlow: false
        userSetupAllowed: false
      - requirement: ALTERNATIVE
        priority: 30
        flowAlias: browser with otp forms
        authenticatorFlow: true
        userSetupAllowed: false
  - alias: browser with otp forms
    description: Username/password then mandatory OTP
    providerId: basic-flow
    topLevel: false
    builtIn: false
    authenticationExecutions:
      - authenticator: auth-username-password-form
        requirement: REQUIRED
        priority: 10
        authenticatorFlow: false
        userSetupAllowed: false
      - authenticator: auth-otp-form
        requirement: REQUIRED
        priority: 20
        authenticatorFlow: false
        userSetupAllowed: false

groups:
  - name: vpn-users
    attributes:
      description: ["Users allowed to connect via WireGuard VPN"]
  - name: engineers
    attributes:
      description: ["Standard engineer access — GitLab, Grafana, Argo CD"]
  - name: admins
    attributes:
      description: ["Platform administrators"]

roles:
  realm:
    - name: platform-admin
      description: Platform administrator role

clientScopes:
  - name: groups
    description: Group membership claim for Maze platform RBAC
    protocol: openid-connect
    attributes:
      include.in.token.scope: "true"
      display.on.consent.screen: "false"
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
      - groups
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
      - groups
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
      - groups
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

  - clientId: kellnr
    name: Kellnr
    enabled: true
    clientAuthenticatorType: client-secret
    secret: ${kellnr_client_secret}
    redirectUris:
      - "${kellnr_redirect_uri}"
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
      - groups
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

  - clientId: coder
    name: Coder
    enabled: true
    clientAuthenticatorType: client-secret
    secret: ${coder_client_secret}
    redirectUris:
      - "${coder_redirect_uri}"
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
      - groups
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

users:
${realm_users_yaml}
