#!/usr/bin/env bash
# seed.sh — the demo's IDM fixtures: the account manager, the nightly job's
# own service identity, and one client related to the account manager.
#
# Split out of Terraform because these are records, not schema — the
# provider owns bravo_txn_client's *type* and the manager<->client
# relationship's shape, not the rows in it. Run this after `terraform apply`;
# the relationship property has to exist before a record can use it, and a
# relationship added after records already exist does not retro-link
# (docs/api/10-managed-objects.md, in pingone-aic-manager).
#
# Idempotent. Needs: an unlocked `aic` agent, curl, jq.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${TXNDEMO_ALICE_PASSWORD:?set it in .env}"
: "${TXNDEMO_JOBSVC_PASSWORD:?set it in .env}"

# A managed user creates with PUT and then refuses a second one: PUT again is
# 400 Not Allowed on RDN (a full replace would rewrite fr-idm-uuid, the
# entry's RDN). Converge with PATCH when already there, and never re-send the
# password — the realm's password history rejects re-setting the one already
# stored.
user() { # $1 id, $2 username, $3 password
  local id=$1 name=$2 password=$3
  if quiet GET "$IDM/managed/bravo_user/$id"; then
    quiet PATCH "$IDM/managed/bravo_user/$id" --data "$(jq -nc \
      --arg u "$name" --arg m "$name@txndemo.test" \
      '[{operation:"replace",field:"/userName",value:$u},
        {operation:"replace",field:"/mail",value:$m},
        {operation:"replace",field:"/accountStatus",value:"active"}]')" &&
      say "$name (updated)"
  else
    quiet PUT "$IDM/managed/bravo_user/$id" --data "$(jq -n \
      --arg u "$name" --arg p "$password" \
      '{userName:$u, givenName:($u|split("-")[1]//$u), sn:"Demo", mail:($u+"@txndemo.test"),
        password:$p, accountStatus:"active"}')" &&
      say "$name"
  fi
}

echo "Identities"
user "$USER_ALICE"  am-alice        "$TXNDEMO_ALICE_PASSWORD"
user "$USER_JOBSVC" svc-accrual-job "$TXNDEMO_JOBSVC_PASSWORD"

echo "Clients"
# bravo_txn_client has no fr-idm-uuid RDN constraint (it is a custom type, not
# a Ping-shipped identity object), so PUT converges fine on a repeat run.
quiet PUT "$IDM/managed/bravo_txn_client/$CLIENT_ACME" --data "$(jq -n \
  --arg manager "$USER_ALICE" \
  '{displayName:"Acme Holdings", tier:"gold",
    accountManager:{_ref:("managed/bravo_user/"+$manager)}}')" &&
  say "Acme Holdings (gold, managed by am-alice)"

echo
echo "Seeded. Once terraform apply and scripts/setup-jwtbearer.sh have both run,"
echo "check it with: scripts/chain.sh"
