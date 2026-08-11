#!/usr/bin/env python3
"""Validate WriterPad Sync Contract schemas, vectors, and cross-file semantics."""

from __future__ import annotations

import hashlib
import json
import sys
import unicodedata
from pathlib import Path
from typing import Any

import rfc8785
from jsonschema import Draft202012Validator, FormatChecker


CONTRACT_DIR = Path(__file__).resolve().parents[1]
EXPECTED_VECTOR_IDS = {f"TV-{index:03d}" for index in range(1, 13)}
EXPECTED_STORAGE_VECTOR_IDS = {f"SN-{index:03d}" for index in range(1, 16)}
EXPECTED_ATOMIC_CASE_IDS = {f"ASC-{index:03d}" for index in range(1, 5)}
EXPECTED_DOCUMENT_CASE_IDS = {f"DC-{index:03d}" for index in range(1, 8)}
REQUIRED_SCHEMAS = {
    "protocol.schema.json",
    "incident.schema.json",
    "snapshot.schema.json",
    "transition-vector.schema.json",
    "atomic-structure-commit.schema.json",
    "document-commit.schema.json",
    "storage-name-vectors.schema.json",
}
REQUIRED_BATCH_FIELDS = {
    "batch_id",
    "writer_device_id",
    "client_build_id",
    "sync_protocol_version",
    "contract_version",
    "canonical_contract_sha256",
    "client_capabilities",
    "batch_payload_sha256",
}
OPERATION_CREATING_ACTIONS = {
    "create_folder",
    "create_document",
    "rename_folder",
    "rename_document",
    "delete_folder",
    "delete_document",
    "connect_legacy_client",
    "rebase_operation",
    "legacy_structure_write",
}
WINDOWS_RESERVED_BASENAMES = {
    "con",
    "prn",
    "aux",
    "nul",
    *(f"com{index}" for index in range(1, 10)),
    *(f"lpt{index}" for index in range(1, 10)),
}


def fail(message: str) -> None:
    raise SystemExit(message)


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def validate_instance(instance: Any, schema: Any, label: str) -> None:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(instance), key=lambda error: list(error.path))
    if not errors:
        return
    print(f"{label}: validation failed", file=sys.stderr)
    for error in errors:
        location = "/".join(str(item) for item in error.absolute_path) or "<root>"
        print(f"  {location}: {error.message}", file=sys.stderr)
    raise SystemExit(1)


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def verify_capability_matrix(protocol: dict[str, Any]) -> dict[int, dict[str, Any]]:
    versions = protocol["supported_protocol_versions"]
    by_version = {entry["version"]: entry for entry in versions}
    if sorted(by_version) != [1, 2, 3] or len(by_version) != len(versions):
        fail("supported protocol versions must be unique and exactly [1, 2, 3]")

    client_caps = protocol["client_capabilities"]
    server_caps = protocol["server_capabilities"]
    for version, entry in by_version.items():
        for capability in entry["required_client_capabilities"]:
            if capability not in client_caps:
                fail(f"protocol {version}: unknown required client capability {capability}")
            if client_caps[capability]["since_protocol"] > version:
                fail(f"protocol {version}: client capability {capability} starts later")
        for capability in entry["required_server_capabilities"]:
            if capability not in server_caps:
                fail(f"protocol {version}: unknown required server capability {capability}")
            if server_caps[capability]["since_protocol"] > version:
                fail(f"protocol {version}: server capability {capability} starts later")

    if by_version[1]["batch_requirement"] != "forbidden":
        fail("protocol 1 must forbid fabricated contract batches")
    if by_version[2]["batch_requirement"] != "forbidden":
        fail("protocol 2 must forbid fabricated contract batches")
    if by_version[3]["batch_requirement"] != "required":
        fail("protocol 3 must require contract batches")
    if protocol["immutable_batch_metadata"]["applies_to_protocols"] != [3]:
        fail("immutable batch metadata must apply exactly to protocol 3")
    field_names = {item["name"] for item in protocol["immutable_batch_metadata"]["fields"]}
    if field_names != REQUIRED_BATCH_FIELDS:
        fail(f"batch metadata fields mismatch: {sorted(field_names)}")
    return by_version


