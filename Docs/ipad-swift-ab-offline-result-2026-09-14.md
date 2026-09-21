# Swift A/B 시간·요청 예산·세션·생명주기 — 오프라인 구현 결과

2026-09-14. 사용자 요청에 따라 합성 transport 전용 Swift A/B 정책을 구현하고 신규·영향 검사를 한 묶음으로 완료했다. 이전 Python A/B와 Swift reader/생명주기 소스를 대조했다. 실제 Windows raw를 이번 A/B 입력으로 사용하거나 다시 검토하지 않았다.

## 결과

- **신규 Swift 64개 + 기존 Swift 141개 + 기존 Python 177개 = 최종 고유 382개 통과, 실패 0.** Swift 합계 205개이며 이전 단계의 318개를 별도로 다시 더하지 않는다.
- `SyntheticABContract.swift`와 `SyntheticABPolicy.swift`를 추가했다. 새 고정 합성 identity/본문/대상만 만드는 Expected와 구체 final 타입의 transport·가짜 시계/세션·journal을 사용한다. 임의 네트워크 함수·transport protocol·실제 세션·reader의 보관 자료를 받는 초기화 경로는 없다.
- 두 소스를 기존 격리 iOS target에 추가했고 **generic iOS Debug unsigned 빌드가 성공**했다. 기존 화면/controller·원래 WriterPad 앱·reader·저장 adapter는 변경하지 않았다. 새 정책을 시작하는 UI나 실제 수신 자동 호출은 추가하지 않았다.
- 앱 Mach-O 3개에 코드 서명 load command가 없고 `_CodeSignature`/profile도 없음을 산출물 읽기로 확인했다. 설치·기기/시뮬레이터 실행으로 확인한 결과가 아니다.

## 고정한 실행 의미

| 항목 | 이번 Swift 정책 |
| --- | --- |
| 한 실행 | `synthetic-ab-<UUID>` 아래 A 7회 → B 7회의 순차 대조. 기존 UI 자동 주기나 종료 run을 재개하는 단위가 아님 |
| 요청 예산 | HTTP 최대 14회 안에 Auth 사용자 확인 2회 포함. 14+2회가 아님. Q1 사용자 확인, Q2 handshake, Q3~Q7 projects/settings/documents/folders/tree_orders. POST는 handshake뿐이며 refresh·원격 write 없음 |
| 요청 조건 | project_id=eq.<합성 project>, select=*, limit=10000, Prefer=count=exact. 최초 실패에서 다음 예약 중단. 추가 page·재시도·redirect 추적 없음 |
| 사전 차감 | HTTP/Auth 예약을 journal에 직렬화하고 재읽기 일치 확인 후 요청 소비. 시작 시각도 별도 기록·확인. 기록 무동작/실패면 전송하지 않음 |
| 실패 유지 | 예약 후 미전송·timeout·유실·취소도 확정된 예약 유지. stop은 마지막 재읽기 상태에서만 기록. 누락/불확실 기록을 성공으로 보정하거나 비용을 환불하지 않음 |
| 재시작 | running/stopped/finished 복원본, poisoned journal, 사용된 transport, 같은 journal 잠금 충돌을 차단. 종료 run 자동 재개·15번째 요청 없음 |
| 시간 | request/pass/interpass/preApply/localApply/total 및 UTC 시작/만료를 명시. 모든 값은 합성 정수 밀리초. elapsed ≥ limit, now ≥ expiry 차단. 건당 4 MiB·run 32 MiB 상한 이하의 명시적 크기 제한 |
| 비용에 포함되는 시간 | 예약 지연·응답 지연·증거 기록 지연, A 마지막 응답 이후 간격, B 마지막 응답 이후 기록/비교/대기. localApply는 실제 저장이 아닌 `local_policy_probe`의 가짜 경과 시간 |
| 세션 | 합성 세션 ID·변경 횟수·별도 합성 만료 시각을 검사. 동일 ID로 교체돼도 차단. 실제 토큰/refresh/SDK 세션 읽기 없음 |
| 부팅·생명주기 | 부팅 ID/변경 횟수와 기존 BoundaryLifecycle lease를 결합. 비활성/보호 데이터 상실 후 곧바로 복귀해도 이전 lease 차단. UTC/단조 시계 역행·취소 차단 |
| 완료 게시 | finish 뒤에도 같은 lease/세션/부팅/만료/전체 시간을 재확인. 반환된 completion의 checkedReport()도 다시 확인하며 requireApplyInput()은 항상 unverified로 거부 |

