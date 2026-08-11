#!/usr/bin/env python3
"""Static and cross-file checks for the Stage 7 Supabase implementation."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_DIR = ROOT / "sync-contract"
MIGRATIONS = ROOT / "supabase" / "migrations"

VERSION = "0.2.0"
CONTRACT_GIT_COMMIT = "fcd99b7098b9a04bd93c585d89b16588aa482530"
CONTRACT_CONTENT_COMMIT = "7bcb5d25c5376b02469666df7318b90b456ffee6"
DIGEST = "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"
CANONICAL_BYTES = 23256


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def load_json(path: pathlib.Path):
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    lock = load_json(CONTRACT_DIR / "contract-lock.json")
    protocol = load_json(CONTRACT_DIR / "protocol.json")
    require(lock["contract_version"] == VERSION, "contract version pin mismatch")
    require(protocol["contract_version"] == VERSION, "protocol version pin mismatch")
    require(lock["canonical_byte_length"] == CANONICAL_BYTES, "canonical byte pin mismatch")
    require(lock["canonical_contract_sha256"] == DIGEST, "contract digest pin mismatch")

    sql_paths = sorted(MIGRATIONS.glob("*.sql"))
    require(len(sql_paths) >= 2, "Stage 7 foundation and RPC migrations are required")
    sql = "\n".join(path.read_text(encoding="utf-8") for path in sql_paths)

    for value in (
        VERSION,
        CONTRACT_GIT_COMMIT,
        CONTRACT_CONTENT_COMMIT,
        DIGEST,
        str(CANONICAL_BYTES),
    ):
        require(value in sql, f"missing Stage 6 pin in migrations: {value}")

    required_objects = (
        "sync_contract_allowlist",
        "project_sync_settings",
        "project_sync_migrations",
        "sync_batches",
        "sync_operations",
        "sync_operation_attempts",
        "sync_operation_events",
        "sync_batch_results",
        "tree_orders",
        "atomic_structure_commit",
        "document_commit",
        "cancel_sync_operation",
        "begin_project_sync_migration",
        "validate_project_sync_migration",
        "complete_project_sync_migration",
        "storage_name_v1",
    )
    for name in required_objects:
        require(name in sql, f"missing Stage 7 server object: {name}")

    required_guards = (
        "LEGACY_EPOCH_0",
        "CONTRACT_BATCH",
        "CONTRACT_NOT_ALLOWED",
        "CONTRACT_DIGEST_MISMATCH",
        "PROTOCOL_TOO_OLD",
        "CAPABILITY_MISMATCH",
        "BATCH_ID_REUSED",
        "OPERATION_ID_REUSED",
        "EVENT_ID_REUSED",
        "OPERATION_TERMINAL",
        "STORAGE_NAME_INVALID",
        "STORAGE_NAME_RESERVED",
        "CONTENT_DIGEST_MISMATCH",
        "CONTENT_SIZE_MISMATCH",
        "STRUCTURE_REVISION_CONFLICT",
        "MIGRATION_LOCKED",
        "STALE_MIGRATION_EPOCH",
    )
    for guard in required_guards:
        require(guard in sql, f"missing contract guard: {guard}")

    require("begin_project_sync_migration" in sql and "complete_project_sync_migration" in sql,
            "manual migration boundary must be explicit")
    require("project_sync_mode = 'LEGACY'" in sql,
            "row absence and legacy mode must remain the default boundary")
    require("enabled boolean not null default false" in sql.lower(),
            "released contract allowlist must be installed disabled")
    require("reject_append_only_mutation" in sql,
            "append-only ledgers need mutation triggers")
    require("supersedes_operation_id" in sql,
            "immutable rebase relationship is missing")
    require("create or replace function public.document_commit(p_request jsonb)" in sql,
            "normative protocol 3 document_commit RPC is missing")
    require("structure_revision" in sql and "document_relative_path" in sql,
            "document structure barrier implementation is missing")
    require("pg_catalog.normalize(" not in sql,
            "NORMALIZE special syntax must not be schema-qualified")
    require(sql.count("normalize(v_assigned_buffer, NFKC)") == 2,
            "Unicode 15 NFKC normalization calls are missing or malformed")

    generator = ROOT / "supabase" / "scripts" / "generate_casefold_sql.py"
    generator_sha = hashlib.sha256(generator.read_bytes()).hexdigest()
    print(f"Stage 7 static checks passed ({len(sql_paths)} migrations)")
    print(f"contract: {VERSION} {DIGEST}")
    print(f"casefold generator sha256: {generator_sha}")


if __name__ == "__main__":
    main()
