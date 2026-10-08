#!/usr/bin/env bash
# Felipe-run: the server half of Sign in with Apple (#35, #36, #37), merged.
# Preview: DRY_RUN=1 bash scripts/deploy-auth-2026-10-08.sh
# Deploy:  DRY_RUN=0 bash scripts/deploy-auth-2026-10-08.sh
#
# 1. Applies 20261006120000_finish_and_release_assignments.sql, and nothing
#    else: the phone can report finished and reopened tasks
#    (sync_my_assignments) and free tasks another phone holds
#    (release_my_other_assignments).
# 2. Deploys the new delete-account function with its gateway JWT check on.
#    breakdown, grade and revenuecat-webhook are unchanged and not redeployed.
# 3. Checks that delete-account refuses a request with no token (401).
# 4. Says which of the four APPLE_* secrets are set, by name only. Setting them
#    is the next step (docs/security/sign-in-runbook.md). Until they are, the
#    function deletes without revoking Apple's token, so they must be in place
#    before the new app build ships.
#
# The current app build calls none of these, so students see no change until
# the new build (#34) ships.
#
# Undo: fix forward. Both database functions and the edge function are new;
# nothing existing is altered.
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
URL="https://$REF.supabase.co"
PREVIOUS=20261001190000
EXPECTED=20261006120000
MIGRATION=20261006120000_finish_and_release_assignments.sql
MIGRATION_DIGEST=2edee99c482251571f38bca1ae8d99810fdb2cdca8ce1e2d20370be729c9eb4b
# Every function source, config.toml, deno.json and deno.lock, as reviewed.
SOURCE_DIGEST=11bc52a493d60a84fbe25dbeacf019d11963d3b5d13aa481590829e84c6bff0a
APPLE_SECRETS='APPLE_TEAM_ID APPLE_KEY_ID APPLE_PRIVATE_KEY APPLE_CLIENT_ID'
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3 shasum curl; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-auth-deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [ "$DRY_RUN" = 1 ] && [ -n "${ALBUS_SOURCE:-}" ]; then
  echo 'Previewing supplied candidate source; this does not establish that it is merged.'
  mkdir -p "$STAGE/repo"
  cp -R "$ALBUS_SOURCE/supabase" "$STAGE/repo/supabase"
  rm -rf "$STAGE/repo/supabase/.temp"
else
  echo 'Reading a fresh copy of GitHub main.'
  git clone --quiet --depth 1 --branch main https://github.com/fgutort8-droid/albus.git "$STAGE/repo"
fi
cd "$STAGE/repo"
[ -f "supabase/migrations/$MIGRATION" ] || stop 'merge #36 first'
[ -f supabase/functions/delete-account/index.ts ] || stop 'merge #35 first'
[ "$(shasum -a 256 "supabase/migrations/$MIGRATION" | awk '{print $1}')" = "$MIGRATION_DIGEST" ] \
  || stop 'migration fingerprint differs from what was reviewed'
