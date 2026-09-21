import Foundation
import Darwin

// Separate from the existing synthetic runner. Imported context JSON cannot construct authority.
final class ReceiveAuthorizedRun:ReceiveAppJob,@unchecked Sendable {
    struct Event:Codable {
        let ordinal:Int, reserved:ABRunStamp
        var started:ABRunStamp?,received:ABRunStamp?,verified:ABRunStamp?
        var status:Int?,range:String?,raw:Data?,sha256:String?,rows:Int?
    }
    struct Ledger:Codable {
        let kind:String,context:ReceiveReviewedJournalBinding,authorityDigest:String,timing:SyntheticABTiming,start:ABRunStamp
        var approvalDigest:String?
        var status="prepared",httpUsed=0,authUsed=0,events:[Event]=[]
    }
    private let environment:ReceiveDedicatedEnvironment,target:ReviewedReceiveTarget,httpTarget:ReceiveHTTPTarget
    private let journalRoot:URL,offlineProtocol:AnyClass?,grant:ReceiveActivationAuthority
    private let stateLock=NSLock()
    private let started:ABRuntimeClock.Sample
    private var used=false,connection:ReceiveHTTPConnection?
    var checkpoint:(String)throws->Void={_ in}
    init(environment:ReceiveDedicatedEnvironment,target:ReviewedReceiveTarget,httpTarget:ReceiveHTTPTarget,journalRoot:URL,offlineProtocol:AnyClass?=nil,startedAt:ABRuntimeClock.Sample?=nil) throws {
        let now=try environment.clock.sample()
        started=startedAt ?? now
        try abInteger(started.utcMS);try abInteger(started.monoMS)
        try connectionNeed(started.utcMS<=now.utcMS && started.monoMS<=now.monoMS,.clock)
        guard let grant=environment.authority else{throw ReceiveConnectionError.closed}
        try environment.check(.cachedSession);try environment.check(.httpRead);try grant.requireTarget(httpTarget)
        try connectionNeed(grant.binding.handoffSHA256==target.review.handoff_sha256 && grant.binding.targetSHA256==target.targetSHA256 && grant.binding.sourceRun==target.sourceRun && grant.binding.account==target.binding.str("account_id") && grant.binding.project==target.binding.str("project_id") && grant.binding.endpoint==target.binding.str("endpoint"),.invalidTarget)
        try connectionNeed(grant.rehearsal ? offlineProtocol != nil:offlineProtocol == nil,.closed)
        try grant.timing.validate();try environment.validatePaths()
        try Self.validateJournal(journalRoot,environment:environment)
        self.environment=environment;self.target=target;self.httpTarget=httpTarget;self.journalRoot=journalRoot;self.offlineProtocol=offlineProtocol;self.grant=grant
    }
    static func validateJournal(_ url:URL,environment:ReceiveDedicatedEnvironment) throws {
        try SafeFiles.checked(url)
        guard let grant=environment.authority else{throw ReceiveConnectionError.closed}
        if grant.rehearsal {
            let prefix="ReceiveAuthorizedJournal-"
            try require([try SafeFiles.temporaryPath(),"/private/tmp"].contains(url.deletingLastPathComponent().path) && url.lastPathComponent.hasPrefix(prefix) && UUID(uuidString:String(url.lastPathComponent.dropFirst(prefix.count))) != nil,.path)
        } else {
            try require(url.path==environment.paths.root.deletingLastPathComponent().appendingPathComponent("execution-"+grant.binding.runID).path,.path)
        }
        try require(url.path != environment.paths.root.path && !url.path.hasPrefix(environment.paths.root.path+"/"),.path)
    }
    func cancel(){grant.revoke();stateLock.lock();let c=connection;stateLock.unlock();c?.cancel()}
    private func claim() throws {stateLock.lock();defer{stateLock.unlock()};try require(!used,.incomplete);used=true}
    private func attach(_ c:ReceiveHTTPConnection){stateLock.lock();connection=c;stateLock.unlock()}
    func run() async throws -> any ReceiveAppReceipt {
        do {
        let completion=try await collect()
        // A read-only grant returns evidence; a separate storage scope is required to write.
        guard grant.permitsStorage else{return completion}
        return try await Task.detached{[environment] in
            let store=try environment.prepare(proof:completion.proof());try store.apply();return store
        }.value
        }catch{cancel();throw error}
    }
    func collect() async throws -> ReceiveAuthorizedCompletion {
        try claim()
        return try await withTaskCancellationHandler(operation:{
            do{return try await perform()}catch{cancel();throw error}
        },onCancel:{self.cancel()})
    }
    private func perform() async throws -> ReceiveAuthorizedCompletion {
        // Total begins before cached-session access and all journal/container IO.
        let guardState=try ReceiveRunGuard(environment:environment,start:started)
        try Self.validateJournal(journalRoot,environment:environment)
        let journal=try ReceiveAuthorizedJournal(root:journalRoot,access:environment.protection,check:guardState.check)
        var ledger=Ledger(kind:"ipad-authorized-ab-ledger-v1",context:grant.binding,authorityDigest:grant.contextDigest,timing:grant.timing,start:.init(utcMS:started.utcMS,monoMS:started.monoMS),approvalDigest:grant.approvalDigest)
        try journal.write(ledger)
        let session=try environment.source.capture(account:grant.account,clock:environment.clock)
        try session.requireContext(account:grant.account,epoch:grant.binding.sessionEpoch,expiresUTCMS:grant.binding.sessionExpiresUTCMS)
        let capturedAccount=grant.account,capturedBinding=grant.binding
        guardState.sessionCheck={try session.requireContext(account:capturedAccount,epoch:capturedBinding.sessionEpoch,expiresUTCMS:capturedBinding.sessionExpiresUTCMS)}
        let c=try environment.connection(target:httpTarget,offlineProtocol:offlineProtocol,additionalCheck:guardState.check);attach(c)
        let expected=try SyntheticABExpected.reviewedComparison(target)
        var passes:[[WindowsJSON]]=[[],[]],totalBytes=0,passStart=0,lastResponse=0,passA:Data?
        for ordinal in 0..<14 {
            try guardState.check()
            let reserved=try guardState.stamp()
            if ordinal%7==0 {
                if ordinal==7 {try abNeed(reserved.monoMS-lastResponse < grant.timing.interpassMS,.interpassTimeout)}
                passStart=reserved.monoMS
            }
            guardState.requestDeadline=try abAdd(reserved.monoMS,grant.timing.requestMS);guardState.passDeadline=try abAdd(passStart,grant.timing.passMS)
            try abNeed(ledger.httpUsed<14 && (ordinal%7 != 0 || ledger.authUsed<2),.quota)
            ledger.httpUsed+=1;if ordinal%7==0{ledger.authUsed+=1}
            ledger.status="running";ledger.events.append(.init(ordinal:ordinal,reserved:reserved))
            try journal.write(ledger);try checkpoint("reserved:\(ordinal)");try guardState.check()
            ledger.events[ordinal].started=try guardState.stamp()
            try journal.write(ledger)
            func limits() throws {
                let stamp=try guardState.stamp()
                try abNeed(stamp.monoMS-reserved.monoMS < grant.timing.requestMS,.requestTimeout)
                try abNeed(stamp.monoMS-passStart < grant.timing.passMS,.passTimeout)
                if ordinal==7 {try abNeed(stamp.monoMS-lastResponse < grant.timing.interpassMS,.interpassTimeout)}
            }
            try limits()
            let remaining=try min(grant.timing.requestMS-(guardState.stamp().monoMS-reserved.monoMS),grant.timing.passMS-(guardState.stamp().monoMS-passStart),grant.timing.totalMS-(guardState.stamp().monoMS-started.monoMS))
            let response=try await c.send(ordinal:ordinal,timeoutMS:remaining,expiresUTCMS:grant.timing.expiresUTCMS,maxBytes:grant.timing.maxResponseBytes,reserveAndStart:{try limits();try journal.verify(ledger)})
            let received=try guardState.stamp();lastResponse=received.monoMS
            ledger.events[ordinal].received=received;ledger.events[ordinal].status=response.status;ledger.events[ordinal].range=response.contentRange;ledger.events[ordinal].raw=response.bytes;ledger.events[ordinal].sha256=byteHash(response.bytes)
            try journal.write(ledger);try checkpoint("response:\(ordinal)")
            totalBytes=try abAdd(totalBytes,response.bytes.count);try abNeed(totalBytes<=grant.timing.maxRunBytes,.runSize)
            let value=try expected.validateResponse(ordinal%7,.init(raw:response.bytes,status:response.status,contentRange:response.contentRange,delayMS:0))
            if ordinal%7>=2{ledger.events[ordinal].rows=try value.array().count}
            passes[ordinal/7].append(value)
            if ordinal%7==6 {
                let comparison=try expected.validatePass(passes[ordinal/7])
                if ordinal==6{passA=comparison}else{try abNeed(comparison==passA,.abChanged)}
            }
            ledger.events[ordinal].verified=try guardState.stamp()
            try journal.write(ledger);try limits()
            guardState.requestDeadline=nil;if ordinal%7==6{guardState.passDeadline=nil}
        }
        guardState.lastResponse=lastResponse
        let parts=try ReceiveAdmissionPlan.memberParts(target:target,values:passes[1])
        _ = try ReceiveProductProjection(parts:parts,local:environment.local,project:grant.project,account:grant.account)
        try guardState.check();ledger.status="finished";try journal.write(ledger)
        try journal.verify(ledger);try guardState.check()
        return ReceiveAuthorizedCompletion(journal:journal,ledger:ledger,parts:parts,guardState:guardState,environment:environment)
    }
}

