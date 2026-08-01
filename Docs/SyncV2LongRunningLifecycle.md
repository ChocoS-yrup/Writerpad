# Sync v2 장기 실행 수명 관리

## 현재 계약

Realtime payload는 원고 본문에 직접 적용하지 않는다. `documents` 변경은
snapshot pull을 깨우는 신호일 뿐이며, 적용 여부는 서버 snapshot의 revision,
영구 queue 상태, 로컬 dirty/IME guard를 함께 확인해 결정한다.

인증 세션은 Supabase SDK의 자동 갱신에 맡기지 않는다. access token 만료 시각을
추적해 기본 5분 전에 single-flight refresh를 실행하고, 응답의 access token과
회전된 refresh token, 새 만료 시각을 하나의 Keychain payload로 교체한다.
인증 오류가 난 snapshot은 이 갱신이 성공한 경우에만 한 번 재시도한다.

Realtime은 `subscribing`, `subscribed`, `closed`, `channelError`, `timedOut`
상태를 workspace에 전달한다. 종료 계열 상태에서는 1, 2, 5, 10, 30초
backoff로 새 generation의 채널을 만들며, 구독 성공 즉시 snapshot을 pull한다.
이전 generation의 status/change callback은 무시한다.

workspace와 background pull은 15초 watchdog을 가진다. 실행 중 들어온 여러
Realtime·주기 이벤트는 pending 한 건으로 합치며, 현재 pull이 성공·실패·timeout
어느 경로로 끝나도 task slot을 비운 뒤 후속 pull을 실행할 수 있다. 90초 주기
snapshot은 Realtime 누락과 조용한 연결 고장을 보완한다.

## delta pull 검토

현재 snapshot RPC는 작품의 모든 문서 본문을 매 확인마다 내려받으므로 작품이
커질수록 90초 안전망 비용이 선형으로 증가한다. 장기적으로는 프로젝트별 단조
증가 `change_seq`와 변경 로그를 추가하는 delta pull이 적합하다.

권장 후속 계약은 다음과 같다.

1. 서버 transaction이 문서 변경과 프로젝트 `change_seq` 증가, 변경 로그 기록을
   함께 commit한다.
2. 클라이언트는 `after_seq`와 limit을 넘기고 `(through_seq, changes)`를 받는다.
3. 각 change에는 sequence, document ID, revision, 삭제 여부만 두고 본문은 해당
   문서 snapshot 조회로 검증한다.
4. iPad는 마지막으로 완전히 적용한 `through_seq`를 SyncV2Store에 영구 저장한다.
5. 로그 보존 구간 밖의 sequence나 불연속이 발견되면 전체 snapshot으로
   fallback하고 새 기준 sequence를 저장한다.
6. Realtime payload는 최신 sequence와 식별자만 전달하며, 여전히 pull wake-up
   신호로만 사용한다.

이번 변경은 운영 호환성이 있는 기존 snapshot 계약만 사용한다. migration,
RPC, 운영 Supabase 데이터 변경은 포함하거나 적용하지 않았다. delta 계약을
도입할 때에는 SQL migration, RLS, RPC 원자성 테스트, Windows/iPad 양쪽
클라이언트와 store migration을 한 묶음으로 준비한 뒤 별도 승인을 받아야 한다.