def action_operation_ids(action: dict[str, Any]) -> list[str]:
    action_input = action["input"]
    operation_ids: list[str] = []
    if isinstance(action_input.get("operation_id"), str):
        operation_ids.append(action_input["operation_id"])
    ordered = action_input.get("ordered_operation_ids", [])
    if isinstance(ordered, list):
        operation_ids.extend(item for item in ordered if isinstance(item, str))
    return operation_ids


def verify_vector_semantics(
    vector: dict[str, Any],
    protocol: dict[str, Any],
    versions: dict[int, dict[str, Any]],
    label: str,
) -> None:
    clients = {client["client_id"]: client for client in vector["initial_client_states"]}
    if vector["minimum_protocol_version"] != min(c["protocol_version"] for c in clients.values()):
        fail(f"{label}: minimum_protocol_version does not match the oldest participating client")

    known_operations: set[str] = set()
    immutable_values: dict[str, dict[str, Any]] = {}
    for client in clients.values():
        version = client["protocol_version"]
        if version not in versions:
            fail(f"{label}: unsupported client protocol {version}")
        declared = set(client["capabilities"])
        required = set(versions[version]["required_client_capabilities"])
        missing = required - declared
        if missing:
            fail(f"{label}/{client['client_id']}: missing capabilities {sorted(missing)}")
        for capability in declared:
            definition = protocol["client_capabilities"].get(capability)
            if definition is None:
                fail(f"{label}/{client['client_id']}: unknown capability {capability}")
            if definition["since_protocol"] > version:
                fail(
                    f"{label}/{client['client_id']}: capability {capability} starts at "
                    f"protocol {definition['since_protocol']}"
                )
        for item in client["queue"]:
            operation_id = item["operation_id"]
            if operation_id in known_operations:
                fail(f"{label}: duplicate initial operation_id {operation_id}")
            known_operations.add(operation_id)
            immutable_values[operation_id] = {
                key: item[key]
                for key in ("batch_id", "base_revision", "payload_sha256")
                if key in item
            }
            expected_provenance = versions[version]["provenance_kind"]
            if item["provenance_kind"] != expected_provenance:
                fail(f"{label}/{operation_id}: provenance does not match protocol {version}")
            if version == 3 and "batch_id" not in item:
                fail(f"{label}/{operation_id}: protocol 3 operation lacks batch_id")
            if version < 3 and "batch_id" in item:
                fail(f"{label}/{operation_id}: legacy operation fabricates batch_id")

    creation_paths = set(known_operations)
    for action in vector["ordered_actions"]:
        actor = clients.get(action["actor"])
        if actor is None:
            fail(f"{label}/{action['action_id']}: unknown actor {action['actor']}")
        operation_ids = action_operation_ids(action)
        if action["kind"] in OPERATION_CREATING_ACTIONS and not operation_ids:
            fail(f"{label}/{action['action_id']}: operation-creating action lacks operation_id")
        for operation_id in operation_ids:
            is_new = operation_id not in creation_paths
            action_input = action["input"]
            if is_new:
                creation_paths.add(operation_id)
                if actor["protocol_version"] == 3 and "batch_id" not in action_input:
                    fail(f"{label}/{action['action_id']}: new protocol 3 operation lacks batch_id")
                if actor["protocol_version"] < 3 and "batch_id" in action_input:
                    fail(f"{label}/{action['action_id']}: legacy operation fabricates batch_id")
            elif operation_id in immutable_values:
                for key, original in immutable_values[operation_id].items():
                    if key in action_input and action_input[key] != original:
                        fail(f"{label}/{action['action_id']}: immutable {key} changed for {operation_id}")

        if action["kind"] == "rebase_operation":
            action_input = action["input"]
            required = {
                "operation_id",
                "batch_id",
                "supersedes_operation_id",
                "base_revision",
                "payload_sha256",
            }
            if not required <= action_input.keys():
                fail(f"{label}/{action['action_id']}: rebase lacks {sorted(required - action_input.keys())}")
            if action_input["operation_id"] == action_input["supersedes_operation_id"]:
                fail(f"{label}/{action['action_id']}: rebase must create a new operation_id")
            superseded = immutable_values.get(action_input["supersedes_operation_id"])
            if superseded and action_input["batch_id"] == superseded.get("batch_id"):
                fail(f"{label}/{action['action_id']}: rebase must create a new batch_id")

    expected_ids = {item["operation_id"] for item in vector["expected_queue_states"]}
    missing_paths = expected_ids - creation_paths
    if missing_paths:
        fail(f"{label}: expected operations have no creation path: {sorted(missing_paths)}")


