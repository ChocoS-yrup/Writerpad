# 로컬 완료 구조 기록의 제품 재개 — 2026-09-27

## 범위와 재현

- 기준: PR #45 병합 `f97995845b28a0d0888e0400eb671ee6c8f1ba8d`.
- 브랜치: `codex/ipad-product-structure-resume`.
- 일반 앱의 열린 작품 자동 재개와 설정 재시도를 보완한다.
- 실제 TXT·SwiftData·SQLite·binder journal·계약 recorder를 사용하고 원격 transport만 합성 응답이다.

관문이 닫힌 상태에서 화 이름을 변경하면 로컬 파일·metadata는 반영되고 고정 batch를 가진
binder journal이 남는다. 기존 `SyncV2ProjectHandoffResumer`는 본문 인계만 조회해,
구조 기록만 남았을 때 미처리 수 0을 반환하고 큐 등록·송신을 하지 않았다.
수정 전 통합 시험에서 journal 잔존, 큐 0건, 송신 0건을 재현했다.

첫 fixture는 화를 권 폴더 없이 만들어 제품 규칙에 거절됐다. `메인/원고/1권`으로 바로잡은
재현 결과가 `/private/tmp/writerpad-structure-resume-red-v2.log`다. 제품 원고 규칙은 바꾸지 않았다.

## 구현

1. binder protocol에 구조 기록 존재 조회와 **송신 인계 전용** 재시도를 추가했다.
2. 새 로컬 구조 거래는 파일 변경 전에 기존 recorder에서 서버·계정 출처를 읽어 journal에 남긴다.
   최초 durable batch에도 같은 출처를 복사한다. 이전 기록에 현재 연결 정보를 소급해서 붙이지 않는다.
3. 자동/설정 재시도는 동일 작품의 journal 한 개가 `metadataSaved`이고, 고정 batch·거래 ID·출처가
   모두 맞을 때만 기존 승인 포함 recorder를 호출한다. 이름 변경/이동, 생성, 새 권, 순서 변경이 대상이다.
4. 작품 구조 mutation gate 안에서 재생하며, 일반 journal 복구도 같은 gate로 직렬화했다.
   기존 alias 이관은 gate 밖의 기존 경로에 남겨 중첩 gate 획득을 피한다.
5. recorder의 최종 SQLite 승인 검사까지 호출자 수명 검증을 전달한다. enqueue 뒤에도 승인을
   재확인하고 원래 journal bytes가 그대로일 때만 성공한 인계 표식을 제거한다.
6. 공통 resumer가 구조 기록을 먼저 확인하고, 같은 인증·연결·작품·설정·전경·서버 기준 검사를 거친다.
   구조 기록이 보류되면 뒤의 본문 인계를 재생하지 않는다. 기존 불확실 큐의 receipt 재시도는 유지한다.
7. 작업 화면과 설정의 제품 조립에 binder를 전달했다. 보류는 기존 `저장 기록 확인 필요` 안내를 이용한다.

본문을 다시 쓰거나 새 요청 UUID를 생성하지 않는다. 서버 API·계약·SQL·RLS·Windows·교차 플랫폼 입력·
패키지·서명 구성은 바꾸지 않았다. Supabase 스킬의 변경 목록·인증 문서 확인을 거쳐 기존 인증 경계를
유지했으며, 사용자 metadata·새 관리자 권한·서버 모드 전환은 추가하지 않았다.

## 의도적으로 자동 처리하지 않는 기록

- 파일 작업 미완료(`prepared`, `filesApplied`), batch 없음, 손상 journal.
- 작성 당시 서버·계정 출처가 없거나 현재 연결과 다른 기록.
- 휴지통 이동/복원/영구 삭제/전체 비우기. 후속 파일 정리가 포함될 수 있어 이번 전송 전용 경로에서 제외한다.
- 여러 journal이 동시에 남은 경우. UUID 파일명으로 인과 순서를 추정하지 않는다.
- recorder 실패·서버 크기 제한. 표식을 지우거나 완료로 표시하지 않는다.

