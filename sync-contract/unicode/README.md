# Frozen Unicode tables

Three implementations have to produce the same `storage-name-v1` collision key
byte for byte: Postgres, the Windows client, and the iPad client. None of them
may derive that key from whatever Unicode data its runtime happens to carry.

These files are the origin. Everything else is generated from them.

## Why these exist

The contract used to say "use Unicode 15.0.0" and leave each implementation to
satisfy that on its own. Measurement on 2026-08-13 showed that does not work:

- iPadOS 26.5 carries ICU 78.1 / Unicode 17.0.0, and Foundation's
  `folding(options: [.caseInsensitive])` is not Unicode default case folding at
  all. Comparing every code point against the frozen tables, 276 scalars
  produced a different key, and 181 of those were **inside** the Unicode 14.0.0
  assigned set — so a rule that only rejects unassigned scalars would not have
  caught them.
- Windows satisfied the requirement only by bundling a third-party
  `unicodedata2` build into its executable, which made a pip pin a single point
  of failure for all writes.
- The server was already doing the right thing: freezing the tables into a
  migration and reading them at runtime.

Moving the tables here makes the server's approach the contract's approach.

## Files

| File | What it is |
|---|---|
| `casefold-15.0.0.json` | Full default case folding, 1,530 mappings. The `storage-name-v1` folding step. |
| `assigned-baseline-14.0.0.json` | The scalars a storage name may contain, 698 ranges / 282,230 scalars. |
| `excluded-scalars.json` | Assigned scalars that still may not appear in a name (Private Use, tags, variation selector supplement). |
| `assigned-15.0.0.json` | Unicode 15.0.0 assigned ranges, 707 ranges. Describes what the deployed server already does. |

`assigned-baseline-14.0.0.json` and `assigned-15.0.0.json` are different tables
and are not interchangeable. The first is what the revision moves both clients
to; the second is what the currently deployed server uses internally.

## Canonical digests

Every file carries a `canonical_sha256` over a canonical form that ignores JSON
formatting, so three implementations in three languages can confirm they are
looking at the same table with one value.

```
casefold-15.0.0.json            eac289d0d721c58867acb07af38d9a8e8ee374d328b33d93251ae6348e258439
assigned-baseline-14.0.0.json   aed4e530cc5e0de638310db961f17f174d605282764a6657afd0f70e5515c85c
assigned-15.0.0.json            5a354149c4f2b58f7c2ffc5eab9fc92f6eab5a68292ebce626f4ba402f736e31
excluded-scalars.json           f56ee73bca1690e842a189336ffdfabe7625128f7f314a7ac567755952571e86
```

Each file states its own canonical form. Two shapes are in use:

- range tables — `<START_HEX>..<END_HEX>` lines, uppercase, no padding, LF
  separated, **no trailing newline**
- the casefold table — `<SRC>><DST>[,<DST>...]` entries joined by `;` in
  ascending source order, uppercase, no padding

## Line endings are LF, and this has already bitten once

The baseline table first crossed between machines over a Windows transfer and
arrived with CRLF line endings. Its digest did not match until the CR bytes were
stripped — the table was intact the whole time, but a mechanical check on the
file as received would have rejected it.

Keep these files LF. `generate_casefold_sql.py` refuses to run if it finds a CR.

## Consumers

```
sync-contract/unicode/*.json           <- origin
  -> supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql
       via supabase/scripts/generate_casefold_sql.py
  -> WriterPad/Sync/SyncV2UnicodeCasefold.swift
  -> the Windows client's own table
```

To confirm the deployed migration still matches the assets:

```
python3 supabase/scripts/generate_casefold_sql.py --check \
  supabase/migrations/20260811010000_sync_contract_0_1_0_foundation.sql
```

That migration is already applied and must not change. The check exists to prove
the flip to JSON did not alter a single byte of it.

## Not yet referenced by protocol.json

`protocol.json` still pins `storage_name_unicode: 15.0.0` and does not mention
these files. Wiring them in, adding their digests to `contract-lock.json`, and
bumping `contract_version` all belong to the storage-name revision, which is
still under review with the Windows session. Adding those now would move
`canonical_contract_sha256` ahead of the server's allowlist and fail every write
with `CONTRACT_DIGEST_MISMATCH`.
