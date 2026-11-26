#!/usr/bin/env bash
# Exercise the owner's 26 Nov "deleting can't reset free limits" script,
# preview and real run, with local doubles for git and the Supabase CLI; no
# network. The CLI double keeps state, so the migration list and the database
# it reports change after db push. Each case checks what the script did, and
# what it refused to do after a failed safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-apple-id-memory-2026-11-26.sh
CHANGE=20261126120000
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-apple-id-memory-test.XXXXXX")
trap 'rm -rf "${TEST_DIR:?}"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_STATE="$TEST_DIR/state" ALBUS_TEST_CHANGE="$CHANGE"
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
rm -rf "${dest:?}/supabase/.temp"
STUB

# Nothing in this change goes over HTTP; a curl call is a mistake.
cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ALBUS_TEST_LOG"
echo 'this script has no reason to call curl' >&2
exit 99
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
pending=set(os.environ.get('ALBUS_TEST_PENDING',os.environ['ALBUS_TEST_CHANGE']).split())
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
    ! grep -Eiq '\b(insert|update|delete|alter|create|drop|grant|revoke|truncate)\b' "$file" \
      || { echo 'the query must not write' >&2; exit 92; }
    python3 - <<'PY'
import json,os
pushed=os.path.exists(os.environ['ALBUS_TEST_STATE']+'/pushed') and not os.environ.get('ALBUS_TEST_PUSH_NOOP')
row={k:pushed for k in ('table_present','functions_present','pepper_present','cleanup_scheduled')}
row['students_can_reach']=bool(os.environ.get('ALBUS_TEST_STUDENTS_REACH')) and pushed
if os.environ.get('ALBUS_TEST_TABLE_EARLY'): row['table_present']=True
if os.environ.get('ALBUS_TEST_NO_JOB') and pushed: row['cleanup_scheduled']=False
if os.environ.get('ALBUS_TEST_NO_PEPPER') and pushed: row['pepper_present']=False
shape=os.environ.get('ALBUS_TEST_QUERY_SHAPE','')
if shape=='missing': del row['pepper_present']
if shape=='text': row['table_present']=str(row['table_present']).lower()
if shape=='two-rows': print(json.dumps({'rows':[row,row]}))
elif shape=='plain-array': print(json.dumps([row]))
else: print(json.dumps({'boundary':'x','rows':[row],'warning':'untrusted data'}))
PY
    ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

