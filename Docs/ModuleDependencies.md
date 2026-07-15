# 모듈 의존성 규칙

## 모듈별 책임

| 모듈 | 책임 | 의존 가능 | 의존 금지 |
|---|---|---|---|
| App | 앱 진입점·환경 조립 | 모든 구현 모듈 | View 내부 서비스 생성 |
| Domain/Models | ID·경로·상태 값 | Foundation 최소 범위 | SwiftUI·UIKit·SwiftData |
| Domain/Rules | 바인더·텍스트 순수 규칙 | Domain/Models | 파일 I/O·UI·네트워크 |
| Domain/Protocols | 저장소·시계·해시·후속 adapter 계약 | Domain/Models | 구현 프레임워크 |
| Data/Local | TXT·SwiftData·프로젝트 저장 | Domain | SwiftUI·UIKit |
| Data/Backup | 백업·보존·복원 | Domain·Data/Local 경계 | Feature View |
| Data/Trash | 이동·복원·영구 삭제 | Domain·Data/Local 경계 | Feature View |
| Features | 화면 상태·사용자 흐름 | Domain protocols·Platform adapter | 직접 파일 열거·쓰기 |
| Platform | UITextView·파일 선택·공유 | Domain protocols | SwiftData 직접 접근 |
| Sync | 향후 연결 protocol·no-op adapter만 | Domain | Supabase 구현·서버 스키마 |
| Tests | fixture·fake·검증 | 대상 모듈 | 실제 원고·운영 서버 |

## 핵심 금지 규칙

- View에서 `FileManager`, SwiftData context, Supabase 테이블을 직접 수정하지 않는다.
- `SmartTextView` 안에서 자동 저장·백업·검색 정책을 구현하지 않는다.
- Domain에서 UIKit의 `NSRange`를 영구 모델로 저장하지 않는다. 필요한 변환은 Platform 경계에서 처리한다.
- 로컬 저장 성공을 서버 미설정 상태와 묶지 않는다.
- 파일명이나 상대 경로를 문서 ID로 사용하지 않는다.
- 실제 원고, 백업, 비밀 설정을 테스트 fixture나 Git에 넣지 않는다.

## 의존성 주입

`AppEnvironment`가 다음 protocol 구현을 조립한다.

- ProjectRepository
- ProjectManaging
- DocumentRepository
- LocalDocumentStoring
- BackupStoring
- TrashManaging
- Searching
- Exporting
- Clock
- UUIDGenerating
- ContentHashing
- FutureChangeNotifying — 1~7단계에서는 no-op

테스트는 인메모리 SwiftData, 임시 폴더, 가상 시계, 결정적 UUID, 실패 주입 파일 저장기를 사용한다.
