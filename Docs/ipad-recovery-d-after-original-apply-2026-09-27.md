# D 수신 복구 시험 기록 — 2026-09-27

최종 상태: **통과**, journal 207 / revision 13 / 활성 송신 대기 0.
아래 준비·중단·재실행 절차는 순차 실행 기록이며 재실행 지시가 아니다.
완료 증거는 하단 `D 완료 확인`, 후속 검사와 잔여 범위는
[최종 회귀 점검](ipad-recovery-final-regression-2026-09-27.md)을 참조한다.

## 범위와 승인

A/B/C 완료 후 D(`afterOriginalApply`)를 준비한다. 사용자는 시험 문서 1개를 `WriterPad recovery D 20260927`로 바꾸고 서버 revision 12→13으로 올리는 **관리용 시험 변경**을 명시적으로 승인했다. 이는 iPad/Windows 송신·인증 성공 또는 교차 플랫폼 검토 결과가 아니다.

- Staging: `mhpnszcorfzrvhyondxr`
- Server project: `d8f50b5f-ae0e-42f8-9296-5d5885a5b304`
- Document: `db8a3cc2-8b1a-5539-841c-042de34f5fd6`
- Path: `메인/원고/일반본문검증 20260912.txt`
- Parent: `f4c92790-d675-4970-b1fc-b90f3a929ffb`, structure revision 1 유지.

기기 journal 188은 C 완료 시점과 바이트 단위로 동일했다. 기준선 revision 12와 draft가 정확히 일치하며 활성 save/충돌/진행 중 receive가 없고 C run은 completed=true다. 본문 hash는 `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`다. 서버 변경 전 대상 문서도 같은 revision/29바이트/hash였다.

## 관리용 서버 본문 생성 완료

배포된 `document_commit` 및 `document_commit_legacy` 정의를 읽어 기존 문서·버전·처리 결과 기록 경로를 확인했다. 새 RPC나 스키마를 설치하지 않았다.

- 새 batch: `4968ebd5-949a-4d9a-9549-9cf206517523`
- 새 operation: `c8190529-1584-4f15-bcf6-b91bd5dd0038`
- 별도 관리용 writer: `bc490ff8-cb9d-4761-a9cc-4bb51520e611`
- client build: `staging-admin-recovery-d-fixture-20260927`
- 기존 계약 0.2.0 / protocol 3 / ID_BASED / epoch 1 유지.
- 관리 SQL은 transaction-local owner context로 기존 RPC를 호출했다. 실제 JWT 인증 시험이 아니며, 권한/RLS/allowlist/앱 key 변경은 없다. 실제 owner 식별자는 공개 문서에 기록하지 않는다.

Postgres 잠금 지침에 따라 RPC와 같은 project→document advisory lock 순서, lock_timeout 5초, statement_timeout 20초의 짧은 트랜잭션을 사용했다. 기준 revision/hash/문서 구조/계약이 달라졌거나 새 ID가 이미 사용됐으면 실패한다. 다른 문서·폴더·정렬 및 기존 버전을 전후 비교하며, 정확히 한 새 버전 외 변경이 있으면 예외로 전체 롤백한다.

같은 명세로 먼저 RPC 및 사후 검증을 실행한 뒤 ROLLBACK했다. 별도 SELECT에서 revision 12, 새 batch 0건을 확인한 후 동일 ID로 COMMIT을 한 번 실행했다. 이는 본문 백업이나 복원이 아니라 적용 전 롤백 검증이다.

최종 서버 SELECT 결과:

- 본문: `WriterPad recovery D 20260927` (줄바꿈 없는 29바이트)
- revision **13**, committed/applied=true.
- 본문 SHA-256: `c98094cf24ad972fea982bb3d5e615671b73827da330740d6049db760aaf2926`
- request SHA-256: `69ead7a8f81fe61f4e2e30203b8bc22823883350c3fa6c045b1224dfb4e8aaad`
- payload SHA-256: `72666443f0401d6429f57cbba38802511fd9cd78878de521968afcea0cf9fa08`
- response SHA-256: `ac526f65e6bf1b9a34c1980cd315c3fa1c19f9677628993f1568130f406a009b`
- 문서 버전/operation/batch 결과는 기존 RPC가 생성했다. 원고나 history를 직접 UPDATE/DELETE하지 않았다. 다른 문서·폴더·정렬과 기존 버전은 트랜잭션 내부 검증을 통과해 유지됐다.

SQL 및 좁은 진단 증거: `/private/tmp/writerpad-d-recovery-lStnDm/`. `admin-fixture.sql`은 이미 실행된 기록이다. 재실행 시 새 batch를 발급하거나 baseline guard를 변경하지 말고 기존 receipt부터 확인한다.

## iPad 실행 설정 적용

