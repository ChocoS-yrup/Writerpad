# 편집용 로컬 사본 → WriterPad 오프라인 1회 승격 계약

2026-09-21. `ReceiveEditable-v1`의 저장 완료 작업 사본을 WriterPad의 새 로컬 작품으로 옮기는 후속 범위를 정한다. 계약을 먼저 고정한 뒤 Receive Boundary의 순수 package 생산 계층, WriterPad의 읽기 전용 소비 계층과 WriterPad 내부 오프라인 승격 거래·복구 엔진까지 구현했다. 파일 선택 UI, 실제 사용자 자료 승격, 기기, 설치물, 인증, 서버는 연결하거나 실행하지 않았다.

## 결정

첫 버전은 **source run 전체를 사용자가 검토한 뒤 WriterPad의 새 로컬 작품 하나로 정확히 한 번 승격**한다.

- Receive Boundary는 검증된 불변 패키지를 사용자가 선택한 파일 위치로 내보낸다.
- WriterPad는 사용자가 선택한 패키지를 읽기 전용으로 검사한 뒤 자기 앱 컨테이너 안에서 새 작품·문서 identity를 발급한다.
- 두 앱 사이에서 앱 컨테이너를 직접 읽거나 쓰지 않는다.
- 기존 WriterPad 작품에 병합하지 않는다.
- 승격 성공만으로 로그인, 프로젝트 연결, SyncV2 operation, HTTP 요청을 만들지 않는다.
- 같은 source local ID와 source run의 두 번째 승격은 차단한다.

## 확인한 실제 저장 경계

현재 프로젝트 설정과 소스에서 다음을 확인했다.

| 항목 | Receive Boundary | WriterPad |
| --- | --- | --- |
| Bundle ID | `com.chocos.writerpad.receiveboundary` | `com.chocos.writerpad$(WRITERPAD_BUNDLE_SUFFIX)` |
| 주요 로컬 위치 | `Library/Application Support/ReceiveEditable-v1/<local>/<source-run>` | 앱 Documents 루트 아래 `<작품명>/집필모드` |
| 작업 본문 | `workspace.json` 안의 저장 완료 UTF-8 문자열 | `집필모드` 아래 개별 TXT |
| 메타데이터 | `identity.json`, `workspace.json`, save journal | SwiftData `ProjectRecord`, `DocumentRecord`와 작품 파일 트리 |
| 공유 App Group | 설정 없음 | 설정 없음 |

따라서 Receive Boundary가 WriterPad의 SwiftData나 Documents에 직접 쓰는 경로는 현재 권한 모델에 없다. Bundle ID를 같게 만들거나 App Group을 뒤늦게 추가해 기존 자료를 한 저장소처럼 다루지도 않는다. 사용자 파일 위치를 경계로 하는 생산자·소비자 방식만 허용한다.

기존 WriterPad `WindowsProjectImporter`에는 외부 폴더 검사, security-scoped 접근, 숨김 staging, 새 UUID 발급, SwiftData 일괄 등록, 정식 폴더 승격, 재실행 복구가 이미 있다. 새 승격은 이 보호 원칙과 `ProjectPathResolver`, `ProjectImportMetadataRegistering`을 재사용하되 Windows 폴더 규칙으로 패키지를 가장하지 않는 전용 importer로 둔다.

## 입력 범위

승격 후보는 다음 조건을 모두 만족하는 저장 완료 `ReceiveEditable-v1` snapshot이다.

1. 현재 보관 원본을 다시 읽어 `identity.json`과 정확히 결합된다.
2. `workspace.json`의 format, source run, 문서 수·ID·이름·base SHA-256, revision, save chain, 현재 본문 SHA-256이 모두 통과한다.
3. 열린 편집 화면에 미저장 초안이 없다.
4. 문서마다 UTF-8 바이트가 4 MiB 이하이고 전체 `workspace.json`이 기존 16 MiB 상한을 통과한다.
5. 문서 이름은 WriterPad `PathPolicy`에서도 그대로 사용할 수 있고 대소문자·Unicode NFC 기준으로 서로 충돌하지 않는다.

첫 버전은 source run에 포함된 모든 문서를 함께 승격한다. 일부 문서 선택, 기존 작품 병합, 문서 이름 자동 변경은 포함하지 않는다. 이름 충돌을 숫자 suffix로 자동 회피하지 않고 검토 단계에서 차단한다.

## 전달 패키지 v1

단일 TXT 내보내기는 provenance와 여러 문서 결합 정보를 포함하지 않으므로 승격 입력으로 사용하지 않는다. 별도 document package `*.writerpadpromotion`을 사용한다. 파일 앱에서는 하나의 문서처럼 선택하지만 내부는 다음 항목만 가진 디렉터리 package다.

```text
<name>.writerpadpromotion/
├── manifest.json
├── seal.json
└── payload/
    ├── 0001.txt
    ├── 0002.txt
    └── ...
```

### `manifest.json`

canonical UTF-8 JSON으로 다음 의미를 고정한다.

