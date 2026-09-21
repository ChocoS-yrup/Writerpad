import Foundation
import Darwin

// A prepared, non-secret description from the trusted app composition root. It is neither
// Codable nor accepted by the Windows document importer. No identity is generated here.
struct ReceiveApprovalIdentity: Codable, Equatable {
    let approvalID: String, device: String, installationID: String, candidateSHA256: String
    func validate() throws {
        for text in [approvalID, device, installationID] {
            try connectionNeed(!text.isEmpty && text.utf8.count <= 256 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, .unverified)
        }
        try connectionNeed(candidateSHA256.count == 64 && candidateSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, .unverified)
    }
}

// Explicit providers only. No Keychain/SDK/file lookup, refresh, identity issuance or default key.
// The installation callback must verify the exact prepared identity, not just a bundle string.
struct ReceiveApprovalProviders {
    let readRuntime: () throws -> ReceiveExecutionCandidate.RuntimeSnapshot
    let readPublishableKey: () throws -> String
    let source: ReceiveSessionSource
    let verifyInstallation: (ReceiveApprovalIdentity) throws -> Void
    let verifyIdentity: () throws -> Void
    struct LocalRuntime {let local:UUID,bundle:String,boot:String}
    static func cached(source:ReceiveSessionSource,clock:ABRuntimeClock,
                       readLocalRuntime:@escaping ()throws->LocalRuntime,readPublishableKey:@escaping ()throws->String,
                       verifyInstallation:@escaping (ReceiveApprovalIdentity)throws->Void,verifyIdentity:@escaping ()throws->Void) -> Self {
        .init(readRuntime:{
            let local=try readLocalRuntime()
            return try source.approvalRuntime(local:local.local,bundle:local.bundle,boot:local.boot,clock:clock)
        },readPublishableKey:readPublishableKey,source:source,verifyInstallation:verifyInstallation,verifyIdentity:verifyIdentity)
    }
}

