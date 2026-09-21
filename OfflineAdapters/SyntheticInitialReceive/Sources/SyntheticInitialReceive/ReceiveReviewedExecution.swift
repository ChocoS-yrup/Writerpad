import Foundation

// A persisted comparison binding, not an authorization. Reopening cannot mint execution authority.
struct ReceiveReviewedJournalBinding: Codable, Equatable {
    let mode: String
    let endpoint: String, account: String, project: String
    let sourceRun: String, handoffSHA256: String, targetSHA256: String
    let runID: String, localProjectID: String, bundleID: String, bootID: String
    let sessionEpoch: Int, sessionExpiresUTCMS: Int, httpLimit: Int, authLimit: Int
    var digest: String { byteHash(try! canonical(self)) }
    func validate() throws {
        try abNeed(mode == "offline-reviewed-comparison-v1" && endpoint == "https://synthetic.invalid",.policy)
        for id in [account,project,sourceRun,runID,localProjectID] {
            try abNeed(id.hasPrefix("ee2609") && UUID(uuidString:id)?.uuidString.lowercased() == id,.policy)
        }
        try abNeed(runID != sourceRun && ![account,project,sourceRun,runID].contains(localProjectID),.policy)
        for hash in [handoffSHA256,targetSHA256] { try abNeed(hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) },.policy) }
        try abNeed(bundleID == ProtectedBoundaryContainer.bundleID && bootID.hasPrefix("synthetic-") && bootID.utf8.count <= 128 && bootID.utf8.allSatisfy { $0 >= 33 && $0 <= 126 },.policy)
        try abInteger(sessionEpoch);try abInteger(sessionExpiresUTCMS,1)
        try abNeed(httpLimit == 14 && authLimit == 2,.policy)
    }
}

// No URLSession, token source or production container factory is accepted here.
// The retained reader is used with synthetic source files; real origins/identities remain closed.
struct ReceiveReviewedExecution {
    let target: ReviewedReceiveTarget
    let timing: SyntheticABTiming
    let journalBinding: ReceiveReviewedJournalBinding
    private let draft: ReceiveExecutionCandidate.Draft
    private let readRuntime: () throws -> ReceiveExecutionCandidate.RuntimeSnapshot
    private init(target:ReviewedReceiveTarget,draft:ReceiveExecutionCandidate.Draft,runtime:ReceiveExecutionCandidate.RuntimeSnapshot,readRuntime:@escaping () throws -> ReceiveExecutionCandidate.RuntimeSnapshot) throws {
        self.target = target;self.draft = draft;self.readRuntime = readRuntime;timing = draft.timing!
        journalBinding = .init(mode:"offline-reviewed-comparison-v1",endpoint:draft.endpoint!,account:draft.account!.uuidString.lowercased(),project:draft.project!.uuidString.lowercased(),sourceRun:target.sourceRun,handoffSHA256:draft.handoffSHA256!,targetSHA256:draft.targetSHA256!,runID:draft.runID!.uuidString.lowercased(),localProjectID:draft.localProjectID!.uuidString.lowercased(),bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:draft.sessionEpoch!,sessionExpiresUTCMS:runtime.sessionExpiresUTCMS,httpLimit:draft.httpLimit!,authLimit:draft.authLimit!)
        try journalBinding.validate()
    }
    static func offline(target:ReviewedReceiveTarget,draft:ReceiveExecutionCandidate.Draft,now:ABRuntimeClock.Sample,readRuntime:@escaping () throws -> ReceiveExecutionCandidate.RuntimeSnapshot) throws -> Self {
        // Reject real origins before consulting the supplied runtime callback.
        try abNeed(try target.binding.str("endpoint") == "https://synthetic.invalid" && draft.endpoint == "https://synthetic.invalid",.policy)
        let runtime = try readRuntime()
        let comparison = try ReceiveExecutionCandidate.compare(draft,to:target,now:now,runtime:runtime)
        try abNeed(comparison.local_fields_matched,.policy)
        return try .init(target:target,draft:draft,runtime:runtime,readRuntime:readRuntime)
    }
    func check(_ env:SyntheticABEnvironment) throws {
        try env.refresh()
        let runtime = try readRuntime()
        let comparison = try ReceiveExecutionCandidate.compare(draft,to:target,now:.init(utcMS:env.utcMS,monoMS:env.monoMS),runtime:runtime)
        try abNeed(comparison.local_fields_matched && runtime.sessionExpiresUTCMS == journalBinding.sessionExpiresUTCMS,.sessionChanged)
        try abNeed(env.sessionGeneration == journalBinding.sessionEpoch && env.sessionExpiresUTCMS == journalBinding.sessionExpiresUTCMS,.sessionChanged)
        try abNeed(env.bootID == journalBinding.bootID,.bootChanged)
    }
    func requireExecution() throws { throw ReceiveConnectionError.closed }
    func requireApplyInput() throws { throw SyntheticABError.unverified }
}
