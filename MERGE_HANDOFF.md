# merge/ipad-unified — 인수인계

이 문서 하나로 이어받을 수 있게 적는다. 새 세션(Codex든 Claude Code든)은
**이 브랜치와 이 문서만** 읽으면 된다. 다른 대화 기록은 필요 없다.

```
worktree   /private/tmp/WriterPad-Merge
브랜치     merge/ipad-unified
병합       codex 계보(6e9ad49) ← backup/ipad-local-20260815(2058980)
보존 사본  /private/tmp/WriterPad-Merge.bak-20260818
```

---

## 1. 무슨 일이었나

2026-08-11 `20d60ea`에서 두 갈래로 갈라져 6주 따로 굴렀다.

- **codex 계보** (32커밋) — 폴더 동기화, 프로젝트 백업. 로컬 스키마 4.
- **backup 계보** (23커밋) — 사건 기반 상태 계산(스키마 5), 인증, 유니코드 접기 동결.

codex를 기준선으로 backup을 병합했다. 65개 파일은 자동 병합됐고, 충돌 34덩어리 중
20개는 앞서 해소돼 있었다. **남은 19덩어리(본문 14 + 시험 5)를 이번에 닫았다.**

두 계보가 **같은 문제를 각자 따로 구현**해서 생긴 충돌이라 "어느 쪽이 최신인가"로는
고를 수 없었다. Windows 클라이언트 측에 계약 해석을 교차로 물어 결정했다.
질문지와 답변은 저장소 최상위의 `교차검증_*.md`에 있다.

---

## 2. 결정 세 가지와 근거

### 결정 B — 원격 폴더 존재 판정 (`SyncV2LocalSnapshotApply.swift`)

**두 안을 다 버리고 세 갈래 타입으로 바꿨다.**

```swift
enum SyncV2RemoteFolderProjection {
    case unsupported            // 폴더 모형 없음 → 옛 tree_order 추측 허용
    case unavailable(code:)     // 받지 못함 → 판정 보류 (짓지도 지우지도 않음)
    case known(Set<String>)     // 서버가 정한다. 비어 있어도 답이다
}
```

- codex의 `hasRemoteFolderProjection: Bool`과 backup의
  `remoteLiveFolderPaths: Set<String>`을 **한 값으로 접었다.**
- `Bool`도 빈 `Set`도 "서버에 폴더가 없다"와 "받지 못했다"를 구별하지 못한다.
  구별하지 못하면 실패한 pull에서 tree_order 이름으로 **유령 폴더**를 짓는다.
- `preparePull`이 `.unavailable`로 되돌리고 `prepareRemoteFolders`만 올릴 수 있다.
  빈 집합으로 되돌리면 "서버가 폴더를 다 지웠다"와 같은 값이 되어 더 위험하다.

소비처 3곳을 `liveFolderPaths(_:)` / `mayInferFolders(_:)` 두 헬퍼로 통일했다.

### 결정 C — fetchFolders 위치와 실패 처리 (`SyncV2SnapshotPullService.swift`)

- **fetch는 임계구역 밖**을 유지했다(두 계보가 이미 합의한 원칙).
- **실패를 삼키지도 던지지도 않는다.** 값으로 남긴다.
  - 삼키면 빈 목록이 되어 유령 폴더를 짓는다.
  - 던지면 폴더 하나 때문에 문서 pull까지 막히고, 폴더가 없던 시절 작품이 죽는다.
- `folderApplier == nil`은 `.unsupported`로 **따로** 떨어뜨렸다. 보류로 두면
  폴더 동기화가 없던 작품에서 폴더가 하나도 안 보인다.
- Swift 라벨 `folderStage:`를 써서 실패 시 폴더 구간만 건너뛴다.

Windows도 독립적으로 같은 세 갈래를 권했다(윈도우측 답변 4-3).

### 결정 A — 폴더 revision 충돌 되감기 (`SyncV2Dispatcher.swift`, `SyncV2Store.swift`)

**A-2안(backup의 `rebaseFolderAfterRevisionConflict`)을 골랐다. 계약 근거다.**

codex안(`rebaseFolder(serverRevision:)`)을 버린 결정적 이유는 적합성 벡터
**TV-008**이다.

```
expected_server_state.entity_assertions:
  "folder remains a tombstone at revision 5"
  "rename does not resurrect the folder implicitly"
```

