# iPad 복구 진단 로그인 Tab 이동 수정 — 2026-09-27

## 보고 및 원인

사용자가 이메일 입력칸에서 Tab을 누르면 본문에 포커스가 이동하여 실수로 본문을 입력했다고 보고했다.
이후 송수신 준비에서 `NORMAL_QUEUE_FAILED`가 표시됐다.

실기기 journal 119번(`actionStopped`)에서 다음을 확인했다. 실제 입력 문자열은 로그·문서에 옮기지 않았다.

- 기존 A run과 beforeHTTP checkpoint는 유지된다.
- 기존 run의 frozen 요청은 request hash `0c2d2ab761fa3f637da7bc669ff09426bcfb044bd3f0437fc97e0104be9ddd76`, journal attempts 0을 유지한다.
- 별도의 queued 저장 1건이 추가되어 미완료 저장이 총 2건이다. 새 저장에는 request/hash/attempt가 없다.
- 두 활성 source와 draft는 원래 A 시험 본문인 동일한 29바이트이며 SHA-256은 `f2c3066ea8bfce2a389f9cd8e80eea85d6a9ac6b2cfa4b2e8cd3120a26569ec0`이다.
- `NormalEditorRecoveryInjection.preflight`는 A~C의 미완료 저장이 정확히 1개여야 하므로 이 상태를 `NORMAL_QUEUE_FAILED`로 차단한다. 본문을 되돌렸어도 이미 만든 frozen 요청과 추가 저장은 자동 병합되지 않는다.

따라서 본문 오입력·복원으로 추가 저장이 생긴 것이 현재 준비 실패와 부합한다. 실패는 서버 전송 이전 로컬 사전 검사에서 발생한다. 이번 단계에서 서버 상태를 직접 조회하지 않았다.

## 변경 범위

- 진단 화면 전용 `NormalEditorCredentialFocus`가 이메일/비밀번호 UITextField를 weak 참조한다.
- 해당 입력칸이 first responder일 때만 Tab/Shift+Tab을 우선 처리하여 두 칸 사이에서 이동한다. 본문으로 빠지지 않고, Tab은 로그인·저장·송신을 호출하지 않는다.
- 이메일 Return도 비밀번호로 이동한다. 비밀번호 Return의 기존 로그인 동작은 유지한다.
- 대상 칸이 없거나 비활성/다른 window이면 기존 입력칸에 머문다. 조합 중에는 강제로 포커스를 이동하지 않는다.
- SwiftUI 갱신 시 focus 요청을 자동 발생시키지 않는다. teardown 시 등록과 참조를 해제하며 교체된 새 필드 등록을 지우지 않는다.
- 이전 TUIInputAssistantHostView 크래시 회피(빈 assistant shortcut groups, 고정 secure/contentType, accessory view 미추가)는 유지한다.
- 공통 본문 입력, Windows, 계약, 서버 스키마/인증 정책은 변경하지 않는다. Windows 회신은 필요하지 않다.

API 근거: https://developer.apple.com/documentation/uikit/uikeycommand/wantspriorityoversystembehavior

## 남은 큐 문제

Tab 수정은 재발 방지이며 이미 생긴 중복 저장을 정리하지 않는다.
기존 `동일 본문 중복 대기 정리`는 요청 생성 전 freezing 상태만 허용한다. 현재는 frozen 요청과 소비된 checkpoint가 있어 적용할 수 없다.
이 조건을 무작정 완화하거나 기존 요청을 재발급/삭제하지 않았다. 후속 단계에서 동일 요청·run을 유지하는 별도 정리 경로가 필요하다.

후속 구현·검증은 [frozen 요청 뒤 중복 정리](ipad-frozen-request-duplicate-reconciliation-2026-09-27.md)를 참조한다.

## 검증

- iPad Pro 11-inch(M5) / iOS 26.5 simulator에서 총 **161개 통과 / 실패 0 / 건너뜀 0**.
- CredentialField 12개(기존 6 + 신규 6), StructureReference 9개, NormalEditor 70개, GeneralSync 70개.
- 신규 검사는 UIWindow 내 first responder를 사용하여 Tab/Shift+Tab 양방향 이동과 본문 불변, Tab의 미제출·binding 불변, 비활성/미등록 대상, 비활성 입력칸의 포커스 탈취 방지, 이메일 Return, teardown과 교체 필드 등록 보존을 검사했다.
- simulator test/device build 성공. 로그 `warning:`/`error:` 0건, xcresult `runtimeWarnings: []`.
- 실기기 서명 검증 성공. 동일 `com.chocos.writerpad.debug`로 삭제 없이 덮어 설치하고 환경변수 없이 실행 성공. 후속 프로세스 조회에서도 실행 중이었다.
- 설치 전후 119번 record와 draft를 각각 `cmp`로 비교하여 바이트 동일 확인. 실행 후에도 119번이 최신이었다. 로그인·송수신·큐 정리는 하지 않았다.
- 실제 iPad 물리 Tab 이동은 사용자 확인 대기다. 키 명령 핸들러·UI responder 테스트를 물리 키보드 시험으로 보고하지 않는다.

검증 로그:

- `/private/tmp/writerpad-tab-fix-tests.log`
- `/private/tmp/writerpad-tab-fix-device-build.log`
- `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_12-36-31-+0900.xcresult`

로컬 진단 증거(임시 파일, 공개 배포 대상 아님): `/private/tmp/writerpad-tab-fix-6VQuBE/`.
