#!/usr/bin/env bash
# Felipe-run: puts the marking change reviewed in the "choose criteria" PR on
# the Albus project (25 Nov 2026). Run it only after that PR is merged, and
# before build 3 reaches anyone.
# Preview: DRY_RUN=1 bash scripts/deploy-grade-criteria-2026-11-25.sh
# Apply:   DRY_RUN=0 bash scripts/deploy-grade-criteria-2026-11-25.sh
#
# The change lets the Grader mark only the criteria a student ticks. Only one
# function changes: grade (marks work), deployed from main. No database change,
# no secrets, no settings. The live function ignores the new choice and marks
# every criterion, which is why this goes out before the app that sends it.
#
# Before anything, it checks that GitHub's main holds exactly what was
# reviewed, and that the project's database changes match main's exactly, so
# this deploy meets the database it was written for. After, it checks that
# grade is live with its sign-in check on and refuses a request with no
# sign-in.
#
# It asks for the albus-setup access token (typing is hidden) instead of using
# the login saved on this Mac, which belongs to the OLD project, and refuses the
# old project. It needs Supabase CLI 2.117 or newer.
#
# Safe to run again: it only redeploys the same function.
set -euo pipefail
REF=yqhzmgikkawxjzvdjvsf
OLD_REF=ssvehwhblgqtvqkfbkbj
URL="https://$REF.supabase.co"
# Every migration file's name and contents on main, as reviewed.
MIGRATIONS_DIGEST=7d43e91b579ee7f0a38e4d018f67b35e9cafd1a6845a9005e82c1615451678f8
# config.toml and every function source file on main, as reviewed.
SOURCE_DIGEST=589103d5dad19a985b174d5ac6f2ac7188f966f149c821c7ba351ee5879e344d
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

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-grade-criteria.XXXXXX")
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
  || stop 'the database changes on main differ from what was reviewed; ask Claude for a new script'
[ "$(sed -n 2p <<<"$ACTUAL")" = "$SOURCE_DIGEST" ] \
  || stop 'the function source on main differs from what was reviewed; has the criteria PR been merged? If it has, ask Claude for a new script'
echo "Verified database changes SHA-256: $MIGRATIONS_DIGEST"
echo "Verified function source SHA-256: $SOURCE_DIGEST"

supabase link --project-ref "$REF" </dev/null >/dev/null \
  || stop 'this access token cannot reach the new project; make it in the account that owns the project'
[ "$(cat supabase/.temp/project-ref)" = "$REF" ] || stop 'unexpected project reference'
echo "Linked to the new project $REF."

lines() { tr ' ' '\n' <<<"$1" | sed '/^$/d' | sort; }
# Stops unless the project holds exactly main's database changes: this deploy
# changes no database, so it must meet the one it was written for. An
# unreadable list must never look like "nothing pending".
supabase migration list --linked --output-format json > "$STAGE/migrations.json" </dev/null \
  || stop 'could not read migration history'
PARSED=$(python3 - "$STAGE/migrations.json" <<'PY'
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
LOCAL_LIST=$(lines "$(sed -n 1p <<<"$PARSED")" | xargs)
REMOTE_LIST=$(lines "$(sed -n 2p <<<"$PARSED")" | xargs)
FILES=$(for f in supabase/migrations/*.sql; do v=$(basename "$f"); echo "${v%%_*}"; done | sort | xargs)
[ -n "$LOCAL_LIST" ] && [ "$LOCAL_LIST" = "$FILES" ] \
  || stop 'could not read the migration list, or it does not match main; stopping rather than guessing'
[ "$REMOTE_LIST" = "$LOCAL_LIST" ] \
  || stop 'the project database does not match main (a change is missing or extra); tell Claude before deploying'
echo 'The project database matches main.'

# grade, with the gateway's sign-in check on.
grade_state() {
  supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json" </dev/null \
    || stop 'could not read the live functions'
  python3 - "$STAGE/functions.json" "$1" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])) or []
rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
if not isinstance(rows,list) or not all(isinstance(r,dict) for r in rows): sys.exit('could not read the live functions; tell Claude')
m=[r for r in rows if r.get('slug',r.get('name'))=='grade']
if sys.argv[2]=='before':
 if len(m)!=1: sys.exit('grade is not live on the project; this script only updates it, so tell Claude')
 if m[0].get('verify_jwt') is not True: sys.exit('grade is live without its sign-in check; tell Claude')
 print('grade: live at version '+str(m[0].get('version'))+'; this redeploys it')
else:
 if len(m)!=1 or m[0].get('verify_jwt') is not True or m[0].get('status','ACTIVE')!='ACTIVE':
  sys.exit('grade is not live with its sign-in check on; tell Claude before anything else')
 print('grade: live at version '+str(m[0].get('version'))+', sign-in check on')
PY
}

grade_state before || stop 'grade is not as expected; tell Claude'

if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would deploy grade from main, then check it refuses a request with no sign-in'
  echo 'DRY RUN FINISHED: nothing was changed.'
  exit 0
fi

supabase functions deploy grade --project-ref "$REF" --use-api </dev/null \
  || stop 'grade did not deploy; nothing else changed, and running this again is safe'
grade_state after || stop 'grade deployed, but not as reviewed; tell Claude before anything else'
rm -f "$STAGE/answer.json"
STATUS=$(curl -s -o "$STAGE/answer.json" -w '%{http_code}' --max-time 30 -X POST "$URL/functions/v1/grade" \
  -H 'Content-Type: application/json' -d '{}' || true)
[ "$STATUS" = 401 ] \
  || stop "deployed, but grade answered $STATUS to a request with no sign-in (expected 401); tell Claude before anything else"
echo 'grade: refuses a request with no sign-in (401), as it should.'
echo 'DONE: grade is live from main and marks only the criteria a student ticks.'
echo 'Nothing else changed. Build 3 can go out now.'