ACTUAL=$(python3 - <<'PY'
from pathlib import Path
import hashlib
h=hashlib.sha256(); root=Path('supabase')
paths=sorted([root/'config.toml', *[p for p in (root/'functions').rglob('*')
    if p.is_file() and '_tests' not in p.parts and p.suffix in ('.ts','.json','.lock')]])
for p in paths: h.update(str(p.relative_to(root)).encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
[ "$ACTUAL" = "$SOURCE_DIGEST" ] \
  || stop 'server configuration differs from what was reviewed (function source or config.toml)'
# Pinned by the fingerprint above; checked by name too, so the reason is plain.
awk '/^\[functions\.delete-account\]$/ {f=1; next} /^\[/ {f=0} f && /^verify_jwt = true$/ {ok=1} END {exit !ok}' \
  supabase/config.toml || stop 'config.toml does not turn the JWT check on for delete-account'
echo "Verified migration SHA-256: $MIGRATION_DIGEST"
echo "Verified function source SHA-256: $ACTUAL"

supabase link --project-ref "$REF" </dev/null >/dev/null
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'
compare() {
  local out
  out=$(supabase migration list --linked </dev/null) || stop 'could not read migration history'
  # Different CLI versions draw the table with "|" or "│". Read either, and
  # stop if the newest local change is missing: an unreadable list must never
  # look like "nothing pending".
  out=$(printf '%s\n' "$out" | sed 's/│/|/g')
  awk -F'|' 'NF>=3 {l=$1;gsub(/ /,"",l);if(l~/^[0-9]+$/)print l}' <<<"$out" | grep -qx "$EXPECTED" \
    || stop "could not read the migration list ($EXPECTED not found); stopping rather than guessing"
  awk -F'|' 'NF>=3 {r=$2;gsub(/ /,"",r);if(r~/^[0-9]+$/)print r}' <<<"$out" | grep -qx "$PREVIOUS" \
    || stop "the live database is not at $PREVIOUS; stopping rather than guessing"
  REMOTE_ONLY=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(r~/^[0-9]+$/ && l=="")print r}' <<<"$out" | xargs)
  PENDING=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(l~/^[0-9]+$/ && r=="")print l}' <<<"$out" | xargs)
  [ -z "$REMOTE_ONLY" ] || stop "unrecognized remote migrations: $REMOTE_ONLY"
  case "$PENDING" in ""|"$EXPECTED") ;; *) stop "unexpected pending migrations: $PENDING" ;; esac
  # The reviewed state is exact, not just "contains $PREVIOUS": main's newest
  # change is $EXPECTED, and the live database ends at $PREVIOUS, or at
  # $EXPECTED when this runs again after applying it.
  local latest_local latest_remote
  latest_local=$(awk -F'|' 'NF>=3 {l=$1;gsub(/ /,"",l);if(l~/^[0-9]+$/)print l}' <<<"$out" | sort | tail -1)
  latest_remote=$(awk -F'|' 'NF>=3 {r=$2;gsub(/ /,"",r);if(r~/^[0-9]+$/)print r}' <<<"$out" | sort | tail -1)
  [ "$latest_local" = "$EXPECTED" ] \
    || stop "main has a migration newer than the reviewed one ($latest_local); ask Claude for a new script"
  case "$latest_remote" in
    "$PREVIOUS"|"$EXPECTED") ;;
    *) stop "the live database ends at $latest_remote, not $PREVIOUS or $EXPECTED; stopping rather than guessing" ;;
  esac
}

functions_state() {
  supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null \
    || stop 'could not read the live functions'
  python3 - "$STAGE/functions.json" "$1" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
def find(name): return [r for r in rows if r.get('slug',r.get('name'))==name]
for name,jwt in [('breakdown',True),('grade',True),('revenuecat-webhook',False)]:
 m=find(name)
 if len(m)!=1 or m[0].get('verify_jwt') is not jwt: sys.exit(name+': its live JWT policy is not what was reviewed; tell Claude')
 print(name+': live at version '+str(m[0].get('version'))+', unchanged by this script')
m=find('delete-account')
if sys.argv[2]=='before':
 if m and m[0].get('verify_jwt') is not True: sys.exit('delete-account is already live without its JWT check; tell Claude')
 print('delete-account: '+('live at version '+str(m[0].get('version'))+'; this redeploys it' if m else 'not live yet; this deploys it'))
else:
 if len(m)!=1 or m[0].get('verify_jwt') is not True or m[0].get('status','ACTIVE')!='ACTIVE':
  sys.exit('delete-account is not live with its JWT check on; tell Claude')
 print('delete-account: live at version '+str(m[0].get('version'))+' with its JWT check on')
PY
}

apple_secrets() {
  supabase secrets list --project-ref "$REF" --output json > "$STAGE/secrets.json" </dev/null \
    || stop 'could not read the secret names'
  # Names only. The list also carries a digest of each value; it is never printed.
  python3 - "$STAGE/secrets.json" $APPLE_SECRETS <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('secrets',rows) if isinstance(rows,dict) else rows
names={r.get('name') for r in rows if isinstance(r,dict)}
missing=[n for n in sys.argv[2:] if n not in names]
for n in sys.argv[2:]: print(n+': '+('set' if n in names else 'not set yet'))
print('All four Apple secrets are set.' if not missing else
      'Next step, before the new app build ships: bash scripts/set-apple-secrets.sh /path/to/AuthKey_XXXXXXXXXX.p8 (sets '+', '.join(missing)+')')
PY
}

