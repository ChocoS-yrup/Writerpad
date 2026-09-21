"""Read-only Windows draft -> Expected comparison input. No transport/store/app imports.

Retained data is never an A/B pass or an applicable baseline. Original JSON bytes and
pointers remain authoritative for references; normalized rows are private memory only.
"""
import argparse
import copy
from dataclasses import dataclass
import json
from pathlib import Path
import re
import stat
import unicodedata
import zipfile

import receive_contract_offline as c

FORMAT = 'windows-isolated-receive-handoff-draft-v1'
FLAGS = ('baseline_ready', 'baseline_applied', 'execution_allowed', 'app_binding_created',
         'complete', 'atomic_snapshot', 'editing_allowed', 'sending_allowed', 'automatic_receive_allowed')
KINDS = {'document': ('documents', 'document_id', 'Q14.body'),
         'folder': ('folders', 'folder_id', 'Q15.body'),
         'tree_order': ('tree_orders', 'tree_order_id', 'Q16.body')}
FIELDS = ('started_at', 'received_at', 'content_range', 'reported_total', 'row_count')
# Request-side capabilities differ from handshake SERVER capabilities.
CLIENT_CAPABILITIES = frozenset(('folders_authoritative','tree_order_ids','tombstones',
    'immutable_batch_contract_metadata','operation_attempt_history','operation_state_events',
    'storage_name_v1','document_commit_v1'))


def ref(aid, ptr=''):
    return dict(artifact_id=aid, json_pointer=ptr)


def false_authority(value):
    c.keys(value, FLAGS)
    c.need(all(v is False for v in value.values()), 'AUTHORITY')


def canonical_digest(value):
    # Windows sync_contract canonical JSON has no LF. Artifact encoding has one LF.
    def walk(v):
        if isinstance(v, str): c.text(v)
        elif type(v) is int: c.integer(v, -c.MAX_INT)
        elif v is None or type(v) is bool: pass
        elif type(v) is list:
            for x in v: walk(x)
        elif type(v) is dict:
            for k, x in v.items():
                c.need(type(k) is str and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', k), 'CANONICAL_KEY')
                walk(x)
        else: raise c.ContractError('CANONICAL_TYPE')
    walk(value)
    return c.sha(c.json_bytes(value)[:-1])


@c.closed_shape
def read_zip(filename):
    """Read bounded regular entries in memory; never extract or execute local-sources."""
    c.need(Path(filename).is_file() and not Path(filename).is_symlink(), 'ZIP_FILE')
    c.need(Path(filename).stat().st_size <= 64 * 1024 * 1024, 'ZIP_SIZE')
    try:
        with zipfile.ZipFile(filename) as archive:
            entries = archive.infolist()
            c.need(len(entries) <= 256 and sum(i.file_size for i in entries) <= 32 * 1024 * 1024, 'ZIP_SIZE')
            names = set(); aliases = set()
            for info in entries:
                name = info.filename.rstrip('/') if info.is_dir() else info.filename
                c.path(name)
                alias = unicodedata.normalize('NFC',name).casefold()
                c.need(alias not in aliases, 'ZIP_ALIAS'); aliases.add(alias)
                c.need(info.filename not in names, 'ZIP_DUPLICATE'); names.add(info.filename)
                mode = (info.external_attr >> 16) & 0xffff
                c.need(not mode or stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR), 'ZIP_LINK')
                c.need(not info.flag_bits & 1 and info.file_size <= 4 * 1024 * 1024, 'ZIP_ENTRY')
            candidates = [n for n in names if n.endswith('/handoff.json')]
            c.need(len(candidates) == 1, 'ZIP_ENVELOPE')
            prefix = candidates[0][:-len('handoff.json')]
            return {i.filename[len(prefix):]: archive.read(i) for i in entries
                    if i.filename.startswith(prefix) and not i.is_dir()}
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError):
        raise c.ContractError('ZIP_READ') from None


