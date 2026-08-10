# Changelog

All notable changes to the WriterPad shared sync contract package are recorded
here. This file describes contract artifacts only; it is not an application or
server release log.

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
