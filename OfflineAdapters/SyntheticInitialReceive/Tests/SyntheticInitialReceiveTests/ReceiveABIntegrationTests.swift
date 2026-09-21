import XCTest
import Foundation
import Darwin
@testable import SyntheticInitialReceive

final class ReceiveABStub: URLProtocol {
    static let lock = NSLock()
    static var values = SyntheticABExpected.fixture().responses()+SyntheticABExpected.fixture().responses()
    static var requests:[URLRequest] = []
    static var hold:Int?, action:((Int)->Void)?
    static func reset(_ responses:[SyntheticABResponse]? = nil,hold:Int? = nil,action:((Int)->Void)? = nil) {
        lock.lock(); defer { lock.unlock() };values = responses ?? SyntheticABExpected.fixture().responses()+SyntheticABExpected.fixture().responses();requests = [];self.hold = hold;self.action = action
    }
    static var count:Int { lock.lock();defer { lock.unlock() };return requests.count }
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "receive-boundary.invalid" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let index = Self.requests.count;Self.requests.append(request)
        let value = index < Self.values.count ? Self.values[index] : SyntheticABResponse(raw:Data(),status:500)
        let hold = Self.hold == index, action = Self.action;Self.lock.unlock()
        action?(index);if hold { return }
        var headers = ["Content-Length":String(value.raw.count)]
        if let range = value.contentRange { headers["Content-Range"] = range }
        let response = HTTPURLResponse(url:request.url!,statusCode:value.status,httpVersion:"HTTP/1.1",headerFields:headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:value.raw);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ReceiveABIntegrationTests:XCTestCase {
    let fm = FileManager.default
    var homes:[URL] = []
    let account = UUID(uuidString:SyntheticABExpected.fixture().account)!
    var timing:SyntheticABTiming { .init(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:1000,localApplyMS:1000,totalMS:60000,notBeforeUTCMS:1000,expiresUTCMS:61000) }
    func cached(_ token:String = "synthetic.integration.token",expiry:Int = 61000)->ReceiveCachedSession { .init(account:account,accessToken:token,expiresUTCMS:expiry) }
    func owner() throws -> ReceiveAuthOwner { let o = ReceiveAuthOwner();try o.replaceCachedSession(cached());return o }
    func home() throws -> URL {
        let h = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("ReceiveABIntegration-"+UUID().uuidString.lowercased())
        try fm.createDirectory(at:h,withIntermediateDirectories:false);homes.append(h);return h
    }
    func life()->BoundaryLifecycle { let l = BoundaryLifecycle();l.update(active:true,protectedDataAvailable:true);return l }
    func work(_ h:URL,_ o:ReceiveAuthOwner,_ l:BoundaryLifecycle,clock:ABRuntimeClock = ABRuntimeClock(utcMS:1000,monoMS:0),timing:SyntheticABTiming? = nil,protection:PhysicalStorageAccess = .init()) throws -> ReceiveABCoordinator {
        try .init(syntheticHome:h,lease:l.begin(),protection:protection,owner:o,clock:clock,timing:timing ?? self.timing,protocolClass:ReceiveABStub.self)
    }
    func inspect(_ h:URL,_ l:BoundaryLifecycle) throws -> SyntheticABJournalState {
        try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:l.begin(),protection:.init()).inspect()
    }
    func tree(_ h:URL) throws -> [String:String] {
        let e = fm.enumerator(at:h,includingPropertiesForKeys:[.isRegularFileKey])!;var files:[String:String] = [:]
        for case let p as URL in e where try p.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true { files[p.path] = byteHash(try Data(contentsOf:p)) };return files
    }
    func blocked(_ w:ReceiveABCoordinator,_ expected:SyntheticABError? = nil,file:StaticString = #filePath,line:UInt = #line) async {
        do { _ = try await w.run();XCTFail("unexpected success",file:file,line:line) }
        catch { if let expected { XCTAssertEqual(error as? SyntheticABError,expected,file:file,line:line) } }
    }
    override func setUp() { super.setUp();ReceiveABStub.reset() }
    override func tearDownWithError() throws { for h in homes { try fm.removeItem(at:h) };homes = [];ReceiveABStub.reset() }

