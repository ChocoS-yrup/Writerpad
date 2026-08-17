# 로컬 Xcode 설정

Bundle ID는 구성마다 다르다. Release는 `com.chocos.writerpad`, Debug는 `com.chocos.writerpad.debug`다.
`Shared.xcconfig`의 `WRITERPAD_BUNDLE_SUFFIX`가 그 차이를 만들고, `WRITERPAD_DISPLAY_NAME`이 홈 화면 이름을 함께 가른다.

같은 Bundle ID를 쓰면 iOS가 같은 앱 컨테이너를 준다. 그러면 두 빌드가
`sync-v2.sqlite3` 하나를 공유하고, 스키마 번호는 올라가기만 하므로 높은 쪽을
한 번 설치한 기기에서는 낮은 쪽 빌드가 전부 열리지 않는다. 보존해 둔 계보의
빌드를 같은 기기에 놓고 비교하려면 컨테이너가 갈려 있어야 한다.

Debug ID를 바꾸면 그 빌드는 이전 Debug 설치본의 문서·로그인 정보를 보지 못한다.
새 컨테이너이므로 처음 켠 상태에서 시작하고 로그인을 다시 해야 한다.

시뮬레이터 빌드에는 별도 설정이 필요하지 않다.

`Debug.xcconfig`, `Test.xcconfig`, `Release.xcconfig`는 서로 분리되어 있고 기본 Supabase 값은 비어 있다. 공개 프로젝트 URL과 publishable key가 필요하면 `Supabase.local.xcconfig.example`을 해당 환경의 다음 이름 중 하나로 복사한다.

- `Supabase.Debug.local.xcconfig`
- `Supabase.Test.local.xcconfig`
- `Supabase.Release.local.xcconfig`

이 로컬 파일들은 Git에서 제외된다. 앱 번들에는 URL과 publishable key만 허용한다. service role/secret key, access·refresh token, 이메일, 비밀번호는 여기에 기록하지 않는다.

실제 iPad 서명이 필요할 때 `Local.xcconfig.example`을 참고해 개인 Apple Developer Team 값을 설정한다. 개인 Team ID와 인증 관련 값은 Git에 커밋하지 않는다.