기존 `com.chocos.writerpad.debug`를 아래 환경변수로 재실행하는 명령이 성공했다. 재설치·자동 수신·송신은 없다. 재실행 후 journal은 188번 그대로다.

- Plan: `normal-editor-recovery-20260913-v1`
- Point: `afterOriginalApply`
- Run: `952a1973-d39f-4c42-97b0-14ecc5593628`
- Base revision: `12`
- Base SHA-256: `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`
- Incoming SHA-256: `c98094cf24ad972fea982bb3d5e615671b73827da330740d6049db760aaf2926`

**iPad에서 D 본문을 입력하거나 저장하지 않는다.** 사용자 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 `서버 변경 수신·반영 재개` 1회가 다음 단계다. prepare에서 local baseline/본문/dirty/조합/대기열을 재검증하며, 통과하면 D run을 영속 등록한다.

예상 중단은 `NORMAL_RECOVERY_CHECKPOINT`, journal receive.phase=`originalApplyStarted`, 저장된 remote revision 13/D hash, 실제 TXT=D 본문이다. 기준선과 draft는 아직 revision 12/C 본문일 수 있다. 중단 직후의 차이를 오류로 단정하거나 draft를 수동 변경하지 않는다.

중단 확인 후 사용자 앱 전환기 종료/홈 재실행, 같은 receive ID/remote/TXT 보존 확인, 로그인·준비 후 **수신 버튼**으로 저장된 수신 건을 마무리한다. `저장된 변경 송신 1회`나 `미완료 송신 결과 확인`은 D 복구 동작이 아니다.

최종 판정은 원본 TXT·journal/SQLite 기준선·draft가 revision 13/D 본문으로 일치하고 receive=nil, run completed=true, 활성 송신 대기 0임을 확인한 뒤 내린다. 현재는 서버 fixture와 iPad 설정 준비 완료이며 D 수신·중단·복구는 아직 미실행이다.

## D 중단 지점 확인 — 2026-09-27 14:05 KST 기록

사용자가 예상 문구를 확인했다. 기기 journal 203(`actionStopped`), draft, SQLite/열린 WAL 진단 사본, 실제 TXT 및 서버 SELECT를 대조했다.

- lastFailure=`NORMAL_RECOVERY_CHECKPOINT`. D run은 위 실행 UUID로 completed=false이며 `afterOriginalApply` checkpoint가 기록됐다.
- receive ID: `42e426e3-b852-4a79-bba7-0376e4ec4aca`, phase=`originalApplyStarted`.
- receive.baseline은 revision 12/C 본문, receive.remote는 revision 13/D 본문이다. observedOriginalHash는 D hash와 일치한다.
- 실제 파일 `Documents/일반동기화 검증 20260910/집필모드/메인/원고/일반본문검증 20260912.txt`를 읽어 확인한 결과 29바이트, SHA-256 `c98094cf24ad972fea982bb3d5e615671b73827da330740d6049db760aaf2926`로 remote 및 현재 서버와 일치한다. SQLite의 프로젝트 이름도 해당 경로와 일치한다.
- journal 기준선과 saves 배열은 D 시작 전과 동일하다. journal/SQLite 기준선은 revision 12/C hash `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`를 유지한다.
- draft는 D 시작 전 사본과 바이트 단위로 동일하며 C 본문 29바이트다. 중단 지점에서 TXT만 D이고 draft/기준선은 C인 것은 기대 상태다.
- journal 활성 save 0, SQLite 활성 source/request 각각 0. SQLite quick_check=ok. DB 사본은 원자적 전체 백업이 아니다.
- 서버는 revision 13/29바이트/D hash를 유지한다. 이번 확인에서 서버를 수정하거나 새 송신하지 않았다.

판정: **D의 수신 본문 원본 TXT 반영 후, 기준선·draft 완료 전 진단 중단 확인**. 아직 재실행 후 완료는 확인하지 않았다.

다음은 사용자가 `ChocoS 복구 진단`만 앱 전환기에서 종료하고 홈 아이콘으로 다시 실행하는 단계다. 재실행 후 같은 receive ID/remote/TXT와 이전 draft 보존을 확인하기 전에는 본문 편집·저장·송수신 버튼을 누르지 않는다. 이어서 로그인·준비 후 **서버 변경 수신·반영 재개**로 같은 수신 건을 마무리한다.

진단 증거는 `/private/tmp/writerpad-d-recovery-lStnDm/`의 `checkpoint.record`, `checkpoint-draft.json`, `checkpoint-body.txt`, `checkpoint.sqlite3`, `checkpoint.sqlite3-wal`이다.

## 홈 아이콘 재실행 후 기록·원본 보존 확인

사용자가 앱 전환기 종료와 홈 아이콘 재실행 완료를 보고했다. 별도 launch 명령이나 환경변수 주입 없이 journal/draft/TXT를 읽었다.

