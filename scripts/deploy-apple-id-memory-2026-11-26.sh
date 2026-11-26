#!/usr/bin/env bash
# Felipe-run: puts the "deleting can't reset free limits" PR on the Albus
# project (26 Nov 2026). Run it only after that PR is merged.
# Preview: DRY_RUN=1 bash scripts/deploy-apple-id-memory-2026-11-26.sh
# Apply:   DRY_RUN=0 bash scripts/deploy-apple-id-memory-2026-11-26.sh
#
# Deleting an account and signing in again with the same Apple ID started the
# week's free AI plans from zero. Migration 20261126120000 makes a deleted
# account's last 30 days of AI use count for the next account with the same
# Apple ID, through a peppered one-way hash of the Apple identifier:
#
#   * a random pepper, made in the database and kept in Vault;
#   * private.ai_usage_apple_ids, the links, closed to students;
#   * a trigger on auth.users that makes the links when an account is deleted;
#   * the four usage-counting functions, which now also count those links;
#   * a daily job, prune-apple-usage-memory, that removes each link once its
#     usage is 30 days old.
#
# Only the database changes. No function is deployed and no secret is set:
# the functions already call the counting functions this changes.
#
# Before anything, it checks that GitHub's main holds exactly what was
# reviewed, and that the project lacks this one database change and no other.
# After, it checks with one read-only query that every piece is in place and
# that nothing a student holds can reach it.
#
# It asks for the albus-setup access token (typing is hidden) instead of using
# the login saved on this Mac, which belongs to the OLD project, and refuses the
# old project. It needs Supabase CLI 2.117 or newer.
#
# Safe to run again: once the change is applied, it only checks.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
CHANGE=20261126120000
# Every migration file's name and contents on main, as reviewed.
MIGRATIONS_DIGEST=433ef1357098da9aa910788e9175dd4a2c1ad869fc94311852bf383a11ca58af
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
TTY=${ALBUS_TTY:-/dev/tty}   # the tests point this at /dev/null; nothing else sets it
[ "$REF" != "$OLD_REF" ] || stop 'that is the old project, which this script must never touch'
for tool in git supabase python3 comm; do command -v "$tool" >/dev/null || stop "missing $tool"; done
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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-apple-id-memory.XXXXXX")
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
h=hashlib.sha256()
for p in sorted(Path('supabase/migrations').glob('*.sql')): h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
[ "$ACTUAL" = "$MIGRATIONS_DIGEST" ] \
  || stop 'the database changes on main differ from what was reviewed; has the PR been merged? If it has, ask Claude for a new script'
echo "Verified database changes SHA-256: $MIGRATIONS_DIGEST"

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
# single prepared statement, which refuses several. Before the change every
# piece is absent and the counting functions do not mention the links; after
# it every piece is present, and nothing a student holds can reach it. The
# privilege checks run only once the objects exist, since naming a missing one
# is an error.
cat > "$STAGE/state.sql" <<'SQL'
select
 to_regclass('private.ai_usage_apple_ids') is not null as table_present,
 (to_regprocedure('private.apple_id_hash(uuid)') is not null
   and to_regprocedure('private.prune_apple_usage_memory()') is not null
   and exists(select 1 from pg_trigger where tgname='remember_apple_usage'
              and tgrelid='auth.users'::regclass and tgenabled<>'D')
   and (select bool_and(position('ai_usage_apple_ids' in pg_get_functiondef(f)) > 0)
          from unnest(array['public.ai_spend_count(uuid,text,interval)'::regprocedure,
                            'public.ai_window_resets_at(uuid,text,interval)'::regprocedure,
                            'private.ai_attempt_count(uuid,text,interval)'::regprocedure,
                            'private.ai_account_cost(uuid,interval)'::regprocedure]) f)) as functions_present,
 exists(select 1 from vault.secrets where name='albus_apple_id_pepper') as pepper_present,
 exists(select 1 from cron.job where jobname='prune-apple-usage-memory' and active
        and schedule='17 5 * * *' and command='select private.prune_apple_usage_memory()') as cleanup_scheduled,
 case when to_regclass('private.ai_usage_apple_ids') is not null
       and to_regprocedure('private.apple_id_hash(uuid)') is not null
       and to_regprocedure('private.prune_apple_usage_memory()') is not null
  then has_table_privilege('authenticated','private.ai_usage_apple_ids','select')
    or has_table_privilege('anon','private.ai_usage_apple_ids','select')
    or has_function_privilege('authenticated','private.apple_id_hash(uuid)','execute')
    or has_function_privilege('anon','private.apple_id_hash(uuid)','execute')
    or has_function_privilege('authenticated','private.prune_apple_usage_memory()','execute')
    or has_function_privilege('anon','private.prune_apple_usage_memory()','execute')
  else false end as students_can_reach;
SQL
# Sets STATE to "table_present=… … students_can_reach=…", or stops with the
# reason given.
read_state() {
  supabase db query --linked --file "$STAGE/state.sql" --output json > "$STAGE/state.json" </dev/null \
    || stop "$1"
  STATE=$(python3 - "$STAGE/state.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows') if isinstance(j,dict) else j
keys=('table_present','functions_present','pepper_present','cleanup_scheduled','students_can_reach')
if not (isinstance(r,list) and len(r)==1 and isinstance(r[0],dict) and set(r[0])==set(keys)
        and all(type(r[0][k]) is bool for k in keys)): sys.exit(1)
print(' '.join(k+'='+str(r[0][k]).lower() for k in keys))
PY
) || stop "$1"
}
BEFORE_STATE='table_present=false functions_present=false pepper_present=false cleanup_scheduled=false students_can_reach=false'
AFTER_STATE='table_present=true functions_present=true pepper_present=true cleanup_scheduled=true students_can_reach=false'

compare
read_state 'could not read the database'
echo "Now: $STATE"
if [ -z "$PENDING" ]; then
  [ "$STATE" = "$AFTER_STATE" ] || stop "the change $CHANGE is recorded as applied, but the database is not as reviewed; tell Claude"
  echo "The change $CHANGE is already applied."
else
  [ "$STATE" = "$BEFORE_STATE" ] || stop 'the database is not what this change was written against; tell Claude'
  echo "Pending: $CHANGE (deleting an account no longer resets the limits of the same Apple ID)."
fi

if [ "$DRY_RUN" = 1 ]; then
  [ -z "$PENDING" ] || echo "[dry run] would apply $CHANGE, then check the database with a read-only query"
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
echo 'DONE: deleting an account and signing in again with the same Apple ID no longer resets its limits;'
echo 'the links are closed to students and cleared daily once 30 days old. Nothing else changed.'
