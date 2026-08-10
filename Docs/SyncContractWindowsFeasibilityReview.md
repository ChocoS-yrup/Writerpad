# Windows sync-contract 구현 가능성 검토

## 검토 식별자

- 검토일: 2026-08-10
- 공유 저장소 기준: `ChocoS-yrup/Writerpad@e0e84d4523d7d3fe0518d6ed957a1c2329b0a1f3`
- 계약 기준 commit: `fb882d7312f803266a18ea9c07a226f23c1a88a5`
- 계약 버전: `0.1.0-draft.1`
- RFC 8785 canonical byte length: `11640`
- canonical SHA-256: `d64bccd8ecbd2566a5d0bb9cec74fc2866cafd0cc7b8ebeea68e16be8bc8872e`
- Windows 공개 구현 기준: `ChocoS-yrup/Writerpad_main@539cbd39074475b59cbd729923fbc2bc5ee5a7f9`
- Windows DB 증거 기준: `evidence/windows-99516096-20260810-055633/sync_v2.sqlite3`
  (`SHA-256 512e131e038f51dc3c4b0ae281cfef8b2ccd82a57ffa4f4bec2390bdbde5ba77`)
- 검토 방식: 소스와 migration을 읽기 전용으로 대조했다. 앱, 서버, 계약, DB, incident 데이터는 변경하거나 실행하지 않았다.

현재 Windows 작업 폴더에는 미커밋 파일이 있으므로 검토 근거로 사용하지 않았다. 재현 가능한 원격
`main`과 `sync-contract`가 모두 가리키는 `539cbd39074475b59cbd729923fbc2bc5ee5a7f9`의 Git
객체를 기준으로 삼았다. 공유 저장소의 `Scripts/fixtures/SyncV2StoreSchemaV1.sql`부터
`SyncV2StoreSchemaV4.sql`까지는 현재 런타임 schema가 아니라 후속 설계 fixture로 구분했다.
보존 DB 복사본은 SQLite URI의 `mode=ro&immutable=1`로 열어 `sqlite_master`만 확인했다.
`PRAGMA user_version`은 0이었으며 batch 또는 append-only attempt table은 없었다.

## 결론

계약의 서버 및 Windows 구현은 가능하다. 다만 아래 여섯 항목은 계약 내부 규칙끼리 충돌하거나
wire 의미가 정의되지 않아 현재 문구 그대로는 상호 운용 가능한 구현을 만들 수 없다. 6단계 계약
최종화에서 이 항목을 먼저 고쳐야 하며, 수정 전에는 서버 구현 단계로 넘어가면 안 된다.

그 밖의 차이는 기존 구현에 기능이 아직 없다는 의미이며 계약의 구현 불가능 사유는 아니다.

## 계약 차단 항목

### C-01. 불변 operation과 같은 operation_id rebase가 충돌한다

근거:

- `sync-contract/protocol.json:155-165`는 `base_revision`과 `payload_sha256`을 포함한 intent를 생성 후
  불변으로 정의한다.
- `sync-contract/protocol.json:415-418`은 같은 `operation_id`의 payload가 달라지면
  `OPERATION_ID_REUSED`라고 정의한다.
- `sync-contract/test_vectors/05-revision-conflict-rebase.json`은 충돌 뒤 `base_revision`과 병합 결과를
  바꾸면서 같은 `operation_id`로 재시도해 성공하도록 요구한다.
- 공개 Windows 구현도 `sync_v2_store.py:613-642`에서 같은 operation 행의 base와 content를 바꾼다.

이 세 규칙은 동시에 만족할 수 없다. 다음 중 하나를 계약에서 선택해야 한다.

1. 권장: 충돌한 원 operation을 보존하고 새 `operation_id`를 가진 rebase operation을 만들며
   `supersedes_operation_id`로 연결한다.
2. 대안: `operation_id`를 논리 intent 식별자로 재정의하고, 전송 payload마다 별도의 불변
   `attempt_payload_id` 또는 `rebase_generation`을 정의한다. 이 경우 INV-002와 replay key도 함께 바꿔야 한다.