def verify_state_model(protocol: dict[str, Any], vectors: list[dict[str, Any]]) -> None:
    model = protocol["operation_model"]
    event_types = set(model["event"]["event_types"])
    derivation = model["state"]["derivation"]
    derived_events = {item["event_type"] for item in derivation}
    derived_states = {item["result_state"] for item in derivation}
    if derived_events != event_types:
        fail("state derivation must cover every event type exactly by name")
    if not set(model["state"]["states"]) <= derived_states:
        fail("every operation state must be derivable from an event")
    if not {"cancel_requested", "superseded"} <= event_types:
        fail("cancellation and supersession events are required")
    if "TV-011" not in {vector["vector_id"] for vector in vectors}:
        fail("TV-011 cancellation conformance vector is required")
    cancellation_vector = next(v for v in vectors if v["vector_id"] == "TV-011")
    outcomes = " ".join(action["expected_outcome"] for action in cancellation_vector["ordered_actions"])
    for phrase in ("already_cancelled", "OPERATION_TERMINAL"):
        if phrase not in outcomes:
            fail(f"TV-011 must cover {phrase}")


def normalize_storage_name(value: str) -> tuple[str | None, str | None]:
    if any(char in "/\\" or ord(char) <= 0x1F or ord(char) == 0x7F for char in value):
        return None, "STORAGE_NAME_INVALID"
    normalized = unicodedata.normalize("NFKC", value).casefold()
    normalized = unicodedata.normalize("NFKC", normalized).rstrip(" .")
    if normalized in {"", ".", ".."}:
        return None, "STORAGE_NAME_INVALID"
    basename = normalized.split(".", 1)[0]
    if basename in WINDOWS_RESERVED_BASENAMES:
        return None, "STORAGE_NAME_RESERVED"
    return normalized, None


def verify_storage_vectors(protocol: dict[str, Any], schema: dict[str, Any]) -> int:
    path = CONTRACT_DIR / protocol["storage_name_normalization"]["conformance_vectors"]
    suite = require_object(load_json(path), str(path.name))
    validate_instance(suite, schema, str(path.name))
    if suite["contract_version"] != protocol["contract_version"]:
        fail("storage-name vector contract version differs from protocol")
    if suite["unicode_version"] != protocol["storage_name_normalization"]["unicode_version"]:
        fail("storage-name Unicode version differs from protocol")
    if unicodedata.unidata_version != suite["unicode_version"]:
        fail(
            f"Python Unicode data version mismatch: expected {suite['unicode_version']}, "
            f"got {unicodedata.unidata_version}"
        )
    ids = {item["vector_id"] for item in suite["vectors"]}
    if ids != EXPECTED_STORAGE_VECTOR_IDS:
        fail("storage-name vector ID set mismatch")
    for item in suite["vectors"]:
        normalized, error = normalize_storage_name(item["input"])
        if item["valid"]:
            if error is not None or normalized is None:
                fail(f"{item['vector_id']}: expected valid but got {error}")
            if normalized != item["normalized"]:
                fail(f"{item['vector_id']}: normalized value mismatch")
            if normalized.encode("utf-8").hex() != item["utf8_hex"]:
                fail(f"{item['vector_id']}: UTF-8 collision key mismatch")
        elif error != item["error_code"]:
            fail(f"{item['vector_id']}: expected {item['error_code']}, got {error}")
    return len(suite["vectors"])


def resolve_atomic_request(case: dict[str, Any], cases: dict[str, dict[str, Any]]) -> dict[str, Any]:
    if "request" in case:
        return case["request"]
    source_id = case.get("request_from") or case.get("replay_of")
    if not isinstance(source_id, str) or source_id not in cases:
        fail(f"{case['case_id']}: missing resolvable request source")
    return resolve_atomic_request(cases[source_id], cases)


