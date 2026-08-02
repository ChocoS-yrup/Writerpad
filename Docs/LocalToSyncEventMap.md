# 8-3 로컬 사건과 Sync v2 사건 매핑

- 감사일: 2026-07-26
- 기준 Git: `5a0744d80242c2a93ee3c0dd489460c326dda27d`
- 서버 계약: `Docs/SyncV2Contract.md`
- 범위: 현재 Swift 로컬 변경 경로의 분류와 향후 durable recorder 계약
- 비범위: SyncV2Store schema·migration, 서버 연결, queue 구현

## 결론

현재 `FutureChangeNotifying`는 로컬 마일스톤의 no-op 확장점으로만 유지할 수
있다. 영구 동기화 queue의 계약으로 확장하면 안 된다. 사건에 path, 본문
snapshot, 저장 generation, rename·move·reorder, purge generation이 없고
`record`가 오류나 결과를 반환하지 않기 때문이다.

8-4에서 별도 `DurableLocalChangeRecording` 경계를 만들고, 기존
`FutureChangeNotifying`는 호환 adapter를 거쳐 제거한다. 로컬 TXT 저장 성공은
그대로 확정하되 queue 등록 실패를 숨기지 않고 “로컬 저장됨·원격 보장 안 됨”
결과로 호출자와 UI에 전달한다.

## 현재 실제 사건

`LocalChangeEvent`에는 다음 7종만 있다.

| 현재 사건 | 실제 호출 위치 | 가진 정보 | 빠진 핵심 정보 |
|---|---|---|---|
| `appLaunched` | `RootView` | 없음 | 복구 대상·binding·queue 상태 |
| `documentSaved` | `EditorSessionModel` | project/document ID, hash | path, 본문, generation |
| `manuscriptVolumeCreated` | `LocalBinderCommandService` | volume/chapter ID | 25개 path·본문·순서·batch ID |
| `documentRestored` | `DocumentRestoreCoordinator` | ID, hash | 복원 본문·path·generation |
| `documentTrashed` | `LocalBinderCommandService` | root ID | subtree, 원래 path·본문·revision |
| `documentRestoredFromTrash` | `LocalBinderCommandService` | root ID | 새 path·본문·subtree |
| `documentPermanentlyDeleted` | `LocalBinderCommandService` | root ID | purge revision·generation·subtree |

호출은 로컬 작업이 성공한 뒤 `await`하지만 `record`는 nonthrowing이고 반환값이
없다. NoOp adapter 외에는 영구 보존이 없으므로 현재 호출 성공은 queue 등록
성공을 뜻하지 않는다.

현재 사건이 전혀 없는 변경:

- 작품 생성·이름 변경·정렬·삭제 요청·삭제 목록 이동·복원·영구 삭제
- 단일 TXT와 폴더 생성
- TXT·폴더 이름 변경과 이동
- 바인더 순서 변경
- 휴지통 전체 비우기의 단일 generation
- Windows 가져오기 완료와 서버 연결 승인
- 원고 내보내기

## 전체 사건 분류표

### 앱과 작품

| 로컬 사건 | 서버 분류 | 확정 정책 |
|---|---|---|
| 앱 시작 | 로컬 전용 | mutation이 아니다. 후속 구현은 queue 복구·session 복원·pull을 시작하지만 commit을 새로 만들지 않는다. |
| 마지막 작품 복원·작품 선택 | 로컬 전용 | 화면 상태이며 서버 사건이 아니다. |
| 작품 생성 | 프로젝트 `ensure_project` | 로컬 생성은 즉시 성공한다. 사용자가 sync를 켜거나 연결을 승인한 뒤 같은 project UUID와 이름으로 보장한다. |
| 작품 이름 변경 | 프로젝트 `ensure_project` | 같은 project UUID에 새 이름을 전달한다. 이름을 식별자로 사용하지 않는다. |
| 작품 목록 순서 변경 | 로컬 전용 | 서버에 작품 순서 계약이 없다. |
| 삭제 요청·취소 | 로컬 전용 | iPad의 단계적 삭제 UI 상태이며 서버 계약이 아니다. |
| 삭제 목록 이동 | 로컬 전용 | 서버 project delete/hide RPC가 없다. |
| 삭제 목록에서 복원 | 로컬 전용 | 서버 project 상태를 바꾸지 않는다. 기존 binding은 별도 SyncV2Store에서 보존한다. |
| 작품 영구 삭제 | 서버 계약이 없어 보류 | 기본 동작은 로컬 전용이다. 서버 project와 다른 기기 자료를 자동 삭제하지 않는다. |

