# 10-2 enqueue와 문서별 순서 구현

## 범위

`SyncV2Store.enqueue(_:)`가 이미 서버에 연결된 local project의 mutation
batch를 SQLite에 영구 기록한다. 아직 `LocalDocumentStore` 호출 경로에는
연결하지 않으며 operation claim, 서버 전송, retry, success, conflict 처리는
10-2 범위에 포함하지 않는다.

## 원자적 batch

하나의 `BEGIN IMMEDIATE` transaction 안에서 다음을 수행한다.

1. 연결된 project UUID와 owner subject를 snapshot으로 확정한다.
2. version 1 canonical JSON을 sorted key와 lowercase UUID로 인코딩하고
   SHA-256 payload hash를 만든다.
3. batch row를 기록한다.
4. document row를 생성하거나 기존 lane을 검증한다.
5. document별 `next_document_sequence`를 읽어 operation에 배정한다.
6. 모든 immutable payload를 operation row로 기록한다.
7. document의 다음 sequence와 pending 상태를 갱신한다.
8. 실제 operation ID 목록과 mutation 수가 같을 때만 commit한다.

중간 operation ID 충돌, path constraint, foreign key 오류가 하나라도 발생하면
batch·새 document·operation·sequence 증가가 모두 rollback된다.

## 문서별 순서와 operation ID

- 같은 document UUID는 sequence 1부터 단조 증가한다.
- 다른 document UUID는 각각 독립된 lane을 가진다.
- 동시 enqueue도 하나의 store actor가 직렬화해 sequence를 중복 배정하지 않는다.
- 앞 operation이 nonterminal이면 뒤 operation의 `base_revision`은 nil이다.
- rename, move, delete, restore도 각각 새 operation ID와 sequence를 보존한다.
- 재실행 후에도 operation ID, payload, sequence와 pending 상태는 유지된다.
- ensure-project는 document ID와 sequence가 없는 project lane operation이다.

10-2에서는 operation을 claim하거나 상태를 inflight로 바꾸지 않는다.

## 안전한 멱등성과 비병합 정책

같은 batch ID와 완전히 같은 canonical payload를 다시 enqueue하면 새 row를
만들지 않고 기존 operation ID 목록을 반환한다. 같은 batch ID에 다른 payload를
사용하면 `batchIDReused`로 거부한다.

서로 다른 batch ID의 저장은 활성 operation이 있으면 본문이 같아도 자동 병합하지
않는다. 10-5부터는 일반 저장에 한해 서버 revision이 1 이상이고 server path와
base content가 모두 같으며 활성 operation이 없을 때만 no-op으로 완료한다.
rename·move·delete·restore 의미는 생략하지 않는다. 정확한 batch replay는
no-op batch에도 동일하게 적용한다.

## 입력 검증

- local-only project에는 enqueue하지 않는다.
- batch는 operation을 하나 이상 가져야 한다.
- batch 내부 operation ID는 중복될 수 없다.
- ensure-project 이름은 공백일 수 없다.
- document operation은 ensure-project kind를 사용할 수 없다.
- save generation은 음수일 수 없다.
- 상대 path는 비어 있거나 절대 path이거나 `.`·`..`·역슬래시를 포함할 수 없다.
- content byte count와 SHA-256은 호출자가 아닌 store가 UTF-8 원문에서 계산한다.

## 10-3 정지 경계

다음은 구현하지 않았다.

- 편집기 snapshot과 `LocalDocumentStore` 저장 세션 연결
- IME 확정 시점 판단
- 로컬 저장 성공/queue 실패 UI 상태
- operation claim·네트워크 전송
- retry backoff·success·conflict 상태 전이
