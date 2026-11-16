#!/usr/bin/env bash
# Exercise the owner's 16 Nov plan cut-off script, preview and real run, with
# local doubles for git, curl and the Supabase CLI; no network. The CLI double
# keeps state, so the migration list, the reservations it reports and the
# function versions change after db push and deploy. Each case checks what the
# script did, and what it refused to do after a failed safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-plan-cutoff-2026-11-16.sh
CHANGE=20261115120000
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-plan-cutoff-test.XXXXXX")
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
  */functions/v1/breakdown) printf '%s' "${ALBUS_TEST_BREAKDOWN_PROBE:-401}" ;;
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
state=os.environ['ALBUS_TEST_STATE']; style=os.environ.get('ALBUS_TEST_STYLE','json')
pending=set(os.environ.get('ALBUS_TEST_PENDING','20261115120000').split())
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
after=pushed and not os.environ.get('ALBUS_TEST_RESERVATION_STAYS')
row={'plan_with_rubric':125000 if after else int(os.environ.get('ALBUS_TEST_PLAN_BEFORE','60000')),
     'plan_without_rubric':30000,
     'marking_with_rubric':int(os.environ.get('ALBUS_TEST_MARKING','450000')),
     'marking_without_rubric':200000}
shape=os.environ.get('ALBUS_TEST_QUERY_SHAPE','')
if shape=='missing': del row['plan_without_rubric']
if shape=='null': row['plan_with_rubric']=None
if shape=='text': row['plan_with_rubric']=str(row['plan_with_rubric'])
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
    [[ " $* " != *" --no-verify-jwt "* ]] || { echo 'these functions keep their sign-in check' >&2; exit 90; }
    [ "$3" != "${ALBUS_TEST_DEPLOY_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/deployed-$3" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

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
last_line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | tail -1 | cut -d: -f1; }
expect_pass() { [ "$STATUS" -eq 0 ] || fail "$1"; grep -q -- "$2" "$TEST_DIR/output" || fail "$1 (no '$2')"; }
expect_stop() {
  [ "$STATUS" -ne 0 ] || fail "$1 did not stop"
  grep -q -- "$2" "$TEST_DIR/output" || fail "$1 stopped for the wrong reason (wanted '$2')"
  ! grep -q -E '^(DRY RUN FINISHED|DONE:)' "$TEST_DIR/output" || fail "$1 finished anyway"
}
no_push() { ! called 'db push' || fail "$1: the change was applied"; }
no_deploy() { ! called 'functions deploy' || fail "$1: a function was deployed"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN

# A dated script pins what it was reviewed with. Before #52 is merged, and
# once main moves on, it rightly refuses to run, and there is nothing to test.
run 1
if [ "$STATUS" -ne 0 ] && grep -q 'differs* from what was reviewed' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: main does not hold exactly what this one-time deploy was reviewed with"
  exit 0
fi
expect_pass 'the preview' 'DRY RUN FINISHED'
grep -q "Pending: $CHANGE" "$TEST_DIR/output" || fail 'the pending change was not named'
grep -q 'Now: plan_with_rubric=60000 plan_without_rubric=30000 marking_with_rubric=450000 marking_without_rubric=200000' "$TEST_DIR/output" \
  || fail 'the reservations before were not shown'
grep -q 'breakdown: live at version 12; this redeploys it' "$TEST_DIR/output" || fail 'the live functions were not shown'
grep -q "\[dry run\] would apply $CHANGE" "$TEST_DIR/output" || fail 'the preview did not say what it would apply'
grep -q '\[dry run\] would deploy breakdown and grade' "$TEST_DIR/output" || fail 'the preview did not say what it would deploy'
no_push 'the preview'; no_deploy 'the preview'
! grep -q -v -E '^(git clone|supabase (link|migration list|db query|functions list) )' "$ALBUS_TEST_LOG" || fail 'the preview ran something other than reads'
echo "PASS: the preview names the one pending change, shows the reservations and functions, and reads only"

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 1 ] || fail 'expected exactly one prompt'
grep -q -- ' -s ' <<<"$reads" || fail 'the prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'the prompt hides its own question'
echo 'PASS: the token prompt hides what is typed and shows its question'

