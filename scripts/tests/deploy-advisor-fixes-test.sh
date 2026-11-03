#!/usr/bin/env bash
# Exercise the owner's 3 Nov security-fix script, preview and real run, with
# local doubles for git and the Supabase CLI; no network. The CLI double keeps
# state, so the migration list and the database's answers change after db push.
# Each case checks what the script did, and what it refused to do after a
# failed safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-advisor-fixes-2026-11-03.sh
CHANGE=20261028120000
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-advisor-fixes-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_STATE="$TEST_DIR/state" ALBUS_TEST_SOURCE="$ROOT"
export ALBUS_TTY=/dev/null
# A stand-in built at run time, so nothing token-shaped sits in the repository.
TOKEN="sbp_$(printf '%040d' 7)"
mkdir -p "$TEST_DIR/bin" "$ALBUS_TEST_STATE"

cat > "$TEST_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "$ALBUS_TEST_LOG"
[ "$1" = clone ] || { echo 'Unexpected git command' >&2; exit 99; }
dest=${!#}
mkdir -p "$dest"
cp -R "${ALBUS_TEST_SOURCE_OVERRIDE:-$ALBUS_TEST_SOURCE}/supabase" "$dest/supabase"
rm -rf "$dest/supabase/.temp"
STUB

cat > "$TEST_DIR/bin/supabase" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != --version ] || { echo "${ALBUS_TEST_CLI_VERSION:-2.122.0}"; exit 0; }
printf 'supabase %s\n' "$*" >> "$ALBUS_TEST_LOG"
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo 'no token reached the CLI' >&2; exit 98; }
if env | grep '^SUPABASE_' | grep -qv '^SUPABASE_ACCESS_TOKEN='; then echo 'a stray SUPABASE_ setting reached the CLI' >&2; exit 97; fi
case "$1 ${2:-}" in
  'link --project-ref')
    [ -z "${ALBUS_TEST_LINK_FAILS:-}" ] || exit 1
    mkdir -p supabase/.temp; printf '%s' "${ALBUS_TEST_LINKED_REF:-$3}" > supabase/.temp/project-ref ;;
  'migration list')
    [[ " $* " == *" --output-format json "* ]] || { echo 'the migration list must be asked for as JSON' >&2; exit 96; }
    python3 - <<'PY'
import glob,json,os
state=os.environ['ALBUS_TEST_STATE']; style=os.environ.get('ALBUS_TEST_STYLE','json')
pending=set(os.environ.get('ALBUS_TEST_PENDING','20261028120000').split())
pushed=os.path.exists(state+'/pushed') and not os.environ.get('ALBUS_TEST_PUSH_NOOP')
rows=[]
for f in sorted(glob.glob('supabase/migrations/*.sql')):
    v=os.path.basename(f).split('_')[0]
    applied=pushed or v not in pending
    rows.append({'local':v,'remote':v if applied else '','time':v})
rows+=[{'local':'','remote':v,'time':v} for v in os.environ.get('ALBUS_TEST_REMOTE_ONLY','').split()]
if style=='garbled': print('Local | Remote | Time (UTC)')
else: print(json.dumps({'migrations':rows,'message':'Migrations listed'}))
PY
    ;;
  'db push')
    [[ " $* " == *" --yes "* ]] || { echo 'db push must not wait for an answer' >&2; exit 95; }
    [ -z "${ALBUS_TEST_PUSH_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/pushed" ;;
  'db query')
    [ -z "${ALBUS_TEST_QUERY_FAILS:-}" ] || exit 1
    file=; prev=
    for a in "$@"; do [ "$prev" = --file ] && file=$a; prev=$a; done
    [ -n "$file" ] || { echo 'the db query double expects --file' >&2; exit 94; }
    # Read-only and one statement, as Supabase CLI 2.122 requires.
    [ "$(head -1 "$file")" = select ] && [ "$(tr -cd ';' < "$file" | wc -c | tr -d ' ')" = 1 ] \
      || { echo 'the query must be one plain select' >&2; exit 93; }
    python3 - <<'PY'
import json,os
pushed=os.path.exists(os.environ['ALBUS_TEST_STATE']+'/pushed') and not os.environ.get('ALBUS_TEST_PUSH_NOOP')
row={'graphql_on': (not pushed) or bool(os.environ.get('ALBUS_TEST_GRAPHQL_STAYS')),
     'plans_readable': not os.environ.get('ALBUS_TEST_PLANS_CLOSED'),
     'own_functions_callable': not (os.environ.get('ALBUS_TEST_FUNCTIONS_CLOSED') and (pushed or not os.environ.get('ALBUS_TEST_CLOSED_AFTER_PUSH')))}
