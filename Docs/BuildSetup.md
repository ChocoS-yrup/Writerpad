# WriterPad 빌드 환경

## 확정 설정

| 항목 | 값 |
|---|---|
| Xcode | 26.6 (17F113) |
| iOS/iPadOS SDK | 26.5 |
| 최소 지원 버전 | iPadOS 17.0 |
| 대상 기기 | iPad (`TARGETED_DEVICE_FAMILY = 2`) |
| 사용자 실기기 | iPad Pro 11-inch (M4) |
| 앱 이름 | WriterPad |
| Bundle ID | `com.chocos.writerpad` |
| 서명 방식 | Automatic |
| Mac Catalyst | 사용 가능, 호환 빌드 통과 |
| 서버 패키지 | 없음 |

## Xcode에서 열기

저장소 루트의 `WriterPad.xcodeproj`를 연다. 상단 Scheme은 `WriterPad`, 실행 기기는 설치된 iPad 시뮬레이터를 선택한다.

현재 자동 확인에는 화면 크기가 같은 `iPad Pro 11-inch (M5)`, iOS 26.5 시뮬레이터를 사용한다. 사용자 실기기는 `iPad Pro 11-inch (M4)`다. 최소 지원 버전은 17.0이므로 이후에는 iPadOS 17 계열 실기기 또는 시뮬레이터 회귀 검사도 추가한다.

## 대상 구성

- `WriterPad`: SwiftUI 앱 대상
- `WriterPadTests`: XCTest 자동 테스트 대상
- `WriterPad/Domain`: 모델·규칙·프로토콜
- `WriterPad/Data`: 로컬 저장·백업·휴지통·이전 처리
- `WriterPad/Features`: 작품·바인더·편집기·백업·검색·추출·설정
- `WriterPad/Platform`: UIKit/TextKit 연결부
- `WriterPad/Sync`: 향후 서버 기능의 protocol 구현부; 현재는 no-op만 사용

SwiftData에는 현재 앱 구동 확인용 메타데이터만 있다. 원고 본문은 저장하지 않으며, 2단계부터 UTF-8 TXT 파일을 단일 원본으로 다룬다.

## 로컬 설정과 비밀값

`Configuration/Local.xcconfig.example`은 나중에 필요한 로컬 설정 형식의 예시다. 실제 `Local.xcconfig`, `.env`, 인증서, 키 파일은 Git에 저장하지 않는다. 1~7단계에는 Supabase URL이나 키가 필요하지 않다.

## 검증 결과

- iPad 시뮬레이터 Debug 빌드: 통과
- 전체 자동 테스트: 15개 통과
- Mac Catalyst Debug 호환 빌드: 통과

실제 iPad에 설치하려면 Xcode의 WriterPad 대상에서 Signing & Capabilities를 열고 사용자의 Apple 개발 Team을 선택해야 한다. 이 설정은 개인 계정에 종속되므로 저장소에 임의 값을 고정하지 않는다.
