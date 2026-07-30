# 로컬 Xcode 설정

프로젝트의 고정 Bundle ID는 `com.chocos.writerpad`다. 시뮬레이터 빌드에는 별도 설정이 필요하지 않다.

`Debug.xcconfig`, `Test.xcconfig`, `Release.xcconfig`는 서로 분리되어 있고 기본 Supabase 값은 비어 있다. 공개 프로젝트 URL과 publishable key가 필요하면 `Supabase.local.xcconfig.example`을 해당 환경의 다음 이름 중 하나로 복사한다.

- `Supabase.Debug.local.xcconfig`
- `Supabase.Test.local.xcconfig`
- `Supabase.Release.local.xcconfig`

이 로컬 파일들은 Git에서 제외된다. 앱 번들에는 URL과 publishable key만 허용한다. service role/secret key, access·refresh token, 이메일, 비밀번호는 여기에 기록하지 않는다.

실제 iPad 서명이 필요할 때 `Local.xcconfig.example`을 참고해 개인 Apple Developer Team 값을 설정한다. 개인 Team ID와 인증 관련 값은 Git에 커밋하지 않는다.
