import XCTest
import Foundation
import SwiftData
@testable import SyntheticInitialReceive

final class AuthorizedRunTests:XCTestCase {
    enum Injected:Error {case stop}
    private var target:ReviewedReceiveTarget!,draft:ReceiveExecutionCandidate.Draft!,runtime:ReceiveExecutionCandidate.RuntimeSnapshot!
    private var observer:ReceiveAuthCallSiteObserver!,clock:ABRuntimeClock!,responses:[SyntheticABResponse]=[],directories:[URL]=[]
    private var lifecycle:BoundaryLifecycle!
    override func setUpWithError() throws {
        let portable=try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!)
        let files=try WindowsHandoffReader.files(from:portable)
        let pin=try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!))
        target=try .read(portable:portable,expected:.init(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:pin.get("binding").encoded()))
        let timing=SyntheticABTiming(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:500,localApplyMS:1000,totalMS:60000,notBeforeUTCMS:1000,expiresUTCMS:61000)
        draft = .init(endpoint:"https://synthetic.invalid",account:UUID(uuidString:try target.binding.str("account_id")),project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000381"),localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000382"),bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-admission-boot",sessionEpoch:1,timing:timing,httpLimit:14,authLimit:2)
        runtime = .init(account:draft.account!,localProjectID:draft.localProjectID!,bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:1,sessionExpiresUTCMS:61000)
        clock=ABRuntimeClock(utcMS:1000,monoMS:0);observer=ReceiveAuthCallSiteObserver()
        let op=UUID();observer.begin(op);observer.accept(op,account:draft.account!,accessToken:"synthetic.admission.session",expiresAt:Date(timeIntervalSince1970:61))
        lifecycle=BoundaryLifecycle();lifecycle.update(active:true,protectedDataAvailable:true)
        let values=try ["Q1.body","Q2.body","Q3.body","Q4.body","Q14.body","Q15.body","Q16.body"].map{try WindowsJSON.decode(files["source/"+$0]!)}
        responses=try values.enumerated().map{i,v in let count=i>=2 ? try v.array().count:nil;return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map{$0==0 ? "*/0":"0-\($0-1)/\($0)"},delayMS:0)};responses += responses
        ReceiveABStub.reset(responses)
    }
    override func tearDownWithError() throws {ReceiveABStub.reset();for d in directories {try FileManager.default.removeItem(at:d)}}
    private func directory(_ prefix:String="ReceiveInputAdmission-") throws -> URL {
        let d=URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent(prefix+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false);directories.append(d);return d
    }
    private func descriptor(_ d:URL,mode:ReceiveLocalStoreDescriptor.Mode = .offline,local:String?=nil,bundle:String?=nil)->ReceiveLocalStoreDescriptor {
        .init(mode:mode,localProjectID:local ?? draft.localProjectID!.uuidString.lowercased(),bundleID:bundle ?? draft.bundleID!,workspace:d.path)
    }
    private func execution() throws -> ReceiveReviewedExecution {
        let snapshot=runtime!
        return try .offline(target:target,draft:draft,now:clock.sample(),readRuntime:{snapshot})
    }
    private func received() async throws -> (ReceiveReviewedExecution,ReceiveABCompletion,ReceiveAdmissionPlan) {
        let e=try execution(),home=try directory("AdmissionJournal-")
        let c=try ReceiveABCoordinator(offlineReviewed:e,syntheticHome:home,lease:lifecycle.begin(),protection:.init(),owner:observer.owner,clock:clock,protocolClass:ReceiveABStub.self)
        let completion=try await c.run()
        return (e,completion,try ReceiveAdmissionPlan.offline(execution:e,completion:completion))
    }
    private func authority(_ e:ReceiveReviewedExecution,scopes:Set<ReceiveActivationAuthority.Scope>=[.cachedSession,.httpRead,.productStorage]) throws -> ReceiveActivationAuthority {
        try .offline(execution:e,scopes:scopes,clock:clock,readRuntime:{self.runtime})
    }
    private func paths(_ root:URL)->ReceiveDedicatedPaths {
        .init(root:root,metadata:root.appendingPathComponent("metadata/store.sqlite"),syncDB:root.appendingPathComponent("sync.sqlite"),texts:root.appendingPathComponent("texts"),journal:root.appendingPathComponent("journal"),identity:root.appendingPathComponent("identity.json"))
    }
    private func environment(_ root:URL,_ grant:ReceiveActivationAuthority?,source:ReceiveSessionSource?=nil,identity:@escaping ()throws->Void={}) throws -> ReceiveDedicatedEnvironment {
        try .init(paths:paths(root),local:runtime.localProjectID,bundle:runtime.bundleID,source:source ?? observer.owner.source,authority:grant,clock:clock,lease:lifecycle.begin(),protection:.init(),verifyIdentity:identity)
    }
    private func httpTarget() throws -> ReceiveHTTPTarget {try .init(origin:URL(string:"https://receive-boundary.invalid")!,account:runtime.account,project:draft.project!,publishableKey:"sb_publishable_offline_fixture")}
    private func tree(_ root:URL) throws -> [String:Data] {
        var result:[String:Data]=[:]
        for case let u as URL in FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])! where try u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {result[u.path]=try Data(contentsOf:u)}
        return result
    }
    private func prepared(scopes:Set<ReceiveActivationAuthority.Scope>=[.cachedSession,.httpRead,.productStorage]) throws -> (ReceiveAuthorizedRun,ReceiveDedicatedEnvironment,URL) {
        let e=try execution(),root=try directory("ReceiveProductStore-"),journal=try directory("ReceiveAuthorizedJournal-"),env=try environment(root,authority(e,scopes:scopes))
        return (try ReceiveAuthorizedRun(environment:env,target:target,httpTarget:httpTarget(),journalRoot:journal,offlineProtocol:ReceiveABStub.self),env,journal)
    }
    private func ledger(_ url:URL) throws -> ReceiveAuthorizedRun.Ledger {try JSONDecoder().decode(ReceiveAuthorizedRun.Ledger.self,from:Data(contentsOf:url.appendingPathComponent("run.json")))}
    private func storedFixture() async throws -> (URL,URL,URL) {
        let (run,env,journal)=try prepared();let receipt=try await run.run();try await receipt.verify()
        let home=try directory("StoredReader-"),parent=home.appendingPathComponent("Library/Application Support/ReceiveDedicated-v1")
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        let root=parent.appendingPathComponent(runtime.localProjectID.uuidString.lowercased())
        let log=parent.appendingPathComponent("execution-"+draft.runID!.uuidString.lowercased())
        try FileManager.default.copyItem(at:env.paths.root,to:root)
        try FileManager.default.copyItem(at:journal,to:log)
        return (home,root,log)
    }
    func testStoredReaderShowsCompletedDocumentsWithoutWritesOrRequests() async throws {
        let (home,_,_)=try await storedFixture(),before=try tree(home),count=ReceiveABStub.count
        let result=try ReceiveStoredReader.read(home:home,local:runtime.localProjectID,target:target,check:{})
        XCTAssertEqual(result.documents.count,2)
        XCTAssertEqual(result.documents.filter{$0.byteCount==0}.count,1)
        XCTAssertEqual(result.runID,draft.runID!.uuidString.lowercased())
        _ = try ReceiveStoredReader.read(home:home,local:runtime.localProjectID,target:target,check:{})
        XCTAssertEqual(try tree(home),before);XCTAssertEqual(ReceiveABStub.count,count)
    }
    func testStoredReaderRejectsIncompleteCorruptLinkedAndChangedFiles() async throws {
        let (home,root,log)=try await storedFixture()
        func read() throws {_ = try ReceiveStoredReader.read(home:home,local:runtime.localProjectID,target:target,check:{})}
        let complete=root.appendingPathComponent("complete.json"),bytes=try Data(contentsOf:complete)
        try FileManager.default.removeItem(at:complete);XCTAssertThrowsError(try read());try bytes.write(to:complete)
        try Data("bad".utf8).write(to:complete);XCTAssertThrowsError(try read());try bytes.write(to:complete)
        let extra=root.appendingPathComponent("unexpected");try Data().write(to:extra);XCTAssertThrowsError(try read());try FileManager.default.removeItem(at:extra)
        let wal=root.appendingPathComponent("sync.sqlite-wal");try Data([1]).write(to:wal);XCTAssertThrowsError(try read());try FileManager.default.removeItem(at:wal)
        let ledger=log.appendingPathComponent("run.json"),original=try Data(contentsOf:ledger)
        var object=try JSONSerialization.jsonObject(with:original) as! [String:Any];object["status"]="running"
        try JSONSerialization.data(withJSONObject:object).write(to:ledger);XCTAssertThrowsError(try read());try original.write(to:ledger)
        try FileManager.default.removeItem(at:complete);try FileManager.default.createSymbolicLink(at:complete,withDestinationURL:root.appendingPathComponent("identity.json"))
        XCTAssertThrowsError(try read());try FileManager.default.removeItem(at:complete);try bytes.write(to:complete)
        XCTAssertThrowsError(try ReceiveStoredReader.read(home:home,local:UUID(),target:target,check:{}))
        XCTAssertThrowsError(try ReceiveStoredReader.read(home:home,local:runtime.localProjectID,target:target,check:{throw Injected.stop}))
        for name in ["sync.sqlite","metadata/store.sqlite"] {
            let db=root.appendingPathComponent(name),saved=try Data(contentsOf:db)
            var corrupted=saved;corrupted[0]=0;try corrupted.write(to:db)
            XCTAssertThrowsError(try read());try saved.write(to:db)
        }
        let text=try XCTUnwrap(FileManager.default.enumerator(at:root.appendingPathComponent("texts"),includingPropertiesForKeys:nil)?.allObjects.compactMap{$0 as? URL}.first{$0.pathExtension=="txt"})
        let body=try Data(contentsOf:text);try Data("tampered".utf8).write(to:text)
        XCTAssertThrowsError(try read());try body.write(to:text)
        var checkpoints=0
        XCTAssertThrowsError(try ReceiveStoredReader.read(home:home,local:runtime.localProjectID,target:target,check:{
            checkpoints+=1
            if checkpoints==30 {try Data("changed during read".utf8).write(to:complete)}
        }))
        XCTAssertGreaterThanOrEqual(checkpoints,30);try bytes.write(to:complete)
        let before=try tree(home);try read();XCTAssertEqual(try tree(home),before)
    }
    func testStoredReaderPrivateBackupWhenSupplied() throws {
        guard let path=ProcessInfo.processInfo.environment["RECEIVE_COMPLETED_BACKUP"],let portable=ProcessInfo.processInfo.environment["RECEIVE_RETAINED_REVIEW_PATH"] else {throw XCTSkip("Private backup not supplied")}
        let home=URL(fileURLWithPath:path),before=try tree(home)
        let realTarget=try ReviewedReceiveTarget.read(portable:Data(contentsOf:URL(fileURLWithPath:portable)),expected:.retainedSeptember14())
        let result=try ReceiveStoredReader.read(home:home,local:UUID(uuidString:"a3d42989-72f1-432e-8373-ae1906526331")!,target:realTarget,check:{})
        XCTAssertEqual(result.documents.count,2);XCTAssertEqual(result.documents.map(\.byteCount).sorted(),[0,28])
        XCTAssertEqual(try tree(home),before)
    }

    func testSharedAuthorizedRouteCollects14ThenWritesRealFormats() async throws {
        let (run,env,journal)=try prepared();let receipt=try await run.run();try await receipt.verify();try receipt.checkPublication()
        XCTAssertEqual(ReceiveABStub.count,14);let recorded=try ledger(journal)
        XCTAssertEqual(recorded.status,"finished");XCTAssertEqual(recorded.httpUsed,14);XCTAssertEqual(recorded.authUsed,2)
        XCTAssertEqual(recorded.events.count,14);XCTAssertTrue(recorded.events.allSatisfy{$0.started != nil && $0.received != nil && $0.verified != nil && $0.raw != nil})
        XCTAssertTrue(FileManager.default.fileExists(atPath:env.paths.syncDB.path));XCTAssertTrue(FileManager.default.fileExists(atPath:env.paths.root.appendingPathComponent("complete.json").path))
        do{_ = try await run.collect();XCTFail()}catch{};XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testReadOnlyScopeNeverCreatesProductFiles() async throws {
        let (run,env,_)=try prepared(scopes:[.cachedSession,.httpRead]);let receipt=try await run.run();try await receipt.verify()
        XCTAssertTrue(try tree(env.paths.root).isEmpty);XCTAssertEqual(ReceiveABStub.count,14)
        guard let completion=receipt as? ReceiveAuthorizedCompletion else{return XCTFail()}
        XCTAssertThrowsError(try completion.proof());XCTAssertThrowsError(try completion.requireBaseline())
    }
    func testReservationIOExpiryRetainsChargeAndSendsNothing() async throws {
        let (run,env,journal)=try prepared()
        run.checkpoint={if $0=="reserved:0" {try self.clock.advance(1000)}}
        do{_ = try await run.collect();XCTFail()}catch{}
        let saved=try ledger(journal);XCTAssertEqual(saved.httpUsed,1);XCTAssertEqual(saved.authUsed,1);XCTAssertNil(saved.events[0].started)
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(env.paths.root).isEmpty)
        XCTAssertThrowsError(try env.authority!.require(.httpRead))
    }
    func testHTTP401StopsRetainsCountAndPreventsRetry() async throws {
        responses[0].status=401;ReceiveABStub.reset(responses)
        let (run,_,journal)=try prepared()
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger(journal).httpUsed,1)
        do{_ = try await run.collect();XCTFail()}catch{};XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testCountMismatchHasNoPaginationOrAdditionalRequest() async throws {
        responses[2].contentRange="0-0/2";ReceiveABStub.reset(responses)
        let (run,env,journal)=try prepared()
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,3);let saved=try ledger(journal);XCTAssertEqual(saved.httpUsed,3);XCTAssertNotNil(saved.events[2].raw)
        XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testABMetadataChangeStopsBeforeProductStorage() async throws {
        var projects=try WindowsJSON.decode(responses[9].raw).array();var row=try projects[0].object();row["synthetic_new_field"] = .string("changed");projects[0] = .object(row);responses[9].raw=WindowsJSON.array(projects).encoded(lf:true);ReceiveABStub.reset(responses)
        let (run,env,journal)=try prepared()
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,14);XCTAssertNotEqual(try ledger(journal).status,"finished");XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testSessionAndProtectedLossCancelRemainingRequests() async throws {
        let (run,env,journal)=try prepared()
        run.checkpoint={if $0=="response:0"{self.observer.invalidate();self.lifecycle.update(active:false,protectedDataAvailable:false)}}
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger(journal).httpUsed,1);XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testJournalCorruptionAndPendingAreNotRepaired() async throws {
        let (run,env,journal)=try prepared()
        run.checkpoint={if $0=="reserved:0"{try Data("broken".utf8).write(to:journal.appendingPathComponent("run.json.pending"))}}
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(FileManager.default.fileExists(atPath:journal.appendingPathComponent("run.json.pending").path));XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testCopiedOrCompletedJournalCannotStartNewRun() async throws {
        let (run,_,journal)=try prepared(scopes:[.cachedSession,.httpRead]);_ = try await run.collect();let before=try tree(journal)
        let e=try execution(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let repeated=try ReceiveAuthorizedRun(environment:env,target:target,httpTarget:httpTarget(),journalRoot:journal,offlineProtocol:ReceiveABStub.self)
        do{_ = try await repeated.collect();XCTFail()}catch{}
        XCTAssertEqual(try tree(journal),before);XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testFreshProofCannotMoveToOtherIdentityOrAuthority() async throws {
        let (run,_,_)=try prepared();let c=try await run.collect(),proof=try c.proof()
        let root=try directory("ReceiveProductStore-"),g=try authority(execution())
        let env=try ReceiveDedicatedEnvironment(paths:paths(root),local:UUID(uuidString:"ee260915-0000-4000-8000-000000000999")!,bundle:runtime.bundleID,source:observer.owner.source,authority:g,clock:clock,lease:lifecycle.begin(),protection:.init(),verifyIdentity:{})
        XCTAssertThrowsError(try env.prepare(proof:proof));XCTAssertTrue(try tree(root).isEmpty)
    }
    func testPreApplyDeadlineCannotBeResetByPreparingStore() async throws {
        let (run,env,_)=try prepared();let c=try await run.collect();try clock.advance(500)
        XCTAssertThrowsError(try c.proof());XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testConstructorIdentityIOAndWaitCountAgainstTotal() async throws {
        let (run,env,journal)=try prepared();try clock.advance(60000)
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertTrue(try tree(journal).isEmpty);XCTAssertTrue(try tree(env.paths.root).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testWrongTargetAndMissingProtocolFailBeforeJournalOrHTTP() throws {
        let (run,env,journal)=try prepared();_ = run
        let wrong=try ReceiveHTTPTarget(origin:URL(string:"https://foreign.invalid")!,account:runtime.account,project:draft.project!,publishableKey:"sb_publishable_synthetic")
        XCTAssertThrowsError(try ReceiveAuthorizedRun(environment:env,target:target,httpTarget:wrong,journalRoot:journal,offlineProtocol:ReceiveABStub.self))
        XCTAssertThrowsError(try ReceiveAuthorizedRun(environment:env,target:target,httpTarget:httpTarget(),journalRoot:journal))
        XCTAssertTrue(try tree(journal).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testLocalBudgetIncludesDatabaseReadbackAndCompletionIO() async throws {
        let (run,env,_)=try prepared(),c=try await run.collect(),store=try env.prepare(proof:c.proof(),checkpoint:{if $0=="readback"{try self.clock.advance(1000)}})
        XCTAssertThrowsError(try store.apply());XCTAssertThrowsError(try store.checkPublication())
        XCTAssertFalse(FileManager.default.fileExists(atPath:env.paths.root.appendingPathComponent("complete.json").path))
    }
    func testCorruptCurrentJournalCannotBeOverwrittenOnNextStage() async throws {
        let (run,_,journal)=try prepared()
        run.checkpoint={if $0=="reserved:0"{try Data("corrupt".utf8).write(to:journal.appendingPathComponent("run.json"))}}
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(try Data(contentsOf:journal.appendingPathComponent("run.json")),Data("corrupt".utf8));XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testFinishedProofRejectsJournalTamperAndAnotherGrant() async throws {
        let (run,env,journal)=try prepared(),c=try await run.collect(),proof=try c.proof()
        let otherRoot=try directory("ReceiveProductStore-"),other=try environment(otherRoot,authority(execution()))
        XCTAssertThrowsError(try other.prepare(proof:proof));XCTAssertTrue(try tree(otherRoot).isEmpty)
        try Data("corrupt".utf8).write(to:journal.appendingPathComponent("run.json"))
        XCTAssertThrowsError(try env.prepare(proof:proof));XCTAssertTrue(try tree(env.paths.root).isEmpty)
    }
    func testInFlightSessionRevocationCancelsHeldTransport() async throws {
        ReceiveABStub.reset(responses,hold:0,action:{_ in self.observer.invalidate()})
        let (run,_,journal)=try prepared()
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger(journal).httpUsed,1)
    }
    func testInFlightIOClockReachesRequestDeadlineWithoutAnotherRequest() async throws {
        ReceiveABStub.reset(responses,hold:0,action:{_ in try! self.clock.advance(1000)})
        let (run,_,journal)=try prepared()
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try ledger(journal).httpUsed,1)
    }
    func testPassBudgetIncludesResponseJournalAndVerification() async throws {
        draft.timing!.passMS=50
        let (run,_,journal)=try prepared()
        run.checkpoint={if $0.hasPrefix("response:"){try self.clock.advance(30)}}
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,2);XCTAssertEqual(try ledger(journal).httpUsed,2)
    }
    func testInterpassReservationIOCannotExtendBudget() async throws {
        let (run,_,journal)=try prepared()
        run.checkpoint={if $0=="reserved:7"{try self.clock.advance(1000)}}
        do{_ = try await run.collect();XCTFail()}catch{}
        XCTAssertEqual(ReceiveABStub.count,7);XCTAssertEqual(try ledger(journal).httpUsed,8);XCTAssertEqual(try ledger(journal).authUsed,2)
    }
    @MainActor func testAppSessionUsesSharedAuthorizedRunAndCancelsWithoutGrant() async throws {
        let (run,env,_)=try prepared(),app=ReceiveOfflineAppSession(lifecycle:lifecycle)
        await app.run{_ in run};XCTAssertEqual(app.state,.complete);XCTAssertFalse(app.baselineApplied || app.executionAllowed)
        let empty=try directory("ReceiveProductStore-"),journal=try directory("ReceiveAuthorizedJournal-")
        let missing=try environment(empty,nil)
        XCTAssertThrowsError(try ReceiveAuthorizedRun(environment:missing,target:target,httpTarget:httpTarget(),journalRoot:journal,offlineProtocol:ReceiveABStub.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath:env.paths.root.appendingPathComponent("complete.json").path));XCTAssertTrue(try tree(journal).isEmpty)
    }

    func testMetadataProtectionFailureOccursBeforeProjectOrDocumentPayload() async throws {
        let (run,_,_)=try prepared(),c=try await run.collect(),proof=try c.proof()
        let p=try ReceiveProductProjection(parts:proof.parts,local:runtime.localProjectID,project:draft.project!,account:runtime.account),root=try directory("EmptyMetadata-"),url=root.appendingPathComponent("store.sqlite")
        var prepared=false
        XCTAssertThrowsError(try ReceiveProductMetadata.write(p,url:url,check:{},prepareFiles:{prepared=true;throw ProtectedBoundaryError.protection}))
        XCTAssertTrue(prepared)
        try ReceiveProductMetadata.withContext(url:url,write:false){context in
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectRecord>()),0)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentRecord>()),0)
        }
    }

    func testDateProjectionAcceptsContractOffsetsAndPreservesMicroseconds() throws {
        let whole=try ReceiveProductProjection.date("2026-09-14T00:00:00Z")
        let fractional=try ReceiveProductProjection.date("2026-09-14T00:00:00.123456Z")
        XCTAssertEqual(fractional.timeIntervalSince(whole),0.123456,accuracy:0.0000002)
        XCTAssertEqual(try ReceiveProductProjection.date("2026-09-14T09:00:00.123456+09:00"),fractional)
        XCTAssertEqual(try ReceiveProductProjection.date("2026-09-13T10:00:00-14:00"),whole)
        XCTAssertThrowsError(try ReceiveProductProjection.date("2026-02-30T00:00:00Z"))
        XCTAssertThrowsError(try ReceiveProductProjection.date("2026-09-14T00:00:00.1234567Z"))
    }

    func testLiveIssuerRejectsManualClockBeforeRuntimeReadAndClockCopiesCannotBind() throws {
        var reads=0
        XCTAssertThrowsError(try ReceiveActivationAuthority.afterExplicitUserConfirmation(target:target,draft:draft,scopes:[.httpRead],clock:clock,readRuntime:{reads+=1;return self.runtime}))
        XCTAssertEqual(reads,0)
        let root=try directory("ReceiveProductStore-"),g=try authority(execution())
        let env=try ReceiveDedicatedEnvironment(paths:paths(root),local:runtime.localProjectID,bundle:runtime.bundleID,source:observer.owner.source,authority:g,clock:ABRuntimeClock(utcMS:1000,monoMS:0),lease:lifecycle.begin(),protection:.init(),verifyIdentity:{})
        XCTAssertThrowsError(try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self))
        XCTAssertThrowsError(try ReceiveHTTPConnection(authorizedTarget:httpTarget(),authority:g,source:observer.owner.source,clock:ABRuntimeClock(utcMS:1000,monoMS:0),offlineProtocol:ReceiveABStub.self,leaseCheck:{}))
        XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(root).isEmpty)
    }

}
