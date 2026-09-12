-- 분할 작업의 원본과 로컬 선택 기록을 보존하고 휴지통 표식 계약을 지원한다.
BEGIN IMMEDIATE;
DROP INDEX sync_contract_operations_batch_idx;
ALTER TABLE sync_contract_operations RENAME TO sync_contract_operations_v15;
CREATE TABLE sync_contract_operations (
    operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
    batch_id TEXT NOT NULL
        REFERENCES sync_contract_batches(batch_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    entity_kind TEXT NOT NULL CHECK (
        entity_kind IN ('folder', 'tree_order', 'document', 'trash_purge')
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

INSERT INTO sync_contract_operations SELECT * FROM sync_contract_operations_v15;
DROP TABLE sync_contract_operations_v15;
ALTER TABLE sync_contract_local_batches ADD COLUMN parent_batch_id TEXT REFERENCES sync_contract_local_batches(batch_id) ON DELETE RESTRICT;
ALTER TABLE sync_contract_local_batches ADD COLUMN local_resolution_json TEXT;
CREATE INDEX sync_contract_local_parent ON sync_contract_local_batches(parent_batch_id);
INSERT INTO schema_migrations(version,name,checksum,applied_at) VALUES (16,'SyncV2StoreSchemaV16','design-fixture-v16',strftime('%Y-%m-%dT%H:%M:%fZ','now'));
PRAGMA user_version = 16;
COMMIT;
