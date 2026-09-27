#!/usr/bin/env bash
# Runs the CI gates on this machine.
#
# Not a convenience: GitHub Actions has been refusing to start jobs since the
# account's Actions allowance ran out on 22 Aug 2026, so every check on every
# PR since has been red for a reason that has nothing to do with the code. Six
# days of meaningless red trains you to ignore the one that matters.
#
# Everything here mirrors .github/workflows/ci.yml. When that file changes,
# change this one. The macOS-only jobs are skipped unless Xcode is present.
#
#   scripts/ci-local.sh            # the cheap guards plus the fast suites
#   scripts/ci-local.sh --full     # adds the iOS build (slow)
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
hdr()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

hdr "No secrets committed"
PATTERN='sb_secret_[A-Za-z0-9]{20,}|sbp_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|-----BEGIN (EC |RSA )?PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{30,}'
# Tracked files only. CI scans a fresh checkout, which by definition contains
# nothing gitignored — scanning the working tree instead finds your real .env
# and prints your live keys to the terminal, which is a worse outcome than the
# one it is guarding against.
if git ls-files -z | grep -zZv '^\.env\.example$' \
     | xargs -0 grep -EnI "$PATTERN" 2>/dev/null; then
  bad "a live credential appears to be committed — rotate it, then remove it"
else
  pass "clean (tracked files only)"
fi

hdr "Every table has RLS"
rls=0
for f in supabase/migrations/*.sql; do
  while read -r t; do
    [ -z "$t" ] && continue
    grep -qEi "alter table (only )?public\.${t}\b[^;]*enable row level security" "$f" && continue
    { grep -q "enable row level security" "$f" && grep -qE "'${t}'" "$f"; } && continue
    bad "$f: table '$t' is created but never has RLS enabled"; rls=1
  done < <(grep -oE "create table (if not exists )?public\.[a-z_]+" "$f" | sed -E "s/.*public\.//")
done
[ "$rls" -eq 0 ] && pass "every created table has RLS"

hdr "Migrations are append-only"
base=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
if [ -z "$base" ]; then
  pass "no origin/main to compare against — skipped"
else
  changed=$(git diff --name-only --diff-filter=MD "$base"...HEAD -- supabase/migrations || true)
  if [ -n "$changed" ]; then bad "applied migrations modified or deleted:"; echo "$changed"
  else pass "append-only respected"; fi
fi

hdr "Edge function tests"
if command -v deno >/dev/null; then
  ( cd supabase/functions && deno task check >/dev/null 2>&1 && deno task lint >/dev/null 2>&1 \
    && deno task test >/dev/null 2>&1 ) && pass "check, lint and test" || bad "deno gate failed"
else
  pass "deno not installed — skipped"
fi

hdr "Database security tests"
if command -v supabase >/dev/null && supabase status >/dev/null 2>&1; then
  supabase test db --local >/dev/null 2>&1 \
    && scripts/security-concurrency-local.sh >/dev/null 2>&1 \
    && pass "pgTAP policy checks plus real multi-connection races" \
    || bad "database security gate failed"
else
  bad "local Supabase is not running — database security was not verified"
fi

hdr "Core logic tests"
if command -v swift >/dev/null; then
  ( cd ios/AlbusCore && swift test >/dev/null 2>&1 ) && pass "swift test" || bad "swift test failed"
else
  pass "swift not installed — skipped"
fi

if [ "${1:-}" = "--full" ]; then
  hdr "iOS build and tests"
  if command -v xcodebuild >/dev/null; then
    ( cd ios && xcodegen generate --spec project.yml >/dev/null 2>&1 \
      && xcodebuild test -onlyUsePackageVersionsFromResolvedFile -scheme Albus -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           -skip-testing:AlbusUITests >/dev/null 2>&1 ) \
      && pass "build and unit tests" || bad "iOS build or tests failed"
  else
    pass "xcodebuild not installed — skipped"
  fi
fi

printf '\n'
[ "$fail" -eq 0 ] && printf '\033[32mall gates pass\033[0m\n' || printf '\033[31mgates failed\033[0m\n'
exit "$fail"
