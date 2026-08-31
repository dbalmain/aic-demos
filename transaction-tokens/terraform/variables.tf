variable "realm" {
  type        = string
  default     = "bravo"
  description = "The demo lives in bravo, alongside capability-tokens. alpha holds live customer config; do not point this at it."
}

variable "web_client_id" {
  type    = string
  default = "TxnDemo_web"
}

variable "web_client_secret" {
  type        = string
  sensitive   = true
  description = "The account manager's sign-in client secret. Set TF_VAR_web_client_secret; never commit it."
}

variable "jobsvc_client_id" {
  type    = string
  default = "TxnDemo_jobsvc"
}

variable "jobsvc_client_secret" {
  type        = string
  sensitive   = true
  description = "The nightly job's self-sign-in client secret (jwt-bearer grant, no user). Set TF_VAR_jobsvc_client_secret."
}

variable "caller_client_id" {
  type    = string
  default = "TxnDemo_caller"
}

variable "caller_client_secret" {
  type        = string
  sensitive   = true
  description = "The internal exchange client's secret — every trust-domain service authenticates as this one client to mint a Txn-Token. Set TF_VAR_caller_client_secret."
}

variable "web_port" {
  type        = number
  default     = 9000
  description = "Where portal-bff listens; the web client's redirect URI is built from it."
}

locals {
  # The OAuth2 Scope resource type ships with every realm; gate A's policies
  # hang off it because AM decides scope grants against this one. Same id
  # capability-tokens references — it is stock, not per-tenant.
  oauth2_scope_resource_type = "d60b7a71-1dc6-44a5-8e48-e4b9d92dee8b"

  script_dir = "${path.module}/../scripts/am"

  # The two subject-token scopes the internal exchange ever sees, and what
  # each may do. A subject token is either a real account manager's (signed
  # in through the browser) or the nightly job's own service identity (signed
  # in via jwt-bearer, no user) — nothing else ever reaches the exchange.
  subject_scopes = {
    human   = "portal.activities"
    service = "job.accrual"
  }
}
