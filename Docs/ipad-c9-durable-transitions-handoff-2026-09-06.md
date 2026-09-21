# iPad C9 미관측 차단·해소 전이 보완 회신

2026-09-06 KST. 기준은 `ab893843562e06e14f400d99e18870f1a97c3703`이며 이번 변경은
그 위의 작업 트리다. 실제 계약 관문·서버 설정·정규 계약·digest는 변경하지
않았고 실제 서버 쓰기를 실행하지 않았다. 기존 실기기 Debug 설치본은 ab89384다.

## 재현과 수정

지적한 누락을 격리 SQLite와 모의 전송에서 재현했다. 기존 코드에서 실제
recorder로 만든 계약 배치를 준비하고 상태 응답을 기다리는 동안 실제 dispatcher가
문서/폴더 작업을 blocked 또는 conflict로 전이시켰다. 다음 작업의 모의 응답을
만들 때 별도의 실제 SyncV2Store 연결로 첫 작업을 취소·해소했다. coordinator에는
drain 종료 후 차단 건수 0인 snapshot만 전달됐다. 기존 준비의 계약 쓰기가
시작되어 쓰기 0회 요구 시험이 실패했다. 최초 xcresult의 구체적인 실패 표시는
`folder=false, conflict=false`(문서 blocked→해소)다. 이를 모든 하위 조건의
수정 전 실패 개수로 확대하지 않는다. 실서버 오전송 재현은 아니다.

`SyncV2ContractQueueHistory`가 기존 `sync_operation_events`에서 다음 사건의
식별자를 정렬해 작품별 SHA-256 지문을 만든다.

- blocked/conflict_detected 사건
- 바로 전 사건이 blocked/conflict_detected인 사건: 취소, superseded, pending 등
  차단·충돌을 벗어나는 실제 저장소 사건

문서와 폴더 등 `sync_operations`의 모든 종류를 포함한다. 기존 전이 기록과 상태
갱신은 같은 SQLite 트랜잭션에서 수행된다. 지문은 메모리 snapshot 전달 여부와
무관하고 다른 저장소 연결에서 완료된 변경도 감지한다. 조회의 같은 snapshot에서
`sync_operations` 및 `sync_contract_batches`의 현재 blocked/conflict도 검사한다.
현재 계약 전용 배치 표에 임의 차단 해소 API를 새로 추가하지 않는다.

sender는 새 작품 상태 조회 **전에** 이력을 잡고, 응답 수신 직후와 기존 authorize
호출 지점들에서 재검사한다. 실제 HTTP 준비 후 쓰기를 시작하기 직전의 authorize도
포함한다. 읽기 실패 또는 현재 차단은 승인하지 않는다. 매번 짧은 별도 읽기 전용
연결을 열고 닫으므로 네트워크 대기 동안 SQLite 연결/읽기 트랜잭션을 붙잡지 않는다.
기존 관문·인증·작품 수명·구조 기준 검사는 유지한다.

이력 지문을 계약 payload나 digest에 넣지 않는다. DB 스키마와 사건 생성 경로도
변경하지 않는다. 정상 enqueue/dispatch/retry 사건은 차단 직후 사건이 아닌 한
지문에 포함하지 않아 정상 원고 저장이 옛 준비를 무효화하지 않는다.

## 실제 경로 회귀 시험

모든 계약 쓰기는 모의 transport이며 관문은 시험 전용 UserDefaults에서만 연다.
실제 앱 관문을 조작하지 않는다. 새 시험은 제품 authority.observeQueue 또는
coordinator.restore를 직접 호출해 차단·해소를 대신 전달하지 않는다. 시험 초기의
구조 기준만 기존 helper로 승인하고 실제 pull producer는 기존 전체 회귀로 검사한다.

