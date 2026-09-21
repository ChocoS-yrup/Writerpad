"""Offline contract/AB simulator. No network, credentials, app store or baseline apply.

Wire semantics draft: strict JSON and U1/U2 reviews. AB uses only SyntheticExchange,
FakeClock and a reservation journal double. Not an iOS transport implementation.
"""
from dataclasses import dataclass
from functools import wraps
from datetime import datetime
import copy
import hashlib
import json
import re
import unicodedata
from uuid import UUID

MAX_INT = 2**53 - 1
CONTRACT_SHA = '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
CAPABILITIES = frozenset(('atomic_structure_commit', 'contract_allowlist_validation',
    'project_mode_migration_lock', 'folder_tombstones', 'id_tree_validation',
    'legacy_epoch_zero_adapter', 'storage_name_v1', 'document_commit_v1'))
TABLES = ('projects', 'project_sync_settings', 'documents', 'folders', 'tree_orders')
CHECK_IDS = frozenset(('identity_project','handshake_contract','settings_coherence',
    'target_binding','body_versions','visible_completeness','creation_link','preapply_consistency'))
ROLES = frozenset(('target_manifest','creation_requests','creation_response','raw_json',
    'raw_bytes','header_json','header_bytes','local_measurement','plan','scope'))


class ContractError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)  # Never include raw content, credentials or server errors.


def closed_shape(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError, RecursionError):
            raise ContractError('SHAPE') from None
    return wrapped


def need(condition, code):
    if not condition:
        raise ContractError(code)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def integer(value, minimum=0, maximum=MAX_INT):
    need(type(value) is int and minimum <= value <= maximum, 'INTEGER')
    return value


def text(value):
    need(type(value) is str, 'STRING')
    try:
        value.encode('utf-8', errors='strict')
    except UnicodeError:
        raise ContractError('UNICODE') from None
    return value


def identifier(value):
    value = text(value)
    try:
        need(str(UUID(value)) == value, 'UUID')
    except ValueError:
        raise ContractError('UUID') from None
    return value


def hash_value(value):
    need(type(value) is str and re.fullmatch('[0-9a-f]{64}', value), 'SHA')
    return value


def keys(value, required, optional=()):
    need(type(value) is dict and set(required) <= set(value) <= set(required) | set(optional), 'KEYS')


def required(value, names):
    need(type(value) is dict and set(names) <= set(value), 'MISSING_FIELD')


def json_bytes(value):
    # Internal deterministic comparison encoding, NOT a replacement for original raw SHA.
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')


def strict_json(data, limit=4 * 1024 * 1024):
    need(type(data) is bytes and len(data) <= limit, 'RESPONSE_SIZE')
    def pairs(items):
        result = {}
        for k, v in items:
            need(k not in result, 'DUPLICATE_KEY')
            result[k] = v
        return result
    def reject(_):
        raise ContractError('NONFINITE')
    try:
        result = json.loads(data.decode('utf-8', errors='strict'), object_pairs_hook=pairs, parse_constant=reject)
    except (ValueError, UnicodeError, RecursionError):
        raise ContractError('JSON') from None
    def walk(value, depth=0):
        need(depth <= 64, 'DEPTH')
        if isinstance(value, str): text(value)
        elif type(value) is dict:
            for k, v in value.items(): text(k); walk(v, depth + 1)
        elif type(value) is list:
            for v in value: walk(v, depth + 1)
        elif type(value) is float:
            need(abs(value) != float('inf'), 'NONFINITE')
    walk(result)
    return result


DATE = re.compile(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})', re.ASCII)


def date(value):
    value = text(value)
    match = DATE.fullmatch(value)
    need(match is not None, 'DATE')
    y, mo, d, h, mi, s = map(int, match.groups()[:6])
    try:
        datetime(y, mo, d, h, mi, s)
    except ValueError:
        raise ContractError('DATE') from None
    zone = match.group(8)
    if zone != 'Z':
        hour, minute = int(zone[1:3]), int(zone[4:6])
        need(hour <= 14 and minute <= 59 and (hour != 14 or minute == 0), 'DATE_OFFSET')
    return value  # Original lexical representation is preserved for A/B comparison.


