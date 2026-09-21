"""New synthetic identities only. No imported Windows observation or app storage."""
import copy
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import receive_contract_offline as c
import receive_ab_simulator as a


def uid(n):
    return 'ee260914-0000-4000-8000-%012d' % n


ACCOUNT, PROJECT, ROOT, DOC, DOC2, TOP_ORDER, ORDER, RUN = [uid(n) for n in range(1,9)]
DATE = '2026-09-14T00:00:00.123456Z'


def dataset():
    folder = dict(project_id=PROJECT,folder_id=ROOT,parent_folder_id=None,name='합성',
        revision=1,updated_at=DATE,is_deleted=False,deleted_at=None)
    doc = dict(project_id=PROJECT,document_id=DOC,parent_folder_id=ROOT,name='가.txt',
        relative_path='합성/가.txt',revision=1,structure_revision=1,updated_at=DATE,
        is_deleted=False,deleted_at=None,content='e\u0301🙂\n')
    doc2 = dict(doc,document_id=DOC2,name='나.txt',relative_path='합성/나.txt',content='')
    order = dict(project_id=PROJECT,tree_order_id=ORDER,parent_folder_id=ROOT,revision=1,updated_at=DATE,children=[DOC,DOC2])
    top = dict(order,tree_order_id=TOP_ORDER,parent_folder_id=None,children=[ROOT])
    hs = dict(supported=True,project_id=PROJECT,project_sync_mode='ID_BASED',migration_epoch=1,
        contract_version='0.2.0',canonical_contract_sha256=c.CONTRACT_SHA,server_contract_sha256=c.CONTRACT_SHA,
        server_protocol_version=3,supported_protocol_versions=[3,4],server_capabilities=sorted(c.CAPABILITIES))
    return [dict(id=ACCOUNT),hs,[dict(project_id=PROJECT,owner_id=ACCOUNT,is_deleted=False)],
        [dict(project_id=PROJECT,project_sync_mode='ID_BASED',migration_epoch=1)],
        [doc,doc2],[folder],[top,order]]


def expected(values=None):
    v = copy.deepcopy(values if values is not None else dataset())
    return c.Expected(ACCOUNT,PROJECT,dict(root_id=ROOT,
        members=dict(documents=v[4],folders=v[5],tree_orders=[v[6][1]]),reference_ids=[TOP_ORDER],
        reference_rows=dict(tree_orders=[v[6][0]])))


def responses(values=None):
    v = dataset() if values is None else values
    return [a.MockResponse(c.json_bytes(value),content_range=(('0-%d/%d'%(len(value)-1,len(value))) if value else '*/0') if i >= 2 else None)
        for i,value in enumerate(v)]


def timing(**changes):
    # Deliberately tiny mock milliseconds, NOT proposed production limits or an approval.
    values = dict(request_ms=100,pass_ms=1000,interpass_ms=100,preapply_ms=100,
        local_apply_ms=100,total_ms=3000,not_before_utc_ms=1000,expires_utc_ms=6000)
    values.update(changes)
    return a.Timing(**values)


def envelope():
    v = dataset()
    binding = dict(account_id=ACCOUNT,project_id=PROJECT,contract_version='0.2.0',
        contract_sha256=c.CONTRACT_SHA,protocol_version=3,mode='ID_BASED',epoch=1)
    ref = lambda aid, ptr: dict(artifact_id=aid,json_pointer=ptr)
    entry = lambda kind,id,parent,name,ptr,member: dict(entity_kind=kind,entity_id=id,parent_id=parent,name=name,
        allowed_actions=['observe','future_apply'] if member else ['observe'],source_refs=[ref('rows',ptr)])
    target = dict(binding=binding,root_id=ROOT,parent_id=None,
        members=[entry('folder',ROOT,None,'합성','/5/0',True),entry('document',DOC,ROOT,'가.txt','/4/0',True)],
        references=[entry('order',TOP_ORDER,None,None,'/6/0',False)],context_only=[])
    batch = dict(batch_id=uid(30),operation_ids=[uid(31)],result='synthetic')
    files = {'target.json':c.json_bytes(target),'rows.json':c.json_bytes(v),'requests.json':c.json_bytes([batch]),
        'response.json':c.json_bytes(batch),'headers.json':c.json_bytes({'Content-Range':'0-1/2'}),
        'clock.json':c.json_bytes({'received_utc_ms':1005})}
    roles = [('target','target_manifest','target.json'),('rows','raw_json','rows.json'),
        ('requests','creation_requests','requests.json'),('response','creation_response','response.json'),
        ('headers','header_json','headers.json'),('clock','local_measurement','clock.json')]
    artifacts = [dict(artifact_id=aid,role=role,path=p,sha256=c.sha(files[p]),byte_count=len(files[p])) for aid,role,p in roles]
    e = dict(format='windows-isolated-receive-handoff-v1',schema_version=1,binding=binding,
        target=dict(target,manifest_ref=ref('target','')),artifacts=artifacts,
        creation=[dict(request_index=8,request_ref=ref('requests','/0'),batch_id=uid(30),operation_ids=[uid(31)],response_ref=ref('response',''))],
        observations=[dict(phase='A',request_index=5,method='GET',path='/rest/v1/documents',query={'project_id':'eq.'+PROJECT},
            request_body_sha256=c.sha(b''),response_ref=ref('rows','/4'),http_status=200,evidence_ids=['count','range','time','absent'])],
        evidence={'count':dict(state='derived_from_raw',value=2,source_ref=ref('rows','/4'),missing_evidence_id=None),
            'range':dict(state='captured_header',value='0-1/2',source_ref=ref('headers','/Content-Range'),missing_evidence_id=None),
            'time':dict(state='local_measured',value=1005,source_ref=ref('clock','/received_utc_ms'),missing_evidence_id=None),
            'absent':dict(state='unavailable',value=None,source_ref=None,missing_evidence_id='missing-old-time')},
        missing_evidence=[dict(evidence_id='missing-old-time',expected_role='request_time',phase='precreate',request_index=1,reason='not captured')],
        checks=[dict(check_id='creation_link',expected=True,reported=dict(producer='synthetic-Windows',run_id=uid(40),state='pass',value=True),
            independent=dict(verifier='claimed-iPad',run_id=uid(41),state='pass',value=True),evidence_refs=[ref('response','')],reason=None)],
        authority=dict(baseline_ready=False,baseline_applied=False,execution_allowed=False,app_binding_created=False,atomic_snapshot=False))
    files['handoff.json'] = c.json_bytes(e)
    return files,e


def repack(files,e, target=False):
    """Fixture producer updates declared raw hashes; verifier never repairs inputs."""
    if target: files['target.json'] = c.json_bytes({k:v for k,v in e['target'].items() if k != 'manifest_ref'})
    for artifact in e['artifacts']:
        p = artifact['path']
        if p in files:
            artifact.update(sha256=c.sha(files[p]),byte_count=len(files[p]))
    files['handoff.json'] = c.json_bytes(e)
    return files
