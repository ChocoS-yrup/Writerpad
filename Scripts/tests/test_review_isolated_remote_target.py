import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import review_isolated_remote_target as r

def uid(label):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'synthetic-offline-review/' + label))

def node(ident, path, parent=None, text=None, revision=1, structure=1, deleted=False):
    return dict(id=ident, kind='folder' if text is None else 'text', parent_id=parent, path=path,
                revision=revision, structure_revision=None if text is None else structure, deleted=deleted,
                utf8_bytes=None if text is None else len(text.encode()), ends_lf=None if text is None else text.endswith('\n'),
                sha256=None if text is None else hashlib.sha256(text.encode()).hexdigest())

def fixture():
    main=uid('main'); manuscript='f4c92790-d675-4970-b1fc-b90f3a929ffb'
    rows=[node(main,'메인'), node(r.PARENT,'메인/메모장',main), node(manuscript,'메인/원고',main),
          node(r.OLD_ROOT,r.OLD_PATH,r.PARENT)]
    a='dbccc13f-899c-4a49-82a4-9a1ead1dc417'; b='86082d2a-51ad-4cd8-bc4d-d64fe2aec2e5'
    rows += [node(a,r.OLD_PATH+'/A수정',r.OLD_ROOT),node(b,r.OLD_PATH+'/B',r.OLD_ROOT,revision=3),
             node('955ff845-aa32-4f10-956e-bac83501b205',r.OLD_PATH+'/B/왕복.txt',b,'Windows 충돌 기준\n',9,4),
             node('be2814bb-a04d-4954-aaab-b600235da812',r.OLD_PATH+'/빈문서.txt',r.OLD_ROOT,'',5,6,True)]
    protected=node('db8a3cc2-8b1a-5539-841c-042de34f5fd6','메인/원고/일반본문검증 20260912.txt',manuscript,'',9,1)
    protected.update(utf8_bytes=393,ends_lf=True,sha256='570040e0bd94d5ff31c64799d549775ef74eb14503b7fa374f170ad7297b764f')
    rows.append(protected)
    before=dict(format=r.FORMAT,endpoint=r.ENDPOINT,account_id=uid('account'),server_project_id=r.PROJECT,complete=True,nodes=rows)
    candidate=copy.deepcopy(before); root=uid('root'); path='메인/메모장/새 원격 대상 합성 제안'
    candidate['nodes'] += [node(root,path,r.PARENT),node(uid('text'),path+'/입력.txt',root,'합성\n')]
    target=dict(format=r.FORMAT,purpose='offline_review_only',origin='synthetic_test',endpoint=r.ENDPOINT,
                account_id=uid('account'),server_project_id=r.PROJECT,local_project_id=uid('local'),
                parent_id=r.PARENT,root_id=root,root_path=path,member_ids=[root,uid('text')],
                before_sha256=None,candidate_sha256=None,semantics=copy.deepcopy(r.SEMANTICS))
    return target,before,candidate

def encode(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True).encode()

def prepare(target,before,candidate):
    a,b=encode(before),encode(candidate)
    target['before_sha256']=hashlib.sha256(a).hexdigest();target['candidate_sha256']=hashlib.sha256(b).hexdigest()
    return a,b