def body(value):
    value = text(value)
    need('\r' not in value and '\0' not in value, 'BODY_CHARACTER')
    raw = value.encode('utf-8')
    return {'sha256': sha(raw), 'byte_count': len(raw), 'ends_lf': raw.endswith(b'\n')}


def path(value):
    value = text(value)
    parts = value.split('/')
    need(value and all(p and p not in ('.', '..') for p in parts), 'PATH')
    need('\\' not in value and ':' not in value and not any(ord(c) < 32 or ord(c) == 127 for c in value), 'PATH')
    return value


def pointer(value, pointer_string):
    need(type(pointer_string) is str and (pointer_string == '' or pointer_string.startswith('/')), 'POINTER')
    if pointer_string == '': return value
    for encoded in pointer_string[1:].split('/'):
        need(re.search(r'~(?![01])', encoded) is None, 'POINTER_ESCAPE')
        token = encoded.replace('~1', '/').replace('~0', '~')
        if type(value) is dict:
            need(token in value, 'POINTER_MISSING'); value = value[token]
        elif type(value) is list:
            need(re.fullmatch(r'0|[1-9][0-9]*', token) is not None, 'POINTER_INDEX')
            index = int(token); need(index < len(value), 'POINTER_MISSING'); value = value[index]
        else: raise ContractError('POINTER_TYPE')
    return value


def handshake(value, project):
    required(value, ('supported', 'project_id', 'project_sync_mode', 'migration_epoch', 'contract_version',
        'canonical_contract_sha256', 'server_contract_sha256', 'server_protocol_version',
        'supported_protocol_versions', 'server_capabilities'))
    need(value['supported'] is True and identifier(value['project_id']) == project, 'HANDSHAKE_PROJECT')
    need(value['project_sync_mode'] == 'ID_BASED' and integer(value['migration_epoch'], 1) == 1, 'EPOCH')
    need(value['contract_version'] == '0.2.0' and value['canonical_contract_sha256'] == value['server_contract_sha256'] == CONTRACT_SHA, 'CONTRACT')
    server = integer(value['server_protocol_version'], 3)
    versions = value['supported_protocol_versions']
    need(type(versions) is list, 'PROTOCOL'); [integer(v, 1) for v in versions]
    need(len(set(versions)) == len(versions) and 3 in versions and server in versions, 'PROTOCOL')
    caps = value['server_capabilities']; need(type(caps) is list, 'CAPABILITY')
    [text(v) for v in caps]
    need(len(set(caps)) == len(caps) and CAPABILITIES <= set(caps), 'CAPABILITY')


def row(table, value, project):
    ids = {'documents': 'document_id', 'folders': 'folder_id', 'tree_orders': 'tree_order_id'}
    required(value, ('project_id',))
    need(identifier(value['project_id']) == project, 'PROJECT')
    if table in ('projects', 'project_sync_settings'): return
    if table == 'documents':
        required(value, ('document_id','relative_path'))
        identifier(value['document_id']); path(value['relative_path'])
        if value['relative_path'].startswith('__antigravity__/'):
            return  # Retain raw fields; no ordinary body/date/structure claim for this role.
    required(value, (ids[table], 'parent_folder_id', 'revision', 'updated_at'))
    identifier(value[ids[table]]); integer(value['revision'], 1); date(value['updated_at'])
    if value['parent_folder_id'] is not None: identifier(value['parent_folder_id'])
    if table == 'tree_orders':
        required(value, ('children',)); need(type(value['children']) is list, 'CHILDREN')
        children = [identifier(v) for v in value['children']]
        need(len(set(children)) == len(children), 'DUPLICATE_CHILD')
        return
    required(value, ('name', 'is_deleted', 'deleted_at'))
    name = text(value['name']); need('/' not in name, 'NAME'); path(name)
    need(type(value['is_deleted']) is bool, 'DELETED_BOOL')
    if value['is_deleted']: date(value['deleted_at'])
    else: need(value['deleted_at'] is None, 'DELETION_DATE')
    if table == 'documents':
        required(value, ('relative_path', 'structure_revision', 'content'))
        path(value['relative_path']); integer(value['structure_revision'], 1); body(value['content'])