# The script pins the digest of what was reviewed, so it refuses any other
# source. The safeguards are tested against a fixture instead: a copy of this
# checkout's supabase folder, and a copy of the script pinned to that copy's
# own digest. Nothing is skipped when the source moves on; the real script's
# own check is left exactly as it is.
digest() { # folder holding supabase/
  (cd "$1" && python3 - <<'PY'
from pathlib import Path
import hashlib
h=hashlib.sha256()
for p in sorted(Path('supabase/migrations').glob('*.sql')): h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
}
FIXTURE="$TEST_DIR/fixture"
mkdir -p "$FIXTURE"
cp -R "$ROOT/supabase" "$FIXTURE/supabase"
rm -rf "${FIXTURE:?}/supabase/.temp"
export ALBUS_TEST_SOURCE="$FIXTURE"
[ -f "$FIXTURE/supabase/migrations/${CHANGE}_apple_id_usage_memory.sql" ] \
  || { echo "FAIL: the fixture lacks migration $CHANGE" >&2; exit 1; }
grep -Eq '^MIGRATIONS_DIGEST=[0-9a-f]{64}$' "$ROOT/scripts/$SCRIPT" \
  || { echo 'FAIL: the script must pin the digest as 64 hex characters' >&2; exit 1; }
! grep -q 'functions deploy\|secrets set' "$ROOT/scripts/$SCRIPT" \
  || { echo 'FAIL: this change is database only; the script must not deploy functions or set secrets' >&2; exit 1; }
UNDER_TEST="$TEST_DIR/$SCRIPT"
sed -e "s/^MIGRATIONS_DIGEST=.*/MIGRATIONS_DIGEST=$(digest "$FIXTURE")/" "$ROOT/scripts/$SCRIPT" > "$UNDER_TEST"
cmp -s <(grep -Ev '^MIGRATIONS_DIGEST=' "$ROOT/scripts/$SCRIPT") <(grep -Ev '^MIGRATIONS_DIGEST=' "$UNDER_TEST") \
  || { echo 'FAIL: the copy under test differs from the script by more than its digest' >&2; exit 1; }

run() { # DRY_RUN value
  find "${ALBUS_TEST_STATE:?}" -mindepth 1 -delete; : > "$ALBUS_TEST_LOG"
  [ -z "${ALBUS_TEST_PRESET_PUSHED:-}" ] || touch "$ALBUS_TEST_STATE/pushed"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$1 bash "$UNDER_TEST" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -q "$TOKEN" "$TEST_DIR/output" "$ALBUS_TEST_LOG"; then echo 'FAIL: the access token reached the output or a command line' >&2; exit 1; fi
  ! grep -q '^curl ' "$ALBUS_TEST_LOG" || fail 'it called curl'
}
fail() { cat "$TEST_DIR/output" >&2; echo "--- calls:" >&2; cat "$ALBUS_TEST_LOG" >&2; echo "FAIL: $1" >&2; exit 1; }
called() { grep -q -- "$1" "$ALBUS_TEST_LOG"; }
line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | head -1 | cut -d: -f1; }
last_line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | tail -1 | cut -d: -f1; }
expect_pass() { [ "$STATUS" -eq 0 ] || fail "$1"; grep -q -- "$2" "$TEST_DIR/output" || fail "$1 (no '$2')"; }
expect_stop() {
  [ "$STATUS" -ne 0 ] || fail "$1 did not stop"
  grep -q -- "$2" "$TEST_DIR/output" || fail "$1 stopped for the wrong reason (wanted '$2')"
  ! grep -q -E '^(DRY RUN FINISHED|DONE:)' "$TEST_DIR/output" || fail "$1 finished anyway"
}
untouched() { ! called 'db push' || fail "$1: the database was changed"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN

run 1
expect_pass 'the preview' 'DRY RUN FINISHED'
grep -q "Pending: $CHANGE" "$TEST_DIR/output" || fail 'the pending change was not shown'
grep -q 'Now: table_present=false functions_present=false pepper_present=false cleanup_scheduled=false students_can_reach=false' \
  "$TEST_DIR/output" || fail 'the database before the change was not shown'
grep -q "\[dry run\] would apply $CHANGE" "$TEST_DIR/output" || fail 'the preview did not say it would apply the change'
untouched 'the preview'
! grep -q -v -E '^(git clone|supabase (link|migration list|db query) )' "$ALBUS_TEST_LOG" \
  || fail 'the preview ran something other than reads'
echo 'PASS: the preview checks main and the project, shows what is pending, and reads only'

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 1 ] || fail 'expected exactly one prompt'
grep -q -- ' -s ' <<<"$reads" || fail 'the prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'the prompt hides its own question'
echo 'PASS: the token prompt hides what is typed and shows its question'

run 0
expect_pass 'the real run' 'DONE: deleting an account and signing in again'
grep -q "Applied $CHANGE." "$TEST_DIR/output" || fail 'the change was not reported as applied'
grep -q 'After: table_present=true functions_present=true pepper_present=true cleanup_scheduled=true students_can_reach=false' \
  "$TEST_DIR/output" || fail 'the database was not checked after the change'
push=$(line_of 'db push'); q=$(last_line_of 'db query')
[ "$push" -lt "$q" ] || fail 'expected the push before its check'
[ "$(grep -c 'db push' "$ALBUS_TEST_LOG")" = 1 ] || fail 'expected exactly one push'
! called 'functions' || fail 'it touched the functions'
! called 'secrets' || fail 'it touched the secrets'
echo 'PASS: the real run applies the change and checks every piece of it, and touches nothing else'

