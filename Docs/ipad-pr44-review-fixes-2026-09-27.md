# PR #44 최종 검토 지적 보완

첫 검토 기준: `1e0eab33f34d4c54664ec7f06b2164a0d73d66a8`.
GitHub Codex가 P1 2건·P2 1건을 제시했으며, 하나의 후속 변경으로 보완한다.

## 1. 연결 변경 시 이전 활성화 철회

`SupabaseProjectBindingService`가 연결을 해제하면 작품별 관문을 먼저 닫는다.
서버/계정 대상이 다른 연결을 저장하기 전에도 관문을 닫아 이전 opt-in이 새 대상으로 이어지지 않는다.
같은 서버·계정의 이름 새로고침은 승인을 유지한다. 기존 binding epoch 전환 검사도 유지한다.
서비스와 UI는 제품에서 같은 기본 UserDefaults를 사용하며 시험은 격리 suite를 주입한다.

검사: 이름 새로고침, 해제→동일 대상 재연결, 다른 서버 대상, 다른 계정 대상,
UserDefaults 재생성 뒤의 닫힘을 확인한다.

## 2. 파일 인계 출처 고정

TXT 교체 전에 저장소의 연결에서 로컬 작품·서버 작품·소유 계정 UUID를 읽는다.
이를 로컬 `LocalMutationBatch.handoffOrigin`에 저장하고 재생 시 현재 연결과 비교한다.
원고 본문이나 기존 batch/operation ID를 다시 만들지 않는다. 교체용 로컬 배치도 출처를 유지한다.
계약 recorder와 구형 recorder에서 검사하며 실제 SQLite 큐 작성 시에도 현재 연결을 재확인한다.
출처를 모르는 이전 형식 인계 파일은 현재 연결을 임의로 부여하지 않고 보류한다.
재시도 실패 시 파일과 본문을 삭제하거나 다른 서버로 재배정하지 않는다.

기존 기준 메타데이터의 외래키는 서버 ID 직접 변경을 이미 제한한다. 최초 시험의 직접 교체는
이 보호에 걸렸으므로 보호를 제거하지 않고, 기존 인계 파일이 남은 상태에서 새 연결 저장소를
사용하는 재개 사례로 검사했다. 서비스 수준 연결 변경과 SQLite 기록 직전 출처 불일치도 따로 검사한다.
출처 필드는 iPad 로컬 기록용이며 서버 RPC나 공유 계약 형식을 변경하지 않는다.

## 3. 기준 승인 공개와 잠금 해제 순서

서버·저장 기준이 일치하면 마지막 비동기 조회 뒤 권한을 다시 확인하고,
upload permit을 보유한 상태에서 기준 승인을 공개한 뒤 permit을 반환한다.
수신 준비 handler가 공개 전 토큰을 교체하는 순서 문제를 방지한다.
반환 직후에도 권한을 검사하며, 그 사이 취소되면 자신이 공개한 승인만 revision 비교로 무효화한다.
새 수신이 만든 더 최신 승인은 이전 continuation이 지우지 않는다.

검사: 미처리 서버 세대가 있는 상태에서 수신 준비 callback이 이미 공개된 승인을 보는지,
callback 중 권한 취소가 발생해도 점유가 반환되고 이전 승인이 무효화되는지 확인한다.
첫 중간 실행은 반환 후 무효화 보완 전 코드로 이 후자 검사를 실패했고 후속 수정에 포함했다.

## 첫 보완 검증 및 경계

최종 소스 회귀 **564개 통과, 실패 0, 건너뜀 0**, `runtimeWarnings: []`.
컴파일 경고·오류 0건이며 격리 시뮬레이터·빈 서버 URL/key·고정 package 버전을 사용했다.

- AppEnvironment 116, LocalDocumentStore 17, LocalDocumentStoreRecovery 3,
  ReceiveValidationPolicy 18, SupabaseProjectBindingService 24, SyncSettingsModel 6,
  Dispatcher 31, GeneralSync 73, Handshake 137, SnapshotPull 139.
- 회귀 로그: `/private/tmp/writerpad-pr44-review-fix-tests-v2.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_16-14-14-+0900.xcresult`.
- 최종 Release 로그: `/private/tmp/writerpad-pr44-review-fix-release-v1.log`.
  Release 완료와 새 head의 원격 CI·재검토 결과는 PR 본문/댓글에 기록한다.

변경된 로컬 기록 외에 서버 스키마·RLS·RPC·
계약 0.2.0·Windows 구현·교차 플랫폼 입력·의존성은 변경하지 않는다.
계약 검증기는 Python 3.12 및 고정 의존성으로 통과했다.
Supabase 스킬의 인증 보안 기준에 따라 기존 인증·계정 검사와 인증된 transport를 유지했다.
실기기 설치·실서버 변경·백업·과거 진단 앱 재시험은 하지 않는다.