run 0
expect_pass 'the real run' 'DONE: a rubric plan now reserves US\$0.125'
grep -q 'After: plan_with_rubric=125000 plan_without_rubric=30000 marking_with_rubric=450000 marking_without_rubric=200000' "$TEST_DIR/output" \
  || fail 'the reservations after were not shown'
grep -q 'breakdown: live at version 13, sign-in check on' "$TEST_DIR/output" || fail 'breakdown was not checked after its deploy'
grep -q 'grade: live at version 13, sign-in check on' "$TEST_DIR/output" || fail 'grade was not checked after its deploy'
grep -q 'breakdown: refuses a request with no sign-in (401)' "$TEST_DIR/output" || fail 'breakdown was not probed'
grep -q 'grade: refuses a request with no sign-in (401)' "$TEST_DIR/output" || fail 'grade was not probed'
[ "$(grep -c 'db push' "$ALBUS_TEST_LOG")" = 1 ] || fail 'the change should be applied exactly once'
[ "$(grep -c 'functions deploy' "$ALBUS_TEST_LOG")" = 2 ] || fail 'exactly two functions should be deployed'
link=$(line_of 'supabase link'); list=$(line_of 'migration list'); before=$(line_of 'db query')
push=$(line_of 'db push'); after=$(last_line_of 'db query')
d1=$(line_of 'functions deploy breakdown'); d2=$(line_of 'functions deploy grade')
listed=$(last_line_of 'functions list'); probe1=$(line_of 'curl ')
[ "$link" -lt "$list" ] && [ "$list" -lt "$push" ] && [ "$before" -lt "$push" ] && [ "$push" -lt "$after" ] \
  && [ "$after" -lt "$d1" ] && [ "$d1" -lt "$d2" ] && [ "$d2" -lt "$listed" ] && [ "$listed" -lt "$probe1" ] \
  || fail 'expected reads, then the push, a read of the reservations, both deploys, a read of the functions and the probes, in that order'
! called 'secrets' || fail 'it touched secrets'
! called 'functions deploy delete-account' && ! called 'functions deploy revenuecat-webhook' || fail 'it deployed a function #52 did not change'
grep -q "curl .*https://yqhzmgikkawxjzvdjvsf.supabase.co/functions/v1/breakdown" "$ALBUS_TEST_LOG" || fail 'the probe went somewhere else'
echo 'PASS: the real run applies the database change once, then deploys both functions, then checks and probes them'

ALBUS_TEST_PRESET_PUSHED=1 run 0
expect_pass 'running it again' 'DONE: a rubric plan now reserves'
grep -q "The change $CHANGE is already applied." "$TEST_DIR/output" || fail 'an applied change was not recognised'
no_push 'running it again'
ALBUS_TEST_PRESET_PUSHED=1 run 1
expect_pass 'a preview once applied' 'DRY RUN FINISHED'
! grep -q 'would apply' "$TEST_DIR/output" || fail 'a preview once applied offered to apply again'
echo 'PASS: once applied, a run only checks and redeploys'

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
expect_pass 'stray SUPABASE_ settings in the shell' 'DONE: a rubric plan now reserves'
ALBUS_TEST_LINK_FAILS=1 run 0
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
no_push 'a refused link'; no_deploy 'a refused link'
ALBUS_TEST_LINKED_REF=ssvehwhblgqtvqkfbkbj run 0
expect_stop 'a link that lands on another project' 'unexpected project reference'
no_push 'a link to another project'; no_deploy 'a link to another project'
echo 'PASS: an old CLI, a bad or missing token, or a refused or wrong link stops it; stray settings are dropped'

mkdir -p "$TEST_DIR/changed"
cp -R "$ROOT/supabase" "$TEST_DIR/changed/supabase"
printf '\n-- drift\n' >> "$TEST_DIR/changed/supabase/migrations/${CHANGE}_plan_reservation_covers_reasoning.sql"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'a changed migration on main' 'database changes on main differ from what was reviewed'
! called 'supabase ' || fail 'changed database changes reached the CLI'
rm -rf "$TEST_DIR/changed/supabase"; cp -R "$ROOT/supabase" "$TEST_DIR/changed/supabase"
printf '\n// drift\n' >> "$TEST_DIR/changed/supabase/functions/_shared/anthropic.ts"
ALBUS_TEST_SOURCE_OVERRIDE="$TEST_DIR/changed" run 0
expect_stop 'changed function source on main' 'function source on main differs from what was reviewed'
! called 'supabase ' || fail 'changed function source reached the CLI'
grep -q 'has #52 been merged' "$TEST_DIR/output" || fail 'the refusal did not say what to check first'
echo 'PASS: a changed migration or function source on main stops it before anything is touched'

