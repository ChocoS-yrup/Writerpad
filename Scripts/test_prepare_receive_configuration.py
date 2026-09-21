import json
from pathlib import Path
import tempfile
import unittest
from prepare_receive_configuration import build, digest, LIMITS

class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name).resolve()
        self.spec=dict(identity=dict(approvalID='synthetic',device='synthetic',installationID='synthetic',candidateSHA256='a'*64),local='ee260915-0000-4000-8000-000000000482',publishableKey='sb_publishable_fixture',mode='observe',policy=LIMITS)
        self.input=self.root/'input.json';self.portable=self.root/'portable.json';self.exe=self.root/'executable';self.out=self.root/'out'
        self.portable.write_text('{}');self.exe.write_bytes(b'synthetic')
    def tearDown(self):
        self.tmp.cleanup()
    def run_builder(self):
        self.input.write_text(json.dumps(self.spec))
        return build(self.input,self.portable,self.exe,self.out)
    def test_hash_chain_permissions_and_no_overwrite(self):
        sha=self.run_builder();payload=self.out/'ReceiveConfiguration-v1'
        envelope=json.loads((payload/'configuration.json').read_bytes())
        self.assertEqual(sha,digest((payload/'configuration.json').read_bytes()))
        self.assertEqual(envelope['installationSHA256'],digest((payload/'installation.json').read_bytes()))
        self.assertEqual(json.loads((self.out/'launch-arguments.json').read_bytes())[1],sha)
        self.assertEqual((payload/'configuration.json').stat().st_mode & 0o777,0o600)
        before=(payload/'configuration.json').read_bytes()
        with self.assertRaises(FileExistsError): self.run_builder()
        self.assertEqual(before,(payload/'configuration.json').read_bytes())
    def test_secret_and_extra_credentials_rejected_without_output(self):
        self.spec['publishableKey']='sb_secret_fixture'
        with self.assertRaises(ValueError):self.run_builder()
        self.spec['publishableKey']='sb_publishable_fixture';self.spec['password']='not-allowed'
        with self.assertRaises(ValueError):self.run_builder()
        self.assertFalse(self.out.exists())
    def test_symlink_input_rejected(self):
        self.exe.unlink();self.exe.symlink_to(self.portable)
        with self.assertRaises(ValueError):self.run_builder()
        self.assertFalse(self.out.exists())
    def test_policy_expansion_rejected(self):
        self.spec['policy']={**LIMITS,'totalMS':360001}
        with self.assertRaises(ValueError):self.run_builder()
        self.assertFalse(self.out.exists())

if __name__=='__main__': unittest.main()
