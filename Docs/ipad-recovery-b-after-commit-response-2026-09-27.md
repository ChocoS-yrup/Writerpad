# B 복구 시험 준비 — 2026-09-27

## 현재 상태

A(beforeHTTP)는 완료됐다. B는 `afterCommitResponse`, 즉 서버 응답을 받은 뒤 로컬 응답 기록 직전의 진단 중단을 검증한다. 실제 통신 장애를 일으키는 시험은 아니다.

실행 전 읽기 전용 확인:

- 기기 journal 137: `sendCompleted`, A run completed=true, 활성 save 0.
- 기기 기준선 revision 10. draft와 기준 본문 SHA-256 일치.
- Staging 대상 문서 revision 10, UTF-8 29바이트, SHA-256 `f2c3066ea8bfce2a389f9cd8e80eea85d6a9ac6b2cfa4b2e8cd3120a26569ec0`.
- 서버 변경, 큐 초기화, 기록 직접 수정, 전체 백업은 하지 않았다. 좁은 범위의 읽기 전용 진단 사본만 사용했다.

## 새 B 설정

기존 `com.chocos.writerpad.debug` 앱을 아래 환경변수로 재실행하는 명령이 성공했다. 재설치는 하지 않았다. 이 설정만으로 본문 편집·로그인·송신은 일어나지 않는다. **B run의 durable 등록은 이후 사용자가 준비 동작을 성공시킬 때 확인해야 한다.**

- Plan: `normal-editor-recovery-20260913-v1`
- Point: `afterCommitResponse`
- Run ID: `f5bc11c1-82da-4207-bb9a-801cc9acd916`
- Base revision: `10`
- Base SHA-256: `f2c3066ea8bfce2a389f9cd8e80eea85d6a9ac6b2cfa4b2e8cd3120a26569ec0`
- 시험 본문: `WriterPad recovery B 20260927` (줄바꿈 없는 29바이트)
- 시험 본문 SHA-256: `b69b7fe151d593651f1967979fbe72d84fd3a9dabb26cace6d8c81d63743d99f`

진단 사본: `/private/tmp/writerpad-b-recovery-YpnjR6/` (배포 대상 아님).

## 이어서 확인할 순서

1. 사용자가 본문 전체를 위 한 줄로 바꾸고 저장한다. 준비 전 앱을 강제 종료하면 아직 영속화되지 않은 B 환경변수 설정이 사라지므로 재설정이 필요하다.
2. 송신 전에 draft/본문/기준선과 정확히 1개의 queued save, request nil, attempts 0을 확인한다. 입력 도중 자동저장으로 여러 대기가 생겼다면 무작정 송신하지 않는다.
3. 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 저장된 변경 송신 1회.
4. `NORMAL_RECOVERY_CHECKPOINT`에서 멈춘 뒤 기록을 확인한다. 기대값은 httpStarted, journal HTTP attempts 1, response nil, 로컬 기준선 10, 서버 revision 11 및 B 본문이다.
5. 진단 앱만 강제 종료하고 홈 아이콘으로 재실행한다. 같은 B run이 환경변수 없이 복원되는지 확인한다.
6. 로그인·준비 후 **미완료 송신 결과 확인**을 사용한다. 새 송신 버튼을 누르지 않는다. 동일 batch/operation/request의 서버 결과 조회로 완료되는지 대조한다.
7. 최종 로컬/서버 revision 11, 본문 hash 일치, 활성 대기 0, B run completed, 추가 HTTP commit 시도 없음 여부를 검증한다.

아직 B 송신·중단·재실행·복구 완료를 주장하지 않는다. C/D, 실제 OS 중단 및 최종 PR 검토도 별도 잔여 범위다. 이번 준비에는 코드/계약/Windows/서버 스키마 변경이 없다.

## 사용자 저장 후 확인 — 2026-09-27 13:13 KST 기록

사용자가 저장 완료를 알린 뒤 기기 journal 138(`localSaveQueued`)과 최신 draft를 읽기 전용으로 확인했다.

- 활성 save는 정확히 1건이며 queued, request/response 없음, HTTP attempts 0이다.
- 새 batch: `95066856-751d-4fd7-a508-05aea30852d0`.
- 새 operation: `3fdbce7b-3d02-4b01-af11-2b6114c6e8de`.
- source의 본문과 draft가 정확히 일치하며, 각각의 실제 UTF-8 내용에서 계산한 SHA-256이 B 설정과 일치한다. 29바이트, 끝 줄바꿈 없음.
- journal 기준선은 revision 10, conflicts 없음. A run 완료는 유지되고 B run은 아직 등록 전이다.
- 앱 prepare에서 실제 로컬 파일/기준선/dirty 상태와 B run 설정을 다시 검증한다. 이번 확인은 서버를 수정하거나 송신하지 않았다.

다음 사용자 동작은 로그인 → 송수신 준비·권한 갱신 → 준비 성공일 때 저장된 변경 송신 1회다. `NORMAL_RECOVERY_CHECKPOINT` 또는 다른 중단 문구가 나오면 재송신·재실행하지 않고 먼저 기록을 확인한다.

## B 중단 지점 확인 — 2026-09-27 13:22 KST 기록

사용자가 예상된 중단 문구를 확인했다. 기기 journal 156과 SQLite/열린 WAL의 좁은 진단 사본, Staging의 읽기 전용 SELECT로 대조했다. 진단 사본은 원자적 전체 백업이 아니다.

