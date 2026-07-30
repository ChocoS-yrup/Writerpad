# 9-1 Supabase 기반 고정 기록

## 의존성 기준

- 패키지: 공식 `supabase-swift`
- 저장소: `https://github.com/supabase/supabase-swift.git`
- 고정 버전: `2.46.0` (2026-04-29 공개)
- 공식 최소 요구사항: iOS 13+, Xcode 15.3+, Swift 5.10+
- WriterPad 기준: iOS 17.6, Xcode 26.6

WriterPad의 최소 OS와 현재 도구가 패키지 요구사항보다 높다. 프로젝트는 재현성을 위해 범위가 아닌 정확한 패키지 버전을 사용한다.

## 구성 경계

`Configuration/Debug.xcconfig`, `Test.xcconfig`, `Release.xcconfig`는 별도 파일이다. Git에 포함되는 파일의 값은 비어 있으며, 실제 공개 URL과 publishable key는 환경별 `Supabase.*.local.xcconfig`에 둔다. 로컬 파일은 `*.local.xcconfig` 규칙으로 제외된다.

앱 번들 키는 다음 둘뿐이다.

- `WriterPadSupabaseURL`
- `WriterPadSupabasePublishableKey`

service role/secret key, access token, refresh token, 이메일, 비밀번호는 source, plist, xcconfig, 로그에 두지 않는다.

## 실패 안전성

`SupabaseClientProvider`는 번들의 공개 설정을 파싱한다. 설정 누락, HTTPS가 아닌 URL, 사용자 정보·쿼리·fragment가 포함된 URL, service role credential은 `.unavailable` 상태가 된다. 이 상태는 오류를 던지지 않고 네트워크 요청도 만들지 않으므로 앱 시작과 기존 로컬 저장 구성을 막지 않는다.

`AppEnvironment`는 `SupabaseClient` 자체가 아니라 `SupabaseClientProviding`을 보유한다. View와 ViewModel에는 client 생성이나 전역 client 참조가 없다. 인증, 세션, 서버 호출은 9-2 이후 범위다.
