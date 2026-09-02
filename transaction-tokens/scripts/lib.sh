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

# `aic` roots at the current directory unless AIC_PROJECT (or --project) names
# a different one. This repo has no `.aic/`, so AIC_PROJECT must point at a
# pingone-aic-manager checkout that does; it is set in .env. There is
# deliberately no sibling-path default: `aic` treats a project directory that
# is not one as an error rather than falling back to the cwd, so a guessed
# path can only turn that clear failure into a puzzling one. The tenant
# hostname is customer-identifying, which is the other reason the config lives
# over there rather than in this repo.
if [ -z "${AIC_PROJECT:-}" ]; then
  echo "error: AIC_PROJECT is not set." >&2
  echo "  Set it in $ROOT/.env to the absolute path of a pingone-aic-manager" >&2
  echo "  checkout — the one whose \`aic ctx list\` shows your tenant." >&2
  exit 2
fi
export AIC_PROJECT

# Fail here, with the remedy, rather than three curl calls later with a 401.
# Report aic's own message rather than a guess: it distinguishes a locked agent
# from an AIC_PROJECT naming a directory that is not a project, and this check
# used to blame the former for both.
if ! err=$(aic --no-prompt whoami --token 2>&1 >/dev/null); then
  echo "error: aic could not mint a token." >&2
  if [ -n "$err" ]; then printf '  %s\n' "$err" >&2; fi
  echo "  If the agent is locked, run: aic login" >&2
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