- journal 156 이벤트 `actionStopped`, lastFailure=`NORMAL_RECOVERY_CHECKPOINT`, lastHTTPStatus=200.
- 활성 B run은 위 run ID 및 batch에 연결되어 completed=false. `afterCommitResponse` checkpoint가 영속 기록돼 있다.
- 활성 save 1건, phase=httpStarted, journal HTTP attempts 1, response 없음. journal 기준선 revision 10.
- 저장된 요청에서 다시 계산한 SHA-256은 `4e4e07505dda260a011d01f547152606a4798e7cb7727d64645ea78a19431ece`이며 journal 및 서버 request hash와 일치한다.
- SQLite quick_check=ok. source materialized / request processing / claim attempts 1 / response nil / operation inflight / base_revision 10 / result_revision nil. SQLite 기준선 역시 revision 10, A 본문 hash 유지. claim attempts는 HTTP 횟수와 별개다.
- 서버에는 같은 batch/operation의 committed, applied=true 결과가 존재한다. 결과와 현재 문서 모두 revision 11, 29바이트, B 본문 SHA-256과 일치한다.
- batch payload SHA-256: `79c27b4ebfdb8633df92687a4d860ba72248240d4613ae05ad65ce84318f7dc1` (SQLite와 서버 일치).
- 서버 response SHA-256: `1acb8c8467ccda21c412d6bae44380bfc758a8b3d8e14a67cbb21c8667f9d770`.

판정: **B의 서버 처리 완료 → 로컬 응답 저장 전 진단 중단 확인**. 아직 재실행 후 결과 복구는 완료하지 않았다. 기기 또는 서버 기록을 직접 수정하거나 추가 송신하지 않았다.

다음은 사용자가 `ChocoS 복구 진단` 앱만 앱 전환기에서 강제 종료하고 홈 아이콘으로 재실행하는 단계다. 재실행 후 기록 보존을 확인하기 전에는 본문 편집·송수신 버튼을 누르지 않는다. 이후 로그인·준비 성공 시 `미완료 송신 결과 확인`으로 기존 결과를 조회하며, 새 송신을 실행하지 않는다.

중단 진단 증거: `/private/tmp/writerpad-b-recovery-YpnjR6/checkpoint.record`, `checkpoint.sqlite3`, `checkpoint.sqlite3-wal` (공개 배포 대상 아님).

## 홈 아이콘 재실행 후 기록 보존 확인

사용자가 앱 전환기 종료와 홈 아이콘 재실행 완료를 보고했다. 재실행은 사용자가 수행했으며 별도 launch 명령이나 환경변수 주입은 하지 않았다.

- 최신 journal은 여전히 156번이며, 다시 읽어 온 `reopened.record`를 중단 직후 `checkpoint.record`와 바이트 단위 비교하여 동일함을 확인했다.
- `reopened-draft.json` 역시 B 저장 직후 draft와 바이트 단위로 동일하다.
- 동일 B run/batch/request hash/checkpoint가 유지된다. 활성 save는 httpStarted, HTTP attempts 1, response nil, 기준선 10, run completed=false다.
- 재실행 후 새 journal 이벤트 또는 추가 송신 attempt는 관찰되지 않았다. 이는 journal 증거이며 전 네트워크 패킷 계측 결과는 아니다.

다음 사용자 동작: 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 **미완료 송신 결과 확인** 1회. `저장된 변경 송신 1회`나 본문 편집·저장은 하지 않는다. 예상 표시는 revision 11 / 29바이트 / SHA-256 `b69b7fe151d59…` 송신 완료이며, 실제 완료는 이후 기기/서버 대조로 확정한다.

## B 완료 확인 — 2026-09-27 13:27 KST 기록

사용자가 예상된 완료 표시를 보고했다. 추가 송신 없이 journal 164(`sendCompleted`), 로컬 SQLite 진단 사본 및 서버 SELECT를 대조했다.

- B run completed=true, save completed, journal 활성 save 0.
- 중단 시점과 source/request/request hash/HTTP attempt 배열/checkpoint 배열을 비교하여 모두 동일함을 확인했다. HTTP attempt는 기존 1회 그대로다.
- 로컬 journal 및 SQLite 기준선: revision 11, UTF-8 29바이트, B 본문 SHA-256 `b69b7fe151d593651f1967979fbe72d84fd3a9dabb26cace6d8c81d63743d99f`.
- SQLite source/request/operation 모두 completed, operation result_revision=11, request response 존재, claim attempts=1 유지, 활성 source/request 각각 0. quick_check=ok.
- 서버 현재 문서도 revision 11 / 29바이트 / 동일 본문 hash다. 기존 batch/operation의 committed/applied=true 결과와 request/payload hash가 일치한다.
- 로컬에 저장된 응답의 canonical JSON SHA-256은 `1acb8c8467ccda21c412d6bae44380bfc758a8b3d8e14a67cbb21c8667f9d770`이며 중단 직후 및 완료 후 서버 response hash와 동일하다.

판정: **B(afterCommitResponse 진단 중단 → 사용자 앱 종료/홈 재실행 → 동일 요청의 기존 결과 조회 → 로컬 완료) 통과**. journal상 추가 commit 시도 없이 동일 결과를 복구했다. 전 네트워크 패킷 계측이나 실제 통신 장애 시험을 의미하지 않는다.

완료 진단 증거: `/private/tmp/writerpad-b-recovery-YpnjR6/completed.record`, `completed.sqlite3`, `completed.sqlite3-wal` (열린 DB의 좁은 진단 사본이며 전체 백업 아님).

다음 단계는 별도 새 run의 C(`afterStoredResponse`, 응답 영속 저장 후 로컬 완료 전 중단) 시험이다. 기준 revision은 11, 기준 hash는 B 본문 hash를 사용한다. 이번 완료 확인에서는 C 설정이나 새 송신을 시작하지 않았다. A/B는 완료됐고 C/D 및 실제 OS 중단·최종 PR 검토는 남아 있다.