def verify_atomic_vectors(
    protocol: dict[str, Any], schema: dict[str, Any], canonical_digest: str
) -> int:
    suite = require_object(
        load_json(CONTRACT_DIR / "conformance_vectors" / "atomic-structure-commit.json"),
        "atomic-structure-commit.json",
    )
    if suite.get("contract_version") != protocol["contract_version"]:
        fail("atomic conformance contract version differs from protocol")
    cases = {item["case_id"]: item for item in suite.get("cases", [])}
    if set(cases) != EXPECTED_ATOMIC_CASE_IDS or len(cases) != len(suite.get("cases", [])):
        fail("atomic conformance case ID set mismatch")
    protocol_three = next(item for item in protocol["supported_protocol_versions"] if item["version"] == 3)
    required_caps = set(protocol_three["required_client_capabilities"])
    for case_id, case in cases.items():
        request = resolve_atomic_request(case, cases)
        response = case["response"]
        validate_instance(request, schema, f"{case_id}/request")
        validate_instance(response, schema, f"{case_id}/response")
        batch = request["batch"]
        intents = request["ordered_intents"]
        if batch["canonical_contract_sha256"] != canonical_digest:
            fail(f"{case_id}: request does not pin the lock digest")
        if set(batch["client_capabilities"]) != required_caps:
            fail(f"{case_id}: atomic request capability set differs from protocol 3")
        sequences = [intent["sequence"] for intent in intents]
        if sequences != list(range(1, len(intents) + 1)):
            fail(f"{case_id}: ordered intent sequence is not contiguous")
        if any(intent["batch_id"] != batch["batch_id"] for intent in intents):
            fail(f"{case_id}: intent batch_id differs from request batch")
        for intent in intents:
            digest = hashlib.sha256(rfc8785.dumps(intent["payload"])).hexdigest()
            if digest != intent["payload_sha256"]:
                fail(f"{case_id}: intent {intent['sequence']} payload digest mismatch")
        batch_digest = hashlib.sha256(rfc8785.dumps(intents)).hexdigest()
        if batch_digest != batch["batch_payload_sha256"]:
            fail(f"{case_id}: batch payload digest mismatch")
        if response["batch_id"] != batch["batch_id"]:
            fail(f"{case_id}: response batch_id mismatch")
        if response["batch_payload_sha256"] != batch["batch_payload_sha256"]:
            fail(f"{case_id}: response batch digest mismatch")
        if response["applied"]:
            result_sequences = [item["sequence"] for item in response["results"]]
            if result_sequences != sequences:
                fail(f"{case_id}: success results do not cover ordered intents")
        elif response["results"]:
            fail(f"{case_id}: failure contains partial success results")
    if cases["ASC-002"]["response"]["status"] != "replayed":
        fail("ASC-002 must define identical replay")
    if cases["ASC-003"]["expected_semantics"] != "rollback_all":
        fail("ASC-003 must define complete rollback")
    if cases["ASC-004"]["response"]["error"]["code"] != "BATCH_ID_REUSED":
        fail("ASC-004 must reject changed replay payload")
    return len(cases)


