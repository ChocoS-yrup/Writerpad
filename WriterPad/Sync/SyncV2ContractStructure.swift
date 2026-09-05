import Foundation
import Supabase

/// UserDefaults의 읽기/쓰기는 스레드 안전하다. 송신 예약에만 전달하는 불변 참조다.
private struct ContractDefaults: @unchecked Sendable {
    let value: UserDefaults
}

enum SyncV2ContractStructureError: Error, Equatable, Sendable {
    case unavailable
    case gateClosed
    case handshakeMissing
    case authenticationRequired
    case projectNotConnected
    case unsupportedLocalBatch
    case missingTreeOrder
    case invalidStoredRequest
    case noReadyBatch
    case transportRejected
    case uploadPullGateBusy
    case transmissionNotStarted
}

struct SyncV2AtomicStructureParameters: Encodable, Equatable, Sendable {
    let request: SyncV2JSON

    enum CodingKeys: String, CodingKey {
        case request = "p_request"
    }
}

protocol SyncV2AtomicStructureTransporting: Sendable {
    func commit(request: SyncV2JSON) async throws -> SyncV2JSON
    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON
}

extension SyncV2AtomicStructureTransporting {
    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        try authorize()
        return try await commit(request: request)
    }
}

actor LiveSyncV2AtomicStructureTransport:
    SyncV2AtomicStructureTransporting {
    private let http: SyncV2ContractHTTPClient

    init(client: SupabaseClient, configuration: SupabasePublicConfiguration) {
        http = SyncV2ContractHTTPClient(configuration: configuration, accessToken: { client.auth.currentSession?.accessToken })
    }

    func commit(request: SyncV2JSON) async throws -> SyncV2JSON {
        // 실제 전송에는 항상 송신 시작 예약이 필요하다.
        throw SyncV2ContractStructureError.transmissionNotStarted
    }

    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        do {
            let data = try await http.call(rpc: "atomic_structure_commit",
                body: JSONEncoder().encode(SyncV2AtomicStructureParameters(request: request)), authorize: authorize)
            return try JSONDecoder().decode(SyncV2JSON.self, from: data)
        } catch {
            if let local = error as? SyncV2ContractStructureError { throw local }
            if error is CancellationError { throw error }
            switch LiveSyncV2HandshakeTransport.classify(error) {
            case .authenticationRequired: throw SyncV2HandshakeError.authenticationRequired
            case .forbidden: throw SyncV2HandshakeError.forbidden
            case .contractRejected: throw SyncV2HandshakeError.contractUnavailable
            default: throw SyncV2ContractStructureError.transportRejected
            }
        }
    }
}

struct SyncV2PendingContractBatch: Equatable, Sendable {
    let localProjectID: ProjectID
    let serverProjectID: UUID
    let request: SyncV2ContractRequest
}

struct SyncV2ContractSendReport: Equatable, Sendable {
    let batchID: UUID
    let status: SyncV2CommitStatus
    let operationCount: Int
}

extension SyncV2ContractRequest {
    func validateForTransmission(context: SyncV2HandshakeContext,
                                 handshake: SyncV2ValidatedHandshake,
                                 writerDeviceID: UUID) throws {
        let fields = json.objectValue
        let batch = fields?["batch"]?.objectValue
        guard fields?["kind"]?.stringValue == "atomic_structure_commit_request",
              fields?["project_id"]?.stringValue == context.serverProjectID.uuidString.lowercased(),
              fields?["project_sync_mode"]?.stringValue == handshake.projectSyncMode.rawValue,
              fields?["migration_epoch"]?.intValue == handshake.migrationEpoch,
              batch?["writer_device_id"]?.stringValue == writerDeviceID.uuidString.lowercased(),
              batch?["contract_version"]?.stringValue == SyncV2Contract.version,
              batch?["canonical_contract_sha256"]?.stringValue == context.clientContractSHA256,
              batch?["sync_protocol_version"]?.intValue == SyncV2Contract.syncProtocolVersion,
              let capabilities = batch?["client_capabilities"]?.arrayValue,
              Set(capabilities.compactMap(\.stringValue)) == Set(SyncV2Contract.clientCapabilities),
              try SyncV2JSON.array(orderedIntents).sha256Hex() == batchPayloadSHA256
        else { throw SyncV2ContractStructureError.invalidStoredRequest }
        for intent in orderedIntents {
            guard let value = intent.objectValue, let payload = value["payload"],
                  value["batch_id"]?.stringValue == batchID.uuidString.lowercased(),
                  try payload.sha256Hex() == value["payload_sha256"]?.stringValue
            else { throw SyncV2ContractStructureError.invalidStoredRequest }
        }
    }

