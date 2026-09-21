# SYNC-004: iPadOS 백그라운드 저장·동기화 정책

- 결정일: 2026-09-22
- 상태: 정책 확정, 수명주기 통합 검증 대기
- 조사 기준: `8370e1f53e9d0782f46351c2913f8407f0af1b8d`
- 범위: iPad 클라이언트 실행 수명과 저장·재시도·완료 표시
- 이번 변경: 문서만 변경. 서버 wire 계약, Windows 동작, 앱 실행 코드는 변경하지 않는다.

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

- `WriterPad/Features/Editor/EditorSessionModel.swift`의 `updateSceneActivity`는
  `saveNow(.sceneInactive)`, 세션 저장, lease 정리를 순서대로 기다린다.
  `WritingWorkspaceView.updateSceneActivity`는 좌우 편집기를 차례로 처리한다.
  첫 편집기의 지연이 둘째 저장과 workspace 정리에 미치는 영향은 통합 검증 대상이다.
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
