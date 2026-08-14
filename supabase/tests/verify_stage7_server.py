#!/usr/bin/env python3
"""Static and cross-file checks for the released Supabase server chain."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_DIR = ROOT / "sync-contract"
MIGRATIONS = ROOT / "supabase" / "migrations"

VERSION = "0.3.0"
CONTRACT_GIT_COMMIT = "2705fcbda0be440a9d82a5e1919f2885c6166727"
CONTRACT_CONTENT_COMMIT = "3843b05aa91461e1541f5ebaa14557dc3dc2b39c"
DIGEST = "abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c"
CANONICAL_BYTES = 24777
BASELINE_NAME = "20260811000000_operational_v2_schema_baseline_snapshot.sql"
FOUNDATION_NAME = "20260811010000_sync_contract_0_1_0_foundation.sql"
RPC_NAME = "20260811020000_sync_contract_0_1_0_rpcs.sql"
STORAGE_V2_NAME = "20260813063251_sync_contract_0_3_0_storage_name_v2.sql"
CORRECTIVE_NAME = "20260814182850_rpc_auth_error_envelope_corrective.sql"
SOURCE_CATALOG_DIGEST = (
    "6c71ff36a90993dc327557b4a1a64c0dfb27b347134ed89e7f126dae76c6ff9a"
)
IMMUTABLE_MIGRATION_DIGESTS = {
    BASELINE_NAME: "323c6e092cd9afabb438eaf233b7e63abd0195d5e1a91a5f5fe3fe5940699198",
    FOUNDATION_NAME: "5374b61f270541ae3f40717269c82e3f60949889254d1cdaaaee94ffa99aa70d",
    RPC_NAME: "60775ced603122aae2f4a53a7cfaf39299676c647b839feaf9527210ec514b46",
    STORAGE_V2_NAME: "77b3e4ca9537d42207cb16b407be4490adc1cda4dbf2054316cc8f775139c66a",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def load_json(path: pathlib.Path):
    return json.loads(path.read_text(encoding="utf-8"))


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    lock = load_json(CONTRACT_DIR / "contract-lock.json")
    protocol = load_json(CONTRACT_DIR / "protocol.json")
    require(lock["contract_version"] == VERSION, "contract version pin mismatch")
    require(protocol["contract_version"] == VERSION, "protocol version pin mismatch")
    require(lock["canonical_byte_length"] == CANONICAL_BYTES, "canonical byte pin mismatch")
    require(lock["canonical_contract_sha256"] == DIGEST, "contract digest pin mismatch")

    sql_paths = sorted(MIGRATIONS.glob("*.sql"))
    require(
        [path.name for path in sql_paths]
        == [BASELINE_NAME, FOUNDATION_NAME, RPC_NAME, STORAGE_V2_NAME, CORRECTIVE_NAME],
        "the server chain must end with the additive auth-envelope corrective migration",
    )
    for name, expected in IMMUTABLE_MIGRATION_DIGESTS.items():
        require(sha256(MIGRATIONS / name) == expected, f"historical migration changed: {name}")

    sql = "\n".join(path.read_text(encoding="utf-8") for path in sql_paths)
    baseline = (MIGRATIONS / BASELINE_NAME).read_text(encoding="utf-8")
    storage_v2 = (MIGRATIONS / STORAGE_V2_NAME).read_text(encoding="utf-8")
    corrective = (MIGRATIONS / CORRECTIVE_NAME).read_text(encoding="utf-8")

    for marker in (
        "purpose: bootstrap blank staging/new environment",
        "historical_migration_replay: false",
        "production_execution: forbidden",
        "production_reconciliation_required: true",
        "source_catalog_project: redacted",
        f"source_catalog_snapshot_sha256: {SOURCE_CATALOG_DIGEST}",
        "BASELINE_SNAPSHOT_REQUIRES_EMPTY_APP_SCHEMA",
    ):
        require(marker in baseline, f"baseline snapshot safety marker missing: {marker}")

    for forbidden in ("isotfvmlklrxspusjpcn", "supabase.co", "service_role_key", "postgresql://"):
        require(forbidden not in baseline.lower(), f"baseline leaks forbidden value: {forbidden}")

    for required_baseline_object in (
        "public.projects", "public.project_members", "public.documents",
        "public.document_versions", "public.edit_leases", "public.folders",
        "public.folder_versions", "private.project_purge_tombstones",
        "private.has_project_role", "p.trashed_at is null", "public.commit_folder",
        "public.trash_project", "public.restore_project", "public.purge_project",
        "supabase_realtime",
    ):
        require(required_baseline_object in baseline,
                f"operational snapshot object missing: {required_baseline_object}")

    for value in (VERSION, CONTRACT_GIT_COMMIT, CONTRACT_CONTENT_COMMIT, DIGEST,
                  str(CANONICAL_BYTES)):
        require(value in storage_v2, f"missing 0.3.0 pin in storage-name-v2 migration: {value}")

    for name in (
        "sync_contract_allowlist", "project_sync_settings", "project_sync_migrations",
        "sync_batches", "sync_operations", "sync_operation_attempts",
        "sync_operation_events", "sync_batch_results", "tree_orders",
        "atomic_structure_commit", "document_commit", "cancel_sync_operation",
        "begin_project_sync_migration", "validate_project_sync_migration",
        "complete_project_sync_migration", "storage_name_v1", "storage_name_v2",
        "storage_name_v2_assigned_ranges", "storage_name_v2_excluded_ranges",
        "storage_name_v2_casefold", "storage_name_v2_nonzero_ccc",
    ):
        require(name in sql, f"missing server object: {name}")

    for marker in (
        "atomic_structure_commit_legacy",
        "document_commit_legacy",
        "AUTH_REQUIRED",
        "FORBIDDEN",
        "grant execute on function public.atomic_structure_commit(jsonb)",
        "grant execute on function public.document_commit(jsonb)",
        "to anon, authenticated",
        "set search_path = ''",
    ):
        require(marker in corrective, f"auth-envelope corrective guard missing: {marker}")
    require(
        "from public, anon, authenticated" in corrective,
        "legacy RPC entry points must not remain callable by client roles",
    )

    for guard in (
        "LEGACY_EPOCH_0", "CONTRACT_BATCH", "CONTRACT_NOT_ALLOWED",
        "CONTRACT_DIGEST_MISMATCH", "PROTOCOL_TOO_OLD", "CAPABILITY_MISMATCH",
        "BATCH_ID_REUSED", "OPERATION_ID_REUSED", "EVENT_ID_REUSED",
        "OPERATION_TERMINAL", "STORAGE_NAME_INVALID", "STORAGE_NAME_RESERVED",
        "STORAGE_NAME_UNASSIGNED", "STORAGE_NAME_UNSUPPORTED_SCALAR",
        "CONTENT_DIGEST_MISMATCH", "CONTENT_SIZE_MISMATCH",
        "STRUCTURE_REVISION_CONFLICT", "MIGRATION_LOCKED", "STALE_MIGRATION_EPOCH",
    ):
        require(guard in sql, f"missing contract guard: {guard}")

    require("project_sync_mode = 'LEGACY'" in sql,
            "row absence and legacy mode must remain the default boundary")
    require("enabled boolean not null default false" in sql.lower(),
            "released contract allowlist must default disabled")
    require("false\n)\non conflict (canonical_contract_sha256) do nothing;" in storage_v2,
            "0.3.0 allowlist row must be installed disabled")
    require("reject_append_only_mutation" in storage_v2,
            "frozen server tables need immutable mutation triggers")
    require("writerpad.contract_sha256" in storage_v2,
            "validated batch digest must select storage-name behavior transaction-locally")
    require("storage_name_v1_legacy" in storage_v2,
            "historical storage-name-v1 compatibility implementation is not preserved")
    require("pg_catalog.normalize(" not in sql,
            "NORMALIZE special syntax must not be schema-qualified")
    require(sql.count("normalize(v_assigned_buffer, NFKC)") == 2,
            "historical Unicode 15 NFKC implementation changed")
    require(storage_v2.count("normalize(p_name, NFKC)") == 1
            and storage_v2.count("normalize(v_folded, NFKC)") == 1,
            "storage-name-v2 must perform NFKC/casefold/NFKC")
    require(storage_v2.index("if v_character in ('/', E'\\\\')") < storage_v2.index(
        "Defensive post-NFKC baseline recheck"),
        "post-NFKC separator check must precede the defensive baseline recheck")

    generator = ROOT / "supabase" / "scripts" / "generate_casefold_sql.py"
    subprocess.run(
        [sys.executable, str(generator), "--check", str(MIGRATIONS / FOUNDATION_NAME)],
        check=True,
    )
    subprocess.run(
        [sys.executable, str(generator), "--check-v2", str(MIGRATIONS / STORAGE_V2_NAME)],
        check=True,
    )

    print(f"Server static checks passed ({len(sql_paths)} migrations)")
    print(f"contract: {VERSION} {DIGEST}")
    print(f"operational catalog: {SOURCE_CATALOG_DIGEST}")
    for name, expected in IMMUTABLE_MIGRATION_DIGESTS.items():
        print(f"immutable migration: {name} {expected}")
    print(f"storage-name-v2 migration sha256: {sha256(MIGRATIONS / STORAGE_V2_NAME)}")
    print(f"Unicode SQL generator sha256: {sha256(generator)}")


if __name__ == "__main__":
    main()
