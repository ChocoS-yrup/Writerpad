# WriterPad Sync Contract 0.2.0

This directory is the released, implementation-independent WriterPad sync
contract. It defines wire behavior and conformance requirements; it does not
implement Windows, iPad, macOS, server, database, or migration code.

## Release identity

- Contract version: `0.2.0`
- Status: released; deployment and server allowlisting are separate stage-7 actions
- Canonicalization: RFC 8785
- Canonical `protocol.json` byte length: `23256`
- Canonical SHA-256:
  `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`

The digest is SHA-256 over the exact UTF-8 bytes returned by RFC 8785
canonicalization of `protocol.json`. It is not a source-file, pretty-print,
newline-normalized, `sort_keys`, or `jq -S` digest.

Consumers must pin these external handoff values together:

```text
contract_version
contract_git_commit
canonical_contract_sha256
```

The final Git commit is external to `protocol.json` and `contract-lock.json`
because a Git commit cannot contain its own SHA without changing that SHA.

## Package contents

| Path | Purpose |
|---|---|
| `protocol.json` | Normative protocol, operation/event, mode, compatibility, normalization, migration, and evidence rules |
| `protocol.schema.json` | Draft 2020-12 schema for the released protocol |
| `atomic-structure-commit.schema.json` | Normative request/success/failure wire schema for atomic structure batches |
| `document-commit.schema.json` | Normative request/success/failure wire schema for atomic document body commits |
| `storage-name-vectors.schema.json` | Schema for platform-independent storage-name vectors |
| `incident.schema.json` | Cross-platform incident evidence format |
| `snapshot.schema.json` | Server snapshot interchange format |
| `transition-vector.schema.json` | State transition and fault-injection vector format |
| `test_vectors/*.json` | Twelve required cross-client transition vectors |
| `conformance_vectors/*.json` | Atomic wire and storage-name conformance cases |
| `TRACEABILITY.md` | C-01 through C-07 normative text → schema → vector → verifier mapping |
| `contract-lock.json` | Expected release identity, counts, canonical length, and digest |
| `scripts/verify_contract.py` | Schema, vector, digest, and cross-file semantic verifier |
| `requirements-validation.txt` | Pinned verifier dependencies |

## Compatibility matrix

| Protocol | Writable modes | Provenance | Contract batch | Required behavior |
|---|---|---|---|---|
| 1 | `LEGACY` only | `LEGACY_EPOCH_0` | forbidden | Name-based legacy projection through the server legacy adapter |
| 2 | `LEGACY` only | `LEGACY_EPOCH_0` | forbidden | Stable folders and tombstones without claiming released-contract provenance |
| 3 | `LEGACY`, `MIGRATING`, `ID_BASED` | `CONTRACT_BATCH` | required | Full capability set, append-only attempts/events, storage-name-v1, atomic structure, and atomic document writes |

`MIGRATING` and `ID_BASED` require protocol 3 for both content and structure.
Protocol 1/2 clients are rejected with `PROTOCOL_TOO_OLD` after enforcement
begins. Capabilities may not be declared before their `since_protocol`, and a
writer must declare every capability required by its selected protocol.

## Immutable operations, rebase, and state

- Transport retry reuses an identical `batch_id`, `operation_id`, base revision,
  and payload digest.
- Rebase creates a new immutable operation and batch. The successor carries
  `supersedes_operation_id`; the original intent and attempts never change.
- Attempt and state-event ledgers are append-only. A mutable state column is a
  rebuildable projection, not authority.
- Cancellation is a `cancel_requested` event. Duplicate cancellation,
  cancellation after completion, and event replay have explicit idempotent
  behavior in `protocol.json` and TV-011.

## Atomic structure boundary

Every protocol-3 structural write is one
`atomic_structure_commit_request`. `ordered_intents` is applied only in
contiguous `sequence` order. `batch_payload_sha256` binds the RFC 8785 bytes of
that complete array, and `batch_id` is the idempotency key.

Success covers every intent. Any validation or apply failure rolls back the
complete transaction and returns an empty result list. An identical replay
returns `status=replayed` with the original result fields; the same batch ID
with changed bytes returns `BATCH_ID_REUSED`.

## Atomic document boundary

Every protocol-3 document create, body update, delete, or restore is one
`document_commit_request` containing exactly one immutable intent. The request
binds the full UTF-8 content by byte count and SHA-256 and also binds the
complete payload and batch using RFC 8785. An intentional empty document is a
real write with byte count zero and the standard SHA-256 of empty bytes.

Existing document commits cannot rename or move a document. They must name the
current `structure_revision`; stale structure is rejected. Rename and move use
`atomic_structure_commit`. Delete preserves the current body before writing a
tombstone, and restore reuses the tombstoned body before any later edit.
Identical retries replay the complete stored result after response loss or a
server restart. Any mismatch or partial result is rejected and never applied by
a client.

## Storage-name-v1

Sibling collision keys use Unicode 15.0.0 and this fixed sequence:

1. Reject controls, DEL, `/`, and `\` in a single name segment.
2. Apply Unicode NFKC, Default Case Folding without locale, then NFKC again.
3. Remove trailing ASCII space and full stop.
4. Reject empty, dot, dot-dot, and Windows device basenames.
5. Compare the exact UTF-8 bytes of the remaining string.

Leading ASCII space remains significant. Internal whitespace is preserved
except where Unicode NFKC changes its code point. SN-001 through SN-015 are the
normative cross-language cases for Windows, Swift, and PostgreSQL
implementations.

## Legacy migration boundary

Existing projects remain explicitly:

```text
project_sync_mode = LEGACY
migration_epoch = 0
contract_enforcement_started_at = null
```

Historical build, protocol, digest, batch, or device values that were not
recorded remain absent/null with `PRE_CONTRACT_HISTORY`; they must never be
invented. Existing ledgers are not rewritten into contract batches.

Only a manual, server-locked `LEGACY -> MIGRATING` transition creates epoch 1
and the enforcement timestamp. Every later write requires protocol 3 contract
provenance. Validation permits—but never automatically performs—the later
`MIGRATING -> ID_BASED` transition. Migration failure remains diagnosable in
`MIGRATING`; there is no automatic downgrade.

## Reproducible validation

Use Python 3.12 and the pinned dependencies:

```text
python3.12 -m venv .venv-contract
.venv-contract/bin/python -m pip install -r sync-contract/requirements-validation.txt
.venv-contract/bin/python sync-contract/scripts/verify_contract.py
```

The verifier checks:

- all seven Draft 2020-12 schemas;
- released protocol `0.2.0` and twelve transition vectors;
- capability `since_protocol` and required capability declarations;
- operation creation paths and immutable rebase identities;
- protocol-specific batch/provenance obligations;
- event-to-state derivation and cancellation cases;
- fifteen Unicode 15.0.0 storage-name vectors and exact UTF-8 keys;
- four atomic wire cases, including digest binding, replay, and full rollback;
- seven document wire cases covering empty content, update, delete, restore,
  replay, changed replay, and full rollback;
- legacy epoch-0 defaults and manual enforcement boundary;
- RFC 8785 canonical byte length and SHA-256 lock.

## Evidence and implementation boundaries

- A public source claim must name a reproducible repository and exact commit.
- Preserved Windows SQLite evidence is separate evidence. Another platform must
  not claim it verified that database without an accessible artifact and digest.
- Repository Supabase migrations are not proof of deployed state. The
  operational migration ledger remains unverified until stage 7 performs a
  read-only preflight.
- This release does not modify client/server source, run a migration, change a
  database, retry synchronization, or allowlist/deploy the contract.
