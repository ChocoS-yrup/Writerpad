import Foundation
import Darwin

// iPad-local adoption contract. This does not rename/finalize the Windows wire artifact.
enum ReceiveInputContract {
    static let version = "ipad-isolated-input-admission-v1"
    struct Comparison: Encodable {
        let contract = ReceiveInputContract.version
        let source_run: String, handoff_sha256: String, target_sha256: String
        let member_ids: [String], unresolved: [String]
        let retained_wire_kind = "windows-isolated-receive-handoff-draft-v1"
        let retained_schema_version = 1
        let retained_schema_finalized = false
        let execution_allowed = false, baseline_ready = false, baseline_applied = false
        let app_binding_created = false, current_server_verified = false
        let remaining_conditions = ["fresh_ab_evidence", "independent_local_binding", "execution_permission", "apply_permission"]
    }
    static func compare(target:ReviewedReceiveTarget,draft:ReceiveExecutionCandidate.Draft,now:ABRuntimeClock.Sample) throws -> Comparison {
        let result = try ReceiveExecutionCandidate.compare(draft,to:target,now:now)
        return .init(source_run:target.sourceRun,handoff_sha256:target.review.handoff_sha256,target_sha256:target.targetSHA256,
                     member_ids:target.entities.filter{$0.role == "members"}.map(\.id).sorted(),unresolved:result.unresolved)
    }
    // No live grant issuer, session reader, container factory or network activation in this version.
    static func requireLiveAdmission() throws { throw ReceiveConnectionError.closed }
}

