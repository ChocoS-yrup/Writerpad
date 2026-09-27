# 실사용 앱의 작품별 일반 동기화 설정 연결 — 2026-09-27

## 범위

PR #43 병합 main `4141059`에서 시작했다. 사용자 요청대로 복구 진단 앱의 물리 Tab 확인은
진행 조건에서 제외한다. 이번 변경 대상은 `NormalEditor`/`IntegratedEditor`가 아니라
일반 WriterPad의 설정 화면과 기존 동기화 경로다.

기존 live 환경에는 LocalDocumentStore → durable recorder → 일반 계약 큐 → dispatcher와
서버 수신 경로가 연결돼 있다. 하지만 작품별 계약 경로를 켜는 UI가 개발 진단 화면에만 있고,
일반 화면의 상태 조회·재시도 호출 대상도 `DEBUG` 조건 안에 있었다.

## 구현

- 작품별 서버 연결 아래에 일반 동기화 스위치와 활성화 확인창을 추가했다. 임의 서버 UUID를
  입력하는 진단 절차 없이 현재 연결된 작품에 대해 서버 호환성을 새로 확인한다.
- 제품 UI는 ID_BASED 응답만 허용한다. LEGACY 서버 작품의 자동 이관이나 새 서버 작품 생성은 하지 않는다.
  과거 개발용 LEGACY 관문은 개발 섹션에만 명시적으로 남겨 둔다.
- 현재 인증 계정과 연결 소유자, 표시 중인 연결과 현재 연결의 동일성, 활성 작품 여부를 검사한다.
  인증·연결·작품 수명·화면 activity 세대가 바뀌면 늦은 응답으로 활성화하지 않는다.
- 프로젝트 관리 인터페이스에 기존 수명 epoch를 전달한다. epoch를 제공하지 않는 구현은
  활성화를 승인하지 않는다. 새 권한 플래그나 서버 권한 우회는 없다.
- 같은 작품의 중복 확인을 막고, 설정 화면 이탈/비활성 시 미완료 활성화를 취소한다.
  닫기는 즉시 반영하며, 기존 연결·본문·큐를 삭제하지 않는다.
- 스위치는 작품별 계약 경로 선택이다. 전체 자동 동기화 설정을 대신 켜지 않으며,
  기존 송신기의 계정·서버 상태·구조 기준·대기열·전경 검사는 그대로 유지한다.
  구형 동기화 경로 전체를 차단하는 전역 중지 스위치가 아니다.
- 관문 상태 로드, 일반 대기열 조회·재시도 함수를 Release에서도 사용하도록 옮겼다.

## 검증

최종 선택 회귀 **358개 통과, 실패 0, 건너뜀 0**:

- AppEnvironment 116, LocalProjectManager 27, ReceiveValidationPolicy 18,
  SyncSettingsModel 6, GeneralSync 70, Handshake 121.
- 새 제품 활성화 검사 7개는 소유자/표시 연결 불일치, LEGACY·계약 불일치, 인증·연결·작품 수명·
  scene·취소 변화, 중복 클릭, 작품별 격리, 삭제/로그아웃, 통신 실패 뒤 재시도를 포함한다.
- iPad Pro 11-inch (M5) / iOS 26.5 simulator, 격리 bundle 및 빈 서버 URL/key,
  `WRITERPAD_ISOLATED_TESTS`, 고정 package 버전, 서명 비활성. 실제 서버에 접속하지 않았다.
- 로그 `warning:`/`error:` 0건, xcresult `runtimeWarnings: []`. 전체 suite 또는 실기기 송수신 완료로 집계하지 않는다.
- 최종 로그: `/private/tmp/writerpad-product-sync-settings-tests-v3.log`.
- 결과 번들: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_14-45-56-+0900.xcresult`.

일반 **Release 최적화 빌드 성공**:

- generic iOS Simulator 대상, 산출물 아키텍처 `arm64`·`x86_64` 확인.
- DEBUG·복구 진단·격리 테스트 플래그를 추가하지 않은 Release 구성으로 빌드했다.
- 별도 `.productreleasecheck` bundle suffix, 빈 서버 URL/key, 고정 package 버전,
  서명 비활성. 빌드만 수행했으며 설치·실행하지 않았다.
- 로그 `warning:`/`error:` 0건.
- 로그: `/private/tmp/writerpad-product-sync-release-v1.log`.

최초 Debug 빌드에서 수명 epoch의 프로토콜 노출 누락을 수정했다.
중간 검사에서는 테스트 fixture 전체를 Sendable closure로 캡처하던 경고와,
concrete 테스트 더블의 호출이 프로토콜 기본 nil 구현을 선택한 assertion을 수정했다.
경고 억제나 제품 권한 검사 완화로 해결하지 않았다.

## 보안·호환성 및 다음 범위

Supabase 스킬에 따라 최신 변경 목록과 공식 Swift 인증 문서를 확인했다.
[user()](https://supabase.com/docs/reference/swift/auth-getuser)는 서버가 검증한 사용자 정보와
로컬 캐시의 구분을 설명한다. 기존 인증 서비스와 인증된 서버 handshake를 유지하고
화면의 로그인 표시나 사용자 편집 metadata만으로 권한을 열지 않는다.
토큰·key·계정 식별자는 문서나 로그에 추가하지 않는다.

서버 API·계약 0.2.0·Windows·교차 플랫폼 입력·스키마·RLS는 변경하지 않았다.
이 iPad 전용 연결에는 Windows 회신을 요구하지 않는다. 관련 실사용 연결 변경을 묶어 최종 head에서 검토한다.

이번 단계는 실사용 설정 연결 구현이며 설치/실제 서버 송수신 완료가 아니다.
다음은 일반 앱의 다중 문서 저장→대기열→송신·수신 흐름을 제품 구성으로 검증하고
필요한 연결을 보완하는 단계다. 진단 앱 Tab 시험이나 백업은 선행 조건이 아니다.