final class ReceivePreparedApproval {
    enum Mode: String { case observe, receiveAndApply }
    let identity: ReceiveApprovalIdentity, target: ReviewedReceiveTarget
    let draft: ReceiveExecutionCandidate.Draft, expectedRuntime: ReceiveExecutionCandidate.RuntimeSnapshot
    let paths: ReceiveDedicatedPaths, journalRoot: URL, clock: ABRuntimeClock
    let mode: Mode, providers: ReceiveApprovalProviders
    fileprivate let rehearsal: ReceiveReviewedExecution?, protocolClass: AnyClass?
    // The same preparation object cannot be reinstalled to issue a second authority.
    private let lock = NSLock()
    private var consumed = false
    init(identity: ReceiveApprovalIdentity, target: ReviewedReceiveTarget, draft: ReceiveExecutionCandidate.Draft,
         expectedRuntime: ReceiveExecutionCandidate.RuntimeSnapshot, paths: ReceiveDedicatedPaths, journalRoot: URL,
         clock: ABRuntimeClock, mode: Mode, providers: ReceiveApprovalProviders) {
        self.identity=identity;self.target=target;self.draft=draft;self.expectedRuntime=expectedRuntime
        self.paths=paths;self.journalRoot=journalRoot;self.clock=clock;self.mode=mode;self.providers=providers
        rehearsal=nil;protocolClass=nil
    }
    private init(identity: ReceiveApprovalIdentity, target: ReviewedReceiveTarget, draft: ReceiveExecutionCandidate.Draft,
                 expectedRuntime: ReceiveExecutionCandidate.RuntimeSnapshot, paths: ReceiveDedicatedPaths, journalRoot: URL,
                 clock: ABRuntimeClock, mode: Mode, providers: ReceiveApprovalProviders,
                 execution: ReceiveReviewedExecution, protocolClass: AnyClass) {
        self.identity=identity;self.target=target;self.draft=draft;self.expectedRuntime=expectedRuntime
        self.paths=paths;self.journalRoot=journalRoot;self.clock=clock;self.mode=mode;self.providers=providers
        rehearsal=execution;self.protocolClass=protocolClass
    }
    static func offline(identity: ReceiveApprovalIdentity, target: ReviewedReceiveTarget, draft: ReceiveExecutionCandidate.Draft,
                        expectedRuntime: ReceiveExecutionCandidate.RuntimeSnapshot, paths: ReceiveDedicatedPaths, journalRoot: URL,
                        clock: ABRuntimeClock, mode: Mode, providers: ReceiveApprovalProviders, protocolClass: AnyClass) throws -> ReceivePreparedApproval {
        let execution=try ReceiveReviewedExecution.offline(target:target,draft:draft,now:clock.sample(),readRuntime:{expectedRuntime})
        return .init(identity:identity,target:target,draft:draft,expectedRuntime:expectedRuntime,paths:paths,journalRoot:journalRoot,
                     clock:clock,mode:mode,providers:providers,execution:execution,protocolClass:protocolClass)
    }
    fileprivate func checkUnused() throws {lock.lock();defer{lock.unlock()};try connectionNeed(!consumed,.reused)}
    fileprivate func consume() throws {lock.lock();defer{lock.unlock()};try connectionNeed(!consumed,.reused);consumed=true}
    fileprivate func invalidate() {lock.lock();consumed=true;lock.unlock()}
    fileprivate var scopes: Set<ReceiveActivationAuthority.Scope> {
        mode == .receiveAndApply ? [.cachedSession,.httpRead,.productStorage] : [.cachedSession,.httpRead]
    }
    fileprivate func validate(now: ABRuntimeClock.Sample) throws {
        try identity.validate()
        try connectionNeed(ReceiveExecutionCandidate.compare(draft,to:target,now:now,runtime:expectedRuntime).local_fields_matched,.unverified)
        try connectionNeed(draft.localProjectID?.uuidString.lowercased() == paths.root.lastPathComponent || rehearsal != nil,.invalidTarget)
        if rehearsal == nil {
            try connectionNeed(clock.isSystem,.closed)
            for id in [draft.localProjectID!,draft.runID!] {try connectionNeed(!id.uuidString.lowercased().hasPrefix("ee2609"),.closed)}
            let origin=URLComponents(string:draft.endpoint!)
            try connectionNeed(origin?.host?.hasSuffix(".invalid") == false,.closed)
        }
    }
    fileprivate func requireExpectedRuntime() throws -> ReceiveExecutionCandidate.RuntimeSnapshot {
        let actual=try providers.readRuntime(),expected=expectedRuntime
        try connectionNeed(actual.account==expected.account && actual.localProjectID==expected.localProjectID && actual.bundleID==expected.bundleID && actual.bootID==expected.bootID && actual.sessionEpoch==expected.sessionEpoch && actual.sessionExpiresUTCMS==expected.sessionExpiresUTCMS,.changedSession)
        return actual
    }
}