    func testOwnerStartsEmptyAndPendingMutationBlocksCachedRead() throws {
        let o = ReceiveAuthOwner(),clock = ABRuntimeClock(utcMS:1000,monoMS:0)
        XCTAssertThrowsError(try o.source.capture(account:account,clock:clock))
        let change = try o.beginChange();XCTAssertThrowsError(try o.source.capture(account:account,clock:clock))
        try o.finish(change,cachedSession:cached());_ = try o.source.capture(account:account,clock:clock)
    }
    func testSameTokenABAAndBeginBeforeAsyncCompletionRevokeOldLease() throws {
        let o = try owner(), clock = ABRuntimeClock(utcMS:1000,monoMS:0),lease = try o.source.capture(account:account,clock:clock)
        let change = try o.beginChange();XCTAssertThrowsError(try lease.check());try o.finish(change,cachedSession:cached())
        XCTAssertThrowsError(try lease.check());_ = try o.source.capture(account:account,clock:clock)
    }
    func testForeignDuplicateAndStaleMutationTicketsCannotOverwriteNewOwner() throws {
        let o = try owner(),other = try owner(),first = try o.beginChange(),second = try o.beginChange()
        XCTAssertThrowsError(try other.finish(second,cachedSession:cached()))
        try o.finish(second,cachedSession:cached("synthetic.new.token"))
        XCTAssertThrowsError(try o.finish(first,cachedSession:nil));XCTAssertThrowsError(try o.finish(second,cachedSession:nil))
        let lease = try o.source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0));XCTAssertEqual(try lease.authorization(),"Bearer synthetic.new.token")
    }
    func testAsyncOwnerFailureLeavesNoCachedSession() async throws {
        let o = try owner()
        do { try await o.withChange { throw ReceiveConnectionError.authentication };XCTFail() } catch {}
        XCTAssertThrowsError(try o.source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0)))
    }
    func testAsyncOwnerLateCompletionCannotEraseNewerSession() async throws {
        let o = try owner()
        do { try await o.withChange { try o.replaceCachedSession(self.cached("synthetic.new.token"));return self.cached() };XCTFail() } catch {}
        XCTAssertEqual(try o.source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0)).authorization(),"Bearer synthetic.new.token")
    }
    func testCancelledOwnerOperationCannotPublishLateSession() async throws {
        let o = try owner(),entered = expectation(description:"entered"),gate = DispatchSemaphore(value:0)
        func waitForDouble() { gate.wait() }
        let t = Task.detached { try await o.withChange { entered.fulfill();waitForDouble();return self.cached() } }
        await fulfillment(of:[entered],timeout:2);t.cancel();gate.signal()
        do { try await t.value;XCTFail() } catch {}
        XCTAssertThrowsError(try o.source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0)))
    }
    func testConstructionPassiveAndMissingSessionCreatesNoJournal() async throws {
        let h = try home(),w = try work(h,ReceiveAuthOwner(),life())
        XCTAssertTrue(try tree(h).isEmpty);await blocked(w);XCTAssertTrue(try tree(h).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testFourteenNativeRequestsValidateAndPersistOnSingleJournalThread() async throws {
        let h = try home(),o = try owner(),l = life(),w = try work(h,o,l)
        var threads = Set<UInt32>();w.checkpoint = { _ in threads.insert(pthread_mach_thread_np(pthread_self())) }
        let result = try await w.run(), report = try result.checkedReport(),state = try inspect(h,l)
        XCTAssertEqual(threads.count,1);XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(state.status,"finished")
        XCTAssertEqual(state.httpUsed,14);XCTAssertEqual(state.authUsed,2);XCTAssertEqual(state.events.count,15)
        XCTAssertEqual(state.events.compactMap(\.raw).count,14);XCTAssertFalse(report.baseline_applied || report.execution_allowed || report.baseline_ready)
        XCTAssertThrowsError(try result.requireApplyInput())
        let bytes = String(decoding:try canonical(state),as:UTF8.self);XCTAssertFalse(bytes.contains("synthetic.integration.token"));XCTAssertFalse(bytes.contains("Bearer"))
    }
    func testCompletedCoordinatorAndNewCoordinatorCannotRepeatOrAlterDisk() async throws {
        let h = try home(),o = try owner(),l = life(),w = try work(h,o,l);_ = try await w.run();let before = try tree(h)
        await blocked(w,.runReuse);await blocked(try work(h,o,l),.runReuse);XCTAssertEqual(try tree(h),before);XCTAssertEqual(ReceiveABStub.count,14)
    }
    func test401PreservesOneChargeAndBlocksRestart() async throws {
        let h = try home(),o = try owner(),l = life(),w = try work(h,o,l);var r = SyntheticABExpected.fixture().responses();r[0].status = 401;ReceiveABStub.reset(r)
        await blocked(w,.httpStatus);let s = try inspect(h,l);XCTAssertEqual(s.httpUsed,1);XCTAssertEqual(s.authUsed,1);XCTAssertNil(s.events[0].raw)
        XCTAssertEqual(s.status,"stopped");let before = try tree(h);await blocked(try work(h,o,l));XCTAssertEqual(try tree(h),before);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testMalformedAuthBodyCannotAdvanceToSecondRequest() async throws {
        let h = try home(),l = life();var r = SyntheticABExpected.fixture().responses();r[0].raw = Data("{}".utf8);ReceiveABStub.reset(r)
        await blocked(try work(h,owner(),l));let s = try inspect(h,l);XCTAssertEqual(ReceiveABStub.count,1);XCTAssertNotNil(s.events[0].receivedMonoMS);XCTAssertNil(s.events[0].raw)
    }
    func testMissingCountStopsBeforeNextQuery() async throws {
        let h = try home(),l = life();var r = SyntheticABExpected.fixture().responses();r[2].contentRange = nil;ReceiveABStub.reset(r)
        await blocked(try work(h,owner(),l),.count);XCTAssertEqual(ReceiveABStub.count,3);XCTAssertEqual(try inspect(h,l).httpUsed,3)
    }
    func testABDifferencePreventsLocalCompletion() async throws {
        let h = try home(),l = life();var r = SyntheticABExpected.fixture().responses()+SyntheticABExpected.fixture().responses()
        var rows = try WindowsJSON.decode(r[9].raw).array(),row = try rows[0].object();row["extra_marker"] = .string("changed");rows[0] = .object(row);r[9].raw = WindowsJSON.array(rows).encoded(lf:true);ReceiveABStub.reset(r)
        await blocked(try work(h,owner(),l),.abChanged);let s = try inspect(h,l);XCTAssertEqual(s.httpUsed,14);XCTAssertEqual(s.events.count,14);XCTAssertEqual(s.status,"stopped")
    }
    func testBadTargetBodyStopsBeforeBaselinePromotion() async throws {
        let h = try home(),l = life();var r = SyntheticABExpected.fixture().responses();var rows = try WindowsJSON.decode(r[4].raw).array(),row = try rows[0].object();row["content"] = .string("wrong");rows[0] = .object(row);r[4].raw = WindowsJSON.array(rows).encoded(lf:true);ReceiveABStub.reset(r)
        await blocked(try work(h,owner(),l),.targetChanged);XCTAssertEqual(ReceiveABStub.count,7);XCTAssertEqual(try inspect(h,l).status,"stopped")
    }
    func testCancelBeforeRunLeavesFilesystemUntouched() async throws {
        let h = try home(),w = try work(h,owner(),life());w.cancel();await blocked(w,.cancelled);XCTAssertTrue(try tree(h).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testTaskCancelWhileHTTPStallsReturnsAndKeepsReservation() async throws {
        let h = try home(),l = life(),w = try work(h,owner(),l),started = expectation(description:"started")
        ReceiveABStub.reset(hold:0,action:{ _ in started.fulfill() });let t = Task { try await w.run() }
        await fulfillment(of:[started],timeout:3);t.cancel();do { _ = try await t.value;XCTFail() } catch {}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try inspect(h,l).httpUsed,1)
    }
    func testSameTokenOwnerChangeDuringStalledHTTPCancelsAndPreserves() async throws {
        let h = try home(),l = life(),o = try owner(),w = try work(h,o,l)
        ReceiveABStub.reset(hold:0,action:{ _ in try! o.replaceCachedSession(self.cached()) });await blocked(w)
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try inspect(h,l).httpUsed,1)
    }
    func testLifecycleRevokeAndQuickRestoreCannotReviveInflightRun() async throws {
        let h = try home(),l = life(),o = try owner(),w = try work(h,o,l)
        ReceiveABStub.reset(hold:0,action:{ _ in l.update(active:false,protectedDataAvailable:true);l.update(active:true,protectedDataAvailable:true) });await blocked(w)
        let before = try tree(h);await blocked(try work(h,o,l));XCTAssertEqual(try tree(h),before);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testReservationAndStartIOTimeAreChargedBeforeNativeSend() async throws {
        for point in ["committed:reserve:1","committed:start:1"] {
            ReceiveABStub.reset();let h = try home(),l = life(),clock = ABRuntimeClock(utcMS:1000,monoMS:0),w = try work(h,owner(),l,clock:clock)
            w.checkpoint = { if $0 == point { try clock.advance(1000) } };await blocked(w,.requestTimeout)
            XCTAssertEqual(ReceiveABStub.count,0);XCTAssertEqual(try inspect(h,l).httpUsed,1)
        }
    }
    func testResponsePersistenceTimeCanBlockNextSend() async throws {
        let h = try home(),l = life(),clock = ABRuntimeClock(utcMS:1000,monoMS:0),w = try work(h,owner(),l,clock:clock)
        w.checkpoint = { if $0 == "committed:response:1" { try clock.advance(1000) } };await blocked(w,.requestTimeout)
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertNotNil(try inspect(h,l).events[0].raw)
    }
    func testPassBudgetCancelsStalledRequestBeforeItsRequestBudget() async throws {
        let h = try home(),l = life(),clock = ABRuntimeClock(utcMS:1000,monoMS:0);var policy = timing;policy.passMS = 500;policy.requestMS = 2000
        let w = try work(h,owner(),l,clock:clock,timing:policy);ReceiveABStub.reset(hold:0,action:{ _ in try! clock.advance(500) })
        await blocked(w,.passTimeout);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testTotalBudgetIncludesContainerInitialization() async throws {
        let h = try home(),l = life(),clock = ABRuntimeClock(utcMS:1000,monoMS:0);var policy = timing;policy.totalMS = 500
        let w = try work(h,owner(),l,clock:clock,timing:policy);w.checkpoint = { if $0 == "created-root" { try clock.advance(500) } }
        await blocked(w,.totalTimeout);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testSessionChangeDuringStartPreventsAnyHTTP() async throws {
        let h = try home(),l = life(),o = try owner(),w = try work(h,o,l)
        w.checkpoint = { if $0 == "committed:start:1" { _ = try o.beginChange() } };await blocked(w)
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertEqual(try inspect(h,l).httpUsed,1)
    }
    func testPendingJournalFailurePreservesEvidenceAndBlocksNewCoordinator() async throws {
        let h = try home(),l = life(),o = try owner(),w = try work(h,o,l)
        w.checkpoint = { if $0 == "pending:start:1:record-003.json" { throw SyntheticABError.journalWrite } };await blocked(w)
        let before = try tree(h);XCTAssertTrue(before.keys.contains { $0.hasSuffix("record-003.json.pending") });await blocked(try work(h,o,l));XCTAssertEqual(try tree(h),before);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testWholeRunFileLockRemainsHeldDuringHTTPAwait() async throws {
        let h = try home(),l = life(),w = try work(h,owner(),l),entered = expectation(description:"entered")
        ReceiveABStub.reset(hold:0,action:{ _ in entered.fulfill() });let t = Task { try await w.run() }
        await fulfillment(of:[entered],timeout:3)
        let path = h.appendingPathComponent("Library/Application Support/WriterPadReceiveBoundary-v1/execution-journal/lock"),fd = open(path.path,O_RDWR|O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd,0);if fd >= 0 { XCTAssertNotEqual(flock(fd,LOCK_EX|LOCK_NB),0);close(fd) }
        w.cancel();do { _ = try await t.value;XCTFail() } catch {}
        let reopened = open(path.path,O_RDWR|O_NOFOLLOW);XCTAssertGreaterThanOrEqual(reopened,0);if reopened >= 0 { XCTAssertEqual(flock(reopened,LOCK_EX|LOCK_NB),0);_ = flock(reopened,LOCK_UN);close(reopened) }
    }
    func testCompletionRevokedByOwnerChangeAndDiskDamage() async throws {
        let h = try home(),l = life(),o = try owner(),result = try await work(h,o,l).run()
        try o.replaceCachedSession(cached());XCTAssertThrowsError(try result.checkedReport())
        ReceiveABStub.reset();let h2 = try home(),l2 = life(),result2 = try await work(h2,owner(),l2).run()
        let path = h2.appendingPathComponent("Library/Application Support/WriterPadReceiveBoundary-v1/execution-journal/record-059.json");try Data("{}".utf8).write(to:path)
        XCTAssertThrowsError(try result2.checkedReport())
    }
    func testOwnerChangeAtFinishCannotPublishSuccess() async throws {
        let h = try home(),l = life(),o = try owner(),w = try work(h,o,l)
        w.checkpoint = { if $0 == "committed:finish" { try o.replaceCachedSession(self.cached()) } };await blocked(w);XCTAssertEqual(ReceiveABStub.count,14)
        let before = try tree(h);await blocked(try work(h,o,l));XCTAssertEqual(try tree(h),before)
    }
}
