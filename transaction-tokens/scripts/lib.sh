# Shared shell helpers for seed/setup scripts. Source, don't execute.
#
# Everything is addressed by a fixed id so the scripts are idempotent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

REALM="${TXNDEMO_REALM:-bravo}"
AM="/am/json/realms/root/realms/$REALM"
IDM="/openidm"
AGENT_V="protocol=2.1,resource=1.0"

# `aic` resolves its tenant from a project directory. It reads the cwd by
# default, but honours AIC_PROJECT, so every script here exports that once
# instead of wrapping each call in a subshell `cd` — which is what these
# scripts used to do, inconsistently (aicurl.sh and setup-jwtbearer.sh had
# two different, and one wrong, default paths). The tenant hostname is
# customer-identifying, which is the other reason the config stays over
# there rather than in this repo.
: "${AIC_PROJECT:=${AIC_PROJECT_DIR:-$ROOT/../../pingone-aic-manager}}"
if [ ! -f "$AIC_PROJECT/.aic/config.toml" ]; then
  echo "error: no .aic/config.toml under AIC_PROJECT ($AIC_PROJECT)." >&2
  echo "  Point AIC_PROJECT at a pingone-aic-manager checkout that has one." >&2
  exit 2
fi
export AIC_PROJECT

# Fail here, with the remedy, rather than three curl calls later with a 401.
if ! aic --no-prompt whoami --token >/dev/null 2>&1; then
  echo "error: the aic agent is locked or not running. Run: aic login" >&2
  exit 3
fi

# Fixed ids. Managed objects must be UUIDs (IDM rejects a slug for a user) —
# the client fixture is the exception, since bravo_txn_client is a custom
# type with no such constraint, and a readable id is worth keeping.
USER_ALICE=0a97c003-0000-4000-8000-000000000001
USER_JOBSVC=0a97c003-0000-4000-8000-000000000002
CLIENT_ACME=client-4471

WEB_CLIENT="${TXNDEMO_WEB_CLIENT_ID:-TxnDemo_web}"
JOBSVC_CLIENT="${TXNDEMO_JOBSVC_CLIENT_ID:-TxnDemo_jobsvc}"
CALLER_CLIENT="${TXNDEMO_CALLER_CLIENT_ID:-TxnDemo_caller}"

aic_call() { "$HERE/aicurl.sh" "$@"; }
quiet()    { "$HERE/aicurl.sh" "$@" >/dev/null 2>&1; }
say()      { printf '  %s\n' "$*"; }
