# 9-4 프로젝트 binding과 ensure_project 경계

## 현재 구현 경계

`SupabaseProjectBindingService`가 다음 네 흐름을 분리한다.

- 새 서버 프로젝트: local project UUID를 server UUID로 사용한다.
- 기존 서버 프로젝트: 사용자가 입력한 UUID가 선택한 UUID와 정확히 같아야 한다.
- Windows 가져오기 프로젝트: 확인된 server UUID와 `windows_import` 종류를 쓴다.
- 연결 해제: local binding만 `local_only`로 바꾸고 서버 RPC를 호출하지 않는다.

이름만으로 server project를 검색하거나 연결하는 API는 없다. 로컬 이름 변경은
기존 binding의 server UUID로 `ensure_project`를 다시 호출하므로 UUID가
유지된다. 작품을 삭제 목록으로 옮기는 로컬 흐름에는 binding service를 연결하지
않았으며 서버 데이터와 binding을 자동 삭제하지 않는다.

## 오류 분류

`AUTH_REQUIRED`, `FORBIDDEN`, `INVALID_ARGUMENT`, 네트워크 오류, 응답 불일치와
기타 서버 거부를 각각 구분한다. 특히 `FORBIDDEN`을 빈 프로젝트나 네트워크
오류로 바꾸지 않는다. 응답의 project UUID와 정리된 이름이 요청과 다르면
binding을 저장하지 않는다.

## 10-1과의 의존성

기획서 10-1이 8-4의 전체 SQLite schema 생성·migration·복구를 구현하는
단계다. 9-4에서 부분 SQLite DB를 먼저 만들면 10-1의 schema checksum과 원자적
migration 경계를 훼손할 수 있으므로 만들지 않는다.

`ProjectBindingStoring` 영구 저장 계약을 먼저 고정했고 테스트에서는
`InMemoryProjectBindingStore`로 네 흐름과 유일성 제약을 검증했다.

10-1에서 `LazySyncV2ProjectBindingStore`가 이 계약을 실제 `sync_projects`
table에 연결했다. DB open·migration·integrity 검증에 실패하면 unavailable이
되어 `ensure_project`를 호출하기 전에 중단하므로, 영구 binding 없이 원격
프로젝트만 생기는 상태가 없다. binding UI는 아직 노출하지 않는다.

## 제외 범위

operation queue, 문서 commit, lease, pull, Realtime, 프로젝트 원격 삭제와
이름 기반 자동 병합은 9-4에 포함하지 않는다.
