#!/usr/bin/env bash
# Felipe-run subscription update. Run the maintenance script first.
# Preview: DRY_RUN=1 ALBUS_SOURCE=/path/to/reviewed/albus bash this-script.sh
# After both PRs are merged: DRY_RUN=0 bash this-script.sh
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
EXPECTED=20260925170000
MIGRATION=20260925170000_subscription_ordering.sql
DIGEST=7293aa88935051f8e230e976951b4f11f6382c0c319bcd9f1664fb6cca40f3ee
WEBHOOK_DIGEST=27f7613a9ae3b012789a7e2db3eb4fa53d6c070fbc068dccd3b8e86e3527d491
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3 shasum; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-subscription-deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [ "$DRY_RUN" = 1 ] && [ -n "${ALBUS_SOURCE:-}" ]; then
  echo 'Previewing supplied candidate source; this does not establish that it is merged.'
  mkdir -p "$STAGE/repo"
  cp -R "$ALBUS_SOURCE/supabase" "$STAGE/repo/supabase"
else
  echo 'Reading a fresh copy of GitHub main.'
  git clone --quiet --depth 1 --branch main https://github.com/fgutort8-droid/albus.git "$STAGE/repo"
fi
cd "$STAGE/repo"
[ -f "supabase/migrations/$MIGRATION" ] || stop 'merge the reviewed subscription PR first'
[ "$(shasum -a 256 "supabase/migrations/$MIGRATION" | awk '{print $1}')" = "$DIGEST" ] || stop 'migration fingerprint differs'
ACTUAL=$(python3 - <<'PY'
from pathlib import Path
import hashlib
h=hashlib.sha256()
for name in ['revenuecat-webhook/index.ts','_shared/auth.ts','_shared/body.ts','_shared/http.ts','_shared/revenuecat.ts','deno.json']:
 h.update(name.encode()+b'\0'+(Path('supabase/functions')/name).read_bytes()+b'\0')
print(h.hexdigest())
PY
)
[ "$ACTUAL" = "$WEBHOOK_DIGEST" ] || stop 'webhook source or dependency configuration differs'
echo "Verified migration SHA-256: $DIGEST"
echo "Verified webhook source SHA-256: $ACTUAL"
supabase link --project-ref "$REF" </dev/null
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'
compare() {
  local out
  out=$(supabase migration list --linked </dev/null) || stop 'could not read migration history'
  REMOTE_ONLY=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(r~/^[0-9]+$/ && l=="")print r}' <<<"$out" | xargs)
  PENDING=$(awk -F'|' 'NF>=3 {l=$1;r=$2;gsub(/ /,"",l);gsub(/ /,"",r);if(l~/^[0-9]+$/ && r=="")print l}' <<<"$out" | xargs)
  [ -z "$REMOTE_ONLY" ] || stop "unrecognized remote migrations: $REMOTE_ONLY"
  if [ "$DRY_RUN" = 1 ] && [ "$PENDING" = "20260925140000 $EXPECTED" ]; then
    echo '[dry run] maintenance prerequisite is pending; run deploy-maintenance-2026-09-25.sh first'
  else
    [ -z "$PENDING" ] || [ "$PENDING" = "$EXPECTED" ] || stop "unexpected pending migrations: $PENDING; run maintenance first"
  fi
}
compare
echo "Pending migrations: ${PENDING:-none}"
if [ -n "$PENDING" ]; then
  cat > "$STAGE/preflight.sql" <<'SQL'
begin read only;
select count(*)=0 as ownership_history_empty from public.subscription_transactions;
commit;
SQL
  supabase db query --linked --file "$STAGE/preflight.sql" --output json > "$STAGE/preflight.json"
  python3 - "$STAGE/preflight.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
assert len(r)==1 and r[0].get('ownership_history_empty') is True, 'STOP: historical purchases require reconciliation before this transition'
print('Preflight: no historical purchase ownership needs reconciliation.')
PY
  if [ "$DRY_RUN" = 1 ]; then
    echo '[dry run] after maintenance, would apply exactly the subscription migration'
  else
    supabase db push --yes </dev/null
    compare
    [ -z "$PENDING" ] || stop 'migration still pending'
  fi
fi
if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would deploy revenuecat-webhook with its existing Authorization/HMAC checks and no gateway JWT'
  echo '[dry run] would verify private table RLS, client grants and function search paths'
  echo 'DRY RUN FINISHED: no migrations, deployments or secret changes performed.'
else
cat > "$STAGE/verify.sql" <<'SQL'
begin read only;
select
 (select relrowsecurity from pg_class where oid='private.subscription_transfers'::regclass) as transfer_rls,
 (select relrowsecurity from pg_class where oid='private.ai_usage_purchases'::regclass) as usage_rls,
 not has_table_privilege('authenticated','private.subscription_transfers','select,insert,update,delete') as transfer_clients_closed,
 not has_table_privilege('authenticated','private.ai_usage_purchases','select,insert,update,delete') as usage_clients_closed,
 not has_function_privilege('authenticated','public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text)','execute') as client_rpc_closed,
 has_function_privilege('service_role','public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text)','execute') as server_rpc_allowed,
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)) as definer_paths_closed;
commit;
SQL
supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verify.json"
python3 - "$STAGE/verify.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
assert len(r)==1 and len(r[0])==7 and all(v is True for v in r[0].values()), 'Database verification failed'
for key,value in r[0].items(): print(key+': '+str(value))
PY
supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null
echo 'DONE: subscription database controls verified and reviewed webhook deployed. No secrets changed.'

fi
