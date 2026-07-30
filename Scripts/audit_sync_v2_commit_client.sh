#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
client="$root/WriterPad/Sync/SyncV2Client.swift"
tests="$root/WriterPadTests/SyncV2ClientTests.swift"
document="$root/Docs/SyncV2CommitClient.md"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

for key in \
    p_document_id p_project_id p_base_revision p_operation_id p_device_id \
    p_relative_path p_content p_is_deleted p_lease_token; do
    rg -q "$key" "$client" || fail "missing RPC parameter $key"
done

for field in \
    status document_id version_id operation_id operation_kind revision \
    relative_path is_deleted content_hash committed_at; do
    rg -q "$field" "$client" || fail "missing response field $field"
done

for code in \
    AUTH_REQUIRED FORBIDDEN INVALID_ARGUMENT DOCUMENT_NOT_FOUND \
    DOCUMENT_ALREADY_EXISTS REVISION_CONFLICT OPERATION_ID_REUSED \
    LEASE_REQUIRED LEASE_CONFLICT LEASE_EXPIRED PATH_CONFLICT; do
    rg -q "$code" "$client" || fail "missing stable error $code"
done

rg -Fq '.rpc("commit_document"' "$client" \
    || fail "commit_document RPC call is missing"
rg -q 'case committed' "$client" \
    || fail "committed response is missing"
rg -q 'case replayed' "$client" \
    || fail "replayed response is missing"
rg -q 'testCommittedThenReplayedSameOperationConvergesToSameResult' "$tests" \
    || fail "operation replay convergence test is missing"
rg -q 'testMalformedSuccessfulResponseIsNeverAccepted' "$tests" \
    || fail "malformed response test is missing"
rg -q '11-2 정지 경계' "$document" \
    || fail "next-stage stop boundary is missing"

if rg -q 'claimNextReadyOperation|markRetry|markSuccess|NWPathMonitor' "$client"; then
    fail "11-2 dispatcher behavior leaked into 11-1"
fi

echo "PASS: 11-1 commit_document client audit"
