# SYNC-004: iPadOS 백그라운드 저장·동기화 정책

- 결정일: 2026-09-22
- 상태: 정책 확정, 분할 저장 수명주기 보완, 실기기 저장 완료 원고의 잠금·재실행 보존 확인, 중단 경계 추가 검증 필요
- 조사 기준: `8370e1f53e9d0782f46351c2913f8407f0af1b8d`
- 범위: iPad 클라이언트 실행 수명과 저장·재시도·완료 표시
- 정책 결정 단계는 문서만 변경했다. 후속 분할 저장 수명주기 보완과 검증은 아래 기록을 따른다.

## 결정

현재 제품은 **로컬 저장 우선·미전송 작업 보존·foreground 복귀 후 재개**를
채택한다. 화면을 잠그거나 앱을 떠났을 때 서버 업로드가 끝난다고 약속하지 않는다.
다른 기기에서 바로 이어 쓰려면 앱이 열린 상태에서 서버 동기화 완료를 확인해야 한다.

이번 정책에는 `BGTaskScheduler`, background `URLSession`,
`BGContinuedProcessingTask` 또는 업로드용 `beginBackgroundTask`를 도입하지 않는다.
백그라운드 전송은 필수 성공 조건이 아니다. 앱에 실행 시간이 남아 기존 전송이
완료되는 경우에는 기존 응답 검증과 저장 절차에 따라 반영할 수 있다.
한정된 검증/편집 모드의 foreground 권한이 취소된 경우에는 해당 모드의 응답 거부와
복구 규칙이 우선한다. 일반 동기화와 이 모드의 허용 범위를 합치지 않는다.

## Apple 실행 제약과 선택 근거

