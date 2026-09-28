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
                       epoch: SyncV2ContractEpoch = .init(), contract: SyncV2ReleasedContract = .v02) -> SyncV2ProjectTransitionModel {
        let identity = identity
        return .init(transport: transport, journal: journal, contract: contract) { _ in
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
    func testPreparationReplayDoesNotMislabelConcurrentlyCompletedProject() async throws {
        let transport = TransitionTransportStub(identity: identity)
        await transport.completeAfterPreparation()
        let model = model(transport, journal())
        await model.inspect(); await model.prepare()
        XCTAssertEqual(model.plan?.mode, .idBased)
        XCTAssertTrue(model.message.contains("ID_BASED"))
        XCTAssertFalse(model.hasPendingRequest)
    }

    func testContract03TransitionUsesWindowsMetadataAndVerifiesCompletedHandshake() async throws {
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        let model = model(transport, journal(), contract: .v03)
        await model.inspect()
        XCTAssertEqual(model.plan?.handshake?.contractVersion, "0.3.0")
        await model.prepare(); await model.validate(); await model.complete()
        XCTAssertEqual(model.plan?.mode, .idBased)
        XCTAssertEqual(model.plan?.handshake?.contractSHA256, SyncV2ReleasedContract.v03.sha256)
        XCTAssertEqual(Set(model.plan?.handshake?.serverCapabilities ?? []), [
            "atomic_structure_commit", "contract_allowlist_validation", "project_mode_migration_lock",
            "folder_tombstones", "id_tree_validation", "legacy_epoch_zero_adapter", "storage_name_v2", "document_commit_v1"])
        let requests = await transport.preparations
        let batch = try XCTUnwrap(requests.first?.objectValue?["batch"]?.objectValue)
        XCTAssertEqual(batch["contract_version"], .string("0.3.0"))
        XCTAssertEqual(batch["canonical_contract_sha256"], .string(SyncV2ReleasedContract.v03.sha256))
        XCTAssertEqual(batch["sync_protocol_version"], .int(3))
        XCTAssertEqual(batch["client_capabilities"], .array([
            "folders_authoritative", "tree_order_ids", "tombstones", "immutable_batch_contract_metadata",
            "operation_attempt_history", "operation_state_events", "storage_name_v2", "document_commit_v1"].map { .string($0) }))
        let calls = await transport.calls
        XCTAssertFalse(calls.contains("get_project_sync_transition_plan"))
        XCTAssertTrue(model.message.contains("계약 0.3을 선택"))
        XCTAssertTrue(model.message.contains("이 화면에서는 활성화하지 않습니다"))
    }
    func testContract03HandshakeDriftBlocksBeforeJournalOrPreparation() async throws {
        let cases: [[String: SyncV2JSON]] = [
            ["supported": .bool(false)],
            ["contract_version": .string("0.2.0")],
            ["canonical_contract_sha256": .string(SyncV2Contract.canonicalSHA256)],
            ["server_contract_sha256": .string(SyncV2Contract.canonicalSHA256)],
            ["server_capabilities": .array(SyncV2Contract.requiredServerCapabilities.sorted().map { .string($0) })],
            ["supported_protocol_versions": .array([.int(4)]), "server_protocol_version": .int(4)],
            ["project_id": .string(UUID().uuidString.lowercased())],
            ["project_sync_mode": .string("ID_BASED"), "migration_epoch": .int(1)],
        ]
        for fields in cases {
            let transport = TransitionTransportStub(identity: identity, contract: .v03)
            await transport.overrideHandshake(fields)
            let journal = journal(); let model = model(transport, journal, contract: .v03)
            await model.inspect(); await model.prepare()
            XCTAssertNil(model.plan, "\(fields)")
            let entry = try await journal.load(identity)
            XCTAssertNil(entry)
            let writes = await transport.preparations
            XCTAssertTrue(writes.isEmpty)
        }
    }
    func testContract03ResponseLossReplaysUnchangedAndCompletionLossReconciles() async throws {
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        await transport.loseNextPreparation()
        let journal = journal(); let first = model(transport, journal, contract: .v03)
        await first.inspect(); await first.prepare()
        let frozen = try await journal.load(identity)
        let resumed = model(transport, journal, contract: .v03)
        await resumed.inspect(); await resumed.prepare()
        let requests = await transport.preparations
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests.first, requests.last)
        XCTAssertEqual(frozen?.request, requests.first)
        await resumed.validate(); await transport.loseNextCompletion(); await resumed.complete()
        XCTAssertNil(resumed.plan)
        await resumed.inspect()
        XCTAssertEqual(resumed.plan?.mode, .idBased)
        let after = try await journal.load(identity)
        XCTAssertNil(after)
    }
    func testContract03NeverRepinsRetained02Journal() async throws {
        let journal = journal()
        let old = TransitionTransportStub(identity: identity)
        await old.loseNextPreparation()
        let oldModel = model(old, journal)
        await oldModel.inspect(); await oldModel.prepare()
        let frozen = try await journal.load(identity)
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        let newModel = model(transport, journal, contract: .v03)
        await newModel.inspect(); await newModel.prepare()
        XCTAssertNil(newModel.plan)
        let after = try await journal.load(identity)
        XCTAssertEqual(after, frozen)
        let writes = await transport.preparations
        XCTAssertTrue(writes.isEmpty)
    }
    func testContract03RejectsModifiedJournalPayloadHash() async throws {
        let journal = journal()
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        await transport.loseNextPreparation()
        let first = model(transport, journal, contract: .v03)
        await first.inspect(); await first.prepare()
        let frozen = try await journal.load(identity)
        var fields = try XCTUnwrap(frozen?.request.objectValue)
        var intents = try XCTUnwrap(fields["ordered_intents"]?.arrayValue)
        var intent = try XCTUnwrap(intents[0].objectValue)
        intent["payload_sha256"] = .string(String(repeating: "0", count: 64))
        intents[0] = .object(intent); fields["ordered_intents"] = .array(intents)
        let corrupt = self.journal()
        try await corrupt.save(.init(identity: identity, request: .object(fields)))
        let second = model(transport, corrupt, contract: .v03)
        await second.inspect(); await second.prepare()
        XCTAssertNil(second.plan)
        let writes = await transport.preparations
        XCTAssertEqual(writes.count, 1)
    }
    func testCompleted03InspectionDoesNotDeleteRetained02Journal() async throws {
        let journal = journal()
        let old = TransitionTransportStub(identity: identity)
        await old.loseNextPreparation()
        let oldModel = model(old, journal)
        await oldModel.inspect(); await oldModel.prepare()
        let frozen = try await journal.load(identity)
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        await transport.setCompleted()
        let newModel = model(transport, journal, contract: .v03)
        await newModel.inspect()
        XCTAssertNil(newModel.plan)
        let after = try await journal.load(identity)
        XCTAssertEqual(after, frozen)
    }
    func testContract03PostCompletionHandshakeMismatchRetainsJournal() async throws {
        let transport = TransitionTransportStub(identity: identity, contract: .v03)
        let journal = journal(); let model = model(transport, journal, contract: .v03)
        await model.inspect(); await model.prepare(); await model.validate()
        await transport.overrideHandshake(["server_contract_sha256": .string(SyncV2Contract.canonicalSHA256)])
        await model.complete()
        XCTAssertNil(model.plan)
        let entry = try await journal.load(identity)
        XCTAssertNotNil(entry)
    }
    func testContract03WriterIsExplicitAndDoesNotReplaceReleased02Pin() throws {
        XCTAssertEqual(SyncV2Contract.version, "0.2.0")
        XCTAssertEqual(SyncV2Contract.canonicalSHA256, "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670")
        XCTAssertNoThrow(try SyncV2Contract.buildAtomicStructureRequest(projectID: identity.serverID,
            projectSyncMode: .idBased, migrationEpoch: 1, writerDeviceID: identity.deviceID,
            orderedIntents: [.init(entityKind: .folder, entityID: UUID(), intentKind: .create,
                payload: .object(["name": .string("folder")]))], contract: .v03))
        XCTAssertThrowsError(try SyncV2Contract.requireServerCompatibility(projectSyncMode: .idBased,
            migrationEpoch: 1, serverProtocolVersion: 3, serverContractSHA256: SyncV2ReleasedContract.v03.sha256,
            serverCapabilities: SyncV2ReleasedContract.v03.serverCapabilities))
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
    var finishAfterPreparation = false
    let contract: SyncV2ReleasedContract
    var handshakeOverrides: [String: SyncV2JSON] = [:]
    init(identity: SyncV2TransitionIdentity, contract: SyncV2ReleasedContract = .v02) {
        self.identity = identity; self.contract = contract; self.profile = SyncV2TransitionProfile.sha256(for: contract)
    }
    func overrideHandshake(_ fields: [String: SyncV2JSON]) { handshakeOverrides = fields }
    func setCompleted() { mode = "ID_BASED" }
    func loseNextPreparation() { losePreparation = true }
    func loseNextCompletion() { loseCompletion = true }
    func rejectValidation() { invalidValidation = true }
    func setProfile(_ value: String) { profile = value }
    func setOtherDevice() { mode = "MIGRATING"; otherDevice = true }
    func rejectNextBaseline() { rejectBaseline = true }
    func invalidateAfterPreparation(_ callback: @escaping @Sendable () -> Void) { preparationCallback = callback }
    func completeAfterPreparation() { finishAfterPreparation = true }
    func call(_ rpc: String, parameters: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        try authorize(); calls.append(rpc)
        switch rpc {
        case "get_project_sync_transition_plan", "get_project_sync_transition_plan_for_contract":
            if contract == .v03 && parameters.objectValue?["p_target_contract_sha256"] != .string(contract.sha256) {
                throw SyncV2ContractError("CONTRACT_NOT_ALLOWED")
            }
            var payload: [String: SyncV2JSON] = ["profile_sha256": .string(profile),
                "baseline_sha256": .string(String(repeating: "a", count: 64)), "documents": .array([]), "orders": .array([])]
            if contract == .v03 { payload["target_contract_sha256"] = .string(contract.sha256) }
            var result: [String: SyncV2JSON] = ["profile_sha256": .string(profile), "project_id": .string(identity.serverID.uuidString.lowercased()),
                "mode": .string(mode), "epoch": .int(mode == "LEGACY" ? 0 : 1),
                "started_by_user_id": .string(identity.accountID.uuidString.lowercased()),
                "started_by_device_id": .string((otherDevice ? UUID() : identity.deviceID).uuidString.lowercased()),
                "payload": .object(payload)]
            if contract == .v03 {
                result["target_contract_sha256"] = .string(contract.sha256)
                var handshake: [String: SyncV2JSON] = ["supported": .bool(true),
                    "project_id": .string(identity.serverID.uuidString.lowercased()), "project_sync_mode": .string(mode),
                    "migration_epoch": .int(mode == "LEGACY" ? 0 : 1), "contract_version": .string(contract.version),
                    "canonical_contract_sha256": .string(contract.sha256), "server_contract_sha256": .string(contract.sha256),
                    "server_protocol_version": .int(3), "supported_protocol_versions": .array([.int(3)]),
                    "server_capabilities": .array(contract.serverCapabilities.sorted().map { .string($0) })]
                handshake.merge(handshakeOverrides) { _, new in new }
                result["handshake"] = .object(handshake)
            }
            return .object(result)
        case "prepare_project_sync_transition":
            if rejectBaseline { rejectBaseline = false; throw SyncV2ContractError("TRANSITION_BASELINE_CHANGED") }
            let request = try SyncV2ContractRequest(storedJSON: parameters.objectValue!["p_request"]!)
            preparations.append(request.json); mode = "MIGRATING"
            if finishAfterPreparation { mode = "ID_BASED" }
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
