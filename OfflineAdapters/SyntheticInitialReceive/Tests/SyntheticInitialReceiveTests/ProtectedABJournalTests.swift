import Foundation
import Darwin
import XCTest
@testable import SyntheticInitialReceive

final class ProtectedABJournalTests: XCTestCase {
    typealias Protection = ProtectedContainerTests.Protection
    let fm = FileManager.default
    enum Injected: Error { case stop }
    func home() throws -> URL {
        let h = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("ProtectedABFakeHome-"+UUID().uuidString.lowercased())
        try fm.createDirectory(at:h,withIntermediateDirectories:false)
        addTeardownBlock { try? self.fm.removeItem(at:h) }; return h
    }
    func active() -> BoundaryLifecycle { let life = BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true);return life }
    func work(_ h: URL,_ life: BoundaryLifecycle,_ p: Protection) throws -> ProtectedABJournalWork {
        let lease = try life.begin()
        return try .init(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:p.access(lease))
    }
    func tree(_ root:URL) throws -> [String:Data] {
        var files: [String:Data] = [:]
        func visit(_ dir:URL,_ prefix:String) throws {
            for name in try fm.contentsOfDirectory(atPath:dir.path) {
                let u = dir.appendingPathComponent(name), a = try XCTUnwrap(SafeFiles.attributes(u))
                if a.st_mode & S_IFMT == S_IFDIR { try visit(u,prefix+name+"/") }
                else if a.st_mode & S_IFMT == S_IFREG { files[prefix+name] = try Data(contentsOf:u) }
            }
        }
        try visit(root,"");return files
    }
    func mock() -> SyntheticABTransport { let e = SyntheticABExpected.fixture();return .init(e.responses()+e.responses()) }
    func blocked(_ w:ProtectedABJournalWork,_ h:URL) throws {
        let before = try tree(h), t = mock()
        XCTAssertThrowsError(try w.run(transport:t));XCTAssertTrue(t.calls.isEmpty);XCTAssertEqual(try tree(h),before)
    }
    func testProtectedRunPersistsAllStagesAndClosedAuthority() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
        let result = try w.run(transport:t), report = try result.checkedReport(), state = try w.inspect()
        XCTAssertEqual(t.calls.count,14);XCTAssertEqual(state.httpUsed,14);XCTAssertEqual(state.authUsed,2);XCTAssertEqual(state.status,"finished")
        XCTAssertEqual(state.context?.timing,.fixture);XCTAssertEqual(state.context?.sessionExpiresUTCMS,6000)
        XCTAssertEqual(try tree(h).count,64);XCTAssertTrue(report.synthetic_policy_passed)
        XCTAssertFalse(report.baseline_applied || report.execution_allowed || report.app_binding_created || report.editing_allowed || report.sending_allowed || report.automatic_receive_allowed)
        XCTAssertThrowsError(try result.requireApplyInput())
        let owner = try Data(contentsOf:w.container.workspace.appendingPathComponent("execution-journal/owner.json"))
        XCTAssertTrue(String(decoding:owner,as:UTF8.self).contains("synthetic-ab-protected-journal-v1"))
    }
    func testProtectionAppliedToEveryNewFileBeforeAnyPayloadByte() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        _ = try w.run()
        XCTAssertTrue(p.firstByteSizes.allSatisfy { $0 == 0 })
        XCTAssertTrue(p.createdNames.contains("execution-journal"));XCTAssertTrue(p.createdNames.contains("lock"))
        XCTAssertTrue(p.createdNames.contains("owner.json.pending"));XCTAssertTrue(p.createdNames.contains("record-059.json.pending"))
        for name in try tree(w.container.workspace).keys { try p.verify(w.container.workspace.appendingPathComponent(name)) }
    }
    func testWrongBundleAndRevokedLeaseCannotPrepareHome() throws {
        let h = try home(), life = active(), p = Protection(), lease = try life.begin()
        XCTAssertThrowsError(try ProtectedABJournalWork(home:h,declaredBundle:"old.app",lease:lease,protection:p.access(lease)))
        life.update(active:false,protectedDataAvailable:true)
        XCTAssertThrowsError(try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:p.access(lease)))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:h.path),[])
    }
    func testOuterLeaseCannotBeBypassedByPermissiveProtectionCheck() throws {
        let h = try home(), life = active(), p = Protection(), lease = try life.begin()
        let access = PhysicalStorageAccess(created:p.create,verify:p.verify)
        let w = try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access)
        life.update(active:true,protectedDataAvailable:false)
        XCTAssertThrowsError(try w.run());XCTAssertEqual(try fm.contentsOfDirectory(atPath:h.path),[])
    }
    func testHostInitializerCannotAdoptProtectedWorkspace() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        try w.container.prepare()
        XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:w.container.workspace));XCTAssertEqual(try tree(h).count,1)
    }
    func testSeparateJournalPreservesExistingFivePartStoreAndNeighborOriginals() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        let support = h.appendingPathComponent("Library/Application Support")
        try fm.createDirectory(at:support,withIntermediateDirectories:true)
        try Data(repeating:65,count:18).write(to:support.appendingPathComponent("synthetic-unsent-a"))
        try Data(repeating:66,count:19).write(to:support.appendingPathComponent("synthetic-unsent-b"))
        try w.container.prepare();let session = try w.container.session(input:BoundaryAppFixture.make());try session.apply()
        let before = try tree(h)
        _ = try w.run();XCTAssertEqual(try session.snapshot().count,5)
        let after = try tree(h);for (name,data) in before { XCTAssertEqual(after[name],data) }
        try session.apply();XCTAssertEqual(try tree(h),after)
    }
    func testFinishedReopenInspectsButNeverStartsNewRun() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p);_ = try w.run()
        let before = try tree(h);life.update(active:true,protectedDataAvailable:true)
        let reopened = try work(h,life,p);XCTAssertEqual(try reopened.inspect().httpUsed,14)
        try blocked(reopened,h);XCTAssertEqual(try tree(h),before)
    }
    func testLockOrBackgroundAfterCompletionRevokesPublicationPermanently() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), result = try w.run()
        let before = try tree(h)
        for flags in [(true,false),(false,true),(true,true)] {
            life.update(active:flags.0,protectedDataAvailable:flags.1)
            XCTAssertThrowsError(try result.checkedReport());XCTAssertThrowsError(try w.inspect())
        }
        try blocked(work(h,life,p),h);XCTAssertEqual(try tree(h),before)
    }
    func testProtectionFailureAtRootLockOwnerAndRecordLeavesNoTransportCalls() throws {
        for name in ["execution-journal","lock","owner.json.pending","record-000.json.pending","head.json.pending","record-001.json.pending","record-002.json.pending"] {
            let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
            try w.container.prepare();p.failCreation = name
            XCTAssertThrowsError(try w.run(transport:t),name);XCTAssertTrue(t.calls.isEmpty)
            let before = try tree(h)
            if let data = before.first(where: { $0.key.hasSuffix(name) && name.hasSuffix("pending") })?.value { XCTAssertTrue(data.isEmpty,name) }
            p.failCreation = nil;try blocked(work(h,life,p),h);XCTAssertEqual(try tree(h),before)
        }
    }
    func testBackgroundDuringProtectionSettingLeavesEmptyPendingAndOldLeaseBlocked() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
        p.onCreate = { url in if url.lastPathComponent == "record-002.json.pending" { life.update(active:false,protectedDataAvailable:true) } }
        XCTAssertThrowsError(try w.run(transport:t));XCTAssertTrue(t.calls.isEmpty)
        let before = try tree(h);XCTAssertEqual(before.first { $0.key.hasSuffix("record-002.json.pending") }?.value.count,0)
        life.update(active:true,protectedDataAvailable:true);p.onCreate = nil
        try blocked(w,h);try blocked(work(h,life,p),h);XCTAssertEqual(try tree(h),before)
    }
    func testQuickRestoreAtPrePayloadPendingPublishedAndCommittedBoundariesCannotResume() throws {
        for point in ["protected:reserve:1:record-002.json","pending:reserve:1:record-002.json","published:reserve:1:record-002.json","pending:reserve:1:head.json","published:reserve:1:head.json","committed:reserve:1","committed:start:1","committed:metadata:1","committed:response:1"] {
            let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
            XCTAssertThrowsError(try w.run(transport:t,checkpoint:{ if $0 == point { life.update(active:true,protectedDataAvailable:false);life.update(active:true,protectedDataAvailable:true) } }),point)
            XCTAssertEqual(t.calls.count,point.contains("metadata") || point.contains("response") ? 1 : 0,point)
            try blocked(w,h);try blocked(work(h,life,p),h)
        }
    }
    func testReservationIsPreservedWhenLifecycleBlocksStart() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
        XCTAssertThrowsError(try w.run(transport:t,checkpoint:{ if $0 == "committed:reserve:1" { life.update(active:false,protectedDataAvailable:true) } }))
        XCTAssertTrue(t.calls.isEmpty);life.update(active:true,protectedDataAvailable:true)
        let reopened = try work(h,life,p), state = try reopened.inspect()
        XCTAssertEqual(state.httpUsed,1);XCTAssertEqual(state.authUsed,1);XCTAssertNil(state.events[0].startedMonoMS);XCTAssertEqual(state.status,"running")
        try blocked(reopened,h)
    }
    func testBackgroundAtProbeAndFinishCannotPublishSuccess() throws {
        for point in ["committed:local_start","pending:finish:head.json","committed:finish"] {
            let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), t = mock()
            XCTAssertThrowsError(try w.run(transport:t,checkpoint:{ if $0 == point { life.update(active:false,protectedDataAvailable:true) } }))
            XCTAssertEqual(t.calls.count,14);life.update(active:true,protectedDataAvailable:true);try blocked(work(h,life,p),h)
        }
    }
    func testWeakExistingProtectionIsNeverRepaired() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), result = try w.run()
        let before = try tree(h), calls = p.createdNames
        for name in ["WriterPadReceiveBoundary-v1","container.json","execution-journal","lock","owner.json","head.json","record-002.json","record-059.json"] {
            p.rejectVerification = name
            XCTAssertThrowsError(try w.inspect(),name);XCTAssertThrowsError(try result.checkedReport(),name)
            try blocked(w,h);XCTAssertEqual(p.createdNames,calls);XCTAssertEqual(try tree(h),before)
        }
    }
    func testReadRevocationDoesNotReturnStateOrPublishAfterRestore() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p);_ = try w.run()
        let before = try tree(h), lease = try life.begin()
        var triggered = false
        let access = PhysicalStorageAccess(created:p.create,verify:{ url in
            try p.verify(url)
            if url.lastPathComponent == "record-001.json" && !triggered { triggered = true;life.update(active:false,protectedDataAvailable:true);life.update(active:true,protectedDataAvailable:true) }
        })
        let reader = try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access)
        XCTAssertThrowsError(try reader.inspect());XCTAssertTrue(triggered);XCTAssertThrowsError(try reader.inspect());XCTAssertEqual(try tree(h),before)
    }
    func testDamagedCompletedJournalRevokesPreviouslyReturnedCompletion() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), result = try w.run()
        try Data("{}\n".utf8).write(to:w.container.workspace.appendingPathComponent("execution-journal/record-059.json"))
        let before = try tree(h);XCTAssertThrowsError(try result.checkedReport());try blocked(w,h);XCTAssertEqual(try tree(h),before)
    }
    func testPartialContainerCannotBeRepairedByJournalEntry() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        p.failCreation = "container.json.pending";XCTAssertThrowsError(try w.run());let before = try tree(h)
        p.failCreation = nil;try blocked(work(h,life,p),h);XCTAssertEqual(try tree(h),before)
    }
    func testForeignFileAndSymlinkJournalBlockBeforeRequests() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p);try w.container.prepare()
        let foreign = w.container.workspace.appendingPathComponent("unknown");try Data("preserve".utf8).write(to:foreign)
        try blocked(w,h);try fm.removeItem(at:foreign)
        let outside = h.appendingPathComponent("outside");try fm.createDirectory(at:outside,withIntermediateDirectories:false)
        try Data("preserve".utf8).write(to:outside.appendingPathComponent("original"))
        try fm.createSymbolicLink(at:w.container.workspace.appendingPathComponent("execution-journal"),withDestinationURL:outside)
        let t = mock();XCTAssertThrowsError(try w.run(transport:t));XCTAssertTrue(t.calls.isEmpty)
        XCTAssertEqual(try Data(contentsOf:outside.appendingPathComponent("original")),Data("preserve".utf8))
    }
    func testHostOwnerFormatCannotBePromotedToProtectedOwner() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        XCTAssertThrowsError(try w.run(checkpoint:{ if $0 == "committed:claim" { throw Injected.stop } }))
        let url = w.container.workspace.appendingPathComponent("execution-journal/owner.json")
        try canonical(SyntheticABDiskJournal.Owner(format:"synthetic-ab-disk-journal-v1",workspace:w.container.workspace.path)).write(to:url)
        try blocked(w,h);XCTAssertThrowsError(try w.inspect())
    }
    func testResponseLossKeepsChargeInProtectedStoppedJournal() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p), e = SyntheticABExpected.fixture()
        var responses = e.responses();responses[0].lost = true
        XCTAssertThrowsError(try w.run(transport:SyntheticABTransport(responses)))
        let state = try w.inspect();XCTAssertEqual(state.status,"stopped");XCTAssertEqual(state.httpUsed,1);XCTAssertEqual(state.authUsed,1)
        XCTAssertNotNil(state.events[0].startedMonoMS);try blocked(w,h)
    }
    func testLockIsReleasedWhenProtectedAccessFailsDuringInitialization() throws {
        let h = try home(), life = active(), p = Protection(), w = try work(h,life,p)
        p.failCreation = "owner.json.pending";XCTAssertThrowsError(try w.run());p.failCreation = nil
        let lock = w.container.workspace.appendingPathComponent("execution-journal/lock"), fd = open(lock.path,O_RDWR|O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd,0);guard fd >= 0 else { return };defer { close(fd) }
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0);_ = flock(fd,LOCK_UN)
        try blocked(w,h)
    }
}
