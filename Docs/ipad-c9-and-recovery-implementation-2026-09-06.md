# iPad C9 및 복구 진단 보완

기준: `bb40d22164f34371f9ad7f70b9cddf208a692f83` 위 수정이며 이 문서와 함께 커밋되는 코드다.
날짜: 2026-09-06 KST. 이 문서는 이전 검토 회신 이후의 구현 결과다.
실제 계약 관문·서버 설정·계약 pin/digest는 변경하지 않았다.

## 변경 동작

### C9: 구조 승인과 작품 상태

`SyncV2ContractStructureAuthority`는 작품별로 구조 기준과 인증/binding 문맥,
대기열 차단 여부, 확인한 서버 작품 상태를 보관한다. 구조 기준은 메모리에만
있으며 새 실행에서는 미확인이다. 디스크의 과거 성공 시각으로 승인하지 않는다.

- 실제 snapshot pull 시작 시 기준을 미확인으로 바꾸고, 해당 호출 토큰에만
  완료 권한을 준다. 늦은 성공은 이후 차단/새 pull을 덮어쓰지 못한다.
- 폴더 조회, projection 평가, 순서 기준 반영이 확인되고 구조 거절·대기·merge가
  없는 경우에만 기준을 허용한다. 원고 pull이 성공했더라도 폴더 조회 실패를
  삼켰거나 projection을 평가하지 못했다면 계약 구조는 허용하지 않는다.
- 정상 로컬 enqueue가 `lastPullSucceeded=false`를 만드는 것은 구조 기준을
  무효화하지 않는다. 기존 동기화 표시와 구조 쓰기 승인을 구분한다.
- coordinator가 queue를 받는 실제 경로에서 blocked/conflict를 공유한다.
  이 둘이 있으면 계약 구조 쓰기를 보수적으로 차단한다. 일반 원고 dispatcher의
  승인 조건을 변경하지 않았다. queue가 해소돼도 대기 중인 옛 전송 증명은
  재사용하지 않는다.
- 로컬 작품 삭제 대기·삭제 목록 이동·영구 삭제·복원 함수의 수명 세대를
  실제 manager에 추가했다. 상태 조회 전후 및 송신 직전에 같은 수명인지
  확인한다. 상태 조회 실패, 누락 작품, 로컬 비활성 작품은 계약 전송하지 않는다.
- 수동 계약 송신 때마다 `get_project_status`를 읽는다. 응답 작품 UUID가 요청과
  같고 state가 `active`여야 한다. `trashed`, `purged`, 미지 값, 해독/통신 실패는
  허용하지 않는다. 삭제 뒤 복원된 작품도 새 읽기로 재검증할 수 있다.
- 실제 송신은 새 active 판정과 유효한 구조 증명을 확보한 뒤 기존 gate/auth/
  binding/handshake/scene/global-sync 조건에 구조 증명·로컬 작품 수명을 추가해
  예약한다. 읽기 RPC 실행 자체는 쓰기 허가가 아니다.
- 시작 전에 차단되면 같은 batch/operation ID와 payload를 보존한다. 이미 시작한
  요청의 검증된 영수증은 원래 저장소에 반영한다. 상태가 달라지면 새 화면에
  완료 표시를 하지 않는다.

연결 위치: `AppEnvironment`의 recorder/sender/pull service가 같은 authority를
사용한다. `LocalProjectManager`의 실제 삭제·복원 함수와 coordinator의 queue 갱신이
상태 생산자다. 테스트만을 위한 독립 스위치로 승인하는 구현이 아니다.

### 복구 진단

Debug 앱에 `SyncV2RecoveryDiagnostics`를 추가했다. 기록 필드는 실행 session ID,
절대 시각, 단조 uptime, 단계, 사건, 로컬 작품 UUID, 호출 UUID, 재시도 번호·예정
시각으로 제한한다. 이메일·토큰·서버 오류 본문·원고 본문·경로·작품 이름을 받는
필드는 없다.

기록 단계:

- 네트워크 복구 관측, 인증 준비 상태 및 인증 재시도 예정 시각
- handshake 시작, 물리 요청 종료, 유효 응답 수락, timeout/낡은 응답,
  재시도 예정 시각, 아직 끝나지 않은 물리 요청 슬롯 대기