// This object is the actual screen's immutable review ticket, not an imported approval document.
final class ReceiveApprovalReview {
    let text: String, digest: String
    fileprivate let issuedAt: ABRuntimeClock.Sample
    fileprivate init(_ prepared: ReceivePreparedApproval, now: ABRuntimeClock.Sample) throws {
        let d=prepared.draft,t=d.timing!
        struct Record: Encodable {
            let identity:ReceiveApprovalIdentity,endpoint:String,account:String,project:String,source:String,handoff:String,target:String
            let run:String,local:String,bundle:String,boot:String,epoch:Int,sessionExpiry:Int,timing:SyntheticABTiming,mode:String,productPath:String,journalPath:String
        }
        let record=Record(identity:prepared.identity,endpoint:d.endpoint!,account:d.account!.uuidString.lowercased(),project:d.project!.uuidString.lowercased(),source:prepared.target.sourceRun,handoff:d.handoffSHA256!,target:d.targetSHA256!,run:d.runID!.uuidString.lowercased(),local:d.localProjectID!.uuidString.lowercased(),bundle:d.bundleID!,boot:d.bootID!,epoch:d.sessionEpoch!,sessionExpiry:prepared.expectedRuntime.sessionExpiresUTCMS,timing:t,mode:prepared.mode.rawValue,productPath:prepared.paths.root.path,journalPath:prepared.journalRoot.path)
        digest=byteHash(try canonical(record));issuedAt=now
        func date(_ ms:Int)->String {ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:Double(ms)/1000))}
        text="""
        \(prepared.rehearsal == nil ? "실제 수신 실행 승인" : "합성 실행 승인 연습")
        승인: \(record.identity.approvalID)
        기기: \(record.identity.device) / 설치: \(record.identity.installationID)
        앱: \(record.bundle)
        후보 SHA256: \(record.identity.candidateSHA256)
        대상: \(record.endpoint)
        계정: \(record.account)
        프로젝트: \(record.project)
        source run: \(record.source)
        handoff SHA256: \(record.handoff)
        target SHA256: \(record.target)
        새 실행: \(record.run) / local: \(record.local)
        세션 epoch: \(record.epoch) / 실행 범위: \(record.boot)
        세션 만료: \(date(record.sessionExpiry))
        실행 창(UTC): \(date(t.notBeforeUTCMS)) ~ \(date(t.expiresUTCMS))
        A/B 각 7회, HTTP 최대 14회(Auth 2회 포함). 추가 페이지·재시도 없음.
        요청 \(t.requestMS)ms / pass \(t.passMS)ms / interpass \(t.interpassMS)ms
        적용 준비 \(t.preApplyMS)ms / local \(t.localApplyMS)ms / 전체 \(t.totalMS)ms
        응답 \(t.maxResponseBytes) bytes / 실행 \(t.maxRunBytes) bytes
        \(prepared.mode == .receiveAndApply ? "성공 시 members 4개만 전용 local 적용" : "관찰 보관만; local 적용 없음")
        저장: \(record.productPath)
        저널: \(record.journalPath)
        원격 생성·수정, 로그인 갱신, 편집·송신·자동 수신, hold/prod 변경은 포함하지 않습니다.
        확인 값: \(digest)
        """
    }
}

