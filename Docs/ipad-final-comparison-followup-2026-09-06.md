# Windows 최종 대조에 대한 iPad 추가 회신

후속 구현·최종 검증은 [C9 및 복구 진단 보완 결과](ipad-c9-and-recovery-implementation-2026-09-06.md)를 참조한다. 이 문서는 수정 전 bb40d22 검토 기록이다.

검토일: 2026-09-06 KST. 기준 제품 코드: `bb40d22164f34371f9ad7f70b9cddf208a692f83`.
Windows 기준은 제공된 회신의 `a3eaa8b97dc9769ad313ac3fe579d0b1443849a9`다.
Windows 재현을 이 환경에서 다시 실행한 것은 아니다.

**결론: C4 엄격성 제안에 동의한다. C9는 추가 보완이 필요하며 전체 일치로
승격하지 않는다. 실제 계약 시험은 보류한다.** 이번 작업은 코드 검토와 격리된
모의 시험, 문서 정정이다. 제품 코드 수정·실기기 재설치·커밋·푸시·서버 쓰기를
하지 않았다. 실제 관문도 조작하지 않았다.

## 1. C4 정책 회신

- `project_id`는 필수 UUID이며 요청 작품과 일치해야 한다.
- protocol 목록은 비어 있지 않은 양의 정수 목록이며 중복이 없어야 한다.
- capability 목록은 중복·빈 문자열을 허용하지 않으며 필수 항목을 포함해야 한다.
- version `0.2.0`, canonical/server digest 일치, protocol `3` 지원 검사는 유지한다.
- iPad 검사를 완화하지 않는다. Windows 수정 완료 여부는 후속 증거로 판정한다.

근거: `WriterPad/Sync/SyncV2Handshake.swift:43` 필수 응답 필드,
`:244` version 검사, `:248` 목록 검증.
기존 `testDuplicateCapabilitiesAreMalformed`, `testProtocolVersionDecisionTable`,
`testWrongContractVersionIsRejectedEvenWithCorrectDigest` 등도 관련 근거다.
모든 비정상 입력이 각각 별도 시험으로 존재한다는 의미는 아니다.

`sync-contract/handshake-envelope.md`의 필수 3개 필드 누락에 관한 Windows
수정 전 설명을 정정했다. 정규 계약 파일·lock·digest·pin은 변경하지 않았다.

## 2. C9 구조 기준과 작품 상태

### 코드로 확인한 범위

- `SyncV2ContractStructure.swift:308` sender는 gate/auth/binding/handshake/scene/
  global-sync 수명을 검사하지만 구조 승인 상태나 작품 활성 상태를 받지 않는다.
- `SyncV2Dispatcher.swift:774`의 `beginUploadDrain`은 실행 중인 pull/upload만
  확인한다. `lastPullSucceeded`, queue의 blocked/conflict를 승인 조건으로
  확인하지 않고 phase를 `drainingUpload`로 바꾼다.
- `SyncSettingsView.swift:577`의 작품 목록은 로컬 `isActive`로 필터링하지만,
  `:214`의 비동기 수동 전송부터 실제 transport 예약까지 활성 상태를 다시
  확인하는 근거가 되지 않는다.
- `SupabaseProjectBindingService.swift:11`의 binding에는 서버 작품 활성 상태가
  없다. 따라서 계정·binding 세대 검사만으로 서버 작품 비활성 변경을 감지한다고
  설명할 수 없다. 실제 서버 비활성 전이를 주입한 종단간 시험은 미검증이다.

### 격리된 재현

검토용 시험 결과는 별도 evidence JSON과 patch에 기록한다. 이 시험은 제품의
안전 요구 통과 시험이 아니라 현재 누락 동작을 측정하는 재현이다. 실제 제품
sender/coordinator와 임시 UserDefaults, 모의 queue/transport를 사용하며 서버에
접속하지 않는다. 원본 테스트 파일은 실행 후 복원한다.