- 기준 pull 시작/종료/실패
- 일반 원고 큐 배출 시작/종료와 계약 배치 송신 시작/완료를 분리
- 화면의 동기화/재연결 표시 변화, 앱 전경/배경 변화

단계는 서로 병렬로 진행할 수 있다. `finished`는 해당 단계 종료이며 모든
데이터의 서버 적용 성공을 뜻하지 않는다. 네트워크 monitor가 여러 개라 같은
복구를 여러 번 관측할 수 있다. handshake의 물리 응답 종료와 유효 응답 수락도
별도 사건이다. 절대 시각은 ISO 8601, 세밀한 간격 비교는 같은 session의 uptime을
사용한다.

파일: 앱 컨테이너 `Library/Caches/SyncDiagnostics/recovery.jsonl` 및
`recovery.previous.jsonl`. 각각 최대 약 512 KiB로 회전하며 직렬 백그라운드 큐에서
기록한다. 기록 실패가 집필·동기화 실패로 전파되지 않는다. Release에서는
기록하지 않는다. 이 파일만 추출하면 기존 원고 관련 상세 로그와 분리해 전달할
수 있다. 캐시 정리나 강제 종료 직전 비동기 기록은 유실될 수 있다.

이전 4회 중 1회의 30초~2분 지연 원인은 아직 미확정이다. 이 변경은 향후 시험의
관측 수단이며 과거 시각을 복원하지 않는다. 수정 앱의 실기기 설치·재현은 아직
수행하지 않았다.

## 서버 읽기 확인

WriterPad Staging의 배포된 `public.get_project_status(uuid)` 함수 정의를 읽기로
확인했다. `active / trashed / purged`와 요청 작품 ID를 반환하며, 인증·작품 소유자
또는 멤버 권한을 확인한다. 로컬 baseline migration의 응답 형식과 일치한다.
`private.has_project_role` 자체가 `trashed_at is null`을 요구하는 것도 읽기로
확인했다. 실제 계약 RPC의 모든 트랜잭션 경계를 검증했다는 뜻은 아니다.
함수 변경이나 실제 작품 상태 변경은 하지 않았다. 사용자 인증으로 실제
`get_project_status` 응답을 받은 시험 대신, 배포 정의 조회와 모의 응답 검증을 했다. 읽기 결과를 iPad 정책 근거로
사용했으며 Windows의 최종 공통 정책 합의가 끝났다는 의미는 아니다.

클라이언트가 아직 관측하지 못한 다른 기기의 서버 상태 변경까지 로컬 증명만으로
차단할 수는 없다. 서버 쓰기 시점의 활성 상태·revision 검사는 별도 canary 사전
확인 대상이다. 실제 계약 RPC 전송 성공·멱등성 증거는 아직 없다.

## 검증 및 전달

최종 `Scripts/run_tests.sh` 결과: **총 957개 / 통과 956개 / 실패 0개 / 건너뜀 1개**.
2026-09-06 10:03:43–10:06:27 KST, iPad Pro 13-inch (M5) Simulator 26.5.

주요 회귀 범위:

- claim 중 / 실제 transport 예약 직전 × 구조 미확인·차단, queue blocked·conflict,
  로컬 삭제 수명, 서버 비활성·미확인 변경에서 계약 전송 **0회**.
- 최초 구조 미확인, 로컬 비활성, 서버 trashed/purged, 상태 조회 통신 실패에서
  전송 0회 및 요청 보존. 복원된 서버 작품은 새 조회 후 같은 배치로 전송.
- 늦은 active 응답이 그 사이 발생한 차단을 지우지 않음. 늦은 pull 성공이 새
  차단을 지우지 않음. 다른 인증 수명에서 이전 구조 기준을 재사용하지 않음.
- 실제 pull 경로에서 폴더 조회 실패·projection 미평가를 승인하지 않음.
  변경 없는 정상 pull과 폴더 변경이 정상 반영된 pull은 모두 승인 가능.
- 정상 로컬 enqueue가 구조 승인을 스스로 막지 않음. 이미 시작한 영수증은
  보존하되 변경된 화면의 완료 표시를 억제함.
- 진단 JSON의 허용 필드, 실제 파일 기록, 파일 크기 제한 확인.

