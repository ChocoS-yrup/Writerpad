import Foundation

// Synthetic transport/session only; optional system UTC/continuous clock, never a token or network client.
enum SyntheticABError: String, Error, Codable {
    case policy, window, expired, requestTimeout, passTimeout, interpassTimeout, preApplyTimeout, localProbeTimeout, totalTimeout
    case lifecycle, sessionChanged, sessionExpired, bootChanged, clockBackward, cancelled, arithmetic
    case busy, journalCorrupt, journalWrite, journalUncertain, journalReadback, journalPoisoned, runReuse, transportReuse, reservationRequired, quota
    case mockMissing, responseLost, responseSize, runSize, httpStatus, subject, handshake, project, settings, count, contract, graph, targetChanged, partialPass, abChanged, unverified
}
func abNeed(_ condition: @autoclosure () throws -> Bool,_ error: SyntheticABError) throws { if try !condition() { throw error } }
private let abMax = 9_007_199_254_740_991
func abInteger(_ value: Int,_ minimum: Int = 0) throws { try abNeed(value >= minimum && value <= abMax,.policy) }
func abAdd(_ a: Int,_ b: Int) throws -> Int {
    let (sum,overflow) = a.addingReportingOverflow(b)
    try abNeed(!overflow && sum >= 0 && sum <= abMax,.arithmetic); return sum
}

struct SyntheticABTiming: Codable, Equatable {
    var requestMS: Int, passMS: Int, interpassMS: Int, preApplyMS: Int, localApplyMS: Int, totalMS: Int
    var notBeforeUTCMS: Int, expiresUTCMS: Int
    var maxResponseBytes: Int = 4*1024*1024
    var maxRunBytes: Int = 32*1024*1024
    func validate() throws {
        for v in [requestMS,passMS,interpassMS,preApplyMS,localApplyMS,totalMS,expiresUTCMS,maxResponseBytes,maxRunBytes] { try abInteger(v,1) }
        try abInteger(notBeforeUTCMS)
        try abNeed(notBeforeUTCMS < expiresUTCMS && maxResponseBytes <= 4*1024*1024 && maxRunBytes <= 32*1024*1024 && maxRunBytes >= maxResponseBytes,.policy)
    }
    static var fixture: Self { .init(requestMS:100,passMS:1000,interpassMS:100,preApplyMS:100,localApplyMS:100,totalMS:3000,notBeforeUTCMS:1000,expiresUTCMS:6000) }
}