ALBUS_TEST_PENDING="20261028120000 $CHANGE" run 0
expect_stop 'another change pending too' "missing other database changes too (20261028120000 $CHANGE)"
no_push 'another change pending'; no_deploy 'another change pending'
ALBUS_TEST_REMOTE_ONLY=29991231999999 run 0
expect_stop 'a change only the project has' 'database changes main does not: 29991231999999'
no_push 'a change only the project has'
ALBUS_TEST_STYLE=garbled run 0
expect_stop 'a migration list that is not JSON' 'could not read the migration list'
no_push 'an unreadable list'
echo 'PASS: anything but exactly this change pending, or an unreadable list, stops it before the push'

ALBUS_TEST_PLAN_BEFORE=70000 run 0
expect_stop 'a reservation that is not what the change was written against' 'not what this change was written against'
no_push 'an unexpected reservation'; no_deploy 'an unexpected reservation'
ALBUS_TEST_MARKING=500000 run 0
expect_stop 'a marking reservation already changed' 'not what this change was written against'
no_push 'a changed marking reservation'
ALBUS_TEST_PRESET_PUSHED=1 ALBUS_TEST_RESERVATION_STAYS=1 run 0
expect_stop 'recorded as applied but not in effect' 'recorded as applied, but the reservations are not as reviewed'
no_deploy 'recorded as applied but not in effect'
ALBUS_TEST_QUERY_FAILS=1 run 0
expect_stop 'a read that fails' 'could not read the database'
no_push 'a failed read'
for shape in missing null text two-rows; do
  ALBUS_TEST_QUERY_SHAPE=$shape run 0
  expect_stop "an answer shaped $shape" 'could not read the database'
  no_push "an answer shaped $shape"
done
ALBUS_TEST_QUERY_SHAPE=plain-array run 0
expect_pass 'a plain array, as outside an AI tool' 'DONE: a rubric plan now reserves'
echo 'PASS: unexpected reservations, or a failed or malformed read, stop it before the push; both answer formats are read'

ALBUS_TEST_FUNCTION_MISSING=grade run 0
expect_stop 'a function not live' 'grade is not live on the project'
no_push 'a function not live'; no_deploy 'a function not live'
ALBUS_TEST_JWT_OFF=breakdown run 0
expect_stop 'a function live without its sign-in check' 'breakdown is live without its sign-in check'
no_push 'a function without its check'
echo 'PASS: a missing function or one without its sign-in check stops it before the push'

ALBUS_TEST_PUSH_FAILS=1 run 0
expect_stop 'a push Supabase refuses' 'error applying the change'
no_deploy 'a refused push'
ALBUS_TEST_PUSH_NOOP=1 run 0
expect_stop 'a push that applied nothing' 'still pending after the push'
no_deploy 'an empty push'
ALBUS_TEST_RESERVATION_STAYS=1 run 0
expect_stop 'the reservation unchanged after the push' 'the reservations are not as reviewed'
no_deploy 'an unchanged reservation'
echo 'PASS: a refused or empty push, or a reservation not as reviewed afterwards, stops it before any deploy'

ALBUS_TEST_DEPLOY_FAILS=breakdown run 0
expect_stop 'breakdown failing to deploy' 'breakdown did not deploy'
! called 'functions deploy grade' || fail 'grade was deployed after breakdown failed'
ALBUS_TEST_DEPLOY_FAILS=grade run 0
expect_stop 'grade failing to deploy' 'grade did not'
ALBUS_TEST_JWT_OFF=grade ALBUS_TEST_JWT_OFF_AFTER=1 run 0
expect_stop 'grade live without its check after the deploy' 'grade is not live with its sign-in check on'
! called 'curl ' || fail 'it probed a function that failed its check'
ALBUS_TEST_GRADE_PROBE=200 run 0
expect_stop 'grade answering a request with no sign-in' 'grade answered 200'
ALBUS_TEST_BREAKDOWN_PROBE=000 run 0
expect_stop 'breakdown not answering' 'breakdown answered 000'
echo 'PASS: a failed deploy, a function without its check, or one that answers without a sign-in stops it before DONE'

echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
