#!/usr/bin/env sh
# chain.sh — the capability-token flow, end to end, against the live tenant.
#
# This is the Phase 0 exit criterion made repeatable: log in as a user whose
# identity token carries no capability, exchange it for exactly one, ask AM's
# policy engine whether that token may act, and show the same question answered
# "no" for the capability the user has no claim to.
#
# Two clients, because there are two layers. The login client authenticates the
# user; the caller client is the BFF's own outbound identity and is the one that
# mints capability tokens. The exchange is permitted only because the identity
# token carries may_act naming the caller, and the capability token's 60s life
# is the caller's — there is no per-exchange lifetime.
#
# Needs: .env (see .env.example), an unlocked aic agent, curl, jq, python3.
set -eu

here=$(dirname "$0")
[ -f "$here/../.env" ] && . "$here/../.env"
: "${CAPTOKEN_REALM:=bravo}"
: "${CAPTOKEN_LOGIN_CLIENT_ID:=CapTokenDemo_web}"
: "${CAPTOKEN_LOGIN_CLIENT_SECRET:?set CAPTOKEN_LOGIN_CLIENT_SECRET in .env}"
: "${CAPTOKEN_CALLER_CLIENT_ID:=CapTokenDemo_caller}"
: "${CAPTOKEN_CALLER_CLIENT_SECRET:?set CAPTOKEN_CALLER_CLIENT_SECRET in .env}"
: "${CAPTOKEN_DEMO_PASSWORD:?set CAPTOKEN_DEMO_PASSWORD in .env}"

if [ -z "${TENANT_BASE_URL:-}" ]; then
  TENANT_BASE_URL=$(cd "${AIC_PROJECT_DIR:-$here/../../../pingone-aic-manager}" &&
    aic --no-prompt ctx list | awk '$1=="*" {print $NF}')
fi
TOKEN_URL="$TENANT_BASE_URL/am/oauth2/realms/root/realms/$CAPTOKEN_REALM/access_token"
LOGIN_AUTH="$CAPTOKEN_LOGIN_CLIENT_ID:$CAPTOKEN_LOGIN_CLIENT_SECRET"
CALLER_AUTH="$CAPTOKEN_CALLER_CLIENT_ID:$CAPTOKEN_CALLER_CLIENT_SECRET"

claims() { cut -d. -f2 | python3 -c 'import sys,base64,json;p=sys.stdin.read().strip();print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))))'; }

login() {   # $1 = username -> access token on stdout
  curl -sS -u "$LOGIN_AUTH" -d grant_type=password -d "username=$1" \
    -d "password=$CAPTOKEN_DEMO_PASSWORD" -d scope=openid "$TOKEN_URL" |
    jq -r '.access_token // empty'
}

exchange() {  # $1 = subject token, $2 = requested scope -> token (may be empty)
              # authenticates as the CALLER: the scope gate that decides this
              # lives on the acting client, not on the login client.
  curl -sS -u "$CALLER_AUTH" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d "subject_token=$1" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d requested_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d "scope=$2" "$TOKEN_URL" | jq -r '.access_token // empty'
}

decide() {  # $1 = token, $2 = resource -> the granted actions
  "$here/aicurl.sh" POST \
    "/am/json/realms/root/realms/$CAPTOKEN_REALM/policies?_action=evaluate" \
    --apiver protocol=1.0,resource=2.0 \
    --data "$(jq -n --arg t "$1" --arg r "$2" \
      '{resources:[$r],application:"CapTokenDemo",subject:{jwt:$t}}')" \
    2>/dev/null | jq -c '.[0].actions'
}

ORDER=https://shop-api.demo:443/orders/123
PAYMENT=https://shop-api.demo:443/payments/9

for who in alice bob; do
  echo "== $who@captoken.demo =="
  base=$(login "$who@captoken.demo")
  [ -n "$base" ] || { echo "  login failed"; continue; }
  echo "  identity token : $(printf '%s' "$base" | claims | jq -c '{scope,demoRoles}')"
  echo "  it may         : $(decide "$base" "$ORDER") on the order"

  for want in orders.read orders.approve payments.refund; do
    cap=$(exchange "$base" "$want")
    if [ -z "$cap" ]; then echo "  $want: refused at the exchange"; continue; fi
    got=$(printf '%s' "$cap" | claims | jq -rc '"\(.scope) for \(.exp - .iat)s"')
    case "$want" in payments.*) res=$PAYMENT ;; *) res=$ORDER ;; esac
    echo "  $want: minted $got -> $(decide "$cap" "$res")"
  done
done