    init(storedJSON json: SyncV2JSON) throws {
        guard
            let fields = json.objectValue,
            let batch = fields["batch"]?.objectValue,
            let batchIDValue = batch["batch_id"]?.stringValue,
            let batchID = UUID(uuidString: batchIDValue),
            let digest = batch["batch_payload_sha256"]?.stringValue,
            let intents = fields["ordered_intents"]?.arrayValue,
            !intents.isEmpty
        else {
            throw SyncV2ContractStructureError.invalidStoredRequest
        }
        self.init(
            json: json,
            batchID: batchID,
            batchPayloadSHA256: digest,
            orderedIntents: intents
        )
    }
}

/// 로컬 바인더가 완료한 배치를 관문과 서 있는 핸드셰크가 모두
/// 있을 때만 contract 대기열로 보낸다. 관문이 열려 있는데 답이 없으면
/// 레거시로 후퇴하지 않고 로컬 완료+미대기로 남긴다.
actor SyncV2ContractPathRecorder: DurableLocalChangeRecording {
    private let store: LazySyncV2ProjectBindingStore
    private let handshakeService: SyncV2HandshakeService?
    private let authenticationService: any AuthenticationServicing
    private let bindingEpoch: SyncV2ContractEpoch?
    private let defaults: UserDefaults

    init(
        store: LazySyncV2ProjectBindingStore,
        handshakeService: SyncV2HandshakeService?,
        authenticationService: any AuthenticationServicing,
        defaults: UserDefaults = .standard,
        bindingEpoch: SyncV2ContractEpoch? = nil
    ) {
        self.store = store
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.defaults = defaults
        self.bindingEpoch = bindingEpoch
    }

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        await store.requirement(for: projectID)
    }

    func hasRecordedInitialSnapshot(
        for projectID: ProjectID,
        kind: DurableLocalBatchKind
    ) async throws -> Bool {
        try await store.hasRecordedInitialSnapshot(
            for: projectID,
            kind: kind
        )
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        let touchesStructure = batch.mutations.contains { mutation in
            switch mutation {
            case .folderSnapshot, .treeOrder: return true
            case .ensureProject, .documentSnapshot, .trashPurge: return false
            }
        }
        guard touchesStructure,
              ContractPathGate.isOpen(for: batch.projectID, in: defaults)
        else {
            return await store.record(batch)
        }
        guard let handshakeService else {
            return .localSavedButNotQueued(
                reason: "계약 핸드셰크 서비스를 사용할 수 없습니다."
            )
        }
        let authEpoch = authenticationService.contractEpoch
        let authRevision = authEpoch?.value ?? 0
        let bindingRevision = bindingEpoch?.value ?? 0
        let gateRevision = ContractPathGate.revision(for: batch.projectID, in: defaults)
        let handshakeEpoch = handshakeService.authorizationEpoch
        let handshakeRevision = handshakeEpoch.value
        guard let binding = try? await store.binding(for: batch.projectID),
              let serverProjectID = binding.serverProjectID,
              binding.kind != .localOnly
        else {
            return .localSavedButNotQueued(
                reason: "서버 작품 연결을 확인할 수 없습니다."
            )
        }
        let state = await authenticationService.currentState()
        let context = SyncV2HandshakeContext.make(
            authenticationState: state,
            localProjectID: batch.projectID,
            serverProjectID: serverProjectID,
            authenticationEpoch: authRevision,
            bindingEpoch: bindingRevision
        )
        guard await handshakeService.usesContractStructure(
            context: context,
            gateIsOpen: true
        ), let handshake = await handshakeService.standingHandshake(for: context)
        else {
            return .localSavedButNotQueued(
                reason: "이 작품에 서 있는 계약 핸드셰크가 없어 구조 쓰기를 보내지 않습니다."
            )
        }
        let defaults = ContractDefaults(value: self.defaults)
        let bindingEpoch = self.bindingEpoch
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try ContractPathGate.reserveStart(for: batch.projectID, in: defaults.value, revision: gateRevision) {
                (authEpoch?.value ?? 0) == authRevision &&
                (bindingEpoch?.value ?? 0) == bindingRevision &&
                (bindingEpoch?.isAvailable ?? false) &&
                handshakeEpoch.value == handshakeRevision
            }
        }
        do {
            let operationIDs = try await store.enqueueContractStructure(
                batch,
                binding: binding,
                handshake: handshake,
                authorize: authorize
            )
            return .queued(operationIDs: operationIDs)
        } catch {
            return .localSavedButNotQueued(
                reason: "계약 구조 배치를 기록하지 못했습니다: \(error)"
            )
        }
    }

    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) async -> DurableRecordResult? {
        await store.preservedResult(
            for: projectID,
            documentID: documentID
        )
    }
}

