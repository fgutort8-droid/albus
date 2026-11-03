#!/usr/bin/env bash
# Felipe-run: puts the new Albus project's secrets in place (27 Oct 2026).
# Preview: DRY_RUN=1 bash scripts/set-secrets-2026-10-27.sh
# Set:     DRY_RUN=0 bash scripts/set-secrets-2026-10-27.sh
#
# Four secrets. None appears on screen, in the chat, in a saved file or in the
# list of running programs, so Claude never sees them:
#   1. ANTHROPIC_API_KEY: you make a new key in the Anthropic console and copy
#      it; this reads it from the clipboard and checks Anthropic accepts it.
#   2. ALBUS_SIGNAL_PEPPER: made here at random, and kept if already set.
#   3. REVENUECAT_WEBHOOK_SECRET: made here, then put on your clipboard to
#      paste into RevenueCat's webhook, after its new address.
#   4. REVENUECAT_WEBHOOK_SIGNING_SECRET: RevenueCat makes it; you copy it,
#      and this reads it from the clipboard.
# The clipboard is emptied after each one, and when the script ends, however
# it ends.
#
# Safe to run again: each run replaces 1, 3 and 4. Nothing here can grant a
# plan: until both webhook passwords match, the server refuses every delivery.
# REVENUECAT_APP_IDS and the APPLE_* secrets come later, once the App Store app
# and the Sign in with Apple key exist.
#
# It asks for the albus-setup access token (typing is hidden), never uses the
# login saved on this Mac, which belongs to the OLD project, and refuses the
# old project. It needs Supabase CLI 2.117 or newer.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
WEBHOOK_URL="https://$REF.supabase.co/functions/v1/revenuecat-webhook"
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
TTY=${ALBUS_TTY:-/dev/tty}   # the tests point this at a file; nothing else sets it
[ "$REF" != "$OLD_REF" ] || stop 'that is the old project, which this script must never touch'
for tool in supabase openssl pbcopy pbpaste python3 curl; do command -v "$tool" >/dev/null || stop "missing $tool"; done
# Only this run's token may steer the CLI. Any other SUPABASE_* setting left in
# the shell is dropped: SUPABASE_PROJECT_ID, for one, wins over --project-ref.
for name in $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$name" = SUPABASE_ACCESS_TOKEN ] || unset "$name"
done
CLI_VERSION=$(supabase --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
IFS=. read -r cli_major cli_minor _ <<<"${CLI_VERSION:-0.0.0}"
[ "$cli_major" -gt 2 ] || { [ "$cli_major" -eq 2 ] && [ "$cli_minor" -ge 117 ]; } \
  || stop "the Supabase tool here is version ${CLI_VERSION:-unknown}, and this needs 2.117 or newer; run: brew upgrade supabase/tap/supabase"

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  read -r -s -p 'Paste the albus-setup access token (typing is hidden), then press Enter: ' SUPABASE_ACCESS_TOKEN <"$TTY" \
    || stop 'could not ask for the access token; run this in a Terminal tab'
  echo
fi
[[ "$SUPABASE_ACCESS_TOKEN" =~ ^sbp_([a-z][a-z0-9]{0,7}_)?[a-f0-9]{40}$ ]] \
  || stop 'that does not look like a Supabase access token (sbp_ and 40 more letters and digits); if you pasted it twice, run this again and paste it once'
export SUPABASE_ACCESS_TOKEN

WORK=$(mktemp -d "${TMPDIR:-/tmp}/albus-secrets.XXXXXX")
chmod 700 "$WORK"
cleanup() {
  rm -rf "$WORK"
  [ "$DRY_RUN" = 1 ] || pbcopy </dev/null || true
}
trap cleanup EXIT

pause() { read -r -p '   Press Enter only once that is done. ' _ <"$TTY" || stop 'waiting for you'; }

# Stores NAME=VALUE through a file only you can read, deleted straight after,
# so the value is never on a command line.
store() {
  local file="$WORK/$1.env"
  ( umask 077; printf '%s=%s\n' "$1" "$2" > "$file" )
  if [ "$DRY_RUN" = 1 ]; then
    rm -f "$file"
    echo "   [dry run] would store $1"
    return 0
  fi
  if ! supabase secrets set --project-ref "$REF" --env-file "$file" </dev/null > "$WORK/out" 2>&1; then
    rm -f "$file"
    sed -n 1,5p "$WORK/out" >&2
    return 1
  fi
  rm -f "$file"
  echo "   Stored $1."
}

# What a copy button gives: one unbroken run of ordinary characters, none of
# which the server's settings file reads as a quote, comment or variable. The
# length is checked apart from the pattern: macOS's matcher can't count past 255.
looks_like_secret() {
  [ "${#1}" -ge 20 ] && [ "${#1}" -le 512 ] && [[ "$1" =~ ^[A-Za-z0-9_+/=.:@%~,-]+$ ]]
}
# An API key, not an admin key: functions must never hold an admin key.
looks_like_anthropic_key() {
  [[ "$1" == sk-ant-api* ]] && [ "${#1}" -ge 40 ] && [ "${#1}" -le 300 ] && [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}
# Asks Anthropic whether it accepts the key: a free request that lists models,
# with the key in a header file only you can read, so it never shows in ps.
anthropic_accepts() {
  ( umask 077; printf 'x-api-key: %s\n' "$1" > "$WORK/anthropic.header" )
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H @"$WORK/anthropic.header" \
    -H 'anthropic-version: 2023-06-01' https://api.anthropic.com/v1/models || true)
  rm -f "$WORK/anthropic.header"
  [ "$status" = 200 ]
}

# 32 random bytes as 64 hex digits, or stop: an empty or short secret must
# never be stored, and a failure inside $(...) would otherwise go unnoticed.
random_hex() {
  local value
  value=$(openssl rand -hex 32) && [[ "$value" =~ ^[0-9a-f]{64}$ ]] || stop "making $1"
  printf '%s' "$value"
}

names() {
  supabase secrets list --project-ref "$REF" --output json > "$WORK/names.json" </dev/null \
    || stop 'could not reach the new project with this token'
  # Names only: the list also carries a digest of each value, never printed.
  python3 -c 'import json,sys; rows=json.load(open(sys.argv[1])) or []; print(" ".join(sorted(r.get("name","") for r in rows if isinstance(r,dict))))' \
    "$WORK/names.json" || stop 'could not read the secret names'
}

echo '== Step 0 of 4: can this Mac reach the new project?'
BEFORE=" $(names) "
for n in ANTHROPIC_API_KEY ALBUS_SIGNAL_PEPPER REVENUECAT_WEBHOOK_SECRET REVENUECAT_WEBHOOK_SIGNING_SECRET; do
  case "$BEFORE" in *" $n "*) echo "   $n: set now; this replaces it" ;; *) echo "   $n: not set yet" ;; esac
