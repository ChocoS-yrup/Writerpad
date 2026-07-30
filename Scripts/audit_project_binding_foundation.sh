#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
service="$root/WriterPad/Sync/SupabaseProjectBindingService.swift"
provider="$root/WriterPad/Sync/SupabaseClientProvider.swift"
environment="$root/WriterPad/App/AppEnvironment.swift"
tests="$root/WriterPadTests/SupabaseProjectBindingServiceTests.swift"
document="$root/Docs/ProjectBindingFoundation.md"

require() {
    pattern=$1
    file=$2
    message=$3
    if ! grep -Eq "$pattern" "$file"; then
        echo "9-4 audit failed: $message" >&2
        exit 1
    fi
}

reject() {
    pattern=$1
    file=$2
    message=$3
    if grep -Eq "$pattern" "$file"; then
        echo "9-4 audit failed: $message" >&2
        exit 1
    fi
}

require 'actor SupabaseProjectBindingService' "$service" \
    "binding service actor is missing"
require 'rpc[(]"ensure_project"' "$service" \
    "ensure_project RPC is missing"
require 'p_project_id' "$service" \
    "ensure_project project UUID key is missing"
require 'p_name' "$service" \
    "ensure_project name key is missing"
require 'ConfirmedServerProjectID' "$service" \
    "explicit UUID confirmation boundary is missing"
require 'newServerProject' "$service" \
    "new server project flow is missing"
require 'existingServerProject' "$service" \
    "existing server project flow is missing"
require 'windowsImport' "$service" \
    "Windows binding flow is missing"
require 'func disconnect' "$service" \
    "disconnect flow is missing"
require 'case forbidden' "$service" \
    "RLS/forbidden error is not distinct"
require 'serverProjectAlreadyBound' "$service" \
    "one-server-to-one-local uniqueness is missing"
require 'makeProjectBindingTransport' "$provider" \
    "provider does not expose the binding transport"
require 'projectBindingService' "$environment" \
    "AppEnvironment does not inject the binding service"
require 'LazySyncV2ProjectBindingStore' "$environment" \
    "live app must use the durable SyncV2 binding adapter"
require 'testSameNameNeverMergesDifferentLocalProjects' "$tests" \
    "same-name non-merge test is missing"
require 'testForbiddenIsNotReportedAsEmptyOrNetworkFailure' "$tests" \
    "forbidden classification test is missing"
require 'testDisconnectOnlyChangesLocalBindingAndNeverCallsServer' "$tests" \
    "disconnect preservation test is missing"
require '10-1' "$document" \
    "10-1 durable storage handoff is undocumented"

reject 'eq[(]"name"|ilike|find.*[Nn]ame|serverProject.*name:' "$service" \
    "name-based server matching is forbidden"
reject 'commit_document|acquire_edit_lease|Realtime|channel[(]' "$service" \
    "10-2 or later server behavior leaked into 9-4"
reject 'removeRemote|deleteRemote|from[(]"projects"[^)]*[.]delete' "$service" \
    "remote project deletion is outside 9-4"
reject 'print[(]|NSLog|Logger[.]|os_log' "$service" \
    "binding identifiers or server errors must not be generally logged"

echo "9-4 project binding foundation audit passed."
