#!/usr/bin/env bash
# write-env.sh — turn `terraform output -json` into apps/.env.
#
# The apps read plain environment variables so they stay runnable without
# Terraform (provision.sh is still a supported path). This is the bridge: it
# takes the names Terraform actually created rather than the names anyone
# assumed, which is the whole reason the outputs exist.
#
# The tenant URL and the two client secrets are NOT Terraform outputs — the
# hostname is customer-identifying and the secrets are inputs, not products —
# so they come from the environment, the same place Terraform got them.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

: "${CAPTOKEN_TENANT_URL:?set it in .env, or export PINGONEAIC_TENANT_URL and re-export it as this}"
: "${CAPTOKEN_LOGIN_CLIENT_SECRET:?set it in .env}"
: "${CAPTOKEN_CALLER_CLIENT_SECRET:?set it in .env}"

OUT=$(cd "$ROOT/terraform" && terraform output -json)
get() { printf '%s' "$OUT" | jq -r ".$1.value"; }
join() { printf '%s' "$OUT" | jq -r ".$1.value | join(\",\")"; }

TARGET="$ROOT/apps/.env"
cat > "$TARGET" <<ENV
# Written by scripts/write-env.sh from terraform output. Do not edit by hand
# and do not commit it — it holds secrets and the tenant hostname.
CAPTOKEN_TENANT_URL=$CAPTOKEN_TENANT_URL
CAPTOKEN_REALM=$(get realm)
CAPTOKEN_POLICY_SET=$(get policy_set)
CAPTOKEN_REGISTER_TREE=$(get register_tree)
CAPTOKEN_OFFERED_ROLES=$(join offered_roles)

CAPTOKEN_LOGIN_CLIENT_ID=$(get login_client_id)
CAPTOKEN_LOGIN_CLIENT_SECRET=$CAPTOKEN_LOGIN_CLIENT_SECRET
CAPTOKEN_CALLER_CLIENT_ID=$(get caller_client_id)
CAPTOKEN_CALLER_CLIENT_SECRET=$CAPTOKEN_CALLER_CLIENT_SECRET

# Reaching ?_action=evaluate needs a service-account bearer; a realm OAuth2
# client's client_credentials token is refused even holding fr:am:*. Supply one,
# or let shop-api borrow the local aic agent's for development.
# CAPTOKEN_API_BEARER=
CAPTOKEN_AIC_PROJECT=${CAPTOKEN_AIC_PROJECT:-${AIC_PROJECT_DIR:-../../pingone-aic-manager}}

CAPTOKEN_WEB_PORT=${CAPTOKEN_WEB_PORT:-8790}
CAPTOKEN_API_PORT=${CAPTOKEN_API_PORT:-8791}
CAPTOKEN_API_URL=${CAPTOKEN_API_URL:-http://127.0.0.1:8791}
CAPTOKEN_API_AUDIENCE=${CAPTOKEN_API_AUDIENCE:-https://shop-api.demo:443}
ENV
echo "wrote $TARGET from terraform output"
