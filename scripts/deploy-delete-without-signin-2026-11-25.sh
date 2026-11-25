#!/usr/bin/env bash
# Felipe-run: puts the "delete without signing in again" PR on the Albus
# project (25 Nov 2026). Run it only after that PR is merged, and before build
# 3 reaches anyone.
# Preview: DRY_RUN=1 bash scripts/deploy-delete-without-signin-2026-11-25.sh
# Apply:   DRY_RUN=0 bash scripts/deploy-delete-without-signin-2026-11-25.sh
#
# Deleting an account revokes Sign in with Apple, which needs a token Apple
# issued for the account. Until now that meant Apple's sign-in sheet right
# before deleting. The PR keeps the token at sign-in instead. Two parts, in
# this order:
#
# 1. Database: migration 20261125180000 adds private.apple_refresh_tokens (only
#    a Vault secret's id per account; the token itself is encrypted in Vault)
#    and two functions only the server can call, to keep and to take a token.
# 2. Functions: apple-token (new: keeps the token at sign-in) and delete-account
#    (revokes with a kept token, or asks for Apple's sheet as before) are
#    deployed from main. Both keep their sign-in check. No secrets change: they
#    use the APPLE_* secrets set on 8 Oct.
#
# The database goes first: both functions call what it adds.
#
# Before anything, it checks that GitHub's main holds exactly what was
# reviewed, and that the project lacks this one database change and no other.
# After, it checks with read-only queries that the table and functions are in
# place and closed to students, that both functions are live with their
# sign-in check on, and that each refuses a request with no sign-in.
#
# It asks for the albus-setup access token (typing is hidden) instead of using
# the login saved on this Mac, which belongs to the OLD project, and refuses the
# old project. It needs Supabase CLI 2.117 or newer.
#
# Safe to run again: once the change is applied, it only checks and redeploys
# the same functions.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
URL="https://$REF.supabase.co"
CHANGE=20261125180000
# Every migration file's name and contents on main, as reviewed.
MIGRATIONS_DIGEST=b94e83750b1e608739ec83c1fcd4c91ef3a3e21be6bde7c0817cfd77bfe7e69c
# config.toml and every function source file on main, as reviewed.
SOURCE_DIGEST=351573b83e7029d9e777b901eaf36ab4a823e7d331c4fb06ed26c2d43e19e3d9
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
TTY=${ALBUS_TTY:-/dev/tty}   # the tests point this at /dev/null; nothing else sets it
[ "$REF" != "$OLD_REF" ] || stop 'that is the old project, which this script must never touch'
for tool in git supabase python3 comm curl; do command -v "$tool" >/dev/null || stop "missing $tool"; done
# Only this run's token may steer the CLI. Any other SUPABASE_* setting left in
# the shell is dropped: SUPABASE_PROJECT_ID, for one, wins over the linked project.
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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-delete-signin.XXXXXX")
trap 'rm -rf "${STAGE:?}"' EXIT
if [ "$DRY_RUN" = 1 ] && [ -n "${ALBUS_SOURCE:-}" ]; then
  echo 'Previewing supplied candidate source; this does not establish that it is merged.'
  mkdir -p "$STAGE/repo"
  cp -R "$ALBUS_SOURCE/supabase" "$STAGE/repo/supabase"
  rm -rf "${STAGE:?}/repo/supabase/.temp"
else
  echo 'Reading a fresh copy of GitHub main.'
  git clone --quiet --depth 1 --branch main https://github.com/fgutort8-droid/albus.git "$STAGE/repo"
