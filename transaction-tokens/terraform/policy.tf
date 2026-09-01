# Gate A — which internal exchange scopes a subject token's own scope earns
# it. Reached by validate-scope.js calling policy.evaluate, not by
# usePolicyEngineForScope, which is handed an unauthenticated subject and so
# cannot key on the subject token at all (same limitation capability-tokens
# found, docs/api/22-token-exchange.md).
resource "pingoneaic_policy_set" "scopes" {
  realm             = var.realm
  name              = "TxnDemoScopes"
  display_name      = "Transaction Tokens Demo — grantable internal scopes"
  description       = "Gate A: which internal exchange scopes a subject token's own scope earns."
  resource_type_ids = [local.oauth2_scope_resource_type]
  subjects          = ["JwtClaim", "AuthenticatedUsers", "Identity", "AND", "OR", "NOT", "NONE"]
  conditions        = ["OAuth2Scope", "AND", "OR", "NOT", "Script", "SimpleTime"]
}

# Both the real account manager and the nightly job's own service identity
# are trusted to write an activity at all — the distinction that matters
# (may this one assert a cost?) is Gate B's job, not this one's.
resource "pingoneaic_policy" "scope_write" {
  for_each = local.subject_scopes

  realm            = var.realm
  name             = "TxnDemoScope_${each.key}"
  description      = "Grant client:activity:write to a subject token scoped ${each.value}."
  policy_set       = pingoneaic_policy_set.scopes.remote_name
  resource_type_id = local.oauth2_scope_resource_type
  resources        = ["client:activity:write"]
  action_values    = { GRANT = true }

  subject {
    type        = "JwtClaim"
    claim_name  = "scope"
    claim_value = each.value
  }
}

# Gate B's resource space: what may be asserted in tctx, as fields rather than
# URLs. cost_cents is the one field that ever gets refused — every other
# tctx field (activity_type, delivered_on, client_ref) is safe for any
# authenticated workload to propose, since token-modification.js decides
# what to DO with a proposal, not whether one exists.
resource "pingoneaic_resource_type" "issuance" {
  realm       = var.realm
  name        = "TxnDemo Issuance"
  description = "Transaction tokens demo: which tctx fields a workload may assert"
  patterns = [
    "tctx/*",
  ]
  actions = {
    assert = false
  }
}

# Gate B — may THIS SUBJECT assert a cost? The account manager's subject token
# carries the human scope; the nightly job's own service token never does
# (local.subject_scopes). Note "subject", not "workload": both programs
# authenticate the exchange as the same client, so this cannot and does not
# distinguish the BFF from the job as callers — see departure 8 in
# ARCHITECTURE.md.
#
# The gate is re-run on every mint, so a change HERE takes effect on the next
# token. That is not the same as revocation being immediate: policy.evaluate
# reads the `scope` claim frozen into the subject token, so removing a scope
# from the client configuration has no effect on subject tokens already issued
# until they expire. Editing the policy is immediate; changing what future
# subject tokens carry is not.
resource "pingoneaic_policy_set" "issuance" {
  realm             = var.realm
  name              = "TxnDemoIssuance"
  display_name      = "Transaction Tokens Demo — issuance policy"
  description       = "Gate B: may this workload assert a cost in tctx?"
  resource_type_ids = [pingoneaic_resource_type.issuance.id]
  subjects          = ["JwtClaim", "AuthenticatedUsers", "Identity", "AND", "OR", "NOT", "NONE"]
  conditions        = ["OAuth2Scope", "AND", "OR", "NOT", "Script", "SimpleTime"]
}

# Two policies, not one, and the second is the point.
#
# A policy set with only the ALLOW row answers a non-matching subject with
# `actions: {}` — "no policy applied" (docs/api/21-am-policies.md). That is
# indistinguishable, at the script, from "the policy you meant to consult has
# been deleted or no longer matches this resource". Both produce a cost-free
# token, and the demo would print "refused by the issuance policy, as
# expected" in either case: the headline passing for a reason that is not the
# policy at all.
#
# So the refusal is written down. The nightly job's scope gets an explicit
# `assert = false`, the script requires a boolean either way, and an empty
# decision now means a broken configuration rather than a quiet no.
resource "pingoneaic_policy" "assert_cost" {
  realm            = var.realm
  name             = "TxnDemoIssuance_AssertCost"
  description      = "An account manager's subject token may assert tctx/cost_cents."
  policy_set       = pingoneaic_policy_set.issuance.remote_name
  resource_type_id = pingoneaic_resource_type.issuance.id
  resources        = ["tctx/cost_cents"]
  action_values    = { assert = true }

  subject {
    type        = "JwtClaim"
    claim_name  = "scope"
    claim_value = local.subject_scopes.human
  }
}

resource "pingoneaic_policy" "deny_cost" {
  realm            = var.realm
  name             = "TxnDemoIssuance_DenyCost"
  description      = "The nightly job's service token may NOT assert tctx/cost_cents — an explicit no, so the script can tell a decision from a misconfiguration."
  policy_set       = pingoneaic_policy_set.issuance.remote_name
  resource_type_id = pingoneaic_resource_type.issuance.id
  resources        = ["tctx/cost_cents"]
  action_values    = { assert = false }

  subject {
    type        = "JwtClaim"
    claim_name  = "scope"
    claim_value = local.subject_scopes.service
  }
}
