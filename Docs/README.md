# WriterPad 개발 문서

## 현재 상태

- 현재 단계: 1-1 저장소 조사와 개발 문서 준비
- 제품 코드: 아직 없음
- Git: 로컬 저장소 초기화 완료
- Xcode: 전체 Xcode가 활성화되지 않았고 Command Line Tools만 선택됨
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
- `ADR/README.md`: 확정된 설계 결정 색인

## 1-2 진입 전 확인

- 전체 Xcode 설치 또는 활성 developer directory 확인
- iPadOS 17 이상 SDK 사용 가능 여부 확인
- Bundle ID 초안 결정 위치 마련
- Windows 참조 소스의 실제 경로 규칙을 1~7단계 프롬프트에 반영했는지 확인
