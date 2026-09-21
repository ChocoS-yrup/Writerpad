import XCTest
import Foundation
@testable import SyntheticInitialReceive

private actor AppTestGate {
    var open = false
    var waiters:[CheckedContinuation<Void,Never>] = []
    func wait() async { if open { return };await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true;let pending = waiters;waiters = [];pending.forEach { $0.resume() } }
}
private final class AppTestReceipt:ReceiveAppReceipt {
    var verification:() async throws -> Void = {}
    var publication:() throws -> Void = {}
    func verify() async throws { try await verification() }
    func checkPublication() throws { try publication() }
}
private final class AppTestJob:ReceiveAppJob, @unchecked Sendable {
    let receipt = AppTestReceipt()
    var operation:() async throws -> Void = {}
    private let lock = NSLock()
    private var cancelled = 0, entered = 0
    var cancellations:Int { lock.lock();defer { lock.unlock() };return cancelled }
    var runs:Int { lock.lock();defer { lock.unlock() };return entered }
    private func begin() { lock.lock();entered += 1;lock.unlock() }
    func run() async throws -> any ReceiveAppReceipt { begin();try await operation();return receipt }
    func cancel() { lock.lock();cancelled += 1;lock.unlock() }
}
private final class AppThreadEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var main = false, reads = 0
    func record(_ url:URL) { lock.lock();defer { lock.unlock() };main = main || Thread.isMainThread;if url.lastPathComponent.hasPrefix("record-") { reads += 1 } }
    var value:(Bool,Int) { lock.lock();defer { lock.unlock() };return(main,reads) }
}

