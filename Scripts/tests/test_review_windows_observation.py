import copy
import hashlib
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import review_windows_observation as r

ROOT = '10000000-0000-4000-8000-000000000001'
DOC = '10000000-0000-4000-8000-000000000002'
ORDER = '10000000-0000-4000-8000-000000000003'
ROOT_ORDER = '10000000-0000-4000-8000-000000000004'
RUN = '10000000-0000-4000-8000-000000000005'

def enc(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))+'\n').encode()

def fixture(stop_at=None, raw=False):
    folder = dict(id=ROOT, kind='folder', parent_id=None, name='합성', path='합성', revision=1, structure_revision=None,
                  deleted=False, utf8_bytes=None, ends_lf=None, sha256=None)
    text = '합성 e\u0301🙂\n'
    doc = dict(id=DOC, kind='text', parent_id=ROOT, name='원고.txt', path='합성/원고.txt', observed_relative_path='합성/원고.txt',
               revision=1, structure_revision=1, deleted=False, utf8_bytes=len(text.encode()), ends_lf=True, sha256=r.sha(text.encode()))
    orders = [dict(id=ROOT_ORDER, parent_id=None, revision=1, children=[ROOT]), dict(id=ORDER, parent_id=ROOT, revision=1, children=[DOC])]
    old = [{k:v for k,v in n.items() if k not in ['name','observed_relative_path']} for n in [folder, doc]]
    files = {'reference/before-metadata.json':enc(dict(format='windows-isolated-target-metadata-proposal-v1', endpoint=r.ENDPOINT,
        account_id=r.ACCOUNT, server_project_id=r.PROJECT, complete=False, nodes=old)),
        'reference/before-orders.json':enc(dict(format='windows-retained-orders-v1', complete=False, orders=orders))}
    hashes = dict(metadata=r.sha(files['reference/before-metadata.json']), orders=r.sha(files['reference/before-orders.json']))
    scope = dict(format='windows-isolated-read-scope-v1', run_id=RUN, endpoint=r.ENDPOINT, account_id=r.ACCOUNT,
        project_id=r.PROJECT, max_requests=7, max_seconds=180, expires_at=1200, reference_sha256=hashes)
    files['scope.json'] = enc(scope)
    obs = dict(format='windows-read-observation-v1', status='observed' if stop_at is None else 'stopped',
        stop_reason=None if stop_at is None else 'REFERENCE_DIFFERENCE', execution_allowed=False, complete=False, baseline_ready=False,
        atomic_snapshot=False, visibility='synthetic account scope', endpoint=r.ENDPOINT, account_id=r.ACCOUNT,
        server_project_id=r.PROJECT, contract_version='0.2.0', protocol_version=3, reference_sha256=hashes,
        http_used=stop_at or 7, auth_user_used=1, token_refreshes=0, document_structure_writes=0, automatic_cycles=0,
        started_at=1000, deadline=1180, candidate_check='no collision in observed scope' if stop_at is None else 'not_completed',
        differences=[], special_metadata_ids=[], nodes=[doc,folder], orders=orders)
    if stop_at:
        obs['nodes']=[{k:v for k,v in doc.items() if k!='path'}];obs['orders']=[]
    events=[]
    def event(name, data):
        row=dict(sequence=len(events)+1, previous=events[-1]['sha256'] if events else '', event=name, data=data)
        row['sha256']=r.sha(enc(row));events.append(row)
    event('opened',dict(scope_sha256=r.sha(files['scope.json']),started=1000,deadline=1180))
    for n in range(1,(stop_at or 7)+1):
        event('attempt',dict(request=n,method='POST' if n==2 else 'GET',path=r.PATHS[n-1],
            params=None if n<3 else dict(project_id='eq.'+r.PROJECT,select='*',limit='10000'),body_sha256=r.sha(enc(dict(p_project_id=r.PROJECT,p_contract_sha256=r.CONTRACT_SHA))) if n==2 else r.sha(b''),at=1000+n))
        body=enc({'synthetic':n});count=None if n<3 else (2 if n==7 else 1)
        if raw:files[f'Q{n}.body']=body
        event('response',dict(request=n,file=f'Q{n}.body',sha256=r.sha(body),bytes=len(body),status=200,at=1000+n,
            content_range=None if n<3 else f'0-{count-1}/{count}',content_range_state='missing' if n<3 else 'value'))
        if n!=stop_at:event('validated',dict(request=n,count=count,at=1000+n))
    files['observation.json']=enc(obs)
    event(obs['status'],dict(reason=obs['stop_reason'],http_used=stop_at or 7,at=1010,observation_sha256=r.sha(files['observation.json'])))
    files['journal.jsonl']=b''.join(enc(e) for e in events)
    return files

def alter_obs(files, action):
    obs=json.loads(files['observation.json']);action(obs);files['observation.json']=enc(obs)
    ev=events(files);ev[-1]['data']['observation_sha256']=r.sha(files['observation.json']);save_events(files,ev)

def events(files):return [json.loads(line) for line in files['journal.jsonl'].splitlines()]

