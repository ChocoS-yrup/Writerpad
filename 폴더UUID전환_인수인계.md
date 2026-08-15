# 폴더 UUID 전환 — 인수인계

브랜치: `feat/sync-v2-structure-recovery`
마지막 커밋: `1d84096`

요구사항 1~8의 구현은 끝났다. **남은 것은 실기기 검증뿐이다.**

## 이번에 한 것 (커밋 10개)

| 커밋 | 내용 |
|---|---|
| `35a3306` | 1단계 — 대기열에 폴더 작업, 스키마 V3 `sync_folders` |
| `62644e1` | 2단계 — `commit_folder` RPC 클라이언트 |
| `a7e7d09` | 3단계 — 디스패처 폴더 분기 |
| `544a1c8` | 4단계 — 이관 실행, 스키마 V4 이관 표식 |
| `8fb6fa7` | 5단계 앞 — 원격 폴더 반영 계획 |
| `21e77cc` | 5단계 뒤 — 실제로 옮기고 만들고 지우기 |
| `31c1ad3` | pull에 폴더 반영부 연결 |
| `8b4ad1f` | 6단계 — 재귀 삭제 순서 |
| `24aa787` | pull에 이관 연결, 미전송 폴더 보호 |
| `1d84096` | 7단계 — 전 구간 관통 테스트 |

WriterPadTests 595개 중 594개 통과, 실패 0개 (1개는 원래 skip).

## 실기기에서 가장 먼저 볼 것

**`commit_folder` 응답의 키 이름은 확인되지 않았다.**
마이그레이션 SQL이 저장소 어디에도 없어 `commit_document`의 반환 모양을 그대로
본떴다. 두 함수의 `p_` 인자 이름이 똑같이 지어져 있어 같은 틀로 만들어졌다고
보았지만 추측이다. **틀렸다면 폴더 관련이 통째로 안 돈다.**

고칠 곳은 `SyncV2Client.swift`의 `SyncV2CommitFolderResult.CodingKeys` 한
곳이다. 대기열을 이어 가는 데 꼭 필요한 값만 필수로 읽고 `version_id` 같은
칸은 없어도 넘어가게 해 두었으므로, 이름만 맞추면 된다.

가정한 키: `status`, `folder_id`, `version_id`, `operation_id`,
`operation_kind`, `revision`, `parent_folder_id`, `name`, `is_deleted`,
`committed_at`.

확인하는 법:
```sql
SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'commit_folder';
```

## 나머지 확인 목록

원래 인수인계에 있던 네 가지에 이번에 만든 것이 더해진다.

- 이름 끝 공백 입력 시 팝업
- 빈 폴더 이름 변경 (양방향) ← **이번 작업의 핵심**
- 아이패드에서 만든 폴더가 안 지워지는지
- 문서 든 폴더가 안 건드려지는지
- 기존 작품을 처음 열 때 이관이 한 번만 돌고 폴더가 그대로인지
- 폴더를 통째로 지울 때 안쪽부터 나가는지 (`FOLDER_NOT_EMPTY`가 안 떠야 한다)
- 두 기기가 같은 작품을 각자 이관했을 때 폴더 UUID가 같은지

## 조사로 알아낸 것 (다시 파지 말 것)

**폴더는 이미 안정적인 로컬 UUID를 갖고 있다.**
`DocumentRecord.id`가 SwiftData에 저장되고 이름 변경·이동에도 유지된다.

**예외는 동기화가 만든 폴더였다.**
`SyncV2LocalSnapshotApply`가 tree-order에서 폴더를 만들 때 경로 기반 uuid5를
썼다. 이관이 이것을 서버와 공유하는 값으로 바꾼다.

**문서가 든 폴더는 원래 잘 동작한다.** 문제는 빈 폴더뿐이다.

**이관은 서버 작품 ID를 써야 한다.** 로컬 작품 ID는 기기마다 다르다.

**이관 완료 여부는 경로로 판단할 수 없다.**
스키마 V4의 `sync_projects.folder_migration_completed_at`에 적는다.

## 이 프로젝트에서 반드시 지킬 것

**새 파일은 pbxproj에 직접 등록해야 한다.** 등록하지 않으면 조용히
컴파일되지 않는다. 이번에 더한 파일이 실제로 빌드에 들어갔는지는 빌드 로그에서
파일 이름을 세어 확인했다.

**증분 빌드가 변경을 놓친다.**
```bash
grep -cE 'SwiftCompile|CompileSwift' build.log   # 0이면 반영 안 된 것
```
0이면 `xcodebuild clean build-for-testing`으로 다시 할 것. `-quiet`를 쓰면 이
줄이 지워지므로 쓰지 말 것.

**테스트 결과는 로그가 아니라 결과 번들에서 볼 것.**
```bash
LATEST=$(ls -td ~/Library/Developer/Xcode/DerivedData/WriterPad-*/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results summary --path "$LATEST"
```
실행 개수가 `grep -h 'func test' WriterPadTests/*.swift | wc -l`과 맞는지 볼 것.

**새 테스트는 반드시 실패를 먼저 확인할 것.**
이번 작업에서 **세 번** 헛도는 테스트를 만들었다. 세 번 다 같은 원인이다.

> 폴더 대기열 테스트에서 뒤 작업이 안 나가는 것을 확인할 때, 앞 작업을 먼저
> 완료시키지 않으면 순서 보장이 아니라 **아직 비어 있는 `base_revision`** 이
> 뒤 작업을 붙잡는다. 그래서 고치려는 코드를 지워도 테스트가 통과한다.

폴더 대기열 테스트를 쓸 때는 `claimReadyFolderOperations` → `complete`로 앞
작업을 끝낸 뒤에 확인할 것.

## 이번에 잡은 함정

**프로토콜 기본 구현이 구체 구현을 가렸다.**
`SyncV2DispatchStoring`에 폴더 메서드의 기본 구현을 두었더니, 저장소를 구체
타입으로 직접 부를 때 `async`인 기본 구현이 동기 구현을 이겨 실제 저장 대신
`unavailable`을 던졌다. 문서 쪽에는 기본 구현이 없어 이 문제가 없었다. 기본
구현을 걷어내고 대역 두 곳에 직접 구현을 넣어 해결했다. **폴더 관련 프로토콜에
기본 구현을 다시 넣지 말 것.**

## 타이밍에 기대는 테스트 둘

전체 실행이 무거울 때 번갈아 실패한다. 따로 돌리면 통과한다. 이번 작업과
무관하지만 실기기 검증에서 다시 보이면 따로 볼 값어치가 있다.

- `SyncV2SnapshotPullTests.testBackgroundForegroundEntryDoesNotRestartInitialSubscription`
- `AppEnvironmentTests.testEditorSessionRefreshesStatisticsDuringContinuousTyping`

UI 테스트 `testStageSixBackupAndTrashControlsAreReachable`은 이 작업 이전부터
실패하고 있었다 (HEAD로 되돌려 확인).
