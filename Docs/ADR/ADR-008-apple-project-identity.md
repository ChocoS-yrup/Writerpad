# ADR-008: Apple 프로젝트 식별자와 지원 플랫폼 기준

- 상태: 승인
- 날짜: 2026-07-15

## 맥락

로컬 기능 개발을 시작하려면 재현 가능한 Xcode 프로젝트 식별자, 최소 운영체제, 대상 기기 범위를 확정해야 한다. 1차 제품은 iPad 집필 프로그램이며 iPhone 전용 UI는 범위가 아니다. Mac은 당장 별도 제품으로 구현하지 않지만 향후 Catalyst 가능성을 막지 않아야 한다.

## 결정

- 앱 이름과 Scheme은 `WriterPad`를 사용한다.
- Bundle ID는 `com.chocos.writerpad`를 사용한다.
- 최소 지원 버전은 iPadOS 17.0이다.
- 대상 기기 패밀리는 iPad만 지정한다.
- Mac Catalyst를 허용하되 iPad 앱의 Mac 직접 실행은 끈다.
- Apple 개발 Team은 개인 계정에 종속되므로 저장소에 고정하지 않는다.

## 결과

iPad 시뮬레이터에서 서명 없이 개발과 자동 테스트를 진행할 수 있다. Mac Catalyst 호환성도 빌드 단계에서 조기에 확인할 수 있다. 실제 iPad 설치 전에는 사용자가 Xcode에서 자신의 Team을 선택해야 한다.