### C-02. protocol별 capability와 test vector가 일치하지 않는다

근거:

- `protocol.json`은 `operation_attempt_history`를 protocol 3부터 지원한다고 선언한다.
- `06-response-loss-idempotent-retry.json:6,31-35`는 protocol 2 client가 해당 capability를 선언한다.
- `protocol.json:112-152`는 모든 operation이 필수 contract metadata를 가진 batch를 참조하도록
  일반 규칙을 둔다.
- `10-legacy-structure-write-to-id-based.json:45-53`은 protocol 1 client의 queue에 `batch_id`를
  넣고, 같은 vector에서 legacy content write를 허용한다. 그러나 protocol 1 client가 필수 batch
  metadata를 어떻게 제공하는지는 정의되지 않았다.
- `03-legacy-first-connect.json`은 initial queue나 action input에 없는 operation을 최종 queue에서
  `completed`로 요구하며 그 operation의 `batch_id`도 정의하지 않는다.

필요한 계약 수정:

- TV-006을 protocol 3으로 올리거나 `operation_attempt_history.since_protocol`을 2로 바꾼다.
- protocol 1/2에 batch 규칙을 적용할지 명시한다. legacy adapter가 server-side synthetic batch를
  만든다면 writer/build/digest의 출처와 synthetic 표시 규칙을 정의한다.
- TV-003의 operation과 batch를 입력 단계에 명시한다.
- ID_BASED에서 protocol 1 content-only write를 유지할 경우 contract metadata 예외 또는 adapter
  경계를 명시한다. 예외가 없다면 minimum content protocol을 올려야 한다.

### C-03. `cancelled` 상태를 intent와 attempt만으로 도출할 수 없다

근거:

- `protocol.json:186-212`의 attempt outcome에는 `cancelled`가 없다.
- `protocol.json:214-238`은 `cancelled`를 terminal state로 두면서 모든 current state가 immutable
  intent와 append-only attempts에서 도출되어야 한다고 요구한다.
- 공개 Windows 구현 `sync_v2_store.py:410-432,613-642,661-710`은 operation 행의 status를 직접
  `cancelled`, `pending`, `conflict`로 바꾸며 별도 상태 이력을 남기지 않는다.

필요한 계약 수정:

- append-only `operation_state_events`에 cancellation, supersession, recovery 전이를 정의하거나,
- attempt outcome에 cancellation을 추가하고 cancellation reason과 대체 operation을 기록하거나,
- state derivability 요구를 완화한다.

성공 뒤 과거 오류를 보존하려면 현재 Windows의 `attempts` 숫자와 `last_error` 한 칸만으로는 부족하며,
별도 attempt/event 표가 필요하다.

### C-04. atomic structure commit의 필수 여부와 wire boundary가 불명확하다

근거:

- `protocol.json:40-52`는 protocol 3의 atomic structure boundary를 “when available”이라고 표현한다.
- `protocol.json:370-380`은 ID_BASED protocol 3 write를 원자 적용 또는 전체 거부하도록 요구한다.
- INV-008(`protocol.json:439-442`)도 선언된 structure transaction을 all-or-nothing으로 요구한다.
- 현재 계약 package에는 `atomic_structure_commit`의 request/response JSON schema, operation 정렬,
  batch payload hash 계산 대상, 부분 replay 결과 및 atomic boundary 식별 규칙이 없다.

필요한 계약 수정:

- `atomic_structure_commit`을 ID_BASED 승격과 구조 write의 필수 server capability로 명시한다.
- 요청/응답 schema에 batch metadata, ordered intents, expected revisions, migration epoch, payload digest,
  replay result와 표준 error envelope를 정의한다.
- “when available”을 제거하거나 capability가 없을 때 승격 및 write를 거부하는 오류를 정의한다.

### C-05. normalized storage name 알고리즘이 정의되지 않았다

근거:

- migration validation은 `protocol.json:283-290`에서 같은 부모의 normalized storage name 중복을
  금지하지만 normalization 알고리즘을 정의하지 않는다.
