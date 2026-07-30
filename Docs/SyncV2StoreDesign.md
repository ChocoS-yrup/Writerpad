# 8-4 SyncV2Store와 migration 설계

- 설계일: 2026-07-26
- 기준 Git: `5a0744d80242c2a93ee3c0dd489460c326dda27d`
- 입력 계약: `Docs/SyncV2Contract.md`, `Docs/LocalToSyncEventMap.md`
- 실행 가능한 schema fixture:
  `Scripts/fixtures/SyncV2StoreSchemaV1.sql`
- 비범위: Swift SQLite 구현, Supabase 연결, 인증, 실제 사용자 DB 생성

## 결론

Sync v2 상태는 `WriterPadSchemaV1`과 완전히 분리된 SQLite 파일에 둔다.
SwiftData V1에는 server revision, base content, operation, conflict, binding을
추가하지 않는다. 따라서 1~7단계 사용자가 8단계 이후 빌드로 이동할 때
SwiftData migration은 필요하지 않다.

SQLite schema version은 1에서 시작하며 최소 네 table 외에
`sync_batches`와 `schema_migrations`가 필요하다. `sync_batches`는 새 권 25화,
folder subtree, Windows import처럼 여러 operation을 하나의 durable handoff로
기록하기 위한 경계다.

## 저장 책임 분리

| 저장소 | 원본·책임 | 금지 |
|---|---|---|
| UTF-8 TXT | 사용자가 편집하는 로컬 원본 | 서버 실패로 rollback |
| SwiftData V1 | project/document 로컬 identity, path projection, 화면 상태 | 서버 revision·queue·base 본문 |
| SyncV2 SQLite | binding, server base, durable operation, conflict | 화면 상태와 로컬 백업 |
| LocalBackupStore | 사용자가 복원하는 로컬 snapshot | 서버 version ledger 역할 |

SyncV2Store가 열리지 않거나 migration에 실패해도 TXT·SwiftData·로컬 백업은
정상 동작해야 한다. 이때 서버 기능만 unavailable로 조립하고 원격 보장 실패를
명시한다.

## 파일과 실행 경계

향후 구현의 기본 위치:

```text
Application Support/WriterPad/SyncV2/sync-v2.sqlite3
```

- 사용자가 파일 앱에서 편집하는 `집필모드` 밖에 둔다.
- project 폴더 rename·삭제와 SQLite 파일 수명을 결합하지 않는다.
- access token·refresh token·비밀번호·이메일은 저장하지 않는다.
- `owner_subject`에는 인증 사용자의 UUID 같은 비민감 식별자만 허용한다.
- actor가 database handle과 migration을 소유한다.
- View와 ViewModel은 SQLite handle을 직접 참조하지 않는다.

