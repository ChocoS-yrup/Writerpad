import Foundation
import XCTest
@testable import WriterPad

@MainActor
final class SyncV2ProjectTransitionTests: XCTestCase {
    private let identity = SyncV2TransitionIdentity(localID: UUID(), serverID: UUID(), accountID: UUID(), deviceID: UUID())
    private func journal() -> SyncV2TransitionJournal {
        SyncV2TransitionJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent("transition-tests-" + UUID().uuidString))
    }
    private func model(_ transport: TransitionTransportStub, _ journal: SyncV2TransitionJournal,
                       epoch: SyncV2ContractEpoch = .init()) -> SyncV2ProjectTransitionModel {
        let identity = identity
        return .init(transport: transport, journal: journal) { _ in
            let version = epoch.value
            return .init(identity: identity, check: {
                guard epoch.value == version else { throw SyncV2ContractError("STALE_AUTH") }
            })
        }
    }
    func testInspectionHasNoWritesAndCompletionNeedsExplicitValidation() async throws {
        let transport = TransitionTransportStub(identity: identity)
        let model = model(transport, journal())
        await model.inspect(); await model.complete()
        XCTAssertEqual(model.plan?.mode, .legacy)
        var calls = await transport.calls
        XCTAssertEqual(calls, ["get_project_sync_transition_plan"])
        await model.prepare()
        XCTAssertEqual(model.plan?.mode, .migrating)
        XCTAssertFalse(model.validated)
        await model.complete()
        calls = await transport.calls
        XCTAssertFalse(calls.contains("complete_project_sync_migration"))
        await model.validate(); XCTAssertTrue(model.validated)
        await model.complete(); XCTAssertEqual(model.plan?.mode, .idBased)
        XCTAssertFalse(model.hasPendingRequest)
    }
    func testResponseLossReusesExactJournalAcrossModelRestart() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.loseNextPreparation()
        let journal = journal()
        let first = model(transport, journal)
        await first.inspect(); await first.prepare()
        XCTAssertNil(first.plan)
        let frozen = try await journal.load(identity)
        XCTAssertNotNil(frozen)
        let second = model(transport, journal)
        await second.inspect(); await second.prepare()
        let requests = await transport.preparations
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0], requests[1])
        XCTAssertEqual(requests[0], frozen?.request)
        XCTAssertEqual(second.plan?.mode, .migrating)
    }
    func testCompletionResponseLossReconcilesWithoutAnotherBegin() async throws {
        let transport = TransitionTransportStub(identity: identity)
        let journal = journal(); let model = model(transport, journal)
        await model.inspect(); await model.prepare(); await model.validate()
        await transport.loseNextCompletion()
        await model.complete(); XCTAssertNil(model.plan)
        await model.inspect(); XCTAssertEqual(model.plan?.mode, .idBased)
        let entry = try await journal.load(identity)
        XCTAssertNil(entry)
        let calls = await transport.calls
        XCTAssertEqual(calls.filter { $0 == "prepare_project_sync_transition" }.count, 1)
    }
    func testAccountEpochChangeInvalidatesPriorValidation() async throws {
        let transport = TransitionTransportStub(identity: identity)
        let epoch = SyncV2ContractEpoch(); let model = model(transport, journal(), epoch: epoch)
        await model.inspect(); await model.prepare(); await model.validate()
        epoch.advance()
        await model.complete()
        XCTAssertNil(model.plan)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("complete_project_sync_migration"))
    }
    func testScreenInvalidationPreventsWrites() async throws {
        let transport = TransitionTransportStub(identity: identity)
        let model = model(transport, journal())
        await model.inspect(); model.invalidate(); await model.prepare()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["get_project_sync_transition_plan"])
    }
    func testUnsupportedProfileDoesNotCreateJournalOrBegin() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.setProfile("unknown")
        let journal = journal(); let model = model(transport, journal)
        await model.inspect(); await model.prepare()
        XCTAssertNil(model.plan)
        let entry = try await journal.load(identity)
        XCTAssertNil(entry)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["get_project_sync_transition_plan"])
    }
    func testOtherDeviceMigrationIsBlocked() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.setOtherDevice()
        let model = model(transport, journal())
        await model.inspect(); await model.prepare()
        XCTAssertNil(model.plan)
        let calls = await transport.calls
        XCTAssertEqual(calls, ["get_project_sync_transition_plan"])
    }
    func testInvalidValidationDoesNotEnableCompletion() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.rejectValidation()
        let model = model(transport, journal())
        await model.inspect(); await model.prepare(); await model.validate(); await model.complete()
        XCTAssertFalse(model.validated)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("complete_project_sync_migration"))
    }
    func testJournalCannotOverwriteUncertainRequestOrCrossAccounts() async throws {
        let journal = journal()
        let entry = SyncV2TransitionJournal.Entry(identity: identity, request: .object(["request": .int(1)]))
        try await journal.save(entry)
        try await journal.save(entry)
        do {
            try await journal.save(.init(identity: identity, request: .object(["request": .int(2)])))
            XCTFail("replaced frozen request")
        } catch { XCTAssertEqual((error as? SyncV2ContractError)?.code, "TRANSITION_JOURNAL_MISMATCH") }
        let other = SyncV2TransitionIdentity(localID: identity.localID, serverID: identity.serverID, accountID: UUID(), deviceID: identity.deviceID)
        let result = try await journal.load(other)
        XCTAssertNil(result)
    }
    func testCorruptJournalFailsClosed() async throws {
        let journal = journal()
        try await journal.save(.init(identity: identity, request: .object(["invalid": .bool(true)])))
        let transport = TransitionTransportStub(identity: identity)
        let model = model(transport, journal)
        await model.inspect(); await model.prepare()
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("prepare_project_sync_transition"))
    }
    func testDefinitiveBaselineRejectionAllowsFreshPlanning() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.rejectNextBaseline()
        let journal = journal(); let model = model(transport, journal)
        await model.inspect(); await model.prepare()
        let entry = try await journal.load(identity)
        XCTAssertNil(entry)
        XCTAssertFalse(model.hasPendingRequest)
        await model.inspect(); await model.prepare()
        XCTAssertEqual(model.plan?.mode, .migrating)
    }
    func testAuthorizationChangesAfterSendRetainJournalAndRejectResult() async throws {
        let epoch = SyncV2ContractEpoch()
        let transport = TransitionTransportStub(identity: identity)
        await transport.invalidateAfterPreparation { epoch.advance() }
        let journal = journal(); let model = model(transport, journal, epoch: epoch)
        await model.inspect(); await model.prepare()
        XCTAssertNil(model.plan)
        let entry = try await journal.load(identity)
        XCTAssertNotNil(entry)
        XCTAssertFalse(model.validated)
    }
    func testPlanRejectsWrongProjectAndInvalidEpoch() throws {
        let payload = SyncV2JSON.object(["profile_sha256": .string(SyncV2TransitionProfile.sha256),
            "baseline_sha256": .string(String(repeating: "a", count: 64)), "documents": .array([]), "orders": .array([])])
        let result = SyncV2JSON.object(["profile_sha256": .string(SyncV2TransitionProfile.sha256),
            "project_id": .string(identity.serverID.uuidString.lowercased()), "mode": .string("LEGACY"), "epoch": .int(1), "payload": payload])
        XCTAssertThrowsError(try SyncV2TransitionPlan(result, projectID: identity.serverID, accountID: identity.accountID, deviceID: identity.deviceID))
        XCTAssertThrowsError(try SyncV2TransitionPlan(result, projectID: UUID(), accountID: identity.accountID, deviceID: identity.deviceID))
    }
}

