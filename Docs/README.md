# WriterPad 개발 문서

## 현재 상태

- 현재 단계: 2-2 UTF-8 TXT 원자적 저장 완료
- 다음 단계: 2-3 작품 생성·목록·이름 변경
- 제품 코드: SwiftUI 앱·SwiftData 메타데이터 저장소·테스트 타깃 기반 생성 완료
- Git: 로컬 저장소 초기화 완료
- Xcode: 26.6 설치·라이선스·최초 구성 완료
- Apple SDK: iOS/iPadOS 26.5 SDK 사용 가능
- Simulator: iOS 26.5 런타임과 iPad Pro·Air·mini·기본 iPad 기기 사용 가능
- 검증 기기: iPad Pro 11-inch (M5), iOS 26.5 시뮬레이터
- 사용자 실기기: iPad Pro 11-inch (M4), 실기기 서명·검증은 후속 진행
- Bundle ID: `com.chocos.writerpad`
- Deployment Target: iPadOS 17.0
- Mac Catalyst: 설정 및 호환 빌드 확인 완료
- Windows 소스: `공유/`에 읽기 전용 참조 소스 제공됨
- Windows 테스트 작품: `집필모드/`에 1권·2권, 총 50화 제공됨
- Supabase: 1~7단계 범위에서 제외

## 요구사항 우선순위

서로 다른 문서의 내용이 충돌하면 다음 순서로 판단한다.

1. 사용자가 대화에서 확정한 최신 결정
2. `아팯_집필프로그램_코딩프롬프트_1-7단계.md`
3. `통합개발기획서_확인메모.md`
4. `아팯_집필프로그램_통합개발기획서.md`
5. 원본 전체 코딩 프롬프트

현재 확정된 예외는 다음과 같다.

- AI 집필도우미는 구현하지 않는다.
- 플롯과 메인 스토리 틀은 고정 바인더 항목이 아니다.
- 고정 바인더 최상위 항목은 8개다.
- TXT 전체 추출은 공백 포함 300자 미만 화에서 해당 화부터 중단한다.
- Windows v2와 Supabase 규약은 확정 전까지 구현하지 않는다.

## 문서 목록

- `RequirementsTraceability.md`: 요구사항과 단계·검증 연결
- `Architecture.md`: 목표 아키텍처와 데이터 흐름
- `ModuleDependencies.md`: 모듈 의존 규칙
- `StageCompletionCriteria.md`: 1~7단계 완료 조건
- `Risks.md`: 위험과 대응 계획
- `WindowsReferenceFindings.md`: Windows 소스·테스트 작품 대조 결과
- `BuildSetup.md`: Xcode 열기·빌드·테스트·서명 설정
- `DomainModel.md`: 프로젝트·문서·백업·편집·저장 상태 모델 관계
- `SwiftDataMetadata.md`: V1 스키마·무결성·복원·복구 정책
- `PathPolicy.md`: Windows 호환 이름·상대 경로·표준 작품 구조
- `AtomicDocumentStore.md`: UTF-8 TXT 원자 저장·오류·generation·재실행 복구 계약
- `ADR/README.md`: 확정된 설계 결정 색인

## 2-2 검증 결과

- 앱과 테스트 타깃을 Xcode가 정상 인식한다.
- iPad 시뮬레이터 빌드가 성공한다.
- SwiftData·경로 정책·TXT 저장을 포함한 자동 테스트 39개가 통과한다.
- 작품·문서·백업 ID와 상대 경로가 별도 타입으로 분리됐다.
- 이동·휴지통 이동 후에도 문서 ID와 작품 ID가 유지된다.
- Codable 메타데이터에 원고 본문 필드가 없음을 검사한다.
- 저장 상태는 이전 generation의 늦은 결과를 무시한다.
- 작품·문서·마지막 작품·좌우 문서·커서·바인더 너비·펼침 상태가 저장된다.
- 잘못된 부모와 작품을 넘는 부모 관계가 저장 단계에서 거부된다.
- 손상 메타데이터는 오류로 보고하며 원고 TXT에는 접근하지 않는다.
- Windows 금지 문자·예약 이름·끝 공백·마침표·제어 문자를 거부한다.
- 대소문자 비구분과 Unicode NFC 기준 충돌을 거부한다.
- 절대 경로·`..`·심볼릭 링크를 통한 작품 루트 탈출을 거부한다.
- 새 작품에는 플롯·메인 스토리 틀·전환직전 폴더를 만들지 않는다.
- 빈 파일·한글·이모지·대용량 원고가 UTF-8로 손실 없이 왕복한다.
- 임시 파일 쓰기·flush·표식·교체 실패에서 기존 원고가 보존된다.
- 문서별 저장 직렬화와 generation 검증으로 오래된 저장이 최신본을 덮지 못한다.
- TXT 저장 후 SwiftData 실패는 재조정 표식으로 남고 다음 실행에서 해시를 검증해 복구한다.
- Mac Catalyst 호환 빌드가 성공한다.
- 실제 iPad 설치용 Apple 개발 팀과 서명은 아직 설정하지 않았다.
