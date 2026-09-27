# iPad 복구 변경 묶음 최종 회귀 점검 — 2026-09-27

## 판정

현재 로컬 코드 변경 묶음의 대상·인접 회귀 검사 **426개 통과, 실패 0, 건너뜀 0**.
A–D 실기기 진단 경계 시험도 모두 완료했다. 이는 전체 제품 또는 모든 장애 시험의 완료를 뜻하지 않는다.
아래 회귀 점검 단계에서는 코드 변경, 실기기 재설치/재실행, 서버 변경, 커밋/푸시/PR 생성을 하지 않았다.
후속 PR 제출에서는 이 검사와 동일한 Swift 코드 및 아래 증거 문서를 한 묶음으로 사용한다.
최종 제출 head와 검토 상태는 GitHub PR을 기준으로 확인한다.

- 작업 branch: `codex/ipad-diagnostic-auth-keyboard`.
- 기준 HEAD/main: `6ae7421afd53f0519cf2cc0dd01d34d9a92d89fa` (PR #42 병합).
- 14:19 KST 무렵 `gh pr list --state open`, `gh api .../branches/main`으로 열린 PR 0건과 같은 원격 main SHA를 확인했다.
- 코드 변경은 기존 7개 Swift 파일에 1,602줄 추가/21줄 삭제이며 회귀 점검 당시 미커밋이었다. 이 문서 및 상태 연결 문서는 별도다.

## 한 PR에 포함할 변경과 검토 결과

1. 진단 로그인 UIKit 필드의 identity/secure trait 유지, assistant shortcut 비활성화, 폼 내부 Tab/Shift+Tab 및 이메일 Return 이동.
2. 고정 메모장 하위 트리만 허용하는 명시적 구조 비교 기준 갱신. 본문 기준선·저장 source를 바꾸지 않으며 갱신 뒤 재준비한다.
3. ID와 source hash가 고정된 이전 미송신 시험 2건의 명시적 취소. source를 삭제하지 않고 감사 표식을 남기며 불확실한 요청·의존성·다른 작업은 거부한다.
4. 동일 UTF-8 본문의 미송신 후속 저장 정리. beforeHTTP에서 동결된 원 요청·batch·operation·run을 유지하고, SQLite 이력이 없는 동일 후속 저장만 superseded로 기록한다.
5. 완료 이력을 활성 대기열로 오인하지 않는 조회. 일반 복구 페이지의 페이지 수와 무관하게 다른 활성 작업은 계속 차단한다.

변경된 production 코드와 관련 회귀 검사를 대조했다. 불변 요청/원본 source, 권한·foreground 검사,
변경된 draft/기준선 거부, SQLite rollback, 필드 교체 시 weak 등록 해제, 일반 본문 포커스 탈취 방지 경로를 확인했다.
이번 검토에서 추가 수정이 필요한 결함은 발견하지 못했다. 이는 독립 검토자의 최종 head 리뷰를 대체하지 않는다.

계약 버전 0.2.0 / protocol 3 / canonical SHA
`416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`는 유지된다.
계약·Windows 참조 구현·공통 본문 입력·서버 스키마/인증 정책 변경은 없다.
따라서 이 변경 묶음에는 Windows 회신을 요청하지 않는다. 최종 commit head에서 한 번만 PR 검토한다.

## 이번 회귀 검사

두 실행은 서로 겹치지 않는 class 집합이다. 과거 161/165개 실행을 다시 합산하지 않았다.

| 집합 | class별 통과 수 | 합계 |
|---|---|---:|
| 직접 변경 | CredentialField 12, StructureReference 9, NormalEditor 74, GeneralSync 70 | 165 |
| 인접 회귀 | AutoSaveIsolation 18, IntegratedEditor 49, LocalDocumentStoreRecovery 3, SaveStateMachine 6, SyncV2Contract 46, SyncV2Store 139 | 261 |

- iPad Pro 11-inch (M5) / iOS 26.5 simulator, Debug, package lock 고정, 병렬 테스트 비활성.
- 별도 bundle suffix `.recoveryrunfix`, `WRITERPAD_ISOLATED_TESTS`, 빈 서버 URL/key, 서명 비활성으로 실제 서버 접근과 실기기 앱 변경을 차단했다.
- 두 실행 모두 `TEST SUCCEEDED`, xcresult failed/skipped 0, `runtimeWarnings: []`.
- 두 로그의 `warning:`/`error:` 0건. `git diff --check` 통과.
- 전체 test target 및 성능 측정 harness를 실행한 결과가 아니라 위 10개 class의 선택 회귀 결과다.

증거(로컬 임시 파일이며 공개 배포 대상 아님):

- `/private/tmp/writerpad-final-recovery-regression-20260927.log`
- `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_14-18-34-+0900.xcresult`
- `/private/tmp/writerpad-final-recovery-adjacent-regression-20260927.log`
- `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_14-20-02-+0900.xcresult`

## 실기기 증거 연결

| 시험 | 재개 방식 | 완료 journal / revision | 기록 |
|---|---|---|---|
| A beforeHTTP | 같은 동결 요청으로 첫 송신 | 137 / 10 | [A 및 중복 정리](ipad-frozen-request-duplicate-reconciliation-2026-09-27.md) |
| B afterCommitResponse | 서버 처리 결과 조회 후 완료 | 164 / 11 | [B](ipad-recovery-b-after-commit-response-2026-09-27.md) |
| C afterStoredResponse | 저장된 응답으로 로컬 완료 | 188 / 12 | [C](ipad-recovery-c-after-stored-response-2026-09-27.md) |
| D afterOriginalApply | 같은 수신 건으로 기준선·draft 완료 | 207 / 13 | [D](ipad-recovery-d-after-original-apply-2026-09-27.md) |

마지막 확인된 실기기 상태는 D 완료, 활성 송신 대기 0이다. D의 서버 본문 생산자는
사용자 승인 관리 작업이므로 Windows/iPad 송신 성공으로 집계하지 않는다.
A–D는 진단 오류 후 사용자 앱 전환기 종료/홈 아이콘 재실행 복구이며 실제 망 단절이나 임의 시점 OS 종료가 아니다.

## 다음 단계와 남은 범위

1. 위 변경·증거 문서를 한 commit/PR 묶음으로 정리하고 최종 head 기준 검토 1회. 이 회귀 점검 기록 시점은 PR 생성 전이며 이후 제출 상태는 GitHub에서 확인한다.
2. [로그인 Tab](ipad-diagnostic-credential-tab-2026-09-27.md)의 실제 iPad 물리 키보드 이동 확인. 자동 responder 검사 12개는 통과했지만 사용자의 명시적 물리 Tab 확인은 아직 없다. 로그인 버튼은 누르지 않고 이메일→Tab→비밀번호, Shift+Tab→이메일 및 본문 불변만 확인할 수 있다.
3. 실제 통신 장애, 임의 시점 OS 종료, 저장 전 입력/한글 IME 조합의 별도 시험. 기존 저장 완료 본문 수명주기 검사와 구분한다.
4. 제한된 단일 문서 진단에서 일반 제품 dispatcher/다중 문서 동작으로 확대하는 구현·검증 범위 정리. A–D만으로 해당 범위 완료를 선언하지 않는다.

사용자 지침에 따라 모든 시험 데이터에 별도 백업·복원은 요구하지 않는다.
이미 완료된 D 관리 SQL/복구 버튼, 이전 대기 2건 취소를 반복 실행하거나 저널을 초기화하지 않는다.