## 재검토 추가 P2 보완

재검토 기준: `374062aa7b71bab4c2a463570f360358b6aeac43`.

### 4. 출처 없는 이전 기록의 선두 정체 해소

- 검토: https://github.com/ChocoS-yrup/Writerpad/pull/44#discussion_r4114486508
- 이전 기록 자체에 현재 연결을 부여하지 않는다. 같은 작품·문서의 더 최근 완전한
  `documentSave`가 현재 연결 출처와 일치할 때만 옛 기록을 활성 재시도에서 분리한다.
- `.writerpad-quarantined-handoff-<batch UUID>.json`에 기존 batch/operation ID·본문을
  그대로 원자적으로 보존한 뒤 활성 파일을 갱신한다. 이 파일은 자동 재생하지 않는다.
- 별도 보존 실패 시 활성 기록과 새 저장을 모두 보류한다. 활성 파일 갱신 실패 시
  메모리 목록도 원래대로 되돌린다. 중단 후 같은 보존 파일이 있으면 내용 일치를 검사한다.
- 새 출처가 없거나 다른 연결인 기록, 구조 변경/삭제 기록은 이 처리로 우회하지 않는다.
- 회귀: 기존 형식 파일 재개→새 저장 큐 등록, 별도 파일 쓰기 실패→저장소 재생성 후
  재시도, 원래 기록 일치, TXT 유지, 다시 열어도 큐 중복/옛 기록 재송신 없음.

### 5. 첫 서버 연결과 TXT 저장 직렬화

- 검토: https://github.com/ChocoS-yrup/Writerpad/pull/44#discussion_r4114486515
- `AppEnvironment`가 별도의 작품별 gate를 생성해 제품 `LocalDocumentStore`와
  `SupabaseProjectBindingService`에 공유한다. 기존 문서별 gate와 다른 인스턴스다.
- 저장/파일 인계 재시도는 작품→문서 순서로 gate를 사용한다. 연결 확정은
  binding 저장부터 초기 snapshot 큐 등록까지 작품 gate 안에서 수행한다.
  서버 ensure/비어 있음 사전 조회는 gate 밖에서 실행한다.
- 저장이 먼저면 로컬 저장 완료 뒤 초기 snapshot이 새 TXT를 읽는다. 연결이 먼저면
  초기 snapshot 큐 등록 뒤 새 저장이 확정된 출처를 캡처한다.
- 해제 및 current/allBindings의 초기 snapshot 재개도 같은 gate를 사용한다.
  조회 중 기다린 binding이 변경되었으면 옛 값으로 초기 snapshot을 재개하지 않는다.
- 회귀: 실제 TXT와 `ProjectInitialSyncRecorder`를 사용해 저장 전 validation 중
  연결 시작, 초기 snapshot 기록 중 새 저장 시작의 양쪽 순서를 barrier로 재현한다.
  최종 본문이 초기 또는 후속 snapshot에 포함되고 출처 없는 파일이 남지 않음을 검사한다.

### 추가 보완 검증

최종 회귀 **566개 통과, 실패 0, 건너뜀 0**, `runtimeWarnings: []`.
컴파일 경고·오류 0건. 첫 보완의 564개에 새 테스트 메서드 2개를 추가했으며,
각 메서드에서 정상/보존 실패 및 경합의 양쪽 순서를 검사한다.

- AppEnvironment 116, LocalDocumentStore 17, LocalDocumentStoreRecovery 3,
  ReceiveValidationPolicy 18, SupabaseProjectBindingService 25, SyncSettingsModel 6,
  Dispatcher 31, GeneralSync 73, Handshake 138, SnapshotPull 139.
- 회귀 로그: `/private/tmp/writerpad-pr44-rereview-fix-tests-v3.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_16-45-10-+0900.xcresult`.
- 추가 보완 Release 로그: `/private/tmp/writerpad-pr44-rereview-fix-release-v1.log`.
  Release 완료 및 새 커밋의 원격 CI와 재검토 요청은 PR에 별도로 남긴다.
- 계약 0.2.0 검증기 재통과. `git diff --check` 통과.

첫 중간 빌드는 새 테스트 대역의 필수 메서드 누락으로 실패했다. 다음 중간 시험은
대역이 빈 operation ID를 반환해 결과 판정이 실패했으며, 대역을 수정했다.
그 실행의 optional 문자열 출력 경고도 명시적인 표현으로 수정했다.

서버·공유 계약·Windows·교차 플랫폼 입력은 여전히 변경하지 않는다.
Supabase 변경사항과 공식 인증 문서를 확인했으며 기존 인증 transport/출처 검사를 유지한다.
