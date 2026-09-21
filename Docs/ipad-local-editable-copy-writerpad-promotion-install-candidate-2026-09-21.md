# Receive Boundary → WriterPad 1회 승격 설치 후보 절차

작성일: 2026-09-21
상태: 오프라인 구현·합성 브리지 검증 완료, 실기기 설치 전

## 목적

Receive Boundary의 검증된 편집 사본을 사용자가 파일로 내보낸 뒤 WriterPad에서 읽기 전용 검토하고, 최종 확인 시 WriterPad의 새 local-only 작품으로 한 번만 만드는 후보를 검증한다.

이 절차는 두 앱의 기존 자료를 보존한다. 인증, 서버 조회, 송수신, 프로젝트 연결, SyncV2 작업은 실행하지 않는다.

## 현재 오프라인 판정

- 공유 합성 package: `TestFixtures/ReceivePromotionBridge.writerpadpromotion`
- 생산자 검사: 10개 통과
- WriterPad reader 경계 하네스: 8개 통과
- WriterPad transaction·복구 하네스: 기존 8개와 공유 fixture 브리지 통과
- 공유 fixture의 빈 문서, 한글, 마지막 LF가 실제 reader → 실제 transaction 뒤 byte-identical
- 같은 source-key 재실행은 새 UUID와 새 write 없이 기존 완료 결과 반환
- 검사 뒤 package 변경, 기존 작품명 충돌, 같은 source-key의 다른 fingerprint, 손상된 복구 상태는 fail closed
- WriterPad와 Receive Boundary generic 빌드 성공

전체 `WriterPadTests` bundle은 기존 `AutoSaveIsolationStore.checkpoint`와 `NormalEditorRecoveryInjection.$testConfiguration` 테스트 소스 불일치 때문에 생성 전에 중단된다. 새 promotion 소스와 전용 하네스에서는 컴파일·실행 오류가 없다.

## 설치 전 중단 조건

다음 중 하나면 설치하지 않는다.

- 두 앱 중 하나의 설치 전 app data container 백업 실패
- 백업 안의 링크 또는 읽을 수 없는 파일 발견
- 후보 앱 서명 검사 실패
- 기록한 실행 파일 SHA-256과 설치할 앱이 다름
- bundle ID가 각각 기존 앱과 다름
- Receive Boundary에 저장되지 않은 편집 초안이 남음
- WriterPad에 미완료 promotion transaction 표식이 발견됨

## 1. 설치 전 자료 보존

사용자가 Mac 터미널에서 두 앱을 각각 전체 백업한다.

1. ChoCo를 USB로 연결하고 잠금을 해제한다.
2. Receive Boundary와 WriterPad를 모두 종료한다.
3. Receive Boundary bundle ID `com.chocos.writerpad.receiveboundary`의 app data container 전체를 새 폴더에 복사한다.
4. WriterPad bundle ID `com.chocos.writerpad`의 app data container 전체를 다른 새 폴더에 복사한다.
5. 각 백업의 상대경로, byte 수, SHA-256 manifest를 만든다.
6. 다음 핵심 폴더를 별도 집계한다.
   - Receive Boundary: `ReceiveConfiguration-v1`, `ReceiveDedicated-v1`, `ReceiveEditable-v1`, `WriterPadReceiveBoundary-v1`
   - WriterPad: 기존 작품 폴더, SwiftData store와 sidecar
7. 두 백업 위치와 manifest SHA-256을 설치 기록에 적는다.

OS가 관리하는 `Library/Caches`, `Library/Saved Application State`, SplashBoard snapshot은 설치 뒤 달라질 수 있으므로 핵심 자료 보존 판정과 분리한다.

## 2. 후보 식별·서명 확인

각 앱에 대해 다음을 기록한다.

- `.app` 절대경로
- bundle ID
- 서명 검증 결과
- 실행 파일 SHA-256
- 빌드 시각

후보는 현재 소스에서 새로 빌드한 Debug-iphoneos 결과만 사용한다. 다른 DerivedData의 오래된 `.app`을 경로 검색 결과만 보고 선택하지 않는다.

## 3. 보존형 설치

1. Receive Boundary 후보를 기존 bundle ID 위에 설치한다.
2. 앱을 열지 않고 app data container를 다시 복사한다.
3. 네 핵심 폴더가 설치 전과 byte-identical인지 확인한다.
4. WriterPad 후보를 기존 bundle ID 위에 설치한다.
5. 앱을 열지 않고 WriterPad container를 다시 복사한다.
6. 기존 작품과 SwiftData store가 설치 전과 byte-identical인지 확인한다.