// Immutable, non-Codable fresh evidence + member projection. Retained-only data cannot construct it.
final class ReceiveAdmissionPlan {
    let context: ReceiveReviewedJournalBinding
    let parts: [LocalStoragePart:Data]
    let digest: String, resultDigest: String
    let journalSHA256: String
    let contextTiming: SyntheticABTiming
    var clock: ABRuntimeClock { completion.clock }
    let lastResponseMonoMS: Int
    private let completion: ReceiveABCompletion
    private init(context:ReceiveReviewedJournalBinding,parts:[LocalStoragePart:Data],journalSHA256:String,lastResponseMonoMS:Int,timing:SyntheticABTiming,completion:ReceiveABCompletion) throws {
        self.context = context; self.parts = parts; self.journalSHA256 = journalSHA256; contextTiming = timing
        self.lastResponseMonoMS = lastResponseMonoMS; self.completion = completion
        resultDigest = byteHash(try canonical(LocalStoragePart.allCases.map {
            DigestEntry(path:$0.rawValue,bytes:parts[$0]!.count,sha256:byteHash(parts[$0]!))
        }.sorted{$0.path < $1.path}))
        digest = byteHash(WindowsJSON.object(["contract":.string(ReceiveInputContract.version),"context":.string(context.digest),
            "journal":.string(journalSHA256),"projection":.string(resultDigest)]).encoded(lf:true))
    }
    static func offline(execution:ReceiveReviewedExecution,completion:ReceiveABCompletion) throws -> ReceiveAdmissionPlan {
        try execution.journalBinding.validate()
        let state = try completion.checkedAdmissionJournal()
        let values = try validateEvidence(state,execution:execution)
        let parts=try memberParts(target:execution.target,values:values)
        let plan = try ReceiveAdmissionPlan(context:execution.journalBinding,parts:parts,journalSHA256:byteHash(canonical(state)),
            lastResponseMonoMS:state.events[13].receivedMonoMS!,timing:execution.timing,completion:completion)
        try plan.check(); return plan
    }
    static func memberParts(target:ReviewedReceiveTarget,values:[WindowsJSON]) throws -> [LocalStoragePart:Data] {
        var rows:[String:WindowsJSON] = [:]
        for (i,kind) in ["document","folder","tree_order"].enumerated() {
            let key = WindowsHandoffReader.kinds[kind]!.1
            for row in try values[i+4].array() { rows[try row.str(key)] = row }
        }
        var bodies:[String:Data] = [:], metadata:[WindowsJSON] = [], documents:[WindowsJSON] = [], folders:[WindowsJSON] = [], orders:[WindowsJSON] = []
        for entity in target.entities.filter({$0.role == "members"}).sorted(by:{$0.id < $1.id}) {
            guard let row = rows[entity.id] else { throw WindowsReaderError.reference }
            switch entity.kind {
            case "document":
                try wrNeed(!row.str("relative_path").hasPrefix("__antigravity__/"),.body)
                let content = try row.get("content")
                guard case let .string(text) = content else { throw WindowsReaderError.body }
                let raw = Data(text.utf8)
                try wrNeed(byteHash(raw) == entity.bodySHA256 && raw.count == entity.bodyBytes,.body)
                bodies[entity.id] = raw
                var fields = try row.object(); fields.removeValue(forKey:"content")
                metadata.append(.object(fields))
                documents.append(.object(["row":.object(fields),"body_sha256":.string(byteHash(raw)),"body_bytes":.number(String(raw.count))]))
            case "folder": metadata.append(row); folders.append(row)
            case "tree_order": orders.append(row)
            default: throw WindowsReaderError.shape
            }
        }
        // Full wire rows retain null, versions, dates, external parent and child references exactly.
        let parts:[LocalStoragePart:Data] = [.bodies:try canonical(bodies),.metadata:WindowsJSON.array(metadata).encoded(lf:true),
            .documentBaseline:WindowsJSON.array(documents).encoded(lf:true),.folderBaseline:WindowsJSON.array(folders).encoded(lf:true),
            .treeOrderBaseline:WindowsJSON.array(orders).encoded(lf:true)]
        return parts
    }
    // Defense-in-depth parser for the checked journal; internal so malformed synthetic records can be tested.
    static func validateEvidence(_ state:SyntheticABJournalState,execution:ReceiveReviewedExecution) throws -> [WindowsJSON] {
        try abNeed(state.status == "finished" && state.httpUsed == 14 && state.authUsed == 2 && state.events.count == 15,.unverified)
        try abNeed(state.context?.reviewed == execution.journalBinding && state.runID == "synthetic-ab-"+execution.journalBinding.runID,.journalCorrupt)
        guard let context = state.context else { throw SyntheticABError.journalCorrupt }
        try abNeed(context.timing == execution.timing,.policy)
        try context.validate(runID:state.runID!)
        let expected = try SyntheticABExpected.reviewedComparison(execution.target)
        try abNeed(state.binding == context.journalBinding && context.startedUTCMS >= context.timing.notBeforeUTCMS,.journalCorrupt)
        var totalBytes=0
        var passes:[[WindowsJSON]] = [[],[]], lastUTC = context.startedUTCMS, lastMono = context.startedMonoMS
        for i in 0..<14 {
            let e = state.events[i]
            try abNeed(e.phase == (i < 7 ? "A" : "B") && e.request == SyntheticABRunner.request(i,project:execution.journalBinding.project) && e.reservationID == state.runID!+":\(i+1)",.reservationRequired)
            guard let ru=e.reservedUTCMS,let rm=e.reservedMonoMS,let su=e.startedUTCMS,let sm=e.startedMonoMS,
                  let du=e.receivedUTCMS,let dm=e.receivedMonoMS,let vu=e.verifiedUTCMS,let vm=e.verifiedMonoMS,
                  let raw=e.raw,let status=e.status else { throw SyntheticABError.unverified }
            for pair in [(ru,rm),(su,sm),(du,dm),(vu,vm)] {
                try abInteger(pair.0); try abInteger(pair.1)
                try abNeed(pair.0 >= lastUTC && pair.1 >= lastMono,.clockBackward)
                try abNeed(pair.0 < context.timing.expiresUTCMS && pair.0 < context.sessionExpiresUTCMS,.expired)
                lastUTC=pair.0;lastMono=pair.1
            }
            try abNeed(vm-rm < context.timing.requestMS && vm-context.startedMonoMS < context.timing.totalMS,.requestTimeout)
            try abNeed(raw.count == e.byteCount && byteHash(raw) == e.sha256 && raw.count <= context.timing.maxResponseBytes,.journalCorrupt)
            totalBytes=try abAdd(totalBytes,raw.count);try abNeed(totalBytes <= context.timing.maxRunBytes,.runSize)
            if i%7 == 6 { try abNeed(vm-state.events[i-6].reservedMonoMS! < context.timing.passMS,.passTimeout) }
            if i == 7 { try abNeed(sm-state.events[6].receivedMonoMS! < context.timing.interpassMS,.interpassTimeout) }
            let value = try expected.validateResponse(i%7,.init(raw:raw,status:status,contentRange:e.contentRange,delayMS:0))
            if i%7 >= 2 { try abNeed(e.rowCount == value.array().count,.count) }
            passes[i/7].append(value)
        }
        let local=state.events[14]
        guard local.phase == "local_policy_probe",local.request == nil,let start=local.startedMonoMS,let end=local.completedMonoMS,
              let startUTC=local.startedUTCMS,let endUTC=local.completedUTCMS else { throw SyntheticABError.unverified }
        try abNeed(start >= lastMono && end >= start && startUTC >= lastUTC && endUTC >= startUTC,.clockBackward)
        try abNeed(start-state.events[13].receivedMonoMS! < context.timing.preApplyMS && end-start < context.timing.localApplyMS,.preApplyTimeout)
        try abNeed(end-context.startedMonoMS < context.timing.totalMS && endUTC < context.timing.expiresUTCMS && endUTC < context.sessionExpiresUTCMS,.expired)
        try abNeed(expected.validatePass(passes[0]) == expected.validatePass(passes[1]),.abChanged)
        return passes[1]
    }
    func check() throws { try completion.checkPublication() }
    func verify() throws {
        try check()
        try abNeed(byteHash(canonical(completion.checkedAdmissionJournal())) == journalSHA256,.journalCorrupt)
        try check()
    }
    func requireBaseline() throws { throw ReceiveConnectionError.closed }
}

