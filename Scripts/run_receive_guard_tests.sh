#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mode=${1:-regression}
label=${2:-final}
: "${WRITERPAD_SIMULATOR_ID:?Use a dedicated synthetic-data iOS Simulator UUID}"
case "$mode" in regression|selected) ;; *) exit 2;; esac
output="$root/build/ipad-catalog-receive-guard-20260911"
packages="$root/build/ipad-catalog-candidate-20260911/private/SourcePackages"
derived="$output/TestDerivedData"
flags='$(inherited) -DWRITERPAD_ISOLATED_TESTS'
if [ "$mode" = selected ]; then flags="$flags -DWRITERPAD_RECEIVE_VALIDATION"; fi
mkdir -p "$output"
set -- -project "$root/WriterPad.xcodeproj" -scheme WriterPad -configuration Debug \
    -destination "platform=iOS Simulator,id=$WRITERPAD_SIMULATOR_ID" -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$packages" -disableAutomaticPackageResolution -skipPackageUpdates \
    -onlyUsePackageVersionsFromResolvedFile
xcodebuild build-for-testing "$@" "OTHER_SWIFT_FLAGS=$flags" CODE_SIGNING_ALLOWED=NO > "$output/build-$mode-$label.log" 2>&1
if [ "$mode" = selected ]; then
    set -- "$@" -only-testing:WriterPadTests/ReceiveValidationBuildSelectionTests
else
    set -- "$@" \
        -only-testing:WriterPadTests/ReceiveValidationPolicyTests \
        -only-testing:WriterPadTests/ServerProjectCatalogTests \
        -only-testing:WriterPadTests/SupabaseAuthServiceTests \
        -skip-testing:WriterPadTests/SupabaseAuthServiceTests/testKeychainStoreRoundTripsAndDeletesSession \
        -only-testing:WriterPadTests/SyncV2DispatcherTests \
        -only-testing:WriterPadTests/EditLeaseManagerTests \
        -only-testing:WriterPadTests/SyncV2ClientTests \
        -only-testing:WriterPadTests/SyncV2StoreTests/testReceiveGuardDirectClaimsRecoveryAndRetryPreserveDatabaseBytes \
        -only-testing:WriterPadTests/SyncV2StoreTests/testForbiddenUpdateLaneRecoversOnLaunchAndExplicitRetry \
        -only-testing:WriterPadTests/SyncV2StoreTests/testDispatcherClaimPreservesDocumentFIFOAndPromotesNextRevision \
        -only-testing:WriterPadTests/SupabaseProjectBindingServiceTests/testReceiveGuardBindingLookupDoesNotEnqueueInitialSnapshotOrEnsure \
        -only-testing:WriterPadTests/SupabaseProjectBindingServiceTests/testFailedInitialSnapshotIsNotReportedConnectedAndRecoversOnLookup \
        -only-testing:WriterPadTests/SupabaseProjectBindingServiceTests/testNewAndWindowsConnectionsRecordInitialSnapshotsWithDistinctKinds \
        -only-testing:WriterPadTests/SyncV2HandshakeTests/testGeneralRestartGateCloseOrReloginDuringReadNeverClaimsOrSends \
        -only-testing:WriterPadTests/SyncV2HandshakeTests/testGeneralSenderHonorsGateClosureAtTransportReservation \
        -only-testing:WriterPadTests/SyncV2HandshakeTests/testContractPathNeedsGateAndStandingAnswerTogether
fi
xcodebuild test-without-building "$@" -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 -resultBundlePath "$output/tests-$mode-$label.xcresult" \
    > "$output/tests-$mode-$label.log" 2>&1
