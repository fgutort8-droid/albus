#!/usr/bin/env bash
# Exercise the owner's 25 Nov grade-criteria script, preview and real run, with
# local doubles for git, curl and the Supabase CLI; no network. The CLI double
# keeps state, so the function version changes after the deploy. Each case
# checks what the script did, and what it refused to do after a failed
# safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-grade-criteria-2026-11-25.sh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-grade-criteria-test.XXXXXX")
trap 'rm -rf "${TEST_DIR:?}"' EXIT
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
  */functions/v1/grade) printf '%s' "${ALBUS_TEST_GRADE_PROBE:-401}" ;;
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
style=os.environ.get('ALBUS_TEST_STYLE','json')
pending=set(os.environ.get('ALBUS_TEST_PENDING','').split())
rows=[]
for f in sorted(glob.glob('supabase/migrations/*.sql')):
    v=os.path.basename(f).split('_')[0]
    rows.append({'local':v,'remote':'' if v in pending else v,'time':v})
rows+=[{'local':'','remote':v,'time':v} for v in os.environ.get('ALBUS_TEST_REMOTE_ONLY','').split()]
if style=='garbled': print('Local | Remote | Time (UTC)')
else: print(json.dumps({'migrations':rows,'message':'Migrations listed'}))
PY
    ;;
  'functions list')
    python3 - <<'PY'
import json,os
state=os.environ['ALBUS_TEST_STATE']
def deployed(n): return os.path.exists(state+'/deployed-'+n)
rows=[]
for name in ('breakdown','grade','delete-account','revenuecat-webhook'):
    if name==os.environ.get('ALBUS_TEST_FUNCTION_MISSING'): continue
    jwt=name!='revenuecat-webhook'
    if name==os.environ.get('ALBUS_TEST_JWT_OFF') and (deployed(name) or not os.environ.get('ALBUS_TEST_JWT_OFF_AFTER')): jwt=False
    rows.append({'slug':name,'verify_jwt':jwt,'status':'ACTIVE','version':12+deployed(name)})
