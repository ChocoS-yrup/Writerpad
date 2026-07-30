#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dispatcher="$root/WriterPad/Sync/SyncV2Dispatcher.swift"
store="$root/WriterPad/Sync/SyncV2Store.swift"
tests="$root/WriterPadTests/SyncV2ClientTests.swift"
store_tests="$root/WriterPadTests/SyncV2StoreTests.swift"
app="$root/WriterPad/App/WriterPadApp.swift"
document="$root/Docs/SyncV2Dispatcher.md"

fail() {
    echo "11-2 dispatcher audit failed: $1" >&2
    exit 1
}

require() {
    pattern=$1
    file=$2
    message=$3
    rg -q "$pattern" "$file" || fail "$message"
}

require 'actor SyncV2Dispatcher' "$dispatcher" "dispatcher actor is missing"
require 'maximumConcurrentDocuments' "$dispatcher" "concurrency limit is missing"
require 'SyncV2RetryPolicy' "$dispatcher" "retry policy is missing"
require 'pow\(2' "$dispatcher" "exponential backoff is missing"
require 'jitterFraction' "$dispatcher" "retry jitter is missing"
require 'loginSucceeded' "$dispatcher" "login retry signal is missing"
require 'appEnteredForeground' "$dispatcher" "foreground retry signal is missing"
require 'userRequestedRetry' "$dispatcher" "user retry signal is missing"
require 'networkRecovered' "$dispatcher" "network recovery signal is missing"
require 'SyncV2NetworkRecoveryDetector' "$dispatcher" \
    "NWPathMonitor recovery transition guard is missing"
require 'claimReadyOperations' "$store" "durable claim is missing"
require 'earlier\.document_sequence < o\.document_sequence' "$store" \
    "document FIFO guard is missing"
require 'attempts = attempts \+ 1' "$store" "attempt persistence is missing"
require 'base_revision = \?' "$store" "next revision promotion is missing"
require 'testLimitedConcurrencyAndConflictIsolation' "$tests" \
    "concurrency/conflict test is missing"
require 'testEveryImmediateOpportunityReleasesRetryWait' "$tests" \
    "immediate retry signal test is missing"
require 'testNetworkRecoveryRequiresDisconnectedToConnectedTransition' "$tests" \
    "network recovery transition test is missing"
require 'testDispatcherClaimPreservesDocumentFIFO' "$store_tests" \
    "durable FIFO test is missing"
require 'syncDispatcher\?\.loginSucceeded' "$app" \
    "authenticated app wiring is missing"
require '11-3 정지 경계' "$document" "next-stage stop boundary is missing"

if rg -q 'EditLeaseManager|heartbeatLease|acquireLease' \
    "$dispatcher" "$store"; then
    fail "11-3 lease behavior leaked into 11-2"
fi

echo "PASS: 11-2 dispatcher and retry audit"
