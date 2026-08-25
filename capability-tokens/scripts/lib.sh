# Shared shell helpers for provision/teardown. Source, don't execute.
#
# Everything is addressed by a fixed id so both scripts are idempotent and so
# Terraform (phase 3) has the same names to import.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

REALM="${CAPTOKEN_REALM:-bravo}"
AM="/am/json/realms/root/realms/$REALM"
IDM="/openidm"
POLICY_V="protocol=1.0,resource=2.0"
AGENT_V="protocol=2.1,resource=1.0"
SCRIPT_V="protocol=2.0,resource=1.0"

# The OAuth2 Scope resource type ships with every realm; gate A's policies hang
# off it rather than off a type of our own, because AM decides scope grants
# against this one.
OAUTH2_SCOPE_RT="d60b7a71-1dc6-44a5-8e48-e4b9d92dee8b"
SHOP_RT="CapTokenDemoShopApi"

# Fixed ids. Managed objects must be UUIDs (IDM rejects a slug for a user);
# scripts are UUIDs too. Policies, policy sets and resource types take names.
ROLE_READER=0a97c001-0000-4000-8000-000000000011
ROLE_APPROVER=0a97c001-0000-4000-8000-000000000012
ROLE_PAYMENTS=0a97c001-0000-4000-8000-000000000013
USER_ALICE=0a97c001-0000-4000-8000-000000000001
USER_BOB=0a97c001-0000-4000-8000-000000000002
SCRIPT_MAYACT=0a97c001-0000-4000-8000-00000000aa02
SCRIPT_VALIDATE=0a97c001-0000-4000-8000-00000000aa03
SCRIPT_TOKENMOD=0a97c001-0000-4000-8000-00000000aa04
SCRIPT_REGISTER=0a97c001-0000-4000-8000-00000000aa05
NODE_REGISTER=0a97c001-0000-4000-8000-0000000000b1
TREE_REGISTER=CapTokenDemoRegister

# AM's built-in static tree endpoints. Every tree connects to these same two
# ids; they are not nodes you create.
TREE_SUCCESS=70e691a5-1e33-4ac3-a356-e7b6d60d92e0
TREE_FAILURE=e301438c-0bd0-429c-ab0c-66126501069a

LOGIN_CLIENT="${CAPTOKEN_LOGIN_CLIENT_ID:-CapTokenDemo_web}"
CALLER_CLIENT="${CAPTOKEN_CALLER_CLIENT_ID:-CapTokenDemo_caller}"

# The capability → role map, in one place. Both gates read it: the scope
# policies decide who may hold a capability, the shop policies what holding it
# lets you do.
#   capability | role | resource | action
CAPABILITIES='orders.read|orders.reader|https://*:*/orders/*|read
orders.approve|orders.approver|https://*:*/orders/*|approve
payments.refund|payments.admin|https://*:*/payments/*|refund'

aic_call() { "$HERE/aicurl.sh" "$@"; }
quiet()    { "$HERE/aicurl.sh" "$@" >/dev/null 2>&1; }
say()      { printf '  %s\n' "$*"; }
