#!/usr/bin/env bash
# Exercise the actual owner scripts with a local CLI double; no network.
#
# The double lists every local migration as applied except the ones named in
# ALBUS_TEST_PENDING, in one of three table styles: "|", "│" (box drawing) or
# an unreadable one. The first two must preview normally. The unreadable one
# must stop before anything else happens: a list the script cannot read must
# never look like "nothing pending".
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-deploy-test.XXXXXX")
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
    done ;;
  'functions list') printf '%s\n' '[{"slug":"breakdown","verify_jwt":true},{"slug":"grade","verify_jwt":true},{"slug":"revenuecat-webhook","verify_jwt":false}]' ;;
  'db query') printf '{"rows":[{"ownership_history_empty":true}]}\n' ;;
  *) echo 'Unexpected or mutating CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/supabase"

preview() {
  : > "$ALBUS_TEST_DEPLOY_LOG"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=1 ALBUS_SOURCE="$ROOT" \
    bash "$ROOT/scripts/$1" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -Eq 'db push|functions deploy|secrets' "$ALBUS_TEST_DEPLOY_LOG"; then
    echo "$1: dry run reached a mutating command" >&2; exit 1
  fi
}

for script in deploy-subscriptions-2026-09-25.sh deploy-security-2026-09-27.sh; do
  if [ "$script" = deploy-security-2026-09-27.sh ]; then
    export ALBUS_TEST_PENDING='20260925140000 20260925170000 20260927171142'
  else
    export ALBUS_TEST_PENDING='20260925140000 20260925170000'
  fi

  export ALBUS_TEST_STYLE=pipe
  preview "$script"
  # These dated scripts pin the exact server code they were reviewed with.
  # Once main moves on, the script rightly refuses to run and there is
  # nothing left to test. That must not fail every later pull request.
  if [ "$STATUS" -ne 0 ] && grep -q 'configuration differs' "$TEST_DIR/output"; then
    echo "SKIP $script: server code has changed since this one-time deployment was reviewed"
    continue
  fi
  [ "$STATUS" -eq 0 ] || { cat "$TEST_DIR/output" >&2; echo "$script: '|' preview failed" >&2; exit 1; }
  grep -q 'DRY RUN FINISHED' "$TEST_DIR/output"

  export ALBUS_TEST_STYLE=box
  preview "$script"
  [ "$STATUS" -eq 0 ] || { cat "$TEST_DIR/output" >&2; echo "$script: '│' preview failed" >&2; exit 1; }
  grep -Eq 'Pending migrations?: 20260925140000' "$TEST_DIR/output" \
    || { cat "$TEST_DIR/output" >&2; echo "$script: '│' list was not read as pending" >&2; exit 1; }

  export ALBUS_TEST_STYLE=garbled
  preview "$script"
  [ "$STATUS" -ne 0 ] || { echo "$script: an unreadable migration list did not stop the script" >&2; exit 1; }
  grep -q 'could not read the migration list' "$TEST_DIR/output" \
    || { cat "$TEST_DIR/output" >&2; echo "$script: stopped for the wrong reason" >&2; exit 1; }
  if grep -q 'db query' "$ALBUS_TEST_DEPLOY_LOG"; then
    echo "$script: carried on past an unreadable migration list" >&2; exit 1
  fi
  echo "PASS $script: reads '|' and '│' lists, stops on an unreadable one"
done
echo 'PASS: actual dry-run scripts called only link, migration/function lists and read-only db query; no deployment or write command reached.'
