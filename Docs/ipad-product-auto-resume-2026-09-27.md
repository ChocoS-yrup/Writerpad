# 열린 작품의 저장 기록 자동 재개 — 2026-09-27

## 기준과 범위

- PR #44는 GitHub CLI로 검토·CI를 확인한 뒤 `660135b4362231e2a41a80d9a7703d88a84ab713`으로 main에 병합했다.
- 후속 브랜치: `codex/ipad-product-auto-resume`.
- 현재 열린 작품의 활성화/전경 복귀, 로그인/연결 갱신, 네트워크 복구와 상태 배지의 명시적 재시도에 파일 인계를 연결한다.
- 미개봉 작품 전체 순회, 주기적 파일 스캔, OS 백그라운드 실행 스케줄러는 이번 범위가 아니다.
- 진단 앱 재시험, 실기기 설치, 실제 서버 송수신 및 서버 데이터 변경은 하지 않는다.

## 구현

`SyncV2ProjectHandoffResumer`로 설정의 기존 검증을 공통화했다. 자동 경로도 같은 계정·연결 소유자·활성 작품·
작품별 opt-in·전체 동기화 설정·ID_BASED handshake·전경·서버 기준 검사와 기존 recorder를 거친다.
본문을 재저장하거나 opt-in을 자동으로 켜거나, 기존 요청 ID와 내용을 다시 만들지 않는다.

자동 경로는 로컬 파일 인계의 존재를 먼저 읽기 전용으로 확인한다. 기록이 없으면 handshake/서버 기준
조회와 일반 큐 재시도를 생략한다. 손상된 파일은 존재하는 것으로 간주해 재개 실패로 보고한다.
설정의 명시적 재시도는 기존의 큐/receipt 복구 경로를 유지한다.

작업 공간 내에서는 재개 한 건만 진행한다. 같은 수명의 반복 사건은 진행 중인 작업에 합류한다.
화면 비활성/종료와 인증/연결 변경은 재개 세대를 즉시 무효화하고 취소를 요청한다.
취소를 무시하는 작업도 실제 종료 전에는 실행 자리를 넘기지 않는다. 그동안 새 수명에서 재개 요청이
오면 종료 뒤 한 번만 다시 실행한다. 기존 로컬 저장/기록 gate와 송신기의 최종 권한 검사는 유지한다.
자동 경로는 호출자 검증을 로컬 저장소의 gate 안쪽과 recorder의 SQLite enqueue 직전까지 전달한다.
내부 비구조적 Task가 상위 취소를 자동 전파하지 않아도 같은 검증 closure로 옛 수명을 거절한다.
이를 지원하지 않는 저장소/recorder의 기본 구현은 무검증 재시도로 우회하지 않고 보류한다.

파일 기록이 보류됐으면 현재 문서의 pull 성공만으로 작품이 모두 동기화됐다고 표시하지 않는다.
배지에 `저장 기록 확인 필요`와 재시도 안내를 표시하되, 로컬 저장 실패·현재 문서의 기록 실패·다른 기기
편집 잠금은 기존 우선순위를 유지한다.

## 검증

- 첫 구현의 선택 회귀 287개 통과. 이는 파일 존재 확인 보완 전 중간 결과다.
- 취소 경계 추가 보완 전 확장 회귀 572개 통과. 중간 결과를 최종 증거로 대체하지 않는다.
- 최종 확장 회귀 **573개 통과, 실패 0, 건너뜀 0**, `runtimeWarnings: []`, 컴파일 경고·오류 0건.
- AppEnvironment 116, LocalDocumentStore 17, LocalDocumentStoreRecovery 3, ReceiveValidationPolicy 18,
  SupabaseProjectBindingService 26, SyncSettingsModel 6, Dispatcher 31, GeneralSync 73, Handshake 141, SnapshotPull 142.
- iPad Pro 11-inch (M5) / iOS 26.5 simulator, Debug 격리 bundle, 빈 서버 URL/key, 고정 package 버전, 서명 비활성.
- 로그: `/private/tmp/writerpad-auto-resume-tests-v3.log`.
- 결과: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_18-27-57-+0900.xcresult`.
- `git diff --check` 통과. 최종 소스 Release 빌드와 원격 CI/PR 검토는 아직 수행하지 않았다.
- 계약 검증 통과: 0.2.0, 스키마 7개/전이 12개/저장 이름 15개/atomic wire 4개/document wire 7개.
- canonical SHA-256: `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.
- 실제 TXT·SwiftData·SQLite와 합성 원격 transport를 사용한다. 수명 재개는 모델/저장소 경계 테스트이며 실제 프로세스 강제 종료 증거가 아니다.
- 신규 검사: 재개 중복 합류, 취소를 무시하는 작업과 전경 재진입 직렬화, opt-in/전역 설정, 보류 배지,
  미개봉 문서 2개 자동 재연결과 반복 사건의 중복 방지, 빈 기록의 서버 조회 생략, 손상 기록 보존,
  recorder 내부 await 중 호출자 수명 변경 후 SQLite 미등록과 원래 파일 바이트 보존.

## 호환성·후속 단계

Supabase 스킬에 따라 changelog와 [Swift 세션 갱신 문서](https://supabase.com/docs/reference/swift/auth-refreshsession)를 확인했다.
기존 인증 서비스/인증된 transport를 유지한다. 관리자 키, 인증 우회, 사용자 편집 metadata 기반 권한을 추가하지 않았다.
SQL/RLS/RPC/공유 계약/Windows 구현/교차 플랫폼 입력/패키지/서명 설정 변경은 없다.
새 로컬 Swift 저장소 조회 인터페이스는 Windows wire 계약이 아니다. Windows 회신은 요청하지 않는다.

후속은 자동 재개 경계 추가 점검과 최종 Release 빌드, 관련 변경을 묶은 PR 검토다.
현재 단계의 구현만으로 전체 자동 동기화나 실기기 검증 완료를 주장하지 않는다.