final class ReceiveApprovalCallSite {
    private let lock=NSLock()
    private var prepared:ReceivePreparedApproval?,pending:ReceiveApprovalReview?
    private var confirming=false,cancelled=false
    private var active:ReceiveAuthorizedRun?,authority:ReceiveActivationAuthority?
    // No provider or runtime is read when a controller is created or configuration is installed.
    init(prepared:ReceivePreparedApproval?=nil) {self.prepared=prepared}
    func present() throws -> ReceiveApprovalReview {
        lock.lock();defer{lock.unlock()}
        guard let prepared,!cancelled,!confirming,active==nil else {throw ReceiveConnectionError.closed}
        try prepared.checkUnused();let now=try prepared.clock.sample();try prepared.validate(now:now)
        // Re-presenting invalidates the old screen ticket even when every field looks identical.
        let review=try ReceiveApprovalReview(prepared,now:now);pending=review;return review
    }
    private func requireConfirming() throws {lock.lock();defer{lock.unlock()};try connectionNeed(confirming && !cancelled,.cancelled)}
    func cancel() {
        lock.lock();cancelled=true;pending=nil;let a=authority,r=active,p=prepared;lock.unlock()
        p?.invalidate();a?.revoke();r?.cancel()
    }
    func confirm(_ review:ReceiveApprovalReview,lease:BoundaryLease,protection:PhysicalStorageAccess) throws -> ReceiveAuthorizedRun {
        lock.lock()
        guard let p=prepared,pending === review,!confirming,!cancelled,active==nil else {lock.unlock();throw ReceiveConnectionError.closed}
        pending=nil;confirming=true;lock.unlock()
        var grant:ReceiveActivationAuthority?
        do {
            try p.consume() // Single use even if a provider fails or the run never reaches HTTP.
            let started=try p.clock.sample();try p.validate(now:started)
            try connectionNeed(started.utcMS>=review.issuedAt.utcMS && started.monoMS>=review.issuedAt.monoMS,.clock)
            let timing=p.draft.timing!
            let check:()throws->Void = { [weak self] in
                guard let self else {throw ReceiveConnectionError.cancelled}
                try self.requireConfirming();try lease.check();try protection.check();try Task.checkCancellation()
                let now=try p.clock.sample()
                try connectionNeed(now.utcMS>=started.utcMS && now.monoMS>=started.monoMS,.clock)
                try abNeed(now.monoMS-started.monoMS<timing.totalMS,.totalTimeout)
                try p.validate(now:now)
            }
            try check();try p.providers.verifyInstallation(p.identity);try check()
            try p.providers.verifyIdentity();try check()
            let runtime:()throws->ReceiveExecutionCandidate.RuntimeSnapshot = {try check();return try p.requireExpectedRuntime()}
            if let execution=p.rehearsal {
                grant=try .offline(execution:execution,scopes:p.scopes,clock:p.clock,approvalDigest:review.digest,readRuntime:runtime)
            } else {
                grant=try .afterExplicitUserConfirmation(target:p.target,draft:p.draft,scopes:p.scopes,clock:p.clock,approvalDigest:review.digest,readRuntime:runtime)
            }
            try check();let key=try p.providers.readPublishableKey();try check()
            let http=try ReceiveHTTPTarget(origin:URL(string:grant!.endpoint)!,account:grant!.account,project:grant!.project,publishableKey:key)
            let verify:()throws->Void = {
                try check();try p.providers.verifyInstallation(p.identity);try p.providers.verifyIdentity();try check()
            }
            let env=ReceiveDedicatedEnvironment(paths:p.paths,local:p.draft.localProjectID!,bundle:p.draft.bundleID!,source:p.providers.source,authority:grant,clock:p.clock,lease:lease,protection:protection,verifyIdentity:verify)
            let run=try ReceiveAuthorizedRun(environment:env,target:p.target,httpTarget:http,journalRoot:p.journalRoot,offlineProtocol:p.protocolClass,startedAt:started)
            lock.lock()
            guard !cancelled else {lock.unlock();run.cancel();throw ReceiveConnectionError.cancelled}
            authority=grant;active=run;lock.unlock()
            return run
        } catch {grant?.revoke();cancel();throw error}
    }
}

