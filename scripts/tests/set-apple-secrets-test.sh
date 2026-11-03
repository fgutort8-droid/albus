#!/usr/bin/env bash
# Exercise the owner's Apple-secrets helper with a throwaway key and a local CLI
# double; no network. The double keeps the env file it is handed, so the test
# can check its shape, and that the key never reached the screen.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/albus-apple-secrets-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export ALBUS_TEST_LOG="$TEST_DIR/calls" ALBUS_TEST_ENV_COPY="$TEST_DIR/received.env"
# A stand-in built at run time, so nothing token-shaped sits in the repository.
TOKEN="sbp_$(printf '%040d' 7)"
export SUPABASE_ACCESS_TOKEN=$TOKEN
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/supabase" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" != --version ] || { echo "${ALBUS_TEST_CLI_VERSION:-2.122.0}"; exit 0; }
printf '%s\n' "$*" >> "$ALBUS_TEST_LOG"
[ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo 'no token reached the CLI' >&2; exit 98; }
if env | grep '^SUPABASE_' | grep -qv '^SUPABASE_ACCESS_TOKEN='; then echo 'a stray SUPABASE_ setting reached the CLI' >&2; exit 97; fi
case "$1 $2" in
  'secrets set')
    [ -z "${ALBUS_TEST_SET_FAILS:-}" ] || exit 1
    while [ $# -gt 0 ]; do
      if [ "$1" = --env-file ]; then cp "$2" "$ALBUS_TEST_ENV_COPY"; fi
      shift
    done ;;
  'secrets list')
    [ -z "${ALBUS_TEST_LIST_FAILS:-}" ] || exit 1
    printf '[{"name":"SUPABASE_URL","value":"00"}'
    if [ -f "$ALBUS_TEST_ENV_COPY" ] && [ -z "${ALBUS_TEST_DROP:-}" ]; then
      sed -nE 's/^([A-Z_]+)=.*/,{"name":"\1","value":"00"}/p' "$ALBUS_TEST_ENV_COPY" | tr -d '\n'
    fi
    printf ']\n' ;;
  *) echo 'Unexpected CLI command' >&2; exit 99 ;;
esac
STUB
chmod +x "$TEST_DIR/bin/supabase"
KEY="$TEST_DIR/AuthKey_ABCDE12345.p8"
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null \
  | openssl pkcs8 -topk8 -nocrypt -out "$KEY" 2>/dev/null
BODY=$(sed -n 2p "$KEY")

run() { # the key file, then what is typed at the prompts, one line each
  local key=$1; shift
  rm -f "$ALBUS_TEST_ENV_COPY"; : > "$ALBUS_TEST_LOG"
  printf '%s\n' "$@" > "$TEST_DIR/typed"
  set +e
  ALBUS_TTY="${ALBUS_TTY:-$TEST_DIR/typed}" PATH="$TEST_DIR/bin:$PATH" bash "$ROOT/scripts/set-apple-secrets.sh" "$key" \
    > "$TEST_DIR/output" 2>&1
  STATUS=$?
  set -e
  ! grep -qF -- "$BODY" "$TEST_DIR/output" || { echo 'FAIL: key material reached the screen' >&2; exit 1; }
  ! grep -qF -- "$TOKEN" "$TEST_DIR/output" "$ALBUS_TEST_LOG" || { echo 'FAIL: the access token reached the screen or a command line' >&2; exit 1; }
}
nothing_set() { ! grep -q 'secrets set' "$ALBUS_TEST_LOG"; }

# Bash prints read's question on stderr, so a 2> on a read hides the question.
token_read=$(grep -E '^[[:space:]]*read .*SUPABASE_ACCESS_TOKEN' "$ROOT/scripts/set-apple-secrets.sh")
grep -q -- ' -s ' <<<"$token_read" && ! grep -q -- '2>' <<<"$token_read" \
  || { echo 'FAIL: the token prompt must hide typing and show its question' >&2; exit 1; }

run "$KEY" 'TEAMID1234'
[ "$STATUS" -eq 0 ] || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a valid key was refused' >&2; exit 1; }
grep -q '^APPLE_KEY_ID=ABCDE12345$' "$ALBUS_TEST_ENV_COPY" || { echo 'FAIL: key ID not read from the file name' >&2; exit 1; }
grep -q '^APPLE_TEAM_ID=TEAMID1234$' "$ALBUS_TEST_ENV_COPY" || { echo 'FAIL: team ID not passed' >&2; exit 1; }
grep -q '^APPLE_CLIENT_ID=com.felipegutierrez.albus$' "$ALBUS_TEST_ENV_COPY" || { echo 'FAIL: client ID wrong' >&2; exit 1; }
[ "$(grep -c '^APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\\n.*\\n-----END PRIVATE KEY-----"$' "$ALBUS_TEST_ENV_COPY")" = 1 ] \
  || { echo 'FAIL: private key is not one quoted line with \n breaks' >&2; exit 1; }
[ "$(wc -l < "$ALBUS_TEST_ENV_COPY" | tr -d ' ')" = 4 ] || { echo 'FAIL: env file is not exactly four lines' >&2; exit 1; }
grep -q 'No value was shown or saved' "$TEST_DIR/output" || { echo 'FAIL: names not confirmed' >&2; exit 1; }
[ "$(grep -c -- '--project-ref yqhzmgikkawxjzvdjvsf' "$ALBUS_TEST_LOG")" = 2 ] && ! grep -q ssvehwhblgqtvqkfbkbj "$ALBUS_TEST_LOG" \
  || { cat "$ALBUS_TEST_LOG" >&2; echo 'FAIL: the secrets did not go to the new project, and only there' >&2; exit 1; }
leftover=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'albus-apple-secrets.*' -newer "$KEY" 2>/dev/null | head -1)
[ -z "$leftover" ] || { echo "FAIL: the env file outlived the run ($leftover)" >&2; exit 1; }
echo 'PASS: a valid key sets four secrets in the new project as one-line values, and nothing is left behind'

