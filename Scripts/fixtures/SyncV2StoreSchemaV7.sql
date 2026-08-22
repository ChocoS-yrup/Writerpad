-- 불변 rebase는 새 operation에서 attempts를 다시 시작한다. 자동 되감기
-- 상한까지 함께 초기화하면 두 기기의 이름 변경이 영원히 서로를 밀 수 있으므로
-- 승계 사슬의 되감기 횟수를 intent와 별도로 영속한다.

BEGIN IMMEDIATE;

ALTER TABLE sync_operations
ADD COLUMN automatic_rebase_count INTEGER NOT NULL DEFAULT 0
    CHECK (automatic_rebase_count >= 0);

-- 하나의 원본 intent는 정확히 한 successor에게만 직접 승계될 수 있다.
-- 그 밖의 같은-entity 후속 intent는 superseded 사건의 related_operation_id로
-- 같은 successor를 가리킨다.
DROP INDEX sync_operations_supersedes_idx;

CREATE UNIQUE INDEX sync_operations_supersedes_idx
    ON sync_operations(supersedes_operation_id)
    WHERE supersedes_operation_id IS NOT NULL;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    7,
    'SyncV2StoreSchemaV7',
    'design-fixture-v7',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 7;

COMMIT;
