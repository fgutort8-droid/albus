#!/usr/bin/env bash
# Felipe-run: puts the security fix reviewed in #43 on the new Albus project
# (3 Nov 2026).
# Preview: DRY_RUN=1 bash scripts/deploy-advisor-fixes-2026-11-03.sh
# Apply:   DRY_RUN=0 bash scripts/deploy-advisor-fixes-2026-11-03.sh
#
# One database change and nothing else: migration 20261028120000 switches off
# pg_graphql, a second way into the database that Albus never uses (the app and
# its functions use REST and RPC only). No functions, secrets or settings change.
#
# 1. Checks that GitHub's main holds exactly the database changes reviewed for
#    this, and that the new project lacks this one change and no other.
# 2. Applies it.
# 3. Checks with a read-only query that GraphQL is off, and that students can
#    still read the plans and call their own functions.
#
# It asks for the albus-setup access token (typing is hidden) instead of using
# the login saved on this Mac, which belongs to the OLD project, and refuses the
# old project. It needs Supabase CLI 2.117 or newer.
#
# Safe to run again: once the change is applied, it only checks. Undo, should
# GraphQL ever be wanted: Database, then Extensions, then pg_graphql in the
# dashboard.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
CHANGE=20261028120000
# Every migration file's name and contents on main, as reviewed.
MIGRATIONS_DIGEST=0d804d52092d7438e7a35b43be5acab11a08c542fbd8e4366df7e2ef551b7d2d
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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-advisor-fixes.XXXXXX")
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
h=hashlib.sha256()
for p in sorted(Path('supabase/migrations').glob('*.sql')): h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
[ "$ACTUAL" = "$MIGRATIONS_DIGEST" ] \
  || stop 'the database changes on main differ from what was reviewed; ask Claude for a new script'
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
# single prepared statement, which refuses several.
cat > "$STAGE/state.sql" <<'SQL'
select
 exists(select 1 from pg_extension where extname = 'pg_graphql') as graphql_on,
 has_table_privilege('authenticated', 'public.plans', 'select') as plans_readable,
 has_function_privilege('authenticated', 'public.my_plan()', 'execute') as own_functions_callable;
SQL
# Sets STATE to "graphql_on=yes plans_readable=yes own_functions_callable=yes",
# or stops with the reason given.
read_state() {
  supabase db query --linked --file "$STAGE/state.sql" --output json > "$STAGE/state.json" </dev/null \
    || stop "$1"
  STATE=$(python3 - "$STAGE/state.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows') if isinstance(j,dict) else j
keys=('graphql_on','plans_readable','own_functions_callable')
if not (isinstance(r,list) and len(r)==1 and isinstance(r[0],dict) and set(r[0])==set(keys)
        and all(isinstance(r[0][k],bool) for k in keys)): sys.exit(1)
print(' '.join(k+'='+('yes' if r[0][k] else 'no') for k in keys))
PY
) || stop "$1"
}

compare
read_state 'could not read the database'
echo "Now: $STATE"
[[ "$STATE" == *'plans_readable=yes own_functions_callable=yes' ]] \
  || stop 'students cannot read the plans or call their own functions even before this change; tell Claude'
if [ -z "$PENDING" ]; then
  echo "The change $CHANGE is already applied."
else
  echo "Pending: $CHANGE (switches GraphQL off)."
fi

if [ "$DRY_RUN" = 1 ]; then
  [ -z "$PENDING" ] || echo "[dry run] would apply $CHANGE, then check the result with a read-only query"
  echo 'DRY RUN FINISHED: no database changes performed.'
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
[ "$STATE" = 'graphql_on=no plans_readable=yes own_functions_callable=yes' ] \
  || stop 'the change is applied, but the check did not pass; tell Claude'
echo 'DONE: GraphQL is off on the new project, and students can still read the plans'
echo 'and call their own functions. In the dashboard, Advisors then Security Advisor'
echo 'should no longer list the GraphQL warnings once it refreshes.'
