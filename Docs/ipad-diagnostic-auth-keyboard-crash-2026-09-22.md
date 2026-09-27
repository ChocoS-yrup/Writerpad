# iPad 진단 로그인 입력창 충돌 — 2026-09-22

## 관측

PR #42 병합 main(`6ae7421`)의 NormalEditor 복구 진단 앱에서 A 시험을
준비하던 중 이메일 필드 선택으로 앱 종료가 두 번 재현됐다.
기기는 iPad Pro 11-inch (M4), iPadOS 27.0 (24A437)이다.
이는 진단용 `NORMAL_RECOVERY_CHECKPOINT`가 아니라 실제 SIGABRT다.

두 번째 실행 콘솔에서 `NSInvalidArgumentException`과 다음 이유를 확인했다.

> TUIInputAssistantHostView.leading … A constraint cannot be made … to a constant.
> Location anchors require being paired.

직전에는 nil layout anchor 경고가 있었다. 예외 스택은
`NSLayoutConstraint` → `UIInputWindowControllerHostingItem.inputAssistantHostView`
→ `setInputAccessoryView` → 입력창 배치/애니메이션 경로다.
직접 확인한 것은 UIKit 키보드 보조 영역의 제약 생성 실패이며,
OS 결함인지 앱의 responder 전환이 유발했는지는 아직 확정하지 않았다.
기기 식별정보가 포함된 원본 충돌 보고서와 콘솔은 공개 저장소에 추가하지 않는다.

## 제한된 수정 후보

- `NormalEditorWorkspaceView`의 이메일/비밀번호 필드만 안정된 `UITextField`
  인스턴스를 사용하는 `UIViewRepresentable`로 교체한다.
- UIKit의 공개 API로 두 입력 보조 버튼 그룹을 생성 시 비운다.
  [Apple UITextInputAssistantItem 문서](https://developer.apple.com/documentation/uikit/uitextinputassistantitem)에
  문서화된 단축 버튼 숨김 방식이며, 이 문서가 해당 충돌 해결을 보장하는 것은 아니다.
- secure 입력 여부와 content type은 생성 시 고정한다. 일반 상태 갱신에서는
  입력값이 다를 때만 갱신하며, 강제 포커스/키보드 재로딩을 추가하지 않는다.
- 비밀번호 마스킹, username/password content type, Return 제출, 모델에서의
  비밀번호 지우기를 유지한다. 해제 시 delegate/target와 필드 텍스트를 제거한다.
- 공유 본문 편집기, 동기화 계약, 요청 본문, 계정/RLS 검사, Windows 코드는 변경하지 않는다.
  따라서 Windows 기능 검토 요청은 하지 않는다.

## 검증 범위

입력 특성·보조 버튼 그룹, secure 상태와 비밀번호 초기화, editingChanged 전달,
최신 값의 단일 제출, coordinator 갱신과 선택 보존, 해제 후 callback 차단에
관한 회귀 테스트 6개를 추가했다.

자동 테스트와 빌드 결과는 아래에 기록한다. 시뮬레이터 단위 테스트 통과만으로
iPadOS 27의 실제 키보드 전환 충돌이 해결됐다고 판단하지 않는다.
실기기에서 이메일 선택 → 비밀번호 선택 → 로그인 성공 → 준비 성공을 확인해야 한다.
복구 A 시험은 그 이후 같은 기준과 저장본으로 재개한다.

- 자동 테스트: 입력창 6 + NormalEditor 49 + GeneralSync 70 = 125개 통과.
  iOS 26.5 시뮬레이터, 네트워크 설정이 비어 있는 격리 테스트 앱에서 실행했다.
  빌드 로그의 warning/error 0건.
- 실기기 빌드: 성공, 빌드 로그의 warning/error 0건.
- 실기기 입력 전환 재확인: 사용자가 이메일 입력 → 비밀번호 입력 → 이메일
  재선택의 정상 작동을 보고했다. 이후 로그인·준비를 거쳐 서버 구조 조회까지
  진입했다. 장시간/모든 키보드 조합의 검증 완료를 의미하지는 않는다.
- A 중단/재개 시험: 미완료.

후속 A 송신에서는 `NORMAL_TARGET_MISMATCH`가 발생했다. 현재 대상 문서의
revision 9·393 bytes·기준 해시는 서버와 같지만, 작품 전체 구조는 로컬 14폴더/
4문서/15순서 행과 서버 15폴더/6문서/16순서 행으로 다르다. 다른 시험에서
추가된 폴더/문서와 변경된 메모장 순서, 다른 문서의 본문 revision이 원인이다.
이는 키보드 충돌과 별도 문제다. 전체 구조 일치 검사를 우회하지 않았고,
A 저장 항목은 queued·request 없음·attempts 0이며 서버 처리 기록도 0건이다.
로컬 기준 갱신 경로 검토가 필요하며 이 문서의 입력창 수정에 포함해 해결했다고
주장하지 않는다.

사용자 지시에 따라 모든 앱/서버 데이터는 테스트 데이터로 취급하며 전체 백업이나
복원 절차를 선행 조건으로 두지 않는다. 데이터 초기화나 서버 권한 우회는 하지 않았다.
