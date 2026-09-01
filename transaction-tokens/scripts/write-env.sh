#!/usr/bin/env bash
# write-env.sh — turn `terraform output -json` into apps/.env.
#
# The apps read plain environment variables so they stay runnable without
# Terraform in front of them. The tenant URL and the three client secrets are
# NOT Terraform outputs — the hostname is customer-identifying and the
# secrets are inputs, not products — so they come from the environment, the
# same place Terraform got them.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

: "${TXNDEMO_TENANT_URL:?set it in .env, or export PINGONEAIC_TENANT_URL and re-export it as this}"
: "${TXNDEMO_WEB_CLIENT_SECRET:?set it in .env}"
: "${TXNDEMO_JOBSVC_CLIENT_SECRET:?set it in .env}"
: "${TXNDEMO_CALLER_CLIENT_SECRET:?set it in .env}"

OUT=$(cd "$ROOT/terraform" && terraform output -json)
get() { printf '%s' "$OUT" | jq -r ".$1.value"; }

TARGET="$ROOT/apps/.env"

# The internal workload credential (shared/workload.js) is generated here,
# not configured: it is a per-install stub for what production does with
# mTLS. Reuse the existing one on a re-run — rotating it while services are
# up would 401 every internal hop until all three restart.
INTERNAL_TOKEN=$(sed -n 's/^TXNDEMO_INTERNAL_TOKEN=//p' "$TARGET" 2>/dev/null | head -1)
[ -n "$INTERNAL_TOKEN" ] || INTERNAL_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-40)
cat > "$TARGET" <<ENV
# Written by scripts/write-env.sh from terraform output. Do not edit by hand
# and do not commit it — it holds secrets and the tenant hostname.
TXNDEMO_TENANT_URL=$TXNDEMO_TENANT_URL
TXNDEMO_REALM=$(get realm)

TXNDEMO_WEB_CLIENT_ID=$(get web_client_id)
TXNDEMO_WEB_CLIENT_SECRET=$TXNDEMO_WEB_CLIENT_SECRET
TXNDEMO_JOBSVC_CLIENT_ID=$(get jobsvc_client_id)
TXNDEMO_JOBSVC_CLIENT_SECRET=$TXNDEMO_JOBSVC_CLIENT_SECRET
TXNDEMO_CALLER_CLIENT_ID=$(get caller_client_id)
TXNDEMO_CALLER_CLIENT_SECRET=$TXNDEMO_CALLER_CLIENT_SECRET

# The nightly job's own IDM record — its jwt-bearer assertion's sub claim.
# Fixed in scripts/lib.sh (USER_JOBSVC), not a Terraform output: it is a
# seeded record, not tenant config.
TXNDEMO_JOBSVC_SUBJECT_ID=0a97c003-0000-4000-8000-000000000002

TXNDEMO_TRUST_DOMAIN=acme-internal
TXNDEMO_INTERNAL_TOKEN=$INTERNAL_TOKEN
TXNDEMO_PORTAL_SCOPE=$(printf '%s' "$OUT" | jq -r '.subject_scopes.value.human')
TXNDEMO_EXCHANGE_SCOPE=client:activity:write

TXNDEMO_PORTAL_PORT=${TXNDEMO_PORTAL_PORT:-9000}
TXNDEMO_ACTIVITY_API_PORT=${TXNDEMO_ACTIVITY_API_PORT:-9002}
TXNDEMO_LEDGER_PORT=${TXNDEMO_LEDGER_PORT:-9003}
TXNDEMO_ACTIVITY_API_URL=${TXNDEMO_ACTIVITY_API_URL:-http://127.0.0.1:9002}
TXNDEMO_LEDGER_URL=${TXNDEMO_LEDGER_URL:-http://127.0.0.1:9003}
ENV
echo "wrote $TARGET from terraform output"
