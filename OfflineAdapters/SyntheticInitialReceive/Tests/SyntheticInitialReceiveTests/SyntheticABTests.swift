import Foundation
import XCTest
@testable import SyntheticInitialReceive

final class SyntheticABTests: XCTestCase {
    let runID = "synthetic-ab-ee260914-0000-4000-8000-000000009100"
    var expected = SyntheticABExpected.fixture()
    var timing = SyntheticABTiming.fixture
    var env = SyntheticABEnvironment()
    var responses: [SyntheticABResponse] = []
    var journal: SyntheticABJournal!
    var transport: SyntheticABTransport!
    override func setUpWithError() throws { try reset() }
    func reset(special: Bool = false) throws {
        expected = .fixture(includeSpecial:special); timing = .fixture; env = .init()
        responses = expected.responses()+expected.responses(); journal = try .init(); transport = nil
    }
    func execute(_ delays: SyntheticABDelays = .init()) throws -> SyntheticABCompletion {
        if transport == nil { transport = .init(responses) }
        return try SyntheticABRunner(expected:expected,timing:timing,runID:runID).run(transport:transport,journal:journal,environment:env,delays:delays)
    }
    func fail(_ code: SyntheticABError? = nil,_ delays: SyntheticABDelays = .init(),file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertThrowsError(try execute(delays),file:file,line:line) { error in
            if let code { XCTAssertEqual(error as? SyntheticABError,code,file:file,line:line) }
        }
    }
    func mutate(_ index: Int,_ path: [String],_ value: WindowsJSON?) throws {
        func replace(_ old: WindowsJSON,_ path: ArraySlice<String>) throws -> WindowsJSON {
            guard let first = path.first else { return value ?? .null }
            if case var .object(o) = old {
                if path.count == 1 { o[first] = value } else { o[first] = try replace(XCTUnwrap(o[first]),path.dropFirst()) }; return .object(o)
            }
            var a = try old.array(); a[Int(first)!] = try replace(a[Int(first)!],path.dropFirst()); return .array(a)
        }
        responses[index].raw = try replace(WindowsJSON.decode(responses[index].raw),path[...]).encoded(lf:true)
    }
    func testFourteenReservationsTwoAuthAndAllAuthorityClosed() throws {
        responses += expected.responses()
        let completion = try execute(), report = try completion.checkedReport()
        XCTAssertTrue(report.synthetic_policy_passed); XCTAssertTrue(report.sequential_comparison_passed)
        XCTAssertEqual(report.http_reserved,14); XCTAssertEqual(report.auth_reserved,2); XCTAssertEqual(transport.calls.count,14)
        XCTAssertFalse(report.baseline_applied); XCTAssertFalse(report.baseline_ready); XCTAssertFalse(report.execution_allowed)
        XCTAssertFalse(report.app_binding_created); XCTAssertFalse(report.current_server_verified); XCTAssertFalse(report.latest_at_apply_guaranteed)
        XCTAssertFalse(report.atomic_snapshot); XCTAssertFalse(report.special_body_semantics_verified); XCTAssertThrowsError(try completion.requireApplyInput())
        XCTAssertEqual(try journal.read().status,"finished")
    }
    func testRequestAllowlistOrderBodyAndCountHeaders() throws {
        _ = try execute(); let requests = transport.calls
        XCTAssertEqual(requests.map(\.requestIndex),Array(1...7)+Array(1...7))
        XCTAssertEqual(requests.map(\.phase),Array(repeating:"A",count:7)+Array(repeating:"B",count:7))
        XCTAssertEqual(requests.filter { $0.method == "POST" }.map(\.path),Array(repeating:"/rest/v1/rpc/get_sync_handshake",count:2))
        for r in requests where r.requestIndex >= 3 {
            XCTAssertEqual(r.query,["project_id":"eq."+expected.project,"select":"*","limit":"10000"])
            XCTAssertEqual(r.headers,["Prefer":"count=exact"])
        }
        XCTAssertEqual(requests[0].bodySHA256,byteHash(Data()))
        XCTAssertFalse(requests.contains { $0.path.contains("refresh") || $0.path.contains("commit") })
    }
    func testFifteenthRequestConstructionBlocked() throws {
        let runner = try SyntheticABRunner(expected:expected,timing:timing,runID:runID)
        XCTAssertThrowsError(try runner.request(14)); XCTAssertThrowsError(try runner.request(-1))
    }
    func testNoTakeBeforeReadbackReservation() throws {
        let runner = try SyntheticABRunner(expected:expected,timing:timing,runID:runID), transport = SyntheticABTransport(responses)
        XCTAssertThrowsError(try transport.take(runner.request(0),journal:journal,environment:env))
        XCTAssertEqual(transport.calls.count,0)
    }
    func testAllFourTimesAndRawEvidenceSaved() throws {
        _ = try execute(.init(reservationMS:2))
        let s = try journal.read()
        for (i,e) in s.events.prefix(14).enumerated() {
            XCTAssertEqual(e.reservationID,runID+":\(i+1)")
            XCTAssertEqual(try XCTUnwrap(e.startedMonoMS)-XCTUnwrap(e.reservedMonoMS),2)
            XCTAssertLessThanOrEqual(try XCTUnwrap(e.receivedMonoMS),try XCTUnwrap(e.verifiedMonoMS))
            XCTAssertEqual(e.sha256,byteHash(try XCTUnwrap(e.raw))); XCTAssertEqual(e.byteCount,e.raw?.count)
        }
        XCTAssertEqual(s.events.last?.phase,"local_policy_probe"); XCTAssertNotNil(s.events.last?.completedMonoMS)
    }
    func testLossRetainsStartAndChargeWithoutRaw() throws {
        responses[3].lost = true; fail(.responseLost)
        let s = try journal.read(); XCTAssertEqual(s.httpUsed,4); XCTAssertEqual(s.authUsed,1); XCTAssertEqual(s.status,"stopped")
        XCTAssertNotNil(s.events.last?.startedMonoMS); XCTAssertNil(s.events.last?.raw)
    }
    func testMissingMockDoesNotRefund() throws { responses = []; fail(.mockMissing); XCTAssertEqual(try journal.read().httpUsed,1); XCTAssertEqual(transport.calls.count,1) }
    func testFailedHTTPBodyNeverInJournalOrSummary() throws {
        let secret = "SYNTHETIC-SECRET-ONLY"; responses[1] = .init(raw:Data("{\"access_token\":\"\(secret)\"}".utf8),status:401)
        fail(.httpStatus); let s = try journal.read(); XCTAssertEqual(s.httpUsed,2); XCTAssertNil(s.events.last?.raw); XCTAssertNotNil(s.events.last?.sha256)
        XCTAssertFalse(String(decoding:journal.blob,as:UTF8.self).contains(secret)); XCTAssertFalse(String(decoding:journal.blob,as:UTF8.self).contains(Data(secret.utf8).base64EncodedString()))
    }
    func testRedirectAndUnexpectedStatusNeverFollowed() throws {
        for status in [301,302,307,204,206] {
            try reset(); responses[0].status = status; fail(.httpStatus); XCTAssertEqual(transport.calls.count,1)
        }
    }
    func testSubjectFailureStopsBeforeNextReservation() throws {
        try mutate(0,["id"],.string("ee260914-0000-4000-8000-000000000099")); fail(.subject); XCTAssertEqual(transport.calls.count,1); XCTAssertEqual(try journal.read().httpUsed,1)
    }
    func testHandshakeFailureStopsBeforeThirdRequest() throws { try mutate(1,["migration_epoch"],.number("2")); fail(.handshake); XCTAssertEqual(transport.calls.count,2) }
    func testProjectTrashCannotUseSyntheticDeletedFallback() throws {
        try mutate(2,["0","trashed_at"],nil); try mutate(2,["0","is_deleted"],.bool(false)); fail(.contract); XCTAssertEqual(transport.calls.count,3)
    }
    func testSettingsFailureStopsBeforeDocumentRequest() throws { try mutate(3,["0","project_sync_mode"],.string("LEGACY")); fail(.settings); XCTAssertEqual(transport.calls.count,4) }
    func testCountFailureStopsWithoutExtraPage() throws {
        responses[4].contentRange = "0-1/3"; fail(.count); XCTAssertEqual(try journal.read().httpUsed,5); XCTAssertEqual(transport.calls.count,5)
    }
    func test206RequiresCompleteCount() throws {
        responses[4].status = 206; _ = try execute()
        try reset(); responses[4].status = 206; responses[4].contentRange = nil; fail(.count)
    }
    func testEmptyArrayCountRules() throws {
        try SyntheticABExpected.count("*/0",rows:0); try SyntheticABExpected.count("0-0/0",rows:0)
        XCTAssertThrowsError(try SyntheticABExpected.count(nil,rows:0)); XCTAssertThrowsError(try SyntheticABExpected.count("0-0/1",rows:0))
        XCTAssertThrowsError(try SyntheticABExpected.count("0-9999/*",rows:10000))
    }
    func testTruncatedJSONAndMalformedUTF8StopEarly() throws {
        for raw in [Data("[".utf8),Data([0xff])] { try reset(); responses[4].raw = raw; fail(.contract); XCTAssertEqual(transport.calls.count,5) }
    }
    func testDuplicateJSONAndBoolRevisionRejected() throws {
        responses[0].raw = Data("{\"id\":\"x\",\"id\":\"x\"}".utf8); fail(.contract)
        try reset(); try mutate(4,["0","revision"],.bool(true)); fail(.contract); XCTAssertEqual(transport.calls.count,5)
    }
    func testSameIncompleteGraphInBothPassesCannotSucceed() throws {
        try mutate(6,["1","children"],.array([])); responses[13] = responses[6]; fail(); XCTAssertEqual(transport.calls.count,7)
    }
    func testMemberBodyAndReferenceVersionChangesDetected() throws {
        try mutate(11,["0","content"],.string("later")); fail(.targetChanged)
        try reset(); try mutate(13,["0","revision"],.number("2")); fail(.targetChanged)
    }
    func testUnknownFieldsAndLexicalDateChangesCompared() throws {
        try mutate(9,["0","future"],.string("changed")); fail(.abChanged)
        try reset(); try mutate(2,["0","updated_at"],.string("2026-09-14T00:00:00Z")); try mutate(9,["0","updated_at"],.string("2026-09-14T09:00:00+09:00")); fail(.abChanged)
    }
    func testSpecialRowsComparedWithoutBodyPromotion() throws {
        try reset(special:true); let result = try execute().checkedReport(); XCTAssertFalse(result.special_body_semantics_verified)
        try reset(special:true); try mutate(11,["2","content"],.string("changed")); fail(.abChanged)
    }
    func testObjectRowCapabilityAndProtocolOrderIgnored() throws {
        for i in [11,12,13] { responses[i].raw = try WindowsJSON.array(WindowsJSON.decode(responses[i].raw).array().reversed()).encoded(lf:true) }
        let capabilities = try WindowsJSON.decode(responses[8].raw).list("server_capabilities")
        try mutate(8,["server_capabilities"],.array(capabilities.reversed()))
        try mutate(1,["supported_protocol_versions"],.array([.number("3"),.number("4")]))
        try mutate(8,["supported_protocol_versions"],.array([.number("4"),.number("3")]))
        XCTAssertTrue(try execute().checkedReport().sequential_comparison_passed)
    }
    func testCapabilitySetChangesDetected() throws {
        var caps = try WindowsJSON.decode(responses[8].raw).list("server_capabilities"); caps.append(.string("synthetic-extra")); try mutate(8,["server_capabilities"],.array(caps)); fail(.abChanged)
    }
    func testResponseAndAggregateLimits() throws {
        timing.maxResponseBytes = 10; timing.maxRunBytes = 100; fail(.responseSize); XCTAssertEqual(try journal.read().httpUsed,1)
        try reset(); let max = responses.map { $0.raw.count }.max()!; timing.maxResponseBytes = max; timing.maxRunBytes = max+1; fail(.runSize); XCTAssertGreaterThan(try journal.read().httpUsed,1)
    }
    func testInvalidPolicyValuesRejectedBeforeClaim() throws {
        let paths: [WritableKeyPath<SyntheticABTiming,Int>] = [\.requestMS,\.passMS,\.interpassMS,\.preApplyMS,\.localApplyMS,\.totalMS,\.expiresUTCMS,\.maxResponseBytes,\.maxRunBytes]
        for key in paths { for v in [0,-1,Int.max] { timing = .fixture; timing[keyPath:key] = v; fail(.policy); XCTAssertEqual(try journal.read().status,"unused") } }
    }
    func testInvalidWindowAndSizePolicy() throws {
        timing.notBeforeUTCMS = 6000; fail(.policy)
        timing = .fixture; timing.maxRunBytes = 1; fail(.policy)
        timing = .fixture; timing.maxResponseBytes = 4*1024*1024+1; fail(.policy)
    }
    func testNegativeDelayCannotConsumeBudget() throws { responses[0].delayMS = -1; fail(.policy); XCTAssertEqual(try journal.read().httpUsed,0) }
    func testAbsoluteWindowBoundaries() throws {
        for now in [999,6000] { try reset(); env = .init(utcMS:now); fail(.window); XCTAssertEqual(transport.calls.count,0) }
        try reset(); timing.expiresUTCMS = 1014; fail(.expired)
        try reset(); timing.expiresUTCMS = 1015; _ = try execute()
    }
    func testRequestTimeoutIncludesReservationWithoutSend() throws {
        fail(.requestTimeout,.init(reservationMS:100)); XCTAssertEqual(transport.calls.count,0); XCTAssertEqual(try journal.read().httpUsed,1)
    }
    func testRequestTimeoutIncludesReceiveAndPersistence() throws {
        responses[0].delayMS = 100; fail(.requestTimeout)
        try reset(); responses[0].persistenceMS = 99; fail(.requestTimeout); XCTAssertNil(try journal.read().events.last?.raw)
        try reset(); responses[0].delayMS = 99; _ = try execute()
    }
    func testPassTimeoutEqualityAndReservationBoundary() throws {
        timing.passMS = 7; fail(.passTimeout); XCTAssertEqual(transport.calls.count,7)
        try reset(); timing.passMS = 8; _ = try execute()
        try reset(); timing.passMS = 2; fail(.passTimeout,.init(reservationMS:2)); XCTAssertEqual(transport.calls.count,0)
    }
    func testInterpassIncludesLastResponsePersistence() throws {
        responses[6].persistenceMS = 30; fail(.interpassTimeout,.init(interpassMS:70)); XCTAssertEqual(transport.calls.count,7)
        try reset(); responses[6].persistenceMS = 30; _ = try execute(.init(interpassMS:69))
    }
    func testPreApplyIncludesPersistenceComparisonAndWait() throws {
        responses[13].persistenceMS = 30; fail(.preApplyTimeout,.init(comparisonMS:20,preApplyMS:50))
        try reset(); responses[13].persistenceMS = 30; _ = try execute(.init(comparisonMS:20,preApplyMS:49))
    }
    func testLocalDurationOnlyRecordsProbe() throws {
        fail(.localProbeTimeout,.init(localApplyMS:100)); let s = try journal.read()
        XCTAssertEqual(s.httpUsed,14); XCTAssertEqual(s.events.last?.phase,"local_policy_probe"); XCTAssertNil(s.events.last?.completedMonoMS); XCTAssertEqual(s.status,"stopped")
        try reset(); _ = try execute(.init(localApplyMS:99))
    }
    func testTotalDeadlineEvenIfOtherLimitsPass() throws {
        timing.totalMS = 14; fail(.totalTimeout)
        try reset(); timing.totalMS = 15; _ = try execute()
    }
    func testArithmeticOverflowBlocksWithoutWrapping() throws {
        env = .init(utcMS:9_007_199_254_740_989,sessionExpiresUTCMS:9_007_199_254_740_991); timing.notBeforeUTCMS = 0; timing.expiresUTCMS = 9_007_199_254_740_991
        responses[0].delayMS = 3; fail(.arithmetic); XCTAssertEqual(try journal.read().httpUsed,1)
    }
    func testBackgroundAndQuickReactivationBothRevoke() throws {
        for effect: SyntheticABEffect in [.background,.backgroundAndActivate] { try reset(); responses[3].effect = effect; fail(.lifecycle); XCTAssertEqual(try journal.read().httpUsed,4) }
    }
    func testProtectedDataLossAndQuickRestoreBothRevoke() throws {
        for effect: SyntheticABEffect in [.protectedLoss,.protectedLossAndRestore] { try reset(); responses[3].effect = effect; fail(.lifecycle); XCTAssertEqual(try journal.read().httpUsed,4) }
    }
    func testSessionIdentityAndGenerationBothBound() throws {
        for effect: SyntheticABEffect in [.replaceSession,.replaceSessionWithSameID] { try reset(); responses[3].effect = effect; fail(.sessionChanged); XCTAssertEqual(try journal.read().httpUsed,4) }
    }
    func testBootIdentityAndGenerationBothBound() throws {
        for effect: SyntheticABEffect in [.restart,.restartWithSameID] { try reset(); responses[3].effect = effect; fail(.bootChanged) }
    }
    func testClockRollbackAndCancellationStop() throws {
        for effect: SyntheticABEffect in [.utcBackward,.monoBackward,.cancel] { try reset(); responses[3].effect = effect; fail(effect == .cancel ? .cancelled : .clockBackward) }
    }
    func testReservationLifecycleRevocationConsumesButDoesNotSend() throws {
        fail(.lifecycle,.init(reservationEffect:.backgroundAndActivate)); XCTAssertEqual(try journal.read().httpUsed,1); XCTAssertEqual(transport.calls.count,0)
    }
    func testInterruptDuringEvidencePersistencePreservesMetadataOnly() throws {
        responses[0].persistenceEffect = .replaceSessionWithSameID; fail(.sessionChanged)
        let e = try journal.read().events[0]; XCTAssertNotNil(e.startedMonoMS); XCTAssertNotNil(e.sha256); XCTAssertNil(e.raw)
    }
    func testInterruptAtAllPostResponseStages() throws {
        let delays: [SyntheticABDelays] = [.init(interpassEffect:.background),.init(comparisonEffect:.background),.init(preApplyEffect:.background),.init(localEffect:.background)]
        for d in delays { try reset(); fail(.lifecycle,d); XCTAssertEqual(try journal.read().status,"stopped") }
    }
    func testFinishAndDelayedPublicationCannotReviveLease() throws {
        fail(.lifecycle,.init(finishEffect:.backgroundAndActivate)); XCTAssertEqual(try journal.read().status,"finished")
        try reset(); let completion = try execute(); try env.apply(.replaceSessionWithSameID); XCTAssertThrowsError(try completion.checkedReport())
    }
    func testDelayedReportExpiresAndNeverApplies() throws {
        let completion = try execute(); try env.advance(5000); XCTAssertThrowsError(try completion.checkedReport()); XCTAssertThrowsError(try completion.requireApplyInput())
    }
    func testInactiveLockedAndCancelledCannotClaim() throws {
        for (active,available) in [(false,true),(true,false)] { try reset(); env = .init(active:active,protectedDataAvailable:available); fail(.lifecycle); XCTAssertEqual(try journal.read().httpUsed,0) }
        try reset(); try env.apply(.cancel); fail(.cancelled); XCTAssertEqual(try journal.read().status,"unused")
    }
    func testSameJournalCannotBeUsedAfterSuccessOrStop() throws {
        _ = try execute(); let bytes = journal.blob; transport = nil; fail(.runReuse); XCTAssertEqual(journal.blob,bytes); XCTAssertEqual(transport.calls.count,0)
        try reset(); responses[0].lost = true; fail(.responseLost); let stopped = journal.blob; transport = nil; fail(.runReuse); XCTAssertEqual(journal.blob,stopped)
    }
    func testSerializedRunningStoppedAndFinishedRemainClosed() throws {
        for status in ["running","stopped","finished"] {
            try reset(); let runner = try SyntheticABRunner(expected:expected,timing:timing,runID:runID)
            let state = SyntheticABJournalState(runID:runID,binding:runner.binding,status:status)
            let bytes = try canonical(state); journal = try .init(restored:bytes); fail(.runReuse); XCTAssertEqual(journal.blob,bytes); XCTAssertEqual(transport.calls.count,0)
        }
    }
    func testTransportCannotBeReusedWithFreshJournal() throws {
        _ = try execute(); journal = try .init(); fail(.transportReuse); XCTAssertEqual(try journal.read().httpUsed,0)
    }
    func testNoopAndBeforeAfterWriteFaultsDoNotSend() throws {
        for injection in 0..<3 { for ordinal in [1,3] {
            try reset(); let op = "reserve:\(ordinal)"
            if injection == 0 { journal.skipOperation = op } else if injection == 1 { journal.failBefore = op } else { journal.failAfter = op }
            fail(); XCTAssertEqual(transport.calls.count,ordinal-1); XCTAssertTrue(journal.poisoned)
            XCTAssertEqual(try journal.read().httpUsed,ordinal-1+(injection == 2 ? 1 : 0))
        } }
    }
    func testClaimFaultDoesNotConsumeRequest() throws {
        for injection in 0..<3 {
            try reset(); if injection == 0 { journal.skipOperation = "claim" } else if injection == 1 { journal.failBefore = "claim" } else { journal.failAfter = "claim" }
            fail(); XCTAssertEqual(transport.calls.count,0); XCTAssertEqual(try journal.read().httpUsed,0); XCTAssertTrue(journal.poisoned)
        }
    }
    func testStartWriteFaultPreservesChargeButNoTransport() throws {
        journal.skipOperation = "start:1"; fail(.journalReadback); XCTAssertEqual(try journal.read().httpUsed,1); XCTAssertEqual(transport.calls.count,0)
    }
    func testMetadataResponseProbeFinishFailuresNeverReturnSuccess() throws {
        for (op,calls) in [("metadata:1",1),("response:1",1),("response:7",7),("local_start",14),("finish",14)] {
            try reset(); journal.skipOperation = op; fail(.journalReadback); XCTAssertEqual(transport.calls.count,calls); XCTAssertEqual(try journal.read().httpUsed,calls)
        }
    }
    func testPoisonedJournalNeverRetries() throws {
        journal.failAfter = "reserve:1"; fail(.journalUncertain); transport = nil; fail(.journalPoisoned); XCTAssertEqual(transport.calls.count,0)
    }
    func testBusyAndCorruptionDoNotClaim() throws {
        journal.lock.lock(); fail(.busy); journal.lock.unlock(); XCTAssertEqual(transport.calls.count,0)
        journal = try .init(restored:Data("{".utf8)); fail(.journalCorrupt); XCTAssertEqual(transport.calls.count,0)
    }
    func testBindingIncludesTimingAndSyntheticTarget() throws {
        let a = try SyntheticABRunner(expected:expected,timing:timing,runID:runID); timing.requestMS += 1
        let b = try SyntheticABRunner(expected:expected,timing:timing,runID:runID); XCTAssertNotEqual(a.binding,b.binding)
        XCTAssertFalse(a.binding.contains(expected.project))
    }
    func testRealRunIDAndNonSyntheticSessionLabelsRejected() throws {
        XCTAssertThrowsError(try SyntheticABRunner(expected:expected,timing:timing,runID:"cf1c003a-d2c9-4873-a3db-bbac1368ee05"))
        env = .init(sessionID:"real-session-placeholder"); fail(.policy); XCTAssertEqual(try journal.read().httpUsed,0)
    }
    func testIndependentSyntheticSessionExpiryBeforeAndDuringRun() throws {
        env = .init(sessionExpiresUTCMS:1000); fail(.sessionExpired); XCTAssertEqual(try journal.read().httpUsed,0)
        try reset(); env = .init(sessionExpiresUTCMS:1004); fail(.sessionExpired); XCTAssertEqual(try journal.read().httpUsed,4)
        try reset(); env = .init(sessionExpiresUTCMS:1015); _ = try execute()
        try reset(); env = .init(sessionExpiresUTCMS:0); fail(.policy); XCTAssertEqual(try journal.read().httpUsed,0)
    }
    func testSessionContextIsHashedIntoJournalBinding() throws {
        _ = try execute(); let a = try journal.read().binding
        try reset(); env = .init(sessionID:"synthetic-other-session"); _ = try execute()
        XCTAssertNotEqual(try journal.read().binding,a)
    }
    func testPositiveClockValuesCanStillRollBack() throws {
        env = .init(monoMS:1000); responses[0].effect = .monoBackward; fail(.clockBackward); XCTAssertGreaterThan(env.monoMS,0)
        try reset(); responses[0].effect = .utcBackward; fail(.clockBackward); XCTAssertGreaterThan(env.utcMS,0)
    }
    func testUnknownNumberSpellingIsConservativelyRetained() throws {
        try mutate(2,["0","future_number"],.number("1e0"))
        try mutate(9,["0","future_number"],.number("1.0"))
        fail(.abChanged)
    }
    func testReportNeverExportsRawSessionOrBody() throws {
        let report = try execute().checkedReport(), value = try WindowsJSON.decode(canonical(report))
        XCTAssertNil(try value.object()["raw"]); XCTAssertNil(try value.object()["sessionID"])
        XCTAssertFalse(String(decoding:try canonical(report),as:UTF8.self).contains("합성 AB"))
    }
}