| 시험 | 확인 범위 |
|---|---|
| `testC9UnobservedDurableTransitionsDuringStatusReadPreventWrite` | 실제 recorder·SQLite·dispatcher·coordinator·sender 연결. 문서/폴더 × blocked/conflict 4조건. 별도 DB 연결로 실제 취소 해소. 최종 snapshot만 관측해도 쓰기 0회, 요청 전체 동일, 새 준비에서 같은 배치 성공 |
| `testC9DurableTransitionsAtFinalTransportPreserveAndResumeBatch` | 실제 문서 recorder와 claim/markBlocked/markConflict/cancelOperation. 모의 transport 최종 준비 중 2조건. 쓰기 0회, 저장 요청 유지, 새 준비 성공 |
| `testC9ActualNormalRecorderEnqueueDoesNotInvalidatePreparedSend` | 실제 원고 recorder의 일반 enqueue가 상태 조회/최종 transport 경계에서 발생해도 원래 배치를 1회 전송 |
| `testC9QueueHistoryFailsClosedAndDetectsCrossConnectionResolution` | DB 없음 및 현재 blocked 승인 거절. 다른 DB 연결의 해소 뒤 옛 승인 거절, 새 승인 허용 |
| `testC9ActualConflictPreservationAndResolutionInvalidateOldPreparation` | 실제 preserveConflict → 해소 원고 enqueue → resolveConflict(manualMerge). 중간 snapshot 전달 없이 옛 준비 쓰기 0회, 배치 유지, 새 준비 재개 |

상태 조회 중 dispatcher를 돌리는 시험과 달리 최종 transport 경계 시험은 이미
claim된 실제 작업을 저장소 API로 전이시킨다. upload permit을 가진 동안 두 번째
dispatcher drain이 동시에 실행될 수 있다고 주장하지 않는다. 수동 충돌 해소 시험의
원고 enqueue는 저장소 API를 직접 사용해 중간 snapshot 없이도 감지됨을 확인한다.
SwiftUI 화면을 자동 조작한 시험은 아니다.

## 증거와 해석

최종 전체 시험은 **962개 / 통과 961 / 실패 0 / 건너뜀 1**다.
2026-09-06 11:10:03–11:12:36 KST 시뮬레이터 실행이다.
최종 수치·시각·diff 해시·xcresult 경로는
`Docs/evidence/ipad-c9-durable-transitions-2026-09-06.json`에 기록한다.
최초 재현 실패와 최종 전체 실행 수치를 합산하지 않는다. 제품+테스트 패치는
`build/ipad-c9-durable-product-and-tests-2026-09-06.patch`다.

이 결과는 로컬 통합 회귀 검증이다. Windows 최신 작업 트리의 독립 실행 검증,
양쪽 설치 버전 고정, 실기기 복구 시험 및 실제 계약 쓰기 성공을 뜻하지 않는다.
쓰기 직전에 서버 상태가 바뀌는 경우의 활성 상태·revision·권한·멱등성은 별도
실서버 트랜잭션 검증이 필요하다.

`sync-contract/handshake-envelope.md`의 오래된 Windows project_id/중복 목록 허용
표를 최신 보완 회신에 맞춰 정정하고 서버 작품 복원 후 재개 순서 차이를 명시했다.
정규 protocol/lock/pin은 그대로다.

## 사용자에게 안내한 다음 절차

기존 ab89384 Debug에서 일반 복구 시험을 1회 진행하고 시각을 알려 주면
`recovery.jsonl`과 회전 파일을 기기에서 수집한다. 안내는
`Docs/ipad-closed-gate-recovery-guide-2026-09-06.md`에 있다. 이번 코드의 계약 차단
시험과 실기기 일반 복구 기록을 분리한다. 과거 30초~2분 지연의 원인은 아직
확정되지 않았다.

Windows에는 이번 제품·테스트 패치와 검증 JSON을 전달해 재대조를 요청한다.
그 뒤 양쪽 커밋/빌드를 고정한다. 실제 관문은 계속 닫아 두며 첫 계약 시험 범위도
기존 합의인 iPad Debug 수동 새 폴더 1개 + 부모 tree_order 1개 배치를 유지한다.
