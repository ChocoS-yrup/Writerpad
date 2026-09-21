# 9-2 Keychain 세션과 인증 상태

## 책임 경계

- `SupabaseAuthService` actor가 로그인·복원·로그아웃 상태 전이를 소유한다.
- 이메일/비밀번호 회원 가입은 Supabase의 두 응답을 구분한다. 즉시 세션이
  발급되면 Keychain에 저장하고 로그인하며, 이메일 확인이 필요한 응답에는
  세션을 만들지 않고 확인 안내만 표시한다.
- `KeychainSessionStore` actor가 access token과 refresh token 한 쌍만 저장한다.
- Supabase SDK의 자체 영구 세션 저장과 자동 refresh는 끈다. 세션 영속성의 단일 소유자는 WriterPad Keychain 저장소다.
- 이메일과 비밀번호는 Keychain에 저장하지 않는다.
- 인증 상태에는 서버가 검증한 사용자 UUID와 마스킹된 이메일만 노출한다.
- View와 ViewModel은 `SupabaseClient`를 직접 참조하지 않는다.

## 보호된 화면 경계

- 로컬 작품 목록·편집·저장은 로그인 없이 계속 사용할 수 있다.
- 전체 동기화와 작품별 서버 연결 화면은 `AuthenticationState.authenticated`
  에서만 렌더링한다. 로그아웃·세션 만료·네트워크로 검증할 수 없는 상태에는
  로그인 화면과 잠금 안내만 보여 준다.
- 앱은 인증 상태 stream을 계속 관찰한다. 세션이 만료되거나 폐기되면 background
  sync와 edit lease를 즉시 닫고, 다시 인증되면 사용자가 켜 둔 동기화를 재개한다.
- 화면 가드는 UX 경계일 뿐 권한의 근거가 아니다. Supabase의 공개 테이블은 모두
  RLS가 켜져 있고 `anon`에는 테이블 권한이 없으며, 읽기 정책은
  `TO authenticated`와 작품 membership 검사로 행 접근을 제한한다.

## 앱 시작 복원

앱 화면은 인증과 무관하게 먼저 구성된다. 비동기 복원은 다음 순서를 따른다.

이미 `.restoring`이거나 인증이 완료된 상태의 중복 복원 요청은 무시해 같은 refresh token을 두 번 사용하지 않는다.

1. Keychain에서 token 쌍을 읽는다.
2. Supabase `setSession`으로 서버 확인을 수행한다.
3. 만료된 access token이면 refresh token으로 갱신한다.
4. 성공한 세션의 회전된 token 쌍을 Keychain에 다시 저장한다.
5. 모든 단계가 성공한 뒤에만 `.authenticated`가 된다.

네트워크 오류나 Keychain 오류에서 stale 사용자 객체를 로그인 상태로 사용하지 않는다. 인증 실패는 로컬 작품 열기·편집·저장과 별도 경계다.

## 오류와 정리 정책

- `session_expired`: 만료로 분류하고 저장 token을 삭제한다.
- `refresh_token_not_found`: 폐기된 refresh token으로 분류하고 삭제한다.
- `refresh_token_already_used`: 재사용 감지로 분류하고 삭제한다.
- 네트워크 오류: 로그인 상태로 승격하지 않으며, 나중 재시도를 위해 token을 보존한다.
- Keychain 접근 실패: 별도 오류로 유지한다.
- 사용자 로그아웃: 서버 결과와 관계없이 메모리 인증 상태와 Keychain 세션을 정리한다.

비밀번호 재설정과 계정 삭제는 아직 이 계층의 범위에 포함하지 않는다. 인증이
필요한 sync pending operation도 로그아웃 때 삭제하지 않는다.
