import XCTest
import Foundation
@testable import SyntheticInitialReceive

final class ReviewedABJournalTests:XCTestCase {
    private final class Runtime {
        var value:ReceiveExecutionCandidate.RuntimeSnapshot
        init(_ value:ReceiveExecutionCandidate.RuntimeSnapshot){self.value=value}
        func change(epoch:Int? = nil,boot:String? = nil,local:UUID? = nil,expiry:Int? = nil) {
            value = .init(account:value.account,localProjectID:local ?? value.localProjectID,bundleID:value.bundleID,bootID:boot ?? value.bootID,sessionEpoch:epoch ?? value.sessionEpoch,sessionExpiresUTCMS:expiry ?? value.sessionExpiresUTCMS)
        }
    }
    private var target:ReviewedReceiveTarget!, draft:ReceiveExecutionCandidate.Draft!, runtime:Runtime!, responses:[SyntheticABResponse]=[]
    override func setUpWithError() throws {
        let portable = try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!),files = try WindowsHandoffReader.files(from:portable)
        let pin = try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!))
        target = try ReviewedReceiveTarget.read(portable:portable,expected:WindowsHandoffExpectation(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:pin.get("binding").encoded()))
        draft = .init(endpoint:"https://synthetic.invalid",account:UUID(uuidString:try target.binding.str("account_id")),project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000181"),localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000182"),bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-boot",sessionEpoch:0,timing:.fixture,httpLimit:14,authLimit:2)
        runtime = Runtime(.init(account:draft.account!,localProjectID:draft.localProjectID!,bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:0,sessionExpiresUTCMS:6000))
        // New mock pass from synthetic post-creation source rows. No raw shape adaptation.
        let values = try ["Q1.body","Q2.body","Q3.body","Q4.body","Q14.body","Q15.body","Q16.body"].map { try WindowsJSON.decode(files["source/"+$0]!) }
        responses = try values.enumerated().map { i,v in
            let count = i >= 2 ? try v.array().count : nil
            return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map{$0 == 0 ? "*/0" : "0-\($0-1)/\($0)"})
        }
        responses += responses
    }
    private func execution() throws -> ReceiveReviewedExecution {
        let box=runtime!
        return try .offline(target:target,draft:draft,now:.init(utcMS:1000,monoMS:0),readRuntime:{box.value})
    }
    private func runner() throws -> SyntheticABRunner {try .init(reviewed:execution())}
    private func perform(_ transport:SyntheticABTransport? = nil,_ journal:SyntheticABJournal? = nil,_ env:SyntheticABEnvironment? = nil) throws -> SyntheticABCompletion {
        try runner().run(transport:transport ?? SyntheticABTransport(responses),journal:journal ?? SyntheticABJournal(),environment:env ?? SyntheticABEnvironment())
    }
    private func change(_ index:Int,_ key:String,_ value:WindowsJSON) throws {
        var object = try WindowsJSON.decode(responses[index].raw).object();object[key]=value;responses[index].raw=WindowsJSON.object(object).encoded(lf:true)
    }
    func testReviewedTargetDrivesFourteenRequestsAndJournalContext() throws {
        let t=SyntheticABTransport(responses),j=try SyntheticABJournal(),report=try perform(t,j).checkedReport(),s=try j.read()
        XCTAssertEqual(t.calls.count,14);XCTAssertEqual(report.http_reserved,14);XCTAssertEqual(report.auth_reserved,2)
        XCTAssertNotEqual(draft.project!.uuidString.lowercased(),SyntheticABExpected.fixture().project)
        for r in t.calls where r.requestIndex>=3 {XCTAssertEqual(r.query["project_id"],"eq."+draft.project!.uuidString.lowercased())}
        XCTAssertEqual(s.context?.reviewed?.targetSHA256,target.targetSHA256);XCTAssertEqual(s.context?.reviewed?.localProjectID,draft.localProjectID!.uuidString.lowercased())
        XCTAssertFalse(report.baseline_ready || report.baseline_applied || report.execution_allowed)
        XCTAssertEqual(target.review.missing_evidence,52);XCTAssertThrowsError(try execution().requireExecution());XCTAssertThrowsError(try execution().requireApplyInput())
    }
    func testLegacyInitializerCannotAdmitReviewedExpectation() throws {
        XCTAssertThrowsError(try SyntheticABRunner(expected:.reviewedComparison(target),timing:.fixture,runID:"synthetic-ab-"+draft.runID!.uuidString.lowercased()))
    }
    func testUnresolvedCandidateBlockedBeforeRuntimeStorageOrRequests() throws {
        draft.localProjectID=nil;XCTAssertThrowsError(try execution())
    }
    func testRealEndpointBlockedBeforeRuntimeCallback() throws {
        draft.endpoint="https://example.com";var reads=0
        XCTAssertThrowsError(try ReceiveReviewedExecution.offline(target:target,draft:draft,now:.init(utcMS:1000,monoMS:0),readRuntime:{reads+=1;return self.runtime.value}))
        XCTAssertEqual(reads,0)
    }
    func testWrongRuntimeAndOldRunCannotCreateExecution() throws {
        runtime.change(epoch:1);XCTAssertThrowsError(try execution());runtime.change(epoch:0)
        draft.runID=UUID(uuidString:target.sourceRun);XCTAssertThrowsError(try execution())
    }
    func testChangedRuntimeBeforeClaimHasZeroWritesAndRequests() throws {
        let e=try execution(),t=SyntheticABTransport(responses),j=try SyntheticABJournal();runtime.change(local:UUID())
        XCTAssertThrowsError(try SyntheticABRunner(reviewed:e).run(transport:t,journal:j,environment:SyntheticABEnvironment()))
        XCTAssertEqual(try j.read(),SyntheticABJournalState());XCTAssertTrue(t.calls.isEmpty)
    }
    func testDifferentEnvironmentBootEpochOrExpiryCannotClaim() throws {
        let e=try execution(),env=SyntheticABEnvironment(bootID:"synthetic-other"),j=try SyntheticABJournal(),t=SyntheticABTransport(responses)
        XCTAssertThrowsError(try SyntheticABRunner(reviewed:e).run(transport:t,journal:j,environment:env));XCTAssertEqual(try j.read().status,"unused");XCTAssertTrue(t.calls.isEmpty)
        runtime.change(expiry:7000);let e2=try execution();XCTAssertThrowsError(try SyntheticABRunner(reviewed:e2).run(transport:t,journal:j,environment:SyntheticABEnvironment()))
    }
    func testRuntimeChangeAtSecondPassKeepsEighthReservationAndStopsSend() throws {
        let t=SyntheticABTransport(responses),j=try SyntheticABJournal()
        t.onEvent={phase in if phase=="before-send" && t.calls.count==7 {self.runtime.change(epoch:1)}}
        XCTAssertThrowsError(try perform(t,j));XCTAssertEqual(t.calls.count,7);XCTAssertEqual(try j.read().httpUsed,8);XCTAssertEqual(try j.read().authUsed,2);XCTAssertEqual(try j.read().status,"stopped")
    }
    func testPostCompletionRuntimeChangeRevokesReport() throws {
        let result=try perform();runtime.change(boot:"synthetic-restarted");XCTAssertThrowsError(try result.checkedReport())
    }
    func testAuthSubjectAndHandshakeEpochMismatchStopChargedAttempt() throws {
        for index in [0,1] {
            let saved=responses
            if index==0 {try change(0,"id",.string(SyntheticABExpected.fixture().account))} else {try change(1,"migration_epoch",.number("2"))}
            let t=SyntheticABTransport(responses),j=try SyntheticABJournal();XCTAssertThrowsError(try perform(t,j));XCTAssertEqual(try j.read().httpUsed,index+1);responses=saved
        }
    }
    func testSingletonHandshakeIsNotSilentlyAdapted() throws {
        let hs=try WindowsJSON.decode(responses[1].raw);responses[1].raw=WindowsJSON.array([hs]).encoded();XCTAssertThrowsError(try perform())
    }
    func testCountWithoutExactTotalAndPartialRangeFail() throws {
        for range in ["0-0/*","0-0/2"] {responses[2].contentRange=range;let j=try SyntheticABJournal();XCTAssertThrowsError(try perform(nil,j));XCTAssertEqual(try j.read().httpUsed,3)}
    }
    func testChangedTargetBodyCannotFinishOrBecomeBaseline() throws {
        var rows=try WindowsJSON.decode(responses[4].raw).array(),row=try rows[0].object();row["content"] = .string("changed");rows[0] = .object(row);responses[4].raw=WindowsJSON.array(rows).encoded()
        let j=try SyntheticABJournal();XCTAssertThrowsError(try perform(nil,j));XCTAssertEqual(try j.read().status,"stopped")
    }
    func testABNonTargetProjectFieldDifferenceIsCompared() throws {
        var rows=try WindowsJSON.decode(responses[9].raw).array(),row=try rows[0].object();row["synthetic_extra"] = .string("changed");rows[0] = .object(row);responses[9].raw=WindowsJSON.array(rows).encoded()
        let j=try SyntheticABJournal();XCTAssertThrowsError(try perform(nil,j));XCTAssertEqual(try j.read().httpUsed,14);XCTAssertEqual(try j.read().status,"stopped")
    }
    func testRowOrderAloneStillMatches() throws {
        for i in [11,12,13] {responses[i].raw=WindowsJSON.array(try WindowsJSON.decode(responses[i].raw).array().reversed()).encoded()}
        _ = try perform().checkedReport()
    }
    func test401PreservesChargeAndStopsFurtherAttempt() throws {
        responses[0].status=401;let t=SyntheticABTransport(responses),j=try SyntheticABJournal();XCTAssertThrowsError(try perform(t,j));XCTAssertEqual(try j.read().httpUsed,1);XCTAssertEqual(t.calls.count,1)
        let next=SyntheticABTransport(responses);XCTAssertThrowsError(try perform(next,j));XCTAssertTrue(next.calls.isEmpty)
    }
    func testLifecycleAndSameSessionGenerationChangesStop() throws {
        for effect in [SyntheticABEffect.background,.replaceSessionWithSameID,.restartWithSameID] {responses[0].effect=effect;let j=try SyntheticABJournal();XCTAssertThrowsError(try perform(nil,j));XCTAssertEqual(try j.read().httpUsed,1)}
    }
    func testContextPinTamperingRejectedOnMemoryReadback() throws {
        let j=try SyntheticABJournal();_ = try perform(nil,j);var state=try WindowsJSON.decode(j.blob).object(),context=try state["context"]!.object(),reviewed=try context["reviewed"]!.object()
        reviewed["targetSHA256"] = .string(String(repeating:"0",count:64));context["reviewed"] = .object(reviewed);state["context"] = .object(context)
        XCTAssertThrowsError(try SyntheticABJournal(restored:WindowsJSON.object(state).encoded()).read())
    }
    func testRequestCannotReplayAgainstOldFixtureProject() throws {
        let j=try SyntheticABJournal();_ = try perform(nil,j);var state=try j.read();state.events[2].request=try SyntheticABRunner.request(2,project:SyntheticABExpected.fixture().project)
        XCTAssertThrowsError(try SyntheticABJournal(restored:canonical(state)).read())
    }
    func testTransportInterfaceCannotOpenNativePath() throws {
        final class Other:SyntheticABTransporting {
            let responses:[SyntheticABResponse]=[],calls:[SyntheticABRequest]=[]
            func checkCancellation()throws{XCTFail("must reject before callback")}
            func take(_ request:SyntheticABRequest,journal:SyntheticABJournal,environment:SyntheticABEnvironment,check:()throws->Void)throws->SyntheticABResponse{throw SyntheticABError.mockMissing}
        }
        let j=try SyntheticABJournal();XCTAssertThrowsError(try runner().run(transport:Other(),journal:j,environment:SyntheticABEnvironment()));XCTAssertEqual(try j.read().status,"unused")
    }
    private func home()throws->URL {
        let h=URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("ProtectedABFakeHome-"+UUID().uuidString.lowercased());try FileManager.default.createDirectory(at:h,withIntermediateDirectories:false)
        addTeardownBlock{try? FileManager.default.removeItem(at:h)};return h
    }
    func testProtectedDiskRoundtripPreservesTargetContextAndBlocksRestart() throws {
        let h=try home(),life=BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true);let lease=try life.begin(),p=ProtectedContainerTests.Protection(),w=try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:p.access(lease)),e=try execution()
        let result=try w.runReviewed(e,transport:SyntheticABTransport(responses),environment:SyntheticABEnvironment());XCTAssertFalse(try result.checkedReport().baseline_ready)
        let state=try w.inspect();XCTAssertEqual(state.context?.reviewed,e.journalBinding);try state.context!.validate(runID:state.runID!)
        let before=try canonical(state),next=SyntheticABTransport(responses);XCTAssertThrowsError(try w.runReviewed(e,transport:next,environment:SyntheticABEnvironment()));XCTAssertTrue(next.calls.isEmpty);XCTAssertEqual(try canonical(w.inspect()),before)
    }
    func testProtectedClaimMismatchAfterPreparationSendsNothing() throws {
        let h=try home(),life=BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true);let lease=try life.begin(),p=ProtectedContainerTests.Protection(),e=try execution()
        let access=PhysicalStorageAccess(created:{u in try p.create(u);self.runtime.change(epoch:1)},verify:p.verify)
        let w=try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:access),t=SyntheticABTransport(responses)
        XCTAssertThrowsError(try w.runReviewed(e,transport:t,environment:SyntheticABEnvironment()));XCTAssertTrue(t.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:w.container.workspace.appendingPathComponent("execution-journal").path))
    }
    func testReviewedPendingReservationCannotBeRefundedOrReopened() throws {
        enum Interrupted:Error {case stop}
        let h=try home(),life=BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true)
        let lease=try life.begin(),p=ProtectedContainerTests.Protection(),w=try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:p.access(lease)),e=try execution(),t=SyntheticABTransport(responses)
        XCTAssertThrowsError(try w.runReviewed(e,transport:t,environment:SyntheticABEnvironment(),checkpoint:{point in
            if point=="pending:reserve:1:record-002.json" {throw Interrupted.stop}
        }))
        XCTAssertTrue(t.calls.isEmpty)
        let pending=w.container.workspace.appendingPathComponent("execution-journal/record-002.json.pending")
        let before=try Data(contentsOf:pending),record=try decodeExact(SyntheticABDiskJournal.Record.self,before)
        XCTAssertEqual(record.state.httpUsed,1);XCTAssertEqual(record.state.authUsed,1);XCTAssertEqual(record.state.context?.reviewed,e.journalBinding)
        let next=SyntheticABTransport(responses);XCTAssertThrowsError(try w.runReviewed(e,transport:next,environment:SyntheticABEnvironment()));XCTAssertTrue(next.calls.isEmpty);XCTAssertEqual(try Data(contentsOf:pending),before)
    }
    func testReviewedContextCannotBeDowngradedToLegacyContext() throws {
        let j=try SyntheticABJournal();_ = try perform(nil,j);var state=try j.read();state.context?.reviewed=nil
        XCTAssertThrowsError(try state.context!.validate(runID:state.runID!))
    }
    func testRuntimeCallbackTimeConsumesTotalBudgetBeforeJournalClaim() throws {
        let clock=ABRuntimeClock(utcMS:1000,monoMS:0),env=try SyntheticABEnvironment(clock:clock,session:ABSessionDouble(expiresUTCMS:6000))
        draft.bootID="synthetic-runtime-boot";runtime.change(boot:draft.bootID!)
        let e=try ReceiveReviewedExecution.offline(target:target,draft:draft,now:clock.sample(),readRuntime:{try clock.advance(1000);return self.runtime.value})
        let j=try SyntheticABJournal(),t=SyntheticABTransport(responses)
        XCTAssertThrowsError(try SyntheticABRunner(reviewed:e).run(transport:t,journal:j,environment:env));XCTAssertEqual(try j.read().status,"unused");XCTAssertTrue(t.calls.isEmpty)
    }

    func testMalformedReservationWithMissingRunIDFailsWithoutTrap() throws {
        let j=try SyntheticABJournal();_ = try perform(nil,j);let finished=try j.read()
        var claimed=SyntheticABJournalState();claimed.runID=finished.runID;claimed.binding=finished.binding;claimed.context=finished.context;claimed.status="running"
        var malformed=claimed;malformed.runID=nil;malformed.httpUsed=1;malformed.authUsed=1
        malformed.events=[SyntheticABEvent(request:try runner().request(0),reservationID:finished.runID!+":1",phase:"A",reservedUTCMS:1000,reservedMonoMS:0)]
        XCTAssertThrowsError(try SyntheticABDiskJournal.transition(claimed,malformed,operation:"reserve:1"))
    }

}
