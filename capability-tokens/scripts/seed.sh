#!/usr/bin/env bash
# seed.sh — the demo's IDM fixtures: three capability roles and two users.
#
# Split out of provision.sh because these are the objects Terraform does not
# own, and the line is not arbitrary: they are managed *records*, not config.
# The provider models IDM schema, not the rows in it, and registration creates
# more users at runtime anyway — so the tenant's user table was never
# Terraform's to declare. `terraform apply` then this script gives you the same
# tenant `provision.sh` does.
#
# Idempotent. Needs: an unlocked `aic` agent, curl, jq.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

: "${CAPTOKEN_DEMO_PASSWORD:?set it in .env}"

# ---------------------------------------------------------------- roles
echo "Roles"
role() {  # $1 id, $2 name
  quiet PUT "$IDM/managed/bravo_role/$1" \
    --data "$(jq -n --arg n "$2" '{name:$n,description:("Capability-token demo role: "+$n)}')" &&
    say "$2"
}
role "$ROLE_READER"   orders.reader
role "$ROLE_APPROVER" orders.approver
role "$ROLE_PAYMENTS" payments.admin

# ------------------------------------------------------------ demo users
# Seeds, so the demo works before anyone registers. IDM requires a 36-char
# UUID for a managed user id — a readable slug is rejected outright.
echo "Users"
# A managed user creates with PUT and then refuses one: a second PUT to the
# same id is `400 Not Allowed on RDN`, because a full replace would rewrite
# `fr-idm-uuid`, which is the entry's RDN. So converge with PATCH when the user
# is already there. (The roles, resource type, policies and clients all take a
# repeat write happily; this is the one object that does not.)
user() {  # $1 id, $2 username, $3.. role ids
  local id=$1 name=$2; shift 2
  local refs
  refs=$(for r in "$@"; do jq -n --arg r "$r" '{_ref:("managed/bravo_role/"+$r)}'; done | jq -sc .)
  if quiet GET "$IDM/managed/bravo_user/$id"; then
    # No password in the update: the realm keeps a password history, and
    # re-setting the one the user already has is a 400 Constraint Violation.
    quiet PATCH "$IDM/managed/bravo_user/$id" --data "$(jq -nc \
      --arg u "$name" --argjson roles "$refs" \
      '[{operation:"replace",field:"/userName",value:$u},
        {operation:"replace",field:"/mail",value:$u},
        {operation:"replace",field:"/accountStatus",value:"active"},
        {operation:"replace",field:"/roles",value:$roles}]')" &&
      say "$name (updated)"
  else
    quiet PUT "$IDM/managed/bravo_user/$id" --data "$(jq -n \
      --arg u "$name" --arg p "$CAPTOKEN_DEMO_PASSWORD" --argjson roles "$refs" \
      '{userName:$u, givenName:($u|split("@")[0]), sn:"Demo", mail:$u,
        password:$p, accountStatus:"active", roles:$roles}')" &&
      say "$name"
  fi
}
user "$USER_ALICE" alice@captoken.demo "$ROLE_READER" "$ROLE_APPROVER"
user "$USER_BOB"   bob@captoken.demo   "$ROLE_READER"

# provision.sh calls this and prints its own trailer.
if [ -z "${CAPTOKEN_SEED_QUIET:-}" ]; then
  echo
  echo "Seeded. Once terraform apply has run, check it with: scripts/chain.sh"
fi
