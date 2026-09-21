import Foundation
import XCTest
@testable import SyntheticInitialReceive

final class WindowsReaderTests: XCTestCase {
    var files: [String:Data] = [:]
    var binding: WindowsJSON = .null
    override func setUpWithError() throws {
        files = try WindowsHandoffReader.files(from:Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!))
        binding = try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!)).get("binding")
    }
    func read(_ p: String) throws -> WindowsJSON { try WindowsJSON.decode(XCTUnwrap(files[p])) }
    func change(_ p: String,_ path: [String],_ value: WindowsJSON?) throws {
        func replacing(_ old: WindowsJSON,_ path: ArraySlice<String>) throws -> WindowsJSON {
            guard let head = path.first else { return value ?? .null }
            if case var .object(o) = old {
                if path.count == 1 { o[head] = value }
                else { o[head] = try replacing(XCTUnwrap(o[head]),path.dropFirst()) }; return .object(o)
            }
            var a = try old.array(); guard let i = Int(head), i < a.count else { throw WindowsReaderError.shape }
            a[i] = try replacing(a[i],path.dropFirst()); return .array(a)
        }
        files[p] = try replacing(read(p),path[...]).encoded(lf:true)
    }
    /// Test producer only: re-seal altered synthetic bytes to exercise independent validation.
    func reseal(target: Bool = false) throws {
        var h = try read("handoff.json").object()
        if target {
            var t = try read("target.json").object()
            for (k,v) in try h["target"]!.object() where k != "manifest_ref" { t[k] = v }
            files["target.json"] = WindowsJSON.object(t).encoded(lf:true)
        }
        let candidate = byteHash(try XCTUnwrap(files["source/baseline-candidate.json"]))
        let hashes = files.filter { $0.key.hasPrefix("source/") && !$0.key.hasSuffix("candidate-prepared.json") && !$0.key.hasSuffix("terminal.json") }
        files["source/037-candidate-prepared.json"] = WindowsJSON.object(["files":.object(Dictionary(uniqueKeysWithValues:hashes.map { (String($0.key.dropFirst(7)),.string(byteHash($0.value))) })),"sha256":.string(candidate)]).encoded(lf:true)
        h["candidate_sha256"] = .string(candidate)
        h["artifacts"] = .array(files.keys.sorted().filter { $0 != "handoff.json" && $0 != "completed.json" }.map { p in
            .object(["artifact_id":.string(p.hasPrefix("source/") ? String(p.dropFirst(7)) : p),"path":.string(p),"role":.string(p == "target.json" ? "target-draft" : "retained-source"),"sha256":.string(byteHash(files[p]!)),"byte_count":.number(String(files[p]!.count))])
        })
        files["handoff.json"] = WindowsJSON.object(h).encoded(lf:true)
        files["completed.json"] = WindowsJSON.object(["format":.string("windows-handoff-local-seal-v1"),"handoff_sha256":.string(byteHash(files["handoff.json"]!)),"target_sha256":.string(byteHash(files["target.json"]!)),"source_run_id":h["source_run_id"]!,"execution_allowed":.bool(false),"source_files":.object(Dictionary(uniqueKeysWithValues:files.filter { $0.key.hasPrefix("source/") }.map { (String($0.key.dropFirst(7)),.string(byteHash($0.value))) }))]).encoded(lf:true)
    }
    func expected() throws -> WindowsHandoffExpectation { try .init(handoffSHA256:byteHash(XCTUnwrap(files["handoff.json"])),bindingJSON:binding.encoded()) }
    func reviewFixture(target: Bool = false) throws -> WindowsHandoffReview { try reseal(target:target); return try WindowsHandoffReader.review(files:files,expected:expected()) }
    func blocked(target: Bool = false) { XCTAssertThrowsError(try reviewFixture(target:target)) }
    func portable() -> Data { WindowsJSON.object(["format":.string("ipad-windows-handoff-review-bytes-v1"),"files":.object(files.mapValues { .string($0.base64EncodedString()) })]).encoded() }
    func lifecycle() -> BoundaryLifecycle { let l = BoundaryLifecycle(); l.update(active:true,protectedDataAvailable:true); return l }

    func addSpecialContext() throws {
        let id = "ee260914-0000-4000-8000-000000000099"
        var rows = try read("source/Q14.body").array()
        var row = try rows[0].object()
        row["document_id"] = .string(id)
        row["relative_path"] = .string("__antigravity__/metadata")
        row["revision"] = .null; row["structure_revision"] = .null
        var oldRows = try read("source/Q5.body").array()
        oldRows.append(.object(row))
        files["source/Q5.body"] = WindowsJSON.array(oldRows).encoded(lf:true)
        try change("handoff.json",["evidence","Q5.row_count","value"],.number(String(oldRows.count)))
        rows.append(.object(row))
        files["source/Q14.body"] = WindowsJSON.array(rows).encoded(lf:true)
        try change("handoff.json",["evidence","Q14.row_count","value"],.number("3"))
        try change("handoff.json",["target","context_only"],.array([.object([
            "entity_id":.string(id),"entity_kind":.string("document"),
            "classification":.string("special-metadata"),
            "source_refs":.array([.object(["artifact_id":.string("Q14.body"),"json_pointer":.string("/2")])])
        ])]))
        for observation in try read("handoff.json").list("observations") {
            let request = try observation.get("request_index").int()
            if request == 5 || request == 14 {
                let event = "source/" + (try observation.get("response_event_ref").str("artifact_id"))
                let bytes = try XCTUnwrap(files["source/Q\(request).body"])
                try change(event,["bytes"],.number(String(bytes.count)))
                try change(event,["sha256"],.string(byteHash(bytes)))
            }
        }
        try reseal(target:true)
    }
    func testReviewedSpecialNullRevisionsRemainUnverified() throws {
        try addSpecialContext()
        let target = try ReviewedReceiveTarget.read(portable:portable(),expected:expected())
        let special = try XCTUnwrap(target.entities.first { $0.role == "context_only" })
        XCTAssertNil(special.revision); XCTAssertNil(special.structureRevision)
        XCTAssertNil(special.bodySHA256); XCTAssertNil(special.bodyBytes)
        XCTAssertFalse(target.review.special_body_semantics_verified)
        XCTAssertThrowsError(try target.requireApplyInput())
    }
    func testReviewedNormalNullRevisionsStillRejected() throws {
        for key in ["revision","structure_revision"] {
            try setUpWithError()
            try change("source/Q14.body",["0",key],.null); try reseal()
            XCTAssertThrowsError(try ReviewedReceiveTarget.read(portable:portable(),expected:expected()))
        }
    }
    func testReviewedSpecialCannotBecomeMember() throws {
        try addSpecialContext()
        let special = try read("handoff.json").get("target").list("context_only")
        let members = try read("handoff.json").get("target").list("members")
        try change("handoff.json",["target","members"],.array(members + special))
        try change("handoff.json",["target","context_only"],.array([])); try reseal(target:true)
        XCTAssertThrowsError(try ReviewedReceiveTarget.read(portable:portable(),expected:expected()))
    }
    func testLocalRetainedReviewedTargetWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RECEIVE_RETAINED_REVIEW_PATH"] else {
            throw XCTSkip("Optional private retained fixture is not supplied")
        }
        let bytes = try Data(contentsOf:URL(fileURLWithPath:path))
        XCTAssertEqual(byteHash(bytes),"ea40cbc7e87ed0b1e2c3d218dd1746482afa55e28ecfe1c932ba2c13aaeab9ce")
        let target = try ReviewedReceiveTarget.read(portable:bytes,expected:.retainedSeptember14())
        XCTAssertEqual(target.review.context_only,18)
        XCTAssertFalse(target.review.execution_allowed)
        XCTAssertThrowsError(try target.requireApplyInput())
    }

    func testNativeReaderSuccessAndNoAuthority() throws {
        let r = try reviewFixture(); XCTAssertEqual(r.source_files,60); XCTAssertEqual(r.members,4); XCTAssertEqual(r.references,1)
        XCTAssertEqual(r.normal_bodies_checked,2); XCTAssertEqual(r.missing_evidence,52)
        XCTAssertFalse(r.baseline_ready); XCTAssertFalse(r.baseline_applied); XCTAssertFalse(r.execution_allowed)
        XCTAssertFalse(r.fresh_ab_verified); XCTAssertFalse(r.app_binding_created); XCTAssertFalse(r.special_body_semantics_verified)
        XCTAssertThrowsError(try r.requireApplyInput())
    }
    func testPortablePreservesExactOriginalBytes() throws {
        let before = files; XCTAssertEqual(try WindowsHandoffReader.files(from:portable()),before)
        _ = try WindowsHandoffReader.review(portable:portable(),expected:expected()); XCTAssertEqual(files,before)
    }
    func testExternalPinCannotComeFromPayload() throws {
        let e = try WindowsHandoffExpectation(handoffSHA256:String(repeating:"0",count:64),bindingJSON:binding.encoded())
        XCTAssertThrowsError(try WindowsHandoffReader.review(portable:portable(),expected:e))
    }
    func testWrongExternalBinding() throws {
        var b = try binding.object(); b["account_id"] = .string("ee260914-0000-4000-8000-000000000099"); binding = .object(b); blocked()
    }
    func testKnownRetainedProfileDoesNotAcceptSynthetic() throws {
        XCTAssertThrowsError(try WindowsHandoffReader.review(portable:portable(),expected:.retainedSeptember14()))
    }
    func testRawHashTamper() throws {
        let e = try expected(); files["source/Q14.body"]!.append(32)
        XCTAssertThrowsError(try WindowsHandoffReader.review(files:files,expected:e))
    }
    func testMissingRawNotSynthesized() throws { files.removeValue(forKey:"source/Q14.body"); blocked() }
    func testDuplicateJSONKeyRejected() throws {
        files["source/Q1.body"] = Data(#"{"id":"x","id":"x"}"#.utf8); blocked()
    }
    func testDuplicateEscapedKeyRejected() { XCTAssertThrowsError(try WindowsJSON.decode(Data(#"{"x":1,"\u0078":2}"#.utf8))) }
    func testUnknownEnvelopeFieldRejected() throws { try change("handoff.json",["new_authority"],.bool(true)); blocked() }
    func testFinalizedInputRejected() throws { try change("handoff.json",["schema_finalized"],.bool(true)); blocked() }
    func testFalseFlagsCannotBeRaised() throws { try change("handoff.json",["authority","execution_allowed"],.bool(true)); blocked() }
    func testSourceSealCorrupt() throws {
        let e = try expected(); try change("completed.json",["source_files","Q14.body"],.string(String(repeating:"0",count:64)))
        XCTAssertThrowsError(try WindowsHandoffReader.review(files:files,expected:e))
    }
    func testPlanHashMismatch() throws { try change("source/plan.json",["root_path"],.string("changed")); blocked() }
    func testRowPointerSwap() throws { try change("handoff.json",["target","members","0","source_refs","0","json_pointer"],.string("/1")); blocked(target:true) }
    func testLeadingZeroPointer() throws { try change("handoff.json",["target","members","0","source_refs","0","json_pointer"],.string("/00")); blocked(target:true) }
    func testPointerEscapeAndScalarBoundary() {
        XCTAssertThrowsError(try WindowsJSON.string("x").pointer("/x")); XCTAssertThrowsError(try WindowsJSON.object([:]).pointer("/~9"))
    }
    func testVersionBoolRejected() throws { try change("source/Q14.body",["0","revision"],.bool(true)); blocked() }
    func testVersionFloatRejected() throws { try change("source/Q14.body",["0","revision"],.number("1.0")); blocked() }
    func testVersionExponentRejected() throws { try change("source/Q14.body",["0","revision"],.number("1e0")); blocked() }
    func testMissingDateRejected() throws { try change("source/Q14.body",["0","updated_at"],nil); blocked() }
    func testInvalidCalendarAndOffsetRejected() {
        for s in ["2026-02-30T00:00:00Z","2026-01-01T00:00:60Z","2026-01-01T00:00:00+14:01","٢٠٢٦-01-01T00:00:00Z","2026-01-01T00:00:00Z\n"] {
            XCTAssertThrowsError(try WindowsHandoffReader.date(.string(s)))
        }
    }
    func testDatePrecisionOriginalBytesRetained() throws {
        for s in ["2026-01-01T00:00:00Z","2026-01-01T00:00:00.123456+14:00"] { try WindowsHandoffReader.date(.string(s)) }
    }
    func testDeletionContradictionRejected() throws { try change("source/Q14.body",["0","deleted_at"],.string("2026-01-01T00:00:00Z")); blocked() }
    func testBodyByteMismatchRejected() throws { try change("handoff.json",["target","members","0","body","utf8_bytes"],.number("1")); blocked(target:true) }
    func testBodyCRAndNULRejected() { for s in ["a\rb","a\0b"] { XCTAssertThrowsError(try WindowsHandoffReader.body(.string(s))) } }
    func testProjectTrashIsNotDocumentDeletionFlag() throws {
        try change("source/Q12.body",["0","trashed_at"],nil); try change("source/Q12.body",["0","is_deleted"],.bool(false)); blocked()
    }
    func testTrashedProjectRejected() throws { try change("source/Q12.body",["0","trashed_at"],.string("2026-01-01T00:00:00Z")); blocked() }
    func testHandshakeCapabilityMismatchRejected() throws { try change("source/Q2.body",["server_capabilities"],.array([])); blocked() }
    func testClientServerCapabilitiesSeparate() throws {
        try change("source/creation-requests.json",["0","batch","client_capabilities"],.array(WindowsHandoffReader.serverCaps.sorted().map { .string($0) })); blocked()
    }
    func testOperationReceiptMismatchRejected() throws { try change("source/Q9.body",["results","0","operation_id"],.string("ee260914-0000-4000-8000-000000000999")); blocked() }
    func testFailedCreationNotApplied() throws { try change("source/Q9.body",["applied"],.bool(false)); blocked() }
    func testOrderNotSilentlySorted() throws { try change("source/Q16.body",["1","children"],.array([])); blocked() }
    func testRequiredReferenceCannotBeContext() throws {
        let refs = try read("handoff.json").get("target").get("references")
        try change("handoff.json",["target","references"],.array([])); try change("handoff.json",["target","context_only"],refs); blocked(target:true)
    }
    func testRawCountIndependent() throws { try change("handoff.json",["evidence","Q14.row_count","value"],.number("9")); blocked() }
    func testMissingTimeNotFilled() throws { try change("handoff.json",["evidence","Q1.started_at","value"],.number("1000")); blocked() }
    func testSourceEndedRunNotResumable() throws { try change("source/038-terminal.json",["resumable"],.bool(true)); blocked() }
    func testReservationNotRefunded() throws { try change("source/015-reserved.json",["writes_reserved"],.number("0")); blocked() }
    func testClaimedIndependentSuccessNotAdopted() throws {
        try change("handoff.json",["server_provenance_verified"],.bool(true))
        let r = try reviewFixture(); XCTAssertFalse(r.current_server_verified); XCTAssertFalse(r.schema_finalized)
    }
    func testCanonicalContractAndArtifactLFDiffer() throws {
        let v: WindowsJSON = .object(["name":.string("e\u{301}🙂\n"),"n":.number("1")])
        XCTAssertEqual(v.encoded(),Data("{\"n\":1,\"name\":\"e\u{301}🙂\\n\"}".utf8))
        XCTAssertNotEqual(byteHash(v.encoded()),byteHash(v.encoded(lf:true)))
    }
    func testMalformedJSONBounded() {
        for s in ["[1,]","{\"x\":1,}","NaN","1e999","01",String(repeating:"[",count:66)+"0"+String(repeating:"]",count:66),#""\ud800""#] { XCTAssertThrowsError(try WindowsJSON.decode(Data(s.utf8))) }
    }
    func testPortableTraversalAndInvalidBase64() {
        for value: WindowsJSON in [.object(["../handoff.json":.string("e30=")]),.object(["handoff.json":.string("%%%%")])] {
            XCTAssertThrowsError(try WindowsHandoffReader.files(from:WindowsJSON.object(["format":.string("ipad-windows-handoff-review-bytes-v1"),"files":value]).encoded()))
        }
    }
    func testInactiveCannotStartWork() {
        let l = BoundaryLifecycle(); XCTAssertThrowsError(try l.begin())
    }
    func testLeaseRevokedDuringNativeReview() throws {
        let l = lifecycle(), lease = try l.begin(); var count = 0
        XCTAssertThrowsError(try WindowsHandoffReader.review(files:files,expected:expected(),checkpoint:{
            count += 1; if count == 10 { l.update(active:false,protectedDataAvailable:true) }; try lease.check()
        }))
        XCTAssertGreaterThanOrEqual(count,10)
    }
    func testLatePublicationCannotReviveAfterUnlock() throws {
        let l = lifecycle(), work = try WindowsReaderWork(lease:l.begin()), r = try work.review(portable:portable(),expected:expected())
        l.update(active:false,protectedDataAvailable:false); l.update(active:true,protectedDataAvailable:true)
        XCTAssertThrowsError(try work.publish(r)); XCTAssertFalse(r.baseline_applied)
    }
    func testNewExplicitWorkAfterActivation() throws {
        let l = lifecycle(); l.update(active:false,protectedDataAvailable:false); l.update(active:true,protectedDataAvailable:true)
        let work = try WindowsReaderWork(lease:l.begin()); XCTAssertEqual(try work.publish(work.review(portable:portable(),expected:expected())).members,4)
    }
    func testReadOnlyLocalFileAndNoStoreCreation() throws {
        let dir = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("synthetic-reader-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:dir) }
        let file = dir.appendingPathComponent("input.json"), bytes = portable(); try bytes.write(to:file)
        let work = try WindowsReaderWork(lease:lifecycle().begin()); _ = try work.review(portable:work.readLocalFile(file),expected:expected())
        XCTAssertEqual(try Data(contentsOf:file),bytes); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path),["input.json"])
        let link = dir.appendingPathComponent("link.json"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try work.readLocalFile(link))
    }
    func testReportDoesNotContainRawContent() throws {
        let r = try reviewFixture(), data = try canonical(r), value = try WindowsJSON.decode(data)
        XCTAssertNil(try value.object()["content"]); XCTAssertNil(try value.object()["files"])
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("synthetic.invalid"))
    }
}