class RemoteReviewTests(unittest.TestCase):
    def setUp(self):
        self.t,self.a,self.b=fixture()
    def check(self):
        a,b=prepare(self.t,self.a,self.b)
        return r.review(self.t,self.a,self.b,a,b)
    def blocked(self,code=None):
        with self.assertRaises(r.Invalid) as cm:self.check()
        if code:self.assertEqual(str(cm.exception),code)
    def test_valid_synthetic_review_never_grants_execution(self):
        with patch('socket.socket',side_effect=AssertionError('network forbidden')):
            result=self.check()
        self.assertEqual(result['status'],'offline_review_checked');self.assertFalse(result['execution_allowed'])
        self.assertFalse(result['live_server_verified']);self.assertFalse(result['app_binding_created'])
        self.assertIn('REMOTE_BOOTSTRAP_ADAPTER_NOT_IMPLEMENTED',result['blockers'])
    def test_windows_label_does_not_verify_provenance(self):
        self.t['origin']='windows_export'
        result=self.check();self.assertFalse(result['execution_allowed'])
        self.assertIn('WINDOWS_FORMAT_ACCEPTANCE_AND_EXPORT_PROVENANCE_UNVERIFIED',result['blockers'])
    def test_unknown_execution_and_credential_fields_rejected(self):
        for key in ['execution','access_token','automatic_policy']:
            self.t[key]='sensitive';self.blocked('TARGET_KEYS');del self.t[key]
    def test_staging_and_project_are_both_pinned(self):
        self.t['endpoint']='https://invalid.example';self.blocked('STAGING_SCOPE')
        self.t['endpoint']=r.ENDPOINT;self.t['server_project_id']=uid('other-project');self.blocked('STAGING_SCOPE')
    def test_old_and_synthetic_local_projects_rejected(self):
        for value in [r.OLD_LOCAL,*r.SYNTHETIC]:
            self.t['local_project_id']=value;self.blocked('LOCAL_PROJECT_REUSE')
    def test_old_synthetic_and_duplicate_member_ids_rejected(self):
        original=self.t['member_ids'][:]
        for value in [r.OLD_ROOT,*r.SYNTHETIC]:
            self.t['member_ids']=original+[value];self.blocked('PROTECTED_MEMBER')
        self.t['member_ids']=original+[original[0]];self.blocked('MEMBER_IDS')
    def test_parent_and_path_boundaries_rejected(self):
        self.t['parent_id']=uid('other-parent');self.blocked('PARENT_SCOPE');self.t['parent_id']=r.PARENT
        for path in [r.OLD_PATH,'메인/메모장/../원고','/tmp/input','메인/원고/새 시험']:
            self.t['root_path']=path;self.blocked()
    def test_each_policy_semantic_mismatch_is_blocked(self):
        for field in r.SEMANTICS:
            self.t['semantics'][field]='different';self.blocked('AUTOMATIC_SEMANTICS_DIFFER')
            self.t['semantics'][field]=r.SEMANTICS[field]
    def test_changed_input_bytes_cannot_use_old_hash(self):
        a,b=prepare(self.t,self.a,self.b)
        with self.assertRaisesRegex(r.Invalid,'EVIDENCE_HASH_MISMATCH'):
            r.review(self.t,self.a,self.b,a+b'\n',b)
    def test_account_mismatch_and_incomplete_export_rejected(self):
        self.b['account_id']=uid('other');self.blocked('SNAPSHOT_CONTEXT')
        self.b['account_id']=self.t['account_id'];self.b['complete']=False;self.blocked('SNAPSHOT_COMPLETENESS')
    def test_missing_protected_baseline_and_rev9_drift_rejected(self):
        protected=self.a['nodes'].pop();self.blocked('PRESERVED_BASELINE_MISSING')
        self.a['nodes'].append(protected);protected['revision']=8;self.blocked('PROTECTED_REV9_DRIFT')
    def test_existing_rows_must_be_byte_metadata_identical(self):
        self.b['nodes'][3]['revision']+=1;self.blocked('OUTSIDE_TARGET_CHANGED')
    def test_deleted_e_and_conflict_remote_remain_pinned(self):
        self.a['nodes'][6]['revision']=10;self.blocked('PRESERVED_CONFLICT_REMOTE_DRIFT')
        self.a['nodes'][6]['revision']=9;self.a['nodes'][7]['deleted']=False;self.blocked('PRESERVED_DELETED_E_DRIFT')
    def test_unlisted_additions_and_removals_are_rejected(self):
        extra=node(uid('extra'),'메인/추가',self.a['nodes'][0]['id'])
        self.b['nodes'].append(extra);self.blocked('UNDECLARED_ADDITION_OR_REMOVAL');self.b['nodes'].pop()
        self.b['nodes'].pop(4);self.blocked('UNDECLARED_ADDITION_OR_REMOVAL')
    def test_new_tree_may_not_escape_to_other_parent(self):
        row=self.b['nodes'][-1];row['parent_id']=r.PARENT;row['path']='메인/메모장/탈출.txt'
        self.blocked('MEMBER_OUTSIDE_ROOT')
    def test_parent_cycle_and_missing_parent_rejected(self):
        row=self.b['nodes'][-1];row['parent_id']=uid('missing');self.blocked('MISSING_PARENT')
        row['parent_id']=self.t['root_id'];root=self.b['nodes'][-2];root['parent_id']=root['id'];root['deleted']=True
        self.blocked('PARENT_CYCLE')
    def test_bool_revision_and_invalid_hash_are_not_accepted(self):
        row=self.b['nodes'][-1];row['revision']=True;self.blocked('REVISION_TYPE_OR_RANGE')
        row['revision']=1;row['sha256']='not-a-hash';self.blocked('HASH_FORMAT')
    def test_duplicate_json_keys_and_nonfinite_rejected(self):
        for raw in [b'{"id":1,"id":2}',b'{"x":NaN}',b'{"x":Infinity}',b'\xff']:
            with self.assertRaises(r.Invalid):r.decode(raw)
    def test_file_review_is_read_only_and_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();p=root/'snapshot.json';p.write_bytes(encode(self.a));original=p.read_bytes()
            self.assertEqual(r.read(p)[0],original);self.assertEqual(p.read_bytes(),original)
            link=root/'link.json';link.symlink_to(p)
            with self.assertRaisesRegex(r.Invalid,'INPUT_SYMLINK'):r.read(link)
    def test_cli_block_report_never_echoes_private_input(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();paths=[]
            for name,value in [('target',{'access_token':'secret-private-value'}),('before',self.a),('candidate',self.b)]:
                p=root/(name+'.json');p.write_bytes(encode(value));paths.append(str(p))
            from io import StringIO
            output=StringIO()
            with patch('sys.stdout',output):self.assertEqual(r.main(paths),2)
            self.assertNotIn('secret-private-value',output.getvalue());self.assertNotIn(temp,output.getvalue())

if __name__=='__main__':unittest.main()
