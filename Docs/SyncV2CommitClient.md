# 11-1 `commit_document` 클라이언트

## 구현 범위

`SyncV2Client.commitDocument`는 SQL fixture의
`public.commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid)`
호출 계약만 구현한다.

wire parameter는 다음 아홉 key를 명시적으로 인코딩한다.

```text
p_document_id
p_project_id
p_base_revision
p_operation_id
p_device_id
p_relative_path
p_content
p_is_deleted
p_lease_token
```

nil lease도 JSON `null`로 인코딩해 RPC overload 선택을 암묵적인 key 생략에
의존하지 않는다. 새 문서는 base revision 0, live 상태, nil lease만 허용한다.
본문 UTF-8 10MiB와 서버 상대 경로 규칙을 호출 전에 다시 검사한다.

## 성공 응답 검증

다음 값 중 하나라도 누락되거나 형식이 잘못되면 성공이 아니라
`invalidResponse`다.

```text
status
document_id
version_id
operation_id
operation_kind
revision
relative_path
is_deleted
content_hash
committed_at
```

응답의 document·operation·path·deleted 상태는 요청과 같아야 한다. revision은
`base + 1`이어야 하고, create는 revision 1과 `create` kind여야 한다.
`content_hash`는 요청 본문의 UTF-8 SHA-256 lowercase hex와 정확히 같아야 한다.
PostgreSQL의 소수 초 timestamptz도 decode한다.

`committed`와 `replayed`를 모두 정상 성공으로 받는다. 서버 성공 뒤 로컬
SyncV2Store 반영 전에 앱이 종료되어도 operation row는 아직 완료되지 않았으므로,
후속 dispatcher가 같은 불변 parameter와 같은 operation ID를 다시 보내면 서버의
`replayed` 응답으로 같은 version·revision·hash·시각에 수렴한다.

## 오류 분류

SQL의 P0001 message는 다음 안정 코드로 정확히 분류한다.

- `AUTH_REQUIRED`
- `FORBIDDEN`
- `INVALID_ARGUMENT`
- `DOCUMENT_NOT_FOUND`
- `DOCUMENT_ALREADY_EXISTS`
- `REVISION_CONFLICT`
- `OPERATION_ID_REUSED`
- `LEASE_REQUIRED`
- `LEASE_CONFLICT`
- `LEASE_EXPIRED`
- `PATH_CONFLICT`

PostgREST `42501`은 RLS forbidden, `PGRST301`·`PGRST302`는 인증 필요로
분류한다. `URLError.timedOut`은 timeout으로, 나머지 URL 오류는 네트워크
불가로 분리한다. 알 수 없는 PostgreSQL 오류는 code·message·detail을 버리지
않고 `serverRejected`에 보존한다.

## 11-2 정지 경계

이번 단계는 queue claim, 제한 동시성 dispatcher, backoff·jitter,
SyncV2Store 성공·재시도 반영, lease 획득·갱신을 구현하지 않는다.
`SupabaseClientProvider`는 설정이 있을 때 클라이언트를 만들 수 있게만 연결한다.
