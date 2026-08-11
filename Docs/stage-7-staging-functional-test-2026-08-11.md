# Stage 7 staging functional test — 2026-08-11

## 판정

```yaml
status: PASSED_WITH_MANAGED_SERVER_RESTART_UNVERIFIED
staging_project_id: mhpnszcorfzrvhyondxr
pr_head_at_resume: 162f14591d30c290e8939360d70af8c8f8bfd6bc
contract_version: 0.2.0
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
allowlist_enabled_after_test: false
enabled_allowlist_row_count_after_test: 0
production_changes: none
pr_merged: false
stage_8_started: false
```

Contract `0.2.0`과 적용된 migration/RPC 코드는 수정하지 않았다. 첫 probe의
`LEGACY + protocol 3` 성공은 서버 실패가 아니라 잘못된 테스트 기대였으므로 아래처럼
재분류했다.

```text
LEGACY + protocol 3 atomic_structure_commit
expected: allowed
actual: committed
result: PASS
automatic promotion: none
```

`sync-contract/protocol.json`은 protocol 3의 write mode에 `LEGACY`, `MIGRATING`,
`ID_BASED`를 모두 포함하고 structure matrix에서 `LEGACY + protocol 3`을
`allowed=true`, provenance `CONTRACT_BATCH`로 규정한다. 첫 commit 뒤에도
`project_sync_settings=0`이어서 자동 승격은 발생하지 않았다.

## 합성 fixture

실제 사용자 정보나 작품은 사용하지 않았다. 비밀번호, JWT, access token,
service-role key 및 auth metadata는 기록하지 않았다.

```yaml
owner_test_user_id: 096cc935-0a3f-4c6c-9985-d302c138bc44
unauthorized_test_user_id: 6b504154-b680-4a42-a3db-dcf6bf7f6206
project_id: 71000000-0000-4000-8000-000000000001
writer_device_id: 76000000-0000-4000-8000-000000000001
migration_id: 936f0571-5fe3-4d37-affc-9cced9183d1c
folders:
  - 73000000-0000-4000-8000-000000000101
  - 73000000-0000-4000-8000-000000000201
  - 73000000-0000-4000-8000-000000000301
documents:
  - 74000000-0000-4000-8000-000000000401
  - 74000000-0000-4000-8000-000000000402
```

project는 owner의 `auth.uid()`를 설정한 뒤 정식 `public.ensure_project` 경계로
생성했다. mode 전환은 정식 begin/validate/complete migration RPC만 사용했다.
fixture 및 append-only 원장은 삭제하거나 덮어쓰지 않았다.

## mode 및 protocol 검증

- LEGACY/epoch 0에서 protocol 3 atomic structure commit: `committed`, 자동 승격 없음
- 명시적 begin: `MIGRATING/epoch 1`, migration lock 생성
- 올바른 lock owner의 protocol 3 write: `committed`
- 잘못된 device: `MIGRATION_LOCKED`
- stale epoch: `STALE_MIGRATION_EPOCH`
- validation: `valid=true`, issues `[]`
- 명시적 complete: `ID_BASED/epoch 1`
- ID_BASED protocol 1 write: `PROTOCOL_TOO_OLD`
- ID_BASED protocol 2 write: `PROTOCOL_TOO_OLD`
- 필수 capability 누락: `CAPABILITY_MISMATCH`
- 잘못된 canonical digest: `CONTRACT_DIGEST_MISMATCH`

## atomic structure 검증

두 intent 성공 batch는 folder create와 root tree order를 한 번에 적용했다. 두 번째
intent가 존재하지 않는 parent로 move하도록 만든 실패 batch는
`FOLDER_NOT_FOUND`, `failed_sequence=2`, `applied=false`를 반환했다. 첫 intent의
rename도 rollback되어 대상 folder는 원래 이름과 revision 1을 유지했다.

별도 batch로 folder rename, move, delete, restore를 순서대로 실행했다. 최종 상태는
다음과 같다.

```yaml
name: Child Restored
parent_folder_id: 73000000-0000-4000-8000-000000000201
revision: 5
is_deleted: false
```

대소문자만 다른 기존 root folder 이름으로 rename한 normalize collision은
`PATH_CONFLICT`, `applied=false`였고 대상 folder의 이름과 revision은 변하지 않았다.

## document commit 검증

- 일반 본문 create: `committed`, revision 1, UTF-8 19 bytes
- 의도적인 빈 본문 create: `committed`, revision 1, 0 bytes,
  SHA-256 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- 동일 일반 문서 request 재전송: `replayed`, 중복 revision 없음