@dataclass(frozen=True)
class DraftMapping:
    """Private mapped rows for a future comparison, never storage admission authority."""
    report: dict
    _expected: c.Expected

    def comparison_expected(self):
        return copy.deepcopy(self._expected)

    def require_apply_input(self):
        raise c.ContractError('REAL_CONTRACT_UNRESOLVED')


@c.closed_shape
def map_draft(files, expected_handoff_sha256, expected_binding):
    c.need(type(files) is dict and len(files) <= 128 and all(type(v) is bytes for v in files.values())
           and sum(map(len, files.values())) <= 32 * 1024 * 1024, 'BUNDLE_SIZE')
    for p in files: c.path(p)
    c.need(c.sha(files['handoff.json']) == c.hash_value(expected_handoff_sha256), 'HANDOFF_PIN')
    h = c.strict_json(files['handoff.json'])
    c.keys(h, ('format','intended_format','schema_version','schema_finalized','blocked_reasons',
        'source_run_id','candidate_sha256','binding','plan_contract_sha256','plan_artifact_ref',
        'target','artifacts','creation','observations','evidence','missing_evidence','checks',
        'authority','local_source_links_verified','raw_count_independently_verified','server_provenance_verified'))
    c.need(h['format'] == FORMAT and h['intended_format'] == 'windows-isolated-receive-handoff-v1'
           and c.integer(h['schema_version'],1) == 1 and h['schema_finalized'] is False, 'FORMAT')
    false_authority(h['authority'])
    c.need(type(h['blocked_reasons']) is list and all(type(x) is str for x in h['blocked_reasons']), 'BLOCKERS')
    b = h['binding']; c.keys(b, ('endpoint','account_id','project_id','project_sync_mode','migration_epoch','contract_version','contract_sha256'))
    c.need(c.json_bytes(b) == c.json_bytes(expected_binding), 'EXTERNAL_BINDING')
    c.identifier(b['account_id']); c.identifier(b['project_id']); c.identifier(h['source_run_id'])
    c.need(b['project_sync_mode'] == 'ID_BASED' and c.integer(b['migration_epoch'],1) == 1
        and b['contract_version'] == '0.2.0' and b['contract_sha256'] == c.CONTRACT_SHA, 'BINDING_CONTRACT')
    artifacts, values = {}, {}
    for a in h['artifacts']:
        c.keys(a, ('artifact_id','role','path','sha256','byte_count'))
        aid = c.path(a['artifact_id']); c.need('/' not in aid and aid not in artifacts, 'ARTIFACT_ID')
        wanted_path = 'target.json' if aid == 'target.json' else 'source/' + aid
        c.need(a['path'] == wanted_path and a['role'] == ('target-draft' if aid == 'target.json' else 'retained-source'), 'ARTIFACT_ROLE_PATH')
        raw = files[wanted_path]
        c.need(c.sha(raw) == c.hash_value(a['sha256']) and len(raw) == c.integer(a['byte_count']), 'ARTIFACT_HASH')
        artifacts[aid] = a; values[aid] = c.strict_json(raw)
    c.need(set(files) == {'handoff.json','completed.json'} | {a['path'] for a in artifacts.values()}, 'EXTRA_FILE')
    def resolve(r):
        c.keys(r, ('artifact_id','json_pointer'))
        c.need(r['artifact_id'] in values, 'ARTIFACT_REF')
        return c.pointer(values[r['artifact_id']], r['json_pointer'])
    def raw(aid): return files[artifacts[aid]['path']]
    done = c.strict_json(files['completed.json'])
    c.keys(done, ('format','handoff_sha256','target_sha256','source_run_id','source_files','execution_allowed'))
    c.need(done['format'] == 'windows-handoff-local-seal-v1' and done['execution_allowed'] is False
        and done['handoff_sha256'] == expected_handoff_sha256 and done['target_sha256'] == c.sha(raw('target.json'))
        and done['source_run_id'] == h['source_run_id'], 'LOCAL_SEAL')
    source_hashes = {aid:c.sha(raw(aid)) for aid in artifacts if aid != 'target.json'}
    c.need(done['source_files'] == source_hashes, 'SOURCE_SEAL')
    seals = [aid for aid in artifacts if aid.endswith('-candidate-prepared.json')]
    terminals = [aid for aid in artifacts if aid.endswith('-terminal.json')]
    c.need(len(seals) == len(terminals) == 1, 'SOURCE_TERMINAL')
    seal, terminal = values[seals[0]], values[terminals[0]]
    c.need(seal['files'] == {aid:s for aid,s in source_hashes.items() if aid not in seals+terminals}
        and seal['sha256'] == h['candidate_sha256'] == c.sha(raw('baseline-candidate.json')), 'CANDIDATE_SEAL')
    for key in ('baseline_ready','baseline_applied','complete','execution_allowed','write_outcome_uncertain','resumable'):
        c.need(terminal[key] is False, 'TERMINAL_AUTHORITY')
    c.need(terminal['status'] == 'candidate-prepared' and terminal['reason'] is None
        and c.integer(terminal['http_reserved']) == 16 and c.integer(terminal['writes_reserved']) == 4
        and c.integer(terminal['writes_acknowledged']) == 4, 'SOURCE_TERMINAL')
    plan, candidate, scope = values['plan.json'], values['baseline-candidate.json'], values['scope.json']
    c.need(h['plan_artifact_ref'] == ref('plan.json') and resolve(h['plan_artifact_ref']) == plan, 'PLAN_REF')
    c.need(h['plan_contract_sha256'] == candidate['plan_sha256'] == scope['plan_sha256'] == c.sha(c.json_bytes(plan)), 'PLAN_HASH')
    c.need(candidate['format'] == 'windows-isolated-receive-baseline-candidate-v1'
        and scope['format'] == 'windows-isolated-target-bootstrap-v1'
        and candidate['run_id'] == scope['run_id'] == h['source_run_id'], 'CANDIDATE_SCOPE')
    for k in ('endpoint','account_id','project_id'):
        c.need(candidate[k] == plan[k] == b[k], 'PLAN_BINDING')
    for k in ('project_sync_mode','migration_epoch','contract_sha256'):
        c.need(type(candidate[k]) is type(b[k]) and candidate[k] == b[k], 'CANDIDATE_BINDING')
    c.need(plan['format'] == 'windows-isolated-target-bootstrap-v1', 'PLAN_FORMAT')
    for k in ('baseline_ready','baseline_applied','complete','execution_allowed','atomic_snapshot','app_binding_created'):
        c.need(candidate[k] is False, 'CANDIDATE_AUTHORITY')
    c.need(plan['execution_allowed'] is False and plan['baseline_applied'] is False and plan['initial_revisions'] is None, 'PLAN_AUTHORITY')
    c.need(c.integer(scope['max_requests']) == 16 and c.integer(scope['max_writes']) == 4
        and c.integer(scope['max_seconds']) == 180
        and c.integer(scope['expires_at']) - c.integer(scope['not_before']) == 180, 'SOURCE_SCOPE')
    for name in ('metadata','orders'):
        c.need(plan['reference_sha256'][name] == c.sha(raw('reference-'+name+'.json')), 'PLAN_REFERENCE_HASH')

    target = h['target']; original = values['target.json']
    c.keys(target, ('manifest_ref','binding','root_id','parent_id','members','references','context_only'))
    c.keys(original, ('format','binding','root_id','parent_id','members','references','context_only','authority'))
    false_authority(original['authority'])
    c.need(original['format'] == 'windows-isolated-target-link-draft-v1'
        and target['manifest_ref'] == ref('target.json') and target['binding'] == b
        and {k:v for k,v in original.items() if k not in ('format','authority')} ==
            {k:v for k,v in target.items() if k != 'manifest_ref'}, 'TARGET_MANIFEST')
    c.need(target['root_id'] == plan['root_id'] and target['parent_id'] == plan['parent_id'], 'TARGET_PLAN')
    tables = dict(zip(c.TABLES, (values['Q%d.body'%n] for n in range(12,17))))
    for table, rows in tables.items():
        c.need(type(rows) is list and len(rows) <= 10000, 'TABLE')
        for value in rows: c.row(table,value,b['project_id'])
    hs = values['Q2.body']
    if type(hs) is list:
        c.need(len(hs) == 1, 'HANDSHAKE_SINGLETON'); hs = hs[0]
    c.handshake(hs, b['project_id'])
    c.need(values['Q1.body']['id'] == b['account_id'], 'SUBJECT')
    for pn, sn in ((3,4),(12,13)):
        p,s = values['Q%d.body'%pn], values['Q%d.body'%sn]
        c.need(type(p) is list and type(s) is list and len(p) == len(s) == 1, 'SINGLETON')
        c.need(p[0]['project_id'] == s[0]['project_id'] == b['project_id']
            and p[0]['owner_id'] == b['account_id']
            and s[0]['project_sync_mode'] == b['project_sync_mode']
            and c.integer(s[0]['migration_epoch'],1) == 1, 'PROJECT_SETTINGS')
        c.validate_project_row(p[0], c.Expected(b['account_id'],b['project_id'],{},'trashed_at'))
    mapped = {'members':{}, 'references':{}, 'context_only':{}}; seen = set(); trace = []
    for role in mapped:
        c.need(type(target[role]) is list, 'TARGET_ROLE')
        for entry in target[role]:
            kind = entry['entity_kind']; c.need(kind in KINDS, 'ENTITY_KIND')
            table,key,aid = KINDS[kind]; ident = c.identifier(entry['entity_id'])
            c.need(ident not in seen, 'TARGET_DUPLICATE'); seen.add(ident)
            refs = entry['source_refs']; c.need(type(refs) is list and len(refs) == 1, 'TARGET_SOURCE')
            r = refs[0]; c.need(r['artifact_id'] == aid and re.fullmatch(r'/[0-9]+',r['json_pointer']), 'TARGET_SOURCE')
            value = resolve(r); c.need(value[key] == ident, 'TARGET_SOURCE_ID')
            special = kind == 'document' and value['relative_path'].startswith('__antigravity__/')
            if special:
                c.keys(entry, ('entity_kind','entity_id','classification','source_refs'))
                c.need(role == 'context_only' and entry['classification'] == 'special-metadata', 'SPECIAL_ROLE')
            else:
                extra = ('children',) if kind == 'tree_order' else ('is_deleted',)
                if kind == 'document': extra += ('structure_revision','body')
                c.keys(entry, ('entity_kind','entity_id','parent_id','name','revision','allowed_actions','source_refs') + extra)
                c.need(entry['allowed_actions'] == [], 'TARGET_AUTHORITY')
                for dest, source in (('parent_id','parent_folder_id'),('revision','revision')):
                    c.need(type(entry[dest]) is type(value[source]) and entry[dest] == value[source], 'TARGET_VALUE')
                c.need(entry['name'] == (None if kind == 'tree_order' else value['name']), 'TARGET_VALUE')
                if kind == 'tree_order': c.need(entry['children'] == value['children'], 'TARGET_ORDER')
                else: c.need(entry['is_deleted'] is value['is_deleted'], 'TARGET_DELETE')
                if kind == 'document':
                    c.need(c.integer(entry['structure_revision'],1) == value['structure_revision'], 'TARGET_STRUCTURE_REVISION')
                    m = c.body(value['content'])
                    body_metadata(entry['body'])
                    c.need(entry['body'] == dict(sha256=m['sha256'],utf8_bytes=m['byte_count'],ends_lf=m['ends_lf']), 'TARGET_BODY')
            mapped[role].setdefault(table,[]).append(copy.deepcopy(value))
            trace.append(dict(role=role,entity_kind=kind,source_ref=copy.deepcopy(r)))
    all_ids = [r[key] for table,key,_ in KINDS.values() for r in tables[table]]
    c.need(len(set(all_ids)) == len(all_ids) and seen == set(all_ids), 'TARGET_COVERAGE')
    expected = c.Expected(b['account_id'],b['project_id'],dict(root_id=target['root_id'],
        members=mapped['members'],reference_rows=mapped['references'],
        reference_ids=[e['entity_id'] for e in target['references']]), project_state_field='trashed_at')
    graph = c.validate_table_graph(tables,expected)
    # Derive ancestor/order/child references independently; context cannot hide a required row.
    folder_map = {r['folder_id']:r for r in tables['folders']}
    ancestors = set(); parent = plan['parent_id']
    while parent is not None:
        c.need(parent in folder_map and parent not in ancestors, 'REFERENCE_PARENT')
        ancestors.add(parent); parent = folder_map[parent]['parent_folder_id']
    required_refs = set(ancestors)
    for order in tables['tree_orders']:
        if order['parent_folder_id'] in ancestors | {None}:
            required_refs.add(order['tree_order_id']); required_refs.update(order['children'])
    required_refs -= {e['entity_id'] for e in target['members']}
    c.need({e['entity_id'] for e in target['references']} == required_refs, 'REFERENCE_ROLE_SCOPE')
    root = next(r for r in tables['folders'] if r['folder_id'] == plan['root_id'])
    docs = {r['document_id']:r for r in tables['documents']}
    orders = {r['tree_order_id']:r for r in tables['tree_orders']}
    c.need(candidate['candidate'] == dict(root=root,documents=[docs[plan['body_id']],docs[plan['empty_id']]],
        orders=[orders[plan['parent_order_id']],orders[plan['root_order_id']]]), 'CANDIDATE_ROWS')
    c.need({e['entity_id'] for e in target['members']} ==
        {plan['root_id'],plan['body_id'],plan['empty_id'],plan['root_order_id']}, 'MEMBER_PLAN')
    for ident,name,meta in ((plan['body_id'],plan['body_name'],plan['initial_body']),
                            (plan['empty_id'],plan['empty_name'],dict(sha256=c.sha(b''),utf8_bytes=0,ends_lf=False))):
        d = docs[ident]; m = c.body(d['content']); body_metadata(meta)
        c.need(d['name'] == name and d['parent_folder_id'] == plan['root_id']
            and d['relative_path'] == plan['root_path']+'/'+name
            and meta == dict(sha256=m['sha256'],utf8_bytes=m['byte_count'],ends_lf=m['ends_lf']), 'PLAN_BODY')
    c.need(root['parent_folder_id'] == plan['parent_id'] and orders[plan['root_order_id']]['children'] == [plan['body_id'],plan['empty_id']], 'PLAN_STRUCTURE')
    verify_creation(h, values, b, plan, tables, resolve)
    counts, missing = verify_observations(h, values, raw, resolve, b)
    c.need(type(h['checks']) is list and {x['check_id'] for x in h['checks']} == c.CHECK_IDS and len(h['checks']) == 8, 'CHECKS')
    for check in h['checks']:
        c.keys(check, ('check_id','expected','reported','independent','evidence_refs','reason'))
        c.need(check['reported']['run_id'] == h['source_run_id'], 'CHECK_RUN')
        for r in check['evidence_refs']: resolve(r)
        # Both reported and incoming independent states remain untrusted producer claims.
    report = dict(format='ipad-windows-draft-mapping-review-v1',handoff_sha256=expected_handoff_sha256,
        source_run_id=h['source_run_id'],mapping_connected=True,source_files_verified=len(source_hashes),
        target_counts={r:len(target[r]) for r in mapped},raw_array_counts=counts,
        missing_evidence_count=len(missing),missing_evidence_ids=sorted(missing),
        normal_bodies_independently_checked=len(graph['normal_body_hashes']),
        special_body_semantics_verified=False,handshake_retained_contract_checked=True,
        creation_request_receipt_readback_links_checked=True,full_windows_engine_equivalence_verified=False,
        mapped_expected_validated=True,project_state_field='trashed_at',reference_trace=trace,
        raw_arrays_counted=True,http_total_verified=False,request_times_verified=False,
        fresh_ab_passes_verified=False,server_provenance_verified=False,
        schema_finalized=False,producer_blocked_reasons=copy.deepcopy(h['blocked_reasons']),
        source_scope_is_current_approval=False,ios_reader_binding_created=False,
        authority={k:False for k in FLAGS})
    return DraftMapping(report,copy.deepcopy(expected))


