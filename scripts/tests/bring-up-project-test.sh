#!/usr/bin/env bash
# Exercise the owner's new-project setup script, preview and real run, with
# local doubles for git, the Supabase CLI and curl; no network. The CLI double
# keeps state, so the migration list changes after db push and the function
# list after each deploy. Each case checks what the script did, and what it
# refused to do after a failed safeguard.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=bring-up-project-2026-10-25.sh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-bring-up-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_STATE="$TEST_DIR/state" ALBUS_TEST_SOURCE="$ROOT"
export ALBUS_TTY=/dev/null
# Stand-ins built at run time, so nothing token-shaped sits in the repository.
TOKEN="sbp_$(printf '%040d' 7)"
PUBLISHABLE="sb_publishable_$(printf '%024d' 7)"
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
    mkdir -p supabase/.temp; printf '%s' "$3" > supabase/.temp/project-ref ;;
  'migration list')
    [[ " $* " == *" --output-format json "* ]] || { echo 'the migration list must be asked for as JSON' >&2; exit 96; }
    python3 - <<'PY'
import glob,json,os
state=os.environ['ALBUS_TEST_STATE']; style=os.environ.get('ALBUS_TEST_STYLE','json')
count=int(os.environ.get('ALBUS_TEST_APPLIED_COUNT','0')); versions=os.environ.get('ALBUS_TEST_APPLIED_VERSIONS','').split()
rows=[]
for i,f in enumerate(sorted(glob.glob('supabase/migrations/*.sql')),1):
    v=os.path.basename(f).split('_')[0]
    applied=os.path.exists(state+'/pushed') or (v in versions if versions else i<=count)
    rows.append({'local':v,'remote':v if applied else '','time':v})
rows+=[{'local':'','remote':v,'time':v} for v in os.environ.get('ALBUS_TEST_REMOTE_ONLY','').split()]
if style=='garbled': print('Local | Remote | Time (UTC)')
elif style=='no-list': print(json.dumps({'message':'Migrations listed'}))
else:
    if style=='with-progress': print(json.dumps({'type':'info','message':'Connecting to remote database...'}))
    print(json.dumps({'migrations':rows,'message':'Migrations listed'}))
PY
    ;;
  'functions list')
    python3 - <<'PY'
import json,os
state=os.environ['ALBUS_TEST_STATE']
rows=[]
jwt={'breakdown':True,'grade':True,'delete-account':True,'revenuecat-webhook':False}
for name in jwt:
    if os.path.exists(state+'/deployed-'+name) or name in os.environ.get('ALBUS_TEST_LIVE','').split():
        want=jwt[name]
        if name==os.environ.get('ALBUS_TEST_WRONG_JWT'): want=not want
        rows.append({'slug':name,'verify_jwt':want,'version':1,'status':'ACTIVE'})
if os.environ.get('ALBUS_TEST_EXTRA_FUNCTION'): rows.append({'slug':os.environ['ALBUS_TEST_EXTRA_FUNCTION'],'verify_jwt':True,'version':1})
print('null' if not rows and os.environ.get('ALBUS_TEST_FUNCTIONS_NULL') else json.dumps(rows))
PY
    ;;
  'secrets list')
    python3 - <<'PY'
import json,os
names=[] if os.environ.get('ALBUS_TEST_NO_PLATFORM_KEYS') else ['SUPABASE_SECRET_KEYS','SUPABASE_PUBLISHABLE_KEYS','SUPABASE_URL']
names+=os.environ.get('ALBUS_TEST_SECRETS','').split()
print(json.dumps([{'name':n,'value':'00'*32} for n in names]))
PY
    ;;
  'db push')
    [ -z "${ALBUS_TEST_PUSH_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/pushed" ;;
  'db query')
    [ -z "${ALBUS_TEST_QUERY_FAILS:-}" ] || exit 1
    python3 -c '
import json,os
keys=["plans_seeded","products_mapped","public_tables_have_rls","anon_has_no_table_access","definer_paths_closed",
 "jobs_scheduled","task_cap_trigger_on","sync_signature","release_signature","sync_privileges","release_privileges",
 "delete_rpc_privileges","inbox_rls","inbox_clients_closed","audit_immutable"]