각 connection에서 다음을 적용한다.

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA busy_timeout = 10000;
```

`foreign_keys`는 connection별 설정이므로 open할 때마다 확인한다. WAL과
`synchronous=FULL`은 operation ID와 pending payload의 강제 종료 내구성을
우선한 선택이다. 성능 완화는 실제 측정 없이 `NORMAL`로 바꾸지 않는다.

모든 read·write·checkpoint·migration은 하나의 `SyncV2Store` actor를 통과한다.
초기 구현은 actor가 소유한 write connection 하나로 시작한다. 별도 read
connection을 추가하려면 snapshot 일관성과 lifecycle 테스트가 먼저 필요하다.

## Schema V1

fixture는 SQLite `STRICT` table, foreign key, check constraint, partial index와
`PRAGMA user_version = 1`을 사용한다. fixture의
`design-fixture-v1` checksum은 설계 표식이며 제품 migration에는 실제 SQL
resource SHA-256을 고정해야 한다.

### `schema_migrations`

| 열 | 의미 |
|---|---|
| `version` | 순방향 schema 번호 |
| `name` | migration의 안정 이름 |
| `checksum` | 내장 SQL resource hash |
| `applied_at` | UTC 적용 시각 |

`user_version`은 빠른 분기에 사용하고 이 table은 이름·checksum 대조에 사용한다.
둘이 다르면 자동 수정하지 않고 migration mismatch로 서버 기능을 비활성화한다.

### `sync_projects`

| 열 | 의미 |
|---|---|
| `local_project_id` | SwiftData `ProjectID` UUID |
| `server_project_id` | Supabase project UUID, local-only이면 nil |
| `binding_kind` | local-only/new/existing/Windows import 구분 |
| `project_name` | `ensure_project`에 사용할 최신 이름 |
| `owner_subject` | 비민감 인증 user UUID, 미인증이면 nil 가능 |
| `created_at`, `updated_at` | UTC 시각 |

binding kind:

```text
local_only
new_server_project
existing_server_project
windows_import
```

local-only에는 server ID가 없어야 하고 나머지는 반드시 있어야 한다. 하나의
server project를 같은 설치의 여러 local project에 자동 연결하지 않도록
non-null server ID에 unique partial index를 둔다.

### `sync_documents`

| 열 | 의미 |
|---|---|
| `document_id` | 로컬·서버가 공유하는 영구 UUID |
| `local_project_id`, `project_id` | local binding과 server project UUID |
| `local_path` | 현재 기기에서의 path. 휴지통 path일 수 있음 |
| `server_path` | 마지막 server live/tombstone path |
| `server_revision` | 마지막 적용 server revision, 미생성은 0 |
| `base_content`, `base_hash` | 3방향 병합의 마지막 공통 server snapshot |
| `is_deleted` | 마지막 적용 server tombstone 상태 |
| `server_updated_at` | 마지막 server snapshot 시각 |
| `sync_state` | local/pending/synced/conflict/blocked |
| `last_error_code` | 안정 server 또는 local sync 오류 코드 |
| `next_document_sequence` | document lane의 다음 durable 순서 |
| `last_applied_operation_id` | 마지막 성공/replay operation |
| 생성·수정 시각 | 로컬 UTC 시각 |

`server_revision`이라는 이름을 사용해 편집 버퍼 revision과 구분한다.
`base_content` 중복은 병합 책임이므로 허용한다. 한 local project 안에서
`local_path`는 unique다.

숨은 문서도 이 table에 일반 UUID로 저장한다. Windows와 같은 방식으로
`UUIDv5(server_project_id, hidden_path)`를 사용하며 RFC 4122 byte 순서와
namespace 입력을 fixture로 고정하는 테스트가 구현 전에 필요하다.

### `sync_batches`

| 열 | 의미 |
|---|---|
| `batch_id` | 재실행 후에도 같은 durable handoff UUID |
| `local_project_id` | batch 소유 project |
| `local_transaction_id` | binder/import journal UUID, 없으면 nil |
| `batch_kind` | 변경 원인 |
| `mutation_count` | 기대 operation 수 |
| `payload_hash` | canonical batch payload SHA-256 |
| `status` | ready/processing/completed/attention |
| `last_error_code` | batch 수준 오류 |
| 생성·수정 시각 | UTC 시각 |

같은 batch ID와 같은 hash는 기존 operation ID 목록으로 멱등 수렴한다. 같은
batch ID와 다른 hash는 local `BATCH_ID_REUSED` 오류다.

canonical payload는 version이 있는 UTF-8 JSON으로 만들고 object key를
Unicode scalar 순서로 정렬하며 UUID lowercase string, path의 `/`, 정수,
boolean과 본문 원문을 포함한다. locale, Dictionary iteration 순서와 pretty
printing에 의존하지 않는다. 같은 canonical bytes의 SHA-256만 `payload_hash`로
저장한다.

### `sync_operations`

| 열 | 의미 |
|---|---|
| `queue_id` | SQLite 내부 FIFO row ID |
| `operation_id` | 서버에 재사용하는 영구 UUID |
| `batch_id` | all-or-nothing handoff 소유 batch |
| local/server project ID | binding snapshot |
| `owner_subject` | enqueue 당시 binding의 비민감 인증 user UUID |
| `document_id` | ensure-project만 nil |
| `device_id` | commit payload에 고정할 설치 UUID |
| `document_sequence` | document별 durable queue 순서 |
| `local_save_generation` | 같은 실행에서 stale save를 거르는 hint |
| `operation_kind` | ensure/document/tree-order/trash-purge |
| `project_name` | ensure-project payload에만 사용 |
| `base_revision`, `base_content` | commit·merge 기준 |
| `local_path` | 현재 로컬 파일 위치 |
| `relative_path` | 서버에 commit할 path |
| `content`, `content_byte_count`, `content_hash` | immutable payload |
| `is_deleted` | tombstone payload |
| `status`, `attempts` | queue 실행 상태 |
| `last_error_code`, `last_error_detail` | 안정 코드와 민감정보 제거 detail |
| `next_attempt_at` | retry backoff 시각 |
| 생성·수정 시각 | UTC 시각 |

operation kind:

```text
ensure_project
document_commit
tree_order
trash_purge
```

status:

```text
pending
inflight
retry_wait
conflict
completed
cancelled
blocked
```

`operation_id`, device ID, path, content hash, deleted 상태는 최초 enqueue 뒤
바꾸지 않는다. 새 payload는 새 operation ID다. 같은 document의 operation은
`document_sequence` 순서로만 실행한다.

sender는 현재 인증 subject가 operation의 `owner_subject`와 같을 때만 전송한다.
로그아웃 상태나 다른 계정이면 `AUTH_REQUIRED` 또는 account-mismatch 대기로
남기고 operation ID를 다른 사용자 payload로 재사용하지 않는다.

연속 저장에서 두 번째 operation의 `base_revision`은 앞 operation 성공 전까지
nil일 수 있다. 앞 operation 성공 transaction이 반환 revision과 content를
다음 pending row에 승계한다.

### `sync_conflicts`

| 열 | 의미 |
|---|---|
| `conflict_id` | local conflict UUID |
| operation/document ID | 원인 operation과 document |
| Base·Local·Remote·Merged | 충돌 원본과 미리보기 |
| `remote_revision`, `remote_path` | 해결 기준 server snapshot |
| `conflict_count` | 겹친 구간 수 |
| `created_at`, `resolved_at` | lifecycle 시각 |
| `resolution_kind` | local/remote/manual 선택 |

한 document에는 미해결 conflict 하나만 허용한다. conflict 해결은 기존
operation ID payload를 바꾸지 않고 새 operation ID를 만든다.

## 본문 중복과 큰 파일

전체 본문 중복은 다음 세 책임에만 허용한다.

1. `sync_documents.base_content`
2. active `sync_operations.content`
3. unresolved `sync_conflicts`의 네 원본

completed/cancelled operation payload와 resolved conflict의 retention은 후속
진단·개인정보 단계에서 기간을 정한 뒤 정리한다. 근거 없이 무기한 보존하거나
즉시 삭제하지 않는다.

UTF-8 10MiB를 초과한 TXT:

- TXT 저장은 정상 성공한다.
- 서버 RPC를 호출하지 않는다.
- document는 `blocked`, 오류는 local `CONTENT_TOO_LARGE`로 기록한다.
- blocked operation에는 byte count와 hash를 남기되, 공간 압박을 키우지 않도록
  초과 본문 전체를 SQLite에 복제하지 않는다.
- 본문이 제한 아래로 저장되면 새 batch와 operation으로 다시 평가한다.

## Actor API 초안

```swift
actor SyncV2Store {
    static func open(at url: URL) async -> SyncV2StoreAvailability

    func bindProject(_ binding: ProjectSyncBinding) throws
    func record(_ batch: LocalMutationBatch) throws -> DurableRecordReceipt
    func claimNextReadyOperation(at now: Date) throws -> SyncOperation?
    func markRetry(operationID: UUID, error: SanitizedSyncError, nextAttempt: Date) throws
    func markSuccess(operationID: UUID, response: CommitDocumentResult) throws
    func markConflict(operationID: UUID, snapshot: ConflictSnapshot) throws
    func resolveConflict(_ resolution: ConflictResolution) throws -> UUID
    func applyRemoteSnapshots(_ snapshots: [RemoteDocumentSnapshot]) throws
    func recoverInterruptedWork() throws
}

