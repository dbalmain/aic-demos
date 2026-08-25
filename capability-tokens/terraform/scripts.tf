# The four AM scripts, read from their single copy in scripts/am/ so
# provision.sh and Terraform cannot drift apart.
#
# `evaluator_version` defaults to 2.0 in the provider, but note that the
# evaluator is really selected by the *context id*: the _NEXT_GEN contexts are
# what get you the v2 engine. A legacy context cannot take a JS object literal
# and fails at runtime with "Error running may_act script".

# Stamps may_act on the identity token, naming the caller client as the only
# client allowed to exchange it. The template is shared with provision.sh, which
# substitutes the same placeholder with sed.
resource "pingoneaic_script" "may_act" {
  realm       = var.realm
  name        = "CapTokenDemo_MayAct"
  description = "Let the caller client act for this subject."
  context     = "OAUTH2_MAY_ACT_NEXT_GEN"
  source = replace(
    file("${local.script_dir}/may-act.js.tmpl"),
    "@@CALLER_CLIENT@@",
    var.caller_client_id,
  )
}

# Gate A. Asks the scope policies which of the requested capabilities this
# subject may hold, and returns only those. Fails closed.
resource "pingoneaic_script" "validate_scope" {
  realm       = var.realm
  name        = "CapTokenDemo_ValidateScope"
  description = "Gate A: ask the scope policies which capabilities this subject may hold."
  context     = "OAUTH2_VALIDATE_SCOPE_NEXT_GEN"
  source      = file("${local.script_dir}/validate-scope.js")
}

# Puts the user's IDM role names into the token as demoRoles, which is what
# both gates match on.
resource "pingoneaic_script" "token_modification" {
  realm       = var.realm
  name        = "CapTokenDemo_TokenModification"
  description = "Put the user's role names in the token as demoRoles."
  context     = "OAUTH2_ACCESS_TOKEN_MODIFICATION_NEXT_GEN"
  source      = file("${local.script_dir}/token-modification.js")
}

# The demo's deliberate hole: registration that lets the registrant choose
# their own roles. The script bounds the choice to the three capability roles;
# the form says "never do this" above the fields.
resource "pingoneaic_script" "register" {
  realm       = var.realm
  name        = "CapTokenDemo_Register"
  description = "Self-service registration with role choice (demo only)."
  context     = "SCRIPTED_DECISION_NODE"
  source      = file("${local.script_dir}/register.js")
}