작품 생성·이름 변경의 `ensure_project` 실패는 로컬 작업을 되돌리지 않는다.
다만 연결된 작품이면 queue/연결 상태에 명시적인 오류를 남긴다.

### TXT와 폴더

| 로컬 사건 | 서버 분류 | queue 단위 |
|---|---|---|
| TXT 생성 | v2 문서 commit + 숨은 tree-order commit | 새 UUID, base revision 0, full snapshot, 새 순서 |
| TXT 본문 저장 | v2 문서 commit | document UUID, path, full snapshot, save generation |
| TXT 이름 변경 | v2 문서 commit + 숨은 tree-order commit | 같은 UUID의 move와 새 순서 |
| TXT 폴더 이동 | v2 문서 commit + 숨은 tree-order commit | 같은 UUID의 move와 양쪽 부모 순서 |
| 폴더 생성 | 숨은 tree-order commit | 비어 있어도 parent의 child name으로 경로를 표현한다. |
| 폴더 이름 변경 | 하위 TXT v2 commit + 숨은 tree-order commit | 모든 descendant path move를 한 local batch로 기록 |
| 폴더 이동 | 하위 TXT v2 commit + 숨은 tree-order commit | 모든 descendant path move와 순서를 한 batch로 기록 |
| 폴더 삭제·휴지통 이동 | 하위 TXT tombstone + 숨은 tree-order commit | 각 descendant UUID 삭제와 live tree 제거 |
| 빈 폴더 삭제 | 숨은 tree-order commit | child list에서는 제거한다. 수신 기기의 기존 로컬 폴더 자동 제거는 별도 충돌 정책 전까지 보류한다. |

폴더는 서버 entity가 아니며 UUID commit 대상도 아니다. 폴더 아래 TXT는 각자의
UUID를 유지한다. 폴더 구조는 TXT의 relative path와 tree-order projection으로
재구성한다.

### 새 권과 25화

| 로컬 사건 | 서버 분류 | 확정 정책 |
|---|---|---|
| 새 권 생성 | v2 문서 commit + 숨은 tree-order commit | 권 폴더는 entity가 아니다. 25개 화를 각 UUID의 create로 만들고 tree-order를 함께 기록한다. |

로컬 파일·SwiftData transaction이 모두 성공한 뒤 25개 document snapshot과
tree-order snapshot을 SyncV2 SQLite의 하나의 batch transaction으로
기록해야 한다. 25개 중 일부만 queue에 들어간 상태를 성공으로 반환하면 안 된다.
서버 전송은 문서별 operation 순서로 나뉠 수 있지만 durable handoff는
all-or-nothing이어야 한다.

### 문서 휴지통과 영구 삭제

| 로컬 사건 | 서버 분류 | 확정 정책 |
|---|---|---|
| TXT 휴지통 이동 | v2 문서 commit + 숨은 tree-order commit | 같은 UUID를 원래 live server path의 tombstone으로 commit한다. iPad 휴지통 내부 path는 올리지 않는다. |
| 폴더 휴지통 이동 | 하위 TXT v2 tombstone + 숨은 tree-order commit | subtree의 모든 text UUID를 batch로 기록한다. |
| TXT·폴더 복원 | v2 문서 commit + 숨은 tree-order commit | 같은 UUID를 선택된 새 live path와 full content로 restore한다. |
| 문서 영구 삭제 | 숨은 trash-purge commit | 마지막 tombstone revision을 UUID별 purge revision으로 기록한다. 서버 row를 직접 삭제하지 않는다. |
| 휴지통 전체 비우기 | 숨은 trash-purge commit | 하나의 `empty_generation`과 대상 UUID별 purge revision을 한 snapshot으로 기록한다. |

로컬 휴지통의 충돌 회피 이름과 삭제 시각 metadata는 기기 로컬 표현이다.
교차 기기 의미는 document UUID의 tombstone, restore와 숨은 purge 문서로
전달한다.

서버에 아직 생성되지 않은 TXT를 로컬에서 바로 삭제한 경우에도 동일 UUID의
queue lane에서 create 다음 delete 순서를 유지해야 한다. 8-4의 coalescing은
다른 기기가 관찰할 의미를 바꾸지 않는다는 증명이 있을 때만 허용한다.

### 백업·가져오기·내보내기

