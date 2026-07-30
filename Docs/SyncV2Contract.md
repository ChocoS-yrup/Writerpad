# Sync v2 서버 계약 감사

- 감사일: 2026-07-26
- 기준 Git: `5a0744d80242c2a93ee3c0dd489460c326dda27d`
- 범위: 현행화 기획서 8-2, SQL·Windows v2의 서버에서 관찰 가능한 계약
- 비범위: Swift 구현, 로컬 사건 매핑, SQLite 설계, 서버 접속·변경

## 결론

Swift 클라이언트는 `projects`, `project_members`, `documents`,
`document_versions`를 인증된 읽기 전용 snapshot으로 사용하고, 모든 서버
변경은 여섯 RPC를 통해야 한다. `edit_leases`는 직접 읽지 않으며 lease token은
lease RPC 응답으로만 받는다.

현재 두 SQL과 Windows v2가 사용하는 RPC 이름·파라미터·오류 코드는 일치한다.
두 번째 SQL은 `ensure_project(uuid, text)`를 최종 재정의한다. 제공된 현재 파일
기준으로 첫 SQL의 같은 함수와 본문도 동일하므로, 두 번째 SQL은 schema 추가가
아닌 안전한 보정·재적용이다.

이 계약을 Swift로 옮기는 데 새 서버 migration은 필요하지 않다. 이미 적용된
두 migration을 다시 실행하지 않는다. 운영 DB 적용 상태는 후속 서버 연결
단계에서 migration history 또는 읽기 전용 schema 조회로 별도 확인해야 한다.

## 계약의 권위와 SQL 관계

1. `20260714000000_supabase_v2_protocol.sql`
   - schema, table, index, RLS, 읽기 grant, 여섯 RPC, Realtime publication을 정의한다.
2. `20260714010000_windows_v2_client_support.sql`
   - `ensure_project(uuid, text)`만 `create or replace`하고 execute 권한을 다시 고정한다.
   - 최종 배포 정의는 이 파일의 함수다.
   - 현재 제공본의 함수 signature와 본문은 첫 SQL의 정의와 byte 단위로 동일하다.

앱이 migration을 실행하거나 table을 생성해서는 안 된다. 계약 변경이 필요하면
구버전 Windows와 새 iPad의 호환성 테스트를 먼저 만들고 승인된 순방향
migration을 별도로 작성한다.

## 테이블과 직접 읽기 경계

| 테이블 | 핵심 열 | 앱 직접 접근 |
|---|---|---|
| `projects` | `project_id`, `owner_id`, `name`, 생성·수정 시각 | authenticated `SELECT` |
| `project_members` | `project_id`, `user_id`, `role` | authenticated `SELECT` |
| `documents` | 현재 path·본문·revision·삭제 상태와 current version | authenticated `SELECT` |
| `document_versions` | operation별 불변 full snapshot과 hash | authenticated `SELECT` |
| `edit_leases` | holder·device·token·만료 시각 | 직접 접근 불가 |

모든 테이블은 RLS가 enable 및 force되어 있다. 프로젝트 구성원에게만 다음
읽기 정책이 적용된다.

- `projects_read_members`
- `project_members_read_members`
- `documents_read_members`
- `document_versions_read_members`

역할은 `owner`, `editor`, `viewer`다. viewer 이상은 snapshot을 읽고 editor
이상은 변경 RPC를 실행할 수 있다. 소유자는 `projects.owner_id`로도 권한이
성립한다. public 앱 표면에서 authenticated 역할에는 네 읽기 테이블의
`SELECT`와 여섯 RPC의 `EXECUTE`만 부여된다. RLS 내부 판정용
`private.has_project_role`에도 실행 권한이 있지만 데이터 변경 표면은 아니다.
table의 `INSERT`, `UPDATE`, `DELETE`는 부여되지 않는다.

