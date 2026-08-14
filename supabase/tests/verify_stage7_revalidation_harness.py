#!/usr/bin/env python3
"""Static safety checks for the exact Stage 7 staging revalidation harness."""

from __future__ import annotations

import hashlib
import pathlib
import re


ROOT = pathlib.Path(__file__).resolve().parents[2]
HARNESS = ROOT / "supabase" / "tests" / "stage7_staging_revalidation_harness.sql"
HELPERS = ROOT / "supabase" / "tests" / "stage7_revalidation_fingerprint_helpers.sql"
WORKFLOW = ROOT / ".github" / "workflows" / "server-contract-run.yml"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    harness = HARNESS.read_text(encoding="utf-8")
    helpers = HELPERS.read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")
    lowered = harness.lower()

    require("\\set ON_ERROR_STOP on" in harness, "harness must fail fast")
    require(
        "\\connect -reuse-previous=on" in harness,
        "harness must use a real second PostgreSQL connection",
    )
    require(
        "set plpgsql.variable_conflict = error;" in harness,
        "harness must reject PL/pgSQL variable/column ambiguity",
    )
    require(
        "do $" not in lowered and "\ndeclare\n" not in lowered,
        "main harness must remain declarative and contain no PL/pgSQL DO variables",
    )
    ordered_sections = (
        "A real second connection proves the contract pin is transaction-local.",
        "All persistent functional cases share one transaction.",
        "original response could have been lost.",
        "Canonical AUTH_REQUIRED envelopes through the anon role.",
        "final Stage 7 harness audit mismatch",
    )
    section_offsets = [harness.index(marker) for marker in ordered_sections]
    require(
        section_offsets == sorted(section_offsets),
        "route reset, functional transaction, replay, auth, and final audit are out of order",
    )
    require(
        re.search(r"\b([a-z_][a-z0-9_]*)\s*=\s*\1\b", lowered) is None,
        "self-comparison pattern can hide a variable/column collision",
    )
    require(
        re.search(r"\b(content|name|revision)\s*=\s*(content|name|revision)\b", lowered)
        is None,
        "unqualified application-column comparison is forbidden",
    )

    for required_variable in (
        "test_run_id",
        "server_project_id",
        "client_build_id",
        "owner_user_id",
        "unauthorized_user_id",
        "existing_fixture_project_id",
        "expected_existing_fixture_fingerprint",
    ):
        require(
            f"missing required psql variable: {required_variable}" in harness,
            f"required input guard missing: {required_variable}",
        )

    for marker in (
        "CONTRACT_DIGEST_MISMATCH",
        "CAPABILITY_MISMATCH",
        "STORAGE_NAME_UNSUPPORTED_SCALAR",
        "document_commit_success",
        "atomic_structure_commit_success",
        "BATCH_ID_REUSED",
        "TREE_REFERENCE_NOT_FOUND",
        "response-loss replay",
        "AUTH_REQUIRED",
        "FORBIDDEN",
        "unauthorized_persistent_writes",
        "SN-001",
        "SN-029",
        "supplementary adjacency",
        "post-NFKC separator rejection",
        "project_sync_settings",
        "project_sync_migrations",
        "existing_fixture_fingerprint",
        "new_fixture_fingerprint",
    ):
        require(marker in harness, f"required Stage 7 assertion missing: {marker}")

    require(
        harness.count("\\quit 1") >= 18,
        "every functional boundary must retain an explicit fail-fast exit",
    )
    require(
        "update private.sync_contract_allowlist" not in lowered,
        "exact harness must not activate or deactivate the allowlist",
    )
    for forbidden in (
        "mhpnszcorfzrvhyondxr",
        "supabase.co",
        "service_role",
        "postgresql://",
        "8a7ce979-6f3f-4c88-b89b-e664df03fbdc",
        "0cafa16f-aa12-444b-91f6-ca8282b12996",
        "c1b0cdf5-ee14-4794-a11f-b5576dd0744d",
    ):
        require(forbidden not in lowered, f"harness contains forbidden remote value: {forbidden}")

    require(
        helpers.count("#variable_conflict error") == 3,
        "every PL/pgSQL fingerprint helper must reject ambiguous references",
    )
    require(
        "create or replace function pg_temp." in helpers,
        "fingerprint helpers must remain session-local",
    )
    require(
        "create or replace function public." not in helpers.lower()
        and "create or replace function private." not in helpers.lower(),
        "fingerprint helpers must not create persistent functions",
    )
    require(
        "pg_catalog.coalesce(" not in (lowered + helpers.lower()),
        "COALESCE is special syntax and must not be schema-qualified",
    )

    for marker in (
        "image: postgres:17.6",
        "verify_stage7_revalidation_harness.py",
        "stage7_staging_revalidation_harness.sql",
        "expected_existing_fixture_fingerprint=capture",
    ):
        require(marker in workflow, f"PostgreSQL 17.6 CI harness marker missing: {marker}")

    print("Stage 7 revalidation harness static checks passed")
    print(f"harness sha256: {sha256(HARNESS)}")
    print(f"fingerprint helpers sha256: {sha256(HELPERS)}")


if __name__ == "__main__":
    main()