def body_metadata(value):
    c.keys(value, ('sha256','utf8_bytes','ends_lf'))
    c.hash_value(value['sha256']); c.integer(value['utf8_bytes'])
    c.need(type(value['ends_lf']) is bool, 'BODY_ENDS_LF')


def verify_creation(h, values, b, plan, tables, resolve):
    requests = values['creation-requests.json']; c.need(type(requests) is list and len(requests) == 4 and len(h['creation']) == 4, 'CREATION_COUNT')
    batches,operations = set(),set()
    rows = {r[key]:r for table,key,_ in KINDS.values() for r in tables[table]}
    for offset, (link, request) in enumerate(zip(h['creation'], requests)):
        n = offset+8; c.keys(link, ('request_index','request_ref','batch_id','operation_ids','response_ref'))
        c.need(c.integer(link['request_index']) == n and link['request_ref'] == ref('creation-requests.json','/'+str(offset))
            and link['response_ref'] == ref('Q%d.body'%n), 'CREATION_REF')
        response = resolve(link['response_ref']); intents = request['ordered_intents']; batch = request['batch']
        bid = c.identifier(batch['batch_id']); c.need(bid not in batches, 'BATCH_DUPLICATE'); batches.add(bid)
        c.need(link['batch_id'] == response['batch_id'] == bid
            and batch['batch_payload_sha256'] == response['batch_payload_sha256'] == canonical_digest(intents), 'BATCH_HASH')
        c.need(request['project_id'] == b['project_id'] and request['project_sync_mode'] == b['project_sync_mode']
            and c.integer(request['migration_epoch'],1) == b['migration_epoch']
            and batch['canonical_contract_sha256'] == b['contract_sha256']
            and batch['contract_version'] == b['contract_version'] and c.integer(batch['sync_protocol_version']) == 3
            and batch['writer_device_id'] == plan['writer_device_id'], 'CREATION_BINDING')
        caps = batch['client_capabilities']
        c.need(type(caps) is list and all(type(x) is str for x in caps) and len(set(caps)) == len(caps)
            and CLIENT_CAPABILITIES <= set(caps), 'CREATION_CAPABILITIES')
        document = offset in (1,2); base = 'document_commit' if document else 'atomic_structure_commit'
        c.need(request['kind'] == base+'_request' and response['kind'] == base+'_success'
            and response['status'] in ('committed','replayed') and response['applied'] is True, 'CREATION_STATUS')
        c.keys(response, ('kind','status','applied','batch_id','batch_payload_sha256','results'))
        c.need(len(intents) == (2 if offset == 3 else 1) and len(response['results']) == len(intents)
            and link['operation_ids'] == [i['operation_id'] for i in intents], 'CREATION_RESULTS')
        for seq,(intent,result) in enumerate(zip(intents,response['results']),1):
            op = c.identifier(intent['operation_id']); c.need(op not in operations, 'OPERATION_DUPLICATE'); operations.add(op)
            c.need(c.integer(intent['sequence'],1) == c.integer(result['sequence'],1) == seq
                and intent['batch_id'] == bid and result['operation_id'] == op
                and intent['payload_sha256'] == canonical_digest(intent['payload']), 'INTENT_LINK')
            c.integer(intent['base_revision']); c.integer(result['result_revision'],1)
            key = 'document_id' if document else 'entity_id'; ident = c.identifier(intent[key])
            c.need(result[key] == ident and ident in rows and result['result_revision'] == rows[ident]['revision'], 'RECEIPT_ROW')
            planned_ids = ((plan['root_id'],),(plan['body_id'],),(plan['empty_id'],),(plan['parent_order_id'],plan['root_order_id']))
            wanted_kind = 'folder' if offset == 0 else 'document' if document else 'tree_order'
            c.need(ident == planned_ids[offset][seq-1] and intent['entity_kind'] == wanted_kind
                and intent['intent_kind'] == ('reorder' if offset == 3 else 'create'), 'INTENT_PLAN')
            base_revision = 0
            if offset == 3 and seq == 1:
                old = [r for r in values['Q7.body'] if r['tree_order_id'] == plan['parent_order_id']]
                c.need(len(old) == 1, 'PARENT_ORDER_BEFORE'); base_revision = c.integer(old[0]['revision'],1)
            c.need(intent['base_revision'] == base_revision, 'INTENT_BASE_REVISION')
            payload,actual = intent['payload'], rows[ident]
            c.keys(payload, ('name','parent_folder_id') if offset == 0 else
                ('content','content_sha256','content_byte_count','is_deleted','name','parent_folder_id','structure_revision') if document else
                ('children','parent_folder_id'))
            for k,v in payload.items():
                if k not in ('content_sha256','content_byte_count'):
                    c.need(k in actual and type(v) is type(actual[k]) and v == actual[k], 'PAYLOAD_READBACK')
            if document:
                c.keys(result, ('sequence','operation_id','document_id','result_revision','structure_revision','parent_folder_id','name','content_sha256','content_byte_count','is_deleted'))
                meta = c.body(actual['content'])
                c.need(payload['content_sha256'] == meta['sha256'] and c.integer(payload['content_byte_count']) == meta['byte_count'], 'PAYLOAD_BODY')
                for k in ('structure_revision','parent_folder_id','name','content_sha256','content_byte_count','is_deleted'):
                    c.need(type(result[k]) is type(payload[k]) and result[k] == payload[k], 'DOCUMENT_RECEIPT')
            else: c.keys(result, ('sequence','operation_id','entity_id','result_revision'))
    # Retained before/after relation, not a claim that the server is unchanged now.
    additions = {'documents':{plan['body_id'],plan['empty_id']},'folders':{plan['root_id']},'tree_orders':{plan['root_order_id']}}
    for n,table in enumerate(c.TABLES,3):
        before,after = values['Q%d.body'%n],tables[table]
        if table not in additions:
            c.need(c.json_bytes(before) == c.json_bytes(after), 'PROTECTED_SETTINGS'); continue
        key = next(k for t,k,_ in KINDS.values() if t == table)
        old,new = {r[key]:r for r in before},{r[key]:r for r in after}
        c.need(len(old) == len(before) and not set(old) & additions[table] and set(new) == set(old)|additions[table], 'CREATION_SCOPE')
        for ident,r in old.items():
            wanted = copy.deepcopy(r)
            if table == 'tree_orders' and ident == plan['parent_order_id']:
                wanted.update(children=r['children']+[plan['root_id']],revision=new[ident]['revision'],updated_at=new[ident]['updated_at'])
            c.need(c.json_bytes(wanted) == c.json_bytes(new[ident]), 'PROTECTED_ROW')