A-2안의 `!remote.isDeleted || operation.isDeleted` 조건이 이것을 강제한다.
codex안은 revision 숫자만 보고 되감아 **지워진 폴더를 되살리려 하고, 서버가
다시 거절하면 영구 루프가 된다.** 이 조건은 원격 삭제 상태를 알아야 하므로
codex안에 옮겨 붙일 수 없다 — 가져오는 순간 A-2안이 된다.

함께 얻은 것: `status='inflight' AND attempts=?` 낙관적 잠금,
`local_project_id`/`project_id` 범위 조건, `sqlite3_changes == 1` 확인.
codex안은 `WHERE operation_id = ?` 하나뿐이라 경합 시 조용히 덮어썼다.

---

## 3. 원안 두 쪽에 다 없던 것 — 되감기 상한

**이번 병합에서 새로 넣었다. 이유가 있다.**

확인해 보니 iPad에는 **재시도 횟수 상한이 아예 없었다.**
`SyncV2RetryPolicy`에 지연 4종만 있고 횟수 제한이 없다. 게다가 폴더 발행이
큐 + `base_revision` 구조라, 두 기기가 모두 이름 변경을 들고 있으면 서로
되감기를 주고받는다. Windows는 폴더를 조정 루프로 다뤄 이 구멍이 없고,
문서로 "큐로 바꾸면 같은 구멍이 열린다"고 못 박아 두었다.

**고리가 둘인데 서로 다르다.**

```
고리 1  삭제 vs 이름변경 (TV-008)   → A-2의 isDeleted 조건이 닫는다
고리 2  이름변경 vs 이름변경         → 어느 안도 닫지 못한다. 상한만이 닫는다
```

그래서 넣은 것:

- `SyncV2RetryPolicy.maximumAutomaticRebases` (기본 8)
- `dispatchFolder`가 되감기 전에 `operation.attempts`를 보고, 상한에 닿으면
  `AUTO_REBASE_LIMIT`으로 세우고 `reportStalledFolder`로 화면에 알린다.
- **`rebaseFolderAfterRevisionConflict`에서 `attempts = 0` 되돌림을 뺐다.**
  되돌리면 상한 검사가 영원히 걸리지 않는다.

> **알려진 단순화:** 상한이 `attempts`를 쓰므로 되감기 횟수와 일반 재시도
> 횟수가 섞인다. 되감기 전용 계수기가 옳지만 스키마 변경이라 이번엔 뺐다.
> 되물림 지연이 되감기마다 커지는데, 핑퐁 상황에서는 오히려 감쇠 효과라 둔다.

---

## 4. 놓치면 안 됐던 것 — `stalledFolderChanges` 보존

`SyncV2Store.swift`의 충돌 덩어리가 **결정 A와 무관한 codex 기능을 끼워 물고
있었다.** `stalledFolderChanges`(서버가 거절해 세워 둔 폴더 변경을 화면이
말하게 하는 것, `ad37c7d`)다. 덩어리를 통째로 backup 쪽으로 잡으면 사라진다.

**살렸다.** 그리고 위 3번의 상한이 "닿으면 세우고 화면이 말한다"인데,
말할 수단이 정확히 이 함수다. 두 계보의 물건이 여기서 맞물린다.

---

## 5. 시험은 합집합이다

`SyncV2StoreTests.swift`가 **충돌 파일이었다.** 한쪽을 고르면 그쪽 시험만 돌아
"양쪽 계보 시험을 다 통과했다"는 판정 자체가 성립하지 않는다.

- backup이 더한 시험 36개 + codex가 더한 시험 5개를 **둘 다** 남겼다.
- codex 시험이 쓰는 헬퍼 두 개(`FailingMarkerRemovalFileManager`,
  `UnavailableInitialSnapshotStateRecorder`)도 함께 옮겼다.
- 총 114개.

**고친 기대값이 하나 있다.** `testFolderRevisionConflictRebasesSameFIFOOperation`의
`XCTAssertEqual(retried.attempts, 1)` → `2`. `attempts = 0` 되돌림을 뺀 결과이고,
의도한 변경이다. 주석으로 이유를 적어 두었다.

---

## 6. 계약 pin은 건드리지 않았다 — 일부러다

```
sync-contract/ 패키지         0.3.0
SyncV2Contract.swift 고정값   0.2.0
```

**버그처럼 보이지만 아니다.** 0.3.0 CHANGELOG의 Deployment boundary가 이렇게 적고 있다.

> Clients must retain the 0.2.0 pin until the server stage deploys
> storage-name-v2 and allowlists this release digest.

Windows도 0.2.0 pin이다. **양쪽이 맞아 있는 상태다.**

