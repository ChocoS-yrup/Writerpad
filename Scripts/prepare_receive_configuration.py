#!/usr/bin/env python3
"""Offline artifact builder. Never signs, installs, launches, issues IDs or contacts a server.
Input spec: identity {approvalID,device,installationID,candidateSHA256}, local UUID,
publishableKey, mode (observe/receiveAndApply), policy (six millisecond limits).
Supply reviewed IDs explicitly. Output must not exist. Launch hash stays outside payload.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import uuid

BUNDLE = 'com.chocos.writerpad.receiveboundary'
LIMITS = dict(requestMS=15000, passMS=120000, interpassMS=15000,
              preApplyMS=60000, localApplyMS=60000, totalMS=360000)

def read(path, limit):
    path = Path(os.path.abspath(path))
    for ancestor in [*reversed(path.parents), path]:
        if stat.S_ISLNK(ancestor.lstat().st_mode):
            raise ValueError('symlink input')
    with path.open('rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError('unsafe input')
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('oversize input')
    return data

def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))+'\n').encode()

def digest(data):
    return hashlib.sha256(data).hexdigest()

def build(spec_path, portable_path, executable_path, output):
    spec = json.loads(read(spec_path, 16384))
    if set(spec) != {'identity', 'local', 'publishableKey', 'mode', 'policy'}:
        raise ValueError('spec fields')
    identity = spec['identity']
    if set(identity) != {'approvalID', 'device', 'installationID', 'candidateSHA256'}:
        raise ValueError('identity fields')
    for value in identity.values():
        if not isinstance(value, str) or not value or len(value.encode()) > 256 or any(ord(c)<32 or ord(c)==127 for c in value):
            raise ValueError('identity value')
    if len(identity['candidateSHA256']) != 64 or any(c not in '0123456789abcdef' for c in identity['candidateSHA256']):
        raise ValueError('candidate hash')
    local = str(uuid.UUID(spec['local']))
    key = spec['publishableKey']
    if not isinstance(key,str) or not key.startswith('sb_publishable_') or len(key)>512 or any(ord(c)<33 or ord(c)>126 for c in key):
        raise ValueError('publishable key')
    if spec['mode'] not in ('observe', 'receiveAndApply') or set(spec['policy']) != set(LIMITS):
        raise ValueError('mode or policy')
    if any(type(spec['policy'][k]) is not int or not 0 < spec['policy'][k] <= cap for k, cap in LIMITS.items()):
        raise ValueError('policy limit')
    executable = read(executable_path, 128*1024*1024)
    if not executable:
        raise ValueError('empty executable')
    portable = read(portable_path, 8*1024*1024)
    json.loads(portable) # Strict retained validation is performed by the app, not inferred here.
    installation = encode(dict(identity=identity, bundle=BUNDLE, executableSHA256=digest(executable)))
    local_record = encode(dict(local=local, bundle=BUNDLE, installationID=identity['installationID']))
    envelope = encode(dict(version=1, portable=base64.b64encode(portable).decode(),
        installationSHA256=digest(installation), localSHA256=digest(local_record),
        identity=identity, publishableKey=key, mode=spec['mode'], policy=spec['policy']))
    output = Path(output)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    payload = output/'ReceiveConfiguration-v1'
    payload.mkdir(mode=0o700)
    for path, data in [(payload/'installation.json', installation), (payload/'local.json', local_record),
                       (payload/'configuration.json', envelope),
                       (output/'launch-arguments.json', encode(['--receive-configuration-sha256', digest(envelope)]))]:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
    return digest(envelope)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('spec', 'portable', 'executable', 'output'):
        parser.add_argument('--'+name, required=True)
    args = parser.parse_args()
    try:
        build(args.spec, args.portable, args.executable, args.output)
    except (ValueError, OSError, TypeError, KeyError):
        parser.exit(1, 'Preparation blocked; inspect local inputs. No device action performed.\n')
    print('Local artifacts created; retained validation and installation remain pending.')
