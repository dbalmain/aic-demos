# The manager<->client relationship lives in AIC itself, not in an app
# database, so the whole demo is a `terraform apply` + a seed script — no
# tunnel from AIC back into anything of ours. bravo_txn_client is a new
# managed type; the reverse property this writes onto bravo_user (a
# Ping-shipped object) must be `custom_`-prefixed and comes back unindexed —
# both AIC constraints, not this provider's (docs/api/10-managed-objects.md).
resource "pingoneaic_managed_object" "txn_client" {
  name  = "bravo_txn_client"
  title = "Transaction Tokens Demo — Client"
  icon  = "fa-briefcase"

  property {
    name     = "displayName"
    type     = "string"
    title    = "Display name"
    required = true
  }

  property {
    name     = "tier"
    type     = "string"
    title    = "Tier"
    enum     = ["bronze", "silver", "gold"]
    required = true
  }

  # Has-one from the client's side: which account manager owns this client.
  # The reverse (has-many, one manager to many clients) is what the
  # token-modification script actually reads.
  property {
    name                  = "accountManager"
    type                  = "relationship"
    title                 = "Account manager"
    resource_path         = "managed/bravo_user"
    reverse_property_name = "custom_txnClients"
    reverse_relationship  = true
    reverse_cardinality   = "many"
  }
}
