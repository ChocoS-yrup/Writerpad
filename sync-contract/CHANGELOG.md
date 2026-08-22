# Changelog

All notable changes to the WriterPad shared sync contract package are recorded
here. This file describes contract artifacts only; it is not an application or
server release log.

## 0.2.0 - 2026-08-11

### Released

- Added the normative protocol-3 `document_commit` request, success, and
  failure wire for document create, body update, delete, and restore.
- Added `document_commit_v1` client/server capability requirements.
- Defined intentional empty content, exact UTF-8 byte count and SHA-256,
  structure revision barriers, immutable idempotency, response-loss/server-
  restart replay, and fail-closed partial-response behavior.
- Added seven document conformance cases and cross-file semantic verification.

### Release identity

- RFC 8785 canonical protocol bytes: `23256`.
- Canonical SHA-256:
  `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.

## 0.1.0 - 2026-08-11

### Released

- Resolved C-01 by requiring rebase to create a new immutable operation and
  batch linked through `supersedes_operation_id`.
- Resolved C-02 with an explicit protocol/capability/provenance matrix:
  protocol 1/2 are honest `LEGACY_EPOCH_0`; protocol 3 requires a complete
  `CONTRACT_BATCH`.
- Resolved C-03 with append-only state events and deterministic cancellation,
  terminal, duplicate, and replay rules.
- Resolved C-04 with a normative atomic structure request/success/failure wire
  schema, complete payload digest, ordered results, and rollback semantics.
- Resolved C-05 with Unicode 15.0.0 `storage-name-v1` and fifteen normative
  normalization/error vectors.
- Resolved C-06 with explicit `LEGACY/epoch 0` provenance, unknown historical
  metadata rules, a manual enforcement boundary, and no automatic promotion.
- Raised `MIGRATING` and `ID_BASED` content and structure writes to protocol 3.
- Added TV-011 cancellation derivation and TV-012 atomic rollback.
- Expanded validation from JSON shape checks to cross-file semantic checks.
- Added blocker traceability and explicit public-source, preserved-database,
  and operational-database evidence boundaries.

### Release identity

- RFC 8785 canonical protocol bytes: `19473`.
- Canonical SHA-256:
  `fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46`.

## 0.1.0-draft.1 - 2026-08-10

### Added

- Machine-readable protocol versions 1 through 3.
- Explicit client and server capabilities.
- Immutable batch contract metadata and separate operation intent, attempt,
  and state models.
- Server-controlled contract digest allowlist rules.
- One-way `LEGACY -> MIGRATING -> ID_BASED` project promotion.
- Migration epoch, project-scoped server lock, and migration validation rules.
- Mode-specific minimum content and structure write protocols.
- Structural write permission matrix.
- Legacy content-only editing policy for ID-based projects.
- Stable protocol, migration, document, folder, tree, and lease error codes.
- Server invariants for revisions, idempotency, tombstones, folder identity,
  ID tree references, atomic structure boundaries, and acyclic parents.
- JSON Schema Draft 2020-12 schemas for protocol, incidents, snapshots, and
  transition vectors.
- Ten required transition and fault-injection vectors.

### Compatibility notes

- The historical name-projection behavior from `Docs/SyncV2Contract.md` is
  retained only as protocol v1 behavior for `LEGACY` projects.
- Authoritative folder identity begins with protocol v2.
- ID-based ordering and immutable contract metadata are required for protocol
  v3 structural writes.
- Automatic project downgrade is forbidden.

### Validation

- Four schemas passed Draft 2020-12 schema checking.
- `protocol.json` and all ten transition vectors passed instance validation.
- RFC 8785 canonical `protocol.json` SHA-256:
  `d64bccd8ecbd2566a5d0bb9cec74fc2866cafd0cc7b8ebeea68e16be8bc8872e`.
