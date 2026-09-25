#!/usr/bin/env python3
"""Validate immutable build inputs and explicitly scoped workflow tokens."""
import json
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
errors = []
for path in sorted((root / '.github/workflows').glob('*.yml')):
    source = path.read_text()
    if not re.search(r'^permissions:\n(?:  [a-z-]+: (?:read|none)\n)+', source, re.M):
        errors.append(f'{path.name}: explicit read-only workflow permissions required')
    for action in re.findall(r'\buses:\s*([^\s#]+)', source):
        if not action.startswith('./') and not re.fullmatch(r'[\w./-]+@[0-9a-f]{40}', action):
            errors.append(f'{path.name}: action must use a full commit SHA: {action}')
spec = (root / 'ios/project.yml').read_text()
if re.search(r'^    from:', spec, re.M):
    errors.append('Swift dependencies must use reviewed revisions')
lock = root / 'ios/Package.resolved'
if not lock.exists():
    errors.append('Swift dependency lock is missing')
else:
    pins = json.loads(lock.read_text())['pins']
    if not pins or any(not re.fullmatch(r'[0-9a-f]{40}', p['state'].get('revision', '')) for p in pins):
        errors.append('Every Swift dependency must have an immutable revision')
config = json.loads((root / 'supabase/functions/deno.json').read_text())
if config.get('lock') != {'path': './deno.lock', 'frozen': True}:
    errors.append('Edge dependencies must use a frozen lockfile')
if not (root / 'supabase/functions/deno.lock').exists():
    errors.append('Edge dependency lock is missing')
for error in errors:
    print(error, file=sys.stderr)
if errors:
    raise SystemExit(1)
print('Dependency controls pass: SHA-pinned actions, scoped tokens, Swift revisions and frozen Edge lock.')
