-- 검토용 요청은 일반 claim 대상과 분리한다. 실제 송신을 시도한 뒤에도
-- 같은 요청의 명시적 재시도만 허용할 수 있도록 이 연결을 보존한다.
BEGIN IMMEDIATE;
CREATE TABLE sync_contract_preparations (
    batch_id TEXT PRIMARY KEY CHECK (length(batch_id) = 36),
    local_project_id TEXT NOT NULL UNIQUE REFERENCES sync_projects(local_project_id) ON DELETE RESTRICT,
    preparation_json TEXT NOT NULL,
    created_at TEXT NOT NULL
) STRICT;
INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (11, 'SyncV2StoreSchemaV11', 'design-fixture-v11', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
PRAGMA user_version = 11;
COMMIT;
