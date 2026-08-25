-- contract 0.2.0 구조 배치를 레거시 문서 대기열과 분리해 저장한다.
--
-- atomic_structure_commit은 폴더와 tree_order를 한 배치로 적용한다. 요청을
-- 먼저 적어 놓지 않으면 프로세스가 끊긴 뒤 같은 batch_id로 재시도할
-- 수 없다. 레거시 dispatcher가 이 행을 폴더 단건 쓰기로 착각하지 않도록
-- 전용 표로 분리한다.

BEGIN IMMEDIATE;

CREATE TABLE sync_contract_batches (
    batch_id TEXT PRIMARY KEY CHECK (length(batch_id) = 36),
    local_project_id TEXT NOT NULL
        REFERENCES sync_projects(local_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    request_json TEXT NOT NULL CHECK (request_json <> ''),
    batch_payload_sha256 TEXT NOT NULL CHECK (
        length(batch_payload_sha256) = 64
        AND batch_payload_sha256 = lower(batch_payload_sha256)
        AND batch_payload_sha256 NOT GLOB '*[^0-9a-f]*'
    ),
    status TEXT NOT NULL DEFAULT 'ready' CHECK (
        status IN ('ready', 'processing', 'completed', 'conflict', 'blocked')
    ),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    response_json TEXT,
    last_error_code TEXT,
    last_error_detail TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (local_project_id, project_id)
        REFERENCES sync_projects(local_project_id, server_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT
) STRICT;

CREATE INDEX sync_contract_batches_ready_idx
    ON sync_contract_batches(status, created_at, batch_id)
    WHERE status = 'ready';

CREATE TABLE sync_contract_operations (
    operation_id TEXT PRIMARY KEY CHECK (length(operation_id) = 36),
    batch_id TEXT NOT NULL
        REFERENCES sync_contract_batches(batch_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    sequence INTEGER NOT NULL CHECK (sequence > 0),
    entity_kind TEXT NOT NULL CHECK (
        entity_kind IN ('folder', 'tree_order')
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

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    7,
    'SyncV2StoreSchemaV7',
    'design-fixture-v7',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 7;

COMMIT;