// Inert description for a future independent store. This release materializes disposable hosts only.
struct ReceiveLocalStoreDescriptor: Codable, Equatable {
    enum Mode: String, Codable { case offline, live }
    let mode: Mode
    let localProjectID: String, bundleID: String, workspace: String
    func validateOffline(_ context:ReceiveReviewedJournalBinding) throws {
        try connectionNeed(mode == .offline,.closed)
        try abNeed(localProjectID == context.localProjectID && localProjectID.hasPrefix("ee2609") && bundleID == context.bundleID,.policy)
        let url = URL(fileURLWithPath:workspace,isDirectory:true)
        try SafeFiles.checked(url)
        try connectionNeed(url.path == workspace && [try SafeFiles.temporaryPath(),"/private/tmp"].contains(url.deletingLastPathComponent().path),.invalidTarget)
        let prefix = "ReceiveInputAdmission-"
        try connectionNeed(url.lastPathComponent.hasPrefix(prefix) && UUID(uuidString:String(url.lastPathComponent.dropFirst(prefix.count))) != nil,.invalidTarget)
        guard let info=try SafeFiles.attributes(url),info.st_mode & S_IFMT == S_IFDIR else { throw ReceiveError.path }
    }
}

// Explicit offline storage permission, sealed to this plan, run, identity and exact namespace.
// Neither Codable nor a Boolean field in an imported document can mint it.
struct ReceiveOfflineApplyPermit {
    fileprivate let planDigest:String, descriptor:ReceiveLocalStoreDescriptor
    private init(planDigest:String,descriptor:ReceiveLocalStoreDescriptor) { self.planDigest=planDigest;self.descriptor=descriptor }
    static func issue(plan:ReceiveAdmissionPlan,descriptor:ReceiveLocalStoreDescriptor) throws -> Self {
        try descriptor.validateOffline(plan.context);try plan.verify()
        return .init(planDigest:plan.digest,descriptor:descriptor)
    }
}

