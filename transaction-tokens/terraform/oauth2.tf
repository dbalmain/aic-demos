# Three clients, one per identity boundary — the Txn-Token inherits the
# ACTING client's lifetime, and there is no per-exchange TTL to set.

# The account manager's real sign-in. AIC is the IdP for real here.
resource "pingoneaic_oauth2_client" "web" {
  realm = var.realm
  name  = var.web_client_id

  core = {
    client_type           = "Confidential"
    userpassword          = var.web_client_secret
    redirection_uris      = ["http://localhost:${var.web_port}/callback"]
    scopes                = ["openid", "profile", local.subject_scopes.human]
    default_scopes        = ["openid"]
    access_token_lifetime = 900
  }

  advanced = {
    grant_types                = ["password", "authorization_code", "refresh_token"]
    token_endpoint_auth_method = "client_secret_basic"
    is_consent_implied         = true
  }

  override = {
    provider_overrides_enabled = true
    # Stateless (a real JWT), not opaque, despite the general preference —
    # this token becomes a subject_token the exchange scripts parse directly
    # as {jwt: subjectToken} (policy.evaluate, docs/api/21). An opaque token
    # has nothing for that call to parse. The browser-facing session cookie
    # is where "opaque where we can" actually applies here — see README.
    stateless_tokens_enabled    = true
    access_token_may_act_script = pingoneaic_script.may_act_web.id
  }
}

# The nightly job's own identity. It authenticates itself via jwt-bearer (its
# own key, verified against a Trusted JWT Issuer) — there is no user, so this
# is the closest AIC-native analogue of the draft's "self-signed subject_token,
# no user" flow (departure #9, ARCHITECTURE.md). The grant type is plain config
# and lives here; the Trusted JWT Issuer itself (a signing keypair) is set up
# by scripts/setup-jwtbearer.sh, not Terraform — the provider has no
# TrustedJwtIssuer resource yet, and a signing keypair is closer to a runtime
# credential than declarative config.
resource "pingoneaic_oauth2_client" "jobsvc" {
  realm = var.realm
  name  = var.jobsvc_client_id

  core = {
    client_type           = "Confidential"
    userpassword          = var.jobsvc_client_secret
    scopes                = [local.subject_scopes.service]
    default_scopes        = [local.subject_scopes.service]
    access_token_lifetime = 300
  }

  advanced = {
    grant_types                = ["urn:ietf:params:oauth:grant-type:jwt-bearer"]
    token_endpoint_auth_method = "client_secret_basic"
  }

  override = {
    provider_overrides_enabled  = true
    stateless_tokens_enabled    = true # same reason as web: parsed as {jwt: ...} by the scripts
    access_token_may_act_script = pingoneaic_script.may_act_jobsvc.id
  }
}

# The one internal exchange identity. Every trust-domain service authenticates
# as this client to turn a subject token into a Txn-Token — the subject token
# itself carries which workload originated the request, not the caller
# client, so a single shared exchange identity is correct here rather than
# one per service (see terraform/README notes in ARCHITECTURE.md).
resource "pingoneaic_oauth2_client" "caller" {
  realm = var.realm
  name  = var.caller_client_id

  core = {
    client_type           = "Confidential"
    userpassword          = var.caller_client_secret
    scopes                = ["client:activity:write", "client:activity:read"]
    default_scopes        = []
    access_token_lifetime = 60
  }

  advanced = {
    grant_types                = ["urn:ietf:params:oauth:grant-type:token-exchange"]
    token_endpoint_auth_method = "client_secret_basic"
  }

  override = {
    provider_overrides_enabled            = true
    stateless_tokens_enabled              = true # the Txn-Token itself: must be self-contained for every hop to validate it independently
    validate_scope_plugin_type            = "SCRIPTED"
    validate_scope_script                 = pingoneaic_script.validate_scope.id
    access_token_modification_plugin_type = "SCRIPTED"
    access_token_modification_script      = pingoneaic_script.token_modification.id
  }
}
