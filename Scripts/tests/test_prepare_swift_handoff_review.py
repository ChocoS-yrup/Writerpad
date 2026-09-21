import base64
import pathlib
import socket
import tempfile
import unittest
from unittest.mock import patch
import windows_handoff_fixtures as f
import prepare_swift_handoff_review as p


class SwiftPortableTests(unittest.TestCase):
    def setUp(self):
        self.files,self.h,self.binding=f.fixture();f.seal(self.files,self.h);self.pin=f.c.sha(self.files['handoff.json'])
    def test_exact_raw_bytes_preserved_without_authority(self):
        before=dict(self.files)
        with patch.object(socket,'socket',side_effect=AssertionError('no network')):
            data=p.prepare(self.files,self.pin,self.binding)
        value=f.c.strict_json(data)
        self.assertEqual(value['format'],'ipad-windows-handoff-review-bytes-v1')
        self.assertEqual({k:base64.b64decode(v) for k,v in value['files'].items()},before)
        self.assertEqual(self.files,before);self.assertEqual(set(value),{'format','files'})
    def test_pin_mismatch_blocks_export(self):
        with self.assertRaises(f.c.ContractError):p.prepare(self.files,'0'*64,self.binding)
    def test_no_raw_no_export(self):
        del self.files['source/Q14.body']
        with self.assertRaises(f.c.ContractError):p.prepare(self.files,self.pin,self.binding)
    def test_binding_mismatch_blocks_export(self):
        with self.assertRaises(f.c.ContractError):p.prepare(self.files,self.pin,dict(self.binding,endpoint='https://other.invalid'))
    def test_write_never_overwrites(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-native-export-') as d:
            out=pathlib.Path(d)/'review.json';p.write_new(out,b'first')
            with self.assertRaises(FileExistsError):p.write_new(out,b'second')
            self.assertEqual(out.read_bytes(),b'first');self.assertEqual(out.stat().st_mode&0o777,0o600)
    def test_output_symlink_cannot_modify_original(self):
        with tempfile.TemporaryDirectory(prefix='synthetic-native-export-') as d:
            original=pathlib.Path(d)/'original';original.write_bytes(b'original')
            link=pathlib.Path(d)/'link';link.symlink_to(original)
            with self.assertRaises(OSError):p.write_new(link,b'new')
            self.assertEqual(original.read_bytes(),b'original')