struct ABRunStamp:Codable {let utcMS:Int,monoMS:Int}

final class ReceiveRunGuard {
    let environment:ReceiveDedicatedEnvironment,start:ABRuntimeClock.Sample
    private let lock=NSRecursiveLock()
    private var last:ABRuntimeClock.Sample,failed=false,localStart:Int?
    private var lastResponseValue:Int?,requestValue:Int?,passValue:Int?
    var lastResponse:Int? {get{lock.lock();defer{lock.unlock()};return lastResponseValue}set{lock.lock();lastResponseValue=newValue;lock.unlock()}}
    var requestDeadline:Int? {get{lock.lock();defer{lock.unlock()};return requestValue}set{lock.lock();requestValue=newValue;lock.unlock()}}
    var passDeadline:Int? {get{lock.lock();defer{lock.unlock()};return passValue}set{lock.lock();passValue=newValue;lock.unlock()}}
    var sessionCheck:()throws->Void={}
    init(environment:ReceiveDedicatedEnvironment,start:ABRuntimeClock.Sample) throws {self.environment=environment;self.start=start;last=start;try check()}
    func check() throws {
        lock.lock();defer{lock.unlock()}
        try abNeed(!failed,.cancelled)
        do {
            try environment.check(.cachedSession);try sessionCheck()
            guard let g=environment.authority else{throw ReceiveConnectionError.closed}
            let now=try environment.clock.sample(),t=g.timing
            try abNeed(now.utcMS>=last.utcMS && now.monoMS>=last.monoMS,.clockBackward);last=now
            try abNeed(now.monoMS-start.monoMS<t.totalMS,.totalTimeout)
            if let requestDeadline{try abNeed(now.monoMS<requestDeadline,.requestTimeout)}
            if let passDeadline{try abNeed(now.monoMS<passDeadline,.passTimeout)}
            if let localStart {try abNeed(now.monoMS-localStart<t.localApplyMS,.localProbeTimeout)}
            else if let lastResponse {try abNeed(now.monoMS-lastResponse<t.preApplyMS,.preApplyTimeout)}
        }catch{failed=true;throw error}
    }
    func stamp() throws -> ABRunStamp {try check();let value=try environment.clock.sample();return .init(utcMS:value.utcMS,monoMS:value.monoMS)}
    func beginLocal() throws {lock.lock();defer{lock.unlock()};try check();try require(localStart==nil,.incomplete);localStart=try environment.clock.sample().monoMS}
}