enum SyncV2StoreAvailability {
    case available(SyncV2Store)
    case unavailable(SyncV2StoreDiagnostic)
}
```

`open` 실패를 throw해 앱 조립 전체를 중단하지 않는다. AppEnvironment는
unavailable adapter를 주입하고 로컬 기능을 계속 제공한다.

## Transaction 경계

### 최초 생성·migration

1. directory와 database file을 연다.
2. connection PRAGMA를 설정하고 실제 값을 읽어 확인한다.
3. header·schema version·migration checksum을 검사한다.
4. `BEGIN IMMEDIATE` 안에서 다음 migration 하나를 적용한다.
5. `foreign_key_check`, `quick_check`, 예상 table·index를 확인한다.
6. schema_migrations와 user_version을 같은 transaction에서 갱신하고 commit한다.

### batch durable handoff

하나의 `BEGIN IMMEDIATE`에서:

1. batch ID와 canonical payload hash를 검사하거나 insert한다.
2. 필요한 project/document row를 검증한다.
3. document별 `next_document_sequence`를 읽고 증가시킨다.
4. 모든 operation을 immutable snapshot으로 insert한다.
5. 실제 insert 수가 `mutation_count`와 같은지 확인한다.
6. document sync state를 pending/blocked로 갱신한다.
7. commit한다.

중간 하나라도 실패하면 batch·operation·sequence 증가를 전부 rollback한다.
새 권 25화, folder subtree, import가 일부만 durable해지는 상태를 허용하지 않는다.

### dequeue와 재시작

- 앞선 nonterminal document sequence가 없는 ready row만 claim한다.
- ensure-project는 document lane 없이 claim할 수 있고, document 계열은
  `base_revision`이 non-nil일 때만 claim한다.
- claim transaction에서 status를 inflight로 바꾸고 attempts를 증가시킨다.
- 앱 재시작 시 inflight는 같은 operation ID·payload·attempts를 유지한 채
  pending 또는 retry-wait로 되돌린다.
- processing batch도 operation 상태를 재계산해 ready 또는 attention으로
  복구한다.
- operation ID를 새로 만들지 않는다.

### 성공

한 transaction에서:

1. operation을 completed로 표시한다.
2. document의 server path·revision·base·hash·삭제 상태를 응답으로 갱신한다.
3. `last_applied_operation_id`를 저장한다.
4. 다음 document operation의 nil base revision/content를 승계한다.
5. 남은 nonterminal operation 유무로 document와 batch 상태를 갱신한다.

`status=replayed`도 같은 성공 transaction을 사용한다.

### retry·conflict·해결

- 네트워크·AUTH_REQUIRED 등 재시도 가능 오류는 attempts와
  `next_attempt_at`을 같은 transaction에서 기록한다.
- 영구 입력 오류는 blocked로 두고 자동 무한 재시도하지 않는다.
- revision conflict는 operation을 conflict로 바꾸고 conflict row와 document
  상태를 한 transaction에서 기록한다.
- 해결 시 remote revision/base를 기준으로 새 operation ID를 insert하고,
  conflict의 resolution을 같은 transaction에서 확정한다.

### pull

active operation이나 unresolved conflict가 없는 document만 새 remote snapshot으로
갱신한다. queue가 있으면 pull이 base와 local payload를 덮어쓰지 않는다.
파일 적용과 SQLite 적용 사이에는 별도 복구 marker가 필요하며 구체 설계는
pull 구현 단계에서 작성한다.

## Migration 정책

### 1~7단계 사용자

- Sync DB가 없으면 새 V1 DB를 만든다.
- 기존 SwiftData V1과 TXT를 scan하거나 수정하지 않는다.
- 사용자가 sync 연결을 승인할 때만 binding과 initial operation batch를 만든다.
- 따라서 `WriterPadMigrationPlan`은 계속 V1 하나와 빈 stage 목록을 유지한다.

### 향후 V1 → V2+

- 순방향 migration만 지원한다.
- 각 단계는 `(fromVersion, toVersion, name, SQL checksum)`을 코드에 고정한다.
- 한 번에 한 version만 올린다.
- migration 전에 SQLite backup API로 일관된 pre-migration copy를 만든다.
- WAL 파일을 열린 상태에서 단순 복사하지 않는다.
- migration transaction 안에서 table 재작성·데이터 검증·version 갱신을 끝낸다.
- downgrade와 destructive 자동 재생성은 하지 않는다.
- 앱보다 높은 user_version이면 read/write하지 않고 sync만 비활성화한다.
- user_version 0인데 사용자 table이 이미 있으면 빈 DB로 추정하지 않는다.

## 실패·복구 정책

| 실패 | 처리 | 로컬 앱 |
|---|---|---|
| directory·DB open 실패 | unavailable diagnostic, 재시도 제공 | 계속 실행·저장 |
| migration SQL·checksum 실패 | transaction rollback, pre-migration copy 보존 | 계속 실행·저장 |
| `SQLITE_FULL` | queue 보장 실패 표시, 공간 확보 후 재시도 | 이미 성공한 TXT 유지 |
| `SQLITE_BUSY/LOCKED` | bounded retry 후 unavailable/attention | TXT 저장과 분리 |
| foreign key·constraint 실패 | programmer/data-integrity 오류로 차단 | 해당 sync batch만 실패 |
| quick/integrity check 실패 | DB를 닫고 손상본 보존, 자동 삭제 금지 | 로컬 모드 |
| 앱 강제 종료 | WAL 복구 후 inflight 동일 ID 재대기 | 로컬 자료 유지 |
| 더 높은 schema version | downgrade 금지, read/write 차단 | 로컬 모드 |

### DB 손상

Sync DB에는 미전송 본문과 conflict 원본이 있으므로 “서버에서 다시 받으면 된다”는
이유로 삭제하면 안 된다.

1. write를 중단하고 diagnostic에 SQLite extended code를 남긴다.
2. 가능한 경우 SQLite backup/recovery API로 별도 recovery copy를 만든다.
3. 원본 DB와 WAL/SHM을 명시적인 timestamp 이름으로 보존한다.
4. 사용자 확인 없이 빈 DB로 교체하거나 queue를 재구성하지 않는다.
5. 새 DB가 필요하면 TXT를 기준으로 resync할 수 있지만 기존 operation ID,
   server base와 conflict를 잃는 위험을 먼저 알린다.

로그에는 본문, token, 이메일, 개인 절대 경로를 넣지 않는다. project/document/
operation UUID, schema version, SQLite code와 상대 path의 제한된 진단만 허용한다.

### 저장 공간 부족

TXT 저장과 SQLite enqueue가 모두 공간 부족일 수 있지만 결과를 합치지 않는다.
TXT가 성공하고 SQLite만 실패했다면 로컬 저장 성공을 유지하고
`localSavedButNotQueued`를 표시한다. outbox marker조차 쓸 수 없는 경우 메모리
상태만으로 원격 보장을 약속하지 않고 사용자가 공간 확보 후 다시 저장하도록
안내한다.

## 검증 전략

현재 fixture 자동 검증:

- schema version 1
- WAL
- `quick_check`
- 필수 5개 domain table
- project/document/batch/operation 정상 insert
- local path unique constraint
- 중복 operation ID 거부
- 실패한 multi-operation batch 전체 rollback
- inflight의 같은 operation ID pending 복구

향후 Swift 구현 전에 추가할 테스트:

- 모든 connection의 foreign key 활성화
- UUIDv5 hidden document fixture의 Windows 일치
- batch ID 같은 payload replay와 다른 payload 거부
- document sequence 동시 할당
- 앞 operation 성공 후 base revision 승계
- 25화·folder subtree·import 원자 enqueue
- conflict 생성·해결·새 operation ID
- 10MiB 경계와 초과 blocked 상태
- disk full, busy, corrupt header, checksum mismatch
- V1→가상 V2 forward migration과 중간 강제 종료

## 8-4 완료 판정

- SQLite schema와 transaction 경계를 fixture와 문서로 고정했다.
- WAL·foreign key·actor 직렬화 원칙을 확정했다.
- SwiftData V1 무변경과 migration 불필요 결정을 확정했다.
- 새 Sync DB의 version 1과 향후 순방향 migration 절차를 정의했다.
- migration 실패·공간 부족·DB 손상·강제 종료 정책을 정의했다.
- 빈 폴더·작품 삭제·10MiB 초과 정책을 숨기지 않았다.
- 앱 target, TXT, SwiftData, 서버와 실제 SyncV2 SQLite를 변경하지 않았다.

이 문서는 8단계 설계 완료 지점이다. 다음 9-1의 Supabase package·설정 구현을
포함하지 않는다.