print(json.dumps(rows))
PY
    ;;
  'functions deploy')
    [[ " $* " == *" --use-api "* ]] || { echo 'deploy must bundle on the server' >&2; exit 91; }
    [[ " $* " != *" --no-verify-jwt "* ]] || { echo 'grade keeps its sign-in check' >&2; exit 90; }
    [ -z "${ALBUS_TEST_DEPLOY_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/deployed-$3" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

run() { # DRY_RUN value
  find "${ALBUS_TEST_STATE:?}" -mindepth 1 -delete; : > "$ALBUS_TEST_LOG"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$1 bash "$ROOT/scripts/$SCRIPT" > "$TEST_DIR/output" 2>&1
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
no_deploy() { ! called 'functions deploy' || fail "$1: a function was deployed"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN

# A dated script pins what it was reviewed with. Once main moves on, it rightly
# refuses to run, and there is nothing to test.
run 1
if [ "$STATUS" -ne 0 ] && grep -q 'differs* from what was reviewed' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: main does not hold exactly what this one-time deploy was reviewed with"
  exit 0
fi
expect_pass 'the preview' 'DRY RUN FINISHED'
grep -q 'The project database matches main.' "$TEST_DIR/output" || fail 'the database check was not shown'
grep -q 'grade: live at version 12; this redeploys it' "$TEST_DIR/output" || fail 'the live function was not shown'
grep -q '\[dry run\] would deploy grade from main' "$TEST_DIR/output" || fail 'the preview did not say what it would deploy'
no_deploy 'the preview'
! grep -q -v -E '^(git clone|supabase (link|migration list|functions list) )' "$ALBUS_TEST_LOG" || fail 'the preview ran something other than reads'
echo 'PASS: the preview checks main and the project, shows grade, and reads only'

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 1 ] || fail 'expected exactly one prompt'
grep -q -- ' -s ' <<<"$reads" || fail 'the prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'the prompt hides its own question'
echo 'PASS: the token prompt hides what is typed and shows its question'

run 0
expect_pass 'the real run' 'DONE: grade is live from main'
grep -q 'grade: live at version 13, sign-in check on' "$TEST_DIR/output" || fail 'grade was not checked after its deploy'
grep -q 'grade: refuses a request with no sign-in (401)' "$TEST_DIR/output" || fail 'grade was not probed'
[ "$(grep -c 'functions deploy' "$ALBUS_TEST_LOG")" = 1 ] || fail 'exactly one function should be deployed'
called 'functions deploy grade' || fail 'grade was not the function deployed'
link=$(line_of 'supabase link'); list=$(line_of 'migration list'); d=$(line_of 'functions deploy grade')
listed=$(last_line_of 'functions list'); probe=$(line_of 'curl ')
[ "$link" -lt "$list" ] && [ "$list" -lt "$d" ] && [ "$d" -lt "$listed" ] && [ "$listed" -lt "$probe" ] \
  || fail 'expected the reads, then the deploy, a read of the functions and the probe, in that order'
! called 'db push' && ! called 'db query' && ! called 'secrets' || fail 'it touched the database or secrets'
grep -q "curl .*https://yqhzmgikkawxjzvdjvsf.supabase.co/functions/v1/grade" "$ALBUS_TEST_LOG" || fail 'the probe went somewhere else'
echo 'PASS: the real run deploys grade alone, then checks and probes it'

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
expect_pass 'stray SUPABASE_ settings in the shell' 'DONE: grade is live from main'
ALBUS_TEST_LINK_FAILS=1 run 0
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
no_deploy 'a refused link'
ALBUS_TEST_LINKED_REF=ssvehwhblgqtvqkfbkbj run 0
expect_stop 'a link that lands on another project' 'unexpected project reference'
no_deploy 'a link to another project'
echo 'PASS: an old CLI, a bad or missing token, or a refused or wrong link stops it; stray settings are dropped'

mkdir -p "$TEST_DIR/changed"
cp -R "$ROOT/supabase" "$TEST_DIR/changed/supabase"
first=$(ls "$TEST_DIR/changed/supabase/migrations/"*.sql | head -1)
printf '\n-- drift\n' >> "$first"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a changed migration on main' 'database changes on main differ from what was reviewed'
! called 'supabase ' || fail 'changed database changes reached the CLI'
rm -rf "${TEST_DIR:?}/changed/supabase"; cp -R "$ROOT/supabase" "$TEST_DIR/changed/supabase"
printf '\n// drift\n' >> "$TEST_DIR/changed/supabase/functions/grade/index.ts"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'changed function source on main' 'function source on main differs from what was reviewed'
! called 'supabase ' || fail 'changed function source reached the CLI'
grep -q 'has the criteria PR been merged' "$TEST_DIR/output" || fail 'the refusal did not say what to check first'
echo 'PASS: a changed migration or function source on main stops it before anything is touched'

last=$(ls "$ROOT/supabase/migrations/"*.sql | tail -1); last=$(basename "$last"); last=${last%%_*}
ALBUS_TEST_PENDING=$last run 0
expect_stop 'a database change missing on the project' 'does not match main'
no_deploy 'a missing database change'
ALBUS_TEST_REMOTE_ONLY=29991231999999 run 0
expect_stop 'a change only the project has' 'does not match main'
no_deploy 'a change only the project has'
ALBUS_TEST_STYLE=garbled run 0
expect_stop 'a migration list that is not JSON' 'could not read the migration list'
no_deploy 'an unreadable list'
echo 'PASS: a project database that differs from main, or an unreadable list, stops it before the deploy'

ALBUS_TEST_FUNCTION_MISSING=grade run 0
expect_stop 'grade not live' 'grade is not live on the project'
no_deploy 'grade not live'
ALBUS_TEST_JWT_OFF=grade run 0
expect_stop 'grade live without its sign-in check' 'grade is live without its sign-in check'
no_deploy 'grade without its check'
echo 'PASS: grade missing or without its sign-in check stops it before the deploy'

ALBUS_TEST_DEPLOY_FAILS=1 run 0
expect_stop 'grade failing to deploy' 'grade did not deploy'
ALBUS_TEST_JWT_OFF=grade ALBUS_TEST_JWT_OFF_AFTER=1 run 0
expect_stop 'grade live without its check after the deploy' 'grade is not live with its sign-in check on'
! called 'curl ' || fail 'it probed a function that failed its check'
ALBUS_TEST_GRADE_PROBE=200 run 0
expect_stop 'grade answering a request with no sign-in' 'grade answered 200'
echo 'PASS: a failed deploy, grade without its check, or answering without a sign-in stops it before DONE'

echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