functions_state before || stop 'the live functions are not as reviewed'
compare
echo "Pending migrations: ${PENDING:-none}"
apple_secrets

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry run] would apply only $MIGRATION, then check both new database functions"
  echo '[dry run] would deploy delete-account with its JWT check on, then check it refuses a request with no token'
  echo 'DRY RUN FINISHED: no migrations, deployments or secret changes performed.'
  exit 0
fi

if [ -n "$PENDING" ]; then
  supabase db push --yes </dev/null \
    || stop 'Supabase reported an error applying the migration, so nothing was deployed; tell Claude'
  compare
  [ -z "$PENDING" ] || stop 'migration still pending'
fi
cat > "$STAGE/verify.sql" <<'SQL'
begin read only;
select
 pg_get_function_identity_arguments('public.sync_my_assignments(uuid[],uuid[])'::regprocedure) = 'p_finished uuid[], p_open uuid[]' as sync_signature,
 pg_get_function_identity_arguments('public.release_my_other_assignments(uuid[])'::regprocedure) = 'p_keep uuid[]' as release_signature,
 (select prosecdef and coalesce(proconfig @> array['search_path=""'],false) from pg_proc where oid='public.sync_my_assignments(uuid[],uuid[])'::regprocedure) as sync_definer_path_closed,
 (select prosecdef and coalesce(proconfig @> array['search_path=""'],false) from pg_proc where oid='public.release_my_other_assignments(uuid[])'::regprocedure) as release_definer_path_closed,
 not has_function_privilege('anon','public.sync_my_assignments(uuid[],uuid[])','execute') as sync_anon_closed,
 not has_function_privilege('anon','public.release_my_other_assignments(uuid[])','execute') as release_anon_closed,
 has_function_privilege('authenticated','public.sync_my_assignments(uuid[],uuid[])','execute') as sync_students_allowed,
 has_function_privilege('authenticated','public.release_my_other_assignments(uuid[])','execute') as release_students_allowed,
 exists(select 1 from pg_trigger where tgname='assignments_active_limit' and tgrelid='public.assignments'::regclass and tgenabled<>'D') as task_cap_trigger_on,
 has_function_privilege('authenticated','public.delete_my_account()','execute') and not has_function_privilege('anon','public.delete_my_account()','execute') as delete_rpc_unchanged,
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)) as definer_paths_closed;
commit;
SQL
supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verify.json" </dev/null \
  || stop 'the migration is applied, but the database checks could not run, so delete-account was not deployed; tell Claude'
python3 - "$STAGE/verify.json" <<'PY' || stop 'the migration is applied, but the database checks did not all pass, so delete-account was not deployed; tell Claude before anything else'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
if len(r)==1 and isinstance(r[0],dict):
 for key,value in r[0].items(): print(key+': '+str(value))
sys.exit(0 if len(r)==1 and len(r[0])==11 and all(v is True for v in r[0].values()) else 1)
PY
supabase functions deploy delete-account --project-ref "$REF" --use-api </dev/null \
  || stop 'the migration is applied and checked, but delete-account did not deploy; running this again is safe'
functions_state after || stop 'delete-account deployed, but not as reviewed; tell Claude before anything else'
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/functions/v1/delete-account" \
  -H 'Content-Type: application/json' -d '{}' || true)
[ "$STATUS" = 401 ] || stop "deployed, but delete-account answered $STATUS instead of refusing a request with no token (401); tell Claude before anything else"
echo 'delete-account refuses a request with no token (401), as it should.'
apple_secrets
echo 'DONE: the task functions are live and checked, delete-account is deployed with its JWT check on. No secrets changed.'
echo 'Send Claude everything this printed.'
