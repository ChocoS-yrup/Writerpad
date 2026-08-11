# stage-7-server-contract-implementation

## 상태

- 구현 범위: Server/Supabase only
- 구현 상태: 로컬 및 GitHub PostgreSQL 16 CI 검증 완료, staging/운영 미적용
- 운영 쓰기: 수행하지 않음
- client 앱 변경: 없음
- 구현 브랜치: `codex/stage-7-server-contract-implementation`
- 구현 커밋: `1fbc31bee3e36d46e86e8723936b5c2c7b71081f`
- 검증된 server build SHA: `3111faa589a302404aa57ae88b9eee347a961dc8`

## 계약 pin

```yaml
repository: https://github.com/ChocoS-yrup/Writerpad
contract_version: 0.1.0
contract_git_commit: 45d18cff62cc48e29d0e6efcfc634fec96150198
contract_content_commit: 7f05f32dd385ce0e1922b88d688742fca2a503fa
canonical_contract_bytes: 19473
canonical_contract_sha256: fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46
```

## 적용 대상 migration

1. `20260811010000_sync_contract_0_1_0_foundation.sql`
2. `20260811020000_sync_contract_0_1_0_rpcs.sql`

첫 migration은 contract allowlist, LEGACY/epoch 0 provenance, Unicode 15 storage-name 정규화 자료와 함수, immutable operation/batch/event 저장소, RLS 및 읽기 권한을 추가한다. allowlist row는 기본적으로 `enabled = false`라서 migration 적용만으로 enforcement가 켜지거나 기존 project가 승격되지 않는다.

두 번째 migration은 protocol/capability 검증, atomic ordered structure batch, idempotent replay, cancellation, 수동 project migration RPC와 document write enforcement boundary를 추가한다.

## 검증 결과

- Python: `3.12.13`
- contract schema: 6 passed
- transition vectors: 12 passed
- storage-name vectors: 15 passed
- atomic wire cases: 4 passed
- canonical bytes/digest: pin과 일치
- Stage 7 정적 검사: 2 migrations passed
- PostgreSQL parser 검사: 두 migration 모두 parse 성공
- whitespace 검사: passed
- secret scan: 발견 없음
- PostgreSQL 16 통합 검증: passed ([Actions run 31453547913](https://github.com/ChocoS-yrup/Writerpad/actions/runs/31453547913))

CI는 reference v2 migration을 적용한 임시 PostgreSQL 16에서 Stage 7 migration과 SQL conformance test를 실행한다. 운영 또는 staging 데이터베이스를 사용하지 않는다.

## 읽기 전용 운영/staging 확인 절차

`supabase/preflight/stage7_readonly.sql`을 대상 DB에서 읽기 전용으로 실행해 다음 증거를 보존해야 한다.

- Supabase migration ledger
- PostgreSQL version과 catalog snapshot
- reference v2 및 Stage 7 object/RPC 존재 여부
- 기존 project의 legacy 분포
- provenance 불일치와 migration ID 충돌

현재 환경에는 staging endpoint, project ID, DB 자격 증명이 없어서 이 확인은 수행하지 않았다.

## Stage 8에 전달할 값

```yaml
staging_project_id: UNVERIFIED
staging_endpoint: UNVERIFIED
migration_ids:
  - 20260811010000
  - 20260811020000
server_build_sha: 3111faa589a302404aa57ae88b9eee347a961dc8
contract_version: 0.1.0
canonical_contract_sha256: fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46
```

Stage 8은 위의 `UNVERIFIED` 항목을 실제 staging 증거로 교체하고, PR CI와 staging conformance가 모두 통과한 뒤에만 시작해야 한다.

## 미적용 운영 작업

1. staging에서 preflight를 읽기 전용으로 실행하고 ledger/catalog snapshot을 보존한다.
2. 두 migration을 순서대로 staging에 적용한다.
3. staging conformance, replay, rollback, concurrency, cancellation, mixed-client 검증을 수행한다.
4. 검증 결과를 근거로 contract allowlist 활성화 여부를 별도 승인한다.
5. project별 수동 승격 전 `validate_project_sync_migration` 결과를 보존한다.
6. 운영 적용은 별도 승인과 maintenance/복구 계획이 있을 때만 수행한다.

## 복구 원칙

- 적용 도중 실패하면 transaction 전체 실패를 확인하고 ledger에 성공 migration으로 기록되지 않았는지 확인한다.
- 데이터가 생성되기 전에는 staging을 snapshot으로 복원하거나 새 staging DB에서 재검증한다.
- operation/event/batch 데이터가 생성된 후에는 append-only 기록을 삭제하거나 덮어쓰지 않는다. 새 corrective migration으로 복구한다.
- allowlist를 활성화했을 경우 우선 `enabled = false`로 되돌려 신규 protocol 3 요청을 차단하고, project mode를 자동 변경하지 않은 상태에서 원인을 조사한다.
- 기존 project는 명시적 완료 절차 없이는 계속 `LEGACY/epoch 0`으로 취급한다.