// Trusted native configuration, never decoded from an imported handoff or approval flag.
// Session delivery uses this dedicated in-memory owner; no startup restore, login or refresh.
final class ReceiveAppPreparation {
    struct Configuration {
        let identity:ReceiveApprovalIdentity
        let target:ReviewedReceiveTarget
        let draft:ReceiveExecutionCandidate.Draft
        let publishableKey:String
        let mode:ReceivePreparedApproval.Mode
    }
    struct LocalIdentity:Equatable {
        let local:UUID, bundle:String, boot:String
    }
    private let configuration:Configuration, source:ReceiveSessionSource, clock:ABRuntimeClock
    private let readInstallation:()throws->ReceiveApprovalIdentity
    private let readLocal:()throws->LocalIdentity
    private let lock=NSLock()
    private var attempted=false
    init(configuration:Configuration,sessionOwner:ReceiveAuthOwner,clock:ABRuntimeClock=ABRuntimeClock(),
         readInstallation:@escaping ()throws->ReceiveApprovalIdentity,
         readLocal:@escaping ()throws->LocalIdentity) {
        self.configuration=configuration;source=sessionOwner.source;self.clock=clock
        self.readInstallation=readInstallation;self.readLocal=readLocal
    }
    // Explicit preparation button only. Reads memory and local attestations, creates no files,
    // authority or transport. A failed/cancelled preparation needs a new reviewed configuration.
    func prepare() throws -> ReceivePreparedApproval { try build(rehearsal:nil) }
    func prepareOffline(paths:ReceiveDedicatedPaths,journal:URL,protocolClass:AnyClass) throws -> ReceivePreparedApproval {
        try paths.validate()
        return try build(rehearsal:(paths,journal,protocolClass))
    }
    private func build(rehearsal:(ReceiveDedicatedPaths,URL,AnyClass)?) throws -> ReceivePreparedApproval {
        lock.lock();let used=attempted;attempted=true;lock.unlock()
        try connectionNeed(!used,.reused)
        let c=configuration,d=c.draft
        try c.identity.validate()
        guard let local=d.localProjectID,let bundle=d.bundleID,let boot=d.bootID,
              let run=d.runID,let endpoint=d.endpoint,let account=d.account,let project=d.project else {
            throw ReceiveConnectionError.unverified
        }
        let expected=LocalIdentity(local:local,bundle:bundle,boot:boot)
        let verifyLocal:()throws->Void = {try connectionNeed(self.readLocal()==expected,.unverified)}
        let verifyInstall:(ReceiveApprovalIdentity)throws->Void = { identity in
            try connectionNeed(identity==c.identity && self.readInstallation()==identity,.unverified)
        }
        try verifyInstall(c.identity);try verifyLocal()
        let providers=ReceiveApprovalProviders.cached(source:source,clock:clock,readLocalRuntime:{
            try verifyLocal();return .init(local:local,bundle:bundle,boot:boot)
        },readPublishableKey:{c.publishableKey},verifyInstallation:verifyInstall,verifyIdentity:verifyLocal)
        let runtime=try providers.readRuntime()
        guard let origin=URL(string:endpoint) else {throw ReceiveConnectionError.invalidTarget}
        _ = try ReceiveHTTPTarget(origin:origin,account:account,project:project,publishableKey:c.publishableKey)
        let paths=try rehearsal?.0 ?? ReceiveDedicatedPaths.live(local:local,bundle:bundle)
        let journal=rehearsal?.1 ?? paths.root.deletingLastPathComponent().appendingPathComponent("execution-"+run.uuidString.lowercased())
        try SafeFiles.checked(journal)
        let prepared:ReceivePreparedApproval
        if let rehearsal {
            prepared=try .offline(identity:c.identity,target:c.target,draft:d,expectedRuntime:runtime,
                paths:paths,journalRoot:journal,clock:clock,mode:c.mode,providers:providers,protocolClass:rehearsal.2)
        } else {
        prepared=ReceivePreparedApproval(identity:c.identity,target:c.target,draft:d,expectedRuntime:runtime,
            paths:paths,journalRoot:journal,clock:clock,mode:c.mode,providers:providers)
        }
        try prepared.validate(now:clock.sample())
        try verifyInstall(c.identity);try verifyLocal()
        _ = try prepared.requireExpectedRuntime()
        return prepared
    }
}

// Only fixed stage/error labels are retained. Never store underlying error descriptions,
// provider values, URLs, configuration bytes, keys or session credentials in diagnostics.
struct ReceiveConfigurationFailure: Error, CustomStringConvertible {
    enum Stage:String {
        case launch, file, envelope, retained, target, home, installationRecord="installation-record"
        case localRecord="local-record", binding, boot, bootQuery="boot-query", bootRead="boot-read"
        case bootFormat="boot-format", executable, composition
    }
    let stage:Stage, code:String
    var description:String { "configuration." + stage.rawValue + " / " + code }
    static func at<T>(_ stage:Stage,_ body:()throws->T) throws -> T {
        do {return try body()}
        catch let failure as ReceiveConfigurationFailure {throw failure}
        catch {
            let code:String
            if let e=error as? ReceiveConnectionError {code="connection:"+e.rawValue}
            else if let e=error as? ReceiveError {code="file:"+e.rawValue}
            else if let e=error as? WindowsReaderError {code="reader:"+e.rawValue}
            else if error is DecodingError {code="decode"}
            else {code="unverified"}
            throw ReceiveConfigurationFailure(stage:stage,code:code)
        }
    }
}

// Native execution scope, deliberately shorter than an OS boot. Never loaded from disk.
// A fresh process loses approvals/auth state and gets a fresh scope; saved journals cannot
// supply this value. Legacy boot/bootID field names carry this opaque scope for compatibility.
struct ReceiveProcessLifetime {
    static let current = ReceiveProcessLifetime()
    let identifier = "app-process-v1:" + UUID().uuidString.lowercased()
}