def verify_observations(h, values, raw, resolve, b):
    c.need(type(h['observations']) is list and len(h['observations']) == 16, 'OBSERVATION_COUNT')
    c.need(type(h['evidence']) is dict and len(h['evidence']) == 80, 'EVIDENCE_COUNT')
    missing = {}; used = set(); counts = {}; expected_missing = set()
    for m in h['missing_evidence']:
        c.keys(m, ('evidence_id','expected_role','phase','request_index','reason'))
        c.need(m['evidence_id'] not in missing, 'MISSING_DUPLICATE'); missing[m['evidence_id']] = m
    for n,o in enumerate(h['observations'],1):
        c.keys(o, ('request_index','phase','method','path','query','request_body_sha256','response_ref','http_status','reservation_ref','response_event_ref','evidence_ids'))
        phase = 'precreate' if n <= 7 else 'creation' if n <= 11 else 'postcreate'
        c.need(c.integer(o['request_index']) == n and o['phase'] == phase and o['response_ref'] == ref('Q%d.body'%n), 'OBSERVATION_REF')
        table = 3 <= n <= 7 or n >= 12
        method,query,payload = 'GET',{},None
        if n == 1: path = '/auth/v1/user'
        elif n == 2:
            method,path,payload = 'POST','/rest/v1/rpc/get_sync_handshake',dict(p_project_id=b['project_id'],p_contract_sha256=b['contract_sha256'])
        elif table:
            path = '/rest/v1/'+c.TABLES[n-3 if n<=7 else n-12]
            query = dict(project_id='eq.'+b['project_id'],select='*',limit='10000')
        else:
            method,path = 'POST','/rest/v1/rpc/'+('document_commit' if n in (9,10) else 'atomic_structure_commit')
            payload = dict(p_request=values['creation-requests.json'][n-8])
        digest = c.sha(c.json_bytes(payload) if payload is not None else b'')
        c.need(o['method'] == method and o['path'] == path and o['query'] == query and o['request_body_sha256'] == digest, 'REQUEST_CONTRACT')
        reserve,resp = resolve(o['reservation_ref']),resolve(o['response_event_ref'])
        c.need(o['reservation_ref']['json_pointer'] == o['response_event_ref']['json_pointer'] == ''
            and o['reservation_ref']['artifact_id'].endswith('-reserved.json')
            and o['response_event_ref']['artifact_id'].endswith('-response.json'), 'EVENT_REF')
        for k in ('request','http_reserved','writes_reserved'): c.integer(reserve[k])
        c.need(reserve == dict(request=n,method=method,path=path,http_reserved=n,writes_reserved=min(4,max(0,n-7)),body_sha256=digest), 'RESERVATION')
        data = raw('Q%d.body'%n)
        c.need(c.integer(resp['request']) == n and c.integer(resp['status']) == c.integer(o['http_status'])
            and resp['status'] in ((200,206) if table else (200,))
            and resp['sha256'] == c.sha(data) and c.integer(resp['bytes']) == len(data), 'RESPONSE_EVENT')
        if table:
            value = resolve(o['response_ref']); c.need(type(value) is list and len(value) <= 10000, 'RAW_COUNT')
            counts['Q%d'%n] = len(value)
        ids = ['Q%d.%s'%(n,f) for f in FIELDS]; c.need(o['evidence_ids'] == ids, 'EVIDENCE_IDS')
        for f,eid in zip(FIELDS,ids):
            e = h['evidence'][eid]; used.add(eid)
            c.keys(e, ('state','value','source_ref','missing_evidence_id'))
            absent = f in ('started_at','received_at') or table and f in ('content_range','reported_total')
            if absent:
                c.need(e == dict(state='unavailable',value=None,source_ref=None,missing_evidence_id=eid), 'MISSING_EVIDENCE_STATE')
                expected_missing.add(eid)
                c.need(missing[eid] == dict(evidence_id=eid,expected_role=f,phase=phase,request_index=n,reason='NOT_RETAINED_BY_SOURCE_ENGINE'), 'MISSING_LINK')
            elif table:
                c.need(e['state'] == 'derived_from_raw' and c.integer(e['value']) == counts['Q%d'%n]
                    and e['source_ref'] == o['response_ref'] and e['missing_evidence_id'] is None, 'RAW_COUNT')
            else: c.need(e == dict(state='not_applicable',value=None,source_ref=None,missing_evidence_id=None), 'EVIDENCE_APPLICABILITY')
    c.need(set(h['evidence']) == used and set(missing) == expected_missing, 'EVIDENCE_COVERAGE')
    return counts,missing


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip_path'); parser.add_argument('--handoff-sha256',required=True)
    parser.add_argument('--binding-file',required=True,help='Explicit expected binding, not inferred from incoming ZIP')
    args = parser.parse_args()
    try:
        result = map_draft(read_zip(args.zip_path),args.handoff_sha256,c.strict_json(Path(args.binding_file).read_bytes()))
        print(json.dumps(result.report,ensure_ascii=False,indent=2))
    except c.ContractError as e:
        print(json.dumps(dict(status='blocked',code=e.code))); return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())
