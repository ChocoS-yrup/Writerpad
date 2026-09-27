# beforeHTTP 중단 후 동일 본문 중복 정리 — 2026-09-27

## 범위

사용자가 중복 대기를 정리하고 다음 A 시험 재개까지 진행하도록 승인했다.
기존 `동일 본문 중복 대기 정리 · 기록 유지` 동작을 beforeHTTP checkpoint의 frozen 요청 뒤에 생긴 동일 본문 대기에도 제한적으로 적용한다.
일반 큐 초기화·요청 재생성·자동 송신은 추가하지 않는다. Windows 동작, 교차 플랫폼 입력, 계약, 서버 스키마/권한 변경은 없다.

## 사전 실기기 상태

- journal 119번, `NORMAL_QUEUE_FAILED`.
- A run `0ef0b8a9-2bfb-4c55-a5b9-e2f6178ce794`와 beforeHTTP checkpoint 유지.
- 원본 batch `4f9c1a5e-7d2b-45aa-958c-5cfdb11a7ba8`는 frozen, journal HTTP attempts 0.
- request hash `0c2d2ab761fa3f637da7bc669ff09426bcfb044bd3f0437fc97e0104be9ddd76` 유지.
- 후속 queued batch `7caa9c66-18d6-46e2-bb10-00aef1bf0518`는 원본과 동일한 29바이트. 요청·응답·attempt 없음.
- SQLite 진단 사본 quick_check=ok. 기존 source materialized / request processing / claim attempts 1 / operation inflight / response nil.
- SQLite claim attempts는 HTTP 횟수가 아니다. 이 실행은 첫 claim 뒤 beforeHTTP에서 중단됐고 journal HTTP attempts는 0이다.
- 실제 기기 DB·저널은 직접 수정하지 않았다. 진단용 사본은 원자적 전체 백업이 아니다.

## 보호 조건

- 기존 freezing/요청 없음 경로는 유지한다.
- 새 경로는 frozen + 같은 active A run + 소비된 beforeHTTP checkpoint + journal HTTP attempts 0 + 응답 없음만 허용한다.
- 저장된 요청을 파싱하고 source·request hash·기준 revision을 검증한다. 요청 객체도 정리 계획에 포함하므로 잠금 안에서 변경을 재검사한다.
- SQLite BEGIN IMMEDIATE 아래에서 기존 source와 request JSON 전체, batch payload hash, operation의 ID/순서/종류/대상/base/payload/hash를 비교한다.
- source materialized, request processing/claim attempts 1, operation inflight만 허용한다. 완료·응답·오류·재시도·해결 기록·의존 건·다른 활성 큐/legacy 송신은 거부한다.
- 모든 follower는 동일 본문의 queued 상태이며 SQLite source/request/operation/legacy/dependency 기록이 전혀 없어야 한다.
- 실제 로컬 본문·draft·baseline과 전경/lifecycle을 재확인한 뒤 append-only journal 이벤트 하나에서 follower phase만 superseded로 바꾼다.
- SQLite는 읽기/예약만 하고 ROLLBACK으로 종료한다. source·request·operation·checkpoint·run·baseline·본문을 재작성하거나 삭제하지 않는다.
- 정리 후에도 로그인/준비/송신은 명시적 사용자 동작이다. 기존 권한 검사를 우회하지 않는다.

## 검증 및 재개

최종 회귀 검사 **165개 통과 / 실패 0 / 건너뜀 0**. CredentialField 12, StructureReference 9,
NormalEditor 74, GeneralSync 70이다. 최종 테스트·실기기 빌드 로그의 `warning:`/`error:` 0건,
xcresult `runtimeWarnings: []`. 처음 두 빌드에서 발견한 revision 비교 타입/테스트 불변 source 대입 오류를 수정한 뒤 재실행했다.

