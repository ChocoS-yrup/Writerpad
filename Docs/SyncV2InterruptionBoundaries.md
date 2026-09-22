# SYNC-004 중단 경계 회귀 검증

기준 main은 PR #39 병합 커밋 `08d2a3342141fbed2a7a8fea9fafb258d2fe6a87`이다.
이번 범위는 임시 SQLite 저장소의 전송 전 큐 보존과 응답 로컬 반영 실패 복구다.
제품 코드·공통 계약·서버 설정은 바꾸지 않는다. 검증은 합성 원고와 응답을 사용한다.

## 새 회귀 검사

`WriterPadTests/SyncV2StoreTests.swift`의 `SyncV2GeneralSyncTests`에 추가했다.

- `testRestartBeforeFirstClaimPreservesQueuedBytesIDsAndFIFO`: 두 원고를 영구 큐에
  넣고 첫 요청을 만들기 전에 DB를 닫았다가 연다. source 행 전체, batch/operation ID,
  큐 순서, 한글·분해형 Unicode·이모지·CRLF의 UTF-8 바이트를 대조한다. 첫 저장의
  응답을 반영한 뒤에만 둘째 요청이 다음 revision을 사용하며 큐가 차례로 비워지는지 확인한다.
- `testReceiptWriteFailureRollsBackAndReopensWithoutReclaimingRequest`: 첫 요청과
  후속 원고를 보존한 상태에서 서버 처리 결과를 나타내는 합성 receipt를 적용한다.
  문서 기준과 operation 및 source의 완료 상태를 갱신한 뒤, batch 완료 행을 쓰는
  시점에 SQLite trigger로 오류를 주입한다. 네 관련 테이블의 모든 행이 반영 전과
  동일한지 대조하고, DB를 닫았다가 열어 동일 요청으로 receipt 복구를 수행한다.
  새 claim 없이 attempts가 유지되고, 후속 원고는 새 Base로 진행하며, 늦은 첫
  receipt가 최신 Base를 되돌리지 않는지 확인한다.

두 번째 검사는 SQLite 쓰기 오류에 대한 transaction rollback 검사다. 실제 저장 장치
고장·디스크 용량 고갈·프로세스 강제 종료를 재현한 것은 아니다. 첫 번째 검사도
저장소를 정상적으로 닫고 다시 여는 검사이며, OS가 프로세스를 suspend한 증거가 아니다.

## 기존 검사와의 연결

| 경계 | 검사 | 증명 범위 |
|---|---|---|
| 전송 전 DB 재개 | 새 `testRestartBeforeFirstClaimPreservesQueuedBytesIDsAndFIFO` | 영구화된 두 source와 요청 식별자·바이트·순서 |
| 요청을 만든 뒤 응답 유실 | `SyncV2GeneralSyncTests.testRestartAndResponseLossReuseExactlyTheStoredRequest` | 같은 불변 요청 복구 |
| 서버 결과 확인 후 재개 | `SyncV2GeneralSyncTests.testLostReceiptAfterRestartCompletesWithoutReclaimAndNextSaveUsesAcknowledgedBase` | 새 claim 없는 receipt 반영과 다음 Base |
| 응답 로컬 반영 중 쓰기 실패 | 새 `testReceiptWriteFailureRollsBackAndReopensWithoutReclaimingRequest` | 로컬 반영의 원자성·재개·후속 원고 보존 |
| 반영 중 권한 취소 | `SyncV2GeneralSyncTests.testReceiptAuthorizationLossRollsBackAllLocalAcknowledgementWrites` | 권한 상실 후 부분 완료 방지 |
| 불완전·불일치 응답 | `SyncV2GeneralSyncTests.testPartialResponseDoesNotAdvanceBaselineAndSchedulesBackoff`, `testReceiptMismatchNeverCompletesOrRewritesTheStoredRequest` | 기준선 유지·대기·요청 보존 |
| 제한된 일반 편집 모드 | `NormalEditorTests`의 `testHTTPNotStartedKeepsSameRequestForFirstTransmission`, `testLostResponseRequiresReceiptAndNeverResends`, `testStoredResponseFinishesLocallyWithoutAnotherGETOrPOST` | 첫 전송/receipt/로컬 완료 경로 분리 |
| 조합 중 초안·후속 저장 | `IntegratedEditorTests.testComposingDraftsRemainWithTheirDocumentAcrossSessionReopen`, `testMultiDocumentSavesLostReceiptAndLaterSaveKeepOrder` | 합성 모델 사건과 저널 재개 |
| 비활성 전환 중 지연·실패·조합 | `AppEnvironmentTests.testSceneDeactivationSavesRightAndStopsSyncWhileLeftSaveWaits`, `testSceneDeactivationKeepsFailedPaneDirtyAndSavesOtherPane`, `testSceneDeactivationDefersComposingPaneWithoutBlockingOtherPane` | 두 편집기의 독립 저장과 모델 조합 지연 |