```json
{
  "format": "writerpad-receive-promotion-v1",
  "package_id": "새 UUID",
  "producer_bundle_id": "com.chocos.writerpad.receiveboundary",
  "source": {
    "local_id": "기존 local UUID",
    "run_id": "기존 source run UUID",
    "folder_name": "검증된 원본 폴더명",
    "editable_identity_sha256": "identity.json SHA-256",
    "editable_workspace_sha256": "workspace.json SHA-256"
  },
  "documents": [
    {
      "source_document_id": "기존 문서 UUID",
      "source_name": "빈문서.txt",
      "source_body_sha256": "수신 원본 본문 SHA-256",
      "editable_revision": 1,
      "editable_body_sha256": "승격할 본문 SHA-256",
      "byte_count": 0,
      "payload": "payload/0001.txt"
    }
  ]
}
```

- `documents`는 `source_document_id` 오름차순으로 고정한다.
- payload 번호는 이 정렬 순서와 일치한다.
- payload는 저장 완료 본문의 UTF-8 바이트와 정확히 같아야 한다. BOM, 줄바꿈, Unicode, 공백을 바꾸지 않는다.
- source UUID는 provenance로만 보존하며 WriterPad의 `ProjectRecord.id`나 `DocumentRecord.id`로 사용하지 않는다.
- endpoint, publishable key, 계정, 세션, 승인, 절대경로, 서버 응답은 넣지 않는다.

### `seal.json`

`seal.json`은 다음 값으로 package의 닫힌 inventory를 검증한다.

- format: `writerpad-receive-promotion-seal-v1`
- `manifest_sha256`
- 정렬된 각 payload 상대경로, byte 수, SHA-256
- manifest와 payload 목록으로 계산한 `inventory_sha256`

해시는 전송 중 손상과 구성 불일치를 탐지하는 무결성 값이다. 별도 신뢰 키가 없으므로 제3자에 대한 작성자 인증이나 전자서명으로 표현하지 않는다.

package 루트에는 `manifest.json`, `seal.json`, `payload`만, payload에는 manifest가 선언한 일반 파일만 허용한다. 심볼릭 링크, hard link, device file, 중복·정규화 충돌 이름, 절대경로, `..`, 선언되지 않은 파일은 차단한다.

## Receive Boundary 생산 단계

1. 새 lifecycle lease에서 보관 원본과 작업 사본을 다시 연다.
2. 미저장 초안 0개와 package 입력 조건을 검사한다.
3. package ID를 새로 발급하고 canonical manifest, payload, seal을 메모리 또는 앱 소유 staging에 완성한다.
4. 완성된 package 자체를 다시 읽어 inventory, 크기, 모든 SHA-256을 검증한다.
5. 화면에 source run, 작품 기본 이름, 문서 수, 각 문서명·revision·byte 수·SHA-256과 `WriterPad 새 로컬 작품용 패키지`임을 표시한다.
6. 사용자가 계속을 선택한 뒤에만 시스템 파일 내보내기를 연다.
7. 사용자가 선택한 최종 package를 다시 읽어 전체 package SHA-256 계약을 확인한다.
8. 성공·취소·재검증 실패를 구분해 표시한다.

생산은 `ReceiveDedicated-v1`, `ReceiveEditable-v1`, revision, save journal을 수정하지 않는다. package 생성은 승격 완료로 기록하지 않으며 여러 번 내보내도 WriterPad의 1회 소비 규칙은 달라지지 않는다.

## WriterPad 검사와 사용자 검토

WriterPad 작품 목록에 별도 `수신 편집본 가져오기`를 둔다. 기존 `Windows 작품 가져오기`와 혼합하지 않는다.

1. 사용자가 `*.writerpadpromotion` package 하나를 선택한다.
2. 파일 선택에서 얻은 security-scoped 접근을 검사 시작 전에 확보하고, 검토가 취소되거나 승격이 성공할 때까지 유지한다. 승격 직전 재검사는 같은 접근 범위 안에서 실행한다.
3. package 유형, exact inventory, 링크·경로 탈출, canonical JSON, manifest/seal/payload hash, UTF-8, 크기와 문서 수를 검사한다.
4. source 중복 키를 조회한다.
5. 기본 작품명은 검증된 `folder_name + " 편집본"`으로 제안하되 사용자가 새 작품명을 검토·수정한다.
6. 대상 경로를 미리 표시한다. 모든 문서는 새 작품의 `집필모드/메인/메모장/<source_name>`에 배치한다.
7. 같은 이름의 작품, 문서 이름 충돌, 기존 완료 영수증, 미완료 충돌 거래가 있으면 실행 버튼을 막는다.
8. 문서 수·이름·revision·byte 수·SHA-256, 새 작품 생성, 서버 전송 없음, 기존 작품 병합 없음이 표시된 최종 확인 뒤에만 실행한다.

검사 뒤 package의 fingerprint가 달라지면 실행하지 않고 다시 검사를 요구한다. package 자체를 수정하거나 이름을 고쳐서 자동 채택하지 않는다.

