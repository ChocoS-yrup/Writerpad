# C 복구 시험 준비 — 2026-09-27

## 범위와 시작 상태

A(beforeHTTP) 및 B(afterCommitResponse)는 완료됐다. C는 서버 응답을 journal에 영속 저장한 뒤, 로컬 SQLite 완료 처리 직전의 `afterStoredResponse` 진단 중단을 검증한다. 실제 네트워크 장애나 임의 OS 강제 종료 지점의 검증과는 구분한다.

실행 전 읽기 전용 확인:

- 기기 최신 journal 164(`sendCompleted`)는 B 완료 확인 시점의 기록과 바이트 단위로 동일하다.
- B run completed=true, 활성 save 0, conflicts 0, 진행 중 receive 없음.
- journal 기준선 revision 11과 draft 본문이 정확히 일치한다. draft의 실제 UTF-8 SHA-256은 `b69b7fe151d593651f1967979fbe72d84fd3a9dabb26cace6d8c81d63743d99f`다.
- Staging 대상 문서도 revision 11 / 29바이트 / 동일 hash다.
- 전체 백업, 기기 기록 직접 수정, 서버 변경은 하지 않았다. 좁은 진단 사본만 사용했다.

## 실행 설정

기존 `com.chocos.writerpad.debug` 앱을 아래 6개 환경변수로 `--terminate-existing` 재실행하는 명령이 성공했다. 재설치/코드 수정/자동 송신은 없다. C run은 아직 journal 등록 전이며, 사용자 준비 동작이 검증을 통과하면 영속 등록된다.

- `WRITERPAD_RECOVERY_PLAN`: `normal-editor-recovery-20260913-v1`
- `WRITERPAD_RECOVERY_POINT`: `afterStoredResponse`
- `WRITERPAD_RECOVERY_CONTENT_SHA256`: `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`
- `WRITERPAD_RECOVERY_RUN_ID`: `db1242c0-58c0-4b84-aa9c-a0b9d60ddeb2`
- `WRITERPAD_RECOVERY_BASE_REVISION`: `11`
- `WRITERPAD_RECOVERY_BASE_SHA256`: `b69b7fe151d593651f1967979fbe72d84fd3a9dabb26cace6d8c81d63743d99f`

시험 본문은 `WriterPad recovery C 20260927` 한 줄, 끝 줄바꿈 없는 **29바이트**다.

진단 사본: `/private/tmp/writerpad-c-recovery-0oc91p/` (공개 배포 대상 아님).

## 진행 순서와 기대값

1. 사용자가 본문 전체를 시험 한 줄로 바꾸고 저장한다. 아직 송신하거나 앱을 종료하지 않는다. 준비 전 종료 시 환경변수 설정을 다시 적용해야 한다.
2. source/draft hash 일치, 기준선 11, queued save 정확히 1건, request nil, HTTP attempts 0을 확인한다.
3. 사용자 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 저장된 변경 송신 1회.
4. `NORMAL_RECOVERY_CHECKPOINT`에서 기록 확인. 기대값: C run 활성, afterStoredResponse checkpoint 존재, journal phase=responseStored, 검증된 response 존재, journal HTTP attempts 1, 로컬 기준선 11, 서버 문서/결과 revision 12 및 C hash. SQLite response 저장 완료까지 가정하지 않는다. 이 중단은 journal 응답 저장 후 backend.complete 호출 전이다.
5. 사용자 앱 전환기 종료 → 홈 아이콘 재실행. 저장된 response/request/run/checkpoint가 그대로 유지되는지 확인한다.
6. 로그인·준비 후 **미완료 송신 결과 확인** 1회. 저장된 response를 사용하여 로컬 완료한다. 이 경로는 코드상 receipt 재조회 분기를 건너뛰지만, 로그인·준비의 네트워크 요청은 별개이므로 오프라인 시험이라고 표현하지 않는다.
7. 최종 기기/서버 revision 12 / C hash, 활성 save 0, C run completed 및 원래 request/response/HTTP attempts 유지 여부를 확인한다. 새 송신 버튼은 사용하지 않는다.

현재는 설정 재실행까지만 완료했다. C 본문 저장·송신·중단·복구는 아직 확인 전이다. 계약·Windows 동작·교차 플랫폼 입력·서버 스키마 변경은 없다.

