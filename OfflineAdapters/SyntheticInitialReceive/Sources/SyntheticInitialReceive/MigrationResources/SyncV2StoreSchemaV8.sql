-- 원격 tombstone 때문에 전송할 수 없는 로컬 폴더 트리를 일반 동기화 트리
-- 밖에 보존한다. 파일 payload는 Application Support의 전용 패키지에 있고,
-- 이 두 표는 crash recovery, 멱등성, 신규 신원 복구의 영속 장부다.

BEGIN IMMEDIATE;

CREATE TABLE conflict_recovery_packages (
    package_id TEXT PRIMARY KEY CHECK (length(package_id) = 36),
    local_project_id TEXT NOT NULL
        REFERENCES sync_projects(local_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    server_project_id TEXT NOT NULL CHECK (length(server_project_id) = 36),
    source_operation_id TEXT NOT NULL
        REFERENCES sync_operations(operation_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT,
    source_folder_id TEXT NOT NULL CHECK (length(source_folder_id) = 36),
    source_base_revision INTEGER NOT NULL CHECK (source_base_revision >= 0),
    tombstone_revision INTEGER NOT NULL CHECK (tombstone_revision > source_base_revision),
    display_name TEXT NOT NULL CHECK (display_name <> ''),
    state TEXT NOT NULL CHECK (
        state IN (
            'preparing',
            'ready',
            'source_resolved',
            'restore_enqueued',
            'restored',
            'discarded'
        )
    ),
    payload_relative_path TEXT NOT NULL CHECK (payload_relative_path <> ''),
    manifest_sha256 TEXT CHECK (
        manifest_sha256 IS NULL OR (
            length(manifest_sha256) = 64
            AND manifest_sha256 = lower(manifest_sha256)
            AND manifest_sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ),
    file_count INTEGER NOT NULL DEFAULT 0 CHECK (file_count >= 0),
    total_bytes INTEGER NOT NULL DEFAULT 0 CHECK (total_bytes >= 0),
    restore_batch_id TEXT CHECK (
        restore_batch_id IS NULL OR length(restore_batch_id) = 36
    ),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    restored_at TEXT,
    payload_deleted_at TEXT,
    UNIQUE (source_operation_id, tombstone_revision),
    CHECK (
        (state = 'preparing' AND manifest_sha256 IS NULL)
        OR (state <> 'preparing' AND manifest_sha256 IS NOT NULL)
    ),
    CHECK (
        (state IN ('restore_enqueued', 'restored') AND restore_batch_id IS NOT NULL)
        OR (state NOT IN ('restore_enqueued', 'restored') AND restore_batch_id IS NULL)
    )
) STRICT;

CREATE INDEX conflict_recovery_packages_project_state_idx
    ON conflict_recovery_packages(local_project_id, state, created_at);

CREATE TABLE conflict_recovery_entities (
    package_id TEXT NOT NULL
        REFERENCES conflict_recovery_packages(package_id)
        ON UPDATE RESTRICT
        ON DELETE CASCADE,
    entity_kind TEXT NOT NULL CHECK (entity_kind IN ('folder', 'document')),
    source_entity_id TEXT NOT NULL CHECK (length(source_entity_id) = 36),
    restored_entity_id TEXT CHECK (
        restored_entity_id IS NULL OR length(restored_entity_id) = 36
    ),
    parent_source_entity_id TEXT CHECK (
        parent_source_entity_id IS NULL OR length(parent_source_entity_id) = 36
    ),
    relative_path TEXT NOT NULL CHECK (relative_path <> ''),
    title TEXT NOT NULL CHECK (title <> ''),
    user_order INTEGER NOT NULL CHECK (user_order >= 0),
    byte_count INTEGER CHECK (byte_count IS NULL OR byte_count >= 0),
    sha256 TEXT CHECK (
        sha256 IS NULL OR (
            length(sha256) = 64
            AND sha256 = lower(sha256)
            AND sha256 NOT GLOB '*[^0-9a-f]*'
        )
    ),
    restore_status TEXT NOT NULL DEFAULT 'pending' CHECK (
        restore_status IN ('pending', 'enqueued', 'committed')
    ),
    PRIMARY KEY (package_id, source_entity_id),
    CHECK (
        (entity_kind = 'folder' AND byte_count IS NULL AND sha256 IS NULL)
        OR (entity_kind = 'document' AND byte_count IS NOT NULL AND sha256 IS NOT NULL)
    )
) STRICT;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    8,
    'SyncV2StoreSchemaV8',
    'design-fixture-v8',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 8;

COMMIT;
