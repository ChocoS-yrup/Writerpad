#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

fail() {
    echo "8-1 entry audit failed: $1" >&2
    exit 1
}

if rg -n 'XCRemoteSwiftPackageReference|XCSwiftPackageProductDependency' \
    WriterPad.xcodeproj/project.pbxproj >/dev/null; then
    fail "the Xcode project contains a Swift package dependency"
fi

if rg -n \
    '(^|[[:space:]])import[[:space:]]+Supabase|SupabaseClient|URLSession|SecItem(Add|CopyMatching|Update|Delete)|(^|[[:space:]])import[[:space:]]+Security|SQLite3|GRDB|SyncV2Store' \
    WriterPad --glob '*.swift' >/dev/null; then
    fail "an authentication, network, or sync database implementation exists in the app target"
fi

if rg -n \
    'serverRevision|baseContent|operationID|operationId|leaseToken|deviceID|deviceId' \
    WriterPad/Data/Local/WriterPadMetadataSchema.swift >/dev/null; then
    fail "server state has leaked into WriterPadSchemaV1"
fi

rg -q 'Schema\.Version\(1, 0, 0\)' \
    WriterPad/Data/Local/WriterPadMetadataSchema.swift \
    || fail "WriterPadSchemaV1 is no longer version 1.0.0"

rg -q 'let futureChangeNotifier = NoOpFutureChangeNotifier\(\)' \
    WriterPad/App/AppEnvironment.swift \
    || fail "the live composition root is not using the no-op future change notifier"

rg -q 'let mode: FutureSyncMode = \.localOnly' \
    WriterPad/Sync/NoOpFutureChangeNotifier.swift \
    || fail "the no-op adapter is not explicitly local-only"

echo "8-1 entry audit passed: local-only schema and composition boundary are intact."