enum SyntheticABEffect: Equatable {
    case none, background, backgroundAndActivate, protectedLoss, protectedLossAndRestore
    case replaceSession, replaceSessionWithSameID, restart, restartWithSameID, utcBackward, monoBackward, cancel
}
final class SyntheticABEnvironment {
    private(set) var utcMS: Int, monoMS: Int
    private(set) var sessionID: String, bootID: String
    private(set) var sessionExpiresUTCMS: Int
    let clock: ABRuntimeClock?
    private let session: ABSessionDouble?
    let budgetOrigin: Int?
    private(set) var sessionGeneration = 0, bootGeneration = 0
    private(set) var cancelled = false
    let lifecycle = BoundaryLifecycle()
    init(utcMS: Int = 1000,monoMS: Int = 0,sessionID: String = "synthetic-session",bootID: String = "synthetic-boot",active: Bool = true,protectedDataAvailable: Bool = true,sessionExpiresUTCMS: Int = 6000) {
        clock = nil; session = nil; budgetOrigin = nil
        self.sessionExpiresUTCMS = sessionExpiresUTCMS
        self.utcMS = utcMS; self.monoMS = monoMS; self.sessionID = sessionID; self.bootID = bootID
        lifecycle.update(active:active,protectedDataAvailable:protectedDataAvailable)
    }
    init(clock: ABRuntimeClock,session: ABSessionDouble,bootID:String = "synthetic-runtime-boot") throws {
        let now = try clock.sample(), current = session.snapshot()
        self.clock = clock; self.session = session; budgetOrigin = now.monoMS
        utcMS = now.utcMS; monoMS = now.monoMS; sessionID = current.id; sessionGeneration = current.generation
        sessionExpiresUTCMS = current.expiresUTCMS; self.bootID = bootID
        lifecycle.update(active:true,protectedDataAvailable:true)
    }
    func refresh() throws {
        if let clock { let now = try clock.sample(); utcMS = now.utcMS; monoMS = now.monoMS }
        if let session { let current = session.snapshot(); sessionID = current.id; sessionGeneration = current.generation; sessionExpiresUTCMS = current.expiresUTCMS }
    }
    func advance(_ delta: Int) throws {
        if let clock { try clock.advance(delta); try refresh(); return }
        try abInteger(delta)
        let utc = try abAdd(utcMS,delta), mono = try abAdd(monoMS,delta)
        utcMS = utc; monoMS = mono
    }
    func apply(_ effect: SyntheticABEffect) throws {
        switch effect {
        case .none: break
        case .background: lifecycle.update(active:false,protectedDataAvailable:true)
        case .backgroundAndActivate: lifecycle.update(active:false,protectedDataAvailable:true); lifecycle.update(active:true,protectedDataAvailable:true)
        case .protectedLoss: lifecycle.update(active:true,protectedDataAvailable:false)
        case .protectedLossAndRestore: lifecycle.update(active:true,protectedDataAvailable:false); lifecycle.update(active:true,protectedDataAvailable:true)
        case .replaceSession:
            if let session { try session.replace(id:"synthetic-replaced-session"); try refresh() }
            else { sessionID = "synthetic-replaced-session"; sessionGeneration = try abAdd(sessionGeneration,1) }
        case .replaceSessionWithSameID:
            if let session { try session.replace(); try refresh() }
            else { sessionGeneration = try abAdd(sessionGeneration,1) }
        case .restart: bootID = "synthetic-restarted-boot"; bootGeneration = try abAdd(bootGeneration,1)
        case .restartWithSameID: bootGeneration = try abAdd(bootGeneration,1)
        case .utcBackward:
            if let clock { try clock.setForTest(utcMS:max(0,utcMS-100),monoMS:monoMS); try refresh() }
            else { utcMS = max(0,utcMS-100) }
        case .monoBackward:
            if let clock { try clock.setForTest(utcMS:utcMS,monoMS:max(0,monoMS-100)); try refresh() }
            else { monoMS = max(0,monoMS-100) }
        case .cancel: cancelled = true
        }
    }
}

