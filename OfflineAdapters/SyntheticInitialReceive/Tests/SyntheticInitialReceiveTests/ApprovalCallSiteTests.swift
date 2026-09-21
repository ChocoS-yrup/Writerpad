import XCTest
import Foundation
import SwiftData
@testable import SyntheticInitialReceive

// Password endpoint fixture is separate from the receive fixture so budgets cannot blur.
final class IntegratedPasswordStub:URLProtocol {
    private static let lock=NSLock()
    private static var bytes=Data(),status=200,requests:[URLRequest]=[]
    static func reset(_ data:Data=Data(),status:Int=200) {
        lock.lock();defer{lock.unlock()};bytes=data;self.status=status;requests=[]
    }
    static var captured:[URLRequest] {lock.lock();defer{lock.unlock()};return requests}
    override class func canInit(with request:URLRequest)->Bool {
        request.url?.host=="synthetic.invalid" && request.url?.path=="/auth/v1/token"
    }
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        Self.lock.lock();Self.requests.append(request);let data=Self.bytes,status=Self.status;Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:"HTTP/1.1",headerFields:["Content-Length":String(data.count)])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ApprovalCallSiteTests:XCTestCase {
    enum Injected:Error {case stop}
    private var target:ReviewedReceiveTarget!,draft:ReceiveExecutionCandidate.Draft!,runtime:ReceiveExecutionCandidate.RuntimeSnapshot!
    private var observer:ReceiveAuthCallSiteObserver!,clock:ABRuntimeClock!,responses:[SyntheticABResponse]=[],directories:[URL]=[]
    private var lifecycle:BoundaryLifecycle!
    private var reads:[String:Int]=[:]
    private var installAction:()throws->Void = {}
    private var identityAction:()throws->Void = {}
    private var keyAction:()throws->String = {"sb_publishable_approval_fixture"}
    private var cacheMissing=false
    private var lastRoot:URL!,lastJournal:URL!
    override func setUpWithError() throws {
        let portable=try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!)
        let files=try WindowsHandoffReader.files(from:portable)
        let pin=try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!))
        target=try .read(portable:portable,expected:.init(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:pin.get("binding").encoded()))
        let timing=SyntheticABTiming(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:500,localApplyMS:1000,totalMS:60000,notBeforeUTCMS:1000,expiresUTCMS:61000)
        draft = .init(endpoint:"https://synthetic.invalid",account:UUID(uuidString:try target.binding.str("account_id")),project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000481"),localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000482"),bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-admission-boot",sessionEpoch:1,timing:timing,httpLimit:14,authLimit:2)
        runtime = .init(account:draft.account!,localProjectID:draft.localProjectID!,bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:1,sessionExpiresUTCMS:61000)
        clock=ABRuntimeClock(utcMS:1000,monoMS:0);observer=ReceiveAuthCallSiteObserver()
        let op=UUID();observer.begin(op);observer.accept(op,account:draft.account!,accessToken:"synthetic.admission.session",expiresAt:Date(timeIntervalSince1970:61))
        lifecycle=BoundaryLifecycle();lifecycle.update(active:true,protectedDataAvailable:true)
        let values=try ["Q1.body","Q2.body","Q3.body","Q4.body","Q14.body","Q15.body","Q16.body"].map{try WindowsJSON.decode(files["source/"+$0]!)}
        responses=try values.enumerated().map{i,v in let count=i>=2 ? try v.array().count:nil;return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map{$0==0 ? "*/0":"0-\($0-1)/\($0)"},delayMS:0)};responses += responses
        ReceiveABStub.reset(responses)
    }
    override func tearDownWithError() throws {IntegratedPasswordStub.reset();ReceiveABStub.reset();for d in directories {try FileManager.default.removeItem(at:d)}}
    private func directory(_ prefix:String="ReceiveInputAdmission-") throws -> URL {
        let d=URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent(prefix+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false);directories.append(d);return d
    }
    private var identity:ReceiveApprovalIdentity {.init(approvalID:"synthetic-stage-three",device:"iPad Pro 11-inch M4 (synthetic)",installationID:"synthetic-install",candidateSHA256:String(repeating:"a",count:64))}
    private func configuration(mode:ReceivePreparedApproval.Mode = .receiveAndApply,live:Bool=false,identity:ReceiveApprovalIdentity?=nil) throws -> ReceivePreparedApproval {
        lastRoot=try directory("ReceiveProductStore-");lastJournal=try directory("ReceiveAuthorizedJournal-")
        let root=lastRoot!,paths=ReceiveDedicatedPaths(root:root,metadata:root.appendingPathComponent("metadata/store.sqlite"),syncDB:root.appendingPathComponent("sync.sqlite"),texts:root.appendingPathComponent("texts"),journal:root.appendingPathComponent("journal"),identity:root.appendingPathComponent("identity.json"))
        let source=ReceiveSessionSource(readCached:{
            self.reads["cache",default:0]+=1
            return self.cacheMissing ? nil:.init(account:self.runtime.account,accessToken:"synthetic.admission.session",expiresUTCMS:self.runtime.sessionExpiresUTCMS)
        },ownerEpoch:{self.runtime.sessionEpoch})
        let providers=ReceiveApprovalProviders(readRuntime:{self.reads["runtime",default:0]+=1;return self.runtime},readPublishableKey:{self.reads["key",default:0]+=1;return try self.keyAction()},source:source,verifyInstallation:{value in
            self.reads["installation",default:0]+=1;XCTAssertEqual(value,self.identity);try self.installAction()
        },verifyIdentity:{self.reads["identity",default:0]+=1;try self.identityAction()})
        if live {return .init(identity:identity ?? self.identity,target:target,draft:draft,expectedRuntime:runtime,paths:paths,journalRoot:lastJournal,clock:clock,mode:mode,providers:providers)}
        return try .offline(identity:identity ?? self.identity,target:target,draft:draft,expectedRuntime:runtime,paths:paths,journalRoot:lastJournal,clock:clock,mode:mode,providers:providers,protocolClass:ReceiveABStub.self)
    }
    private func confirm(_ site:ReceiveApprovalCallSite,_ review:ReceiveApprovalReview) throws -> ReceiveAuthorizedRun {
        try site.confirm(review,lease:lifecycle.begin(),protection:.init())
    }
    private func empty(_ url:URL) throws -> Bool {try FileManager.default.contentsOfDirectory(atPath:url.path).isEmpty}
    private func ledger() throws -> ReceiveAuthorizedRun.Ledger {try JSONDecoder().decode(ReceiveAuthorizedRun.Ledger.self,from:Data(contentsOf:lastJournal.appendingPathComponent("run.json")))}

    private func composition() -> ReceiveAppPreparation {
        .init(configuration:.init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.receiveAndApply),sessionOwner:observer.owner,clock:clock,readInstallation:{
            self.reads["installation",default:0]+=1;try self.installAction();return self.identity
        },readLocal:{
            self.reads["local",default:0]+=1;try self.identityAction()
            return .init(local:self.runtime.localProjectID,bundle:self.runtime.bundleID,boot:self.runtime.bootID)
        })
    }
    private func prepareComposition(_ value:ReceiveAppPreparation) throws -> ReceivePreparedApproval {
        let fixture=try configuration()
        return try value.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
    }
    func testCompositionIsInertAndExecutesOnlyAfterConfirmation() async throws {
        let value=composition();XCTAssertTrue(reads.isEmpty)
        let prepared=try prepareComposition(value)
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try empty(lastRoot))
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        XCTAssertFalse(review.text.contains("synthetic.admission.session"))
        XCTAssertEqual(ReceiveABStub.count,0)
        let run=try confirm(site,review)
        _ = try await run.run()
        XCTAssertEqual(ReceiveABStub.count,14)
        XCTAssertThrowsError(try prepareComposition(value))
    }
    func testCompositionCreatesMissingRootsOnlyDuringApprovedRun() async throws {
        let prepared=try prepareComposition(composition())
        try FileManager.default.removeItem(at:lastRoot)
        try FileManager.default.removeItem(at:lastJournal)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        let run=try confirm(site,review)
        XCTAssertFalse(FileManager.default.fileExists(atPath:lastRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:lastJournal.path))
        _ = try await run.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath:lastRoot.appendingPathComponent("complete.json").path))
        XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testEmptyRootPreparationPreservesExistingDataAndRejectsLinks() throws {
        let root=try directory(),file=root.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to:file)
        XCTAssertThrowsError(try ReceiveDedicatedPaths.prepareEmptyRoot(root,access:.init(),check:{}))
        XCTAssertEqual(try Data(contentsOf:file),Data("preserve".utf8))
        let link=root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        XCTAssertThrowsError(try ReceiveDedicatedPaths.prepareEmptyRoot(link,access:.init(),check:{}))
    }
    func testCompositionRejectsWrongAccountExpiredSessionAndLocalMismatch() throws {
        try observer.owner.replaceCachedSession(.init(account:UUID(),accessToken:"synthetic.other",expiresUTCMS:61000))
        XCTAssertThrowsError(try prepareComposition(composition()))
        try observer.owner.replaceCachedSession(.init(account:draft.account!,accessToken:"synthetic.expired",expiresUTCMS:999))
        XCTAssertThrowsError(try prepareComposition(composition()))
        runtime = .init(account:draft.account!,localProjectID:UUID(),bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:1,sessionExpiresUTCMS:61000)
        XCTAssertThrowsError(try prepareComposition(composition()))
        XCTAssertEqual(ReceiveABStub.count,0)
    }

    func testCompositionMissingSessionAndChangedIdentityBlockWithoutHTTP() throws {
        observer.invalidate()
        XCTAssertThrowsError(try prepareComposition(composition()))
        XCTAssertEqual(ReceiveABStub.count,0)
        identityAction={throw Injected.stop}
        XCTAssertThrowsError(try prepareComposition(composition()))
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testCompositionSessionReplacementAfterReviewBlocks() throws {
        let prepared=try prepareComposition(composition())
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        observer.invalidate()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testCompositionInstallationChangeAfterReviewBlocks() throws {
        let prepared=try prepareComposition(composition())
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        installAction={throw Injected.stop}
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testCompositionLiveRejectsSyntheticConfiguration() throws {
        XCTAssertThrowsError(try composition().prepare());XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testDedicatedPathsResolveHomeAliasButRejectChildLink() throws {
        let home=try directory(),alias=home.appendingPathComponent("alias")
        let actual=home.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at:actual,withIntermediateDirectories:false)
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:actual)
        let local=UUID(),bundle=ProtectedBoundaryContainer.bundleID
        let paths=try ReceiveDedicatedPaths.make(local:local,bundle:bundle,systemHome:alias.path)
        XCTAssertTrue(paths.root.path.hasPrefix(actual.path+"/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.root.path))
        try FileManager.default.createSymbolicLink(at:actual.appendingPathComponent("Library"),withDestinationURL:home)
        XCTAssertThrowsError(try ReceiveDedicatedPaths.make(local:local,bundle:bundle,systemHome:alias.path))
    }

    private func bootstrapEnvelope() throws -> ReceiveConfigurationEnvelope {
        .init(version:1,portable:try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!),installationSHA256:String(repeating:"a",count:64),localSHA256:String(repeating:"b",count:64),identity:identity,publishableKey:"sb_publishable_fixture",mode:"receiveAndApply",policy:.init(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:500,localApplyMS:1000,totalMS:60000))
    }
    func testBootstrapExternalHashAndRetainedPinAreBothRequired() throws {
        let envelope=try bootstrapEnvelope(),bytes=try JSONEncoder().encode(envelope)
        let expected=try WindowsHandoffExpectation(handoffSHA256:target.review.handoff_sha256,bindingJSON:target.binding.encoded())
        var count=0
        func loader(_ args:[String]) -> ReceiveConfigurationBootstrap {
            .init(arguments:args,read:{count+=1;return bytes},expectation:{expected})
        }
        let args=[ReceiveConfigurationBootstrap.argument,byteHash(bytes)]
        let good=loader(args);XCTAssertEqual(count,0)
        XCTAssertEqual(try good.load().1.targetSHA256,target.targetSHA256)
        XCTAssertThrowsError(try loader([]).load())
        XCTAssertThrowsError(try loader(args+args).load())
        XCTAssertEqual(count,1)
        XCTAssertThrowsError(try loader([args[0],String(repeating:"0",count:64)]).load())
        XCTAssertThrowsError(try ReceiveConfigurationBootstrap(arguments:args,read:{bytes}).load())
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testPostLoginFactoryUsesCurrentEpochAndClipsWindowThenConsumes() throws {
        let (evidence,_,_)=try nativeEvidence(),envelope=try bootstrapEnvelope()
        let factory=ReceivePostLoginPreparation(envelope:envelope,target:target,evidence:evidence,owner:observer.owner,clock:clock,newRun:{self.draft.runID!})
        XCTAssertTrue(reads.isEmpty)
        let op=UUID();observer.begin(op);observer.accept(op,account:draft.account!,accessToken:"synthetic.new",expiresAt:Date(timeIntervalSince1970:20))
        try clock.setForTest(utcMS:5000,monoMS:4000)
        let preparation=try factory.preparation()
        let prepared=try prepareComposition(preparation)
        XCTAssertEqual(prepared.draft.sessionEpoch,2)
        XCTAssertEqual(prepared.draft.timing?.notBeforeUTCMS,5000)
        XCTAssertEqual(prepared.draft.timing?.expiresUTCMS,20000)
        let review=try ReceiveApprovalCallSite(prepared:prepared).present()
        XCTAssertFalse(review.text.isEmpty)
        XCTAssertThrowsError(try factory.preparation())
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testPostLoginFactoryMissingSessionDoesNotIssueRun() throws {
        let (evidence,_,_)=try nativeEvidence();var issued=0
        let factory=ReceivePostLoginPreparation(envelope:try bootstrapEnvelope(),target:target,evidence:evidence,owner:ReceiveAuthOwner(),clock:clock,newRun:{issued+=1;return self.draft.runID!})
        XCTAssertThrowsError(try factory.preparation());XCTAssertEqual(issued,0)
        XCTAssertThrowsError(try factory.preparation())
    }
    func testBootstrapPolicyRejectsOverflowAndExpandedLimits() throws {
        XCTAssertThrowsError(try ReceiveConfigurationEnvelope.Policy(requestMS:15001,passMS:1,interpassMS:1,preApplyMS:1,localApplyMS:1,totalMS:1).timing(now:0,expiry:10))
        let policy=try bootstrapEnvelope().policy
        XCTAssertThrowsError(try policy.timing(now:Int.max,expiry:Int.max))
        XCTAssertThrowsError(try policy.timing(now:100,expiry:100))
        XCTAssertEqual(try policy.timing(now:100,expiry:200).expiresUTCMS,200)
    }

    private func nativeEvidence(bundle:String=ProtectedBoundaryContainer.bundleID,installationID:String?=nil,boot:(()throws->String)?=nil) throws -> (ReceiveNativePreparationEvidence,URL,URL) {
        let home=try directory(),root=home.appendingPathComponent("Library/Application Support/ReceiveConfiguration-v1")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let executable=home.appendingPathComponent("fixture-executable")
        let bytes=Data("synthetic executable bytes".utf8);try bytes.write(to:executable)
        let installation=ReceiveNativePreparationEvidence.InstallationRecord(identity:identity,bundle:draft.bundleID!,executableSHA256:byteHash(bytes))
        let local=ReceiveNativePreparationEvidence.LocalRecord(local:draft.localProjectID!,bundle:draft.bundleID!,installationID:installationID ?? identity.installationID)
        let a=try canonical(installation),b=try canonical(local)
        try a.write(to:root.appendingPathComponent("installation.json"));try b.write(to:root.appendingPathComponent("local.json"))
        let evidence=ReceiveNativePreparationEvidence(pins:.init(installationSHA256:byteHash(a),localSHA256:byteHash(b)),readHome:{self.reads["home",default:0]+=1;return home},readExecutable:{executable},readBundle:{bundle},readBoot:boot ?? {self.runtime.bootID})
        return (evidence,root,executable)
    }
    private func assertStage(_ stage:ReceiveConfigurationFailure.Stage,_ body:()throws->Void,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertThrowsError(try body(),file:file,line:line) {error in
            XCTAssertEqual((error as? ReceiveConfigurationFailure)?.stage,stage,file:file,line:line)
        }
    }
    func testConfigurationDiagnosticsSeparateLaunchFileEnvelopeAndRetained() throws {
        var reads=0
        assertStage(.launch) {_ = try ReceiveConfigurationBootstrap(arguments:[],read:{reads+=1;return Data()}).load()}
        XCTAssertEqual(reads,0)
        let args=[ReceiveConfigurationBootstrap.argument,String(repeating:"a",count:64)]
        assertStage(.file) {_ = try ReceiveConfigurationBootstrap(arguments:args,read:{throw Injected.stop}).load()}
        assertStage(.envelope) {_ = try ReceiveConfigurationBootstrap(arguments:args,read:{Data("wrong".utf8)}).load()}
        let bytes=try JSONEncoder().encode(bootstrapEnvelope())
        assertStage(.retained) {_ = try ReceiveConfigurationBootstrap(arguments:[args[0],byteHash(bytes)],read:{bytes}).load()}
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testConfigurationDiagnosticsSeparateNativeStagesAndPreserveInnerFailure() throws {
        let (missing,root,_)=try nativeEvidence()
        try FileManager.default.removeItem(at:root.appendingPathComponent("installation.json"))
        assertStage(.installationRecord) {_ = try missing.readInstallation()}
        let (badLocal,root2,_)=try nativeEvidence()
        try Data("changed".utf8).write(to:root2.appendingPathComponent("local.json"))
        assertStage(.localRecord) {_ = try badLocal.readLocal()}
        let wrongBundle=try nativeEvidence(bundle:"wrong").0
        assertStage(.binding) {_ = try wrongBundle.readInstallation()}
        let boot=try nativeEvidence(boot:{throw Injected.stop}).0
        assertStage(.boot) {_ = try boot.readInstallation()}
        let os=try nativeEvidence(boot:{throw ReceiveConfigurationFailure(stage:.bootQuery,code:"os:1")}).0
        assertStage(.bootQuery) {_ = try os.readInstallation()}
        let (exe,_,binary)=try nativeEvidence()
        try Data("changed".utf8).write(to:binary)
        assertStage(.executable) {_ = try exe.readInstallation()}
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testConfigurationDiagnosticDoesNotRetainUnderlyingSecretDescription() throws {
        let secret="synthetic-secret-password-and-key"
        do {
            try ReceiveConfigurationFailure.at(.file) {
                throw NSError(domain:secret,code:7,userInfo:[NSLocalizedDescriptionKey:secret])
            }
            XCTFail("must block")
        } catch {
            XCTAssertEqual(String(describing:error),"configuration.file / unverified")
            XCTAssertFalse(String(reflecting:error).contains(secret))
        }
    }

    func testNativeDefaultScopeIsSharedAndDoesNotRewriteRecords() throws {
        let (_,root,executable)=try nativeEvidence()
        let installation=root.appendingPathComponent("installation.json"),local=root.appendingPathComponent("local.json")
        let a=try Data(contentsOf:installation),b=try Data(contentsOf:local)
        let pins=ReceiveNativePreparationEvidence.Pins(installationSHA256:byteHash(a),localSHA256:byteHash(b))
        func make() -> ReceiveNativePreparationEvidence {
            .init(pins:pins,readHome:{root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()},
                  readExecutable:{executable},readBundle:{ProtectedBoundaryContainer.bundleID})
        }
        let first=make(),second=make()
        let scope=ReceiveProcessLifetime.current.identifier
        XCTAssertTrue(scope.hasPrefix("app-process-v1:"))
        XCTAssertNotNil(UUID(uuidString:String(scope.dropFirst("app-process-v1:".count))))
        XCTAssertEqual(try first.readLocal().boot,scope)
        XCTAssertEqual(try second.readLocal().boot,scope)
        XCTAssertEqual(try first.readLocal().boot,scope)
        XCTAssertEqual(try Data(contentsOf:installation),a)
        XCTAssertEqual(try Data(contentsOf:local),b)
        XCTAssertNotEqual(ReceiveProcessLifetime().identifier,scope)
    }
    func testNewProcessScopeRejectsPreviousDraft() throws {
        let first=ReceiveProcessLifetime(),next=ReceiveProcessLifetime()
        draft.bootID=first.identifier
        let current=ReceiveExecutionCandidate.RuntimeSnapshot(account:runtime.account,localProjectID:runtime.localProjectID,
            bundleID:runtime.bundleID,bootID:first.identifier,sessionEpoch:runtime.sessionEpoch,sessionExpiresUTCMS:runtime.sessionExpiresUTCMS)
        XCTAssertTrue(try ReceiveExecutionCandidate.compare(draft,to:target,now:clock.sample(),runtime:current).local_fields_matched)
        let restarted=ReceiveExecutionCandidate.RuntimeSnapshot(account:current.account,localProjectID:current.localProjectID,
            bundleID:current.bundleID,bootID:next.identifier,sessionEpoch:current.sessionEpoch,sessionExpiresUTCMS:current.sessionExpiresUTCMS)
        XCTAssertThrowsError(try ReceiveExecutionCandidate.compare(draft,to:target,now:clock.sample(),runtime:restarted))
    }
    func testLifetimeChangeAfterReviewBlocksBeforeKeyAndHTTP() throws {
        // Offline execution requires synthetic scopes; retain that explicit fixture boundary.
        var scope=runtime.bootID
        let (evidence,_,_)=try nativeEvidence(boot:{scope})
        let preparation=evidence.preparation(configuration:.init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.observe),sessionOwner:observer.owner,clock:clock)
        let fixture=try configuration()
        let prepared=try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        scope="synthetic-"+ReceiveProcessLifetime().identifier
        XCTAssertThrowsError(try confirm(site,review))
        XCTAssertEqual(ReceiveABStub.count,0)
        XCTAssertThrowsError(try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self))
    }

    func testNativeEvidenceConstructionIsInertAndReadsPinnedIdentity() throws {
        let (evidence,_,_)=try nativeEvidence()
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(try evidence.readInstallation(),identity)
        XCTAssertEqual(try evidence.readLocal().local,draft.localProjectID)
        XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testNativeEvidenceRejectsMissingChangedAndLinkedRecords() throws {
        let (evidence,root,_)=try nativeEvidence()
        let url=root.appendingPathComponent("local.json"),original=try Data(contentsOf:url)
        try Data("{\"approved\":true}".utf8).write(to:url)
        XCTAssertThrowsError(try evidence.readLocal())
        try FileManager.default.removeItem(at:url)
        XCTAssertThrowsError(try evidence.readLocal())
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        let other=root.appendingPathComponent("other.json");try original.write(to:other)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:other)
        XCTAssertThrowsError(try evidence.readLocal());XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testNativeEvidenceRejectsBundleAndInstallationMismatch() throws {
        let wrongBundle=try nativeEvidence(bundle:"com.example.wrong").0
        XCTAssertThrowsError(try wrongBundle.readInstallation())
        let wrongInstall=try nativeEvidence(installationID:"another-install").0
        XCTAssertThrowsError(try wrongInstall.readLocal())
    }
    func testNativeEvidenceRejectsWrongExecutableAndLaterReplacement() throws {
        let (first,_,binary)=try nativeEvidence()
        try Data("different bytes".utf8).write(to:binary)
        XCTAssertThrowsError(try first.readInstallation())
        let (second,_,binary2)=try nativeEvidence()
        _ = try second.readInstallation()
        try Data("replacement bytes".utf8).write(to:binary2)
        XCTAssertThrowsError(try second.readInstallation())
    }
    func testPinnedNativeEvidenceConnectsToOfflineApprovalAndApply() async throws {
        let (evidence,_,_)=try nativeEvidence()
        let preparation=evidence.preparation(configuration:.init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.receiveAndApply),sessionOwner:observer.owner,clock:clock)
        XCTAssertTrue(reads.isEmpty)
        let fixture=try configuration()
        let prepared=try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        XCTAssertEqual(ReceiveABStub.count,0)
        _ = try await confirm(site,review).run()
        XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testPinnedEvidenceChangedAfterReviewStopsBeforeHTTP() throws {
        let (evidence,root,_)=try nativeEvidence()
        let preparation=evidence.preparation(configuration:.init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.observe),sessionOwner:observer.owner,clock:clock)
        let fixture=try configuration()
        let prepared=try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        try Data("changed".utf8).write(to:root.appendingPathComponent("installation.json"))
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,0)
    }

    @MainActor func testDedicatedLoginOwnerConnectsToApprovalAndLogoutRevokesReview() async throws {
        let auth=ReceiveDedicatedAuthentication(account:draft.account!,clock:clock,authenticate:{_ in
            .init(account:self.draft.account!,accessToken:"synthetic.login.session",expiresUTCMS:61000)
        })
        let ready=expectation(description:"login completed")
        auth.onStateChange={if $0 == .signedIn {ready.fulfill()}}
        try auth.signIn(.init(email:"fixture@example.invalid",password:"synthetic-password"))
        await fulfillment(of:[ready],timeout:2)
        let (evidence,_,_)=try nativeEvidence()
        let preparation=evidence.preparation(configuration:.init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.observe),sessionOwner:auth.owner,clock:clock)
        let fixture=try configuration()
        let prepared=try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        auth.onInvalidate={site.cancel()}
        auth.cancel()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,0)
    }

    @MainActor func testPasswordTransportBindsReviewedEndpointAccountAndKeyWithoutSending() async throws {
        let authTarget=try ReceivePasswordAuthTarget(origin:URL(string:draft.endpoint!)!,account:draft.account!,publishableKey:"sb_publishable_approval_fixture")
        let transport=try ReceivePasswordAuthTransport.offline(target:authTarget,clock:clock,protocolClass:ReceiveABStub.self)
        let config=ReceiveAppPreparation.Configuration(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.observe)
        let flow=try transport.authentication(configuration:config)
        XCTAssertEqual(flow.destination,draft.endpoint);XCTAssertEqual(flow.state,.signedOut)
        let wrongKey=ReceiveAppPreparation.Configuration(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_other",mode:.observe)
        XCTAssertThrowsError(try transport.authentication(configuration:wrongKey))
        var changed=draft!;changed.endpoint="https://receive-boundary.invalid"
        let wrongEndpoint=ReceiveAppPreparation.Configuration(identity:identity,target:target,draft:changed,publishableKey:"sb_publishable_approval_fixture",mode:.observe)
        XCTAssertThrowsError(try transport.authentication(configuration:wrongEndpoint))
        XCTAssertEqual(ReceiveABStub.count,0)
    }

    private func capturedABRequests() -> [URLRequest] {
        ReceiveABStub.lock.lock();defer{ReceiveABStub.lock.unlock()};return ReceiveABStub.requests
    }
    private var integratedConfiguration:ReceiveAppPreparation.Configuration {
        .init(identity:identity,target:target,draft:draft,publishableKey:"sb_publishable_approval_fixture",mode:.receiveAndApply)
    }
    @MainActor private func integratedAuthentication(wrongAccount:Bool=false) throws -> ReceiveDedicatedAuthentication {
        let body=WindowsJSON.object(["access_token":.string("synthetic.http.login"),"token_type":.string("bearer"),"expires_at":.number("61"),"expires_in":.number("60"),"user":.object(["id":.string((wrongAccount ? UUID():draft.account!).uuidString.lowercased())]),"refresh_token":.string("synthetic.unretained")]).encoded()
        IntegratedPasswordStub.reset(body)
        let transport=try ReceivePasswordAuthTransport.offline(target:.init(origin:URL(string:draft.endpoint!)!,account:draft.account!,publishableKey:integratedConfiguration.publishableKey),clock:clock,protocolClass:IntegratedPasswordStub.self)
        return try transport.authentication(configuration:integratedConfiguration)
    }
    @MainActor private func completeIntegratedLogin(_ auth:ReceiveDedicatedAuthentication,expected:ReceiveDedicatedAuthentication.State = .signedIn) async throws {
        let done=expectation(description:"HTTP login completes")
        auth.onStateChange={if $0==expected {done.fulfill()}}
        try auth.signIn(.init(email:"integration@example.invalid",password:"synthetic-password"))
        await fulfillment(of:[done],timeout:2)
        XCTAssertEqual(auth.state,expected)
    }
    @MainActor private func integratedPreparation(_ auth:ReceiveDedicatedAuthentication,evidence:ReceiveNativePreparationEvidence) throws -> ReceivePreparedApproval {
        let fixture=try configuration()
        let preparation=evidence.preparation(configuration:integratedConfiguration,sessionOwner:auth.owner,clock:clock)
        return try preparation.prepareOffline(paths:fixture.paths,journal:fixture.journalRoot,protocolClass:ReceiveABStub.self)
    }
    @MainActor func testIntegratedHTTPLoginThroughNativeEvidenceApprovalAndStoredReadback() async throws {
        let auth=try integratedAuthentication(),(evidence,_,_)=try nativeEvidence()
        XCTAssertTrue(reads.isEmpty);XCTAssertTrue(IntegratedPasswordStub.captured.isEmpty)
        try await completeIntegratedLogin(auth)
        XCTAssertTrue(reads.isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
        let prepared=try integratedPreparation(auth,evidence:evidence)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        auth.onInvalidate={site.cancel()}
        XCTAssertTrue(try empty(lastRoot));XCTAssertTrue(try empty(lastJournal));XCTAssertEqual(ReceiveABStub.count,0)
        XCTAssertFalse(review.text.contains("synthetic.http.login"));XCTAssertFalse(review.text.contains("synthetic-password"))
        let receipt=try await confirm(site,review).run();try await receipt.verify()
        XCTAssertEqual(IntegratedPasswordStub.captured.count,1);XCTAssertEqual(ReceiveABStub.count,14)
        let requests=capturedABRequests()
        XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Authorization")=="Bearer synthetic.http.login"})
        let record=try ledger();XCTAssertEqual(record.httpUsed,14);XCTAssertEqual(record.authUsed,2)
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,14)
    }
    @MainActor func testPostLoginFactoryHTTPLoginThroughStoredReadback() async throws {
        let auth=try integratedAuthentication(),(evidence,_,_)=try nativeEvidence()
        XCTAssertTrue(reads.isEmpty);XCTAssertTrue(IntegratedPasswordStub.captured.isEmpty)
        try await completeIntegratedLogin(auth)
        XCTAssertTrue(reads.isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
        let factory=ReceivePostLoginPreparation(envelope:try bootstrapEnvelope(),target:target,evidence:evidence,owner:auth.owner,clock:clock,newRun:{self.draft.runID!})
        let prepared=try prepareComposition(factory.preparation())
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        auth.onInvalidate={site.cancel()}
        XCTAssertTrue(try empty(lastRoot));XCTAssertTrue(try empty(lastJournal));XCTAssertEqual(ReceiveABStub.count,0)
        XCTAssertFalse(review.text.contains("synthetic.http.login"));XCTAssertFalse(review.text.contains("synthetic-password"))
        let receipt=try await confirm(site,review).run();try await receipt.verify()
        XCTAssertEqual(IntegratedPasswordStub.captured.count,1);XCTAssertEqual(ReceiveABStub.count,14)
        let requests=capturedABRequests()
        XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Authorization")=="Bearer synthetic.http.login"})
        let record=try ledger();XCTAssertEqual(record.httpUsed,14);XCTAssertEqual(record.authUsed,2)
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(ReceiveABStub.count,14)
    }
    @MainActor func testIntegratedWrongLoginAccountStopsBeforeEvidenceOrReceive() async throws {
        let auth=try integratedAuthentication(wrongAccount:true)
        try await completeIntegratedLogin(auth,expected:.failed)
        XCTAssertTrue(reads.isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
        XCTAssertEqual(IntegratedPasswordStub.captured.count,1)
        XCTAssertThrowsError(try auth.owner.source.capture(account:draft.account!,clock:clock))
    }
    @MainActor func testIntegratedEvidenceChangeAfterLoginBlocksPreparation() async throws {
        let auth=try integratedAuthentication(),(evidence,root,_)=try nativeEvidence()
        try await completeIntegratedLogin(auth)
        try Data("changed".utf8).write(to:root.appendingPathComponent("local.json"))
        XCTAssertThrowsError(try integratedPreparation(auth,evidence:evidence))
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try empty(lastRoot))
    }
    @MainActor func testIntegratedLogoutAfterConfirmationBlocksRunAndPreservesEmptyRoots() async throws {
        let auth=try integratedAuthentication(),(evidence,_,_)=try nativeEvidence()
        try await completeIntegratedLogin(auth)
        let prepared=try integratedPreparation(auth,evidence:evidence)
        let site=ReceiveApprovalCallSite(prepared:prepared),review=try site.present()
        auth.onInvalidate={site.cancel()}
        let run=try confirm(site,review);auth.cancel()
        do {_ = try await run.run();XCTFail("revoked run succeeded")}catch {}
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try empty(lastRoot));XCTAssertTrue(try empty(lastJournal))
    }
    @MainActor func testIntegratedReloginCannotReuseOldSessionEpochConfiguration() async throws {
        let auth=try integratedAuthentication(),(evidence,_,_)=try nativeEvidence()
        try await completeIntegratedLogin(auth)
        let old=try auth.owner.source.capture(account:draft.account!,clock:clock)
        auth.cancel();try await completeIntegratedLogin(auth)
        XCTAssertThrowsError(try old.check())
        XCTAssertThrowsError(try integratedPreparation(auth,evidence:evidence))
        XCTAssertEqual(IntegratedPasswordStub.captured.count,2);XCTAssertEqual(ReceiveABStub.count,0)
    }

    func testDefaultCallSiteHasNoApprovalOrSideEffects() throws {
        XCTAssertThrowsError(try ReceiveApprovalCallSite().present());XCTAssertTrue(reads.isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testPreparingAndPresentingDoesNotReadProvidersOrWriteFiles() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        XCTAssertTrue(reads.isEmpty);XCTAssertTrue(try empty(lastRoot));XCTAssertTrue(try empty(lastJournal));XCTAssertEqual(ReceiveABStub.count,0)
        XCTAssertTrue(review.text.contains("HTTP 최대 14회(Auth 2회 포함)"));XCTAssertTrue(review.text.contains("members 4개"))
        XCTAssertTrue(review.text.contains(identity.candidateSHA256));XCTAssertTrue(review.text.contains(draft.handoffSHA256!));XCTAssertTrue(review.text.contains("synthetic-stage-three"))
        XCTAssertFalse(review.text.contains("synthetic.admission.session"));XCTAssertFalse(review.text.contains("sb_publishable_"));XCTAssertEqual(review.digest.count,64)
    }
    func testUnresolvedDraftAndWrongPinFailBeforeProviders() throws {
        draft.runID=nil;XCTAssertThrowsError(try configuration());XCTAssertTrue(reads.isEmpty)
        draft.runID=UUID(uuidString:"ee260915-0000-4000-8000-000000000481");draft.handoffSHA256=String(repeating:"0",count:64)
        XCTAssertThrowsError(try configuration());XCTAssertTrue(reads.isEmpty)
    }
    func testInvalidCandidateIdentityCannotBePresented() throws {
        let bad=ReceiveApprovalIdentity(approvalID:"",device:"iPad",installationID:"synthetic",candidateSHA256:"missing")
        let site=ReceiveApprovalCallSite(prepared:try configuration(identity:bad))
        XCTAssertThrowsError(try site.present());XCTAssertTrue(reads.isEmpty)
    }
    func testLiveFactoryRejectsSyntheticClockBeforeAnyProviderOrGrant() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration(live:true))
        XCTAssertThrowsError(try site.present());XCTAssertTrue(reads.isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testReopeningReviewInvalidatesPreviousScreenTicket() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),first=try site.present(),second=try site.present()
        XCTAssertEqual(first.digest,second.digest);XCTAssertThrowsError(try confirm(site,first));XCTAssertTrue(reads.isEmpty)
        let run=try confirm(site,second);run.cancel();XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testTicketCannotMoveToOtherController() throws {
        let config=try configuration(),a=ReceiveApprovalCallSite(prepared:config),b=ReceiveApprovalCallSite(prepared:config)
        let first=try a.present();_ = try b.present()
        XCTAssertThrowsError(try confirm(b,first));XCTAssertTrue(reads.isEmpty)
    }
    func testCancelBeforeConfirmationIsPermanentAndInert() throws {
        let config=try configuration(),site=ReceiveApprovalCallSite(prepared:config),review=try site.present();site.cancel()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertThrowsError(try site.present());XCTAssertTrue(reads.isEmpty)
        XCTAssertThrowsError(try ReceiveApprovalCallSite(prepared:config).present())
    }
    func testExpiryWhileScreenOpenFailsWithoutProviderAccess() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present();try clock.advance(60000)
        XCTAssertThrowsError(try confirm(site,review));XCTAssertTrue(reads.isEmpty);XCTAssertTrue(try empty(lastJournal))
    }
    func testBackwardClockAfterReviewDoesNotReadProvider() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present();try clock.setForTest(utcMS:999,monoMS:0)
        XCTAssertThrowsError(try confirm(site,review));XCTAssertTrue(reads.isEmpty)
    }
    func testLifecycleLossRejectsEvenIfProtectedDataReturns() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present(),lease=try lifecycle.begin()
        lifecycle.update(active:false,protectedDataAvailable:false);lifecycle.update(active:true,protectedDataAvailable:true)
        XCTAssertThrowsError(try site.confirm(review,lease:lease,protection:.init()));XCTAssertTrue(reads.isEmpty)
    }
    func testInstallationMismatchStopsBeforeKeyCacheAndJournal() throws {
        installAction={throw Injected.stop}
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(reads["installation"],1)
        XCTAssertNil(reads["identity"]);XCTAssertNil(reads["key"]);XCTAssertNil(reads["cache"]);XCTAssertTrue(try empty(lastJournal))
    }
    func testIdentityFailureConsumesPreparationAcrossControllers() throws {
        identityAction={throw Injected.stop}
        let config=try configuration(),site=ReceiveApprovalCallSite(prepared:config),review=try site.present()
        XCTAssertThrowsError(try confirm(site,review));identityAction={}
        XCTAssertThrowsError(try ReceiveApprovalCallSite(prepared:config).present());XCTAssertNil(reads["key"]);XCTAssertNil(reads["cache"])
    }
    func testSessionEpochChangeBetweenReviewAndConfirmationStopsBeforeKey() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present(),r=runtime!
        runtime = .init(account:r.account,localProjectID:r.localProjectID,bundleID:r.bundleID,bootID:r.bootID,sessionEpoch:2,sessionExpiresUTCMS:r.sessionExpiresUTCMS)
        XCTAssertThrowsError(try confirm(site,review));XCTAssertNil(reads["key"]);XCTAssertNil(reads["cache"]);XCTAssertTrue(try empty(lastJournal))
    }
    func testLegacyKeyFailsBeforeSessionOrTransport() throws {
        keyAction={"legacy.anon.key"}
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertEqual(reads["key"],1);XCTAssertNil(reads["cache"]);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testInstallationIOConsumesTotalBeforeSessionAndHTTP() throws {
        draft.timing!.totalMS=100
        installAction={try self.clock.advance(100)}
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        XCTAssertThrowsError(try confirm(site,review));XCTAssertNil(reads["key"]);XCTAssertNil(reads["cache"]);XCTAssertTrue(try empty(lastJournal))
    }
    func testTotalStartsAtConfirmationNotAtScreenPresentation() async throws {
        draft.timing!.totalMS=1000
        let site=ReceiveApprovalCallSite(prepared:try configuration(mode:.observe)),review=try site.present()
        try clock.advance(2000);let run=try confirm(site,review),receipt=try await run.run();try await receipt.verify()
        XCTAssertEqual(try ledger().start.monoMS,2000);XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testProviderTimeRemainsInRunLedgerAndDeadline() async throws {
        draft.timing!.totalMS=1000
        var once=false
        installAction={if !once {once=true;try self.clock.advance(600)}}
        let site=ReceiveApprovalCallSite(prepared:try configuration(mode:.observe)),review=try site.present(),run=try confirm(site,review)
        run.checkpoint={if $0=="reserved:0"{try self.clock.advance(400)}}
        do{_ = try await run.run();XCTFail()}catch{}
        XCTAssertEqual(try ledger().start.monoMS,0);XCTAssertEqual(try ledger().httpUsed,1);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testConfirmationRuns14AndAppliesOnlyDedicatedMembersOnce() async throws {
        let config=try configuration(),site=ReceiveApprovalCallSite(prepared:config),review=try site.present(),run=try confirm(site,review)
        XCTAssertNil(reads["cache"]);XCTAssertTrue(try empty(lastJournal))
        let receipt=try await run.run();try await receipt.verify();try receipt.checkPublication()
        XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(try ledger().authUsed,2)
        XCTAssertEqual(try ledger().approvalDigest,review.digest)
        XCTAssertTrue(FileManager.default.fileExists(atPath:lastRoot.appendingPathComponent("complete.json").path))
        XCTAssertThrowsError(try confirm(site,review));XCTAssertThrowsError(try ReceiveApprovalCallSite(prepared:config).present())
        XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testObservationModeCannotPublishProductBaseline() async throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration(mode:.observe)),review=try site.present()
        XCTAssertTrue(review.text.contains("local 적용 없음"))
        let receipt=try await confirm(site,review).run();try await receipt.verify()
        XCTAssertTrue(try empty(lastRoot));XCTAssertEqual(ReceiveABStub.count,14)
        guard let completion=receipt as? ReceiveAuthorizedCompletion else{return XCTFail()}
        XCTAssertThrowsError(try completion.proof());XCTAssertThrowsError(try completion.requireBaseline())
    }
    func testMissingCacheStopsWithoutHTTPAndRetainsLocalJournal() async throws {
        cacheMissing=true
        let site=ReceiveApprovalCallSite(prepared:try configuration()),run=try confirm(site,site.present())
        do{_ = try await run.run();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try empty(lastRoot));XCTAssertEqual(try ledger().httpUsed,0)
    }
    func testReentrantCancelDuringProviderCannotIssueRun() throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        installAction={site.cancel()}
        XCTAssertThrowsError(try confirm(site,review));XCTAssertNil(reads["key"]);XCTAssertNil(reads["cache"])
    }
    func testCancelDuringTransportPreservesFirstChargeAndStopsRemaining() async throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),run=try confirm(site,site.present())
        ReceiveABStub.reset(responses,hold:0,action:{_ in site.cancel()})
        do{_ = try await run.run();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger().httpUsed,1);XCTAssertTrue(try empty(lastRoot))
    }
    func testInstallationChangeDuringRunRevokesRemainingHTTP() async throws {
        let site=ReceiveApprovalCallSite(prepared:try configuration()),run=try confirm(site,site.present())
        run.checkpoint={if $0=="response:0"{self.installAction={throw Injected.stop}}}
        do{_ = try await run.run();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger().httpUsed,1);XCTAssertTrue(try empty(lastRoot))
    }
    func testReviewDigestIncludesScopeAndInstallation() throws {
        let config=try configuration(mode:.observe)
        func changed(_ id:ReceiveApprovalIdentity,_ mode:ReceivePreparedApproval.Mode) throws -> ReceiveApprovalReview {
            let other=try ReceivePreparedApproval.offline(identity:id,target:config.target,draft:config.draft,expectedRuntime:config.expectedRuntime,paths:config.paths,journalRoot:config.journalRoot,clock:clock,mode:mode,providers:config.providers,protocolClass:ReceiveABStub.self)
            return try ReceiveApprovalCallSite(prepared:other).present()
        }
        let original=try ReceiveApprovalCallSite(prepared:config).present()
        XCTAssertNotEqual(original.digest,try changed(identity,.receiveAndApply).digest)
        let another=ReceiveApprovalIdentity(approvalID:identity.approvalID,device:identity.device,installationID:"other-installation",candidateSHA256:identity.candidateSHA256)
        XCTAssertNotEqual(original.digest,try changed(another,.observe).digest)
    }
    func testSimultaneousConfirmationsCannotCallProvidersTwice() throws {
        let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
        let site=ReceiveApprovalCallSite(prepared:try configuration()),review=try site.present()
        var first=true
        installAction={if first {first=false;entered.signal();guard release.wait(timeout:.now()+5) == .success else {throw Injected.stop}}}
        DispatchQueue.global().async {
            defer{finished.signal()}
            do{_ = try self.confirm(site,review)}catch{XCTFail("First confirmation failed")}
        }
        XCTAssertEqual(entered.wait(timeout:.now()+5),.success)
        XCTAssertThrowsError(try confirm(site,review));release.signal()
        XCTAssertEqual(finished.wait(timeout:.now()+5),.success)
        XCTAssertEqual(reads["key"],1);XCTAssertNil(reads["cache"]);XCTAssertEqual(ReceiveABStub.count,0);site.cancel()
    }
    func testCachedProviderConstructionIsPassiveAndUsesSameOwnerMetadata() throws {
        var calls=0
        let source=ReceiveSessionSource(readCached:{calls+=1;return .init(account:self.runtime.account,accessToken:"synthetic.owner",expiresUTCMS:61000)},ownerEpoch:{7})
        let p=ReceiveApprovalProviders.cached(source:source,clock:clock,readLocalRuntime:{.init(local:self.runtime.localProjectID,bundle:self.runtime.bundleID,boot:self.runtime.bootID)},readPublishableKey:{XCTFail();return ""},verifyInstallation:{_ in XCTFail()},verifyIdentity:{XCTFail()})
        XCTAssertEqual(calls,0);XCTAssertTrue(p.source === source)
        let result=try p.readRuntime();XCTAssertEqual(calls,1);XCTAssertEqual(result.sessionEpoch,7);XCTAssertEqual(result.sessionExpiresUTCMS,61000);XCTAssertEqual(result.account,runtime.account)
    }
    func testCachedProviderRejectsMissingExpiredAndOwnerRace() throws {
        let missing=ReceiveSessionSource(readCached:{nil},ownerEpoch:{0})
        XCTAssertThrowsError(try missing.approvalRuntime(local:runtime.localProjectID,bundle:runtime.bundleID,boot:runtime.bootID,clock:clock))
        let expired=ReceiveSessionSource(readCached:{.init(account:self.runtime.account,accessToken:"synthetic.owner",expiresUTCMS:1000)},ownerEpoch:{0})
        XCTAssertThrowsError(try expired.approvalRuntime(local:runtime.localProjectID,bundle:runtime.bundleID,boot:runtime.bootID,clock:clock))
        var epoch=0
        let raced=ReceiveSessionSource(readCached:{epoch+=1;return .init(account:self.runtime.account,accessToken:"synthetic.owner",expiresUTCMS:61000)},ownerEpoch:{epoch})
        XCTAssertThrowsError(try raced.approvalRuntime(local:runtime.localProjectID,bundle:runtime.bundleID,boot:runtime.bootID,clock:clock))
    }
    func testCachedOwnerBridgeRunsApprovalAndCancelsOnSameTokenReplacement() async throws {
        let base=try configuration()
        let providers=ReceiveApprovalProviders.cached(source:observer.owner.source,clock:clock,readLocalRuntime:{.init(local:self.runtime.localProjectID,bundle:self.runtime.bundleID,boot:self.runtime.bootID)},readPublishableKey:{"sb_publishable_approval_fixture"},verifyInstallation:{_ in},verifyIdentity:{})
        let config=try ReceivePreparedApproval.offline(identity:identity,target:target,draft:draft,expectedRuntime:runtime,paths:base.paths,journalRoot:base.journalRoot,clock:clock,mode:.receiveAndApply,providers:providers,protocolClass:ReceiveABStub.self)
        let site=ReceiveApprovalCallSite(prepared:config),run=try confirm(site,site.present())
        run.checkpoint={if $0=="response:0"{try self.observer.owner.replaceCachedSession(.init(account:self.runtime.account,accessToken:"synthetic.admission.session",expiresUTCMS:61000))}}
        do{_ = try await run.run();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger().httpUsed,1);XCTAssertTrue(try empty(lastRoot))
    }
}
