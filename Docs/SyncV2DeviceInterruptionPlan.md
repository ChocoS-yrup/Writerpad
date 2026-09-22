# SYNC-004 실기기·서버 중단 시험 준비

- 기준: PR #40 병합 main `2dcb1d29f64cadcc64ae29b36e5b3cea5413b9b3`, 2026-09-22.
- 상태: **절차 설계와 코드 대조만 수행. 실기기·서버 중단 시험은 미실행.**
- 허용 변경: 이 문서와 문서 색인/연결. 제품·테스트·빌드 설정·계약·서버는 변경하지 않는다.
- 목적: 이미 확인한 [저장 완료 본문 보존](SyncV2DeviceLifecycleValidation.md) 및
  [임시 DB 중단 검사](SyncV2InterruptionBoundaries.md)와 실제 서버 시험을 구분한다.

## 1. 현재 진단 기능과 제약

소스 기준으로 아래를 확인했다. 과거 검증 대상의 현재 서버 상태나 권한을 확인한 것은 아니다.

| 근거 | 확인한 동작 | 시험에 미치는 영향 |
|---|---|---|
| `NormalEditorState.swift`: `NormalEditorRecoveryInjection` | `DEBUG`, `WRITERPAD_NORMAL_EDITOR`, `WRITERPAD_NORMAL_EDITOR_RECOVERY`가 모두 있어야 실행 환경의 중단 설정을 사용한다. | 일반 앱이나 기존 오프라인 수명주기 빌드에 환경 변수만 넣어 활성화할 수 없다. |
| `GeneralValidationExecution.swift`: `GeneralValidationPlan`, `NormalEditorState.swift`: `NormalEditorPlan` | 이전 합성 작품·문서·부모 ID, 경로, staging endpoint에 고정되어 있다. | 새 fixture를 환경 변수만으로 선택할 수 없다. 고정 값을 우회하거나 검사만 제거하지 않는다. |
| `NormalEditorSession.swift`: `open` | 저널 최초 개설은 revision 6, 269 UTF-8 bytes, 고정 SHA-256과 로컬 본문 일치를 요구한다. | 빈 컨테이너에 설치하는 것만으로 시험 준비가 되지 않는다. 초기 기준선·메타데이터·연결을 검증해야 한다. |
| `ReceiveValidationPolicy.swift`, `NormalEditorBackend.swift`: `prepare` | policy 계정, 인증 계정, 작품 연결의 소유자, gate, 계약 handshake, 수명 epoch를 확인한다. | 설정 파일 또는 URL/key의 존재는 송신 허가가 아니다. 재실행/비활성 이후 명시적 준비가 필요하다. |
| `NormalEditorState.swift`: `hit` | 예상 phase·요청·합성 본문 해시를 확인한 뒤 중단 소비 기록을 영구화하고 오류를 반환한다. | 프로세스 종료·네트워크 차단·OS suspension을 일으키는 기능이 아니다. |
| `NormalEditorState.swift`: `record` | 아직 `queued`인 이전 저장을 `superseded`로 바꿀 수 있다. | 이 제한 모드를 일반 제품의 모든 저장 FIFO 증거로 사용하지 않는다. |

중단 소비 키는 `normal-editor-recovery-20260913-v1:<point>`다. 본문 해시나
실행 ID가 키에 포함되지 않으므로 **같은 저널에서 같은 point는 한 번만** 중단된다.
환경 변수를 다시 설정해도 재무장되지 않는다. 재시험을 위해 기존 저널을 삭제하거나
완료 기록을 편집하지 않는다. 재현 가능한 새 실행 단위 격리가 후속 구현의 선행 조건이다.

로컬 `Configuration/Supabase.Debug.local.xcconfig`에는 URL/key 설정 항목이 존재한다.
이번 단계에서는 값·유효성·계정 접근 권한을 검사하거나 출력하지 않았다. Debug 빌드는
이를 선택적으로 포함하므로 오프라인 빌드는 URL/key를 명시적으로 빈 값으로 덮어써야 한다.
이 파일은 별도 작업 트리에 자동 복사되지 않으며 Git에 추가하지 않는다.

## 2. 격리 결정과 실행 전 게이트

다음 구현의 기본 방향은 **별도 실행 ID와 합성 fixture를 사용하는 진단 전용 구성**이다.
기존 9월 12~13일 fixture는 현재 사용 여부·본문·권한을 확인하기 전에는 재사용하지 않는다.
아래 항목은 구현/검토 요구사항이지, 현재 이미 제공되는 기능이 아니다.

1. 읽기 전용 준비 검사에서 endpoint, 인증 계정, local/server project, document/parent,
   경로, 기준 revision/본문 해시, contract SHA, ID_BASED/migration epoch를 하나의
   승인된 시험 명세와 대조한다. 누락·범위 밖 대상·해시 불일치는 송신 전에 차단한다.
   파일의 임의 ID를 받는 것만으로 승인된 대상으로 간주하지 않는다.
