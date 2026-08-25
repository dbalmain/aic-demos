# Gate B's resource space: what the shop API exposes, and the actions over it.
#
# The patterns are matched as URLs and the wildcard rules are not what the
# vendor docs describe — `*` crosses `/`, `-*-` does not, a query string is part
# of the resource, and matching is case-insensitive. A resource that matches
# nothing comes back as `{}`, the same answer as a deny, so a mistake here reads
# like an authorization bug. Measured 2026-08-25; the table is in
# pingone-aic-manager docs/api/21-am-policies.md.
resource "pingoneaic_resource_type" "shop_api" {
  realm       = var.realm
  name        = "CapTokenDemo Shop API"
  description = "Capability-token demo: the shop API surface"
  patterns = [
    "https://*:*/orders",
    "https://*:*/orders/*",
    "https://*:*/payments",
    "https://*:*/payments/*",
  ]
  actions = {
    read    = true
    approve = false
    refund  = false
  }
}

# Gate B — what a presented capability token may do.
resource "pingoneaic_policy_set" "shop" {
  realm             = var.realm
  name              = "CapTokenDemo"
  display_name      = "Capability Tokens Demo"
  description       = "Gate B: what a presented capability token may do."
  resource_type_ids = [pingoneaic_resource_type.shop_api.id]
  subjects          = ["JwtClaim", "AuthenticatedUsers", "Identity", "AND", "OR", "NOT", "NONE"]
  conditions        = ["OAuth2Scope", "AND", "OR", "NOT", "Script", "SimpleTime"]
}

# Gate A — which capabilities a user may be given at token-exchange time.
# Reached by the validate-scope script calling policy.evaluate, not by
# usePolicyEngineForScope, which engages on the exchange but is handed an
# unauthenticated subject and so cannot express a per-user rule.
resource "pingoneaic_policy_set" "scopes" {
  realm             = var.realm
  name              = "CapTokenDemoScopes"
  display_name      = "Capability Tokens Demo — grantable capabilities"
  description       = "Gate A: which capabilities a user may be given at token-exchange time."
  resource_type_ids = [local.oauth2_scope_resource_type]
  subjects          = ["JwtClaim", "AuthenticatedUsers", "Identity", "AND", "OR", "NOT", "NONE"]
  conditions        = ["OAuth2Scope", "AND", "OR", "NOT", "Script", "SimpleTime"]
}

# Gate A, one policy per capability: may this user hold it at all?
resource "pingoneaic_policy" "scope" {
  for_each = local.capabilities

  realm            = var.realm
  name             = "CapTokenDemoScope_${each.key}"
  description      = "Grant the ${each.key} capability to holders of the ${each.value.role} role."
  policy_set       = pingoneaic_policy_set.scopes.remote_name
  resource_type_id = local.oauth2_scope_resource_type
  resources        = [each.key]
  action_values    = { GRANT = true }

  subject {
    type        = "JwtClaim"
    claim_name  = "demoRoles"
    claim_value = each.value.role
  }
}

# Gate B, one policy per capability: the role AND the capability, both read out
# of the presented token.
#
# Requiring the role again is not redundant. A capability token outlives the
# role being revoked — it is minted for 60 seconds against a claim that was true
# when it was issued — and this is the gate that catches that.
#
# Note what is *not* here: no environment is passed at evaluation time, so the
# resource server cannot assert a scope the token never carried. JwtClaim
# matches inside an array claim, including the standard `scope`, which is the
# whole trick.
resource "pingoneaic_policy" "shop" {
  for_each = local.capabilities

  realm            = var.realm
  name             = "CapTokenDemo_${each.value.label}"
  description      = "${each.value.action} needs the ${each.value.role} role and the ${each.key} capability."
  policy_set       = pingoneaic_policy_set.shop.remote_name
  resource_type_id = pingoneaic_resource_type.shop_api.id
  resources        = [each.value.resource]
  action_values    = { (each.value.action) = true }

  subject {
    type = "AND"

    subject {
      type        = "JwtClaim"
      claim_name  = "demoRoles"
      claim_value = each.value.role
    }

    subject {
      type        = "JwtClaim"
      claim_name  = "scope"
      claim_value = each.key
    }
  }
}
