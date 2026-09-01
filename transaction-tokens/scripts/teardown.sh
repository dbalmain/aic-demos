#!/usr/bin/env bash
# teardown.sh — undo everything the demo created, in the order that works.
#
# `terraform destroy` alone is not enough: it owns the tenant CONFIG (clients,
# scripts, policies, the managed-object type) but not the RECORDS seed.sh
# wrote, not the Trusted JWT Issuer subject setup-jwtbearer.sh added, and not
# the local artefacts (the private JWK, apps/.env, the SQLite ledger).
#
# Records first, config second: a bravo_txn_client record cannot outlive the
# type that defines it, and destroying the type with rows still in it is how
# you end up with a managed object you can neither read nor delete.
#
#   scripts/teardown.sh            # tenant records + local artefacts
#   scripts/teardown.sh --all      # the above, then terraform destroy
#
# Idempotent: every step tolerates the thing already being gone.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

# "Already gone" and "the delete failed" are different outcomes, and reporting
# the second as the first is how --all proceeds to terraform destroy with the
# rows still in place — the exact ordering problem this script's header says
# it prevents. So probe first, and let a real failure stop the run.
failed=0
remove() { # $1 managed path, $2 label
  local path=$1 label=$2
  if ! quiet GET "$IDM/managed/$path"; then
    say "$label (already gone)"
    return 0
  fi
  if quiet DELETE "$IDM/managed/$path"; then
    say "$label removed"
  else
    echo "  ERROR: could not delete $label ($path)" >&2
    failed=1
  fi
}

echo "Records"
remove "bravo_txn_client/$CLIENT_ACME" "Acme Holdings"
remove "bravo_user/$USER_ALICE"        "am-alice"
remove "bravo_user/$USER_JOBSVC"       "svc-accrual-job"

echo "Trusted JWT Issuer"
# Leaves the realm's issuer and its key in place — both are install-wide, not
# this demo's to delete (setup-jwtbearer.sh says the same in reverse). Only
# the subject this demo added is withdrawn.
#
# EXCEPT when it is the only one. An EMPTY allowedSubjects does not mean
# "nobody"; it means EVERY user in the realm
# (pingone-aic-manager docs/api/17-jwt-bearer-user-tokens.md). Withdrawing the
# last subject from an issuer whose key stays published would hand anyone
# holding that key the ability to mint for any user — a teardown that ends
# with the tenant less safe than it started. Refuse, and say why.
subjects=$(aic --no-prompt jwt-bearer subjects list --realm "$REALM" 2>/dev/null || true)
if ! printf '%s\n' "$subjects" | grep -qx "$USER_JOBSVC"; then
  say "svc-accrual-job was not an allowed subject (already gone)"
elif [ "$(printf '%s\n' "$subjects" | grep -c .)" -le 1 ]; then
  say "svc-accrual-job is the issuer's ONLY allowed subject — leaving it."
  say "  An empty allowedSubjects means every user in the realm, not none."
  say "  Remove the issuer itself if you want it gone, rather than emptying it."
elif aic --no-prompt jwt-bearer subjects rm --id "$USER_JOBSVC" --realm "$REALM" >/dev/null 2>&1; then
  say "svc-accrual-job withdrawn from allowedSubjects"
else
  echo "  ERROR: could not withdraw svc-accrual-job from allowedSubjects" >&2
  failed=1
fi

# These are removed unconditionally. If you pointed this demo at fixtures that
# already existed — the two user UUIDs are fixed, and seed.sh adopts a record
# it finds rather than failing — then teardown is deleting something it did
# not create. Say so rather than discovering it afterwards.
echo "Local artefacts"
for f in "$ROOT/apps/accrual-job/.keys/signing.jwk" "$ROOT/apps/.env" "$ROOT/apps/ledger-service/ledger.sqlite"; do
  if [ -e "$f" ]; then rm -f "$f"; say "removed ${f#"$ROOT"/}"; else say "${f#"$ROOT"/} (already gone)"; fi
done

if [ "$failed" -ne 0 ]; then
  echo >&2
  echo "Something could not be removed — see the errors above. Stopping before" >&2
  echo "any terraform destroy: the managed-object type must outlive its rows." >&2
  exit 1
fi

if [ "$ALL" -eq 1 ]; then
  echo "Tenant config"
  echo "  running terraform destroy — this needs the same PINGONEAIC_* and TF_VAR_*"
  echo "  environment that apply needed."
  ( cd "$ROOT/terraform" && terraform destroy -auto-approve )
else
  echo
  echo "Tenant config left in place. To remove it too:"
  echo "  scripts/teardown.sh --all      (or: terraform -chdir=terraform destroy)"
fi