그리고 올릴 수도 없다. 0.3.0은 이름 알고리즘을 `storage-name-v2`로 **교체**한
판인데, 코드에는 그 구현이 **0건**이다.

```
storage-name-v2                   0건
STORAGE_NAME_UNASSIGNED           0건
STORAGE_NAME_UNSUPPORTED_SCALAR   0건
SN-016 … SN-029                   0건
storageNameAlgorithm = "storage-name-v1"   ← 0.3.0이 교체한 그것
```

**버전 문자열만 바꾸면 구현하지 않은 계약을 구현했다고 선언하게 된다.**
다이제스트가 어긋나면 `require_server_compatibility`가 막고, 터지지 않고
**조용히 계약 경로가 닫힌다.** Windows가 지금 그 상태이고 아무도 몰랐다.

---

## 6-1. 시험 상태

```
763개 실행 · 1개 건너뜀 · 실패 0
```

병합 해소가 깨뜨린 시험은 전부 복구했다. 32건 → 17 → 14 → 1 → 0.

**계약 벡터 13건 — Windows 2라운드 답변으로 닫혔다.**

Windows가 넷째 길을 알려 줬다. 패키지를 0.2.0에 고정한 채 0.3.0 작업을
**패키지 밖**에 두는 방식이다. Windows는 `normalize_storage_name_v2()`를
보통 소스에, 29개 벡터를 `tests/storage_name_v2_vectors.json`에 벤더링해
두 단언을 동시에 통과시킨다.

iPad는 0.3.0이 가져온 구현이 **0건**이라 무를 것이 없었다. 그래서
`sync-contract/`를 backup 판본(0.2.0)으로 되돌렸다.

```
contract_version          0.2.0
canonical_contract_sha256 416c1b99…      ← SyncV2Contract 고정값과 일치
contentCommit             7bcb5d25…      ← Windows 와 같은 내용 커밋
test_vectors/*.json       전부 0.2.0
```

> **바이트 동일은 아니다.** backup 판본에 7개가 더 있다 — 유니코드 표 4개,
> `conformance_vectors/storage-name-v2.json`, README, `.gitattributes`
> (`8753cde`가 넣음). `protocol.json` 다이제스트에는 영향이 없고 코드가
> 읽지도 않는다. 다만 **0.3.0 산출물이 0.2.0 패키지 안에 들어앉은 상태**라
> Windows 규칙대로면 시험 폴더로 빼야 한다. 7번 후속 항목이다.

**나머지 복구 내역**

- `SyncV2FolderEndToEndTests` 98개 — `automaticRebaser` 배선.
  A-2안은 그 협력자가 있어야 도는데 시험이 안 넘기고 있었다.
  `FolderDeviceFixture`가 서버를 들고, `EndToEndFolderSnapshotClient`로
  `FakeFolderServer.folderList()`를 읽게 했다.
  제품은 `AppEnvironment.swift:247,261`에서 같은 배선을 한다.
- `SyncV2SnapshotPullTests` 97개 — `preparePull`만 부르던 3곳에
  `prepareRemoteFolders(.unsupported)` 명시. legacy 시나리오라 보류가 아니라
  "없음"이 맞다.
- `SyncV2StoreTests` 114개 — 셋을 고쳤다.
  - `testWindowsInitialSnapshotMarkerReplays…`,
    `testNewServerProjectInitialSnapshotBackfillsLiveDocuments`:
    **codex가 구현과 함께 고쳐 둔 시험인데 합집합이 backup(=base) 판본을
    남겨서** 깨졌다. codex 판본으로 교체.
  - `testThreeLevelFolderTombstonesCommitDeepestFirst`:
    준비 단계가 생성 3개를 한 번에 claim한다고 가정하는데,
    **backup이 넣은 생성 부모 게이트**(`1273624`)가 병합 트리에 있어
    부모가 끝나야 자식이 준비된다. 준비 단계를 반복으로 바꿨다.
    판정 자체(가장 깊은 것부터 커밋)는 그대로다.

## 7. 남은 일

### 바로 할 수 있는 것

1. **검증06 재실행.** `실서버_종단간검증_절차서_1회차.md`의 6단계
   "동시 이름 변경". 기기 둘, 비행기 모드, 이름 하나.
   A-1안은 이걸 통과했지만 A-2안은 실기기 증거가 없다. **반드시 돌려야 한다.**
