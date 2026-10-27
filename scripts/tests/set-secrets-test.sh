#!/usr/bin/env bash
# Exercise the owner's secrets script for the new project, preview and real
# run, with local doubles for the Supabase CLI, the clipboard and curl; no
# network. The clipboard double serves what the owner would copy, in order,
# and keeps a history of what the script put there. Every secret value is
# checked never to reach the output or a command line.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=set-secrets-2026-10-27.sh
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-secrets-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_STATE="$TEST_DIR/state" ALBUS_PROBE_WAIT=0
export ALBUS_TTY="$TEST_DIR/enter"
# Enter, pressed as often as the script asks.
printf '\n%.0s' $(seq 1 30) > "$ALBUS_TTY"
# Stand-ins built at run time, so nothing secret-shaped sits in the repository.
TOKEN="sbp_$(printf '%040d' 7)"
GOOD_KEY="sk-ant-api03-$(printf '%086d' 7)AA"
OTHER_KEY="sk-ant-api03-$(printf '%086d' 8)AA"
ADMIN_KEY="sk-ant-admin01-$(printf '%086d' 7)AA"
SIGN="rc_whsec_$(printf '%040d' 9)"
URL=https://yqhzmgikkawxjzvdjvsf.supabase.co/functions/v1/revenuecat-webhook
mkdir -p "$TEST_DIR/bin" "$ALBUS_TEST_STATE"

cat > "$TEST_DIR/bin/supabase" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != --version ] || { echo "${ALBUS_TEST_CLI_VERSION:-2.122.0}"; exit 0; }
printf 'supabase %s\n' "$*" >> "$ALBUS_TEST_LOG"
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo 'no token reached the CLI' >&2; exit 98; }
if env | grep '^SUPABASE_' | grep -qv '^SUPABASE_ACCESS_TOKEN='; then echo 'a stray SUPABASE_ setting reached the CLI' >&2; exit 97; fi
case "$1 ${2:-}" in
  'secrets list')
    [ -z "${ALBUS_TEST_LIST_FAILS:-}" ] || exit 1
    python3 - <<'PY'
import json,os
state=os.environ['ALBUS_TEST_STATE']
names=['SUPABASE_URL','SUPABASE_SECRET_KEYS','SUPABASE_PUBLISHABLE_KEYS']+os.environ.get('ALBUS_TEST_PRESET','').split()
if os.path.exists(state+'/stored'):
    names+=[l.split('=',1)[0] for l in open(state+'/stored').read().splitlines()]
if os.environ.get('ALBUS_TEST_DROP'): names=[n for n in names if n!=os.environ['ALBUS_TEST_DROP']]
print(json.dumps([{'name':n,'value':'00'*32} for n in sorted(set(names))]))
PY
    ;;
  'secrets set')
    file=; prev=
    for a in "$@"; do [ "$prev" = --env-file ] && file=$a; prev=$a; done
    [ -n "$file" ] || { echo 'expected --env-file' >&2; exit 96; }
    mode=$(python3 -c 'import os,sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$file")
    [ "$mode" = 600 ] || { echo "the env file was mode $mode, not 600" >&2; exit 95; }
    name=$(cut -d= -f1 < "$file")
    [ "$name" != "${ALBUS_TEST_SET_FAILS:-}" ] || exit 1
    cat "$file" >> "$ALBUS_TEST_STATE/stored"
    printf 'set %s\n' "$name" >> "$ALBUS_TEST_LOG" ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB

cat > "$TEST_DIR/bin/pbcopy" <<'STUB'
#!/usr/bin/env bash
cat > "$ALBUS_TEST_STATE/clipboard"
{ cat "$ALBUS_TEST_STATE/clipboard"; echo; } >> "$ALBUS_TEST_STATE/copied"
echo pbcopy >> "$ALBUS_TEST_LOG"
STUB

# What the owner copies, one line per paste, in order: "@clipboard" means they
# copied nothing new, "@auth" the Authorization password again.
cat > "$TEST_DIR/bin/pbpaste" <<'STUB'
#!/usr/bin/env bash
echo pbpaste >> "$ALBUS_TEST_LOG"
q="$ALBUS_TEST_STATE/pastes"
next=$(head -1 "$q" 2>/dev/null || true)
[ ! -s "$q" ] || { tail -n +2 "$q" > "$q.next"; mv "$q.next" "$q"; }
case "$next" in
  ''|@clipboard) cat "$ALBUS_TEST_STATE/clipboard" 2>/dev/null || true ;;
  @auth) sed -n 's/^REVENUECAT_WEBHOOK_SECRET=//p' "$ALBUS_TEST_STATE/stored" | tail -1 ;;
  *) printf '%s\n' "$next" ;;
