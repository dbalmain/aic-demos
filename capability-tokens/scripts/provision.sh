#!/usr/bin/env bash
# provision.sh — build the whole demo in the tenant, from nothing.
#
# Idempotent: safe to re-run. Phase 3 replaces this with Terraform, and until
# then this script is the specification of what Terraform has to produce.
#
# Needs: an unlocked `aic` agent (see scripts/aicurl.sh), curl, jq.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${CAPTOKEN_LOGIN_CLIENT_SECRET:?set it in .env}"
: "${CAPTOKEN_CALLER_CLIENT_SECRET:?set it in .env}"
: "${CAPTOKEN_DEMO_PASSWORD:?set it in .env}"

echo "Provisioning the capability-token demo into realm '$REALM'."

# The IDM fixtures — roles and demo users — live in seed.sh, because they are
# managed records rather than config and Terraform does not own them. Running
# them from here keeps `provision.sh` a single command that builds everything.
CAPTOKEN_SEED_QUIET=1 "$HERE/seed.sh"

# -------------------------------------------------------- resource type
# A resource type is the one AM object here that creates with a PUT to an id
# you choose; policies and policy sets refuse that and need ?_action=create.
echo "Resource type"
quiet PUT "$AM/resourcetypes/$SHOP_RT" --data '{
  "name":"CapTokenDemo Shop API",
  "description":"Capability-token demo: the shop API surface",
  "patterns":["https://*:*/orders","https://*:*/orders/*","https://*:*/payments","https://*:*/payments/*"],
  "actions":{"read":true,"approve":false,"refund":false}}' && say "$SHOP_RT"

# ----------------------------------------------------------- policy sets
echo "Policy sets"
policy_set() {  # $1 name, $2 display, $3 description, $4 resource type uuid
  local body
  body=$(jq -n --arg n "$1" --arg d "$2" --arg desc "$3" --arg rt "$4" '{
    name:$n, displayName:$d, description:$desc, resourceTypeUuids:[$rt],
    applicationType:"iPlanetAMWebAgentService", entitlementCombiner:"DenyOverride",
    conditions:["OAuth2Scope","AND","OR","NOT","Script","SimpleTime"],
    subjects:["JwtClaim","AuthenticatedUsers","Identity","AND","OR","NOT","NONE"]}')
  quiet PUT "$AM/applications/$1" --apiver "$POLICY_V" --data "$body" ||
    quiet POST "$AM/applications?_action=create" --apiver "$POLICY_V" --data "$body"
  say "$1"
}
policy_set CapTokenDemo "Capability Tokens Demo" \
  "Gate B: what a presented capability token may do." "$SHOP_RT"
policy_set CapTokenDemoScopes "Capability Tokens Demo — grantable capabilities" \
  "Gate A: which capabilities a user may be given at token-exchange time." "$OAUTH2_SCOPE_RT"

# ------------------------------------------------------------- policies
# A policy has no update-or-create verb, so replace: delete then create. Both
# gates key on JwtClaim, because a `jwt` subject never satisfies
# AuthenticatedUsers and `claims` satisfies nothing at all.
echo "Policies"
replace_policy() {  # $1 name, $2 body
  quiet DELETE "$AM/policies/$1" --apiver "$POLICY_V" || true
  quiet POST "$AM/policies?_action=create" --apiver "$POLICY_V" --data "$2" && say "$1"
}
printf '%s\n' "$CAPABILITIES" | while IFS='|' read -r cap role resource action; do
  # Gate A — may this user hold the capability at all?
  replace_policy "CapTokenDemoScope_$cap" "$(jq -n \
    --arg n "CapTokenDemoScope_$cap" --arg cap "$cap" --arg role "$role" --arg rt "$OAUTH2_SCOPE_RT" '{
      name:$n, active:true,
      description:("Grant the "+$cap+" capability to holders of the "+$role+" role."),
      applicationName:"CapTokenDemoScopes", resourceTypeUuid:$rt,
      resources:[$cap], actionValues:{GRANT:true},
      subject:{type:"JwtClaim",claimName:"demoRoles",claimValue:$role}}')"

  # Gate B — the role AND the capability, both read out of the presented token.
  # Requiring the role again is not redundant: a capability token outlives the
  # role being revoked, and this is where that gets caught.
  name="CapTokenDemo_$(printf '%s' "$cap" | sed -e 's/^\(.\)/\U\1/' -e 's/\.\(.\)/\U\1/')"
  replace_policy "$name" "$(jq -n \
    --arg n "$name" --arg cap "$cap" --arg role "$role" --arg r "$resource" \
    --arg a "$action" --arg rt "$SHOP_RT" '{
      name:$n, active:true,
      description:($a+" needs the "+$role+" role and the "+$cap+" capability."),
      applicationName:"CapTokenDemo", resourceTypeUuid:$rt,
      resources:[$r], actionValues:{($a):true},
      subject:{type:"AND",subjects:[
        {type:"JwtClaim",claimName:"demoRoles",claimValue:$role},
        {type:"JwtClaim",claimName:"scope",claimValue:$cap}]}}')"
