#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
store="$root/WriterPad/Sync/SyncV2Store.swift"
tests="$root/WriterPadTests/SyncV2StoreTests.swift"
schema="$root/Scripts/fixtures/SyncV2StoreSchemaV1.sql"
environment="$root/WriterPad/App/AppEnvironment.swift"
project="$root/WriterPad.xcodeproj/project.pbxproj"
document="$root/Docs/SyncV2StoreImplementation.md"

require() {
    pattern=$1
    file=$2
    message=$3
    if ! grep -Eq "$pattern" "$file"; then
        echo "10-1 audit failed: $message" >&2
        exit 1
    fi
}

reject() {
    pattern=$1
    file=$2
    message=$3
    if grep -Eq "$pattern" "$file"; then
        echo "10-1 audit failed: $message" >&2
        exit 1
    fi
}

require 'actor SyncV2Store' "$store" "SyncV2Store actor is missing"
require 'import SQLite3' "$store" "SQLite3 implementation is missing"
require 'journal_mode = WAL' "$store" "WAL configuration is missing"
require 'synchronous = FULL' "$store" "FULL durability is missing"
require 'foreign_keys = ON' "$store" "foreign keys are not enabled"
require 'sqlite3_busy_timeout.*10_000' "$store" \
    "bounded busy timeout is missing"
require 'SHA256[.]hash' "$store" "migration resource checksum is missing"
require 'schemaTooNew' "$store" "higher schema refusal is missing"
require 'migrationMismatch' "$store" "checksum/schema mismatch is missing"
require 'PRAGMA quick_check' "$store" "quick_check is missing"
require 'PRAGMA foreign_key_check' "$store" "foreign_key_check is missing"
require "status = 'pending'" "$store" "inflight pending recovery is missing"
require 'LazySyncV2ProjectBindingStore' "$environment" \
    "live binding adapter is not wired to SyncV2Store"
require 'SyncV2StoreSchemaV1.sql in Resources' "$project" \
    "schema fixture is not an app resource"
require 'design-fixture-v1' "$schema" \
    "schema checksum replacement marker is missing"

for test_name in \
    testNewDatabaseCreatesFullSchemaAndWAL \
    testWALAndBindingSurviveCloseAndReopen \
    testFailedMultiRowTransactionRollsBackEveryRow \
    testHigherSchemaVersionIsPreservedAndRejected \
    testPartiallyCorruptUUIDRowDisablesStoreWithoutDeletingIt \
    testDuplicateDocumentIDIsRejectedAndFirstRowSurvives \
    testDuplicateOperationIDIsRejectedWithoutOverwritingPayload \
    testOneThousandQueuedOperationsReopenIntact \
    testStartupReturnsInflightToPendingWithSameIDAndAttempts; do
    require "$test_name" "$tests" "required test $test_name is missing"
done

require '10-2' "$document" "10-2 stop boundary is undocumented"
reject 'claimNextReadyOperation|markRetry|markSuccess|commit_document|Realtime' \
    "$store" "remote queue execution leaked into the durable store"
reject 'DELETE FROM sync_operations|DROP TABLE' "$store" \
    "destructive recovery is forbidden"
reject 'print[(]|NSLog|Logger[.]|os_log' "$store" \
    "store must not log payloads or private paths"

echo "10-1 SyncV2Store implementation audit passed."
