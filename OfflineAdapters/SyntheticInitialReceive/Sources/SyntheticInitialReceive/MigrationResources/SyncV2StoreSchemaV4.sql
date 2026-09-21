-- 폴더 UUID 이관을 작품마다 한 번만 하도록 표식을 남긴다.
--
-- 이관 여부를 경로로는 판단할 수 없다. 이관된 폴더의 이름이 바뀌면 경로와
-- UUID가 어긋나므로, 다시 계산하면 같은 폴더에 다른 값을 붙여 두 번 이관하게
-- 된다. 계산으로 알아낼 수 없으니 끝났다는 사실 자체를 적어 둔다.
--
-- 표를 다시 만들지 않고 칸만 더한다. sync_projects에는 CHECK를 바꿀 일이 없고,
-- 대기 중인 작업이 걸린 표도 아니다.

BEGIN IMMEDIATE;

ALTER TABLE sync_projects
    ADD COLUMN folder_migration_completed_at TEXT;

INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (
    4,
    'SyncV2StoreSchemaV4',
    'design-fixture-v4',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

PRAGMA user_version = 4;

COMMIT;
