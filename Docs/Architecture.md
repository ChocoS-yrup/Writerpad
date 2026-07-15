# 목표 아키텍처 — 로컬 1~7단계

## 설계 목표

WriterPad는 iPad에서 인터넷 없이 집필할 수 있는 로컬 우선 앱이다. 원고 본문은 UTF-8 TXT가 단일 원본이고 SwiftData는 UUID, 경로, 정렬, 화면 상태 같은 메타데이터만 보관한다. 화면은 저장 구현을 직접 호출하지 않고 도메인 서비스와 저장소 경계를 통해 작업한다.

## 계층

```mermaid
flowchart TD
    UI["SwiftUI Features"] --> VM["View Models / Coordinators"]
    VM --> DOMAIN["Domain Models · Rules · Protocols"]
    VM --> DATA["Local Repositories"]
    DATA --> FILES["UTF-8 TXT · Backup · Trash"]
    DATA --> META["SwiftData Metadata"]
    EDITOR["UIKit UITextView · TextKit"] --> VM
    EDITOR --> RULES["TextRuleEngine"]
    FUTURE["Future Sync Adapter"] -. "protocol only" .-> DOMAIN
```

의존 방향은 위에서 아래로만 흐른다. Domain은 SwiftUI, UIKit, SwiftData, 파일 시스템, Supabase를 import하지 않는다.

## 단일 원본과 저장 흐름

1. 편집기가 현재 텍스트 스냅샷과 generation을 저장 coordinator에 전달한다.
2. `LocalDocumentStore` actor가 동일 문서 저장을 직렬화한다.
3. 같은 디렉터리에 고유 임시 파일을 쓴다.
4. UTF-8 바이트 쓰기와 가능한 flush를 마친 뒤 원본을 안전하게 교체한다.
5. 성공한 바이트에서 SHA-256을 계산한다.
6. SwiftData의 경로·해시·수정 시각을 갱신한다.
7. 필요하면 백업 사건을 요청한다.
8. 향후 동기화 adapter에는 사건을 전달할 수 있지만 1~7단계에서는 no-op이다.

SwiftData 갱신에 실패하더라도 TXT 원고를 되돌려 잃게 만들지 않는다. 원고 교체 전에 저장한 재조정 표식과 실제 TXT SHA-256가 일치할 때만 다음 실행에서 메타데이터를 반영한다.

## 작품 관리 흐름

`ProjectListModel`은 `ProjectManaging`만 호출하고 파일 시스템과 SwiftData를 직접 수정하지 않는다. `LocalProjectManager` actor가 작품 생성·이름 변경을 직렬화하며, 숨김 임시 폴더와 단계별 저널로 파일 이동과 SwiftData 갱신 사이의 중단을 복구한다. SwiftData V1은 작품 정체성과 이름을, 원자적 로컬 카탈로그는 사용자 순서와 삭제 대기 상태를 담당한다.

삭제 확인은 파일 제거가 아니라 `deletionRequested` 상태 전이다. 실제 `메인/휴지통` 이동이나 영구 삭제는 6단계 정책이 이 상태를 소비할 때 수행한다.

## Windows 작품 가져오기 흐름

`ProjectListModel`은 폴더 선택 URL을 `ProjectImporting`에 전달할 뿐 파일을 직접 읽지 않는다. `WindowsProjectImporter` actor가 security-scoped resource 접근을 작업 범위에 맞춰 열고 닫으며, 읽기 전용 전체 검사와 쓰기 거래를 분리한다.

검사 보고서는 UTF-8, 구조, 중복 화, 이름 규칙, 접근 오류와 레거시 자료를 분류한다. 사용자가 경고를 확인하면 앱 내부 숨김 임시 프로젝트로 전체 트리를 복사하고, `SwiftDataMetadataRepository`가 작품과 문서 UUID·해시를 한 번에 등록한다. 이후에만 정식 작품 경로로 승격한다. 단계 표식은 앱 중단 후 완료 여부를 판정하며 불완전한 복사본과 메타데이터는 함께 롤백한다. 원본 폴더에는 어떤 쓰기 작업도 하지 않는다.

