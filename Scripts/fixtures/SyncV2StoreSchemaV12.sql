-- 일반 작업은 명령 순서를 보존하고 앞선 응답이 확정된 뒤 요청을 한 번만 만든다.
BEGIN IMMEDIATE;
ALTER TABLE sync_documents ADD COLUMN parent_folder_id TEXT;
ALTER TABLE sync_documents ADD COLUMN name TEXT;
ALTER TABLE sync_documents ADD COLUMN structure_revision INTEGER CHECK (structure_revision IS NULL OR structure_revision > 0);
DROP INDEX sync_contract_operations_batch_idx;
ALTER TABLE sync_contract_operations RENAME TO sync_contract_operations_v11;
CREATE TABLE sync_contract_operations (
    operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
    batch_id TEXT NOT NULL
        REFERENCES sync_contract_batches(batch_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    entity_kind TEXT NOT NULL CHECK (
        entity_kind IN ('folder', 'tree_order', 'document')
    ),
    entity_id TEXT NOT NULL CHECK (length(entity_id) = 36),
    intent_kind TEXT NOT NULL CHECK (
        intent_kind IN (
            'create', 'update', 'rename', 'move', 'delete', 'restore',
            'reorder'
        )
    ),
    base_revision INTEGER NOT NULL CHECK (base_revision >= 0),
    payload_json TEXT NOT NULL CHECK (payload_json <> ''),
    payload_sha256 TEXT NOT NULL CHECK (
        length(payload_sha256) = 64
        AND payload_sha256 = lower(payload_sha256)
        AND payload_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN ('pending', 'inflight', 'completed', 'conflict', 'blocked')
    ),
    result_revision INTEGER CHECK (
        result_revision IS NULL OR result_revision > 0
    ),
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (batch_id, sequence)
) STRICT;

CREATE INDEX sync_contract_operations_batch_idx
    ON sync_contract_operations(batch_id, sequence);

INSERT INTO sync_contract_operations SELECT * FROM sync_contract_operations_v11;
DROP TABLE sync_contract_operations_v11;
CREATE TABLE sync_contract_local_batches (
    queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id TEXT NOT NULL UNIQUE CHECK (length(batch_id) = 36),
    local_project_id TEXT NOT NULL REFERENCES sync_projects(local_project_id) ON DELETE RESTRICT,
    project_id TEXT NOT NULL,
    source_json TEXT NOT NULL,
    writer_device_id TEXT NOT NULL,
    project_sync_mode TEXT NOT NULL,
    migration_epoch INTEGER NOT NULL,
    contract_version TEXT NOT NULL,
    contract_sha256 TEXT NOT NULL,
    protocol_version INTEGER NOT NULL,
    client_build_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting','materialized','completed','blocked')),
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (local_project_id, project_id) REFERENCES sync_projects(local_project_id, server_project_id) ON DELETE RESTRICT
) STRICT;
CREATE INDEX sync_contract_local_batches_project_queue_idx ON sync_contract_local_batches(local_project_id, queue_id);
ALTER TABLE sync_contract_batches ADD COLUMN next_attempt_at TEXT;
INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (12, 'SyncV2StoreSchemaV12', 'design-fixture-v12', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
PRAGMA user_version = 12;
COMMIT;