| 로컬 사건 | 서버 분류 | 확정 정책 |
|---|---|---|
| 자동·수동 로컬 백업 생성 | 로컬 전용 | 백업 파일과 backup metadata는 업로드하지 않는다. |
| 백업 삭제·retention | 로컬 전용 | 서버 version 삭제와 무관하다. |
| 백업 복원 | v2 문서 commit | 복원 완료 TXT를 새 full snapshot·새 save generation으로 enqueue한다. |
| Windows 작품 검사 | 로컬 전용 | 읽기 전용 검사이며 서버 사건이 아니다. |
| Windows 작품 가져오기 | 보류 후 프로젝트 `ensure_project` + v2 문서 commit + tree-order | import 자체는 로컬에서 완료한다. 별도 사용자 확인 전 서버 연결·동명이름 자동 병합 금지. |
| 원고 TXT·PDF 내보내기 | 로컬 전용 | 동기화·백업·가져오기 수단으로 사용하지 않는다. |

Windows 가져오기 연결 확인 화면은 최소한 다음 선택을 구분해야 한다.

1. 새 서버 project UUID로 연결
2. 사용자가 권한을 가진 기존 project UUID에 명시적으로 연결
3. 연결하지 않고 로컬 전용 유지

이름이 같다는 이유로 2번을 자동 선택하지 않는다. 확인 후 `ensure_project`와
모든 live TXT create, tree-order의 durable batch가 완성되어야 서버 전송을
시작한다.

### 그 밖의 로컬 상태

화면 설정, 커서, 좌우 pane, 마지막 문서, 검색 query·결과, 바인더 펼침 상태,
프로젝트 목록 순서와 export 설정은 로컬 전용이다. 바인더의 사용자 지정
형제 순서만 `tree-order.json`에 투영한다.

## 빈 폴더 정책

Windows `save_tree_order`는 빈 폴더 자신의 key는 생략할 수 있지만 parent의
child name에는 그 폴더를 남긴다. iPad pull은 같은 snapshot에 포함된 live TXT
경로와 child name을 대조해, TXT가 아닌 항목을 물리 폴더와 로컬 metadata로
재구성한다. 중첩된 빈 폴더도 parent-first 순서로 만든다.

서버에는 여전히 folder table이나 folder UUID가 없다. 따라서 서버가 보존하는
것은 폴더의 독립 identity가 아니라 tree-order 시점의 이름·경로·계층이다.
iPad의 폴더 UUID는 이 경로에서 결정적으로 파생하며 일반 문서 UUID 계약에
포함하지 않는다. `__antigravity__` 실제 폴더나 파일은 만들지 않는다.

### 고정 루트 이름 계약

`tree_order["<root>"]`에는 UI 표시명이나 이모지를 넣지 않고 실제 저장 폴더의
basename만 기록한다. 현행 고정 루트는 다음 9개다.

`원고`, `캐릭터`, `설정집`, `메모장`, `스토리 플롯`, `흐름정리`, `복선`, `장소`, `휴지통`

스토리 플롯의 canonical 경로는 `메인/스토리 플롯`이다. iPad는 구형
`메인/플롯`, `메인/메인 스토리 틀`과 이전 Windows UI 표시명 payload를
canonical 이름으로 읽되, 신·구 실제 폴더가 공존하면 자동 병합·삭제하지 않고
구조 충돌로 중단한다. 초기 13-2 수신부가 만든 이모지 루트는 경로 기반 UUIDv5,
빈 디렉터리, 하위 metadata 없음이 모두 확인될 때만 정리한다.

## 듀얼 편집기 정책

현재 두 pane은 같은 document UUID를 열 수 있고 mutation·snapshot을 서로
전파한다. `EditorSessionModel.nextSaveGeneration`은 두 session의 실제 저장
제출에 단조 증가 generation을 공유한다. 하지만 이는 process 전역 값이며
재실행 가능한 document queue identity는 아니다.

동기화에서는 다음을 고정한다.

- lease는 pane별이 아니라 document UUID별 하나다.
- queue는 document UUID별 직렬 lane 하나다.
- recorder는 document UUID별 하나의 durable queue sequence를 SQLite
  transaction 안에서 발급한다.
- `localSaveGeneration`은 같은 실행 중 오래된 저장 완료를 거르는 ordering
  hint이며 영구 operation identity로 사용하지 않는다.
- durable handoff의 중복 판정은 재실행 후에도 유지되는 `batchID`와 이후
  발급되는 operation ID를 사용한다.
- 두 pane이 같은 snapshot을 연속 저장해도 오래된 generation이 새 queue
  상태를 덮어쓰지 않는다.
- 최신 full snapshot의 안전한 coalescing은 가능하지만 이미 inflight인
  operation ID를 바꾸거나 재사용하지 않는다.