def save_events(files, ev):
    # Intentionally do not rehash the chain: review checks declared links but
    # does not claim cross-platform canonical encoding validation.
    files['journal.jsonl']=b''.join(enc(e) for e in ev)

class ObservationTests(unittest.TestCase):
    def assertBlocked(self, files, code):
        with self.assertRaisesRegex(r.Invalid,code):r.review(files)

    def test_success_is_metadata_review_never_baseline_or_raw_verification(self):
        f=fixture();before=copy.deepcopy(f)
        with patch.object(socket,'socket',side_effect=AssertionError('network forbidden')):
            result=r.review(f)
        self.assertEqual(f,before)
        self.assertEqual(result['status'],'observation_reviewed')
        self.assertEqual(result['metadata_reference_differences'],[])
        self.assertEqual(result['reference_uncompared'],[])
        for k in ['execution_allowed','baseline_ready','baseline_applied','body_independently_verified','chain_hash_verified','candidate_profile_verified']:
            self.assertIs(result[k],False)
        self.assertEqual(len(result['raw_missing']),7)

    def test_missing_reference_does_not_use_another_baseline(self):
        f=fixture();del f['reference/before-metadata.json'];del f['reference/before-orders.json']
        result=r.review(f)
        self.assertEqual(len(result['reference_uncompared']),2)
        self.assertIn('reference_comparison_incomplete',result['unverified'])

    def test_partial_count_and_absent_path_orders_stay_unknown(self):
        result=r.review(fixture(stop_at=5))
        self.assertEqual(result['status'],'partial_observation_reviewed')
        self.assertEqual(result['requests'][4]['stage'],'response_received')
        self.assertIsNone(result['requests'][4]['count'])
        self.assertFalse(result['requests'][4]['count_validated'])
        self.assertEqual(result['requests'][5]['stage'],'unattempted')
        self.assertTrue(result['reference_uncompared'])
        self.assertFalse(result['metadata_reference_differences'])

    def test_missing_terminal_does_not_promote_existing_observation(self):
        f=fixture();save_events(f,events(f)[:-1]);result=r.review(f)
        self.assertEqual(result['status'],'incomplete_observation');self.assertNotIn('finished_at',result)
        self.assertIn('terminal_link_missing',result['unverified'])

    def test_scope_only_has_unknown_usage(self):
        f=fixture();result=r.review({'scope.json':f['scope.json']})
        self.assertIsNone(result['reserved_http']);self.assertEqual(result['status'],'incomplete_observation')

    def test_partial_journal_is_not_truncated_or_repaired(self):
        f=fixture();f['journal.jsonl']=f['journal.jsonl'][:-1];old=f['journal.jsonl']
        self.assertBlocked(f,'PARTIAL_JOURNAL');self.assertEqual(f['journal.jsonl'],old)

    def test_reference_whitespace_byte_tampering_is_blocked(self):
        f=fixture();f['reference/before-orders.json']+=b' ';self.assertBlocked(f,'REFERENCE_HASH')

    def test_supplied_raw_hash_is_checked_without_claiming_content_validation(self):
        f=fixture(raw=True);result=r.review(f)
        self.assertFalse(result['body_independently_verified']);self.assertEqual(result['raw_missing'],[])
        f['Q5.body']+=b' ';self.assertBlocked(f,'RAW_HASH')

    def test_node_body_differences_are_reported_without_body_or_rewrite(self):
        f=fixture();alter_obs(f,lambda o:o['nodes'][0].update(utf8_bytes=42,sha256='a'*64))
        result=r.review(f);fields=result['metadata_reference_differences'][0]['fields']
        self.assertIn('sha256',fields);self.assertIn('utf8_bytes',fields)
        self.assertFalse(result['baseline_ready'])

    def test_order_revision_difference_preserves_children_order(self):
        f=fixture();alter_obs(f,lambda o:o['orders'][0].update(revision=2))
        result=r.review(f);self.assertIn('revision',result['metadata_reference_differences'][0]['fields'])

    def test_duplicate_ids_missing_parents_and_path_mismatch_blocked(self):
        for action,code in [(lambda o:o['nodes'].append(copy.deepcopy(o['nodes'][0])),'DUPLICATE_ROW'),
                            (lambda o:o['nodes'][0].update(parent_id=RUN),'PARENT_GRAPH'),
                            (lambda o:o['nodes'][0].update(observed_relative_path='wrong'),'OBSERVED_PATH_MISMATCH')]:
            f=fixture();alter_obs(f,action);self.assertBlocked(f,code)

    def test_children_membership_is_not_repaired(self):
        f=fixture();alter_obs(f,lambda o:o['orders'][1].update(children=[]));self.assertBlocked(f,'ORDER_MEMBERSHIP')

    def test_privilege_flags_cannot_be_promoted(self):
        for key in ['complete','baseline_ready','execution_allowed','atomic_snapshot']:
            f=fixture();alter_obs(f,lambda o:o.update({key:True}));self.assertBlocked(f,'OBSERVATION_PRIVILEGE')

    def test_usage_bool_overbudget_and_nonfinite_rejected(self):
        f=fixture();alter_obs(f,lambda o:o.update(http_used=True));self.assertBlocked(f,'INTEGER_RANGE')
        f=fixture();s=json.loads(f['scope.json']);s['max_requests']=8;f['scope.json']=enc(s);self.assertBlocked(f,'INTEGER_RANGE')
        f=fixture();f['scope.json']=f['scope.json'].replace(b'180',b'1e999');self.assertBlocked(f,'TIME_NUMBER')

    def test_endpoint_and_ended_run_rejected(self):
        for key,value,code in [('endpoint','https://invalid.example','SCOPE_BINDING'),('run_id',r.ENDED,'ENDED_RUN')]:
            f=fixture();s=json.loads(f['scope.json']);s[key]=value;f['scope.json']=enc(s);self.assertBlocked(f,code)

    def test_request_order_filter_and_missing_validation_blocked(self):
        for index,field,value,code in [(4,'request',3,'REQUEST_ORDER'),(7,'params',{},'REQUEST_FILTER')]:
            f=fixture();ev=events(f);ev[index]['data'][field]=value;save_events(f,ev);self.assertBlocked(f,code)
        f=fixture();ev=events(f);ev[3]['event']='attempt';self.assertBlocked(fixture()|{'journal.jsonl':b''.join(enc(e) for e in ev)},'FIELD_SET')

    def test_wrong_handshake_payload_hash_is_blocked(self):
        f=fixture();ev=events(f);ev[4]['data']['body_sha256']='a'*64
        save_events(f,ev);self.assertBlocked(f,'HANDSHAKE_REQUEST_HASH')

    def test_count_truncation_unknown_total_and_failed_http_not_validated(self):
        for field,value,code in [('content_range','0-0/2','COUNT_RANGE_MISMATCH'),('content_range','0-0/*','COUNT_RANGE_MISMATCH'),('status',401,'VALIDATED_HTTP')]:
            f=fixture();ev=events(f);ev[8]['data'][field]=value;save_events(f,ev);self.assertBlocked(f,code)

    def test_observation_digest_and_scope_digest_block_tampering(self):
        f=fixture();f['observation.json']+=b' ';self.assertBlocked(f,'OBSERVATION_HASH')
        f=fixture();f['scope.json']+=b' ';self.assertBlocked(f,'SCOPE_HASH')

    def test_complete_result_requires_path_and_derived_counts(self):
        f=fixture();alter_obs(f,lambda o:o['nodes'][0].pop('path'));self.assertBlocked(f,'COMPLETE_PATH_MISSING')
        f=fixture();alter_obs(f,lambda o:o.update(special_metadata_ids=[RUN]));self.assertBlocked(f,'DERIVED_COUNT')

    def test_unknown_and_duplicate_json_fields_rejected(self):
        f=fixture();alter_obs(f,lambda o:o.update(access_token='not-a-real-secret'));self.assertBlocked(f,'FIELD_SET')
        f=fixture();f['scope.json']=f['scope.json'].replace(b'{',b'{"run_id":"duplicate",',1);self.assertBlocked(f,'DUPLICATE_JSON_KEY')

    def test_loader_zip_directory_no_writes_and_no_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp).resolve();f=fixture();z=base/'input.zip'
            with zipfile.ZipFile(z,'w') as out:
                for name,raw in f.items():out.writestr('example/'+name,raw)
            before=z.read_bytes()
            with patch.object(socket,'socket',side_effect=AssertionError('network')):
                result=r.review(r.load_bundle(z,'example'))
            self.assertEqual(result['status'],'observation_reviewed');self.assertEqual(z.read_bytes(),before)
            self.assertEqual(list(base.iterdir()),[z])
            d=base/'dir';d.mkdir()
            for name,raw in f.items():
                p=d/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(raw)
            self.assertEqual(r.load_bundle(d),f)

    def test_loader_rejects_traversal_duplicates_symlinks_and_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp).resolve();z=base/'bad.zip'
            with zipfile.ZipFile(z,'w') as out:out.writestr('../scope.json',b'{}')
            with self.assertRaises(r.Invalid):r.load_bundle(z)
            with zipfile.ZipFile(z,'w') as out:
                out.writestr('x',b'1');out.writestr('x',b'2')
            with self.assertRaisesRegex(r.Invalid,'DUPLICATE_ZIP_ENTRY'):r.load_bundle(z)
            link=base/'link';link.symlink_to(z)
            with self.assertRaisesRegex(r.Invalid,'INPUT_SYMLINK'):r.load_bundle(link)
            with patch.object(r,'MAX_FILE',1):
                with zipfile.ZipFile(z,'w') as out:out.writestr('scope.json',b'{}')
                with self.assertRaisesRegex(r.Invalid,'INPUT_TOO_LARGE'):r.load_bundle(z)

    def test_file_manifest_checked_without_following_external_names(self):
        f=fixture();f['SHA256SUMS.json']=enc({'scope.json':r.sha(f['scope.json'])});r.review(f)
        f['SHA256SUMS.json']=enc({'../elsewhere':'a'*64});self.assertBlocked(f,'PATH_TRAVERSAL')

if __name__=='__main__':unittest.main()
