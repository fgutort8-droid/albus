#!/usr/bin/env python3
"""Deployment previews reject changed inputs and never invoke deployment."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DeploymentPreviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / 'supabase', self.root / 'source/supabase', ignore=shutil.ignore_patterns('.temp', '.branches'))
        binary = self.root / 'bin/supabase'
        binary.parent.mkdir()
        binary.write_text('''#!/bin/sh
if [ "$1 $2" = "functions list" ]; then
 echo '[{"slug":"breakdown","verify_jwt":true},{"slug":"grade","verify_jwt":true},{"slug":"revenuecat-webhook","verify_jwt":false}]'
else
 echo "Forbidden command: $*" >> "$PREVIEW_FORBIDDEN"
 exit 99
fi
''')
        binary.chmod(0o700)

    def run_preview(self):
        env = dict(os.environ, DRY_RUN='1', ALBUS_SOURCE=str(self.root / 'source'),
                   PATH=str(self.root / 'bin') + ':' + os.environ['PATH'],
                   PREVIEW_FORBIDDEN=str(self.root / 'forbidden'))
        result = subprocess.run(['bash', str(ROOT / 'scripts/deploy-dependencies-2026-09-25.sh')], env=env, capture_output=True, text=True)
        self.assertFalse((self.root / 'forbidden').exists())
        return result

    def test_reviewed_preview_passes(self):
        result = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_changed_handler_rejected(self):
        path = self.root / 'source/supabase/functions/grade/index.ts'
        path.write_text(path.read_text() + '\n// changed source\n')
        self.assertNotEqual(self.run_preview().returncode, 0)

    def test_jwt_comment_cannot_override_false(self):
        path = self.root / 'source/supabase/config.toml'
        source = path.read_text()
        self.assertIn('verify_jwt = true', source)
        path.write_text(source.replace('verify_jwt = true', '# verify_jwt = true\nverify_jwt = false', 1))
        self.assertNotEqual(self.run_preview().returncode, 0)

if __name__ == '__main__':
    unittest.main()