`document_versions`에는 본문 전체가 들어가며 프로젝트 viewer도 RLS 범위
안에서 읽을 수 있다. `edit_leases`에는 direct `SELECT` policy와 grant가 모두
없어 token을 table 조회로 노출하지 않는다.

### Windows가 실제 수행하는 snapshot 읽기

단일 문서 충돌 처리:

```text
from documents
select document_id, relative_path, content, revision,
       is_deleted, deleted_at, updated_at
filter document_id == 대상 UUID
limit 1
```

프로젝트 pull:

```text
from documents
select document_id, relative_path, content, revision,
       is_deleted, deleted_at, updated_at
filter project_id == 연결된 프로젝트 UUID
```

서버 query에는 명시적인 `order`가 없다. Windows 적용부는 수신 목록을
`trash-purge`, tombstone, live 문서 순으로 나눈 뒤 revision을 사용해 로컬에서
정렬한다. Swift도 서버 반환 순서에 의존하면 안 된다.

Windows는 현재 `projects`, `project_members`, `document_versions`를 직접
조회하지 않는다. 이 세 table의 `SELECT` 권한은 서버 계약에는 있지만 초기
Swift 동기화 경로에 필수는 아니다.

## RPC 계약

### `ensure_project(p_project_id, p_name) -> jsonb`

- 인증이 필요하다.
- 이름은 trim 후 비어 있으면 안 된다.
- 없는 UUID이면 현재 사용자를 owner로 하는 project와 owner member를 만든다.
- 존재하면 editor 이상만 이름을 갱신할 수 있다.
- project UUID advisory transaction lock을 사용한다.

응답:

```json
{"project_id":"uuid","name":"trimmed name"}
```

### `acquire_edit_lease(p_document_id, p_device_id, p_ttl_seconds) -> jsonb`

- 기본 TTL은 90초이며 요청값을 30~120초로 clamp한다.
- editor 이상만 획득할 수 있다.
- 만료 lease는 제거한다.
- 같은 사용자·같은 device는 같은 token을 유지하며 갱신된다.
- 다른 사용자 또는 device가 보유하면 `LEASE_CONFLICT`다.

응답 필드: `document_id`, `lease_token`, `device_id`, `expires_at`.

### `renew_edit_lease(p_document_id, p_device_id, p_lease_token, p_ttl_seconds) -> jsonb`

- editor 이상만 갱신할 수 있다.
- 사용자, device, token 중 하나라도 다르거나 만료됐으면 `LEASE_EXPIRED`다.
- TTL 규칙과 응답은 acquire와 같다.

### `release_edit_lease(p_document_id, p_device_id, p_lease_token) -> boolean`

- 인증과 non-null 파라미터를 요구한다.
- 현재 사용자·device·token이 모두 일치하는 row만 삭제한다.
- 삭제했으면 `true`, 일치하는 lease가 없으면 오류가 아니라 `false`다.

### `get_edit_lease(p_document_id, p_device_id) -> jsonb`

- viewer 이상이 호출할 수 있다.
- 활성 lease가 없으면 `{"document_id":"uuid","state":"available"}`다.
- 있으면 state는 `held_by_me` 또는 `held_by_other`이고 `expires_at`을 포함한다.
- holder 식별자와 lease token은 반환하지 않는다.

### `commit_document(...) -> jsonb`

파라미터:

```text
p_document_id uuid
p_project_id uuid
p_base_revision bigint
p_operation_id uuid
p_device_id uuid
p_relative_path text
p_content text
p_is_deleted boolean = false
p_lease_token uuid = null
```

응답 필드:

```text
status             committed | replayed
document_id        uuid
version_id         uuid
operation_id       uuid
operation_kind     create | update | move | delete | restore
revision           bigint
relative_path      text
is_deleted         boolean
content_hash       lowercase SHA-256 hex
committed_at       timestamptz
```

#### 생성

