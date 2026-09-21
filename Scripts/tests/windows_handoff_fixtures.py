"""New synthetic Windows-shaped draft. Never reads delivered raw or retained originals."""
import copy
import receive_fixtures as f
import windows_handoff_mapping as w
c = w.c


def fixture():
    v = f.dataset(); v[2][0].pop('is_deleted'); v[2][0].update(trashed_at=None,trashed_by=None)
    v[6][0]['revision'] = 2
    binding = dict(endpoint='https://synthetic.invalid',account_id=f.ACCOUNT,project_id=f.PROJECT,
        project_sync_mode='ID_BASED',migration_epoch=1,contract_version='0.2.0',contract_sha256=c.CONTRACT_SHA)
    plan = dict(format='windows-isolated-target-bootstrap-v1',endpoint=binding['endpoint'],account_id=f.ACCOUNT,project_id=f.PROJECT,
        root_id=f.ROOT,parent_id=None,body_id=f.DOC,empty_id=f.DOC2,parent_order_id=f.TOP_ORDER,root_order_id=f.ORDER,
        body_name=v[4][0]['name'],empty_name=v[4][1]['name'],root_path=v[5][0]['name'],writer_device_id=f.uid(80),
        initial_body=dict(sha256=c.body(v[4][0]['content'])['sha256'],utf8_bytes=c.body(v[4][0]['content'])['byte_count'],ends_lf=True),
        initial_revisions=None,execution_allowed=False,baseline_applied=False,
        reference_sha256={k:c.sha(c.json_bytes([])) for k in ('metadata','orders')})
    source = {'plan.json':plan,'reference-metadata.json':[],'reference-orders.json':[],
        'scope.json':dict(format=plan['format'],run_id=f.RUN,not_before=1000,expires_at=1180,max_requests=16,max_writes=4,max_seconds=180,plan_sha256=c.sha(c.json_bytes(plan)))}
    source.update({'Q%d.body'%(i+1):copy.deepcopy(x) for i,x in enumerate(v)})
    source['Q5.body']=[];source['Q6.body']=[];source['Q7.body']=[dict(v[6][0],children=[],revision=1)]
    source.update({'Q%d.body'%(i+12):copy.deepcopy(x) for i,x in enumerate(v[2:])})
    requests=[]
    groups=[[(v[5][0],'folder','create',0)],[(v[4][0],'document','create',0)],[(v[4][1],'document','create',0)],
            [(v[6][0],'tree_order','reorder',1),(v[6][1],'tree_order','reorder',0)]]
    for offset,group in enumerate(groups):
        bid=f.uid(100+offset);document=offset in (1,2);base='document_commit' if document else 'atomic_structure_commit'
        intents=[];results=[]
        for seq,(row,kind,intent_kind,base_rev) in enumerate(group,1):
            payload={k:copy.deepcopy(row[k]) for k in (('name','parent_folder_id') if kind=='folder' else ('children','parent_folder_id') if kind=='tree_order' else ('name','parent_folder_id','content','is_deleted','structure_revision'))}
            if document:payload.update(content_sha256=c.body(row['content'])['sha256'],content_byte_count=c.body(row['content'])['byte_count'])
            ident=row[w.KINDS[kind][1]];op=f.uid(200+offset*3+seq);key='document_id' if document else 'entity_id'
            intent=dict(sequence=seq,operation_id=op,batch_id=bid,entity_kind=kind,intent_kind=intent_kind,base_revision=base_rev,payload=payload,payload_sha256=w.canonical_digest(payload))
            intent[key]=ident;intents.append(intent)
            result=dict(sequence=seq,operation_id=op,result_revision=row['revision']);result[key]=ident
            if document:result.update({k:payload[k] for k in ('structure_revision','name','parent_folder_id','content_sha256','content_byte_count','is_deleted')})
            results.append(result)
        batch=dict(batch_id=bid,batch_payload_sha256=w.canonical_digest(intents),writer_device_id=plan['writer_device_id'],
            client_build_id='synthetic-only',sync_protocol_version=3,contract_version='0.2.0',canonical_contract_sha256=c.CONTRACT_SHA,client_capabilities=sorted(w.CLIENT_CAPABILITIES))
        requests.append(dict(kind=base+'_request',project_id=f.PROJECT,project_sync_mode='ID_BASED',migration_epoch=1,batch=batch,ordered_intents=intents))
        source['Q%d.body'%(8+offset)]=dict(kind=base+'_success',status='committed',applied=True,results=results,batch_id=bid,batch_payload_sha256=batch['batch_payload_sha256'])
    source['creation-requests.json']=requests
    source['baseline-candidate.json']=dict(format='windows-isolated-receive-baseline-candidate-v1',run_id=f.RUN,
        endpoint=binding['endpoint'],account_id=f.ACCOUNT,project_id=f.PROJECT,project_sync_mode='ID_BASED',migration_epoch=1,contract_sha256=c.CONTRACT_SHA,
        plan_sha256=c.sha(c.json_bytes(plan)),candidate=dict(root=v[5][0],documents=v[4],orders=v[6]),
        baseline_ready=False,baseline_applied=False,complete=False,execution_allowed=False,atomic_snapshot=False,app_binding_created=False,
        body_bytes_verified=True,protected_rows_unchanged=True)
    target=dict(format='windows-isolated-target-link-draft-v1',binding=binding,root_id=f.ROOT,parent_id=None,
                members=[],references=[],context_only=[],authority={k:False for k in w.FLAGS})
    for kind,(table,key,aid) in w.KINDS.items():
        for i,row in enumerate(source[aid]):
            entry=dict(entity_kind=kind,entity_id=row[key],parent_id=row['parent_folder_id'],name=None if kind=='tree_order' else row['name'],
                revision=row['revision'],allowed_actions=[],source_refs=[w.ref(aid,'/'+str(i))])
            if kind=='tree_order':entry['children']=copy.deepcopy(row['children'])
            else:entry['is_deleted']=row['is_deleted']
            if kind=='document':
                meta=c.body(row['content']);entry.update(structure_revision=row['structure_revision'],body=dict(sha256=meta['sha256'],utf8_bytes=meta['byte_count'],ends_lf=meta['ends_lf']))
            target['references' if row[key]==f.TOP_ORDER else 'members'].append(entry)
    h=dict(format=w.FORMAT,intended_format='windows-isolated-receive-handoff-v1',schema_version=1,schema_finalized=False,
        blocked_reasons=['SYNTHETIC_DRAFT'],source_run_id=f.RUN,candidate_sha256='',binding=binding,
        plan_contract_sha256=c.sha(c.json_bytes(plan)),plan_artifact_ref=w.ref('plan.json'),
        target=dict({k:copy.deepcopy(x) for k,x in target.items() if k not in ('format','authority')},manifest_ref=w.ref('target.json')),
        artifacts=[],creation=[],observations=[],evidence={},missing_evidence=[],checks=[],authority={k:False for k in w.FLAGS},
        local_source_links_verified=True,raw_count_independently_verified=False,server_provenance_verified=False)
    counter=1
    for n in range(1,17):
        phase='precreate' if n<=7 else 'creation' if n<=11 else 'postcreate';table=3<=n<=7 or n>=12
        method,query,payload='GET',{},None
        if n==1:path='/auth/v1/user'
        elif n==2:method,path,payload='POST','/rest/v1/rpc/get_sync_handshake',dict(p_project_id=f.PROJECT,p_contract_sha256=c.CONTRACT_SHA)
        elif table:path='/rest/v1/'+c.TABLES[n-3 if n<=7 else n-12];query=dict(project_id='eq.'+f.PROJECT,select='*',limit='10000')
        else:method,path,payload='POST','/rest/v1/rpc/'+('document_commit' if n in (9,10) else 'atomic_structure_commit'),dict(p_request=requests[n-8])
        digest=c.sha(c.json_bytes(payload) if payload is not None else b'');rn='%03d-reserved.json'%counter;en='%03d-response.json'%(counter+1);counter+=2
        source[rn]=dict(request=n,method=method,path=path,http_reserved=n,writes_reserved=min(4,max(0,n-7)),body_sha256=digest)
        data=c.json_bytes(source['Q%d.body'%n]);source[en]=dict(request=n,status=200,sha256=c.sha(data),bytes=len(data))
        if 8<=n<=11:source['%03d-commit-confirmed.json'%counter]=dict(request=n);counter+=1
        ids=['Q%d.%s'%(n,k) for k in w.FIELDS]
        h['observations'].append(dict(request_index=n,phase=phase,method=method,path=path,query=query,request_body_sha256=digest,
            response_ref=w.ref('Q%d.body'%n),http_status=200,reservation_ref=w.ref(rn),response_event_ref=w.ref(en),evidence_ids=ids))
        for k,eid in zip(w.FIELDS,ids):
            absent=k in ('started_at','received_at') or table and k in ('content_range','reported_total')
            if absent:
                ev=dict(state='unavailable',value=None,source_ref=None,missing_evidence_id=eid)
                h['missing_evidence'].append(dict(evidence_id=eid,expected_role=k,phase=phase,request_index=n,reason='NOT_RETAINED_BY_SOURCE_ENGINE'))
            elif table:ev=dict(state='derived_from_raw',value=len(source['Q%d.body'%n]),source_ref=w.ref('Q%d.body'%n),missing_evidence_id=None)
            else:ev=dict(state='not_applicable',value=None,source_ref=None,missing_evidence_id=None)
            h['evidence'][eid]=ev
    for i,r in enumerate(requests):h['creation'].append(dict(request_index=i+8,request_ref=w.ref('creation-requests.json','/'+str(i)),
        batch_id=r['batch']['batch_id'],operation_ids=[x['operation_id'] for x in r['ordered_intents']],response_ref=w.ref('Q%d.body'%(i+8))))
    for check in sorted(c.CHECK_IDS):h['checks'].append(dict(check_id=check,expected='synthetic-only',reported=dict(run_id=f.RUN,state='pass'),
        independent=dict(verifier='untrusted-claim',state='pass',value=True),reason=None,evidence_refs=[w.ref('Q2.body')]))
    source['038-terminal.json']=dict(status='candidate-prepared',reason=None,http_reserved=16,writes_reserved=4,writes_acknowledged=4,
        baseline_ready=False,baseline_applied=False,complete=False,execution_allowed=False,write_outcome_uncertain=False,resumable=False)
    files={'source/'+n:c.json_bytes(x) for n,x in source.items()};files['target.json']=c.json_bytes(target)
    return files,h,binding


