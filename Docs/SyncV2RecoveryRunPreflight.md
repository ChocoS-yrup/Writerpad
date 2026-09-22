# iPad 진단 실행 격리와 사전 검사

기준 main: PR #41 병합 `ba97e4ce037b60acfb36f43351b5bf38b5a78abd`.
범위는 제한된 `NormalEditor` 진단 후보의 로컬 실행 기록·준비 검사다.
공통 계약, wire 요청, Windows 동작과 서버 설정을 변경하지 않는다.
이는 [실기기 시험 계획](SyncV2DeviceInterruptionPlan.md)의 선행 구현이며 실기기 시험 결과가 아니다.

## 실행 명세와 보존

기존 plan/point/content SHA 설정에 다음 세 launch 환경 값을 **모두** 추가하면 실행별
검사가 켜진다. 기존 세 값만 사용하는 과거 진단 형식은 유지한다.

- `WRITERPAD_RECOVERY_RUN_ID`: 소문자 표준 UUID.
- `WRITERPAD_RECOVERY_BASE_REVISION`: 6 이상, Int64 최댓값 미만인 정규 십진수.
- `WRITERPAD_RECOVERY_BASE_SHA256`: 예상 기존 기준선 본문의 소문자 SHA-256.

일부 값 누락, 잘못된 형식, 예상 기준선·대상·본문 불일치는 실패로 처리한다.
이 설정은 시험 대상을 승인하거나 기존 인증·계정·gate 검사를 대체하지 않는다.
런타임 launch 설정은 기존 DEBUG/NormalEditor/recovery 컴파일 조건 안에서만 읽는다.

새 실행은 `NormalEditorJournal`의 선택적 `recoveryRuns` 필드에 명세와 송신 source의
batch ID를 영구 기록한다. 이전 저널의 hash chain·파일·draft·요청/operation ID는 그대로
둔다. 실행마다 빈 큐나 새 저널을 열어 미확정 작업을 숨기지 않는다. 소비 키는
`<기존 plan>:<run UUID>:<point>`로 구분하며, 같은 실행의 재개는 새 소비 기록을 만들지 않는다.
기존 run 없는 소비 키와 충돌하지 않는다.

실행 환경 값 없이 홈 아이콘으로 다시 실행하면 미완료 실행 명세를 저널에서 이어받는다.
다른 실행 ID/본문/point/기준선 또는 run 없는 설정으로 미완료 실행을 교체할 수 없다.
단, 아래의 명시적 준비 취소 조건을 만족하면 취소 기록을 남긴 뒤 새 UUID로 준비할 수 있다.
완료 뒤에도 이전 실행 기록과 소비 키를 보존하며 같은 UUID를 재사용할 수 없다.
새 실행에 기존 frozen/httpStarted 요청을 편입하지 않는다.

이는 **동일 저널 안의 논리적 실행 격리**다. 별도 컨테이너·계정·합성 fixture 생성이나
원본 증거 디렉터리 자동 수집을 구현한 것은 아니다. 고정된 기존 대상/초기 기준선 제한을
유지하므로 임의의 새 서버 작품을 지정해 실행할 수 없다. 실제 대상의 사용 가능성 확인과
새 fixture 선택/초기화, 설치 계획은 별도 단계다.

## 준비와 동작 경계

`prepare`에서 backend 권한 준비/handshake 이전에 로컬 검사와 실행 기록을 완료한다.
송신·결과 복구·수신 버튼에서도 다시 검사해 준비 후 편집/저장 변화가 검사를 우회하지 못한다.
로컬 본문·draft 읽기 및 실행 기록 외에 사전 검사 자체는 서버 호출을 하지 않는다.

- 공통: 올바른 고정 문서/경로/부모, 예상 기록 기준선, dirty/조합/초안 저장 오류 없음,
  충돌·저널 오류 없음을 요구한다. 실제 인증·연결·endpoint 검사는 기존 backend가 유지한다.
- A~C: 미완료 source가 정확히 한 개이며 저장된 로컬 본문·초안·명세 해시가 같아야 한다.
  새 실행은 아직 요청이 없는 queued source에만 연결한다. 재개에서는 기존 batch를 유지한다.
