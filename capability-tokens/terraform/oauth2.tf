# One OAuth2 client per layer boundary, which is also how the capability token
# gets to be short-lived: it inherits the *acting* client's lifetime, and there
# is no per-exchange TTL to set.

# The user's sign-in client. Allowed openid/profile and nothing else, so it can
# never issue a capability — which is why it carries no scope gate.
resource "pingoneaic_oauth2_client" "login" {
  realm = var.realm
  name  = var.login_client_id

  core = {
    client_type           = "Confidential"
    userpassword          = var.login_client_secret
    redirection_uris      = ["http://localhost:${var.web_port}/callback"]
    scopes                = ["openid", "profile"]
    default_scopes        = ["openid"]
    access_token_lifetime = 900
  }

  advanced = {
    # The password grant, because a scriptable demo beats a browser redirect.
    # A real BFF uses authorization_code and nothing else in the pattern moves.
    grant_types                = ["password", "authorization_code", "refresh_token"]
    token_endpoint_auth_method = "client_secret_basic"
    is_consent_implied         = true
  }

  override = {
    # Turning provider_overrides_enabled on applies *every* default in this
    # block, which silently switched the client from stateless JWTs to opaque
    # tokens the first time we did it. Hence the explicit true below.
    provider_overrides_enabled            = true
    stateless_tokens_enabled              = true
    access_token_may_act_script           = pingoneaic_script.may_act.id
    access_token_modification_plugin_type = "SCRIPTED"
    access_token_modification_script      = pingoneaic_script.token_modification.id
  }
}

# The BFF's outbound identity. Token-exchange only, no refresh token, 60s.
#
# The scope gate is attached HERE and nowhere else. AM consults the acting
# client's config on an exchange and ignores the login client's, so a gate on
# the login client alone leaves the exchange completely ungated — and the
# failure is silent: it mints the capability and hands it over.
resource "pingoneaic_oauth2_client" "caller" {
  realm = var.realm
  name  = var.caller_client_id

  core = {
    client_type           = "Confidential"
    userpassword          = var.caller_client_secret
    scopes                = ["orders.read", "orders.approve", "payments.refund"]
    default_scopes        = []
    access_token_lifetime = 60
  }

  advanced = {
    grant_types                = ["urn:ietf:params:oauth:grant-type:token-exchange"]
    token_endpoint_auth_method = "client_secret_basic"
  }

  override = {
    provider_overrides_enabled            = true
    stateless_tokens_enabled              = true
    validate_scope_plugin_type            = "SCRIPTED"
    validate_scope_script                 = pingoneaic_script.validate_scope.id
    access_token_modification_plugin_type = "SCRIPTED"
    access_token_modification_script      = pingoneaic_script.token_modification.id
  }
}
