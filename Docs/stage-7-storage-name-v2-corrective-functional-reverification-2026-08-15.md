# Stage 7 storage-name-v2 corrective functional revalidation

Date: 2026-08-15 (Asia/Seoul)
Target: WriterPad Staging (`mhpnszcorfzrvhyondxr`)
Server base: `f67441cc6b1da0469cfae3be90edd7a4e57b5c2a`
Run: `0cafa16f-aa12-444b-91f6-ca8282b12996`
Synthetic project: `c1b0cdf5-ee14-4794-a11f-b5576dd0744d`
Client build: `stage7-storage-v2-0cafa16f-aa12-444b-91f6-ca8282b12996`

## Verdict

`BLOCKED` — the fail-closed path completed successfully. The 0.3.0 allowlist row is disabled and the full Stage 7 functional suite was not retried.

The first functional execution stopped because the validation block used `content=content`, which PostgreSQL rejected as an ambiguous reference between the PL/pgSQL variable and the table column. The error occurred inside the transaction after the first RPC invocation; PostgreSQL rolled back the complete transaction. This is a validation-harness failure, not a server response mismatch, but the approval required stopping at the first discrepancy and prohibited retrying the same run.

## Preflight and activation

- Project identity, URL, and `ACTIVE_HEALTHY` status matched the approved target.
- The migration ledger exactly contained `20260811000000`, `20260811010000`, `20260811020000`, `20260813063251`, and `20260814182850`.
- The corrective migration file SHA-256 was `13edfc69a9546c7c4b6cadf07be010d066be4d5e7b30d746835819ef77a4b221`.
- The exact 0.3.0 allowlist row count was 1, with `enabled=false` and `revoked_at=null`; total enabled rows were 0.
- Preflight global fingerprint: `f1517a1770d78e148c6fa4be1f0c1793`.
- Existing failed-fixture fingerprint: `dbe4a86a76990e0a0c01b7965257fa28`.
- Existing counts, project pins, wrapper definitions, and wrapper/legacy ACLs matched the previous handoff.
- A guarded transaction changed only the exact row's `enabled` value from false to true.
- A separate connection confirmed exactly one enabled row, the same five migrations, unchanged counts/fingerprints, and zero in-progress project migrations.

## Gates completed before the stop

- Exact 0.3.0 contract validation: PASS.
- Wrong digest rejection with persistent write 0: PASS.
- Capability mismatch rejection with persistent write 0: PASS.
- Validated batch selected storage-name-v2: PASS.
- Transaction-local contract pin isolation and next-connection v1 restoration: PASS.
- SN-001 through SN-029: PASS.
- Supplementary adjacency rejection: PASS.
- Post-NFKC separator rejection: PASS.
- storage-name-v1 compatibility: PASS.

The persistent functional transaction began with the normal `document_commit` case, then stopped at the validation assertion described above. Its batch, operation, document, and version rows were all rolled back.

## Fail-closed result

- A guarded transaction changed only the exact 0.3.0 row's `enabled` value from true to false.
- A separate connection confirmed `matching_rows=1`, `enabled=false`, `revoked_at=null`, and `total_enabled_rows=0`.
- The migration ledger remains the same five entries; no rollback or ledger repair occurred.
- The existing failed-fixture fingerprint remains `dbe4a86a76990e0a0c01b7965257fa28`.
- The new synthetic fixture was preserved without cleanup: one project row and one owner membership row; all scoped folders, documents, document versions, tree orders, batches, operations, project settings, and project migrations are 0.
- New synthetic-fixture fingerprint: `b97797b36e4f9800757061aed2aee736`.
- Final global fingerprint: `af22f0ac0df3abe07eb7f29fe320c3a4` (the expected change is the preserved synthetic project and membership).
- Final counts: users 6, projects 5, project members 5, folders 13, documents 6, document versions 17, tree orders 5, batches 47, batch results 47, operations 59, attempts 59, events 179, project sync migrations 3.
- The synthetic project remains implicit `LEGACY`, epoch 0, active digest null, with no automatic promotion or project migration.
- In-progress project migrations: 0.
- The four previously accepted corrective-wrapper advisor warnings remain expected; this run performed no DDL.

## Not executed after the stop

The same run did not continue to empty-document commit, atomic commit/rollback, replay cases, new-run auth envelopes, unauthorized-write checks, or final PASS audit. Their expected values were not adjusted, and the run was not retried.

No production or other Supabase project was accessed. No existing failed run was reclassified. No fixture was deleted or repaired. Stage 8 was not started.
