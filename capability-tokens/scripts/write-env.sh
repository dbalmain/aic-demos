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
# shellcheck disable=SC1091  # gitignored .env; not a committed source file
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

: "${CAPTOKEN_TENANT_URL:?set it in .env, or export PINGONEAIC_TENANT_URL and re-export it as this}"
: "${CAPTOKEN_LOGIN_CLIENT_SECRET:?set it in .env}"
: "${CAPTOKEN_CALLER_CLIENT_SECRET:?set it in .env}"

# shop-api needs a service-account bearer to reach ?_action=evaluate. There
# are two ways to supply one, and requiring the second unconditionally broke
# the first: CAPTOKEN_API_BEARER is a fixed bearer the app prefers and which
# needs no `aic` at all, and CAPTOKEN_AIC_PROJECT is the development shortcut
# that borrows the local agent's. Demand exactly one of them.
if [ -z "${CAPTOKEN_API_BEARER:-}" ]; then
  if [ -z "${AIC_PROJECT:-}" ]; then
    echo "error: neither CAPTOKEN_API_BEARER nor AIC_PROJECT is set." >&2
    echo "  shop-api needs a service-account bearer for the PDP. Set one in" >&2
    echo "  $ROOT/.env: a fixed CAPTOKEN_API_BEARER, or AIC_PROJECT pointing at" >&2
    echo "  a pingone-aic-manager checkout to borrow the local agent's." >&2
    exit 2
  fi
  # `cd` succeeding proves the path exists, not that it is an AIC project —
  # AIC_PROJECT=/tmp used to be written into apps/.env and fail later, at the
  # app's first policy call. Ask `aic` instead; it is the authority.
  if ! err=$(AIC_PROJECT="$AIC_PROJECT" aic --no-prompt ctx current 2>&1 >/dev/null); then
    echo "error: AIC_PROJECT is not a usable AIC project." >&2
    if [ -n "$err" ]; then printf '  %s\n' "$err" >&2; fi
    exit 2
  fi
fi
# apps/.env is resolved against the app's cwd, not this directory, so write an
# absolute path. Empty when a fixed CAPTOKEN_API_BEARER is in use and no
# project was configured — pdp-credential.js prefers the bearer and never
# looks at this.
CAPTOKEN_AIC_PROJECT=""
if [ -n "${AIC_PROJECT:-}" ]; then
  if ! CAPTOKEN_AIC_PROJECT=$(cd "$AIC_PROJECT" 2>/dev/null && pwd); then
    echo "error: AIC_PROJECT=$AIC_PROJECT is not a directory." >&2
    exit 2
  fi
fi

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
CAPTOKEN_AIC_PROJECT=$CAPTOKEN_AIC_PROJECT

CAPTOKEN_WEB_PORT=${CAPTOKEN_WEB_PORT:-8790}
CAPTOKEN_API_PORT=${CAPTOKEN_API_PORT:-8791}
CAPTOKEN_API_URL=${CAPTOKEN_API_URL:-http://127.0.0.1:8791}
CAPTOKEN_API_AUDIENCE=${CAPTOKEN_API_AUDIENCE:-https://shop-api.demo:443}
ENV
echo "wrote $TARGET from terraform output"
