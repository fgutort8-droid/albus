#!/usr/bin/env bash
# Exercise the owner's 25 Nov "delete without signing in again" script, preview
# and real run, with local doubles for git, curl and the Supabase CLI; no
# network. The CLI double keeps state, so the migration list, the database it
# reports and the live functions change after db push and deploy. Each case
# checks what the script did, and what it refused to do after a failed
# safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-delete-without-signin-2026-11-25.sh
CHANGE=20261125180000
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-delete-signin-test.XXXXXX")
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

cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$ALBUS_TEST_LOG"
out=; prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
[ -n "$out" ] && echo '{"msg":"no sign-in"}' > "$out"
url=
for a in "$@"; do case "$a" in https://*) url=$a ;; esac; done
case "$url" in
  */functions/v1/delete-account) printf '%s' "${ALBUS_TEST_DELETE_PROBE:-401}" ;;
  */functions/v1/apple-token) printf '%s' "${ALBUS_TEST_TOKEN_PROBE:-401}" ;;
  *) echo 'unexpected address' >&2; exit 99 ;;
esac
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
    ! grep -Eiq '\b(insert|update|delete|alter|create|drop|grant|revoke)\b' "$file" \
      || { echo 'the query must not write' >&2; exit 92; }
    python3 - <<'PY'
import json,os
pushed=os.path.exists(os.environ['ALBUS_TEST_STATE']+'/pushed') and not os.environ.get('ALBUS_TEST_PUSH_NOOP')
row={'table_present':pushed,'functions_present':pushed,
     'students_can_reach':bool(os.environ.get('ALBUS_TEST_STUDENTS_REACH')) and pushed}
if os.environ.get('ALBUS_TEST_TABLE_EARLY'): row['table_present']=True
shape=os.environ.get('ALBUS_TEST_QUERY_SHAPE','')
if shape=='missing': del row['functions_present']
if shape=='text': row['table_present']=str(row['table_present']).lower()
if shape=='two-rows': print(json.dumps({'rows':[row,row]}))
elif shape=='plain-array': print(json.dumps([row]))
else: print(json.dumps({'boundary':'x','rows':[row],'warning':'untrusted data'}))
PY
    ;;
  'functions list')
    python3 - <<'PY'
import json,os
state=os.environ['ALBUS_TEST_STATE']
def deployed(n): return os.path.exists(state+'/deployed-'+n)
rows=[]
for name in ('breakdown','grade','delete-account','apple-token','revenuecat-webhook'):
    if name==os.environ.get('ALBUS_TEST_FUNCTION_MISSING'): continue
    if name=='apple-token' and not deployed(name) and not os.environ.get('ALBUS_TEST_TOKEN_LIVE'): continue
    jwt=name!='revenuecat-webhook'
    if name==os.environ.get('ALBUS_TEST_JWT_OFF') and (deployed(name) or not os.environ.get('ALBUS_TEST_JWT_OFF_AFTER')): jwt=False
    rows.append({'slug':name,'verify_jwt':jwt,'status':'ACTIVE','version':12+deployed(name)})
