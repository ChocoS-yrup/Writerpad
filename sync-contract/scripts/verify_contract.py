#!/usr/bin/env python3
"""Validate the shared WriterPad Sync contract package."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import rfc8785
from jsonschema import Draft202012Validator, FormatChecker


CONTRACT_DIR = Path(__file__).resolve().parents[1]
EXPECTED_VECTOR_IDS = {f"TV-{index:03d}" for index in range(1, 11)}


def load_json(path: Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_instance(instance: object, schema: object, label: str) -> None:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if not errors:
        return

    print(f"{label}: validation failed", file=sys.stderr)
    for error in errors:
        location = "/".join(str(item) for item in error.absolute_path) or "<root>"
        print(f"  {location}: {error.message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    schemas: dict[str, object] = {}
    for path in sorted(CONTRACT_DIR.glob("*.schema.json")):
        schema = load_json(path)
        Draft202012Validator.check_schema(schema)
        schemas[path.name] = schema

    required_schemas = {
        "protocol.schema.json",
        "incident.schema.json",
        "snapshot.schema.json",
        "transition-vector.schema.json",
    }
    missing_schemas = required_schemas - schemas.keys()
    if missing_schemas:
        raise SystemExit(f"missing schemas: {sorted(missing_schemas)}")

    protocol = load_json(CONTRACT_DIR / "protocol.json")
    validate_instance(protocol, schemas["protocol.schema.json"], "protocol.json")

    lock = load_json(CONTRACT_DIR / "contract-lock.json")
    if not isinstance(protocol, dict) or not isinstance(lock, dict):
        raise SystemExit("protocol.json and contract-lock.json must be JSON objects")
    if protocol.get("contract_version") != lock.get("contract_version"):
        raise SystemExit("contract version differs between protocol.json and contract-lock.json")

    canonical_bytes = rfc8785.dumps(protocol)
    digest = hashlib.sha256(canonical_bytes).hexdigest()
    if len(canonical_bytes) != lock.get("canonical_byte_length"):
        raise SystemExit(
            f"canonical byte length mismatch: expected {lock.get('canonical_byte_length')}, "
            f"got {len(canonical_bytes)}"
        )
    if digest != lock.get("canonical_contract_sha256"):
        raise SystemExit(
            f"canonical digest mismatch: expected {lock.get('canonical_contract_sha256')}, "
            f"got {digest}"
        )

    vector_ids: set[str] = set()
    vector_paths = sorted((CONTRACT_DIR / "test_vectors").glob("*.json"))
    for path in vector_paths:
        vector = load_json(path)
        validate_instance(vector, schemas["transition-vector.schema.json"], str(path.name))
        if not isinstance(vector, dict) or not isinstance(vector.get("vector_id"), str):
            raise SystemExit(f"{path.name}: missing vector_id")
        if vector["vector_id"] in vector_ids:
            raise SystemExit(f"duplicate vector_id: {vector['vector_id']}")
        vector_ids.add(vector["vector_id"])

    if vector_ids != EXPECTED_VECTOR_IDS:
        raise SystemExit(
            f"test vector set mismatch: expected {sorted(EXPECTED_VECTOR_IDS)}, "
            f"got {sorted(vector_ids)}"
        )

    print(f"Validated {len(schemas)} JSON schemas.")
    print(f"Validated protocol contract {protocol['contract_version']}.")
    print(f"Validated {len(vector_paths)} transition vectors.")
    print(f"Canonical protocol bytes: {len(canonical_bytes)}")
    print(f"Canonical SHA-256: {digest}")


if __name__ == "__main__":
    main()