## 사용자 저장 후 확인 — 2026-09-27 13:42 KST 기록

사용자의 저장 완료 보고 후 journal 166(`localSaveQueued`)과 최신 draft를 읽기 전용으로 확인했다.

- 활성 save는 정확히 1건, queued이며 request/response 없음, HTTP attempts 0이다.
- 새 batch: `802d46b4-1a7c-49aa-9be3-11c4487a38da`.
- 새 operation: `2fb9ebe8-5cc7-4d1f-b4d1-8fed78f47dd0`.
- source 본문과 draft가 정확히 일치한다. 실제 UTF-8 내용에서 각각 계산한 SHA-256은 C 설정의 `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`와 일치하며, 29바이트이고 끝 줄바꿈이 없다.
- journal 기준선은 revision 11, conflicts 없음. A/B run 완료는 유지되고 C run은 준비 전이라 아직 등록되지 않았다.

다음 사용자 동작: 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 저장된 변경 송신 1회. `NORMAL_RECOVERY_CHECKPOINT`가 예상되며, 그 밖의 오류가 나오면 해당 단계에서 중단한다. 앱 prepare는 실제 로컬 파일·기준선·dirty 상태와 C 설정을 다시 검증한다. 중단 후에는 재송신·재실행 전에 journal의 저장된 response와 서버 결과를 대조한다.

이번 확인에서 서버 변경이나 추가 송신은 하지 않았다. 저장 확인 증거는 같은 진단 디렉터리의 `saved.record`, `saved-draft.json`이다.

## C 중단 지점 확인 — 2026-09-27 13:52 KST 기록

사용자가 예상 문구를 확인했다. journal 185, 로컬 SQLite/열린 WAL의 진단 사본 및 Staging 읽기 전용 SELECT를 대조했다.

- journal 185 이벤트 `actionStopped`, lastFailure=`NORMAL_RECOVERY_CHECKPOINT`, lastHTTPStatus=200.
- C run `db1242c0-58c0-4b84-aa9c-a0b9d60ddeb2`는 위 batch에 연결되어 completed=false. `afterStoredResponse` checkpoint가 영속 기록돼 있다.
- 활성 save 1건, phase=responseStored, 검증된 committed/applied=true 응답 존재, journal HTTP attempts 1. journal 기준선은 revision 11이다.
- 저장 요청의 canonical JSON SHA-256을 재계산한 값은 `a3b3d73150f6c9c7005bf4ef173cbf26f0c598dd6bb78892aa266f71f1c4ff26`이며 journal 및 서버 request hash와 일치한다.
- 저장 응답의 canonical JSON SHA-256은 `e26dcd6f24adca8d7da7d8b317b6cc09f3f90f626f737098c7fe46653b7f2f95`로 서버 response hash와 일치한다.
- 서버 현재 문서 및 같은 batch/operation 결과는 revision 12 / 29바이트 / C 본문 hash다.
- batch payload SHA-256은 `6ae4671f506177847f755c9b40c57a53eb8389922da0068f288d0cda2022aeb7`이며 journal 응답·SQLite·서버가 일치한다.
- SQLite quick_check=ok. source materialized / request processing / claim attempts 1 / response nil / operation inflight / base_revision 11 / result_revision nil. SQLite 기준선 revision 11과 B hash가 유지된다. 응답은 journal에 저장됐고 SQLite 완료 전에서 멈춘 것이므로 이 차이는 기대 상태다.

판정: **C의 서버 반영 → journal 응답 저장 → 로컬 완료 전 진단 중단 확인**. 아직 재실행 후 복구는 완료하지 않았다. 추가 송신이나 기기/서버 기록 직접 수정은 하지 않았다. SQLite 사본은 원자적 전체 백업이 아니다.

다음은 사용자가 `ChocoS 복구 진단`만 앱 전환기에서 종료하고 홈 아이콘으로 다시 실행하는 단계다. 재실행 후 기록 보존 확인 전에는 본문 편집·송수신 버튼을 누르지 않는다. 이후에는 저장된 응답으로 `미완료 송신 결과 확인`을 실행하며 새 송신하지 않는다.

