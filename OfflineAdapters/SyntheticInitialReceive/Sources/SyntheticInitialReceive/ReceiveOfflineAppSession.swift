import Foundation

protocol ReceiveAppReceipt {
    func verify() async throws
    func checkPublication() throws
}
protocol ReceiveAppJob: AnyObject {
    func run() async throws -> any ReceiveAppReceipt
    func cancel()
}
extension ReceiveABCompletion: ReceiveAppReceipt {
    func verify() async throws { _ = try await checkedReportAsync() }
}

// All publication changes are serialized on the UI actor; invalidation never frees an active slot.
@MainActor
final class ReceiveOfflineAppSession {
    enum State: Equatable { case idle, running, stopped, complete }
    private let lifecycle: BoundaryLifecycle
    private var active: (any ReceiveAppJob)?
    private var generation: UInt64 = 0
    private(set) var state: State = .idle
    var isRunning: Bool { active != nil }
    var syntheticReady: Bool { state == .complete }
    let baselineApplied = false, executionAllowed = false
    init(lifecycle:BoundaryLifecycle) { self.lifecycle = lifecycle }
    func invalidate() {
        // Saturating generation cannot revive a stale ticket; the captured lease is revoked too.
        if generation < UInt64.max { generation += 1 }
        state = .stopped; active?.cancel()
    }
    func run(makeJob:(BoundaryLease) throws -> any ReceiveAppJob) async {
        guard active == nil else { return }
        state = .running
        do {
            try Task.checkCancellation()
            try abNeed(generation < UInt64.max,.runReuse)
            generation += 1; let ticket = generation
            let lease = try lifecycle.begin()
            let job = try makeJob(lease)
            do { try Task.checkCancellation(); try lease.check(); try abNeed(generation == ticket,.cancelled) }
            catch { job.cancel(); throw error }
            active = job
            defer { active = nil }
            try await withTaskCancellationHandler(operation:{
                let receipt = try await job.run()
                try Task.checkCancellation(); try lease.check(); try abNeed(generation == ticket,.cancelled)
                try await receipt.verify()
                try Task.checkCancellation(); try lease.check(); try abNeed(generation == ticket,.cancelled)
                // No suspension between the final in-memory guard and UI publication.
                try receipt.checkPublication(); state = .complete
            },onCancel:{ job.cancel() })
        } catch {
            // Error strings, paths, credentials and response bodies never become UI state.
            state = .stopped
        }
    }
}

// Built-in synthetic URLProtocol. It never falls through to a socket or accepts an external body.
final class ReceiveAppFixtureProtocol: URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "receive-boundary.invalid" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            let fixture = SyntheticABExpected.fixture()
            let paths = ["/auth/v1/user","/rest/v1/rpc/get_sync_handshake"]+WindowsHandoffReader.tables.map { "/rest/v1/"+$0 }
            guard let url = request.url,let index = paths.firstIndex(of:url.path) else { throw ReceiveConnectionError.invalidRequest }
            let target = try ReceiveHTTPTarget(origin:URL(string:"https://receive-boundary.invalid")!,account:UUID(uuidString:fixture.account)!,project:UUID(uuidString:fixture.project)!,publishableKey:"sb_publishable_offline_fixture")
            let expected = try target.request(ordinal:index,authorization:"Bearer synthetic.app.session",timeoutMS:5000)
            try connectionNeed(url == expected.url && request.httpMethod == expected.httpMethod && request.value(forHTTPHeaderField:"Authorization") == expected.value(forHTTPHeaderField:"Authorization") && request.value(forHTTPHeaderField:"apikey") == expected.value(forHTTPHeaderField:"apikey"),.invalidRequest)
            // URL loading can materialize POST data as a stream. This protocol never reads it;
            // request construction is separately checked, and only fixed synthetic replies exist.
            let value = fixture.responses()[index]
            var headers = ["Content-Length":String(value.raw.count)]
            if let range = value.contentRange { headers["Content-Range"] = range }
            let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:headers)!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:value.raw); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:URLError(.unsupportedURL)) }
    }
    override func stopLoading() {}
}

