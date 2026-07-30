#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

schema="Scripts/fixtures/SyncV2StoreSchemaV1.sql"
design="Docs/SyncV2StoreDesign.md"
swiftdata_schema="WriterPad/Data/Local/WriterPadMetadataSchema.swift"

fail() {
    echo "8-4 store design audit failed: $1" >&2
    exit 1
}

for table in schema_migrations sync_projects sync_documents sync_batches \
    sync_operations sync_conflicts; do
    rg -q "CREATE TABLE $table" "$schema" \
        || fail "schema table $table is absent"
done

for column in local_project_id server_project_id binding_kind owner_subject \
    server_revision base_content base_hash server_updated_at sync_state \
    last_error_code queue_id operation_id device_id document_sequence \
    base_revision relative_path content content_byte_count is_deleted status \
    attempts next_attempt_at conflict_id remote_content merged_content \
    remote_revision conflict_count resolved_at; do
    rg -q "\\b$column\\b" "$schema" \
        || fail "required schema field $column is absent"
done

for pragma in \
    'PRAGMA foreign_keys = ON' \
    'PRAGMA journal_mode = WAL' \
    'PRAGMA synchronous = FULL' \
    'PRAGMA user_version = 1'; do
    rg -F -q "$pragma" "$schema" \
        || fail "required setting is absent: $pragma"
done

for policy in \
    'SwiftData V1에는 server revision' \
    'SQLite backup API' \
    'localSavedButNotQueued' \
    'CONTENT_TOO_LARGE' \
    '사용자 확인 없이 빈 DB로 교체' \
    '하나의 `SyncV2Store` actor'; do
    rg -F -q "$policy" "$design" \
        || fail "design policy is absent: $policy"
done

rg -q 'Schema\.Version\(1, 0, 0\)' "$swiftdata_schema" \
    || fail "WriterPadSchemaV1 is no longer version 1.0.0"
if rg -q 'serverRevision|baseContent|operationID|leaseToken|deviceID' \
    "$swiftdata_schema"; then
    fail "server state leaked into SwiftData V1"
fi

if rg -q 'SQLite3|GRDB|SyncV2Store' WriterPad --glob '*.swift'; then
    fail "a SyncV2 SQLite implementation was added to the app during design-only 8-4"
fi

echo "8-4 store design audit passed: schema fixture and isolation policies are intact."