done
case "$BEFORE" in *" ALBUS_SIGNAL_PEPPER "*) KEEP_PEPPER=1 ;; *) KEEP_PEPPER=0 ;; esac

if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would read a new Anthropic key from your clipboard, check Anthropic accepts it, and store it'
  if [ "$KEEP_PEPPER" = 1 ]; then
    echo '[dry run] would keep ALBUS_SIGNAL_PEPPER as it is'
  else
    PEPPER=$(random_hex 'the signal pepper')
    store ALBUS_SIGNAL_PEPPER "$PEPPER"
  fi
  echo "[dry run] would put the new webhook address on your clipboard: $WEBHOOK_URL"
  AUTH=$(random_hex 'the Authorization password')
  store REVENUECAT_WEBHOOK_SECRET "$AUTH"
  echo "[dry run] would read RevenueCat's signing secret from your clipboard and store it"
  echo 'DRY RUN FINISHED: no secrets were changed.'
  exit 0
fi

echo '== Step 1 of 4: the Anthropic API key'
echo '   At platform.claude.com:'
echo '     1. Settings, then Limits: check the monthly spend limit is the one you chose.'
echo '     2. API keys: create a key named albus-new, then click its copy button.'
echo "        Don't paste it anywhere: this script reads it from the clipboard."
tries=0
while :; do
  pause
  KEY=$(pbpaste)
  if ! looks_like_anthropic_key "$KEY"; then
    echo '   The clipboard does not hold an Anthropic API key (it starts sk-ant-api). Copy it again.'
  elif ! anthropic_accepts "$KEY"; then
    echo '   Anthropic did not accept that key. Copy the new albus-new key again.'
  else
    break
  fi
  tries=$((tries + 1))
  [ "$tries" -lt 3 ] || stop 'reading the Anthropic key (tell Claude: the key check refused it)'
