# stage-7-server-contract-implementation

## 상태

- 범위: Server/Supabase only
- 계약 및 서버 소스 구현: 완료
- operational v2 squashed baseline snapshot: 작성 및 catalog exact-match 완료
- PostgreSQL 17.6 blank-DB chain 검증: 통과
- PR #4 상태: ready, mergeable, checks passed, 미병합
- Stage 7 판정: `AWAITING_STAGING_FUNCTIONAL_TEST_APPROVAL`
- staging migration: 승인된 3개 정식 적용 및 metadata 검증 완료
- 운영 쓰기 및 ledger reconciliation: 수행하지 않음
- allowlist 활성화 및 project 승격: 수행하지 않음
- client 앱 변경: 없음
- PR: https://github.com/ChocoS-yrup/Writerpad/pull/4
- server implementation commit: `5b218026d6b786dada2053e0a04761597d9083f8`
- baseline verification candidate commit: `e716f3890b8e43ef699fc521f97ec2f75f0edda0`
- staging applied source head: `3045417821371a0e5220c3be90d9b46353dbf711`

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

## blank-environment migration chain

```yaml
migration_order:
  - id: 20260811000000
    file: supabase/migrations/20260811000000_operational_v2_schema_baseline_snapshot.sql
    sha256: 323c6e092cd9afabb438eaf233b7e63abd0195d5e1a91a5f5fe3fe5940699198
    purpose: blank-environment current operational v2 schema snapshot
  - id: 20260811010000
    file: supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql
    sha256: afd86ef2c565e5932dafd4847e351d5fa218590e357a25de9c35dbb87b94d44a
  - id: 20260811020000
    file: supabase/migrations/20260811020000_sync_contract_0_1_0_rpcs.sql
    sha256: 60775ced603122aae2f4a53a7cfaf39299676c647b839feaf9527210ec514b46
```

첫 파일은 과거 migration 이력의 추정 복원이 아니라 현재 운영 v2 catalog의
schema-only squashed snapshot이다. 사용자 row, 문서 본문·경로, auth metadata,
secret, sequence 현재값, production 식별자를 포함하지 않는다.

snapshot은 앱 schema가 이미 존재하면
`BASELINE_SNAPSHOT_REQUIRES_EMPTY_APP_SCHEMA`로 실패한다. 기존 운영 환경에는
실행하지 않으며, 향후 exact catalog match 후 별도 승인된 ledger reconciliation만
사용한다.

snapshot이 재현하는 범위:

- projects/project_members/documents/document_versions/edit_leases
- folders/folder_versions와 immutable folder history
- project trash/purge와 private purge tombstone
- 최종 `has_project_role`의 `trashed_at is null` 보호 조건
- baseline document/edit-lease RPC와 folder/trash RPC
- 최종 RLS/policy, grants, documents/folders Realtime membership
- extension 의존성과 남아 있는 private/trigger helper

Stage 7 foundation/RPC는 contract 0.2.0 enforcement, 정직한
`LEGACY/epoch 0`, immutable operation, append-only attempt/event,
document commit, atomic structure commit, idempotency/replay/cancellation,
Unicode 15 storage-name 및 수동 project migration boundary를 구현한다.

## 운영 catalog 근거

운영 조회는 승인된 프로젝트에서 `READ ONLY` transaction과 `ROLLBACK`만
사용했다. 사용자 row 값, 문서 본문·경로, auth metadata는 조회하지 않았다.

```yaml
postgresql_version: 17.6
transaction_read_only: on
source_catalog_project: redacted_in_snapshot
source_catalog_manifest_bytes: 49540
source_catalog_manifest_sha256: 6c71ff36a90993dc327557b4a1a64c0dfb27b347134ed89e7f126dae76c6ff9a
catalog_sort: explicit_C_collation
operational_write: none
```

운영 DB의 ICU locale과 CI 컨테이너 locale이 달라도 동일 digest를 만들도록 manifest
배열 정렬은 명시적인 `COLLATE "C"`를 사용한다. PostgreSQL 17.6 CI에서 snapshot
적용 직후 동일한 49,540 bytes와 SHA-256이 확인됐다.