핵심 자료 차이가 있으면 두 앱을 열지 않고 중단한다. 화면 캐시 차이만 있으면 목록을 기록하고 다음 단계로 진행할 수 있다.

## 4. 오프라인 사용자 확인

이 단계부터 사용자가 iPad에서 직접 누른다.

### 4.1 Receive Boundary package 만들기

1. 비행기 모드를 켠다.
2. Wi-Fi와 Bluetooth가 꺼졌는지 확인한다.
3. **Receive Boundary**를 연다.
4. **보관된 인계 자료 확인**을 누른다.
5. 승격할 완료 자료에서 **기존 로컬 사본 확인**을 누른다.
6. 문서 이름, revision, 편집 본문 상태를 확인한다.
7. 저장되지 않은 초안 표시가 있으면 저장하거나 취소하고 여기서 중단한다.
8. **WriterPad 승격 package 내보내기**를 누른다.
9. 검토 창에서 source local ID, source run ID, 문서 수, package SHA-256을 기록한다.
10. **파일에 저장**을 누른다.
11. 파일 화면에서 **나의 iPad**를 누른다.
12. 검증용 새 폴더를 선택하고 **저장**을 누른다.
13. 원래 화면으로 돌아와 원본과 편집 사본이 그대로 열리는지 확인한다.

### 4.2 WriterPad 취소 경계

1. **WriterPad**를 연다.
2. 작품 목록에서 **수신 편집본 가져오기**를 누른다.
3. 앞에서 저장한 `.writerpadpromotion`을 선택한다.
4. 읽기 전용 검토 창에서 작품명, 문서 2개, revision, byte 수, package SHA-256을 확인한다.
5. **취소**를 누른다.
6. 작품 목록에 새 작품이 생기지 않았는지 확인한다.

### 4.3 이름 충돌 경계

1. 다시 **수신 편집본 가져오기**를 누르고 같은 package를 선택한다.
2. 새 작품 이름에 기존 WriterPad 작품과 완전히 같은 이름을 입력한다.
3. **로컬 작품 만들기**를 누른다.
4. 기존 작품명 충돌 문구가 표시되고 기존 작품과 package가 그대로인지 확인한다.
5. 자동 이름 변경, 병합, 덮어쓰기가 일어나면 실패로 판정한다.

### 4.4 한 번 승격

1. 같은 검토 화면에서 아직 없는 새 작품 이름을 입력한다.
2. **로컬 작품 만들기**를 한 번 누른다.
3. 완료 문구와 새 작품 이름을 확인한다.
4. 새 작품을 연다.
5. `빈문서.txt`가 빈 문서인지 확인한다.
6. `저장경계.txt`가 `한글`, 다음 줄 `마지막 LF`, 마지막 줄바꿈을 보존하는지 확인한다.
7. 서버 연결이나 송수신 표시가 생기지 않았는지 확인한다.

### 4.5 재실행·중복 차단

1. WriterPad를 사용자가 직접 종료한다.
2. WriterPad를 다시 연다.
3. 새 작품과 두 문서가 정상적으로 열리는지 확인한다.
4. 같은 package를 다시 선택하고 같은 승격을 시도한다.
5. 이미 완료된 source라는 안내가 나오고 두 번째 작품이 생기지 않는지 확인한다.

## 5. 최종 보존 판정

두 앱을 종료한 뒤 app data container를 다시 백업한다.

- Receive Boundary 네 핵심 폴더는 package 내보내기 전후 byte-identical이어야 한다.
- WriterPad의 기존 작품 파일은 모두 byte-identical이어야 한다.
- SwiftData 변화는 새 작품과 새 문서 metadata 추가 범위여야 한다.
- 새 작품에는 두 payload와 `.writerpad-receive-provenance-v1.json`만 계약한 구조로 존재해야 한다.
- `.writerpad-promotion-receipts`에는 해당 source-key 완료 영수증 하나가 있어야 한다.
- 미완료 `.writerpad-promotion-transaction-*.json`과 staging 폴더가 남으면 실패다.
- 인증·HTTP·handshake·dispatcher·SyncV2 operation은 0이어야 한다.

## 실패 시 처리