shape=os.environ.get('ALBUS_TEST_QUERY_SHAPE','')
if shape=='missing': del row['plans_readable']
if shape=='text': row['graphql_on']='false'
if shape=='two-rows': print(json.dumps({'rows':[row,row]}))
elif shape=='plain-array': print(json.dumps([row]))
else: print(json.dumps({'boundary':'x','rows':[row],'warning':'untrusted data'}))
PY
    ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase"

run() { # DRY_RUN value
  rm -f "$ALBUS_TEST_STATE"/*; : > "$ALBUS_TEST_LOG"
  [ -z "${ALBUS_TEST_PRESET_PUSHED:-}" ] || touch "$ALBUS_TEST_STATE/pushed"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$1 bash "$ROOT/scripts/$SCRIPT" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -q "$TOKEN" "$TEST_DIR/output" "$ALBUS_TEST_LOG"; then echo 'FAIL: the access token reached the output or a command line' >&2; exit 1; fi
}
fail() { cat "$TEST_DIR/output" >&2; echo "--- calls:" >&2; cat "$ALBUS_TEST_LOG" >&2; echo "FAIL: $1" >&2; exit 1; }
called() { grep -q -- "$1" "$ALBUS_TEST_LOG"; }
line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | head -1 | cut -d: -f1; }
expect_pass() { [ "$STATUS" -eq 0 ] || fail "$1"; grep -q -- "$2" "$TEST_DIR/output" || fail "$1 (no '$2')"; }
expect_stop() {
  [ "$STATUS" -ne 0 ] || fail "$1 did not stop"
  grep -q -- "$2" "$TEST_DIR/output" || fail "$1 stopped for the wrong reason (wanted '$2')"
  ! grep -q -E '^(DRY RUN FINISHED|DONE:)' "$TEST_DIR/output" || fail "$1 finished anyway"
}
no_push() { ! called 'db push' || fail "$1: the change was applied"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN

# A dated script pins the database changes it was reviewed with. Once main
# moves on, it rightly refuses to run, and there is nothing left to test.
run 1
if [ "$STATUS" -ne 0 ] && grep -q 'differ from what was reviewed' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: the database changes have moved on since this one-time fix was reviewed"
  exit 0
fi
expect_pass 'the preview' 'DRY RUN FINISHED'
grep -q "Pending: $CHANGE (switches GraphQL off)" "$TEST_DIR/output" || fail 'the pending change was not named'
grep -q 'Now: graphql_on=yes plans_readable=yes own_functions_callable=yes' "$TEST_DIR/output" || fail 'the state before was not shown'
grep -q "\[dry run\] would apply $CHANGE" "$TEST_DIR/output" || fail 'the preview did not say what it would do'
no_push 'the preview'
! grep -q -v -E '^(git clone|supabase (link|migration list|db query) )' "$ALBUS_TEST_LOG" || fail 'the preview ran something other than reads'
echo "PASS: the preview names the one pending change and reads only"

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 1 ] || fail 'expected exactly one prompt'
grep -q -- ' -s ' <<<"$reads" || fail 'the prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'the prompt hides its own question'
echo 'PASS: the token prompt hides what is typed and shows its question'

run 0
expect_pass 'the real run' 'DONE: GraphQL is off'
grep -q 'After: graphql_on=no plans_readable=yes own_functions_callable=yes' "$TEST_DIR/output" || fail 'the state after was not shown'
[ "$(grep -c 'db push' "$ALBUS_TEST_LOG")" = 1 ] || fail 'the change should be applied exactly once'
push=$(line_of 'db push'); before=$(line_of 'db query'); after=$(grep -n 'db query' "$ALBUS_TEST_LOG" | tail -1 | cut -d: -f1)
link=$(line_of 'supabase link'); list=$(line_of 'migration list')
[ "$link" -lt "$list" ] && [ "$list" -lt "$push" ] && [ "$before" -lt "$push" ] && [ "$push" -lt "$after" ] \
  || fail 'expected link, list and a read before the push, and a read after it'
! called 'functions deploy' && ! called 'secrets' || fail 'it touched functions or secrets'
echo 'PASS: the real run reads, applies the one change once, then checks it'

ALBUS_TEST_PRESET_PUSHED=1 run 0
expect_pass 'running it again' 'DONE: GraphQL is off'
grep -q "The change $CHANGE is already applied." "$TEST_DIR/output" || fail 'an applied change was not recognised'
no_push 'running it again'
ALBUS_TEST_PRESET_PUSHED=1 run 1
expect_pass 'a preview once applied' 'DRY RUN FINISHED'
! grep -q 'would apply' "$TEST_DIR/output" || fail 'a preview once applied offered to apply again'
echo 'PASS: once applied, a run only checks'

ALBUS_TEST_CLI_VERSION=2.98.2 run 0
expect_stop 'an old Supabase CLI' 'needs 2.117 or newer'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'an old CLI was used'
SUPABASE_ACCESS_TOKEN="$TOKEN$TOKEN" run 0
expect_stop 'a token pasted twice' 'paste it once'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a malformed token was used'
SUPABASE_ACCESS_TOKEN='' run 0
expect_stop 'no token, and no terminal to ask in' 'could not ask for the access token'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'the CLI ran without a token'
SUPABASE_PROJECT_ID=ssvehwhblgqtvqkfbkbj SUPABASE_DB_PASSWORD=x run 0
expect_pass 'stray SUPABASE_ settings in the shell' 'DONE: GraphQL is off'
ALBUS_TEST_LINK_FAILS=1 run 0
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
no_push 'a refused link'
ALBUS_TEST_LINKED_REF=ssvehwhblgqtvqkfbkbj run 0
expect_stop 'a link that lands on another project' 'unexpected project reference'
no_push 'a link to another project'
echo 'PASS: an old CLI, a bad or missing token, or a refused or wrong link stops it; stray settings are dropped'

mkdir -p "$TEST_DIR/changed"
cp -R "$ROOT/supabase" "$TEST_DIR/changed/supabase"
printf '\n-- drift\n' >> "$TEST_DIR/changed/supabase/migrations/${CHANGE}_security_advisor_fixes.sql"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a changed migration on main' 'differ from what was reviewed'
! called 'supabase ' || fail 'changed database changes reached the CLI'
printf 'select 1;\n' > "$TEST_DIR/changed/supabase/migrations/29991231000000_extra.sql"
git -C "$ROOT" show "HEAD:supabase/migrations/${CHANGE}_security_advisor_fixes.sql" > "$TEST_DIR/changed/supabase/migrations/${CHANGE}_security_advisor_fixes.sql"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a new migration on main' 'differ from what was reviewed'
echo 'PASS: a changed or added migration on main stops it before anything is touched'

ALBUS_TEST_PENDING="20261006120000 $CHANGE" run 0
expect_stop 'another change pending too' 'missing other database changes too (20261006120000 20261028120000)'
no_push 'another change pending'
ALBUS_TEST_REMOTE_ONLY=29991231999999 run 0
expect_stop 'a change only the project has' 'database changes main does not: 29991231999999'
no_push 'a change only the project has'
ALBUS_TEST_STYLE=garbled run 0
expect_stop 'a migration list that is not JSON' 'could not read the migration list'
no_push 'an unreadable list'
echo 'PASS: anything but exactly this change pending, or an unreadable list, stops it before the push'

ALBUS_TEST_PLANS_CLOSED=1 run 0
expect_stop 'plans already unreadable' 'even before this change'
no_push 'plans already unreadable'
ALBUS_TEST_QUERY_FAILS=1 run 0
expect_stop 'a read that fails' 'could not read the database'
no_push 'a failed read'
for shape in missing text two-rows; do
  ALBUS_TEST_QUERY_SHAPE=$shape run 0
  expect_stop "an answer shaped $shape" 'could not read the database'
  no_push "an answer shaped $shape"
done
ALBUS_TEST_QUERY_SHAPE=plain-array run 0
expect_pass 'a plain array, as outside an AI tool' 'DONE: GraphQL is off'
echo 'PASS: a failed or malformed read stops it before the push; both answer formats are read'

ALBUS_TEST_PUSH_FAILS=1 run 0
expect_stop 'a push Supabase refuses' 'error applying the change'
ALBUS_TEST_PUSH_NOOP=1 run 0
expect_stop 'a push that applied nothing' 'still pending after the push'
ALBUS_TEST_GRAPHQL_STAYS=1 run 0
expect_stop 'GraphQL still on after the push' 'the check did not pass'
ALBUS_TEST_FUNCTIONS_CLOSED=1 ALBUS_TEST_CLOSED_AFTER_PUSH=1 run 0
expect_stop 'students locked out after the push' 'the check did not pass'
echo 'PASS: a refused or empty push, or a failed check afterwards, stops it before DONE'

echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
