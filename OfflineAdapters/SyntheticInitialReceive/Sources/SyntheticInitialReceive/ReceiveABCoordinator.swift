import Foundation

private func nativeABError(_ error:Error) -> SyntheticABError {
    if let e = error as? SyntheticABError { return e }
    if error is ProtectedBoundaryError { return .lifecycle }
    guard let e = error as? ReceiveConnectionError else { return .cancelled }
    switch e {
    case .missingSession, .changedSession: return .sessionChanged
    case .expired: return .sessionExpired
    case .clock: return .clockBackward
    case .timeout: return .requestTimeout
    case .cancelled: return .cancelled
    case .tooLarge: return .responseSize
    case .authentication, .status, .redirect: return .httpStatus
    default: return .contract
    }
}

// Only this dedicated journal thread waits. The caller and URLSession queues never block on disk.
// The existing journal's pthread ownership and whole-run flock stay unchanged across HTTP awaits.
final class ReceiveNativeABTransport: SyntheticABTransporting {
    let responses: [SyntheticABResponse] = []
    private(set) var calls: [SyntheticABRequest] = []
    private let connection: ReceiveHTTPConnection, timing: SyntheticABTiming
    private let sessionCheck: () throws -> Void
    private let reviewedDigest:String?
    fileprivate init(connection:ReceiveHTTPConnection,timing:SyntheticABTiming,sessionCheck:@escaping () throws -> Void,reviewedDigest:String? = nil) {
        self.connection = connection; self.timing = timing; self.sessionCheck = sessionCheck;self.reviewedDigest = reviewedDigest
    }
    func requireReviewed(_ execution:ReceiveReviewedExecution) throws {
        try abNeed(reviewedDigest == execution.journalBinding.digest && timing == execution.timing,.policy)
    }
    func checkCancellation() throws { do { try sessionCheck() } catch { throw nativeABError(error) } }
    private final class ResultSlot: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value:0)
        private let lock = NSLock()
        private var value: Result<ReceiveHTTPResponse,Error>?
        func publish(_ value:Result<ReceiveHTTPResponse,Error>) { lock.lock(); self.value = value; lock.unlock(); semaphore.signal() }
        func get() throws -> ReceiveHTTPResponse { lock.lock(); defer { lock.unlock() }; return try value!.get() }
    }
    func take(_ request:SyntheticABRequest,journal:SyntheticABJournal,environment:SyntheticABEnvironment,check:() throws -> Void) throws -> SyntheticABResponse {
        let state = try journal.read(), ordinal = calls.count
        try abNeed(!journal.poisoned && state.status == "running" && ordinal < 14 && state.httpUsed == ordinal+1 && state.events.last?.request == request && state.events.last?.startedMonoMS != nil,.reservationRequired)
        try check(); try checkCancellation()
        // A fresh disk read on the lock owner thread proves reservation/start persistence.
        // No second reservation or off-thread journal access occurs in the URLSession task.
        calls.append(request)
        let slot = ResultSlot()
        let task = Task.detached { [connection,timing] in
            do { slot.publish(.success(try await connection.send(ordinal:ordinal,timeoutMS:timing.requestMS,expiresUTCMS:timing.expiresUTCMS,maxBytes:timing.maxResponseBytes,reserveAndStart:{}))) }
            catch { slot.publish(.failure(error)) }
        }
        var failure: SyntheticABError?
        while slot.semaphore.wait(timeout:.now()+0.01) == .timedOut {
            if failure == nil {
                do { try check(); try checkCancellation() }
                catch { failure = nativeABError(error); connection.cancel(); task.cancel() }
            }
        }
        if let failure { throw failure }
        do {
            try check(); try checkCancellation()
            let response = try slot.get()
            return .init(raw:response.bytes,status:response.status,contentRange:response.contentRange,delayMS:0)
        } catch { throw nativeABError(error) }
    }
}

// The contained completion and its mutable guards are accessed only under this lock.
final class ReceiveABCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: ProtectedABJournalCompletion
    let clock: ABRuntimeClock
    fileprivate init(_ completion:ProtectedABJournalCompletion,clock:ABRuntimeClock) { self.completion = completion; self.clock = clock }
    func checkedReport() throws -> SyntheticABReport {
        lock.lock(); defer { lock.unlock() }; return try completion.checkedReport()
    }
    func requireApplyInput() throws { throw SyntheticABError.unverified }
    func checkedAdmissionJournal() throws -> SyntheticABJournalState {
        lock.lock(); defer { lock.unlock() }
        return try completion.checkedAdmissionJournal()
    }
    func checkedReportAsync() async throws -> SyntheticABReport {
        try Task.checkCancellation()
        let report: SyntheticABReport = try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do { continuation.resume(returning:try self.checkedReport()) }
                catch { continuation.resume(throwing:error) }
            }
            thread.name = "receive-boundary.report"; thread.qualityOfService = .utility; thread.start()
        }
        try Task.checkCancellation(); try checkPublication(); return report
    }
    func checkPublication() throws {
        lock.lock(); defer { lock.unlock() }; try completion.checkPublication()
    }
}

