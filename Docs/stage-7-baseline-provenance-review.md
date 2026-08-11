# Stage 7 baseline provenance review

Review date: 2026-08-11

## Decision

`PARTIAL_OR_LATER_SCHEMA`

The three SQL files are a coherent repository and CI baseline candidate. An
approved read-only comparison proved that the operational database contains
the baseline core plus later folder and project-trash extensions, while the
three baseline version IDs are missing from the migration ledger. The
reference files are therefore not a complete authoritative operational
history and must not yet be promoted or applied.

Only explicit `READ ONLY` transactions ending in `ROLLBACK` were executed. No
migration, DDL, DML or application RPC was executed. No contract allowlist,
project mode, or project row was changed.

## Reviewed inputs and Git provenance

| Repository path | SHA-256 | Introduced by | Current main blob |
|---|---|---|---|
| `참조파일/20260714000000_supabase_v2_protocol.sql` | `937e2682120abf8181e488d47b0555d7b8c5f03992831f8b90918f244ab40295` | `5a0744d80242c2a93ee3c0dd489460c326dda27d` (`chore: freeze stage 7 local baseline`) | `bf94a39fe9a45922d72c604bf2a8e3d804288a56` |
| `참조파일/20260714010000_windows_v2_client_support.sql` | `75d2221a5a9d5b64346c1d3209a75985d647934625c233f705420d93c594a786` | `5a0744d80242c2a93ee3c0dd489460c326dda27d` (`chore: freeze stage 7 local baseline`) | `cc5a56e937ff1671ca1a39ffec87bfed3476309a` |
| `참조파일/20260729000000_repair_owner_project_membership.sql` | `8827a8f6686b2dbf096894eb71a660606fdb5b1936fce0d0e084a8b3986ab489` | `2178af4ecd8d9a1acec2f0fc356576d30235fabf` (`feat: 동기화 v2 및 실기기 복구 구현`) | `1ef7d6173de106eec3c1988059515ddbbe4071e2` |

All three introducing commits are ancestors of current `origin/main`
`fcd99b7098b9a04bd93c585d89b16588aa482530`. Git history contains no earlier
formal `supabase/migrations` origin for these blobs: the first two entered the
repository directly as frozen reference files, and the third entered later as
a repair migration reference file.

## Operational database relationship

Repository documents describe the first two SQL files as previously applied,
but the same documents explicitly state that this claim was not verified
against the operational Supabase migration ledger or catalog. The sync
contract also says repository migrations are not proof of deployed state.

The approved staging preflight found a blank staging project, not a copy of the
operational v2 schema. A later, separately approved metadata-only inspection of
`ChocoS-yrup's Web` established the operational relationship recorded below.

## Approved operational read-only comparison

```yaml
dashboard_name: ChocoS-yrup's Web
project_id: isotfvmlklrxspusjpcn
endpoint: https://isotfvmlklrxspusjpcn.supabase.co
region: ap-northeast-1
postgresql_version: 17.6
transaction_read_only: on
final_classification: PARTIAL_OR_LATER_SCHEMA
```

Every catalog query ran inside `begin transaction read only; ... rollback;`.
No user row values, auth metadata, document content or document path was read.

### Extensions

- `pg_stat_statements` 1.11 in `extensions`
- `pgcrypto` 1.3 in `extensions`
- `plpgsql` 1.0 in `pg_catalog`
- `supabase_vault` 0.3.1 in `vault`
- `uuid-ossp` 1.1 in `extensions`

### Migration ledger

`supabase_migrations.schema_migrations` exists. The three baseline IDs are all
absent. The ledger contains only these later rows:

| Version | Name | Statement MD5 |
|---|---|---|
| `20260808205433` | `tighten_folder_read_auth_policies` | `eca6c32684bb18c90894e728a903c996` |
| `20260808210030` | `restore_original_folder_read_policies` | `a13df56bd0d875e8f80d9cab8f023bd9` |
| `20260808210106` | `reapply_folder_read_auth_policies` | `eca6c32684bb18c90894e728a903c996` |

This is neither an exact baseline ledger nor a wholly missing ledger. It is a
later partial ledger over a schema whose earlier provenance is not recorded.

### Baseline match

The baseline definitions match operational catalog for:

- `project_members`, `documents`, `document_versions`, and `edit_leases`
  columns and constraints;
- all baseline explicit and constraint-backed indexes on those tables;
- RLS enabled and forced on all five baseline tables;
- the four baseline member-read policies;
- `documents` membership in `supabase_realtime`;
- eight of nine baseline helper/RPC canonical bodies;
- final `ensure_project(uuid,text)` exactly matching the third owner-membership
  repair file.

`projects` retains all baseline columns and constraints but has later
`trashed_at` and `trashed_by` columns, trash-state/FK constraints, and
`projects_owner_trash_idx`.

### Canonical function-body digest comparison

Digest rule: MD5 of UTF-8 function body after CRLF-to-LF normalization and
trimming boundary spaces, tabs and newlines.

