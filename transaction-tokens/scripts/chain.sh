#!/usr/bin/env bash
# chain.sh — the two gates, end to end, against the live tenant, with no
# Node services in the way.
#
# This is the "is the TENANT right?" check. If chain.sh is green and the apps
# still misbehave, the problem is in apps/; if chain.sh is red, no amount of
# reading Node source will help. Run it after terraform apply + seed.sh +
# setup-jwtbearer.sh, before `npm run dev`.
#
# It mints the nightly job's token with `aic auth`, which signs the same
# RFC 7523 assertion apps/shared/aic.js signs — same issuer, same key, same
# subject — so the refusal you see here is the one the job sees.
#
# Needs: .env, an unlocked aic agent, curl, jq, python3.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${TXNDEMO_ALICE_PASSWORD:?set it in .env}"
: "${TXNDEMO_WEB_CLIENT_SECRET:?set it in .env}"
: "${TXNDEMO_JOBSVC_CLIENT_SECRET:?set it in .env}"
: "${TXNDEMO_CALLER_CLIENT_SECRET:?set it in .env}"

TENANT_BASE_URL="${TENANT_BASE_URL:-$(aic --no-prompt ctx list | awk '$1=="*" {print $NF}')}"
TOKEN_URL="$TENANT_BASE_URL/am/oauth2/realms/root/realms/$REALM/access_token"

claims() {
  cut -d. -f2 |
    python3 -c 'import sys,base64,json;p=sys.stdin.read().strip();print(json.dumps(json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4))),indent=2,sort_keys=True))'
}

# The account manager's real sign-in: password grant on the web client.
login_human() {
  curl -sS -u "$WEB_CLIENT:$TXNDEMO_WEB_CLIENT_SECRET" \
    -d grant_type=password -d username=am-alice \
    --data-urlencode "password=$TXNDEMO_ALICE_PASSWORD" \
    -d "scope=openid portal.activities" "$TOKEN_URL" | jq -r '.access_token // empty'
}

# The nightly job's sign-in: it signs its own assertion with the key the
# Trusted JWT Issuer trusts. No user is at a keyboard; there is still an AIC
# user RECORD behind it (departure #7, ARCHITECTURE.md).
login_job() {
  printf '%s' "$TXNDEMO_JOBSVC_CLIENT_SECRET" |
    aic --no-prompt auth --as-username svc-accrual-job \
      --client-id "$JOBSVC_CLIENT" --client-secret-stdin \
      --client-auth client-secret-basic --scope job.accrual \
      --realm "$REALM" --token
}

# One exchange. Prints the raw response so an error is visible as an error.
exchange() { # $1 subject token, $2 request_details JSON
  curl -sS -u "$CALLER_CLIENT:$TXNDEMO_CALLER_CLIENT_SECRET" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    --data-urlencode "subject_token=$1" \
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d requested_token_type=urn:ietf:params:oauth:token-type:access_token \
    -d "audience=${TXNDEMO_TRUST_DOMAIN:-acme-internal}" \
    -d "scope=client:activity:write" \
    --data-urlencode "request_details=$2" \
    --data-urlencode 'request_context={"authn":"chain.sh","portal":"cli"}' \
    "$TOKEN_URL"
}

show_tctx() { # stdin: an exchange response
  local body; body=$(cat)
  if [ "$(printf '%s' "$body" | jq -r '.error // empty')" != "" ]; then
    printf '%s' "$body" | jq -c '{error, error_description}'
    return 1
  fi
  printf '%s' "$body" | jq -r .access_token | claims | jq -c '{sub, req_wl, scope, tctx}'
}

fail=0
check() { # $1 label, $2 expected ("cost"|"nocost"|"error")
  local label=$1 want=$2 out rc
  out=$(cat); rc=0
  case "$want" in
    error)
      if printf '%s' "$out" | jq -e '.error' >/dev/null 2>&1; then
        printf '  %-46s REJECTED (%s)\n' "$label" "$(printf '%s' "$out" | jq -r .error)"
      else rc=1; fi ;;
    cost|nocost)
      local tctx
      tctx=$(printf '%s' "$out" | jq -r '.access_token // empty' | claims | jq -c .tctx 2>/dev/null) || rc=1
      if [ -z "$tctx" ] || [ "$tctx" = "null" ]; then rc=1
      elif [ "$want" = cost ]   && [ "$(printf '%s' "$tctx" | jq -r '.cost_cents // "absent"')" = absent ]; then rc=1
      elif [ "$want" = nocost ] && [ "$(printf '%s' "$tctx" | jq -r '.cost_cents // "absent"')" != absent ]; then rc=1
      else printf '  %-46s %s\n' "$label" "$tctx"; fi ;;
  esac
  if [ "$rc" -ne 0 ]; then
    printf '  %-46s UNEXPECTED: %s\n' "$label" "$(printf '%s' "$out" | head -c 300)"
    fail=1
  fi
}

echo
echo "Gate A + Gate B, as the account manager"
HUMAN=$(login_human)
[ -n "$HUMAN" ] || { echo "  could not sign in as am-alice — is the password in .env the one seed.sh set?" >&2; exit 1; }
exchange "$HUMAN" '{"activity_type":"advisory","delivered_on":"2026-09-01","client_ref":"'"$CLIENT_ACME"'","cost_cents":45000}' |
  check "cost requested, policy allows it" cost

echo
echo "Gate B, as the nightly job — the demonstration"
JOB=$(login_job)
[ -n "$JOB" ] || { echo "  could not sign in as svc-accrual-job — run scripts/setup-jwtbearer.sh" >&2; exit 1; }
exchange "$JOB" '{"activity_type":"accrual","delivered_on":"2026-09-01","cost_cents":9900}' |
  check "same cost requested, policy refuses it" nocost

echo
echo "Input validation — a malformed request is rejected, not signed"
exchange "$HUMAN" '{"activity_type":{"admin":true}}'                   | check "activity_type is not a string"        error
exchange "$HUMAN" '{"delivered_on":"not-a-date"}'                      | check "delivered_on is not a date"           error
exchange "$HUMAN" '{"cost_cents":-1}'                                  | check "cost_cents is negative"               error
exchange "$HUMAN" '{"client_ref":"NOPE-9999","cost_cents":100}'        | check "client_ref names a client not theirs" error

echo
if [ "$fail" -eq 0 ]; then
  echo "All checks behaved as expected. The tenant side is good; run 'cd apps && npm run dev'."
else
  echo "Something did not behave as expected — see above. The tenant side is not ready." >&2
  exit 1
fi