중단 진단 증거: `/private/tmp/writerpad-c-recovery-0oc91p/checkpoint.record`, `checkpoint.sqlite3`, `checkpoint.sqlite3-wal` (공개 배포 대상 아님).

## 홈 아이콘 재실행 후 기록 보존 확인

사용자가 앱 전환기 종료와 홈 아이콘 재실행 완료를 보고했다. 이번에는 별도 launch 명령이나 환경변수 주입 없이 기기 기록만 읽었다.

- 최신 journal은 185번 그대로다. `reopened.record`와 중단 직후 `checkpoint.record`를 바이트 단위로 비교하여 완전히 동일함을 확인했다.
- `reopened-draft.json`도 C 저장 직후 draft와 바이트 단위로 동일하다.
- C run/batch/request/저장된 response/checkpoint가 유지된다. 활성 save 1건, responseStored, HTTP attempts 1, 기준선 11, run completed=false다.
- 재실행 후 추가 journal 이벤트나 송신 attempt는 관찰되지 않았다. 이는 journal 증거이며 전 네트워크 패킷 계측 결과는 아니다.

다음 사용자 동작은 로그인 → 송수신 준비·권한 갱신 → 준비 성공 시 **미완료 송신 결과 확인** 1회다. 저장된 response를 사용하므로 코드상 receipt 조회 분기를 건너뛰고 로컬 완료를 재개한다. 로그인·준비는 여전히 네트워크와 권한 검증이 필요하므로 오프라인 시험으로 표현하지 않는다. 새 송신이나 본문 편집·저장은 하지 않는다.

예상 완료 표시는 revision 12 / 29바이트 / SHA-256 `8ce49878e51c…`다. 실제 C 완료는 사용자 동작 후 기기·서버 대조로 확정한다.

## C 완료 확인 — 2026-09-27 13:56 KST 기록

사용자가 예상된 완료 표시를 보고했다. 추가 송신 없이 journal 188(`sendCompleted`), 로컬 SQLite 진단 사본 및 서버 SELECT를 대조했다.

- C run completed=true, save completed, journal 활성 save 0.
- 중단 시점과 source/request/request hash/저장된 response/HTTP attempt 배열/checkpoint 배열을 비교하여 모두 동일함을 확인했다. 기존 journal HTTP attempt 1회가 그대로 유지됐다.
- 로컬 journal 및 SQLite 기준선: revision 12, UTF-8 29바이트, C 본문 SHA-256 `8ce49878e51c363f883b787b41824d60bf8a720b59398003e0fc1b8943d9ca1f`.
- SQLite source/request/operation 모두 completed, operation result_revision=12, request response 존재, claim attempts=1 유지, 활성 source/request 각각 0. quick_check=ok.
- 서버 현재 문서도 revision 12 / 29바이트 / 같은 본문 hash다. 기존 batch/operation의 committed/applied=true 결과와 request/payload hash가 일치한다.
- 로컬 응답 canonical JSON SHA-256 `e26dcd6f24adca8d7da7d8b317b6cc09f3f90f626f737098c7fe46653b7f2f95`는 중단 전 저장 응답 및 서버 response hash와 동일하다.

판정: **C(afterStoredResponse 진단 중단 → 사용자 앱 종료/홈 재실행 → 저장된 응답으로 로컬 완료) 통과**. journal상 추가 commit 시도 없이 기존 응답으로 복구됐다. 저장된 응답이 있으면 receipt 조회를 생략하는 코드 경로 및 동일 응답 보존을 확인한 것이며, 모든 네트워크 요청을 계측하거나 오프라인 복구를 검증한 것은 아니다.

완료 진단 증거: `/private/tmp/writerpad-c-recovery-0oc91p/completed.record`, `completed.sqlite3`, `completed.sqlite3-wal` (열린 DB의 좁은 진단 사본이며 전체 백업 아님).

A/B/C는 완료됐다. 다음은 별도 새 run의 D(`afterOriginalApply`, 수신 본문 파일 반영 후 기준선 완료 전 중단) 시험이다. 기준 revision 12 및 C 본문 hash에서 시작하되, 수신할 새 서버 본문을 만드는 절차와 범위를 먼저 확인해야 한다. 이번 확인에서 D 설정·새 서버 변경·새 송신은 시작하지 않았다. 실제 OS 중단·최종 PR 검토는 별도 잔여 범위다.