print(json.dumps({"rows":[{k: k != os.environ.get("ALBUS_TEST_FALSE_CHECK") for k in keys}]}))' ;;
  'functions deploy')
    name=$3
    [ "$name" != "${ALBUS_TEST_DEPLOY_FAILS:-}" ] || exit 1
    touch "$ALBUS_TEST_STATE/deployed-$name" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB

cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ALBUS_TEST_LOG"
out=; prev=
for a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done
[ -n "$out" ] || { echo 'the curl double expects -o' >&2; exit 98; }
reply() { printf '%s' "$2" > "$out"; printf '%s' "$1"; }  # the body to -o, the status as -w asks
good='{"external":{"apple":true,"email":false,"anonymous_users":false,"google":false},"disable_signup":false}'
unconfigured='{"error":"NOT_CONFIGURED","message":"NOT_CONFIGURED"}'
refused='{"code":401,"message":"Missing authorization header"}'
case "$*" in
  *"/auth/v1/settings"*) reply "${ALBUS_TEST_SETTINGS_STATUS:-200}" "${ALBUS_TEST_SETTINGS:-$good}" ;;
  *"/functions/v1/revenuecat-webhook"*) reply "${ALBUS_TEST_STATUS_WEBHOOK:-503}" "${ALBUS_TEST_WEBHOOK_BODY:-$unconfigured}" ;;
  *"/functions/v1/breakdown"*) reply "${ALBUS_TEST_STATUS_BREAKDOWN:-401}" "$refused" ;;
  *"/functions/v1/grade"*) reply "${ALBUS_TEST_STATUS_GRADE:-401}" "$refused" ;;
  *"/functions/v1/delete-account"*) reply "${ALBUS_TEST_STATUS_DELETE:-401}" "$refused" ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/git" "$TEST_DIR/bin/supabase" "$TEST_DIR/bin/curl"

