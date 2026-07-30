#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
schema="$repository_root/Scripts/fixtures/SyncV2StoreSchemaV1.sql"
test_root=$(mktemp -d)
database="$test_root/sync-v2.sqlite3"
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fail() {
    echo "SyncV2Store schema test failed: $1" >&2
    exit 1
}

sqlite3 "$database" <"$schema" >/dev/null

query() {
    sqlite3 "$database" "$1"
}

[ "$(query 'PRAGMA user_version;')" = "1" ] \
    || fail "schema version is not 1"
[ "$(query 'PRAGMA journal_mode;')" = "wal" ] \
    || fail "journal mode is not WAL"
[ "$(query 'PRAGMA quick_check;')" = "ok" ] \
    || fail "quick_check did not pass"
[ -z "$(query 'PRAGMA foreign_key_check;')" ] \
    || fail "foreign_key_check did not pass"
[ "$(query "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('sync_projects','sync_documents','sync_batches','sync_operations','sync_conflicts');")" = "5" ] \
    || fail "one or more required tables are absent"

now="2026-07-26T00:00:00.000Z"
local_project_id="11111111-1111-1111-1111-111111111111"
server_project_id="22222222-2222-2222-2222-222222222222"
document_id="33333333-3333-3333-3333-333333333333"
batch_id="44444444-4444-4444-4444-444444444444"
operation_id="55555555-5555-5555-5555-555555555555"
device_id="88888888-8888-8888-8888-888888888888"

sqlite3 "$database" <<SQL
PRAGMA foreign_keys = ON;
INSERT INTO sync_projects(
    local_project_id, server_project_id, binding_kind, project_name, owner_subject,
    created_at, updated_at
) VALUES (
    '$local_project_id', '$server_project_id', 'new_server_project',
    '스키마 테스트', 'user-uuid',
    '$now', '$now'
);
INSERT INTO sync_documents(
    document_id, local_project_id, project_id, local_path, server_path,
    created_at, updated_at
) VALUES (
    '$document_id', '$local_project_id', '$server_project_id',
    '메인/원고/1권/001화.txt', '메인/원고/1권/001화.txt',
    '$now', '$now'
);
INSERT INTO sync_batches(
    batch_id, local_project_id, batch_kind, mutation_count, payload_hash,
    created_at, updated_at
) VALUES (
    '$batch_id', '$local_project_id', 'document_save', 1,
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    '$now', '$now'
);
INSERT INTO sync_operations(
    operation_id, batch_id, local_project_id, project_id, owner_subject, document_id,
    device_id, document_sequence, local_save_generation, operation_kind,
    base_revision, base_content,
    local_path, relative_path, content, content_byte_count, content_hash,
    created_at, updated_at
) VALUES (
    '$operation_id', '$batch_id', '$local_project_id', '$server_project_id',
    'user-uuid',
    '$document_id', '$device_id', 1, 42, 'document_commit', 0, '',
    '메인/원고/1권/001화.txt',
    '메인/원고/1권/001화.txt', '본문', 6,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '$now', '$now'
);
SQL

[ "$(query "SELECT status || ':' || document_sequence FROM sync_operations WHERE operation_id='$operation_id';")" = "pending:1" ] \
    || fail "document operation was not recorded"

if sqlite3 "$database" <<SQL >/dev/null 2>&1
.bail on
PRAGMA foreign_keys = ON;
INSERT INTO sync_projects(
    local_project_id, server_project_id, binding_kind, project_name,
    created_at, updated_at
) VALUES (
    '99999999-9999-9999-9999-999999999999',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'local_only', '잘못된 binding', '$now', '$now'
);
SQL
then
    fail "local-only binding accepted a server project ID"
fi

if sqlite3 "$database" <<SQL >/dev/null 2>&1
.bail on
PRAGMA foreign_keys = ON;
INSERT INTO sync_batches(
    batch_id, local_project_id, batch_kind, mutation_count, payload_hash,
    created_at, updated_at
) VALUES (
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    'document_save', 1,
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
    '$now', '$now'
);
SQL
then
    fail "batch accepted an unknown local project"
fi

if sqlite3 "$database" <<SQL >/dev/null 2>&1
.bail on
PRAGMA foreign_keys = ON;
INSERT INTO sync_documents(
    document_id, local_project_id, project_id, local_path, server_path,
    created_at, updated_at
) VALUES (
    '66666666-6666-6666-6666-666666666666',
    '$local_project_id', '$server_project_id',
    '메인/원고/1권/001화.txt', '다른경로.txt', '$now', '$now'
);
SQL
then
    fail "duplicate local path was accepted"
fi

atomic_batch_id="77777777-7777-7777-7777-777777777777"
if sqlite3 "$database" <<SQL >/dev/null 2>&1
.bail on
PRAGMA foreign_keys = ON;
BEGIN IMMEDIATE;
INSERT INTO sync_batches(
    batch_id, local_project_id, batch_kind, mutation_count, payload_hash,
    created_at, updated_at
) VALUES (
    '$atomic_batch_id', '$local_project_id', 'volume_creation', 2,
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
    '$now', '$now'
);
INSERT INTO sync_operations(
    operation_id, batch_id, local_project_id, project_id, owner_subject, document_id,
    device_id, document_sequence, operation_kind, base_revision, relative_path,
    local_path, content, content_byte_count, content_hash, created_at, updated_at
) VALUES (
    '$operation_id', '$atomic_batch_id', '$local_project_id', '$server_project_id',
    'user-uuid',
    '$document_id', '$device_id', 2, 'document_commit', 1,
    '메인/원고/1권/001화.txt',
    '메인/원고/1권/001화.txt', '중복 operation', 16,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    '$now', '$now'
);
COMMIT;
SQL
then
    fail "duplicate operation ID was accepted"
fi

[ "$(query "SELECT COUNT(*) FROM sync_batches WHERE batch_id='$atomic_batch_id';")" = "0" ] \
    || fail "failed batch was not rolled back atomically"

sqlite3 "$database" "UPDATE sync_operations SET status='inflight', attempts=1 WHERE operation_id='$operation_id';"
sqlite3 "$database" "UPDATE sync_operations SET status='pending' WHERE status='inflight';"
[ "$(query "SELECT operation_id || ':' || status || ':' || attempts FROM sync_operations WHERE operation_id='$operation_id';")" = "$operation_id:pending:1" ] \
    || fail "restart recovery changed identity or attempt count"

echo "SyncV2Store schema test passed: schema, constraints, WAL, atomic batch, and restart recovery."
