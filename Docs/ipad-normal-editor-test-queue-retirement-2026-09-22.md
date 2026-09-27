# NormalEditor 진단 큐 검사와 이전 테스트 대기 취소

## 확인된 원인

구조 비교 기준 갱신 후 실기기 송신은 `freezeStarted` 다음에
`NORMAL_QUEUE_FAILED`로 멈췄다. 현재 A source/run/본문과 비교 기준은 그대로이며,
요청 생성·전송 시도·beforeHTTP checkpoint는 아직 없다.

`generalRecoveryPage`는 실제 대기뿐 아니라 완료된 확장 계획 원본도 반환한다.
이 페이지 전체를 활성 큐로 취급한 검사는 완료 이력 3건 때문에도 차단됐다.
별도로 과거 메모장 시험 문서의 미송신 대기 2건이 있어, 완료 이력만 제외해도
현재 A 배치를 송신할 수 없는 상황이었다.

## 변경

- NormalEditor 전용 활성 배치 조회는 local/request 양쪽에서 미완료 ID를 합친다.
  완료 이력의 양이나 복구 페이지 커서와 무관하다. 활성 ID가 현재 source가 아니거나
  여러 개면 거절한다. 기존 legacy/blocked/conflict/retry 및 총 대기 수 검사도 유지한다.
- 명시적 진단 버튼 `이전 테스트 송신 대기 2건 취소`와 확인 대화상자를 추가했다.
  자동 실행·자동 송신·일반 큐 초기화는 없다.
- 취소 범위는 조사된 2개의 batch UUID와 각각의 **저장된 source_json 전체 SHA-256**이다.
  고정 작품/서버 작품이 같고, 두 행 모두 waiting·요청 미생성·오류 없음·의존/대체 관계
  없음이어야 한다. 다른 활성 작업, legacy 작업, materialized/불확실 요청은 거절한다.
- A(beforeHTTP) run만 허용하며, 단일 현재 저장 대기가 queued 또는 freezing이고
  request/hash/response/attempt/checkpoint가 없어야 한다. 로그인·전경·준비·깨끗한 편집기와
  실제 TXT/기준 본문/초안/복구 preflight를 확인한다.
- 두 행은 한 SQLite 트랜잭션에서 취소한다. source_json을 지우거나 바꾸지 않는다.
  완료 상태는 큐에서 제외하기 위한 저장 형식이며, `NORMAL_TEST_UNSENT_RETIRED` 및
  source SHA/시각을 담은 local_resolution_json으로 **송신 성공이 아닌 취소**임을 남긴다.
  복구 UI에도 미송신 테스트 취소 기록으로 표시한다.
- 중간 검증/권한 실패 시 두 행 모두 rollback. 성공 후 UI 표시 전에 종료돼도
  동일 source와 취소 표식 확인 후 재실행할 수 있다. 별도 저널 성공 표식에 의존하지 않는다.
- 현재 A source/run/phase, SQLite 구조/본문 기준, 실제 TXT 및 서버는 수정하지 않는다.
  성공 후 준비 상태를 해제하며 다음 송신은 별도 사용자 동작이다.

## 범위와 검증

서버 API·스키마·계약·Windows·공유 본문 입력에는 변경이 없다. iPad 로컬 진단 및
취소 기록 표시만 변경하므로 별도 Windows 회신을 기다리지 않는다.

실제 SQLite + 가짜 HTTP 검증에는 완료 이력 50건 초과, 다른 대기 차단, 전체 source
보존, 재호출, freezing 재개, 같은 batch의 beforeHTTP/POST 0회, 변조 시 전체 rollback,
요청 생성/다른 작업/의존/소비한 checkpoint/권한 해제 거절을 포함한다. 세션 테스트는
전경·준비·미저장 상태와 성공 후 재준비/자동 송신 없음도 확인한다.

실기기에서는 설치 후 로그인 → 송수신 준비 → 취소 버튼 및 확인 → 결과 문구를 먼저
확인한다. 아직 본문 수정이나 송신은 하지 않는다. 취소 결과의 DB 기록 검증 후
재준비 → 저장된 변경 송신 1회로 A checkpoint 시험을 이어간다.

검증 결과: 148/148 통과(입력창 6, 비교 기준 9, NormalEditor 63, GeneralSync 70).
테스트 빌드와 실기기 빌드 warning/error 0건. 실기기 취소 동작은 아직 미확인이다.

## 편집 후 원복한 동일 본문 후속 대기 정리

실기기 재설치 뒤 편집→원복 저장으로, 기존 run의 `freezing` 항목과 동일한 본문의
새 `queued` 항목이 생겼다. 준비 preflight의 단일 대기 검사에서 막히므로, 네트워크
준비를 요구하지 않는 명시적 **동일 본문 중복 대기 정리 · 기록 유지** 버튼을 추가한다.