def seal(files,h,update_target=False):
    """Synthetic producer seals altered test bytes, never repairs real reader input."""
    if update_target:
        original=c.strict_json(files['target.json']);original.update({k:copy.deepcopy(x) for k,x in h['target'].items() if k!='manifest_ref'})
        files['target.json']=c.json_bytes(original)
    source={n[7:]:c.sha(x) for n,x in files.items() if n.startswith('source/') and not n.endswith(('candidate-prepared.json','terminal.json'))}
    h['candidate_sha256']=c.sha(files['source/baseline-candidate.json'])
    files['source/037-candidate-prepared.json']=c.json_bytes(dict(files=source,sha256=h['candidate_sha256']))
    h['artifacts']=[dict(artifact_id=n[7:] if n.startswith('source/') else n,role='retained-source' if n.startswith('source/') else 'target-draft',
        path=n,sha256=c.sha(x),byte_count=len(x)) for n,x in sorted(files.items()) if n not in ('handoff.json','completed.json')]
    files['handoff.json']=c.json_bytes(h)
    files['completed.json']=c.json_bytes(dict(format='windows-handoff-local-seal-v1',handoff_sha256=c.sha(files['handoff.json']),
        target_sha256=c.sha(files['target.json']),source_run_id=h['source_run_id'],execution_allowed=False,
        source_files={n[7:]:c.sha(x) for n,x in files.items() if n.startswith('source/')}))
    return files