2. 합성 작품과 문서만 사용한다. 시험 계정/작품 생성·초기화·서버 쓰기는 실제 대상과
   변경 내용을 사용자에게 제시한 별도 실행 단계에서 진행한다. 기존 원고의 revision을
   되돌리거나 서버 행을 직접 수정해 과거 fixture 상태에 맞추지 않는다.
3. 앱은 publishable key와 시험 계정 인증을 사용한다. secret/service_role 키로 RLS를
   우회하지 않는다. 모바일 앱에 secret key를 넣지 않는 원칙은
   [Supabase 공식 API key 문서](https://supabase.com/docs/guides/getting-started/api-keys)를 따른다.
4. 대상 밖 읽기·쓰기, 일반 dispatcher/Realtime, 자동 재시도, 다른 앱의 계정/설정 공유를
   차단한다. 기존 제한 모드의 endpoint·계정·범위·요청 바이트 검사와 권한 취소를 유지한다.
5. 실행별 증거 디렉터리와 중단 소비 기록을 분리한다. 이전 결과는 읽기 전용으로 보존한다.
   실행 ID 변경이 불명확한 기존 요청의 새 batch/operation ID 발급을 허용해서는 안 된다.
6. bundle ID·서명·설치 슬롯을 설치 직전에 확인한다. 과거 실기기 기록에는 무료 서명
   슬롯 제한이 있었으므로 새 앱 설치 가능성을 가정하지 않는다. `.debug`, `.receiveboundary`,
   `.lifecyclevalidation` 앱과 그 데이터는 보존한다. 슬롯이 없으면 설치를 중단하고
   어느 검증 앱을 백업 후 갱신할지 별도 확인한다. 앱 삭제로 해결하지 않는다.
7. 설치 전에 앱 데이터·합성 본문·저널·DB의 일관된 보관 사본과 해시 목록을 만든다.
   SQLite는 앱 정지 후 DB/WAL/SHM 세트 또는 일관된 backup 방식으로 수집한다.
   실행 중 DB 파일 하나만 복사해 정확한 큐 상태라고 판정하지 않는다.

## 3. 순차 시험표

먼저 각 경계를 별도 합성 실행으로 확인한다. 한 사건에 네트워크 차단, 강제 종료,
잠금, IME 입력을 동시에 넣지 않는다. 아래는 기존 제한 모드 소스로 확인한 기대값이며,
새 진단 빌드에서도 같은 의미인지 테스트로 검증해야 한다.

| 사건 | 중단 시 기대 상태 | 재실행 후 허용 동작과 판정 |
|---|---|---|
| A: `beforeHTTP` | 요청은 `frozen`, 이 저장의 전송 attempts는 0, `document_commit` 미호출. 준비 handshake/조회는 앞서 실행될 수 있다. | 현재 권한을 다시 준비한 뒤 **송신**으로 동일 batch/operation/요청 해시의 첫 commit 1회. receipt 복구 버튼으로 대체하지 않는다. |
| B: `afterCommitResponse` | 유효한 commit 응답을 메모리에서 검증했지만 저널에는 아직 저장하지 않음. `httpStarted`, attempts 1, 저장된 response 없음. | **결과 복구**로 기존 batch의 `sync_batches`/`sync_batch_results`를 조회·검증해 로컬 반영. 새 commit 0회, 서버 revision 증가 총 1회. receipt가 없거나 불일치하면 미확정 상태로 중단하며 재송신하지 않는다. |
| C: `afterStoredResponse` | `responseStored`, attempts 1, 검증한 response가 저널에 존재. 로컬 완료 전. | **결과 복구**로 저장된 response를 로컬 반영. 복구 동작 자체의 receipt GET/commit POST는 0회. 재준비 handshake와 외부 증거 조회는 별도 집계한다. |
| D: `afterOriginalApply` | 별도 수신 시험. 원본 TXT 적용 뒤 기준선 갱신 전 `originalApplyStarted`. | dirty/조합/미완료 송신이 없어야 한다. 재준비 후 **수신**으로 저장된 수신 건을 마무리하고 원본·기준선·초안 해시를 일치시킨다. 서버에 새 본문을 만드는 상대 플랫폼 작업은 별도 승인/조율한다. |

A~C를 먼저 수행하고 D는 수신 fixture와 상대 플랫폼 준비 후 별도로 수행한다.
B는 **서버 응답을 받은 뒤 로컬 저장을 생략한 진단 오류**다. 실제 망 단절이나
서버 장애를 재현했다고 부르지 않는다. 실제 응답 유실/프로세스 중단은 이후 독립 사건이다.
commit POST 0/1회는 요청별 범위이며 인증·handshake POST까지 0이라고 표현하지 않는다.

### 각 사건의 공통 절차

1. Git/build/contract와 시험 명세를 고정하고 오프라인 차단 검사를 통과한다.
   원본 앱 데이터의 보관 사본과 시험 전 로컬/서버 기준선을 확보한다.
2. 합성 본문을 한 번 저장하고 영구 source/저널 기록을 확인한다. 화면에 보이는 글자만으로
   저장됐다고 판단하지 않는다. 해당 본문 SHA-256과 point를 묶어 중단을 활성화한다.
3. 권한 준비 후 해당 동작을 한 번 실행한다. 기대한 checkpoint와 phase가 보존됐음을
   확인한다. 중단 오류 뒤 세션의 `prepared`는 해제되어야 한다.
4. 기기에서 해당 검증 앱만 수동 종료·재실행한다. 실행 전후 PID/시각을 비공개 증거에
   남긴다. 재실행만으로 송신이 시작되지 않았는지 확인한다. 홈 아이콘 재실행에서는
   이전 launch 환경이 전달된다고 가정하지 않으며, 이미 소비한 중단을 재무장하지 않는다.
5. 다시 준비한 뒤 표의 동작만 실행한다. request/source의 batch·operation ID, UTF-8
   바이트/해시, Base, attempts와 서버 receipt의 작성 주체·요청/응답 해시를 대조한다.
   이후 후속 합성 저장이 확인된 새 Base를 쓰는지 별도 확인한다.
6. 원래 사건/서버 상태를 보존한다. 성공 뒤에도 원본 fixture나 receipt를 삭제·초기화하지
   않는다. 다음 시험은 이전 사건의 미확정 요청이 남아 있으면 진행하지 않는다.

## 4. 일반 제품·실제 OS 시험은 별도

- 위 제한 모드는 일반 제품 dispatcher의 자동 재개, 여러 문서 FIFO, 분할 편집기,
  실제 IME 조합을 대신하지 않는다. 제품 경로의 별도 격리와 관찰 지점을 먼저 준비한다.
- 저장 직전 종료는 마지막 입력의 영구화 여부를 기록하는 시험이다. 영구화되지 않은
  입력까지 무조건 복원돼야 한다는 합격 조건을 만들지 않는다.
- 실제 조합 중 잠금 시험은 키보드 종류·입력 순서·marked text·양쪽 편집기의 저장 경계를
  구분한다. 이미 확인한 저장 완료 003·004화 잠금/재실행 결과를 반복 집계하지 않는다.
- OS suspension은 debugger를 붙이지 않은 실행에서 OS 상태 근거를 별도로 확보해야 한다.
  잠금 시간, callback 로그, 앱이 잠시 응답하지 않았다는 관찰만으로 확정하지 않는다.
  근거를 얻지 못하면 `미관측`으로 기록한다. 수동 종료 결과와 합치지 않는다.
- 실제 서버 결과 유실 사건은 서버 receipt와 클라이언트 중단 시각을 대응시킬 수 있을 때만
  판정한다. 로그가 없다는 이유만으로 전송 0회를 주장하지 않는다. 계측 불충분은 미판정이다.

## 5. 증거·중단 조건·인계

비공개 사건 기록에는 `test_run_id`, 양 플랫폼 commit, build SHA, bundle ID, 기기/OS,
계정/작품/문서 대응, contract SHA, 본문 길이·해시, 요청 ID·해시, 중단 전후 phase·Base·
attempts·queue 상태, 서버 receipt, 실행 시각, 사용자 조작과 직접 관측의 구분을 남긴다.
공개 인계에는 자격 증명, 원본 DB/원고, 실제 기기 UDID, 설치 컨테이너 ID를 넣지 않는다.
필드가 없는 경우 0 또는 통과로 채우지 말고 `미수집`/`미판정`으로 남긴다.

범위 밖 대상, 변경된 기준선, 불일치 receipt, 중복 commit, 로컬 저장 실패, 알려지지 않은
큐 항목, 증거 수집 실패가 있으면 즉시 다음 송신을 멈춘다. 로그/원본/큐를 보존하고
원인 확인 단계로 전환한다. 새 요청 생성, 전역 recovery, DB 편집으로 우회하지 않는다.

이번 단계는 코드·공식 key 지침 대조, 문서 참조/diff 검사, 공통 계약 검사로 검증한다.
XCTest·기기 설치/실행·인증·서버 fixture 조회/변경은 수행하지 않는다. PR #40의 107개
통과는 이전 단계 결과이며 이번 단계에서 다시 실행했다고 보고하지 않는다.

다음 순서: 이 문서의 정확한 커밋을 Windows에서 읽기 전용 검토 → 병합 → 진단 실행별
격리와 fail-closed 준비 검사 구현/오프라인 회귀 → 대상·계정·설치 계획 확정 → A~C 실행.
일반 제품·실제 OS 시험까지 필요한 근거를 확보하기 전 **SYNC-004는 부분 검증**이다.
