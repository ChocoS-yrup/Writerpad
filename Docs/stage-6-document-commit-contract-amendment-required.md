# Stage 6 document-commit contract amendment — resolved

> Resolved by sync-contract 0.2.0 in PR #5, merged as
> `fcd99b7098b9a04bd93c585d89b16588aa482530`. This file is retained as the
> historical reason Stage 7 initially stopped rather than inventing an RPC.

## 판정

```yaml
status: BLOCKED_CONTRACT_AMENDMENT_REQUIRED
stage_7_pr: https://github.com/ChocoS-yrup/Writerpad/pull/4
stage_7_head: a57f698542cc1ca66fc9210b591da466d318b746
released_contract_version: 0.1.0
released_contract_sha256: fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46
staging_write: NOT_STARTED
production_write: NOT_STARTED
```

Stage 7 시작 게이트에서 released contract가 protocol 3 문서 본문 commit을
규범적으로 정의하는지 확인했다. 계약은 document operation의 공통 immutable
intent와 batch provenance는 정의하지만 실제 문서 commit wire는 정의하지 않는다.

## 직접 확인한 계약 범위

- `sync-contract/protocol.json`
  - `document` entity kind와 create/update/delete/restore intent를 열거한다.
  - `MIGRATING` 및 `ID_BASED` content write에 protocol 3을 요구한다.
  - 모든 protocol 3 operation에 `CONTRACT_BATCH` provenance를 요구한다.
  - 규범 RPC/wire로는 structure 전용 `atomic_structure_commit`만 지정한다.
- `sync-contract/atomic-structure-commit.schema.json`
  - ordered structure intent의 request/success/failure만 정의한다.
- `sync-contract/README.md`와 `TRACEABILITY.md`
  - package에 protocol 3 document commit request/response schema를 열거하지 않는다.
- `Docs/SyncV2Contract.md`
  - 기존 `commit_document(...)`를 정의하지만 implementation 문서이며 released
    contract package의 canonical digest 대상이 아니다.

## 계약 개정에서 결정해야 할 규범 항목

1. protocol 3 document commit RPC 이름과 atomic boundary
2. exact request/success/failure JSON schema
3. batch ID, operation ID, document ID, folder ID 및 sequence 관계
4. base revision, content bytes, empty content, tombstone 및 restore 표현
5. content SHA-256과 batch payload SHA-256 canonicalization
6. immutable intent 비교 필드와 `OPERATION_ID_REUSED` 조건
7. identical replay의 exact response 및 response-loss 복구
8. rebase의 새 batch/operation과 `supersedes_operation_id`
9. cancellation 경합과 terminal 이후 동작
10. stable error code와 partial/ambiguous response 거부 규칙
11. structure batch와 document commit 사이의 ordering/commit barrier
12. protocol 1/2 legacy adapter와 protocol 3 enforcement 경계

## 필수 conformance 추가

- 일반 문서 create/update/delete/restore
- 의도적인 zero-byte/empty-string 문서 commit
- 동일 request replay와 changed replay 거부
- response loss 후 replay
- revision conflict와 immutable rebase
- cancellation 및 duplicate cancellation
- document content와 structure batch ordering
- crash/restart 및 server restart
- legacy/new client 혼재
- digest/capability mismatch fail-closed

계약 개정은 version, schema, vectors, verifier, traceability 및 canonical digest를
함께 변경하고 정상 review/병합해야 한다. Stage 7은 새 contract merge commit과
digest를 pin한 후 기존 PR #4에서 server implementation을 재개해야 한다.

## 재개 조건

```yaml
contract_amendment_merged: required
new_contract_version: required
new_contract_git_commit: required
new_contract_content_commit: required
new_canonical_bytes: required
new_canonical_sha256: required
document_commit_vectors_passed: required
```

이 조건 전에는 protocol 3 문서 RPC 구현, staging migration, project 승격 및
Windows/iPad Stage 8·9 진행을 허용하지 않는다.
