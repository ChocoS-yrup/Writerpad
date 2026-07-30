#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
service="$root/WriterPad/Sync/DeviceIdentityService.swift"
environment="$root/WriterPad/App/AppEnvironment.swift"
app="$root/WriterPad/App/WriterPadApp.swift"
tests="$root/WriterPadTests/DeviceIdentityServiceTests.swift"
adr="$root/Docs/ADR-0001-DeviceIdentityLifecycle.md"

require() {
    pattern=$1
    file=$2
    message=$3
    if ! grep -Eq "$pattern" "$file"; then
        echo "9-3 audit failed: $message" >&2
        exit 1
    fi
}

reject() {
    pattern=$1
    file=$2
    message=$3
    if grep -Eq "$pattern" "$file"; then
        echo "9-3 audit failed: $message" >&2
        exit 1
    fi
}

require 'actor KeychainDeviceIdentityStore' "$service" \
    "device identity Keychain actor is missing"
require 'actor DeviceIdentityService' "$service" \
    "device identity service actor is missing"
require 'kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly' "$service" \
    "ThisDeviceOnly accessibility is missing"
require 'kSecUseDataProtectionKeychain' "$service" \
    "data-protection Keychain is missing"
require 'redactedDescription' "$service" \
    "masked diagnostic representation is missing"
require 'invalidStoredIdentity' "$service" \
    "corrupt identity is not distinguished"
require 'capturedIdentifier' "$service" \
    "captured operation identity policy is missing"
require 'preservesExistingOperation' "$service" \
    "operation preservation rule is missing"
require 'deviceIdentityService' "$environment" \
    "AppEnvironment does not inject the device identity service"
require 'prepareIdentity' "$app" \
    "app startup does not prepare the device identity"
require 'Keychain.*복원|Keychain 값' "$adr" \
    "Keychain restore/corruption policy is not documented"
require '재설치' "$adr" \
    "reinstall policy is not documented"
require '덮어쓰지 않고' "$adr" \
    "identity rotation operation rule is not documented"
require 'testConcurrentRequestsCoalesceToOneCreation' "$tests" \
    "concurrent creation test is missing"
require 'testCorruptStoredIdentityFailsClosedWithoutReplacement' "$tests" \
    "corruption test is missing"
require 'testExistingOperationKeepsCapturedIdentityAfterRotation' "$tests" \
    "operation identity rotation test is missing"

reject 'UserDefaults|@AppStorage' "$service" \
    "device identity must not use preferences"
reject 'print[(]|NSLog|Logger[.]|os_log' "$service" \
    "device identity must not be written to general logs"
reject 'kSecAttrSynchronizable' "$service" \
    "device identity must not synchronize through iCloud Keychain"
reject 'ensure_project|ensureProject|SupabaseClient|commit_document|Realtime' \
    "$service" "9-4 or later server behavior leaked into 9-3"

echo "9-3 device identity foundation audit passed."
