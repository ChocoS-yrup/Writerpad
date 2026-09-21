# iPad 회신 — Windows 핸드셰이크 공통 규칙 C1–C12

작성일: 2026-09-06 KST

> 이 문서는 수정 전 검사 기록이다. 후속 구현·회귀 시험 결과는 [안정화 구현 회신](ipad-handshake-stability-implementation-2026-09-06.md)을 참조한다.

## 1. 검사 기준 및 범위

- 요청 문서: [Windows 인수인계, a3eaa8b](https://github.com/ChocoS-yrup/WriterPad_main/blob/a3eaa8b97dc9769ad313ac3fe579d0b1443849a9/docs/windows-handshake-stability-handoff-2026-09-06.md).
- Windows 수정 코드 기준: 문서에 명시된 `d92d26a92f1e5e1b2ada690853e33a9103796078`.
- iPad 저장소: `ChocoS-yrup/Writerpad`.
- 브랜치: `codex/ipad-unified-contract-canary-integration`.
- 검사 HEAD: `2ef42c8b81da40c458edb2eb0cb139b2c1bee942`.
- 설치본: 위 수정 후 빌드·설치한 ChocoS Debug, `com.chocos.writerpad.debug`.
- 연결 환경: 설치 빌드의 Info.plist 기준 WriterPad Staging, `mhpnszcorfzrvhyondxr`.
- 계약: version `0.2.0`, protocol `3`.
- digest: `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.
- 09-06 06:36 KST 실기기 Preferences 재조회: 계약 관문 키 0개, 열린 관문 0개.
- 실제 관문, 앱 코드, 계약 파일, 서버 설정, mode/epoch를 변경하지 않았다.
- 이번 결과는 코드·기존 테스트/결과 번들·실기기 관문 설정의 대조다.
  새로운 네트워크 장애 주입, 로그인 조작, 실제 계약 쓰기는 실행하지 않았다.

판정은 **일치 1개 / 수정 필요 9개 / 미검증 2개**다. 규칙 중 일부만 구현돼 있으면
전체 일치로 올리지 않았다. `미검증`은 성공 판정이 아니다.

현재 일반 동기화는 기존 `commit_document` / `commit_folder` 경로다.
계약 구조 sender는 개발 화면의 수동 1건 전송에만 연결돼 있으며, 계약 관문이
닫혀 있으므로 현재 정상 동기화를 새 계약 배치 성공으로 해석하지 않는다.

## 2. C1–C12 판정표

| 규칙 | 판정 | 코드 근거와 차이 | 테스트 근거·남은 검사 |
|---|---|---|---|
| C1 문맥에 귀속된 캐시 | **수정 필요** | `SyncV2HandshakeContext`는 local/server project ID, account ID, digest를 갖는다. 서비스 generation도 있지만 실제 인증·연결 수명 변화에 연결되지 않았다. 동일 계정 재로그인 및 같은 ID로 재연결한 새 수명을 구분하지 못한다. [H:264, 428, 458] | `testStandingAnswerDoesNotCrossAccounts/Projects/ClientDigests` 통과. 같은 계정의 새 인증 수명·연결 재생성 시험 없음. |
| C2 무효화 시 상태 정리·진행 슬롯 유지 | **수정 필요** | `forget`은 응답 폐기와 generation 증가를 수행하고 inFlight 슬롯을 유지한다. 그러나 작품·인증 변경 및 서버 무효 통지의 실제 호출 연결이 없다. 관문 닫기는 `Task`로 비동기 무효화된다. 자동 조회 시도/재시도 상태도 아직 없다. [H:446–469, S:163–172] | `testEachInvalidationDropsTheStandingAnswer`는 메서드 직접 호출 시험이다. 앱 사건 전체 배선 검증이 아님. |
| C3 옛 컨텍스트의 모든 응답 폐기 | **수정 필요** | 첫 refresh 호출자는 성공 후 generation을 확인한다. 반면 inFlight 합류 분기는 문맥 비교·완료 후 generation 검사 없이 task.value를 반환한다. 오류 경로도 generation 검사 전에 무효화 오류를 처리한다. [H:349–425] | `testLateAnswerFromAnEarlierGenerationIsDiscarded`는 첫 요청의 성공만 검사. 다른 문맥 합류, 옛 실패/unsupported, 무효화 이후 합류는 미포함. 이번에는 코드상 차이를 확인했으며 새 재현 시험은 실행하지 않음. |
| C4 응답 필수값·계약 검증 | **수정 필요** | 필수 필드, 두 digest 일치와 pin, protocol 집합, capability, mode/epoch 검사는 있다. **contractVersion은 nil/빈 문자열만 거절하며 version == 0.2.0 검사가 없다.** 또한 project_id는 Windows 규칙보다 엄격하게 필수다. [H:35–59, 168–238] | `testSupportedAnswerMissingItsOwnFieldsIsMalformed`, `testDisagreeingDigestsAreMalformed`, `testProtocolVersionDecisionTable` 등 통과. 올바른 digest + 다른 nonempty version 거절 시험 없음. |
| C5 일시적 실패·확정 거절 분리 | **수정 필요** | URLError와 일부 인증/권한 오류는 구분하지만 기타 PostgREST 계약 오류를 serverRejected로 합친다. 429/5xx·감싼 원인 오류를 공통 규칙대로 분류하는 처리가 없고 핸드셰이크 자동 재시도도 없다. 구조 transport는 모든 예외를 transportRejected로 합친다. [H:117–156, A:37–49] | `testRecoverableErrorsKeepNothingButDoNotPretendToSucceed`는 서비스 대역 오류 시험이다. 실제 SDK 오류 분류 전체 검증 아님. 인증 토큰 보존·명시적 만료 거절 시험은 별도로 통과. |
| C6 2→4→8→16→32→60초 재시도 | **수정 필요** | 핸드셰이크 재시도 스케줄러가 없다. 일반 sync backoff는 1/2/5/10/30초, auth refresh retry는 30초, workspace auth retry는 3초다. 이 일반 동기화 설정을 핸드셰이크 규칙의 구현으로 세지 않는다. [T:23–40] | 핸드셰이크용 지연 증가·60초 상한·성공/문맥 변화 reset 시험 없음. |
| C7 역할별 중복 작업 억제 | **미검증** | handshake inFlight, auth activeRestore/activeRefresh, workspace SingleFlightTask, 계약 배치의 ready→processing claim은 있다. 그러나 자동 핸드셰이크/재시도 연결이 없고 실제 SDK 취소와 모바일 중단을 포함한 통합 검증이 없다. [H:366, U:333–375, D:10499] | `testConcurrentAsksReachTheServerOnce`, `testConcurrentRestoreCallersCoalesceAndReceiveFinalState`, `testConcurrentForcedRefreshUsesSingleFlight`, `testRefreshDuringRestoreReturnsTheInFlightRestoreResult` 통과. 반복 복구 알림·동시 계약 sender까지 포함한 시험은 없음. |
| C8 집필 비차단·대기 원고를 보호한 복구 pull | **미검증** | 로컬 우선 저장과 bootstrap pull 예외는 있다. 다만 새 계약 핸드셰이크 자동 복구 파이프라인 자체가 없어 Windows 실기기 장애 복구 시나리오 전체와 동등하다고 판단할 수 없다. [P:2170 이후, U:333 이후] | `testUnauthenticatedStateDoesNotBlockLocalManuscriptSave`, `testBootstrapMayPullWithPendingInitialUpload`, `testUploadPermitCoversEmptyGapBeforeNextClaim` 통과. iPad에서 앱 전용 통신 차단 후 로컬 저장→자동 handshake→자동 복구 실증은 미실행. |
| C9 실제 전송 시작 경계까지 현재 조건 재검사 | **수정 필요** | sender 진입 시 gate·binding·auth·standing handshake를 검사한다. 이후 queue 조회, permit 획득, batch claim을 await한 뒤 재검사 없이 transport.commit으로 간다. 저장된 요청과 현재 문맥의 version/digest/device/project/mode/epoch 전체 대조도 없다. [A:218–263] | 실제 sender를 대상으로 준비 중 gate/auth/binding 변경 후 RPC 0회를 검사하는 테스트 없음. 서비스의 usesContractStructure 시험을 sender 경계 시험으로 대신할 수 없음. |
| C10 기존 배치 ID·payload·계약 메타데이터 보존 | **일치** | 현재 저장된 canary 계약 배치 보존 범위에서 일치한다. 관문 변경은 defaults만 바꾸며 기존 배치를 재작성하지 않는다. 요청 JSON을 저장한 뒤 claim/실패/중단 복구는 상태만 변경하고 같은 요청을 재사용한다. 다른 프로토콜로 변환하는 경로 없음. [S:163, D:2932, 10401, 10499, 10649] | `testContractFolderCreatePersistsImmutableAtomicBatchBeforeSend`가 중단 복구 후 batch ID와 request JSON 동일성을 검사. 다만 다른 계정/연결에 전송되지 않게 하는 실제 시작 경계는 C9 수정 대상이며, 관문 전환과 결합한 통합 시험은 추가 필요. |
| C11 전송 전·시작 후·적용 확인/결과 불명 구분 | **수정 필요** | 응답 ID/digest 검증 후 원래 store에 response_json과 결과 revision을 transaction으로 기록하고 중단 시 동일 요청을 복구하는 부분은 있다. 그러나 전송 시작의 예약/최종 조건 검사가 없고 settings의 완료 표시에도 요청 문맥 비교가 없다. [A:253–310, D:10565–10645, S:180–200] | 저장소의 immutable batch 복구 시험은 통과. 관문 닫기·계정 전환 중 실제 응답 유실/늦은 영수증과 새 화면 오염 방지 시험 없음. |
| C12 자동 개방 금지·명시적 개방에도 최신 응답 요구 | **수정 필요** | 성공만으로 관문이 열리지는 않는다. 하지만 setGateOpen(true)는 인증/handshake 검사 없이 defaults를 기록한다. 쓰기는 별도 조건으로 막히더라도 ‘관문 개방 자체의 선행 검사’에는 불일치한다. [S:163–176, H:493–518] | `testSuccessfulHandshakeAloneDoesNotOpenTheContractPath` 통과. `testContractPathGateTogglePublishesAndRestoresStoredState`는 오히려 signedOut 상태에서 handshake 없이 열리는 현재 동작을 확인한다. |

## 3. 사건별 수명주기 회신

| 사건 | 현재 iPad 동작 |
|---|---|
| 앱 재실행 | handshake 서비스 새 인스턴스, 메모리 응답 없음. 자동 handshake는 미연결. 과거 DB 관측만으로 승인하지 않음. |
| 같은 계정 재로그인 | Auth 서비스는 operationID로 자체 상태를 관리하나 handshake.authenticationChanged 호출 없음. account UUID가 같으면 handshake 문맥이 같은 것으로 남을 수 있음. |
| 다른 계정 로그인 | standingHandshake의 account ID 대조로 다른 계정 응답 사용을 막음. 새 계정의 자동 handshake는 없음. |
| 작품 전환·연결 변경 | local/server ID가 다르면 문맥 대조로 응답 사용을 막음. projectChanged 호출 없음. A→B→A 복귀나 같은 ID 재연결을 새 세대로 처리하는 연결이 필요. |
| 관문 닫기 | defaults의 gate를 즉시 제거. 별도 Task가 서비스 gateClosed를 호출. gate 검사를 이미 통과한 진행 중 sender에 대한 시작 직전 재검사는 없음. |
| 백그라운드→복귀 | workspace의 일반 sync는 정지/재활성화한다. handshake는 메모리에 남고 TTL/강제 재조회 정책 없음. 모바일 정지 중 요청 수명은 미검증. |
| 서버 계약 무효 통지 | 서비스에 forgetIfStale 메서드는 있으나 실제 계약 sender/오류 처리에서 호출하지 않음. |

Windows와 동일하게 TTL은 현재 handshake fresh의 기준이 아니다. iPad의 observedAt은
진단 시각이며 `isFresh`는 문맥과 generation에 맞는 standing answer가 있는지를 뜻한다.
이 정의는 같지만 generation을 올리는 실제 사건 배선은 미완성이다.

## 4. 인증 SDK·지연 작업·중단 복구

- Auth 서비스는 restore/refresh를 합치고 operationID로 완료를 검사한다.
- 현재 live transport는 provider가 공유하는 SupabaseClient에서 setSession/signIn/
  refreshSession을 수행한다. Windows처럼 복원용 클라이언트를 분리하지 않았다.
- provider는 EphemeralAuthLocalStorage와 autoRefreshToken=false를 사용한다.
  앱의 자체 인증 상태 보호와 SDK 내부 세션 변경 차단은 별개다. 대역 시험만으로
  늦은 SDK 세션 변경까지 안전하다고 판정하지 않는다.
- accept(session)는 sessionStore.save 뒤에 operationID를 검사한다. 저장 대기 중
  로그아웃·다른 로그인과 겹치는 경우의 자격 증명 보존 순서도 별도 시험이 필요하다.
- 일반 auth 복원은 12초 watchdog과 네트워크 실패 시 저장 토큰 보존이 있다.
  workspace가 복원을 재시도하지만 C6과 같은 handshake 지연 정책은 없다.
- 계약 배치는 ready→processing으로 claim되며 이 시점은 네트워크 송신/서버 적용
  증거가 아니다. 중단 복구는 processing→ready, inflight→pending으로 되돌리고
  요청 JSON은 보존한다.
- 정상 영수증은 검증 후 completed와 response_json을 같은 transaction으로 저장한다.
  완료 배치는 ready 조회에 잡히지 않는다. 실제 서버의 멱등성 실증은 아직 없다.
- 이번 점검에서 위 SDK 경쟁·송신 경계 결함을 새 테스트로 재현한 것은 아니다.
  구현과 시험 공백을 구분해 후속 회귀 검사 대상으로 남긴다.

## 5. 테스트 증거와 한계

검사 HEAD의 직전 검증 명령은 `Scripts/run_tests.sh`다. 이번에는 소스를 변경하지
않았으므로 같은 테스트를 재실행하지 않고 보관된 최종 xcresult와 소스를 대조했다.

- 결과 번들: `build/TestDerivedData/Logs/Test/Test-WriterPad-2026.09.05_18-58-07-+0900.xcresult`.
- 최종 xcresult: **총 924 / 통과 923 / 실패 0 / 건너뜀 1**.
- 이 수치는 앞서 실행 스크립트 종료 출력으로 보고한 922 통과를 정정한다.
- `SyncV2HandshakeTests`: 30개 통과.
- `SupabaseAuthServiceTests`: 19개 통과.
- `SyncSettingsModelTests`: 6개 통과.
- 현재 30개 handshake 시험은 서비스 코어 중심이다. HTTP 분류, 자동 재시도,
  인증·작품 사건 연결, sender의 직전 차단, 실제 모바일 장애 복구 전체를 검증하지 않는다.

닫힌 관문에서 원고 로컬 저장은 가능하며 일반 동기화의 상태에 따라 로컬 저장,
로그인 확인, 오프라인 저장, 서버 동기화 완료 등이 표시된다. 일반 동기화 완료가
새 계약 완료라는 뜻은 아니다. 실기기 재실행 후 일반 동기화 정상은 사용자 확인을
받았지만, 이번 점검에서 **계약 쓰기 RPC 호출 카운터 0회 테스트는 새로 실행하지 않았다.**
sender의 진입 gateClosed 분기는 코드로 확인했으며, 실제 관문은 열지 않았다.

## 6. 후속 수정 순서와 미지원 범위

1. C1–C4: 문맥/세대/동시 응답 처리, version 검사와 사건 무효화부터 보강한다.
2. C5–C8: live 오류 분류, 2/4/8/16/32/60초 지연 정책, 자동 조회와 복구를 연결한다.
   먼저 닫힌 관문에서 로컬 집필과 읽기 복구를 검증한다.
3. C9–C12: 명시적 관문 개방의 선행 조건, 실제 전송 시작 경계, 불명 결과와
   늦은 영수증 처리를 구현하고 대역 RPC 0회/동일 ID 보존 회귀 검사를 추가한다.
4. 위 검증 이후 별도 시험 작품으로 새 폴더 1개 + 순서의 양방향 계약 전송을 검증한다.
   이번 회신은 관문 개방이나 실제 서버 쓰기의 실행 요청으로 해석하지 않는다.

iPad의 계약 구조 배치 생성기는 현재 새 폴더 1개와 tree_order 1개만 허용한다.
이름 변경·이동·삭제·복원·복합 구조 변경과 원고 document_commit 배선은 미완성이다.
이번 Windows 안정화와 이 기능 범위 확대를 같은 완료 항목으로 묶지 않는다.
LEGACY + protocol 3 허용과 ID_BASED 승격도 구분한다. 이 대조를 위해 mode/epoch나
서버 allowlist를 바꿀 필요는 없다. prod 전환 완료로 판정하지 않는다.

## 코드 위치

아래 약어의 행 번호는 검사 HEAD 기준이다. 링크는 고정 커밋을 가리킨다.

- [H — SyncV2Handshake.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SyncV2Handshake.swift)
- [A — SyncV2ContractStructure.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SyncV2ContractStructure.swift)
- [D — SyncV2Store.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SyncV2Store.swift)
- [S — SyncSettingsView.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Features/Settings/SyncSettingsView.swift)
- [U — SupabaseAuthService.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SupabaseAuthService.swift)
- [P — SyncV2SnapshotPull.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SyncV2SnapshotPull.swift)
- [T — SyncV2Timing.swift](https://github.com/ChocoS-yrup/Writerpad/blob/2ef42c8b81da40c458edb2eb0cb139b2c1bee942/WriterPad/Sync/SyncV2Timing.swift)

테스트 근거 파일:

- [SyncV2HandshakeTests.swift](../WriterPadTests/SyncV2HandshakeTests.swift)
- [SupabaseAuthServiceTests.swift](../WriterPadTests/SupabaseAuthServiceTests.swift)
- [SyncSettingsModelTests.swift](../WriterPadTests/SyncSettingsModelTests.swift)
- [SyncV2StoreTests.swift](../WriterPadTests/SyncV2StoreTests.swift)
- [SyncV2SnapshotPullTests.swift](../WriterPadTests/SyncV2SnapshotPullTests.swift)