@dataclass(frozen=True)
class Expected:
    account: str
    project: str
    target: dict  # Exact expected member and required reference rows. Copied by runner.
    project_state_field: str = 'is_deleted'  # Explicit synthetic versus retained Windows wire contract.

    @closed_shape
    def validate(self):
        identifier(self.account); identifier(self.project)
        need(self.project_state_field in ('is_deleted', 'trashed_at'), 'PROJECT_STATE_CONTRACT')
        keys(self.target, ('members', 'reference_ids', 'reference_rows', 'root_id'))
        identifier(self.target['root_id'])
        need(type(self.target['members']) is dict and type(self.target['reference_ids']) is list, 'TARGET')
        refs = [identifier(v) for v in self.target['reference_ids']]
        need(len(set(refs)) == len(refs), 'TARGET')
        member_ids = set()
        for table, rows in self.target['members'].items():
            need(table in ('documents', 'folders', 'tree_orders') and type(rows) is list, 'TARGET')
            key = {'documents':'document_id','folders':'folder_id','tree_orders':'tree_order_id'}[table]
            for value in rows:
                row(table, value, self.project)
                need(value[key] not in member_ids, 'TARGET_DUPLICATE'); member_ids.add(value[key])
                if table == 'documents': need(not value['relative_path'].startswith('__antigravity__/'), 'SPECIAL_MEMBER')
                if table != 'tree_orders': need(value['is_deleted'] is False, 'DELETED_MEMBER')
        need(self.target['root_id'] in {r['folder_id'] for r in self.target['members'].get('folders',[])}, 'TARGET_ROOT')
        need(not member_ids.intersection(refs), 'TARGET_ROLE')
        need(type(self.target['reference_rows']) is dict, 'REFERENCE_ROWS')
        reference_ids = []
        for table, rows in self.target['reference_rows'].items():
            need(table in ('documents','folders','tree_orders') and type(rows) is list, 'REFERENCE_ROWS')
            key = {'documents':'document_id','folders':'folder_id','tree_orders':'tree_order_id'}[table]
            for value in rows:
                row(table,value,self.project); reference_ids.append(value[key])
        need(len(set(reference_ids)) == len(reference_ids) and set(reference_ids) == set(refs), 'REFERENCE_ROWS')


def validate_project_row(value, expected):
    required(value, ('owner_id', 'project_id', expected.project_state_field))
    need(identifier(value['owner_id']) == expected.account and value['project_id'] == expected.project, 'OWNER')
    need(expected.project_state_field in ('is_deleted', 'trashed_at'), 'PROJECT_STATE_CONTRACT')
    if expected.project_state_field == 'is_deleted':
        need(value['is_deleted'] is False, 'OWNER')
    else:
        required(value, ('trashed_by',))
        need(value['trashed_at'] is None and value['trashed_by'] is None, 'PROJECT_TRASHED')
        if 'is_deleted' in value: need(value['is_deleted'] is False, 'PROJECT_STATE_CONFLICT')


@closed_shape
def validate_response(index, response, expected):
    """Fail each paid request before permitting the next reservation."""
    need(type(index) is int and 0 <= index < 7, 'REQUEST_INDEX')
    need(type(response.status) is int and response.status in ((200,) if index < 2 else (200,206)), 'HTTP_STATUS')
    value = strict_json(response.raw)
    if index == 0:
        required(value, ('id',)); need(identifier(value['id']) == expected.account, 'SUBJECT')
    elif index == 1: handshake(value, expected.project)
    else:
        need(type(value) is list, 'TABLE'); count_header(response.content_range,len(value))
        for item in value: row(TABLES[index-2],item,expected.project)
        if index in (2,3):
            need(len(value) == 1, 'SINGLETON')
            if index == 2:
                validate_project_row(value[0], expected)
            else:
                required(value[0],('project_sync_mode','migration_epoch'))
                need(value[0]['project_sync_mode'] == 'ID_BASED' and integer(value[0]['migration_epoch'],1) == 1, 'SETTINGS')
    return value


def count_header(header, length):
    need(length <= 10000, 'COUNT_LIMIT')
    if length == 0: need(header in ('*/0', '0-0/0'), 'COUNT')
    else: need(header == '0-%d/%d' % (length - 1, length), 'COUNT')


