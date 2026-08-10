# WriterPad Sync Contract Package Draft

This directory is the machine-readable draft shared contract for WriterPad
sync. It is intentionally separate from the iPad application target and can be
vendored or packaged by the Windows and iPad repositories without copying
client implementation code.

The draft was created in the iPad repository because it contains
`Docs/SyncV2Contract.md`. The Windows evidence commit
`77c57b8d39ce726f6aad0a565a0397b7a5a98fc3` was not present in the iPad Git
object database when this package was authored, so this directory remains an
implementation-independent package. It is now published in the shared
WriterPad repository; it is not yet a deployed or server-allowlisted release.

## Status

- Contract version: `0.1.0-draft.1`
- Status: draft; not deployed and not server-allowlisted
- Canonicalization: RFC 8785 JSON Canonicalization Scheme
- Canonical `protocol.json` byte length: `11640`
- Canonical SHA-256:
  `d64bccd8ecbd2566a5d0bb9cec74fc2866cafd0cc7b8ebeea68e16be8bc8872e`

The digest is the lowercase SHA-256 of the UTF-8 bytes returned by applying
RFC 8785 to `protocol.json`. The digest is not stored inside `protocol.json`,
which avoids a circular self-reference. It is stored on immutable batches and
in the server allowlist.

## Package contents

| Path | Purpose |
|---|---|
| `protocol.json` | Normative protocol, capability, mode, allowlist, and invariant draft |
| `protocol.schema.json` | Draft 2020-12 schema for `protocol.json` |
| `incident.schema.json` | Cross-platform read-only incident evidence format |
| `snapshot.schema.json` | Server snapshot interchange format |
| `transition-vector.schema.json` | State transition and fault-injection vector format |
| `test_vectors/*.json` | Ten minimum cross-client transition vectors |
| `contract-lock.json` | Expected contract version, canonical byte length, and digest |
| `scripts/verify_contract.py` | Shared schema, vector, and RFC 8785 digest verifier |
| `requirements-validation.txt` | Pinned verifier dependencies for local use and CI |
| `CHANGELOG.md` | Contract-only change history |

## Authority and compatibility

`Docs/SyncV2Contract.md` remains the historical audit of the deployed
document-only/legacy tree contract. Its statement that the server had no
folder entity describes protocol v1. This package adds explicit protocol
boundaries for the later `folders` extension:

- Protocol v1, `LEGACY`: name-based `tree_order` may project folders.
- Protocol v2: `folders` is authoritative; name-based `tree_order` is order
  compatibility data only.
- Protocol v3, `ID_BASED`: folder and document IDs are authoritative and
  `tree_order` references IDs.

Project promotion is one way:

```text
LEGACY -> MIGRATING -> ID_BASED
```

The server, not a client declaration, decides whether a structural write is
allowed. Every operation references immutable batch metadata containing the
writer, build, protocol, contract version, RFC 8785 digest, and capabilities.

## Canonical digest procedure

1. Parse `protocol.json` as I-JSON.
2. Serialize it with RFC 8785. Do not hash pretty-printed JSON, source file
   whitespace, platform newlines, or a generic `sort_keys` approximation.
3. Encode the canonical result as UTF-8.
4. Compute SHA-256 and encode it as 64 lowercase hexadecimal characters.
5. Compare the result with the batch digest and an active server allowlist
   entry.

Clients must pin all three values in CI:

```text
contract_version
contract_git_commit
canonical_contract_sha256
```

The baseline package commit is
`fb882d7312f803266a18ea9c07a226f23c1a88a5`. Implementations must still pin
the exact commit they consumed because later commits may change the package.

## Reproducible validation

From the repository root, install the pinned validation dependencies in an
isolated Python environment and run:

```text
python sync-contract/scripts/verify_contract.py
```

GitHub Actions runs the same command whenever contract files change. The
validator checks all Draft 2020-12 schemas, validates the protocol and ten
required vectors, canonicalizes `protocol.json` with RFC 8785, and compares
the byte length and SHA-256 with `contract-lock.json`.

The repository handoff and branch policy is documented in
`Docs/CrossPlatformSyncGitWorkflow.md`.

## Test vectors

| Vector | Scenario |
|---|---|
| `TV-001` | Empty folder creation |
| `TV-002` | Folder with a document creation |
| `TV-003` | Legacy client first connection |
| `TV-004` | Six rapid renames and a final tree checkpoint |
| `TV-005` | Revision conflict and rebase |
| `TV-006` | Lost response and identical operation retry |
| `TV-007` | Client termination and durable queue recovery |
| `TV-008` | Rename versus delete/tombstone conflict |
| `TV-009` | Same name with different folder IDs |
| `TV-010` | Legacy structural write to an ID-based project |

Each vector contains initial server and client state, ordered actions, injected
faults, expected server/client/queue state, and explicit invariants. A client
passes a vector only when both its local assertions and the shared server
assertions pass.

## Validation performed

The draft was checked as follows:

- all 15 JSON files parsed successfully with `jq 1.7.1`;
- all four schemas passed `Draft202012Validator.check_schema` using
  `jsonschema 4.26.0`;
- `protocol.json` passed `protocol.schema.json` with format checking;
- all ten transition vectors passed `transition-vector.schema.json` with
  format checking;
- the canonical digest was computed with `rfc8785 0.1.4`, not a sorted-key
  approximation.

`incident.schema.json` and `snapshot.schema.json` are schema-checked but do not
yet have captured evidence fixtures in this package. The separately preserved
iPad and Windows incident artifacts should be normalized into those schemas in
a later evidence-only step.

## Integration rules

- Do not infer capabilities from platform name or build recency.
- Do not accept a capability merely because a client declares it.
- Do not mutate batch contract metadata after creation.
- Do not rewrite an operation ID during retry, restart recovery, or rebase.
- Do not use `tree_order` to create authoritative folders outside `LEGACY`.
- Do not automatically downgrade a project.
- In `ID_BASED`, a legacy client may edit existing document content only when
  path, parent, identity, and deletion state are unchanged and normal revision,
  authorization, hash, operation, and lease checks pass.
- Preserve attempt history even after eventual success.

## Not implemented by this draft

This package does not create server tables, RPCs, migrations, allowlist rows,
migration locks, or client queue code. In particular,
`atomic_structure_commit` is a required capability contract, not a claim that
the current server already implements it.

Application code, server code, operational databases, and preserved incident
evidence are outside this directory and were not modified by this contract
draft.