위 기록은 기존 거래 복구와 별도 후속 검토 대상으로 남긴다. 이 단계로 구조 변경의 모든 복구,
미개봉 작품 전체 재개, OS background 전송이나 실기기 송수신이 끝났다고 선언하지 않는다.

## 검증

새 검사 4개:

- 본문 인계 없이 이름 변경 journal만 남아도 읽기 전용 서버 기준 준비 후 같은 batch/source로 큐 등록·송신.
  반복 재개의 중복 없음, 일반 계약 큐 완료와 구형 송신 0건 확인.
- 파일 단계 2종, 출처 없음/다름, batch 없음, 손상, 여러 기록, 닫힌 관문에서 journal bytes·본문 유지.
- recorder 내부 비동기 경계에서 호출자 권한이 바뀌면 SQLite 미등록과 journal 보존.
- 설정 재시도에서 폴더 생성·새 권 생성 기록을 연결하고 합성 송신 완료.

중간 바인더 기존 검사 44개는 통과했다. 새 송신 fixture에는 기존 서버 tree-order 기준도 추가했다.
해당 기준이 없으면 송신기가 거부하는 것이 정상이며, 제품의 기준 검사를 완화하지 않았다.
완료된 큐 source는 복구 상세 API에서 제외되므로 원본 비교는 완료 전 수행한다.

최종 확장 회귀 **556개 통과, 실패/건너뜀 0**, 컴파일 경고·오류 0건,
xcresult 요약의 `runtimeWarnings: []`.
AppEnvironment 116, LocalBinderCommandService 44, LocalBinderFolderSync 6,
LocalBinderRepository 16, SyncSettingsModel 6, GeneralSync 73, Handshake 148, SnapshotPull 147.
전체 suite나 실제 서버 시험의 결과가 아니라 위 8개 class의 선택 회귀다.

- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_23-12-28-+0900.xcresult`.
- 일반 Release 빌드 성공(exit 0), `arm64`·`x86_64` 확인, 컴파일 경고·오류 0건.
  DEBUG·진단·격리 테스트 컴파일 플래그를 추가하지 않은 Release 구성이다. 설치·실행 증거는 아니다.

- 확장 회귀 로그: `/private/tmp/writerpad-structure-resume-regression-v1.log`.
- Release 로그: `/private/tmp/writerpad-structure-resume-release-v1.log`.
- 계약 검증 통과: 0.2.0, 7 schemas / 12 transitions / 15 storage-name / 4 atomic-wire / 7 document-wire.
- canonical SHA-256: `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.
- 격리 simulator bundle, 빈 서버 URL/key, package lock 고정, 서명 비활성. 실제 기기·서버 조작 없음.
- 관련 변경은 이 브랜치의 로컬 체크포인트로 정리한다. push/PR/원격 검토/병합은 수행하지 않았다.

## 후속 마무리

같은 브랜치에서 이동·순서 변경, 재개와 명시적 복구의 동시 실행, 작품·계정·전경 변경 경계를
추가 점검한다. 현재 4개 신규 테스트가 모든 구조 명령이나 실제 OS 수명을 검증한 것은 아니다.
관련 보완을 마친 최종 head만 한 PR로 검토 요청하며, iPad 전용 범위에는 Windows 회신을 요구하지 않는다.

## 후속 경계 검증 완료 — 로컬 체크포인트

구현 체크포인트 `d258249` 이후 제품 코드는 그대로 두고 테스트 5개를 추가했다.
기존 보수적 보류 검사도 8종에서 14종으로 확장했다.

- 일반 폴더의 문서 이동, 하위 폴더 전체 이동, 자식 순서 변경을 실제 binder 명령으로 수행한다.
  설정 재개 후 원래 batch/source 유지, metadata·본문 bytes·파일 수정 시각 불변, 합성 계약 요청 1건,
  완료 후 대기·재시도·주의 큐 0건과 구형 송신 0건을 확인했다. 원고 계층 보호 규칙은 유지한다.