- `base_revision == 0`
- 같은 `document_id`가 없어야 한다.
- `is_deleted == false`
- `lease_token == nil`
- 같은 프로젝트의 live path가 비어 있어야 한다.
- 성공 revision은 1이고 operation kind는 `create`다.

#### 기존 문서 변경

- `base_revision > 0`
- project와 document UUID가 일치해야 한다.
- 현재 server revision과 base revision이 같아야 한다.
- non-nil token과 유효한 사용자·device lease가 필요하다.
- live 문서로 저장할 때 다른 UUID의 live path와 충돌하면 안 된다.
- 성공 revision은 기존 revision + 1이다.
- 삭제 성공 시 lease를 제거하고, 그 외 성공은 lease를 90초 연장한다.

operation kind 판정 우선순위:

1. live에서 deleted로 바뀌면 `delete`
2. deleted에서 live로 바뀌면 `restore`
3. path만 바뀌고 content가 같으면 `move`
4. 그 밖에는 `update`

#### 멱등 재시도

`operation_id`는 전체 `document_versions`에서 unique다. 이미 처리된 operation의
다음 값이 모두 같으면 lease 검사 전에 원래 결과를 `replayed`로 반환한다.

- document ID
- project ID
- base revision
- device ID
- relative path
- content SHA-256
- deleted 상태
- authenticated user

하나라도 다르면 `OPERATION_ID_REUSED`다. replay 비교에는 lease token이
포함되지 않으며, 응답의 version·revision·hash·시각은 최초 commit 값이다.

## 입력 제한

### 상대 경로

- nil 또는 빈 문자열 금지
- 앞뒤 공백 금지
- PostgreSQL 문자 길이 최대 1,024
- `/`로 시작 금지
- `\` 금지
- `//` 금지
- `.` 또는 `..` path component 금지
- `/`로 끝나는 경로 금지

서버 규칙은 현재 iPad `PathPolicy`의 Windows 안전 이름 규칙보다 느슨하다.
Swift는 더 엄격한 기존 로컬 정책을 유지하면서 서버 제한도 만족해야 한다.

### 본문과 hash

- `p_content`는 non-null text다.
- UTF-8 byte 길이 최대 10,485,760 bytes(10 MiB)다.
- hash는 UTF-8 bytes의 SHA-256 lowercase 64자리 hex다.
- 로컬 TXT 저장 성공은 이 서버 제한과 독립이어야 한다.
- 제한 초과는 로컬 저장 실패가 아니라 원격 전송 불가 상태로 다뤄야 한다.

## 안정 오류 코드

```swift
enum SyncV2RemoteErrorCode: String, Codable, Error, CaseIterable {
    case authRequired = "AUTH_REQUIRED"
    case forbidden = "FORBIDDEN"
    case invalidArgument = "INVALID_ARGUMENT"
    case documentNotFound = "DOCUMENT_NOT_FOUND"
    case documentAlreadyExists = "DOCUMENT_ALREADY_EXISTS"
    case revisionConflict = "REVISION_CONFLICT"
    case operationIDReused = "OPERATION_ID_REUSED"
    case leaseRequired = "LEASE_REQUIRED"
    case leaseConflict = "LEASE_CONFLICT"
    case leaseExpired = "LEASE_EXPIRED"
    case pathConflict = "PATH_CONFLICT"
}
```

모든 안정 오류는 PostgreSQL `P0001`의 message로 전달된다. 클라이언트는
전체 오류 문자열 검색이 아니라 RPC error message에서 안정 코드를 분리하고,
알 수 없는 값은 원문을 보존하는 unknown 오류로 처리해야 한다.

- `LEASE_CONFLICT` detail: `expires_at`
- `REVISION_CONFLICT` detail: `current_revision`, `current_hash`, `is_deleted`
- commit에서 token이 nil이면 `LEASE_REQUIRED`
- token이 틀렸거나 lease가 없거나 만료됐으면 `LEASE_EXPIRED`

## Swift 요청·응답 타입 초안