done
store ANTHROPIC_API_KEY "$KEY" || stop 'storing the Anthropic key on the server'
unset KEY
pbcopy </dev/null
echo '   Anthropic accepts it. Clipboard emptied.'

echo '== Step 2 of 4: the signal pepper'
if [ "$KEEP_PEPPER" = 1 ]; then
  echo '   Already set; kept, so earlier abuse signals still match.'
else
  PEPPER=$(random_hex 'the signal pepper')
  store ALBUS_SIGNAL_PEPPER "$PEPPER" || stop 'storing the signal pepper on the server'
  unset PEPPER
fi

echo "== Step 3 of 4: point RevenueCat's webhook at the new server"
printf '%s' "$WEBHOOK_URL" | pbcopy
echo "   The new address is on your clipboard: $WEBHOOK_URL"
echo '   In RevenueCat: Integrations, then Webhooks, then Albus server.'
echo '     1. Click in "Webhook URL", select what is there, and press Cmd+V.'
pause
AUTH=$(random_hex 'the Authorization password')
store REVENUECAT_WEBHOOK_SECRET "$AUTH" || stop 'storing the Authorization password on the server'
printf '%s' "$AUTH" | pbcopy
echo '   The Authorization password is on your clipboard now.'
echo '     2. Click in "Authorization header value", select what is there, and press'
echo "        Cmd+V. It shows as dots; that's right."
echo '     3. Click Save.'
pause
pbcopy </dev/null
echo '   Clipboard emptied.'

echo '== Step 4 of 4: the signing secret'
echo '   On the same page, by "Enable HMAC webhook signing":'
echo '     1. Click "Rotate secret" for a new one, then the copy button next to it.'
echo "        Don't paste it anywhere: this script reads it from the clipboard."
echo '     2. Click Save if RevenueCat asks.'
tries=0
while :; do
  pause
  SIGN=$(pbpaste)
  if [ "$SIGN" = "$AUTH" ] || [ "$SIGN" = "$WEBHOOK_URL" ]; then
    echo '   That is still what this script put on your clipboard. Copy the signing secret instead.'
  elif looks_like_secret "$SIGN"; then
    break
  else
    echo '   The clipboard does not hold a signing secret. Click the copy button next to it.'
  fi
  tries=$((tries + 1))
  [ "$tries" -lt 4 ] || stop 'reading the signing secret (tell Claude: the secret check refused it)'
done
store REVENUECAT_WEBHOOK_SIGNING_SECRET "$SIGN" || stop 'storing the signing secret on the server'
unset AUTH SIGN
pbcopy </dev/null
echo '   Clipboard emptied.'

echo '== Final check'
AFTER=" $(names) "
for n in ANTHROPIC_API_KEY ALBUS_SIGNAL_PEPPER REVENUECAT_WEBHOOK_SECRET REVENUECAT_WEBHOOK_SIGNING_SECRET; do
  case "$AFTER" in *" $n "*) ;; *) stop "the server does not list $n" ;; esac
done
echo '   The server lists all four.'
# The webhook answered 503 while its passwords were missing; with them set, a
# request without the password is refused with 401. A new secret reaches the
# function within seconds, so a 503 is asked again a few times first.
for try in 1 2 3 4 5; do
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$WEBHOOK_URL" \
    -H 'Content-Type: application/json' -d '{}' || true)
  [ "$status" != 503 ] || [ "$try" = 5 ] || { sleep "${ALBUS_PROBE_WAIT:-3}"; continue; }
  break
done
[ "$status" = 401 ] || stop "the webhook answered $status to a request without its password (expected 401); tell Claude"
echo '   The webhook now refuses a request without its password (401), as it should.'
echo 'DONE: the four secrets are set. In RevenueCat, click "Send test event" on the'
echo 'same page; it should show 200. Tell Claude what it shows.'