done

# -------------------------------------------------------------- scripts
# `evaluatorVersion` follows the context id, not the field: the _NEXT_GEN
# contexts are what select the v2 evaluator.
echo "Scripts"
script() {  # $1 id, $2 name, $3 description, $4 context, $5 file
  quiet PUT "$AM/scripts/$1" --apiver "$SCRIPT_V" --data "$(jq -n \
    --arg n "$2" --arg d "$3" --arg c "$4" --arg s "$(base64 -w0 "$HERE/am/$5")" \
    '{name:$n,description:$d,script:$s,language:"JAVASCRIPT",context:$c,
      evaluatorVersion:"2.0",default:false}')" && say "$2"
}
sed "s/@@CALLER_CLIENT@@/$CALLER_CLIENT/" "$HERE/am/may-act.js.tmpl" > "$HERE/am/may-act.js"
script "$SCRIPT_MAYACT"   CapTokenDemo_MayAct \
  "Let the caller client act for this subject." OAUTH2_MAY_ACT_NEXT_GEN may-act.js
script "$SCRIPT_VALIDATE" CapTokenDemo_ValidateScope \
  "Gate A: ask the scope policies which capabilities this subject may hold." \
  OAUTH2_VALIDATE_SCOPE_NEXT_GEN validate-scope.js
script "$SCRIPT_TOKENMOD" CapTokenDemo_TokenModification \
  "Put the user's role names in the token as demoRoles." \
  OAUTH2_ACCESS_TOKEN_MODIFICATION_NEXT_GEN token-modification.js
script "$SCRIPT_REGISTER" CapTokenDemo_Register \
  "Self-service registration with role choice (demo only)." \
  SCRIPTED_DECISION_NODE register.js

# ------------------------------------------------- registration journey
# One scripted decision node, which collects on its first pass and creates the
# account on its second. A node takes only inputs/outcomes/outputs/script — a
# `name` is rejected outright; the label lives on the tree's node entry.
echo "Registration journey"
quiet PUT "$AM/realm-config/authentication/authenticationtrees/nodes/ScriptedDecisionNode/$NODE_REGISTER" \
  --apiver "$AGENT_V" --data "$(jq -n --arg s "$SCRIPT_REGISTER" \
    '{script:$s,outcomes:["created","error"],outputs:["*"],inputs:["*"]}')" &&
  say "node $NODE_REGISTER"
quiet PUT "$AM/realm-config/authentication/authenticationtrees/trees/$TREE_REGISTER" \
  --apiver "$AGENT_V" --data "$(jq -n --arg n "$NODE_REGISTER" --arg ok "$TREE_SUCCESS" --arg no "$TREE_FAILURE" \
    '{entryNodeId:$n, nodes:{($n):{displayName:"Register with roles",
      nodeType:"ScriptedDecisionNode", connections:{created:$ok, error:$no}}}}')" &&
  say "$TREE_REGISTER"

