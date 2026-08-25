#!/usr/bin/env bash
# teardown.sh — remove everything provision.sh created, and nothing else.
#
# Named objects only, all under the CapTokenDemo prefix or a fixed id. It never
# touches the stock resource types (`URL`, `OAuth2 Scope`, `Authentication`) or
# any policy set it did not create, because this realm is shared.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

KEEP_USERS=${KEEP_USERS:-0}
echo "Removing the capability-token demo from realm '$REALM'."

gone() { say "removed $*"; }

echo "OAuth2 clients"
for c in "$LOGIN_CLIENT" "$CALLER_CLIENT"; do
  quiet DELETE "$AM/realm-config/agents/OAuth2Client/$c" --apiver "$AGENT_V" && gone "$c"
done

echo "Policies"
# Delete the policies before their sets: a set with policies still in it is not
# removable, and the error AM gives for that does not say so.
printf '%s\n' "$CAPABILITIES" | while IFS='|' read -r cap role resource action; do
  name="CapTokenDemo_$(printf '%s' "$cap" | sed -e 's/^\(.\)/\U\1/' -e 's/\.\(.\)/\U\1/')"
  quiet DELETE "$AM/policies/CapTokenDemoScope_$cap" --apiver "$POLICY_V" && gone "CapTokenDemoScope_$cap"
  quiet DELETE "$AM/policies/$name" --apiver "$POLICY_V" && gone "$name"
done

echo "Policy sets"
for s in CapTokenDemo CapTokenDemoScopes; do
  quiet DELETE "$AM/applications/$s" --apiver "$POLICY_V" && gone "$s"
done

echo "Resource type"
quiet DELETE "$AM/resourcetypes/$SHOP_RT" && gone "$SHOP_RT"

echo "Registration journey"
# The tree first: a node still referenced by a tree cannot be removed.
quiet DELETE "$AM/realm-config/authentication/authenticationtrees/trees/$TREE_REGISTER" \
  --apiver "$AGENT_V" && gone "$TREE_REGISTER"
quiet DELETE "$AM/realm-config/authentication/authenticationtrees/nodes/ScriptedDecisionNode/$NODE_REGISTER" \
  --apiver "$AGENT_V" && gone "node $NODE_REGISTER"

echo "Scripts"
for s in "$SCRIPT_MAYACT" "$SCRIPT_VALIDATE" "$SCRIPT_TOKENMOD" "$SCRIPT_REGISTER"; do
  quiet DELETE "$AM/scripts/$s" --apiver "$SCRIPT_V" && gone "script $s"
done

if [ "$KEEP_USERS" = "1" ]; then
  echo "Users and roles kept (KEEP_USERS=1)."
else
  echo "Users"
  for u in "$USER_ALICE" "$USER_BOB"; do
    quiet DELETE "$IDM/managed/bravo_user/$u" && gone "user $u"
  done
  # Anyone who registered through the journey. They have generated ids, so
  # they are found by address. `co` and not `ew` — IDM rejects `ew` here, and
  # rejects it by returning a body with no `result` rather than an error, so a
  # wrong filter reads as "nobody to delete" and silently leaves them behind.
  for id in $(aic_call GET "$IDM/managed/bravo_user?_queryFilter=$(printf 'userName co "@captoken.demo"' | jq -sRr @uri)&_fields=_id" 2>/dev/null | jq -r '.result[]?._id'); do
    quiet DELETE "$IDM/managed/bravo_user/$id" && gone "registered user $id"
  done
  echo "Roles"
  for r in "$ROLE_READER" "$ROLE_APPROVER" "$ROLE_PAYMENTS"; do
    quiet DELETE "$IDM/managed/bravo_role/$r" && gone "role $r"
  done
fi

echo
echo "Done."