- 최신 journal은 203번이며 `reopened.record`와 `checkpoint.record`가 바이트 단위로 동일하다. 같은 receive ID `42e426e3-b852-4a79-bba7-0376e4ec4aca`, originalApplyStarted, remote revision 13, D run completed=false가 유지된다.
- `reopened-body.txt`는 중단 직후 TXT와 바이트 단위로 동일하며 D hash `c98094cf24ad972fea982bb3d5e615671b73827da330740d6049db760aaf2926`다. 이전 C draft로 덮어써지지 않았다.
- `reopened-draft.json`은 중단 직후 C draft와 바이트 단위로 동일하다. journal 기준선도 revision 12이며 활성 save는 0이다.
- 재실행만으로 새 journal 이벤트나 송신 대기가 생기지 않았다. 전 네트워크 패킷 계측을 뜻하지 않는다.

다음 사용자 동작: 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 **서버 변경 수신·반영 재개** 1회. 저장돼 있는 같은 수신 건으로 기준선과 draft를 마무리한다. 송신 버튼 및 미완료 송신 결과 확인 버튼은 사용하지 않고, 본문 편집·저장도 하지 않는다.

예상 완료 표시는 `수신 완료 · revision 13 · 29바이트 · SHA-256 c98094cf24ad…`다. 실제 D 통과는 이 동작 뒤 원본·기준선·draft·서버 상태를 대조한 후 확정한다.

## D 완료 확인 — 2026-09-27 14:10 KST 기록

사용자가 예상된 수신 완료 표시를 보고했다. 추가 송수신 없이 journal 206/207, 실제 TXT·draft·SQLite 진단 사본 및 서버 SELECT를 대조했다.

- 완료 직전 206번의 receive ID와 remote 전체가 중단 기록 203번과 동일하다. 같은 수신 건을 이어서 처리했다.
- 207번 이벤트는 `receiveCompleted`, 기준선 revision 13, receive=nil, D run completed=true다.
- 중단 전후 saves 배열과 checkpoint 배열이 동일하다. journal 활성 save 0, SQLite 활성 source/request 각각 0.
- 실제 TXT, draft.text, journal baseline.content를 각각 계산한 SHA-256은 모두 `c98094cf24ad972fea982bb3d5e615671b73827da330740d6049db760aaf2926`이며 본문은 29바이트다.
- SQLite 기준선 revision 13 / 29바이트 / 같은 D hash. quick_check=ok. DB/WAL은 열린 DB의 좁은 진단 사본이며 원자적 전체 백업은 아니다.
- 서버 현재 문서도 revision 13 / 29바이트 / 같은 D hash를 유지한다. 이번 확인에서 서버 쓰기나 새 송신을 하지 않았다.

판정: **D(afterOriginalApply 진단 중단 → 사용자 앱 종료/홈 재실행 → 동일 보관 수신 건 재개 → 원본·기준선·draft 완료) 통과**. 이전 초안이 D 원본을 덮어쓰지 않았고, 최종 기준선·초안도 D 본문으로 일치했다.

완료 증거는 같은 진단 디렉터리의 `resuming.record`, `completed.record`, `completed-body.txt`, `completed-draft.json`, `completed.sqlite3`, `completed.sqlite3-wal`이다.

## A–D 진단 경계 결과

| 경계 | 확인한 재개 경로 | 최종 revision | 결과 |
|---|---|---|---|
| A beforeHTTP | 기존 요청으로 첫 송신 | 10 | 통과 |
| B afterCommitResponse | 기존 서버 처리 결과 조회 | 11 | 통과 |
| C afterStoredResponse | 저장된 응답으로 로컬 완료 | 12 | 통과 |
| D afterOriginalApply | 보관된 수신 건으로 기준선·draft 완료 | 13 | 통과 |

이 표의 4/4는 제한된 진단 경계 시험의 완료율이지 전체 제품 완료율이 아니다. 실제 통신 장애, 임의 시점 OS 종료/저장 전 입력, 일반 제품 dispatcher/다중 문서 동작과 최종 회귀 검사·통합 PR 검토는 별도 잔여 범위다. D의 서버 변경 생산자는 사용자 승인 관리 작업이며 Windows/iPad 송신 성공 근거로 사용하지 않는다.

다음 단계는 이번 코드 변경과 A–D 증거를 함께 정리하고 최종 회귀 검사 및 잔여 시험 범위를 점검하는 것이다. 실제 계약/Windows/공유 입력 차이가 없는 iPad 전용 변경에 Windows 회신을 요구하지 않으며, 관련 변경은 최종 head 기준 한 PR 검토로 묶는다. 이번 단계에서는 새 빌드·커밋·PR·앱 재실행을 수행하지 않았다.
