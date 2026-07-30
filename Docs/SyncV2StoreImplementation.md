# 10-1 SyncV2Store 구현

## 저장 위치와 앱 경계

라이브 DB 기본 위치는 다음과 같다.

```text
Application Support/WriterPad/SyncV2/sync-v2.sqlite3
```

TXT 원고와 SwiftData V1은 읽거나 변경하지 않는다. `LazySyncV2ProjectBindingStore`
가 최초 binding 요청에서 DB를 열며, 실패하면 project binding과 서버 기능만
unavailable이 된다. 앱 화면·로컬 열기·편집·저장은 계속 동작한다.

## V1 생성과 검증

앱 resource는 8-4의 `Scripts/fixtures/SyncV2StoreSchemaV1.sql` 원본 하나만
사용한다. 실행 전 resource UTF-8 bytes의 SHA-256을 계산하고 fixture의
`design-fixture-v1` 표식을 실제 checksum으로 치환한다. schema와 migration
기록은 fixture의 `BEGIN IMMEDIATE` transaction 안에서 함께 생성된다.

모든 connection은 다음을 설정하고 실제 값을 다시 읽어 확인한다.

- `foreign_keys = ON`
- `journal_mode = WAL`
- `synchronous = FULL`
- busy timeout 10초

재오픈 시 다음을 모두 통과해야 한다.

- `user_version == 1`
- migration 이름과 resource SHA-256 일치
- 여섯 필수 table 존재
- `quick_check == ok`
- `foreign_key_check` 결과 없음
- project/document/batch/operation/conflict UUID 열의 의미 검증

버전 0의 빈 DB만 V1으로 올린다. version 0에 사용자 table이 있거나, 앱보다
높은 version, checksum 불일치, 일부 손상 row가 있으면 원본을 삭제하거나
재생성하지 않고 sync만 비활성화한다.

## 강제 종료 복구

open 검증 뒤 하나의 `BEGIN IMMEDIATE` transaction에서:

- `inflight` operation을 같은 operation ID·payload·attempts로 `pending` 복구
- `processing` batch를 자식 operation 상태에 따라 ready/attention/completed로
  복구

operation을 새로 생성하거나 합치거나 순서를 결정하지 않는다. enqueue, claim,
retry backoff와 문서별 순서는 10-2 범위다.

## 9-4 binding 연결

`SyncV2Store`는 `ProjectBindingStoring`을 구현하고 `sync_projects`에 binding을
upsert한다. server project UUID의 partial unique index를 그대로 사용한다.
연결 해제는 동일 local row를 `local_only`로 바꾸며 DB나 원격 project를
삭제하지 않는다.

## 자동 검증

`SyncV2StoreTests`가 다음을 실제 SQLite 파일로 검증한다.

- 새 DB와 resource checksum, 전체 schema, WAL
- close/reopen과 binding 보존
- 빈 version 0 → V1
- 더 높은 version과 checksum mismatch 보존·거부
- 실패 transaction 전체 rollback
- 일부 손상 UUID row 보존·비활성화
- 중복 document ID·operation ID 거부
- pending operation 1,000개 재오픈
- inflight의 동일 ID·attempts pending 복구
- lazy binding adapter의 실제 `sync_projects` 저장

실제 operation enqueue API와 로컬 저장 연결은 추가하지 않는다.