- 자동으로 반복 실행하지 않는다.
- 앱을 삭제하거나 container를 초기화하지 않는다.
- package와 양쪽 설치 전·후 백업을 유지한다.
- 화면 문구, 후보 실행 파일 SHA-256, package SHA-256, 마지막 성공 단계만 기록한다.
- 기존 작품이나 Receive Boundary 원본을 수동으로 이동·수정하지 않는다.

## 현재 실행 경계

이 문서는 설치 후보 절차만 확정한다. 작성 시점에는 기기 설치, 실제 package 내보내기, 인증, 서버 요청을 수행하지 않았다.

## 2026-09-21 실기기 중단과 수정 후보

첫 package 선택·검토·취소는 정상 동작했다. 같은 package를 다시 선택해 기존 작품명을 입력하고 실행했을 때, 원자 거래가 첫 쓰기 전에 수행하는 package 재검사에서 `패키지 구성이 계약과 다릅니다`로 중단됐다. 첫 검사 뒤 파일 선택기의 security-scoped 접근을 해제했기 때문에 provider-backed package를 두 번째로 열 수 없었던 것이 원인이다.

거래 journal·staging·작품·영수증은 package 재검사 다음에 생성되므로 이 중단으로 WriterPad 작품 자료가 기록되지는 않았다.

수정 후보는 파일 선택 직후 접근 범위를 확보해 다음 경계까지 유지한다.

- 취소: 접근 해제 후 검토 화면 닫기
- 새 package 선택: 이전 접근 해제 후 새 접근 확보
- 이름 충돌 등 재시도 가능한 오류: 접근 유지
- 승격 성공: 접근 해제 후 검토 상태 제거
- 접근 확보가 필요하지 않은 URL: stop 미호출

오프라인 검증 결과:

- security-scoped 접근의 유지·교체·해제 균형 단위 검사 추가
- 접근 확보가 `false`인 경우 stop 미호출 검사 추가
- 실제 package reader→transaction 공유 fixture와 장애 복구 하네스 전 항목 통과
- WriterPad generic iOS Simulator 앱 빌드 성공
- 전체 테스트 번들 생성은 기존 `NormalEditorRecoveryInjection.$testConfiguration`과 `AutoSaveIsolationStore.checkpoint` 테스트 소스 불일치에서 중단됐다. 이번 `ReceivePromotionPackageReaderTests.swift` 또는 `ProjectListModel.swift`의 새 컴파일 오류는 출력되지 않았다.
- 기기 재설치·재검사는 수정 후보를 새로 빌드한 뒤 별도 보존 절차로 진행

## 2026-09-21 완료 영수증 재실행 중단

보안 범위 수정본으로 이름 충돌 경계와 첫 승격은 통과했다. 사용자가 승격 작품의 폴더와 두 문서를 정상 확인한 뒤 앱을 재실행해 같은 package를 다시 선택하자 `완료 영수증과 승격된 작품이 일치하지 않습니다`로 차단됐다. 두 번째 거래의 첫 쓰기 전이므로 새 작품·거래·영수증은 추가되지 않았다.

원인은 완료 뒤에도 승격 직후의 전체 `DocumentNode`와 원본 payload 해시를 요구한 것이다. 폴더 열기는 `isExpanded`, 문서 열기는 커서 상태를 바꿀 수 있고 일반 편집은 본문 해시·수정 시각을 바꾸므로, 편집 가능한 WriterPad 작품의 정상 lifecycle과 맞지 않는다.

수정 원칙:

- 거래 중 staging·metadata·payload 검증과 미완료 거래 복구는 기존처럼 엄격히 유지
- 완료 영수증 재실행은 source-key·package fingerprint·대상 project ID를 유지
- 현재 작품명으로 project container를 다시 계산하고 canonical provenance와 저장된 SHA-256을 검증
- provenance에 매핑된 WriterPad text document ID가 현재 같은 project에 존재하는지 검증
- 작품명·본문·경로·순서·커서·폴더 펼침·수정 시각은 정상 사용자 변경으로 허용
- 대상 작품, provenance 또는 매핑된 document ID가 사라지면 계속 fail closed
- 정상 편집 뒤 재실행에서도 기존 결과만 반환하고 UUID·파일·metadata write는 0

오프라인 수정 검증 결과:

- WriterPad generic iOS Simulator 앱 빌드 성공
- 실제 reader→transaction 공유 fixture와 기존 거래·복구 검증 전 항목 통과
- 정상 본문 편집·커서 변경·폴더 펼침·작품 이름 변경 뒤 같은 package 재실행: 기존 transaction/project 반환, 새 UUID 0, 파일 write 0
- 매핑된 WriterPad document ID 누락: 계속 `completedPromotionUnavailable`로 fail closed
- 전체 테스트 번들 생성은 기존 `NormalEditorRecoveryInjection.$testConfiguration`과 `AutoSaveIsolationStore.checkpoint` 불일치에서만 중단됐으며 새 승격 테스트 컴파일 오류는 출력되지 않음

## 2026-09-21 실기기 최종 결과

### 설치 후보와 자료 보존

- Receive Boundary 실행 파일 SHA-256: `a1c2fed443202932e731a91713226b01c62d1a7364677ba102284eadd52ee42d`
- 첫 WriterPad 승격 후보 실행 파일 SHA-256: `013a6875cf7ad1522b5736b76d1cea91a7f7159f29d24752422e57fd0fcee5bb`
- 보안 범위 수정 후보 실행 파일 SHA-256: `efa6ef5a1cab13dd530ac1331342ecdb1d2f413155b8614786597c5ebcad00fd`
- 완료 영수증 수정 후보 실행 파일 SHA-256: `354296ac23e47c6d7f8ae847cac798d6211de7f87241a82112cd0024e7cb0c91`
- Receive Boundary 설치·설정 전달 뒤 `ReceiveDedicated-v1` 21개, `ReceiveEditable-v1` 3개, `WriterPadReceiveBoundary-v1` 17개 파일이 보존됐다.
- WriterPad 첫 설치 뒤 `Documents` 772개와 `Library/Application Support` 717개 파일의 SHA-256이 설치 전과 같았다.
- 보안 범위 수정본 설치 뒤 기존 핵심 파일 1,489개가 같았고, 완료 영수증 수정본 설치 뒤 현재 작품·영수증·metadata 1,494개가 같았다.

관련 기록:

- `/Users/chocos/Documents/ReceivePromotion-before.3z7g5QeJ`
- `/Users/chocos/Documents/ReceivePromotion-RB-installed.YUtmlLaH`
- `/Users/chocos/Documents/ReceivePromotion-WriterPad-installed.jMLxh28M`
- `/Users/chocos/Documents/ReceivePromotion-scopefix-installed.Pro56tBw`
- `/Users/chocos/Documents/ReceivePromotion-receiptfix-installed.yzO934l6`

### 1회 승격

- 같은 작품 이름이 있을 때 `같은 이름으로 판단되는 작품이 있습니다.`로 첫 쓰기 전에 차단됐다.
- 사용자가 작품명을 `자동수신저장 격리검증 승격 20260921`로 바꾼 뒤 승격이 완료됐다.
- WriterPad에 local-only 작품 하나와 문서 두 개가 생성됐다.
- 실제 문서 내용은 Receive Boundary의 편집 사본과 일치했다.
  - `빈문서.txt`: `오프라인 편집 사본 저장 확인 2026-09-20`
  - `저장경계.txt`: `격리 저장 경계 기준`
- 합성 fixture의 `한글`·`마지막 LF`는 오프라인 계약 검사 자료이며 실사용 승격 문서의 예상 본문으로 사용하지 않았다.

### 완료 영수증 재실행

- 작품의 폴더와 문서를 연 뒤 앱을 종료·재실행했다.
- 같은 package를 다시 선택하자 `가져오기 완료`와 `이미 완료된 로컬 작품을 확인했습니다.`가 표시됐다.
- 새 작품이나 두 번째 완료 영수증을 만들지 않고 기존 완료 작품을 반환했다.
- 최종 읽기 전용 백업 비교에서 WriterPad `Documents` 777개 파일의 경로·크기·SHA-256이 재실행 전과 같았다.
- 승격 transaction 임시 자료와 `.tmp` 자료가 남지 않았다.

최종 검증 기록:

- `/Users/chocos/Documents/ReceivePromotion-idempotent-verified.wUK52GMo`

### 최종 판정

실기기에서 package 검토, 이름 충돌 선차단, 명시적 1회 승격, 실제 편집 본문 보존, 앱 재실행 뒤 완료 영수증 확인과 중복 방지가 통과했다. 최종 재확인은 WriterPad `Documents`에 쓰기를 만들지 않았다. 이 검증 중 인증과 서버 요청은 수행하지 않았다.
