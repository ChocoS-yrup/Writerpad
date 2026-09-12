#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output="$root/build/ipad-bidirectional-preparation-20260911"
packages="$root/build/ipad-catalog-candidate-20260911/private/SourcePackages"
: "${WRITERPAD_SIMULATOR_ID:?dedicated synthetic Simulator required}"
label=${1:-first}
mkdir -p "$output/private"
set -- -project "$root/WriterPad.xcodeproj" -scheme WriterPad -configuration Debug \
 -destination "platform=iOS Simulator,id=$WRITERPAD_SIMULATOR_ID" \
 -derivedDataPath "$output/private/TestDerivedData" -clonedSourcePackagesDirPath "$packages" \
 -disableAutomaticPackageResolution -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile
xcodebuild build-for-testing "$@" 'OTHER_SWIFT_FLAGS=$(inherited) -DWRITERPAD_ISOLATED_TESTS' CODE_SIGNING_ALLOWED=NO > "$output/private/build-$label.log" 2>&1
xcodebuild test-without-building "$@" -parallel-testing-enabled NO -test-timeouts-enabled YES \
 -default-test-execution-time-allowance 60 -resultBundlePath "$output/private/tests-$label.xcresult" \
 -only-testing:WriterPadTests/BodyValidationPolicyTests \
 -only-testing:WriterPadTests/BodyValidationServiceTests \
 -only-testing:WriterPadTests/ReceiveValidationPolicyTests \
 -only-testing:WriterPadTests/ServerProjectCatalogTests \
 -only-testing:WriterPadTests/SyncV2ClientTests \
 -only-testing:WriterPadTests/EditLeaseManagerTests \
 -only-testing:WriterPadTests/LocalDocumentStoreTests \
 -only-testing:WriterPadTests/SupabaseAuthServiceTests \
 -skip-testing:WriterPadTests/SupabaseAuthServiceTests/testKeychainStoreRoundTripsAndDeletesSession \
 -only-testing:WriterPadTests/SyncV2StoreTests/testReceiveGuardDirectClaimsRecoveryAndRetryPreserveDatabaseBytes \
 > "$output/private/tests-$label.log" 2>&1
