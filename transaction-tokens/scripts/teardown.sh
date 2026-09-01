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

echo "Records"
for spec in "bravo_txn_client/$CLIENT_ACME:Acme Holdings" \
            "bravo_user/$USER_ALICE:am-alice" \
            "bravo_user/$USER_JOBSVC:svc-accrual-job"; do
  path=${spec%%:*}; label=${spec#*:}
  if quiet DELETE "$IDM/managed/$path"; then say "$label removed"; else say "$label (already gone)"; fi
done

echo "Trusted JWT Issuer"
# Leaves the realm's issuer and its key in place — both are install-wide, not
# this demo's to delete (setup-jwtbearer.sh says the same in reverse). Only
# the subject this demo added is withdrawn.
if aic --no-prompt jwt-bearer subjects rm --id "$USER_JOBSVC" --realm "$REALM" >/dev/null 2>&1; then
  say "svc-accrual-job withdrawn from allowedSubjects"
else
  say "svc-accrual-job was not an allowed subject (already gone)"
fi

echo "Local artefacts"
for f in "$ROOT/apps/accrual-job/.keys/signing.jwk" "$ROOT/apps/.env" "$ROOT/apps/ledger-service/ledger.sqlite"; do
  if [ -e "$f" ]; then rm -f "$f"; say "removed ${f#"$ROOT"/}"; else say "${f#"$ROOT"/} (already gone)"; fi
done

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