- 공개 서버는 `documents_live_path_uidx`에서 PostgreSQL text의 정확한 path equality만 사용한다
  (`20260714000000_supabase_v2_protocol.sql:55-77`).
- Windows 파일시스템은 case와 Unicode 정규화, 끝의 점·공백, 예약 이름을 별도로 처리해야 한다.

동일 이름 판정이 플랫폼마다 달라지면 migration 성공 여부와 `PATH_CONFLICT`가 달라진다. 계약에
Unicode normalization form, case 처리, separator, trailing dot/space, Windows reserved name 처리와
비교 대상 UTF-8 bytes를 규범적으로 정의해야 한다.

### C-06. 기존 행을 필수 immutable metadata로 정직하게 backfill할 규칙이 없다

근거:

- INV-009(`protocol.json:443-446`)는 모든 operation이 writer와 canonical digest까지 추적되도록 요구한다.
- 보존 Windows DB와 공개 Windows source에는 batch가 없고 operation에도 build, protocol, contract
  version, digest가 없다 (`Writerpad_main@539cbd3:sync_v2_store.py:68-122`).
- 공개 서버의 `document_versions`에는 `operation_id`와 `device_id`는 있지만 `batch_id`, client build,
  protocol, contract digest와 capabilities가 없다
  (`20260714000000_supabase_v2_protocol.sql:85-109`).

과거 행에 알 수 없는 값을 만들어 넣으면 immutable provenance가 거짓이 된다. 계약은 다음을 정의해야 한다.

- enforcement 시작 revision 또는 시각
- pre-contract history를 나타내는 명시적 legacy provenance
- legacy history에는 어떤 invariant를 적용하지 않는지
- 새 contract batch부터 NOT NULL과 immutability를 강제하는 전환 규칙

## Windows 동기화 DB 필드 대응

보존 DB에서 확인한 실제 table은 `sync_projects`, `sync_project_imports`, `sync_documents`,
`sync_folders`, `sync_operations`, `sync_tree_barriers`, `sync_folder_rename_intents`이다.

| 계약 개념 | 보존 Windows DB 및 공개 구현 | 설계 fixture | 판정 |
|---|---|---|---|
| project identity | `sync_projects.local_key`, `project_id`, `project_name` | V1은 `local_project_id`, `server_project_id`, `binding_kind`로 확장 | 기존 ID 유지 가능 |
| project_sync_mode | 없음 | 없음 | additive server/client projection 필요 |
| document identity/revision | `sync_documents.document_id`, `revision`, path, tombstone, base | V1은 `server_revision`, state, last operation을 명확히 정의 | 대응 가능 |
| folder identity/revision | 보존 DB에 `sync_folders(folder_id,parent_folder_id,path,name,revision,tombstone)`가 있으나 공개 commit에는 없음 | V2 operation 확장, V3 `sync_folders` | source publication과 versioned migration 필요 |
| immutable batch | 보존 DB와 공개 commit에 없음 | V1 `sync_batches`는 id/kind/payload hash/state만 보유 | contract metadata columns 또는 별도 metadata 표 필요 |
| immutable operation intent | 보존 DB의 한 행에 ID, base, payload, state를 함께 저장하며 `document_id`가 필수 | V1/V2도 intent와 state를 한 행에 저장 | entity-generic 새 intent 표 필요 |
| append-only attempt | 없음; `attempts`, `last_error`만 갱신 | 없음 | 새 attempt 표 필요 |
| mutable state projection | `sync_operations.status` | V1/V2의 `status`, `attempts`, errors | 유지 가능하나 event/attempt에서 재생성 가능해야 함 |
| pending/blocked/completed | 공개 구현은 pending/inflight/conflict/completed/cancelled 중심 | V1/V2는 계약 상태 집합을 포함 | migration 뒤 호환 가능 |
| operation_id | UUID unique | UUID unique | 유지 가능 |
| batch_id | 없음 | V1부터 UUID primary key | 공개 구현에는 신규 도입 |
| device_id | manager와 server RPC에는 있으나 공개 local operation 행에는 없음 | V1/V2 operation에 존재 | 새 batch의 writer_device_id로 승격 가능 |