// Pinned local evidence is supplied by trusted native composition, not the handoff picker.
// These files contain no session, token or execution permission. This checks local provenance;
// platform code-signing and device identity attestation remain separate installation checks.
final class ReceiveNativePreparationEvidence {
    struct Pins {
        let installationSHA256:String, localSHA256:String
    }
    struct InstallationRecord:Codable {
        let identity:ReceiveApprovalIdentity, bundle:String, executableSHA256:String
    }
    struct LocalRecord:Codable {
        let local:UUID, bundle:String, installationID:String
    }
    private struct FileStamp:Equatable {
        let device:dev_t, inode:ino_t, size:off_t, mode:mode_t
        let modifiedSeconds:Int, modifiedNanos:Int, changedSeconds:Int, changedNanos:Int
        init(_ value:stat) {
            device=value.st_dev;inode=value.st_ino;size=value.st_size;mode=value.st_mode
            modifiedSeconds=value.st_mtimespec.tv_sec;modifiedNanos=value.st_mtimespec.tv_nsec
            changedSeconds=value.st_ctimespec.tv_sec;changedNanos=value.st_ctimespec.tv_nsec
        }
    }
    private let pins:Pins
    private let readHome:()throws->URL, readExecutable:()throws->URL
    private let readBundle:()throws->String, readBoot:()throws->String
    private let lock=NSLock()
    private var executableSeal:(URL,FileStamp,String)?
    init(pins:Pins,readHome:@escaping ()throws->URL,readExecutable:@escaping ()throws->URL,
         readBundle:@escaping ()throws->String,
         readBoot:@escaping ()throws->String = {ReceiveProcessLifetime.current.identifier}) {
        self.pins=pins;self.readHome=readHome;self.readExecutable=readExecutable
        self.readBundle=readBundle;self.readBoot=readBoot
    }
    static func native(pins:Pins) -> ReceiveNativePreparationEvidence {
        .init(pins:pins,readHome:{try BoundarySystemHome.resolve()},readExecutable:{
            // Canonicalize only the OS-provided app bundle, never a record/payload path.
            guard let executable=Bundle.main.executableURL,
                  let pointer=realpath(Bundle.main.bundleURL.path,nil) else {throw ReceiveConnectionError.unverified}
            defer {free(pointer)}
            return URL(fileURLWithPath:String(cString:pointer),isDirectory:true).appendingPathComponent(executable.lastPathComponent)
        },readBundle:{
            guard let value=Bundle.main.bundleIdentifier else {throw ReceiveConnectionError.unverified};return value
        })
    }
    private func validHash(_ value:String) throws {
        try connectionNeed(value.count==64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)},.unverified)
    }
    private func record<T:Decodable>(_ type:T.Type,url:URL,hash:String) throws -> T {
        try validHash(hash)
        let bytes=try SafeFiles.read(url,limit:16*1024)
        try connectionNeed(byteHash(bytes)==hash,.unverified)
        return try JSONDecoder().decode(type,from:bytes)
    }
    private func verifyExecutable(expected:String) throws {
        try validHash(expected)
        let url=try readExecutable();try SafeFiles.checked(url)
        guard let info=try SafeFiles.attributes(url),info.st_mode & S_IFMT == S_IFREG,
              info.st_size>0,info.st_size<=128*1024*1024 else {throw ReceiveConnectionError.unverified}
        let stamp=FileStamp(info)
        if let seal=executableSeal {
            try connectionNeed(seal.0==url && seal.1==stamp && seal.2==expected,.unverified)
        } else {
            let bytes=try SafeFiles.read(url,limit:128*1024*1024)
            try connectionNeed(byteHash(bytes)==expected,.unverified)
            guard let after=try SafeFiles.attributes(url) else {throw ReceiveConnectionError.unverified}
            try connectionNeed(FileStamp(after)==stamp,.unverified)
            executableSeal=(url,stamp,expected)
        }
    }
    private func snapshot() throws -> (InstallationRecord,LocalRecord,String) {
        lock.lock();defer{lock.unlock()}
        let home=try ReceiveConfigurationFailure.at(.home) {let url=try readHome();try SafeFiles.checked(url);return url}
        let root=home.appendingPathComponent("Library/Application Support/ReceiveConfiguration-v1")
        let installation=try ReceiveConfigurationFailure.at(.installationRecord) {
            try record(InstallationRecord.self,url:root.appendingPathComponent("installation.json"),hash:pins.installationSHA256)
        }
        let local=try ReceiveConfigurationFailure.at(.localRecord) {
            try record(LocalRecord.self,url:root.appendingPathComponent("local.json"),hash:pins.localSHA256)
        }
        try ReceiveConfigurationFailure.at(.binding) {try installation.identity.validate()}
        let bundle=try ReceiveConfigurationFailure.at(.binding) {try readBundle()}
        let boot=try ReceiveConfigurationFailure.at(.boot) {try readBoot()}
        try ReceiveConfigurationFailure.at(.binding) {
            try connectionNeed(bundle==ProtectedBoundaryContainer.bundleID && installation.bundle==bundle && local.bundle==bundle && local.installationID==installation.identity.installationID,.unverified)
        }
        try ReceiveConfigurationFailure.at(.boot) {
            try connectionNeed(!boot.isEmpty && boot.utf8.count<=128 && boot.utf8.allSatisfy{(33...126).contains($0)},.unverified)
        }
        try ReceiveConfigurationFailure.at(.executable) {try verifyExecutable(expected:installation.executableSHA256)}
        return (installation,local,boot)
    }
    func readInstallation() throws -> ReceiveApprovalIdentity {try snapshot().0.identity}
    func readLocal() throws -> ReceiveAppPreparation.LocalIdentity {
        let value=try snapshot();return .init(local:value.1.local,bundle:value.1.bundle,boot:value.2)
    }
    func preparation(configuration:ReceiveAppPreparation.Configuration,sessionOwner:ReceiveAuthOwner,clock:ABRuntimeClock=ABRuntimeClock()) -> ReceiveAppPreparation {
        .init(configuration:configuration,sessionOwner:sessionOwner,clock:clock,
              readInstallation:{try self.readInstallation()},readLocal:{try self.readLocal()})
    }
}

