import Foundation
import XCTest
@testable import SyntheticInitialReceive

final class ABRuntimeClockTests: XCTestCase {
    let runID = "synthetic-ab-ee260914-0000-4000-8000-000000009400"
    let fixture = SyntheticABExpected.fixture()
    func workspace() throws -> URL {
        let url = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticABJournal-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }; return url
    }
    func responses(zero: Bool = false) -> [SyntheticABResponse] {
        var r = fixture.responses()+fixture.responses();if zero { for n in r.indices { r[n].delayMS = 0 } };return r
    }
    func execute(clock: ABRuntimeClock,session: ABSessionDouble? = nil,timing: SyntheticABTiming = .fixture,journal: SyntheticABJournal? = nil,transport: SyntheticABTransport? = nil) throws -> SyntheticABCompletion {
        let env = try SyntheticABEnvironment(clock:clock,session:session ?? ABSessionDouble(expiresUTCMS:6000))
        return try SyntheticABRunner(expected:fixture,timing:timing,runID:runID).run(transport:transport ?? SyntheticABTransport(responses()),journal:journal ?? SyntheticABJournal(),environment:env)
    }
    func ioFailure(point:String,cost:Int,code:SyntheticABError,timing:SyntheticABTiming = .fixture,calls:Int,charged:Int) throws {
        let disk = try SyntheticABDiskJournal(workspace:workspace()), clock = ABRuntimeClock(utcMS:1000,monoMS:0), transport = SyntheticABTransport(responses())
        disk.checkpoint = { if $0 == point { try clock.advance(cost) } }
        XCTAssertThrowsError(try execute(clock:clock,timing:timing,journal:SyntheticABJournal(disk:disk),transport:transport)) { XCTAssertEqual($0 as? SyntheticABError,code,point) }
        XCTAssertEqual(transport.calls.count,calls,point)
        let state = try disk.read();XCTAssertEqual(state.httpUsed,charged,point)
        let next = SyntheticABTransport(responses())
        XCTAssertThrowsError(try execute(clock:clock,timing:timing,journal:SyntheticABJournal(disk:disk),transport:next));XCTAssertTrue(next.calls.isEmpty)
    }
    func testSystemUTCAndContinuousClockAreReadWithoutNetwork() throws {
        let clock = ABRuntimeClock(), before = Date().timeIntervalSince1970*1000, a = try clock.sample()
        Thread.sleep(forTimeInterval:0.02);let b = try clock.sample(), after = Date().timeIntervalSince1970*1000
        XCTAssertGreaterThanOrEqual(Double(a.utcMS),before-1);XCTAssertLessThanOrEqual(Double(b.utcMS),after+1)
        XCTAssertGreaterThanOrEqual(b.monoMS-a.monoMS,15);XCTAssertTrue(clock.isSystem)
        XCTAssertThrowsError(try clock.advance(1));XCTAssertThrowsError(try clock.setForTest(utcMS:0,monoMS:0))
    }
    func testManualClockExactBoundariesAndArithmeticAreControlled() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:20);try c.advance(5)
        XCTAssertEqual(try c.sample().utcMS,1005);XCTAssertEqual(try c.sample().monoMS,25)
        XCTAssertThrowsError(try c.advance(-1));try c.setForTest(utcMS:-1,monoMS:0);XCTAssertThrowsError(try c.sample())
        try c.setForTest(utcMS:9_007_199_254_740_991,monoMS:0);XCTAssertThrowsError(try c.advance(1))
    }
    func testClockedSuccessKeepsAllRealAuthorityClosed() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), j = try SyntheticABJournal(), result = try execute(clock:c,journal:j), report = try result.checkedReport()
        XCTAssertEqual(report.http_reserved,14);XCTAssertEqual(report.auth_reserved,2)
        XCTAssertFalse(report.execution_allowed || report.baseline_applied || report.app_binding_created || report.sending_allowed)
        XCTAssertThrowsError(try result.requireApplyInput());XCTAssertEqual(try j.read().events.last?.completedMonoMS,14)
    }
    func testInitializationIOCountsTowardTotalBeforeFirstRequest() throws {
        try ioFailure(point:"committed:initialize",cost:3000,code:.totalTimeout,calls:0,charged:0)
    }
    func testClaimIOCountsTowardTotalWithoutRefund() throws {
        try ioFailure(point:"committed:claim",cost:3000,code:.totalTimeout,calls:0,charged:0)
    }
    func testReservationIOAtDeadlineBlocksSendAndKeepsCharge() throws {
        try ioFailure(point:"committed:reserve:1",cost:100,code:.requestTimeout,calls:0,charged:1)
    }
    func testStartIOAtDeadlineBlocksSendAndKeepsCharge() throws {
        try ioFailure(point:"committed:start:1",cost:100,code:.requestTimeout,calls:0,charged:1)
    }
    func testMetadataAndRawPublicationIOCountTowardRequest() throws {
        for point in ["committed:metadata:1","committed:response:1"] { try ioFailure(point:point,cost:99,code:.requestTimeout,calls:1,charged:1) }
    }
    func testPassDeadlineIncludesResponseJournalWrite() throws {
        var t = SyntheticABTiming.fixture;t.requestMS = 2000
        try ioFailure(point:"committed:response:1",cost:999,code:.passTimeout,timing:t,calls:1,charged:1)
    }
    func testInterpassIncludesFirstBStartIOBeforeAdmission() throws {
        var t = SyntheticABTiming.fixture;t.requestMS = 1000
        try ioFailure(point:"committed:start:8",cost:100,code:.interpassTimeout,timing:t,calls:7,charged:8)
    }
    func testFirstBResponseDurationIsNotInterpassTime() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0);var t = SyntheticABTiming.fixture;t.requestMS = 500
        var r = responses();r[7].delayMS = 150
        XCTAssertNoThrow(try execute(clock:c,timing:t,transport:SyntheticABTransport(r)))
    }
    func testPreApplyAgeIncludesLastResponsePersistence() throws {
        var t = SyntheticABTiming.fixture;t.requestMS = 1000
        try ioFailure(point:"committed:response:14",cost:100,code:.preApplyTimeout,timing:t,calls:14,charged:14)
    }
    func testLocalStartAndFinishPersistenceCannotPublishOverBudget() throws {
        for point in ["committed:local_start","committed:finish"] {
            var t = SyntheticABTiming.fixture;t.preApplyMS = 1000
            try ioFailure(point:point,cost:100,code:.localProbeTimeout,timing:t,calls:14,charged:14)
        }
    }
    func testIOUTCSessionExpiryIsIndependentOfElapsedDeadline() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), session = ABSessionDouble(expiresUTCMS:1050), disk = try SyntheticABDiskJournal(workspace:workspace()), t = SyntheticABTransport(responses())
        disk.checkpoint = { if $0 == "committed:reserve:1" { try c.setForTest(utcMS:1050,monoMS:1) } }
        XCTAssertThrowsError(try execute(clock:c,session:session,journal:SyntheticABJournal(disk:disk),transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.sessionExpired) }
        XCTAssertTrue(t.calls.isEmpty);XCTAssertEqual(try disk.read().httpUsed,1)
    }
    func testIOUTCExecutionExpiryAndBackwardClocksFailClosed() throws {
        for (utc,mono,code) in [(6000,1,SyntheticABError.expired),(999,1,.clockBackward),(1001,-1,.arithmetic)] {
            let c = ABRuntimeClock(utcMS:1000,monoMS:0), s = ABSessionDouble(expiresUTCMS:10000), disk = try SyntheticABDiskJournal(workspace:workspace()), t = SyntheticABTransport(responses())
            disk.checkpoint = { if $0 == "committed:reserve:1" { try c.setForTest(utcMS:utc,monoMS:mono) } }
            XCTAssertThrowsError(try execute(clock:c,session:s,journal:SyntheticABJournal(disk:disk),transport:t)) { XCTAssertEqual($0 as? SyntheticABError,code) };XCTAssertTrue(t.calls.isEmpty)
        }
    }
    func testSessionChangeAndSameIDReplacementDuringIOBlock() throws {
        for sameID in [false,true] {
            let c = ABRuntimeClock(utcMS:1000,monoMS:0), s = ABSessionDouble(expiresUTCMS:6000), disk = try SyntheticABDiskJournal(workspace:workspace()), t = SyntheticABTransport(responses())
            disk.checkpoint = { if $0 == "committed:reserve:1" { try s.replace(id:sameID ? nil : "synthetic-other") } }
            XCTAssertThrowsError(try execute(clock:c,session:s,journal:SyntheticABJournal(disk:disk),transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.sessionChanged) }
            XCTAssertTrue(t.calls.isEmpty);XCTAssertEqual(try disk.read().httpUsed,1)
        }
    }
    func testSessionExpiryExtensionDoesNotRefreshAnActiveRun() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), s = ABSessionDouble(expiresUTCMS:6000), t = SyntheticABTransport(responses()), j = try SyntheticABJournal()
        t.onEvent = { if $0 == "before-delivery" { try s.replace(expiresUTCMS:12000) } }
        XCTAssertThrowsError(try execute(clock:c,session:s,journal:j,transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.sessionChanged) }
        XCTAssertEqual(t.calls.count,1);XCTAssertNil(try j.read().events[0].raw);XCTAssertEqual(try j.read().httpUsed,1)
    }
    func testExpiredSessionAtStartDoesNotClaimJournal() throws {
        let j = try SyntheticABJournal(), t = SyntheticABTransport(responses())
        XCTAssertThrowsError(try execute(clock:ABRuntimeClock(utcMS:1000,monoMS:0),session:ABSessionDouble(expiresUTCMS:1000),journal:j,transport:t))
        XCTAssertEqual(try j.read(),SyntheticABJournalState());XCTAssertTrue(t.calls.isEmpty)
    }
    func testPreCancelledTransportDoesNotCharge() throws {
        let j = try SyntheticABJournal(), t = SyntheticABTransport(responses());t.cancel()
        XCTAssertThrowsError(try execute(clock:ABRuntimeClock(utcMS:1000,monoMS:0),journal:j,transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.cancelled) }
        XCTAssertEqual(try j.read(),SyntheticABJournalState());XCTAssertTrue(t.calls.isEmpty)
    }
    func testCancellationAtAdmissionInflightAndLateDeliveryKeepsCharge() throws {
        for point in ["before-send","in-flight","before-delivery"] {
            let j = try SyntheticABJournal(), t = SyntheticABTransport(responses())
            t.onEvent = { [weak t] in if $0 == point { t?.cancel() } }
            XCTAssertThrowsError(try execute(clock:ABRuntimeClock(utcMS:1000,monoMS:0),journal:j,transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.cancelled) }
            XCTAssertEqual(t.calls.count,point == "before-send" ? 0 : 1);XCTAssertEqual(try j.read().httpUsed,1);XCTAssertNil(try j.read().events[0].raw)
        }
    }
    func testCancellationFromAnotherThreadDiscardsInflightResponse() throws {
        let t = SyntheticABTransport(responses()), j = try SyntheticABJournal()
        t.onEvent = { [weak t] point in
            if point == "in-flight" {
                let done = DispatchSemaphore(value:0)
                DispatchQueue.global().async { t?.cancel();done.signal() }
                XCTAssertEqual(done.wait(timeout:.now()+2),.success)
            }
        }
        XCTAssertThrowsError(try execute(clock:ABRuntimeClock(utcMS:1000,monoMS:0),journal:j,transport:t))
        XCTAssertEqual(t.calls.count,1);XCTAssertNil(try j.read().events[0].raw)
    }
    func testAdmissionRechecksAfterJournalReadBeforeTransport() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), j = try SyntheticABJournal(), t = SyntheticABTransport(responses())
        t.onEvent = { if $0 == "before-send" { try c.advance(100) } }
        XCTAssertThrowsError(try execute(clock:c,journal:j,transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.requestTimeout) }
        XCTAssertTrue(t.calls.isEmpty);XCTAssertEqual(try j.read().httpUsed,1)
    }
    func testLateResponseAfterExpiryOrSessionChangeNeverStoresRaw() throws {
        for changed in [false,true] {
            let c = ABRuntimeClock(utcMS:1000,monoMS:0), s = ABSessionDouble(expiresUTCMS:1100), j = try SyntheticABJournal(), t = SyntheticABTransport(responses())
            t.onEvent = { if $0 == "before-delivery" { if changed { try s.replace() } else { try c.setForTest(utcMS:1100,monoMS:2) } } }
            XCTAssertThrowsError(try execute(clock:c,session:s,journal:j,transport:t)) { XCTAssertEqual($0 as? SyntheticABError,changed ? .sessionChanged : .sessionExpired) }
            XCTAssertNil(try j.read().events[0].raw);XCTAssertEqual(try j.read().httpUsed,1)
        }
    }
    func testCompletionExpiresAndCannotReviveWithReplacementSession() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), s = ABSessionDouble(expiresUTCMS:6000), result = try execute(clock:c,session:s)
        try s.replace(expiresUTCMS:12000);XCTAssertThrowsError(try result.checkedReport())
        XCTAssertThrowsError(try result.requireApplyInput())
    }
    func testPositiveMonotonicRollbackAndRuntimeEffectAreNotOverwritten() throws {
        for effect in [SyntheticABEffect.monoBackward,.replaceSession,.replaceSessionWithSameID] {
            let c = ABRuntimeClock(utcMS:1000,monoMS:200);var r = responses();r[0].effect = effect
            XCTAssertThrowsError(try execute(clock:c,transport:SyntheticABTransport(r))) { XCTAssertEqual($0 as? SyntheticABError,effect == .monoBackward ? .clockBackward : .sessionChanged) }
        }
    }
    func testCancellationDuringFinishAndAfterCompletionCannotPublish() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), disk = try SyntheticABDiskJournal(workspace:workspace()), t = SyntheticABTransport(responses())
        disk.checkpoint = { [weak t] in if $0 == "committed:finish" { t?.cancel() } }
        XCTAssertThrowsError(try execute(clock:c,journal:SyntheticABJournal(disk:disk),transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.cancelled) }
        XCTAssertEqual(try disk.read().httpUsed,14);XCTAssertEqual(try disk.read().status,"finished")
        let later = SyntheticABTransport(responses()), result = try execute(clock:ABRuntimeClock(utcMS:1000,monoMS:0),transport:later)
        later.cancel();XCTAssertThrowsError(try result.checkedReport())
    }
    func testObservedExpiryCannotReviveWhenWallClockReturns() throws {
        let c = ABRuntimeClock(utcMS:1000,monoMS:0), result = try execute(clock:c)
        try c.setForTest(utcMS:6000,monoMS:15);XCTAssertThrowsError(try result.checkedReport())
        try c.setForTest(utcMS:1015,monoMS:16);XCTAssertThrowsError(try result.checkedReport())
    }
    func testRealClockAccountsForActualJournalWaitBeforeSend() throws {
        let c = ABRuntimeClock(), now = try c.sample(), s = ABSessionDouble(expiresUTCMS:now.utcMS+60000)
        let timing = SyntheticABTiming(requestMS:5,passMS:30000,interpassMS:5000,preApplyMS:5000,localApplyMS:5000,totalMS:60000,notBeforeUTCMS:now.utcMS,expiresUTCMS:now.utcMS+60000)
        let d = try SyntheticABDiskJournal(workspace:workspace()), t = SyntheticABTransport(responses(zero:true))
        d.checkpoint = { if $0 == "pending:reserve:1:record-002.json" { Thread.sleep(forTimeInterval:0.02) } }
        XCTAssertThrowsError(try execute(clock:c,session:s,timing:timing,journal:SyntheticABJournal(disk:d),transport:t)) { XCTAssertEqual($0 as? SyntheticABError,.requestTimeout) }
        XCTAssertTrue(t.calls.isEmpty);XCTAssertEqual(try d.read().httpUsed,1);XCTAssertGreaterThanOrEqual(try c.sample().monoMS-now.monoMS,20)
    }
    func testProtectedPreparationCannotRebindSessionOrHideClockRollback() throws {
        for mutation in ["session","utc","mono"] {
            let h = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("RuntimePreparationHome-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:h,withIntermediateDirectories:false);defer { try? FileManager.default.removeItem(at:h) }
            let c = ABRuntimeClock(utcMS:1000,monoMS:200), session = ABSessionDouble(expiresUTCMS:6000), env = try SyntheticABEnvironment(clock:c,session:session)
            let life = BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true)
            let lease = try life.begin(), protection = ProtectedContainerTests.Protection(), t = SyntheticABTransport(responses())
            protection.onCreate = { url in
                if url.lastPathComponent == "container.json.pending" {
                    if mutation == "session" { try session.replace() }
                    else { try c.setForTest(utcMS:mutation == "utc" ? 999 : 1000,monoMS:mutation == "mono" ? 100 : 200) }
                }
            }
            let work = try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:protection.access(lease))
            XCTAssertThrowsError(try work.run(transport:t,environment:env)) { XCTAssertEqual($0 as? SyntheticABError,mutation == "session" ? .sessionChanged : .clockBackward) }
            XCTAssertTrue(t.calls.isEmpty);XCTAssertFalse(FileManager.default.fileExists(atPath:work.container.workspace.appendingPathComponent("execution-journal").path))
        }
    }
    func testProtectedWorkSystemClockSuccessWithSyntheticSessionAndTransport() throws {
        let h = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("RuntimeFakeHome-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:h,withIntermediateDirectories:false);defer { try? FileManager.default.removeItem(at:h) }
        let life = BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true)
        let lease = try life.begin(), protection = ProtectedContainerTests.Protection()
        let work = try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:protection.access(lease))
        let result = try work.runWithSystemClock(), report = try result.checkedReport(), state = try work.inspect()
        XCTAssertEqual(report.http_reserved,14);XCTAssertFalse(report.execution_allowed)
        XCTAssertGreaterThan(try XCTUnwrap(state.context).startedUTCMS,1_700_000_000_000)
        XCTAssertGreaterThan(try XCTUnwrap(state.events.last?.completedMonoMS),try XCTUnwrap(state.context).startedMonoMS)
        XCTAssertThrowsError(try work.runWithSystemClock())
    }
}
