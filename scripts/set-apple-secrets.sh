#!/usr/bin/env bash
# Felipe-run: puts the four Sign in with Apple secrets into the live project,
# so delete-account can revoke Apple's tokens when a student deletes their
# account. The key never reaches the screen, terminal history or a file that
# outlives this run.
#
# Run: bash scripts/set-apple-secrets.sh /path/to/AuthKey_XXXXXXXXXX.p8
#
# The key ID is read from the file name Apple gives it; the team ID is asked
# for (it is not secret, but it stays out of this public repository). The
# client ID is the app's bundle ID.
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
CLIENT_ID=com.felipegutierrez.albus
NAMES='APPLE_TEAM_ID APPLE_KEY_ID APPLE_PRIVATE_KEY APPLE_CLIENT_ID'
# Before the secrets are sent, a stop changes nothing. From then on, they may
# be set, and sending the same four again is safe.
stop() { echo "STOPPED: $*; nothing was set." >&2; exit 1; }
stop_after_sending() { echo "STOPPED: $*. They may or may not be set; running this again is safe. Tell Claude." >&2; exit 1; }
for tool in supabase python3 openssl; do command -v "$tool" >/dev/null || stop "missing $tool"; done
[ $# -eq 1 ] || stop 'give the path to the .p8 file Apple let you download'
KEY_FILE=$1
[ -f "$KEY_FILE" ] || stop "no file at $KEY_FILE"
# A Sign in with Apple key is a P-256 private key in PKCS#8 form. Check that
# without printing any of it.
grep -q -- '-----BEGIN PRIVATE KEY-----' "$KEY_FILE" || stop 'that file is not a .p8 private key'
# Public half only: the private numbers are never printed, even to a pipe.
CURVE=$(openssl pkey -in "$KEY_FILE" -noout -text_pub 2>/dev/null) \
  || stop 'that file is not a private key openssl can read'
grep -Eq 'prime256v1|P-256' <<<"$CURVE" \
  || stop 'that file is not a P-256 private key, which a Sign in with Apple key is'
KEY_ID=$(basename "$KEY_FILE" | sed -nE 's/^AuthKey_([A-Z0-9]{10})\.p8$/\1/p')
if [ -z "$KEY_ID" ]; then
  read -r -p 'Key ID (10 capital letters and digits, shown with the key in Apple Developer): ' KEY_ID
fi
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || stop 'a key ID is 10 capital letters and digits'
read -r -p 'Team ID (10 capital letters and digits, top right in Apple Developer): ' TEAM_ID
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || stop 'a team ID is 10 capital letters and digits'

umask 077
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-apple-secrets.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
# The key goes in as one line with \n for each line break; delete-account
# turns them back into line breaks.
python3 - "$KEY_FILE" "$STAGE/apple.env" "$TEAM_ID" "$KEY_ID" "$CLIENT_ID" <<'PY'
import sys
key_file, env_file, team, key_id, client = sys.argv[1:]
key = open(key_file).read().replace('\r', '').strip()
assert all(c.isalnum() or c in '+/=- \n' for c in key), 'unexpected characters in the key file'
with open(env_file, 'w') as f:
    f.write('APPLE_TEAM_ID=' + team + '\n')
    f.write('APPLE_KEY_ID=' + key_id + '\n')
    f.write('APPLE_CLIENT_ID=' + client + '\n')
    f.write('APPLE_PRIVATE_KEY="' + key.replace('\n', '\\n') + '"\n')
PY
supabase secrets set --project-ref "$REF" --env-file "$STAGE/apple.env" </dev/null >/dev/null \
  || stop_after_sending 'Supabase reported an error setting the secrets'
supabase secrets list --project-ref "$REF" --output json > "$STAGE/secrets.json" </dev/null \
  || stop_after_sending 'the secrets were sent, but their names could not be read back'
# Names only. The list also carries a digest of each value; it is never printed.
python3 - "$STAGE/secrets.json" $NAMES <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('secrets',rows) if isinstance(rows,dict) else rows
names={r.get('name') for r in rows if isinstance(r,dict)}
missing=[n for n in sys.argv[2:] if n not in names]
if missing: sys.exit('STOPPED: sent, but not listed: '+', '.join(missing)+'. Running this again is safe. Tell Claude.')
print('Set: '+', '.join(sys.argv[2:])+'. No value was shown or saved.')
PY
echo 'Tell Claude, who checks them next.'
