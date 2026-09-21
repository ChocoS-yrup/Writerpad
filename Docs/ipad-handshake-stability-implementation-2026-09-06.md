# iPad 핸드셰이크 안정화 구현 회신 — 2026-09-06

## 검사 대상과 판정 범위

- 기준 문서: [Windows C1–C12 인수인계](https://github.com/ChocoS-yrup/WriterPad_main/blob/a3eaa8b97dc9769ad313ac3fe579d0b1443849a9/docs/windows-handshake-stability-handoff-2026-09-06.md).
- Windows 코드 기준: 인수인계에 명시된 `d92d26a92f1e5e1b2ada690853e33a9103796078`.
- iPad 저장소/브랜치: `ChocoS-yrup/Writerpad`, `codex/ipad-unified-contract-canary-integration`.
- iPad 기준 HEAD: `2ef42c8b81da40c458edb2eb0cb139b2c1bee942`.
- **검증은 위 HEAD에 수정한 작업 트리에서 커밋 전에 수행했다. 이번 수정은 이 보고서를 포함한 커밋에 반영되며, 기준 HEAD만 체크아웃하면 포함되지 않는다.**
- 소스·시험 diff SHA-256 (`git diff -- WriterPad WriterPadTests`): `d55c4dfc9aac9a8ca6fce676b90d5a2327a8b509a02374c14bc89a44bad4f609`.
- 실제 계약 관문, 서버 allowlist, mode/epoch, staging/prod 설정을 변경하지 않았다. 실제 계약 쓰기 RPC도 호출하지 않았다.
- 07:25 검증 종료 당시에는 iPad 설치본을 갱신하지 않았다. 당시 최신 관문 조회는 09-06 06:36 KST, 키 0개/열림 0개였으며 이번 작업에서 실기기 설정을 다시 조회하거나 수정하지 않았다.

아래 **‘일치’는 수정 소스와 시뮬레이터의 대역·로컬 저장 회귀 시험 범위**다.
실기기의 앱 전용 통신 차단→복원, 양쪽 실서버 계약 전송과 멱등성은 아직 **미검증**이다.
테스트 통과 수를 실제 계약 전송 성공 건수로 해석하지 않는다.

## C1–C12 재대조

| 항목 | 판정 | 보완한 동작 | 코드·시험 근거 |
|---|---|---|---|
| C1 캐시의 문맥 귀속 | 일치 — 구현·회귀 범위 | account/local project/server project/digest 외에 인증·연결 세대를 포함한다. 같은 계정 재로그인, A→B→A, 연결 변경을 재조회에 연결했다. 연결 처리 중에는 계약 송신을 막고, 연결 실패로 기존 연결이 남아도 완료 사건으로 재검증한다. | H `SyncV2HandshakeContext`, `observeProject`; B 연결 전환·완료 callback; A 인증 세대. 시험 `testSameAccountReloginAndAToBToASelectFreshGenerations`, 인증 재로그인 세대 시험. |
| C2 무효화와 실제 진행 슬롯 | 일치 — 구현·회귀 범위 | 캐시·재시도 횟수·기한을 초기화한다. watchdog/취소/화면 변경으로 실제 네트워크 슬롯을 먼저 해제하지 않는다. | H `refresh`, `invalidateLifecycle`; `testTimeoutDoesNotReleasePhysicalSlotAndLateSuccessIsDiscarded`. |
| C3 늦은 성공·실패·합류 응답 | 일치 — 구현·회귀 범위 | 같은 문맥·세대만 합류하며 모든 반환 경로에서 세대를 확인한다. 이전 전송의 거절도 새 핸드셰이크를 폐기할 수 없다. | H `refresh`, `forgetIfStale(expectedGeneration:)`; `testCoalescedLateFailureCannotSurviveInvalidationOrFreePhysicalSlot`, `testLateContractRejectionCannotInvalidateNewHandshake`. |
| C4 계약 응답 검증 | 일치 — project_id는 엄격한 정책 유지 | version `0.2.0` 정확 일치 검사를 추가했다. 필수 project_id, 두 digest와 pin, protocol 집합/최댓값, capability, mode/epoch 검사를 유지한다. | H `readHandshakeCompatibility`; `testWrongContractVersionIsRejectedEvenWithCorrectDigest` 및 기존 응답 검증 시험. Windows의 project_id 생략 허용에 맞춰 완화하지 않았다. |
| C5 일시적 실패와 확정 거절 | 일치 — 구현·회귀 범위 | timeout/네트워크/감싼 원인/429/5xx와 인증·권한·계약 거절을 구분한다. JSON 오류를 해독하면서 HTTP 상태를 잃지 않도록 계약 RPC에 상태 보존 전송기를 사용한다. 토큰 복원 실패의 일시적 오류는 저장 토큰을 보존한다. | H `SyncV2ContractHTTPClient`, `classify`; A 오류 분류; `testHTTPStatusAndNestedErrorsPreserveRetryPolicy`, 기존 인증 토큰 보존 시험. |
| C6 지연 재시도 | 일치 — 구현·회귀 범위 | 2/4/8/16/32/60초, 이후 60초 상한. 성공·인증/작품/연결 수명 변경에 초기화한다. 고정 TTL을 추가하지 않았다. | H `runAutomatic`, `retryDelay`; `testAutomaticBackoffReachesCapAndResetsOnRelogin`. 이 시험의 시간/sleep은 가상화했으며 실제로 60초씩 기다린 서버 시험은 아니다. |
| C7 중복 억제 | 일치 — 구현·회귀 범위 / 실기기 미검증 | 핸드셰이크 실제 호출, SDK 인증 교환, 동일 작품 pull, 동일 작품 계약 sender에 각각 진행 슬롯을 유지한다. 취소를 무시하는 대역으로 겹침을 확인했다. | H `refresh`; A `SerializedSupabaseAuthTransport`; P `activeProjects`; S `sendingProjects`. 시험 `testLateRestoreCannotOverlapNewLoginOrOverwriteItsTokens`, `testCancelledPhysicalPullKeepsProjectSlotUntilNetworkReturns`, `testSameProjectSenderIsSingleFlightAcrossReservationWait`. |
| C8 집필 비차단·복구 | 일치 — 구현·회귀 범위 / 실기기 미검증 | 작품 선택은 네트워크 완료를 기다리지 않고 자동 조회를 시작한다. 핸드셰이크가 대기 중이어도 실제 로컬 TXT 저장·재읽기가 끝난다. pending 초기 업로드가 있어도 구조 bootstrap pull을 허용하는 기존 경로와 로컬 미전송 원고 보호를 유지한다. | `testLocalWritingCompletesWhileAutomaticHandshakeWaitsForNetwork`, `testAutomaticRetryRecoversSameProjectWithoutOpeningGate`; 기존 `testBootstrapMayPullWithPendingInitialUpload`, `testEqualServerRevisionWithPendingLocalOperationIsNotUpToDate`. 실기기 통신 차단·복원 전체 시나리오는 별도 확인 필요. |
| C9 실제 전송 직전 재검사 | 일치 — 구현·회귀 범위 | gate/인증/연결/핸드셰이크/scene/전체 동기화 세대를 캡처하고 queue·permit·claim·transport 대기 이후 RPC 시작 예약에서 재검사한다. 저장 요청의 project/device/version/digest/protocol/capability/mode/epoch 및 payload hash를 대조한다. 새 배치 생성도 저장 직전 권한 검사를 통과해야 한다. | S `validateForTransmission`, `sendNext`, recorder; H `reserveStart`; D enqueue. `testSenderRechecksEveryAuthorityAfterClaimAndAtTransportReservation`은 2개 경계×6개 상태 변경에서 대역 RPC 0회와 배치 보존을 검사한다. 기기 불일치 시험도 포함. |
| C10 불변 배치 보존 | 일치 — 현재 지원 범위 | 송신 전 차단, 통신 결과 불명, 부분/잘못된 응답, 중단 복구에서 ID·payload·계약 메타데이터를 다시 만들지 않는다. legacy 변환도 하지 않는다. | D `failContractStructure`, claim/recover; 보강한 `testContractFolderCreatePersistsImmutableAtomicBatchBeforeSend`, `testUnknownResultRetriesSameBatchAndLateSuccessStaysWithOriginalQueue`. |
| C11 예약·완료·결과 불명 | 일치 — 구현·회귀 범위 | 시작 예약은 서버 적용 증거가 아니다. 검증된 응답만 원래 작품 장부에 완료로 기록한다. 늦은 완료는 바뀐 화면에 게시하지 않는다. 결과 불명은 같은 ID를 보존해 재시도하며 다시 현재 조건을 검사한다. 완료 장부에는 늦은 실패를 적용하지 않는다. | S sender, UI `sendOneContractBatch`; D 완료/실패 transaction. `testLateContractReceiptIsStoredWithoutPublishingIntoChangedScreen`, 동일 ID 재시도 시험, 저장소의 완료 후 늦은 실패 무시 시험. 실제 서버 영수증은 이번 검증에 없음. |
| C12 자동 개방 금지 | 일치 — 구현·회귀 범위 | 자동 성공은 관문을 열지 않는다. 명시적 열기도 새 서버 조회가 성공해야 하며 기존 진행 조회에 합류해 열지 않는다. 조회 중 닫은 관문은 늦은 응답으로 열리지 않는다. | H `refreshForGate`, `openAfterValidation`; UI `setGateOpen`; `testSettingsOpensOnlyAfterFreshResponseAndClosingWinsAgainstLateResponse`, `testExplicitGateOpeningRequiresANewReading`. 테스트에서만 격리 UserDefaults 관문을 사용했다. |

## 테스트 결과

최종 명령: `Scripts/run_tests.sh`.

- **총 946개 / 통과 945개 / 실패 0개 / 건너뜀 1개** — 최종 xcresult 기준.
- 기준 HEAD의 924개에서 회귀 시험 22개를 추가했다. 기존 설정·배치 저장·편집권 시험의 검증 조건도 보강했다.
- `SyncV2HandshakeTests` 49개, `SupabaseAuthServiceTests` 21개, `SyncSettingsModelTests` 6개 모두 통과.
- `SyncV2SnapshotPullTests` 134개, `SyncV2StoreTests` 134개, `EditLeaseManagerTests` 22개 모두 통과.
- 실행 시각: **2026-09-06 07:22:37–07:25:40 KST**.
- 기기: iPad Pro 13-inch (M5), iOS Simulator 26.5 (23F77).
- 결과 번들: `build/TestDerivedData/Logs/Test/Test-WriterPad-2026.09.06_07-22-37-+0900.xcresult`.
- `git diff --check` 통과. 검사 종료 뒤 소스·시험 diff SHA-256이 위 값과 동일함을 재확인했다.
- 스크립트의 로그 문자열 집계 대신 `xcresulttool get test-results summary`의 최종 수치를 사용했다.
- 휴대 가능한 [검증 요약 JSON](evidence/ipad-handshake-stability-tests-2026-09-06.json)을 함께 남겼다.

기존 테스트의 의미도 보완했다.

- 로그인 상태 이벤트 시험은 로그인 시작의 `.restoring`을 포함한다. 같은 계정의 재로그인도 기존 계약 권한을 그대로 유지하지 않는다.
- 기존 편집권 시험에서 RPC 횟수 2회를 ‘재획득 완료’로 가정한 경쟁을 재현했다. 실패 당시 상태는 `acquiring`이었다. 제품 편집권 로직을 바꾸지 않고 `held` 상태 사건까지 기다리도록 시험을 수정했다.

## 실제 기기에서 이어서 확인할 순서

1. 이 작업 트리를 검토·커밋한 뒤 Debug 빌드를 iPad에 재설치한다. 설치 전후 실제 계약 관문이 닫혔는지 확인한다.
2. 재실행, 같은 계정 재로그인, A→B→A 작품 전환에서 새 세대의 자동 핸드셰이크가 기록되는지 확인한다.
3. 별도 시험 작품에서 앱 통신을 차단하고 원고를 로컬 저장한다. 통신 복구 뒤 작품 화면을 나가지 않아도 핸드셰이크·기존 동기화가 회복되는지 확인한다.
4. 백그라운드→복귀, 빠른 작품 전환, 연결 실패·재연결을 겹쳐 중복 조회나 다른 작품의 상태 표시가 없는지 확인한다.
5. 결과를 Windows에 회신한다. **그 뒤 별도 시험 작품의 계약 송신 검증을 결정한다.** 현재 수정은 실제 관문 개방, prod 이관 또는 실서버 계약 전송 완료를 뜻하지 않는다.

현재 계약 배치 생성 범위는 새 폴더 1개 + tree_order 1개다. 일반 원고 저장은 기존 경로이며,
계약 이름 변경·이동·삭제·복원·원고 document_commit 배선 확대는 이번 안정화와 별도 작업이다.

## 코드 위치

아래 행 번호는 이번 작업 트리 기준이다.

- H: `WriterPad/Sync/SyncV2Handshake.swift` — HTTP 보존 129, 오류 분류 171, version 검사 244, refresh 438, 자동 사건 549, 재시도 638, 관문 예약 769.
- A: `WriterPad/Sync/SupabaseAuthService.swift` — SDK 교환 직렬화 58, 인증 시작/완료 세대.
- B: `WriterPad/Sync/SupabaseProjectBindingService.swift` — 연결 변경 시작/완료 507, 571, publish 710.
- S: `WriterPad/Sync/SyncV2ContractStructure.swift` — 저장 요청 대조 88, recorder 175, sender 303.
- D: `WriterPad/Sync/SyncV2Store.swift` — enqueue 10245, claim 10501, complete 10564, fail 10648.
- P: `WriterPad/Sync/SyncV2SnapshotPullService.swift` — 작품별 실제 pull 슬롯 176.
- UI: `WriterPad/Features/Settings/SyncSettingsView.swift` — 명시적 개방 166, 완료 표시 214.
- 앱 사건: `WriterPad/Features/Projects/ProjectWorkspaceView.swift` 158.
