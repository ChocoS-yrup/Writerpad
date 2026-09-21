"""Offline observation adapter. Reads supplied ZIP/directory; returns a review only.

No baseline objects, app storage, network, credentials, execution grants or writes.
File hashes are checked; Python/Swift journal re-encoding is deliberately unverified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import zipfile

from review_isolated_remote_target import decode, identifier, relative, hash_string, require, Invalid

ENDPOINT = 'https://mhpnszcorfzrvhyondxr.supabase.co'
ACCOUNT = 'e487c6ea-1c2b-4a90-821e-91e8547106de'
PROJECT = 'd8f50b5f-ae0e-42f8-9296-5d5885a5b304'
ENDED = '6a7a9c7d-982a-4fcd-90e6-3b4140504860'
CONTRACT_SHA = '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
TABLES = ['projects', 'project_sync_settings', 'documents', 'folders', 'tree_orders']
PATHS = ['/auth/v1/user', '/rest/v1/rpc/get_sync_handshake'] + ['/rest/v1/' + x for x in TABLES]
SCOPE_KEYS = 'format run_id endpoint account_id project_id max_requests max_seconds expires_at reference_sha256'.split()
OBS_KEYS = ('format status stop_reason execution_allowed complete baseline_ready atomic_snapshot visibility endpoint account_id '
            'server_project_id contract_version protocol_version reference_sha256 http_used auth_user_used token_refreshes '
            'document_structure_writes automatic_cycles started_at deadline candidate_check differences special_metadata_ids nodes orders').split()
EVENT_KEYS = {
    'opened': 'scope_sha256 started deadline',
    'attempt': 'request method path params body_sha256 at',
    'response': 'request file sha256 bytes status at content_range content_range_state',
    'validated': 'request count at',
    'observed': 'reason http_used at observation_sha256',
    'stopped': 'reason http_used at observation_sha256',
}
MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def keys(obj, required, optional=()):
    require(type(obj) is dict and set(required) <= set(obj) <= set(required) | set(optional), 'FIELD_SET')


def integer(n, low=0, high=10000):
    require(type(n) is int and low <= n <= high, 'INTEGER_RANGE')


def number(n):
    # decode() rejects non-finite constants, but 1e999 also needs rejection.
    import math
    require(type(n) in (int, float) and math.isfinite(n), 'TIME_NUMBER')


def no_links(path):
    require(not any(p.is_symlink() for p in [path, *path.parents]), 'INPUT_SYMLINK')


def load_bundle(path, prefix=''):
    """Bounded read without extraction or following any referenced external path."""
    path = Path(path).absolute()
    no_links(path)
    prefix = prefix.rstrip('/')
    if prefix:
        relative(prefix)
    output = {}
    total = 0

    def add(name, size, read):
        nonlocal total
        relative(name)
        require(name not in output and len(output) < 64, 'DUPLICATE_OR_TOO_MANY_FILES')
        require(0 <= size <= MAX_FILE and total + size <= MAX_TOTAL, 'INPUT_TOO_LARGE')
        raw = read()
        require(len(raw) == size, 'INPUT_CHANGED')
        output[name] = raw
        total += size

    if path.is_dir():
        base = path / prefix if prefix else path
        no_links(base)
        require(base.is_dir(), 'INPUT_DIRECTORY')
        for p in sorted(base.rglob('*')):
            no_links(p)
            if p.is_file():
                add(p.relative_to(base).as_posix(), p.stat().st_size, p.read_bytes)
            else:
                require(p.is_dir(), 'INPUT_FILE_TYPE')
    else:
        require(path.is_file(), 'INPUT_FILE')
        with zipfile.ZipFile(path) as archive:
            names = set()
            for info in archive.infolist():
                name = info.filename.rstrip('/')
                relative(name)
                require(name not in names, 'DUPLICATE_ZIP_ENTRY')
                names.add(name)
                require(not stat.S_ISLNK(info.external_attr >> 16), 'INPUT_SYMLINK')
                if info.is_dir():
                    continue
                if prefix and not info.filename.startswith(prefix + '/'):
                    continue
                selected = info.filename[len(prefix) + 1:] if prefix else info.filename
                add(selected, info.file_size, lambda i=info: archive.read(i))
    require(output, 'EMPTY_BUNDLE')
    return output


def rows(values, kind, reference=False):
    require(type(values) is list and len(values) <= 20000, 'ROW_LIST')
    result = {}
    for row in values:
        if kind == 'orders':
            keys(row, ['id', 'parent_id', 'revision', 'children'])
        else:
            required = 'id kind parent_id revision structure_revision deleted utf8_bytes ends_lf sha256'.split()
            keys(row, required + (['path'] if reference else ['name']), () if reference else ['path', 'observed_relative_path'])
            require(row['kind'] in ['text', 'folder'] and type(row['deleted']) is bool, 'NODE_TYPE')
            if 'path' in row:
                relative(row['path'])
            if not reference:
                require(type(row['name']) is str and row['name'] and '/' not in row['name'] and '\\' not in row['name'], 'NODE_NAME')
            if row['kind'] == 'folder':
                require(all(row[k] is None for k in ['structure_revision', 'utf8_bytes', 'ends_lf', 'sha256']), 'FOLDER_BODY')
            else:
                integer(row['structure_revision'], 1, 2**63-1)
                integer(row['utf8_bytes'], 0, MAX_FILE)
                require(type(row['ends_lf']) is bool, 'BODY_LF')
                hash_string(row['sha256'])
                if not reference:
                    require('observed_relative_path' in row, 'OBSERVED_PATH_MISSING')
                    require(row['observed_relative_path'] is None or type(row['observed_relative_path']) is str, 'OBSERVED_PATH_TYPE')
        ident = identifier(row['id'])
        require(ident not in result, 'DUPLICATE_ROW')
        if row['parent_id'] is not None:
            identifier(row['parent_id'])
        integer(row['revision'], 1, 2**63-1)
        if kind == 'orders':
            require(type(row['children']) is list and len(row['children']) <= 20000, 'ORDER_CHILDREN')
            children = [identifier(x) for x in row['children']]
            require(len(children) == len(set(children)), 'DUPLICATE_CHILD')
        result[ident] = row
    return result


def review(files):
    require(type(files) is dict and all(type(k) is str and type(v) is bytes for k, v in files.items()), 'BUNDLE_TYPE')
    checked = []
    missing_raw = []
    if 'SHA256SUMS.json' in files:
        manifest = decode(files['SHA256SUMS.json'])
        require(type(manifest) is dict, 'MANIFEST_TYPE')
        for name, expected in manifest.items():
            relative(name); hash_string(expected)
            require(name in files and sha(files[name]) == expected, 'FILE_HASH_MISMATCH')
            checked.append(name)
    require('scope.json' in files, 'SCOPE_MISSING')
    scope = decode(files['scope.json']); keys(scope, SCOPE_KEYS)
    require(scope['format'] == 'windows-isolated-read-scope-v1', 'SCOPE_FORMAT')
    identifier(scope['run_id']); require(scope['run_id'] != ENDED, 'ENDED_RUN')
    require((scope['endpoint'], scope['account_id'], scope['project_id']) == (ENDPOINT, ACCOUNT, PROJECT), 'SCOPE_BINDING')
    integer(scope['max_requests'], 7, 7)
    number(scope['max_seconds']); number(scope['expires_at'])
    require(0 < scope['max_seconds'] <= 180, 'SCOPE_DURATION')
    keys(scope['reference_sha256'], ['metadata', 'orders'])
    for v in scope['reference_sha256'].values(): hash_string(v)
    # Historical/expired scopes are readable, never executable.
    report = dict(format='ipad-windows-observation-review-v1', status='incomplete_observation',
                  execution_allowed=False, baseline_ready=False, baseline_applied=False, complete=False,
                  atomic_snapshot=False, app_binding_created=False, run_id=scope['run_id'],
                  file_hashes_checked=checked, requests=[], reserved_http=None,
                  metadata_reference_differences=[], reference_uncompared=[], raw_missing=missing_raw,
                  unverified=['server_origin_and_current_state', 'raw_content_independent_verification',
                              'cross_platform_chain_hash', 'candidate_profile_binding'],
                  body_independently_verified=False, chain_hash_verified=False,
                  candidate_profile_verified=False, reference_files_verified=[])
    if 'journal.jsonl' not in files:
        report['unverified'].append('journal_missing')
        return report
    raw = files['journal.jsonl']
    require(raw.endswith(b'\n') and raw, 'PARTIAL_JOURNAL')
    events = [decode(line) for line in raw.splitlines()]
    require(len(events) <= 23, 'EVENT_LIMIT')
    stages = {}; previous = ''; terminal = None; opened = None; last_time = None
    for seq, event in enumerate(events, 1):
        keys(event, ['sequence', 'previous', 'event', 'data', 'sha256'])
        integer(event['sequence'], seq, seq); hash_string(event['sha256'])
        require(event['previous'] == previous and terminal is None, 'EVENT_LINK_OR_AFTER_TERMINAL')
        previous = event['sha256']  # Declared link only, not a recomputed row hash.
        name = event['event']; require(name in EVENT_KEYS, 'EVENT_KIND')
        data = event['data']; keys(data, EVENT_KEYS[name].split())
        at = data['started'] if name == 'opened' else data['at']; number(at)
        require(last_time is None or at >= last_time, 'EVENT_TIME_ORDER'); last_time = at
        if name == 'opened':
            require(seq == 1, 'OPENED_ORDER')
            require(data['scope_sha256'] == sha(files['scope.json']), 'SCOPE_HASH')
            number(data['deadline'])
            require(data['deadline'] == min(scope['expires_at'], at + scope['max_seconds']) and at < data['deadline'], 'DEADLINE')
            opened = data
            continue
        require(opened is not None, 'OPENED_MISSING')
        if name in ['observed', 'stopped']:
            integer(data['http_used'], 0, 7)
            require(data['http_used'] == len(stages), 'USAGE_MISMATCH')
            require(data['reason'] is None if name == 'observed' else type(data['reason']) is str and bool(data['reason']), 'TERMINAL_REASON')
            if name == 'observed':
                require(len(stages) == 7 and all(r['stage'] == 'validated' for r in stages.values()), 'INCOMPLETE_OBSERVED')
                require(at < opened['deadline'], 'OBSERVED_AFTER_DEADLINE')
            hash_string(data['observation_sha256']); terminal = event
            continue
        n = data['request']; integer(n, 1, 7)
        if name == 'attempt':
            require(n == len(stages) + 1 and (n == 1 or stages[n-1]['stage'] == 'validated'), 'REQUEST_ORDER')
            require(at < opened['deadline'], 'ATTEMPT_AFTER_DEADLINE')
            require(data['method'] == ('POST' if n == 2 else 'GET') and data['path'] == PATHS[n-1], 'REQUEST_ALLOWLIST')
            expected = None if n < 3 else dict(project_id='eq.' + PROJECT, select='*', limit='10000')
            require(data['params'] == expected, 'REQUEST_FILTER')
            hash_string(data['body_sha256'])
            if n != 2: require(data['body_sha256'] == sha(b''), 'GET_BODY')
            else:
                payload = dict(p_project_id=PROJECT, p_contract_sha256=CONTRACT_SHA)
                body = (json.dumps(payload, sort_keys=True, separators=(',', ':')) + '\n').encode()
                require(data['body_sha256'] == sha(body), 'HANDSHAKE_REQUEST_HASH')
            stages[n] = dict(request=n, stage='attempted', count=None, count_validated=False, attempted_at=at)
        elif name == 'response':
            require(n in stages and n == len(stages) and stages[n]['stage'] == 'attempted', 'RESPONSE_ORDER')
            require(data['file'] == f'Q{n}.body', 'RAW_PATH')
            hash_string(data['sha256']); integer(data['bytes'], 0, MAX_FILE); integer(data['status'], 100, 599)
            require(data['content_range_state'] in ['value', 'missing', 'invalid'], 'COUNT_STATE')
            cr = data['content_range']
            require((type(cr) is str and len(cr) <= 64 and re.fullmatch(r'(\d+-\d+|\*)/(\d+|\*)', cr)) if data['content_range_state'] == 'value' else cr is None, 'COUNT_HEADER')
            if data['file'] in files:
                body = files[data['file']]
                require(len(body) == data['bytes'] and sha(body) == data['sha256'], 'RAW_HASH')
                checked.append(data['file'])
            else: missing_raw.append(data['file'])
            stages[n].update(stage='response_received', response=data)
        else:
            require(n in stages and n == len(stages) and stages[n]['stage'] == 'response_received', 'VALIDATED_ORDER')
            response = stages[n]['response']
            require(response['status'] == 200 or n >= 3 and response['status'] == 206, 'VALIDATED_HTTP')
            if n < 3: require(data['count'] is None, 'NON_TABLE_COUNT')
            else:
                count = data['count']; integer(count)
                if n in [3, 4]: integer(count, 1, 1)
                expected = ['*/0', '0-0/0'] if count == 0 else [f'0-{count-1}/{count}']
                require(response['content_range'] in expected, 'COUNT_RANGE_MISMATCH')
            stages[n].update(stage='validated', count=data['count'], count_validated=n >= 3)
    require(opened is not None, 'OPENED_MISSING')
    report['requests'] = [stages.get(n, dict(request=n, stage='unattempted', count=None, count_validated=False)) for n in range(1, 8)]
    report.update(reserved_http=len(stages), started_at=opened['started'], deadline=opened['deadline'], last_recorded_at=last_time)
    if terminal is None:
        report['unverified'].append('terminal_link_missing')
        return report
    require('observation.json' in files, 'OBSERVATION_MISSING')
    require(sha(files['observation.json']) == terminal['data']['observation_sha256'], 'OBSERVATION_HASH')
    obs = decode(files['observation.json']); keys(obs, OBS_KEYS)
    require(obs['format'] == 'windows-read-observation-v1', 'OBSERVATION_FORMAT')
    require(all(obs[k] is False for k in ['execution_allowed', 'complete', 'baseline_ready', 'atomic_snapshot']), 'OBSERVATION_PRIVILEGE')
    require((obs['endpoint'], obs['account_id'], obs['server_project_id']) == (ENDPOINT, ACCOUNT, PROJECT), 'OBSERVATION_BINDING')
    require(obs['contract_version'] == '0.2.0' and type(obs['protocol_version']) is int and obs['protocol_version'] == 3, 'EXPECTED_CONTRACT')
    require(obs['reference_sha256'] == scope['reference_sha256'], 'REFERENCE_BINDING')
    require(obs['status'] == terminal['event'] and obs['stop_reason'] == terminal['data']['reason'], 'STATUS_MISMATCH')
    for k, value in [('http_used', len(stages)), ('auth_user_used', int(bool(stages))), ('token_refreshes', 0), ('document_structure_writes', 0), ('automatic_cycles', 0)]:
        integer(obs[k], value, value)
    number(obs['started_at']); number(obs['deadline'])
    require(obs['started_at'] == opened['started'] and obs['deadline'] == opened['deadline'], 'OBSERVATION_TIME')
    require(type(obs['visibility']) is str and bool(obs['visibility']), 'VISIBILITY')
    require(obs['candidate_check'] == ('no collision in observed scope' if obs['status'] == 'observed' else 'not_completed'), 'CANDIDATE_STATUS')
    current = {k:rows(obs[k], k) for k in ['nodes', 'orders']}
    require(type(obs['special_metadata_ids']) is list, 'SPECIAL_IDS')
    special = [identifier(v) for v in obs['special_metadata_ids']]
    require(len(special) == len(set(special)) and not set(special) & (set(current['nodes']) | set(current['orders'])) and not set(current['nodes']) & set(current['orders']), 'ID_COLLISION')
    require(type(obs['differences']) is list, 'DIFFERENCES')
    for d in obs['differences']:
        keys(d, ['kind', 'id', 'fields']); identifier(d['id'])
        require(type(d['kind']) is str and type(d['fields']) is list and all(type(f) is str for f in d['fields']), 'DIFFERENCE_FIELDS')
    # Sender differences are separate from independently compared metadata fields.
    report['sender_differences'] = obs['differences']
    for kind, refname in [('nodes', 'metadata'), ('orders', 'orders')]:
        path = 'reference/before-' + refname + '.json'
        if path not in files:
            report['reference_uncompared'].append(dict(kind=kind, reason='reference_missing'))
            continue
        require(sha(files[path]) == scope['reference_sha256'][refname], 'REFERENCE_HASH')
        ref = decode(files[path])
        if kind == 'nodes':
            keys(ref, ['format', 'endpoint', 'account_id', 'server_project_id', 'complete', 'nodes'])
            require(ref['format'] == 'windows-isolated-target-metadata-proposal-v1' and (ref['endpoint'], ref['account_id'], ref['server_project_id']) == (ENDPOINT, ACCOUNT, PROJECT), 'REFERENCE_CONTEXT')
        else:
            keys(ref, ['format', 'complete', 'orders']); require(ref['format'] == 'windows-retained-orders-v1', 'REFERENCE_FORMAT')
        require(ref['complete'] is False, 'REFERENCE_COMPLETENESS')
        old = rows(ref[kind], kind, reference=True)
        report['reference_files_verified'].append(path)
        for ident, row in current[kind].items():
            if ident not in old:
                report['metadata_reference_differences'].append(dict(kind=kind, id=ident, fields=['unmatched_observed_id']))
                continue
            fields = [k for k in old[ident] if k in row and row[k] != old[ident][k]]
            absent = [k for k in old[ident] if k not in row]
            if kind == 'nodes' and row['name'] != old[ident]['path'].rsplit('/', 1)[-1]: fields.append('name')
            if fields: report['metadata_reference_differences'].append(dict(kind=kind, id=ident, fields=fields))
            if absent: report['reference_uncompared'].append(dict(kind=kind, id=ident, fields=absent, reason='partial_row'))
        for ident in old.keys() - current[kind].keys():
            full = obs['status'] == 'observed'
            destination = 'metadata_reference_differences' if full else 'reference_uncompared'
            report[destination].append(dict(kind=kind, id=ident, fields=['id'], reason='missing_observed_id' if full else 'partial_collection'))
    if obs['status'] == 'observed':
        for n in current['nodes'].values():
            require('path' in n, 'COMPLETE_PATH_MISSING')
            if n['kind'] == 'text': require(n['observed_relative_path'] == n['path'], 'OBSERVED_PATH_MISMATCH')
            parent = n['parent_id']; seen = {n['id']}
            while parent is not None:
                require(parent in current['nodes'] and parent not in seen, 'PARENT_GRAPH')
                ancestor = current['nodes'][parent]; require(ancestor['kind'] == 'folder' and (n['deleted'] or not ancestor['deleted']), 'PARENT_KIND')
                seen.add(parent); parent = ancestor['parent_id']
            expected_path = (current['nodes'][n['parent_id']]['path'] + '/' if n['parent_id'] else '') + n['name']
            require(n['path'] == expected_path, 'DERIVED_PATH')
        parents = set()
        for order in current['orders'].values():
            parent = order['parent_id']; require(parent not in parents, 'DUPLICATE_ORDER_PARENT'); parents.add(parent)
            require(parent is None or parent in current['nodes'] and current['nodes'][parent]['kind'] == 'folder', 'ORDER_PARENT')
            expected = {n['id'] for n in current['nodes'].values() if n['parent_id'] == parent and not n['deleted']}
            require(set(order['children']) == expected, 'ORDER_MEMBERSHIP')
        require(parents >= {n['parent_id'] for n in current['nodes'].values() if not n['deleted']}, 'ORDER_MISSING')
        counts = [sum(n['kind'] == 'text' for n in current['nodes'].values()) + len(special), sum(n['kind'] == 'folder' for n in current['nodes'].values()), len(current['orders'])]
        require(counts == [stages[n]['count'] for n in [5, 6, 7]], 'DERIVED_COUNT')
    report.update(status='observation_reviewed' if obs['status'] == 'observed' else 'partial_observation_reviewed',
                  observation_status=obs['status'], stop_reason=obs['stop_reason'],
                  finished_at=terminal['data']['at'], node_count=len(current['nodes']), order_count=len(current['orders']))
    if report['reference_uncompared']: report['unverified'].append('reference_comparison_incomplete')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--prefix', default='', help='Explicit ZIP/directory subfolder, no extraction')
    args = parser.parse_args()
    try:
        result = review(load_bundle(args.bundle, args.prefix))
    except (Invalid, OSError, ValueError, KeyError, TypeError, RecursionError, zipfile.BadZipFile):
        # No exception path, manuscript, raw response or credentials in error output.
        import sys
        error = sys.exc_info()[1]
        result = dict(status='blocked', execution_allowed=False, baseline_ready=False,
                      baseline_applied=False, body_independently_verified=False,
                      error=str(error) if isinstance(error, Invalid) else 'INVALID_INPUT')
        print(json.dumps(result, ensure_ascii=False, indent=2)); return 1
    print(json.dumps(result, ensure_ascii=False, indent=2)); return 0


if __name__ == '__main__':
    raise SystemExit(main())