## 실행 기록

2026-09-22, iPad Pro 11-inch (M5), iOS 26.5 시뮬레이터에서 실행했다.

- 새 회귀 검사 2개: 통과, 실패 0, 건너뜀 0.
- 후속 관련 회귀 검사: **107개 통과, 실패 0, 건너뜀 0**. 새 검사 2개도 이 107개에
  포함되므로 실행 횟수를 합산해 서로 다른 109개 검사로 보고하지 않는다.
- 범위: `SyncV2GeneralSyncTests` 전체 70개, `NormalEditorTests` 전체 28개,
  위 표의 `AppEnvironmentTests` 3개, `IntegratedEditorTests` 선택 6개.
  Integrated 선택은 표의 두 검사와 `testRepeatedForegroundAndManualCyclesRenewAuthorityWithoutDuplicatingWrites`,
  `testScopeRejectsProtectedSaveAndOutsideRequest`, `testReceiptMismatchNeverFallsBackToAnotherWrite`,
  `testSaveFailureKeepsOriginalDraftAndReportsBoundaryWithoutCreatingSource`다.
- 수정된 실행 옵션의 빌드/검사 로그에서 `warning:`·`error:` 0건,
  두 성공 xcresult의 `runtimeWarnings`는 비어 있다.
- 공통 계약 검증과 `git diff --check` 통과. 계약 0.2.0, canonical 23,256 bytes,
  SHA-256 `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670` 유지.
- 새 검사에서 제품 수정이 필요한 결함을 발견하지 못했다. 기준 main 대비 제품 코드,
  빌드 설정, 공통 계약 diff는 비어 있다.

전용 simulator bundle suffix는
`.interruptionvalidation`, DerivedData는 `/private/tmp/WriterPad-Interruption-DD`다.
`OTHER_SWIFT_FLAGS='$(inherited) -DWRITERPAD_ISOLATED_TESTS'`로 앱 시작 환경을
격리하고 서버 URL/key를 빈 값으로 덮어쓴다. 기존 package의 컴파일 조건은 유지한다.

첫 실행은 `SWIFT_ACTIVE_COMPILATION_CONDITIONS`를 명령행에서 대체해
swift-crypto의 기본 조건이 사라지면서 빌드 단계에서 실패했다. 테스트는 시작되지
않았으며 제품 결함 재현으로 집계하지 않는다. 실행 옵션을 고친 후 별도 로그로 재검증했다.

로컬 증거(다른 환경에서 접근 가능한 공개 파일은 아님):

- 첫 빌드 실패: `/private/tmp/writerpad-interruption-boundaries-targeted.log`.
- 새 2개 검사: `/private/tmp/writerpad-interruption-boundaries-targeted-retry.log`,
  `/private/tmp/WriterPad-Interruption-DD/Logs/Test/Test-WriterPad-2026.09.22_11-42-34-+0900.xcresult`.
- 관련 회귀 107개: `/private/tmp/writerpad-interruption-boundaries-regression.log`,
  `/private/tmp/WriterPad-Interruption-DD/Logs/Test/Test-WriterPad-2026.09.22_11-45-46-+0900.xcresult`.

명령은 새 검사에서 `xcodebuild test`, 후속 회귀에서는 동일 빌드의
`xcodebuild test-without-building`을 사용했다. 공통 옵션은 `-project WriterPad.xcodeproj`,
`-scheme WriterPad`, `-configuration Debug`, `-parallel-testing-enabled NO`,
`-collect-test-diagnostics never`, `-test-timeouts-enabled YES`,
`-maximum-test-execution-time-allowance 120`이며 `-only-testing:WriterPadTests/<class>/<test>`로
위 범위를 지정했다. 전체 class를 검사할 때는 `<test>`를 생략했다.
실행 로그 첫 줄에 destination·DerivedData·package 경로와 실제 전체 명령이 남아 있다.

## 남은 실기기 범위

실행 전 격리 조건과 진단 경계별 절차는
[실기기·서버 중단 시험 준비](SyncV2DeviceInterruptionPlan.md)를 따른다. 아직 실행 결과는 아니다.

- 실제 IME 조합·저장 직전 강제 종료·OS suspension은 위 검사로 완료 처리하지 않는다.
- 실제 서버의 결과 기록·중복 변경 방지와 응답 유실은 서버를 연결한 별도 검증이 필요하다.
- 실기기에서는 영구 큐와 요청이 기록된 시점을 먼저 확인하고 잠금·종료·재실행 전후
  요청 ID/본문/순서/Base를 대조해야 한다. 실제 원고 대신 합성 원고를 쓴다.
- [정책](SyncV2BackgroundPolicy.md)의 영구화 성공 이후 보존 범위를 유지하며,
  SYNC-004 전체 상태는 부분 검증으로 남긴다.
