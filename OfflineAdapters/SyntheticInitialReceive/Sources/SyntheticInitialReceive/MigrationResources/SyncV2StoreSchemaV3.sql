-- 폴더의 서버 상태를 로컬에 남긴다.
--
-- V2에서 대기열에 폴더 자리를 만들었지만 폴더의 revision을 둘 곳이 없었다.
-- 문서는 sync_documents가 server_revision과 다음 순번을 들고 있어 대기열이
-- base_revision을 채울 수 있는데, 폴더는 그 표에 행이 없다. 같은 역할을 하는
-- 표를 폴더에도 둔다.
--
-- 경로 칸은 두지 않는다. 폴더를 경로로 식별하지 않는 것이 이번 전환의 목적이고,
-- 경로를 함께 저장하면 이름이 바뀔 때마다 어긋난 값이 남는다. 위치는
-- parent_folder_id 사슬이 유일한 근거다.
--
-- sync_operations.folder_id에 외래키를 걸지 않는다. SQLite는 외래키를 나중에
-- 추가할 수 없어 표를 다시 만들어야 하는데, V2에서 이미 한 번 옮긴 대기열을
-- 연달아 또 옮기는 위험이 이득보다 크다. 폴더 작업을 넣을 때 sync_folders 행을
-- 먼저 만들므로 문서와 같은 순서가 보장된다.

BEGIN IMMEDIATE;

CREATE TABLE sync_folders (
    folder_id TEXT PRIMARY KEY CHECK (length(folder_id) = 36),
    local_project_id TEXT NOT NULL,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    parent_folder_id TEXT CHECK (
        parent_folder_id IS NULL OR length(parent_folder_id) = 36
    ),
    name TEXT NOT NULL CHECK (name <> ''),
    server_revision INTEGER NOT NULL DEFAULT 0 CHECK (server_revision >= 0),
    is_deleted INTEGER NOT NULL DEFAULT 0 CHECK (is_deleted IN (0, 1)),
    server_updated_at TEXT,
    sync_state TEXT NOT NULL DEFAULT 'local' CHECK (
        sync_state IN ('local', 'pending', 'synced', 'conflict', 'blocked')
    ),
    last_error_code TEXT,
    next_folder_sequence INTEGER NOT NULL DEFAULT 1 CHECK (
        next_folder_sequence > 0
    ),
    last_applied_operation_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    -- 자기 자신을 부모로 삼으면 사슬이 끊긴다. 더 긴 순환은 사슬을 따라가야
    -- 알 수 있어 넣을 때 검사한다.
    CHECK (parent_folder_id IS NULL OR parent_folder_id <> folder_id),
    FOREIGN KEY (local_project_id, project_id)
        REFERENCES sync_projects(local_project_id, server_project_id)
        ON UPDATE RESTRICT
        ON DELETE RESTRICT
) STRICT;

-- 같은 이름의 폴더가 같은 부모 아래 둘 생기는 것은 막지 않는다. 목적지가 이미
-- 차 있으면 덮어쓰지 말고 충돌로 보존해야 하는데, 고유 제약을 걸면 넣는 순간
-- 실패해 보존할 기회가 없어진다.
CREATE INDEX sync_folders_project_revision_idx
    ON sync_folders(project_id, server_revision, folder_id);
CREATE INDEX sync_folders_parent_idx
    ON sync_folders(local_project_id, parent_folder_id, folder_id);
CREATE INDEX sync_folders_sync_state_idx
    ON sync_folders(local_project_id, sync_state, folder_id);

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    3,
    'SyncV2StoreSchemaV3',
    'design-fixture-v3',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 3;

COMMIT;
