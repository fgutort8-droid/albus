#!/usr/bin/env bash
# Felipe-run: redeploy the three functions so they read Supabase's new API keys.
# Preview: DRY_RUN=1 ALBUS_SOURCE=/path/to/reviewed/albus bash this-script.sh
# After the key PR is merged: DRY_RUN=0 bash this-script.sh
#
# No migrations and no secret changes. The platform already injects the new
# keys (SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS); this only ships the
# code that reads them first. Undo: redeploy from the commit before the merge.
set -euo pipefail
REF=ssvehwhblgqtvqkfbkbj
# Every function source, config.toml, deno.json and deno.lock, as reviewed.
SOURCE_DIGEST=036666ff8b9ae0bba1461caac61e7f5e2ced0bba2db4ac1bca767f1f46747320
DRY_RUN=${DRY_RUN:-1}
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-functions-deploy.XXXXXX")
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
grep -q 'export function resolveKey' supabase/functions/_shared/auth.ts \
  || stop 'merge the reviewed key PR first'
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
echo "Verified function source SHA-256: $ACTUAL"
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
print('The platform injects both new key dictionaries.')
PY
if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would deploy breakdown, grade and revenuecat-webhook with unchanged authentication policies'
  echo 'DRY RUN FINISHED: nothing deployed, no secrets changed.'
  exit 0
fi
supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null
supabase functions deploy grade --project-ref "$REF" --use-api </dev/null
supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null
echo 'DONE: all three functions deployed; they now use the new keys. No secrets changed.'
