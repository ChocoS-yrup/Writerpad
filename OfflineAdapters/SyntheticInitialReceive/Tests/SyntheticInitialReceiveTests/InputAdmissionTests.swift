import XCTest
import Foundation
@testable import SyntheticInitialReceive

final class InputAdmissionTests:XCTestCase {
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
    private func session(_ plan:ReceiveAdmissionPlan,_ desc:ReceiveLocalStoreDescriptor,checkpoint:@escaping(String)throws->Void={_ in},protection:PhysicalStorageAccess = .init()) throws -> ReceiveAdmissionSession {
        try .prepare(plan:plan,descriptor:desc,permit:ReceiveOfflineApplyPermit.issue(plan:plan,descriptor:desc),lease:lifecycle.begin(),protection:protection,checkpoint:checkpoint)
    }
    private func tree(_ d:URL) throws -> [String:Data] {
        var files:[String:Data]=[:]
        for case let p as URL in FileManager.default.enumerator(at:d,includingPropertiesForKeys:[.isRegularFileKey])! where try p.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {
            files[p.path]=try Data(contentsOf:p)
        };return files
    }
    func testRetainedComparisonNeverFinalizesOrGrants() throws {
        let c=try ReceiveInputContract.compare(target:target,draft:draft,now:clock.sample())
        XCTAssertEqual(c.member_ids.count,4);XCTAssertEqual(c.unresolved,["runtime_snapshot"])
        XCTAssertFalse(c.retained_schema_finalized || c.execution_allowed || c.baseline_ready || c.baseline_applied)
        XCTAssertThrowsError(try ReceiveInputContract.requireLiveAdmission());XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testMissingContextRemainsUnresolvedWithoutDependencyReads() throws {
        let c=try ReceiveInputContract.compare(target:target,draft:.init(),now:clock.sample())
        XCTAssertTrue(c.unresolved.contains("local_project_id"));XCTAssertTrue(c.unresolved.contains("timing"));XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testWrongPinAndTargetDoNotEnterAdmission() throws {
        draft.targetSHA256=String(repeating:"0",count:64)
        XCTAssertThrowsError(try ReceiveInputContract.compare(target:target,draft:draft,now:clock.sample()))
        XCTAssertThrowsError(try execution());XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testRemoteEntityWriterAndSourceIDsCannotBecomeLocalOrRunIDs() throws {
        let original=draft!
        for id in [target.sourceRun,try target.sourceWriterDeviceID,target.entities[0].id] {
            draft=original;draft.localProjectID=UUID(uuidString:id)
            XCTAssertThrowsError(try ReceiveInputContract.compare(target:target,draft:draft,now:clock.sample()))
            draft=original;draft.runID=UUID(uuidString:id)
            XCTAssertThrowsError(try ReceiveInputContract.compare(target:target,draft:draft,now:clock.sample()))
        }
    }
    func testFreshProjectionContainsOnlyMembersAndExactBodyBytes() async throws {
        let (_,c,p)=try await received()
        XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(try c.checkedReport().auth_reserved,2)
        let bodies=try JSONDecoder().decode([String:Data].self,from:p.parts[.bodies]!)
        let members=target.entities.filter{$0.role == "members"},docs=members.filter{$0.kind == "document"}
        XCTAssertEqual(Set(bodies.keys),Set(docs.map(\.id)))
        for doc in docs {XCTAssertEqual(byteHash(bodies[doc.id]!),doc.bodySHA256);XCTAssertEqual(bodies[doc.id]!.count,doc.bodyBytes)}
        let orderIDs=try WindowsJSON.decode(p.parts[.treeOrderBaseline]!).array().map{try $0.str("tree_order_id")}
        XCTAssertEqual(Set(orderIDs),Set(members.filter{$0.kind == "tree_order"}.map(\.id)))
        XCTAssertEqual(try WindowsJSON.decode(p.parts[.metadata]!).array().count,3)
        XCTAssertFalse(p.parts.values.contains{String(decoding:$0,as:UTF8.self).contains("synthetic.admission.session")})
        XCTAssertThrowsError(try p.requireBaseline());XCTAssertThrowsError(try c.requireApplyInput())
    }
    func testProjectionKeepsVersionsNullDatesAndOriginalParent() async throws {
        let (_,_,p)=try await received()
        let folder=try WindowsJSON.decode(p.parts[.folderBaseline]!).array()[0]
        XCTAssertEqual(try folder.get("deleted_at"),.null);XCTAssertEqual(try folder.get("is_deleted"),.bool(false))
        XCTAssertGreaterThan(try folder.get("revision").int(),0);try WindowsHandoffReader.date(folder.get("updated_at"))
        let originalFolders=try WindowsJSON.decode(responses[12].raw).array()
        let original=try originalFolders.first{try $0.str("folder_id") == folder.str("folder_id")}!
        XCTAssertTrue(try folder.get("parent_folder_id").equalBytes(original.get("parent_folder_id")))
        XCTAssertTrue(folder.equalBytes(original))
        let doc=try WindowsJSON.decode(p.parts[.documentBaseline]!).array()[0]
        XCTAssertGreaterThan(try doc.get("row").get("structure_revision").int(),0)
    }
    func testNoPermitAndLiveDescriptorDoNotWrite() async throws {
        let (_,_,p)=try await received(),d=try directory(),desc=descriptor(d)
        XCTAssertThrowsError(try ReceiveAdmissionSession.prepare(plan:p,descriptor:desc,permit:nil,lease:lifecycle.begin(),protection:.init()))
        XCTAssertThrowsError(try ReceiveOfflineApplyPermit.issue(plan:p,descriptor:descriptor(d,mode:.live)))
        XCTAssertTrue(try tree(d).isEmpty)
    }
    func testDescriptorRejectsForeignIdentityBundleAndOldNamespace() async throws {
        let (_,_,p)=try await received(),d=try directory(),old=try directory("SyntheticInitialReceive-")
        for desc in [descriptor(d,local:target.entities[0].id),descriptor(d,bundle:"old.app"),descriptor(old)] {
            XCTAssertThrowsError(try ReceiveOfflineApplyPermit.issue(plan:p,descriptor:desc))
        };XCTAssertTrue(try tree(d).isEmpty);XCTAssertTrue(try tree(old).isEmpty)
    }
    func testPermitIsBoundToExactWorkspace() async throws {
        let (_,_,p)=try await received(),a=try directory(),b=try directory(),permit=try ReceiveOfflineApplyPermit.issue(plan:p,descriptor:descriptor(a))
        XCTAssertThrowsError(try ReceiveAdmissionSession.prepare(plan:p,descriptor:descriptor(b),permit:permit,lease:lifecycle.begin(),protection:.init()))
        XCTAssertTrue(try tree(b).isEmpty)
    }
    func testPhysicalFivePartsReadbackAndIdempotenceRemainOffline() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d))
        XCTAssertThrowsError(try s.snapshot());let receipt=try s.applyOffline(),before=try tree(d)
        XCTAssertTrue(receipt.offline_storage_prepared);XCTAssertFalse(receipt.baseline_ready || receipt.baseline_applied || receipt.execution_allowed || receipt.app_binding_created)
        XCTAssertEqual(try s.snapshot(),p.parts);_ = try s.applyOffline();XCTAssertEqual(try tree(d),before)
        XCTAssertThrowsError(try s.requireBaseline());XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testReopenedSessionResumesCommittedPartialWithoutHTTPReplay() async throws {
        let (_,_,p)=try await received(),d=try directory(),desc=descriptor(d)
        let first=try session(p,desc,checkpoint:{if $0 == "committed:4" {throw Injected.stop}})
        XCTAssertThrowsError(try first.applyOffline());XCTAssertThrowsError(try first.snapshot())
        let reopened=try session(p,desc);_ = try reopened.applyOffline();XCTAssertEqual(try reopened.snapshot(),p.parts);XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testUncommittedPartIsPreservedAndNotInferredOnResume() async throws {
        let (_,_,p)=try await received(),d=try directory(),desc=descriptor(d)
        let first=try session(p,desc,checkpoint:{if $0 == "written:part-bodies.bin" {throw Injected.stop}})
        XCTAssertThrowsError(try first.applyOffline());let before=try tree(d),second=try session(p,desc)
        XCTAssertThrowsError(try second.applyOffline());XCTAssertThrowsError(try second.snapshot());XCTAssertEqual(try tree(d),before)
    }
    func testCompletedStorageTamperBlocksReadAndApplyWithoutRepair() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d));_ = try s.applyOffline()
        try Data("corrupt".utf8).write(to:d.appendingPathComponent("physical-boundary/part-bodies.bin"));let before=try tree(d)
        XCTAssertThrowsError(try s.snapshot());XCTAssertThrowsError(try s.applyOffline());XCTAssertEqual(try tree(d),before)
    }
    func testExistingOriginalFileStopsBeforeSealOrLockCreation() async throws {
        let (_,_,p)=try await received(),d=try directory()
        try Data("unsent-original".utf8).write(to:d.appendingPathComponent("draft.txt"));let before=try tree(d)
        XCTAssertThrowsError(try session(p,descriptor(d)));XCTAssertEqual(try tree(d),before)
    }
    func testSymlinkWorkspaceAndSealAreRejectedWithoutTouchingTarget() async throws {
        let (_,_,p)=try await received(),d=try directory(),other=try directory()
        let original=other.appendingPathComponent("original");try Data("keep".utf8).write(to:original)
        try FileManager.default.createSymbolicLink(at:d.appendingPathComponent("admission.json"),withDestinationURL:original)
        XCTAssertThrowsError(try session(p,descriptor(d)));XCTAssertEqual(try Data(contentsOf:original),Data("keep".utf8))
    }
    func testPreApplyDeadlineBlocksBeforeDataWrites() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d));let before=try tree(d)
        try clock.advance(500);XCTAssertThrowsError(try s.applyOffline());XCTAssertEqual(try tree(d),before)
    }
    func testStorageIOTimeRevokesCompletionAndStopsLaterWrites() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d),checkpoint:{stage in if stage == "committed:3" {try self.clock.advance(1000)}})
        XCTAssertThrowsError(try s.applyOffline());let before=try tree(d)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent("physical-boundary/part-metadata.bin").path))
        XCTAssertThrowsError(try s.snapshot());XCTAssertEqual(try tree(d),before)
    }
    func testAuthObserverInvalidationBetweenEvidenceAndApplyBlocks() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d)),before=try tree(d)
        observer.invalidate();XCTAssertThrowsError(try s.applyOffline());XCTAssertEqual(try tree(d),before)
    }
    func testSameTokenABAIsNotAReusablePermission() async throws {
        let (_,_,p)=try await received(),d=try directory(),permit=try ReceiveOfflineApplyPermit.issue(plan:p,descriptor:descriptor(d))
        let op=UUID();observer.begin(op);observer.accept(op,account:draft.account!,accessToken:"synthetic.admission.session",expiresAt:Date(timeIntervalSince1970:61))
        XCTAssertThrowsError(try ReceiveAdmissionSession.prepare(plan:p,descriptor:descriptor(d),permit:permit,lease:lifecycle.begin(),protection:.init()));XCTAssertTrue(try tree(d).isEmpty)
    }
    func testProtectedLossDuringPartWriteCannotPublishOrResumeAutomatically() async throws {
        let (_,_,p)=try await received(),d=try directory(),s=try session(p,descriptor(d),checkpoint:{stage in if stage == "committed:3" {self.lifecycle.update(active:true,protectedDataAvailable:false)}})
        XCTAssertThrowsError(try s.applyOffline());let before=try tree(d)
        lifecycle.update(active:true,protectedDataAvailable:true)
        XCTAssertThrowsError(try session(p,descriptor(d)));XCTAssertEqual(try tree(d),before)
    }
    func testProtectionVerificationFailureCannotInitialize() async throws {
        let (_,_,p)=try await received(),d=try directory()
        XCTAssertThrowsError(try session(p,descriptor(d),protection:.init(verify:{_ in throw ProtectedBoundaryError.protection})))
        XCTAssertTrue(try tree(d).isEmpty)
    }
    func testEvidenceMissingRawIsNotIndependentVerification() async throws {
        let (e,c,_)=try await received();var s=try c.checkedAdmissionJournal();s.events[4].raw=nil
        XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
    }
    func testEvidenceWrongHashAndLengthAreRejected() async throws {
        let (e,c,_)=try await received();let original=try c.checkedAdmissionJournal()
        var s=original;s.events[4].sha256=String(repeating:"0",count:64);XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
        s=original;s.events[4].byteCount=0;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
    }
    func testEvidenceMissingTimeRangeOrCountIsNotFilledFromRaw() async throws {
        let (e,c,_)=try await received();let original=try c.checkedAdmissionJournal()
        var s=original;s.events[2].receivedUTCMS=nil;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
        s=original;s.events[2].contentRange=nil;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
        s=original;s.events[2].rowCount=nil;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
    }
    func testEvidenceBudgetSequenceAndContextCannotBeSubstituted() async throws {
        let (e,c,_)=try await received();let original=try c.checkedAdmissionJournal()
        var s=original;s.httpUsed=13;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
        s=original;s.events.swapAt(1,2);XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
        s=original;s.context=nil;XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(s,execution:e))
    }
    func testMalformedFreshBodyOrHandshakeNeverCreatesProjection() async throws {
        responses[8].raw=Data("{}".utf8);ReceiveABStub.reset(responses)
        do {_ = try await received();XCTFail("accepted handshake")}catch{}
        XCTAssertEqual(ReceiveABStub.count,9)
    }
    @MainActor func testFullAppAuthABAndStorageRoutePublishesOnlyOfflineReady() async throws {
        let app=ReceiveOfflineAppSession(lifecycle:lifecycle),e=try execution(),home=try directory("AdmissionApp-"),d=try directory()
        await app.run{lease in try ReceiveAdmittedOfflineAppJob(execution:e,descriptor:descriptor(d),home:home,lease:lease,protection:.init(),owner:observer.owner,clock:clock,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.complete);XCTAssertFalse(app.baselineApplied || app.executionAllowed);XCTAssertEqual(ReceiveABStub.count,14)
        XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("physical-boundary/head.json").path))
    }
    @MainActor func testLiveDescriptorCannotStartAppJobOrReadOwner() async throws {
        let app=ReceiveOfflineAppSession(lifecycle:lifecycle),e=try execution(),home=try directory("AdmissionApp-"),d=try directory()
        await app.run{lease in try ReceiveAdmittedOfflineAppJob(execution:e,descriptor:descriptor(d,mode:.live),home:home,lease:lease,protection:.init(),owner:observer.owner,clock:clock,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.stopped);XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(home).isEmpty);XCTAssertTrue(try tree(d).isEmpty)
    }
    func testFreshMemberBodyAndOrderMismatchCannotBePromotedByNewHashes() async throws {
        let (e,c,_)=try await received();let original=try c.checkedAdmissionJournal()
        for index in [11,13] {
            var state=original,rows=try WindowsJSON.decode(state.events[index].raw!).array()
            let kind=index == 11 ? "document":"tree_order",key=WindowsHandoffReader.kinds[kind]!.1
            let member=target.entities.first{$0.role == "members" && $0.kind == kind}!.id
            let n=try rows.firstIndex{try $0.str(key) == member}!
            var row=try rows[n].object()
            if index == 11 {row["content"] = .string("changed body")}
            else {row["children"] = .array([])}
            rows[n] = .object(row);let raw=WindowsJSON.array(rows).encoded(lf:true)
            state.events[index].raw=raw;state.events[index].sha256=byteHash(raw);state.events[index].byteCount=raw.count
            XCTAssertThrowsError(try ReceiveAdmissionPlan.validateEvidence(state,execution:e))
        }
    }
    func testCompletionCannotBeAttachedToAnotherRun() async throws {
        let (_,c,_)=try await received();let original=draft!
        draft.timing!.preApplyMS += 1
        XCTAssertThrowsError(try ReceiveAdmissionPlan.offline(execution:execution(),completion:c))
        draft=original;draft.runID=UUID(uuidString:"ee260915-0000-4000-8000-000000000391")
        XCTAssertThrowsError(try ReceiveAdmissionPlan.offline(execution:execution(),completion:c))
    }
    @MainActor func testAuthRevocationDuringAppStoragePreventsReadyPublication() async throws {
        let app=ReceiveOfflineAppSession(lifecycle:lifecycle),e=try execution(),home=try directory("AdmissionApp-"),d=try directory()
        let protection=PhysicalStorageAccess(created:{url in
            if url.path.hasPrefix(d.path) && url.lastPathComponent == "physical-boundary" {self.observer.invalidate()}
        })
        await app.run{lease in try ReceiveAdmittedOfflineAppJob(execution:e,descriptor:descriptor(d),home:home,lease:lease,protection:protection,owner:observer.owner,clock:clock,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.stopped);XCTAssertFalse(app.syntheticReady);XCTAssertEqual(ReceiveABStub.count,14)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.appendingPathComponent("physical-boundary/head.json").path))
    }

}