print(json.dumps(rows))
PY
    ;;
  'functions deploy')
    [[ " $* " == *" --use-api "* ]] || { echo 'deploy must bundle on the server' >&2; exit 91; }
    [[ " $* " != *" --no-verify-jwt "* ]] || { echo 'these functions keep their sign-in check' >&2; exit 90; }
    [ "$3" != "${ALBUS_TEST_DEPLOY_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/deployed-$3" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

# The script pins the digests of what was reviewed, so it refuses any other
# source. The safeguards are tested against a fixture instead: a copy of this
# checkout's supabase folder, and a copy of the script pinned to that copy's
# own digests. Nothing is skipped when the source moves on; the real script's
# own check is left exactly as it is.
digests() { # folder holding supabase/
  (cd "$1" && python3 - <<'PY'
from pathlib import Path
import hashlib
root=Path('supabase')
h=hashlib.sha256()
for p in sorted((root/'migrations').glob('*.sql')): h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
h=hashlib.sha256()
paths=sorted([root/'config.toml', *[p for p in (root/'functions').rglob('*')
    if p.is_file() and '_tests' not in p.parts and p.suffix in ('.ts','.json','.lock')]])
for p in paths: h.update(str(p.relative_to(root)).encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
}
FIXTURE="$TEST_DIR/fixture"
mkdir -p "$FIXTURE"
cp -R "$ROOT/supabase" "$FIXTURE/supabase"
rm -rf "${FIXTURE:?}/supabase/.temp"
export ALBUS_TEST_SOURCE="$FIXTURE"
[ -f "$FIXTURE/supabase/migrations/${CHANGE}_apple_refresh_tokens.sql" ] \
  || { echo "FAIL: the fixture lacks migration $CHANGE" >&2; exit 1; }
FIXTURE_DIGESTS=$(digests "$FIXTURE")
grep -Eq '^MIGRATIONS_DIGEST=[0-9a-f]{64}$' "$ROOT/scripts/$SCRIPT" \
  && grep -Eq '^SOURCE_DIGEST=[0-9a-f]{64}$' "$ROOT/scripts/$SCRIPT" \
  || { echo 'FAIL: the script must pin both digests as 64 hex characters' >&2; exit 1; }
UNDER_TEST="$TEST_DIR/$SCRIPT"
sed -e "s/^MIGRATIONS_DIGEST=.*/MIGRATIONS_DIGEST=$(sed -n 1p <<<"$FIXTURE_DIGESTS")/" \
    -e "s/^SOURCE_DIGEST=.*/SOURCE_DIGEST=$(sed -n 2p <<<"$FIXTURE_DIGESTS")/" \
    "$ROOT/scripts/$SCRIPT" > "$UNDER_TEST"
cmp -s <(grep -Ev '^(MIGRATIONS|SOURCE)_DIGEST=' "$ROOT/scripts/$SCRIPT") \
       <(grep -Ev '^(MIGRATIONS|SOURCE)_DIGEST=' "$UNDER_TEST") \
  || { echo 'FAIL: the copy under test differs from the script by more than its two digests' >&2; exit 1; }

run() { # DRY_RUN value
  find "${ALBUS_TEST_STATE:?}" -mindepth 1 -delete; : > "$ALBUS_TEST_LOG"
  [ -z "${ALBUS_TEST_PRESET_PUSHED:-}" ] || touch "$ALBUS_TEST_STATE/pushed"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$1 bash "$UNDER_TEST" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -q "$TOKEN" "$TEST_DIR/output" "$ALBUS_TEST_LOG"; then echo 'FAIL: the access token reached the output or a command line' >&2; exit 1; fi
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
no_push() { ! called 'db push' || fail "$1: the database was changed"; }
no_deploy() { ! called 'functions deploy' || fail "$1: a function was deployed"; }
untouched() { no_push "$1"; no_deploy "$1"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN

run 1
expect_pass 'the preview' 'DRY RUN FINISHED'
grep -q "Pending: $CHANGE" "$TEST_DIR/output" || fail 'the pending change was not shown'
grep -q 'Now: table_present=false functions_present=false students_can_reach=false' "$TEST_DIR/output" \
  || fail 'the database before the change was not shown'
grep -q 'delete-account: live at version 12; this redeploys it' "$TEST_DIR/output" || fail 'delete-account was not shown'
grep -q 'apple-token: not live yet; this deploys it' "$TEST_DIR/output" || fail 'the new function was not shown'
grep -q "\[dry run\] would apply $CHANGE" "$TEST_DIR/output" || fail 'the preview did not say it would apply the change'
untouched 'the preview'
! grep -q -v -E '^(git clone|supabase (link|migration list|db query|functions list) )' "$ALBUS_TEST_LOG" \
  || fail 'the preview ran something other than reads'
echo 'PASS: the preview checks main and the project, shows what is pending, and reads only'

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 1 ] || fail 'expected exactly one prompt'
grep -q -- ' -s ' <<<"$reads" || fail 'the prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'the prompt hides its own question'
echo 'PASS: the token prompt hides what is typed and shows its question'

run 0
expect_pass 'the real run' 'DONE: Apple tokens are kept at sign-in'
grep -q "Applied $CHANGE." "$TEST_DIR/output" || fail 'the change was not reported as applied'
grep -q 'After: table_present=true functions_present=true students_can_reach=false' "$TEST_DIR/output" \
  || fail 'the database was not checked after the change'
grep -q 'delete-account: live at version 13, sign-in check on' "$TEST_DIR/output" || fail 'delete-account was not checked after its deploy'
grep -q 'apple-token: live at version 13, sign-in check on' "$TEST_DIR/output" || fail 'apple-token was not checked after its deploy'
grep -q 'delete-account: refuses a request with no sign-in (401)' "$TEST_DIR/output" || fail 'delete-account was not probed'
grep -q 'apple-token: refuses a request with no sign-in (401)' "$TEST_DIR/output" || fail 'apple-token was not probed'
[ "$(grep -c 'functions deploy' "$ALBUS_TEST_LOG")" = 2 ] || fail 'exactly two functions should be deployed'
push=$(line_of 'db push'); q=$(last_line_of 'db query'); d1=$(line_of 'functions deploy delete-account')
d2=$(line_of 'functions deploy apple-token'); listed=$(last_line_of 'functions list'); probe=$(line_of 'curl ')
[ "$push" -lt "$q" ] && [ "$q" -lt "$d1" ] && [ "$d1" -lt "$d2" ] && [ "$d2" -lt "$listed" ] && [ "$listed" -lt "$probe" ] \
  || fail 'expected the push, its check, both deploys, a read of the functions and the probes, in that order'
! called 'secrets' || fail 'it touched the secrets'
[ "$(grep -c 'curl ' "$ALBUS_TEST_LOG")" = 2 ] || fail 'expected exactly two probes'
! grep 'curl ' "$ALBUS_TEST_LOG" | grep -vq 'https://yqhzmgikkawxjzvdjvsf.supabase.co/functions/v1/' \
  || fail 'a probe went somewhere else'
echo 'PASS: the real run applies the change, checks it, deploys both functions, then checks and probes them'

ALBUS_TEST_PENDING=' ' ALBUS_TEST_PRESET_PUSHED=1 ALBUS_TEST_TOKEN_LIVE=1 run 0
expect_pass 'a second run' 'DONE: Apple tokens are kept at sign-in'
grep -q "The change $CHANGE is already applied." "$TEST_DIR/output" || fail 'a second run did not see the change applied'
no_push 'a second run'
echo 'PASS: running it again only checks and redeploys'

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
expect_pass 'stray SUPABASE_ settings in the shell' 'DONE: Apple tokens are kept at sign-in'
ALBUS_TEST_LINK_FAILS=1 run 0
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
untouched 'a refused link'
ALBUS_TEST_LINKED_REF=ssvehwhblgqtvqkfbkbj run 0
expect_stop 'a link that lands on another project' 'unexpected project reference'
untouched 'a link to another project'
echo 'PASS: an old CLI, a bad or missing token, or a refused or wrong link stops it; stray settings are dropped'

mkdir -p "$TEST_DIR/changed"
cp -R "$FIXTURE/supabase" "$TEST_DIR/changed/supabase"
printf '\n-- drift\n' >> "$TEST_DIR/changed/supabase/migrations/${CHANGE}_apple_refresh_tokens.sql"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a changed migration on main' 'database changes on main differ from what was reviewed'
! called 'supabase ' || fail 'changed database changes reached the CLI'
rm -rf "${TEST_DIR:?}/changed/supabase"; cp -R "$FIXTURE/supabase" "$TEST_DIR/changed/supabase"
printf '\n// drift\n' >> "$TEST_DIR/changed/supabase/functions/apple-token/handler.ts"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'changed function source on main' 'function source on main differs from what was reviewed'
! called 'supabase ' || fail 'changed function source reached the CLI'
grep -q 'has the PR been merged' "$TEST_DIR/output" || fail 'the refusal did not say what to check first'
echo 'PASS: a changed migration or function source on main stops it before anything is touched'

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
expect_pass 'a database answer as a plain list' 'DONE: Apple tokens are kept at sign-in'
ALBUS_TEST_QUERY_FAILS=1 run 0
expect_stop 'a refused database read' 'could not read the database'
untouched 'a refused database read'
echo 'PASS: a database not as expected, or an answer that cannot be read, stops it before any change'

ALBUS_TEST_FUNCTION_MISSING=delete-account run 0
expect_stop 'delete-account not live' 'delete-account is not live on the project'
untouched 'delete-account not live'
ALBUS_TEST_JWT_OFF=delete-account run 0
expect_stop 'delete-account live without its sign-in check' 'delete-account is live without its sign-in check'
untouched 'delete-account without its check'
ALBUS_TEST_TOKEN_LIVE=1 ALBUS_TEST_JWT_OFF=apple-token run 0
expect_stop 'apple-token live without its sign-in check' 'apple-token is live without its sign-in check'
untouched 'apple-token without its check'
echo 'PASS: a function missing or without its sign-in check stops it before any change'

ALBUS_TEST_PUSH_FAILS=1 run 0
expect_stop 'a failed push' 'error applying the change'
no_deploy 'a failed push'
ALBUS_TEST_PUSH_NOOP=1 run 0
expect_stop 'a push that changed nothing' 'still pending after the push'
no_deploy 'a push that changed nothing'
ALBUS_TEST_STUDENTS_REACH=1 run 0
expect_stop 'functions a student can reach' 'database is not as reviewed'
no_deploy 'functions a student can reach'
echo 'PASS: a failed or empty push, or a result students can reach, stops it before the deploys'

ALBUS_TEST_DEPLOY_FAILS=delete-account run 0
expect_stop 'delete-account failing to deploy' 'delete-account did not deploy'
! called 'functions deploy apple-token' || fail 'apple-token deployed after delete-account failed'
ALBUS_TEST_DEPLOY_FAILS=apple-token run 0
expect_stop 'apple-token failing to deploy' 'apple-token did not'
ALBUS_TEST_JWT_OFF=apple-token ALBUS_TEST_JWT_OFF_AFTER=1 run 0
expect_stop 'apple-token live without its check after the deploy' 'apple-token is not live with its sign-in check on'
! called 'curl ' || fail 'it probed a function that failed its check'
ALBUS_TEST_DELETE_PROBE=200 run 0
expect_stop 'delete-account answering a request with no sign-in' 'delete-account answered 200'
ALBUS_TEST_TOKEN_PROBE=500 run 0
expect_stop 'apple-token answering a request with no sign-in' 'apple-token answered 500'
echo 'PASS: a failed deploy, a function without its check, or one answering without a sign-in stops it before DONE'

echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
