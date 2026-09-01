#!/usr/bin/env bash
# setup-jwtbearer.sh — the nightly job's self-sign-in credential.
#
# AM has no "self_signed subject_token, no user" token type (the draft's own
# internally-initiated flow), so the closest AIC-native analogue is a Trusted
# JWT Issuer: a realm-level signing config the job's own assertion is checked
# against (pingone-aic-manager docs/api/17-jwt-bearer-user-tokens.md). This
# is set up here rather than in Terraform because the provider has no
# TrustedJwtIssuer resource yet, and a signing keypair is closer to a runtime
# credential than declarative config.
#
# Two things this does NOT do, both worth knowing before you point it at
# anything but a sandbox:
#
#   * `aic jwt-bearer setup` ADDS the job to the realm issuer's
#     allowedSubjects; it does not reduce the list to only the job. If the
#     realm already trusts other subjects, they stay trusted. The script
#     prints the resulting list so you can see what is actually allowed.
#   * The signing key is the INSTALL's per-tenant key, shared with any other
#     jwt-bearer use of the same tenant — not a key minted for this job. A
#     real deployment gives the job its own issuer and its own key.
#
# Idempotent, including the key export: `aic jwt-bearer key export` refuses to
# overwrite, so a second run keeps the key already on disk rather than
# failing halfway through.
#
# Needs: an unlocked `aic` agent, and scripts/seed.sh to have already created
# svc-accrual-job.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

echo "Trusted JWT Issuer"
aic --no-prompt jwt-bearer setup --realm "$REALM" --username svc-accrual-job

echo "Grant type on $JOBSVC_CLIENT"
# Terraform already declares this grant type, so "already present" is the
# expected outcome and not an error. Anything else — a wrong client id, an
# expired agent, a tenant error — must surface rather than be swallowed by a
# blanket `|| true`.
if ! out=$(aic --no-prompt oauth grant add "$JOBSVC_CLIENT" \
    urn:ietf:params:oauth:grant-type:jwt-bearer --realm "$REALM" 2>&1); then
  case "$out" in
    *already*|*unchanged*|*no\ change*) say "already present" ;;
    *) printf '%s\n' "$out" >&2; exit 1 ;;
  esac
else
  say "added"
fi

# accrual-job signs its own assertion, so it needs the private key on its own
# side — exported once, held only in the app's gitignored key directory,
# never in this repo.
KEY_DIR="$ROOT/apps/accrual-job/.keys"
mkdir -p "$KEY_DIR"
# Idempotence here has to mean CONVERGENCE, not "a file exists". `aic
# jwt-bearer key export` refuses to overwrite, so the naive fix was to skip
# when the file is non-empty — which keeps a key from before a rotation. The
# tenant-side check then passes (it signs with the CLI's current key) while
# the Node job fails with invalid_grant, because its stale `kid` is no longer
# published. Compare the kid, and replace the file when it has drifted.
# `key list` marks this install's own published key with * in MINE; that is
# the one `key export` hands out. (`--out /dev/stdout` is refused — the
# command will not overwrite an existing path.)
current_kid=$(aic --no-prompt jwt-bearer key list --realm "$REALM" 2>/dev/null |
  awk '$NF=="*" {print $1}' | head -1)
local_kid=""
[ -s "$KEY_DIR/signing.jwk" ] && local_kid=$(jq -r '.kid // empty' "$KEY_DIR/signing.jwk" 2>/dev/null || true)

if [ -z "$current_kid" ]; then
  echo "error: could not read the issuer's current signing key from aic." >&2
  exit 1
elif [ "$local_kid" = "$current_kid" ]; then
  say "signing key already current (kid $current_kid) — keeping it"
else
  [ -n "$local_kid" ] && say "local key is stale (kid $local_kid) — replacing it"
  rm -f "$KEY_DIR/signing.jwk"
  aic --no-prompt jwt-bearer key export --out "$KEY_DIR/signing.jwk"
  say "signing key written to apps/accrual-job/.keys/signing.jwk (gitignored)"
fi

echo
echo "Subjects this realm's issuer will now accept an assertion for:"
aic --no-prompt jwt-bearer subjects list --realm "$REALM" | sed 's/^/  /'
echo
echo "svc-accrual-job's UUID (the assertion's sub claim): $USER_JOBSVC"
