# Shared shell helpers for seed/teardown scripts. Source, don't execute.
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