아래는 wire 계약 초안이며 아직 앱 target에 추가하지 않는다. Swift의 편집
버퍼 `revision`과 구분하기 위해 앱 내부 속성은 `serverRevision`으로 명명하고
CodingKeys만 `revision` 또는 `p_base_revision`에 연결한다.

```swift
struct EnsureProjectParameters: Encodable {
    let projectID: UUID
    let name: String
    enum CodingKeys: String, CodingKey {
        case projectID = "p_project_id"
        case name = "p_name"
    }
}

struct AcquireLeaseParameters: Encodable {
    let documentID: UUID
    let deviceID: UUID
    let ttlSeconds: Int
    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case ttlSeconds = "p_ttl_seconds"
    }
}

struct RenewLeaseParameters: Encodable {
    let documentID: UUID
    let deviceID: UUID
    let leaseToken: UUID
    let ttlSeconds: Int
    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case leaseToken = "p_lease_token"
        case ttlSeconds = "p_ttl_seconds"
    }
}

struct ReleaseLeaseParameters: Encodable {
    let documentID: UUID
    let deviceID: UUID
    let leaseToken: UUID
    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case leaseToken = "p_lease_token"
    }
}

struct GetLeaseParameters: Encodable {
    let documentID: UUID
    let deviceID: UUID
    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
    }
}

struct CommitDocumentParameters: Encodable {
    let documentID: UUID
    let projectID: UUID
    let baseServerRevision: Int64
    let operationID: UUID
    let deviceID: UUID
    let relativePath: String
    let content: String
    let isDeleted: Bool
    let leaseToken: UUID?
    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case projectID = "p_project_id"
        case baseServerRevision = "p_base_revision"
        case operationID = "p_operation_id"
        case deviceID = "p_device_id"
        case relativePath = "p_relative_path"
        case content = "p_content"
        case isDeleted = "p_is_deleted"
        case leaseToken = "p_lease_token"
    }
}
```

Swift 기본 key 변환 전략에 암묵적으로 의존하지 않는다.

```swift
struct ProjectRPCResult: Decodable {
    let projectID: UUID
    let name: String
    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
    }
}

enum LeaseState: String, Decodable {
    case available
    case heldByMe = "held_by_me"
    case heldByOther = "held_by_other"
}

struct LeaseMutationResult: Decodable {
    let documentID: UUID
    let leaseToken: UUID
    let deviceID: UUID
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case leaseToken = "lease_token"
        case deviceID = "device_id"
        case expiresAt = "expires_at"
    }
}

struct LeaseInspectionResult: Decodable {
    let documentID: UUID
    let state: LeaseState
    let expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case state
        case expiresAt = "expires_at"
    }
}

enum CommitStatus: String, Decodable {
    case committed
    case replayed
}

enum RemoteOperationKind: String, Decodable {
    case create, update, move, delete, restore
}

struct CommitDocumentResult: Decodable {
    let status: CommitStatus
    let documentID: UUID
    let versionID: UUID
    let operationID: UUID
    let operationKind: RemoteOperationKind
    let serverRevision: Int64
    let relativePath: String
    let isDeleted: Bool
    let contentHash: String
    let committedAt: Date
    enum CodingKeys: String, CodingKey {
        case status
        case documentID = "document_id"
        case versionID = "version_id"
        case operationID = "operation_id"
        case operationKind = "operation_kind"
        case serverRevision = "revision"
        case relativePath = "relative_path"
        case isDeleted = "is_deleted"
        case contentHash = "content_hash"
        case committedAt = "committed_at"
    }
}

struct RemoteDocumentSnapshot: Decodable {
    let documentID: UUID
    let relativePath: String
    let content: String
    let serverRevision: Int64
    let isDeleted: Bool
    let deletedAt: Date?
    let updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case relativePath = "relative_path"
        case content
        case serverRevision = "revision"
        case isDeleted = "is_deleted"
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
    }
}
```

