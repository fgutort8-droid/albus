#!/usr/bin/env bash
# Felipe-run combined security update. Run the maintenance script first.
# Preview: DRY_RUN=1 ALBUS_SOURCE=/path/to/reviewed/albus bash this-script.sh
# After the combined security PR is merged: DRY_RUN=0 bash this-script.sh
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
EXPECTED=20260925170000
SEQUENCE=20260927171142
SEQUENCE_MIGRATION=20260927171142_tighten_application_sequence.sql
SEQUENCE_DIGEST=d78b008fd635f1e3942494cc3bd6bc6e97e58593c42c3e352bcf14f5c88b394b
MIGRATION=20260925170000_subscription_ordering.sql
DIGEST=b2dd077a1df14555e607459a218626e6391dcf7699a61ef16922beef873a784a
WEBHOOK_DIGEST=b4cb6aff216e4723c5b579c0388fd6bc6bf746d6402624e18da34d7d3487a5fe
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
[ -f "supabase/migrations/$SEQUENCE_MIGRATION" ] || stop 'merge the reviewed combined security PR first'
[ "$(shasum -a 256 "supabase/migrations/$SEQUENCE_MIGRATION" | awk '{print $1}')" = "$SEQUENCE_DIGEST" ] || stop 'sequence migration fingerprint differs'
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
  case "$PENDING" in
    ""|"$SEQUENCE"|"$EXPECTED $SEQUENCE") ;;
    "20260925140000 $EXPECTED $SEQUENCE")
      [ "$DRY_RUN" = 1 ] || stop 'run the maintenance script first'
      echo '[dry run] maintenance prerequisite is pending; run deploy-maintenance-2026-09-25.sh first' ;;
    *) stop "unexpected pending migrations: $PENDING" ;;
  esac
}
supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json"
python3 - "$STAGE/functions.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
for name in ['breakdown','grade','revenuecat-webhook']:
 matches=[r for r in rows if r.get('slug',r.get('name'))==name]
 assert len(matches)==1 and matches[0].get('verify_jwt') is (name != 'revenuecat-webhook'), name+': verify existing JWT policy before proceeding'
 print(name+': gateway JWT policy matches the reviewed configuration')
PY
compare
echo "Pending migrations: ${PENDING:-none}"
if [ -n "$PENDING" ]; then
  if [[ " $PENDING " == *" $EXPECTED "* ]]; then
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
  fi
  if [ "$DRY_RUN" = 1 ]; then
    echo '[dry run] after maintenance, would apply only the reviewed subscription and application-sequence migrations'
  else
    supabase db push --yes </dev/null
    compare
    [ -z "$PENDING" ] || stop 'migration still pending'
  fi
fi
if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would deploy planning, grading and subscription functions with locked dependencies and unchanged authentication policies'
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
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false)) as definer_paths_closed,
 not has_sequence_privilege('anon','public.security_events_id_seq','USAGE,SELECT,UPDATE') as anon_sequence_closed,
 not has_sequence_privilege('authenticated','public.security_events_id_seq','USAGE,SELECT,UPDATE') as client_sequence_closed,
 has_sequence_privilege('service_role','public.security_events_id_seq','USAGE') as server_sequence_allowed;
commit;
SQL
supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verify.json"
python3 - "$STAGE/verify.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
assert len(r)==1 and len(r[0])==10 and all(v is True for v in r[0].values()), 'Database verification failed'
for key,value in r[0].items(): print(key+': '+str(value))
PY
supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null
supabase functions deploy grade --project-ref "$REF" --use-api </dev/null
supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null
echo 'DONE: database controls verified and all three reviewed functions deployed. No secrets changed.'

fi
