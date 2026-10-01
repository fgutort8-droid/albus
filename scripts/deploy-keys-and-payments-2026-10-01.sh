#!/usr/bin/env bash
# Felipe-run: the server half of #30 (payment events saved before they are
# applied) and of this change (the functions read Supabase's new API keys),
# in one update, since both change what the three functions bundle.
# Preview: DRY_RUN=1 ALBUS_SOURCE=/path/to/reviewed/albus bash this-script.sh
# After #30 and this change are merged: DRY_RUN=0 bash this-script.sh
#
# 1. Applies 20260930143051_financial_event_pipeline.sql, and nothing else.
# 2. Deploys breakdown, grade and revenuecat-webhook with their gateway JWT
#    policies unchanged. No secret changes.
# 3. Wakes the webhook once, so its log shows where its keys come from.
#
# Undo: the migration is not undone, and the webhook is never rolled back
# once events are queued (they would not be processed; fix forward). A
# function rolled back to a version from before the new-key order needs the
# legacy keys active: re-activate them in the dashboard first.
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
URL="https://$REF.supabase.co"
PREVIOUS=20260927171142
EXPECTED=20260930143051
MIGRATION=20260930143051_financial_event_pipeline.sql
MIGRATION_DIGEST=b95329643de8f214286e7a1f71acdf561c48692f754db6792d6535a076cd0752
# Every function source, config.toml, deno.json and deno.lock, as reviewed.
SOURCE_DIGEST=aa054a5a7bd1591bcf7d04e864d835d385d2a32053a26d0d09a8931d587ed4e9
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3 shasum curl; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-keys-payments-deploy.XXXXXX")
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
[ -f "supabase/migrations/$MIGRATION" ] || stop 'merge #30 first'
[ "$(shasum -a 256 "supabase/migrations/$MIGRATION" | awk '{print $1}')" = "$MIGRATION_DIGEST" ] \
  || stop 'migration fingerprint differs from what was reviewed'
grep -q 'export function keySources' supabase/functions/_shared/auth.ts || stop 'merge the new-key change first'
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
[ "$ACTUAL" = "$SOURCE_DIGEST" ] || stop 'function source differs from what was reviewed'
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
}

supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null
python3 - "$STAGE/functions.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
for name in ['breakdown','grade','revenuecat-webhook']:
 matches=[r for r in rows if r.get('slug',r.get('name'))==name]
 assert len(matches)==1 and matches[0].get('verify_jwt') is (name != 'revenuecat-webhook'), name+': verify existing JWT policy before proceeding'
 print(name+': live now at version '+str(matches[0].get('version'))+'; gateway JWT policy matches')
PY
supabase secrets list --project-ref "$REF" --output json > "$STAGE/secrets.json" </dev/null
python3 - "$STAGE/secrets.json" <<'PY'
import json,sys
names={s.get('name') for s in json.load(open(sys.argv[1]))}
for name in ['SUPABASE_SECRET_KEYS','SUPABASE_PUBLISHABLE_KEYS']:
 assert name in names, name+' is not injected; create the new API keys in the dashboard first'
for name in ['ALBUS_SUPABASE_SECRET_KEY','ALBUS_SUPABASE_PUBLISHABLE_KEY']:
 assert name not in names, name+' is set and would win over the new keys; unset it first'
print('The platform injects both new key dictionaries, and no override is set.')
PY
compare
echo "Pending migrations: ${PENDING:-none}"

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry run] would apply only $MIGRATION, then check the payment queue's protections"
  echo '[dry run] would deploy breakdown, grade and revenuecat-webhook with unchanged authentication policies'
  echo '[dry run] would wake the webhook once so its log shows where its keys come from'
  echo 'DRY RUN FINISHED: no migrations, deployments or secret changes performed.'
  exit 0
fi

if [ -n "$PENDING" ]; then
  supabase db push --yes </dev/null
  compare
  [ -z "$PENDING" ] || stop 'migration still pending'
fi
cat > "$STAGE/verify.sql" <<'SQL'
begin read only;
select
 (select relrowsecurity from pg_class where oid='private.financial_inbox'::regclass) as inbox_rls,
 (select relrowsecurity from pg_class where oid='private.financial_audit'::regclass) as audit_rls,
 not has_table_privilege('authenticated','private.financial_inbox','select,insert,update,delete') as inbox_clients_closed,
 not has_table_privilege('service_role','private.financial_audit','update,delete') as audit_immutable,
 not has_function_privilege('anon','public.enqueue_revenuecat_event(text,text,jsonb)','execute') as enqueue_anon_closed,
 not has_function_privilege('authenticated','public.process_financial_event(uuid)','execute') as process_clients_closed,
 has_function_privilege('service_role','public.process_financial_event(uuid)','execute') as process_server_allowed,
 (select count(*)=2 from cron.job where jobname in ('albus-financial-drain','albus-financial-payload-retention') and active) as jobs_scheduled,
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)) as definer_paths_closed;
commit;
SQL
supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verify.json"
python3 - "$STAGE/verify.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
assert len(r)==1 and len(r[0])==9 and all(v is True for v in r[0].values()), 'Database verification failed'
for key,value in r[0].items(): print(key+': '+str(value))
PY
supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null
supabase functions deploy grade --project-ref "$REF" --use-api </dev/null
supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null
# Unsigned, so refused; starting it is the point. Its log line names the
# source of each key ("platform" for both is what lets the legacy keys go).
STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/functions/v1/revenuecat-webhook" -d '{}' || true)
echo "Webhook woken (answered $STATUS, as an unsigned request should be refused)."
echo 'DONE: payment queue applied and checked, all three reviewed functions deployed. No secrets changed.'
echo 'Tell Claude, who checks that the webhook log says "platform" for both keys.'
