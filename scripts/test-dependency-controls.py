#!/usr/bin/env python3
"""Exercise dependency guard boundaries with isolated repository fixtures."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]

class DependencyControlsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ['scripts/check-dependency-controls.py', 'ios/project.yml', 'ios/Package.resolved',
                     'supabase/functions/deno.json', 'supabase/functions/deno.lock']:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)
        shutil.copytree(SOURCE / '.github/workflows', self.root / '.github/workflows')

    def run_guard(self):
        return subprocess.run(['python3', str(self.root / 'scripts/check-dependency-controls.py')],
                              capture_output=True, text=True)

    def replace(self, name, before, after):
        path = self.root / name
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after, 1))

    def test_current_configuration_passes(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_job_write_permission_rejected(self):
        self.replace('.github/workflows/ci.yml', '  secrets-scan:\n',
                     '  secrets-scan:\n    permissions:\n      contents: write\n')
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_job_write_all_rejected(self):
        self.replace('.github/workflows/ci.yml', '  secrets-scan:\n',
                     '  secrets-scan:\n    permissions: write-all\n')
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_branch_requirement_rejected(self):
        self.replace('ios/project.yml', 'revision: 40344fb3a7007d772218c6ddf6bca9febd8cb226', 'branch: main')
        self.assertNotEqual(self.run_guard().returncode, 0)

    def test_lock_disagreement_rejected(self):
        self.replace('ios/project.yml', '40344fb3a7007d772218c6ddf6bca9febd8cb226', '0' * 40)
        self.assertNotEqual(self.run_guard().returncode, 0)

if __name__ == '__main__':
    unittest.main()
