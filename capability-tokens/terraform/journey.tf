# One scripted decision node, which collects on its first pass through and
# creates the account on its second. Far less config than the stock
# registration nodes, and the whole thing is one reviewable script.
#
# `success` and `failure` are AM's built-in static outcome nodes; the provider
# translates those words to the fixed UUIDs.
resource "pingoneaic_scripted_decision_node" "register" {
  realm     = var.realm
  script_id = pingoneaic_script.register.id
  outcomes  = ["created", "error"]
}

resource "pingoneaic_journey" "register" {
  realm      = var.realm
  name       = "CapTokenDemoRegister"
  entry_node = pingoneaic_scripted_decision_node.register.id

  node {
    id           = pingoneaic_scripted_decision_node.register.id
    type         = "ScriptedDecisionNode"
    display_name = "Register with roles"
    connections = {
      created = "success"
      error   = "failure"
    }
  }
}
