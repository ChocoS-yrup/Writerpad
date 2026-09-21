import Foundation
import Darwin
import XCTest
@testable import SyntheticInitialReceive

final class StorageFailureDiagnosticTests: XCTestCase {
    private func home() throws -> URL {
        let url = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("DiagnosticSynthetic-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:url) }
        return url
    }
    private func files(_ root: URL) throws -> [String:Data] {
        var result: [String:Data] = [:]
        let inventory = try SafeFiles.inventory(root)
        for file in inventory.files { result[file] = try SafeFiles.read(root.appendingPathComponent(file)) }
        return result
    }
    private func run(_ h:URL,_ trace:StorageFailureRecorder,_ access:PhysicalStorageAccess = .init()) throws -> LocalBoundaryReceipt {
        try StorageDiagnostics.$recorder.withValue(trace) {
            try SyntheticStorageDiagnosticWork.run(home:h,bundle:ProtectedBoundaryContainer.bundleID,access:access)
        }
    }
    func testEachStageRetainsOriginalErrorAndNumericFoundationCode() throws {
        for stage in StorageDiagnosticStage.allCases {
            let trace = StorageFailureRecorder()
            let original = NSError(domain:NSCocoaErrorDomain,code:513,userInfo:[NSFilePathErrorKey:"/private/secret",NSLocalizedDescriptionKey:"TOKEN secret body"])
            XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
                try StorageDiagnostics.at(stage) { throw original }
            }) { XCTAssertTrue(($0 as NSError) === original) }
            XCTAssertEqual(trace.failure?.stage,stage.rawValue)
            XCTAssertEqual(trace.failure?.category,"cocoa")
            XCTAssertEqual(trace.failure?.code,"513")
            let text = String(decoding:try JSONEncoder().encode(trace.failure),as:UTF8.self)
            XCTAssertFalse(text.contains("secret"));XCTAssertFalse(text.contains("TOKEN"));XCTAssertFalse(text.contains("/private"))
        }
    }
    func testUnknownDomainAndErrorDescriptionCannotLeak() throws {
        let trace = StorageFailureRecorder()
        trace.capture(NSError(domain:"token-and-body-secret",code:123,userInfo:[NSLocalizedDescriptionKey:"private text"]),stage:.input)
        let text = String(decoding:try JSONEncoder().encode(trace.failure),as:UTF8.self)
        XCTAssertEqual(trace.failure?.category,"unknown");XCTAssertEqual(trace.failure?.code,"unclassified")
        XCTAssertFalse(text.contains("secret"));XCTAssertFalse(text.contains("private text"))
    }
    func testPathValidationReasonIsFixedAndPreservesLegacyError() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let invalid = h.appendingPathComponent("..", isDirectory: true).appendingPathComponent("child")
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.container) { try SafeFiles.checked(invalid) }
        }) { XCTAssertEqual($0 as? ReceiveError, .path) }
        XCTAssertEqual(trace.failure?.phase, "container")
        XCTAssertEqual(trace.failure?.stage, "container")
        XCTAssertEqual(trace.failure?.category, "receive")
        XCTAssertEqual(trace.failure?.code, "path")
        XCTAssertEqual(trace.failure?.reason, "dotComponent")
        XCTAssertEqual(trace.failure?.displayText, "진단 · container.container / receive:path / reason:dotComponent")
        let encoded = String(decoding: try JSONEncoder().encode(trace.failure), as: UTF8.self)
        XCTAssertFalse(encoded.contains(h.path)); XCTAssertFalse(encoded.contains("child"))
    }
    func testNestedProtectionFailureSurvivesOuterCatch() throws {
        let trace = StorageFailureRecorder()
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.prepare) {
                try StorageDiagnostics.at(.protectionSet) { throw ProtectedBoundaryError.protection }
            }
        }) { XCTAssertEqual($0 as? ProtectedBoundaryError,.protection) }
        trace.capture(ReceiveError.io,stage:.entry)
        XCTAssertEqual(trace.failure?.stage,"protectionSet");XCTAssertEqual(trace.failure?.category,"protection")
        XCTAssertEqual(trace.failure?.phase,"prepare")
    }
    func testPOSIXCaptureKeepsLegacyErrorAndImmediateErrno() throws {
        let trace = StorageFailureRecorder()
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.prepare) {
                let sameError = StorageDiagnostics.posix(ReceiveError.existingData,.openPending,EACCES)
                errno = EINVAL
                throw sameError
            }
        }) { XCTAssertEqual($0 as? ReceiveError,.existingData) }
        XCTAssertEqual(trace.failure?.posixCode,EACCES);XCTAssertEqual(trace.failure?.code,"existingData")
        XCTAssertEqual(trace.failure?.operation,"openPending")
    }
    func testRealPendingCollisionKeepsFileBytesAndDoesNotWriteDestination() throws {
        let h = try home(), target = h.appendingPathComponent("head.json"), trace = StorageFailureRecorder()
        let pending = target.appendingPathExtension("pending"), original = Data("preserved".utf8)
        try original.write(to:pending)
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.apply) { try SafeFiles.write(Data("new".utf8),to:target,checkpoint:{_ in}) }
        }) { XCTAssertEqual($0 as? ReceiveError,.existingData) }
        XCTAssertEqual(trace.failure?.posixCode,EEXIST);XCTAssertEqual(trace.failure?.stage,"apply")
        XCTAssertEqual(try Data(contentsOf:pending),original);XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testAncestorLstatErrorCapturedBeforeStorageCreation() throws {
        let h = try home(), blocker = h.appendingPathComponent("regular-file"), trace = StorageFailureRecorder()
        try Data("keep".utf8).write(to:blocker)
        XCTAssertThrowsError(try run(blocker.appendingPathComponent("child"),trace)) { XCTAssertEqual($0 as? ReceiveError,.io) }
        XCTAssertEqual(trace.failure?.stage,"container");XCTAssertEqual(trace.failure?.operation,"lstat")
        XCTAssertEqual(trace.failure?.posixCode,ENOTDIR)
        XCTAssertEqual(try files(h),["regular-file":Data("keep".utf8)])
    }
    func testWrongBundleStopsBeforeWrites() throws {
        let h = try home(), trace = StorageFailureRecorder()
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try SyntheticStorageDiagnosticWork.run(home:h,bundle:"wrong",access:.init())
        }) { XCTAssertEqual($0 as? LocalBoundaryError,.bundle) }
        XCTAssertEqual(trace.failure?.stage,"container");XCTAssertEqual(try files(h),[:])
    }
    func testSystemHomeAliasReproducesFailureAndPOSIXHomeAllowsSyntheticSave() throws {
        let h = try home(), oldTrace = StorageFailureRecorder()
        let aliased = h.resolvingSymlinksInPath()
        XCTAssertNotEqual(aliased.path, h.path, "Fixture must expose the Foundation system alias")
        XCTAssertThrowsError(try run(aliased, oldTrace)) { XCTAssertEqual($0 as? ReceiveError, .path) }
        XCTAssertEqual(oldTrace.failure?.reason, "invalidAncestorType")
        XCTAssertEqual(oldTrace.failure?.phase, "container")
        XCTAssertEqual(try files(h), [:])

        let resolved = try BoundarySystemHome.resolve(systemHome: aliased.path)
        XCTAssertEqual(resolved.path, h.path)
        let trace = StorageFailureRecorder()
        XCTAssertTrue(try run(resolved, trace).synthetic_boundary_ready)
        let before = try files(h)
        XCTAssertEqual(before.count, 17)
        XCTAssertTrue(try run(resolved, trace).synthetic_boundary_ready)
        XCTAssertEqual(try files(h), before)
        XCTAssertNil(trace.failure)
    }
    func testResolvedHomeStillRejectsLinkedStorageAncestorWithoutChangingTarget() throws {
        let h = try home(), outside = try home(), trace = StorageFailureRecorder()
        let marker = outside.appendingPathComponent("preserved")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: h.appendingPathComponent("Library"), withDestinationURL: outside)
        let resolved = try BoundarySystemHome.resolve(systemHome: h.path)
        XCTAssertThrowsError(try run(resolved, trace)) { XCTAssertEqual($0 as? ReceiveError, .path) }
        XCTAssertEqual(trace.failure?.reason, "invalidAncestorType")
        XCTAssertEqual(trace.failure?.phase, "prepare")
        XCTAssertEqual(try files(outside), ["preserved": Data("keep".utf8)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.path), ["Library"])
    }
    func testResolvedHomeStillRejectsHardLinkedFile() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let original = h.appendingPathComponent("original"), linked = h.appendingPathComponent("linked")
        try Data("keep".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)
        let resolved = try BoundarySystemHome.resolve(systemHome: h.path)
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.prepare) { try SafeFiles.checked(resolved.appendingPathComponent("linked")) }
        }) { XCTAssertEqual($0 as? ReceiveError, .path) }
        XCTAssertEqual(trace.failure?.reason, "invalidAncestorType")
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: linked), Data("keep".utf8))
    }
    func testMissingSystemHomeCapturesRealpathErrnoWithoutCreatingStorage() throws {
        let h = try home(), trace = StorageFailureRecorder()
        XCTAssertThrowsError(try StorageDiagnostics.$recorder.withValue(trace) {
            try StorageDiagnostics.at(.container) { try BoundarySystemHome.resolve(systemHome: h.appendingPathComponent("missing").path) }
        }) { XCTAssertEqual($0 as? ReceiveError, .io) }
        XCTAssertEqual(trace.failure?.operation, "realpath")
        XCTAssertEqual(trace.failure?.posixCode, ENOENT)
        XCTAssertEqual(trace.failure?.phase, "container")
        XCTAssertEqual(try files(h), [:])
        let encoded = String(decoding: try JSONEncoder().encode(trace.failure), as: UTF8.self)
        XCTAssertFalse(encoded.contains(h.path)); XCTAssertFalse(encoded.contains("missing"))
    }
    func testSuccessAndRepeatAreIdenticalAndEmitNoFailure() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let result = try run(h,trace), before = try files(h)
        XCTAssertTrue(result.synthetic_boundary_ready)
        XCTAssertFalse(result.baseline_applied || result.execution_allowed || result.editing_allowed || result.sending_allowed)
        XCTAssertEqual(before.count,17)
        XCTAssertEqual(try run(h,trace),result);XCTAssertEqual(try files(h),before);XCTAssertNil(trace.failure)
    }
    func testProtectionFailurePreservesPartialContainerAndFirstErrorOnRetry() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let access = PhysicalStorageAccess(created:{ url in
            if url.lastPathComponent == "WriterPadReceiveBoundary-v1" {
                try StorageDiagnostics.at(.protectionSet) { throw ProtectedBoundaryError.protection }
            }
        })
        XCTAssertThrowsError(try run(h,trace,access))
        let inventory = try SafeFiles.inventory(h), first = trace.failure
        XCTAssertEqual(first?.stage,"protectionSet")
        XCTAssertThrowsError(try run(h,trace)) { XCTAssertEqual($0 as? ProtectedBoundaryError,.incompleteContainer) }
        XCTAssertEqual(trace.failure,first)
        XCTAssertEqual(try SafeFiles.inventory(h).directories,inventory.directories)
        XCTAssertEqual(try files(h),[:])
    }
    func testApplyFailureBeforeLockLeavesOnlySeal() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let access = PhysicalStorageAccess(check:{ if StorageDiagnostics.stage == .apply { throw ProtectedBoundaryError.leaseRevoked } })
        XCTAssertThrowsError(try run(h,trace,access))
        XCTAssertEqual(trace.failure?.stage,"apply");XCTAssertEqual(trace.failure?.code,"leaseRevoked")
        XCTAssertEqual(try files(h).count,1)
    }
    func testSnapshotFailureDoesNotMeanApplyWasEmptyOrUndoCompletion() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let access = PhysicalStorageAccess(check:{ if StorageDiagnostics.stage == .snapshot { throw ProtectedBoundaryError.leaseRevoked } })
        XCTAssertThrowsError(try run(h,trace,access))
        XCTAssertEqual(trace.failure?.stage,"snapshot");let before = try files(h);XCTAssertEqual(before.count,17)
        let next = StorageFailureRecorder();XCTAssertTrue(try run(h,next).synthetic_boundary_ready)
        XCTAssertEqual(try files(h),before);XCTAssertNil(next.failure);XCTAssertEqual(trace.failure?.stage,"snapshot")
    }
    func testPublishRevocationRetainsCompleteFilesWithoutSuccess() throws {
        let h = try home(), trace = StorageFailureRecorder()
        let access = PhysicalStorageAccess(check:{ if StorageDiagnostics.stage == .publish { throw ProtectedBoundaryError.leaseRevoked } })
        XCTAssertThrowsError(try run(h,trace,access))
        XCTAssertEqual(trace.failure?.stage,"publish");XCTAssertEqual(try files(h).count,17)
    }
    func testConcurrentTaskScopesAndExplicitDetachedBindingAreIsolated() async throws {
        let first = StorageFailureRecorder(), second = StorageFailureRecorder()
        async let a: Void = Task.detached {
            StorageDiagnostics.$recorder.withValue(first) {
                _ = StorageDiagnostics.posix(ReceiveError.io,.lstat,EACCES)
            }
        }.value
        async let b: Void = Task.detached {
            StorageDiagnostics.$recorder.withValue(second) {
                try? StorageDiagnostics.at(.snapshot) { throw LocalBoundaryError.content }
            }
        }.value
        _ = await (a,b)
        XCTAssertEqual(first.failure?.posixCode,EACCES);XCTAssertEqual(second.failure?.stage,"snapshot")
        XCTAssertNil(second.failure?.posixCode);XCTAssertNil(StorageDiagnostics.recorder)
    }
    func testNoDiagnosticScopeRetainsLegacyErrors() {
        XCTAssertNil(StorageDiagnostics.recorder)
        XCTAssertEqual(StorageDiagnostics.posix(ReceiveError.existingData,.openPending,EPERM),.existingData)
    }
    func testTypedCancellationAndPOSIXNSErrorAreSanitized() {
        let a = StorageFailureRecorder(), b = StorageFailureRecorder()
        a.capture(CancellationError(),stage:.publish)
        b.capture(NSError(domain:NSPOSIXErrorDomain,code:Int(EPERM),userInfo:[NSFilePathErrorKey:"private"]),stage:.protectionRead)
        XCTAssertEqual(a.failure?.category,"task");XCTAssertEqual(a.failure?.code,"cancelled")
        XCTAssertEqual(b.failure?.category,"posix");XCTAssertEqual(b.failure?.code,String(EPERM))
    }
}
