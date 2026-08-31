# Everything the apps need, so `terraform output -json` replaces a
# hand-written apps/.env. scripts/write-env.sh turns this into that file.
#
# The tenant URL is deliberately absent: it is customer-identifying and the
# apps read it from the environment, the same place Terraform does.

output "realm" {
  value = var.realm
}

output "web_client_id" {
  value = pingoneaic_oauth2_client.web.remote_name
}

output "jobsvc_client_id" {
  value = pingoneaic_oauth2_client.jobsvc.remote_name
}

output "caller_client_id" {
  value = pingoneaic_oauth2_client.caller.remote_name
}

output "managed_client_type" {
  value       = pingoneaic_managed_object.txn_client.remote_name
  description = "The IDM managed-object type seed.sh creates client fixtures against."
}

output "issuance_policy_set" {
  value       = pingoneaic_policy_set.issuance.remote_name
  description = "Gate B's set — the one the token-modification script evaluates against."
}

output "scopes_policy_set" {
  value       = pingoneaic_policy_set.scopes.remote_name
  description = "Gate A's set — the one the validate-scope script evaluates against."
}

output "subject_scopes" {
  value       = local.subject_scopes
  description = "The two subject-token scopes that ever reach the exchange."
}

output "script_ids" {
  value = {
    may_act_web        = pingoneaic_script.may_act_web.id
    may_act_jobsvc     = pingoneaic_script.may_act_jobsvc.id
    validate_scope     = pingoneaic_script.validate_scope.id
    token_modification = pingoneaic_script.token_modification.id
  }
  description = "Useful when reading a token-exchange failure out of the AM debug log."
}
