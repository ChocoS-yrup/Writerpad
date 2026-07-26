# 7-5 로컬 마일스톤 감사

- 감사일: 2026-07-26
- 기준 기기: iPad Pro 11-inch (M5)
- 범위: 네트워크와 Supabase를 제외한 1~7단계 로컬 기능

## 제품 결정

원고 내보내기는 백업·복원 수단이 아닌 개인 소장용 UTF-8 TXT·PDF다. 작품 폴더 패키지, UUID·경로 manifest와 재가져오기는 ADR-010에 따라 제외한다.

## 완료한 수정

| 감사 항목 | 발견 | 처리 |
|---|---|---|
| 가짜 placeholder | 구현된 원고 내보내기·휴지통 시트의 타입명이 `WorkspacePlaceholderSheet`로 남아 있었음 | `WorkspaceSheet`와 `export`로 변경 |
| View의 직접 파일 접근 | `ManuscriptExportView`가 임시 폴더 생성·결과 파일 읽기·정리를 직접 수행 | actor `ManuscriptExportStaging`으로 이동 |
| 메인 스레드 파일 I/O | 내보내기 임시 파일 처리는 이미 detached 작업이었으나 화면 소유였음 | 별도 actor 실행 경계로 명확화 |
| 무시된 저장소 오류 | 화 이동, 내보내기 마지막 화 초기화, 백업 이력 진입, 최상위 바인더 순서 변경이 일부 읽기 실패를 정상적인 빈 결과처럼 처리 | 오류를 호출자에게 전달하고 사용자 오류 상태로 표시 |
| 500줄 초과 화면 | `ManuscriptExportView.swift` 749줄 | 지원 타입을 `ManuscriptExportSupport.swift`로 분리해 495줄로 축소 |
| 작업 공간 화면의 직접 저장소 접근 | 원고 탐색·마지막 화 계산·복원·화면 상태 저장이 `WritingWorkspaceShell`에 섞여 있었음 | 작품별 actor `WorkspaceStorageCoordinator`로 이동하고 저장·IME 전환 순서는 유지 |
| 작품 상태 혼입 시 강제 종료 | 코디네이터가 다른 작품 ID를 받으면 `precondition`으로 종료할 가능성이 있었음 | 복구 가능한 `projectMismatch` 오류로 바꾸고 저장소 호출 전에 차단 |
| `RootView.swift`의 화면 책임 혼재 | 앱 진입점, 작품 목록, 집필 화면, 레이아웃 관찰, 가져오기 결과, 테마, 검색 입력 브리지와 편집 세션이 한 파일에 있었음 | 테마·작품 목록·새 작품 알림·집필 화면·레이아웃·가져오기 결과·검색 입력·편집 세션을 책임별 파일로 이동해 `RootView.swift`를 3,957줄에서 37줄로 축소 |
| UI 테스트의 실행 상태 의존 | 집필 화면 테스트가 마지막 작품 자동 진입 설정과 바인더 초기 열림 상태를 이전 실행에서 물려받음 | 시작 화면을 작품 목록으로 고정하고 바인더가 닫힌 경우에만 열도록 전제 조건 명시 |

`try? Task.sleep`은 화면 메시지 자동 해제를 취소하기 위한 의도적인 취소 경계다. 파일·저장소 오류를 삼키는 용도로 사용하지 않는다.

## 자동·실기기 증거

| 기능 | 자동 검증 | iPad M5 실기기 |
|---|---|---|
| UTF-8 TXT 전체·범위 내보내기 | 순서, 제목 정규화, 300자 경계, 빈 화, 없는 화, 취소, 출력 교체 실패 | 완료 |
| PDF 내보내기 | 다중 페이지, 한글·이모지, 빈 페이지, 출력 교체 실패 | 열람, 순서, 한글·이모지, 페이지 나눔, 원고 불변 완료 |
| 내보내기 전 저장 | 준비 완료 뒤 exporter 호출, 준비 실패 시 exporter 미호출 | 완료 |
| 내보내기 형식 UI | TXT 기본값, PDF 전환, 설명 노출 UI 테스트 | 완료 |
| 작업 공간 저장·복원 코디네이터 | 원고 25화 탐색, 마지막 화 계산, 상태 저장·복원, 작품 ID 혼입 차단 | 화면 동작 변경이 없어 추가 실기기 확인 불필요 |
| 일반 UI 파일 분리 | 전체 단위 테스트 230개, 작품 편집·삭제 목록 UI, 작품 생성·바인더·설정·원고 선택 UI | 구조 이동만 수행해 추가 실기기 확인 불필요 |
| 7-6 통합 성능 기준선 | 40권·1,000화×6,000자·보조 TXT 500개·실제 백업 5,000개를 임시 영역에 생성하고 median/p95·메모리·메인 액터 heartbeat를 JSON으로 기록. Release 시뮬레이터 교정 통과 | iPad Pro 11-inch (M4), iPadOS 26.5.2 Release 측정 통과. 검색 1,500파일 median 2.645초, 저장 median 3.24ms, 최대 heartbeat 17.28ms, 메인 스레드 파일 I/O 없음. Time Profiler CPU 샘플 4,354개·250ms 이상 멈춤 0건, Allocations·VM Tracker trace 완료 |

## 500줄 초과 파일 분류

단순 줄 수를 맞추기 위한 이동은 기능 안정성을 높이지 않으므로 책임 경계와 회귀 위험으로 분류한다.

| 파일군 | 판단 | 다음 모델 |
|---|---|---|
| `EditorSessionModel.swift`, `DocumentSearchTextField.swift`, `UIKitTextViewBridge.swift` | UI·검색 입력·편집 세션·저장 구현의 파일 경계 분리 완료. 내부 동작 변경은 하지 않음 | 서버 연동 시 Sol |
| `LocalProjectManager`, `LocalBinderCommandService*`, `LocalBackupStore` | 작품 거래·휴지통·백업 원자성 경계. 기계적 분할도 접근 제어와 거래 순서를 건드릴 수 있음 | Sol |
| `EditorAndSaveState.swift`, `TextRuleEngine.swift` | 편집 상태·공유 버퍼·IME 입력 규칙. 기능 변경 없이 별도 감사 필요 | Sol |
| `BinderPanel.swift` | 일반 UI 책임 분리가 가능하나 현재 동작 오류는 없음 | Terra, 위 Sol 경계 해결 후 |
| `WindowsProjectImporter.swift` | 가져오기 거래·원본 무결성 경계 | Sol |

## 다음 모델 전환 경계

`WritingWorkspaceShell`의 저장소 접근은 별도 actor로 옮겼고 저장 전환·커서 복원·IME 커밋 순서는 변경하지 않았다. 일반 UI, 검색 입력 브리지, 편집 세션의 파일 경계도 분리했다. 서버 연동에서는 이 경계를 유지한 채 저장 프로토콜 구현과 동기화 조정자를 연결하며, 해당 작업은 Sol이 담당한다.

7단계 로컬 구현·사용자 실기기 기능 검증·M4 Release 성능 측정과 Instruments 기록은 모두 완료됐다. 다음 단계는 Windows v2와 Supabase 계약이 확정된 뒤 Sol로 재개한다.
