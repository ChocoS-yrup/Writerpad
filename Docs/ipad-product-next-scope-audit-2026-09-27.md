# PR #45 이후 제품 범위 점검 — 2026-09-27

## 기준과 판정

- 기준 main: `f97995845b28a0d0888e0400eb671ee6c8f1ba8d`.
- GitHub CLI로 PR #45의 병합과 열린 PR 0건을 재확인했다.
- 후속 브랜치: `codex/ipad-product-structure-resume`.
- 이번 단계는 현재 코드와 기존 증거의 대조 및 후속 범위 확정이다. 제품 코드 수정이나
  새 기능 완료를 주장하지 않는다. 이 문서는 후속 구현과 같은 PR에 묶는다.

## 완료된 범위와 남은 범위

| 영역 | 확인한 상태 | 남은 일 또는 경계 |
|---|---|---|
| 일반 앱 작품별 활성화 | PR #44에서 제품 설정에 연결, 새 handshake와 계정·작품 수명 검사 | 서버 연결 자체와 계약 동기화 활성화는 별개 |
| 여러 문서 본문 저장 | 실제 TXT·SwiftData·SQLite + 합성 transport의 제품 구성 회귀 존재 | 실제 서버·실기기 일반 앱 종단간 증거와 구분 |
| 열린 작품의 본문 저장 기록 재개 | PR #45에서 전경/인증/연결/네트워크/명시적 재시도에 연결 | 미개봉 작품 전체, 구조 journal, OS background scheduler는 이 PR 범위 밖 |
| 구조 변경 기록 | binder journal의 durable handoff와 기존 복구 진입점 존재 | 현재 제품 계약 구성에서 보류→재개→큐→송신을 묶은 검증 보강 필요 |
| 최초 서버 연결 | `ensure_project`, binding, 초기 snapshot 경로 존재 | 신규/LEGACY 작품의 ID_BASED 준비를 자동 완료한다고 표현할 수 없음 |
| 진단 앱 A–D 복구 | 별도 합성 실기기 증거 존재 | 일반 제품의 모든 장애·OS 중단 검증으로 확대하지 않음 |

581개 회귀, Release arm64/x86_64, CI 3개 및 최종 자동 검토 무지적은 PR #45의
최종 head `a78ec9f0d1bd623704774474cae84a9c8306294c` 증거다. 이번 실행 수에 합산하지 않는다.
전체 완료율은 항목별 크기와 완료 조건이 고정되지 않아 새 숫자를 추정하지 않는다.

## 코드 대조에서 확인한 두 경계

### 1. 본문 인계와 구조 journal 복구는 다르다

`SyncV2ProjectHandoffResumer.resume`은 활성 TXT 문서의 `LocalDocumentStoring`
인계를 조회·재생한다. PR #45 완료를 폴더/이름 변경/새 권/휴지통 거래의 자동 재개까지
완료한 것으로 해석하지 않는다.

반대로 구조 복구가 전혀 없다고 단정해서도 안 된다.
`BinderViewModel.load`와 `LocalBinderCommandService`의 명령 진입점은
`recoverPendingTransactions(in:)`를 이미 호출한다. 기존 복구는 `prepared` rollback,
`filesApplied` metadata 반영, `metadataSaved` durable handoff 및 후속 정리를 포함한다.
따라서 이 함수를 단순한 전송 재시도로 취급해 전경 이벤트에서 무조건 호출하면 안 된다.

기존 `testFailedDurableHandoffReplaysSameBatchFromBinderJournal`은 동일 batch 재생을
검사하지만, 그 자체가 일반 계약 recorder·서버 기준·workspace 재개 전체의 증거는 아니다.
제품 구성 통합 재현을 먼저 추가하고, 실제 누락된 연결만 보완한다.

### 2. 서버 연결과 ID_BASED 준비는 다르다

`SupabaseProjectBindingService.createServerProject`는 `ensure_project`를 통해 작품을
연결한다. 저장소의 `ensure_project` SQL은 작품과 멤버를 만들지만 계약 모드 전환을
수행하지 않는다. handshake SQL은 설정 행 부재를 LEGACY/epoch 0으로 다룬다.
`SyncSettingsModel.setGateOpen(... requiresIDBased: true)`는 LEGACY 응답을 거부한다.

