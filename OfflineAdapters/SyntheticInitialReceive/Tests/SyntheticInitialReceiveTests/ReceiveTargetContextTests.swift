import XCTest
import Foundation
@testable import SyntheticInitialReceive

final class ReceiveTargetContextTests:XCTestCase {
    var portable:Data = Data(), pin:WindowsHandoffExpectation!,target:ReviewedReceiveTarget!,tables:[String:[WindowsJSON]] = [:]
    override func setUpWithError() throws {
        portable = try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!)
        let files = try WindowsHandoffReader.files(from:portable),b = try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!)).get("binding")
        pin = try .init(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:b.encoded());target = try .read(portable:portable,expected:pin)
        for (name,source) in [("documents","Q14.body"),("folders","Q15.body"),("tree_orders","Q16.body")] { tables[name] = try WindowsJSON.decode(files["source/"+source]!).array() }
    }
    func draft() throws -> ReceiveExecutionCandidate.Draft {
        .init(endpoint:try target.binding.str("endpoint"),account:UUID(uuidString:try target.binding.str("account_id"))!,project:UUID(uuidString:try target.binding.str("project_id"))!,handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000081")!,localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000082")!,bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-boot",sessionEpoch:7,timing:.fixture,httpLimit:14,authLimit:2)
    }
    func runtime(_ d:ReceiveExecutionCandidate.Draft) -> ReceiveExecutionCandidate.RuntimeSnapshot { .init(account:d.account!,localProjectID:d.localProjectID!,bundleID:d.bundleID!,bootID:d.bootID!,sessionEpoch:d.sessionEpoch!,sessionExpiresUTCMS:6000) }
    func check(_ d:ReceiveExecutionCandidate.Draft) throws -> ReceiveExecutionCandidate.Comparison { try ReceiveExecutionCandidate.compare(d,to:target,now:.init(utcMS:1000,monoMS:0),runtime:runtime(draft())) }
    func testReaderCreatesTypedRolesAndRetainsMissingEvidenceWithoutAuthority() throws {
        XCTAssertEqual(target.entities.filter { $0.role == "members" }.count,4);XCTAssertEqual(target.entities.filter { $0.role == "references" }.count,1)
        XCTAssertEqual(target.review.missing_evidence,52);XCTAssertFalse(target.review.baseline_ready);XCTAssertThrowsError(try target.requireApplyInput())
        XCTAssertEqual(target.entities.filter { $0.kind == "document" }.count,2);XCTAssertTrue(target.entities.filter { $0.kind == "document" }.allSatisfy { $0.bodySHA256 != nil && $0.bodyBytes != nil && $0.structureRevision == 1 })
    }
    func testForgedPinCannotConstructTypedTarget() throws {
        let wrong = try WindowsHandoffExpectation(handoffSHA256:String(repeating:"0",count:64),bindingJSON:target.binding.encoded())
        XCTAssertThrowsError(try ReviewedReceiveTarget.read(portable:portable,expected:wrong))
    }
    func testMissingSourceCannotBeFilledFromTargetSummary() throws {
        var f = try WindowsHandoffReader.files(from:portable);f.removeValue(forKey:"source/Q14.body")
        let p = WindowsJSON.object(["format":.string("ipad-windows-handoff-review-bytes-v1"),"files":.object(f.mapValues { .string($0.base64EncodedString()) })]).encoded()
        XCTAssertThrowsError(try ReviewedReceiveTarget.read(portable:p,expected:pin))
    }
    func testComparisonMatchesAndReorderingDoesNotChangeDigest() throws {
        let a = try target.compare(tables);for key in tables.keys { tables[key]!.reverse() };XCTAssertEqual(try target.compare(tables),a)
    }
    func testMissingReferenceBlocksComparison() throws { tables["tree_orders"]!.removeFirst();XCTAssertThrowsError(try target.compare(tables)) }
    func testChangedBodyOrRevisionBlocks() throws {
        for key in ["content","revision","structure_revision"] {
            var changed = tables, row = try changed["documents"]![0].object();row[key] = key == "content" ? .string("different") : .number("2");changed["documents"]![0] = .object(row)
            XCTAssertThrowsError(try target.compare(changed))
        }
    }
    func testChangedOrderAndDuplicateIDsBlock() throws {
        var changed = tables,row = try changed["tree_orders"]![1].object();row["children"] = .array(try row["children"]!.array().reversed());changed["tree_orders"]![1] = .object(row);XCTAssertThrowsError(try target.compare(changed))
        tables["documents"]!.append(tables["documents"]![0]);XCTAssertThrowsError(try target.compare(tables))
    }
    func testWrongProjectAndUnexpectedTableBlock() throws {
        var row = try tables["folders"]![0].object();row["project_id"] = .string("ee260915-0000-4000-8000-000000000099");tables["folders"]![0] = .object(row);XCTAssertThrowsError(try target.compare(tables));tables["unknown"] = [];XCTAssertThrowsError(try target.compare(tables))
    }
    func testTargetDoesNotExposeBodiesThroughDebugMirror() { XCTAssertTrue(Mirror(reflecting:target!).children.isEmpty);XCTAssertFalse(String(describing:target!).contains("가.txt")) }
    func testEmptyCandidateReportsMissingFieldsAndCannotExecute() throws {
        let r = try ReceiveExecutionCandidate.compare(.init(),to:target,now:.init(utcMS:1000,monoMS:0));XCTAssertFalse(r.local_fields_matched);XCTAssertEqual(r.unresolved.count,14);XCTAssertThrowsError(try ReceiveExecutionCandidate.requireExecution())
    }
    func testCompleteLocalCandidateStillHasNoExecutionOrBaselineAuthority() throws {
        let r = try check(draft());XCTAssertTrue(r.local_fields_matched);XCTAssertTrue(r.unresolved.isEmpty);XCTAssertFalse(r.execution_allowed || r.baseline_ready || r.baseline_applied || r.app_binding_created);XCTAssertEqual(r.blocked_reasons.count,2)
    }
    func testEachMissingCandidateValueStaysUnresolved() throws {
        let mutations:[(inout ReceiveExecutionCandidate.Draft)->Void] = [{ $0.endpoint=nil },{ $0.account=nil },{ $0.project=nil },{ $0.handoffSHA256=nil },{ $0.targetSHA256=nil },{ $0.runID=nil },{ $0.localProjectID=nil },{ $0.bundleID=nil },{ $0.bootID=nil },{ $0.sessionEpoch=nil },{ $0.timing=nil },{ $0.httpLimit=nil },{ $0.authLimit=nil }]
        for mutate in mutations { var d = try draft();mutate(&d);let r = try check(d);XCTAssertFalse(r.local_fields_matched);XCTAssertEqual(r.unresolved.count,1) }
    }
    func testWrongIdentityAndPinsBlock() throws {
        let mutations:[(inout ReceiveExecutionCandidate.Draft)->Void] = [{ $0.endpoint="https://other.invalid" },{ $0.account=UUID() },{ $0.project=UUID() },{ $0.handoffSHA256=String(repeating:"0",count:64) },{ $0.targetSHA256=String(repeating:"0",count:64) },{ $0.bundleID="other.bundle" }]
        for mutate in mutations { var d = try draft();mutate(&d);XCTAssertThrowsError(try check(d)) }
    }
    func testOldSourceRunOrLocalIdentityCollisionBlocks() throws {
        var d = try draft();d.runID = UUID(uuidString:target.sourceRun);XCTAssertThrowsError(try check(d));d = try draft();d.localProjectID=d.project;XCTAssertThrowsError(try check(d))
    }
    func testChangedBootSessionGenerationAndExpiredRuntimeBlock() throws {
        var d = try draft();d.bootID="other-boot";XCTAssertThrowsError(try check(d));d=try draft();d.sessionEpoch=8;XCTAssertThrowsError(try check(d))
        d=try draft();XCTAssertThrowsError(try ReceiveExecutionCandidate.compare(d,to:target,now:.init(utcMS:6000,monoMS:5000),runtime:runtime(d)))
    }
    func testBudgetsAndInvalidWindowCannotReuseOldUsage() throws {
        var d=try draft();d.httpLimit=16;XCTAssertThrowsError(try check(d));d=try draft();d.authLimit=12;XCTAssertThrowsError(try check(d));d=try draft();d.timing!.expiresUTCMS=1000;XCTAssertThrowsError(try check(d))
    }
    func testNoRuntimeSnapshotDoesNotClaimLocalBinding() throws {
        let r=try ReceiveExecutionCandidate.compare(draft(),to:target,now:.init(utcMS:1000,monoMS:0));XCTAssertFalse(r.local_fields_matched);XCTAssertEqual(r.unresolved,["runtime_snapshot"])
    }
    func testCallSiteObserverPassiveStartAcceptAndRevoke() throws {
        let o=ReceiveAuthCallSiteObserver(),id=UUID(),account=UUID(),clock=ABRuntimeClock(utcMS:1000,monoMS:0)
        XCTAssertThrowsError(try o.owner.source.capture(account:account,clock:clock));o.begin(id);o.accept(id,account:account,accessToken:"synthetic.token",expiresAt:Date(timeIntervalSince1970:6))
        let lease=try o.owner.source.capture(account:account,clock:clock);o.invalidate();XCTAssertThrowsError(try lease.check())
    }
    func testCallSiteSameTokenRefreshAndLateAcceptCannotReviveLease() throws {
        let o=ReceiveAuthCallSiteObserver(),a=UUID(),b=UUID(),account=UUID(),clock=ABRuntimeClock(utcMS:1000,monoMS:0)
        o.begin(a);o.accept(a,account:account,accessToken:"synthetic.token",expiresAt:Date(timeIntervalSince1970:6));let lease=try o.owner.source.capture(account:account,clock:clock)
        o.begin(b);o.accept(a,account:account,accessToken:"old.token",expiresAt:Date(timeIntervalSince1970:6));XCTAssertThrowsError(try o.owner.source.capture(account:account,clock:clock))
        o.accept(b,account:account,accessToken:"synthetic.token",expiresAt:Date(timeIntervalSince1970:6));XCTAssertThrowsError(try lease.check())
    }
    func testCallSiteMissingExpiryAndDuplicateCompletionDoNotPublish() throws {
        let o=ReceiveAuthCallSiteObserver(),a=UUID(),account=UUID(),clock=ABRuntimeClock(utcMS:1000,monoMS:0)
        o.begin(a);o.accept(a,account:account,accessToken:"synthetic.token",expiresAt:nil);o.accept(a,account:account,accessToken:"synthetic.token",expiresAt:Date(timeIntervalSince1970:6))
        XCTAssertThrowsError(try o.owner.source.capture(account:account,clock:clock))
    }
}