검토 중 이름 충돌처럼 다시 시도할 수 있는 오류가 나면 접근 범위를 유지한다. 사용자가 취소하거나 다른 package를 선택하면 기존 범위를 정확히 한 번 해제하고, 새 선택에 필요한 범위를 다시 확보한다. 접근 확보가 필요하지 않아 `startAccessingSecurityScopedResource()`가 `false`를 반환한 URL에는 대응하는 stop을 호출하지 않는다.

## WriterPad 원자 승격 거래

승격은 WriterPad 앱 프로세스와 자기 컨테이너 안에서만 실행한다.

1. `transaction_id`, source 중복 키, package fingerprint, 새 project ID, 새 document ID 매핑, 예상 항목 수를 불변 값으로 만든다.
2. Documents 루트에 `.writerpad-promotion-transaction-<transaction-id>.json`을 원자 기록하고 부모 디렉터리를 동기화한다.
3. `.writerpad-promotion-<transaction-id>.tmp`에 새 작품의 전체 표준 구조를 만든다.
4. payload를 `집필모드/메인/메모장`에 정확한 바이트로 기록한다.
5. 새 project ID와 모든 folder/document ID를 WriterPad가 새 UUID로 발급한다.
6. project container 루트에 `.writerpad-receive-provenance-v1.json`을 기록한다. source local/run, package ID·fingerprint, 원본 문서 ID·원본 SHA-256, 작업 revision·SHA-256, 새 WriterPad ID 매핑을 변경 불가능한 provenance로 보존한다.
7. staging 파일 트리, payload 바이트, metadata 후보, provenance 매핑을 다시 검증한다.
8. 기존 `ProjectImportMetadataRegistering`으로 ProjectRecord와 DocumentRecord를 한 번 저장한다.
9. staging 작품을 최종 작품명 폴더로 한 번에 이동하고 부모 디렉터리를 동기화한다.
10. `.writerpad-promotion-receipts/<source-key>.json` 완료 영수증을 원자 기록한다.
11. 최종 파일 트리·SwiftData·provenance·영수증을 다시 대조한 뒤 거래 표식을 제거한다.

`source-key`는 producer bundle ID, source local ID, source run ID의 canonical 결합 SHA-256이다. package ID나 편집 SHA-256이 달라져도 같은 source-key는 두 번째 새 작품을 만들 수 없다.

현재 SwiftData V1에는 provenance 필드가 없다. 첫 버전은 기존 스키마를 억지로 변경하지 않고 project container 루트의 숨김 sidecar와 완료 영수증을 사용한다. 일반 binder는 `집필모드`만 스캔하므로 provenance를 편집 문서로 표시하지 않는다.

## 중단·재실행·실패 처리

거래 표식은 최소한 `copying`, `staged`, `metadata_registered`, `promoted`, `receipt_written` 단계를 기록한다.

- 완료 영수증과 대상 project ID·불변 provenance·승격된 document ID가 일치하면 같은 요청은 현재 작품을 반환하고 write하지 않는다. 작품명, 본문, 커서, 폴더 펼침, 순서와 수정 시각은 승격 뒤 사용자가 바꿀 수 있는 상태이므로 완료 영수증의 영구 동일성 조건으로 사용하지 않는다.
- metadata 등록 전 실패는 staging과 새 거래의 임시 항목만 제거한다.
- metadata 등록 후 실패는 거래 표식에 기록한 새 project ID만 롤백한다. 기존 작품이나 다른 metadata를 이름으로 찾아 삭제하지 않는다.
- 최종 작품은 있지만 영수증이 없으면 거래 표식의 정확한 ID·fingerprint·항목 수를 검증한 경우에만 영수증 기록을 완료한다.
- 두 위치 모두 존재, package fingerprint 불일치, ID 매핑 불일치, 예상 밖 파일이 있으면 자동 병합·덮어쓰기·삭제를 하지 않고 표식과 마지막 완료 상태를 보존해 복구 필요로 보고한다.
- 재실행 복구는 동일 source-key와 package fingerprint에만 이어진다.
- 실패를 이유로 외부 package, Receive Boundary 원본·사본, 기존 WriterPad 작품을 수정하거나 삭제하지 않는다.

## 중복과 identity 규칙

- WriterPad project/document/folder UUID는 모두 새로 발급한다.
- source project/document UUID는 provenance 이외의 기본키·sync identity·operation ID로 재사용하지 않는다.
- 동일 source-key 완료 영수증은 영구 중복 차단 기준이다.
- 같은 이름의 기존 작품에 합치거나 일부 문서만 덮어쓰지 않는다.
- 완료 영수증이 손상되거나 대상 작품이 사라진 경우 자동 재승격하지 않고 진단 대상으로 둔다.
- source run 이후 작업 사본을 더 편집했더라도 이미 승격한 source-key는 다시 승격하지 않는다. 후속 변경 전달은 별도 계약으로 다룬다.

## 네트워크와 SyncV2 경계

승격 결과는 **연결되지 않은 local-only 새 작품**이다.