@MainActor
final class ReceiveOfflineAppSessionTests:XCTestCase {
    func life(active:Bool = true,available:Bool = true)->BoundaryLifecycle { let l = BoundaryLifecycle();l.update(active:active,protectedDataAvailable:available);return l }
    func home() throws -> URL {
        let h = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("AppReceiveRoute-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:h,withIntermediateDirectories:false)
        addTeardownBlock { try FileManager.default.removeItem(at:h) };return h
    }
    func tree(_ h:URL) throws -> [String:String] {
        var result:[String:String] = [:]
        for case let p as URL in FileManager.default.enumerator(at:h,includingPropertiesForKeys:[.isRegularFileKey])! where try p.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { result[p.path] = byteHash(try Data(contentsOf:p)) };return result
    }
    func testConstructionIsIdleWithClosedAuthority() {
        let s = ReceiveOfflineAppSession(lifecycle:life())
        XCTAssertEqual(s.state,.idle);XCTAssertFalse(s.isRunning || s.syntheticReady || s.baselineApplied || s.executionAllowed)
    }
    func testInactiveAndProtectedUnavailableBlockBeforeFactory() async {
        for l in [life(active:false),life(available:false)] {
            let s = ReceiveOfflineAppSession(lifecycle:l);var made = 0
            await s.run { _ in made += 1;return AppTestJob() }
            XCTAssertEqual(made,0);XCTAssertEqual(s.state,.stopped);XCTAssertFalse(s.isRunning)
        }
    }
    func testFactoryFailureStopsWithoutRawErrorPublication() async {
        let s = ReceiveOfflineAppSession(lifecycle:life())
        await s.run { _ in throw NSError(domain:"private-secret-path",code:7) }
        XCTAssertEqual(s.state,.stopped);XCTAssertFalse(s.syntheticReady || s.isRunning)
    }
    func testRevocationInsideFactoryCancelsJobBeforeRun() async {
        let l = life(),s = ReceiveOfflineAppSession(lifecycle:l),j = AppTestJob()
        await s.run { _ in s.invalidate();return j }
        XCTAssertEqual(j.runs,0);XCTAssertEqual(j.cancellations,1);XCTAssertEqual(s.state,.stopped)
    }
    func testSuccessfulReceiptRequiresVerifyAndPublicationGuard() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob();var verified = false,published = false
        j.receipt.verification = { verified = true };j.receipt.publication = { XCTAssertTrue(verified);published = true }
        await s.run { _ in j };XCTAssertTrue(verified && published && s.syntheticReady);XCTAssertFalse(s.isRunning || s.baselineApplied || s.executionAllowed)
    }
    func testVerificationFailureNeverPublishesSuccess() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob();var published = false
        j.receipt.verification = { throw SyntheticABError.journalCorrupt };j.receipt.publication = { published = true }
        await s.run { _ in j };XCTAssertFalse(published || s.syntheticReady || s.isRunning);XCTAssertEqual(s.state,.stopped)
    }
    func testFinalPublicationFailureCannotExposeVerifiedReceipt() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob()
        j.receipt.publication = { throw ReceiveConnectionError.changedSession }
        await s.run { _ in j };XCTAssertEqual(s.state,.stopped);XCTAssertFalse(s.syntheticReady)
    }
    func testSecondStartDoesNotReplaceRunningJobOrState() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob(),gate = AppTestGate(),entered = expectation(description:"running")
        j.operation = { entered.fulfill();await gate.wait() };let t = Task { await s.run { _ in j } }
        await fulfillment(of:[entered],timeout:2);var second = 0
        await s.run { _ in second += 1;return AppTestJob() }
        XCTAssertEqual(second,0);XCTAssertTrue(s.isRunning);XCTAssertEqual(s.state,.running)
        await gate.release();await t.value;XCTAssertTrue(s.syntheticReady)
    }
    func testInvalidateKeepsSlotUntilIgnoringCancellationJobEnds() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob(),gate = AppTestGate(),entered = expectation(description:"running")
        j.operation = { entered.fulfill();await gate.wait() };let t = Task { await s.run { _ in j } }
        await fulfillment(of:[entered],timeout:2);s.invalidate();XCTAssertEqual(j.cancellations,1);XCTAssertTrue(s.isRunning);XCTAssertEqual(s.state,.stopped)
        var made = 0;await s.run { _ in made += 1;return AppTestJob() };XCTAssertEqual(made,0)
        await gate.release();await t.value;XCTAssertFalse(s.isRunning || s.syntheticReady)
    }
    func testQuickBackgroundRestoreDoesNotPublishLateCompletion() async {
        let l = life(),s = ReceiveOfflineAppSession(lifecycle:l),j = AppTestJob(),gate = AppTestGate(),entered = expectation(description:"running")
        j.operation = { entered.fulfill();await gate.wait() };let t = Task { await s.run { _ in j } }
        await fulfillment(of:[entered],timeout:2);l.update(active:false,protectedDataAvailable:true);s.invalidate();l.update(active:true,protectedDataAvailable:true);s.invalidate()
        await gate.release();await t.value;XCTAssertFalse(s.syntheticReady);XCTAssertEqual(s.state,.stopped)
    }
    func testProtectionLossDuringReceiptVerificationStopsPublication() async {
        let l = life(),s = ReceiveOfflineAppSession(lifecycle:l),j = AppTestJob(),gate = AppTestGate(),entered = expectation(description:"verifying")
        j.receipt.verification = { entered.fulfill();await gate.wait() };let t = Task { await s.run { _ in j } }
        await fulfillment(of:[entered],timeout:2);l.update(active:true,protectedDataAvailable:false);s.invalidate();l.update(active:true,protectedDataAvailable:true)
        await gate.release();await t.value;XCTAssertFalse(s.syntheticReady || s.isRunning)
    }
    func testTaskCancellationDuringVerificationCancelsAndDiscardsLateReceipt() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),j = AppTestJob(),gate = AppTestGate(),entered = expectation(description:"verifying")
        j.receipt.verification = { entered.fulfill();await gate.wait() };let t = Task { await s.run { _ in j } }
        await fulfillment(of:[entered],timeout:2);t.cancel();await gate.release();await t.value
        XCTAssertGreaterThanOrEqual(j.cancellations,1);XCTAssertFalse(s.syntheticReady || s.isRunning)
    }
    func testPrecancelledTaskDoesNotConstructJob() async {
        let s = ReceiveOfflineAppSession(lifecycle:life()),gate = AppTestGate();var made = 0
        let t = Task { await gate.wait();await s.run { _ in made += 1;return AppTestJob() } }
        t.cancel();await gate.release();await t.value;XCTAssertEqual(made,0);XCTAssertEqual(s.state,.stopped)
    }
    func testCompletedStateIsClearedByLaterInvalidation() async {
        let s = ReceiveOfflineAppSession(lifecycle:life());await s.run { _ in AppTestJob() };XCTAssertTrue(s.syntheticReady)
        s.invalidate();XCTAssertFalse(s.syntheticReady);XCTAssertEqual(s.state,.stopped)
    }
    func testWrongBundleCannotConstructNativeAppJobOrWriteDisk() throws {
        let h = try home(),l = life()
        XCTAssertThrowsError(try ReceiveOfflineAppJob(home:h,declaredBundle:"wrong.bundle",lease:l.begin(),protection:.init()))
        XCTAssertTrue(try tree(h).isEmpty)
    }
    func testFixedNativeAppRouteUsesRealClockAndKeepsAllDiskOffMainThread() async throws {
        let h = try home(),l = life(),s = ReceiveOfflineAppSession(lifecycle:l),evidence = AppThreadEvidence()
        let access = PhysicalStorageAccess(created:evidence.record,verify:evidence.record)
        await s.run { lease in try ReceiveOfflineAppJob(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access) }
        XCTAssertTrue(s.syntheticReady);XCTAssertFalse(s.isRunning);XCTAssertFalse(evidence.value.0);XCTAssertGreaterThan(evidence.value.1,0)
        let before = try tree(h)
        await s.run { lease in try ReceiveOfflineAppJob(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access) }
        XCTAssertFalse(s.syntheticReady);XCTAssertEqual(try tree(h),before)
    }
    func testNativeAppJobCancellationDoesNotInitializeDisk() async throws {
        let h = try home(),l = life(),job = try ReceiveOfflineAppJob(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:l.begin(),protection:.init())
        job.cancel();do { _ = try await job.run();XCTFail() } catch {}
        XCTAssertTrue(try tree(h).isEmpty)
    }
    func testNativeReceiptAsyncReadRechecksDamageWithoutBlockingUIThread() async throws {
        let h = try home(),l = life(),evidence = AppThreadEvidence()
        let job = try ReceiveOfflineAppJob(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:l.begin(),protection:.init(created:evidence.record,verify:evidence.record))
        let receipt = try await job.run();try await receipt.verify();try receipt.checkPublication();XCTAssertFalse(evidence.value.0)
        let path = h.appendingPathComponent("Library/Application Support/WriterPadReceiveBoundary-v1/execution-journal/record-059.json")
        try Data("{}".utf8).write(to:path)
        do { try await receipt.verify();XCTFail() } catch {}
        XCTAssertFalse(evidence.value.0)
    }
}