- 같은 batch/operation ID의 변경 payload: `BATCH_ID_REUSED`, `applied=false`
- atomic structure rename/move: structure revision 1 → 2 → 3
- 본문 update/delete/restore: content revision 1 → 2 → 3 → 4

복원 뒤 일반 문서는 `Doc Renamed.md`, 지정 folder 아래, content revision 4,
structure revision 3, `is_deleted=false`다. document version은 일반 문서 4개와 빈 문서
1개로 총 5개다.

## replay 및 cancellation

새 SQL 탭과 새 `request.jwt.claim.sub` 설정에서 빈 문서의 원 요청을 같은 ID와 같은
payload로 재전송했다. allowlist가 꺼진 상태에서도 기존 결과가 `replayed`로 반환됐고
document revision 1, version count 1, 전체 document count 2가 그대로였다. 관리형
Supabase 서버 자체 pause/restart는 승인 범위에 따라 실행하지 않았다.

실패 batch의 blocked operation을 취소한 결과:

```yaml
first_cancel: cancelled
same_event_replay: already_cancelled
new_event_after_cancel: already_cancelled
cancel_requested_event_count: 1
derived_state: cancelled
terminal_operation_cancel: OPERATION_TERMINAL
terminal_cancel_event_count: 0
```

## RLS 및 storage-name

두 번째 합성 사용자는 `READ ONLY` transaction, `role authenticated`에서 대상
project/folder/document/operation을 모두 0건으로만 볼 수 있었다. `ensure_project`를
통한 변경 시도는 `FORBIDDEN`이었다. owner membership은 1건, project name은 그대로다.

`sync-contract/conformance_vectors/storage-name-v1.json`의 15개 vector를 staging
PostgreSQL 함수 `private.storage_name_v1_result`와 직접 비교했다.

```yaml
transaction_read_only: on
total: 15
passed: 15
failed: []
```

## 최종 append-only 증거와 row count

마지막 조회는 `transaction_read_only=on`에서 수행하고 rollback했다.

```yaml
project_mode: ID_BASED
migration_epoch: 1
migration_status: completed
migration_validation: valid
folders: 3
documents: 2
document_versions: 5
project_members: 1
sync_batches: 16
sync_batch_results: 16
sync_operations: 18
sync_operation_events: 55
sync_operation_attempts: 18
operation_states:
  completed: 15
  blocked: 2
  cancelled: 1
event_types:
  enqueued: 18
  dispatch_started: 18
  committed: 15
  blocked: 3
  cancel_requested: 1
attempt_outcomes:
  committed: 15
  blocked: 3
allowlist_enabled: false
any_enabled_allowlist_rows: 0
```

pre-validation 단계에서 거부된 protocol/capability/digest 요청과 exact replay는 새
immutable batch/operation row를 만들지 않는다. business failure로 접수된 batch와
operation은 append-only 증거로 남아 있다.

## 실패 및 재시험 내역

1. 최초 LEGACY protocol 3 성공을 잘못 실패로 분류했다. Contract 원문 대조 후
   서버·migration 수정 없이 PASS로 재분류했다.
2. Supabase SQL Editor가 8,250자 묶음을 빈 query로 제출해 DB 실행 전에 UI 오류가
   발생했다. 데이터 변경은 없었다. 이후 6KB 이하의 guarded transaction으로 나눠
   화면 입력을 확인한 뒤 실행했다.
3. 마지막 읽기 전용 audit 초안이 존재하지 않는 `project_sync_migrations.status` 열을
   참조해 rollback됐다. source schema의 실제 `completed_at`/`migration_epoch`을 사용해
   읽기 전용 query만 수정했고 최종 증거를 수집했다.

기능 실패 뒤 수동 row 보정, ledger 수정, migration 재작성 또는 ID 재사용 재시도는
수행하지 않았다.

## 제한사항 및 종료 상태

- managed Supabase 실제 pause/restart: 미검증(명시적 금지)
- 새 연결/새 인증 세션 response-loss replay: 통과
- staging snapshot restore 절차: 미검증
- production migration/ledger reconciliation: 미수행
- production allowlist/project 승격: 미수행
- PR #4 병합: 미수행
- Stage 8: 시작하지 않음

Contract `0.2.0` allowlist는 모든 write test 묶음 종료 시 다시 비활성화했으며 최종
활성 행 수는 0이다. PR #4에는 이 증거와 handoff 문서만 반영한다.