- 승격 importer는 `DurableLocalChangeRecording.record`, `ensureProject`, `documentSnapshot`, dispatcher, handshake, 로그인, 세션 복원, Supabase transport를 호출하지 않는다.
- `windowsImport` 또는 일반 저장 batch를 승격 완료의 부산물로 만들지 않는다.
- 앱 시작, package 검사, 승격 완료 직후 자동 프로젝트 연결을 제안하거나 시작하지 않는다.
- 이후 사용자가 WriterPad의 별도 연결 화면에서 프로젝트 연결과 최초 snapshot 범위를 검토·승인할 때만 기존 SyncV2 계약으로 진입한다.

## 보존 판정

승격 전후 다음을 각각 manifest로 기록하고 비교한다.

1. Receive Boundary의 `ReceiveDedicated-v1` 전체
2. Receive Boundary의 `ReceiveEditable-v1` 전체
3. WriterPad의 기존 작품 전체와 SwiftData store 파일
4. 새 staging·새 작품·새 metadata·새 provenance·새 영수증

1·2는 byte-identical이어야 한다. 3은 새 거래에 명시된 metadata 추가와 앱이 관리하는 실행 캐시 외에는 동일해야 한다. 기존 작품 파일은 모두 byte-identical이어야 한다. 4는 package manifest와 새 ID 매핑에 정확히 일치해야 한다.

## 구현 영향 파일

최소 구현 후보는 다음과 같다. 실제 구현 단계에서 파일명은 기존 구조에 맞춰 확정한다.

### Receive Boundary 생산자

- 새 `ReceiveEditablePromotionPackage.swift`: canonical manifest/seal/payload 생성·재검증
- `IOSBoundaryController.swift`: 준비 후보와 lifecycle 재검증
- `ReceiveBoundaryApp.swift`: 검토·fileExporter UI
- 전용 package 생성·손상·취소·보존 테스트

### WriterPad 소비자

- 새 domain model/protocol: promotion report, provenance, receipt, importer
- 새 local importer: package 검사, staging, journal, 복구, 중복 차단
- 기존 `ProjectPathResolver`, `ProjectImportMetadataRegistering` 재사용
- `AppEnvironment`, `ProjectListModel`, 작품 목록 UI에 별도 가져오기 경로 연결
- package UTI/extension 선언과 Xcode target 포함
- 전용 importer·복구·오프라인 경계 테스트

`WriterPadMetadataSchema` 변경, App Group, 기존 bundle ID 변경, Receive Boundary에서 WriterPad 파일 직접 쓰기는 첫 버전에 필요하지 않다.

## 필수 자동 검사

1. 한글·빈 문서·마지막 LF를 포함한 모든 payload가 생산 전후·소비 후 byte-identical
2. source ID와 WriterPad ID가 모두 다르고 provenance 매핑만 정확함
3. exact inventory, symlink/hard link, path escape, Unicode·대소문자 충돌 차단
4. manifest, seal, payload byte 수·hash·UTF-8 불일치 차단
5. 미저장 초안과 검사 후 package 변경 차단
6. 기존 작품명 충돌과 문서명 충돌 차단, 자동 merge·rename 없음
7. 복사·fsync·metadata 등록·move·receipt 각 실패 지점의 롤백 또는 재실행 복구
8. 같은 source-key 두 번째 실행에서 새 작품·새 ID·write 없음
9. 완료 영수증 손상, 일부 대상 존재, 다른 fingerprint 재개를 fail closed
10. 기존 WriterPad 작품과 Receive Boundary 원본·사본 전체 보존
11. 로그인·인증·HTTP·handshake·SyncV2 operation·dispatcher 호출 0
12. 승격 후 앱 재실행에서 새 작품이 정상 열리고 provenance·영수증 검증 통과

## 수동 기기 검증 순서

구현과 전체 로컬 회귀가 끝난 뒤 별도 승인을 받아 사용자가 수행한다.

1. 두 앱의 설치 전 자료를 각각 백업하고 SHA-256 manifest를 만든다.
2. 각 앱 후보의 서명과 실행 파일 SHA-256을 확인한다.
3. 기존 자료 보존형으로 두 앱을 설치한다.
4. 통신을 차단한 상태에서 Receive Boundary package를 `나의 iPad`에 한 번 내보낸다.
5. WriterPad에서 package 검사 보고서와 새 작품·문서 매핑을 확인한다.
6. 명시 승인으로 한 번 승격한다.
7. 새 작품의 빈 문서·한글·마지막 LF, 문서 수·이름·hash를 확인한다.
8. WriterPad를 종료·재실행해 복구와 중복 차단을 확인한다.
9. 양쪽 앱 자료를 다시 백업해 원본·사본·기존 작품 불변과 새 작품만 추가됐음을 대조한다.
10. 인증·서버 요청·SyncV2 operation 0을 확인한다.

## 제외 범위

- 기존 WriterPad 작품에 병합·덮어쓰기
- 일부 문서만 선택하거나 문서명을 승격 중 편집
- TXT 한 개를 provenance 없는 승격 자료로 채택
- 승격 완료 뒤 작업 사본의 후속 변경을 재전달
- App Group, bundle ID 통합, 컨테이너 직접 복사
- 자동 로그인·프로젝트 연결·송신·수신
- package 전자서명이나 제3자 작성자 인증
- 서버 project/document identity 복원

