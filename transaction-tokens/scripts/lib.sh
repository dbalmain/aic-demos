# Shared shell helpers for seed/setup scripts. Source, don't execute.
#
# Everything is addressed by a fixed id so the scripts are idempotent.
# shellcheck shell=sh
# shellcheck disable=SC2034  # sourced library; callers consume these
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# An explicitly-set AIC_PROJECT is a deliberate per-invocation override
# (`AIC_PROJECT=/elsewhere scripts/teardown.sh`). Sourcing .env would clobber
# it — the old `AIC_PROJECT_DIR` spelling got this right by accident, because
# the name .env set was not the name `aic` read.
_cli_aic_project="${AIC_PROJECT:-}"
# shellcheck disable=SC1091  # gitignored .env; not a committed source file
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
if [ -n "$_cli_aic_project" ]; then AIC_PROJECT="$_cli_aic_project"; fi
unset _cli_aic_project
if [ -z "${AIC_PROJECT:-}" ]; then
  echo "error: AIC_PROJECT is not set." >&2
  echo "  Set it in $ROOT/.env to the absolute path of a pingone-aic-manager" >&2
  echo "  checkout — the one whose \`aic ctx list\` shows your tenant." >&2
  exit 2
fi
# Absolute only. A relative path resolves against the directory you happened
# to run from, so the same command selects a different project — or none —
# depending on where you stood. The docs have always said absolute; nothing
# enforced it.
case "$AIC_PROJECT" in
  /*) ;;
  *)
    echo "error: AIC_PROJECT must be an absolute path (got '$AIC_PROJECT')." >&2
    echo "  A relative one resolves against the current directory, so the same" >&2
    echo "  command can select a different project depending on where you run it." >&2
    exit 2 ;;
esac
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

# AIC_PROJECT selects a *project*; the project's current context selects the
# *tenant*, and `aic ctx use` can move it at any time. So a token that mints
# proves the agent works, not that it is aimed where this demo expects — and
# these scripts delete records by fixed id. Refuse unless the context `aic`
# resolved is the tenant .env names.
TENANT_BASE_URL="${TENANT_BASE_URL:-$(aic --no-prompt ctx list | awk '$1=="*" {print $NF}')}"
if [ -z "$TENANT_BASE_URL" ]; then
  echo "error: no current tenant context — 'aic ctx list' marks none with '*'." >&2
  echo "  Run 'aic ctx use <name>' in $AIC_PROJECT." >&2
  exit 3
fi
if [ -z "${TXNDEMO_TENANT_URL:-}" ]; then
  echo "error: TXNDEMO_TENANT_URL is not set; cannot confirm which tenant this would touch." >&2
  echo "  Set it in $ROOT/.env to the base URL of the tenant this demo owns." >&2
  exit 2
fi
if [ "${TENANT_BASE_URL%/}" != "${TXNDEMO_TENANT_URL%/}" ]; then
  echo "error: the active aic context is not the tenant this demo is configured for." >&2
  echo "  aic ctx says : $TENANT_BASE_URL" >&2
  echo "  .env says    : $TXNDEMO_TENANT_URL" >&2
  echo "  Refusing, because these scripts write and delete by fixed id." >&2
  echo "  Run 'aic ctx use <name>' in $AIC_PROJECT, or fix TXNDEMO_TENANT_URL." >&2
  exit 4
fi
export TENANT_BASE_URL
# Lets aicurl.sh skip re-running these checks on every single request.
AIC_ENV_READY=1
export AIC_ENV_READY

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
