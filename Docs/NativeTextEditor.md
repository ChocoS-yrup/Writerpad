# 네이티브 편집기 4-1~4-7 계약

## 구성

- `SmartTextView`는 `UITextView`를 상속한 UTF-8 일반 텍스트 편집 표면이다.
- `iPadTextEditor`는 `UIViewRepresentable`로 단일 `SmartTextView` 인스턴스를 SwiftUI에 연결한다.
- `EditorSessionModel`은 문서 메타데이터와 로컬 TXT를 불러오고 현재 세션의 본문·커서·초안을 관리한다.

## 본문 갱신

- 외부 본문은 `document_id + externalVersion`이 바뀐 경우에만 UITextView에 적용한다.
- 같은 문서와 버전의 SwiftUI 업데이트는 전체 `text`를 다시 설정하지 않는다.
- 문서가 바뀔 때만 Undo 이력을 비우며 같은 문서의 외부 버전 갱신은 불필요한 초기화를 하지 않는다.
- 커서와 선택은 영구 모델의 `TextCursorState`처럼 UTF-16 위치를 사용하고 실제 본문 범위로 제한한다.
- 문서별 스크롤 위치는 동일한 UITextView coordinator 안에서 세션 동안 유지한다.

## 표시와 명령

- 빈 문서 안내는 UILabel 계층으로 표시하며 원문 문자열에 포함하지 않는다.
- 복사·잘라내기·일반 텍스트 붙여넣기와 UIKit Undo/Redo를 사용한다.
- 현재 문서 검색 범위는 UTF-16 좌표로 세션별 보관하고 TextKit 표시 속성으로만 강조한다. 강조 변경 중 Undo 등록을 막으며 TXT 문자열에는 포함하지 않는다.
- `⌘F`는 IME 조합 중이면 먼저 marked text를 확정한 뒤 검색 입력으로 이동하고, Escape·닫기는 활성 편집기 포커스를 복원한다.
- Dynamic Type과 VoiceOver용 원고 편집기 레이블을 제공한다.

## 4-5 편집기 사용성

- 상단 글자 수는 Swift `Character` 단위이며 공백과 줄바꿈을 포함한다. 한글 음절과 결합 이모지는 사용자가 보는 글자 한 개로 센다.
- 본문이 실제로 바뀔 때만 통계를 다시 계산하며, 동일 문자열 재주입에는 계산하지 않는다.
- 글꼴 종류·크기·줄 간격·좌우/상하 여백·타자기 스크롤은 `AppStorage`에 보관해 재실행 후 복원한다.
- 화면 설정은 `textStorage` 표시 속성과 `textContainerInset`만 바꾸며 TXT 문자열과 UTF-8 바이트에는 포함하지 않는다.
- 표시 속성 적용 중에는 Undo 등록을 잠시 중지하고 기존 등록 상태를 복원한다. 문서 전체를 교체하면 같은 설정값도 새 본문에 다시 적용한다.
- 타자기 스크롤은 마지막 줄 아래에 화면 높이 절반가량의 표시 전용 여백을 확보해 집필 중인 끝 문장도 중앙 부근까지 올린다. 본문 입력 이벤트에서만 중앙 정렬하며, 화면 탭·방향키 이동·드래그 범위 선택에는 개입하지 않는다. UIKit 기본 커서 스크롤이 끝난 다음 메인 루프에서 최종 위치를 적용하며, 시스템의 동작 줄이기가 켜져 있으면 애니메이션하지 않는다.
- 문서 전환 전에 커서·선택을 저장하고, 실제 본문 길이에 맞게 제한해 복원한다. 스크롤 위치는 편집 세션의 문서별 coordinator 메모리에 유지한다.

## 4-7 외장 키보드 명령

- 앱 메뉴의 공통 `WriterPadEditorCommand`를 현재 scene의 작업공간 action에 연결해 Catalyst 다중 창에서 다른 창으로 명령이 퍼지지 않게 한다.
- `⌘Z`·`⇧⌘Z`는 `UITextView`의 표준 responder chain이 현재 first responder인 활성 편집기에 전달한다. SwiftUI 메뉴와 `SmartTextView.keyCommands`에서 같은 키를 중복 등록하지 않는다.
- WriterPad 메뉴의 Undo/Redo 버튼은 활성 패널 모델의 요청 generation을 해당 `iPadTextEditor.Coordinator`에 전달하며, marked text가 존재하면 조합 완료 뒤 처리한다.
- `Command+S`는 활성 문서 스냅샷을 원자 저장 계층에 전달한다. 조합 중이면 저장 요청을 보류하고 조합 종료 뒤 실행한다.
- 이전·다음 화는 원고 루트 아래의 정규 `N권/NNN화.txt` 형식(1,000화부터 4자리)의 문서만 자연 순서로 이동한다.

## 단계 경계

- 4-1은 TXT 읽기와 세션 내 초안 보존까지만 담당하며 디스크 저장을 시작하지 않는다.
- `markedTextRange`가 있는 동안 외부 본문 적용을 보류하며, 조합 중 문서 전환과 포커스 상태 머신은 `IMEInputSafety.md`의 4-2 계약으로 구현했다.
- 4-7은 `Command+S` 수동 원자 저장만 연결한다. 800ms 디바운스와 전환·background 즉시 저장 coordinator는 5단계 책임이다. 스마트 쌍 입력은 `TextRuleEngine.md`의 4-3 계약으로 연결했다.
- 4-5의 설정 저장은 시각 설정만 담당하며 원고 디스크 저장을 시작하지 않는다.

## 자동 검증

- 한글·이모지 본문과 UTF-16 선택 범위
- 동일 본문·버전 재주입 방지
- 문서/버전 변경 판정과 조합 중 외부 적용 보류
- 빈 문서 안내와 원문 분리
- 기본 Undo
- 실제 로컬 UTF-8 TXT 로딩과 문서 전환 후 세션 초안 복원
- UI에서 새 권의 첫 화를 열고 `한글🙂` 입력
- 공백·줄바꿈을 포함한 한글·결합 이모지 글자 수와 6,000자 성능 측정
- 문서 전환 전 커서·선택 저장과 본문 범위 제한 복원
- 화면 설정 전후 문자열·UTF-8 바이트·선택·Undo 보존
- 같은 설정을 유지한 문서 교체 후 표시 속성 재적용
- 타자기 스크롤 중앙 배치·문서 상하단 제한 계산, 실제 UITextView 마지막 줄 중앙 배치, 탭·범위 선택 오프셋 유지, 기능 해제 시 표시 여백 제거
- 활성 편집기 command request의 Undo/Redo와 수동 UTF-8 원자 저장
- iPad Pro 11-inch (M5), iOS 26.5 시뮬레이터 단위 테스트 123개·UI 테스트 7개와 Mac Catalyst arm64 빌드 통과
- 실제 Magic Keyboard 또는 Bluetooth 키보드 단축키는 미검증