## 순수 생산자 구현 결과

계약 확정 뒤 첫 구현 범위로 Receive Boundary의 순수 package 생성기와 검증기만 추가했다.

- `ReceiveEditableCopy.promotionInput`은 기존 operation lock 안에서 작업 사본을 다시 검증하고 canonical `identity.json`·`workspace.json`의 실제 SHA-256을 읽는다.
- `ReceiveEditablePromotion.prepare`는 메모리 안에서 canonical `manifest.json`, `seal.json`, `payload/NNNN.txt`를 만든다.
- `ReceiveEditablePromotion.validate`는 exact inventory, extension, bundle·source·editable identity, canonical JSON, UUID·SHA-256 표기, byte 수·hash·UTF-8, 문서 매핑, 이름 충돌, 4 MiB 단일 문서·16 MiB 전체 제한을 fail closed로 검사한다.
- `verifyCurrent`는 package 생성 뒤 작업 사본 identity·workspace hash가 달라지면 완료를 차단한다.
- 생성기는 기존 수신 원본·작업 사본을 쓰거나 삭제하지 않는다.
- 앱 UI, 실제 파일 package 작성·내보내기, WriterPad importer·거래·영수증은 연결하지 않았다.

자동 검증 결과:

- `ReceiveEditablePromotionPackageTests`: 8개 통과
- 기존 `ReceiveEditableCopyTests` 9개와 `ReceiveEditableExportTests` 7개를 포함한 관련 검사: 24개 통과, 실패 0
- ReceiveBoundary generic iOS Debug 무서명 빌드 통과
- Xcode project plist 구조 검사 통과

검증 중 기기 설치·기기 자료 접근·앱 실행·인증·서버 요청은 수행하지 않았다.

## WriterPad 읽기 전용 소비 계층 구현 결과

다음 구현 범위로 WriterPad가 사용자가 선택할 package를 변경 없이 검사하는 순수 소비 계층과 후속 거래 인터페이스만 추가했다.

- `ReceivePromotionModels.swift`에 검증 보고서, 문서 검토값, 향후 WriterPad ID 매핑과 거래 결과를 정의했다.
- `ReceivePromotionImporting.swift`에 읽기 전용 `ReceivePromotionPackageInspecting`과 아직 구현되지 않은 WriterPad 소유 거래 경계 `ReceivePromotionTransacting`을 분리했다.
- `ReceivePromotionPackageReader.swift`는 actor 안에서 security-scoped 접근을 검사 동안만 유지하고 package를 write하지 않는다.
- package 루트와 payload의 exact inventory, canonical JSON, format·producer bundle·UUID·SHA-256 표기, 문서 정렬·payload 번호, UTF-8·byte 수·hash, 문서·전체 크기 상한을 검사한다.
- `O_NOFOLLOW`, 일반 파일 유형, hard link 수, 읽기 전후 inode·크기·수정 시각 검사를 사용해 symlink, hard link와 검사 중 파일 교체를 fail closed로 처리한다.
- `PathPolicy`로 source 폴더명·문서명·제안 작품명을 검사하고 Unicode NFC·대소문자 충돌을 차단한다.
- producer bundle, source local ID와 source run ID의 canonical 결합으로 `sourceKey`를 계산하고, manifest·payload·seal의 닫힌 목록으로 `packageFingerprint`를 계산한다.
- 검사 결과는 source UUID와 hash를 provenance 후보로만 돌려준다. 새 WriterPad project/document ID 발급, staging, SwiftData, 영수증, 기존 작품 변경은 수행하지 않는다.

추가한 전용 테스트는 정상 package, 빈 문서·한글·마지막 LF, source key와 fingerprint, 예상 밖·누락 항목, payload·manifest 변조, symlink·hard link, Unicode·대소문자 이름 충돌, 잘못된 확장자·이름을 다룬다.

검증 결과:

- 새 소비 파일들을 실제 의존 파일과 함께 Swift strict concurrency·warnings-as-errors로 직접 컴파일한 독립 하네스: 8개 경계 통과
- `WriterPad.xcodeproj/project.pbxproj`: plist 구조 검사 통과
- WriterPad 앱 타깃 컴파일 과정에서 새 소비 파일의 컴파일 오류 없음
- 전체 `WriterPadTests` 실행은 기존 `NormalEditorRecoveryInjection.$testConfiguration`, `AutoSaveIsolationStore.checkpoint` 테스트 소스 오류 때문에 테스트 번들 생성 전에 중단됐다. 이 두 오류는 이번 추가 파일 밖에 있으며 이번 단계에서 수정하지 않았다.
- 전체 앱 빌드는 종료 코드 0이었지만 Xcode가 기존 `SyncV2Store.swift`, `SyncV2SnapshotPull.swift`, `SyncV2Diagnostics.swift`, `EditLeaseManager.swift`에 `command failed with exit code 0 but produced no further output` 진단을 출력해 깨끗한 성공 판정으로 사용하지 않았다.

