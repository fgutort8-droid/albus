#!/usr/bin/env bash
# Exercise the actual owner script with a local CLI double; no network.
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
  'migration list') printf ' 20260925140000 | |\n 20260925170000 | |\n'; if [ "${ALBUS_TEST_SEQUENCE:-0}" = 1 ]; then printf ' 20260927171142 | |\n'; fi ;;
  'functions list') printf '%s\n' '[{"slug":"breakdown","verify_jwt":true},{"slug":"grade","verify_jwt":true},{"slug":"revenuecat-webhook","verify_jwt":false}]' ;;
  'db query') printf '{"rows":[{"ownership_history_empty":true}]}\n' ;;
  *) echo 'Unexpected or mutating CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/supabase"
for script in deploy-subscriptions-2026-09-25.sh deploy-security-2026-09-27.sh; do
if [ "$script" = deploy-security-2026-09-27.sh ]; then export ALBUS_TEST_SEQUENCE=1; else export ALBUS_TEST_SEQUENCE=0; fi
PATH="$TEST_DIR/bin:$PATH" DRY_RUN=1 ALBUS_SOURCE="$ROOT" bash "$ROOT/scripts/$script" > "$TEST_DIR/output"
if grep -Eq 'db push|functions deploy|secrets' "$ALBUS_TEST_DEPLOY_LOG"; then
  echo 'Dry run reached a mutating command' >&2; exit 1
fi
grep -q 'DRY RUN FINISHED' "$TEST_DIR/output"
done
echo 'PASS: actual dry-run script called only link, migration/function lists and read-only db query; no deployment or write command reached.'