## 문서 정체성과 경로

- `project_id`와 `document_id`는 생성 후 바뀌지 않는다.
- 상대 경로는 파일의 현재 위치다.
- 이름 변경, 이동, 휴지통 이동 시 ID는 유지하고 경로·부모만 변경한다.
- 원고는 `원고/N권/NNN화.txt` 규칙을 사용한다.
- 플롯과 메인 스토리 틀은 시스템 고정 항목이 아니다.
- Windows 호환 휴지통 경로는 `메인/휴지통`이다.

## 편집기

- SwiftUI는 화면 조합과 상태 표시를 담당한다.
- `iPadTextEditor`가 `UITextView`를 SwiftUI에 연결한다.
- `SmartTextView`는 키 입력과 명령의 UIKit 접점을 담당한다.
- `TextRuleEngine`은 UIKit과 분리된 순수 Swift 규칙 엔진이다.
- IME 조합 중에는 본문 재주입과 즉시 문서 교체를 금지한다.
- 자동 저장, 백업, 검색은 editor subclass 내부에 구현하지 않는다.

## 바인더

고정 최상위 항목은 원고, 캐릭터, 설정집, 메모장, 흐름 정리, 복선, 장소, 휴지통 8개다. `BinderRuleService`는 원고 전용 제약만 판정하고 일반 문서 영역은 안전한 파일명 규칙 안에서 사용자 폴더 생성을 허용한다.

`BinderRuleService`는 생성·이름 변경·이동·드롭 요청을 파일 I/O 없이 판정한다. 권·화 번호는 ASCII 정규 형식으로 파싱하고 원고 전체 중복 화를 막으며, 1,000화부터 자릿수를 자연 확장한다. 권 이름과 화 번호 접두사, 원고 안팎 경계, 원고의 숫자 자연 정렬을 보호한다. Windows 가져오기 검사도 같은 파서를 사용한다.

`BinderViewModel`은 조회에 `BinderRepository`, 변경에 `BinderCommanding`만 사용한다. 로컬 구현은 작품 진입 시 `메인`의 직계 자식만 읽고, 사용자가 폴더를 펼칠 때 해당 직계 자식만 백그라운드에서 읽는다. 파일 시스템 상대 경로가 그대로 정체성이 되지 않도록 SwiftData UUID와 조정하며, 정확한 경로 일치와 유일한 TXT 해시 일치에서 기존 UUID를 유지한다. 변경 명령은 파일 작업 전 저널을 남기고 하위 트리 메타데이터를 일괄 갱신한다.

화면의 최상위 `휴지통`은 디스크의 `메인/휴지통`에 매핑한다. Windows 구형 작품의 `메인/플롯`과 `백업/전환직전`은 가져오기 중 삭제하거나 다른 폴더와 합치지 않고 레거시 사용자 자료로 보존한다.

## 실패 복구

- 파일 작업은 임시 경로와 승격 또는 복구 저널을 사용한다.
- 작품 생성, 가져오기, 새 권 생성은 전부 성공 또는 전부 롤백한다.
- 저장 실패 시 마지막 정상 TXT와 메모리 스냅샷 중 최소 하나가 남아야 한다.
- 복원 전 현재본을 강제 백업한다.
- 이름 충돌은 덮어쓰지 않는다.

## 후속 서버 연결 경계

1~7단계에서는 Supabase 패키지, 인증, SQL, RPC, 서버 payload를 만들지 않는다. Domain/Protocols에 로컬 저장 완료, 구조 변경, 복원, 삭제 같은 사건을 향후 adapter에 전달할 수 있는 최소 인터페이스만 둔다. 현재 구현은 no-op이며 로컬 성공 여부에 영향을 주지 않는다.
