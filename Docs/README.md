# WriterPad 개발 문서

## 현재 상태

- 현재 단계: 1-2 Xcode 프로젝트와 로컬 앱 기반 구성 완료
- 다음 단계: 1-3 핵심 도메인 모델과 로컬 저장 경계 구체화
- 제품 코드: SwiftUI 앱·SwiftData 메타데이터 저장소·테스트 타깃 기반 생성 완료
- Git: 로컬 저장소 초기화 완료
- Xcode: 26.6 설치·라이선스·최초 구성 완료
- Apple SDK: iOS/iPadOS 26.5 SDK 사용 가능
- Simulator: iOS 26.5 런타임과 iPad Pro·Air·mini·기본 iPad 기기 사용 가능
- 검증 기기: iPad Pro 13-inch (M5), iOS 26.5 시뮬레이터
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
- `ADR/README.md`: 확정된 설계 결정 색인

## 1-2 검증 결과

- 앱과 테스트 타깃을 Xcode가 정상 인식한다.
- iPad 시뮬레이터 빌드가 성공한다.
- SwiftData 인메모리 저장·조회 및 서버 no-op 경계 자동 테스트 2개가 통과한다.
- Mac Catalyst 호환 빌드가 성공한다.
- 실제 iPad 설치용 Apple 개발 팀과 서명은 아직 설정하지 않았다.