// The launch hash is an external trust input from the local preparation tool. Payload flags
// never grant authority. Initialization is inert; load is an explicit foreground UI action.
struct ReceiveConfigurationEnvelope: Codable {
    let version:Int, portable:Data, installationSHA256:String, localSHA256:String
    let identity:ReceiveApprovalIdentity, publishableKey:String, mode:String
    let policy:Policy
    struct Policy:Codable {
        let requestMS:Int, passMS:Int, interpassMS:Int, preApplyMS:Int, localApplyMS:Int, totalMS:Int
        func timing(now:Int,expiry:Int) throws -> SyntheticABTiming {
            try connectionNeed(requestMS<=15000 && passMS<=120000 && interpassMS<=15000 && preApplyMS<=60000 && localApplyMS<=60000 && totalMS<=360000,.unverified)
            let result=SyntheticABTiming(requestMS:requestMS,passMS:passMS,interpassMS:interpassMS,preApplyMS:preApplyMS,localApplyMS:localApplyMS,totalMS:totalMS,notBeforeUTCMS:now,expiresUTCMS:min(try abAdd(now,totalMS),expiry))
            try result.validate();return result
        }
    }
}
final class ReceiveConfigurationBootstrap {
    static let argument="--receive-configuration-sha256"
    private let arguments:[String], read:()throws->Data, expectation:()throws->WindowsHandoffExpectation
    init(arguments:[String],read:@escaping ()throws->Data,expectation:@escaping ()throws->WindowsHandoffExpectation = {try .retainedSeptember14()}) {
        self.arguments=arguments;self.read=read;self.expectation=expectation
    }
    static func native(arguments:[String]) -> ReceiveConfigurationBootstrap {
        .init(arguments:arguments,read:{
            let root=try BoundarySystemHome.resolve().appendingPathComponent("Library/Application Support/ReceiveConfiguration-v1")
            return try SafeFiles.read(root.appendingPathComponent("configuration.json"),limit:16*1024*1024)
        })
    }
    func load() throws -> (ReceiveConfigurationEnvelope,ReviewedReceiveTarget) {
        let hash=try ReceiveConfigurationFailure.at(.launch) {
            let indices=arguments.indices.filter{arguments[$0]==Self.argument}
            guard indices.count==1,let index=indices.first,index+1<arguments.count else {throw ReceiveConnectionError.closed}
            let value=arguments[index+1]
            try connectionNeed(value.count==64 && value.utf8.allSatisfy{(48...57).contains($0)||(97...102).contains($0)},.unverified)
            return value
        }
        let bytes=try ReceiveConfigurationFailure.at(.file) {try read()}
        let envelope=try ReceiveConfigurationFailure.at(.envelope) {
            try connectionNeed(bytes.count<=16*1024*1024 && byteHash(bytes)==hash,.unverified)
            _ = try WindowsJSON.decode(bytes)
            let value=try JSONDecoder().decode(ReceiveConfigurationEnvelope.self,from:bytes)
            try connectionNeed(value.version==1 && ReceivePreparedApproval.Mode(rawValue:value.mode) != nil,.unverified)
            try value.identity.validate()
            _ = try value.policy.timing(now:0,expiry:360000)
            return value
        }
        let target=try ReceiveConfigurationFailure.at(.retained) {
            try ReviewedReceiveTarget.read(portable:envelope.portable,expected:expectation())
        }
        _ = try ReceiveConfigurationFailure.at(.target) {
            try ReceivePasswordAuthTarget(origin:URL(string:target.binding.str("endpoint"))!,account:UUID(uuidString:target.binding.str("account_id"))!,publishableKey:envelope.publishableKey)
        }
        return (envelope,target)
    }
}