앱은 background 전환 뒤 suspend될 수 있다. 주기적인 실행이나 특정 시각의
실행을 보장할 수 없으며, 사용자가 강제 종료한 앱의 자동 재실행에도 제한이 있다.
`BGAppRefreshTask`와 `BGProcessingTask`는 다음 기기에서 즉시 이어 쓰기 위한
업로드 기한을 보장하는 수단이 아니다.
[Apple DTS: iOS Background Execution Limits](https://developer.apple.com/forums/thread/685525)

`beginBackgroundTask`도 실행 시간 보장이 없고 생성 실패나 즉시 만료를 처리해야 한다.
도입할 경우 정상 종료·오류·취소·만료에서 시작한 식별자를 빠짐없이 종료해야 하며,
`backgroundTimeRemaining`의 추정값으로 데이터 안전성을 결정해서는 안 된다.
[Apple DTS: UIApplication Background Task Notes](https://developer.apple.com/forums/thread/85066)

background `URLSession`은 파일 전송용 별도 수명 관리가 필요하다. 현재의
인증·lease·revision·RPC 응답 처리 흐름을 그대로 실행 시간 보장으로 바꾸는 옵션은
아니다. 따라서 기존 영구 큐 복구 경계를 유지하는 것이 이번 단계의 설계 판단이다.
[Apple: Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

## 상태별 계약

| 상황 | 저장·동기화 기준 | 완료 판정 |
|---|---|---|
| active에서 편집 | 자동저장과 명시적 저장으로 원고를 일찍 영구화한다. 현재 계정·작품·동기화 설정이 허용할 때 기존 큐를 처리한다. | 로컬 저장과 서버 동기화를 별도 판정한다. |
| inactive/background 진입 | 확정된 입력의 즉시 로컬 저장과 세션 상태 보존을 요청한다. IME 조합·지연 저장·분할 편집기의 처리 완료는 별도 검증한다. | 진입 콜백 실행 자체를 저장 완료로 간주하지 않는다. |
| 전송 중 suspend 또는 종료 | 영구화된 요청 본문·operation/batch ID·순서·Base를 보존한다. 응답이 없으면 서버 반영 여부는 미확정이다. | 전송 시작·취소·시간 만료만으로 완료 처리하지 않는다. |
| foreground 복귀/재실행 | 현재 인증·작품 연결·권한을 재검증하고 경로별 기존 복구 절차로 미완료 요청을 재개한다. 응답 유실 재시도는 동일 불변 요청을 사용한다. | 유효한 서버 응답을 로컬 상태에 반영한 뒤 완료한다. |
| 오프라인·인증 불가·충돌 | 미전송 데이터와 복구 자료를 유지하고 대기/오류를 표시한다. | 로컬 저장 성공을 서버 동기화 성공으로 바꾸지 않는다. |

로컬 저장도 **영구화 성공 이후**의 데이터만 복구 대상으로 보장할 수 있다.
저장 전에 강제 종료되거나 저장 자체가 실패한 마지막 입력까지 보존됐다고
표현하지 않는다. OS 중단 전에 모든 비동기 저장이 반드시 끝난다는 보장도 없다.

## 현재 구현 증거와 남은 검증

- 정책 조사 기준의 `WriterPad/Features/Editor/EditorSessionModel.swift`의 `updateSceneActivity`는
  `saveNow(.sceneInactive)`, 세션 저장, lease 정리를 순서대로 기다린다.
  `WritingWorkspaceView.updateSceneActivity`는 좌우 편집기를 차례로 처리한다.
  이 순차 처리에서 첫 편집기의 지연이 둘째 저장과 workspace 동기화 중지를 막는
  결함을 후속 회귀 테스트로 재현했고, 아래와 같이 보완했다.
- `WriterPad/App/WriterPadApp.swift`는 비활성 전환에서 검증 권한을 무효화하고
  background pull coordinator를 중지한다. 일반 dispatcher는 여기서 중지하지 않는다.
  `ReceiveValidationPolicy.invalidate()`만으로 일반 dispatcher의 송신이 차단됐다고
  판단할 수 없다(`sendingAllowed == !enabled`).
- `SyncV2Dispatcher.prioritizeProject`와 `SyncV2BackgroundSyncCoordinator`의
  background는 **앱이 실행되는 동안 열지 않은 작품의 동기화**도 의미한다.
  이 이름이나 해당 테스트 통과가 OS background 업로드 지원 증거는 아니다.
- `SyncV2Store.recoverInterruptedWork`는 중단된 요청을 복구한다. 전체 프로젝트
  dispatcher와 제한된 경로는 복구 권한이 다르므로 제한 경로에 전역 복구를 적용하지 않는다.
- `IntegratedEditorSession.setForeground`와 `NormalEditorSession.setForeground`는
  자체 권한·저널 수명 관리를 가진다. 복귀만으로 자동 송신이 허용된다고 일반화하지 않는다.
- `UIBackgroundModes`, `BGTaskScheduler`, `beginBackgroundTask` 선언/호출은 현재
  `WriterPad`와 프로젝트 설정에서 확인되지 않았다.

기존 근거는 `SyncV2StoreTests`의 큐 재실행·충돌 원본 보존,
`SyncV2ClientTests`의 재실행 drain·응답/lease 처리,
`SyncV2SnapshotPullTests`의 scene 전환·중복 구독·복구 순서,
`IntegratedEditorTests`의 조합 초안 재실행 복구 테스트다.
이 근거는 OS suspension, 강제 종료, 잠금 상태 저장을 한 흐름으로 검증한 결과가 아니다.

## 다음 단계와 완료 조건

전송 전 영구 큐와 응답 로컬 반영 실패의 추가 회귀 검사는
[중단 경계 검증](SyncV2InterruptionBoundaries.md)에 정리한다.

다음 구현/검증 단계는 위 수명주기 경계의 회귀 검증으로 한정한다.

1. 지연된 첫 편집기 저장/lease 정리 중 둘째 편집기의 최신 입력 보존,
   IME 조합 상태, 빠른 active→inactive→active 전환을 재현한다.
2. 전송 전·응답 유실·응답 로컬 반영 중 중단을 구분해, 요청 ID/본문/순서와
   Base 보존 및 재개 후 중복 서버 변경 방지를 기존 테스트에 매핑한다.
3. 일반 모드와 제한 모드를 각각 확인한다. 취소된 권한, 다른 계정/작품,
   실패한 로컬 저장이 송신·완료 표시를 열지 않는지 확인한다.
4. 실제 OS 중단 검증은 생성 원고로 잠금·앱 전환·수동 강제 종료/재실행을 확인하고
   기기·OS·빌드·로컬 해시·큐 상태를 기록한다. debugger 연결 상태의 관찰이나
   mock 테스트만으로 suspension 검증 완료를 선언하지 않는다.

재현된 결함은 해당 수명주기 범위에서 수정한다. 로컬 저장 보호를 위해
`beginBackgroundTask`가 필요하다는 증거가 생기면 별도 구현으로 검토하며,
그때도 서버 업로드 완료를 필수 조건으로 추가하지 않는다.
SYNC-004는 정책 확정만으로 검증 완료로 올리지 않는다.

## 이번 단계 검증

- Apple 공식 문서와 위 코드·기존 테스트의 읽기 전용 대조
- 공통 계약 검증기 및 문서 diff/참조 검사
- Swift 재빌드, 기기 실행, 서버 요청·변경은 이 문서 단계의 검증에 포함하지 않는다.

## 2026-09-22 분할 저장 수명주기 보완

`WorkspaceSceneTransition.apply`를 실제 workspace 경로에 연결했다.
비활성 전환에서는 두 편집기의 `updateSceneActivity(false)`를 독립적으로 시작하고,
workspace pull/Realtime 중지도 저장 완료를 기다리지 않고 시작한다.
두 편집기의 정리가 완료된 뒤 workspace 상태를 기록한다.
활성 전환은 기존의 왼쪽→오른쪽→동기화 재개 순서를 유지한다.
전체 scene 사건의 직렬화는 `WorkspaceLifecycleCoordinator`가 계속 담당한다.

`AppEnvironmentTests`에 실제 편집기와 로컬 파일 저장소를 사용하는 회귀 테스트를 추가했다.

- `testSceneDeactivationSavesRightAndStopsSyncWhileLeftSaveWaits`: 왼쪽 저장을
  gate로 멈춘 동안 오른쪽 UTF-8 TXT 저장과 동기화 중지가 먼저 끝나는지 확인한다.
  호출자의 취소와 빠른 활성 복귀, 기다리는 동안 추가된 왼쪽 입력도 확인한다.
- `testSceneDeactivationKeepsFailedPaneDirtyAndSavesOtherPane`: 왼쪽 저장 실패에도
  오른쪽은 저장되고 실패한 초안은 dirty로 남아 복귀 후 재시도로 저장되는지 확인한다.
- `testSceneDeactivationDefersComposingPaneWithoutBlockingOtherPane`: 조합 중인
  본문은 TXT로 확정하지 않으며, 다른 편집기는 저장되고 조합 종료 뒤 UTF-8 바이트가 보존되는지 확인한다.

수정 전 세 테스트 중 첫 테스트가 실패했다. 왼쪽 저장이 해제되기 전 오른쪽 저장과
동기화 중지가 시작되지 않았고, 나머지 두 테스트는 통과했다. 수정 후 세 테스트가
모두 통과했다. 한글 조합 테스트는 모델 사건을 주입한 검증이며 실물 IME 검증을 대신하지 않는다.

실제 `EditLeaseManager.releaseAndRemove`는 네트워크 해제를 별도 Task로 실행하므로
서버 해제 응답을 기다리는 결함은 이번 조사에서 확인되지 않았다. lease 구현은 변경하지 않았다.

최종 구현의 관련 회귀 검증은 350개 중 348개 통과, 실패 0개, 건너뜀 2개다.
건너뛴 것은 비공개 실행 기록을 요구하는 `IntegratedEditorTests`의
`testCapturedJournalExtensionOnPrivateCopyPreservesEveryOriginalRecord`와
`testCapturedSeventyRecordsAcceptRecoveryOnCopyAndPreserveFirstDiagnostic`이다.
빌드 로그의 경고/오류와 xcresult runtime warning은 없었다.

검증 범위는 `AppEnvironmentTests`, `LocalDocumentStoreTests`,
`SyncV2SnapshotPullTests`, `IntegratedEditorTests`, `NormalEditorTests` 전체와
큐 순서/ID 재실행·Base/충돌 원본 보존·응답 유실 복구·기동 drain·foreground 권한
취소 후 늦은 응답 거부의 선택 테스트다. 공통 계약 검증기도 통과했다.
전체 테스트 타깃을 모두 실행한 결과로 확대 해석하지 않는다.

이 결과는 iPad Pro 11-inch (M5), iOS 26.5 시뮬레이터의 자동 검증이다.
실제 OS suspension·잠금·강제 종료 직전 미영구화 입력의 보존은 아직 검증하지 않았다.
다음 단계는 생성 원고를 쓰는 격리된 실기기 수명주기 검증이다.

## 2026-09-22 실기기 저장 완료 원고 보존

[실기기 검증 기록](SyncV2DeviceLifecycleValidation.md)에 격리 앱 구성과 제한을 기록했다.
iPad Pro 11-inch (M4), iPadOS 27.0에서 사용자가 입력한 두 한글 합성 원고가
영구 저장된 것을 먼저 확인했다. 사용자 잠금·해제 및 앱 전환기 종료·아이콘 재실행
보고 후 두 원고의 바이트 수/SHA-256과 분할·활성 편집기 상태를 대조해 보존을 확인했다.

실제 종료 동작과 잠금 지속 시간은 사용자 보고이며 OS suspension을 직접 관찰하지 않았다.
서버 연결 없는 로컬 검증이므로 큐 재개·응답 유실과 미영구화 입력 보존은 여전히 남는다.
자동 UI 검사는 러너 자동화 초기화 시간 초과로 실행되지 않았고, 무료 개발 프로필의
앱 설치 수 한도로 수동 검증을 수행했다. 기존 앱·사용자 원고는 유지했다.
이 결과로 SYNC-004 전체를 검증 완료로 올리지 않는다.

후속 자동 UI 검증에서는 iOS 26.5에서 **왼쪽 입력 후 분할을 여는** 흐름의
본문 표시 결함을 재현했다. TXT와 글자 수는 남지만 홈 전환 전부터 왼쪽 화면이
비어 있었다. 앞선 실기기 수동 검사와 입력/분할 순서가 다르다.
최신 mutation 버퍼가 아닌 이전 게시 문자열을 읽던 원인을 수정해,
iOS 26.5 단위 116개·UI 3개(분할 직후·홈 복귀·재실행 포함)가 모두 통과했다.
iPadOS 서명 빌드도 경고 0건으로 성공했다. 수정은 `72ee8b8`에 커밋했고,
실제 iPad의 전용 검증 앱만 업데이트해 기존 Documents 보존을 확인했다.
사용자의 입력 완료 보고 후 003·004화의 분할 본문 표시와 저장 바이트 일치,
기존 001·002화 보존을 확인했다. 수정 빌드에서도 사용자 잠금·해제 후 좌우 본문과
오른쪽 활성 상태, Documents 전체와 네 원고 해시가 유지됐다. 잠금 시간과 동작은
사용자 보고이며 OS suspension 관찰은 아니다. 이어 사용자 수동 종료·아이콘 재실행 후에도
003·004화 본문·분할·오른쪽 활성 상태, Documents 전체와 네 원고 해시가 유지됐다.
동일 전용 앱 설치 경로의 PID가 `1237`에서 `1321`로 바뀐 것도 확인했다.
이미 저장된 원고의 로컬 보존 검사 통과이며 SYNC-004 전체 완료로 올리지 않는다.
원격 push·병합은 하지 않았다. 세부 증거와 검증 한계는 위 기록을 따른다.
