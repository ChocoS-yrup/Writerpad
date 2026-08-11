# Stage 7 staging migration attempt — 2026-08-11

## Scope and authorization

- Environment: staging only
- Project: `WriterPad Staging`
- Project ID: `mhpnszcorfzrvhyondxr`
- Endpoint: `https://mhpnszcorfzrvhyondxr.supabase.co`
- Region: `ap-southeast-1`
- PostgreSQL: `17.6`
- Production changes: none
- Contract allowlist enablement: not attempted
- Project mode or LEGACY promotion: not attempted
- User data creation/import: not attempted

## Approved migrations

1. `supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql`
   - SHA-256: `afd86ef2c565e5932dafd4847e351d5fa218590e357a25de9c35dbb87b94d44a`
2. `supabase/migrations/20260811020000_sync_contract_0_1_0_rpcs.sql`
   - SHA-256: `60775ced603122aae2f4a53a7cfaf39299676c647b839feaf9527210ec514b46`

Both local checksums matched the approved values immediately before execution.

## Before state

- `supabase_migrations.schema_migrations`: absent
- `public`/`private` application relations: none
- `public`/`private` application functions: none
- Required v2 baseline relations: all absent
  - `public.projects`
  - `public.project_members`
  - `public.documents`
  - `public.document_versions`
- Project and legacy rows: not applicable because `public.projects` is absent
- Migration ID collision: none; the migration ledger relation is absent

## Execution result

The foundation migration was submitted unchanged. It failed inside its outer
transaction at the explicit baseline guard:

```text
ERROR: P0001: STAGE7_BASELINE_MISSING
DETAIL: Apply and verify the deployed v2 baseline before this additive migration.
CONTEXT: PL/pgSQL function inline_code_block line 13 at RAISE
```

The RPC migration was not executed.

## Transaction and after state

The foundation file begins with `begin;` and ends with `commit;`. The guard
raised before the Stage 7 tables were created, and PostgreSQL rolled back the
transaction. A separate read-only catalog query confirmed:

- `supabase_migrations.schema_migrations`: absent
- `private` schema: absent
- `public`/`private` application relations: none
- `public`/`private` application functions: none
- all four required baseline relations: absent
- Stage 7 allowlist row: not created
- project/legacy rows: not created

The existing `pgcrypto` extension was visible after rollback; no extension
state was changed as part of this failed transaction.

## Conformance and rerun status

- PostgreSQL 17.6 schema/RPC conformance: not run; foundation did not apply
- `document_commit(jsonb)`: absent
- `atomic_structure_commit(jsonb)`: absent
- same-migration rerun verification: not run because the prerequisite baseline
  is missing and the same deterministic guard would fail again
- deployed RPC catalog verification: not applicable; RPC migration was not run

## Required decision

The two approved Stage 7 migrations are additive migrations over the deployed
v2 baseline. This staging project is blank and does not contain that baseline.
Do not modify these migrations or guess a baseline.

The repository CI currently establishes its test baseline in this order before
the Stage 7 files:

1. `참조파일/20260714000000_supabase_v2_protocol.sql`
   - SHA-256: `937e2682120abf8181e488d47b0555d7b8c5f03992831f8b90918f244ab40295`
2. `참조파일/20260714010000_windows_v2_client_support.sql`
   - SHA-256: `75d2221a5a9d5b64346c1d3209a75985d647934625c233f705420d93c594a786`
3. `참조파일/20260729000000_repair_owner_project_membership.sql`
   - SHA-256: `8827a8f6686b2dbf096894eb71a660606fdb5b1936fce0d0e084a8b3986ab489`

These files are under `참조파일`, not `supabase/migrations`, so their status as
the authoritative deployable baseline and the intended migration-ledger
strategy must be reviewed before staging use. Obtain a new explicit
staging-only approval for the verified baseline set. Then repeat the Stage 7
preflight and request approval to retry the two Stage 7 migrations.
