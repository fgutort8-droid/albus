#!/usr/bin/env bash
# Exercise the actual owner script's dry run with a local CLI double; no network.
#
# The double lists every local migration as applied except those named in
# ALBUS_TEST_PENDING, in one of three table styles: "|", "│" (box drawing) or
# an unreadable one, plus optional remote-only versions. It reports the live
# functions and secret names it is told to. The dry run must preview the
# reviewed state, stop on anything else, and never reach a command that writes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-auth-2026-10-08.sh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-auth-deploy-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_DEPLOY_LOG="$TEST_DIR/calls"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/supabase" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ALBUS_TEST_DEPLOY_LOG"
case "$1 $2" in
  'link --project-ref') mkdir -p supabase/.temp; printf '%s' "$3" > supabase/.temp/project-ref ;;
  'migration list')
    case "${ALBUS_TEST_STYLE:-pipe}" in
      pipe) sep='|' ;;
      box) sep='│' ;;
      garbled) sep='¦' ;;
    esac
    for f in supabase/migrations/*.sql; do
      v=$(basename "$f"); v=${v%%_*}
      if [[ " ${ALBUS_TEST_PENDING:-} " == *" $v "* ]]; then
        printf '   %s %s                %s\n' "$v" "$sep" "$sep"
      else
        printf '   %s %s %s %s\n' "$v" "$sep" "$v" "$sep"
      fi
    done
    for v in ${ALBUS_TEST_REMOTE_ONLY:-}; do
      printf '                  %s %s %s\n' "$sep" "$v" "$sep"
    done ;;
  'functions list')
    printf '[{"slug":"breakdown","verify_jwt":true,"version":33},{"slug":"grade","verify_jwt":true,"version":23},{"slug":"revenuecat-webhook","verify_jwt":false,"version":17}%s]\n' \
      "${ALBUS_TEST_DELETE_FUNCTION:-}" ;;
  'secrets list')
    printf '['
    first=1
    for name in SUPABASE_URL ${ALBUS_TEST_SECRETS:-}; do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"name":"%s","value":"0000000000000000000000000000000000000000000000000000000000000000"}' "$name"
    done
    printf ']\n' ;;
  *) echo 'Unexpected or mutating CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/supabase"

preview() {
  : > "$ALBUS_TEST_DEPLOY_LOG"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=1 ALBUS_SOURCE="${SOURCE:-$ROOT}" \
    bash "$ROOT/scripts/$SCRIPT" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -Eq 'db push|db query|functions deploy|secrets set|secrets unset' "$ALBUS_TEST_DEPLOY_LOG"; then
    cat "$ALBUS_TEST_DEPLOY_LOG" >&2; echo "$SCRIPT: dry run reached a writing command" >&2; exit 1
  fi
}
expect_pass() {
  [ "$STATUS" -eq 0 ] || { cat "$TEST_DIR/output" >&2; echo "FAIL: $1" >&2; exit 1; }
  grep -q 'DRY RUN FINISHED' "$TEST_DIR/output" || { cat "$TEST_DIR/output" >&2; echo "FAIL: $1 (not finished)" >&2; exit 1; }
}
expect_stop() {
  [ "$STATUS" -ne 0 ] || { cat "$TEST_DIR/output" >&2; echo "FAIL: $1 did not stop" >&2; exit 1; }
  grep -q "$2" "$TEST_DIR/output" || { cat "$TEST_DIR/output" >&2; echo "FAIL: $1 stopped for the wrong reason" >&2; exit 1; }
  ! grep -q 'DRY RUN FINISHED' "$TEST_DIR/output" || { echo "FAIL: $1 finished anyway" >&2; exit 1; }
}

# A dated script pins the exact server code it was reviewed with. Once main
# moves on, it rightly refuses to run, and there is nothing left to test.
export ALBUS_TEST_PENDING=20261006120000 ALBUS_TEST_STYLE=pipe
preview
if [ "$STATUS" -ne 0 ] && grep -q 'configuration differs' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: server code has changed since this one-time deployment was reviewed"
  exit 0
fi
expect_pass "'|' preview"
grep -q 'Pending migrations: 20261006120000' "$TEST_DIR/output" || { cat "$TEST_DIR/output" >&2; echo 'FAIL: pending migration not read' >&2; exit 1; }
grep -q 'delete-account: not live yet; this deploys it' "$TEST_DIR/output" || { echo 'FAIL: new function not reported' >&2; exit 1; }
grep -q 'APPLE_PRIVATE_KEY: not set yet' "$TEST_DIR/output" || { echo 'FAIL: missing secret not reported' >&2; exit 1; }
echo "PASS: '|' list previews the one pending migration and the new function"

ALBUS_TEST_STYLE=box preview
expect_pass "'│' preview"
grep -q 'Pending migrations: 20261006120000' "$TEST_DIR/output" || { echo "FAIL: '│' list was not read as pending" >&2; exit 1; }
echo "PASS: '│' list reads the same"

ALBUS_TEST_STYLE=garbled preview
expect_stop 'an unreadable migration list' 'could not read the migration list'
echo 'PASS: an unreadable migration list stops it'

ALBUS_TEST_PENDING='20261001190000 20261006120000' preview
expect_stop 'a database behind the reviewed state' 'the live database is not at 20261001190000'
echo 'PASS: a database not at the reviewed starting point stops it'

ALBUS_TEST_REMOTE_ONLY=20261007000000 preview
expect_stop 'an unknown remote migration' 'unrecognized remote migrations: 20261007000000'
echo 'PASS: a migration only the server knows stops it'

ALBUS_TEST_PENDING='' preview
expect_pass 'a run after the migration was applied'
grep -q 'Pending migrations: none' "$TEST_DIR/output" || { echo 'FAIL: an applied migration was not read as applied' >&2; exit 1; }
echo 'PASS: running again after the migration was applied still previews'

NEWER="$TEST_DIR/newer"
mkdir -p "$NEWER"
cp -R "$ROOT/supabase" "$NEWER/supabase"
rm -rf "$NEWER/supabase/.temp"
printf 'select 1;\n' > "$NEWER/supabase/migrations/20261009000000_unreviewed.sql"
SOURCE="$NEWER" ALBUS_TEST_PENDING='' preview
expect_stop 'a newer migration main and the server both have' 'main has a migration newer than the reviewed one (20261009000000)'
echo 'PASS: a newer migration already on the server stops it, though nothing is pending'

SOURCE="$NEWER" ALBUS_TEST_PENDING='20261006120000 20261009000000' preview
expect_stop 'a newer migration only main has' 'unexpected pending migrations: 20261006120000 20261009000000'
echo 'PASS: a newer pending migration stops it'

ALBUS_TEST_DELETE_FUNCTION=',{"slug":"delete-account","verify_jwt":false,"version":1}' preview
expect_stop 'delete-account live without its JWT check' 'already live without its JWT check'
echo 'PASS: a live delete-account without its JWT check stops it'

ALBUS_TEST_SECRETS='APPLE_TEAM_ID APPLE_KEY_ID APPLE_PRIVATE_KEY APPLE_CLIENT_ID' preview
expect_pass 'all Apple secrets set'
grep -q 'All four Apple secrets are set.' "$TEST_DIR/output" || { echo 'FAIL: set secrets not reported' >&2; exit 1; }
! grep -q '0000000000000000' "$TEST_DIR/output" || { echo 'FAIL: a secret digest was printed' >&2; exit 1; }
echo 'PASS: secret names are reported, never their digests'

SOURCE="$TEST_DIR/source"
mkdir -p "$SOURCE"
cp -R "$ROOT/supabase" "$SOURCE/supabase"
rm -rf "$SOURCE/supabase/.temp"
printf '\n// changed source\n' >> "$SOURCE/supabase/functions/delete-account/handler.ts"
SOURCE="$SOURCE" preview
expect_stop 'a changed function' 'configuration differs'
echo 'PASS: a changed function stops it'
echo "PASS: $SCRIPT dry run called only link, the migration, function and secret-name lists; nothing that writes."
