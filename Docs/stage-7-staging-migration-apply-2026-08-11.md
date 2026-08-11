# Stage 7 staging migration apply — 2026-08-11

## 범위와 판정

- 대상: `WriterPad Staging`
- project ID: `mhpnszcorfzrvhyondxr`
- endpoint: `https://mhpnszcorfzrvhyondxr.supabase.co`
- PostgreSQL: `17.6.1.155` (`17.6`)
- 적용 방식: Supabase CLI `2.113.0`의 linked `db push`
- 결과: 승인된 migration 3개 모두 성공
- 적용 후 판정: `AWAITING_STAGING_FUNCTIONAL_TEST_APPROVAL`
- production/기존 운영 project 변경: 없음
- allowlist 활성화, project 승격, 테스트 사용자·문서 생성: 없음
- PR #4 병합 및 Stage 8 시작: 수행하지 않음

비밀번호, access token, service-role key, connection string 및 사용자 row 값은
이 문서와 로그에 포함하지 않았다.

## 적용 source pin

```yaml
pr: https://github.com/ChocoS-yrup/Writerpad/pull/4
applied_source_head: 3045417821371a0e5220c3be90d9b46353dbf711
contract_version: 0.2.0
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
migrations:
  - version: 20260811000000
    file: 20260811000000_operational_v2_schema_baseline_snapshot.sql
    source_sha256: 323c6e092cd9afabb438eaf233b7e63abd0195d5e1a91a5f5fe3fe5940699198
  - version: 20260811010000
    file: 20260811010000_sync_contract_0_1_0_foundation.sql
    source_sha256: afd86ef2c565e5932dafd4847e351d5fa218590e357a25de9c35dbb87b94d44a
  - version: 20260811020000
    file: 20260811020000_sync_contract_0_1_0_rpcs.sql
    source_sha256: 60775ced603122aae2f4a53a7cfaf39299676c647b839feaf9527210ec514b46
```

Supabase의 `supabase_migrations.schema_migrations`는 현재 `version`, `name`,
`statements` 열만 가지며 checksum 열은 없다. 위 SHA-256은 적용 직전 source file
byte를 fail-closed로 비교한 값이다. CLI dry-run과 실제 apply 출력에서 정확히 이
세 version/file만 같은 순서로 선택됐고, apply 후 remote ledger version과 일치했다.

## 적용 전 재확인

```yaml
linked_project_ref: mhpnszcorfzrvhyondxr
git_head_match: passed
migration_checksum_match: passed
remote_ledger_versions: []
app_table_catalog: empty
dry_run_migrations:
  - 20260811000000_operational_v2_schema_baseline_snapshot.sql
  - 20260811010000_sync_contract_0_1_0_foundation.sql
  - 20260811020000_sync_contract_0_1_0_rpcs.sql
```

## 정식 migration 적용 결과

CLI는 다음 순서로 세 migration을 적용하고 `Finished supabase db push.`를
반환했다. 실패나 수동 수정, 개별 재실행, ledger 조작은 없었다.

```yaml
20260811000000: applied
20260811010000: applied
20260811020000: applied
remote_ledger_after:
  - 20260811000000
  - 20260811010000
  - 20260811020000
```

## 적용 후 읽기 전용 검증

실DB 검증 SQL은 `BEGIN TRANSACTION READ ONLY`에서 metadata와 count만 읽고
마지막에 `ROLLBACK`했다. application RPC는 호출하지 않았고 사용자 row, 문서
본문·경로 및 auth metadata는 읽지 않았다.

```yaml
transaction_read_only: on
postgresql_version: 17.6
contract_allowlist:
  row_count: 1
  contract_version: 0.2.0
  canonical_contract_bytes: 23256
  canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
  enabled: false
  revoked: false
rpc_signatures:
  - public.atomic_structure_commit(p_request jsonb) returns jsonb
  - public.document_commit(p_request jsonb) returns jsonb
realtime_publication:
  - public.documents
  - public.folders
```

필수 baseline/Stage 7 relation 19개가 모두 catalog 및 generated type metadata에
존재했다. public app relation 15개는 모두 RLS `enabled=true`, `forced=true`였다.

정확한 count 결과:

```yaml
auth.users: 0
projects: 0
project_members: 0
documents: 0
document_versions: 0
edit_leases: 0
folders: 0
folder_versions: 0
private.project_purge_tombstones: 0
project_sync_settings: 0
project_sync_migrations: 0
tree_orders: 0
sync_batches: 0
sync_operations: 0
sync_operation_attempts: 0
sync_operation_events: 0
sync_batch_results: 0
```

Foundation이 의도적으로 설치하는 metadata만 존재한다:

```yaml
private.sync_contract_allowlist: 1
private.unicode15_assigned_ranges: 707
private.unicode15_casefold: 1530
```

## 검증 도구 관련 비영향 실패

Schema-only dump는 로컬 Docker 부재로 시작 전에 중단됐다. migration 적용이나
DB transaction 실패가 아니며 staging 상태를 변경하지 않았다. 필요한 catalog,
signature, RLS, Realtime 및 count 검증은 Supabase CLI metadata 조회와 별도의
READ ONLY/ROLLBACK query로 완료했다.

## 다음 승인 gate

이번 승인 범위는 완료됐다. 다음 작업에는 별도 승인이 필요하다.

1. 테스트 사용자/project/document를 사용하는 staging 기능 검증
2. `document_commit`과 `atomic_structure_commit` 실제 왕복
3. replay, rollback, cancellation, response-loss 및 restart 검증
4. 결과 검토 후 PR #4 병합 여부 결정

기능 검증과 PR #4 병합이 완료되기 전에는 Stage 8을 시작하지 않는다.
