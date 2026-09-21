-- 충돌 요청의 원문은 보존하고 새 요청과 사용자 선택 근거를 연결한다.
BEGIN IMMEDIATE;
ALTER TABLE sync_contract_batches ADD COLUMN superseded_by TEXT
    REFERENCES sync_contract_batches(batch_id) ON DELETE RESTRICT;
ALTER TABLE sync_contract_batches ADD COLUMN resolution_json TEXT;
INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (13, 'SyncV2StoreSchemaV13', 'design-fixture-v13', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
PRAGMA user_version = 13;
COMMIT;
