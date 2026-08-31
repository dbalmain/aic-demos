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
# `aic jwt-bearer setup` restricts the issuer's allowedSubjects to just the
# job's own service identity — not left blank the way a lower-environment
# default would allow, because there is no reason this demo's issuer should
# be able to mint a token for anyone else.
#
# Idempotent. Needs: an unlocked `aic` agent (in AIC_PROJECT_DIR), and
# scripts/seed.sh to have already created svc-accrual-job.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

AIC_PROJECT_DIR="${AIC_PROJECT_DIR:-$HERE/../../pingone-aic-manager}"
if [ ! -f "$AIC_PROJECT_DIR/.aic/config.toml" ]; then
  echo "error: no .aic/config.toml under AIC_PROJECT_DIR ($AIC_PROJECT_DIR)." >&2
  exit 2
fi

echo "Trusted JWT Issuer"
( cd "$AIC_PROJECT_DIR" && aic --no-prompt jwt-bearer setup --realm "$REALM" --username svc-accrual-job )

echo "Grant type on $JOBSVC_CLIENT"
( cd "$AIC_PROJECT_DIR" && aic --no-prompt oauth grant add "$JOBSVC_CLIENT" \
    urn:ietf:params:oauth:grant-type:jwt-bearer --realm "$REALM" ) || true

# accrual-job signs its own assertion, so it needs the private key on its own
# side — exported once, held only in the app's gitignored key directory,
# never in this repo.
KEY_DIR="$ROOT/apps/accrual-job/.keys"
mkdir -p "$KEY_DIR"
( cd "$AIC_PROJECT_DIR" && aic --no-prompt jwt-bearer key export --out "$KEY_DIR/signing.jwk" )
say "signing key written to apps/accrual-job/.keys/signing.jwk (gitignored)"

echo
echo "Done. svc-accrual-job's UUID for the assertion's sub claim: $USER_JOBSVC"
