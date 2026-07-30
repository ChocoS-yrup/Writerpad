#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
store="$root/WriterPad/Data/Local/LocalDocumentStore.swift"
session="$root/WriterPad/Features/Editor/EditorSessionModel.swift"
state="$root/WriterPad/Domain/Rules/SaveStateMachine.swift"
sync_store="$root/WriterPad/Sync/SyncV2Store.swift"
store_tests="$root/WriterPadTests/LocalDocumentStoreTests.swift"
session_tests="$root/WriterPadTests/AppEnvironmentTests.swift"
document="$root/Docs/LocalDocumentSaveSyncHandoff.md"

require() {
    pattern=$1
    file=$2
    message=$3
    if ! grep -Eq "$pattern" "$file"; then
        echo "10-3 audit failed: $message" >&2
        exit 1
    fi
}

require 'syncHandoffPrefix' "$store" "durable handoff marker is missing"
require 'persistPendingSyncHandoffs' "$store" \
    "pending handoff persistence is missing"
require 'loadPendingSyncHandoffsIfNeeded' "$store" \
    "relaunch recovery is missing"
require 'metadataUpdater[.]updateAfterFileSave' "$store" \
    "metadata update boundary is missing"
require 'durableChangeRecorder[.]record' "$store" \
    "durable recorder handoff is missing"
require 'func requirement' "$sync_store" \
    "local-only and connected project split is missing"
require '로컬 저장됨 · 동기화 기록 실패' "$state" \
    "queue failure presentation is missing"
require 'isComposing' "$session" "IME composition guard is missing"

for test_name in \
    testSuccessfulSaveHandsImmutableSnapshotToQueueAfterMetadata \
    testQueueFailureKeepsLocalSaveAndRetriesSameImmutableBatch \
    testNextSaveFlushesEarlierFailureBeforeNewSnapshot \
    testQueueFailureSurvivesStoreRecreationWithSameImmutableBatch; do
    require "$test_name" "$store_tests" "required test $test_name is missing"
done

for test_name in \
    testEditorSessionDefersDurableHandoffUntilIMECompositionEnds \
    testEditorSessionKeepsLocalSuccessOnQueueFailureAndRetries \
    testEditorSessionReplaysPendingHandoffWhenDocumentOpens; do
    require "$test_name" "$session_tests" "required test $test_name is missing"
done

require '10-4 연결' "$document" "10-4 continuation is undocumented"
require 'operation claim' "$document" "remote execution exclusion is undocumented"

echo "10-3 local document sync handoff audit passed."
