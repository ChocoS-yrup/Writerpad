import Foundation

struct ProtectedABJournalCompletion {
    private let lease: BoundaryLease
    private let completion: SyntheticABCompletion
    private let container: ProtectedBoundaryContainer
    private let stateSHA256: String
    fileprivate init(lease: BoundaryLease,completion: SyntheticABCompletion,container: ProtectedBoundaryContainer,stateSHA256: String) {
        self.lease = lease; self.completion = completion; self.container = container; self.stateSHA256 = stateSHA256
    }
    func checkedReport() throws -> SyntheticABReport {
        try lease.check()
        let state = try SyntheticABDiskJournal(container:container).read()
        try abNeed(state.status == "finished" && byteHash(canonical(state)) == stateSHA256,.journalCorrupt)
        let report = try completion.checkedReport(); try lease.check(); return report
    }
    func requireApplyInput() throws { throw SyntheticABError.unverified }
    // Only a live completion can expose its exact checked journal to the offline admission layer.
    // Decoding a saved journal alone does not reconstruct this capability.
    func checkedAdmissionJournal() throws -> SyntheticABJournalState {
        _ = try checkedReport()
        let state = try SyntheticABDiskJournal(container:container).read()
        try abNeed(byteHash(canonical(state)) == stateSHA256,.journalCorrupt)
        _ = try completion.checkedReport(); try lease.check()
        return state
    }
    // In-memory publication guard only. Disk verification must precede this on a worker.
    func checkPublication() throws {
        try lease.check(); _ = try completion.checkedReport(); try lease.check()
    }
}

// Same lease covers container preparation, every journal operation, and publication.
// The factory accepts no server input and constructs only the fixed synthetic A/B fixture.
final class ProtectedABJournalWork {
    let container: ProtectedBoundaryContainer
    private let lease: BoundaryLease
    init(home: URL,declaredBundle: String,lease: BoundaryLease,protection: PhysicalStorageAccess) throws {
        try lease.check()
        self.lease = lease
        let check: () throws -> Void = { try lease.check(); try protection.check(); try lease.check() }
        let access = PhysicalStorageAccess(check:check,created:{ url in
            try check(); try protection.created(url); try check()
        },verify:{ url in try check(); try protection.verify(url); try check() })
        container = try ProtectedBoundaryContainer(home:home,declaredBundle:declaredBundle,access:access)
    }
    func run(transport: (any SyntheticABTransporting)? = nil,timing: SyntheticABTiming = .fixture,environment: SyntheticABEnvironment? = nil,checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> ProtectedABJournalCompletion {
        let fixture = SyntheticABExpected.fixture()
        return try runBound(runner:SyntheticABRunner(expected:fixture,timing:timing,runID:"synthetic-ab-ee260914-0000-4000-8000-000000009300"),transport:transport ?? SyntheticABTransport(fixture.responses()+fixture.responses()),environment:environment ?? SyntheticABEnvironment(),checkpoint:checkpoint)
    }
    // Only a concrete in-memory response double; no native transport or live activation path.
    func runReviewed(_ execution:ReceiveReviewedExecution,transport:SyntheticABTransport,environment:SyntheticABEnvironment,checkpoint:@escaping (String) throws -> Void = { _ in }) throws -> ProtectedABJournalCompletion {
        try execution.check(environment)
        return try runBound(runner:SyntheticABRunner(reviewed:execution),transport:transport,environment:environment,checkpoint:checkpoint)
    }
    // A native adapter can only be constructed by the sealed .invalid coordinator in its file.
    func runReviewedNative(_ execution:ReceiveReviewedExecution,transport:ReceiveNativeABTransport,environment:SyntheticABEnvironment,checkpoint:@escaping (String) throws -> Void) throws -> ProtectedABJournalCompletion {
        try transport.requireReviewed(execution);try execution.check(environment)
        return try runBound(runner:SyntheticABRunner(reviewed:execution),transport:transport,environment:environment,checkpoint:checkpoint)
    }
    private func runBound(runner:SyntheticABRunner,transport:any SyntheticABTransporting,environment env:SyntheticABEnvironment,checkpoint:@escaping (String) throws -> Void) throws -> ProtectedABJournalCompletion {
        let timing = runner.timing
        try timing.validate(); try env.refresh()
        try abNeed(timing.notBeforeUTCMS <= env.utcMS && env.utcMS < timing.expiresUTCMS,.window)
        try abNeed(env.utcMS < env.sessionExpiresUTCMS,.sessionExpired)
        let initialID = env.sessionID, initialGeneration = env.sessionGeneration, initialExpiry = env.sessionExpiresUTCMS
        let initialUTC = env.utcMS, initialMono = env.monoMS
        try lease.check(); try container.prepare(); try lease.check()
        try env.refresh()
        try abNeed(env.sessionID == initialID && env.sessionGeneration == initialGeneration && env.sessionExpiresUTCMS == initialExpiry,.sessionChanged)
        try abNeed(env.utcMS >= initialUTC && env.monoMS >= initialMono,.clockBackward)
        let disk = try SyntheticABDiskJournal(container:container)
        disk.checkpoint = checkpoint
        let result = try runner.run(transport:transport,journal:SyntheticABJournal(disk:disk),environment:env)
        try lease.check(); _ = try result.checkedReport()
        let state = try inspect()
        _ = try result.checkedReport()
        try abNeed(state.status == "finished",.journalCorrupt)
        return .init(lease:lease,completion:result,container:container,stateSHA256:byteHash(try canonical(state)))
    }
    // These are synthetic local test limits, not a server execution approval or refreshed login.
    func runWithSystemClock() throws -> ProtectedABJournalCompletion {
        let clock = ABRuntimeClock(), now = try clock.sample()
        let timing = SyntheticABTiming(requestMS:5000,passMS:30000,interpassMS:5000,preApplyMS:5000,localApplyMS:5000,totalMS:60000,notBeforeUTCMS:now.utcMS,expiresUTCMS:try abAdd(now.utcMS,60000))
        let env = try SyntheticABEnvironment(clock:clock,session:ABSessionDouble(expiresUTCMS:timing.expiresUTCMS))
        var responses = SyntheticABExpected.fixture().responses()+SyntheticABExpected.fixture().responses()
        for i in responses.indices { responses[i].delayMS = 0 }
        return try run(transport:SyntheticABTransport(responses),timing:timing,environment:env)
    }
    func inspect() throws -> SyntheticABJournalState {
        try lease.check(); try container.validate(container.workspace)
        let state = try SyntheticABDiskJournal(container:container).read()
        try lease.check(); return state
    }
}

#if os(iOS)
extension PhysicalStorageAccess {
    static func completeProtection(lease: BoundaryLease) -> PhysicalStorageAccess {
        let check: () throws -> Void = { try Task.checkCancellation(); try lease.check() }
        let verify: (URL) throws -> Void = { url in
            try check(); try SafeFiles.checked(url)
            let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
            try CompleteFileProtection.require(attrs[.protectionKey]); try check()
        }
        return .init(check:check,created:{ url in
            try check()
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
            try verify(url)
        },verify:verify)
    }
}
#endif