private actor TransitionTransportStub: SyncV2TransitionTransporting {
    let identity: SyncV2TransitionIdentity
    var calls: [String] = []
    var preparations: [SyncV2JSON] = []
    var mode = "LEGACY"
    var profile = SyncV2TransitionProfile.sha256
    var losePreparation = false; var loseCompletion = false; var invalidValidation = false; var otherDevice = false
    var rejectBaseline = false
    var preparationCallback: (@Sendable () -> Void)?
    init(identity: SyncV2TransitionIdentity) { self.identity = identity }
    func loseNextPreparation() { losePreparation = true }
    func loseNextCompletion() { loseCompletion = true }
    func rejectValidation() { invalidValidation = true }
    func setProfile(_ value: String) { profile = value }
    func setOtherDevice() { mode = "MIGRATING"; otherDevice = true }
    func rejectNextBaseline() { rejectBaseline = true }
    func invalidateAfterPreparation(_ callback: @escaping @Sendable () -> Void) { preparationCallback = callback }
    func call(_ rpc: String, parameters: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        try authorize(); calls.append(rpc)
        switch rpc {
        case "get_project_sync_transition_plan":
            return .object(["profile_sha256": .string(profile), "project_id": .string(identity.serverID.uuidString.lowercased()),
                "mode": .string(mode), "epoch": .int(mode == "LEGACY" ? 0 : 1),
                "started_by_user_id": .string(identity.accountID.uuidString.lowercased()),
                "started_by_device_id": .string((otherDevice ? UUID() : identity.deviceID).uuidString.lowercased()),
                "payload": .object(["profile_sha256": .string(profile), "baseline_sha256": .string(String(repeating: "a", count: 64)),
                    "documents": .array([]), "orders": .array([])])])
        case "prepare_project_sync_transition":
            if rejectBaseline { rejectBaseline = false; throw SyncV2ContractError("TRANSITION_BASELINE_CHANGED") }
            let request = try SyncV2ContractRequest(storedJSON: parameters.objectValue!["p_request"]!)
            preparations.append(request.json); mode = "MIGRATING"
            preparationCallback?()
            if losePreparation { losePreparation = false; throw URLError(.timedOut) }
            let intent = request.orderedIntents[0].objectValue!
            return .object(["kind": .string("atomic_structure_commit_success"), "batch_id": .string(request.batchID.uuidString.lowercased()),
                "batch_payload_sha256": .string(request.batchPayloadSHA256), "status": .string(preparations.count > 1 ? "replayed" : "committed"),
                "applied": .bool(true), "results": .array([.object(["sequence": .int(1), "operation_id": intent["operation_id"]!,
                    "entity_id": intent["entity_id"]!, "result_revision": .int(1)])])])
        case "validate_project_sync_migration":
            return .object(["project_id": .string(identity.serverID.uuidString.lowercased()), "valid": .bool(!invalidValidation), "issues": .array([])])
        case "complete_project_sync_migration":
            mode = "ID_BASED"
            if loseCompletion { loseCompletion = false; throw URLError(.timedOut) }
            return .object(["status": .string("id_based"), "project_id": .string(identity.serverID.uuidString.lowercased()), "migration_epoch": .int(1)])
        default: throw SyncV2ContractError.invalidArgument
        }
    }
}