여기의 Auth 2회는 두 pass의 사용자 확인 요청 예약이다. 기존 종료 사용량 Auth 12를 재분류하거나 새 사용량으로 교체하지 않는다. 합성 fixture의 100ms/1000ms/6000ms 등은 경계 검사용 작은 값이며 실제 승인 한도·성능 목표가 아니다. 과거 Windows scope의 epoch 초/180초 창을 여기 UTC 밀리초나 현재 승인으로 변환하지 않았다.

## 계약 검사와 기록

- 매 응답에서 status, 사용자/작품/owner, handshake SHA/version/epoch/protocol/capability, settings, 프로젝트의 명시적 trashed_at/trashed_by null을 먼저 검사한다. 필드 부재를 문서 is_deleted로 대체하지 않는다.
- 테이블 응답은 실제 합성 raw 배열 길이와 Content-Range 전체 1페이지를 대조한다. 206도 count가 완전할 때만 통과한다. 빈 배열은 */0 또는 0-0/0이고, total 미상·잘림·불일치는 차단한다.
- Swift reader의 본문·날짜·삭제·구조 검증을 재사용하고 전체 member/reference 행을 고정 Expected와 대조한다. 같은 불완전 그래프가 A/B에 반복돼도 성공하지 않는다.
- 객체 key·테이블 행·capability/protocol 집합의 순서만 비교에서 제외한다. 본문·날짜 표현·children 순서·미정 필드와 특수 metadata 변화는 보존·대조한다. 특수 metadata 본문 의미 검증 완료 플래그는 발급하지 않는다.
- 예약·시작·응답·검증의 UTC/단조 시각과 예약 ID를 기록한다. 합성 정상 raw만 private memory journal에 담는다. 잘못된 응답은 크기·SHA·status 등 안전한 metadata만 기록하며 오류 본문을 journal/요약으로 내보내지 않는다. 크기/시간 경계에서 먼저 차단된 응답은 원문 보관 완료로 표시하지 않는다.

## Python 대비 차이 및 미완료

1. **Swift 보강:** 요청 시작 시각도 전송 전 재읽기 확인한다. 시작 기록 실패 시 이미 예약한 비용을 유지하되 요청은 소비하지 않는다. 세션/부팅 ID에 변경 횟수를 추가해 같은 ID로 돌아오는 경우를 차단한다. 별도 합성 세션 만료와 완료 반환 뒤 재확인도 추가했다. 합성 문맥은 설정/run과 함께 journal binding hash에 포함한다. 이 보강을 실제 토큰 유효성 검증으로 해석하지 않는다.
2. **보수적인 숫자 차이:** 미정 숫자 필드의 `1e0`과 `1.0`은 Swift에서 다른 원형으로 남아 A/B_CHANGED로 차단된다. Python의 JSON 디코딩에서는 동일한 실수 값으로 처리될 수 있다. 이번에는 검토기를 느슨하게 하거나 완전 호환으로 표시하지 않고 회귀 검사로 차이를 고정했다. 기존 계약의 revision·예산·시각 등 정수 필드는 여전히 bool/소수/지수 변환 없이 검사한다.
3. **실제 경계 미결합:** transport/시계/세션은 직렬 합성 대역이다. 실제 iOS 수신·토큰 만료 측정·SDK의 자동 refresh/redirect·streaming 취소·실제 시간 측정/계측 비용·동시성 검증은 하지 않았다. 기존 UIKit 생명주기와 실기기 파일 보호의 실제 동작도 여전히 미검증이다.
4. **journal 영속성 미완료:** 메모리 직렬화·재읽기·잠금·불확실 실패/복원 차단 검사이다. 디스크 WAL/fsync·프로세스 종료·전원 손실 영속성·과거 snapshot rollback 방어를 새로 구현한 것이 아니다. 예전 물리 adapter의 프로세스 검사로 이번 run journal의 영속성을 증명하지 않는다.
5. **기존 미검증 유지:** Windows 관찰의 누락 시각/header 52개, 특별 metadata 본문 의미, 전체 Windows contract/Unicode15 storage-name/journal 체인 동등성, 현재 서버 상태·fresh A/B·실제 baseline 입장/적용은 해결됐다고 표시하지 않는다. 보관 reader 결과를 이번 고정 합성 Expected로 변환하지 않는다.