struct SyntheticABResponse {
    var raw: Data
    var status: Int = 200
    var contentRange: String? = nil
    var delayMS: Int = 1
    var persistenceMS: Int = 0
    var effect: SyntheticABEffect = .none
    var persistenceEffect: SyntheticABEffect = .none
    var lost = false
}
struct SyntheticABDelays {
    var reservationMS = 0, interpassMS = 0, comparisonMS = 0, preApplyMS = 0, localApplyMS = 0
    var reservationEffect: SyntheticABEffect = .none
    var interpassEffect: SyntheticABEffect = .none
    var comparisonEffect: SyntheticABEffect = .none
    var preApplyEffect: SyntheticABEffect = .none
    var localEffect: SyntheticABEffect = .none
    var finishEffect: SyntheticABEffect = .none
    func validate() throws { for v in [reservationMS,interpassMS,comparisonMS,preApplyMS,localApplyMS] { try abInteger(v) } }
}
struct SyntheticABRequest: Codable, Equatable {
    let phase: String, requestIndex: Int, method: String, path: String
    let query: [String:String], headers: [String:String], bodySHA256: String
}
struct SyntheticABEvent: Codable, Equatable {
    var request: SyntheticABRequest?
    var reservationID: String?
    var phase: String
    var reservedUTCMS: Int?, reservedMonoMS: Int?
    var startedUTCMS: Int?, startedMonoMS: Int?
    var receivedUTCMS: Int?, receivedMonoMS: Int?
    var verifiedUTCMS: Int?, verifiedMonoMS: Int?
    var status: Int?, sha256: String?, byteCount: Int?, contentRange: String?, rowCount: Int?
    var raw: Data?
    var completedUTCMS: Int?, completedMonoMS: Int?
}
struct SyntheticABExecutionContext: Codable, Equatable {
    var reviewed: ReceiveReviewedJournalBinding? = nil
    let configurationBinding: String, fixtureBinding: String, timing: SyntheticABTiming
    let startedUTCMS: Int, startedMonoMS: Int
    let sessionID: String, bootID: String
    let sessionGeneration: Int, bootGeneration: Int, sessionExpiresUTCMS: Int
    let lifecycleGeneration: UInt64
    var contextBinding: String {
        byteHash(WindowsJSON.object(["session_id":.string(sessionID),"session_generation":.number(String(sessionGeneration)),"session_expires_utc_ms":.number(String(sessionExpiresUTCMS)),"boot_id":.string(bootID),"boot_generation":.number(String(bootGeneration)),"lifecycle_generation":.number(String(lifecycleGeneration))]).encoded(lf:true))
    }
    var journalBinding: String {
        byteHash(WindowsJSON.object(["configuration":.string(configurationBinding),"synthetic_context":.string(contextBinding)]).encoded(lf:true))
    }
    func validate(runID: String) throws {
        try timing.validate()
        let fixture = SyntheticABExpected.fixture()
        if let reviewed {
            try reviewed.validate()
            try abNeed(runID == "synthetic-ab-"+reviewed.runID && sessionGeneration == reviewed.sessionEpoch && bootID == reviewed.bootID && sessionExpiresUTCMS == reviewed.sessionExpiresUTCMS && timing.expiresUTCMS <= sessionExpiresUTCMS && timing.requestMS <= 60000,.journalCorrupt)
            try abNeed(fixtureBinding == reviewed.digest,.journalCorrupt)
        } else { try abNeed([fixture.binding,SyntheticABExpected.fixture(includeSpecial:true).binding].contains(fixtureBinding),.journalCorrupt) }
        let configuration = try SyntheticABRunner.configuration(expectedBinding:fixtureBinding,account:reviewed?.account ?? fixture.account,project:reviewed?.project ?? fixture.project,timing:timing,runID:runID)
        try abNeed(configuration == configurationBinding,.journalCorrupt)
        for value in [startedUTCMS,startedMonoMS,sessionGeneration,bootGeneration,sessionExpiresUTCMS] { try abInteger(value) }
        try abNeed(timing.notBeforeUTCMS <= startedUTCMS && startedUTCMS < timing.expiresUTCMS && startedUTCMS < sessionExpiresUTCMS && sessionID.hasPrefix("synthetic-") && bootID.hasPrefix("synthetic-") && configurationBinding.count == 64 && configurationBinding.allSatisfy { "0123456789abcdef".contains($0) },.journalCorrupt)
    }
}
struct SyntheticABJournalState: Codable, Equatable {
    var runID: String?, binding: String?
    var context: SyntheticABExecutionContext?
    var status = "unused"
    var httpUsed = 0, authUsed = 0
    var events: [SyntheticABEvent] = []
}
final class SyntheticABJournal {
    private(set) var blob: Data
    private(set) var poisoned = false
    let lock = NSLock()
    private let disk: SyntheticABDiskJournal?
    var skipOperation: String?, failBefore: String?, failAfter: String?
    init(restored: Data? = nil) throws { disk = nil; blob = try restored ?? canonical(SyntheticABJournalState()) }
    init(disk: SyntheticABDiskJournal) throws { self.disk = disk; blob = try canonical(SyntheticABJournalState()) }
    func acquireExecution() throws {
        try abNeed(lock.try(),.busy)
        do { try disk?.acquire(create:true) }
        catch { lock.unlock(); throw error }
    }
    func releaseExecution() { disk?.release(); lock.unlock() }
    func requireFreshDisk() throws { if let disk { try abNeed(disk.createdHere,.runReuse) } }
    func read() throws -> SyntheticABJournalState {
        do {
            if let disk { blob = try canonical(disk.read()) }
            try abNeed(blob.count <= 48*1024*1024,.journalCorrupt)
            let s = try decodeExact(SyntheticABJournalState.self,blob)
            try abNeed((0...14).contains(s.httpUsed) && (0...2).contains(s.authUsed) && ["unused","running","stopped","finished"].contains(s.status) && s.events.count <= 15,.journalCorrupt)
            if s.status == "unused" { try abNeed(s == SyntheticABJournalState(),.journalCorrupt) }
            else {
                try abNeed(s.runID?.hasPrefix("synthetic-ab-") == true && s.binding?.count == 64,.journalCorrupt)
                if let context = s.context, context.reviewed != nil {
                    try context.validate(runID:s.runID!)
                    try abNeed(s.binding == context.journalBinding,.journalCorrupt)
                    for (i,event) in s.events.enumerated() where event.request != nil {
                        try abNeed(event.request == SyntheticABRunner.request(i,project:context.reviewed!.project),.journalCorrupt)
                    }
                }
                let requests = s.events.compactMap(\.request)
                try abNeed(requests.count == s.httpUsed && requests.filter { $0.requestIndex == 1 }.count == s.authUsed,.journalCorrupt)
                for (i,event) in s.events.enumerated() {
                    if let request = event.request {
                        try abNeed(request.requestIndex == i%7+1 && request.phase == (i < 7 ? "A" : "B") && event.reservationID == s.runID!+":\(i+1)",.journalCorrupt)
                    }
                    if let raw = event.raw { try abNeed(raw.count == event.byteCount && byteHash(raw) == event.sha256,.journalCorrupt) }
                }
            }
            return s
        } catch let error as SyntheticABError { throw error }
        catch { throw SyntheticABError.journalCorrupt }
    }
    func write(_ state: SyntheticABJournalState,operation: String) throws {
        if let disk {
            try abNeed(!poisoned,.journalPoisoned)
            do {
                if failBefore == operation { throw SyntheticABError.journalWrite }
                if skipOperation != operation { try disk.write(state,operation:operation) }
                if failAfter == operation { throw SyntheticABError.journalUncertain }
                try abNeed(try disk.read() == state,.journalReadback)
                blob = try canonical(state)
                return
            } catch { poisoned = true; throw error }
        }
        if failBefore == operation { poisoned = true; throw SyntheticABError.journalWrite }
        let data = try canonical(state)
        if skipOperation != operation { blob = data }
        if failAfter == operation { poisoned = true; throw SyntheticABError.journalUncertain }
        do { try abNeed(blob == data && read() == state,.journalReadback) }
        catch { poisoned = true; throw SyntheticABError.journalReadback }
    }
}

