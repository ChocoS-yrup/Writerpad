# ADR-0001: 설치 device identity 수명 주기

- 상태: 승인
- 적용 단계: 9-3
- 범위: iPad WriterPad 설치 identity

## 결정

WriterPad는 UUID 하나를 최초 필요 시 생성하고 인증 세션과 분리된 Keychain
generic-password 항목에 저장한다. 항목은
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`와 data-protection Keychain을
사용한다. iCloud Keychain 동기화 대상이 아니며 다른 기기로 이전하지 않는다.

앱 시작 시 화면과 로컬 저장소를 먼저 구성한 뒤 identity를 비동기로 준비한다.
Supabase 설정이나 로그인 여부는 identity 생성 조건이 아니다. 앱 재실행에서는
저장된 값을 복원하며 새 UUID를 만들지 않는다.

전체 UUID를 일반 로그와 사용자 메시지에 기록하지 않는다. 진단 식별이 필요하면
`DeviceIdentifier.redactedDescription`의 앞 8자리·뒤 4자리만 사용한다.

## 손상·복원·재설치

- Keychain 값이 UUID로 해석되지 않으면 손상으로 분류하고 자동 교체하지 않는다.
  자동 교체는 이미 만들어진 operation의 출처를 잃게 할 수 있기 때문이다.
- Keychain 접근 오류도 identity 없음과 구분한다. 오류가 있어도 로컬 작품
  열기·편집·저장은 계속 가능하며 서버 작업만 대기한다.
- 암호화 백업이나 새 기기 복원에서는 `ThisDeviceOnly` 항목이 이동하지 않으므로
  복원된 기기는 새 identity를 생성한다.
- 앱 삭제 후 재설치에서 운영체제가 Keychain 항목을 보존하면 같은 identity를
  사용한다. 사용자가 Keychain을 지웠거나 운영체제가 항목을 제거했다면 새
  identity를 생성한다.
- identity 강제 초기화 UI나 자동 삭제는 9-3에 추가하지 않는다. 향후 복구
  기능은 영구 queue를 먼저 검사하고 사용자 확인을 받은 뒤 별도 단계로 만든다.

## 이미 생성된 operation

operation은 생성 시점의 device identity를 자체 필드에 복사해 불변으로 보존한다.
현재 설치 identity가 나중에 달라져도 기존 operation을 삭제하거나 새 값으로
덮어쓰지 않고, 동일 operation ID와 캡처된 device identity로 재시도한다. 새
operation만 현재 identity를 사용한다.

identity 변경 전에 얻은 lease가 operation과 함께 영구 저장되지 않았다면 그
lease는 재사용하지 않는다. 현재 identity로 새 lease를 얻어야 한다. 실제 queue와
lease 연결은 각각 10단계와 11단계에서 이 규칙을 적용한다.

## 제외 범위

프로젝트 binding, `ensure_project`, operation queue 생성, RPC, Realtime, 원격
본문 변경은 이 ADR과 9-3 구현에 포함하지 않는다.
