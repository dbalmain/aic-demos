#!/usr/bin/env bash
# reset-password.sh — force one seeded identity's password to the value in
# .env, for the case seed.sh deliberately will not handle.
#
# seed.sh never re-sends a password on a re-run, because the realm's password
# history rejects re-setting the one already stored. That is right for the
# normal case and wrong for the one where the record survives from an earlier
# install with a DIFFERENT password: .env then looks correct and sign-in
# fails. This script is the explicit way out, kept separate so that resetting
# a credential is never something a routine `seed.sh` does behind your back.
#
#   scripts/reset-password.sh am-alice
#   scripts/reset-password.sh svc-accrual-job
#
# The realm keeps a password history and refuses a value already in it, so
# re-setting the CURRENT password comes back 403 — a no-op that reads like a
# failure. Verified 2026-09-01: PATCH /password with the stored value is 403;
# with a fresh one it is 200. If you get the 403, either the password is
# already what .env says (nothing to do) or you need a value the realm has
# not seen before.
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

who=${1:-}
case "$who" in
  am-alice)        id=$USER_ALICE;  password=${TXNDEMO_ALICE_PASSWORD:-} ;;
  svc-accrual-job) id=$USER_JOBSVC; password=${TXNDEMO_JOBSVC_PASSWORD:-} ;;
  *) echo "usage: $0 am-alice|svc-accrual-job" >&2; exit 2 ;;
esac
[ -n "$password" ] || { echo "error: no password for $who in .env" >&2; exit 2; }

if aic_call PATCH "$IDM/managed/bravo_user/$id" --data "$(jq -nc --arg p "$password" \
    '[{operation:"replace",field:"/password",value:$p}]')" >/dev/null 2>&1; then
  say "$who password set from .env"
else
  echo "  refused (403 is the realm's password history: this value has been used" >&2
  echo "  before, possibly as the current one). Try signing in first; if that also" >&2
  echo "  fails, put a password the realm has never seen in .env and re-run." >&2
  exit 1
fi
