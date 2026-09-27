#!/usr/bin/env bash
# Felipe-run dependency update. Default preview never deploys or changes secrets.
set -euo pipefail
DRY_RUN=${DRY_RUN:-1}
REF=ssvehwhblgqtvqkfbkbj
DIGEST=db975f0ea502b3935c4d3fe37214aec915ba0395ffd7b033c3dcaa7edda274e2
case "$DRY_RUN" in 0|1) ;; *) echo 'DRY_RUN must be 0 or 1'; exit 1;; esac
stop() { echo "STOPPED: $*; no later step ran." >&2; exit 1; }
for tool in git supabase python3; do command -v "$tool" >/dev/null || stop "missing $tool"; done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/albus-dependency-deploy.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
if [ "$DRY_RUN" = 1 ] && [ -n "${ALBUS_SOURCE:-}" ]; then
  mkdir -p "$STAGE/repo"
  cp -R "$ALBUS_SOURCE/supabase" "$STAGE/repo/supabase"
  echo 'Previewing supplied candidate source; this does not establish that it is merged.'
else
  git clone --quiet --depth 1 --branch main https://github.com/fgutort8-droid/albus.git "$STAGE/repo"
fi
cd "$STAGE/repo"
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
[ "$ACTUAL" = "$DIGEST" ] || stop 'Edge source or dependency configuration differs from reviewed files'
echo "Verified Edge source SHA-256: $ACTUAL"
supabase functions list --project-ref "$REF" --output json > "$STAGE/functions.json"
python3 - "$STAGE/functions.json" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1])); rows=rows.get('functions',rows.get('rows',[])) if isinstance(rows,dict) else rows
for name in ['breakdown','grade','revenuecat-webhook']:
 matches=[r for r in rows if r.get('slug',r.get('name'))==name]
 assert len(matches)==1 and matches[0].get('verify_jwt') is (name != 'revenuecat-webhook'), name+': verify existing JWT policy before proceeding'
 print(name+': gateway JWT policy matches the reviewed configuration')
PY
if [ "$DRY_RUN" = 1 ]; then
  echo '[dry run] would deploy all three functions with locked dependencies and unchanged JWT policies'
  echo 'DRY RUN FINISHED: no migrations, deployments or secret changes performed.'
else
  supabase functions deploy breakdown --project-ref "$REF" --use-api </dev/null
  supabase functions deploy grade --project-ref "$REF" --use-api </dev/null
  supabase functions deploy revenuecat-webhook --project-ref "$REF" --no-verify-jwt --use-api </dev/null
  echo 'DONE: locked Edge dependencies deployed. No secrets or spending configuration changed.'
fi