| Function | Candidate MD5 | Operational MD5 | Result |
|---|---|---|---|
| `private.content_sha256(text)` | `ed979000f06a19d8daa7885242bc49e3` | same | exact |
| `private.has_project_role(uuid,uuid,text)` | `0a97f4c7c5f292454d583bb14c262af0` | `2b74956ef98a292c85b2af080c60cb73` | later change |
| `private.is_valid_relative_path(text)` | `3939c499139abaac69cee002ab0d442a` | same | exact |
| `public.acquire_edit_lease(uuid,uuid,integer)` | `9a5291e54d18a2e430bd05d0bdc315cf` | same | exact |
| `public.commit_document(uuid,uuid,bigint,uuid,uuid,text,text,boolean,uuid)` | `49def67d084b4c4bd2326c788dabfd6e` | same | exact |
| `public.ensure_project(uuid,text)` | `7425a800982652b0b55c63f48061e3f4` | same | exact repair definition |
| `public.get_edit_lease(uuid,uuid)` | `7f8a49e3ae235a5ec455c4bf15f75cc9` | same | exact |
| `public.release_edit_lease(uuid,uuid,uuid)` | `c904fd969c595bc6bb114ad996c0cf09` | same | exact |
| `public.renew_edit_lease(uuid,uuid,uuid,integer)` | `b8548ab1cef4c7b09714266e1928eddb` | same | exact |

The operational `has_project_role` adds `projects.trashed_at is null`, which is
consistent with a later project-trash extension and must not be overwritten by
the older baseline body.

### Later operational objects missing from the three baseline files

- tables: `public.folders`, `public.folder_versions`,
  `private.project_purge_tombstones`;
- project trash columns, constraints and index;
- folder constraints and indexes, including live lower-cased name uniqueness;
- policies: `folders_read_members`, `folder_versions_read_members`;
- functions: `private.is_valid_entry_name`, `public.commit_folder`,
  `public.get_project_status`, `public.list_trashed_projects`,
  `public.trash_project`, `public.restore_project`, `public.purge_project`;
- trigger-returning helper functions `touch_editor_locks_locked_at` and
  `touch_writing_contents_updated_at` remain, although no non-internal trigger
  exists in `public` or `private`;
- `public.folders` is also in `supabase_realtime`.

The current repository contains no SQL migration source for the project-trash
and legacy folder object set. The three recorded ledger rows cover only folder
read-policy changes, not creation of those objects.

### Sequences, triggers and row counts

- public/private sequences: none
- public/private non-internal triggers: none

Only counts were read:

| Table | Count |
|---|---:|
| `projects` | 8 |
| `project_members` | 8 |
| `documents` | 377 |
| `document_versions` | 597 |
| `edit_leases` | 0 |
| `folders` | 91 |
| `folder_versions` | 100 |
| `private.project_purge_tombstones` | 39 |

## CI fixture status

The files are active CI inputs. `.github/workflows/server-contract.yml` runs:

1. `supabase/tests/bootstrap_postgres.sql`;
2. the three reviewed reference SQL files in version order;
3. the two Stage 7 migrations.

The bootstrap creates test-only `anon`/`authenticated` roles, `auth.users` and
`auth.uid()`. This proves a fresh PostgreSQL 16 test database can establish the
expected v2 shape before Stage 7. It does not validate a Supabase migration
ledger, production data compatibility, production drift, or PostgreSQL 17.6.

## Object manifest

### Schemas and extensions

- creates `extensions` and `private` if missing;
- installs `pgcrypto` into `extensions` if missing;
- revokes `private` schema access from `public`, `anon`, and `authenticated`;
- grants authenticated use of `private` only where required.

### Tables, columns and principal constraints

1. `public.projects`
   - `project_id uuid` primary key
   - `owner_id uuid` not null, FK to `auth.users(id)`, delete restrict
   - `name text` not null and non-blank
   - `created_at`, `updated_at` timestamptz
2. `public.project_members`
   - `project_id`, `user_id` composite primary key
   - FKs to `projects` and `auth.users`, delete cascade
   - `role` constrained to `owner`, `editor`, or `viewer`
   - `created_at` timestamptz
3. `public.documents`
   - UUID primary identity and project FK
   - validated `relative_path`, `content` limited to 10 MiB
   - revision/current-version fields, tombstone fields and audit users/times
   - deleted-state consistency check
   - unique `(document_id, project_id)`
   - deferred current-version FK to `document_versions`
4. `public.document_versions`
   - UUID primary version identity
   - document/project/revision/base revision/operation/device metadata
   - operation kind constrained to create/update/move/delete/restore
   - validated path, content, SHA-256 and tombstone snapshot
   - FK to document identity, unique document revision, global operation ID,
     and document/version pair
5. `public.edit_leases`
   - document primary key/FK
   - unique generated lease token
   - holder user/device and acquired/renewed/expiry timestamps
   - expiry-after-renewal check

### Explicit indexes

- `project_members_user_project_idx`
- `documents_live_path_uidx` (unique for non-deleted sibling path)
- `documents_project_revision_idx`
- `documents_project_updated_idx`
- `document_versions_project_created_idx`
- `edit_leases_expiry_idx`