상세 provenance와 기존 ledger 상태는
`Docs/stage-7-baseline-provenance-review.md`에 기록했다.

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
postgresql_version: 17.6
blank_snapshot_apply: passed
operational_catalog_exact_match: passed
snapshot_existing_schema_guard: passed
snapshot_failed_apply_transaction_rollback: passed
stage7_foundation_apply: passed
stage7_rpc_apply: passed
stage7_migration_rerun: passed
atomic_replay_cancellation_migration_sql: stage7_server_contract_sql_passed
github_actions_server_run: https://github.com/ChocoS-yrup/Writerpad/actions/runs/31465930836
github_actions_contract_run: https://github.com/ChocoS-yrup/Writerpad/actions/runs/31465930851
```

최종 CI에서 Ubuntu exact head, Windows exact head, Ubuntu PR merge result 및
PostgreSQL 17.6 migration/RPC conformance가 모두 통과했다.

CI 재시험 과정에서 발견한 문제는 운영 schema 문제가 아니었다. 추출 정의의 SQL
delimiter, 분할 파일 경계의 중복 newline, locale 의존 catalog 정렬을 수정했다.
모든 실패는 일회용 CI DB transaction 안에서 발생했으며 staging/운영에는 쓰지
않았다. metadata-only 진단 SQL은 digest mismatch 때만 출력되도록 남겼다.

## staging 적용 결과와 다음 승인 대상

2026-08-11의 기존 staging preflight에서 `WriterPad Staging`
(`mhpnszcorfzrvhyondxr`)은 PostgreSQL 17.6의 빈 프로젝트였고 baseline table과
migration ledger가 없었다. 당시 foundation을 먼저 실행한 시도는
`STAGE7_BASELINE_MISSING`으로 전체 rollback됐고 RPC migration은 실행하지 않았다.

별도 승인 후 PR #4 head `3045417821371a0e5220c3be90d9b46353dbf711`에서
세 migration의 SHA-256을 다시 확인하고 Supabase CLI `2.113.0`의 정식 linked
`db push` 방식으로 순서대로 적용했다. remote ledger에 세 version이 모두 기록됐다.

적용 후 `READ ONLY` transaction과 `ROLLBACK`으로 다음을 실제 DB에서 확인했다.

- contract `0.2.0`, canonical digest와 bytes가 pin과 일치
- allowlist 1행, `enabled=false`, revoked 아님
- `document_commit(jsonb)`와 `atomic_structure_commit(jsonb)` signature 존재
- 필수 public/private relation과 강제 RLS 및 documents/folders Realtime 존재
- auth.users, project/document/folder 및 모든 sync operation table 정확히 0행
- project mode 생성·승격 및 테스트 데이터 생성 없음

비밀값이 제거된 상세 적용 증거는
`Docs/stage-7-staging-migration-apply-2026-08-11.md`에 기록했다.

다음 별도 승인 대상은 테스트 사용자와 데이터가 필요한 실제 staging 기능 검증이다.
`document_commit`/`atomic_structure_commit` 왕복, replay/rollback/cancellation 및
restart/response-loss 검증 전에는 PR #4를 병합하거나 Stage 8을 시작하지 않는다.

## rollback 및 복구

- snapshot의 기존 schema guard가 fail-closed로 동작함을 검증했다.
- auth prerequisite가 없는 중간 실패에서 생성 객체가 모두 rollback됨을 검증했다.
- Stage 7 foundation/RPC 재실행 안전성을 PostgreSQL 17.6에서 검증했다.
- 기존 staging의 잘못된 순서 foundation 시도도 전체 rollback된 상태다.
- 운영 baseline snapshot 실행 및 ledger repair는 금지 상태다.
- allowlist 활성화 뒤 문제가 생기면 `enabled=false`로 신규 요청을 차단한다.
- append-only 자료는 삭제·덮어쓰지 않고 corrective migration/event로 복구한다.
- project mode는 자동으로 변경하거나 되돌리지 않는다.

## Stage 7 handoff

```yaml
contract_version: 0.2.0
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
server_merge_candidate_commit: e716f3890b8e43ef699fc521f97ec2f75f0edda0
staging_applied_source_head: 3045417821371a0e5220c3be90d9b46353dbf711
baseline_snapshot_id: 20260811000000
baseline_snapshot_sha256: 323c6e092cd9afabb438eaf233b7e63abd0195d5e1a91a5f5fe3fe5940699198
source_catalog_manifest_sha256: 6c71ff36a90993dc327557b4a1a64c0dfb27b347134ed89e7f126dae76c6ff9a
migration_ids:
  - 20260811000000
  - 20260811010000
  - 20260811020000
staging_project_id: mhpnszcorfzrvhyondxr
staging_endpoint: https://mhpnszcorfzrvhyondxr.supabase.co
migration_ledger_verified: three_versions_present_after_formal_apply
staging_apply: succeeded_2026-08-11
staging_catalog_verification: required_relations_rls_realtime_and_rpc_signatures_passed
staging_data_counts: auth_users_projects_documents_folders_and_sync_ledgers_all_zero
operational_provenance_classification: PARTIAL_OR_LATER_SCHEMA
operational_catalog_snapshot_resolution: source_only_exact_match_passed
protocol_3_document_rpc: implemented_and_postgresql_17_6_ci_passed
atomic_structure_rpc: implemented_and_postgresql_17_6_ci_passed
test_results: blank_chain_catalog_guard_rollback_rerun_and_rpc_conformance_passed
rollback_status: ci_and_prior_staging_failed_transactions_fully_rolled_back
production_changes: none
allowlist_enabled: false_actual_read
legacy_project_promotions: none
unverified_items:
  - staging document_commit and atomic_structure_commit round trip
  - staging replay, rollback, cancellation and server restart
  - staging snapshot restore procedure
  - existing-production exact-match ledger reconciliation design and approval
```

PR #4는 직접 병합하지 않았다. Stage 8은 Stage 7 staging 검증과 PR #4 병합 commit이
확정되기 전에는 시작하지 않는다.