검증 중 WriterPad 파일 트리·SwiftData·Receive Boundary 자료를 쓰거나 읽지 않았고, 기기·앱 실행·인증·서버 요청도 수행하지 않았다.

## WriterPad 오프라인 승격 거래·복구 구현 결과

읽기 전용 검사 결과를 WriterPad가 소유한 새 local-only 작품으로 옮기는 전용 거래 엔진을 추가했다.

- `ReceivePromotionPackageReader.materialize`는 거래 시작 때 package를 다시 열어 보고서와 검증된 payload 바이트를 함께 반환한다. 최초 검사 보고서와 하나라도 다르면 첫 write 전에 차단한다.
- `ReceivePromotionTransaction`은 새 transaction/project/folder/document UUID를 발급하고, Documents 루트의 전용 거래 표식과 숨김 staging을 사용한다.
- 모든 payload를 `집필모드/메인/메모장`에 원래 UTF-8 바이트 그대로 기록하고, source identity·revision·hash와 새 WriterPad ID 매핑을 canonical provenance sidecar로 보존한다.
- SwiftData 등록, staging의 최종 작품 폴더 이동, 로컬 catalog 게시, source-key 완료 영수증을 순서대로 수행한다. 각 파일은 임시 파일 fsync·rename·부모 directory fsync 패턴을 따른다.
- 완료 영수증은 승격 직후의 전체 `DocumentNode` 목록도 복구 증거로 기록한다. 거래 진행 중 복구는 이 목록과 원본 payload를 엄격히 대조한다. 거래 완료 뒤 같은 source-key와 fingerprint를 다시 확인할 때는 대상 project ID, canonical provenance와 provenance SHA-256, 매핑된 text document ID의 존재·소속만 대조한다. 이후의 정상 편집·이름 변경·커서·폴더 펼침은 허용하면서 새 UUID나 write는 만들지 않는다.
- 같은 source-key의 다른 fingerprint, 기존 작품명 충돌, 손상된 영수증·provenance·payload·metadata, 예상 밖 메모장 파일은 자동 병합·덮어쓰기 없이 차단한다.
- metadata 등록 전 실패는 이 거래의 staging·metadata·표식만 제거한다. 롤백 전 프로젝트와 전체 노드가 표식과 정확히 일치하지 않으면 삭제하지 않고 복구 필요로 남긴다.
- 최종 작품 이동 뒤 중단은 최종 트리와 metadata가 정확할 때만 catalog·영수증 기록을 완성한다. `promoted` 이후 최종 폴더가 사라졌거나 거래 표식의 경로 결합이 손상된 경우 자동 롤백하지 않는다.
- 복구 표식의 파일명, transaction ID, 고정 staging 이름, package/source 결합과 canonical provenance를 다시 검사한다. 표식이 임의 경로를 롤백 대상으로 넓힐 수 없게 했다.
- `LocalProjectManager`의 새 게시 경계는 이미 durable한 프로젝트·폴더가 존재할 때만 local catalog에 추가한다. 이 경로에는 로그인, Supabase, SyncV2 operation, dispatcher 호출이 없다.

변경·추가한 주요 파일:

- `WriterPad/Data/Local/ReceivePromotionTransaction.swift`
- `WriterPad/Data/Local/ReceivePromotionPackageReader.swift`
- `WriterPad/Domain/Models/ReceivePromotionModels.swift`
- `WriterPad/Domain/Protocols/ReceivePromotionImporting.swift`
- `WriterPad/Data/Local/LocalProjectManager.swift`
- `WriterPad/Data/Local/SwiftDataImportRepository.swift`
- `WriterPad/Data/Local/POSIXAtomicFileWriter.swift`
- `WriterPadTests/ReceivePromotionTransactionTests.swift`

오프라인 검증 결과:

- 거래 엔진과 실제 의존 소스를 Swift strict concurrency·warnings-as-errors로 컴파일했다.
- 임시 Documents 루트와 메모리 metadata/catalog를 사용한 장애 주입 하네스 8개가 통과했다: 정상 승격·정확한 payload, 재실행 write 0, 검사 후 package 변경 선차단, staging 실패 롤백, metadata 등록 실패 롤백, move 후 영수증 복구, 손상된 move 결과 보존·차단, 같은 source-key 다른 fingerprint 차단, receipt 후 marker-only 정리.
- 읽기 전용 package 하네스 8개를 다시 컴파일·실행해 정상 package, 변조, 링크, Unicode 충돌과 확장자 차단이 모두 통과했다.
- WriterPad generic iOS Simulator 앱 빌드가 성공했다. 새 거래 엔진은 arm64·x86_64 앱 객체로 컴파일됐다.
- 새 정식 `ReceivePromotionTransactionTests.swift`도 arm64·x86_64 테스트 객체로 컴파일됐다.
- 전체 테스트 번들 생성은 기존 `NormalEditorRecoveryInjection.$testConfiguration` 및 `AutoSaveIsolationStore.checkpoint` 테스트 소스 오류로 중단됐다. 새 승격 테스트의 컴파일 오류는 없었으며, 기존 두 불일치는 이 단계에서 수정하지 않았다.
- Xcode project plist 구조 검사와 변경 파일 whitespace 검사가 통과했다.

