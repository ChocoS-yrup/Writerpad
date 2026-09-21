-- 아직 요청을 만들지 않은 후속 저장도 충돌 선택 근거를 공유하며 보존한다.
BEGIN IMMEDIATE;
ALTER TABLE sync_contract_local_batches ADD COLUMN resolution_batch_id TEXT
    REFERENCES sync_contract_batches(batch_id) ON DELETE RESTRICT;
INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (14, 'SyncV2StoreSchemaV14', 'design-fixture-v14', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
PRAGMA user_version = 14;
COMMIT;
