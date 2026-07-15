# 로컬 Xcode 설정

프로젝트의 고정 Bundle ID는 `com.chocos.writerpad`다. 시뮬레이터 빌드에는 별도 설정이 필요하지 않다.

실제 iPad 서명이 필요할 때 `Local.xcconfig.example`을 `Local.xcconfig`로 복사하고 개인 Apple Developer Team 값을 설정한다. 개인 Team ID와 인증 관련 값은 Git에 커밋하지 않는다.