- 같은 mutation gate를 공유하는 서로 다른 binder actor에서 자동 재개와 명시적 전체 복구를
  양쪽 순서로 겹쳐 실행했다. recorder 내부를 continuation으로 멈추고 두 번째 호출을 시작하며,
  짧은 bounded inverted expectation으로 중복 진입을 검사한다. 해제 후 recorder 호출·송신이 각 1회다.
- 실제 SQLite 등록 직후 호출자 권한이 바뀌면 journal bytes를 보존한다.
  다음 정상 재시도가 같은 batch/source를 재사용하며 큐 수가 늘지 않고 요청 1회로 이어진다.
- 작품 구조 잠금을 다른 작업이 보유한 상태에서 기다리는 재개를 호출자 epoch 변경 또는 Task 취소로
  중단했다. journal·빈 큐를 보존하고, 잠금이 풀린 뒤 새 정상 호출이 성공한다.
- 서버 기준 조회 중 재로그인, 연결 epoch, 로컬 작품 epoch, 설정 작업 취소, 작품 관문 닫기,
  전역 동기화 끄기, 비활성 전경, 작품 전환 8종을 주입했다. 구조 journal·metadata 유지,
  큐/원격 쓰기 0건, 새 구조 권한 미부여를 확인했다.
- 보류 검사에 휴지통/복원/영구 삭제/전체 비우기 종류, 거래 ID 불일치, journal 출처만 누락된
  경우를 추가했다. 종류 검사는 기존 완료 journal의 종류를 바꾼 합성 입력이며 실제 휴지통 거래의
  전체 수명주기 검증을 뜻하지 않는다.

최종 선택 회귀 **561개 통과, 실패·건너뜀 0**. 기존 8개 class 중 Handshake만 148→153개이며,
나머지 class 수는 위와 같다. 컴파일 `warning:`·`error:` 0건, xcresult `runtimeWarnings: []`.
콘솔에는 기존 UIKit appearance/TextKit 안내가 있으며 이전 회귀에도 같은 합산 65건이 있다.
로그 전체가 무경고라고 선언하지 않는다.

- 로그: `/private/tmp/writerpad-structure-boundaries-regression-v1.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_23-36-55-+0900.xcresult`.
- 초기 집중 검사의 자료형 비교 컴파일 오류와 미대기 XCTest expectation 오류는 테스트 코드에서
  수정했다. 제품 오류로 집계하지 않으며 최종 회귀에 두 보정이 포함됐다.
- 계약 0.2.0 재검증 통과, canonical SHA-256은 위와 동일하다.
- 이번 변경은 테스트와 이 문서뿐이다. `WriterPad`, Xcode project, 계약 파일은 `d258249`와 같으므로
  해당 제품 코드의 이전 Release 성공 증거를 유지한다. 이번 단계에서 Release를 다시 실행하지 않았다.
- Supabase 스킬에 따라 변경 목록과 Swift 인증 공식 문서를 확인했으며 기존 인증 경계를 유지했다.
  실제 Supabase·실기기는 조작하지 않았다.
- GitHub CLI 읽기 조회 시 main은 `f97995845b28a0d0888e0400eb671ee6c8f1ba8d`, 이 브랜치 PR은 없음.
  이번 단계는 로컬 검증·커밋까지이며 push·PR 생성·원격 검토·병합은 아직 수행하지 않았다.

다음 단계는 이 브랜치의 구현·검증 변경을 한 PR로 제출하고 최종 head에 한 번 검토를 요청하는 것이다.
Windows 의존성이나 계약·교차 플랫폼 입력 변경이 없으므로 Windows 회신을 대기하지 않는다.
여러 미완료 journal, 파괴적 구조 거래, 출처 없는 이전 journal의 자동 복구는 계속 제외한다.

## PR #46 검토 보완 — 2026-09-28