protocol SyntheticABTransporting {
    var responses: [SyntheticABResponse] { get }
    var calls: [SyntheticABRequest] { get }
    func checkCancellation() throws
    func take(_ request: SyntheticABRequest,journal: SyntheticABJournal,environment: SyntheticABEnvironment,check: () throws -> Void) throws -> SyntheticABResponse
}

final class SyntheticABTransport: SyntheticABTransporting {
    let responses: [SyntheticABResponse]
    private(set) var calls: [SyntheticABRequest] = []
    private let cancellationLock = NSLock()
    private var cancelled = false
    var onEvent: (String) throws -> Void = { _ in }
    func cancel() { cancellationLock.lock(); cancelled = true; cancellationLock.unlock() }
    func checkCancellation() throws {
        cancellationLock.lock(); defer { cancellationLock.unlock() }; try abNeed(!cancelled,.cancelled)
    }
    init(_ responses: [SyntheticABResponse]) { self.responses = responses }
    func take(_ request: SyntheticABRequest,journal: SyntheticABJournal,environment: SyntheticABEnvironment,check: () throws -> Void = {}) throws -> SyntheticABResponse {
        let state = try journal.read()
        try abNeed(!journal.poisoned && state.status == "running" && calls.count < 14 && state.httpUsed == calls.count+1 && state.events.last?.request == request && state.events.last?.startedMonoMS != nil,.reservationRequired)
        try onEvent("before-send"); try check(); try checkCancellation()
        calls.append(request)
        try onEvent("in-flight"); try check(); try checkCancellation()
        try abNeed(calls.count <= responses.count,.mockMissing)
        let response = responses[calls.count-1]
        try environment.advance(response.delayMS); try environment.apply(response.effect)
        try onEvent("before-delivery"); try check(); try checkCancellation()
        if response.lost { throw SyntheticABError.responseLost }
        return response
    }
}

