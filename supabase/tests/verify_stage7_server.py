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
WORKFLOW = ROOT / ".github" / "workflows" / "server-contract-run.yml"

CLIENT_VERSION = "0.2.0"
CLIENT_DIGEST = "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"
CLIENT_CANONICAL_BYTES = 23256
SERVER_VERSION = "0.3.0"
SERVER_CONTRACT_GIT_COMMIT = "2705fcbda0be440a9d82a5e1919f2885c6166727"
SERVER_CONTRACT_CONTENT_COMMIT = "3843b05aa91461e1541f5ebaa14557dc3dc2b39c"
SERVER_DIGEST = "abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c"
SERVER_CANONICAL_BYTES = 24777
BASELINE_NAME = "20260811000000_operational_v2_schema_baseline_snapshot.sql"
FOUNDATION_NAME = "20260811010000_sync_contract_0_1_0_foundation.sql"
RPC_NAME = "20260811020000_sync_contract_0_1_0_rpcs.sql"
STORAGE_V2_NAME = "20260813063251_sync_contract_0_3_0_storage_name_v2.sql"
CORRECTIVE_NAME = "20260814182850_rpc_auth_error_envelope_corrective.sql"
HANDSHAKE_NAME = "20260820113209_authenticated_sync_handshake.sql"
RESTORE_HANDSHAKE_NAME = "20260825000000_restore_deployed_sync_handshake.sql"
TRASH_PURGE_NAME = "20260910053721_general_contract_trash_purge.sql"
CONTROL_DOCUMENTS_NAME = "20260910072310_contract_migration_control_documents.sql"
SECURITY_HARDENING_NAME = "20260921125202_harden_legacy_function_privileges.sql"
SOURCE_CATALOG_DIGEST = (
    "6c71ff36a90993dc327557b4a1a64c0dfb27b347134ed89e7f126dae76c6ff9a"
)
IMMUTABLE_MIGRATION_DIGESTS = {
    BASELINE_NAME: "323c6e092cd9afabb438eaf233b7e63abd0195d5e1a91a5f5fe3fe5940699198",
    FOUNDATION_NAME: "5374b61f270541ae3f40717269c82e3f60949889254d1cdaaaee94ffa99aa70d",
    RPC_NAME: "60775ced603122aae2f4a53a7cfaf39299676c647b839feaf9527210ec514b46",
    STORAGE_V2_NAME: "77b3e4ca9537d42207cb16b407be4490adc1cda4dbf2054316cc8f775139c66a",
    RESTORE_HANDSHAKE_NAME: (
        "48c7b34749687851a233ffe2683b938347c311ff7c4c19ddefa2b74faf349fd4"
    ),
    TRASH_PURGE_NAME: "d26bea7678028e50cbbafa1d871923918f84baa63ab061bc92db8cc3844592e4",
    CONTROL_DOCUMENTS_NAME: (
        "81ccd40b3d5dec672e4d287c1e278155500ef539f626a90d0b71336646cf69a3"
    ),
    SECURITY_HARDENING_NAME: (
        "cc5a914d9fe0fe1c3f0067a8c41fb1bf9ec129a5e7cedb18fde7475450dc44c5"
    ),
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
    require(lock["contract_version"] == CLIENT_VERSION, "client contract version pin mismatch")
    require(protocol["contract_version"] == CLIENT_VERSION, "client protocol version pin mismatch")
    require(
        lock["canonical_byte_length"] == CLIENT_CANONICAL_BYTES,
        "client canonical byte pin mismatch",
    )
    require(
        lock["canonical_contract_sha256"] == CLIENT_DIGEST,
        "client contract digest pin mismatch",
    )

    sql_paths = sorted(MIGRATIONS.glob("*.sql"))
    require(
        [path.name for path in sql_paths]
        == [BASELINE_NAME, FOUNDATION_NAME, RPC_NAME, STORAGE_V2_NAME,
            CORRECTIVE_NAME, HANDSHAKE_NAME, RESTORE_HANDSHAKE_NAME,
            TRASH_PURGE_NAME, CONTROL_DOCUMENTS_NAME, SECURITY_HARDENING_NAME],
        "the server chain must match the exact reviewed migration order",
    )
    for name, expected in IMMUTABLE_MIGRATION_DIGESTS.items():
        require(sha256(MIGRATIONS / name) == expected, f"historical migration changed: {name}")

    sql = "\n".join(path.read_text(encoding="utf-8") for path in sql_paths)
    baseline = (MIGRATIONS / BASELINE_NAME).read_text(encoding="utf-8")
    storage_v2 = (MIGRATIONS / STORAGE_V2_NAME).read_text(encoding="utf-8")
    corrective = (MIGRATIONS / CORRECTIVE_NAME).read_text(encoding="utf-8")
    handshake = (MIGRATIONS / HANDSHAKE_NAME).read_text(encoding="utf-8")
    restored_handshake = (
        MIGRATIONS / RESTORE_HANDSHAKE_NAME
    ).read_text(encoding="utf-8")
    trash_purge = (MIGRATIONS / TRASH_PURGE_NAME).read_text(encoding="utf-8")
    control_documents = (
        MIGRATIONS / CONTROL_DOCUMENTS_NAME
    ).read_text(encoding="utf-8")
    security_hardening = (
        MIGRATIONS / SECURITY_HARDENING_NAME
    ).read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")

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

    for value in (
        SERVER_VERSION,
        SERVER_CONTRACT_GIT_COMMIT,
        SERVER_CONTRACT_CONTENT_COMMIT,
        SERVER_DIGEST,
        str(SERVER_CANONICAL_BYTES),
    ):
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

    for marker in (
        "public.get_sync_handshake",
        "language plpgsql\nstable\nsecurity definer",
        "private.has_project_role(p_project_id, v_user_id, 'viewer')",
        "allowlist.enabled",
        "allowlist.revoked_at is null",
        "project_sync_mode",
        "migration_epoch",
        "server_protocol_version",
        "server_contract_sha256",
        "supported_protocol_versions",
        "server_capabilities",
        "grant execute on function public.get_sync_handshake(uuid, text)\n  to authenticated",
    ):
        require(marker in handshake, f"authenticated handshake guard missing: {marker}")
    require(
        "to anon, authenticated" not in handshake.split("grant execute", 1)[1],
        "anonymous callers must not receive private allowlist metadata",
    )

    normalized_restore = " ".join(
        restored_handshake.replace('"', "").lower().split()
    )
    for marker in (
        "create or replace function public.get_sync_handshake",
        "language plpgsql stable security definer",
        "set search_path to ''",
        "private.has_project_role(p_project_id, v_user_id, 'viewer')",
        "allowlist.enabled",
        "allowlist.revoked_at is null",
        "server_protocol_version",
        "server_contract_sha256",
        "supported_protocol_versions",
        "server_capabilities",
        "revoke all on function public.get_sync_handshake"
        "(p_project_id uuid, p_contract_sha256 text) from public",
        "grant all on function public.get_sync_handshake"
        "(p_project_id uuid, p_contract_sha256 text) to authenticated",
    ):
        require(marker in normalized_restore,
                f"deployed handshake restoration guard missing: {marker}")
    require(
        "to anon" not in normalized_restore,
        "deployed handshake restoration must not grant anonymous execution",
    )
    require(
        workflow.count(f"supabase/migrations/{RESTORE_HANDSHAKE_NAME}") == 4,
        "CI must apply and safely re-run the deployed handshake restoration",
    )

    for marker in (
        "private.apply_contract_trash_purge",
        "(v_payload->'version')::text is distinct from '1'",
        "v_marker.storage_name_key is not null",
        "private.enforce_document_write_boundary",
        "revoke all on function private.apply_contract_trash_purge",
    ):
        require(marker in trash_purge, f"trash-purge guard missing: {marker}")

    for marker in (
        "private.is_contract_migration_control_document",
        "__antigravity__/tree-order.json",
        "__antigravity__/trash-purge.json",
        "INVALID_CONTROL_DOCUMENT",
        "revoke all on function public.validate_project_sync_migration",
        "grant execute on function public.complete_project_sync_migration",
    ):
        require(marker in control_documents,
                f"migration-control guard missing: {marker}")

    for marker in (
        "RLS_AUTO_ENABLE_EVENT_TRIGGER_MISMATCH",
        "LEGACY_FUNCTION_HARDENING_PRIVILEGE_MISMATCH",
        "LEGACY_FUNCTION_HARDENING_CONFIG_MISMATCH",
        "PUBLIC_FUNCTION_DEFAULT_PRIVILEGE_MISMATCH",
        "alter function public.touch_editor_locks_locked_at()",
        "alter function public.touch_writing_contents_updated_at()",
        "set search_path = ''",
        "revoke all on function public.rls_auto_enable()",
        "alter default privileges for role postgres in schema public",
        "revoke execute on functions from public",
    ):
        require(marker in security_hardening,
                f"legacy function hardening guard missing: {marker}")
    require(
        "grant execute" not in security_hardening.lower(),
        "legacy function hardening must not widen execution privileges",
    )

    for name in (TRASH_PURGE_NAME, CONTROL_DOCUMENTS_NAME, SECURITY_HARDENING_NAME):
        require(
            workflow.count(f"supabase/migrations/{name}") == 4,
            f"CI must apply and safely re-run the reviewed migration: {name}",
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
    print(f"client contract: {CLIENT_VERSION} {CLIENT_DIGEST}")
    print(f"server storage contract: {SERVER_VERSION} {SERVER_DIGEST}")
    print(f"operational catalog: {SOURCE_CATALOG_DIGEST}")
    for name, expected in IMMUTABLE_MIGRATION_DIGESTS.items():
        print(f"immutable migration: {name} {expected}")
    print(f"storage-name-v2 migration sha256: {sha256(MIGRATIONS / STORAGE_V2_NAME)}")
    print(f"Unicode SQL generator sha256: {sha256(generator)}")


if __name__ == "__main__":
    main()
