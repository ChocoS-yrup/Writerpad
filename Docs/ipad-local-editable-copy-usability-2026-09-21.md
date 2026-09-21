# 편집용 로컬 사본 — 사용성 보강 결과

2026-09-21. 독립 오프라인 편집 정책에 따라 편집 화면의 출처·revision 표시, 문서별 미저장 초안 보존, 저장 차단 원인 표시를 구현하고 오프라인 검증했다.

## 변경 동작

- 편집 창에 원본 폴더명, 문서 수, 작업 사본 전체의 마지막 local revision을 표시한다.
- 문서별 초안을 메모리에 따로 유지한다. 저장하지 않은 상태로 다른 문서를 선택했다가 돌아와도 입력 내용이 남는다.
- 현재 문서가 저장본과 다르면 `저장하지 않은 변경`을 표시하고, 같으면 저장 버튼을 비활성화한다.
- 미저장 문서가 있는 상태에서 닫기를 누르면 계속 편집하거나 변경을 버리고 닫도록 확인한다.
- 저장 성공 뒤 컨트롤러의 새 snapshot을 기준으로 dirty 상태가 해제된다.
- 저장 차단 문구를 경쟁 저장/revision 변경, 본문 형식·크기, 원본 identity, 작업 사본 검증, 파일 I/O로 구분한다.

초안 상태는 화면 메모리에만 있으며 `identity.json`이나 `workspace.json` 형식을 바꾸지 않는다. 실제 저장은 기존 revision 비교, 배타 lock, 원자 교체, 재검증 경로를 그대로 사용한다.

## 변경 파일

- `OfflineAdapters/SyntheticInitialReceive/Sources/SyntheticInitialReceive/ReceiveEditableCopy.swift`
- `OfflineAdapters/SyntheticInitialReceive/Sources/SyntheticInitialReceive/IOSBoundaryController.swift`
- `OfflineAdapters/IOSBoundaryApp/ReceiveBoundaryApp.swift`
- `OfflineAdapters/SyntheticInitialReceive/Tests/SyntheticInitialReceiveTests/ReceiveEditableCopyTests.swift`

## 검증

- `ReceiveEditableCopyTests`: 9개 통과, 실패 0.
- 새 검사는 두 문서의 미저장 초안이 선택 전환 뒤 유지되는지, 저장된 새 snapshot과 비교해 dirty 수가 감소하는지 확인한다.
- 새 검사는 `busy`, `body`, `identity`, `corrupt`, `io`의 사용자 표시 문구를 각각 확인한다.
- generic iOS Debug unsigned build 성공.
- Xcode 프로젝트 형식 검사와 변경 파일 공백 검사 통과.

Swift Package 첫 실행은 사용자 캐시 및 중첩 sandbox 권한 때문에 시작되지 않았다. 캐시를 `/private/tmp`으로 옮기고 `--disable-sandbox`로 같은 전용 검사를 실행해 통과했다. 첫 iOS 빌드도 sandbox가 Swift 매크로 플러그인을 차단했으며, 승인된 샌드박스 밖 동일 명령으로 재실행해 성공했다. 이는 제품 코드 실패가 아니다.

## 수행하지 않은 일

- 기기 설치·앱 실행·인증·서버 요청
- 저장 형식 migration
- WriterPad 일반 편집 저장소·송신 큐 연결
- 내보내기·공유·삭제 기능

## 다음 단계

새 UI를 실기기에 설치하기 전 수동 확인 범위를 고정한다. 확인 대상은 두 문서 사이의 미저장 초안 전환, 닫기 경고의 두 선택지, 저장 뒤 dirty 해제와 revision 증가, 오류 문구가 기존 저장본을 바꾸지 않는지다. 실제 설치는 별도 사용자 진행으로 남긴다.

## 실기기 확인 완료

후속 사용자 직접 작업으로 사용성 수정본 설치와 오프라인 확인을 완료했다.

- 실행 파일 SHA-256: `5380ce84a313b9a860de0322973ac4010d320db8ec5a8c0342e606cd1be2a115`
- 외부 설정 SHA-256: `b4a2d59fe3bfd7a4527c34f9485b0ca7cf22eeb228a9d43dbbcc80b8ce21cd21`
- 설치 전후 백업과 설정 전달 기록을 별도 보존했다.

화면에서 기존 작업 사본을 재검증해 열고 출처, 문서 2개, 마지막 local revision 1, 저장 버튼의 초기 비활성 상태를 확인했다. `빈문서.txt`와 `저장경계.txt`에 서로 다른 임시 초안을 입력해 문서를 왕복한 뒤 두 초안이 각각 유지됨을 확인했다. 첫 닫기 경고에서 계속 편집을 선택하면 초안이 유지됐고, 두 번째 경고에서 변경을 버리면 읽기 전용 화면으로 돌아왔다.

앱 종료 후 최종 백업에서 다음을 확인했다.

- `WriterPadReceiveBoundary-v1`, `ReceiveDedicated-v1`, `ReceiveEditable-v1` 전체 SHA-256이 설치 전과 동일하다.
- 임시초안 A/B는 디스크에 기록되지 않았다.
- `빈문서.txt`는 기존 완료 저장본과 revision 1, save journal 1건을 유지했다.
- `저장경계.txt`는 revision 0과 빈 save journal을 유지했다.
- 로그인·인증·서버 요청은 수행하지 않았다.

따라서 사용성 보강의 오프라인 검사와 실기기 확인은 완료됐다. 위 `다음 단계` 절은 구현 직후의 계획이며 최신 상태는 이 절이 우선한다.
