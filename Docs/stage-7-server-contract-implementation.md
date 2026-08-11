# stage-7-server-contract-implementation

## 상태

- 범위: Server/Supabase only
- 소스 구현: 완료
- 로컬 정적 검증: 통과
- 임시 PostgreSQL 16 migration/RPC conformance: 통과
- Stage 7 판정: `READY_FOR_STAGING_PREFLIGHT`
- staging 쓰기: 수행하지 않음
- 운영 쓰기: 수행하지 않음
- client 앱 변경: 없음
- PR: https://github.com/ChocoS-yrup/Writerpad/pull/4
- server implementation commit: `5b218026d6b786dada2053e0a04761597d9083f8`

## 최종 계약 pin

```yaml
repository: https://github.com/ChocoS-yrup/Writerpad
contract_pr: https://github.com/ChocoS-yrup/Writerpad/pull/5
contract_version: 0.2.0
contract_git_commit: fcd99b7098b9a04bd93c585d89b16588aa482530
contract_content_commit: 7bcb5d25c5376b02469666df7318b90b456ffee6
canonical_contract_bytes: 23256
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
```

PR #5에서 protocol 3 문서 본문 commit wire가 확정된 뒤 PR #4에 main merge
commit `e712cb0`으로 반영했다.

## migration

```yaml
migration_ids:
  - 20260811010000
  - 20260811020000
migration_files:
  - supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql
  - supabase/migrations/20260811020000_sync_contract_0_1_0_rpcs.sql
```

두 ID와 파일명은 Stage 7 최초 draft에서 할당되었으며 staging 또는 운영에 적용된
적이 없다. 계약 개정 후 같은 미적용 migration ID의 내용을 최종 계약 0.2.0 pin으로
갱신했다. staging preflight에서 ledger 충돌이 발견되면 적용하지 않고 새 corrective
migration ID를 발급해야 한다.

첫 migration은 allowlist(`enabled=false`), 정직한 `LEGACY/epoch 0` 경계,
Unicode 15 storage-name-v1, immutable batch/operation, append-only attempt/event,
document `structure_revision`, RLS와 project 격리를 추가한다.

두 번째 migration은 다음을 구현한다.

- contract 0.2.0 digest/build/protocol/capability enforcement
- `atomic_structure_commit(jsonb)`와 전체 transaction rollback
- document rename/move의 `structure_revision` 장벽
- 규범 wire 그대로의 `document_commit(jsonb)`
- intentional empty body와 exact UTF-8 byte count/SHA-256 검증
- create/update/delete/restore와 delete/restore snapshot 보존
- batch/operation idempotency와 response-loss/server-restart replay
- append-only cancellation 및 수동 project migration RPC
- legacy document RPC에 대한 enforcement boundary

## 검증 결과

```yaml
python: 3.12.13
unicode: 15.0.0
contract_schemas: 7 passed
transition_vectors: 12 passed
storage_name_vectors: 15 passed
atomic_wire_cases: 4 passed
document_wire_cases: 7 passed
stage7_static_checks: passed
postgresql_version: 16
postgresql_migration_parse_apply: passed
postgresql_rpc_conformance: passed
github_actions_server_run: https://github.com/ChocoS-yrup/Writerpad/actions/runs/31459172995
github_actions_contract_run: https://github.com/ChocoS-yrup/Writerpad/actions/runs/31459172997
```

PostgreSQL job은 reference v2 migration 다음에 두 Stage 7 migration을 적용하고
atomic commit/rollback/replay, cancellation, 수동 migration, intentional empty
document commit과 document replay를 실제 SQL로 검증했다.

## staging 승인 게이트

현재 환경에는 확인된 staging project ID, endpoint 및 DB 자격 증명이 없다. 따라서
아래 항목은 `UNVERIFIED`이며 staging 쓰기를 승인받기 전까지 실행하지 않는다.

1. `supabase/preflight/stage7_readonly.sql`로 migration ledger와 catalog snapshot 확인
2. 정확한 staging project ID/endpoint 및 실행할 두 migration을 사용자에게 제시
3. staging 쓰기 승인 후에만 migration 적용 및 재실행 검증
4. 배포 RPC catalog, document/structure 왕복, restart replay 확인
5. rollback/복구 절차와 test project ID 보존

## rollback 및 복구

- CI transaction 실패 시 migration 전체 rollback은 검증했다.
- staging snapshot 복원 및 Supabase 운영 복구는 대상이 없어 아직 검증하지 않았다.
- allowlist 활성화 뒤 문제가 생기면 먼저 `enabled=false`로 신규 요청을 차단한다.
- append-only 자료는 삭제·덮어쓰지 않고 corrective migration/event로 복구한다.
- project mode는 자동으로 변경하거나 되돌리지 않는다.

## Stage 7 handoff

```yaml
contract_version: 0.2.0
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
server_merge_candidate_commit: 5b218026d6b786dada2053e0a04761597d9083f8
migration_ids:
  - 20260811010000
  - 20260811020000
staging_project_id: UNVERIFIED
staging_endpoint: UNVERIFIED
migration_ledger_verified: false
protocol_3_document_rpc: implemented_and_ci_passed
atomic_structure_rpc: implemented_and_ci_passed
test_results: local_static_and_postgresql_16_ci_passed
rollback_status: transaction_rollback_passed_operational_restore_unverified
production_changes: none
unverified_items:
  - staging migration ledger and catalog
  - actual deployed RPC catalog
  - staging document/structure round trip
  - staging restart replay
  - staging snapshot restore procedure
```

Stage 8은 Stage 7 PR 병합 commit과 staging 검증 결과가 확정되기 전에는 시작하지 않는다.