esac
STUB

cat > "$TEST_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$ALBUS_TEST_LOG"
case "$*" in
  *api.anthropic.com*)
    header=; prev=
    for a in "$@"; do [ "$prev" = -H ] && [[ "$a" == @* ]] && header=${a#@}; prev=$a; done
    key=$(sed -n 's/^x-api-key: //p' "$header" 2>/dev/null || true)
    [[ " $ALBUS_TEST_ACCEPTED_KEYS " == *" $key "* ]] && printf 200 || printf 401 ;;
  *functions/v1/revenuecat-webhook*)
    if grep -q '^REVENUECAT_WEBHOOK_SECRET=' "$ALBUS_TEST_STATE/stored" 2>/dev/null; then
      printf '%s' "${ALBUS_TEST_WEBHOOK_STATUS:-401}"
    else printf 503; fi ;;
  *) exit 99 ;;
esac
STUB
# The real generator, unless a case makes it fail.
REAL_OPENSSL=$(command -v openssl)
cat > "$TEST_DIR/bin/openssl" <<STUB
#!/usr/bin/env bash
[ -z "\${ALBUS_TEST_OPENSSL_FAILS:-}" ] || exit 1
exec "$REAL_OPENSSL" "\$@"
STUB
chmod +x "$TEST_DIR/bin/"*
export ALBUS_TEST_ACCEPTED_KEYS=$GOOD_KEY

