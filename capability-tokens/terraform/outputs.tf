# Everything the apps need, so `terraform output -json` replaces a hand-written
# apps/.env. scripts/write-env.sh turns this into that file.
#
# The tenant URL is deliberately absent: it is customer-identifying and the
# apps read it from the environment, the same place Terraform does.

output "realm" {
  value = var.realm
}

output "policy_set" {
  value       = pingoneaic_policy_set.shop.remote_name
  description = "Gate B's set — the one shop-api evaluates against."
}

output "scope_policy_set" {
  value       = pingoneaic_policy_set.scopes.remote_name
  description = "Gate A's set — the one the validate-scope script evaluates against."
}

output "register_tree" {
  value = pingoneaic_journey.register.remote_name
}

output "login_client_id" {
  value = pingoneaic_oauth2_client.login.remote_name
}

output "caller_client_id" {
  value = pingoneaic_oauth2_client.caller.remote_name
}

output "offered_roles" {
  value       = [for capability in local.capabilities : capability.role]
  description = "What the registration form may offer. The journey script enforces the same list."
}

output "capabilities" {
  value       = keys(local.capabilities)
  description = "The scopes the caller client may be asked to mint."
}

output "script_ids" {
  value = {
    may_act            = pingoneaic_script.may_act.id
    validate_scope     = pingoneaic_script.validate_scope.id
    token_modification = pingoneaic_script.token_modification.id
    register           = pingoneaic_script.register.id
  }
  description = "Useful when reading a token-exchange failure out of the AM debug log."
}