- D: 미완료 송신 없이 로컬 본문과 기준선이 같아야 한다. 조회한 remote가 예상 본문 해시와
  더 높은 revision을 만족하는지 수신 기록/원본 적용 **이전**에 검사한다. 저장된 수신 재개는
  기존 baseline 또는 remote 본문이 원본에 있는 중간 상태를 허용한다.
- SQLite 반영 성공 뒤 최종 저널 완료 전 재개에서는 검증된 반영 후 기준선을 허용한다.
  다른 revision/본문은 거부한다. 송신과 수신의 실행 방향을 서로 바꿀 수 없다.
- 송신/수신 완료와 같은 append-only 기록에서 실행 완료도 남긴다. 실패 상태를 초기화하거나
  source를 재발급하지 않는다. 기존 미완료 건은 보존한 채 원인을 확인한다.

## 요청 생성 전 준비 취소

PR #42 최초 head `58f1056` 검토에서, 준비 후 재저장하면 이전 source가 superseded가 되어
실행에 묶인 batch로 재개할 수도 새 실행으로 전환할 수도 없는 P2를 재현했다.
명시적 **진단 준비 취소 · 본문과 기록 보존** 버튼으로 다음 조건에서만 종료할 수 있다.

- 현재 미완료 run이 있고 충돌·저널 오류·수신 기록·해당 run의 소비된 checkpoint가 없어야 한다.
- 완료되지 않은 저장은 queued 또는 superseded이며 request/requestHash/response/attempt가 없어야 한다.
  송신 run에 묶인 source도 같은 조건을 만족해야 한다. freezing부터는 요청 기록이 없어도 거부한다.
- 수신 D도 원격 수신 기록이 생기기 전 준비만 취소할 수 있다. responseStored/부분 원본 적용은
  기존 수신 ID로 복구해야 하며 취소할 수 없다.
- 전경·열린 세션에서 사용자가 직접 누른 경우에만 실행한다. busy 중에는 거부하고 준비 권한을
  먼저 해제한다. 저널 잠금 안에서 조건을 다시 확인하고 새 `recoveryRunCancelledBeforeRequest`
  레코드에 선택적 `cancelled: true`를 기록한다. `completed`는 false로 남는다.
- 저장 source/본문/draft/기준선/오류/과거 record/UUID/소비 키는 지우거나 다시 쓰지 않는다.
  이전 버전의 cancelled 필드 없는 run도 그대로 읽는다.
- 취소 뒤 기존 UUID 재사용, run 없는 설정, 환경 없는 일반 송신 전환은 거부한다.
  새 UUID·현재 저장 본문 해시·같은 기준선 명세로 진단 앱을 실행해 다시 준비해야 한다.
  새 실행이 준비되면 이후 홈 아이콘 재실행은 그 새 실행을 이어받는다.

따라서 준비 후 저장 변화는 자동으로 다른 실행에 편입되지 않는다. 사용자가 명시적으로 취소하고
새 명세를 확인해야 한다. 이미 만들어진 요청/미확정 HTTP를 교체하는 기능은 아니다.

## 검증과 한계

오프라인 테스트는 구성 파싱, 준비 전 권한 호출 차단, 잘못된 대상/조합/초안 오류,
미완료 실행 교체 금지, 실행별 1회 소비, 과거 record 바이트 보존, 환경 없는 재개,
수신 전 queued 차단, remote 검증 및 부분 수신 복구를 포함한다.
기존 일반 편집·실제 SQLite queue/receipt 테스트도 함께 확인한다.
최초 구현 head `58f1056`의 2026-09-22, iPad Pro 11-inch (M5) / iOS 26.5 simulator 결과:

- 최초 NormalEditor 37개 통과 후, 비활성 전환과 재개 범위를 보강해 최종 재실행했다.
- 최종 `NormalEditorTests` 40개(신규 12개 및 기존 경계 검사 확장)와
  `SyncV2GeneralSyncTests` 70개, **총 110개 통과 / 실패 0 / 건너뜀 0**.
  최초 37개를 합산해 서로 다른 147개 검사라고 보고하지 않는다.
