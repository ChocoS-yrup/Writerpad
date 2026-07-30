# 11-2 dispatcher와 재시도

## 범위

`SyncV2Dispatcher`는 `SyncV2Store`의 durable document operation을 claim해
`SyncV2Client.commitDocument`로 전송한다. 한 문서에서는 sequence를 직렬로
처리하고 서로 다른 문서는 기본 3개까지 병렬 처리한다.

`ensure_project`는 문서 lane이 아니므로 이 dispatcher의 claim 대상이 아니다.
프로젝트 생성·연결은 9-4의 `SupabaseProjectBindingService`가 담당한다.

## 원자적 claim과 문서별 FIFO

- `pending` 또는 due가 지난 `retry_wait`만 claim한다.
- 같은 document_id의 앞선 nonterminal operation이 있으면 뒤 sequence는
  claim하지 않는다.
- claim, attempts 증가, `inflight`, batch `processing` 전이는 하나의 SQLite
  transaction이다.
- 성공하면 document의 revision·path·base content·hash를 갱신하고 바로 다음
  sequence에 새 base revision을 승계한다.
- 서버 성공 뒤 로컬 완료 반영 전에 중단되면 시작 복구가 `inflight`를
  `pending`으로 되돌려 같은 operation_id를 재전송한다.

## 오류와 재시도

네트워크 불가, timeout, 인증 필요, 잘못된 성공 응답, 분류되지 않은 서버 오류는
`retry_wait`로 보존한다. delay는 attempts 기반 지수 backoff이며 기본 2초에서
시작해 5분으로 제한하고 ±20% jitter를 적용한다.

revision/path/lease/document 존재 상태/operation ID 충돌은 해당 문서만
`conflict`로 만든다. forbidden과 invalid argument는 `blocked`로 만든다.
한 문서의 conflict·blocked는 다른 document_id의 claim을 막지 않는다.

다음 사건은 `retry_wait`의 시각을 즉시 해제하고 새 전송 기회를 만든다.

- 검증된 로그인 성공
- 앱 foreground 복귀
- 사용자의 명시적 재시도
- `NWPathMonitor`의 비연결 상태에서 satisfied로의 실제 전이

`NWPathMonitor`의 satisfied는 서버 성공으로 기록하지 않는다. dispatcher는
항상 실제 RPC 결과로만 completed 상태를 만든다. 최초 path snapshot이 이미
satisfied인 경우도 복구 사건으로 간주하지 않는다.

## 앱 연결

live `AppEnvironment`는 설정된 Supabase client와 같은 lazy `SyncV2Store`를
dispatcher에 주입한다. 세션 복원 성공과 scenePhase active 전이가 즉시 재시도
진입점을 호출한다. `userRequestedRetry()`는 11-7 상태 UI가 붙일 명시적
사용자 동작 경계다.

## 자동 검증

- 같은 문서 FIFO와 다음 revision 승계
- due 전 retry 차단과 즉시 기회 해제
- 제한 동시성 상한
- 한 문서 conflict와 다른 문서 진행의 격리
- attempts 기반 지수 backoff, cap, jitter
- 로그인·foreground·사용자·network recovery 진입점
- 기존 `SyncV2StoreTests`와 `SyncV2ClientTests` 회귀

## 11-3 정지 경계

이 단계에서는 edit lease 획득·heartbeat·release를 구현하지 않는다. dispatcher는
현재 nil lease로 commit하고 lease 오류를 해당 document lane의 conflict로
보존한다. lease token을 디스크나 로그에 기록하지 않는다.
