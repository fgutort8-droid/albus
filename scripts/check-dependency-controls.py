#!/usr/bin/env python3
"""Validate immutable build inputs and explicitly scoped workflow tokens."""
import json
from pathlib import Path
import re
import sys
import subprocess
root = Path(__file__).resolve().parents[1]
errors = []
def yaml_document(path):
    # Ruby/Psych ships with macOS and the Ubuntu CI image. Parse YAML rather
    # than matching text: comments, flow mappings and job overrides count.
    program = """
require 'yaml'
require 'json'
text = File.read(ARGV[0])
def check(node)
  if node.is_a?(Psych::Nodes::Mapping)
    keys = node.children.each_slice(2).map { |key, _| key.value }
    raise 'duplicate YAML keys' unless keys.uniq.length == keys.length
  end
  (node.children || []).each { |child| check(child) }
end
check(Psych.parse_stream(text))
puts JSON.generate(YAML.safe_load(text, aliases: false))
"""
    return json.loads(subprocess.check_output(['ruby', '-e', program, str(path)], text=True))


def readonly_permissions(value):
    return (isinstance(value, dict)
            and all(level in ('read', 'none') for level in value.values())) or value == 'read-all'


for path in sorted((root / '.github/workflows').glob('*.y*ml')):
    document = yaml_document(path)
    if not readonly_permissions(document.get('permissions')):
        errors.append(f'{path.name}: explicit read-only workflow permissions required')
    for name, job in document.get('jobs', {}).items():
        if 'permissions' in job and not readonly_permissions(job['permissions']):
            errors.append(f'{path.name}/{name}: job permissions must remain read-only')
        uses = [job['uses']] if 'uses' in job else []
        uses += [step['uses'] for step in job.get('steps', []) if 'uses' in step]
        for action in uses:
            if not action.startswith('./') and not re.fullmatch(r'[\w./-]+@[0-9a-f]{40}', action):
                errors.append(f'{path.name}: action must use a full commit SHA: {action}')
spec = yaml_document(root / 'ios/project.yml')
lock = root / 'ios/Package.resolved'
pins = []
if not lock.exists():
    errors.append('Swift dependency lock is missing')
else:
    pins = json.loads(lock.read_text())['pins']
    if not pins or any(not re.fullmatch(r'[0-9a-f]{40}', p['state'].get('revision', '')) for p in pins):
        errors.append('Every Swift dependency must have an immutable revision')
for name, package in spec.get('packages', {}).items():
    if 'path' in package and 'url' not in package:
        continue
    revision = package.get('revision', '')
    if (not re.fullmatch(r'[0-9a-f]{40}', revision)
            or any(key in package for key in ('from', 'branch', 'version', 'exactVersion', 'minVersion', 'maxVersion'))):
        errors.append(f'{name}: remote Swift dependency requires only an immutable revision')
    matches = [p for p in pins if p.get('location') == package.get('url')]
    if len(matches) != 1 or matches[0]['state'].get('revision') != revision:
        errors.append(f'{name}: Swift declaration must match the canonical lockfile')
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