SUPABASE_ACCESS_TOKEN='' run "$KEY" 'TEAMID1234' "$TOKEN"
[ "$STATUS" -eq 0 ] && grep -q 'No value was shown or saved' "$TEST_DIR/output" \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a token typed at the prompt was not used' >&2; exit 1; }
SUPABASE_ACCESS_TOKEN='' run "$KEY" 'TEAMID1234' "$TOKEN$TOKEN"
[ "$STATUS" -ne 0 ] && grep -q 'paste it once' "$TEST_DIR/output" && nothing_set \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a token pasted twice was not refused before setting anything' >&2; exit 1; }
SUPABASE_ACCESS_TOKEN='' ALBUS_TTY=/dev/null run "$KEY"
[ "$STATUS" -ne 0 ] && grep -q 'run this in a Terminal tab' "$TEST_DIR/output" && nothing_set \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: no terminal to ask in did not stop it before setting anything' >&2; exit 1; }
ALBUS_TEST_CLI_VERSION=2.98.2 run "$KEY" 'TEAMID1234'
[ "$STATUS" -ne 0 ] && grep -q 'needs 2.117 or newer' "$TEST_DIR/output" && [ ! -s "$ALBUS_TEST_LOG" ] \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: an old Supabase CLI was used' >&2; exit 1; }
SUPABASE_PROJECT_ID=ssvehwhblgqtvqkfbkbj SUPABASE_DB_PASSWORD=x run "$KEY" 'TEAMID1234'
[ "$STATUS" -eq 0 ] || { cat "$TEST_DIR/output" >&2; echo 'FAIL: stray SUPABASE_ settings were not dropped' >&2; exit 1; }
echo 'PASS: a typed token is used, a malformed token, no terminal or an old CLI stops it before anything is set, and stray settings are dropped'

openssl ecparam -name secp384r1 -genkey -noout 2>/dev/null \
  | openssl pkcs8 -topk8 -nocrypt -out "$TEST_DIR/AuthKey_WRONG12345.p8" 2>/dev/null
run "$TEST_DIR/AuthKey_WRONG12345.p8" 'TEAMID1234'
[ "$STATUS" -ne 0 ] && grep -q 'not a P-256 private key' "$TEST_DIR/output" && nothing_set \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a key on the wrong curve was not refused before setting anything' >&2; exit 1; }
echo 'PASS: a key on the wrong curve is refused before anything is set'

run "$KEY" 'not-an-id'
[ "$STATUS" -ne 0 ] && grep -q 'a team ID is 10 capital letters and digits' "$TEST_DIR/output" && nothing_set \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a malformed team ID was not refused before setting anything' >&2; exit 1; }
cp "$KEY" "$TEST_DIR/key-renamed.p8"
run "$TEST_DIR/key-renamed.p8" 'ABCDE12345' 'TEAMID1234'
[ "$STATUS" -eq 0 ] && grep -q '^APPLE_KEY_ID=ABCDE12345$' "$ALBUS_TEST_ENV_COPY" \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: a key ID typed for a renamed file was not used' >&2; exit 1; }
echo 'PASS: a malformed team ID is refused before anything is set; a renamed file asks for its key ID'

ALBUS_TEST_DROP=1 run "$KEY" 'TEAMID1234'
[ "$STATUS" -ne 0 ] && grep -q 'sent, but not listed: APPLE_TEAM_ID' "$TEST_DIR/output" \
  || { cat "$TEST_DIR/output" >&2; echo 'FAIL: secrets missing after setting were not reported' >&2; exit 1; }
echo 'PASS: secrets that do not read back are reported'

# Once the secrets have been sent, no message may claim nothing changed.
for failing in ALBUS_TEST_SET_FAILS ALBUS_TEST_LIST_FAILS; do
  export "$failing=1"
  run "$KEY" 'TEAMID1234'
  unset "$failing"
  [ "$STATUS" -ne 0 ] && grep -q 'may or may not be set; running this again is safe' "$TEST_DIR/output" \
    && ! grep -q 'nothing was set' "$TEST_DIR/output" \
    || { cat "$TEST_DIR/output" >&2; echo "FAIL: $failing was misreported" >&2; exit 1; }
done
echo 'PASS: a failure after sending never says nothing was set'
echo 'PASS: the Apple-secrets helper never shows the key or the token, and checks what it set.'
