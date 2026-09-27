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
- `git diff --check` 통과. 이 구현 체크포인트 당시 Release 빌드와 원격 CI/PR 검토는 미수행이었다. 후속 결과는 아래에 기록한다.
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

## PR #45 검토 후 보완

- 최초 head `a53f9bba832a9d97a20d5d78afce05f261a30bd5`: Release arm64/x86_64 빌드와 CI 3개 통과.
- GitHub CLI로 확인한 Codex 검토에서 P2 두 건을 확인했다.
  - [충돌·실패 안내 우선순위](https://github.com/ChocoS-yrup/Writerpad/pull/45#discussion_r4114876182):
    저장 기록 경고는 idle/localOnly/synced/automaticallyMerged만 대체한다. 나머지 수신·큐 결과는
    기존 진단 상세, 심각도와 재시도 가능 여부를 유지한다.
  - [동기화 해제 후 경고 잔존](https://github.com/ChocoS-yrup/Writerpad/pull/45#discussion_r4114876187):
    실제 UserDefaults 변경 알림으로 전체/작품별 설정 닫힘을 관찰해 재개를 취소하고 경고를 지운다.
    재시도 진입점도 같은 정리를 수행한다. 전역/작품 설정 revision을 호출자 검증에 포함하므로
    빠른 off/on 뒤 늦게 완료된 작업도 기록을 등록하거나 실패 경고를 다시 게시하지 못한다.
- 관찰자는 workspace start에서 설치하고 stop에서 해제한다. 기존 single-flight 슬롯은 작업 종료까지 유지한다.
- 신규 회귀 3개 포함 SnapshotPull 145개 통과, 실패 0. 실제 설정 알림, 전역/작품 off/on,
  12개 비성공 결과 × 4개 연결 상태 및 성공/idle 4개 결과의 경고 표시를 검증했다.
- 최종 확장 회귀 **576개 통과, 실패/건너뜀/런타임 경고 0**, 컴파일 경고·오류 0건.
  기존 10개 클래스 중 SnapshotPull만 142→145개이며 나머지 검사 수는 동일하다.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_18-53-55-+0900.xcresult`.
- 공유 계약 검증 재통과, canonical SHA-256 불변. 이 수정 체크포인트의 Release 재검증은 진행 중이며,
  최종 Release/CI 증거는 PR 본문에 갱신한다. 검증 후 수정 최종 head에 한 번 재검토를 요청한다.
- 검증 로그: `/private/tmp/writerpad-pr45-review-fix-tests-v1.log`,
  `/private/tmp/writerpad-pr45-review-fix-tests-v2.log`, `/private/tmp/writerpad-pr45-review-fix-release-v1.log`.
- 이번 보완은 iPad 표시·로컬 설정 수명만 변경한다. 공유 계약, Windows, 서버, 교차 플랫폼 입력 변경과
  실기기/실서버 시험은 없다. Windows 회신 및 추가 백업은 요청하지 않는다.

## 추가 검토: 자동 재개의 레거시 우회 차단

- `a7e418a`의 576개 회귀·Release·CI는 모두 통과했으나,
  [후속 P2](https://github.com/ChocoS-yrup/Writerpad/pull/45#discussion_r4114925638)에서
  최초 호출자 승인 직후 관문이 닫히면 무검증 일반 recorder로 우회하는 경계가 확인됐다.
- 신규 테스트 2개를 수정 전 실행해 레거시 큐 등록과 원래 인계 파일 삭제를 재현했다.
  합성 TXT·SwiftData·SQLite만 사용했으며 실제 기기나 서버 데이터는 변경하지 않았다.
- 일반 `record(batch)`와 승인 포함 `record(batch, authorize:)`의 경로 선택을 분리했다.
  승인 포함 경로는 관문 닫힘 또는 non-ID_BASED handshake에서 보류하며, 두 레거시 우회 지점에
  진입하지 않는다. 계약 큐에서는 기존 최종 SQLite 승인 검사를 그대로 사용한다.
- 일반 저장의 닫힌 관문/LEGACY 본문 동작은 유지한다. 새 테스트는 계약 이력이 없는 작품의
  최초 승인 직후 닫힘을 결정적으로 재현하고, 큐 미등록·파일 바이트·본문 보존을 검사한다.
  별도 LEGACY handshake 테스트는 자동 재개 거부 뒤 명시적 일반 재시도 성공도 확인한다.
- 수정 후 선택 회귀 **578개 통과, 실패/건너뜀/런타임 경고 0**, 컴파일 경고·오류 0건.
  Handshake 143개, SnapshotPull 145개이며 나머지 8개 클래스 검사 수는 동일하다.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_19-29-27-+0900.xcresult`.
- 이 수정 체크포인트의 Release arm64/x86_64 빌드는 진행 중이며 최종 증거는 PR 본문에 갱신한다.
  계약 0.2.0 검증은 재통과했고 digest는 불변이다. 최종 검증 후 새 head에 재검토를 한 번 요청한다.
- 재현 로그: `/private/tmp/writerpad-pr45-recorder-red.log`.
  수정 검증 로그: `/private/tmp/writerpad-pr45-recorder-tests-v1.log`,
  `/private/tmp/writerpad-pr45-recorder-release-v1.log`.
- 변경은 iPad 로컬 기록 경로에 한정된다. Windows 구현·공유 wire 계약·SQL/RPC/RLS·입력 동작 변경은 없다.

## 추가 검토: 설정 재시도 후 작업 화면 경고 갱신

- `8f1ed18`의 578개 회귀·Release·CI는 모두 통과했다. 후속 검토의
  [P2](https://github.com/ChocoS-yrup/Writerpad/pull/45#discussion_r4115019044)는 설정에서 파일 인계를
  처리한 뒤에도 작업 화면의 이전 경고가 남는 문제였다. 수정 전 실제 설정 모델·TXT·SwiftData·SQLite를
  사용하는 통합 테스트에서 경고 잔존과 재확인 누락을 재현했다.
- 설정의 파일 인계 재시도가 반환하면 작품 UUID를 담은 내부 알림을 보낸다. 이 알림은 동기화 성공의
  증거가 아니라 현재 파일 상태를 다시 확인하라는 신호다. 활성 상태인 동일 작품의 작업 화면만 처리한다.
- 작업 화면에 경고 또는 진행 중인 재개가 있을 때 이전 재개 세대를 취소하고 기존 공유 재개 경로를
  다시 실행한다. 이전 작업은 종료할 때까지 single-flight 자리를 유지한다. 기존 경고는 재확인 동안
  보존하고, 남은 기록 없음이 확인돼야 지운다. 실패·손상 파일이 남으면 경고를 유지한다.
- 관찰자는 start/stop 수명에 묶고 관찰 ID로 stop 이전에 예약된 늦은 알림도 거절한다.
  미개봉 작품 순회, 주기적 스캔, Windows/공유 계약/서버/교차 플랫폼 입력 변경은 없다.
- 신규 회귀 3개: 실제 설정의 성공·부분 처리 후 별도 전경/네트워크/배지 조작 없이 갱신,
  다른 작품·종료된 화면 알림 무시 및 읽기 실패 시 경고 유지, 오래된 재개 종료 후 재확인 직렬화.
- 선택 회귀 **581개 통과, 실패/건너뜀/런타임 경고 0**, 컴파일 경고·오류 0건.
  Handshake 144개, SnapshotPull 147개이며 나머지 8개 클래스 검사 수는 동일하다.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_22-03-06-+0900.xcresult`.
- 이 수정 체크포인트의 Release 빌드는 진행 중이며 최종 증거는 PR 본문에 갱신한다.
  계약 검증은 재통과했고 canonical digest는 불변이다. 검증 후 새 최종 head에 한 번 재검토를 요청한다.
- 재현 로그: `/private/tmp/writerpad-pr45-settings-warning-red.log`.
  수정 검증 로그: `/private/tmp/writerpad-pr45-settings-warning-tests-v1.log`,
  `/private/tmp/writerpad-pr45-settings-warning-release-v1.log`.
