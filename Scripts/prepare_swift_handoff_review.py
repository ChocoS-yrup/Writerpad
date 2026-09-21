"""Offline byte-container export for the native reader. Not a baseline/apply format."""
import argparse
import base64
import json
import os
from pathlib import Path
import windows_handoff_mapping as w


def prepare(files, expected_handoff_sha256, expected_binding):
    # Validate retained links with the existing reader before copying original bytes.
    w.map_draft(files, expected_handoff_sha256, expected_binding)
    data = w.c.json_bytes(dict(format='ipad-windows-handoff-review-bytes-v1',
                              files={p:base64.b64encode(raw).decode('ascii') for p,raw in files.items()}))
    w.c.need(len(data) <= 48*1024*1024, 'PORTABLE_SIZE')
    return data


def write_new(path, data):
    fd = os.open(str(path),os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as f:
        f.write(data);f.flush();os.fsync(f.fileno())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('zip_path');p.add_argument('--handoff-sha256',required=True)
    p.add_argument('--binding-file',required=True);p.add_argument('--output',required=True)
    a=p.parse_args()
    try:
        data=prepare(w.read_zip(a.zip_path),a.handoff_sha256,w.c.strict_json(Path(a.binding_file).read_bytes()))
        write_new(a.output,data)
        print(json.dumps(dict(kind='private-offline-review-bytes',sha256=w.c.sha(data),bytes=len(data),baseline_applied=False)))
    except w.c.ContractError as e:
        print(json.dumps(dict(status='blocked',code=e.code)));return 1
    except OSError:
        print(json.dumps(dict(status='blocked',code='OUTPUT_UNAVAILABLE')));return 1
    return 0


if __name__=='__main__':raise SystemExit(main())