def verify_document_vectors(
    protocol: dict[str, Any],
    schema: dict[str, Any],
    canonical_digest: str,
    versions: dict[int, dict[str, Any]],
) -> int:
    suite = require_object(
        load_json(CONTRACT_DIR / "conformance_vectors" / "document-commit.json"),
        "document-commit.json",
    )
    if suite.get("contract_version") != protocol["contract_version"]:
        fail("document conformance contract version differs from protocol")
    cases = {item["case_id"]: item for item in suite.get("cases", [])}
    if set(cases) != EXPECTED_DOCUMENT_CASE_IDS or len(cases) != len(suite.get("cases", [])):
        fail("document conformance case ID set mismatch")

    required_caps = set(versions[3]["required_client_capabilities"])
    for case_id, case in cases.items():
        request = resolve_atomic_request(case, cases)
        response = case["response"]
        validate_instance(request, schema, f"{case_id}/request")
        validate_instance(response, schema, f"{case_id}/response")
        batch = request["batch"]
        intents = request["ordered_intents"]
        intent = intents[0]
        payload = intent["payload"]

        if batch["canonical_contract_sha256"] != canonical_digest:
            fail(f"{case_id}: document request does not pin the lock digest")
        if set(batch["client_capabilities"]) != required_caps:
            fail(f"{case_id}: document request capability set differs from protocol 3")
        if intent["batch_id"] != batch["batch_id"]:
            fail(f"{case_id}: document intent batch_id differs from request batch")
        payload_digest = hashlib.sha256(rfc8785.dumps(payload)).hexdigest()
        if payload_digest != intent["payload_sha256"]:
            fail(f"{case_id}: document payload digest mismatch")
        batch_digest = hashlib.sha256(rfc8785.dumps(intents)).hexdigest()
        if batch_digest != batch["batch_payload_sha256"]:
            fail(f"{case_id}: document batch payload digest mismatch")

        content_bytes = payload["content"].encode("utf-8")
        if len(content_bytes) != payload["content_byte_count"]:
            fail(f"{case_id}: document content byte count mismatch")
        if len(content_bytes) > protocol["document_commit"]["content_limit_bytes"]:
            fail(f"{case_id}: document content exceeds the contract limit")
        if hashlib.sha256(content_bytes).hexdigest() != payload["content_sha256"]:
            fail(f"{case_id}: document content digest mismatch")
        normalized, name_error = normalize_storage_name(payload["name"])
        if name_error is not None or normalized is None:
            fail(f"{case_id}: document name violates storage-name-v1: {name_error}")

        if response["batch_id"] != batch["batch_id"]:
            fail(f"{case_id}: document response batch_id mismatch")
        if response["batch_payload_sha256"] != batch["batch_payload_sha256"]:
            fail(f"{case_id}: document response batch digest mismatch")
        if response["applied"]:
            result = response["results"][0]
            expected_result_fields = {
                "sequence": intent["sequence"],
                "operation_id": intent["operation_id"],
                "document_id": intent["document_id"],
                "structure_revision": payload["structure_revision"],
                "parent_folder_id": payload["parent_folder_id"],
                "name": payload["name"],
                "content_sha256": payload["content_sha256"],
                "content_byte_count": payload["content_byte_count"],
                "is_deleted": payload["is_deleted"],
            }
            for key, expected in expected_result_fields.items():
                if result[key] != expected:
                    fail(f"{case_id}: document result {key} mismatch")
        elif response["results"]:
            fail(f"{case_id}: document failure contains a partial result")

    if cases["DC-001"]["expected_semantics"] != "intentional_empty_committed":
        fail("DC-001 must define intentional empty content")
    if resolve_atomic_request(cases["DC-001"], cases)["ordered_intents"][0]["payload"]["content"] != "":
        fail("DC-001 content must be exactly empty")
    if cases["DC-002"]["response"]["status"] != "replayed":
        fail("DC-002 must define identical replay after response loss or restart")
    if cases["DC-005"]["expected_semantics"] != "rollback_all":
        fail("DC-005 must define complete rollback")
    if cases["DC-006"]["response"]["error"]["code"] != "BATCH_ID_REUSED":
        fail("DC-006 must reject changed replay payload")
    if resolve_atomic_request(cases["DC-004"], cases)["ordered_intents"][0]["intent_kind"] != "delete":
        fail("DC-004 must define document deletion")
    if resolve_atomic_request(cases["DC-007"], cases)["ordered_intents"][0]["intent_kind"] != "restore":
        fail("DC-007 must define document restoration")
    return len(cases)


def verify_legacy_boundary(protocol: dict[str, Any]) -> None:
    modes = protocol["project_sync_mode"]
    if modes["automatic_promotion"] or modes["automatic_downgrade"]:
        fail("project mode changes must never be automatic")
    legacy = protocol["legacy_migration"]
    defaults = legacy["default_for_existing_projects"]
    if defaults != {
        "project_sync_mode": "LEGACY",
        "migration_epoch": 0,
        "contract_enforcement_started_at": None,
    }:
        fail("existing project defaults must be honest LEGACY epoch 0 provenance")
    for mode in ("MIGRATING", "ID_BASED"):
        minimum = protocol["minimum_write_protocol"][mode]
        if minimum != {"content": 3, "structure": 3}:
            fail(f"{mode} must require protocol 3 for all writes")
    required_phrases = ("MUST NOT invent", "manual", "Every later write requires protocol 3")
    legacy_text = " ".join(str(value) for value in legacy.values())
    for phrase in required_phrases:
        if phrase not in legacy_text:
            fail(f"legacy migration rule lacks normative phrase: {phrase}")