- `testRecoveryDiagnosticBoundariesSurviveSessionReconstruction`에서 실제 로컬 SQLite,
  `LiveNormalEditorBackend`, 파일 저장소와 모의 wire를 사용해 A~D의 실행별 중단·세션
  재구성·환경 없는 복구를 검사했다. 각 송신 실행의 commit은 1회이며 B만 receipt 조회를
  수행한다. D는 기존 수신 ID를 이어받고 추가 송신/본문 조회 없이 완료한다.
- 준비 중 비활성 전환이 발생하면 권한 준비를 호출하지 않고, 준비 후 초안이 바뀌면
  remote 조회 전에 중단한다. 로컬 반영 후 최종 저널 완료 전 기준선은 별도 모의 검사로 확인했다.
- 빌드/검사 로그의 `warning:`·`error:` 0건, xcresult `runtimeWarnings` 비어 있음.
- 공통 계약 검증·diff 검사 통과. 계약 0.2.0과 canonical SHA
  `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670` 유지.

로컬 증거(공개 배포 파일 아님):

- `/private/tmp/writerpad-recovery-run-tests.log`: 최초 37개 검사.
- `/private/tmp/writerpad-recovery-run-regression.log`: 최종 명령 전체와 110개 결과.
- `/private/tmp/WriterPad-RecoveryRun-DD/Logs/Test/Test-WriterPad-2026.09.22_12-47-12-+0900.xcresult`.
- simulator debug dylib SHA-256:
  `69822f9ad7e6a3c3d7b0eccfebfda6d74d0817d2adac66c631dcd578e9e0c4a6`.

전용 bundle suffix `.recoveryrunvalidation`, DerivedData `/private/tmp/WriterPad-RecoveryRun-DD`,
`OTHER_SWIFT_FLAGS='$(inherited) -DWRITERPAD_ISOLATED_TESTS'`, 빈 Supabase URL/key,
서명 비활성, 고정 package 버전으로 실행했다. `xcodebuild test`의 선택 class는 위 두 개다.
환경 파싱/진단 설정은 TaskLocal로 주입했으며, 실기기 launch 환경 전달이나 서명 설치는 검증하지 않았다.

### P2 수정 후 최종 검증

같은 simulator에서 `NormalEditorTests` **49개**와 `SyncV2GeneralSyncTests` **70개**,
총 **119개 통과 / 실패 0 / 건너뜀 0**. 최초 head의 110개와 중간 수정의 117개는 합산하지 않는다.
수정 회귀 9개는 재저장/원래 본문 복원/자동저장 후 명시 취소와 새 실행 송신 완료,
세션 재구성 뒤 취소·준비, 취소 후 재열기·UUID 재사용/진단 우회 금지, 미저장 초안 보존,
busy/비활성 취소 금지, freezing/frozen/httpStarted/responseStored 및 부분 수신 취소 금지,
request 표식·소비 키 검사, 이전 run 디코딩 호환성을 포함한다.
취소 전의 record 바이트와 저장 source·draft·본문 보존도 확인했다.

- 로그: `/private/tmp/writerpad-recovery-run-fix-regression.log` (최종 명령과 119개 결과).
- 중간 117개 검사: `/private/tmp/writerpad-recovery-run-fix-tests.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.22_13-12-40-+0900.xcresult`.
- debug dylib SHA-256: `1d584f9dc207040cd6c381d7c838a63a08e37d1ad72f9c22f8be923d15bcc017`.
- bundle suffix `.recoveryrunfix`, 별도 DerivedData, 나머지 격리·빈 URL/key·서명 비활성 조건은 동일.
- 최종 빌드/검사 로그 `warning:`·`error:` 0건, xcresult `runtimeWarnings` 비어 있음.
- 계약 검증·`git diff --check` 통과. 계약·wire·Windows·Config·xcodeproj 변경 없음.

최초 P2 재현 작업 트리와 실패 로그는 별도 보존하며 실패 증거를 성공 결과로 덮어쓰지 않았다.
이 검증은 오프라인 세션/저널 복원이며 실제 OS 강제 종료·UI 조작·서버 송수신 검증은 아니다.

이번 변경은 설치·인증·실제 서버 요청·OS suspension을 수행하지 않는다.
SYNC-004는 부분 검증이다. Windows 의존성이나 교차 플랫폼 입력 변경이 없어
Windows 회신은 요청하지 않으며 한 PR의 최종 head에서 검토한다.
