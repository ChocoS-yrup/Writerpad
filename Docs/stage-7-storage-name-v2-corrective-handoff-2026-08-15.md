# WriterPad Stage 7 corrective functional revalidation handoff

```yaml
handoff_version: 1
stage_id: stage7-storage-name-v2-corrective-functional-reverification
platform: ipad-server
repository: https://github.com/ChocoS-yrup/Writerpad
branch: codex/stage7-storage-v2-blocked-evidence
commit_sha: supplied with the immutable pushed-commit handoff
base_main_sha: f67441cc6b1da0469cfae3be90edd7a4e57b5c2a
contract_version: 0.3.0
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c
test_run_id: 0cafa16f-aa12-444b-91f6-ca8282b12996
server_project_id: c1b0cdf5-ee14-4794-a11f-b5576dd0744d
client_build_id_or_sha256: stage7-storage-v2-0cafa16f-aa12-444b-91f6-ca8282b12996
changed_paths:
  - Docs/stage-7-storage-name-v2-corrective-functional-reverification-2026-08-15.md
  - Docs/stage-7-storage-name-v2-corrective-handoff-2026-08-15.md
validation_commands:
  - Supabase project identity, URL, migration-ledger, advisor, and read-only SQL inspections
  - exact preflight global and existing-failure-fixture fingerprint queries
  - guarded exact-row allowlist enable transaction and separate read-only verification
  - read-only 0.3.0 digest/capability/storage-name conformance transaction
  - separate-connection transaction-local route reset verification
  - persistent functional transaction (rolled back on validation-harness ambiguity)
  - guarded exact-row allowlist disable transaction and separate final read-only audit
validation_results:
  verdict: BLOCKED
  preflight: PASS
  allowlist_activation: PASS
  contract_and_storage_name_gate: PASS
  functional_suite: STOPPED_ON_FIRST_DISCREPANCY
  functional_transaction_rollback: PASS
  fail_closed_disable: PASS
  final_total_enabled_rows: 0
  attempted_functional_batches_persisted: 0
  existing_failed_fixture_fingerprint: dbe4a86a76990e0a0c01b7965257fa28
  new_fixture_fingerprint: b97797b36e4f9800757061aed2aee736
remote_changes:
  staging_allowlist_0_3_0_enabled: false
  new_synthetic_project_rows: 1
  new_synthetic_project_member_rows: 1
  new_scoped_functional_rows: 0
  migration_ledger_changed: false
  corrective_migration_rolled_back: false
incident_artifact_paths_or_urls: not-applicable
known_limitations:
  - Full Stage 7 functional revalidation did not complete.
  - The same test_run_id must not be retried or reclassified as PASS.
  - A separate approval and a new run are required before another allowlist activation attempt.
requested_counterpart_action: Windows must review the exact evidence commit SHA, test_run_id 0cafa16f-aa12-444b-91f6-ca8282b12996, server_project_id c1b0cdf5-ee14-4794-a11f-b5576dd0744d, and final allowlist state enabled=false with total_enabled_rows=0; Stage 7 remains BLOCKED.
```

This branch contains evidence and handoff documentation only. It does not change application code, the contract, migrations, or CI configuration, and it must not be made Ready or merged without a separate decision.