@closed_shape
def validate_pass(responses, expected):
    """Raw responses already bounded/persisted in the synthetic evidence journal."""
    need(len(responses) == 7, 'PARTIAL_PASS')
    expected.validate()
    values = [validate_response(i,r,expected) for i,r in enumerate(responses)]
    required(values[0], ('id',)); need(identifier(values[0]['id']) == expected.account, 'SUBJECT')
    handshake(values[1], expected.project)
    tables = {}
    for table, value, response in zip(TABLES, values[2:], responses[2:]):
        need(type(value) is list, 'TABLE')
        count_header(response.content_range, len(value))
        for item in value: row(table, item, expected.project)
        tables[table] = value
    need(len(tables['projects']) == len(tables['project_sync_settings']) == 1, 'SINGLETON')
    p, settings = tables['projects'][0], tables['project_sync_settings'][0]
    validate_project_row(p, expected)
    required(settings, ('project_sync_mode', 'migration_epoch'))
    need(settings['project_sync_mode'] == 'ID_BASED' and integer(settings['migration_epoch'], 1) == 1, 'SETTINGS')
    graph = validate_table_graph(tables, expected)
    # Table row order and handshake set order are irrelevant; all other fields preserved.
    comparable = {'handshake': copy.deepcopy(values[1]), 'tables': {}}
    comparable['handshake']['server_capabilities'].sort()
    comparable['handshake']['supported_protocol_versions'].sort()
    id_fields = ('project_id','project_id','document_id','folder_id','tree_order_id')
    for table, key in zip(TABLES, id_fields): comparable['tables'][table] = sorted(tables[table], key=lambda r: r[key])
    return {'comparison': json_bytes(comparable), 'context_only_ids': graph['context_only_ids'],
            'normal_body_hashes': graph['normal_body_hashes']}


@closed_shape
def validate_table_graph(tables, expected):
    """Validate retained rows, without asserting HTTP totals, time or snapshot consistency."""
    expected.validate()
    keys(tables, TABLES)
    for table, rows in tables.items():
        need(type(rows) is list and len(rows) <= 10000, 'TABLE')
        for value in rows: row(table, value, expected.project)
    # Special rows are retained and compared, but never adopted or blanket body-verified.
    normal, special = [], []
    for d in tables['documents']:
        (special if d['relative_path'].startswith('__antigravity__/') else normal).append(d)
    nodes = tables['folders'] + normal
    ids = [v.get('folder_id', v.get('document_id')) for v in nodes]
    need(len(set(ids)) == len(ids), 'DUPLICATE_ENTITY')
    by_id = dict(zip(ids, nodes)); folders = {v['folder_id']: v for v in tables['folders']}
    special_ids = {v['document_id'] for v in special}
    need(len(special_ids) == len(special) and not special_ids.intersection(by_id), 'DUPLICATE_ENTITY')
    paths = set()
    for entity, n in by_id.items():
        names, seen, current = [n['name']], {entity}, n
        while current['parent_folder_id'] is not None:
            parent = current['parent_folder_id']; need(parent in folders and parent not in seen, 'PARENT')
            seen.add(parent); current = folders[parent]; names.insert(0, current['name'])
            need(n['is_deleted'] or not current['is_deleted'], 'DELETED_PARENT')
        derived = '/'.join(names)
        collision = unicodedata.normalize('NFC', derived).casefold()
        need(collision not in paths, 'PATH_COLLISION'); paths.add(collision)
        if 'document_id' in n: need(n['relative_path'] == derived, 'DERIVED_PATH')
    orders = tables['tree_orders']; parents = [o['parent_folder_id'] for o in orders]
    need(len(set(o['tree_order_id'] for o in orders)) == len(orders) and len(set(parents)) == len(parents), 'ORDER_DUPLICATE')
    need(not set(o['tree_order_id'] for o in orders).intersection(set(by_id)|special_ids), 'DUPLICATE_ENTITY')
    need(set(parents) == {None} | set(folders), 'ORDER_COVERAGE')
    for o in orders:
        children = {entity for entity, n in by_id.items() if n['parent_folder_id'] == o['parent_folder_id'] and not n['is_deleted']}
        need(set(o['children']) == children, 'ORDER_MEMBERSHIP')
    need(expected.target['root_id'] in folders, 'TARGET_ROOT')
    for role in ('members','reference_rows'):
        for table, expected_rows in expected.target[role].items():
            key = {'documents':'document_id','folders':'folder_id','tree_orders':'tree_order_id'}[table]
            actual = {v[key]: v for v in tables[table]}
            for wanted in expected_rows:
                need(wanted[key] in actual and json_bytes(actual[wanted[key]]) == json_bytes(wanted), 'TARGET_CHANGED')
                if role == 'members':
                    if table == 'documents': need(wanted[key] not in special_ids, 'SPECIAL_MEMBER')
                    current = wanted['parent_folder_id'] if table == 'tree_orders' else wanted[key]
                    while current is not None and current != expected.target['root_id']:
                        need(current in by_id, 'TARGET_SCOPE'); current = by_id[current]['parent_folder_id']
                    need(current == expected.target['root_id'], 'TARGET_SCOPE')
    all_ids = set(by_id) | {o['tree_order_id'] for o in orders}
    need(set(expected.target['reference_ids']) <= all_ids, 'REFERENCE_MISSING')
    return {'context_only_ids': sorted(special_ids),
            'normal_body_hashes': {d['document_id']: body(d['content']) for d in normal}}