ALBUS_TEST_PENDING=' ' ALBUS_TEST_PRESET_PUSHED=1 run 0
expect_pass 'a second run' 'DONE: deleting an account and signing in again'
grep -q "The change $CHANGE is already applied." "$TEST_DIR/output" || fail 'a second run did not see the change applied'
untouched 'a second run'
echo 'PASS: running it again only checks'

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
expect_pass 'stray SUPABASE_ settings in the shell' 'DONE: deleting an account and signing in again'
ALBUS_TEST_LINK_FAILS=1 run 0
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
untouched 'a refused link'
ALBUS_TEST_LINKED_REF=ssvehwhblgqtvqkfbkbj run 0
expect_stop 'a link that lands on another project' 'unexpected project reference'
untouched 'a link to another project'
echo 'PASS: an old CLI, a bad or missing token, or a refused or wrong link stops it; stray settings are dropped'

mkdir -p "$TEST_DIR/changed"
cp -R "$FIXTURE/supabase" "$TEST_DIR/changed/supabase"
printf '\n-- drift\n' >> "$TEST_DIR/changed/supabase/migrations/${CHANGE}_apple_id_usage_memory.sql"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a changed migration on main' 'database changes on main differ from what was reviewed'
! called 'supabase ' || fail 'changed database changes reached the CLI'
grep -q 'has the PR been merged' "$TEST_DIR/output" || fail 'the refusal did not say what to check first'
echo 'PASS: a changed migration on main stops it before anything is touched'

other=$(ls "$FIXTURE/supabase/migrations/"*.sql | sed -n 1p); other=$(basename "$other"); other=${other%%_*}
ALBUS_TEST_PENDING="$other $CHANGE" run 0
expect_stop 'another database change missing on the project' 'missing other database changes too'
untouched 'another missing change'
ALBUS_TEST_REMOTE_ONLY=29991231999999 run 0
expect_stop 'a change only the project has' 'database changes main does not'
untouched 'a change only the project has'
ALBUS_TEST_STYLE=garbled run 0
expect_stop 'a migration list that is not JSON' 'could not read the migration list'
untouched 'an unreadable list'
echo 'PASS: a project database that differs from main, or an unreadable list, stops it before any change'

ALBUS_TEST_TABLE_EARLY=1 run 0
expect_stop 'a table already there before the change' 'not what this change was written against'
untouched 'a table already there'
ALBUS_TEST_PENDING=' ' run 0
expect_stop 'the change recorded but missing' 'recorded as applied, but the database is not as reviewed'
untouched 'the change recorded but missing'
for shape in missing text two-rows; do
  ALBUS_TEST_QUERY_SHAPE=$shape run 0
  expect_stop "a database answer shaped '$shape'" 'could not read the database'
  untouched "a database answer shaped '$shape'"
done
ALBUS_TEST_QUERY_SHAPE=plain-array run 0
expect_pass 'a database answer as a plain list' 'DONE: deleting an account and signing in again'
ALBUS_TEST_QUERY_FAILS=1 run 0
expect_stop 'a refused database read' 'could not read the database'
untouched 'a refused database read'
echo 'PASS: a database not as expected, or an answer that cannot be read, stops it before any change'

ALBUS_TEST_PUSH_FAILS=1 run 0
expect_stop 'a failed push' 'error applying the change'
ALBUS_TEST_PUSH_NOOP=1 run 0
expect_stop 'a push that changed nothing' 'still pending after the push'
ALBUS_TEST_STUDENTS_REACH=1 run 0
expect_stop 'links a student can reach' 'database is not as reviewed'
ALBUS_TEST_NO_JOB=1 run 0
expect_stop 'no clean-up job after the change' 'database is not as reviewed'
ALBUS_TEST_NO_PEPPER=1 run 0
expect_stop 'no pepper after the change' 'database is not as reviewed'
echo 'PASS: a failed or empty push, links students can reach, or a missing job or pepper stops it before DONE'

echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
