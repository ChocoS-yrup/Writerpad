# SyntheticInitialReceive

독립 macOS 호스트용 Swift 모듈. 새 임시 합성 저장소에만 초기 자료를 적용하고 같은 입력의 재개를 검증한다. WriterPad 앱 target/설정/DB/계정/transport와 연결하지 않는다. Foundation, 시스템 CryptoKit, Darwin만 사용하며 Swift Package 외부 의존성은 없다.

## 입력과 결과

`SyntheticInput(files:)`는 `manifest.json` 및 `bodies/node-<UUID>.txt` 원래 바이트의 사전을 받는다. `load(directory:)`는 명시한 디렉터리만 읽으며 링크·예상 밖 파일/디렉터리를 거부한다. ZIP, Windows 관찰 결과, 제안 보고를 적용 입력으로 받는 변환 API는 없다.

manifest v1의 필드는 `FixtureManifest`에 정의된다. 알 수 없는/중복 키와 누락 값을 자동 보정하지 않기 위해 **이 모듈의 canonical encoder가 출력한 JSON 원래 바이트와 동일한 입력만** 받는다. sortedKeys, withoutEscapingSlashes, 마지막 LF 1개를 사용한다. nil parent는 JSONEncoder의 생략 표현이며 오직 root에서만 허용된다. 일반 JSON 문서나 Windows JSON을 다시 인코딩해 호환시키라는 뜻이 아니다.

- `kind`: `synthetic-initial-receive-v1`, `version`: 1.
- `fixtureID`, `localIdentity`, `sourceIdentity`, node ID는 각각 `fixture-`, `local-`, `source-`, `node-` 뒤에 소문자 UUID를 붙인 **합성 전용 식별자**다. 테스트는 매번 새 값을 만든다. 실제 iPad local project UUID 발급이 아니다.
- node `revision`과 order `revision`은 fixture 내부의 명시적인 양의 정수 버전 표식이다. 변경 충돌 판정이나 Windows revision/srev/epoch의 의미를 구현하지 않는다. 자동 증가·누락값 채우기는 없다.
- 기대 node/document/order-parent 집합을 완전히 대조한다. 모든 folder에는 비어 있어도 order 한 개가 필요하다. root는 folder 한 개이며 모든 node가 여기에 도달해야 한다. order children 배열의 순서를 그대로 보존한다.
- 본문은 정확한 UTF-8 byte length/SHA-256이 필요하다. LF/CRLF·Unicode 정규화 차이를 고치지 않는다. Windows 관찰의 raw 없음 상태와 구분되는 새 합성 본문이다.
- 이름·경로는 구조와 일치해야 한다. 대소문자/Unicode 정규화 충돌, 링크, hardlink, 제어문자, 경로 탈출과 예약 `.pending` 접미사를 차단한다. 최대 64 node, 입력 파일당 4 MiB, 합계 16 MiB다.

입력 digest는 모든 입력 파일에 대해 `{path, bytes, sha256}`를 만들고 path로 정렬한 배열을 canonical 인코딩한 바이트의 SHA-256이다. 원래 `manifest.json` 자체도 hash 목록에 포함된다. 결과 digest는 출력 파일 목록에 같은 규칙을 적용한다. 이 규칙은 Windows journal 재인코딩 호환 규칙이 아니다.

`SyntheticReceipt`는 출력 전용이며 `synthetic_applied=true`만 제공한다. `baseline_ready`, `baseline_applied`, `execution_allowed`, `app_binding_created`는 항상 false다. 실제 baseline 구조체로 변환하거나 편집/송신을 여는 API는 없다.

## 저장과 재개

호출자가 새로 만든 `<실제 tmp 경로>/SyntheticInitialReceive-<UUID>/`만 workspace로 허용한다. 저장 대상은 그 아래 고정 `store/`, 잠금 파일은 `store.lock`이다. 실제 tmp 경로는 POSIX realpath로 구하고 `/var`·`/tmp` 링크 별칭은 그대로 통과시키지 않는다. 앱 저장 경로를 자동으로 탐색하지 않는다.

`store/`에는 owner/journal, staging 원문, result의 본문·metadata·orders·synthetic-base, complete 표식을 둔다. root 절대 경로·합성 identity·입력/결과 digest를 처음 고정한다. 기존 파일을 채택하거나 다른 입력으로 바꾸지 않는다.

상태: bound → staged → validated → applying → syntheticApplied. 최초 journal 이전 owner만 남은 상태는 불완전한 초기화로 보존/차단한다. journal이 있는 bound 이후는 같은 입력의 존재하는 파일을 모두 대조하고 누락된 미완료 파일만 쓴다. 적용 중 파일별 진행 위치는 현재 파일 집합과 journal의 phase로 판단하며, 전체 저장소가 단일 transaction이라고 가정하지 않는다.

쓰기 전 `.pending` 파일에 기록하고 fsync한 뒤 rename한다. 이름이 남은 pending 파일은 내용이 같아도 추정 복구하지 않는다. 결과 전체와 완료 표식, 최종 phase가 맞아야 `snapshot(for:)`가 열린다. 완료 후 파일 손상·누락은 재적용으로 고치지 않는다. 자동 삭제/rollback/reset API는 없다.

flock으로 같은 root의 협조적인 호출자와 별도 호스트 프로세스를 배제한다. 소유권 없는 코드가 잠금 파일을 지우거나 디렉터리를 동시에 교체하는 적대적 파일시스템 조작의 방어 도구는 아니다. 호스트 프로세스 중단 후 재개를 검사했으며 전원 손실·실기기 파일시스템 영속성의 보장은 아니다.

모듈은 오류를 반환하고 마지막 영속 phase와 파일을 남긴다. 호스트 시험 실행기 `SyntheticReceiveProbe`는 마지막 관측 checkpoint·오류 이유를 별도 stderr JSON으로 내보낸다. 그 checkpoint는 정확한 실패 파일을 추정한 값이 아니라 마지막 관측 지점이다. 호출자가 로그를 보관하며, 오류 기록 때문에 손상 저장소를 수정하지 않는다.

## 검증과 재현

`Tests/.../AdapterTests.swift`의 fixture 생성기는 합성 ID/본문만 만든다. 정상/실패 자료는 새 임시 디렉터리에서 실행하고 테스트 teardown에서 이 임시 자료만 정리한다. 사용자 원본이나 받은 실제 관찰 ZIP은 fixture로 복제하지 않는다.

검사에는 모든 완료된 쓰기/phase checkpoint 재개, 5개 지점의 `_exit(73)` 실제 호스트 프로세스 중단, 별도 프로세스 잠금 경합과 종료, 손상 저장소의 구조화 오류 보고가 포함된다. 최초 owner만 남거나 pending 파일이 남으면 재개 성공 대신 보존/차단을 확인한다.

다음 명령은 재현 방법의 기록이며 추가 실행 지시가 아니다. 기존 호스트 Swift/XCTest만 사용하고 네트워크 의존성을 해결하거나 도구를 설치하지 않는다.

```sh
swift test --package-path OfflineAdapters/SyntheticInitialReceive \
  --scratch-path build/ipad-synthetic-initial-receive-20260914/swift-build \
  --cache-path build/ipad-synthetic-initial-receive-20260914/swift-cache \
  --disable-sandbox
python3 -B -m unittest discover -s Scripts/tests -p 'test_review*.py' -v
```

검사는 호스트 도구 컴파일·실행이다. 앱의 서명 신원/프로파일·설치·기기 실행을 준비하는 작업이 아니다. 미래 앱 내 결합, 실제 수신 계약, 서버/로그인/실제 baseline 확보·적용은 별도 범위다.
