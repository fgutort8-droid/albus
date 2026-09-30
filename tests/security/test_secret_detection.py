import secrets,subprocess,tempfile,unittest,shutil
from pathlib import Path
from urllib.parse import urlunsplit
ROOT=Path(__file__).resolve().parents[2]

class SecretDetectionTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('gitleaks'),'Gitleaks is tested in the required secrets CI job')
    def test_canary_is_blocked_and_redacted_even_in_example_or_workflow(self):
        for filename in ('.env.example','.github/workflows/canary.yml'):
            for kind in ('webhook','database'):
                with self.subTest(filename=filename,kind=kind),tempfile.TemporaryDirectory() as directory:
                    root=Path(directory)
                    subprocess.run(['git','init','-q',directory],check=True)
                    shutil.copy(ROOT/'.gitleaks.toml',root/'.gitleaks.toml')
                    path=root/filename;path.parent.mkdir(parents=True,exist_ok=True)
                    canary=secrets.token_urlsafe(40)
                    value='REVENUECAT_WEBHOOK_SECRET='+canary if kind=='webhook' else 'DATABASE_URL='+urlunsplit(('postgres','albus:'+canary+'@database.example','/app','',''))
                    path.write_text(value+'\n')
                    subprocess.run(['git','-C',directory,'add','.'],check=True)
                    result=subprocess.run(['gitleaks','git','--pre-commit','--staged','--redact=100','--verbose',
                        '--no-banner','--config',str(root/'.gitleaks.toml'),directory],capture_output=True,text=True)
                    self.assertEqual(result.returncode,1)
                    self.assertNotIn(canary,result.stdout+result.stderr)

if __name__=='__main__':unittest.main()
