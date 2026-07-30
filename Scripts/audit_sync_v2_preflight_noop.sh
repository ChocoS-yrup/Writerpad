#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
store="$root/WriterPad/Sync/SyncV2Store.swift"
local_store="$root/WriterPad/Data/Local/LocalDocumentStore.swift"
state="$root/WriterPad/Domain/Rules/SaveStateMachine.swift"
tests="$root/WriterPadTests/SyncV2StoreTests.swift"
doc="$root/Docs/SyncV2PreflightAndNoOp.md"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

rg -q 'maximumContentByteCount = 10 \* 1_024 \* 1_024' "$store" \
    || fail "10 MiB UTF-8 limit is missing"
rg -q 'payload\.contentByteCount > Self\.maximumContentByteCount' "$store" \
    || fail "strict greater-than preflight is missing"
rg -q 'CONTENT_TOO_LARGE' "$store" \
    || fail "durable size error code is missing"
rg -q "operationStatus = isOversized \\? \"blocked\"" "$store" \
    || fail "oversized operation is not blocked"
rg -q 'existingState\.serverRevision > 0' "$store" \
    || fail "no-op server revision guard is missing"
rg -q 'existingState\.serverPath == payload\.relativePath' "$store" \
    || fail "no-op server path comparison is missing"
rg -q 'existingState\.baseContent == payload\.content' "$store" \
    || fail "no-op base content comparison is missing"
rg -q '!hasEarlierOperation' "$store" \
    || fail "no-op active operation guard is missing"
rg -q 'serverSizeLimitExceeded' "$local_store" \
    || fail "local save does not preserve size-limit result"
rg -q 'preservedResult' "$local_store" \
    || fail "relaunch does not restore the persisted size-limit state"
rg -q '로컬 저장됨 · 서버 크기 제한 초과' "$state" \
    || fail "size-limit UI state is missing"
rg -q 'testContentPreflightAllowsTenMiBAndBlocksOneByteOver' "$tests" \
    || fail "10 MiB boundary test is missing"
rg -q 'testServerBaselineNoOpCreatesNoOperationAndRequiresEmptyLane' "$tests" \
    || fail "no-op lane test is missing"
rg -q '11단계 정지 경계' "$doc" \
    || fail "next-stage stop boundary is missing"

echo "PASS: 10-5 size preflight and no-op audit"