# -------------------------------------------------------- oauth2 clients
# One per layer. PUT replaces the whole object and AM re-applies no defaults to
# the groups you omit, so both bodies start from the template.
echo "OAuth2 clients"
TEMPLATE=$(aic_call POST "$AM/realm-config/agents/OAuth2Client?_action=template" \
  --apiver "$AGENT_V" --data '{}' 2>/dev/null)

# The user's sign-in client. Allowed openid/profile and nothing else, so it can
# never issue a capability — which is why it carries no scope gate.
echo "$TEMPLATE" | jq \
  --arg secret "$CAPTOKEN_LOGIN_CLIENT_SECRET" --arg mayact "$SCRIPT_MAYACT" \
  --arg tokenmod "$SCRIPT_TOKENMOD" '
   .coreOAuth2ClientConfig.clientType="Confidential"
 | .coreOAuth2ClientConfig.userpassword=$secret
 | .coreOAuth2ClientConfig.redirectionUris=["http://localhost:8790/callback"]
 | .coreOAuth2ClientConfig.scopes=["openid","profile"]
 | .coreOAuth2ClientConfig.defaultScopes=["openid"]
 | .coreOAuth2ClientConfig.accessTokenLifetime=900
 | .advancedOAuth2ClientConfig.grantTypes=["password","authorization_code","refresh_token"]
 | .advancedOAuth2ClientConfig.tokenEndpointAuthMethod="client_secret_basic"
 | .advancedOAuth2ClientConfig.isConsentImplied=true
 | .overrideOAuth2ClientConfig.providerOverridesEnabled=true
 | .overrideOAuth2ClientConfig.statelessTokensEnabled=true
 | .overrideOAuth2ClientConfig.accessTokenMayActScript=$mayact
 | .overrideOAuth2ClientConfig.accessTokenModificationPluginType="SCRIPTED"
 | .overrideOAuth2ClientConfig.accessTokenModificationScript=$tokenmod' > /tmp/captoken-login.json
quiet PUT "$AM/realm-config/agents/OAuth2Client/$LOGIN_CLIENT" --apiver "$AGENT_V" \
  --data "$(cat /tmp/captoken-login.json)" && say "$LOGIN_CLIENT (sign-in, 900s, openid only)"

# The BFF's outbound identity. Token-exchange only, no refresh token, 60s, and
# it carries the gate — attach it here and nowhere else, because AM consults
# the *acting* client's config and ignores the login client's.
echo "$TEMPLATE" | jq \
  --arg secret "$CAPTOKEN_CALLER_CLIENT_SECRET" --arg validate "$SCRIPT_VALIDATE" \
  --arg tokenmod "$SCRIPT_TOKENMOD" '
   .coreOAuth2ClientConfig.clientType="Confidential"
 | .coreOAuth2ClientConfig.userpassword=$secret
 | .coreOAuth2ClientConfig.scopes=["orders.read","orders.approve","payments.refund"]
 | .coreOAuth2ClientConfig.defaultScopes=[]
 | .coreOAuth2ClientConfig.accessTokenLifetime=60
 | .advancedOAuth2ClientConfig.grantTypes=["urn:ietf:params:oauth:grant-type:token-exchange"]
 | .advancedOAuth2ClientConfig.tokenEndpointAuthMethod="client_secret_basic"
 | .overrideOAuth2ClientConfig.providerOverridesEnabled=true
 | .overrideOAuth2ClientConfig.statelessTokensEnabled=true
 | .overrideOAuth2ClientConfig.validateScopePluginType="SCRIPTED"
 | .overrideOAuth2ClientConfig.validateScopeScript=$validate
 | .overrideOAuth2ClientConfig.accessTokenModificationPluginType="SCRIPTED"
 | .overrideOAuth2ClientConfig.accessTokenModificationScript=$tokenmod' > /tmp/captoken-caller.json
quiet PUT "$AM/realm-config/agents/OAuth2Client/$CALLER_CLIENT" --apiver "$AGENT_V" \
  --data "$(cat /tmp/captoken-caller.json)" && say "$CALLER_CLIENT (exchange, 60s, carries gate A)"

rm -f /tmp/captoken-login.json /tmp/captoken-caller.json
echo
echo "Done. Check it with: scripts/chain.sh"