- active A(beforeHTTP) run에 묶인 원본 head가 freezing이고, 뒤의 활성 항목이 전부
  queued이며 바이트 단위로 같은 본문일 때만 허용한다. 최대 16개, 고정 대상/경로,
  유효한 본문 해시, 서로 다른 batch/operation ID를 검사한다. run 기준 본문/revision,
  실제 TXT, 초안도 검증한다. dirty/composition/draft 오류·충돌·수신·checkpoint는 거절한다.
- 원본 및 후속 항목 모두 journal request/hash/response/attempt가 없어야 한다.
  추가로 SQLite의 local/request/operation/legacy 행과 의존 관계를 읽어, 해당 batch나
  operation이 기록된 적 있으면 completed 이력이라도 정리를 거절한다.
- SQLite `BEGIN IMMEDIATE`로 다른 큐 writer를 잠깐 막은 채 위의 읽기 검사를 하고,
  journal 잠금 안에서 같은 run/source/기준/초안을 재검증한 뒤 한 새 기록을 추가한다.
  SQLite에는 UPDATE/DELETE/INSERT/COMMIT을 수행하지 않고 잠금은 ROLLBACK으로 푼다.
- 새 기록의 event는 `identicalUnsentFollowersSuperseded`. 후속 phase만 superseded로
  바꾸고 기존 source, 원본 freezing phase, run, 본문, 초안, 비교 기준, 이전 기록을 유지한다.
  성공/재실행 후 단일 대기 조건이 돌아오며, 네트워크 준비와 기존 테스트 2건 취소는
  별도 동작이다. 전체 파일시스템과 DB를 묶은 원자 스냅샷이라고 주장하지 않는다.
- 서버 요청·로그인·큐 우선순위 변경·기존 guard 완화는 없다. 일반 앱/Windows 입력이나
  wire 계약에도 변경이 없다. 단지 원복됐다는 이유만으로 다른 본문이나 불확실 요청을
  자동으로 정리하지 않는다.

실기기 다음 동작은 먼저 이 새 버튼을 눌러 결과를 확인하는 것이다. 아직 로그인,
이전 테스트 2건 취소, 송신, 본문 편집은 요청하지 않는다.

추가 검증 결과: 155/155 통과(입력창 6, 비교 기준 9, NormalEditor 70,
GeneralSync 70). 테스트·실기기 빌드 warning/error 0건. 중복 정리 → 예전 대기
취소 → 원래 batch의 beforeHTTP 중단/POST 0회를 통합 시험했다. 실제 기기의
중복 정리 버튼 동작은 설치 후 별도 확인이 필요하다.

실기기 중복 정리 확인: 사용자 성공 문구 및 sequence 99의
`identicalUnsentFollowersSuperseded` 기록 확인. 직전 98과 비교해 후속 1건의
phase만 queued→superseded로 바뀌었고, 저장 항목 수·모든 source와 나머지 state는
동일하다. 기존 A 배치 1건만 freezing으로 남고 request/response 없음·attempts 0·
checkpoint 없음이다. 이전 메모장 테스트 대기 2건 취소 및 A 송신 검증은 아직 남아 있다.

실기기 이전 테스트 2건 취소도 확인했다. 두 SQLite 행은
`NORMAL_TEST_UNSENT_RETIRED` 및 source SHA를 남기고 큐에서 제외됐으며,
원본 source_json은 취소 전과 동일하고 요청 행은 각각 0개다. 해당 작품의 활성
local/request/legacy 큐는 모두 0개다. 진단 DB 표본 간 documents/folders/tree_orders는
동일하며 quick_check=ok다(실행 중 파일의 읽기 표본이며 원자적 전체 백업은 아님).
sequence 101에서도 기존 A saves/run/baseline/reference가 99와 같고 checkpoint는 없다.
다음 검증은 재준비 후 기존 A 저장 변경 송신 1회의 beforeHTTP 중단이다.

실기기 A 중단 확인: sequence 115가 `recoveryCheckpoint:beforeHTTP`, 116이
`actionStopped/NORMAL_RECOVERY_CHECKPOINT`다. 원래 run/batch/source 및 기준/비교 기준이
유지됐고, 단일 pending은 frozen·request 있음·response 없음·journal attempts 0이다.
SQLite request JSON은 journal request와 같으며 기준 revision 9, 본문 29바이트와
원래 SHA를 유지한다. SQLite의 processing/attempts 1은 queue claim 시 증가한 값으로,
HTTP 시작 횟수와 다르다. 코드상 checkpoint는 willStart/network 호출 전에 기록된다.
앱 종료→홈 화면 재실행→같은 요청으로 재개 검증은 아직 남아 있다.
