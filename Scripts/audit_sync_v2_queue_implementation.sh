#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
store="$root/WriterPad/Sync/SyncV2Store.swift"
tests="$root/WriterPadTests/SyncV2StoreTests.swift"
document="$root/Docs/SyncV2QueueImplementation.md"

require() {
    pattern=$1
    file=$2
    message=$3
    if ! grep -Eq "$pattern" "$file"; then
        echo "10-2 audit failed: $message" >&2
        exit 1
    fi
}

reject() {
    pattern=$1
    file=$2
    message=$3
    if grep -Eq "$pattern" "$file"; then
        echo "10-2 audit failed: $message" >&2
        exit 1
    fi
}

require 'func enqueue' "$store" "enqueue API is missing"
require 'BEGIN IMMEDIATE' "$store" "atomic SQLite transaction is missing"
require 'next_document_sequence' "$store" \
    "document sequence allocation is missing"
require 'batchIDReused' "$store" "batch ID replay guard is missing"
require 'operationIDReused' "$store" "operation ID reuse guard is missing"
require 'JSONEncoder' "$store" "canonical payload encoder is missing"
require 'sortedKeys' "$store" "canonical key ordering is missing"
require 'SHA256[.]hash' "$store" "payload hashing is missing"
require "status NOT IN \\('completed', 'cancelled'\\)" "$store" \
    "nonterminal predecessor check is missing"

for test_name in \
    testEnqueueAllocatesDocumentSequenceAndImmutablePayload \
    testExactBatchReplayReusesOperationIDsWithoutDuplicateRows \
    testReusedBatchIDWithDifferentPayloadIsRejected \
    testDistinctIdenticalSavesRemainDistinctAndOrdered \
    testRenameDeleteAndRestoreSnapshotsAreNeverElided \
    testIndependentDocumentsEachStartAtSequenceOne \
    testConcurrentEnqueueSerializesOneDocumentLane \
    testMultiOperationFailureRollsBackBatchDocumentAndSequence \
    testQueueOrderAndOperationIDsSurviveReopen \
    testEnsureProjectUsesNoDocumentLaneAndPreservesOperationID; do
    require "$test_name" "$tests" "required test $test_name is missing"
done

require '10-3' "$document" "10-3 stop boundary is undocumented"
require '활성 operation이 있으면 본문이 같아도 자동 병합하지' "$document" \
    "conservative coalescing policy is undocumented"

reject 'claimNextReadyOperation|markRetry|markSuccess|markConflict' \
    "$store" "10-3 or later queue execution leaked into 10-2"
reject 'commit_document|Realtime' \
    "$store" "remote execution leaked into the durable queue"
reject 'DELETE FROM sync_operations|DROP TABLE' "$store" \
    "destructive queue recovery is forbidden"

echo "10-2 queue implementation audit passed."