// Fixed or strictly reviewed synthetic target and .invalid transport only. This creates no actual local identity.
final class ReceiveABCoordinator: @unchecked Sendable {
    private let reviewed:ReceiveReviewedExecution?
    private let home:URL, lease:BoundaryLease, protection:PhysicalStorageAccess
    private let source:ReceiveSessionSource, clock:ABRuntimeClock, timing:SyntheticABTiming, protocolClass:AnyClass
    private let lock = NSLock()
    private var used = false, cancelled = false
    private var connection:ReceiveHTTPConnection?
    private var dedicated:ReceiveDedicatedEnvironment?
    var checkpoint:(String) throws -> Void = { _ in }
    init(syntheticHome:URL,lease:BoundaryLease,protection:PhysicalStorageAccess,owner:ReceiveAuthOwner,clock:ABRuntimeClock,timing:SyntheticABTiming,protocolClass:AnyClass) throws {
        try timing.validate(); try abNeed(timing.requestMS <= 60000,.policy)
        reviewed = nil
        home = syntheticHome; self.lease = lease; self.protection = protection; source = owner.source
        self.clock = clock; self.timing = timing; self.protocolClass = protocolClass
    }
    init(offlineReviewed:ReceiveReviewedExecution,syntheticHome:URL,lease:BoundaryLease,protection:PhysicalStorageAccess,owner:ReceiveAuthOwner,clock:ABRuntimeClock,protocolClass:AnyClass) throws {
        try offlineReviewed.journalBinding.validate();try offlineReviewed.timing.validate()
        reviewed = offlineReviewed;home = syntheticHome;self.lease = lease;self.protection = protection;source = owner.source
        self.clock = clock;timing = offlineReviewed.timing;self.protocolClass = protocolClass
    }
    init(offlineReviewed:ReceiveReviewedExecution,dedicated:ReceiveDedicatedEnvironment,executionJournalHome:URL,protocolClass:AnyClass) throws {
        try offlineReviewed.journalBinding.validate();try dedicated.check(.cachedSession);try dedicated.check(.httpRead)
        try connectionNeed(dedicated.authority?.contextDigest == offlineReviewed.journalBinding.digest && dedicated.authority?.rehearsal == true,.closed)
        reviewed=offlineReviewed;home=executionJournalHome;lease=dedicated.lease;protection=dedicated.protection
        source=dedicated.source;clock=dedicated.clock;timing=offlineReviewed.timing;self.protocolClass=protocolClass;self.dedicated=dedicated
    }
    func cancel() { lock.lock(); cancelled = true; let c = connection; lock.unlock(); c?.cancel() }
    private func check() throws { lock.lock(); let stop = cancelled; lock.unlock(); try abNeed(!stop,.cancelled); try lease.check() }
    private func claim() throws { lock.lock(); defer { lock.unlock() }; try abNeed(!used,.runReuse); used = true; try abNeed(!cancelled,.cancelled) }
    private func attach(_ c:ReceiveHTTPConnection) { lock.lock(); connection = c; let stop = cancelled; lock.unlock(); if stop { c.cancel() } }
    private func perform() throws -> ReceiveABCompletion {
        try check()
        let account = UUID(uuidString:reviewed?.journalBinding.account ?? SyntheticABExpected.fixture().account)!
        let project = UUID(uuidString:reviewed?.journalBinding.project ?? SyntheticABExpected.fixture().project)!
        // Start total time before owner/context checks or container preparation.
        let env = try SyntheticABEnvironment(clock:clock,session:ABSessionDouble(expiresUTCMS:reviewed?.journalBinding.sessionExpiresUTCMS ?? timing.expiresUTCMS,generation:reviewed?.journalBinding.sessionEpoch ?? 0),bootID:reviewed?.journalBinding.bootID ?? "synthetic-runtime-boot")
        try dedicated?.check(.cachedSession);try dedicated?.check(.httpRead)
        let session = try source.capture(account:account,clock:clock)
        let check:() throws -> Void = {
            try self.check();try session.check()
            if let reviewed = self.reviewed {
                try session.requireContext(account:account,epoch:reviewed.journalBinding.sessionEpoch,expiresUTCMS:reviewed.journalBinding.sessionExpiresUTCMS)
            }
        }
        try reviewed?.check(env);try check()
        let target = try ReceiveHTTPTarget(origin:URL(string:"https://receive-boundary.invalid")!,account:account,project:project,publishableKey:"sb_publishable_offline_fixture")
        let c:ReceiveHTTPConnection
        if let dedicated {c=try dedicated.connection(target:target,offlineProtocol:protocolClass)}
        else {c=try ReceiveHTTPConnection(offlineTarget:target,source:source,clock:clock,protocolClass:protocolClass,leaseCheck:check)}
        attach(c)
        let access = PhysicalStorageAccess(check:{ try check(); try self.protection.check() },created:protection.created,verify:protection.verify)
        let work = try ProtectedABJournalWork(home:home,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access)
        let transport = ReceiveNativeABTransport(connection:c,timing:timing,sessionCheck:check,reviewedDigest:reviewed?.journalBinding.digest)
        let completion:ProtectedABJournalCompletion
        if let reviewed { completion = try work.runReviewedNative(reviewed,transport:transport,environment:env,checkpoint:checkpoint) }
        else { completion = try work.run(transport:transport,timing:timing,environment:env,checkpoint:checkpoint) }
        try check(); _ = try completion.checkedReport()
        return ReceiveABCompletion(completion,clock:clock)
    }
    func run() async throws -> ReceiveABCompletion {
        try claim()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            let result:ReceiveABCompletion = try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { do { continuation.resume(returning:try self.perform()) } catch { continuation.resume(throwing:error) } }
                thread.name = "receive-boundary.journal"; thread.qualityOfService = .utility; thread.start()
            }
            try Task.checkCancellation(); try check(); _ = try await result.checkedReportAsync(); return result
        },onCancel:{ self.cancel() })
    }
}
