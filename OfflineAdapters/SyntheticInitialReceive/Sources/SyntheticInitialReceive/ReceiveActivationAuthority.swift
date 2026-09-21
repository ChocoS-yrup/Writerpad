import Foundation

// The application must explicitly call the trusted confirmation entry; no JSON decoder, default
// authority, Keychain read, login, identity generator, UI action or startup hook exists here.
final class ReceiveActivationAuthority {
    enum Scope: String, Hashable { case cachedSession, httpRead, productStorage }
    private let scopes:Set<Scope>, validate:() throws -> Void
    private let lock=NSLock()
    private var revoked=false, httpClaimed=false, storageClaimed=false
    private var last:ABRuntimeClock.Sample?
    private let clock:ABRuntimeClock
    let rehearsal:Bool, endpoint:String, account:UUID, project:UUID, contextDigest:String
    let binding:ReceiveReviewedJournalBinding,timing:SyntheticABTiming
    let approvalDigest:String?
    private init(scopes:Set<Scope>,rehearsal:Bool,endpoint:String,account:UUID,project:UUID,contextDigest:String,binding:ReceiveReviewedJournalBinding,timing:SyntheticABTiming,clock:ABRuntimeClock,approvalDigest:String?=nil,validate:@escaping () throws -> Void) {
        self.approvalDigest=approvalDigest
        self.binding=binding;self.timing=timing;self.scopes=scopes;self.rehearsal=rehearsal;self.endpoint=endpoint;self.account=account;self.project=project;self.contextDigest=contextDigest;self.validate=validate;self.clock=clock
    }
    static func offline(execution:ReceiveReviewedExecution,scopes:Set<Scope>,clock:ABRuntimeClock,approvalDigest:String?=nil,readRuntime:@escaping () throws -> ReceiveExecutionCandidate.RuntimeSnapshot) throws -> ReceiveActivationAuthority {
        try execution.journalBinding.validate()
        let b=execution.journalBinding
        let check:() throws -> Void = {
            let now=try clock.sample(),r=try readRuntime()
            try connectionNeed(r.account.uuidString.lowercased()==b.account && r.localProjectID.uuidString.lowercased()==b.localProjectID && r.bundleID==b.bundleID && r.bootID==b.bootID && r.sessionEpoch==b.sessionEpoch && r.sessionExpiresUTCMS==b.sessionExpiresUTCMS,.changedSession)
            try connectionNeed(now.utcMS >= execution.timing.notBeforeUTCMS && now.utcMS < execution.timing.expiresUTCMS && now.utcMS < r.sessionExpiresUTCMS,.expired)
        }
        try check()
        let digest=approvalDigest.map{byteHash(Data((b.digest+"|"+$0).utf8))} ?? b.digest
        return .init(scopes:scopes,rehearsal:true,endpoint:"https://receive-boundary.invalid",account:UUID(uuidString:b.account)!,project:UUID(uuidString:b.project)!,contextDigest:digest,binding:b,timing:execution.timing,clock:clock,approvalDigest:approvalDigest,validate:check)
    }
    // Called by the trusted app review ticket path; no default configuration is installed.
    // Runtime metadata is checked again on every use. Imported files cannot call this boundary.
    static func afterExplicitUserConfirmation(target:ReviewedReceiveTarget,draft:ReceiveExecutionCandidate.Draft,scopes:Set<Scope>,clock:ABRuntimeClock,approvalDigest:String?=nil,readRuntime:@escaping () throws -> ReceiveExecutionCandidate.RuntimeSnapshot) throws -> ReceiveActivationAuthority {
        try connectionNeed(clock.isSystem,.closed)
        let first=try readRuntime(),now=try clock.sample()
        let c=try ReceiveExecutionCandidate.compare(draft,to:target,now:now,runtime:first)
        try connectionNeed(c.local_fields_matched && draft.endpoint != "https://synthetic.invalid" && draft.endpoint != "https://receive-boundary.invalid",.closed)
        let expiry=first.sessionExpiresUTCMS
        let check:() throws -> Void = {
            let r=try readRuntime(),c=try ReceiveExecutionCandidate.compare(draft,to:target,now:clock.sample(),runtime:r)
            try connectionNeed(c.local_fields_matched && r.sessionExpiresUTCMS==expiry,.changedSession)
        }
        struct Binding:Encodable {let endpoint:String,account:UUID,project:UUID,bundle:String,expiry:Int,scopes:[String],run:String,local:String,source:String,handoff:String,target:String,boot:String,epoch:Int,timing:SyntheticABTiming}
        let binding=Binding(endpoint:draft.endpoint!,account:draft.account!,project:draft.project!,bundle:draft.bundleID!,expiry:expiry,scopes:scopes.map(\.rawValue).sorted(),run:draft.runID!.uuidString.lowercased(),local:draft.localProjectID!.uuidString.lowercased(),source:target.sourceRun,handoff:target.review.handoff_sha256,target:target.targetSHA256,boot:draft.bootID!,epoch:draft.sessionEpoch!,timing:draft.timing!)
        let record=ReceiveReviewedJournalBinding(mode:"authorized-live-v1",endpoint:draft.endpoint!,account:draft.account!.uuidString.lowercased(),project:draft.project!.uuidString.lowercased(),sourceRun:target.sourceRun,handoffSHA256:draft.handoffSHA256!,targetSHA256:draft.targetSHA256!,runID:draft.runID!.uuidString.lowercased(),localProjectID:draft.localProjectID!.uuidString.lowercased(),bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:draft.sessionEpoch!,sessionExpiresUTCMS:expiry,httpLimit:draft.httpLimit!,authLimit:draft.authLimit!)
        let bindingBytes=try canonical(binding)
        let digest=approvalDigest.map{byteHash(bindingBytes+Data(("|"+$0).utf8))} ?? byteHash(bindingBytes)
        return .init(scopes:scopes,rehearsal:false,endpoint:draft.endpoint!,account:draft.account!,project:draft.project!,contextDigest:digest,binding:record,timing:draft.timing!,clock:clock,approvalDigest:approvalDigest,validate:check)
    }
    func usesClock(_ candidate:ABRuntimeClock)->Bool {candidate === clock}
    var permitsStorage:Bool {scopes.contains(.productStorage)}
    func require(_ scope:Scope) throws {
        lock.lock();defer{lock.unlock()}
        try connectionNeed(!revoked && scopes.contains(scope),.closed)
        do {
            let now=try clock.sample()
            if let last {try connectionNeed(now.utcMS>=last.utcMS && now.monoMS>=last.monoMS,.clock)}
            try validate();last=now
        }catch{revoked=true;throw error}
    }
    func requireTarget(_ t:ReceiveHTTPTarget) throws {
        try require(.httpRead)
        try connectionNeed(t.origin.absoluteString==endpoint && t.account==account && t.project==project,.invalidTarget)
    }
    func claim(_ scope:Scope) throws {
        try require(scope);lock.lock();defer{lock.unlock()}
        try connectionNeed(!revoked,.closed)
        switch scope {
        case .httpRead:try connectionNeed(!httpClaimed,.reused);httpClaimed=true
        case .productStorage:try connectionNeed(!storageClaimed,.reused);storageClaimed=true
        case .cachedSession:throw ReceiveConnectionError.closed
        }
    }
    func revoke(){lock.lock();revoked=true;lock.unlock()}
}
