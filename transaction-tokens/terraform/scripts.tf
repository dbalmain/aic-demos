# Every identity token that will ever be exchanged — the account manager's and
# the nightly job's own — needs a may_act script naming the caller client, or
# the exchange comes back invalid_request. Same script, two instances: the
# subject differs but the acting client does not (one internal exchange
# client serves the whole trust domain, per ARCHITECTURE.md).
resource "pingoneaic_script" "may_act_web" {
  realm       = var.realm
  name        = "TxnDemo_MayAct_Web"
  description = "Let the caller client act for the signed-in account manager."
  context     = "OAUTH2_MAY_ACT_NEXT_GEN"
  source = replace(
    file("${local.script_dir}/may-act.js.tmpl"),
    "@@CALLER_CLIENT@@",
    var.caller_client_id,
  )
}

resource "pingoneaic_script" "may_act_jobsvc" {
  realm       = var.realm
  name        = "TxnDemo_MayAct_JobSvc"
  description = "Let the caller client act for the nightly job's own service identity."
  context     = "OAUTH2_MAY_ACT_NEXT_GEN"
  source = replace(
    file("${local.script_dir}/may-act.js.tmpl"),
    "@@CALLER_CLIENT@@",
    var.caller_client_id,
  )
}

# Gate A. Narrows the internal exchange scope to what the subject token's own
# scope actually earns it — never widens past what the caller client itself
# allows.
resource "pingoneaic_script" "validate_scope" {
  realm       = var.realm
  name        = "TxnDemo_ValidateScope"
  description = "Gate A: is the requested internal scope within what the subject token carries?"
  context     = "OAUTH2_VALIDATE_SCOPE_NEXT_GEN"
  source      = file("${local.script_dir}/validate-scope.js")
}

# Mints tctx/rctx, enriches the manager<->client relationship in-process via
# the openidm binding, and asks the issuance policy which fields this subject
# may assert.
resource "pingoneaic_script" "token_modification" {
  realm       = var.realm
  name        = "TxnDemo_TokenModification"
  description = "Mint tctx/rctx; enrich from IDM; gate cost_cents on the issuance policy."
  context     = "OAUTH2_ACCESS_TOKEN_MODIFICATION_NEXT_GEN"
  source      = file("${local.script_dir}/token-modification.js")
}