struct SyntheticABReport: Encodable {
    let synthetic_policy_passed = true
    let sequential_comparison_passed = true
    let http_reserved: Int
    let auth_reserved: Int
    let baseline_ready = false, baseline_applied = false, execution_allowed = false, app_binding_created = false
    let editing_allowed = false, sending_allowed = false, automatic_receive_allowed = false
    let atomic_snapshot = false, current_server_verified = false, latest_at_apply_guaranteed = false
    let special_body_semantics_verified = false, full_windows_engine_equivalence_verified = false
}
private final class SyntheticABGuard {
    let env: SyntheticABEnvironment, lease: BoundaryLease, timing: SyntheticABTiming
    let first: Int, sessionID: String, bootID: String, sessionGeneration: Int, bootGeneration: Int
    var lastUTC: Int, lastMono: Int
    let sessionExpiry: Int
    let communicationCheck: () throws -> Void
    private var failure: SyntheticABError?
    var requestStart: Int?, passStart: Int?, interpassStart: Int?, preApplyStart: Int?, localStart: Int?
    var contextBinding: String {
        byteHash(WindowsJSON.object(["session_id":.string(sessionID),"session_generation":.number(String(sessionGeneration)),"session_expires_utc_ms":.number(String(env.sessionExpiresUTCMS)),"boot_id":.string(bootID),"boot_generation":.number(String(bootGeneration)),"lifecycle_generation":.number(String(lease.generation))]).encoded(lf:true))
    }
    init(_ env: SyntheticABEnvironment,_ timing: SyntheticABTiming,communicationCheck: @escaping () throws -> Void) throws {
        self.communicationCheck = communicationCheck
        try env.refresh()
        try abNeed(env.sessionID.hasPrefix("synthetic-") && env.bootID.hasPrefix("synthetic-"),.policy)
        try abInteger(env.utcMS); try abInteger(env.monoMS); try abInteger(env.sessionExpiresUTCMS,1)
        try abNeed(timing.notBeforeUTCMS <= env.utcMS && env.utcMS < timing.expiresUTCMS,.window)
        do { lease = try env.lifecycle.begin() } catch { throw SyntheticABError.lifecycle }
        self.env = env; self.timing = timing; first = env.budgetOrigin ?? env.monoMS; sessionExpiry = env.sessionExpiresUTCMS; lastUTC = env.utcMS; lastMono = env.monoMS
        sessionID = env.sessionID; bootID = env.bootID; sessionGeneration = env.sessionGeneration; bootGeneration = env.bootGeneration
        try check()
    }
    func executionContext(configurationBinding: String,fixtureBinding: String) -> SyntheticABExecutionContext {
        .init(configurationBinding:configurationBinding,fixtureBinding:fixtureBinding,timing:timing,startedUTCMS:env.utcMS,startedMonoMS:first,sessionID:sessionID,bootID:bootID,sessionGeneration:sessionGeneration,bootGeneration:bootGeneration,sessionExpiresUTCMS:env.sessionExpiresUTCMS,lifecycleGeneration:lease.generation)
    }
    func check() throws {
        if let failure { throw failure }
        do { try checkCurrent() }
        catch {
            let error = (error as? SyntheticABError) ?? .policy
            failure = error; throw error
        }
    }
    private func checkCurrent() throws {
        try communicationCheck(); try env.refresh()
        try abNeed(!env.cancelled,.cancelled)
        do { try lease.check() } catch { throw SyntheticABError.lifecycle }
        try abNeed(env.sessionID == sessionID && env.sessionGeneration == sessionGeneration && env.sessionExpiresUTCMS == sessionExpiry,.sessionChanged)
        try abNeed(env.bootID == bootID && env.bootGeneration == bootGeneration,.bootChanged)
        try abNeed(env.utcMS >= lastUTC && env.monoMS >= lastMono,.clockBackward)
        try abInteger(env.utcMS); try abInteger(env.monoMS)
        try abNeed(env.utcMS < env.sessionExpiresUTCMS,.sessionExpired)
        try abNeed(env.utcMS < timing.expiresUTCMS,.expired)
        try abNeed(env.monoMS-first < timing.totalMS,.totalTimeout)
        if env.clock != nil {
            for (start,limit,error) in [(requestStart,timing.requestMS,SyntheticABError.requestTimeout),(passStart,timing.passMS,.passTimeout),(interpassStart,timing.interpassMS,.interpassTimeout),(preApplyStart,timing.preApplyMS,.preApplyTimeout),(localStart,timing.localApplyMS,.localProbeTimeout)] {
                if let start { try abNeed(env.monoMS-start < limit,error) }
            }
        }
        lastUTC = env.utcMS; lastMono = env.monoMS
    }
}
struct SyntheticABCompletion {
    private let guardState: SyntheticABGuard
    private let report: SyntheticABReport
    fileprivate init(guardState: SyntheticABGuard,http: Int,auth: Int) { self.guardState = guardState; report = .init(http_reserved:http,auth_reserved:auth) }
    func checkedReport() throws -> SyntheticABReport { try guardState.check(); return report }
    func requireApplyInput() throws { throw SyntheticABError.unverified }
}

