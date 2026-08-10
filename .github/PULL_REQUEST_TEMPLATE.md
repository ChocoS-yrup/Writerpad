## Purpose

- Stage ID:
- Platform: `contract | ipad | windows | server | evidence`
- Scope:
- Explicitly out of scope:

## Pinned baseline

- Base `main` SHA:
- Contract version:
- Contract Git commit:
- Canonical contract SHA-256:
- Test run ID: `not-applicable` if this is not an incident
- Server project ID: `not-applicable` if this is not an incident
- Client build ID or SHA-256:

## Changes

- Changed paths:
- Behavior changed:
- Migration or compatibility impact:

## Validation

- Commands:
- Results:
- Contract verifier passed: `yes | no` for every Sync PR; `not-applicable` only for an unrelated non-Sync PR
- Exact-head CI result (Ubuntu / Windows):
- PR merge-result CI result:
- Relevant test vectors:

## Cross-platform handoff

- Counterpart review requested from: `ipad | windows | server | contract | none`
- Exact commit SHA reviewed:
- Counterpart findings:
- Known limitations or follow-up:

## Safety checklist

- [ ] This PR contains no unrelated local changes.
- [ ] Shared tests use the exact commits listed above.
- [ ] Every Sync PR reports `Contract verifier passed: yes`; `not-applicable` is used only for an unrelated non-Sync PR.
- [ ] Contract changes include schemas, vectors, lock digest, and changelog updates.
- [ ] Incident evidence and implementation changes are not mixed.
- [ ] No user document, credential, token, or raw private database is committed.
- [ ] The next implementation stage will not start before this stage is accepted.