// Whole-run lock and write/readback journal. Existing or partial roots cannot be adopted.
final class ReceiveAuthorizedJournal {
    let root:URL
    private var fd:Int32 = -1
    private var lastBytes:Data?
    private let access:PhysicalStorageAccess,check:()throws->Void
    init(root:URL,access:PhysicalStorageAccess,check:@escaping ()throws->Void) throws {
        self.root=root;self.access=access;self.check=check;try check();try SafeFiles.checked(root)
        try ReceiveDedicatedPaths.prepareEmptyRoot(root,access:access,check:check)
        fd=open(root.appendingPathComponent("run.lock").path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else{if fd>=0{close(fd)};fd = -1;throw ReceiveError.busy}
        do{try access.created(root.appendingPathComponent("run.lock"));try access.verify(root.appendingPathComponent("run.lock"));try check()}catch{close(fd);fd = -1;throw error}
    }
    deinit{if fd>=0{flock(fd,LOCK_UN);close(fd)}}
    private func validate() throws {
        try check();try SafeFiles.checked(root);try access.verify(root)
        let names=Set(try FileManager.default.contentsOfDirectory(atPath:root.path))
        try require(names.isSubset(of:["run.lock","run.json"]) && names.contains("run.lock"),.incomplete)
        var held=stat()
        guard fstat(fd,&held)==0,let current=try SafeFiles.attributes(root.appendingPathComponent("run.lock")),held.st_ino==current.st_ino,held.st_dev==current.st_dev,current.st_nlink==1 else{throw ReceiveError.path}
    }
    func write(_ value:ReceiveAuthorizedRun.Ledger) throws {
        try validate();let bytes=try canonical(value),url=root.appendingPathComponent("run.json")
        if let lastBytes{try require(SafeFiles.read(url,limit:64*1024*1024)==lastBytes,.corrupt)}
        else{try require(SafeFiles.attributes(url)==nil,.existingData)}
        try SafeFiles.write(bytes,to:root.appendingPathComponent("run.json"),prepareFile:{u in try self.check();try self.access.created(u);try self.access.verify(u)},checkpoint:{_ in try self.check()})
        try verify(value);lastBytes=bytes
    }
    func verify(_ value:ReceiveAuthorizedRun.Ledger) throws {
        try validate();let url=root.appendingPathComponent("run.json");try access.verify(url)
        try require(SafeFiles.read(url,limit:64*1024*1024)==canonical(value),.corrupt);try check()
    }
}

final class ReceiveAuthorizedCompletion:ReceiveAppReceipt,@unchecked Sendable {
    private let journal:ReceiveAuthorizedJournal,ledger:ReceiveAuthorizedRun.Ledger,parts:[LocalStoragePart:Data],guardState:ReceiveRunGuard,environment:ReceiveDedicatedEnvironment
    fileprivate init(journal:ReceiveAuthorizedJournal,ledger:ReceiveAuthorizedRun.Ledger,parts:[LocalStoragePart:Data],guardState:ReceiveRunGuard,environment:ReceiveDedicatedEnvironment) {
        self.journal=journal;self.ledger=ledger;self.parts=parts;self.guardState=guardState;self.environment=environment
    }
    func verify() async throws {try verifyNow()}
    func verifyNow() throws {try guardState.check();try journal.verify(ledger)}
    func checkPublication() throws {try guardState.check()}
    func proof() throws -> ReceiveProductProof {
        try environment.check(.productStorage);try verifyNow()
        return try .authorized(context:ledger.context,timing:ledger.timing,parts:parts,journalHash:byteHash(canonical(ledger)),clock:environment.clock,lastResponse:ledger.events.last!.received!.monoMS,
                               check:guardState.check,verify:verifyNow,beginLocal:guardState.beginLocal,grant:environment.authority!)
    }
    var counts:(http:Int,auth:Int){(ledger.httpUsed,ledger.authUsed)}
    func requireBaseline() throws {throw ReceiveConnectionError.closed}
}

// Nonserializable bridge: only a checked old admission or this run's sealed completion can create it.
final class ReceiveProductProof {
    let context:ReceiveReviewedJournalBinding,contextTiming:SyntheticABTiming,parts:[LocalStoragePart:Data],digest:String,resultDigest:String,clock:ABRuntimeClock,lastResponseMonoMS:Int
    let check:()throws->Void,verify:()throws->Void,beginLocal:()throws->Void
    let grant:ReceiveActivationAuthority?
    private init(context:ReceiveReviewedJournalBinding,timing:SyntheticABTiming,parts:[LocalStoragePart:Data],journalHash:String,clock:ABRuntimeClock,lastResponse:Int,check:@escaping ()throws->Void,verify:@escaping ()throws->Void,beginLocal:@escaping ()throws->Void,grant:ReceiveActivationAuthority?=nil) throws {
        self.grant=grant;self.context=context;contextTiming=timing;self.parts=parts;self.clock=clock;lastResponseMonoMS=lastResponse;self.check=check;self.verify=verify;self.beginLocal=beginLocal
        resultDigest=byteHash(try canonical(LocalStoragePart.allCases.map{DigestEntry(path:$0.rawValue,bytes:parts[$0]!.count,sha256:byteHash(parts[$0]!))}.sorted{$0.path<$1.path}))
        digest=byteHash(try canonical(["context":context.digest,"projection":resultDigest,"journal":journalHash]))
    }
    static func offline(_ plan:ReceiveAdmissionPlan) throws -> ReceiveProductProof {
        try plan.verify()
        return try .init(context:plan.context,timing:plan.contextTiming,parts:plan.parts,journalHash:plan.journalSHA256,clock:plan.clock,lastResponse:plan.lastResponseMonoMS,check:plan.check,verify:plan.verify,beginLocal:{})
    }
    fileprivate static func authorized(context:ReceiveReviewedJournalBinding,timing:SyntheticABTiming,parts:[LocalStoragePart:Data],journalHash:String,clock:ABRuntimeClock,lastResponse:Int,check:@escaping ()throws->Void,verify:@escaping ()throws->Void,beginLocal:@escaping ()throws->Void,grant:ReceiveActivationAuthority) throws -> ReceiveProductProof {
        try .init(context:context,timing:timing,parts:parts,journalHash:journalHash,clock:clock,lastResponse:lastResponse,check:check,verify:verify,beginLocal:beginLocal,grant:grant)
    }
}
