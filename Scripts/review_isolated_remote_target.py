"""Read-only review of an iPad-proposed handoff format. Never a wire format or grant.

Standard library only: no network, subprocess, DB, preferences or app-container access.
Input snapshots are supplied local JSON files; no URLs or paths inside them are followed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import uuid

FORMAT = 'ipad-isolated-remote-review/v1'
ENDPOINT = 'https://mhpnszcorfzrvhyondxr.supabase.co'
PROJECT = 'd8f50b5f-ae0e-42f8-9296-5d5885a5b304'
OLD_LOCAL = 'a9452cd1-4474-40b5-80ca-fbb7871e98e5'
OLD_ROOT = 'c7a2df0e-3276-4ed0-8ff2-57df3785f233'
PARENT = '95b8e4d0-1d8d-4af5-b121-0888d0157661'
OLD_PATH = '메인/메모장/통합검증 20260913'
SYNTHETIC = {'9ec6330b-e7ce-451c-a1fb-79ea485f24c6', '0f43b74f-3d01-4659-9090-4524e4de6f65',
             'b703f176-5a7a-4ee3-b9f6-6a7dc708164c', '396ce5f7-24aa-44f9-8781-bc69116e1cdd'}
PRESERVED = {OLD_ROOT, 'dbccc13f-899c-4a49-82a4-9a1ead1dc417',
             '86082d2a-51ad-4cd8-bc4d-d64fe2aec2e5', '955ff845-aa32-4f10-956e-bac83501b205',
             'be2814bb-a04d-4954-aaab-b600235da812', 'db8a3cc2-8b1a-5539-841c-042de34f5fd6'}
SEMANTICS = {
    'cycle': 'automatic_dispatch_without_send_or_receipt_batch',
    'reservation': 'durable_before_auth_and_first_http',
    'failure': 'never_refund_including_pre_http_abort',
    'last_cycle': 'nth_may_apply_with_existing_limits',
    'stop': 'block_all_automatic_before_http_from_n_plus_one',
    'zero': 'block_from_first_automatic_attempt',
    'lifetime': 'per_run_no_reset_on_success_manual_foreground_restart',
    'legacy_or_corrupt': 'block_without_backfill',
    'same_run_change': 'reject',
    'manual': 'separate_existing_authority_no_refund',
}
LIMIT = 8 * 1024 * 1024

class Invalid(ValueError):
    pass

def require(condition, code):
    if not condition:
        raise Invalid(code)

def keys(value, expected, code):
    require(type(value) is dict and set(value) == set(expected), code)

def identifier(value):
    require(type(value) is str, 'UUID_TYPE')
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        raise Invalid('UUID_FORMAT') from None
    require(str(parsed) == value and parsed.int != 0, 'UUID_CANONICAL')
    return value

def positive(value):
    require(type(value) is int and value > 0, 'REVISION_TYPE_OR_RANGE')

def relative(value):
    require(type(value) is str and value and '\\' not in value and not any(ord(c) < 32 for c in value), 'PATH_FORMAT')
    require(all(p not in ('', '.', '..') for p in value.split('/')), 'PATH_TRAVERSAL')

def hash_string(value):
    require(type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None, 'HASH_FORMAT')

def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'DUPLICATE_JSON_KEY')
        result[key] = value
    return result

def decode(raw):
    require(len(raw) <= LIMIT, 'INPUT_TOO_LARGE')
    try:
        return json.loads(raw.decode('utf-8'), object_pairs_hook=no_duplicates,
                          parse_constant=lambda _: (_ for _ in ()).throw(Invalid('NON_FINITE_JSON')))
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise Invalid('JSON_FORMAT') from None

def read(path):
    # Do not follow a symlink at any component, including evidence directory aliases.
    path = Path(path).absolute()
    require(not any(p.is_symlink() for p in [path, *path.parents]), 'INPUT_SYMLINK')
    require(path.is_file() and path.stat().st_size <= LIMIT, 'INPUT_FILE')
    with path.open('rb') as stream:
        raw = stream.read(LIMIT + 1)
    return raw, decode(raw)

def snapshot(value, target):
    keys(value, ['format', 'endpoint', 'account_id', 'server_project_id', 'complete', 'nodes'], 'SNAPSHOT_KEYS')
    require(value['format'] == FORMAT and value['complete'] is True, 'SNAPSHOT_COMPLETENESS')
    require(all(value[k] == target[k] for k in ['endpoint', 'account_id', 'server_project_id']), 'SNAPSHOT_CONTEXT')
    rows = value['nodes']
    require(type(rows) is list and 1 <= len(rows) <= 256, 'SNAPSHOT_SIZE')
    nodes = {}
    for row in rows:
        keys(row, ['id', 'kind', 'parent_id', 'path', 'revision', 'structure_revision', 'deleted',
                   'utf8_bytes', 'ends_lf', 'sha256'], 'NODE_KEYS')
        ident = identifier(row['id']); require(ident not in nodes, 'DUPLICATE_NODE_ID')
        require(ident not in SYNTHETIC, 'SYNTHETIC_NODE_AS_REMOTE')
        require(row['kind'] in ('folder', 'text'), 'NODE_KIND')
        if row['parent_id'] is not None:
            identifier(row['parent_id'])
        relative(row['path']); positive(row['revision'])
        require(type(row['deleted']) is bool, 'DELETED_TYPE')
        if row['kind'] == 'text':
            positive(row['structure_revision'])
            require(type(row['utf8_bytes']) is int and row['utf8_bytes'] >= 0 and type(row['ends_lf']) is bool, 'BODY_DIAGNOSTIC_TYPE')
            hash_string(row['sha256'])
        else:
            require(row['structure_revision'] is None, 'FOLDER_STRUCTURE_REVISION')
            require(all(row[k] is None for k in ['utf8_bytes', 'ends_lf', 'sha256']), 'FOLDER_BODY_FIELDS')
        nodes[ident] = row
    active_paths = set()
    for row in rows:
        parent = row['parent_id']
        if parent is not None:
            require(parent in nodes and nodes[parent]['kind'] == 'folder', 'MISSING_PARENT')
            if not row['deleted']:
                require(not nodes[parent]['deleted'], 'DELETED_PARENT')
                require(row['path'].rsplit('/', 1)[0] == nodes[parent]['path'] and '/' in row['path'], 'PARENT_PATH')
        visited = {row['id']}
        while parent is not None:
            require(parent not in visited, 'PARENT_CYCLE')
            visited.add(parent); parent = nodes[parent]['parent_id']
        if not row['deleted']:
            # Conservative collision check across Windows/iPad path case behavior.
            path = row['path'].casefold()
            require(path not in active_paths, 'DUPLICATE_ACTIVE_PATH')
            active_paths.add(path)
    return nodes

def review(target, before, candidate, before_raw, candidate_raw):
    keys(target, ['format', 'purpose', 'origin', 'endpoint', 'account_id', 'server_project_id',
                  'local_project_id', 'parent_id', 'root_id', 'root_path', 'member_ids',
                  'before_sha256', 'candidate_sha256', 'semantics'], 'TARGET_KEYS')
    require(target['format'] == FORMAT and target['purpose'] == 'offline_review_only', 'NOT_REVIEW_FORMAT')
    require(target['origin'] in ('windows_export', 'synthetic_test'), 'ORIGIN_REQUIRED')
    require(target['endpoint'] == ENDPOINT and target['server_project_id'] == PROJECT, 'STAGING_SCOPE')
    account = identifier(target['account_id']); local = identifier(target['local_project_id'])
    root = identifier(target['root_id']); identifier(target['parent_id'])
    require(local not in {OLD_LOCAL, PROJECT, account, PARENT, *PRESERVED, *SYNTHETIC}, 'LOCAL_PROJECT_REUSE')
    require(target['parent_id'] == PARENT, 'PARENT_SCOPE')
    relative(target['root_path'])
    require(target['root_path'].startswith('메인/메모장/') and target['root_path'].count('/') == 2
            and target['root_path'].casefold() != OLD_PATH.casefold(), 'ROOT_PATH_SCOPE')
    ids = target['member_ids']
    require(type(ids) is list and 2 <= len(ids) <= 64, 'MEMBER_COUNT')
    members = {identifier(x) for x in ids}
    require(len(members) == len(ids) and root in members, 'MEMBER_IDS')
    require(not members.intersection(PRESERVED | SYNTHETIC | {PARENT, OLD_LOCAL, PROJECT, local, account}), 'PROTECTED_MEMBER')
    require(target['semantics'] == SEMANTICS, 'AUTOMATIC_SEMANTICS_DIFFER')
    for field, raw in [('before_sha256', before_raw), ('candidate_sha256', candidate_raw)]:
        hash_string(target[field]); require(target[field] == hashlib.sha256(raw).hexdigest(), 'EVIDENCE_HASH_MISMATCH')
    old = snapshot(before, target); new = snapshot(candidate, target)
    require(PRESERVED.issubset(old), 'PRESERVED_BASELINE_MISSING')
    protected = old['db8a3cc2-8b1a-5539-841c-042de34f5fd6']
    require(protected == dict(id=protected['id'], kind='text',
        parent_id='f4c92790-d675-4970-b1fc-b90f3a929ffb', path='메인/원고/일반본문검증 20260912.txt',
        revision=9, structure_revision=1, deleted=False, utf8_bytes=393, ends_lf=True,
        sha256='570040e0bd94d5ff31c64799d549775ef74eb14503b7fa374f170ad7297b764f'), 'PROTECTED_REV9_DRIFT')
    remote = old['955ff845-aa32-4f10-956e-bac83501b205']
    require(remote['kind'] == 'text' and not remote['deleted'] and remote['revision'] == 9
        and remote['structure_revision'] == 4 and remote['utf8_bytes'] == 22 and remote['ends_lf']
        and remote['sha256'] == hashlib.sha256('Windows 충돌 기준\n'.encode()).hexdigest(), 'PRESERVED_CONFLICT_REMOTE_DRIFT')
    deleted = old['be2814bb-a04d-4954-aaab-b600235da812']
    require(deleted['kind'] == 'text' and deleted['deleted'] and deleted['revision'] == 5
        and deleted['structure_revision'] == 6 and deleted['utf8_bytes'] == 0 and not deleted['ends_lf']
        and deleted['sha256'] == hashlib.sha256(b'').hexdigest(), 'PRESERVED_DELETED_E_DRIFT')
    require(not members.intersection(old), 'TARGET_ID_ALREADY_EXISTS')
    require(set(new) == set(old) | members, 'UNDECLARED_ADDITION_OR_REMOVAL')
    require(all(old[k] == new[k] for k in old), 'OUTSIDE_TARGET_CHANGED')
    require(root in new and new[root]['kind'] == 'folder' and new[root]['parent_id'] == PARENT
            and new[root]['path'] == target['root_path'], 'ROOT_BINDING')
    require(any(new[k]['kind'] == 'text' for k in members), 'TARGET_TEXT_MISSING')
    for ident in members:
        row = new[ident]
        require(not row['deleted'], 'NEW_TARGET_DELETED')
        if ident != root:
            require(row['parent_id'] in members and row['path'].startswith(target['root_path'] + '/'), 'MEMBER_OUTSIDE_ROOT')
    return {
        'status': 'offline_review_checked', 'origin': target['origin'], 'execution_allowed': False,
        'live_server_verified': False, 'app_binding_created': False,
        'member_count': len(members), 'preserved_node_count': len(old),
        'blockers': ['WINDOWS_FORMAT_ACCEPTANCE_AND_EXPORT_PROVENANCE_UNVERIFIED',
                     'FULL_BODY_TREE_ORDER_AND_SERVER_FRESHNESS_REVIEW_REQUIRED',
                     'REMOTE_BOOTSTRAP_ADAPTER_NOT_IMPLEMENTED',
                     'NEW_EXECUTION_SCOPE_AND_APP_SIGNATURE_NOT_PREPARED'],
        'differences': ['WINDOWS_DOCUMENT_TRANSITION_MAY_SAVE_IPAD_RETAINS_DRAFT',
                        'IPAD_AUTH_WRITE_LIMITS_REMAIN_SEPARATE', 'STATE_AND_ERROR_FIELDS_NOT_INTERCHANGEABLE'],
    }

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target'); parser.add_argument('before'); parser.add_argument('candidate')
    args = parser.parse_args(argv)
    try:
        _, target = read(args.target)
        before_raw, before = read(args.before); candidate_raw, candidate = read(args.candidate)
        result = review(target, before, candidate, before_raw, candidate_raw)
    except (Invalid, OSError, RecursionError, TypeError, KeyError) as error:
        # Never echo input values, manuscript content, local paths or credentials.
        code = str(error) if isinstance(error, Invalid) else 'INVALID_OR_UNREADABLE_INPUT'
        result = {'status': 'blocked', 'execution_allowed': False, 'code': code}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['status'] == 'offline_review_checked' else 2

if __name__ == '__main__':
    sys.exit(main())