@closed_shape
def review_handoff(files, envelope_name='handoff.json'):
    """Validate the draft U1 reference graph without granting any authority."""
    need(type(files) is dict and all(type(v) is bytes for v in files.values()) and len(files) <= 128 and sum(len(v) for v in files.values()) <= 32*1024*1024, 'BUNDLE_SIZE')
    need(envelope_name in files, 'ENVELOPE_MISSING')
    e = strict_json(files[envelope_name])
    keys(e, ('format','schema_version','binding','target','artifacts','creation','observations','evidence','missing_evidence','checks','authority'))
    need(e['format'] == 'windows-isolated-receive-handoff-v1' and integer(e['schema_version'],1) == 1, 'FORMAT')
    keys(e['authority'], ('baseline_ready','baseline_applied','execution_allowed','app_binding_created','atomic_snapshot'))
    need(all(v is False for v in e['authority'].values()), 'AUTHORITY')
    b = e['binding']
    keys(b, ('account_id','project_id','contract_version','contract_sha256','protocol_version','mode','epoch'))
    identifier(b['account_id']); identifier(b['project_id'])
    need(b['contract_version'] == '0.2.0' and b['contract_sha256'] == CONTRACT_SHA and integer(b['protocol_version'],1) == 3
        and b['mode'] == 'ID_BASED' and integer(b['epoch'],1) == 1, 'BINDING_CONTRACT')
    artifacts, paths = {}, set()
    need(type(e['artifacts']) is list, 'ARTIFACTS')
    for a in e['artifacts']:
        keys(a, ('artifact_id','role','path','sha256','byte_count'))
        aid = text(a['artifact_id']); need(aid and aid not in artifacts, 'ARTIFACT_ID'); need(a['role'] in ROLES, 'ARTIFACT_ROLE')
        p = path(a['path']); collision = unicodedata.normalize('NFC',p).casefold()
        need(collision not in paths and p != envelope_name, 'ARTIFACT_PATH'); paths.add(collision)
        need(p in files and len(files[p]) == integer(a['byte_count']) and sha(files[p]) == hash_value(a['sha256']), 'ARTIFACT_HASH')
        artifacts[aid] = a
    need(set(files) == {envelope_name} | {a['path'] for a in artifacts.values()}, 'EXTRA_FILE')
    def resolve(ref):
        keys(ref, ('artifact_id','json_pointer'))
        need(ref['artifact_id'] in artifacts, 'ARTIFACT_REF')
        a = artifacts[ref['artifact_id']]; data = files[a['path']]
        if ref['json_pointer'] is None:
            need(a['role'] in ('raw_bytes','header_bytes'), 'NONJSON_ROLE')
            return data
        return pointer(strict_json(data), ref['json_pointer'])
    target = e['target']
    keys(target, ('manifest_ref','binding','root_id','parent_id','members','references','context_only'))
    original = resolve(target['manifest_ref'])
    need(json_bytes(original) == json_bytes({k:v for k,v in target.items() if k != 'manifest_ref'}), 'TARGET_ARTIFACT')
    need(json_bytes(target['binding']) == json_bytes(e['binding']), 'BINDING')
    identifier(target['root_id'])
    if target['parent_id'] is not None: identifier(target['parent_id'])
    seen = set()
    for kind in ('members','references','context_only'):
        need(type(target[kind]) is list, 'TARGET_ENTRIES')
        for entry in target[kind]:
            keys(entry, ('entity_kind','entity_id','parent_id','name','allowed_actions','source_refs'))
            need(entry['entity_kind'] in ('document','folder','order','special'), 'ENTITY_KIND')
            key = identifier(entry['entity_id'])
            need(key not in seen, 'TARGET_DUPLICATE'); seen.add(key)
            if entry['parent_id'] is not None: identifier(entry['parent_id'])
            if entry['entity_kind'] == 'order': need(entry['name'] is None, 'ORDER_NAME')
            else: text(entry['name'])
            allowed = {'observe'} if kind != 'members' else {'observe','future_apply'}
            need(not (kind == 'members' and entry['entity_kind'] == 'special'), 'SPECIAL_MEMBER')
            actions = entry['allowed_actions']; need(type(actions) is list and len(set(actions)) == len(actions) and set(actions) <= allowed, 'ALLOWED_ACTION')
            need(type(entry['source_refs']) is list and entry['source_refs'], 'SOURCE_REFS')
            for ref in entry['source_refs']:
                entity = resolve(ref); need(type(entity) is dict, 'ENTITY_REF')
                need(entity.get('project_id') == b['project_id'], 'ENTITY_PROJECT')
                id_key = {'document':'document_id','folder':'folder_id','order':'tree_order_id','special':'document_id'}[entry['entity_kind']]
                need(entity.get(id_key) == entry['entity_id'] and entity.get('parent_folder_id', object()) == entry['parent_id'], 'ENTITY_REF')
                if entry['name'] is not None: need(entity.get('name') == entry['name'], 'ENTITY_REF')
    need(any(v['entity_kind'] == 'folder' and v['entity_id'] == target['root_id'] and v['parent_id'] == target['parent_id'] for v in target['members']), 'TARGET_ROOT')
    missing = {}
    need(type(e['missing_evidence']) is list, 'MISSING_EVIDENCE')
    for m in e['missing_evidence']:
        keys(m, ('evidence_id','expected_role','phase','request_index','reason'))
        mid = text(m['evidence_id']); need(mid and mid not in missing, 'MISSING_ID')
        for k in ('expected_role','phase','reason'): need(text(m[k]), 'MISSING_DETAIL')
        need(m['phase'] in ('precreate','create','postcreate','A','B','bundle'), 'PHASE')
        if m['request_index'] is not None: integer(m['request_index'],1,16)
        missing[mid] = m
    need(type(e['evidence']) is dict, 'EVIDENCE_MAP')
    for eid, v in e['evidence'].items():
        need(text(eid) and eid not in missing, 'EVIDENCE_ID')
        keys(v, ('state','value','source_ref','missing_evidence_id'))
        if v['state'] == 'unavailable':
            need(v['value'] is None and v['source_ref'] is None and v['missing_evidence_id'] in missing, 'EVIDENCE_UNAVAILABLE')
        elif v['state'] == 'not_applicable':
            need(v['value'] is v['source_ref'] is v['missing_evidence_id'] is None, 'EVIDENCE_NA')
        else:
            need(v['state'] in ('captured_header','derived_from_raw','local_measured'), 'EVIDENCE_STATE')
            source = resolve(v['source_ref']); need(v['missing_evidence_id'] is None and v['value'] is not None, 'EVIDENCE_SOURCE')
            source_role = artifacts[v['source_ref']['artifact_id']]['role']
            if v['state'] == 'derived_from_raw': need(type(source) is list and integer(v['value']) == len(source), 'DERIVED_COUNT')
            elif v['state'] == 'captured_header':
                need(source_role == 'header_json' and json_bytes(source) == json_bytes(v['value']), 'EVIDENCE_HEADER')
            else:
                need(source_role == 'local_measurement', 'EVIDENCE_CLOCK')
                integer(source); need(type(v['value']) is int and source == v['value'], 'EVIDENCE_VALUE')
    obs_keys = ('phase','request_index','method','path','query','request_body_sha256','response_ref','http_status','evidence_ids')
    observed = set()
    need(type(e['observations']) is list, 'OBSERVATIONS')
    for obs in e['observations']:
        keys(obs, obs_keys); index = integer(obs['request_index'],1,16)
        phase = obs['phase']; need(phase in ('precreate','create','postcreate','A','B'), 'PHASE')
        need((phase,index) not in observed, 'OBS_DUPLICATE'); observed.add((phase,index))
        need((phase == 'precreate' and index <= 7) or (phase == 'create' and 8 <= index <= 11) or (phase == 'postcreate' and index >= 12) or (phase in ('A','B') and index <= 7), 'PHASE_INDEX')
        need(obs['method'] in ('GET','POST') and text(obs['path']).startswith('/'), 'REQUEST')
        need(type(obs['query']) is dict and all(type(v) is str for v in obs['query'].values()), 'QUERY')
        hash_value(obs['request_body_sha256'])
        if obs['method'] == 'GET': need(obs['request_body_sha256'] == sha(b''), 'GET_BODY')
        if obs['response_ref'] is None: need(obs['http_status'] is None, 'PARTIAL_RESPONSE')
        else: resolve(obs['response_ref']); integer(obs['http_status'],100,599)
        need(type(obs['evidence_ids']) is list and len(set(obs['evidence_ids'])) == len(obs['evidence_ids']) and set(obs['evidence_ids']) <= set(e['evidence']), 'EVIDENCE_REF')
    need(type(e['creation']) is list, 'CREATION')
    creation_indices = set(); batch_ids = set(); operation_ids = set()
    for c in e['creation']:
        keys(c, ('request_index','request_ref','batch_id','operation_ids','response_ref'))
        integer(c['request_index'],8,11); identifier(c['batch_id'])
        need(c['request_index'] not in creation_indices and c['batch_id'] not in batch_ids, 'CREATION_DUPLICATE')
        creation_indices.add(c['request_index']); batch_ids.add(c['batch_id'])
        need(type(c['operation_ids']) is list and c['operation_ids'] and len(set(c['operation_ids'])) == len(c['operation_ids']), 'OPERATIONS')
        [identifier(x) for x in c['operation_ids']]
        need(not operation_ids.intersection(c['operation_ids']), 'OPERATION_DUPLICATE'); operation_ids.update(c['operation_ids'])
        need(c['request_ref']['json_pointer'] == '/%d' % (c['request_index']-8), 'CREATION_POSITION')
        need(artifacts[c['request_ref']['artifact_id']]['role'] == 'creation_requests', 'CREATION_ROLE')
        request = resolve(c['request_ref']); response = resolve(c['response_ref'])
        for obj in (request,response):
            need(type(obj) is dict and obj.get('batch_id') == c['batch_id'] and obj.get('operation_ids') == c['operation_ids'], 'CREATION_LINK')
    need(type(e['checks']) is list, 'CHECKS'); check_ids = set()
    for check in e['checks']:
        keys(check, ('check_id','expected','reported','independent','evidence_refs','reason'))
        need(check['check_id'] in CHECK_IDS and check['check_id'] not in check_ids, 'CHECK_ID'); check_ids.add(check['check_id'])
        need(check['reason'] is None or type(check['reason']) is str, 'CHECK_REASON')
        need(type(check['evidence_refs']) is list, 'CHECK_REFS')
        for kind, who in (('reported','producer'),('independent','verifier')):
            v = check[kind]; keys(v,(who,'run_id','state','value')); text(v[who])
            need(v['state'] in ('pass','fail','unverified','not_applicable'), 'CHECK_STATE')
            if v['run_id'] is not None: identifier(v['run_id'])
            if v['state'] == 'unverified': need(v['value'] is None, 'UNVERIFIED_VALUE')
        for ref in check['evidence_refs']: resolve(ref)
    return {'reference_graph_reviewed': True, 'missing_evidence_ids': sorted(missing),
        'contract_encoding_hash_verified':False, 'server_origin_verified':False,
        'creation_semantics_verified':False, 'body_semantics_verified':False,
        'received_independent_claims_trusted': False, 'baseline_ready': False, 'baseline_applied': False,
        'execution_allowed': False, 'app_binding_created': False, 'atomic_snapshot': False}
