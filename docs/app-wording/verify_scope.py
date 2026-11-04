"""Verify this task's wording-only diff against its immutable base. No network."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = '48185b6'

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)

def normalise(source):
    source = re.sub(r'"(?:\\.|[^"\\])*"', '"STRING"', source)
    source = re.sub(r'//[^\n]*|/\*.*?\*/', '', source, flags=re.S)
    return re.sub(r'\s+', '', source)

changed = git('diff', '--name-only', BASE).splitlines()
assert not any(p.startswith(('website/', 'supabase/', 'docs/app-store/'))
               or p.endswith('Config.xcconfig') for p in changed)
checked = []
for name in changed:
    if not name.endswith('.swift'):
        assert name.startswith('docs/app-wording/'), name
        continue
    old = git('show', BASE+':'+name)
    new = (ROOT/name).read_text()
    if name.endswith('PaywallScreen.swift'):
        for title, detail in [
            ('The core tools', 'The study tools Albus picks for a step.'),
            ('The expanded tools', 'More of the library, picked per step.'),
            ('Every study tool', 'The whole library, picked per step.')
        ]:
            old = old.replace(',\n                 ("'+title+'", "'+detail+'")', '')
    if name.endswith('SettingsScreen.swift'):
        old = old.replace('Text(entitlements.plan.priceLabel)',
                          'Text("Reference: \\(entitlements.plan.priceLabel)/month")')
        # Free's five a week is a plan limit, not fair use, so only an
        # unlimited allowance is labelled fair use.
        old = old.replace('allowanceRow("AI plans", aiPlans, unit: "this week")',
                          'allowanceRow(aiPlans.isUnlimited ? "AI plans (fair use)" : "AI plans", aiPlans,\n'
                          '                                         unit: "this week")')
    if '/Notifications/Copy/Corpus' in name:
        pattern = re.compile(r'\.init\("([^"]+)",[^\n]+\n\s*"([^"]*)",\n\s*"([^"]*)"')
        def requirements(text):
            return {m[1]: set(re.findall(r'\{\w+\}', m[2]+m[3])) for m in pattern.finditer(text)}
        assert requirements(old) == requirements(new), name+' placeholder requirements'
    assert normalise(old) == normalise(new), name
    checked.append(name)
retired = ['The core tools', 'The expanded tools', 'Every study tool',
           'a real grade', 'the actual grade', 'More marking, and no limits.',
           'MOST PICKED', 'Plus writes a step-by-step plan every time.']
for file in (ROOT/'ios/App/Albus').rglob('*.swift'):
    source = '\n'.join(line for line in file.read_text().splitlines()
                       if not line.lstrip().startswith('//'))
    assert not any(text in source for text in retired), file
print(f'Wording-only comparison passed: {len(checked)} Swift files.')
print('Protected paths unchanged; retired misleading copy absent.')