신규 회귀 검사는 checkpoint 뒤 중복 정리와 journal 재열기, source/request/run/checkpoint/이전 record 보존,
정리 후 같은 요청으로 mock commit 1회, journal의 불확실한 상태 9종, SQLite request/source/operation/응답/claim drift,
후속 SQLite 이력 및 dirty draft 거부를 검증한다. 성공 정리 시 SQLite recovery detail도 동일하다.

같은 앱 ID로 덮어 설치, 서명 검증, 환경변수 없는 실행 성공. 설치 후 119번 record를 설치 전과 cmp하여 동일 확인했다.
사용자에게 아래 순서를 한 번에 안내했고, 이후 실기기 정리와 A 완료를 확인했다(아래 결과).
실기기에서는 정리 성공 후 기존 계정 로그인 → 송수신 준비·권한 갱신 → 준비 성공일 때 저장된 변경 송신 1회 순서로 진행한다.
중단·오류가 나오면 추가 송신하지 않고 기록을 확인한다. 원격 기준 revision이 달라졌다면 정상 충돌 검사로 중단되어야 한다.

진단 사본: `/private/tmp/writerpad-frozen-duplicate-xSYSJP/` (공개 파일 아님).

- 최종 테스트: `/private/tmp/writerpad-frozen-duplicate-tests-v3.log`
- 실기기 빌드: `/private/tmp/writerpad-frozen-duplicate-device-build.log`
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_12-49-02-+0900.xcresult`

## 실기기 A 완료 — 2026-09-27 12:55 KST

사용자가 `송신 완료 리비전10 29바이트 f2c3066ea8bf...`를 보고했다.
추가 송신 없이 기기 기록·로컬 SQLite 진단 사본·Staging 서버 SELECT로 대조했다.

- 120번 이벤트 `identicalUnsentFollowersSuperseded`: 119번과 비교하여 후속 batch의 phase만 queued→superseded로 변경됨을 확인했다. 다른 state 필드는 동일하다.
- 137번 이벤트 `sendCompleted`: 기존 A run의 completed=true, 원본 save completed, journal HTTP attempts **1**, 활성 save **0**.
- 기존 batch/operation/request hash는 유지됐다. 후속 batch는 superseded, request nil, attempts 0.
- 로컬 기준선 revision **10**, **29바이트**, SHA-256 `f2c3066ea8bfce2a389f9cd8e80eea85d6a9ac6b2cfa4b2e8cd3120a26569ec0`.
- SQLite source/request/operation 모두 completed, operation result_revision=10. 기존 claim attempts=1 유지. 활성 source/request 큐 0. quick_check=ok.
- 서버 `sync_batches`/`sync_batch_results`에 기존 batch의 committed/applied=true 결과가 존재하며 request hash와 operation ID가 기기 기록과 일치한다.
- 서버 응답의 revision/byte count/content hash 및 현재 대상 문서의 revision/UTF-8 길이/계산한 SHA-256이 모두 로컬 결과와 일치한다.
- 서버 응답 SHA-256 `9538ca24263f9175fb753441744ea0ae9ced0038c6271bf30ef83d42f62e040c`.
- 후속 중복 batch의 서버 `sync_batches` 건수는 **0**이다.

판정: **A(beforeHTTP 진단 중단 → 재실행 → 동일 요청으로 첫 송신) 완료**.
요청별 journal 전송 기록 1회와 서버 revision 9→10을 확인한 것이며, 전체 HTTP 패킷 계측이나 실제 망 장애 검증은 아니다.
재실행 확인에는 만료된 개발 서명 갱신/덮어 설치가 포함됐다. B/C/D 및 일반 제품·실제 OS 중단 시험 완료를 의미하지 않는다.
다음은 새 run으로 B(afterCommitResponse) 시험을 준비하는 단계이며, 이번 확인에서는 새 run이나 송신을 시작하지 않았다.

완료 진단 증거: `/private/tmp/writerpad-a-complete-Nu2Mgv/` (공개 배포 대상 아님).