final class SyntheticABRunner {
    let expected: SyntheticABExpected, timing: SyntheticABTiming, runID: String, binding: String
    let reviewed: ReceiveReviewedExecution?
    init(expected: SyntheticABExpected,timing: SyntheticABTiming,runID: String) throws {
        try timing.validate()
        let prefix = "synthetic-ab-"
        try abNeed(runID.hasPrefix(prefix) && UUID(uuidString:String(runID.dropFirst(prefix.count)))?.uuidString.lowercased() == String(runID.dropFirst(prefix.count)),.policy)
        try abNeed(expected.reviewedTarget == nil,.policy)
        reviewed = nil; self.expected = expected; self.timing = timing; self.runID = runID
        binding = try Self.configuration(expectedBinding:expected.binding,account:expected.account,project:expected.project,timing:timing,runID:runID)
    }
    init(reviewed:ReceiveReviewedExecution) throws {
        self.reviewed = reviewed;expected = try .reviewedComparison(reviewed.target);timing = reviewed.timing
        runID = "synthetic-ab-"+reviewed.journalBinding.runID
        binding = try Self.configuration(expectedBinding:reviewed.journalBinding.digest,account:expected.account,project:expected.project,timing:timing,runID:runID)
    }
    static func configuration(expectedBinding:String,account:String,project:String,timing:SyntheticABTiming,runID:String) throws -> String {
        let timingJSON = try WindowsJSON.decode(canonical(timing))
        return byteHash(WindowsJSON.object(["fixture":.string(expectedBinding),"account":.string(account),"project":.string(project),"project_state_field":.string("trashed_at"),"timing":timingJSON,"run_id":.string(runID)]).encoded(lf:true))
    }
    func request(_ ordinal:Int) throws -> SyntheticABRequest { try Self.request(ordinal,project:expected.project) }
    static func request(_ ordinal: Int,project:String) throws -> SyntheticABRequest {
        try abNeed((0..<14).contains(ordinal),.quota)
        let n = ordinal%7, paths = ["/auth/v1/user","/rest/v1/rpc/get_sync_handshake"]+WindowsHandoffReader.tables.map { "/rest/v1/"+$0 }
        let body = n == 1 ? WindowsJSON.object(["p_project_id":.string(project),"p_contract_sha256":.string(WindowsHandoffReader.contractSHA)]).encoded(lf:true) : Data()
        return .init(phase:ordinal < 7 ? "A" : "B",requestIndex:n+1,method:n == 1 ? "POST" : "GET",path:paths[n],query:n >= 2 ? ["project_id":"eq."+project,"select":"*","limit":"10000"] : [:],headers:n >= 2 ? ["Prefer":"count=exact"] : [:],bodySHA256:byteHash(body))
    }
    func run(transport: any SyntheticABTransporting,journal: SyntheticABJournal,environment env: SyntheticABEnvironment,delays: SyntheticABDelays = .init()) throws -> SyntheticABCompletion {
        try timing.validate(); try delays.validate()
        if let reviewed {
            if let native = transport as? ReceiveNativeABTransport { try native.requireReviewed(reviewed) }
            else { try abNeed(transport is SyntheticABTransport,.policy) }
            try reviewed.check(env)
        }
        for response in transport.responses { try abInteger(response.delayMS); try abInteger(response.persistenceMS) }
        try abNeed(transport.calls.isEmpty,.transportReuse); try transport.checkCancellation()
        let guardState = try SyntheticABGuard(env,timing,communicationCheck:{ try transport.checkCancellation();try self.reviewed?.check(env) })
        try journal.acquireExecution(); defer { journal.releaseExecution() }
        var claimed = false
        do {
            try abNeed(!journal.poisoned,.journalPoisoned)
            var state = try journal.read(); try journal.requireFreshDisk(); try abNeed(state == SyntheticABJournalState(),.runReuse)
            try guardState.check()
            state.runID = runID; state.context = guardState.executionContext(configurationBinding:binding,fixtureBinding:reviewed?.journalBinding.digest ?? expected.binding); state.context?.reviewed = reviewed?.journalBinding; state.binding = state.context!.journalBinding; state.status = "running"
            try journal.write(state,operation:"claim"); claimed = true; try guardState.check()
            var firstPass: Data?, totalBytes = 0, lastResponse = env.monoMS
            for pass in 0..<2 {
                if pass == 1 {
                    try env.advance(delays.interpassMS); try env.apply(delays.interpassEffect); try guardState.check()
                    try abNeed(env.monoMS-lastResponse < timing.interpassMS,.interpassTimeout)
                }
                let passStart = env.monoMS; guardState.passStart = passStart; var values: [WindowsJSON] = []
                for n in 0..<7 {
                    try guardState.check(); try abNeed(env.monoMS-passStart < timing.passMS,.passTimeout)
                    let ordinal = pass*7+n, req = try request(ordinal), requestStart = env.monoMS
                    guardState.requestStart = requestStart
                    try abNeed(state.httpUsed < 14 && (n != 0 || state.authUsed < 2),.quota)
                    state.httpUsed += 1; if n == 0 { state.authUsed += 1 }
                    state.events.append(.init(request:req,reservationID:runID+":\(ordinal+1)",phase:req.phase,reservedUTCMS:env.utcMS,reservedMonoMS:env.monoMS))
                    try journal.write(state,operation:"reserve:\(ordinal+1)")
                    try env.advance(delays.reservationMS); try env.apply(delays.reservationEffect); try guardState.check()
                    try abNeed(env.monoMS-requestStart < timing.requestMS,.requestTimeout)
                    try abNeed(env.monoMS-passStart < timing.passMS,.passTimeout)
                    state.events[ordinal].startedUTCMS = env.utcMS; state.events[ordinal].startedMonoMS = env.monoMS
                    // Persist attempt start too: a lost reply must not erase the attempt timestamp.
                    try journal.write(state,operation:"start:\(ordinal+1)"); try guardState.check()
                    let response = try transport.take(req,journal:journal,environment:env,check:{ try guardState.check(); if ordinal == 7 { guardState.interpassStart = nil } })
                    if ordinal == 7 { guardState.interpassStart = nil }
                    try guardState.check(); lastResponse = env.monoMS
                    try abNeed(env.monoMS-requestStart < timing.requestMS,.requestTimeout)
                    try abNeed(response.raw.count <= timing.maxResponseBytes,.responseSize)
                    totalBytes = try abAdd(totalBytes,response.raw.count); try abNeed(totalBytes <= timing.maxRunBytes,.runSize)
                    state.events[ordinal].receivedUTCMS = env.utcMS; state.events[ordinal].receivedMonoMS = env.monoMS
                    state.events[ordinal].status = response.status; state.events[ordinal].sha256 = byteHash(response.raw); state.events[ordinal].byteCount = response.raw.count
                    // Bounded safe metadata is durable in the double before semantic validation.
                    try journal.write(state,operation:"metadata:\(ordinal+1)")
                    let parsed = try expected.validateResponse(n,response)
                    state.events[ordinal].raw = response.raw; state.events[ordinal].contentRange = response.contentRange
                    if n >= 2 { state.events[ordinal].rowCount = try parsed.array().count }
                    try env.advance(response.persistenceMS); try env.apply(response.persistenceEffect); try guardState.check()
                    try abNeed(env.monoMS-requestStart < timing.requestMS,.requestTimeout)
                    try abNeed(env.monoMS-passStart < timing.passMS,.passTimeout)
                    state.events[ordinal].verifiedUTCMS = env.utcMS; state.events[ordinal].verifiedMonoMS = env.monoMS
                    try journal.write(state,operation:"response:\(ordinal+1)"); try guardState.check(); guardState.requestStart = nil; values.append(parsed)
                }
                let comparable = try expected.validatePass(values)
                try guardState.check(); try abNeed(env.monoMS-passStart < timing.passMS,.passTimeout)
                if pass == 0 { firstPass = comparable; guardState.interpassStart = lastResponse }
                else {
                    try env.advance(delays.comparisonMS); try env.apply(delays.comparisonEffect); try guardState.check()
                    try abNeed(comparable == firstPass,.abChanged)
                }
                guardState.passStart = nil
            }
            guardState.preApplyStart = lastResponse
            try env.advance(delays.preApplyMS); try env.apply(delays.preApplyEffect); try guardState.check()
            try abNeed(env.monoMS-lastResponse < timing.preApplyMS,.preApplyTimeout)
            let localStart = env.monoMS
            guardState.localStart = localStart
            state.events.append(.init(phase:"local_policy_probe",startedUTCMS:env.utcMS,startedMonoMS:env.monoMS))
            try journal.write(state,operation:"local_start"); try guardState.check(); guardState.preApplyStart = nil
            try env.advance(delays.localApplyMS); try env.apply(delays.localEffect); try guardState.check()
            try abNeed(env.monoMS-localStart < timing.localApplyMS,.localProbeTimeout)
            state.events[state.events.count-1].completedUTCMS = env.utcMS; state.events[state.events.count-1].completedMonoMS = env.monoMS
            state.status = "finished"; try journal.write(state,operation:"finish")
            try env.apply(delays.finishEffect); try guardState.check()
            return .init(guardState:guardState,http:state.httpUsed,auth:state.authUsed)
        } catch {
            // Always stop from the last read-back snapshot. Never refund or infer pending writes.
            if claimed, var persisted = try? journal.read(), persisted.runID == runID && persisted.status == "running" {
                persisted.status = "stopped"; try? journal.write(persisted,operation:"stop")
            }
            if let known = error as? SyntheticABError { throw known }
            throw SyntheticABError.contract
        }
    }
}