`6045b0f`를 [PR #46](https://github.com/ChocoS-yrup/Writerpad/pull/46)로 제출했다.
첫 최종 head 검토에서 다음 P1 두 건이 제기됐고, 추가 재현 검사 2개가 기존 제품 코드에서
실패했다(`/private/tmp/writerpad-pr46-review-red.log`, 21 assertion failures, unexpected 0).

1. [배치와 journal 작업 불일치](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115831623):
   바깥 journal 종류만 허용 목록에 있어도 내부 trashChange 배치나 삭제 mutation 등이 들어갈 수 있었다.
   배치 종류, 복구용 override 부재, 프로젝트/노드 중복/활성 상태, 기록된 구조 snapshot과 새 노드,
   문서 ID·경로·본문 hash·저장 세대, 폴더 ID·부모·이름·삭제 여부, operation ID 중복,
   기대 문서·폴더 mutation 집합과 tree-order 한 개를 검증한다. purge/ensureProject는 거부한다.
   현재 파일을 재작성하거나 새 요청 UUID를 만들지 않는다.
2. [변경 시작 시 출처 없음](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115831625):
   출처 조회는 nil인데 나중 requirement가 연결 상태인 경우, 일반 recorder가 당시 출처 없는 작업을
   현재 연결에 등록할 수 있었다. 출처 필수 recorder에는 journal 출처와 batch 출처 일치를 요구하며,
   출처가 없으면 batch 생성·등록·journal 제거 없이 보류한다. 전체 journal 복구에도 같은 방어가 적용된다.
   localOnly requirement와 출처 비필수 recorder의 기존 동작은 유지한다.

출처 검사 강화에 맞춰 기존 명시적 휴지통 비우기에도 삭제 시작 전에 얻은 출처를 별도의
전체 비우기 요약 batch에 전달한다. 개별 삭제는 기존 거래 시작 시 출처 캡처를 사용한다.
삭제 명령을 자동 재개 대상으로 확대한 것이 아니다.

새 검사는 불일치/삭제/외부 문서 mutation 등 8종의 큐 미등록·journal 및 본문 보존,
출처 nil→연결된 requirement 상황과 이후 전체 복구의 보류, 정상 휴지통 비우기 개별·요약 batch의
출처 전달을 다룬다. 이전 생성·이름 변경·이동·하위 트리·순서·동시성·수명 검사는 그대로 유지한다.

검토 보완의 최종 회귀는 아래에 기록하며, Release·최종 head CI·재검토 결과는 PR 본문에서 추적한다.
검토 대상 head를 문서 갱신만으로 바꾸지 않는다. Supabase 스킬의 변경 목록·Swift 인증 문서를
재확인했고 서버/계정 경계를 로컬에서 강화했다. 실제 기기·서버 변경은 없다.

- 최종 선택 회귀 **564개 통과**, 실패·건너뜀 0, 컴파일 경고·오류 0, xcresult `runtimeWarnings: []`.
  AppEnvironment 116 / BinderCommand 45 / BinderFolderSync 6 / BinderRepository 16 /
  Settings 6 / GeneralSync 73 / Handshake 155 / SnapshotPull 147.
- 로그: `/private/tmp/writerpad-pr46-review-green-v2.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.28_00-15-05-+0900.xcresult`.
- 계약 0.2.0 재검증 통과, canonical digest 불변.

### 전체 구조 snapshot 보강

`6469b17` 재검토에서 [변경 대상 밖 snapshot 검증](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115885541)
지적이 추가됐다. journal의 변경 대상은 일치해도 무관한 형제의 순서·부모·경로 또는 누락을
바꾼 전체 snapshot이 재생될 수 있었다. 4종을 실제 queue 경계에서 재현했으며 수정 전
`/private/tmp/writerpad-pr46-snapshot-red.log`에서 12 assertion failures, unexpected 0을 확인했다.

자동 인계가 작품 구조 mutation gate 안에서 확정 binder metadata 전체를 읽고, 저장된 전체
`LocalStructureSnapshotNode` 집합과 ID 정렬 후 비교하도록 보강했다. 읽기 후 호출자 권한을
다시 확인한다. 일치하지 않으면 기록을 큐에 넣거나 journal을 지우지 않는다. 비교에는 ID·작품·
종류·부모·경로·순서·tree 포함 여부만 포함되며 본문·hash·커서·수정 시각은 포함하지 않는다.
따라서 본문 저장에 따른 비구조 metadata 갱신만으로 구조를 다시 쓰거나 현재 파일로 요청을 재생성하지 않는다.

최종 회귀 결과는 아래에, Release·CI·재검토의 정확한 head와 결과는 PR 본문에 기록한다.

첫 확장 회귀에서 새 snapshot 검사는 통과했지만 기존
`testWorkspaceSyncModelDebouncesRealtimeAndStopsInBackground`가 기대 수신 2회 대신 1회로 실패했다.
로그에는 두 번째 pull 예약 후 실제 시작이 105ms 뒤로 늦어졌으며, 100ms 고정 대기의 assertion이
그 사이 실행됐다. 해당 테스트의 두 긍정 대기를 최대 200회×10ms의 실제 횟수 조건 대기로 바꿨다.
기대 횟수 2/3, 비활성 상태의 추가 수신 금지 검사는 유지하며 제품 debounce 코드는 바꾸지 않았다.
실패 로그 `/private/tmp/writerpad-pr46-snapshot-green.log`도 검증 이력으로 남긴다.

- 최종 선택 회귀 **565개 통과**, 실패·건너뜀 0, 컴파일 경고·오류 0, xcresult `runtimeWarnings: []`.
  이전 564개 구성에서 Handshake만 155→156개이며 나머지 class 수는 같다.
- 로그: `/private/tmp/writerpad-pr46-snapshot-green-v2.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.28_00-27-45-+0900.xcresult`.
- 계약 0.2.0 검증 재통과, canonical digest 불변. Release 로그는
  `/private/tmp/writerpad-pr46-snapshot-release.log`이며 완료 결과는 PR 본문에서 추적한다.

### 본문 저장과 구조 인계 순서·본문 근거 보강

`1892310` 검토의 [영향 문서 잠금](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115926628)과
[생성 본문 근거](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115926632)를 함께 수정한다.
수정 전 집중 검사 2개에서 16 assertion failures, unexpected 0을 재현했다
(`/private/tmp/writerpad-pr46-document-gates-red.log`). 자동/전체 복구의 recorder를 멈춘 동안 같은
문서 저장이 먼저 진입하고, 후속 송신이 막히는 것을 실제 SQLite·합성 transport로 확인했다.
본문과 그 hash를 함께 변경한 생성/새 권 batch도 큐에 들어갔다.

- journal 복구는 구조 잠금 아래 journal bytes와 대상 문서 ID를 수집한 뒤 잠금을 해제하고,
  일반 execute와 같은 UUID 정렬 순서로 **구조 키 + old/new text ID 전체**를 함께 획득한다.
  구조 키를 잡은 채 더 작은 문서 키를 얻는 역순 획득을 하지 않는다.
- 잠금을 다시 얻은 뒤 journal 집합·bytes를 재확인한다. 다른 재개가 소비한 항목은 허용하지만
  새 journal이나 바뀐 내용은 기존 문서 키로 처리하지 않고 보류한다. 복수 키 경로에도
  `drainOnTimeout`을 전달해, 실행 중 작업이 끝나기 전에 문서 잠금이 풀리지 않도록 한다.
- 전송 본문의 계산 hash뿐 아니라 해당 `journal.newNodes`에 저장된 hash와도 일치를 요구한다.
  새 본문과 hash가 함께 바뀐 기록은 보류한다. 새 요청을 재생성하거나 현재 TXT를 덮어쓰지 않는다.
- 잠금 획득보다 먼저 시작한 본문 저장도 별도로 시험했다. 구조 journal이 남아 있으면 TXT와
  본문 handoff는 저장하되 recorder 등록은 보류한다. 구조를 먼저 등록한 뒤 공통 재개가 본문을
  이어 등록한다. journal 조회 실패도 보류하며, 손상 journal을 없애거나 성공으로 간주하지 않는다.
  이 선행 저장 검사는 보강 전 5 assertion failures로 재현했다
  (`/private/tmp/writerpad-pr46-earlier-save-red.log`).

잠금/hash 보강의 중간 선택 회귀 567개가 통과했다. 선행 저장 보류까지 포함한 최종 회귀에는
`LocalDocumentStoreTests`, `LocalDocumentStoreRecoveryTests`도 추가한다. 최종 결과는 아래와
PR 본문에 기록하며 이전 단계의 Release·CI 성공을 새 head 성공으로 대체하지 않는다.

- 최종 선택 회귀 **588개 통과**, 실패·건너뜀 0, 컴파일 경고·오류 0, xcresult `runtimeWarnings: []`.
  AppEnvironment 116 / BinderCommand 45 / BinderFolderSync 6 / BinderRepository 16 /
  DocumentStoreRecovery 3 / DocumentStore 17 / Settings 6 / GeneralSync 73 / Handshake 159 / SnapshotPull 147.
- 로그: `/private/tmp/writerpad-pr46-ordering-final-tests.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.28_00-44-05-+0900.xcresult`.
- 계약 0.2.0 재통과, canonical digest 불변. 실제 서버/기기 작업 없음.
- 중간 Release(`/private/tmp/writerpad-pr46-document-gates-release.log`)는 마지막 저장 경로 보완으로
  대체돼 중단했으며 성공 증거로 사용하지 않는다. 최종 소스는 새 DerivedData
  `/private/tmp/WriterPad-PR46-FinalRelease.ZNcLrE`에서 빌드하고
  `/private/tmp/writerpad-pr46-ordering-final-release.log`에 기록한다. 완료 결과·CI·재검토는 PR 본문에서 추적한다.

### 전체 복구의 저장 배치 검증 통합

`492f789` 최종 검토에서 [전체 복구 검증 우회](https://github.com/ChocoS-yrup/Writerpad/pull/46#discussion_r4115981810)가
추가 확인됐다. 자동 인계는 검증하지만 기존 전체 복구의 `completeDurableHandoff`는 저장된 배치를
바로 recorder에 전달했다. 기존 손상 종류/변경 내용 8종, 전체 snapshot 손상 4종, 생성/새 권의
본문+hash 동시 손상 2종을 전체 복구에도 적용한 테스트 3개에서 **36 assertion failures,
unexpected 0**을 재현했다 (`/private/tmp/writerpad-pr46-full-recovery-red.log`).

이번 범위인 create/createVolume/relocate/reorder의 저장된 배치는 전체 복구에서도 같은 validator를
통과해야 한다. 검사는 recorder 호출뿐 아니라 local-only 성공 처리보다 앞에 둔다. validator 자체도
project/transaction ID와 journal·batch provenance 일치를 검사한다. 손상된 저장 요청은 현재 파일로
재생성하거나 journal을 소비하지 않는다. 기존 명시적 휴지통/삭제 복구 동작의 범위는 확대하지 않는다.

확장 회귀 로그는 `/private/tmp/writerpad-pr46-full-recovery-green.log`, Release 로그는
`/private/tmp/writerpad-pr46-full-recovery-release.log`이며, 완료 결과는 아래와 PR 본문에서 추적한다.
계약 0.2.0 검증 재통과, canonical digest 불변. 실제 서버/기기 변경 없음.

- 선택 회귀 **591개 통과**, 실패·건너뜀 0, 컴파일 경고·오류 0, xcresult `runtimeWarnings: []`.
  앞선 10개 class 구성에서 Handshake만 159→162개로 증가했다.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.28_00-57-45-+0900.xcresult`.
- Release·최종 head CI·검토 결과는 PR 본문에 기록하여 검토 요청 이후 소스 head를 바꾸지 않는다.
