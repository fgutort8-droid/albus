#!/usr/bin/env bash
# Felipe-run: sets up the NEW Albus Supabase project (the move of 21 Oct 2026).
# Preview: DRY_RUN=1 bash scripts/bring-up-project-2026-10-25.sh
# Set up:  DRY_RUN=0 bash scripts/bring-up-project-2026-10-25.sh
#
# The login that owned the old project was lost, so Albus moves to a new project
# in the fgutort8-droid organization. Nothing is copied from the old project:
# this builds the new one from what is on GitHub's main.
#
# 1. Applies every database change in supabase/migrations to the new project,
#    and nothing else.
# 2. Checks the result with a read-only query (shape and security).
# 3. Deploys breakdown, grade and delete-account (each behind the gateway's
#    sign-in check) and revenuecat-webhook (which has its own checks).
# 4. Checks that each answers a request with no sign-in the way it should.
# 5. Reports, by name only, which secrets are set, and whether the sign-in
#    settings made in the dashboard took effect.
#
# It asks for a Supabase access token (typing is hidden) instead of using the
# login saved on this Mac, which belongs to the OLD project. It refuses to
# touch the old project.
#
# Undo: fix forward. The new project holds only what this script puts there.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
URL="https://$REF.supabase.co"
# Every migration file's name and contents, and every function source,
# config.toml, deno.json and deno.lock, as reviewed.
MIGRATIONS_DIGEST=999acfe6914cac5a88d7b775ef8d50b5b29d45d3babccc82ba9cc1b583ba85d7
SOURCE_DIGEST=11bc52a493d60a84fbe25dbeacf019d11963d3b5d13aa481590829e84c6bff0a
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
TTY=${ALBUS_TTY:-/dev/tty}   # the tests point this at /dev/null; nothing else sets it
[ "$REF" != "$OLD_REF" ] || stop 'that is the old project, which this script must never touch'
for tool in git supabase python3 curl comm; do command -v "$tool" >/dev/null || stop "missing $tool"; done
# Only this run's token may steer the CLI. Any other SUPABASE_* setting left in
# the shell is dropped: SUPABASE_PROJECT_ID, for one, wins over the linked project.
for name in $(env | sed -n 's/^\(SUPABASE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  [ "$name" = SUPABASE_ACCESS_TOKEN ] || unset "$name"
done

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  read -r -s -p 'Paste the albus-setup access token (typing is hidden), then press Enter: ' SUPABASE_ACCESS_TOKEN <"$TTY" \
    || stop 'could not ask for the access token; run this in Terminal'
  echo
fi
[[ "$SUPABASE_ACCESS_TOKEN" =~ ^sbp_[A-Za-z0-9_]{20,200}$ ]] \
  || stop 'that does not look like a Supabase access token (it starts sbp_)'
export SUPABASE_ACCESS_TOKEN

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-bring-up.XXXXXX")
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
  || stop 'server configuration differs from what was reviewed (the database changes)'
[ "$(sed -n 2p <<<"$ACTUAL")" = "$SOURCE_DIGEST" ] \
  || stop 'server configuration differs from what was reviewed (function source or config.toml)'
echo "Verified database changes SHA-256: $MIGRATIONS_DIGEST"
echo "Verified function source SHA-256: $SOURCE_DIGEST"

supabase link --project-ref "$REF" </dev/null >/dev/null \
  || stop 'this access token cannot reach the new project; make it in the account that owns the project'
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'
echo "Linked to the new project $REF."

lines() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort; }
compare() {
  local out files
  out=$(supabase migration list --linked </dev/null) || stop 'could not read migration history'
  # Different CLI versions draw the table with "|" or "│". Read either, and
  # stop unless it lists exactly the files on main: an unreadable list must
  # never look like "nothing pending".
  out=$(printf '%s\n' "$out" | sed 's/│/|/g')
  LOCAL=$(awk -F'|' 'NF>=3 {l=$1;gsub(/ /,"",l);if(l~/^[0-9]+$/)print l}' <<<"$out" | sort | xargs)
  REMOTE=$(awk -F'|' 'NF>=3 {r=$2;gsub(/ /,"",r);if(r~/^[0-9]+$/)print r}' <<<"$out" | sort | xargs)
  files=$(for f in supabase/migrations/*.sql; do v=$(basename "$f"); echo "${v%%_*}"; done | sort | xargs)
  [ -n "$LOCAL" ] && [ "$LOCAL" = "$files" ] \
    || stop 'could not read the migration list, or it does not match main; stopping rather than guessing'
  REMOTE_ONLY=$(comm -13 <(lines "$LOCAL") <(lines "$REMOTE") | xargs)
  PENDING=$(comm -23 <(lines "$LOCAL") <(lines "$REMOTE") | xargs)
  [ -z "$REMOTE_ONLY" ] || stop "unrecognized remote migrations: $REMOTE_ONLY; this is not an empty new project"
  if [ -n "$REMOTE" ] && [ -n "$PENDING" ]; then
    local newest first
    newest=$(lines "$REMOTE" | tail -1); first=$(lines "$PENDING" | head -1)
    [[ "$first" > "$newest" ]] || stop "a pending migration ($first) is older than the newest applied one ($newest); stopping rather than guessing"
  fi
}

functions_state() {
  supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null \
    || stop 'could not read the live functions'
  python3 - "$STAGE/functions.json" "$1" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
want={'breakdown':True,'grade':True,'delete-account':True,'revenuecat-webhook':False}
def find(name): return [r for r in rows if r.get('slug',r.get('name'))==name]
for r in rows:
 name=r.get('slug',r.get('name'))
 if name not in want: sys.exit('an unexpected function is live: '+str(name)+'; tell Claude')
for name,jwt in want.items():
 m=find(name)
 if sys.argv[2]=='before':
  if m and m[0].get('verify_jwt') is not jwt: sys.exit(name+' is already live with the wrong sign-in check; tell Claude')
  print(name+': '+('live at version '+str(m[0].get('version'))+'; this redeploys it' if m else 'not live yet; this deploys it'))
 else:
  if len(m)!=1 or m[0].get('verify_jwt') is not jwt or m[0].get('status','ACTIVE')!='ACTIVE':
   sys.exit(name+' is not live with the right sign-in check; tell Claude before anything else')
  print(name+': live at version '+str(m[0].get('version'))+', gateway sign-in check '+('on' if jwt else 'off (it has its own checks)'))
PY
}

secrets_report() {
  supabase secrets list --project-ref "$REF" --output json > "$STAGE/secrets.json" </dev/null \
    || stop 'could not read the secret names'
  # Names only. The list also carries a digest of each value; it is never printed.
  python3 - "$STAGE/secrets.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('secrets',rows) if isinstance(rows,dict) else rows
names={r.get('name') for r in rows if isinstance(r,dict)}
for n in ('SUPABASE_SECRET_KEYS','SUPABASE_PUBLISHABLE_KEYS'):
 if n not in names: sys.exit(n+' is not injected, so the functions would have no keys; tell Claude')
for n in ('ALBUS_SUPABASE_SECRET_KEY','ALBUS_SUPABASE_PUBLISHABLE_KEY'):
 if n in names: sys.exit(n+' is set and would win over the new keys; tell Claude')
print('The platform injects both key sets, and no override is set.')
for n in ('ANTHROPIC_API_KEY','REVENUECAT_WEBHOOK_SECRET','REVENUECAT_WEBHOOK_SIGNING_SECRET','REVENUECAT_APP_IDS','ALBUS_SIGNAL_PEPPER','APPLE_TEAM_ID','APPLE_KEY_ID','APPLE_PRIVATE_KEY','APPLE_CLIENT_ID'):
 print(n+': '+('set' if n in names else 'not set yet'))
PY
}

signin_settings() {
  local key=${ALBUS_PUBLISHABLE_KEY:-}
  if [ -z "$key" ]; then
    # Hidden like the token prompt, in case the wrong thing is pasted here.
    read -r -s -p 'Paste the publishable key (it starts sb_publishable_; typing is hidden), or press Enter to skip this check: ' key <"$TTY" || key=''
    echo
  fi
  case "$key" in
    sbp_*|sb_secret_*|eyJ*) key=''; echo 'That was a secret, not the publishable key. It was not used or shown; do not paste it anywhere else.' ;;
  esac
  SETTINGS_LINE='Sign-in settings: not checked.'
  [ -n "$key" ] || { echo "$SETTINGS_LINE"; return 0; }
  [[ "$key" =~ ^sb_publishable_[A-Za-z0-9_-]{20,100}$ ]] || { echo 'That is not a publishable key, so the sign-in settings were not checked.'; return 0; }
  local status
  status=$(curl -s -o "$STAGE/settings.json" -w '%{http_code}' --max-time 20 -H "apikey: $key" "$URL/auth/v1/settings" || true)
  if [ "$status" != 200 ]; then
    SETTINGS_LINE="Sign-in settings: not checked (Supabase answered $status: it refused that key, or could not be reached)."
    echo "$SETTINGS_LINE"; return 0
  fi
  SETTINGS_OUT=$(python3 - "$STAGE/settings.json" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except ValueError: d=None
if not isinstance(d,dict) or not isinstance(d.get('external'),dict):
 print('Sign-in settings: not checked (an answer this script does not recognise).'); sys.exit(0)
ext=d['external']
todo=[]
def line(label,ok,now,want):
 print('  %-26s %-8s %s'%(label,now,'ok' if ok else 'STILL TO DO: set it '+want))
 if not ok: todo.append(label)
line('Sign in with Apple',ext.get('apple') is True,'on' if ext.get('apple') else 'off','on')
line('Email provider',ext.get('email') is False,'on' if ext.get('email') else 'off','off')
line('Anonymous sign-ins',ext.get('anonymous_users') is False,'on' if ext.get('anonymous_users') else 'off','off')
line('New sign-ups',d.get('disable_signup') is False,'closed' if d.get('disable_signup') else 'open','open')
others=sorted(k for k,v in ext.items() if v is True and k not in ('apple','email','anonymous_users'))
line('Other sign-in providers',not others,', '.join(others) or 'none','off')
print('Sign-in settings: all as planned.' if not todo else 'Sign-in settings: still to do in the dashboard: '+', '.join(todo)+'.')
PY
)
  printf '%s\n' "$SETTINGS_OUT"
  SETTINGS_LINE=$(tail -1 <<<"$SETTINGS_OUT")
}

functions_state before || stop 'the live functions are not as expected'
compare
echo "Database changes on main: $(wc -w <<<"$LOCAL" | tr -d ' '); already applied: $(wc -w <<<"$REMOTE" | tr -d ' '); pending: $(wc -w <<<"$PENDING" | tr -d ' ')"
secrets_report
signin_settings

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry run] would apply the $(wc -w <<<"$PENDING" | tr -d ' ') pending database changes, then check the result with a read-only query"
  echo '[dry run] would deploy breakdown, grade, delete-account and revenuecat-webhook, then check each refuses a request with no sign-in'
  echo 'DRY RUN FINISHED: no database changes, deployments or secret changes performed.'
  exit 0
fi

if [ -n "$PENDING" ]; then
  supabase db push --yes </dev/null \
    || stop 'Supabase reported an error applying the database changes, so nothing was deployed; tell Claude'
  compare
  [ -z "$PENDING" ] || stop 'database changes are still pending after the push; tell Claude'
fi
# definer_paths_closed allows one function by name and exact shape:
# rls_auto_enable(), which Supabase adds to a project created with "Enable
# automatic RLS". It runs only as a DDL event trigger, never for a client, and
# its path is pinned to pg_catalog. Any other definer function needs path "".
cat > "$STAGE/verify.sql" <<'SQL'
begin read only;
select
 (select count(*) = 3 from public.plans) as plans_seeded,
 (select count(*) >= 4 from public.subscription_products) as products_mapped,
 not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity) as public_tables_have_rls,
 not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p','v','m') and has_table_privilege('anon', c.oid, 'select,insert,update,delete,truncate,references,trigger')) as anon_has_no_table_access,
 not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'],false) and not (n.nspname='public' and p.proname='rls_auto_enable' and p.prorettype='event_trigger'::regtype and p.proconfig is not distinct from array['search_path=pg_catalog'])) as definer_paths_closed,
 (select count(*) = 4 from cron.job where active and jobname in ('prune-security-data','reap-abandoned-anonymous','albus-financial-drain','albus-financial-payload-retention')) as jobs_scheduled,
 exists(select 1 from pg_trigger where tgname='assignments_active_limit' and tgrelid='public.assignments'::regclass and tgenabled<>'D') as task_cap_trigger_on,
 pg_get_function_identity_arguments('public.sync_my_assignments(uuid[],uuid[])'::regprocedure) = 'p_finished uuid[], p_open uuid[]' as sync_signature,
 pg_get_function_identity_arguments('public.release_my_other_assignments(uuid[])'::regprocedure) = 'p_keep uuid[]' as release_signature,
 (not has_function_privilege('anon','public.sync_my_assignments(uuid[],uuid[])','execute') and has_function_privilege('authenticated','public.sync_my_assignments(uuid[],uuid[])','execute')) as sync_privileges,
 (not has_function_privilege('anon','public.release_my_other_assignments(uuid[])','execute') and has_function_privilege('authenticated','public.release_my_other_assignments(uuid[])','execute')) as release_privileges,
 (has_function_privilege('authenticated','public.delete_my_account()','execute') and not has_function_privilege('anon','public.delete_my_account()','execute')) as delete_rpc_privileges,
 (select relrowsecurity from pg_class where oid='private.financial_inbox'::regclass) as inbox_rls,
 not has_table_privilege('authenticated','private.financial_inbox','select,insert,update,delete') as inbox_clients_closed,
 not has_table_privilege('service_role','private.financial_audit','update,delete') as audit_immutable;
commit;
SQL
supabase db query --linked --file "$STAGE/verify.sql" --output json > "$STAGE/verify.json" </dev/null \
  || stop 'the database changes are applied, but the checks could not run, so nothing was deployed; tell Claude'
python3 - "$STAGE/verify.json" <<'PY' || stop 'the database changes are applied, but the checks did not all pass, so nothing was deployed; tell Claude'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows',[]) if isinstance(j,dict) else j
if len(r)==1 and isinstance(r[0],dict):
 for key,value in r[0].items(): print(key+': '+str(value))
sys.exit(0 if len(r)==1 and len(r[0])==15 and all(v is True for v in r[0].values()) else 1)
PY

supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null \
  || stop 'the database is set up and checked, but breakdown did not deploy; running this again is safe'
supabase functions deploy grade --project-ref "$REF" --use-api </dev/null \
  || stop 'breakdown deployed, but grade did not; running this again is safe'
supabase functions deploy delete-account --project-ref "$REF" --use-api </dev/null \
  || stop 'breakdown and grade deployed, but delete-account did not; running this again is safe'
supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null \
  || stop 'three functions deployed, but revenuecat-webhook did not; running this again is safe'
functions_state after || stop 'the functions deployed, but not as reviewed; tell Claude before anything else'

probe() {
  local name=$1 status
  shift
  rm -f "$STAGE/answer.json"
  status=$(curl -s -o "$STAGE/answer.json" -w '%{http_code}' --max-time 30 -X POST "$URL/functions/v1/$name" \
    -H 'Content-Type: application/json' -d '{}' || true)
  # The platform also answers 503 when a function fails to start, so a 503
  # counts only when it is the webhook's own "not configured" answer.
  if [ "$status" = 503 ] && ! grep -Eq '"error" *: *"NOT_CONFIGURED"' "$STAGE/answer.json" 2>/dev/null; then
    stop "deployed, but $name answered 503 without saying NOT_CONFIGURED, so it may not have started; tell Claude before anything else"
  fi
  case " $* " in
    *" $status "*) echo "$name: answers a request with no sign-in with $status, as it should." ;;
    *) stop "deployed, but $name answered $status to a request with no sign-in (expected $*); tell Claude before anything else" ;;
  esac
}
# The webhook answers 503 until its two passwords are set, and 401 after.
probe breakdown 401
probe grade 401
probe delete-account 401
probe revenuecat-webhook 401 503
secrets_report
echo "DONE: the new project's database is set up and checked, and all four functions are deployed. No secrets changed."
echo "$SETTINGS_LINE"
echo 'Send Claude everything this printed.'