run() { # DRY_RUN value, then optional script path
  rm -f "$ALBUS_TEST_STATE"/*; : > "$ALBUS_TEST_LOG"
  [ -z "${ALBUS_TEST_PRESET_PUSHED:-}" ] || touch "$ALBUS_TEST_STATE/pushed"
  for f in ${ALBUS_TEST_PRESET_DEPLOYED:-}; do touch "$ALBUS_TEST_STATE/deployed-$f"; done
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$1 bash "${2:-$ROOT/scripts/$SCRIPT}" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  if grep -q "$TOKEN" "$TEST_DIR/output" "$ALBUS_TEST_LOG"; then echo 'FAIL: the access token reached the output or a command line' >&2; exit 1; fi
}
fail() { cat "$TEST_DIR/output" >&2; echo "--- calls:" >&2; cat "$ALBUS_TEST_LOG" >&2; echo "FAIL: $1" >&2; exit 1; }
called() { grep -q -- "$1" "$ALBUS_TEST_LOG"; }
line_of() { grep -n -- "$1" "$ALBUS_TEST_LOG" | head -1 | cut -d: -f1; }
expect_pass() { [ "$STATUS" -eq 0 ] || fail "$1"; grep -q "$2" "$TEST_DIR/output" || fail "$1 (no '$2')"; }
expect_stop() {
  [ "$STATUS" -ne 0 ] || fail "$1 did not stop"
  grep -q -- "$2" "$TEST_DIR/output" || fail "$1 stopped for the wrong reason (wanted '$2')"
  ! grep -q -E '^(DRY RUN FINISHED|DONE:)' "$TEST_DIR/output" || fail "$1 finished anyway"
}
no_writes() { ! grep -q -E 'db push|db query|functions deploy' "$ALBUS_TEST_LOG" || fail "$1: a command that writes ran"; }
export SUPABASE_ACCESS_TOKEN=$TOKEN
NMIG=$(ls "$ROOT"/supabase/migrations/*.sql | wc -l | tr -d ' ')

# A dated script pins the exact server code it was reviewed with. Once main
# moves on, it rightly refuses to run, and there is nothing left to test.
run 1
if [ "$STATUS" -ne 0 ] && grep -q 'configuration differs' "$TEST_DIR/output"; then
  echo "SKIP $SCRIPT: server code has changed since this one-time setup was reviewed"
  exit 0
fi
expect_pass 'preview of a fresh project' 'DRY RUN FINISHED'
grep -q "pending: $NMIG" "$TEST_DIR/output" || fail 'every database change should be pending on a fresh project'
grep -q 'breakdown: not live yet; this deploys it' "$TEST_DIR/output" || fail 'functions not reported as new'
grep -q 'Sign-in settings: not checked.' "$TEST_DIR/output" || fail 'a skipped settings check was not said'
no_writes 'preview'
echo "PASS: a fresh project previews $NMIG pending database changes and four new functions, writing nothing"

# Bash prints read's question on stderr, so a 2> on a read hides the question.
reads=$(grep -E '^[[:space:]]*read ' "$ROOT/scripts/$SCRIPT")
[ "$(wc -l <<<"$reads" | tr -d ' ')" = 2 ] || fail 'expected exactly two prompts'
! grep -v -- ' -s ' <<<"$reads" || fail 'a prompt shows what is typed'
! grep -- '2>' <<<"$reads" || fail 'a prompt hides its own question'
echo 'PASS: both prompts hide what is typed and show their question'
# Supabase CLI 2.122 sends the checks as one prepared statement, which refuses several.
checks=$(sed -n '/^cat > "\$STAGE\/verify.sql" <<.SQL.$/,/^SQL$/p' "$ROOT/scripts/$SCRIPT" | sed '1d;$d')
[ "$(head -1 <<<"$checks")" = select ] && [ "$(tr -cd ';' <<<"$checks" | wc -c | tr -d ' ')" = 1 ] \
  || fail 'the database checks must be a single select statement'
echo 'PASS: the database checks are one select statement'

ALBUS_TEST_STYLE=with-progress run 1
expect_pass 'a list after a progress line' "pending: $NMIG"
ALBUS_TEST_STYLE=garbled run 1
expect_stop 'a migration list that is not JSON' 'could not read the migration list'
ALBUS_TEST_STYLE=no-list run 1
expect_stop 'JSON without a migration list' 'could not read the migration list'
ALBUS_TEST_FUNCTIONS_NULL=1 run 1
expect_pass 'no functions, printed as null' 'breakdown: not live yet'
echo "PASS: the migration list is read as JSON and anything else stops it; null means no functions"

ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE run 1
expect_pass 'good settings' 'Sign-in settings: all as planned.'
ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE ALBUS_TEST_SETTINGS='{"external":{"apple":true,"email":true,"anonymous_users":false},"disable_signup":false}' run 1
expect_pass 'settings with email on' 'DRY RUN FINISHED'
grep -q 'Email provider *on *STILL TO DO: set it off' "$TEST_DIR/output" || fail 'email still on was not flagged'
grep -q 'still to do in the dashboard: Email provider' "$TEST_DIR/output" || fail 'the summary does not name the email provider'
ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE ALBUS_TEST_SETTINGS='{"external":{"apple":false,"email":false,"anonymous_users":true,"github":true},"disable_signup":true}' run 1
for want in 'Sign in with Apple *off *STILL TO DO' 'Anonymous sign-ins *on *STILL TO DO' 'New sign-ups *closed *STILL TO DO' 'Other sign-in providers *github *STILL TO DO'; do
  grep -q "$want" "$TEST_DIR/output" || fail "not flagged: $want"
done
ALBUS_PUBLISHABLE_KEY=not-a-key run 1
expect_pass 'a malformed publishable key' 'not a publishable key'
! called 'auth/v1/settings' || fail 'a malformed key was sent to the settings page'
printf '%s\n' "$PUBLISHABLE" > "$TEST_DIR/typed"
ALBUS_TTY="$TEST_DIR/typed" run 1
expect_pass 'a key typed at the prompt' 'Sign-in settings: all as planned.'
for secret in "$TOKEN" "sb_secret_$(printf '%030d' 7)" "eyJ$(printf '%030d' 7)"; do
  printf '%s\n' "$secret" > "$TEST_DIR/typed"
  ALBUS_TTY="$TEST_DIR/typed" run 1
  expect_pass 'a secret typed at the key prompt' 'That was a secret, not the publishable key'
  ! grep -q -- "${secret:0:12}" "$TEST_DIR/output" "$ALBUS_TEST_LOG" || fail 'a secret typed at the key prompt was shown or used'
  ! called 'auth/v1/settings' || fail 'a secret typed at the key prompt was sent'
done
ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE ALBUS_TEST_SETTINGS_STATUS=401 ALBUS_TEST_SETTINGS='{"message":"Invalid API key"}' run 1
expect_pass 'a key Supabase refuses' 'Sign-in settings: not checked (Supabase answered 401'
! grep -q 'STILL TO DO' "$TEST_DIR/output" || fail 'a refused key was read as settings'
ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE ALBUS_TEST_SETTINGS='{"message":"something else"}' run 1
expect_pass 'an answer without settings' 'not checked (an answer this script does not recognise)'
! grep -q 'STILL TO DO' "$TEST_DIR/output" || fail 'an answer without settings was read as settings'
echo 'PASS: the dashboard settings are checked and each wrong one is flagged, without blocking the setup; secrets typed at that prompt are refused unseen, and a refused key is not read as settings'

ALBUS_TEST_APPLIED_COUNT=10 run 1
expect_pass 'a partly applied project' "already applied: 10; pending: $((NMIG - 10))"
ALBUS_TEST_PRESET_PUSHED=1 run 1
expect_pass 'a fully applied project' 'pending: 0'
echo 'PASS: a half-applied project resumes, and a finished one has nothing pending'

ALBUS_TEST_REMOTE_ONLY=29991231999999 run 1
expect_stop 'a migration only the server knows' 'unrecognized remote migrations: 29991231999999'
V30=$(ls "$ROOT"/supabase/migrations | sed -n 30p | cut -d_ -f1)
ALBUS_TEST_APPLIED_VERSIONS=$V30 run 1
expect_stop 'a gap in the applied migrations' 'older than the newest applied one'
echo 'PASS: a migration only the server knows, or a gap, stops it'

OLD_COPY="$TEST_DIR/old-ref.sh"
sed 's/^REF=yqhzmgikkawxjzvdjvsf$/REF=ssvehwhblgqtvqkfbkbj/' "$ROOT/scripts/$SCRIPT" > "$OLD_COPY"
run 1 "$OLD_COPY"
expect_stop 'the old project' 'that is the old project'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran before the old-project guard'
echo 'PASS: pointed at the old project, it stops before running anything'

SRC="$TEST_DIR/source"; mkdir -p "$SRC"; cp -R "$ROOT/supabase" "$SRC/supabase"; rm -rf "$SRC/supabase/.temp"
printf '\n-- changed\n' >> "$SRC/supabase/migrations/$(ls "$SRC/supabase/migrations" | head -1)"
ALBUS_TEST_SOURCE_OVERRIDE="$SRC" run 1
expect_stop 'a changed migration' 'configuration differs from what was reviewed (the database changes)'
rm -rf "$SRC"; mkdir -p "$SRC"; cp -R "$ROOT/supabase" "$SRC/supabase"; rm -rf "$SRC/supabase/.temp"
printf '\n// changed\n' >> "$SRC/supabase/functions/delete-account/handler.ts"
ALBUS_TEST_SOURCE_OVERRIDE="$SRC" run 1
expect_stop 'a changed function' 'configuration differs from what was reviewed (function source or config.toml)'
! called 'supabase link' || fail 'it linked to the project after a fingerprint mismatch'
echo 'PASS: changed database changes or function code stop it before it touches the project'

ALBUS_SOURCE="$ROOT" run 1
expect_pass 'a preview of supplied source' 'Previewing supplied candidate source'
! called 'git clone' || fail 'a preview of supplied source still cloned main'
ALBUS_SOURCE="$SRC" run 1
expect_stop 'a preview of changed supplied source' 'configuration differs from what was reviewed'
ALBUS_SOURCE="$SRC" run 0
expect_pass 'a real run with supplied source set' '^DONE:'
called 'git clone' || fail 'the real run did not read main'
! grep -q 'Previewing supplied' "$TEST_DIR/output" || fail 'the real run used supplied source'
echo 'PASS: supplied source can only be previewed, and is fingerprinted like main'

# Prefixes, not subshells: a subshell would keep STATUS from expect_stop.
SUPABASE_ACCESS_TOKEN= run 1
expect_stop 'no token' 'could not ask for the access token'
SUPABASE_ACCESS_TOKEN='not-a-token' run 1
expect_stop 'a malformed token' 'does not look like a Supabase access token'
! grep -q 'not-a-token' "$TEST_DIR/output" || fail 'a malformed token was echoed back'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran with a bad token'
echo 'PASS: a missing or malformed token stops it, and is never echoed'
SUPABASE_ACCESS_TOKEN="$TOKEN$TOKEN" run 1
expect_stop 'a token pasted twice' 'if you pasted it twice'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran with a token pasted twice'
SUPABASE_ACCESS_TOKEN="sbp_v0_$(printf '%040d' 7)" run 1
expect_pass 'a token in the newer sbp_v0_ style' 'DRY RUN FINISHED'
echo 'PASS: a token pasted twice stops it unshown; the newer token style is accepted'
for old in 2.98.2 2.116.9 1.250.0 'not a version'; do
  ALBUS_TEST_CLI_VERSION=$old run 1
  expect_stop "Supabase tool $old" 'needs 2.117 or newer'
  [ ! -s "$ALBUS_TEST_LOG" ] || fail "a command ran with Supabase tool $old"
done
for new in 2.117.0 'supabase 3.0.1'; do
  ALBUS_TEST_CLI_VERSION=$new run 1
  expect_pass "Supabase tool $new" 'DRY RUN FINISHED'
done
echo 'PASS: a Supabase tool older than 2.117 stops it before anything runs'
SUPABASE_PROJECT_ID=ssvehwhblgqtvqkfbkbj SUPABASE_DB_PASSWORD=x run 1
expect_pass 'stray SUPABASE_ settings in the shell' 'DRY RUN FINISHED'
echo 'PASS: SUPABASE_ settings left in the shell never reach the CLI'

ALBUS_TEST_LINK_FAILS=1 run 1
expect_stop 'a token that cannot reach the project' 'cannot reach the new project'
ALBUS_TEST_LIVE=revenuecat-webhook ALBUS_TEST_WRONG_JWT=revenuecat-webhook run 1
expect_stop 'a live function with the wrong policy' 'already live with the wrong sign-in check'
ALBUS_TEST_EXTRA_FUNCTION=old-thing run 1
expect_stop 'an unexpected function' 'an unexpected function is live: old-thing'
ALBUS_TEST_NO_PLATFORM_KEYS=1 run 1
expect_stop 'missing platform keys' 'is not injected'
ALBUS_TEST_SECRETS='ALBUS_SUPABASE_SECRET_KEY' run 1
expect_stop 'an override key' 'would win over the new keys'
echo 'PASS: an unreachable project, a wrong live policy, an unknown function and bad keys each stop it'

ALBUS_TEST_SECRETS='ANTHROPIC_API_KEY APPLE_CLIENT_ID' run 1
expect_pass 'secret names' 'ANTHROPIC_API_KEY: set'
grep -q 'APPLE_PRIVATE_KEY: not set yet' "$TEST_DIR/output" || fail 'a missing secret was not reported'
grep -q 'REVENUECAT_APP_IDS: not set yet' "$TEST_DIR/output" || fail 'REVENUECAT_APP_IDS was not reported'
! grep -q '0000000000' "$TEST_DIR/output" || fail 'a secret digest was printed'
echo 'PASS: secret names are reported, never their digests'

# ---- the real run
run 0
expect_pass 'the real run' '^DONE:'
push=$(line_of 'supabase db push'); query=$(line_of 'supabase db query')
d1=$(line_of 'functions deploy breakdown'); d2=$(line_of 'functions deploy grade')
d3=$(line_of 'functions deploy delete-account'); d4=$(line_of 'functions deploy revenuecat-webhook')
[ -n "$push" ] && [ -n "$query" ] && [ -n "$d1" ] && [ "$push" -lt "$query" ] && [ "$query" -lt "$d1" ] \
  && [ "$d1" -lt "$d2" ] && [ "$d2" -lt "$d3" ] && [ "$d3" -lt "$d4" ] || fail 'expected push, the checks, then the four deploys in order'
[ "$(grep -c -- '--no-verify-jwt' "$ALBUS_TEST_LOG")" = 1 ] && grep 'functions deploy revenuecat-webhook' "$ALBUS_TEST_LOG" | grep -q -- '--no-verify-jwt' \
  || fail 'only the webhook may be deployed without the gateway sign-in check'
[ "$(grep -c '^supabase functions deploy' "$ALBUS_TEST_LOG")" = 4 ] || fail 'expected exactly four deploys'
[ "$(grep -c 'supabase link' "$ALBUS_TEST_LOG")" = 1 ] && grep 'supabase link' "$ALBUS_TEST_LOG" | grep -q 'yqhzmgikkawxjzvdjvsf' || fail 'it did not link to the new project'
! grep -q 'ssvehwhblgqtvqkfbkbj' "$ALBUS_TEST_LOG" || fail 'the old project was named in a command'
for n in breakdown grade delete-account; do grep -q "$n: answers a request with no sign-in with 401" "$TEST_DIR/output" || fail "$n probe"; done
grep -q 'revenuecat-webhook: answers a request with no sign-in with 503' "$TEST_DIR/output" || fail 'webhook probe'
echo 'PASS: the real run applies the changes, checks the database, deploys all four, and probes each'

ALBUS_TEST_PRESET_PUSHED=1 ALBUS_TEST_PRESET_DEPLOYED='breakdown grade delete-account revenuecat-webhook' ALBUS_TEST_STATUS_WEBHOOK=401 run 0
expect_pass 'a re-run of a finished setup' '^DONE:'
! called 'supabase db push' || fail 'a re-run pushed again'
grep -q 'breakdown: live at version 1; this redeploys it' "$TEST_DIR/output" || fail 'live functions not reported as redeploys'
echo 'PASS: running again after everything is done skips the push, redeploys, and accepts a 401 from the webhook'

ALBUS_PUBLISHABLE_KEY=$PUBLISHABLE ALBUS_TEST_SETTINGS='{"external":{"apple":true,"email":true,"anonymous_users":false},"disable_signup":false}' run 0
expect_pass 'a real run with email still on' '^DONE:'
[ "$(tail -2 "$TEST_DIR/output" | head -1)" = 'Sign-in settings: still to do in the dashboard: Email provider.' ] || fail 'the closing summary did not repeat what is still to do'
echo 'PASS: the closing message repeats what is still to do in the dashboard'

ALBUS_TEST_FALSE_CHECK=anon_has_no_table_access run 0
expect_stop 'a failed database check' 'the checks did not all pass, so nothing was deployed'
grep -q 'anon_has_no_table_access: False' "$TEST_DIR/output" || fail 'the failed check was not shown'
! called 'functions deploy' || fail 'it deployed after a failed database check'
ALBUS_TEST_QUERY_FAILS=1 run 0
expect_stop 'checks that could not run' 'the checks could not run, so nothing was deployed'
! called 'functions deploy' || fail 'it deployed after checks that could not run'
ALBUS_TEST_PUSH_FAILS=1 run 0
expect_stop 'a failed push' 'error applying the database changes, so nothing was deployed'
! called 'db query' || fail 'it ran the checks after a failed push'
! called 'functions deploy' || fail 'it deployed after a failed push'
echo 'PASS: a failed push, unrunnable checks or a failed check each stop it before anything is deployed'

ALBUS_TEST_DEPLOY_FAILS=grade run 0
expect_stop 'a failed second deploy' 'breakdown deployed, but grade did not; running this again is safe'
! called 'functions deploy delete-account' || fail 'it carried on after a failed deploy'
ALBUS_TEST_DEPLOY_FAILS=revenuecat-webhook run 0
expect_stop 'a failed last deploy' 'three functions deployed, but revenuecat-webhook did not'
echo 'PASS: a failed deploy stops it and says a re-run is safe'

ALBUS_TEST_WRONG_JWT=delete-account ALBUS_TEST_LIVE='' run 0
expect_stop 'a function that comes up with the wrong policy' 'is not live with the right sign-in check'
! called 'curl.*functions/v1' || fail 'it probed after a wrong policy'
ALBUS_TEST_STATUS_DELETE=200 run 0
expect_stop 'a function that answers without a sign-in' 'delete-account answered 200 to a request with no sign-in'
ALBUS_TEST_STATUS_WEBHOOK=200 run 0
expect_stop 'a webhook that answers without a password' 'revenuecat-webhook answered 200'
! grep -q '^DONE:' "$TEST_DIR/output" || fail 'it said DONE after a failed probe'
ALBUS_TEST_WEBHOOK_BODY='{"code":"BOOT_ERROR","message":"Worker failed to boot"}' run 0
expect_stop 'a webhook that did not start' 'revenuecat-webhook answered 503 without saying NOT_CONFIGURED'
echo 'PASS: a wrong live policy, a function that answers without a sign-in, or a webhook that did not start stops it'
echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