final class ReceiveOfflineAppJob: ReceiveAppJob {
    private let coordinator: ReceiveABCoordinator
    init(home:URL,declaredBundle:String,lease:BoundaryLease,protection:PhysicalStorageAccess) throws {
        guard declaredBundle == ProtectedBoundaryContainer.bundleID else { throw LocalBoundaryError.bundle }
        try lease.check()
        let clock = ABRuntimeClock(), now = try clock.sample(), expiry = try abAdd(now.utcMS,60000)
        let timing = SyntheticABTiming(requestMS:5000,passMS:30000,interpassMS:5000,preApplyMS:5000,localApplyMS:5000,totalMS:60000,notBeforeUTCMS:now.utcMS,expiresUTCMS:expiry)
        let owner = ReceiveAuthOwner()
        try owner.replaceCachedSession(.init(account:UUID(uuidString:SyntheticABExpected.fixture().account)!,accessToken:"synthetic.app.session",expiresUTCMS:expiry))
        coordinator = try ReceiveABCoordinator(syntheticHome:home,lease:lease,protection:protection,owner:owner,clock:clock,timing:timing,protocolClass:ReceiveAppFixtureProtocol.self)
    }
    func run() async throws -> any ReceiveAppReceipt { try await coordinator.run() }
    func cancel() { coordinator.cancel() }
}

// Explicit internal app job for an already checked synthetic reader/context input.
// A separate URLProtocol is supplied by offline tests; the connection always adds deny fallback.
final class ReceiveReviewedOfflineAppJob:ReceiveAppJob {
    private let coordinator:ReceiveABCoordinator
    init(execution:ReceiveReviewedExecution,home:URL,declaredBundle:String,lease:BoundaryLease,protection:PhysicalStorageAccess,owner:ReceiveAuthOwner,clock:ABRuntimeClock,protocolClass:AnyClass) throws {
        try connectionNeed(declaredBundle == ProtectedBoundaryContainer.bundleID,.invalidTarget);try lease.check()
        coordinator = try .init(offlineReviewed:execution,syntheticHome:home,lease:lease,protection:protection,owner:owner,clock:clock,protocolClass:protocolClass)
    }
    func run() async throws -> any ReceiveAppReceipt {try await coordinator.run()}
    func cancel(){coordinator.cancel()}
}

// Explicit synthetic rehearsal of the full admission route. No default app injection or live permission.
final class ReceiveAdmittedOfflineAppJob: ReceiveAppJob {
    private let coordinator: ReceiveABCoordinator, execution:ReceiveReviewedExecution
    private let descriptor:ReceiveLocalStoreDescriptor, lease:BoundaryLease, protection:PhysicalStorageAccess
    init(execution:ReceiveReviewedExecution,descriptor:ReceiveLocalStoreDescriptor,home:URL,lease:BoundaryLease,
         protection:PhysicalStorageAccess,owner:ReceiveAuthOwner,clock:ABRuntimeClock,protocolClass:AnyClass) throws {
        try descriptor.validateOffline(execution.journalBinding);try lease.check()
        self.execution=execution;self.descriptor=descriptor;self.lease=lease;self.protection=protection
        coordinator=try .init(offlineReviewed:execution,syntheticHome:home,lease:lease,protection:protection,owner:owner,clock:clock,protocolClass:protocolClass)
    }
    func cancel() { coordinator.cancel() }
    func run() async throws -> any ReceiveAppReceipt {
        try await withTaskCancellationHandler(operation:{
            let completion=try await coordinator.run()
            return try await Task.detached { [self] in
                let plan=try ReceiveAdmissionPlan.offline(execution:execution,completion:completion)
                let permit=try ReceiveOfflineApplyPermit.issue(plan:plan,descriptor:descriptor)
                let session=try ReceiveAdmissionSession.prepare(plan:plan,descriptor:descriptor,permit:permit,lease:lease,protection:protection)
                _ = try session.applyOffline()
                return ReceiveAdmissionAppReceipt(plan:plan,session:session)
            }.value
        },onCancel:{self.cancel()})
    }
}

private final class ReceiveAdmissionAppReceipt: ReceiveAppReceipt, @unchecked Sendable {
    private let lock=NSLock(),plan:ReceiveAdmissionPlan,session:ReceiveAdmissionSession
    init(plan:ReceiveAdmissionPlan,session:ReceiveAdmissionSession){self.plan=plan;self.session=session}
    private func verifyStorage() throws {lock.lock();defer{lock.unlock()};_ = try session.snapshot()}
    func verify() async throws { try Task.checkCancellation();try await Task.detached{try self.verifyStorage()}.value;try Task.checkCancellation() }
    func checkPublication() throws {try plan.check()}
}