run() { # DRY_RUN value, then what the owner copies, in order
  local dry=$1; shift
  rm -f "$ALBUS_TEST_STATE"/*; : > "$ALBUS_TEST_LOG"
  printf '%s\n' "$@" > "$ALBUS_TEST_STATE/pastes"
  set +e
  PATH="$TEST_DIR/bin:$PATH" DRY_RUN=$dry bash "${SCRIPT_PATH:-$ROOT/scripts/$SCRIPT}" > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  # No secret may reach the output or a command line: the stand-ins, and what
  # the script made and stored itself.
  local secret
  for secret in "$TOKEN" "$GOOD_KEY" "$OTHER_KEY" "$ADMIN_KEY" "$SIGN" \
    $(cut -s -d= -f2- "$ALBUS_TEST_STATE/stored" 2>/dev/null); do
    if grep -qF -- "$secret" "$TEST_DIR/output" "$ALBUS_TEST_LOG"; then
      echo 'FAIL: a secret reached the output or a command line' >&2; exit 1
    fi
  done
}
fail() { cat "$TEST_DIR/output" >&2; echo "--- calls:" >&2; cat "$ALBUS_TEST_LOG" >&2; echo "FAIL: $1" >&2; exit 1; }
stored() { cut -d= -f1 "$ALBUS_TEST_STATE/stored" 2>/dev/null | xargs; }
value_of() { sed -n "s/^$1=//p" "$ALBUS_TEST_STATE/stored" | tail -1; }
clipboard() { cat "$ALBUS_TEST_STATE/clipboard" 2>/dev/null || true; }
expect_pass() { [ "$STATUS" -eq 0 ] || fail "$1"; grep -q -- "$2" "$TEST_DIR/output" || fail "$1 (no '$2')"; }
expect_stop() {
  [ "$STATUS" -ne 0 ] || fail "$1 did not stop"
  grep -q -- "$2" "$TEST_DIR/output" || fail "$1 stopped for the wrong reason (wanted '$2')"
  ! grep -q -E '^(DRY RUN FINISHED|DONE:)' "$TEST_DIR/output" || fail "$1 finished anyway"
}
export SUPABASE_ACCESS_TOKEN=$TOKEN

reads=$(grep -E '^[[:space:]]*(read |pause\(\) \{ read )' "$ROOT/scripts/$SCRIPT")
grep -q 'read -r -s -p .Paste the albus-setup access token' <<<"$reads" || fail 'the token prompt does not hide typing'
! grep -- '2>' <<<"$reads" || fail 'a prompt hides its own question'
echo 'PASS: the token prompt hides typing, and no prompt hides its question'

run 1
expect_pass 'the preview' 'DRY RUN FINISHED: no secrets were changed.'
[ -z "$(stored)" ] || fail 'the preview stored a secret'
! grep -q -E '^(pbcopy|pbpaste)$' "$ALBUS_TEST_LOG" || fail 'the preview touched the clipboard'
grep -q 'ANTHROPIC_API_KEY: not set yet' "$TEST_DIR/output" || fail 'the preview did not report what is set'
echo 'PASS: the preview reports what is set, stores nothing and leaves the clipboard alone'

run 0 "$GOOD_KEY" "$SIGN"
expect_pass 'the real run' '^DONE: the four secrets are set'
[ "$(stored)" = 'ANTHROPIC_API_KEY ALBUS_SIGNAL_PEPPER REVENUECAT_WEBHOOK_SECRET REVENUECAT_WEBHOOK_SIGNING_SECRET' ] \
  || fail "stored in the wrong order or set: $(stored)"
[ "$(value_of ANTHROPIC_API_KEY)" = "$GOOD_KEY" ] || fail 'the Anthropic key stored is not the one copied'
[ "$(value_of REVENUECAT_WEBHOOK_SIGNING_SECRET)" = "$SIGN" ] || fail 'the signing secret stored is not the one copied'
[[ "$(value_of REVENUECAT_WEBHOOK_SECRET)" =~ ^[0-9a-f]{64}$ ]] && [[ "$(value_of ALBUS_SIGNAL_PEPPER)" =~ ^[0-9a-f]{64}$ ]] \
  || fail 'the generated password or pepper is not 64 random hex digits'
[ -z "$(head -1 "$ALBUS_TEST_STATE/copied")" ] || fail 'the clipboard was not emptied right after the Anthropic key'
grep -qxF "$URL" "$ALBUS_TEST_STATE/copied" || fail 'the new webhook address was never put on the clipboard'
grep -qxF "$(value_of REVENUECAT_WEBHOOK_SECRET)" "$ALBUS_TEST_STATE/copied" || fail 'the clipboard never held the stored Authorization password'
[ -z "$(clipboard)" ] || fail 'the clipboard was left holding something'
grep -q 'The webhook now refuses a request without its password (401)' "$TEST_DIR/output" || fail 'the webhook was not checked'
grep 'supabase secrets set' "$ALBUS_TEST_LOG" | grep -qv -- '--project-ref yqhzmgikkawxjzvdjvsf' && fail 'a secret went to another project'
! grep -q ssvehwhblgqtvqkfbkbj "$ALBUS_TEST_LOG" || fail 'the old project was named in a command'
echo 'PASS: the real run stores all four, the copied ones exactly, and leaves the clipboard empty'

ALBUS_TEST_PRESET='ALBUS_SIGNAL_PEPPER' run 0 "$GOOD_KEY" "$SIGN"
expect_pass 'a re-run with a pepper already set' '^DONE:'
! grep -qw ALBUS_SIGNAL_PEPPER <<<"$(stored)" || fail 'an existing pepper was replaced'
grep -q 'Already set; kept' "$TEST_DIR/output" || fail 'keeping the pepper was not said'
echo 'PASS: an existing pepper is kept, so earlier abuse signals still match'

run 0 hello "$GOOD_KEY" "$SIGN"
expect_pass 'a wrong copy, then the key' '^DONE:'
grep -q 'does not hold an Anthropic API key' "$TEST_DIR/output" || fail 'a wrong copy was not explained'
# Even if Anthropic accepted an admin key, the functions must never hold one.
ALBUS_TEST_ACCEPTED_KEYS="$GOOD_KEY $ADMIN_KEY" run 0 "$ADMIN_KEY" "$ADMIN_KEY" "$ADMIN_KEY"
expect_stop 'an admin key' 'reading the Anthropic key'
grep -q 'does not hold an Anthropic API key' "$TEST_DIR/output" || fail 'an admin key was not refused as one'
[ -z "$(stored)" ] || fail 'something was stored after the key was refused'
[ -z "$(clipboard)" ] || fail 'the clipboard was left holding something after a stop'
run 0 "$OTHER_KEY" "$OTHER_KEY" "$OTHER_KEY"
expect_stop 'a key Anthropic refuses' 'reading the Anthropic key'
grep -q 'Anthropic did not accept that key' "$TEST_DIR/output" || fail 'a refused key was not explained'
[ -z "$(stored)" ] || fail 'a key Anthropic refuses was stored'
echo 'PASS: only an API key that Anthropic accepts is stored; an admin key never is'

run 0 "$GOOD_KEY" @auth "$SIGN"
expect_pass 'the password copied again, then the signing secret' '^DONE:'
grep -q 'still what this script put on your clipboard' "$TEST_DIR/output" || fail 'pasting the password back was not caught'
[ "$(value_of REVENUECAT_WEBHOOK_SIGNING_SECRET)" = "$SIGN" ] || fail 'the wrong signing secret was stored'
run 0 "$GOOD_KEY" @clipboard "$SIGN"
expect_pass 'nothing copied, then the signing secret' '^DONE:'
grep -q 'does not hold a signing secret' "$TEST_DIR/output" || fail 'an empty clipboard was not explained'
[ "$(value_of REVENUECAT_WEBHOOK_SIGNING_SECRET)" = "$SIGN" ] || fail 'the wrong signing secret was stored'
run 0 "$GOOD_KEY" 'has spaces in it so it is not one' x x x
expect_stop 'no signing secret copied' 'reading the signing secret'
echo "PASS: the signing secret must be RevenueCat's, not what the script copied"

ALBUS_TEST_SET_FAILS=REVENUECAT_WEBHOOK_SECRET run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a failed store' 'storing the Authorization password on the server'
grep -qxF "$URL" "$ALBUS_TEST_STATE/copied" || fail 'the address step did not run first'
[ "$(grep -c -E '^[0-9a-f]{64}$' "$ALBUS_TEST_STATE/copied" || true)" = 0 ] || fail 'an unstored password reached the clipboard'
[ -z "$(clipboard)" ] || fail 'the clipboard was left holding something after a failed store'
ALBUS_TEST_DROP=REVENUECAT_WEBHOOK_SIGNING_SECRET run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a secret missing from the final list' 'the server does not list REVENUECAT_WEBHOOK_SIGNING_SECRET'
ALBUS_TEST_WEBHOOK_STATUS=503 run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a webhook still not configured' 'answered 503 to a request without its password'
ALBUS_TEST_WEBHOOK_STATUS=200 run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a webhook that accepts no password' 'answered 200'
echo 'PASS: a failed store, a missing secret or a webhook that does not refuse stops it'

ALBUS_TEST_OPENSSL_FAILS=1 run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a generator that fails for the pepper' 'making the signal pepper'
! grep -qw ALBUS_SIGNAL_PEPPER <<<"$(stored)" || fail 'a pepper was stored although none was made'
ALBUS_TEST_PRESET=ALBUS_SIGNAL_PEPPER ALBUS_TEST_OPENSSL_FAILS=1 run 0 "$GOOD_KEY" "$SIGN"
expect_stop 'a generator that fails for the password' 'making the Authorization password'
! grep -qw REVENUECAT_WEBHOOK_SECRET <<<"$(stored)" || fail 'a password was stored although none was made'
[ -z "$(clipboard)" ] || fail 'the clipboard was left holding something after a failed generator'
ALBUS_TEST_OPENSSL_FAILS=1 run 1
expect_stop 'a preview whose generator fails' 'making the signal pepper'
echo 'PASS: a random generator that fails stops it, and no empty secret is ever stored'

ALBUS_TEST_LIST_FAILS=1 run 0
expect_stop 'an unreachable project' 'could not reach the new project'
SUPABASE_ACCESS_TOKEN="$TOKEN$TOKEN" run 0
expect_stop 'a token pasted twice' 'if you pasted it twice'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran with a token pasted twice'
ALBUS_TEST_CLI_VERSION=2.98.2 run 0
expect_stop 'an old Supabase tool' 'needs 2.117 or newer'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran with an old Supabase tool'
OLD_COPY="$TEST_DIR/old-ref.sh"
sed 's/^REF=yqhzmgikkawxjzvdjvsf$/REF=ssvehwhblgqtvqkfbkbj/' "$ROOT/scripts/$SCRIPT" > "$OLD_COPY"
SCRIPT_PATH=$OLD_COPY run 0
expect_stop 'the old project' 'that is the old project'
[ ! -s "$ALBUS_TEST_LOG" ] || fail 'a command ran before the old-project guard'
SUPABASE_PROJECT_ID=ssvehwhblgqtvqkfbkbj run 1
expect_pass 'a stray SUPABASE_ setting in the shell' 'DRY RUN FINISHED'
echo 'PASS: an unreachable project, a bad token, an old CLI or the old project stops it before anything is stored'
echo "PASS: $SCRIPT preview and real run, with every safeguard failing in turn."
