# Sync Contract 0.2.0 blocker traceability

This table is normative release traceability for the six blockers confirmed by the
Windows feasibility review and the later protocol-3 document wire gate. A row is
complete only when its normative text, machine-readable schema, conformance vector,
and verifier rule agree.

| Blocker | Normative text | Schema | Vector | Verifier |
|---|---|---|---|---|
| C-01 immutable intent/rebase | `protocol.json.operation_model.intent` and `.rebase`: rebase creates a new `operation_id` and `batch_id`, carries `supersedes_operation_id`, and never mutates the original | `protocol.schema.json` rebase/intent rules; transition queue supports `supersedes_operation_id` | TV-005 | `verify_vector_semantics` rejects same-ID rebase, reused batch, or mutation of immutable fields |
| C-02 protocol/capability/batch | `supported_protocol_versions`, `capability_version_rules`, and `immutable_batch_metadata`: protocol 1/2 use honest `LEGACY_EPOCH_0`; protocol 3 requires all capabilities and `CONTRACT_BATCH` | Protocol version/capability/batch schemas; conditional transition queue provenance | TV-003, TV-006, TV-010 | `verify_capability_matrix` and `verify_vector_semantics` validate `since_protocol`, required capabilities, operation creation paths, and batch presence/absence |
| C-03 cancelled derivation | `operation_model.event`, `.state`, and `.cancellation`: cancellation/supersession are append-only events; terminal and duplicate behavior is deterministic | Event/state/cancellation structures in `protocol.schema.json`; cancellation action and queue terminal states in transition schema | TV-005, TV-011 | `verify_state_model` requires complete event-to-state coverage and duplicate/completed cancellation cases |
| C-04 atomic structure commit | `atomic_structure_commit`: one ordered request is the atomic/idempotent boundary; any failure rolls back all intents | `atomic-structure-commit.schema.json` request, success, and failure wire shapes | TV-012; ASC-001 through ASC-004 | `verify_atomic_vectors` checks sequence, intent/batch digests, exact replay, changed replay rejection, full success coverage, and empty failure results |
| C-05 normalized storage name | `storage_name_normalization`: Unicode 15.0.0 NFKC_Casefold, deterministic rejection, trailing-space/dot policy, reserved basenames, exact UTF-8 comparison | `storage-name-vectors.schema.json` | SN-001 through SN-015 | `verify_storage_vectors` independently computes every normalized value, UTF-8 collision key, and error using pinned Unicode data |
| C-06 historical provenance | `legacy_migration` and `project_sync_mode`: existing projects remain `LEGACY/epoch 0`; unavailable metadata stays unknown; enforcement begins only at a locked manual transition | Legacy migration/default/mode structures in `protocol.schema.json` | TV-003, TV-010 | `verify_legacy_boundary` rejects invented defaults, automatic mode changes, or post-enforcement protocol 1/2 writes |
| C-07 atomic document body commit | `document_commit`: create/update/delete/restore use one immutable document intent, full UTF-8 content digest, structure revision barrier, all-or-nothing response, and deterministic replay | `document-commit.schema.json` request, success, and failure wire shapes | DC-001 through DC-007 | `verify_document_vectors` checks capability and contract pins, payload/batch/content digests, byte counts, result completeness, empty content, replay, rollback, delete, and restore |

## Evidence boundaries

- Public implementation evidence is reproducible only when a repository and exact Git
  commit are named.
- Preserved Windows SQLite evidence is a separate source. The release does not claim
  another platform verified it without an accessible artifact and digest.
- Repository Supabase migrations are not proof of the operational migration ledger.
  Operational state remains unverified until a read-only server preflight is performed.
