import Foundation
import XCTest
@testable import SyntheticInitialReceive

final class ReceiveStubProtocol:URLProtocol {
    struct Plan { var status = 200;var headers:[String:String] = [:];var chunks = [Data("synthetic-response".utf8)];var hold = false;var action:(()->Void)? }
    static let lock = NSLock()
    static var plan = Plan(), requests:[URLRequest] = [], stops = 0
    static func configure(_ p:Plan = .init()) { lock.lock();plan = p;requests = [];stops = 0;lock.unlock() }
    static func captured() -> [URLRequest] { lock.lock();defer { lock.unlock() };return requests }
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "receive-boundary.invalid" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        Self.lock.lock();let plan = Self.plan;Self.requests.append(request);Self.lock.unlock()
        plan.action?();if plan.hold { return }
        let response = HTTPURLResponse(url:request.url!,statusCode:plan.status,httpVersion:"HTTP/1.1",headerFields:plan.headers)!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        for data in plan.chunks { client?.urlProtocol(self,didLoad:data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock();Self.stops += 1;Self.lock.unlock() }
}
final class ReceiveNeverHandlesProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { false }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
}
final class ReceiveConnectionTests:XCTestCase {
    final class Owner {
        let lock = NSLock()
        var value:ReceiveCachedSession?, epoch = 0, reads = 0
        init() { value = ReceiveCachedSession(account:UUID(uuidString:SyntheticABExpected.fixture().account)!,accessToken:"synthetic.access.token",expiresUTCMS:6000) }
        func read()->ReceiveCachedSession? { lock.lock();defer { lock.unlock() };reads += 1;return value }
        func revision()->Int { lock.lock();defer { lock.unlock() };return epoch }
        func change(token:String = "synthetic.access.token",expiry:Int = 6000,bump:Bool = true,missing:Bool = false) {
            lock.lock();defer { lock.unlock() };if bump { epoch += 1 }
            value = missing ? nil : ReceiveCachedSession(account:UUID(uuidString:SyntheticABExpected.fixture().account)!,accessToken:token,expiresUTCMS:expiry)
        }
        var source:ReceiveSessionSource { .init(readCached:read,ownerEpoch:revision) }
    }
    let account = UUID(uuidString:SyntheticABExpected.fixture().account)!, project = UUID(uuidString:SyntheticABExpected.fixture().project)!
    override func setUp() { ReceiveStubProtocol.configure() }
    func target(_ url:String = "https://receive-boundary.invalid") throws -> ReceiveHTTPTarget { try .init(origin:URL(string:url)!,account:account,project:project,publishableKey:"sb_publishable_offline_fixture") }
    func connection(_ owner:Owner,_ clock:ABRuntimeClock = ABRuntimeClock(utcMS:1000,monoMS:0),check:@escaping () throws -> Void = {}) throws -> ReceiveHTTPConnection { try .init(offlineTarget:target(),source:owner.source,clock:clock,protocolClass:ReceiveStubProtocol.self,leaseCheck:check) }
    func fail(_ connection:ReceiveHTTPConnection,_ expected:ReceiveConnectionError,ordinal:Int = 0,clock:ABRuntimeClock? = nil,maxBytes:Int = 4*1024*1024,reserve:@escaping () throws -> Void = {},file:StaticString = #filePath,line:UInt = #line) async {
        do { _ = try await connection.send(ordinal:ordinal,timeoutMS:1000,expiresUTCMS:5000,maxBytes:maxBytes,reserveAndStart:reserve);XCTFail("unexpected success",file:file,line:line) }
        catch { XCTAssertEqual(error as? ReceiveConnectionError,expected,file:file,line:line) }
    }
    func testSourceConstructionNeverReadsSessionAndSecretsAreRedacted() throws {
        let owner = Owner(), source = owner.source;XCTAssertEqual(owner.reads,0)
        let lease = try source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0))
        XCTAssertFalse(String(reflecting:lease).contains("synthetic.access.token"));XCTAssertEqual(Mirror(reflecting:lease).children.count,0)
        let session = try XCTUnwrap(owner.read());XCTAssertFalse(String(reflecting:session).contains("synthetic.access.token"));XCTAssertEqual(Mirror(reflecting:session).children.count,0)
    }
    func testLiveEntryStaysClosedBeforeSessionReservationOrURLSession() async throws {
        let owner = Owner(), c = ReceiveHTTPConnection(closedLiveTarget:try target("https://example.com"),source:owner.source,clock:ABRuntimeClock(),leaseCheck:{})
        var reserved = 0;await fail(c,.closed,reserve:{reserved += 1});XCTAssertEqual(reserved,0);XCTAssertEqual(owner.reads,0);XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testRejectsEndpointCredentialsQueriesAndLegacyOrSecretKeys() throws {
        for url in ["http://example.com","https://user:pass@example.com","https://example.com:443","https://example.com/path","https://example.com?x=1","https://example.com#fragment"] { XCTAssertThrowsError(try target(url)) }
        for key in ["service_role","sb_secret_fake","legacy.anon.jwt","sb_publishable_bad\r\nX:1"] { XCTAssertThrowsError(try ReceiveHTTPTarget(origin:URL(string:"https://receive-boundary.invalid")!,account:account,project:project,publishableKey:key)) }
        XCTAssertThrowsError(try ReceiveHTTPConnection(offlineTarget:target("https://example.com"),source:Owner().source,clock:ABRuntimeClock(),protocolClass:ReceiveStubProtocol.self))
    }
    func testNativeURLSessionReturnsBoundedBytesAndCorrectHeaders() async throws {
        let c = try connection(Owner());var reservations = 0
        let response = try await c.send(ordinal:0,timeoutMS:1000,expiresUTCMS:5000,reserveAndStart:{reservations += 1})
        XCTAssertFalse(response.baselineReady || response.baselineApplied || response.independentlyVerified);XCTAssertEqual(response.bytes,Data("synthetic-response".utf8));XCTAssertEqual(response.status,200);XCTAssertEqual(reservations,1)
        let request = try XCTUnwrap(ReceiveStubProtocol.captured().first)
        XCTAssertEqual(request.url?.path,"/auth/v1/user");XCTAssertEqual(request.httpMethod,"GET")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer synthetic.access.token")
        XCTAssertEqual(request.value(forHTTPHeaderField:"apikey"),"sb_publishable_offline_fixture")
        XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
    }
    func testFourteenAllowlistedRequestsAndNoFifteenthOrReplay() async throws {
        let c = try connection(Owner());var count = 0
        for i in 0..<14 { _ = try await c.send(ordinal:i,timeoutMS:1000,expiresUTCMS:5000,reserveAndStart:{count += 1}) }
        let requests = ReceiveStubProtocol.captured();XCTAssertEqual(requests.count,14);XCTAssertEqual(count,14)
        XCTAssertEqual(requests.filter {$0.url?.path == "/auth/v1/user"}.count,2)
        XCTAssertEqual(requests.filter {$0.httpMethod == "POST"}.count,2)
        for n in [2,3,4,5,6,9,10,11,12,13] {
            let items = URLComponents(url:requests[n].url!,resolvingAgainstBaseURL:false)!.queryItems!
            XCTAssertEqual(Dictionary(uniqueKeysWithValues:items.map {($0.name,$0.value!)}),["project_id":"eq."+project.uuidString.lowercased(),"select":"*","limit":"10000"])
            XCTAssertEqual(requests[n].value(forHTTPHeaderField:"Prefer"),"count=exact")
        }
        await fail(c,.reused,ordinal:14);await fail(c,.reused,ordinal:0);XCTAssertEqual(ReceiveStubProtocol.captured().count,14)
    }
    func testHandshakeBodyMatchesContractAndProject() throws {
        let r = try target().request(ordinal:1,authorization:"Bearer synthetic.access.token",timeoutMS:1000)
        let json = try WindowsJSON.decode(XCTUnwrap(r.httpBody))
        XCTAssertEqual(try json.object()["p_project_id"],.string(project.uuidString.lowercased()))
        XCTAssertEqual(try json.object()["p_contract_sha256"],.string(WindowsHandoffReader.contractSHA))
        for n in [-1,14] { XCTAssertThrowsError(try target().request(ordinal:n,authorization:"x",timeoutMS:1000)) }
    }
    func testMissingExpiredWrongAccountOrInvalidTokenBlocksBeforeReservation() async throws {
        for variant in ["missing","expired","account","token"] {
            let owner = Owner();var count = 0
            if variant == "missing" {owner.change(missing:true)}
            if variant == "expired" {owner.change(expiry:1000)}
            if variant == "account" {owner.value = .init(account:UUID(),accessToken:"synthetic.token",expiresUTCMS:6000)}
            if variant == "token" {owner.change(token:"bad\r\nInjected: yes")}
            let expected:ReceiveConnectionError = variant == "missing" ? .missingSession : variant == "expired" ? .expired : variant == "account" ? .changedSession : .invalidCredential
            await fail(try connection(owner),expected,reserve:{count += 1});XCTAssertEqual(count,0)
        }
        XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testEpochChangesDuringSnapshotAreRejected() throws {
        let owner = Owner(), source = ReceiveSessionSource(readCached:{let v = owner.read();owner.change();return v},ownerEpoch:owner.revision)
        XCTAssertThrowsError(try source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0)))
    }
    func testSessionLeaseRejectsTokenChangeEpochABAAndExpiryExtension() throws {
        for kind in ["token","epoch","expiry","logout"] {
            let o = Owner(), lease = try o.source.capture(account:account,clock:ABRuntimeClock(utcMS:1000,monoMS:0))
            o.change(token:kind == "token" ? "synthetic.new.token" : "synthetic.access.token",expiry:kind == "expiry" ? 12000 : 6000,bump:kind != "token",missing:kind == "logout")
            XCTAssertThrowsError(try lease.authorization());o.change();XCTAssertThrowsError(try lease.check())
        }
    }
    func testReservationFailureStartsNoURLSessionAndLatches() async throws {
        let c = try connection(Owner());await fail(c,.reservation,reserve:{throw NSError(domain:"do-not-export",code:1)})
        await fail(c,.reservation);XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testIOBudgetAndSessionChangeAfterPrechargeBlockBeforeSend() async throws {
        for change in [false,true] {
            let owner = Owner(), clock = ABRuntimeClock(utcMS:1000,monoMS:0), c = try connection(owner,clock);var reserved = 0
            await fail(c,change ? .changedSession : .timeout,reserve:{reserved += 1;if change {owner.change()} else {try clock.advance(1000)}})
            XCTAssertEqual(reserved,1);XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
        }
    }
    func test401NeverRefreshesRetriesOrExportsBody() async throws {
        var p = ReceiveStubProtocol.Plan();p.status = 401;p.chunks = [Data("private-error-fixture".utf8)];ReceiveStubProtocol.configure(p)
        let owner = Owner(), c = try connection(owner);await fail(c,.authentication);await fail(c,.authentication,ordinal:1)
        XCTAssertEqual(ReceiveStubProtocol.captured().count,1);XCTAssertEqual(owner.revision(),0)
    }
    func testRedirectAndServerErrorsDoNotFollowOrRetry() async throws {
        for status in [301,302,307,308,429,500] {
            var p = ReceiveStubProtocol.Plan();p.status = status;p.headers = ["Location":"https://example.com/secret"];ReceiveStubProtocol.configure(p)
            await fail(try connection(Owner()),status < 400 ? .redirect : .status);XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
        }
    }
    func testAdvertisedAndStreamingLimitsRejectBeforeGrowingPastCap() async throws {
        var p = ReceiveStubProtocol.Plan();p.headers = ["Content-Length":"9999"];ReceiveStubProtocol.configure(p)
        await fail(try connection(Owner()),.tooLarge,maxBytes:16)
        p.headers = [:];p.chunks = [Data(repeating:1,count:8),Data(repeating:2,count:9)];ReceiveStubProtocol.configure(p)
        await fail(try connection(Owner()),.tooLarge,maxBytes:16)
    }
    func testTruncationAndContentEncodingAreNotSilentlyAccepted() async throws {
        var p = ReceiveStubProtocol.Plan();p.headers = ["Content-Length":"99"];p.chunks = [Data("short".utf8)];ReceiveStubProtocol.configure(p)
        await fail(try connection(Owner()),.response)
        p.headers = ["Content-Encoding":"gzip"];ReceiveStubProtocol.configure(p);await fail(try connection(Owner()),.response)
    }
    func test206PreservesContentRangeWithoutPromotingCountOrBodySemantics() async throws {
        var p = ReceiveStubProtocol.Plan();p.status = 206;p.headers = ["Content-Range":"0-0/1","Content-Length":"2"];p.chunks = [Data("[]".utf8)];ReceiveStubProtocol.configure(p)
        let r = try await connection(Owner()).send(ordinal:0,timeoutMS:1000,expiresUTCMS:5000,reserveAndStart:{})
        XCTAssertEqual(r.status,206);XCTAssertEqual(r.contentRange,"0-0/1");XCTAssertEqual(r.bytes,Data("[]".utf8))
    }
    func testUnhandledStubFallsBackToNetworkDeny() async throws {
        let c = try ReceiveHTTPConnection(offlineTarget:target(),source:Owner().source,clock:ABRuntimeClock(utcMS:1000,monoMS:0),protocolClass:ReceiveNeverHandlesProtocol.self)
        await fail(c,.transport);XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testExplicitCancelBeforeAndAfterReservationPreventsSend() async throws {
        let c = try connection(Owner());c.cancel();var count = 0;await fail(c,.cancelled,reserve:{count += 1});XCTAssertEqual(count,0)
        let other = try connection(Owner());await fail(other,.cancelled,reserve:{count += 1;other.cancel()});XCTAssertEqual(count,1);XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testInflightCancellationCancelsNativeDataTask() async throws {
        let c = try connection(Owner());var p = ReceiveStubProtocol.Plan();p.hold = true;p.action = {c.cancel()};ReceiveStubProtocol.configure(p)
        await fail(c,.cancelled);XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
    }
    func testTaskCancellationWithoutDataCallbackReleasesAwaiter() async throws {
        let c = try connection(Owner()), started = expectation(description:"native task started")
        var p = ReceiveStubProtocol.Plan();p.hold = true;p.action = {started.fulfill()};ReceiveStubProtocol.configure(p)
        let task = Task {try await c.send(ordinal:0,timeoutMS:1000,expiresUTCMS:5000,reserveAndStart:{})}
        await fulfillment(of:[started],timeout:2);task.cancel()
        do {_ = try await task.value;XCTFail("cancel accepted success")}catch {XCTAssertEqual(error as? ReceiveConnectionError,.cancelled)}
    }
    func testPollingCancelsStalledTaskOnSessionChangeExpiryAndClockBack() async throws {
        for kind in ["session","expiry","clock","deadline"] {
            let owner = Owner(), clock = ABRuntimeClock(utcMS:1000,monoMS:0), c = try connection(owner,clock)
            var p = ReceiveStubProtocol.Plan();p.hold = true;p.action = {
                if kind == "session" {owner.change()} else if kind == "expiry" {try? clock.setForTest(utcMS:6000,monoMS:1)} else if kind == "clock" {try? clock.setForTest(utcMS:999,monoMS:1)} else {try? clock.advance(1000)}
            };ReceiveStubProtocol.configure(p)
            await fail(c,kind == "session" ? .changedSession : kind == "expiry" ? .expired : kind == "clock" ? .clock : .timeout)
            XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
        }
    }
    func testLateDataAfterSessionChangeNeverReturnsSuccess() async throws {
        let owner = Owner();var p = ReceiveStubProtocol.Plan();p.action = {owner.change()};ReceiveStubProtocol.configure(p)
        await fail(try connection(owner),.changedSession)
    }
    func testConcurrentSecondCallCannotReuseSlot() async throws {
        let c = try connection(Owner()), started = expectation(description:"started")
        var p = ReceiveStubProtocol.Plan();p.hold = true;p.action = {started.fulfill()};ReceiveStubProtocol.configure(p)
        let task = Task {try await c.send(ordinal:0,timeoutMS:1000,expiresUTCMS:5000,reserveAndStart:{})}
        await fulfillment(of:[started],timeout:2);await fail(c,.busy);c.cancel();_ = try? await task.value
        XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
    }
    func testRealClockDeadlineCancelsStalledURLSession() async throws {
        let owner = Owner(), clock = ABRuntimeClock(), now = try clock.sample();owner.change(expiry:now.utcMS+10000)
        let c = try connection(owner,clock);var p = ReceiveStubProtocol.Plan();p.hold = true;ReceiveStubProtocol.configure(p)
        do {_ = try await c.send(ordinal:0,timeoutMS:30,expiresUTCMS:now.utcMS+10000,reserveAndStart:{});XCTFail("stalled task succeeded")}
        catch {XCTAssertEqual(error as? ReceiveConnectionError,.timeout)}
        XCTAssertLessThan(try clock.sample().monoMS-now.monoMS,3000)
    }
    func testNativeRedirectDelegateRejectsReplacementRequest() throws {
        let op = ReceiveHTTPOperation(clock:ABRuntimeClock(utcMS:1000,monoMS:0),deadline:1000,expires:5000,maxBytes:32,check:{})
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReceiveNetworkDenyProtocol.self]
        let session = URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let url = URL(string:"https://receive-boundary.invalid/auth/v1/user")!, task = session.dataTask(with:url)
        let redirect = HTTPURLResponse(url:url,statusCode:302,httpVersion:nil,headerFields:["Location":"https://example.com"])!
        var called = false
        op.urlSession(session,task:task,willPerformHTTPRedirection:redirect,newRequest:URLRequest(url:URL(string:"https://example.com")!)) { request in called = true;XCTAssertNil(request) }
        XCTAssertTrue(called);XCTAssertThrowsError(try op.checkNow()) {XCTAssertEqual($0 as? ReceiveConnectionError,.redirect)}
        XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    final class ChallengeSender:NSObject,URLAuthenticationChallengeSender {
        func use(_ credential:URLCredential,for challenge:URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge:URLAuthenticationChallenge) {}
        func cancel(_ challenge:URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge:URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge:URLAuthenticationChallenge) {}
    }
    func testNativeCredentialChallengeCannotRetryWithStoredCredentials() throws {
        let op = ReceiveHTTPOperation(clock:ABRuntimeClock(utcMS:1000,monoMS:0),deadline:1000,expires:5000,maxBytes:32,check:{})
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ReceiveNetworkDenyProtocol.self]
        let session = URLSession(configuration:config);defer {session.invalidateAndCancel()}
        let task = session.dataTask(with:URL(string:"https://receive-boundary.invalid")!)
        let space = URLProtectionSpace(host:"receive-boundary.invalid",port:443,protocol:"https",realm:nil,authenticationMethod:NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace:space,proposedCredential:nil,previousFailureCount:0,failureResponse:nil,error:nil,sender:ChallengeSender())
        var called = false
        op.urlSession(session,task:task,didReceive:challenge) { disposition,credential in called = true;XCTAssertEqual(disposition,.cancelAuthenticationChallenge);XCTAssertNil(credential) }
        XCTAssertTrue(called);XCTAssertThrowsError(try op.checkNow()) {XCTAssertEqual($0 as? ReceiveConnectionError,.authentication)}
        XCTAssertTrue(ReceiveStubProtocol.captured().isEmpty)
    }
    func testNativeTransportFailureRetainsActualDiskPrecharge() async throws {
        let ws = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticABJournal-"+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:ws,withIntermediateDirectories:false);defer {try? FileManager.default.removeItem(at:ws)}
        let disk = try SyntheticABDiskJournal(workspace:ws), journal = try SyntheticABJournal(disk:disk), fixture = SyntheticABExpected.fixture()
        let runner = try SyntheticABRunner(expected:fixture,timing:.fixture,runID:"synthetic-ab-ee260915-0000-4000-8000-000000009500")
        var p = ReceiveStubProtocol.Plan();p.status = 401;ReceiveStubProtocol.configure(p)
        await fail(try connection(Owner()),.authentication,reserve:{
            try journal.acquireExecution();defer {journal.releaseExecution()}
            var state = SyntheticABJournalState();state.runID = runner.runID
            state.context = .init(configurationBinding:runner.binding,fixtureBinding:fixture.binding,timing:.fixture,startedUTCMS:1000,startedMonoMS:0,sessionID:"synthetic-session",bootID:"synthetic-boot",sessionGeneration:0,bootGeneration:0,sessionExpiresUTCMS:6000,lifecycleGeneration:1)
            state.binding = state.context!.journalBinding;state.status = "running";try journal.write(state,operation:"claim")
            let req = try runner.request(0);state.httpUsed = 1;state.authUsed = 1;state.events = [.init(request:req,reservationID:runner.runID+":1",phase:"A",reservedUTCMS:1000,reservedMonoMS:0)]
            try journal.write(state,operation:"reserve:1");state.events[0].startedUTCMS = 1000;state.events[0].startedMonoMS = 0;try journal.write(state,operation:"start:1")
        })
        let persisted = try disk.read();XCTAssertEqual(persisted.httpUsed,1);XCTAssertEqual(persisted.authUsed,1);XCTAssertNil(persisted.events[0].raw)
        XCTAssertThrowsError(try runner.run(transport:SyntheticABTransport(fixture.responses()),journal:journal,environment:SyntheticABEnvironment()))
    }
}
