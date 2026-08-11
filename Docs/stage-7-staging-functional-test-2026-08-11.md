# Stage 7 staging functional test — 2026-08-11

## 판정

```yaml
status: BLOCKED_TEST_EXPECTATION_CONTRACT_CONFLICT
staging_project_id: mhpnszcorfzrvhyondxr
pr_head_at_test: 1fb51232a29d6fdc6940c70650cca13b4a430eab
contract_version: 0.2.0
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
allowlist_enabled_after_test: false
production_changes: none
pr_merged: false
stage_8_started: false
```

승인된 첫 필수 항목은 “LEGACY 상태에서 protocol 3 요청이 거부되는지”였다.
실제 staging에서는 요청이 `committed`, `applied=true`로 처리됐다. 승인된 안전
조건에 따라 allowlist를 같은 transaction 안에서 즉시 `enabled=false`로 복구하고
나머지 기능 테스트를 실행하지 않았다.

이 결과는 서버가 released contract `0.2.0`을 어긴 것이 아니다. 오히려 contract가
LEGACY protocol 3 structure write를 명시적으로 허용하고 있어, 승인된 테스트 기대와
pinned contract 사이에 충돌이 있다.

## Contract 근거

`sync-contract/protocol.json`의 protocol 3 정의는 write project mode에 `LEGACY`,
`MIGRATING`, `ID_BASED`를 모두 포함한다. 같은 파일의 structure write matrix는
다음을 규범적으로 정의한다.

```yaml
project_mode: LEGACY
protocol_version: 3
allowed: true
provenance_kind: CONTRACT_BATCH
server_behavior: Validate the released contract batch and use atomic_structure_commit.
```

서버의 `private.validate_contract_request`도 실제 mode/epoch 일치를 검증한 뒤 protocol
3과 contract batch를 검증한다. LEGACY protocol 3을 차단하는 조건은 없다. 따라서
staging 결과, 서버 source 및 canonical contract가 서로 일치한다.

“LEGACY에서는 protocol 3을 거부한다”가 의도된 최종 규칙이라면 서버-only 수정으로
처리할 수 없다. Stage 6 contract version과 canonical digest를 먼저 개정하고, 이미
적용된 migration 파일을 수정하지 않은 채 새 corrective migration을 작성해야 한다.

## 합성 fixture

비밀번호, JWT, access token, service-role key 및 auth metadata는 기록하지 않았다.

```yaml
owner_test_user_id: 096cc935-0a3f-4c6c-9985-d302c138bc44
unauthorized_test_user_id: 6b504154-b680-4a42-a3db-dcf6bf7f6206
project_id: 71000000-0000-4000-8000-000000000001
writer_device_id: 76000000-0000-4000-8000-000000000001
folder_id: 73000000-0000-4000-8000-000000000101
batch_id: 71000000-0000-4000-8000-000000000101
operation_id: 72000000-0000-4000-8000-000000000101
```

두 사용자는 staging Authentication 관리자 경계에서 auto-confirm 합성 계정으로
생성했다. project는 owner의 `auth.uid()`를 설정한 뒤 `public.ensure_project`로
생성했다. project 또는 membership table을 임의 삽입하지 않았다. 두 번째 사용자는
membership이 없다.

project 생성 직후 `project_sync_settings`가 없음을 확인했다. 즉 project는 정직한
`LEGACY/epoch 0` 상태였고 자동 승격되지 않았다.

## 실행한 probe

allowlist enable, protocol 3 RPC 호출, allowlist disable을 하나의 transaction에서
순서대로 실행했다. 예외가 발생해도 transaction rollback으로 원래 false 상태가
복구되도록 구성했다.

요청은 contract `0.2.0`, canonical digest, protocol 3, 모든 필수 capability,
RFC 8785 payload/batch digest 및 `CONTRACT_BATCH` provenance를 사용했다.

실제 응답:

```yaml
kind: atomic_structure_commit_success
status: committed
applied: true
result_revision: 1
created_folder_count: 1
project_sync_settings_count: 0
allowlist_enabled_after_transaction: false
```

## 보존된 append-only 증거

실패 판정 후 별도 `READ ONLY` transaction에서 확인하고 `ROLLBACK`했다.

```yaml
transaction_read_only: on
operation_state: completed
operation_events:
  - sequence: 1
    type: enqueued
  - sequence: 2
    type: dispatch_started
  - sequence: 3
    type: committed
operation_attempts:
  - attempt_number: 1
    rpc_name: atomic_structure_commit
    outcome: committed
    result_revision: 1
```

증거 row를 삭제하거나 수정하지 않았다.

## 최종 row count

```yaml
auth.users: 2
projects: 1
project_members: 1
folders: 1
folder_versions: 0
documents: 0
document_versions: 0
tree_orders: 0
project_sync_settings: 0
project_sync_migrations: 0
sync_batches: 1
sync_operations: 1
sync_operation_attempts: 1
sync_operation_events: 3
sync_batch_results: 1
```

## 실행하지 않은 항목

첫 필수 항목의 기대 불일치 직후 중단했으므로 다음은 실행하지 않았다.

- 명시적 `LEGACY → MIGRATING → ID_BASED/epoch 1` migration
- folder/document rename, move, delete, restore
- multi-intent 실패 rollback
- 일반/빈 문서 create, update, delete, restore
- 동일 request replay 및 changed-payload ID reuse
- 새 연결/새 인증 세션 response-loss replay
- cancellation, duplicate cancellation 및 terminal cancellation
- 두 번째 사용자의 RLS 격리
- staging Unicode/storage-name vector
- 실제 managed server restart

## 필요한 다음 결정

다음 중 하나를 명시적으로 선택해야 한다.

1. Contract `0.2.0` 유지: 첫 테스트 기대를 “LEGACY protocol 3 contract batch 허용”으로
   수정하고, 보존 fixture에서 새 ID를 사용해 나머지 기능 테스트를 별도 승인한다.
2. LEGACY protocol 3 금지: Stage 6 contract를 새 version/digest로 개정한 뒤 새
   server corrective migration을 작성·검증·적용한다.

이 결정 전에는 allowlist를 활성화하거나 PR #4를 병합하거나 Stage 8을 시작하지 않는다.