성공 플래그는 synthetic_policy_passed/sequential_comparison_passed뿐이다. baseline_ready/applied, execution_allowed, actual app_binding_created, 편집·송신·자동 수신 허용, atomic_snapshot·현재 서버 검증·적용 순간 최신성·특별 metadata 의미·전체 엔진 동등성은 모두 false다.

## 검사·빌드 기록

- `swift-tests-01.log`: 새 코드 컴파일 및 기존 Swift 141개 통과.
- `swift-tests-02.log`: 신규 60개 포함 201개 통과.
- `swift-tests-03.log`: 합성 세션 만료/문맥 binding 검사 2개 보강, 203개 통과.
- `swift-tests-04.log`: 양수 범위 시계 역행·미정 숫자 표기 검사 2개 보강, **최종 205개 통과**.
- `python-impact-01.log`: 기존 Python **177개 통과**. Python 소스는 변경하지 않았다.
- `ios-build-01.log`, `ios-build-02.log`: 모두 unsigned generic iOS Debug 빌드 성공. 최종 소스는 두 번째 산출물이다.

이번 작업에서 컴파일/검사 실패는 없었다. xcodebuild의 CoreSimulator 초기화 경고와 AppIntents metadata 생략 경고는 보존했다. 이를 없애려고 시뮬레이터나 서비스를 실행하지 않았다. 검사 결과/횟수는 반복 시도끼리 합산하지 않는다.

## 보존·사용자가 할 일

작업 전 5,632개 파일 중 기존 격리 Xcode project 1개만 source compile 목록 변경 대상으로 구분했다. 나머지 **5,631개 SHA 대조 차이 0**이다. 새 Swift 2개·신규 검사·명세/결과만 추가했다. 기존 Package.swift/앱 UI/controller/reader/물리 저장소/Python 코드·검사·이전 unsigned 산출물·실제 Windows ZIP·비공개 전달 파일은 보존했다.

충돌·미송신 18/19바이트 원본 2개, 종료 HTTP 323/Auth 12/writes 17·만료 2026-09-13 15:00 KST·설치물·증거를 유지한다. J02/J04/J05/J07 및 UI 자동 주기의 빈 주기 차감 0 의미를 변경하지 않았다. 실제 서버 요청·로그인·서명·설치·실기기/시뮬레이터 실행·baseline 적용·관문/hold/prod 변경은 0이다. 추가 OS network-deny 검증을 수행했다고 표시하지 않는다.

결과 ZIP `build/ipad-swift-ab-offline-20260914/ipad-swift-ab-offline-result-20260914.zip`에는 소스·합성 검사·명세·로그·보존/unsigned 확인 자료를 넣는다. 실제 원고/Auth raw·이전 비공개 입력·앱 바이너리는 넣지 않는다.

**사용자는 결과 ZIP을 보관하고 Windows에는 “Swift 합성 A/B 경계 결과 접수용, 실제 조회·로그인·설치 요청 없음”으로 전달하면 된다. 지금 기기 조작이나 별도 계약 확인 회신은 필요 없다.** 실제 연결에 앞서 남은 핵심은 실행 journal의 영속화, 실제 transport/clock/session의 구체 조건, 실기기 검증 및 baseline 입장 경계이며 이번 범위에서 실행하지 않았다.
