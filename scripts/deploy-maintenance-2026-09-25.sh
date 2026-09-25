#!/usr/bin/env bash
# Felipe-run maintenance update. Default is read-only preview.
# DRY_RUN=1 ALBUS_SOURCE=/path/to/reviewed/albus bash this-script.sh
# After the PR is merged: DRY_RUN=0 bash this-script.sh
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
EXPECTED=20260925140000
MIGRATION=20260925140000_maintenance_account_guards.sql
DIGEST=e40cb3951bde22572d726066290980e96056be896e21e346041400b655c50e3f
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3 shasum; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-maintenance-deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

if [ "$DRY_RUN" = 1 ] && [ -n "${ALBUS_SOURCE:-}" ]; then
  echo 'Previewing the reviewed source supplied by ALBUS_SOURCE; this does not establish that it is merged.'
  mkdir -p "$STAGE/repo/supabase"
  cp "$ALBUS_SOURCE/supabase/config.toml" "$STAGE/repo/supabase/config.toml"
  cp -R "$ALBUS_SOURCE/supabase/migrations" "$STAGE/repo/supabase/migrations"
else
  echo 'Reading a fresh copy of GitHub main.'
  git clone --quiet --depth 1 --branch main https://github.com/fgutort8-droid/albus.git "$STAGE/repo"
fi
cd "$STAGE/repo"
[ -f "supabase/migrations/$MIGRATION" ] || stop 'merge the reviewed maintenance PR first'
ACTUAL=$(shasum -a 256 "supabase/migrations/$MIGRATION" | awk '{print $1}')
[ "$ACTUAL" = "$DIGEST" ] || stop 'migration does not match the reviewed fingerprint'
echo "Verified migration SHA-256: $ACTUAL"
# Link only this disposable folder. No existing checkout is accessed.
supabase link --project-ref "$REF" </dev/null
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'

compare() {
  local out
  out=$(supabase migration list --linked </dev/null) || stop 'could not read migration history'
  REMOTE_ONLY=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(r~/^[0-9]+$/ && l=="")print r}' <<<"$out" | xargs)
  PENDING=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(l~/^[0-9]+$/ && r=="")print l}' <<<"$out" | xargs)
  [ -z "$REMOTE_ONLY" ] || stop "unrecognized remote migrations: $REMOTE_ONLY"
  [ -z "$PENDING" ] || [ "$PENDING" = "$EXPECTED" ] || stop "unexpected pending migrations: $PENDING"
}
compare
echo "Pending migration: ${PENDING:-none}"
if [ -n "$PENDING" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    echo '[dry run] would apply exactly this migration with supabase db push --yes'
  else
    supabase db push --yes </dev/null
    compare
    [ -z "$PENDING" ] || stop 'migration is still pending after applying it'
  fi
else
  echo 'Migration already recorded; checking the installed controls.'
fi

cat > "$STAGE/verify.sql" <<'SQL'
select
  md5(pg_get_functiondef('public.reap_abandoned_anonymous_users(integer)'::regprocedure)) = '217ecaa512edba2cfc1e08b35f84c5ef' as cleanup_matches,
  md5(pg_get_functiondef('public.transfer_subscriptions(uuid[],uuid,text,timestamptz)'::regprocedure)) = '14abf53c159905dbc5e3ffa418ff9dfd' as transfer_matches,
  md5(pg_get_functiondef('public.prune_security_data(integer,integer)'::regprocedure)) = '3a504da1c10fbefb9f1764f721e8f0e5' as prune_unchanged,
  not has_function_privilege('anon','public.reap_abandoned_anonymous_users(integer)','execute') as anon_closed,
  not has_function_privilege('authenticated','public.reap_abandoned_anonymous_users(integer)','execute') as client_closed,
  has_function_privilege('service_role','public.reap_abandoned_anonymous_users(integer)','execute') as service_allowed,
  exists(select 1 from cron.job where jobname='reap-abandoned-anonymous' and active and schedule='17 4 * * *' and command='select public.reap_abandoned_anonymous_users(30)') as cleanup_scheduled,
  exists(select 1 from cron.job where jobname='prune-security-data' and active and schedule='43 4 * * *' and command='select public.prune_security_data(90, 180)') as prune_scheduled;
SQL
if [ "$DRY_RUN" = 1 ] && [ -n "$PENDING" ]; then
  echo '[dry run] would verify installed function fingerprints, grants and both existing schedules; would not invoke either job'
else
  supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verification.json"
  python3 - "$STAGE/verification.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); rows=j.get('rows',[]) if isinstance(j,dict) else j
assert len(rows)==1 and len(rows[0])==8 and all(v is True for v in rows[0].values()), 'Post-deploy verification failed'
for key,value in rows[0].items(): print(key+': '+str(value))
PY
fi
if [ "$DRY_RUN" = 1 ]; then
  echo 'DRY RUN FINISHED: no migrations, deployments or secret changes performed.'
else
  echo 'DONE: maintenance controls verified. Neither maintenance job was manually invoked.'
fi
