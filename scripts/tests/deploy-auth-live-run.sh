#!/usr/bin/env bash
# Exercise the owner script's real run (DRY_RUN=0) with local doubles for git,
# the Supabase CLI and curl; no network. The doubles keep state, so the
# migration list changes after db push and the function list after deploy.
# Each case checks what the script did, and what it refused to do after a
# failed safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-auth-2026-10-08.sh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-auth-live-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_STATE="$TEST_DIR/state" ALBUS_TEST_SOURCE="$ROOT"
mkdir -p "$TEST_DIR/bin" "$ALBUS_TEST_STATE"

cat > "$TEST_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$ALBUS_TEST_LOG"
[ "$1" = clone ] || { echo 'Unexpected git command' >&2; exit 99; }
dest=${!#}
mkdir -p "$dest"
cp -R "$ALBUS_TEST_SOURCE/supabase" "$dest/supabase"
rm -rf "$dest/supabase/.temp"
STUB

cat > "$TEST_DIR/bin/supabase" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'supabase %s\n' "$*" >> "$ALBUS_TEST_LOG"
case "$1 $2" in
  'link --project-ref') mkdir -p supabase/.temp; printf '%s' "$3" > supabase/.temp/project-ref ;;
  'migration list')
    for f in supabase/migrations/*.sql; do
      v=$(basename "$f"); v=${v%%_*}
      if [ "$v" = 20261006120000 ] && [ ! -f "$ALBUS_TEST_STATE/pushed" ]; then
        printf '   %s |                |\n' "$v"
      else
        printf '   %s | %s |\n' "$v" "$v"
      fi
    done ;;
  'functions list')
    printf '[{"slug":"breakdown","verify_jwt":true,"version":33},{"slug":"grade","verify_jwt":true,"version":23},{"slug":"revenuecat-webhook","verify_jwt":false,"version":17}'
    if [ -f "$ALBUS_TEST_STATE/deployed" ]; then
      printf ',{"slug":"delete-account","verify_jwt":%s,"version":1,"status":"ACTIVE"}' "${ALBUS_TEST_DEPLOYED_JWT:-true}"
    fi
    printf ']\n' ;;
  'secrets list') printf '[{"name":"SUPABASE_URL","value":"00"}]\n' ;;
  'db push')
    [ -z "${ALBUS_TEST_PUSH_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/pushed" ;;
  'db query')
    # The verification query's one row; a case can make one check false.
    python3 -c '
import json,os
keys=["sync_signature","release_signature","sync_definer_path_closed","release_definer_path_closed",
 "sync_anon_closed","release_anon_closed","sync_students_allowed","release_students_allowed",
 "task_cap_trigger_on","delete_rpc_unchanged","definer_paths_closed"]
row={k: k != os.environ.get("ALBUS_TEST_FALSE_CHECK") for k in keys}
print(json.dumps({"rows":[row]}))' ;;
  'functions deploy')
    [ -z "${ALBUS_TEST_DEPLOY_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/deployed" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB

cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ALBUS_TEST_LOG"
printf '%s' "${ALBUS_TEST_HTTP_STATUS:-401}"
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

live() {
  rm -f "$ALBUS_TEST_STATE"/*; : > "$ALBUS_TEST_LOG"
  [ -z "${ALBUS_TEST_ALREADY_PUSHED:-}" ] || touch "$ALBUS_TEST_STATE/pushed"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=0 bash "$ROOT/scripts/$SCRIPT" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
}
fail() { cat "$TEST_DIR/output" >&2; echo "--- calls:" >&2; cat "$ALBUS_TEST_LOG" >&2; echo "FAIL: $1" >&2; exit 1; }
called() { grep -q -- "$1" "$ALBUS_TEST_LOG"; }
line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | head -1 | cut -d: -f1; }

# A dated script pins the exact server code it was reviewed with. Once main
# moves on, it rightly refuses to run, and there is nothing left to test.
live
if [ "$STATUS" -ne 0 ] && grep -q 'configuration differs' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: server code has changed since this one-time deployment was reviewed"
  exit 0
fi
[ "$STATUS" -eq 0 ] || fail 'the reviewed live run did not finish'
grep -q '^DONE:' "$TEST_DIR/output" || fail 'no DONE line'
push=$(line_of 'supabase db push'); query=$(line_of 'supabase db query'); deploy=$(line_of 'supabase functions deploy delete-account')
[ -n "$push" ] && [ -n "$query" ] && [ -n "$deploy" ] && [ "$push" -lt "$query" ] && [ "$query" -lt "$deploy" ] \
  || fail 'expected push, then the database checks, then the deploy'
! called 'no-verify-jwt' || fail 'delete-account was deployed without its JWT check'
[ "$(grep -c '^supabase functions deploy' "$ALBUS_TEST_LOG")" = 1 ] || fail 'a function other than delete-account was deployed'
called 'curl -s -o /dev/null' || fail 'the no-token check never ran'
grep -q 'refuses a request with no token (401)' "$TEST_DIR/output" || fail 'the 401 was not reported'
echo 'PASS: the real run applies the migration, checks the database, then deploys and checks delete-account'

ALBUS_TEST_ALREADY_PUSHED=1 live
[ "$STATUS" -eq 0 ] || fail 'a re-run after the migration was applied did not finish'
! called 'supabase db push' || fail 'a re-run pushed again'
called 'supabase functions deploy delete-account' || fail 'a re-run did not deploy'
echo 'PASS: running again after the migration was applied skips the push and still deploys'

ALBUS_TEST_FALSE_CHECK=sync_anon_closed live
[ "$STATUS" -ne 0 ] || fail 'a failed database check did not stop it'
grep -q 'database checks did not all pass, so delete-account was not deployed' "$TEST_DIR/output" || fail 'wrong reason'
grep -q 'sync_anon_closed: False' "$TEST_DIR/output" || fail 'the failed check was not shown'
! called 'supabase functions deploy' || fail 'it deployed after a failed database check'
! called 'curl' || fail 'it carried on after a failed database check'
echo 'PASS: a failed database check stops it before anything is deployed'

ALBUS_TEST_PUSH_FAILS=1 live
[ "$STATUS" -ne 0 ] && grep -q 'error applying the migration, so nothing was deployed' "$TEST_DIR/output" || fail 'a failed push was not stopped plainly'
! called 'supabase functions deploy' || fail 'it deployed after a failed push'
echo 'PASS: a failed push stops it before anything is deployed'

ALBUS_TEST_DEPLOY_FAILS=1 live
[ "$STATUS" -ne 0 ] && grep -q 'delete-account did not deploy; running this again is safe' "$TEST_DIR/output" || fail 'a failed deploy was not stopped plainly'
echo 'PASS: a failed deploy stops it and says a re-run is safe'

ALBUS_TEST_DEPLOYED_JWT=false live
[ "$STATUS" -ne 0 ] && grep -q 'not live with its JWT check on' "$TEST_DIR/output" || fail 'a deploy without the JWT check was not caught'
! called 'curl' || fail 'it carried on after a deploy without the JWT check'
echo 'PASS: a deploy that comes up without its JWT check stops it'

ALBUS_TEST_HTTP_STATUS=200 live
[ "$STATUS" -ne 0 ] && grep -q 'answered 200 instead of refusing a request with no token' "$TEST_DIR/output" || fail 'a function that accepts no token was not caught'
! grep -q '^DONE:' "$TEST_DIR/output" || fail 'it said DONE after the no-token check failed'
echo 'PASS: a function that answers without a token stops it'
echo "PASS: $SCRIPT real run, with every safeguard failing in turn."