중간 전체 실행에서 기존 `testSnapshotNetworkReadsStartConcurrently` 하나가
500회 yield 전에 요청 시작을 보장하지 못해 실패했다. 실패 시 시작 집합은
빈 집합이었다. 모든 응답을 계속 막아 둔 채 세 요청의 시작 사건을 최대 3초
기다리는 방식으로 시험을 수정했다. 순차 실행이라면 여전히 실패하는 검사다.
관련 135개 재검증 후 위 최종 전체 시험도 통과했다. 원래 실패 기록도 보존했다.

- [최종 전체 원본 요약](evidence/ipad-c9-final-full-test-2026-09-06.json)
- [소스·빌드·검증 식별](evidence/ipad-c9-and-recovery-tests-2026-09-06.json)
- [중간 실패 기록](evidence/ipad-c9-full-test-2026-09-06.json)
- [135개 재검증](evidence/ipad-c9-pull-retest-2026-09-06.json)

검증 수치와 소스 diff SHA는 동반 evidence JSON에 기록한다. 기존 검토용
`ipad-c9-review-probes-2026-09-06.patch`는 수정 전 문제의 재현 자료이며 이번 안전성
회귀 시험 결과와 합산하지 않는다.

최초 canary 범위는 새 폴더 1개 + 해당 부모 tree_order 1개, iPad Debug 수동
1배치 전송으로 유지한다. 원고 contract document_commit, 이름 변경·이동·삭제·
복원으로 범위를 확대하지 않았다.

검증 종료 시점에는 커밋·푸시·실기기 재설치 전이었다. 당시 기기 설치본은 bb40d22이며
이 작업 트리를 실행한 결과로 인용하지 않는다. 다음에는 양쪽 결과를 대조하고,
검증된 변경의 commit/빌드를 고정해 실기기 복구 진단을 수집한다. 실제 계약
관문 개방과 canary는 양쪽 준비가 확인된 이후 별도 단계다.


자동 승인 검토에서 한 편집안의 `return true` 변경이 권한 검사를 약화시킬 수
있다는 이유로 거절됐다. 그 편집안은 실행하지 않았다. 최종 구현은 기존 권한
판정을 유지하며 서버 상태 읽기를 다시 수행하고, 새 active 판정과 구조 증명,
최종 authorize를 모두 통과해야만 송신한다.


## 최종 소스와 실기기용 빌드

아래 값은 최종 전체 시험과 Debug 기기용 빌드 종료 후, 커밋 전에 계산했다.
이 문서를 포함한 커밋의 기준 commit 대비 diff와 바이너리 SHA를 함께 사용한다.

- 제품 diff SHA-256: `c2d62e6936380a0dc14e9283b9194e435e69025b697a37f08917531e219c5e9b`
- 제품 + 테스트 diff SHA-256: `e955f146482d53632f074736326948973981f0ea66ab86bbaa037e0f55321a28`
- Debug 빌드: **BUILD SUCCEEDED**, bundle `com.chocos.writerpad.debug`, version `0.1.0`, build `1`.
- 실행 바이너리 SHA-256: `426fc13fa198fd1a5e71c3ae2969b8953aea6ad80f4341dd1c34936243ff0e88`
- 기기용 앱: `build/DeviceDerivedData/Build/Products/Debug-iphoneos/WriterPad.app`.
- 검증 종료 시점 실기기 설치: 미실행. 후속 설치와 일반 복구 시험은 별도 기록한다.


## 후속 Windows 회신과 남은 대조

이 구현을 커밋하는 중 Windows의 「계약 전송 공통 정책 3개 보완 결과」를
전달받았다. Windows는 새 작품 상태 조회·UUID 검사와 더불어 SQLite
`sync_operation_events`의 차단/충돌 진입·해소 이력 지문을 비교한다고 보고했다.
보고 수치는 764개 실행, 763개 통과, 실패 0, 건너뜀 1이며 Windows 소스는 아직
이 환경에서 독립 검증하지 않았다.

iPad의 이번 구현은 coordinator에 **관측된** blocked/conflict 전이를 메모리
revision으로 추적한다. SQLite 이력 지문을 직접 대조하는 구현은 아니다.
coordinator가 관측하기 전에 DB에서 차단→해소가 모두 끝나는 경우까지 같은
보장을 한다고 판정하지 않는다. 두 방식의 실제 저장소 경로 대조와 필요한
추가 보완은 남아 있다. 따라서 이 커밋·설치는 닫힌 관문의 기존 동기화/진단
확인용이며 C9 양쪽 완전 일치나 실제 계약 canary 승인을 뜻하지 않는다.
