-- 원본 보관 ID와 전송 순서를 분리해 충돌 대체 요청이 후속 변경보다 먼저 처리되게 한다.
BEGIN IMMEDIATE;
ALTER TABLE sync_contract_local_batches ADD COLUMN dispatch_order INTEGER CHECK(dispatch_order > 0);
CREATE INDEX sync_contract_local_dispatch_order ON sync_contract_local_batches
    (local_project_id, COALESCE(dispatch_order, queue_id), queue_id) WHERE status <> 'completed';
INSERT INTO schema_migrations(version, name, checksum, applied_at)
VALUES (15, 'SyncV2StoreSchemaV15', 'design-fixture-v15', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
PRAGMA user_version = 15;
COMMIT;
