PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 10000;

BEGIN IMMEDIATE;

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL UNIQUE,
    checksum TEXT NOT NULL,
    applied_at TEXT NOT NULL
) STRICT;

CREATE TABLE sync_projects (
    local_project_id TEXT PRIMARY KEY CHECK (length(local_project_id) = 36),
    server_project_id TEXT CHECK (
        server_project_id IS NULL OR length(server_project_id) = 36
    ),
    binding_kind TEXT NOT NULL CHECK (
        binding_kind IN (
            'local_only',
            'new_server_project',
            'existing_server_project',
            'windows_import'
        )
    ),
    project_name TEXT NOT NULL CHECK (project_name <> ''),
    owner_subject TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (local_project_id, server_project_id),
    CHECK (
        (
            binding_kind = 'local_only'
            AND server_project_id IS NULL
            AND owner_subject IS NULL
        )
        OR
        (
            binding_kind <> 'local_only'
            AND server_project_id IS NOT NULL
            AND owner_subject IS NOT NULL
            AND owner_subject <> ''
        )
    )
) STRICT;

CREATE UNIQUE INDEX sync_projects_server_binding_uidx
    ON sync_projects(server_project_id)
    WHERE server_project_id IS NOT NULL;

CREATE TABLE sync_documents (
    document_id TEXT PRIMARY KEY CHECK (length(document_id) = 36),
    local_project_id TEXT NOT NULL,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    local_path TEXT NOT NULL CHECK (local_path <> ''),
    server_path TEXT NOT NULL CHECK (server_path <> ''),
    server_revision INTEGER NOT NULL DEFAULT 0 CHECK (server_revision >= 0),
    base_content TEXT NOT NULL DEFAULT '',
    base_hash TEXT NOT NULL DEFAULT '' CHECK (
        base_hash = ''
        OR (
            length(base_hash) = 64
            AND base_hash = lower(base_hash)
            AND base_hash NOT GLOB '*[^0-9a-f]*'
        )
    ),
    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
    server_updated_at TEXT,
    sync_state TEXT NOT NULL DEFAULT 'local' CHECK (
        sync_state IN ('local', 'pending', 'synced', 'conflict', 'blocked')
    ),
    last_error_code TEXT,
    next_document_sequence INTEGER NOT NULL DEFAULT 1 CHECK (
        next_document_sequence > 0
    ),
    last_applied_operation_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (local_project_id, local_path),
    FOREIGN KEY (local_project_id, project_id)
        REFERENCES sync_projects(local_project_id, server_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT
) STRICT;

CREATE INDEX sync_documents_project_revision_idx
    ON sync_documents(project_id, server_revision, document_id);
CREATE INDEX sync_documents_sync_state_idx
    ON sync_documents(local_project_id, sync_state, document_id);

CREATE TABLE sync_batches (
    batch_id TEXT PRIMARY KEY CHECK (length(batch_id) = 36),
    local_project_id TEXT NOT NULL
        REFERENCES sync_projects(local_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    local_transaction_id TEXT,
    batch_kind TEXT NOT NULL CHECK (
        batch_kind IN (
            'project_binding',
            'document_save',
            'structure_change',
            'volume_creation',
            'trash_change',
            'backup_restore',
            'windows_import'
        )
    ),
    mutation_count INTEGER NOT NULL CHECK (mutation_count > 0),
    payload_hash TEXT NOT NULL CHECK (
        length(payload_hash) = 64
        AND payload_hash = lower(payload_hash)
        AND payload_hash NOT GLOB '*[^0-9a-f]*'
    ),
    status TEXT NOT NULL DEFAULT 'ready' CHECK (
        status IN ('ready', 'processing', 'completed', 'attention')
    ),
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE INDEX sync_batches_status_idx
    ON sync_batches(status, created_at, batch_id);

CREATE TABLE sync_operations (
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
            'trash_purge'
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
    FOREIGN KEY (local_project_id, project_id)
        REFERENCES sync_projects(local_project_id, server_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    CHECK (
        (
            operation_kind = 'ensure_project'
            AND document_id IS NULL
            AND device_id IS NULL
            AND document_sequence IS NULL
            AND project_name IS NOT NULL
            AND project_name <> ''
            AND local_path = ''
            AND relative_path = ''
        )
        OR
        (
            operation_kind <> 'ensure_project'
            AND document_id IS NOT NULL
            AND device_id IS NOT NULL
            AND document_sequence IS NOT NULL
            AND project_name IS NULL
            AND local_path <> ''
            AND relative_path <> ''
        )
    )
) STRICT;

CREATE INDEX sync_operations_ready_idx
    ON sync_operations(status, next_attempt_at, queue_id)
    WHERE status IN ('pending', 'retry_wait');
CREATE INDEX sync_operations_document_lane_idx
    ON sync_operations(document_id, document_sequence, queue_id)
    WHERE document_id IS NOT NULL;
CREATE INDEX sync_operations_batch_idx
    ON sync_operations(batch_id, queue_id);

CREATE TABLE sync_conflicts (
    conflict_id TEXT PRIMARY KEY CHECK (length(conflict_id) = 36),
    operation_id TEXT NOT NULL UNIQUE
        REFERENCES sync_operations(operation_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    document_id TEXT NOT NULL
        REFERENCES sync_documents(document_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    base_content TEXT NOT NULL,
    local_content TEXT NOT NULL,
    remote_content TEXT NOT NULL,
    merged_content TEXT NOT NULL,
    remote_revision INTEGER NOT NULL CHECK (remote_revision > 0),
    remote_path TEXT NOT NULL CHECK (remote_path <> ''),
    conflict_count INTEGER NOT NULL CHECK (conflict_count > 0),
    created_at TEXT NOT NULL,
    resolved_at TEXT,
    resolution_kind TEXT CHECK (
        resolution_kind IS NULL
        OR resolution_kind IN ('keep_local', 'use_remote', 'manual_merge')
    ),
    CHECK (
        (resolved_at IS NULL AND resolution_kind IS NULL)
        OR
        (resolved_at IS NOT NULL AND resolution_kind IS NOT NULL)
    )
) STRICT;

CREATE UNIQUE INDEX sync_conflicts_one_open_per_document_uidx
    ON sync_conflicts(document_id)
    WHERE resolved_at IS NULL;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    1,
    'SyncV2StoreSchemaV1',
    'design-fixture-v1',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 1;

COMMIT;
