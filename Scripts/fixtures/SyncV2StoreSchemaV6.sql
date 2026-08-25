-- 계약이 정한 tree_order를 서버가 말한 그대로 들고 있기 위한 표다.
--
-- 지금까지 순서는 레거시 문서 하나(__antigravity__/tree-order.json)로만 알았다.
-- 그 문서는 자식을 이름으로 적는데, 계약은 folder_id로 적는다. 이름으로 두면
-- 이름이 바뀌는 순간 순서가 어느 폴더를 가리키는지 알 수 없게 된다.
--
-- 더 급한 이유가 있다. tree_order는 자식 목록 전체를 보낸다. 서버가 무엇을
-- 담고 있는지 모른 채 우리 목록을 보내면 남이 넣은 것을 지운다. 그래서 쓰기
-- 전에 서버가 말한 목록과 그 revision을 갖고 있어야 한다. revision은 우리가
-- 만들어낼 수 없는 유일한 값이다.
--
-- 이 표가 생기면 한 작품에 두 표현이 공존한다. 계약으로 쓰던 작품이 조용히
-- 레거시 쓰기로 후퇴하면 낡은 순서가 서버로 나가므로, 이 표에 행이 있다는
-- 사실 자체가 그 후퇴를 막는 판별 근거가 된다.

BEGIN IMMEDIATE;

CREATE TABLE sync_tree_orders (
    tree_order_id TEXT PRIMARY KEY CHECK (length(tree_order_id) = 36),
    local_project_id TEXT NOT NULL,
    project_id TEXT NOT NULL CHECK (length(project_id) = 36),
    -- NULL은 작품 최상위다. 서버가 parent_folder_id를 NULL로 두는 그 행이다.
    parent_folder_id TEXT CHECK (
        parent_folder_id IS NULL OR length(parent_folder_id) = 36
    ),
    -- folder_id / document_id의 배열을 JSON으로 담는다. 이름이 아니다.
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

-- 한 부모에 순서 행은 하나뿐이다. SQLite는 UNIQUE에서 NULL을 서로 다른 값으로
-- 보므로 최상위 행은 따로 막아야 한다. 두 색인으로 나누는 이유다.
CREATE UNIQUE INDEX sync_tree_orders_parent
    ON sync_tree_orders(local_project_id, parent_folder_id)
    WHERE parent_folder_id IS NOT NULL;

CREATE UNIQUE INDEX sync_tree_orders_root
    ON sync_tree_orders(local_project_id)
    WHERE parent_folder_id IS NULL;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    6,
    'SyncV2StoreSchemaV6',
    'design-fixture-v6',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 6;

COMMIT;