Primary-key and unique constraints also create their normal backing indexes.

### RLS, policies and grants

RLS is enabled and forced on all five tables. Authenticated member-read
policies exist for `projects`, `project_members`, `documents`, and
`document_versions`. `edit_leases` intentionally has no direct read policy or
table grant so lease tokens are exposed only through RPC responses. App roles
receive no direct table write grants.

Policy names:

- `projects_read_members`
- `project_members_read_members`
- `documents_read_members`
- `document_versions_read_members`

### Functions and RPC signatures

Private helpers:

- `private.is_valid_relative_path(text) -> boolean`
- `private.content_sha256(text) -> text`
- `private.has_project_role(uuid, uuid, text) -> boolean`

Public security-definer RPCs:

- `ensure_project(uuid, text) -> jsonb`
- `acquire_edit_lease(uuid, uuid, integer) -> jsonb`
- `renew_edit_lease(uuid, uuid, uuid, integer) -> jsonb`
- `release_edit_lease(uuid, uuid, uuid) -> boolean`
- `get_edit_lease(uuid, uuid) -> jsonb`
- `commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid) -> jsonb`

The first and second files contain byte-equivalent `ensure_project` function
definitions. The third file is the final definition and adds owner-only repair
of a missing owner membership before updating the project.

### Triggers and publication

- no trigger is created by any reviewed file;
- the first file conditionally adds `public.documents` to the existing
  `supabase_realtime` publication;
- no reviewed file creates a Realtime publication.

## Dependency order

1. The first file requires Supabase platform prerequisites: roles `anon` and
   `authenticated`, `auth.users`, and `auth.uid()`. It creates the v2 schema.
2. The second file requires the first file's projects, project-membership and
   private role helper. It re-applies `ensure_project` without changing its
   effective body.
3. The third file requires the same baseline and replaces `ensure_project`
   with the owner-membership repair behavior.
4. Stage 7 foundation requires at least `projects`, `project_members`,
   `documents`, and `document_versions` from the first file.
5. Stage 7 RPC migration requires the completed Stage 7 foundation.

Changing this order is not supported.

## Blank database and rerun safety

- Vanilla blank PostgreSQL: not directly applicable because Supabase auth
  roles/schema/function are prerequisites. CI supplies a test bootstrap.
- Blank Supabase project: structurally plausible, but not executed because
  staging baseline application was not approved. PostgreSQL 17.6 remains
  unverified for these three files.
- First file raw rerun: not idempotent. It uses unguarded `create table`,
  `create index`, and `create policy`. A rerun fails when objects already
  exist. Its outer transaction makes that failure atomic.
- Second and third file rerun: idempotent once prerequisites exist because
  they use `create or replace function` plus repeatable revoke/grant.

The files contain no migration-ledger writes. Running them as raw SQL cannot by
itself establish an authoritative `supabase_migrations.schema_migrations`
history. A formal deployment mechanism and an approved ledger strategy are
required.

## User data and secret review

- no user/project/document rows are embedded or migrated by the SQL files;
- DML statements are inside RPC bodies and execute only when the RPC is later
  called;
- no endpoint, password, API key, service-role key, access token, connection
  string or user email is present;
- `lease_token` is a generated runtime column/response field, not an embedded
  credential.

## Migration-ledger collision risk

- approved staging: ledger relation is absent, so no currently observable
  version collision exists there;
- operational project: ledger exists but none of the three baseline IDs is
  present; three later folder-policy IDs are present;
- formalizing the reference files with the historical IDs could collide with
  existing production ledger rows, or could attempt to recreate a schema that
  was applied manually without ledger entries;
- both cases require read-only operational ledger and catalog comparison before
  choosing copy-as-is, ledger reconciliation, or new corrective migration IDs.

## Conditional promotion design — not yet approved or implemented

If operational evidence later proves an exact match and confirms the three IDs
are the correct authoritative history, the proposed changed paths are:

- add `supabase/migrations/20260714000000_supabase_v2_protocol.sql`
- add `supabase/migrations/20260714010000_windows_v2_client_support.sql`
- add `supabase/migrations/20260729000000_repair_owner_project_membership.sql`
- update `.github/workflows/server-contract.yml` to consume the formal paths
- add a checksum/object-manifest verifier under `supabase/tests/`
- update the Stage 7 handoff with the operational ledger/catalog evidence

A byte-for-byte copy would retain the three reviewed SHA-256 values. No such
copy was made because authoritative operational provenance is not established.

## Required next gate

Do not promote or apply the three reference files yet. Reconstruct the missing
folder and project-trash migration provenance from repository history and the
metadata-only catalog snapshot. The result must define a complete ordered
blank-database chain without replacing the later operational
`has_project_role` or losing folder/project-trash behavior.

After that chain has independent PostgreSQL 17.6 apply and replay checks, show
the proposed formal `supabase/migrations` paths and checksums and obtain a new
staging-only approval. Do not replay the historical baseline SQL against this
operational project and do not reconcile its ledger without a separate plan
and approval.