| 주입 조건 | 모의 전송 횟수 | 판정 |
|---|---:|---|
| 새 coordinator, `lastPullSucceeded=false` | 1 | 이 값이 전송 승인 조건이 아님을 확인 |
| claim 중 blocked=1 / conflict=1 | 각 1 | 차단 검사 누락 재현 |
| transport 예약 직전 blocked=1 / conflict=1 | 각 1 | 차단 검사 누락 재현 |

네 차단/충돌 조건에서 저장 요청은 그대로 보존됐다. 요구하는 전송 0회 조건은
충족하지 못했으므로 C9 보완이 필요하다.

실행: `Scripts/run_tests.sh SyncV2HandshakeTests`, 09:25:41–09:26:58 KST,
iPad Pro 13-inch (M5) Simulator 26.5. **51개 통과 / 실패 0 / 건너뜀 0**:
기존 49개와 현상 재현용 2개다. 2개 재현 시험은 현재의 전송 1회를 기대하도록
작성했으므로 이 통과 수치를 안전성 통과로 보고하지 않는다. 전체 946개 시험을
이번에 다시 실행한 것은 아니다.

- 결과: [재현 결과 JSON](evidence/ipad-c9-review-results-2026-09-06.json)
- 재현 코드: [임시 시험 patch](evidence/ipad-c9-review-probes-2026-09-06.patch)
- 원본 결과 번들: `build/TestDerivedData/Logs/Test/Test-WriterPad-2026.09.06_09-25-41-+0900.xcresult`

동일 제품 commit에서 patch를 적용해 위 명령으로 재현할 수 있다. patch는 제품
수정안이나 상시 안전성 회귀 시험이 아니다. 실행 후 원본 테스트 파일이 HEAD와
일치하도록 복원했으며 제품 Swift 소스와 상시 테스트에는 변경이 없다.

집계 queue 상태를 주입하는 시험이므로 실제 폴더 충돌 발생·서버 작품 비활성·
서버 적용을 재현한 것은 아니다. 이는 coordinator를 구조 전송 승인 근거로
간주할 수 없음을 확인하기 위한 범위다.

### 보완 방향

`lastPullSucceeded`를 그대로 전송 조건에 추가하는 수정은 피한다.
`SyncV2Dispatcher.swift:738`의 로컬 enqueue도 이 값을 false로 바꾸므로 정상
로컬 저장이 스스로 전송을 막을 수 있다. 구조 기준의 확인 여부와 서버 동기화
완료 표시는 별도 상태로 다뤄야 한다.

다음 구현에서는 작품별 구조 승인 상태(모름/허용/차단)와 확인된 작품 활성
상태의 수명을 명시하고, 실제 상태 생산 경로를 연결해야 한다. enqueue/claim/
예약의 await 중 상태가 바뀌면 아직 시작하지 않은 계약 RPC는 0회여야 한다.
이미 시작한 요청의 유효한 영수증은 원래 저장소에 반영한다. 원고 집필과 기존
동기화는 이 계약 전용 차단 때문에 불필요하게 멈추지 않아야 한다.

다른 기기가 바꾼 서버 상태를 클라이언트가 아직 관측하지 못한 경우까지 로컬
세대 검사만으로 보장할 수는 없다. 알려진 상태 변경의 로컬 차단과 실제 쓰기
시점의 서버 검사를 구분해 시험해야 한다. 배포 서버의 활성 상태 정책은 별도
읽기 확인 대상이며 이번에 추측해서 추가하지 않았다.

## 3. 30초~2분 지연 시각 요청

제공 가능한 사실은 사용자 관측인 **4회 중 1회 지연, 이후 자동 복구,
재실행 후 시험 원고 모두 보존**이다. 해당 회차의 통신 복구/인증/handshake/
pull/배출/UI 시각과 전경·배경 전환 시각은 확보하지 못했다. 따라서 시각표를
만들거나 원인을 특정할 수 없다. 이번에 기기 과거 로그를 추출하지 않았다.

