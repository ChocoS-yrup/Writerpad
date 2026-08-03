-- 폴더를 서버와 공유하는 UUID로 식별하기 위해 대기열에 폴더 작업을 넣는다.
--
-- 폴더는 지금까지 서버에 실체가 없어 tree-order의 이름 목록으로만 전달됐다.
-- 그래서 이름 변경이 "옛 이름 사라짐 + 새 이름 생김"으로 도착해 받는 기기에
-- 폴더가 둘 남았다. 폴더도 문서와 같은 줄에 세워 같은 재시도·순서 보장을
-- 그대로 쓴다.
--
-- operation_kind와 본문 CHECK는 SQLite에서 나중에 바꿀 수 없어 표를 다시
-- 만든다. sync_conflicts가 sync_operations를 참조하므로 표를 바꾸는 동안만
-- 외래키 검사를 끄고, 끝난 뒤 foreign_key_check로 확인한다.

PRAGMA foreign_keys = OFF;

BEGIN IMMEDIATE;

CREATE TABLE sync_operations_v2 (
    queue_id INTEGER PRIMARY KEY AUTOINCREMENT,
    operation_id TEXT NOT NULL UNIQUE CHECK (length(operation_id) = 36),
    batch_id TEXT NOT NULL
        REFERENCES sync_batches(batch_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    local_project_id TEXT NOT NULL,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    owner_subject TEXT NOT NULL CHECK (owner_subject <> ''),
    document_id TEXT
        REFERENCES sync_documents(document_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    -- 폴더는 sync_documents에 행이 없다. 서버 folders와 맞추는 값이라
    -- 로컬 문서 표를 참조하지 않는다.
    folder_id TEXT CHECK (folder_id IS NULL OR length(folder_id) = 36),
    parent_folder_id TEXT CHECK (
        parent_folder_id IS NULL OR length(parent_folder_id) = 36
    ),
    folder_name TEXT,
    device_id TEXT CHECK (device_id IS NULL OR length(device_id) = 36),
    document_sequence INTEGER CHECK (
        document_sequence IS NULL OR document_sequence > 0
    ),
    local_save_generation INTEGER CHECK (
        local_save_generation IS NULL OR local_save_generation >= 0
    ),
    operation_kind TEXT NOT NULL CHECK (
        operation_kind IN (
            'ensure_project',
            'document_commit',
            'tree_order',
            'trash_purge',
            'folder_commit'
        )
    ),
    project_name TEXT,
    base_revision INTEGER CHECK (
        base_revision IS NULL OR base_revision >= 0
    ),
    base_content TEXT NOT NULL DEFAULT '',
    local_path TEXT NOT NULL DEFAULT '',
    relative_path TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    content_byte_count INTEGER NOT NULL DEFAULT 0 CHECK (content_byte_count >= 0),
    content_hash TEXT NOT NULL DEFAULT '' CHECK (
        content_hash = ''
        OR (
            length(content_hash) = 64
            AND content_hash = lower(content_hash)
            AND content_hash NOT GLOB '*[^0-9a-f]*'
        )
    ),
    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN (
            'pending',
            'inflight',
            'retry_wait',
            'conflict',
            'completed',
            'cancelled',
            'blocked'
        )
    ),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error_code TEXT,
    last_error_detail TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    next_attempt_at TEXT,
    UNIQUE (document_id, document_sequence),
    -- 폴더도 문서와 같이 한 줄로 세워야 이름 변경과 삭제가 순서대로 나간다.
    UNIQUE (folder_id, document_sequence),
    FOREIGN KEY (local_project_id, project_id)
        REFERENCES sync_projects(local_project_id, server_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CHECK (
        (
            operation_kind = 'ensure_project'
            AND document_id IS NULL
            AND folder_id IS NULL
            AND device_id IS NULL
            AND document_sequence IS NULL
            AND project_name IS NOT NULL
            AND project_name <> ''
            AND local_path = ''
            AND relative_path = ''
        )
        OR
        (
            operation_kind = 'folder_commit'
            AND document_id IS NULL
            AND folder_id IS NOT NULL
            AND folder_name IS NOT NULL
            AND folder_name <> ''
            AND device_id IS NOT NULL
            AND document_sequence IS NOT NULL
            AND project_name IS NULL
            AND local_path = ''
            AND content = ''
        )
        OR
        (
            operation_kind NOT IN ('ensure_project', 'folder_commit')
            AND document_id IS NOT NULL
            AND folder_id IS NULL
            AND folder_name IS NULL
            AND parent_folder_id IS NULL
            AND device_id IS NOT NULL
            AND document_sequence IS NOT NULL
            AND project_name IS NULL
            AND local_path <> ''
            AND relative_path <> ''
        )
    )
) STRICT;

INSERT INTO sync_operations_v2 (
    queue_id, operation_id, batch_id, local_project_id, project_id,
    owner_subject, document_id, device_id, document_sequence,
    local_save_generation, operation_kind, project_name, base_revision,
    base_content, local_path, relative_path, content, content_byte_count,
    content_hash, is_deleted, status, attempts, last_error_code,
    last_error_detail, created_at, updated_at, next_attempt_at
)
SELECT
    queue_id, operation_id, batch_id, local_project_id, project_id,
    owner_subject, document_id, device_id, document_sequence,
    local_save_generation, operation_kind, project_name, base_revision,
    base_content, local_path, relative_path, content, content_byte_count,
    content_hash, is_deleted, status, attempts, last_error_code,
    last_error_detail, created_at, updated_at, next_attempt_at
FROM sync_operations;

DROP TABLE sync_operations;

ALTER TABLE sync_operations_v2 RENAME TO sync_operations;

CREATE INDEX sync_operations_ready_idx
    ON sync_operations(status, next_attempt_at, queue_id)
    WHERE status IN ('pending', 'retry_wait');
CREATE INDEX sync_operations_document_lane_idx
    ON sync_operations(document_id, document_sequence, queue_id)
    WHERE document_id IS NOT NULL;
CREATE INDEX sync_operations_folder_lane_idx
    ON sync_operations(folder_id, document_sequence, queue_id)
    WHERE folder_id IS NOT NULL;
CREATE INDEX sync_operations_batch_idx
    ON sync_operations(batch_id, queue_id);

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    2,
    'SyncV2StoreSchemaV2',
    'design-fixture-v2',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 2;

COMMIT;

PRAGMA foreign_keys = ON;