`Scripts/fixtures/SyncV2StoreSchemaV1.sql:93-229`는 batch와 operation queue의 목표 형태를 제공하고,
V2는 folder operation, V3는 `sync_folders`, V4는 folder migration 완료 표식을 추가한다. 그러나 fixture는
실행 가능한 Windows migration chain이나 현재 런타임 `_initialize`에 연결되어 있지 않다.

## 서버 schema/RPC 대응

| 계약 개념 | 공개 서버 구현 | 필요한 위치 |
|---|---|---|
| document revision/tombstone | `documents`, `document_versions` | 기존 표 유지 |
| document idempotency | `document_versions.operation_id UNIQUE`, replay payload 검증 | generic operation registry와 연결 |
| device identity | `document_versions.device_id`, edit lease device | 새 batch writer와 연결 |
| folders | 공개 commit에는 없음 | authoritative `folders`와 immutable folder versions 추가 |
| tree_order | Windows가 `__antigravity__/tree-order.json` 문서로 저장 | LEGACY adapter만 유지; ID_BASED용 ID tree 표 필요 |
| contract allowlist | 없음 | `sync_contract_allowlist`와 batch 생성/commit 공통 validator |
| immutable batch | 없음 | `sync_batches`와 metadata immutability trigger/RPC |
| operation/attempt/state | document version만 존재 | `sync_operations`, `sync_operation_attempts`, state projection 추가 |
| project_sync_mode | 없음 | `project_sync_settings` one-to-one 표 권장 |
| migration audit/lock | project advisory transaction lock만 존재 | `project_sync_migrations`와 project row/advisory lock 조합 |
| minimum write gate | 없음 | 모든 write RPC가 호출하는 private validator |
| atomic structure commit | 없음 | 단일 PostgreSQL transaction의 새 RPC |

기존 `commit_document`는 revision, lease, operation replay와 document projection update를 한 transaction에서
처리하므로 content write의 기반으로 재사용할 수 있다
(`20260714000000_supabase_v2_protocol.sql:501-715`). 다만 path 변경과 삭제도 같은 RPC가 처리하므로
ID_BASED의 legacy content-only 예외를 적용하려면 server-side mode gate가 이 RPC 자체 또는 그 앞의
유일한 wrapper에 반드시 들어가야 한다. 클라이언트 UI 검사만으로는 write gate가 되지 않는다.

## 구현 위치와 호환성 판정

1. **immutable batch metadata**: 새 server `sync_batches`와 local batch metadata에 추가 가능하다. metadata
   update를 trigger 또는 metadata 전용 immutable 표로 차단하고 상태는 별도 projection으로 둔다.
2. **operation/attempt/state 분리**: 가능하다. intent와 attempts는 append-only, current state는 projection으로
   둔다. C-01과 C-03을 먼저 해결해야 한다.
3. **contract allowlist**: server table과 private validator가 권위가 되어야 한다. batch 생성과 모든 write
   RPC가 같은 validator를 호출해야 한다.
4. **project_sync_mode**: `project_sync_settings(project_id PK, mode, migration_epoch)`를 권장한다. 행이 없는
   기존 project는 LEGACY/epoch 0으로 해석하면 기존 행을 즉시 갱신하지 않아도 된다.
5. **migration lock/epoch**: `project_sync_migrations`에 audit row를 append하고 active migration unique
   constraint를 둔다. 시작/완료 RPC에서 project advisory lock과 row lock을 함께 사용한다.
6. **ID_BASED write gate**: private common validator와 모든 구조 write RPC 안에 둔다. 기존
   `commit_document`에도 ID_BASED에서 path, parent, delete 상태 불변 검사를 넣어야 한다.
7. **legacy content editing**: 기존 live `document_id`, 동일 path/parent, 삭제 상태 불변, revision/lease 성공인
   경우 기술적으로 유지 가능하다. C-02의 metadata adapter 규칙이 먼저 필요하다.
