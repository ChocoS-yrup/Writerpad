#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
protocol="$root/WriterPad/Domain/Protocols/FutureChangeNotifying.swift"
binder="$root/WriterPad/Data/Local/LocalBinderCommandServiceSupport.swift"
binding="$root/WriterPad/Sync/SupabaseProjectBindingService.swift"
sync_store="$root/WriterPad/Sync/SyncV2Store.swift"
restore="$root/WriterPad/Data/Backup/LocalBackupStore.swift"
doc="$root/Docs/LocalStructureSyncHandoff.md"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

for path in "$protocol" "$binder" "$binding" "$sync_store" "$restore" "$doc"; do
    test -f "$path" || fail "missing $path"
done

rg -q 'case treeOrder' "$protocol" || fail "tree-order durable mutation missing"
rg -q 'case trashPurge' "$protocol" || fail "trash-purge durable mutation missing"
rg -q 'completeDurableHandoff' "$binder" || fail "binder recovery handoff missing"
rg -q 'localTransactionCommitted' "$binder" || fail "post-commit rollback guard missing"
rg -q 'durableBatchKind: \.backupRestore' "$restore" || fail "backup restore batch kind missing"
rg -q 'kind == \.windowsImport' "$binding" || fail "explicit Windows connection gate missing"
rg -q 'writerpad-windows-import-sync-handoff' "$sync_store" || fail "Windows recovery marker missing"
rg -q 'syncV2UUIDv5' "$sync_store" || fail "hidden UUIDv5 mapping missing"
rg -q '__antigravity__/tree-order\.json' "$sync_store" || fail "tree-order path missing"
rg -q '__antigravity__/trash-purge\.json' "$sync_store" || fail "trash-purge path missing"
rg -q '10-5 연결' "$doc" || fail "10-5 handoff link missing"

echo "PASS: 10-4 local structure durable handoff audit"
