variable "realm" {
  type        = string
  default     = "bravo"
  description = "The demo lives in bravo. alpha holds live customer config; do not point this at it."
}

variable "login_client_id" {
  type    = string
  default = "CapTokenDemo_web"
}

variable "login_client_secret" {
  type        = string
  sensitive   = true
  description = "The BFF's sign-in client secret. Set TF_VAR_login_client_secret; never commit it."
}

variable "caller_client_id" {
  type    = string
  default = "CapTokenDemo_caller"
}

variable "caller_client_secret" {
  type        = string
  sensitive   = true
  description = "The BFF's outbound client secret. Set TF_VAR_caller_client_secret."
}

variable "web_port" {
  type        = number
  default     = 8790
  description = "Where shop-web listens; the login client's redirect URI is built from it."
}

# The capability map, in one place, exactly as scripts/lib.sh holds it. Both
# gates read it: the scope policies decide who may hold a capability, and the
# shop policies decide what holding it lets you do.
locals {
  capabilities = {
    "orders.read" = {
      role     = "orders.reader"
      resource = "https://*:*/orders/*"
      action   = "read"
      label    = "OrdersRead"
    }
    "orders.approve" = {
      role     = "orders.approver"
      resource = "https://*:*/orders/*"
      action   = "approve"
      label    = "OrdersApprove"
    }
    "payments.refund" = {
      role     = "payments.admin"
      resource = "https://*:*/payments/*"
      action   = "refund"
      label    = "PaymentsRefund"
    }
  }

  # The OAuth2 Scope resource type ships with every realm, and gate A's
  # policies hang off it because AM decides scope grants against this one.
  # It is stock, so Terraform references it rather than creating it.
  oauth2_scope_resource_type = "d60b7a71-1dc6-44a5-8e48-e4b9d92dee8b"

  # The scripts are the ones provision.sh uses, read from their single copy in
  # scripts/am/. Two copies of the same JavaScript would drift, and the whole
  # point of keeping provision.sh is that it can be compared against this.
  script_dir = "${path.module}/../scripts/am"
}