이는 코드/저장소 SQL에 근거한 경계이며, 현재 배포된 DB의 모든 함수·trigger·설정을
조회한 결과가 아니다. LEGACY의 기존 일반 저장 경로까지 전부 고장났다는 뜻도 아니다.
기존 `SyncV2ContractPathRecorder`의 일반 기록에는 LEGACY 호환 경로가 남아 있다.

신규 작품의 계약 준비나 명시적 LEGACY 이관은 별도 기능군으로 취급한다.
현재 활성화 제한을 제거하거나 빈 기준을 임의 승인하거나 서버 모드를 자동 변경하지 않는다.

## 다음 구현 묶음: iPad 구조 변경 기록의 제품 재개

우선 기존 동작의 통합 재현을 작성한다. 새 스케줄러를 만드는 것으로 시작하지 않는다.

1. 실제 로컬 binder journal·TXT·SwiftData·SQLite와 일반 계약 recorder를 조립한다.
   원격 transport는 합성 응답으로 제한한다.
2. 폴더/문서 이름 변경, 이동, 새 권, 휴지통 중 대표 사건의 기록 실패를 주입한다.
   파일·metadata 반영과 큐 등록 실패를 구분하고 원래 batch/operation ID와 payload를 확인한다.
3. 바인더 재진입, 설정 재시도, 전경·로그인·네트워크 복구의 현 동작을 비교한다.
   중복 등록, 복구 중 사용자 명령, 구조 기준 불일치, 손상 journal, 계정/작품/설정 변경을 검사한다.
4. 재현된 연결 누락만 수정한다. 파일 거래 복구와 전송 재시도의 책임을 분리하고,
   성공 표시 전에 보류된 구조 기록을 확인한다. 기존 UUID·불변 요청·권한 검사는 유지한다.
5. 관련 Swift 회귀와 Release·공유 계약 검증을 묶고 최종 head에서 한 번 검토 요청한다.

이 범위는 iPad 로컬 재개 연결을 대상으로 한다. Windows 코드·공유 wire 계약·교차 플랫폼
입력이 그대로이면 Windows 회신을 요구하지 않는다. 실제 공통 차이가 발견되면 그 부분만
분리해 설명한다. 이번 점검에서 Windows 검토를 새로 요청하지 않았다.

## 별도 후속 범위

- 최초 연결·계약 준비 UX와 LEGACY 이관: 기존 서버 계약으로 가능한 경계부터 확인한다.
  서버 계약/Windows 의존성 변경이 필요한 경우에만 교차 플랫폼 검토 대상으로 올린다.
- 미개봉 작품의 파일 인계 재개: 기존 inactive-project pull/dispatcher와 구분해 필요성을 검토한다.
- 일반 앱 전체 회귀·실기기/실서버 송수신: 구현 증거와 설치·실행 증거를 나눠 최종 확인한다.
- OS background 전송은 현재 필수 조건이 아니다. 확정 정책인 로컬 저장 우선·전경 복귀 재개를 유지한다.
- 진단 앱 Tab 수동 시험, 백업, 이미 완료한 A–D 반복 시험을 선행 조건으로 되살리지 않는다.

## 이번 검증

최초 연결/초기 snapshot 재개, LEGACY opt-in 차단, binder journal 재생 및 metadata 복구의
기존 선택 테스트 **5개 통과, 실패/건너뜀 0**, 컴파일 경고·오류 0건,
`runtimeWarnings: []`를 확인했다. 신규 통합 시험이나 전체 회귀 결과는 아니다.

- iPad Pro 11-inch (M5), iOS 26.5 Simulator.
- 결과: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_22-50-10-+0900.xcresult`.

- 로그: `/private/tmp/writerpad-product-scope-audit-20260927.log`.
- 빈 서버 URL/key, 고정 package 버전, 별도 bundle, 서명 비활성.
- 서버/실기기 데이터 변경, 실기기 설치, SQL 실행, migration, 백업·삭제·복원은 수행하지 않았다.
- Supabase 스킬로 changelog와 [Swift 사용자 조회 문서](https://supabase.com/docs/reference/swift/auth-getuser)를
  확인했다. 로컬 세션 표시를 새 권한 근거로 삼지 않으며 기존 인증된 경계를 유지한다.