2. **스키마 5 마이그레이션 주석 수정.** "덧붙이기만 하는 기록에서 계산하면
   그런 어긋남이 생길 자리가 없다"는 **사실이 아니다.** Windows는 사고 당시
   이미 사건 기록을 갖고 있었고, 집계 질의 한 줄이 그것을 우회해서 났다.
   (윈도우측 답변 5-2)

### 서버에 물어야 풀리는 것

1. 서버 핸드셰이크의 실제 `contract_version` / `canonical_contract_sha256` /
   `server_capabilities`
2. 다이제스트가 어긋난 배치를 서버가 실제로 거절하는가
3. `supersedes_operation_id` 없는 rebase를 서버가 어떻게 처리하는가
4. TV-008(삭제된 폴더에 대한 rename 거절)이 배포된 서버에 실제로 있는가

**Windows는 서버에 접속하지 않는다. iPad나 서버 담당이 쳐야 한다.**
넷 다 계약 경로를 언제 켤지에 걸린 문제고, 그 경로는 지금 양쪽 다 꺼져 있다.
**병합을 막지는 않는다.**

### 계약 쪽 후속 (Windows 와 합의된 방향)

- **0.3.0 산출물을 패키지 밖으로.** `sync-contract/conformance_vectors/`의
  `storage-name-v2.json`과 유니코드 표는 0.3.0 것이다. Windows처럼 시험 폴더에
  벤더링한다.
- **계약에 두 문장을 넣는다.** 이번 사고가 정확히 이 공백에서 났다.
  1. 패키지는 내용 커밋 SHA로 식별되는 고정 산출물이며, 클라이언트 pin과
     같은 커밋에서 함께 움직인다.
  2. 클라이언트는 자기 pin 판본의 벡터를 돈다.
- **능력 과대 선언을 정리한다.** iPad와 Windows가 **같은 8개**를 선언하는데,
  양쪽 다 제자리 UPDATE를 하면서 `immutable_batch_contract_metadata`를,
  폴더 경로가 사건을 기록하지 않으면서(`testFolderWritePathsThatDoNotYetRecordEvents`)
  `operation_state_events`를 선언한다. 선언은 능력 광고이지 목표가 아니다.
- **전이 벡터 재생 범위.** iPad는 TV-011·TV-007을 실제 저장소에 재생한다.
  Windows는 메타데이터만 본다. 재생을 넓히면 TV-005에서 제자리 UPDATE가
  바로 걸리므로, 능력 게이팅을 둘지 먼저 합의해야 한다.

### 별도 작업으로 뺀 것 (양쪽 합의)

- **계약 불변 intent 전환** (새 `operation_id` + `supersedes_operation_id`).
  두 iPad 구현 다 제자리 UPDATE라 계약 위반이다. 다만 계약 배치 경로가
  양쪽 다 꺼져 있어 지금 고쳐도 동작 차이가 0이다.
  **Windows는 이미 전환을 끝냈다** — `sync_v2_store.py:2526` `rebase_clean_merge`가
  참조 구현이다.
  backup 시험에 `testRebaseMutatesOperationInPlace_CONTRACT_VIOLATION_PINNED`가
  있다. 위반을 일부러 못 박아 둔 것이니, 전환할 때 이 시험부터 뒤집으면 된다.
- **`project_sync_mode` / `migration_epoch` 배선.** 계약은
  "이름 기반 트리 추측은 LEGACY epoch 0에서만 허용"이라고 적고 있는데,
  이 값들이 **로컬 저장소에 아예 없다.** 지금은 `.known` 여부로 대신하고 있어
  **네트워크가 끊긴 ID_BASED 작품이 legacy로 강등될 구멍이 남아 있다.**
  서버에서 받아 칸을 만들고 마이그레이션해야 한다.
- **폴더 발행 큐 → 조정 루프.** Windows 구조가 구조적으로 옳을 수 있으나 재설계다.
- **`server_updated_at` 정리.** 쓰기만 하고 판정에 한 번도 읽지 않는다.
  Windows v2에는 이 필드가 0건이고 v1 잔재로 보인다.
- **`storage-name-v2` 구현.** 6번 참조. `계약개정안_storage-name-v2_초안.md`가 있다.

---

## 8. 이어받는 방법

```bash
cd /private/tmp/WriterPad-Merge && git status
```

빌드·시험:

```bash
xcodebuild test -project WriterPad.xcodeproj -scheme WriterPad -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -only-testing:WriterPadTests
```

문제가 생기면 보존 사본이 있다:

```bash
ls /private/tmp/WriterPad-Merge.bak-20260818
```
