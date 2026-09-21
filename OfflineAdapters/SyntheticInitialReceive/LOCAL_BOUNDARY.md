# 앱 결합 전 로컬 경계 — 합성 대역 구현

`LocalBoundary.swift`는 앱 결합 전 의존성·저장소·완료 상태의 계약을 구현한다. 앱 target, 실제 저장소 구현, 실제 수신 계약 검증기는 추가하지 않는다. 기존 `SyntheticAdapter` 및 입력 형식은 변경하지 않는다.

## 진입과 의존성

`LocalBoundary.prepare(context:input:makeStorage:)`만 session을 생성한다. session의 직접 initializer는 외부에 공개하지 않는다.

1. 선언된 bundle 문자열, 입력 종류, 합성 local identity, POSIX 실제 tmp namespace를 확인한다.
2. 관찰·제안은 `unsupportedInput`, 실제 수신 후보는 `realContractUnresolved`로 차단한다. 실제 revision/srev/epoch 필드를 합성 필드로 바꾸는 경로가 없다.
3. `store` 경로의 링크를 거부하고 **실제 디스크 저장소가 이미 존재하면 연결하지 않는다**. 이 단계는 메모리 저장 대역 전용이다. 이전 합성 파일 adapter가 만든 저장소에도 연결하지 않는다.
4. 검증한 bundle/root/fixture/local/source identity 및 입력·결과 digest를 고정한 후 저장소 대역 팩토리 한 개만 호출한다. 네트워크·계정·일반 DB·송신 job 팩토리는 인터페이스에 없다.

bundle 값은 시험에서 전달한 기대 문자열 대조다. 실제 iOS bundle·프로파일·entitlements를 확인한 결과가 아니다. root 검사는 기존 임시 경로 보호 조건을 재사용하며 이를 앱 컨테이너까지 확대하지 않는다. 임시 workspace는 호출자가 시험용으로 만들어 준다.

## 저장소 계약과 상태

`LocalBoundaryStorage`는 배타 실행, 읽기, 최초 결합, phase, 다섯 payload 기록, 완료 digest 기록을 모두 구현해야 한다. 아무 작업 없이 성공하는 기본 구현은 없다. 이번 실제 구현체는 `LocalBoundaryTests.FakeStorage`뿐이며 메모리 안에서 동작한다.

다섯 payload는 bodies, metadata, documentBaseline, folderBaseline, treeOrderBaseline이다. bodies는 정확한 `Data`를 base64 JSON으로 표현해 개행·Unicode 바이트를 유지한다. 나머지는 합성 node/body/정렬의 타입별 JSON이다. 이름이 비슷해도 **실제 TXT/SQLite 테이블·baseline·Windows job 형식이 아니다**.

결과 digest는 payload마다 `{path: part 이름, bytes, sha256}`를 만들고 part 이름으로 정렬한 배열의 기존 합성 canonical encoding/SHA-256이다. 관찰 journal 체인 인코딩 호환과 무관하다.

상태는 미결합 → bound → applying → syntheticReady다. 이미 검증된 `SyntheticInput`만 받으므로 원문 staging은 기존 파일 adapter의 역할로 남기며 이 메모리 저장 대역에서 중복 구현하지 않는다.

- 최초 결합은 보호 상태가 명시적으로 깨끗하고, binding/phase/parts/완료 표식이 모두 없는 대역에만 허용한다. 초안 여부나 예상 밖 데이터 여부를 알 수 없으면 차단한다.
- 각 변경 후 binding·phase·모든 기존 payload·완료 표식을 다시 읽어 기대값과 정확히 대조한다. 저장 함수의 성공 반환만 믿지 않는다. 다른 부분이 함께 바뀌거나 기록이 빠지면 차단한다.
- 다섯 payload가 모두 있어야 완료 digest를 기록하고, 최종 phase를 읽어 확인해야 합성 준비 완료를 반환한다. 본문만 성공하거나 완료 표식만 있는 상태는 준비 완료가 아니다.
- 같은 입력/소유권의 applying 상태는 기존 payload가 일치하는 경우만 누락 부분을 재개한다. 완료 후 누락·변조, 소유권 변경, 손실된 phase는 자동 복구/초기화하지 않는다.
- 새 초안/보호 데이터가 나타나면 재개와 읽기를 차단하고 자료를 보존한다. 실제 draft의 저장/해제 API는 없다. J04의 오류 해제 조건을 바꾸지 않는다.
- 모든 apply/snapshot 호출은 동일 저장소의 배타 접근 안에서 다시 검사한다. 준비 상태를 session에 캐시하지 않는다. 배타 실행 구현이 콜백을 생략하거나 중간 오류를 삼켜도 성공으로 끝내지 않는다.

`synthetic_boundary_ready=true`만 반환할 수 있다. baseline_ready/applied, execution_allowed, app_binding_created, editing_allowed, sending_allowed, automatic_receive_allowed는 항상 false다. 합성 완료로 UI·송신·자동 수신 권한을 열지 않는다.

## 검사와 남은 범위

신규 검사는 잘못된 bundle/identity/경로/입력의 팩토리 이전 차단, 기존 물리 저장소 보존, 다섯 payload·본문 바이트/정렬 보존, 단계별 쓰기 전후 실패·새 session 재개, 무동작 저장 구현 차단, 미확인 보호 상태/새 초안, 변조/누락, 같은 대역의 동시 접근을 확인한다.

새 session 재개는 **같은 메모리 대역을 다시 주입한 모델 검사**다. 실제 DB 영속화나 프로세스 재시작 복구를 구현한 것이 아니다. 기존 파일 adapter의 호스트 프로세스 중단 검사는 이번에 영향 검사로 재실행했으며 이 메모리 대역의 영속성 증거로 이관하지 않는다.

앞으로 실제 앱 저장소 구현을 연결할 때는 각 물리 저장소의 정확한 결합·쓰기/읽기·잠금·영속화가 이 계약을 충족하는지 별도 확인해야 한다. 저장 대역의 보고가 실제 물리 저장소를 정직하게 반영하는지를 이 조정 모듈만으로 증명할 수는 없다. iOS 연결, 실제 local project 발급, 실제 수신 wire 계약/검증과 baseline 적용은 미완료다.

기존 Windows 관찰의 raw/handshake 의미, 체인 재인코딩, 후보 profile, 최신성 및 과거 합성 reference 미검증은 유지한다. 해당 자료를 이 구현에 적용하지 않았다.