fi
cd "$STAGE/repo"
ACTUAL=$(python3 - <<'PY'
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
[ "$(sed -n 1p <<<"$ACTUAL")" = "$MIGRATIONS_DIGEST" ] \
  || stop 'the database changes on main differ from what was reviewed; has the PR been merged? If it has, ask Claude for a new script'
[ "$(sed -n 2p <<<"$ACTUAL")" = "$SOURCE_DIGEST" ] \
  || stop 'the function source on main differs from what was reviewed; has the PR been merged? If it has, ask Claude for a new script'
echo "Verified database changes SHA-256: $MIGRATIONS_DIGEST"
echo "Verified function source SHA-256: $SOURCE_DIGEST"

supabase link --project-ref "$REF" </dev/null >/dev/null \
  || stop 'this access token cannot reach the new project; make it in the account that owns the project'
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'
echo "Linked to the new project $REF."

lines() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort; }
# Sets PENDING. Stops unless the list names exactly the files on main, the
# project holds nothing else, and nothing but this one change is missing: an
# unreadable list must never look like "nothing pending".
compare() {
  local parsed files local_list remote_list remote_only
  supabase migration list --linked --output-format json > "$STAGE/migrations.json" </dev/null \
    || stop 'could not read migration history'
  parsed=$(python3 - "$STAGE/migrations.json" <<'PY'
import json,sys
rows=None
for line in open(sys.argv[1]):
 try: d=json.loads(line)
 except ValueError: continue
 if isinstance(d,dict) and isinstance(d.get('migrations'),list): rows=d['migrations']
if rows is None or not all(isinstance(r,dict) for r in rows): sys.exit(1)
for side in ('local','remote'):
 print(' '.join(v for v in (r.get(side) for r in rows) if isinstance(v,str) and v.isdigit()))
PY
) || stop 'could not read the migration list; stopping rather than guessing'
  local_list=$(lines "$(sed -n 1p <<<"$parsed")" | xargs)
  remote_list=$(lines "$(sed -n 2p <<<"$parsed")" | xargs)
  files=$(for f in supabase/migrations/*.sql; do v=$(basename "$f"); echo "${v%%_*}"; done | sort | xargs)
  [ -n "$local_list" ] && [ "$local_list" = "$files" ] \
    || stop 'could not read the migration list, or it does not match main; stopping rather than guessing'
  remote_only=$(comm -13 <(lines "$local_list") <(lines "$remote_list") | xargs)
  [ -z "$remote_only" ] || stop "the project has database changes main does not: $remote_only"
  PENDING=$(comm -23 <(lines "$local_list") <(lines "$remote_list") | xargs)
  [ -z "$PENDING" ] || [ "$PENDING" = "$CHANGE" ] \
    || stop "the project is missing other database changes too ($PENDING); this script applies only $CHANGE"
}

# Reads, never writes. One plain select: Supabase CLI 2.122 sends the file as a
# single prepared statement, which refuses several. Before the change the
# table and functions are absent; after it they are present, and nothing a
# student holds can reach the functions.
cat > "$STAGE/state.sql" <<'SQL'
select
 to_regclass('private.apple_refresh_tokens') is not null as table_present,
 (to_regprocedure('public.store_apple_refresh_token(uuid,text)') is not null
   and to_regprocedure('public.take_apple_refresh_token(uuid)') is not null) as functions_present,
 coalesce(to_regprocedure('public.take_apple_refresh_token(uuid)') is not null
   and to_regprocedure('public.store_apple_refresh_token(uuid,text)') is not null
   and (has_function_privilege('authenticated', 'public.take_apple_refresh_token(uuid)', 'execute')
     or has_function_privilege('anon', 'public.take_apple_refresh_token(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.store_apple_refresh_token(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.store_apple_refresh_token(uuid,text)', 'execute')),
   false) as students_can_reach;
SQL
# Sets STATE to "table_present=… functions_present=… students_can_reach=…",
# or stops with the reason given.
read_state() {
  supabase db query --linked --file "$STAGE/state.sql" --output json > "$STAGE/state.json" </dev/null \
    || stop "$1"
  STATE=$(python3 - "$STAGE/state.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows') if isinstance(j,dict) else j
keys=('table_present','functions_present','students_can_reach')
if not (isinstance(r,list) and len(r)==1 and isinstance(r[0],dict) and set(r[0])==set(keys)
        and all(type(r[0][k]) is bool for k in keys)): sys.exit(1)
print(' '.join(k+'='+str(r[0][k]).lower() for k in keys))
PY
) || stop "$1"
}
BEFORE_STATE='table_present=false functions_present=false students_can_reach=false'
AFTER_STATE='table_present=true functions_present=true students_can_reach=false'

# delete-account must already be live; apple-token is new, so before the
# deploy it may be absent. After it, both are live with the sign-in check on.
functions_state() {
  supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null \
    || stop 'could not read the live functions'
  python3 - "$STAGE/functions.json" "$1" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])) or []
rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
if not isinstance(rows,list) or not all(isinstance(r,dict) for r in rows): sys.exit('could not read the live functions; tell Claude')
for name in ('delete-account','apple-token'):
 m=[r for r in rows if r.get('slug',r.get('name'))==name]
 if sys.argv[2]=='before':
  if not m:
   if name=='apple-token':
    print('apple-token: not live yet; this deploys it'); continue
   sys.exit(name+' is not live on the project; this script only updates it, so tell Claude')
  if len(m)!=1: sys.exit(name+' is listed more than once; tell Claude')
  if m[0].get('verify_jwt') is not True: sys.exit(name+' is live without its sign-in check; tell Claude')
  print(name+': live at version '+str(m[0].get('version'))+'; this redeploys it')
 else:
  if len(m)!=1 or m[0].get('verify_jwt') is not True or m[0].get('status','ACTIVE')!='ACTIVE':
   sys.exit(name+' is not live with its sign-in check on; tell Claude before anything else')
  print(name+': live at version '+str(m[0].get('version'))+', sign-in check on')
PY
}

probe() {
  local name=$1 status
  rm -f "$STAGE/answer.json"
  status=$(curl -s -o "$STAGE/answer.json" -w '%{http_code}' --max-time 30 -X POST "$URL/functions/v1/$name" \
    -H 'Content-Type: application/json' -d '{}' || true)
  [ "$status" = 401 ] \
    || stop "deployed, but $name answered $status to a request with no sign-in (expected 401); tell Claude before anything else"
  echo "$name: refuses a request with no sign-in (401), as it should."
}

compare
read_state 'could not read the database'
echo "Now: $STATE"
if [ -z "$PENDING" ]; then
  [ "$STATE" = "$AFTER_STATE" ] || stop "the change $CHANGE is recorded as applied, but the database is not as reviewed; tell Claude"
  echo "The change $CHANGE is already applied."
else
  [ "$STATE" = "$BEFORE_STATE" ] || stop 'the database is not what this change was written against; tell Claude'
  echo "Pending: $CHANGE (keeps each account's Apple token, encrypted, for deleting without a sign-in)."
fi
functions_state before || stop 'the functions are not as expected; tell Claude'

if [ "$DRY_RUN" = 1 ]; then
  [ -z "$PENDING" ] || echo "[dry run] would apply $CHANGE, then check the database with a read-only query"
  echo '[dry run] would deploy delete-account and apple-token from main, then check both refuse a request with no sign-in'
  echo 'DRY RUN FINISHED: nothing was changed.'
  exit 0
fi

if [ -n "$PENDING" ]; then
  supabase db push --yes </dev/null \
    || stop 'Supabase reported an error applying the change; tell Claude'
  compare
  [ -z "$PENDING" ] || stop 'the change is still pending after the push; tell Claude'
  echo "Applied $CHANGE."
fi
read_state 'the change is applied, but the check could not run; tell Claude'
echo "After: $STATE"
[ "$STATE" = "$AFTER_STATE" ] || stop 'the change is applied, but the database is not as reviewed; tell Claude'

supabase functions deploy delete-account --project-ref "$REF" --use-api </dev/null \
  || stop 'the database change is in, but delete-account did not deploy; running this again is safe'
supabase functions deploy apple-token --project-ref "$REF" --use-api </dev/null \
  || stop 'the database change is in and delete-account deployed, but apple-token did not; running this again is safe'
functions_state after || stop 'the functions deployed, but not as reviewed; tell Claude before anything else'
probe delete-account
probe apple-token
echo 'DONE: Apple tokens are kept at sign-in, and deleting an account revokes with them;'
echo 'delete-account and apple-token are live from main and refuse requests with no sign-in.'
echo 'Nothing else changed. Build 3 can go out now.'