final class ReceiveAdmissionSession {
    struct Receipt: Encodable {
        let offline_storage_prepared = true
        let contract = ReceiveInputContract.version
        let plan_digest:String, local_project_id:String
        let baseline_ready = false, baseline_applied = false, execution_allowed = false, app_binding_created = false
        let editing_allowed = false, sending_allowed = false, automatic_receive_allowed = false
    }
    private let plan:ReceiveAdmissionPlan, descriptor:ReceiveLocalStoreDescriptor
    private let session:LocalBoundarySession, clock:ABRuntimeClock, checkAccess:() throws -> Void
    private var localStart:Int?
    private let operationLock=NSLock()
    private init(plan:ReceiveAdmissionPlan,descriptor:ReceiveLocalStoreDescriptor,session:LocalBoundarySession,clock:ABRuntimeClock,checkAccess:@escaping () throws -> Void) {
        self.plan=plan;self.descriptor=descriptor;self.session=session;self.clock=clock;self.checkAccess=checkAccess
    }
    static func prepare(plan:ReceiveAdmissionPlan,descriptor:ReceiveLocalStoreDescriptor,permit:ReceiveOfflineApplyPermit?,
                        lease:BoundaryLease,protection:PhysicalStorageAccess,checkpoint:@escaping (String) throws -> Void = {_ in}) throws -> ReceiveAdmissionSession {
        // Fail before any factory or write for live/foreign/unpermitted input.
        try descriptor.validateOffline(plan.context)
        guard let permit,permit.planDigest == plan.digest,permit.descriptor == descriptor else { throw ReceiveConnectionError.closed }
        try lease.check();try plan.verify()
        let workspace=URL(fileURLWithPath:descriptor.workspace,isDirectory:true)
        struct Seal:Codable,Equatable { let kind:String,descriptor:ReceiveLocalStoreDescriptor,planDigest:String }
        let seal=Seal(kind:"offline-receive-input-admission-v1",descriptor:descriptor,planDigest:plan.digest)
        let sealURL=workspace.appendingPathComponent("admission.json"),sealBytes=try canonical(seal)
        let check:() throws -> Void = {try Task.checkCancellation();try lease.check();try plan.check();try protection.check();try lease.check()}
        let validate:() throws -> Void = {
            try check();try descriptor.validateOffline(plan.context);try protection.verify(workspace)
            let names=Set(try FileManager.default.contentsOfDirectory(atPath:workspace.path))
            try connectionNeed(names.contains("admission.json") && names.isSubset(of:["admission.json","physical-boundary","physical-boundary.lock"]),.invalidTarget)
            try protection.verify(sealURL)
            try connectionNeed(SafeFiles.read(sealURL,limit:8192) == sealBytes,.invalidTarget);try check()
        }
        try check()
        let names=try FileManager.default.contentsOfDirectory(atPath:workspace.path)
        if names.isEmpty {
            try protection.created(workspace);try protection.verify(workspace);try check()
            try SafeFiles.write(sealBytes,to:sealURL,prepareFile:{url in try check();try protection.created(url);try protection.verify(url)},checkpoint:{_ in try check()})
        }
        try validate()
        let binding=LocalBoundaryBinding(version:1,declaredBundle:descriptor.bundleID,root:workspace.appendingPathComponent("physical-boundary").path,
            localIdentity:descriptor.localProjectID,sourceIdentity:plan.context.project,fixtureID:"offline-admission:"+plan.context.runID,inputDigest:plan.digest,resultDigest:plan.resultDigest)
        let access=PhysicalStorageAccess(check:check,created:{url in try check();try protection.created(url);try check()},verify:{url in try check();try protection.verify(url);try check()})
        let store=try PhysicalBoundaryStorage(workspace:workspace,binding:binding,checkpoint:checkpoint,validateWorkspace:validate,access:access)
        let session=try LocalBoundarySession.offlineAdmission(plan,binding:binding,store:store)
        return ReceiveAdmissionSession(plan:plan,descriptor:descriptor,session:session,clock:plan.clock,checkAccess:check)
    }
    @discardableResult func applyOffline() throws -> Receipt {
        guard operationLock.try() else { throw ReceiveError.busy };defer {operationLock.unlock()}
        try checkAccess();try plan.verify()
        let now=try clock.sample()
        try abNeed(now.monoMS >= plan.lastResponseMonoMS && now.monoMS-plan.lastResponseMonoMS < plan.contextTiming.preApplyMS,.preApplyTimeout)
        if localStart == nil { localStart=now.monoMS }
        _ = try session.apply()
        try checkAccess();try plan.verify()
        try abNeed(try clock.sample().monoMS-localStart! < plan.contextTiming.localApplyMS,.localProbeTimeout)
        _ = try session.snapshot();try checkAccess()
        return .init(plan_digest:plan.digest,local_project_id:descriptor.localProjectID)
    }
    func snapshot() throws -> [LocalStoragePart:Data] { guard operationLock.try() else {throw ReceiveError.busy};defer{operationLock.unlock()};try checkAccess();try plan.verify();let parts=try session.snapshot();try checkAccess();return parts }
    func requireBaseline() throws { throw ReceiveConnectionError.closed }
}
