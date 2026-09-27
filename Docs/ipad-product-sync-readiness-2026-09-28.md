# 제품 동기화 준비 확인 — 2026-09-28

## 기준과 범위

- 기준 main: PR #46 병합 `eae9c7a13bbaba0536d0d0b3a19d81b2bcbc0530`.
- 브랜치: `codex/ipad-product-sync-readiness`.
- 사용자 요청에 따라 다음 승인 필요 지점까지 구현·검증한다. PR 병합, 실제 서버 작품 전환,
  배포는 별도 승인 전 실행하지 않는다.
- 신규 작품 연결과 일반 동기화 준비는 별개다. 이번 묶음은 제품 화면의 **읽기 전용 준비 확인**이다.
  LEGACY→MIGRATING→ID_BASED 실행 기능이 완성됐다고 주장하지 않는다.

## 선행 조사와 구현 경계

`createServerProject`는 ensure_project와 초기 snapshot 인계를 수행하며 모드 전환 API를 호출하지 않는다.
일반 제품 opt-in은 ID_BASED를 요구한다. 저장소에는 소유자 전환 RPC가 있지만, 전환 시작 후 구형
쓰기 제한 및 구조·문서 검증을 수반하므로 이를 단순 연결 버튼에 붙이지 않는다.
배포된 DB 함수·운영 원장을 조회한 결과가 아니라 저장소 코드에 근거한 판단이다.

- 연결된 작품에 “동기화 준비 확인 · 전송 없음”을 제공한다.
- LEGACY는 명시적 형식 전환 필요, MIGRATING은 시작 기기의 검증·완료 필요, ID_BASED는
  서버 형식 확인됨으로 표시한다. 전환 세대와 마지막 조회 시각을 함께 표시한다.
- 조회 성공은 활성화·송수신 완료·서버 전환 권한이 아니다. 활성화는 기존 별도 확인과 새 handshake를 유지한다.
- 네트워크·인증·권한·계약 호환성 실패를 준비 완료로 간주하지 않는다. 재조회 시작 시 이전 결과를 지운다.
- 제품 화면의 기존 송신 handshake 권한/캐시를 바꾸지 않도록 독립 조회 scope에서 같은 wire validator와 timeout을 사용한다.
- 기존 currentBinding은 초기 snapshot을 복구할 수 있으므로 새 읽기 전용 저장 연결 조회를 추가한다.
  기본 구현은 nil로 닫히며, 기존 정상 연결/복구 동작은 바꾸지 않는다.
- 계정·연결·작품·활동·화면 epoch가 바뀌면 늦은 결과를 버리고 이전 결과도 표시하지 않는다.
  화면 이탈·배경 전환·재로드·인증 변경은 결과를 무효화한다. 같은 작품의 조회와 활성화는 중복 시작하지 않는다.

## 변경하지 않는 사항

- 서버/공유 wire 계약/Windows 동작/교차 플랫폼 입력, schema·RLS·RPC·migration·dependency·서명 변경 없음.
- 시작·완료 전환 RPC 호출, 초기 snapshot 등록, queue retry, dispatcher 시작, opt-in 변경 없음.
- 실제 DB 조회/변경, 실기기 설치·시험, 백업·삭제·복원 없음.
- 이 읽기 전용 묶음은 Windows 회신을 요구하지 않는다. 이후 **실제 전환 실행 기능**은 구형 클라이언트
  쓰기 제한 등 실제 교차 플랫폼 영향이 있으므로 최종 head에서 필요한 검토를 별도로 판단한다.

## 검증

첫 실행은 새 테스트의 오류 타입을 생략한 한 곳에서 컴파일 실패했다. 명시적
`SyncV2HandshakeTransportError.forbidden`으로 수정했다. 실패 로그를 성공 증거로 사용하지 않는다.

- 최초 로그: `/private/tmp/writerpad-product-readiness-tests-v1.log`.
- 확장 회귀: `/private/tmp/writerpad-product-readiness-tests-v2.log`.
- 새 폴더 Release: `/private/tmp/writerpad-product-readiness-release-v1.log`,
  `/private/tmp/WriterPad-Readiness-Release.B88JUb`.
- 계약 0.2.0 verifier 재통과: 7 schemas / 12 transitions / 15 storage-name / 4 atomic-wire / 7 document-wire,
  canonical SHA-256 `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670` 불변.
- 완료된 시험 수·xcresult는 아래에 기록하고, 최종 head Release·CI·자동 검토는 PR 본문에 기록한다.

확장 회귀 결과: **626개 통과**, 실패·건너뜀 0, 컴파일 경고·오류 0, xcresult `runtimeWarnings: []`.
선택한 11개 class 결과이며 전체 suite 또는 실기기 검증으로 표현하지 않는다.
AppEnvironment 116 / BinderCommand 45 / BinderFolderSync 6 / BinderRepository 16 /
DocumentStoreRecovery 3 / DocumentStore 17 / ProjectBinding 27 / Settings 6 /
GeneralSync 73 / Handshake 170 / SnapshotPull 147.

xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.28_01-22-05-+0900.xcresult`.
기존 UIKit appearance/TextKit 콘솔 안내까지 모두 사라졌다고 주장하지 않는다.

Supabase 스킬의 changelog·인증 안전 지침을 확인했다. 사용자 편집 metadata를 권한 근거로 삼거나
클라이언트에 관리용 키를 추가하지 않으며, 기존 인증된 handshake 응답을 검증해 표시만 한다.
OpenAI Docs는 다음 단계의 모델 추천 근거로만 사용했다.
