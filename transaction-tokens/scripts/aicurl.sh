#!/usr/bin/env bash
# aicurl.sh — curl an AIC path with the running agent's bearer, any method.
#
#   scripts/aicurl.sh GET  /am/json/realms/root/realms/bravo/policies?_queryFilter=true
#   scripts/aicurl.sh POST /am/json/... --data '{"a":1}' --apiver protocol=1.0,resource=2.0
#
# Differs from pingone-aic-manager's verify-endpoint.sh only in taking a method
# and a body; the token and base-URL resolution are the same idea. The agent
# must be unlocked (`aic login`) — --no-prompt makes a locked agent fail fast
# rather than block on a password an automated caller cannot supply.
#
# `aic` resolves its tenant from `.aic/config.toml`, in the current directory
# by default but from $AIC_PROJECT when that is set. This repo has no `.aic/`,
# so AIC_PROJECT must name a pingone-aic-manager checkout that does; the
# gitignored .env sets it, and there is no sibling-path default to guess wrong.
# The tenant hostname is customer-identifying and must not land in this repo,
# which is the other reason the config stays over there.
#
# Response body is left in $AICURL_BODY (default /tmp/aicurl.body) and the HTTP
# status is printed to stderr, so a caller can jq the body without parsing.
set -euo pipefail

METHOD="${1:?usage: aicurl.sh METHOD PATH [--data JSON] [--apiver V] [curl args...]}"
REQ_PATH="${2:?missing path}"
shift 2

DATA=""
APIVER="resource=1.0"
extra=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data)   DATA="$2"; shift 2 ;;
    --apiver) APIVER="$2"; shift 2 ;;
    *)        extra+=("$1"); shift ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$HERE/../.env" ] && . "$HERE/../.env"
if [ -z "${AIC_PROJECT:-}" ]; then
  echo "error: AIC_PROJECT is not set." >&2
  echo "  Set it in $HERE/../.env to the absolute path of a" >&2
  echo "  pingone-aic-manager checkout." >&2
  exit 2
fi
export AIC_PROJECT

if [ -z "${TENANT_BASE_URL:-}" ]; then
  # `|| true`: under `set -e` + `pipefail` a failing `aic` would abort here
  # silently, before the check below could name the cause.
  TENANT_BASE_URL=$(aic --no-prompt ctx list 2>/tmp/aicurl.err | awk '$1=="*" {print $NF}') || true
fi
if [ -z "${TENANT_BASE_URL:-}" ]; then
  echo "error: no tenant base URL; check 'aic ctx current'" >&2
  if [ -s /tmp/aicurl.err ]; then sed 's/^/  /' /tmp/aicurl.err >&2; fi
  exit 2
fi

if ! TOKEN=$(aic --no-prompt whoami --token 2>/tmp/aicurl.err) || [ -z "$TOKEN" ]; then
  echo "error: no token from the agent — run 'aic login'" >&2
  if [ -s /tmp/aicurl.err ]; then sed 's/^/  /' /tmp/aicurl.err >&2; fi
  exit 3
fi

BODY="${AICURL_BODY:-/tmp/aicurl.body}"
args=(-sS -o "$BODY" -w '%{http_code}' -X "$METHOD"
      -H "Authorization: Bearer $TOKEN"
      -H "Accept: application/json"
      -H "Accept-API-Version: $APIVER")
[ -n "$DATA" ] && args+=(-H "Content-Type: application/json" --data "$DATA")

code=$(curl "${args[@]}" "${extra[@]}" "${TENANT_BASE_URL%/}${REQ_PATH}")
echo "$METHOD ${REQ_PATH%%\?*} -> HTTP $code" >&2

if jq -e . "$BODY" >/dev/null 2>&1; then jq . "$BODY"; else cat "$BODY"; echo; fi
case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac
