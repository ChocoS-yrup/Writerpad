import XCTest
import Foundation
@testable import SyntheticInitialReceive

final class ReviewedNativeAppTests:XCTestCase {
    private final class Runtime {
        private let lock=NSLock()
        private var snapshot:ReceiveExecutionCandidate.RuntimeSnapshot
        init(_ snapshot:ReceiveExecutionCandidate.RuntimeSnapshot){self.snapshot=snapshot}
        func read()->ReceiveExecutionCandidate.RuntimeSnapshot{lock.lock();defer{lock.unlock()};return snapshot}
        func changeEpoch(){lock.lock();defer{lock.unlock()};let v=snapshot;snapshot = .init(account:v.account,localProjectID:v.localProjectID,bundleID:v.bundleID,bootID:v.bootID,sessionEpoch:v.sessionEpoch+1,sessionExpiresUTCMS:v.sessionExpiresUTCMS)}
    }
    private var target:ReviewedReceiveTarget!,draft:ReceiveExecutionCandidate.Draft!,runtime:Runtime!,owner:ReceiveAuthOwner!,clock:ABRuntimeClock!,responses:[SyntheticABResponse]=[],homes:[URL]=[]
    override func setUpWithError() throws {
        let portable=try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!),files=try WindowsHandoffReader.files(from:portable)
        let pin=try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!))
        target=try .read(portable:portable,expected:WindowsHandoffExpectation(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:pin.get("binding").encoded()))
        let timing=SyntheticABTiming(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:1000,localApplyMS:1000,totalMS:60000,notBeforeUTCMS:1000,expiresUTCMS:61000)
        draft = .init(endpoint:"https://synthetic.invalid",account:UUID(uuidString:try target.binding.str("account_id")),project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000281"),localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000282"),bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-native-boot",sessionEpoch:1,timing:timing,httpLimit:14,authLimit:2)
        runtime=Runtime(.init(account:draft.account!,localProjectID:draft.localProjectID!,bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:1,sessionExpiresUTCMS:61000))
        owner=ReceiveAuthOwner();try owner.replaceCachedSession(cached());clock=ABRuntimeClock(utcMS:1000,monoMS:0)
        let values=try ["Q1.body","Q2.body","Q3.body","Q4.body","Q14.body","Q15.body","Q16.body"].map{try WindowsJSON.decode(files["source/"+$0]!)}
        responses=try values.enumerated().map{i,v in let count=i>=2 ? try v.array().count:nil;return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map{$0==0 ? "*/0":"0-\($0-1)/\($0)"},delayMS:0)};responses += responses
        ReceiveABStub.reset(responses)
    }
    override func tearDownWithError()throws{ReceiveABStub.reset();for h in homes{try FileManager.default.removeItem(at:h)};homes=[]}
    private func cached(expiry:Int=61000,account:UUID?=nil)->ReceiveCachedSession{.init(account:account ?? draft.account!,accessToken:"synthetic.reviewed.session",expiresUTCMS:expiry)}
    private func execution()throws->ReceiveReviewedExecution{let box=runtime!;return try .offline(target:target,draft:draft,now:clock.sample(),readRuntime:box.read)}
    private func home()throws->URL{let h=URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("ReviewedNativeApp-"+UUID().uuidString.lowercased());try FileManager.default.createDirectory(at:h,withIntermediateDirectories:false);homes.append(h);return h}
    private func life()->BoundaryLifecycle{let l=BoundaryLifecycle();l.update(active:true,protectedDataAvailable:true);return l}
    private func coordinator(_ h:URL,_ life:BoundaryLifecycle,owner:ReceiveAuthOwner?=nil,protocolClass:AnyClass=ReceiveABStub.self)throws->ReceiveABCoordinator{try .init(offlineReviewed:execution(),syntheticHome:h,lease:life.begin(),protection:.init(),owner:owner ?? self.owner,clock:clock,protocolClass:protocolClass)}
    private func inspect(_ h:URL,_ life:BoundaryLifecycle)throws->SyntheticABJournalState{try ProtectedABJournalWork(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:life.begin(),protection:.init()).inspect()}
    private func tree(_ h:URL)throws->[String:String]{let files=FileManager.default.enumerator(at:h,includingPropertiesForKeys:[.isRegularFileKey])!;var result:[String:String]=[:];for case let p as URL in files where try p.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true{result[p.path]=byteHash(try Data(contentsOf:p))};return result}
    private func blocked(_ c:ReceiveABCoordinator) async {do{_ = try await c.run();XCTFail("unexpected completion")}catch{}}
    func testNativeReviewedPassPersistsOwnerContextAndFourteenRequests() async throws {
        let h=try home(),l=life(),c=try coordinator(h,l),result=try await c.run(),report=try result.checkedReport(),state=try inspect(h,l)
        XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(state.context?.reviewed?.sessionEpoch,1);XCTAssertEqual(state.context?.bootID,draft.bootID);XCTAssertEqual(state.context?.sessionGeneration,1)
        XCTAssertEqual(state.context?.reviewed?.targetSHA256,target.targetSHA256);XCTAssertEqual(report.http_reserved,14);XCTAssertEqual(report.auth_reserved,2)
        for r in ReceiveABStub.requests where r.url!.path.hasPrefix("/rest/v1/") && !r.url!.path.contains("/rpc/"){XCTAssertTrue(r.url!.absoluteString.contains(draft.project!.uuidString.lowercased()))}
        XCTAssertFalse(String(decoding:try canonical(state),as:UTF8.self).contains("synthetic.reviewed.session"));XCTAssertFalse(report.baseline_applied || report.execution_allowed);XCTAssertThrowsError(try result.requireApplyInput())
    }
    func testConstructionIsPassiveAndEmptyOwnerCannotCreateJournal() async throws {
        let h=try home(),c=try coordinator(h,life(),owner:ReceiveAuthOwner());XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(h).isEmpty);await blocked(c);XCTAssertTrue(try tree(h).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testOwnerEpochMismatchBeforeClaimDoesNotReadOrWriteJournal() async throws {
        let h=try home(),c=try coordinator(h,life());try owner.replaceCachedSession(cached());await blocked(c);XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(h).isEmpty)
    }
    func testOwnerExpiryMismatchAndWrongAccountBlockBeforeClaim() async throws {
        for session in [cached(expiry:62000),cached(account:UUID())]{let h=try home(),other=ReceiveAuthOwner();try other.replaceCachedSession(session);await blocked(try coordinator(h,life(),owner:other));XCTAssertTrue(try tree(h).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)}
    }
    func testSameTokenOwnerChangeCancelsHeldRequestAndPreservesCharge() async throws {
        let h=try home(),l=life();ReceiveABStub.reset(responses,hold:0,action:{_ in try? self.owner.replaceCachedSession(self.cached())})
        await blocked(try coordinator(h,l));let s=try inspect(h,l);XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(s.httpUsed,1);XCTAssertEqual(s.status,"running")
        // Revoked storage access forbids a stop write; preserve the last durable state.
        let before=try tree(h);runtime.changeEpoch();draft.sessionEpoch=2
        await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try tree(h),before)
    }
    func testRuntimeChangeCancelsHeldRequestWithoutOwnerChange() async throws {
        let h=try home(),l=life();ReceiveABStub.reset(responses,hold:0,action:{_ in self.runtime.changeEpoch()})
        await blocked(try coordinator(h,l));XCTAssertEqual(try inspect(h,l).httpUsed,1);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testBackgroundRevokesHeldNativeRequest() async throws {
        let h=try home(),l=life();ReceiveABStub.reset(responses,hold:0,action:{_ in l.update(active:false,protectedDataAvailable:true)})
        await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testNativeDeadlineCountsClockAdvanceAndStops() async throws {
        let h=try home(),l=life();ReceiveABStub.reset(responses,hold:0,action:{_ in try? self.clock.advance(1000)})
        await blocked(try coordinator(h,l));XCTAssertEqual(try inspect(h,l).httpUsed,1);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testNative401KeepsChargeAndBlocksFreshCoordinator() async throws {
        responses[0].status=401;ReceiveABStub.reset(responses);let h=try home(),l=life();await blocked(try coordinator(h,l));let before=try tree(h)
        XCTAssertEqual(try inspect(h,l).httpUsed,1);await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,1);XCTAssertEqual(try tree(h),before)
    }
    func testMissingCountStopsAtThirdRequest() async throws {
        responses[2].contentRange=nil;ReceiveABStub.reset(responses);let h=try home(),l=life();await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,3);XCTAssertEqual(try inspect(h,l).httpUsed,3)
    }
    func testABChangeFailsAtFourteenWithoutBaseline() async throws {
        var rows=try WindowsJSON.decode(responses[9].raw).array(),row=try rows[0].object();row["synthetic_marker"] = .bool(true);rows[0] = .object(row);responses[9].raw=WindowsJSON.array(rows).encoded();ReceiveABStub.reset(responses)
        let h=try home(),l=life();await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(try inspect(h,l).status,"stopped")
    }
    func testNoAcceptingURLProtocolUsesDenyFallback() async throws {
        final class RejectAll:URLProtocol{override class func canInit(with request:URLRequest)->Bool{false}}
        let h=try home(),l=life();await blocked(try coordinator(h,l,protocolClass:RejectAll.self));XCTAssertEqual(ReceiveABStub.count,0);XCTAssertEqual(try inspect(h,l).httpUsed,1)
    }
    func testCompletedContextCannotReplayOrPublishAfterRuntimeMutation() async throws {
        let h=try home(),l=life(),c=try coordinator(h,l),result=try await c.run(),before=try tree(h)
        await blocked(c);await blocked(try coordinator(h,l));XCTAssertEqual(ReceiveABStub.count,14);XCTAssertEqual(try tree(h),before)
        runtime.changeEpoch();XCTAssertThrowsError(try result.checkedReport())
    }
    @MainActor func testReviewedJobPublishesThroughExistingAppSession() async throws {
        let h=try home(),l=life(),app=ReceiveOfflineAppSession(lifecycle:l),e=try execution()
        await app.run{lease in try ReceiveReviewedOfflineAppJob(execution:e,home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:.init(),owner:owner,clock:clock,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.complete);XCTAssertTrue(app.syntheticReady);XCTAssertFalse(app.baselineApplied || app.executionAllowed);XCTAssertEqual(ReceiveABStub.count,14)
    }
    @MainActor func testReviewedAppJobRejectsWrongBundleBeforeStarting() async throws {
        let h=try home(),l=life(),app=ReceiveOfflineAppSession(lifecycle:l),e=try execution()
        await app.run{lease in try ReceiveReviewedOfflineAppJob(execution:e,home:h,declaredBundle:"old.app",lease:lease,protection:.init(),owner:owner,clock:clock,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.stopped);XCTAssertEqual(ReceiveABStub.count,0);XCTAssertTrue(try tree(h).isEmpty)
    }
    @MainActor func testAppCancellationOfReviewedJobDoesNotPublishCompletion() async throws {
        let entered=expectation(description:"request"),h=try home(),l=life(),app=ReceiveOfflineAppSession(lifecycle:l),e=try execution()
        ReceiveABStub.reset(responses,hold:0,action:{_ in entered.fulfill()})
        let task=Task{await app.run{lease in try ReceiveReviewedOfflineAppJob(execution:e,home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:.init(),owner:owner,clock:clock,protocolClass:ReceiveABStub.self)}}
        await fulfillment(of:[entered],timeout:5);app.invalidate();task.cancel();await task.value
        XCTAssertEqual(app.state,.stopped);XCTAssertFalse(app.isRunning);XCTAssertFalse(app.syntheticReady);XCTAssertEqual(ReceiveABStub.count,1)
    }
}