def verify_traceability() -> None:
    path = CONTRACT_DIR / "TRACEABILITY.md"
    if not path.exists():
        fail("TRACEABILITY.md is required")
    text = path.read_text(encoding="utf-8")
    for blocker in range(1, 8):
        identifier = f"C-{blocker:02d}"
        if identifier not in text:
            fail(f"TRACEABILITY.md lacks {identifier}")
    for heading in ("Normative text", "Schema", "Vector", "Verifier"):
        if heading not in text:
            fail(f"TRACEABILITY.md lacks {heading} column")


def main() -> None:
    schemas: dict[str, Any] = {}
    for path in sorted(CONTRACT_DIR.glob("*.schema.json")):
        schema = load_json(path)
        Draft202012Validator.check_schema(schema)
        schemas[path.name] = schema
    if set(schemas) != REQUIRED_SCHEMAS:
        fail(f"schema set mismatch: expected {sorted(REQUIRED_SCHEMAS)}, got {sorted(schemas)}")

    protocol = require_object(load_json(CONTRACT_DIR / "protocol.json"), "protocol.json")
    validate_instance(protocol, schemas["protocol.schema.json"], "protocol.json")
    versions = verify_capability_matrix(protocol)
    verify_legacy_boundary(protocol)

    lock = require_object(load_json(CONTRACT_DIR / "contract-lock.json"), "contract-lock.json")
    if protocol["contract_version"] != lock.get("contract_version"):
        fail("contract version differs between protocol.json and contract-lock.json")
    canonical_bytes = rfc8785.dumps(protocol)
    canonical_digest = hashlib.sha256(canonical_bytes).hexdigest()
    if len(canonical_bytes) != lock.get("canonical_byte_length"):
        fail(
            f"canonical byte length mismatch: expected {lock.get('canonical_byte_length')}, "
            f"got {len(canonical_bytes)}"
        )
    if canonical_digest != lock.get("canonical_contract_sha256"):
        fail(
            f"canonical digest mismatch: expected {lock.get('canonical_contract_sha256')}, "
            f"got {canonical_digest}"
        )

    vector_ids: set[str] = set()
    vectors: list[dict[str, Any]] = []
    vector_paths = sorted((CONTRACT_DIR / "test_vectors").glob("*.json"))
    for path in vector_paths:
        vector = require_object(load_json(path), path.name)
        validate_instance(vector, schemas["transition-vector.schema.json"], path.name)
        if vector["contract_version"] != protocol["contract_version"]:
            fail(f"{path.name}: contract_version differs from protocol.json")
        if vector["vector_id"] in vector_ids:
            fail(f"duplicate vector_id: {vector['vector_id']}")
        vector_ids.add(vector["vector_id"])
        verify_vector_semantics(vector, protocol, versions, path.name)
        vectors.append(vector)
    if vector_ids != EXPECTED_VECTOR_IDS:
        fail(f"transition vector set mismatch: got {sorted(vector_ids)}")
    verify_state_model(protocol, vectors)

    storage_count = verify_storage_vectors(protocol, schemas["storage-name-vectors.schema.json"])
    atomic_count = verify_atomic_vectors(
        protocol, schemas["atomic-structure-commit.schema.json"], canonical_digest
    )
    document_count = verify_document_vectors(
        protocol, schemas["document-commit.schema.json"], canonical_digest, versions
    )
    verify_traceability()

    expected_counts = {
        "schema_count": len(schemas),
        "transition_vector_count": len(vector_paths),
        "storage_name_vector_count": storage_count,
        "atomic_wire_case_count": atomic_count,
        "document_wire_case_count": document_count,
    }
    for key, actual in expected_counts.items():
        if lock.get(key) != actual:
            fail(f"contract-lock {key} mismatch: expected {lock.get(key)}, got {actual}")

    print(f"Validated {len(schemas)} JSON schemas.")
    print(f"Validated released protocol contract {protocol['contract_version']}.")
    print(f"Validated {len(vector_paths)} transition vectors with cross-file semantics.")
    print(f"Validated {storage_count} storage-name conformance vectors (Unicode {unicodedata.unidata_version}).")
    print(f"Validated {atomic_count} atomic wire conformance cases.")
    print(f"Validated {document_count} document wire conformance cases.")
    print("Validated capability versions, operation creation, state derivation, batch provenance, immutable rebase, and legacy enforcement.")
    print(f"Canonical protocol bytes: {len(canonical_bytes)}")
    print(f"Canonical SHA-256: {canonical_digest}")


if __name__ == "__main__":
    main()
