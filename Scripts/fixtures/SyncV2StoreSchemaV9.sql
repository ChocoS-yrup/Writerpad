-- 계약이 정한 tree_order를 서버가 말한 그대로 들고 있기 위한 표다.
--
-- V6/V7 번호는 통합선에서 이미 operation 계보에 사용했다. canary 계보의
-- V6 tree_order를 V9로 옮기며, 이미 canary V6/V7을 거친 저장소도 같은 표를
-- 보존한 채 통합 계보로 전진할 수 있도록 생성은 멱등적으로 둔다.

BEGIN IMMEDIATE;

CREATE TABLE IF NOT EXISTS sync_tree_orders (
    tree_order_id TEXT PRIMARY KEY CHECK (length(tree_order_id) = 36),
    local_project_id TEXT NOT NULL,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    parent_folder_id TEXT CHECK (
        parent_folder_id IS NULL OR length(parent_folder_id) = 36
    ),
    children_json TEXT NOT NULL DEFAULT '[]',
    server_revision INTEGER NOT NULL DEFAULT 0 CHECK (server_revision >= 0),
    server_updated_at TEXT,
    sync_state TEXT NOT NULL DEFAULT 'local' CHECK (
        sync_state IN ('local', 'pending', 'synced', 'conflict', 'blocked')
    ),
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
) STRICT;

CREATE UNIQUE INDEX IF NOT EXISTS sync_tree_orders_parent
    ON sync_tree_orders(local_project_id, parent_folder_id)
    WHERE parent_folder_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS sync_tree_orders_root
    ON sync_tree_orders(local_project_id)
    WHERE parent_folder_id IS NULL;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    9,
    'SyncV2StoreSchemaV9',
    'design-fixture-v9',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 9;

COMMIT;