// One factory per explicitly loaded configuration. It cannot silently extend/recreate an
// attempted run. A new login before preparation is captured here, never in an install file.
final class ReceivePostLoginPreparation {
    private let envelope:ReceiveConfigurationEnvelope, target:ReviewedReceiveTarget
    private let evidence:ReceiveNativePreparationEvidence, owner:ReceiveAuthOwner, clock:ABRuntimeClock
    private let newRun:()->UUID
    private let lock=NSLock()
    private var used=false
    init(envelope:ReceiveConfigurationEnvelope,target:ReviewedReceiveTarget,evidence:ReceiveNativePreparationEvidence,
         owner:ReceiveAuthOwner,clock:ABRuntimeClock=ABRuntimeClock(),newRun:@escaping ()->UUID = {UUID()}) {
        self.envelope=envelope;self.target=target;self.evidence=evidence;self.owner=owner;self.clock=clock;self.newRun=newRun
    }
    func preparation() throws -> ReceiveAppPreparation {
        lock.lock();let already=used;used=true;lock.unlock()
        try connectionNeed(!already,.reused)
        try connectionNeed(evidence.readInstallation()==envelope.identity,.unverified)
        let local=try evidence.readLocal()
        let runtime=try owner.source.approvalRuntime(local:local.local,bundle:local.bundle,boot:local.boot,clock:clock)
        let now=try clock.sample()
        let timing=try envelope.policy.timing(now:now.utcMS,expiry:runtime.sessionExpiresUTCMS)
        let draft=ReceiveExecutionCandidate.Draft(endpoint:try target.binding.str("endpoint"),account:runtime.account,project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:newRun(),localProjectID:local.local,bundleID:local.bundle,bootID:local.boot,sessionEpoch:runtime.sessionEpoch,timing:timing,httpLimit:14,authLimit:2)
        let comparison=try ReceiveExecutionCandidate.compare(draft,to:target,now:now,runtime:runtime)
        try connectionNeed(comparison.local_fields_matched,.unverified)
        guard let mode=ReceivePreparedApproval.Mode(rawValue:envelope.mode) else {throw ReceiveConnectionError.unverified}
        return evidence.preparation(configuration:.init(identity:envelope.identity,target:target,draft:draft,publishableKey:envelope.publishableKey,mode:mode),sessionOwner:owner,clock:clock)
    }
}
