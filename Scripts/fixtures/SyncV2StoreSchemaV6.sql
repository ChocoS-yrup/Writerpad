-- 되감기는 이미 보낸 의도를 고쳐 쓰지 않는다. 새 operation/batch를 만들고
-- 어떤 작업을 대신하는지 영속적으로 연결해야 계약 경로가 나중에 열려도
-- supersedes_operation_id를 잃지 않는다.

BEGIN IMMEDIATE;

ALTER TABLE sync_operations
ADD COLUMN supersedes_operation_id TEXT
    REFERENCES sync_operations(operation_id)
    ON UPDATE RESTRICT
    ON DELETE RESTRICT
    CHECK (
        supersedes_operation_id IS NULL
        OR (
            length(supersedes_operation_id) = 36
            AND supersedes_operation_id <> operation_id
        )
    );

CREATE INDEX sync_operations_supersedes_idx
    ON sync_operations(supersedes_operation_id)
    WHERE supersedes_operation_id IS NOT NULL;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    6,
    'SyncV2StoreSchemaV6',
    'design-fixture-v6',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 6;

COMMIT;
