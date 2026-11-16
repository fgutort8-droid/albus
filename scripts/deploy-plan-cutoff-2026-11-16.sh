#!/usr/bin/env bash
# Felipe-run: puts the fix reviewed in #52 on the new Albus project
# (16 Nov 2026). Run it only after #52 is merged.
# Preview: DRY_RUN=1 bash scripts/deploy-plan-cutoff-2026-11-16.sh
# Apply:   DRY_RUN=0 bash scripts/deploy-plan-cutoff-2026-11-16.sh
#
# #52 gives an AI plan room for the model's reasoning, and sets aside enough
# money for each plan to cover that room. Two parts, in this order:
#
# 1. Database: migration 20261115120000 raises what a rubric plan reserves
#    from US$0.06 to US$0.125. Nothing else in the database changes.
# 2. Functions: breakdown (writes plans) and grade (marks work) are deployed
#    from main. Both use the same shared file, which #52 changed. No secrets or
#    settings change.
#
# The database goes first: a plan allowed the bigger room must never be
# admitted against the old, smaller reservation.
#
# Before anything, it checks that GitHub's main holds exactly what was
# reviewed, and that the project lacks this one database change and no other.
# After, it checks with read-only queries that the reservations are as
# reviewed, that both functions are live with their sign-in check on, and
# that each refuses a request with no sign-in.
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
CHANGE=20261115120000
# Every migration file's name and contents on main, as reviewed.
MIGRATIONS_DIGEST=7d43e91b579ee7f0a38e4d018f67b35e9cafd1a6845a9005e82c1615451678f8
# config.toml and every function source file on main, as reviewed.
SOURCE_DIGEST=20a2452de9364e5a65a3f96db5e9997f1425bbe56e55d79fc72f7adc5ee00242
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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-plan-cutoff.XXXXXX")
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
  || stop 'the database changes on main differ from what was reviewed; has #52 been merged? If it has, ask Claude for a new script'
[ "$(sed -n 2p <<<"$ACTUAL")" = "$SOURCE_DIGEST" ] \
  || stop 'the function source on main differs from what was reviewed; has #52 been merged? If it has, ask Claude for a new script'
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
# single prepared statement, which refuses several. Amounts are in millionths
# of a US dollar.
#
# It reads the reservation function's stored definition rather than calling
# it: the function is closed to every role but the server's, and earlier
# scripts have only ever read the catalogue about private objects. A missing
# line reads as null, which stops the run.
cat > "$STAGE/state.sql" <<'SQL'
select
 substring(d from $r$p_kind = 'breakdown' and p_model = 'claude-sonnet-5' then ([0-9]+)$r$)::int as plan_with_rubric,
 substring(d from $r$p_kind = 'breakdown' and p_model = 'claude-haiku-4-5' then ([0-9]+)$r$)::int as plan_without_rubric,
 substring(d from $r$p_kind = 'grade' and p_model = 'claude-opus-5' then ([0-9]+)$r$)::int as marking_with_rubric,
 substring(d from $r$p_kind = 'grade' and p_model = 'claude-sonnet-5' then ([0-9]+)$r$)::int as marking_without_rubric
from (select regexp_replace(pg_get_functiondef('private.ai_reservation_cost(text,text)'::regprocedure),
                            '[[:space:]]+', ' ', 'g') as d) f;
SQL
# Sets STATE to "plan_with_rubric=60000 plan_without_rubric=30000 ...", or
# stops with the reason given.
read_state() {
  supabase db query --linked --file "$STAGE/state.sql" --output json > "$STAGE/state.json" </dev/null \
    || stop "$1"
  STATE=$(python3 - "$STAGE/state.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); r=j.get('rows') if isinstance(j,dict) else j
keys=('plan_with_rubric','plan_without_rubric','marking_with_rubric','marking_without_rubric')
if not (isinstance(r,list) and len(r)==1 and isinstance(r[0],dict) and set(r[0])==set(keys)
        and all(type(r[0][k]) is int for k in keys)): sys.exit(1)
print(' '.join(k+'='+str(r[0][k]) for k in keys))
PY
) || stop "$1"
}
UNCHANGED='plan_without_rubric=30000 marking_with_rubric=450000 marking_without_rubric=200000'
BEFORE_STATE="plan_with_rubric=60000 $UNCHANGED"
AFTER_STATE="plan_with_rubric=125000 $UNCHANGED"

# The two functions this deploys, both with the gateway's sign-in check on.
functions_state() {
  supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null \
    || stop 'could not read the live functions'
  python3 - "$STAGE/functions.json" "$1" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])) or []
rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
if not isinstance(rows,list) or not all(isinstance(r,dict) for r in rows): sys.exit('could not read the live functions; tell Claude')
for name in ('breakdown','grade'):
 m=[r for r in rows if r.get('slug',r.get('name'))==name]
 if sys.argv[2]=='before':
  if len(m)!=1: sys.exit(name+' is not live on the project; this script only updates it, so tell Claude')
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
  [ "$STATE" = "$AFTER_STATE" ] || stop "the change $CHANGE is recorded as applied, but the reservations are not as reviewed; tell Claude"
  echo "The change $CHANGE is already applied."
else
  [ "$STATE" = "$BEFORE_STATE" ] || stop 'the reservations are not what this change was written against; tell Claude'
  echo "Pending: $CHANGE (a rubric plan reserves US\$0.125 instead of US\$0.06)."
fi
functions_state before || stop 'the functions are not as expected; tell Claude'

if [ "$DRY_RUN" = 1 ]; then
  [ -z "$PENDING" ] || echo "[dry run] would apply $CHANGE, then check the reservations with a read-only query"
  echo '[dry run] would deploy breakdown and grade from main, then check both refuse a request with no sign-in'
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
[ "$STATE" = "$AFTER_STATE" ] || stop 'the change is applied, but the reservations are not as reviewed; tell Claude'

supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null \
  || stop 'the database change is in, but breakdown did not deploy; running this again is safe'
supabase functions deploy grade --project-ref "$REF" --use-api </dev/null \
  || stop 'the database change is in and breakdown deployed, but grade did not; running this again is safe'
functions_state after || stop 'the functions deployed, but not as reviewed; tell Claude before anything else'
probe breakdown
probe grade
echo 'DONE: a rubric plan now reserves US$0.125 and has room for the model to reason;'
echo 'breakdown and grade are live from main and refuse requests with no sign-in.'
echo 'Nothing else changed. In a week, Claude can count plans cut off as RESPONSE_TRUNCATED.'