검증은 `/private/tmp`의 합성 package·작품 루트와 메모리 저장소에서만 수행했다. 실제 WriterPad Documents·SwiftData, Receive Boundary 자료, 기기, 앱 실행, 인증, 서버 요청은 사용하지 않았다.

## 다음 승인 경계와 판정

현재 구현은 안전한 package 생산·검증, Receive Boundary 파일 내보내기 검토 UI, WriterPad 읽기 전용 파일 선택·검토 UI, WriterPad 내부 새 local-only 작품 거래·복구까지다.

이번 단계에서 **양쪽 UI 연결의 오프라인 회귀 보강과 설치 후보 절차 작성**을 완료했다. package 생산 wrapper와 WriterPad reader/transaction을 하나의 합성 fixture로 연결했고 취소·중복 이름·검사 후 변조·복구 경계를 확인했다. 실제 사용자 자료, 기기 설치, 인증, 서버 요청은 별도 승인 범위로 계속 제외한다.

현재 구조에서 안전한 WriterPad 연결은 **사용자 파일 선택을 경계로 한 별도 package handoff와 WriterPad 내부 새 작품 거래**다. Receive Boundary의 TXT 내보내기나 앱 컨테이너 직접 접근을 승격으로 간주하지 않는다.

## 2026-09-21 UI 연결 결과

- Receive Boundary는 저장되지 않은 초안이 없을 때만 `*.writerpadpromotion` directory package를 파일 화면으로 내보낸다.
- 생산 앱은 UTI `com.chocos.writerpad.receive-promotion`을 export하고 WriterPad는 같은 UTI를 import한다.
- WriterPad의 작품 목록에서 package를 고르면 읽기 전용 검사 결과, 문서별 revision·크기, package SHA-256과 새 작품 이름을 먼저 표시한다.
- 파일 선택만으로 쓰기는 시작되지 않는다. 사용자가 `로컬 작품 만들기`를 누른 뒤 package 재검사와 지문 대조가 통과해야 거래가 시작된다.
- 이 경로에는 인증, 서버 조회, 서버 작품 연결 또는 전송 호출을 주입하지 않았다.
- Receive Boundary generic iOS 빌드와 WriterPad generic iOS Simulator 빌드가 성공했다.
- Receive Boundary package 생산·wrapper 검사는 10개 모두 통과했다. 고정된 공유 fixture의 생산 바이트가 저장된 `manifest.json`, `seal.json`, payload와 정확히 일치한다.
- WriterPad package reader 경계 하네스 8개와 거래·복구 경계 하네스 8개가 통과했다. 같은 공유 fixture를 실제 reader에서 읽어 실제 transaction으로 승격한 단일 브리지 검사도 통과했으며, 빈 문서·한글·마지막 LF가 정확히 보존되고 재실행 write가 0임을 확인했다.
- 기존 작품명 충돌은 첫 staging write 전에 차단하는 정식 회귀 검사로 고정했다. 취소는 검토 sheet를 닫을 뿐 transaction을 호출하지 않는 UI 경계로 유지한다.
- 전체 `WriterPadTests` bundle은 기존 `AutoSaveIsolationStore.checkpoint`와 `NormalEditorRecoveryInjection.$testConfiguration` 테스트 소스 불일치 때문에 생성 전에 중단된다. 새 promotion 소스와 전용 하네스에는 컴파일·실행 오류가 없다.
- 실기기 후보 절차는 [Receive Boundary → WriterPad 1회 승격 설치 후보 절차](ipad-local-editable-copy-writerpad-promotion-install-candidate-2026-09-21.md)에 고정했다. 이 단계에서는 기기 설치·앱 실행·인증·서버 요청을 수행하지 않았다.

## PR #20 거래·복구 검토 후속 수정 (2026-09-21)

PR 기준 `53dd499..232283e`의 저장·복구·재확인 경로를 검토하면서 아래 세 결함을 합성 회귀 검사로 재현했다.

1. **중단 후 시각 불일치**: marker의 ISO-8601 직렬화는 소수점 초를 버리지만 최초 metadata는 `clock.now()` 원값을 저장했다. 소수점 시계를 주입하면 재실행한 복구의 exact equality가 실패했다. 새 거래의 project/node 시각을 marker와 같은 초 정밀도로 생성한다.
2. **검증 전 staging 삭제**: rollback이 metadata 일치 검사보다 먼저 staging을 지웠다. metadata가 달라 복구를 거부하는 상황에서도 임시 본문·provenance가 사라졌다. 프로젝트·노드 검증이 완료된 뒤 staging과 metadata를 제거하도록 순서를 변경했다.
3. **actor 재진입으로 진행 중 거래 삭제**: metadata 등록을 기다리는 동안 동일 서비스에 `recoverPendingPromotions()`가 들어오면 진행 중인 staging을 미완료 거래로 보고 삭제했다. 승격과 복구의 전체 async 구간에 공유 실행 플래그를 두어 동시 호출을 `operationInProgress`로 거부한다. 성공·실패 시 `defer`로 해제하며, 중복 호출은 활성 거래의 플래그를 해제하지 않는다.