- 한 pane의 저장·전환이 실패하면 다른 pane이 독립적인 server order를
  진행한 것으로 표시하지 않는다.

8-4에서는 process 전역 generation을 그대로 영구 ID로 저장하지 않고,
LocalDocumentStore의 save receipt와 document queue lane 사이에 UUID batch ID와
SQLite가 발급하는 document별 sequence를 둬 복구 가능한 handoff를 설계해야 한다.

## 새 durable recorder 계약

`FutureChangeNotifying`를 직접 변경하지 않고 새 protocol을 도입한다.
구체적인 SQLite schema는 8-4 범위다.

```swift
protocol DurableLocalChangeRecording: Sendable {
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult
}

struct LocalMutationBatch: Sendable {
    let batchID: UUID
    let projectID: ProjectID
    let localTransactionID: UUID?
    let mutations: [DurableLocalMutation]
}

enum DurableLocalMutation: Sendable {
    case ensureProject(name: String)
    case documentSnapshot(
        documentID: DocumentID,
        relativePath: RelativeDocumentPath,
        content: String,
        contentHash: ContentHash,
        localSaveGeneration: UInt64,
        isDeleted: Bool
    )
    case treeOrder(content: String, generation: UInt64)
    case trashPurge(content: String, generation: UUID)
}

enum DurableRecordResult: Sendable {
    case queued(operationIDs: [UUID])
    case localOnly
    case localSavedButNotQueued(reason: String)
}
```

본문은 호출 시점의 immutable full snapshot이어야 한다. recorder가 나중에
path에서 다시 읽으면 rename·후속 저장·삭제와 경합하므로 금지한다.

### 실패와 원자성

로컬 TXT 또는 구조 변경이 성공한 뒤 queue 등록이 실패한 경우:

1. 로컬 변경을 rollback하거나 저장 실패로 거짓 표시하지 않는다.
2. `localSavedButNotQueued`를 호출자에게 반환한다.
3. UI에는 “기기에 저장됨, 원격 반영 보장 안 됨” 고위험 상태를 표시한다.
4. batch ID와 재구성 가능한 handoff marker를 남겨 재실행 복구를 시도한다.
5. marker까지 기록할 수 없으면 사용자에게 즉시 진단·내보내기 가능한 오류를
   표시하고 성공 badge를 “동기화됨”으로 올리지 않는다.

파일 시스템·SwiftData·SQLite 사이에 하나의 ACID transaction은 만들 수 없다.
따라서 구조 명령의 기존 journal을 지운 뒤 best-effort notifier를 호출하는
현재 순서는 durable queue에 충분하지 않다. 8-4에서는 local transaction의
`metadataSaved` 이후 queue handoff를 기록하고, handoff 확인 후에만 journal을
정리하거나 별도 outbox marker로 복구해야 한다.

## 호환 adapter와 교체 순서

1. `NoOpFutureChangeNotifier`와 `.localOnly` composition은 8-4 설계가 구현될
   때까지 유지한다.
2. 새 recorder에 `LocalMutationBatch`를 전달하는 call site를 저장·구조
   transaction 경계에 추가한다.
3. 기존 `LocalChangeEvent`는 테스트·로그 호환 adapter에서만 생성한다.
4. 모든 기존 call site가 새 결과를 처리하는 테스트가 생긴 뒤
   `FutureChangeNotifying` 주입을 제거한다.
5. app launch는 mutation recorder가 아니라 별도 sync lifecycle coordinator로
   이동한다.

기존 enum에 path와 content를 계속 덧붙이는 방식은 batch 원자성, 명시적 실패,
project binding과 숨은 문서를 표현하지 못하므로 채택하지 않는다.

## 8-3 완료 판정

- 기획서가 열거한 모든 현재 로컬 변경 사건을 분류했다.
- 누락된 LocalChangeEvent와 실제 call site를 확인했다.
- 백업 복원·Windows 가져오기·내보내기·로컬 백업 정책을 고정했다.
- 작품 삭제와 빈 폴더의 서버 계약 부재를 명시했다.
- 같은 문서의 generation·lease·queue lane 정책을 고정했다.
- `FutureChangeNotifying`의 유지·교체·adapter 계획을 확정했다.
- 로컬 TXT, SwiftData, 서버와 SyncV2 SQLite는 변경하지 않았다.

다음 8-4는 이 매핑을 바탕으로 SyncV2Store schema와 migration을 설계하는
단계다. 이 문서는 8-4 설계나 구현 결과를 포함하지 않는다.
