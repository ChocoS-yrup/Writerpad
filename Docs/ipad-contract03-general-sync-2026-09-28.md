# iPad 일반 동기화의 명시적 계약 0.3 지원

## 범위와 보존 항목

Windows 통합 PR #11의 검토 대상은 `95252c08df654563179d88a0afb1d3cea4793eb4`다.
서버/iPad PR #50의 전환 전용 구현 `e62b9ab` 위에 일반 경로를 추가한다.
Windows의 Python 3.14.7, 계약 0.3, storage-name-v2 구현은 변경하지 않는다.

- 기존 iPad 0.2 pin `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670` 및 기본값 보존.
- 명시적 0.3 pin `abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c` 추가 선택.
- protocol 3, client/server capability 각각 8개. 0.3은 `storage_name_v2`를 요구한다.
- 기존 protocol/lock/전환 v1·v2 확장 파일, 배포 migration은 변경하지 않는다.
- PR #50 전환 SQL도 이번 후속에서는 불변이며 SHA-256은
  `9c6aaff2ee39bd25f162dcba86392c6b9779df3c2e0e71262aa4d65cb6ece323`이다.

## 제품 동작

설정에서 전체·작품별 동기화를 끈 뒤 해당 작품의 계약을 선택한다. 선택은 로컬 설정만
변경하며 관문을 닫고 이전 열기 시도를 무효화한다. 새 계약을 선택했다고 서버 작품을
repin하거나 allowlist를 활성화하지 않는다. 준비 확인 및 별도 관문 열기는 선택한 계약의
version·양쪽 hash·protocol·capability가 정확히 맞는 새 handshake를 요구한다.
전환 완료 화면도 이 절차를 안내하며 일반 동기화를 직접 켜지 않는다.

handshake 문맥에는 선택한 해시가 포함된다. 수신 기준선 권한과 송신·재개·충돌 복구 역시
같은 문맥을 사용하므로 다른 계약에서 얻은 기준선을 재사용하지 않는다.

일반 대기열은 enqueue 당시의 검증된 계약 버전·해시를 저장한다. materialize, 단계 분할,
재시작 후 replay/receipt recovery, 충돌 대체 요청은 이 pin을 유지한다. 사용자가 선택을
바꿔도 이전 대기열의 JSON·batch ID·operation ID·pin을 재작성하지 않는다. 다른 계약의
요청은 전송하지 않고 보존한다. 미송신 source의 충돌 복구도 SQLite에 저장된 pin과 비교한다.

storage-name-v2는 기존 v1과 분리되어 있다. frozen Unicode 14 assigned baseline → exclusion →
supplementary/CCC adjacency 검사 → NFKC → frozen Unicode 15 casefold → NFKC → separator/control
검사 → baseline 재검사 → trailing dot/space 제거 → 예약 이름 검사의 순서를 지킨다.
assigned/exclusion/CCC 표는 고정 해시를 검증한 생성기로 만들며, exact-head Linux/Windows CI가
생성 결과를 다시 확인한다. host Unicode의 assigned/CCC 판정에 의존하지 않는다.

## 검증 상태

최종 Debug test build 및 네트워크 차단 iPad 시뮬레이터 **633개 성공, 실패 0**.
설정 6, 계약 49, 폴더 로컬 E2E 17, 일반 대기열·복구 78, handshake·송신 175,
전환 22, snapshot pull 147, SQLite store 139개다. 폴더 E2E는 합성 로컬 fixture이며
실제 Windows–iPad 교차 장치 시험이 아니다.

- 공개 storage-name-v2 벡터 29개 및 v1 동작 보존·동결 표·오류 우선순위 확인.
- 본문/구조 0.3 송신, compound 작업의 단계 분할 및 재시작/receipt 복구 확인.
- 본문·순서·이름·복합 구조 충돌 대체 요청의 0.3 유지 확인.
- 0.2 대기열을 0.3 handshake로 재등록해도 pin 불변, 잘못된 계약 송신·대체 거부 확인.
- 잘못된 이름은 source를 보존하고 materialization 차단. 잘못된 해시·capability·로컬 선택 값은 거부.
- 계약 선택만으로 네트워크 쓰기나 일반 동기화를 켜지 않으며, 새 0.3 handshake 후 명시적 열기 확인.
- 두 계약의 수신 기준선 권한 분리 및 기존 수신·SQLite·0.2 회귀 확인.
- frozen assigned/exclusion/CCC 생성물 및 기존 Swift casefold 실제 packed bytes를 계약 자산과 대조.
- `verify_stage7_server.py`와 `git diff --check` 성공. SQL runtime은 PR의 폐기형 DB CI에서 확인한다.

최종 로그: `/private/tmp/writerpad-general03-verified-build.log`,
`/private/tmp/writerpad-general03-verified-tests.log`.
xcresult: `build/TransitionDerivedData/Logs/Test/Test-WriterPad-2026.09.28_17-06-00-+0900.xcresult`.
첫 확대 실행의 두 실패는 시험 보조 데이터의 이전 0.2 문맥과 이전 UI 문구 기대값이었다.
수정 후 재실행했으며 제품 검사를 완화하지 않았다. 그 실패 실행의 Xcode 결과 수집은
대기 상태가 되어 해당 프로세스만 종료했고 원래 로그는 보존했다. 최종 실행은 정상 종료했다.

## 아직 하지 않은 작업과 승인 경계

병합, 배포, live DB 조회·변경, allowlist 활성화, 실제 작품 전환은 하지 않았다.
실제 작품 전환은 사용자 지시대로 생략한다. 이번 변경의 Release 빌드, 실기기 시험,
Windows 실앱과 iPad의 실제 서버를 통한 다기기 E2E도 아직 수행하지 않았다.
격리 fixture와 CI는 이 시험을 대신하지 않는다.

다음 검토는 양쪽 exact head를 고정한 Windows 읽기 전용 호환성 재검토다. 그 결과를 받은 뒤
PR 병합은 별도 사용자 승인이다. DB 적용과 allowlist 활성화 역시 각각 별도 승인 대상으로
남기며, 배포한다면 누적 `db push`가 아니라 검증된 신규 migration 1개 exact bundle만 사용한다.