protocol SyncV2ContractQueue: Sendable {
    func binding(for projectID: ProjectID) async throws -> ProjectSyncBinding?
    func uploadQueueSnapshot(localProjectID: ProjectID) async throws -> SyncV2UploadQueueSnapshot
    func claimNextContractStructure(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch
    func completeContractStructure(_ pending: SyncV2PendingContractBatch, response: SyncV2JSON) async throws
    func failContractStructure(_ pending: SyncV2PendingContractBatch, error: Error, response: SyncV2JSON?) async
}

extension LazySyncV2ProjectBindingStore: SyncV2ContractQueue {}

/// 자동 동기 토글과 분리된 진단용 1회 전송기다. 전송 직전에 관문과
/// 핸드셰크를 다시 확인하고, 로컬에 먼저 저장된 불변 요청만 보낸다.
actor SyncV2ContractStructureSender {
    private let store: any SyncV2ContractQueue
    private let transport: any SyncV2AtomicStructureTransporting
    private let handshakeService: SyncV2HandshakeService
    private let authenticationService: any AuthenticationServicing
    private let uploadPullCoordinator:
        SyncV2ProjectUploadPullCoordinator?
    private let defaults: UserDefaults
    private let bindingEpoch: SyncV2ContractEpoch?
    private let deviceIdentityProvider: (any DeviceIdentityProviding)?
    private var sendingProjects: Set<ProjectID> = []

    init(
        store: any SyncV2ContractQueue,
        transport: any SyncV2AtomicStructureTransporting,
        handshakeService: SyncV2HandshakeService,
        authenticationService: any AuthenticationServicing,
        uploadPullCoordinator:
            SyncV2ProjectUploadPullCoordinator? = nil,
        defaults: UserDefaults = .standard,
        bindingEpoch: SyncV2ContractEpoch? = nil,
        deviceIdentityProvider: (any DeviceIdentityProviding)? = nil
    ) {
        self.store = store
        self.transport = transport
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.uploadPullCoordinator = uploadPullCoordinator
        self.defaults = defaults
        self.bindingEpoch = bindingEpoch
        self.deviceIdentityProvider = deviceIdentityProvider
    }

    func sendNext(
        localProjectID: ProjectID
    ) async throws -> SyncV2ContractSendReport {
        guard sendingProjects.insert(localProjectID).inserted else {
            throw SyncV2ContractStructureError.uploadPullGateBusy
        }
        defer { sendingProjects.remove(localProjectID) }
        let gateRevision = ContractPathGate.revision(for: localProjectID, in: defaults)
        let globalRevision = GlobalSyncPreference.contractEpoch.value
        let authEpoch = authenticationService.contractEpoch
        let authRevision = authEpoch?.value ?? 0
        let bindingRevision = bindingEpoch?.value ?? 0
        let handshakeEpoch = handshakeService.authorizationEpoch
        let handshakeRevision = handshakeEpoch.value
        let activityEpoch = handshakeService.activityEpoch
        let activityRevision = activityEpoch.value
        guard ContractPathGate.isOpen(for: localProjectID, in: defaults)
        else { throw SyncV2ContractStructureError.gateClosed }
        guard let binding = try await store.binding(for: localProjectID),
              let serverProjectID = binding.serverProjectID,
              binding.kind != .localOnly
        else { throw SyncV2ContractStructureError.projectNotConnected }
        guard let context = SyncV2HandshakeContext.make(
            authenticationState: await authenticationService.currentState(),
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            authenticationEpoch: authRevision, bindingEpoch: bindingRevision
        ) else { throw SyncV2ContractStructureError.authenticationRequired }
        guard binding.ownerSubject == context.accountID,
              await handshakeService.usesContractStructure(
            context: context,
            gateIsOpen: true
        ), let handshake = await handshakeService.standingHandshake(for: context),
           await handshakeService.canStartContractWrite(),
           let deviceIdentityProvider
        else { throw SyncV2ContractStructureError.handshakeMissing }
        let writerDeviceID = try await deviceIdentityProvider.currentIdentifier().uuid
        let defaults = ContractDefaults(value: self.defaults)
        let bindingEpoch = self.bindingEpoch
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try ContractPathGate.reserveStart(for: localProjectID, in: defaults.value, revision: gateRevision) {
                (authEpoch?.value ?? 0) == authRevision &&
                (bindingEpoch?.value ?? 0) == bindingRevision &&
                (bindingEpoch?.isAvailable ?? false) &&
                handshakeEpoch.value == handshakeRevision && activityEpoch.value == activityRevision &&
                GlobalSyncPreference.contractEpoch.value == globalRevision &&
                GlobalSyncPreference.isEnabled(in: defaults.value)
            }
        }
        try authorize()

        let uploadPermit:
            SyncV2ProjectUploadPullCoordinator.UploadPermit?
        if let uploadPullCoordinator {
            let queue = try await store.uploadQueueSnapshot(
                localProjectID: localProjectID
            )
            guard let permit = await uploadPullCoordinator.beginUploadDrain(
                localProjectID: localProjectID,
                queue: queue
            ) else {
                throw SyncV2ContractStructureError.uploadPullGateBusy
            }
            uploadPermit = permit
        } else {
            uploadPermit = nil
        }
        var claimed: SyncV2PendingContractBatch?
        let started = SyncV2ContractEpoch()
        do {
            let pending = try await store.claimNextContractStructure(
                localProjectID: localProjectID
            )
            claimed = pending
            guard pending.serverProjectID == serverProjectID,
                  pending.localProjectID == localProjectID else {
                throw SyncV2ContractStructureError.invalidStoredRequest
            }
            try pending.request.validateForTransmission(context: context, handshake: handshake,
                                                        writerDeviceID: writerDeviceID)
            let response = try await transport.commit(
                request: pending.request.json,
                authorize: { try authorize(); started.advance() }
            )
            let status: SyncV2CommitStatus
            do {
                status = try SyncV2Contract.validateAtomicStructureResponse(
                    request: pending.request,
                    response: response
                )
            } catch {
                await store.failContractStructure(
                    pending,
                    error: error,
                    response: response
                )
                throw error
            }
            try await store.completeContractStructure(
                pending,
                response: response
            )
            let report = SyncV2ContractSendReport(
                batchID: pending.request.batchID,
                status: status,
                operationCount: pending.request.orderedIntents.count
            )
            await finishUploadPermit(
                uploadPermit,
                localProjectID: localProjectID
            )
            return report
        } catch {
            // 서버 응답 검증 실패는 위에서 응답과 함께 이미 남겼다.
            // 전송 단계 실패만 재시도 가능 상태로 돌린다.
            if let stale = error as? SyncV2HandshakeError {
                await handshakeService.forgetIfStale(stale, expectedGeneration: handshakeRevision)
            }
            if let contractError = error as? SyncV2ContractError {
                await handshakeService.forgetIfStale(.incompatible(contractError), expectedGeneration: handshakeRevision)
            }
            if let claimed, started.value == 0 {
                await store.failContractStructure(claimed, error: SyncV2ContractStructureError.transmissionNotStarted, response: nil)
            } else if let claimed,
                      error as? SyncV2ContractStructureError == .transportRejected || error is SyncV2HandshakeError || error is CancellationError {
                await store.failContractStructure(
                    claimed,
                    error: error is CancellationError ? SyncV2ContractStructureError.transportRejected : error, response: nil
                )
            }
            await finishUploadPermit(
                uploadPermit,
                localProjectID: localProjectID
            )
            throw error
        }
    }

    private func finishUploadPermit(
        _ permit: SyncV2ProjectUploadPullCoordinator.UploadPermit?,
        localProjectID: ProjectID
    ) async {
        guard let permit, let uploadPullCoordinator else { return }
        let queue = (try? await store.uploadQueueSnapshot(
            localProjectID: localProjectID
        )) ?? SyncV2UploadQueueSnapshot(retryWaitingCount: 1)
        await uploadPullCoordinator.finishUploadDrain(
            permit,
            queue: queue
        )
    }
}