8. **atomic_structure_commit**: PostgreSQL function 한 번의 transaction으로 구현 가능하다. project lock,
   batch/operation replay 검사, 모든 expected revision과 tree invariant 검사를 마친 뒤 projection과 version을
   함께 commit한다. C-04의 wire schema가 먼저 필요하다.
9. **operation_id 호환**: UUID를 그대로 유지할 수 있다. 현재 server uniqueness는 document ledger 안에서만
   보장되므로 global registry 도입 전 document/folder/tree ledger 사이 중복을 preflight해야 한다.
10. **device_id 호환**: 기존 UUID를 새 batch의 `writer_device_id`로 사용할 수 있다.
11. **batch_id 호환**: 공개 Windows와 server에는 없으므로 신규 값이다. fixture의 UUID batch ID는 사용할
    수 있지만 과거 행에는 거짓 metadata를 생성하지 말아야 한다.

## 배포 데이터에 영향을 주지 않는 migration 순서

아래는 설계 순서이며 이번 검토에서는 실행하지 않았다.

1. 운영 schema version, RPC signature, row count, cross-ledger operation ID 중복과 live path/name 충돌을
   읽기 전용으로 점검하고 별도 snapshot을 보존한다.
2. 계약에서 C-01부터 C-06까지 해결하고 최종 version/commit/canonical digest를 동결한다.
3. 기존 table을 rewrite하지 않고 allowlist, batch, generic operation, attempt, project sync settings,
   migration audit, ID tree용 새 table을 additive migration으로 만든다.
4. 기존 project는 row 부재 또는 default를 통해 LEGACY/epoch 0으로 유지한다. 자동 승격하지 않는다.
5. pre-contract document versions는 legacy provenance로 그대로 두고 enforcement 경계 이후 새 write만
   immutable batch와 generic operation을 필수화한다.
6. 새 RPC를 기존 RPC 옆에 배포한다. LEGACY project의 기존 document/content 경로는 계속 허용하고
   구조 write gate는 server에서 mode별로 적용한다.
7. Windows와 iPad가 같은 동결 계약 metadata를 전송하고 공통 vector를 통과한 뒤 allowlist entry를
   활성화한다.
8. 새 테스트 project 하나만 LEGACY에서 MIGRATING으로 수동 전환하고 lock/epoch, folder/document IDs,
   tombstones, normalized names와 ID tree를 검증한다.
9. validation 성공 뒤에만 그 테스트 project를 ID_BASED로 수동 승격한다. 실패 시 LEGACY로 자동
   downgrade하지 않고 MIGRATING 상태와 진단을 보존한다.
10. 실기기 종단간 검증이 끝날 때까지 기존 배포 project와 보존 incident project는 LEGACY로 유지한다.

## 근거 부족

- 운영 Supabase의 실제 migration ledger와 `pg_catalog` snapshot은 조회하지 않았다. 저장소의 공개 SQL이
  실제 배포 상태와 같은지는 서버 구현 전에 읽기 전용 preflight로 확인해야 한다.
- 공개 Windows commit 뒤의 미커밋 source 내용은 재현 가능한 구현 근거에서 제외했다. 단, 보존 DB의
  실제 schema는 위 SHA의 복사본에서 별도로 확인했다.
- 과거 server ledger 전체에서 entity 종류를 가로지르는 `operation_id` 충돌이 없는지는 데이터 audit가
  필요하다.
- `minimum_client_builds`의 platform별 key 형식과 build 비교 규칙은 계약에 정의되어 있지 않다.

## 변경 및 안전 확인

- 이 review 문서 외 계약, Windows 앱, iPad 앱, 서버 source를 수정하지 않았다.
- local/운영 DB migration을 실행하지 않았다.
- 보존 DB 복사본은 immutable read-only mode로 schema만 읽었다.
- 동기화 작업을 실행하거나 재시도하지 않았다.
- 서버 데이터와 보존 incident를 변경하지 않았다.
