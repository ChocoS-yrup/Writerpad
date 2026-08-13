# storage-name-v2 server implementation — 2026-08-13

## Scope and release pin

This stage implements contract `0.3.0` in the repository's PostgreSQL server
chain without connecting to a Supabase project or changing deployed state.

```yaml
contract_version: 0.3.0
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
contract_content_commit: 3843b05aa91461e1541f5ebaa14557dc3dc2b39c
canonical_contract_bytes: 24777
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c
base_main_sha: bebb53746a1e9f06532a04f2084f1b694db5f749
```

The new allowlist row is inserted with `enabled=false`. This stage does not
run a remote migration, enable an allowlist row, promote a project, inspect or
modify operational data, or change a client pin.

## Additive migration

`20260813063251_sync_contract_0_3_0_storage_name_v2.sql` was created with
Supabase CLI `2.113.0`. The three existing migration files remain byte-for-byte
unchanged and are checked by exact SHA-256 before server validation proceeds.

The new migration adds private immutable lookup tables generated from the
released contract assets:

- Unicode 14.0.0 assigned baseline: 698 ranges / 282,230 scalars
- excluded scalars: 5 ranges / 137,836 scalars
- frozen Unicode 15.0.0 full default casefold: 1,530 mappings
- nonzero canonical-combining-class lookup: 912 baseline scalars

The first three tables are regenerated only from the contract JSON assets and
their canonical digests. Canonical combining class is not a fifth frozen
contract asset: contract 0.3.0 leaves platform NFKC and CCC bounded by its
pre/post rejection rules. The server lookup is generated with the existing
Python `3.12.13` / Unicode `15.0.0` CI toolchain after first filtering through
the frozen Unicode 14.0.0 input baseline.

The implementation follows the normative order: pre-NFKC baseline rejection,
pre-NFKC exclusion, supplementary adjacency rejection, NFKC, frozen casefold,
NFKC, post-NFKC control/separator rejection, defensive baseline recheck,
trailing ASCII space/full-stop removal, and Windows reserved-name rejection.

## Compatibility and rollout boundary

The migration preserves the reviewed storage-name-v1 function under
`private.storage_name_v1_legacy`. Existing `0.2.0` requests and direct server
calls continue to use it. Only a batch that passes exact allowlist validation
for the `0.3.0` digest sets a transaction-local route to storage-name-v2.

Manual project migration remains the only project-mode transition. Its target
must be an explicitly enabled, non-revoked allowlist entry. Validation checks
live folder and document names and their combined sibling collision namespace;
completion updates their stored collision keys only after validation succeeds.
No project is migrated by applying this SQL file.

## Reproducible verification

```text
python -m pip check
python sync-contract/scripts/verify_contract.py
python supabase/scripts/generate_casefold_sql.py --check \
  supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql
python supabase/scripts/generate_casefold_sql.py --check-v2 \
  supabase/migrations/20260813063251_sync_contract_0_3_0_storage_name_v2.sql
python supabase/tests/verify_stage7_server.py
git diff --check
```

PostgreSQL CI applies and reruns the complete four-migration chain on
PostgreSQL `17.6`, then runs the existing Stage 7 regression SQL and the new
storage-name-v2 SQL suite. The latter covers SN-001 through SN-029, the disabled
allowlist pin, v1 compatibility, validated v2 routing, and a rollback-contained
synthetic baseline mutation that reaches the real defensive post-NFKC recheck.

## Explicit limitations

- No repository migration proves that a deployed Supabase project has applied it.
- No allowlist row is enabled outside the disposable CI database.
- No existing project or incident is inspected, renamed, promoted, or repaired.
- Client pins remain at their previous release until separately approved server
  deployment and allowlist activation evidence exists.