Supabase가 반환하는 timestamptz fractional precision을 수용하는 날짜 decoder가
필요하다. `contentHash`는 decode 후 64자리 lowercase hex인지 검증한다.

## 숨은 문서와 UI 경계

Windows v2는 다음 고정 path를 일반 document UUID·revision·operation·lease
계약으로 commit한다.

```text
__antigravity__/tree-order.json
__antigravity__/trash-purge.json
```

- `tree-order.json`: 프로젝트 바인더 순서 snapshot
- `trash-purge.json`: UUID별 purge revision과 전체 비우기 generation
- 일반 원고 목록과 검색·편집 UI에서는 제외한다.
- Realtime payload는 적용 원문이 아니라 pull wake-up 신호로만 사용한다.

서버에는 folder table 또는 folder UUID가 없다. 빈 폴더 자체와 폴더 identity는
이 계약만으로 표현되지 않는다. 현재 Windows의 tree-order payload가 어느
범위까지 빈 폴더를 보존하는지는 8-3 사건 매핑에서 결정해야 하며, 이번
감사에서 새 서버 표현을 추측하지 않는다.

## 확인된 차이와 보류

- iPad에는 아직 이 요청·응답 타입, 인증, device UUID, lease, queue, pull이 없다.
- Windows는 `renew_edit_lease`를 heartbeat에서 사용하지만 제공된 정적 감사
  대상의 commit 경로는 acquire·release·commit을 직접 호출한다.
- Windows pull은 `documents` 전체 snapshot을 project ID로 읽고 서버 정렬을
  요청하지 않는다.
- project 영구 삭제 RPC, folder entity, 회원가입, 공유 역할 변경 RPC는 없다.
- `document_versions`는 읽을 수 있지만 Windows 정상 pull에는 사용하지 않는다.
- server schema 적용 상태와 실제 RLS 동작은 이번 읽기 전용 파일 감사만으로
  확인할 수 없다.

## 자동 검증 결과

- `Scripts/audit_sync_v2_contract.sh`: 통과
  - table·RPC·오류 코드·제한·RLS·응답 필드·Windows 호출 경계
  - 두 SQL의 `ensure_project` 정의 동일성
- `Scripts/test_sync_v2_reference.py`: 5개 통과
  - SQLite queue 재실행 보존
  - inflight operation의 같은 ID pending 복구
  - 다음 operation의 server revision 승계
  - 비겹침 3방향 자동 병합
  - 겹침 시 Base·Local·Remote 보존
- `test_dual_v2_runner.py`: 3개 통과
- 제공된 Python 12개 파일 syntax compile: 통과
- 참조 테스트 함수: 총 74개 식별
- 미실행: PyQt6와 `mode_writing`, `main`, `security_manager` 등 Windows 앱 전체
  의존성이 제공되지 않아 `test_sync_v2.py`, `test_sync_state.py`,
  `test_writing_data.py` 전체 실행은 불가
- 미실행: PostgreSQL/Supabase 연결이 없으므로 SQL 실제 적용, RPC, RLS,
  Realtime 통합 테스트는 수행하지 않음

## 8-2 완료 판정

- SQL과 Windows v2의 관찰 가능한 계약을 Swift 타입으로 옮길 수 있게 고정했다.
- 두 SQL의 중복·보정 관계를 기록했다.
- 직접 table read와 RPC write 경계를 구분했다.
- 현재 계약 채택만을 위한 새 migration은 필요 없다고 결론냈다.
- 로컬 TXT, SwiftData, 서버, SyncV2 SQLite는 변경하지 않았다.
- 실제 iPad 검증은 이 문서 감사의 완료 조건이 아니며 수행하지 않았다.

다음 8-3에서는 이 계약을 현재 iPad 로컬 사건과 매핑해야 한다. 이 문서는
8-3 구현 또는 매핑 결과를 포함하지 않는다.