정식 `ReceivePromotionTransactionTests`에 소수점 시계의 metadata 등록 후·작품 이동 후·영수증 기록 후 복구, metadata 불일치 시 디스크 바이트 보존, continuation으로 등록을 정지시킨 동시 호출 검사를 추가했다. 수정 전에는 각각 복구 실패, staging 삭제, 활성 거래 삭제가 재현됐다. 수정 후 독립 macOS XCTest 구성에서 reader 10개와 transaction 13개가 통과했다.

독립 XCTest는 실제 reader·transaction·POSIX writer·경로/도메인 소스와 정식 테스트 파일을 임시 Swift package로 묶어 실행했다. 전체 앱 의존성을 피하기 위해 외곽 저장소 protocol 및 POSIX 오류 타입의 최소 선언을 사용했고, metadata/catalog는 테스트 내 메모리 구현이다. 실제 SwiftData 영속화, iPad 다중 창 UI, 전체 앱 테스트 통과를 뜻하지 않는다. 전체 `WriterPadTests`의 기존 컴파일 제한은 유지한다.

이 수정은 앞으로 생성하는 거래의 시각 정밀도를 맞춘다. 이전 빌드에서 이미 중단된 거래 기록을 무조건 재봉인하거나 초기화하지 않는다. 같은 서비스 인스턴스의 동시 호출을 차단하며 여러 프로세스의 파일 접근을 조정하는 잠금은 아니다.

PR 커밋만 별도 디렉터리에 추출한 앱 빌드에서 `AppEnvironment`의 승격 서비스 생성 코드가 다른 생성자 인자 사이에 삽입된 오류와 `AppEnvironment`·`RootView`의 인자 순서 오류를 확인했다. 작업 폴더의 미커밋 연결부에는 이 오류가 없었지만 PR 커밋에는 남아 있었다. 생성자 경계와 인자 순서를 PR 기준으로 바로잡았다. 이전의 격리 앱 빌드 성공 보고는 `232283e` 자체의 빌드 성공 근거로 사용하지 않는다.

후속 수정 후보를 `232283e` 추출본에 적용한 뒤 WriterPad Debug / generic iOS Simulator / `CODE_SIGNING_ALLOWED=NO` 앱 빌드가 종료 코드 0으로 완료됐다. 기존 deprecated/concurrency 경고는 남아 있다. 이 검증에서 실기기 설치·앱 실행·인증·서버 요청은 하지 않았다.

## PR #20 패키지·완료 영수증 보호 검토 (2026-09-21)

`35f2d80` 기준으로 패키지 입력과 완료 영수증 조회를 검토했다. 영수증 파일 또는 영수증 폴더가 끊어진 심볼릭 링크이면 `fileExists`가 false를 반환해 신규 source로 처리했다. 합성 회귀 검사에서 파일 링크는 두 번째 작품 생성과 영수증 덮어쓰기를, 폴더 링크는 두 번째 작품 생성 후 복구 필요 상태를 재현했다.

영수증 폴더와 파일을 `lstat`으로 확인하고 실제 ENOENT만 미존재로 인정하도록 수정했다. 링크·잘못된 폴더 유형·다른 조회 오류는 기록을 보존한 채 `recoveryRequired`로 차단한다. 회귀 검사는 UUID 발급·작품 수·디스크 바이트가 그대로이고 끊어진 링크도 보존되는지 확인한다.

패키지와 거래 파일의 `open`에는 `O_NONBLOCK`을 추가했다. FIFO처럼 작성자를 기다리는 특수 파일도 `fstat`의 일반 파일 검사까지 즉시 도달해 거부하도록 한다. 거래 파일은 읽는 도중 커져도 20 MiB 상한을 넘겨 메모리에 계속 적재하지 않는다. manifest·seal·payload 및 완료 영수증 FIFO 거부를 검사했다.

독립 macOS XCTest에서 reader 14개와 transaction 15개, 총 29개가 통과했다. 새 검사는 해시가 일치하는 잘못된 UTF-8, seal inventory 불일치, 알려지지 않은 manifest 필드, payload 경로 탈출을 포함한다. 기존 정상 편집·작품명 변경 후 영수증 재확인, source가 같고 fingerprint가 다른 패키지 차단, 중단 복구 검사도 유지했다. 이 결과는 전체 앱 테스트나 실제 기기 검증을 뜻하지 않으며 앞 절의 독립 테스트 제한이 그대로 적용된다.

`35f2d80` 추출본에 이번 수정만 적용한 WriterPad Debug / generic iOS Simulator / 서명 비활성 앱 빌드도 종료 코드 0으로 완료했다. 기존 컴파일 경고는 남아 있으며 실기기 설치·앱 실행·인증·서버 요청은 수행하지 않았다.