현재 `SyncV2Handshake.swift:532`는 무효화 세대를 기록하지만 `:638` 자동 재조회
루프에는 요청 시작·응답·재시도 예약·실제 슬롯 대기의 전 과정을 연결하는
진단 기록이 없다. 기존 pull/UI 로그만으로 위 일곱 단계를 모두 증명할 수 없다.
또한 Realtime 연결 상태와 마지막 pull 결과는 독립 축이므로 원고 반영 이후에도
재연결 표시가 남을 수 있다. 이번 지연의 실제 원인이 그것이었다고 확정하지 않는다.

다음 진단 보완은 통신 복구 → 인증 준비 → handshake 시작/응답 → 기준 pull 완료
→ 일반 대기 작업 처리 → 상태 표시의 시각을 기록한다. 각각의 비동기 흐름은
겹치거나 순서가 달라질 수 있으므로 강제 직렬 단계로 해석하지 않는다. 재시도
번호·예정 시각·슬롯 대기 사유·전경/배경도 함께 남긴다. 계약 관문이 닫힌 시험의
일반 원고 배출은 계약 배치 처리와 구분한다. 이메일·토큰·원고 본문·경로는 제외한다.

사용자에게 같은 시험을 반복 요청하기 전에 이 진단을 준비한다. 과거 1회
지연을 계약 쓰기 성공이나 현재 결함으로 확대 해석하지 않는다.

## 4. 최초 계약 시험 범위와 빌드 식별

- iPad 지원 범위: 새 폴더 1개 + 해당 부모의 tree_order 1개.
- 전송 방식: Debug 설정 화면에서 수동 1배치. 자동 계약 배출은 구현 범위 밖이다.
- 부모/순서 기준 revision이 필요하다. 원고 document_commit 및 이름 변경·이동·
  삭제·복원·복합 구조 변경을 이 시험에 포함하지 않는다.
- 실제 시험은 양쪽 보완 이후 별도 staging 시험 작품·지정 batch를 확정하고
  새 handshake 및 서버 상태 읽기 확인 후 진행한다. 현재는 관문을 열지 않는다.

이전 설치 작업에서 사용한 코드/앱:

| 항목 | 식별자 |
|---|---|
| 소스 commit | `bb40d22164f34371f9ad7f70b9cddf208a692f83` |
| 구성 / bundle | Debug / `com.chocos.writerpad.debug` |
| 버전 / build | `0.1.0` / `1` |
| 이전 설치·실행 기록 | 2026-09-06 08:29 KST, ChoCo iPad Pro 11-inch M4 |
| 보관된 WriterPad 실행 바이너리 SHA-256 | `f7b6e1a60e8cc83586bf67d1cb5136ef5604a52aa08fb534c2d16031121befde` |

SHA는 이번에 `build/DeviceDerivedData/Build/Products/Debug-iphoneos/WriterPad.app/WriterPad`
파일을 읽어 계산했다. 이번에 설치된 기기의 바이너리를 추출하여 다시 대조한
것은 아니다. build 번호 1만으로 소스를 식별하지 않는다. 향후 C9 보완 뒤
시험할 빌드는 새 commit과 바이너리 SHA로 다시 고정해야 한다.

## 5. 다음 작업 분담

1. Windows: R1 HTTP 상태 보존/실제 SDK 변환 회귀, R2 구조 승인 최종 검사,
   C4 엄격성 보완. 현재 AI·집필모드 미커밋 작업은 보존한다.
2. iPad: C9 구조 승인/작품 상태 수명 연결과 경계별 0회 회귀 시험, 복구 진단
   시각 보완. 이번 검토에서는 제품 수정이 완료되지 않았다.
3. 양쪽 수정 commit·시험 결과·빌드를 고정해 다시 대조한다.
4. 관문이 닫힌 검사부터 완료한 뒤 staging의 작은 폴더 계약 시험을 준비한다.
   prod 이전은 후속 단계다.

Windows에는 이 문서를 C4 동의 및 C9 추가 확인 회신으로 전달할 수 있다.
전체 C1–C12 일치 또는 실제 계약 전송 성공 회신으로 사용하지 않는다.
