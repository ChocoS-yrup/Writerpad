import Foundation
import Supabase

/// UserDefaults의 읽기/쓰기는 스레드 안전하다. 송신 예약에만 전달하는 불변 참조다.
struct ContractDefaults: @unchecked Sendable {
    let value: UserDefaults

    static let standard = ContractDefaults(value: .standard)
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
    case invalidRecoveryReceipt
    case noReadyBatch
    case transportRejected
    case uploadPullGateBusy
    case transmissionNotStarted
    case structureAuthorityUnavailable
    case projectInactive
    case preparationRequiresClosedGate
    case unsupportedPreparationBaseline
    case preparationChanged
}

struct SyncV2AtomicStructureParameters: Encodable, Equatable, Sendable {
    let request: SyncV2JSON

    enum CodingKeys: String, CodingKey {
        case request = "p_request"
    }
}

protocol SyncV2AtomicStructureTransporting: Sendable {
    func fetchGeneralConflictDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2JSON
    func fetchGeneralReceipt(projectID: UUID, batchID: UUID) async throws -> SyncV2GeneralCommitReceipt?
    func fetchGeneralBaseline(projectID: UUID) async throws -> SyncV2PreparationSnapshot
    func fetchPreparationSnapshot(projectID: UUID) async throws -> SyncV2PreparationSnapshot
    func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState
    func commit(request: SyncV2JSON) async throws -> SyncV2JSON
    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON
}

extension SyncV2AtomicStructureTransporting {
    func fetchGeneralConflictDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2JSON {
        throw SyncV2GeneralConflictError.unavailable
    }

    func fetchGeneralReceipt(projectID: UUID, batchID: UUID) async throws -> SyncV2GeneralCommitReceipt? {
        throw SyncV2ContractStructureError.unavailable
    }
    func fetchGeneralBaseline(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        throw SyncV2ContractStructureError.unavailable
    }
    func fetchPreparationSnapshot(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        throw SyncV2ContractStructureError.unavailable
    }
    func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState {
        throw SyncV2ContractStructureError.unavailable
    }
    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        try ReceiveValidationPolicy.current.requireSending()
        try authorize()
        return try await commit(request: request)
    }
}

actor LiveSyncV2AtomicStructureTransport:
    SyncV2AtomicStructureTransporting {
    private let http: SyncV2ContractHTTPClient
    private let metadata: LiveSyncV2PreparationMetadata

    init(client: SupabaseClient, configuration: SupabasePublicConfiguration) {
        metadata = LiveSyncV2PreparationMetadata(client: client, serverURL: configuration.url)
        http = SyncV2ContractHTTPClient(configuration: configuration, accessToken: { client.auth.currentSession?.accessToken })
    }

    func fetchGeneralConflictDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2JSON {
        try await metadata.fetchGeneralConflictDocument(projectID: projectID, documentID: documentID)
    }

    func fetchPreparationSnapshot(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        try await metadata.fetch(projectID: projectID)
    }

    func fetchGeneralBaseline(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        try await metadata.fetchGeneralBaseline(projectID: projectID)
    }

    func fetchGeneralReceipt(projectID: UUID, batchID: UUID) async throws -> SyncV2GeneralCommitReceipt? {
        do { return try await metadata.fetchGeneralReceipt(projectID: projectID, batchID: batchID) }
        catch {
            if error is SyncV2ContractStructureError || error is CancellationError { throw error }
            switch LiveSyncV2HandshakeTransport.classify(error) {
            case .authenticationRequired: throw SyncV2HandshakeError.authenticationRequired
            case .forbidden: throw SyncV2HandshakeError.forbidden
            case .networkUnavailable: throw SyncV2HandshakeError.networkUnavailable
            case .timedOut: throw SyncV2HandshakeError.timedOut
            default: throw SyncV2ContractStructureError.transportRejected
            }
        }
    }

    func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState {
        let body = try JSONEncoder().encode(["p_project_id": projectID.uuidString.lowercased()])
        let data: Data
        do {
            data = try await http.call(rpc: "get_project_status", body: body)
        } catch {
            switch LiveSyncV2HandshakeTransport.classify(error) {
            case .authenticationRequired: throw SyncV2HandshakeError.authenticationRequired
            case .forbidden: throw SyncV2HandshakeError.forbidden
            case .networkUnavailable: throw SyncV2HandshakeError.networkUnavailable
            case .timedOut: throw SyncV2HandshakeError.timedOut
            default: throw SyncV2ContractStructureError.unavailable
            }
        }
        return try SyncV2ContractProjectStatus.decode(data, expectedProjectID: projectID)
    }

    func commit(request: SyncV2JSON) async throws -> SyncV2JSON {
        // 실제 전송에는 항상 송신 시작 예약이 필요하다.
        throw SyncV2ContractStructureError.transmissionNotStarted
    }

    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        try ReceiveValidationPolicy.current.requireSending()
        do {
            let rpc: String
            switch request.objectValue?["kind"]?.stringValue {
            case "atomic_structure_commit_request": rpc = "atomic_structure_commit"
            case "document_commit_request": rpc = "document_commit"
            default: throw SyncV2ContractStructureError.invalidStoredRequest
            }
            let data = try await http.call(rpc: rpc,
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
    var mayPresentCompletion: Bool = true
    var recoveredFromReceipt: Bool = false
}

extension SyncV2ContractRequest {
    func validateForTransmission(context: SyncV2HandshakeContext,
                                 handshake: SyncV2ValidatedHandshake,
                                 writerDeviceID: UUID) throws {
        let fields = json.objectValue
        let batch = fields?["batch"]?.objectValue
        guard ["atomic_structure_commit_request", "document_commit_request"].contains(fields?["kind"]?.stringValue ?? ""),
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
    private let structureAuthority: SyncV2ContractStructureAuthority?
    private let localProjectEpoch: SyncV2ContractEpoch?
    private let isLocalProjectActive: @Sendable (ProjectID) async throws -> Bool
    private let bindingEpoch: SyncV2ContractEpoch?
    private let defaults: ContractDefaults

    init(
        store: LazySyncV2ProjectBindingStore,
        handshakeService: SyncV2HandshakeService?,
        authenticationService: any AuthenticationServicing,
        defaults: ContractDefaults = .standard,
        bindingEpoch: SyncV2ContractEpoch? = nil,
        structureAuthority: SyncV2ContractStructureAuthority? = nil,
        localProjectEpoch: SyncV2ContractEpoch? = nil,
        isLocalProjectActive: @escaping @Sendable (ProjectID) async throws -> Bool = { _ in false }
    ) {
        self.store = store
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.defaults = defaults
        self.structureAuthority = structureAuthority
        self.localProjectEpoch = localProjectEpoch
        self.isLocalProjectActive = isLocalProjectActive
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
        do { try GeneralSyncValidationScope.current.require(local: batch.projectID) }
        catch { return .localSavedButNotQueued(reason: "이 작품은 현재 동기화 검증 범위에 포함되지 않습니다.") }
        guard ContractPathGate.isOpen(for: batch.projectID, in: defaults.value) else {
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
        let gateRevision = ContractPathGate.revision(for: batch.projectID, in: defaults.value)
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
        // LEGACY의 일반 본문 저장은 이관하지 않는다. UUID 계약임이 확인된
        // 작품만 일반 계약 큐를 사용하고 기존 검토용 구조 경로는 유지한다.
        let touchesStructure = batch.mutations.contains {
            switch $0 { case .folderSnapshot, .treeOrder: return true; default: return false }
        }
        if handshake.projectSyncMode == .legacy && !touchesStructure {
            return await store.record(batch)
        }
        let localProjectEpoch = self.localProjectEpoch
        let localRevision = localProjectEpoch?.value
        guard let context, let structureAuthority,
              let proof = structureAuthority.proof(context, requiresActiveServer: false),
              (try? await isLocalProjectActive(batch.projectID)) == true,
              localProjectEpoch?.isAvailable == true
        else { return .localSavedButNotQueued(reason: "작품 활성 상태와 구조 기준을 다시 확인해야 합니다.") }
        let defaults = self.defaults
        let bindingEpoch = self.bindingEpoch
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try ContractPathGate.reserveStart(for: batch.projectID, in: defaults.value, revision: gateRevision) {
                (authEpoch?.value ?? 0) == authRevision &&
                (bindingEpoch?.value ?? 0) == bindingRevision &&
                (bindingEpoch?.isAvailable ?? false) &&
                handshakeEpoch.value == handshakeRevision &&
                localProjectEpoch?.value == localRevision && localProjectEpoch?.isAvailable == true &&
                structureAuthority.validates(proof)
            }
        }
        do {
            let operationIDs = try await store.enqueueContractStructure(
                batch,
                binding: binding,
                handshake: handshake,
                general: handshake.projectSyncMode == .idBased,
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

struct SyncV2GeneralQueueStatus: Equatable, Sendable {
    let pendingCount: Int
    let attentionCount: Int
    let retryCount: Int
    var resumeMessage: String? = nil

    var message: String {
        if attentionCount > 0 { return "로컬 저장 유지 · 확인이 필요한 변경 \(attentionCount)건. 작품 백업을 만든 뒤 연결 기준과 충돌을 확인해 주세요." }
        if let resumeMessage { return resumeMessage }
        if retryCount > 0 { return "로컬 저장 유지 · 응답을 확인하지 못한 변경 \(retryCount)건을 다시 시도합니다." }
        return pendingCount == 0 ? "대기 중인 일반 변경 없음" : "동기화할 변경 \(pendingCount)건 · 로컬 저장됨"
    }
}

protocol SyncV2GeneralContractSending: Sendable {
    func handlesProject(_ projectID: ProjectID) async -> Bool
    func drainGeneralContract(localProjectID: ProjectID) async -> Bool
    func nextGeneralRetryDate() async -> Date?
}

extension SyncV2GeneralContractSending {
    func nextGeneralRetryDate() async -> Date? { nil }
}

protocol SyncV2ContractQueue: Sendable {
    func recoverableGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch?
    func recoverGeneralContract(_ pending: SyncV2PendingContractBatch, receipt: SyncV2GeneralCommitReceipt,
        accountID: UUID, authorize: @escaping @Sendable () throws -> Void) async throws
    func generalResumeBaseline(localProjectID: ProjectID) async throws -> SyncV2PreparationSnapshot
    func generalQueueStatus(localProjectID: ProjectID) async throws -> SyncV2GeneralQueueStatus
    func makeGeneralRetriesReady(localProjectID: ProjectID) async throws
    func hasGeneralContractHistory(localProjectID: ProjectID) async throws -> Bool
    func hasReadyGeneralContract(localProjectID: ProjectID) async throws -> Bool
    func claimNextGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch
    func discardUnsentPreparation(localProjectID: ProjectID) async throws
    func preparationQueueAuthorization(localProjectID: ProjectID, excluding batchID: UUID?) async throws -> @Sendable () throws -> Void
    func contractPreparation(localProjectID: ProjectID) async throws -> SyncV2ContractPreparation?
    func saveContractPreparation(_ value: SyncV2ContractPreparation) async throws
    func ensurePreparationQueueIsIdle(localProjectID: ProjectID, excluding batchID: UUID?) async throws
    func claimPreparedContractStructure(_ value: SyncV2ContractPreparation) async throws -> SyncV2PendingContractBatch
    func binding(for projectID: ProjectID) async throws -> ProjectSyncBinding?
    func uploadQueueSnapshot(localProjectID: ProjectID) async throws -> SyncV2UploadQueueSnapshot
    func claimNextContractStructure(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch
    func contractQueueAuthorization(localProjectID: ProjectID) async throws -> @Sendable () throws -> Void
    func completeContractStructure(_ pending: SyncV2PendingContractBatch, response: SyncV2JSON) async throws
    func failContractStructure(_ pending: SyncV2PendingContractBatch, error: Error, response: SyncV2JSON?) async
}

extension SyncV2ContractQueue {
    func recoverableGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch? { nil }
    func recoverGeneralContract(_ pending: SyncV2PendingContractBatch, receipt: SyncV2GeneralCommitReceipt,
        accountID: UUID, authorize: @escaping @Sendable () throws -> Void) async throws { throw SyncV2ContractStructureError.unavailable }
    func generalResumeBaseline(localProjectID: ProjectID) async throws -> SyncV2PreparationSnapshot { throw SyncV2ContractStructureError.unavailable }
    func generalQueueStatus(localProjectID: ProjectID) async throws -> SyncV2GeneralQueueStatus { throw SyncV2ContractStructureError.unavailable }
    func makeGeneralRetriesReady(localProjectID: ProjectID) async throws { throw SyncV2ContractStructureError.unavailable }
    func hasGeneralContractHistory(localProjectID: ProjectID) async throws -> Bool { false }
    func hasReadyGeneralContract(localProjectID: ProjectID) async throws -> Bool { false }
    func claimNextGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch { throw SyncV2ContractStructureError.noReadyBatch }
    func discardUnsentPreparation(localProjectID: ProjectID) async throws { throw SyncV2ContractStructureError.unavailable }
    func preparationQueueAuthorization(localProjectID: ProjectID, excluding batchID: UUID?) async throws -> @Sendable () throws -> Void { throw SyncV2ContractStructureError.unavailable }
    func contractPreparation(localProjectID: ProjectID) async throws -> SyncV2ContractPreparation? { throw SyncV2ContractStructureError.unavailable }
    func saveContractPreparation(_ value: SyncV2ContractPreparation) async throws { throw SyncV2ContractStructureError.unavailable }
    func ensurePreparationQueueIsIdle(localProjectID: ProjectID, excluding batchID: UUID?) async throws { throw SyncV2ContractStructureError.unavailable }
    func claimPreparedContractStructure(_ value: SyncV2ContractPreparation) async throws -> SyncV2PendingContractBatch { throw SyncV2ContractStructureError.unavailable }
}

extension LazySyncV2ProjectBindingStore: SyncV2ContractQueue {}

/// 일반 자동 전송과 명시적 검토 전송이 공유하는 전송기다. 전송 직전에 관문과
/// 핸드셰크를 다시 확인하고, 로컬에 먼저 저장된 불변 요청만 보낸다.
actor SyncV2ContractStructureSender: SyncV2GeneralContractSending, SyncV2GeneralRecoveryReading, SyncV2GeneralConflictResolving, SyncV2GeneralStructureResolving {
    private let store: any SyncV2ContractQueue
    private let transport: any SyncV2AtomicStructureTransporting
    private let handshakeService: SyncV2HandshakeService
    private let authenticationService: any AuthenticationServicing
    private let uploadPullCoordinator:
        SyncV2ProjectUploadPullCoordinator?
    private let defaults: ContractDefaults
    private let structureAuthority: SyncV2ContractStructureAuthority?
    private let localProjectEpoch: SyncV2ContractEpoch?
    private let isLocalProjectActive: @Sendable (ProjectID) async throws -> Bool
    private let bindingEpoch: SyncV2ContractEpoch?
    private let deviceIdentityProvider: (any DeviceIdentityProviding)?
    private let localDocuments: @Sendable (ProjectID) async throws -> [DocumentNode]
    private var sendingProjects: Set<ProjectID> = []
    private var generalDrainProject: ProjectID?
    private var generalRetries: [ProjectID: (attempt: Int, date: Date)] = [:]
    private var generalResumeMessages: [ProjectID: String] = [:]

    init(
        store: any SyncV2ContractQueue,
        transport: any SyncV2AtomicStructureTransporting,
        handshakeService: SyncV2HandshakeService,
        authenticationService: any AuthenticationServicing,
        uploadPullCoordinator:
            SyncV2ProjectUploadPullCoordinator? = nil,
        defaults: ContractDefaults = .standard,
        bindingEpoch: SyncV2ContractEpoch? = nil,
        deviceIdentityProvider: (any DeviceIdentityProviding)? = nil,
        structureAuthority: SyncV2ContractStructureAuthority? = nil,
        localProjectEpoch: SyncV2ContractEpoch? = nil,
        isLocalProjectActive: @escaping @Sendable (ProjectID) async throws -> Bool = { _ in false },
        localDocuments: @escaping @Sendable (ProjectID) async throws -> [DocumentNode] = { _ in throw SyncV2ContractStructureError.unavailable }
    ) {
        self.localDocuments = localDocuments
        self.store = store
        self.transport = transport
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.uploadPullCoordinator = uploadPullCoordinator
        self.defaults = defaults
        self.structureAuthority = structureAuthority
        self.localProjectEpoch = localProjectEpoch
        self.isLocalProjectActive = isLocalProjectActive
        self.bindingEpoch = bindingEpoch
        self.deviceIdentityProvider = deviceIdentityProvider
    }

    /// 관문을 열거나 바인더를 수정하지 않고 읽기와 별도 검토 저장만 한다.
    func prepareEmptyVolume(localProjectID: ProjectID) async throws -> SyncV2ContractPreparation {
        guard sendingProjects.insert(localProjectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(localProjectID) }
        guard !ContractPathGate.isOpen(for: localProjectID, in: defaults.value) else {
            throw SyncV2ContractStructureError.preparationRequiresClosedGate
        }
        let gateRevision = ContractPathGate.revision(for: localProjectID, in: defaults.value)
        let authRevision = authenticationService.contractEpoch?.value
        let bindingRevision = bindingEpoch?.value
        let localRevision = localProjectEpoch?.value
        guard let binding = try await store.binding(for: localProjectID),
              binding.serverProjectID == SyncV2EmptyVolumeReview.projectID,
              let context = SyncV2HandshakeContext.make(authenticationState: await authenticationService.currentState(),
                localProjectID: localProjectID, serverProjectID: SyncV2EmptyVolumeReview.projectID,
                authenticationEpoch: authRevision ?? 0, bindingEpoch: bindingRevision ?? 0),
              binding.ownerSubject == context.accountID, try await isLocalProjectActive(localProjectID),
              let deviceIdentityProvider, let structureAuthority,
              localProjectEpoch?.isAvailable == true, bindingEpoch?.isAvailable == true else {
            throw SyncV2ContractStructureError.projectNotConnected
        }
        let authorizeQueue = try await store.contractQueueAuthorization(localProjectID: localProjectID)
        let authorizePreparation = try await store.preparationQueueAuthorization(localProjectID: localProjectID, excluding: nil)
        _ = try await handshakeService.refreshForGate(context: context)
        let handshakeRevision = handshakeService.authorizationEpoch.value
        guard let handshake = await handshakeService.standingHandshake(for: context),
              handshake.projectSyncMode == .legacy, handshake.migrationEpoch == 0,
              let proof = structureAuthority.proof(context, requiresActiveServer: false) else {
            throw SyncV2ContractStructureError.structureAuthorityUnavailable
        }
        guard try await transport.fetchProjectState(projectID: context.serverProjectID) == .active else {
            throw SyncV2ContractStructureError.projectInactive
        }
        let snapshot = try await transport.fetchPreparationSnapshot(projectID: context.serverProjectID)
        let local = try await localDocuments(localProjectID)
        let localFingerprint = try snapshot.validate(local: local)
        let serverFingerprint = try snapshot.fingerprint()
        let second = try await transport.fetchPreparationSnapshot(projectID: context.serverProjectID)
        guard try second.fingerprint() == serverFingerprint else { throw SyncV2ContractStructureError.preparationChanged }
        let deviceID = try await deviceIdentityProvider.currentIdentifier().uuid
        let existing = try await store.contractPreparation(localProjectID: localProjectID)
        let preparation: SyncV2ContractPreparation
        if let existing {
            guard existing.accountID == context.accountID, existing.serverFingerprint == serverFingerprint,
                  existing.localFingerprint == localFingerprint else { throw SyncV2ContractStructureError.preparationChanged }
            try existing.request.validateForTransmission(context: context, handshake: handshake, writerDeviceID: deviceID)
            preparation = existing
        } else {
            let folderID = UUID(), treeOrderID = UUID()
            let request = try SyncV2Contract.buildAtomicStructureRequest(projectID: context.serverProjectID,
                projectSyncMode: .legacy, migrationEpoch: 0, writerDeviceID: deviceID, orderedIntents: [
                    .init(entityKind: .folder, entityID: folderID, intentKind: .create, payload: .object([
                        "parent_folder_id": .string(SyncV2EmptyVolumeReview.parentID.uuidString.lowercased()), "name": .string(SyncV2EmptyVolumeReview.name)])),
                    .init(entityKind: .treeOrder, entityID: treeOrderID, intentKind: .reorder, payload: .object([
                        "parent_folder_id": .string(SyncV2EmptyVolumeReview.parentID.uuidString.lowercased()),
                        "children": .array([.string(SyncV2EmptyVolumeReview.volumeID.uuidString.lowercased()), .string(folderID.uuidString.lowercased())])]))])
            preparation = .init(localProjectID: localProjectID, accountID: context.accountID,
                serverFingerprint: serverFingerprint, localFingerprint: localFingerprint,
                requestJSON: request.json, requestSHA256: try request.json.sha256Hex(), preparedAt: Date())
        }
        try authorizeQueue()
        try authorizePreparation()
        guard !Task.isCancelled, !ContractPathGate.isOpen(for: localProjectID, in: defaults.value),
              gateRevision == ContractPathGate.revision(for: localProjectID, in: defaults.value),
              authRevision == authenticationService.contractEpoch?.value, bindingRevision == bindingEpoch?.value,
              localRevision == localProjectEpoch?.value, localProjectEpoch?.isAvailable == true,
              handshakeRevision == handshakeService.authorizationEpoch.value,
              structureAuthority.validates(proof), await handshakeService.isFresh(for: context) else {
            throw SyncV2ContractStructureError.preparationChanged
        }
        try await store.saveContractPreparation(preparation)
        try authorizeQueue()
        try authorizePreparation()
        guard !Task.isCancelled, !ContractPathGate.isOpen(for: localProjectID, in: defaults.value),
              gateRevision == ContractPathGate.revision(for: localProjectID, in: defaults.value),
              authRevision == authenticationService.contractEpoch?.value, bindingRevision == bindingEpoch?.value,
              localRevision == localProjectEpoch?.value, localProjectEpoch?.isAvailable == true,
              handshakeRevision == handshakeService.authorizationEpoch.value,
              structureAuthority.validates(proof) else { throw SyncV2ContractStructureError.preparationChanged }
        return preparation
    }

    func discardUnsentPreparation(localProjectID: ProjectID) async throws {
        guard !sendingProjects.contains(localProjectID), !ContractPathGate.isOpen(for: localProjectID, in: defaults.value) else {
            throw SyncV2ContractStructureError.preparationRequiresClosedGate
        }
        try await store.discardUnsentPreparation(localProjectID: localProjectID)
    }

    func reviewedPreparation(localProjectID: ProjectID) async throws -> SyncV2ContractPreparation? {
        try await store.contractPreparation(localProjectID: localProjectID)
    }

    private func validatePreparationBaseline(_ value: SyncV2ContractPreparation) async throws {
        let snapshot = try await transport.fetchPreparationSnapshot(projectID: SyncV2EmptyVolumeReview.projectID)
        let local = try await localDocuments(value.localProjectID)
        let second = try await transport.fetchPreparationSnapshot(projectID: SyncV2EmptyVolumeReview.projectID)
        guard try snapshot.fingerprint() == value.serverFingerprint,
              try second.fingerprint() == value.serverFingerprint,
              try snapshot.validate(local: local) == value.localFingerprint else {
            throw SyncV2ContractStructureError.preparationChanged
        }
        try await store.ensurePreparationQueueIsIdle(localProjectID: value.localProjectID, excluding: try value.request.batchID)
    }

    func generalQueueStatus(localProjectID: ProjectID) async throws -> SyncV2GeneralQueueStatus {
        var status = try await store.generalQueueStatus(localProjectID: localProjectID)
        status.resumeMessage = generalResumeMessages[localProjectID]
        return status
    }

    func generalRecoveryPage(localProjectID: ProjectID, after queueID: Int64?) async throws -> SyncV2GeneralRecoveryPage {
        guard let reader = store as? any SyncV2GeneralRecoveryReading else { throw SyncV2GeneralRecoveryError.unavailable }
        return try await reader.generalRecoveryPage(localProjectID: localProjectID, after: queueID)
    }

    func generalRecoveryDetail(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRecoveryDetail {
        guard let reader = store as? any SyncV2GeneralRecoveryReading else { throw SyncV2GeneralRecoveryError.unavailable }
        return try await reader.generalRecoveryDetail(localProjectID: localProjectID, batchID: batchID)
    }

    func prepareGeneralConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralConflictReview {
        guard sendingProjects.insert(localProjectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(localProjectID) }
        return try await readGeneralConflict(localProjectID: localProjectID, batchID: batchID).review
    }

    func keepSavedGeneralConflict(_ review: SyncV2GeneralConflictReview) async throws -> UUID {
        try await resolveGeneralConflict(review, selection: nil)
    }

    func selectGeneralConflict(_ review: SyncV2GeneralConflictReview, content: String,
        saveLocal: @escaping SyncV2GeneralConflictLocalSaving) async throws -> UUID {
        guard content.utf8.count <= SyncV2Store.maximumContentByteCount,
              review.local.records.count < 50, review.local.deferredRecords.isEmpty else { throw SyncV2GeneralConflictError.unsupported }
        return try await resolveGeneralConflict(review, selection: (content, saveLocal))
    }

    private func resolveGeneralConflict(_ review: SyncV2GeneralConflictReview,
        selection: (content: String, save: SyncV2GeneralConflictLocalSaving)?) async throws -> UUID {
        try ReceiveValidationPolicy.current.requireSending()
        let projectID = review.context.localProjectID
        guard sendingProjects.insert(projectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(projectID) }
        guard let resolver = store as? any SyncV2GeneralConflictStoring,
              let uploadPullCoordinator, let structureAuthority else { throw SyncV2GeneralConflictError.unavailable }
        let queue = try await store.uploadQueueSnapshot(localProjectID: projectID)
        guard let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: projectID, queue: queue) else {
            throw SyncV2ContractStructureError.uploadPullGateBusy
        }
        var localSelectionSaved = false
        do {
            // 사용자가 비교한 본문과 같은지 확정 직전에 다시 읽는다.
            var latest = try await readGeneralConflict(localProjectID: projectID, batchID: review.local.detail.row.batchID)
            guard latest.review.context == review.context, latest.review.fingerprint == review.fingerprint else {
                throw SyncV2GeneralConflictError.changed
            }
            try latest.authorize()
            if let selection {
                let operationID = try await selection.save(review, selection.content, latest.authorize)
                localSelectionSaved = true
                try latest.authorize()
                latest = try await readGeneralConflict(localProjectID: projectID, batchID: review.local.detail.row.batchID)
                // 선택 저장 한 건만 추가되어야 한다. 그 사이의 다른 입력은 함께 확정하지 않는다.
                var previousLocal = latest.review.local
                guard previousLocal.followers.count == review.local.followers.count + 1,
                      let added = previousLocal.followers.popLast(),
                      case let .documentSnapshot(addedOperation, _, _, addedContent, _, _, _) = added.source.mutations[0],
                      addedOperation == operationID, addedContent == selection.content else {
                    throw SyncV2GeneralConflictError.changed
                }
                let previousReview = try SyncV2GeneralConflictReview(local: previousLocal, remote: latest.review.remote,
                    remoteBaseline: latest.review.remoteBaseline, context: latest.review.context,
                    authorizationFingerprint: latest.review.authorizationFingerprint)
                guard previousReview.context == review.context, previousReview.fingerprint == review.fingerprint else {
                    throw SyncV2GeneralConflictError.changed
                }
                try latest.authorize()
            }
            _ = structureAuthority.beginBaseline(review.context)
            let replacement = try await resolver.replaceGeneralConflict(latest.review, authorize: latest.authorize)
            generalRetries.removeValue(forKey: projectID); generalResumeMessages.removeValue(forKey: projectID)
            await finishUploadPermit(permit, localProjectID: projectID)
            // 실제 송신은 새 서버 기준·C9를 다시 확인하는 기존 일반 경로만 사용한다.
            Task { _ = await self.drainGeneralContract(localProjectID: projectID) }
            return replacement
        } catch {
            await finishUploadPermit(permit, localProjectID: projectID)
            if localSelectionSaved { throw SyncV2GeneralConflictError.localSelectionSavedNeedsReview }
            throw error
        }
    }

    private func readGeneralConflict(localProjectID: ProjectID, batchID: UUID) async throws ->
        (review: SyncV2GeneralConflictReview, authorize: @Sendable () throws -> Void) {
        let data = try await readGeneralConflictData(localProjectID: localProjectID, batchID: batchID, includeContent: true)
        guard let remote = data.remote else { throw SyncV2GeneralConflictError.unsupported }
        return (try .init(local: data.local, remote: remote, remoteBaseline: data.baseline,
            context: data.context, authorizationFingerprint: data.stamp), data.authorize)
    }

    private func readGeneralOrderConflict(localProjectID: ProjectID, batchID: UUID) async throws ->
        (review: SyncV2GeneralOrderConflictReview, authorize: @Sendable () throws -> Void) {
        let data = try await readGeneralConflictData(localProjectID: localProjectID, batchID: batchID, includeContent: false)
        return (try .init(local: data.local, remoteBaseline: data.baseline,
            context: data.context, authorizationFingerprint: data.stamp), data.authorize)
    }

    func prepareGeneralOrderConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralOrderConflictReview {
        guard sendingProjects.insert(localProjectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(localProjectID) }
        return try await readGeneralOrderConflict(localProjectID: localProjectID, batchID: batchID).review
    }

    func keepSavedGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview) async throws -> UUID {
        let projectID = review.context.localProjectID
        guard sendingProjects.insert(projectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(projectID) }
        guard let resolver = store as? any SyncV2GeneralConflictStoring,
              let uploadPullCoordinator, let structureAuthority else { throw SyncV2GeneralConflictError.unavailable }
        let queue = try await store.uploadQueueSnapshot(localProjectID: projectID)
        guard let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: projectID, queue: queue) else {
            throw SyncV2ContractStructureError.uploadPullGateBusy
        }
        do {
            let latest = try await readGeneralOrderConflict(localProjectID: projectID, batchID: review.local.detail.row.batchID)
            guard latest.review.context == review.context, latest.review.fingerprint == review.fingerprint else {
                throw SyncV2GeneralConflictError.changed
            }
            try latest.authorize()
            _ = structureAuthority.beginBaseline(review.context)
            let replacement = try await resolver.replaceGeneralOrderConflict(latest.review, authorize: latest.authorize)
            generalRetries.removeValue(forKey: projectID); generalResumeMessages.removeValue(forKey: projectID)
            await finishUploadPermit(permit, localProjectID: projectID)
            Task { _ = await self.drainGeneralContract(localProjectID: projectID) }
            return replacement
        } catch {
            await finishUploadPermit(permit, localProjectID: projectID)
            throw error
        }
    }

    private func readGeneralRenameConflict(localProjectID: ProjectID, batchID: UUID) async throws ->
        (review: SyncV2GeneralRenameConflictReview, authorize: @Sendable () throws -> Void) {
        let data = try await readGeneralConflictData(localProjectID: localProjectID, batchID: batchID, includeContent: true)
        guard let remote = data.remote else { throw SyncV2GeneralConflictError.unsupported }
        return (try .init(local: data.local, remote: remote, remoteBaseline: data.baseline,
            context: data.context, authorizationFingerprint: data.stamp), data.authorize)
    }

    func prepareGeneralRenameConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRenameConflictReview {
        guard sendingProjects.insert(localProjectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(localProjectID) }
        return try await readGeneralRenameConflict(localProjectID: localProjectID, batchID: batchID).review
    }

    func keepSavedGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview) async throws -> UUID {
        let projectID = review.context.localProjectID
        guard sendingProjects.insert(projectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(projectID) }
        guard let resolver = store as? any SyncV2GeneralConflictStoring,
              let uploadPullCoordinator, let structureAuthority else { throw SyncV2GeneralConflictError.unavailable }
        let queue = try await store.uploadQueueSnapshot(localProjectID: projectID)
        guard let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: projectID, queue: queue) else {
            throw SyncV2ContractStructureError.uploadPullGateBusy
        }
        do {
            let latest = try await readGeneralRenameConflict(localProjectID: projectID, batchID: review.local.detail.row.batchID)
            guard latest.review.context == review.context, latest.review.fingerprint == review.fingerprint else {
                throw SyncV2GeneralConflictError.changed
            }
            try latest.authorize()
            _ = structureAuthority.beginBaseline(review.context)
            let replacement = try await resolver.replaceGeneralRenameConflict(latest.review, authorize: latest.authorize)
            generalRetries.removeValue(forKey: projectID); generalResumeMessages.removeValue(forKey: projectID)
            await finishUploadPermit(permit, localProjectID: projectID)
            Task { _ = await self.drainGeneralContract(localProjectID: projectID) }
            return replacement
        } catch {
            await finishUploadPermit(permit, localProjectID: projectID)
            throw error
        }
    }

    private func readGeneralStructureConflict(localProjectID: ProjectID, batchID: UUID) async throws ->
        (review: SyncV2GeneralStructureReview, authorize: @Sendable () throws -> Void) {
        let data = try await readGeneralConflictData(localProjectID: localProjectID, batchID: batchID, includeContent: false, includeAllContent: true)
        return (try .init(local: data.local, remoteBaseline: data.baseline, remoteDocuments: data.remote?.arrayValue ?? [],
            context: data.context, authorizationFingerprint: data.stamp), data.authorize)
    }

    func prepareGeneralStructureConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralStructureReview {
        guard sendingProjects.insert(localProjectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(localProjectID) }
        return try await readGeneralStructureConflict(localProjectID: localProjectID, batchID: batchID).review
    }

    func resolveGeneralStructureConflict(_ review: SyncV2GeneralStructureReview, adoptServer: Bool,
        validateLocal: (@Sendable (SyncV2GeneralStructureReview) async throws -> Void)?) async throws -> UUID {
        try ReceiveValidationPolicy.current.requireSending()
        let projectID = review.context.localProjectID
        guard sendingProjects.insert(projectID).inserted else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        defer { sendingProjects.remove(projectID) }
        guard let resolver = store as? any SyncV2GeneralStructureStoring, let uploadPullCoordinator, let structureAuthority else {
            throw SyncV2GeneralConflictError.unavailable
        }
        let queue = try await store.uploadQueueSnapshot(localProjectID: projectID)
        guard let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: projectID, queue: queue) else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        do {
            let latest = try await readGeneralStructureConflict(localProjectID: projectID, batchID: review.local.detail.row.batchID)
            guard latest.review.fingerprint == review.fingerprint else { throw SyncV2GeneralConflictError.changed }
            if adoptServer {
                guard latest.review.canAdoptServer, let validateLocal else { throw SyncV2GeneralConflictError.unsupported }
                try await validateLocal(latest.review)
            }
            try latest.authorize()
            _ = structureAuthority.beginBaseline(review.context)
            let result = try await resolver.replaceGeneralStructureConflict(latest.review, adoptServer: adoptServer, authorize: latest.authorize)
            generalRetries.removeValue(forKey: projectID); generalResumeMessages.removeValue(forKey: projectID)
            await finishUploadPermit(permit, localProjectID: projectID)
            if !adoptServer { Task { _ = await self.drainGeneralContract(localProjectID: projectID) } }
            return result
        } catch {
            await finishUploadPermit(permit, localProjectID: projectID); throw error
        }
    }

    private func readGeneralConflictData(localProjectID: ProjectID, batchID: UUID, includeContent: Bool, includeAllContent: Bool = false) async throws ->
        (local: SyncV2GeneralConflictLocal, remote: SyncV2JSON?, baseline: SyncV2PreparationSnapshot,
         context: SyncV2HandshakeContext, stamp: String, authorize: @Sendable () throws -> Void) {
        guard let resolver = store as? any SyncV2GeneralConflictStoring,
              let authEpoch = authenticationService.contractEpoch, let bindingEpoch, let localProjectEpoch,
              let deviceIdentityProvider else { throw SyncV2GeneralConflictError.unavailable }
        let authRevision = authEpoch.value, bindingRevision = bindingEpoch.value, localRevision = localProjectEpoch.value
        let activityEpoch = handshakeService.activityEpoch, activityRevision = activityEpoch.value
        let gateRevision = ContractPathGate.revision(for: localProjectID, in: defaults.value)
        let globalEpoch = GlobalSyncPreference.contractEpoch, globalRevision = globalEpoch.value
        guard ContractPathGate.isOpen(for: localProjectID, in: defaults.value), GlobalSyncPreference.isEnabled(in: defaults.value),
              bindingEpoch.isAvailable, localProjectEpoch.isAvailable,
              await handshakeService.canStartContractWrite(), try await isLocalProjectActive(localProjectID),
              let binding = try await store.binding(for: localProjectID), let serverID = binding.serverProjectID,
              let context = SyncV2HandshakeContext.make(authenticationState: await authenticationService.currentState(),
                localProjectID: localProjectID, serverProjectID: serverID, authenticationEpoch: authRevision, bindingEpoch: bindingRevision),
              binding.ownerSubject == context.accountID else { throw SyncV2GeneralConflictError.unavailable }
        if await handshakeService.standingHandshake(for: context) == nil { _ = try await handshakeService.refresh(context: context) }
        guard let handshake = await handshakeService.standingHandshake(for: context), handshake.projectSyncMode == .idBased else {
            throw SyncV2GeneralConflictError.unavailable
        }
        let handshakeEpoch = handshakeService.authorizationEpoch, handshakeRevision = handshakeEpoch.value
        let sharedDefaults = defaults
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try ContractPathGate.reserveStart(for: localProjectID, in: sharedDefaults.value, revision: gateRevision) {
                authEpoch.value == authRevision && bindingEpoch.value == bindingRevision && bindingEpoch.isAvailable &&
                localProjectEpoch.value == localRevision && localProjectEpoch.isAvailable &&
                activityEpoch.value == activityRevision && handshakeEpoch.value == handshakeRevision &&
                globalEpoch.value == globalRevision && GlobalSyncPreference.isEnabled(in: sharedDefaults.value)
            }
        }
        try authorize()
        let local = try await resolver.generalConflictLocal(localProjectID: localProjectID, batchID: batchID)
        if let originalJSON = local.detail.requestJSON {
            let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(originalJSON.utf8)))
            try await request.validateForTransmission(context: context, handshake: handshake,
                writerDeviceID: deviceIdentityProvider.currentIdentifier().uuid)
        } else if !includeAllContent { throw SyncV2GeneralConflictError.unsupported }
        guard try await transport.fetchProjectState(projectID: serverID) == .active else { throw SyncV2ContractStructureError.projectInactive }
        let first = try await transport.fetchGeneralBaseline(projectID: serverID)
        var remote: SyncV2JSON?
        if includeAllContent {
            let ids = try SyncV2GeneralTree(first).activeDocumentIDs.sorted { $0.uuidString < $1.uuidString }
            guard ids.count <= 500 else { throw SyncV2GeneralConflictError.unsupported }
            var bodies: [SyncV2JSON] = [], bytes = 0
            for id in ids {
                try authorize()
                let body = try await transport.fetchGeneralConflictDocument(projectID: serverID, documentID: id)
                bytes += try body.canonicalJSON().utf8.count
                guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes else { throw SyncV2GeneralConflictError.unsupported }
                bodies.append(body)
            }
            remote = .array(bodies)
        } else if includeContent {
            let manuscripts = try local.detail.manuscripts()
            if let mutation = local.detail.source.mutations.first(where: { if case .folderSnapshot = $0 { return true }; return false }),
               case let .folderSnapshot(_, folder, _, _, false) = mutation {
                guard manuscripts.count <= 50,
                      var fields = first.folders.first(where: { $0.objectValue?["folder_id"] == .string(folder.rawValue.uuidString.lowercased()) })?.objectValue else {
                    throw SyncV2GeneralConflictError.unsupported
                }
                var children: [SyncV2JSON] = [], bytes = 0
                for manuscript in manuscripts {
                    try authorize()
                    let child = try await transport.fetchGeneralConflictDocument(projectID: serverID, documentID: manuscript.documentID.rawValue)
                    bytes += try child.canonicalJSON().utf8.count
                    guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes else { throw SyncV2GeneralConflictError.unsupported }
                    children.append(child)
                }
                if !children.isEmpty { fields["descendant_documents"] = .array(children) }
                remote = .object(fields)
            } else if manuscripts.count == 1, let manuscript = manuscripts.first {
                remote = try await transport.fetchGeneralConflictDocument(projectID: serverID, documentID: manuscript.documentID.rawValue)
            } else { throw SyncV2GeneralConflictError.unsupported }
        }
        let second = try await transport.fetchGeneralBaseline(projectID: serverID)
        guard try first.fingerprint() == second.fingerprint() else { throw SyncV2GeneralConflictError.changed }
        try authorize()
        let stamp = [authRevision, bindingRevision, localRevision, activityRevision, handshakeRevision, gateRevision, globalRevision].map(String.init).joined(separator: ":")
        return (local, remote, second, context, stamp, authorize)
    }

    func retryGeneralContract(localProjectID: ProjectID) async throws {
        guard ContractPathGate.isOpen(for: localProjectID, in: defaults.value), GlobalSyncPreference.isEnabled(in: defaults.value)
        else { throw SyncV2ContractStructureError.gateClosed }
        generalRetries.removeValue(forKey: localProjectID)
        generalResumeMessages.removeValue(forKey: localProjectID)
        try await store.makeGeneralRetriesReady(localProjectID: localProjectID)
    }

    func handlesProject(_ projectID: ProjectID) async -> Bool {
        // 닫힌 관문이나 끊긴 인증도 이미 UUID 계약인 작품을 구형 송신으로
        // 되돌리지 않는다. 반대로 LEGACY 작품의 정상 본문 큐는 유지한다.
        if (try? await store.hasGeneralContractHistory(localProjectID: projectID)) ?? true { return true }
        guard ContractPathGate.isOpen(for: projectID, in: defaults.value) else { return false }
        guard let binding = try? await store.binding(for: projectID), let serverID = binding.serverProjectID,
              let context = SyncV2HandshakeContext.make(authenticationState: await authenticationService.currentState(),
                localProjectID: projectID, serverProjectID: serverID,
                authenticationEpoch: authenticationService.contractEpoch?.value ?? 0, bindingEpoch: bindingEpoch?.value ?? 0),
              let handshake = await handshakeService.standingHandshake(for: context) else { return true }
        return handshake.projectSyncMode != .legacy
    }

    func drainGeneralContract(localProjectID: ProjectID) async -> Bool {
        if let retry = generalRetries[localProjectID], retry.date > Date() { return false }
        // 핸드셰이크는 단일 문맥 캐시이므로 작품별 전송을 교차시키지 않는다.
        guard generalDrainProject == nil else {
            scheduleGeneralRetry(localProjectID)
            return false
        }
        generalDrainProject = localProjectID
        defer { generalDrainProject = nil }
        do {
            guard try await store.hasReadyGeneralContract(localProjectID: localProjectID) else {
                generalRetries.removeValue(forKey: localProjectID)
                // 구형 큐만 남은 작품을 성공으로 돌려주면 dispatcher가 즉시 재진입한다.
                return false
            }
            // 네트워크 실패는 다음 예약/복귀 사건에서 재시도한다. ready로 돌아온
            // 같은 요청을 이 루프에서 즉시 반복 송신하지 않는다.
            while try await store.hasReadyGeneralContract(localProjectID: localProjectID) {
                try Task.checkCancellation()
                _ = try await sendNext(localProjectID: localProjectID, generalOnly: true)
            }
            generalRetries.removeValue(forKey: localProjectID)
            generalResumeMessages.removeValue(forKey: localProjectID)
            return true
        } catch {
            generalResumeMessages[localProjectID] = error as? SyncV2ContractStructureError == .invalidRecoveryReceipt
                ? "로컬 저장 유지 · 서버 적용 기록과 보관된 요청이 일치하지 않아 완료를 보류했습니다."
                : "로컬 저장 유지 · 연결과 서버 기준을 다시 확인하고 있습니다. 기준이 달라진 변경은 자동으로 덮어쓰지 않습니다."
            if (try? await store.hasReadyGeneralContract(localProjectID: localProjectID)) == true {
                scheduleGeneralRetry(localProjectID)
            } else { generalRetries.removeValue(forKey: localProjectID) }
            return false
        }
    }

    private func scheduleGeneralRetry(_ projectID: ProjectID) {
        let attempt = min((generalRetries[projectID]?.attempt ?? 0) + 1, 7)
        generalRetries[projectID] = (attempt, Date().addingTimeInterval(min(300, 5 * pow(2, Double(attempt - 1)))))
    }

    func nextGeneralRetryDate() async -> Date? {
        // 다른 경로에서 차단·완료된 소스 때문에 만료된 메모리 타이머가
        // 계속 dispatcher를 깨우지 않도록 실제 준비 상태를 다시 확인한다.
        for projectID in Array(generalRetries.keys) {
            if (try? await store.hasReadyGeneralContract(localProjectID: projectID)) == false {
                generalRetries.removeValue(forKey: projectID)
            }
        }
        return generalRetries.values.map(\.date).min()
    }

    /// 디스크 기준과 서버가 모두 그대로일 때만 재시작으로 잃은 승인을 복원한다.
    /// 원고·바인더를 apply하거나 요청의 revision/신원을 바꾸는 경로가 아니다.
    private func restoreGeneralBaseline(context: SyncV2HandshakeContext,
        authorizeQueue: @escaping @Sendable () throws -> Void) async throws {
        guard let structureAuthority, let uploadPullCoordinator else {
            throw SyncV2ContractStructureError.structureAuthorityUnavailable
        }
        let localID = context.localProjectID
        let queue = try await store.uploadQueueSnapshot(localProjectID: localID)
        structureAuthority.observeQueue(queue, projectID: localID)
        try authorizeQueue()
        guard queue.conflictCount == 0, queue.blockedCount == 0,
              let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: localID, queue: queue)
        else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        let token = structureAuthority.beginBaseline(context)
        do {
            let local = try await store.generalResumeBaseline(localProjectID: localID).fingerprint()
            let first = try await transport.fetchGeneralBaseline(projectID: context.serverProjectID).fingerprint()
            let second = try await transport.fetchGeneralBaseline(projectID: context.serverProjectID).fingerprint()
            let latest = try await store.generalResumeBaseline(localProjectID: localID).fingerprint()
            try Task.checkCancellation()
            try authorizeQueue()
            guard local == first, first == second, local == latest else {
                throw SyncV2ContractStructureError.structureAuthorityUnavailable
            }
            structureAuthority.finishBaseline(context, token: token, allowed: true)
            let latestQueue = try await store.uploadQueueSnapshot(localProjectID: localID)
            await uploadPullCoordinator.finishUploadDrain(permit, queue: latestQueue)
        } catch {
            structureAuthority.finishBaseline(context, token: token, allowed: false)
            let latestQueue = (try? await store.uploadQueueSnapshot(localProjectID: localID))
                ?? SyncV2UploadQueueSnapshot(retryWaitingCount: 1)
            await uploadPullCoordinator.finishUploadDrain(permit, queue: latestQueue)
            throw error
        }
    }

    /// 이미 적용된 결과를 로컬 장부에만 수용한다. C9 승인이나 쓰기 RPC를 만들지 않는다.
    private func recoverGeneralReceipt(_ pending: SyncV2PendingContractBatch, context: SyncV2HandshakeContext,
        authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2ContractSendReport? {
        let handshakeRevision = handshakeService.authorizationEpoch.value
        guard let uploadPullCoordinator, let structureAuthority else { throw SyncV2ContractStructureError.structureAuthorityUnavailable }
        let queue = try await store.uploadQueueSnapshot(localProjectID: pending.localProjectID)
        structureAuthority.observeQueue(queue, projectID: pending.localProjectID)
        try authorize()
        guard queue.conflictCount == 0, queue.blockedCount == 0,
              let permit = await uploadPullCoordinator.beginUploadDrain(localProjectID: pending.localProjectID, queue: queue)
        else { throw SyncV2ContractStructureError.uploadPullGateBusy }
        do {
            guard try await store.recoverableGeneralContract(localProjectID: pending.localProjectID) == pending else {
                throw SyncV2ContractStructureError.invalidStoredRequest
            }
            guard let receipt = try await transport.fetchGeneralReceipt(projectID: pending.serverProjectID, batchID: pending.request.batchID) else {
                try authorize()
                await finishUploadPermit(permit, localProjectID: pending.localProjectID)
                return nil
            }
            let response = try receipt.validatedResponse(for: pending, accountID: context.accountID)
            guard let statusValue = response.objectValue?["status"]?.stringValue,
                  let status = SyncV2CommitStatus(rawValue: statusValue) else { throw SyncV2ContractStructureError.invalidRecoveryReceipt }
            try authorize()
            // 결과 수용 뒤 후속 변경은 전진한 기준을 새로 대조해야 한다.
            _ = structureAuthority.beginBaseline(context)
            try await store.recoverGeneralContract(pending, receipt: receipt, accountID: context.accountID, authorize: authorize)
            await finishUploadPermit(permit, localProjectID: pending.localProjectID)
            var report = SyncV2ContractSendReport(batchID: pending.request.batchID,
                status: status,
                operationCount: pending.request.orderedIntents.count)
            report.recoveredFromReceipt = true
            do { try authorize() } catch { report.mayPresentCompletion = false }
            return report
        } catch {
            await finishUploadPermit(permit, localProjectID: pending.localProjectID)
            if let stale = error as? SyncV2HandshakeError {
                await handshakeService.forgetIfStale(stale, expectedGeneration: handshakeRevision)
            }
            throw error
        }
    }

    func sendNext(
        localProjectID: ProjectID,
        preparedBatchID: UUID? = nil,
        reviewedRequestSHA256: String? = nil,
        generalOnly: Bool = false
    ) async throws -> SyncV2ContractSendReport {
        try ReceiveValidationPolicy.current.requireSending()
        guard !generalOnly || (preparedBatchID == nil && reviewedRequestSHA256 == nil) else {
            throw SyncV2ContractStructureError.invalidStoredRequest
        }
        guard sendingProjects.insert(localProjectID).inserted else {
            throw SyncV2ContractStructureError.uploadPullGateBusy
        }
        defer { sendingProjects.remove(localProjectID) }
        let gateRevision = ContractPathGate.revision(for: localProjectID, in: defaults.value)
        let globalRevision = GlobalSyncPreference.contractEpoch.value
        let authEpoch = authenticationService.contractEpoch
        let authRevision = authEpoch?.value ?? 0
        let bindingRevision = bindingEpoch?.value ?? 0
        let handshakeEpoch = handshakeService.authorizationEpoch
        let activityEpoch = handshakeService.activityEpoch
        let activityRevision = activityEpoch.value
        guard ContractPathGate.isOpen(for: localProjectID, in: defaults.value)
        else { throw SyncV2ContractStructureError.gateClosed }
        if generalOnly, !GlobalSyncPreference.isEnabled(in: defaults.value) {
            throw SyncV2ContractStructureError.gateClosed
        }
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
        if generalOnly, binding.ownerSubject == context.accountID,
           GlobalSyncPreference.isEnabled(in: defaults.value), await handshakeService.canStartContractWrite(),
           await handshakeService.standingHandshake(for: context) == nil {
            _ = try await handshakeService.refresh(context: context)
        }
        let handshakeRevision = handshakeEpoch.value
        guard binding.ownerSubject == context.accountID,
              await handshakeService.usesContractStructure(
            context: context,
            gateIsOpen: true
        ), let handshake = await handshakeService.standingHandshake(for: context),
           await handshakeService.canStartContractWrite(),
           let deviceIdentityProvider
        else { throw SyncV2ContractStructureError.handshakeMissing }
        let localProjectEpoch = self.localProjectEpoch
        let localRevision = localProjectEpoch?.value
        // 삭제 뒤 복원된 서버 작품도 매번 상태를 다시 읽는다. 이 읽기는 쓰기
        // 허가가 아니며 아래의 active + 구조 증명과 최종 authorize가 필수다.
        guard let structureAuthority, localProjectEpoch?.isAvailable == true
        else { throw SyncV2ContractStructureError.structureAuthorityUnavailable }
        guard try await isLocalProjectActive(localProjectID) else { throw SyncV2ContractStructureError.projectInactive }
        // snapshot 사이에 끝난 차단·해소도 이전 준비를 무효화해야 한다.
        let authorizeQueue = try await store.contractQueueAuthorization(localProjectID: localProjectID)
        let serverRead = structureAuthority.beginServerRead(context)
        do {
            let state = try await transport.fetchProjectState(projectID: serverProjectID)
            try authorizeQueue()
            structureAuthority.finishServerRead(context, token: serverRead, state: state)
            guard state == .active else { throw SyncV2ContractStructureError.projectInactive }
        } catch {
            structureAuthority.finishServerRead(context, token: serverRead, state: nil)
            if let error = error as? SyncV2HandshakeError {
                await handshakeService.forgetIfStale(error, expectedGeneration: handshakeRevision)
            }
            throw error
        }
        if generalOnly {
            guard handshake.projectSyncMode == .idBased else { throw SyncV2ContractStructureError.handshakeMissing }
            let recoveryDefaults = defaults
            let recoveryBindingEpoch = bindingEpoch
            let authorizeRecovery: @Sendable () throws -> Void = {
                try Task.checkCancellation()
                try authorizeQueue()
                try ContractPathGate.reserveStart(for: localProjectID, in: recoveryDefaults.value, revision: gateRevision) {
                    (authEpoch?.value ?? 0) == authRevision &&
                    (recoveryBindingEpoch?.value ?? 0) == bindingRevision && recoveryBindingEpoch?.isAvailable == true &&
                    handshakeEpoch.value == handshakeRevision && activityEpoch.value == activityRevision &&
                    GlobalSyncPreference.contractEpoch.value == globalRevision && GlobalSyncPreference.isEnabled(in: recoveryDefaults.value) &&
                    localProjectEpoch?.value == localRevision && localProjectEpoch?.isAvailable == true
                }
            }
            try authorizeRecovery()
            if let pending = try await store.recoverableGeneralContract(localProjectID: localProjectID) {
                let recoveryDeviceID = try await deviceIdentityProvider.currentIdentifier().uuid
                try pending.request.validateForTransmission(context: context, handshake: handshake,
                    writerDeviceID: recoveryDeviceID)
                if let report = try await recoverGeneralReceipt(pending, context: context, authorize: authorizeRecovery) {
                    return report
                }
            }
            if structureAuthority.proof(context, requiresActiveServer: false) == nil {
                try await restoreGeneralBaseline(context: context, authorizeQueue: authorizeQueue)
            }
        }
        guard let structureProof = structureAuthority.proof(context, requiresActiveServer: true)
        else { throw SyncV2ContractStructureError.structureAuthorityUnavailable }
        let preparation: SyncV2ContractPreparation?
        let authorizePreparation: (@Sendable () throws -> Void)?
        if let preparedBatchID {
            guard let value = try await store.contractPreparation(localProjectID: localProjectID),
                  try value.request.batchID == preparedBatchID,
                  value.requestSHA256 == reviewedRequestSHA256, value.accountID == context.accountID else {
                throw SyncV2ContractStructureError.invalidStoredRequest
            }
            try value.validateIntegrity()
            authorizePreparation = try await store.preparationQueueAuthorization(localProjectID: localProjectID, excluding: preparedBatchID)
            try await validatePreparationBaseline(value)
            preparation = value
        } else {
            guard reviewedRequestSHA256 == nil else { throw SyncV2ContractStructureError.invalidStoredRequest }
            preparation = nil
            authorizePreparation = nil
        }
        let writerDeviceID = try await deviceIdentityProvider.currentIdentifier().uuid
        let defaults = self.defaults
        let bindingEpoch = self.bindingEpoch
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try authorizeQueue()
            try authorizePreparation?()
            try ContractPathGate.reserveStart(for: localProjectID, in: defaults.value, revision: gateRevision) {
                (authEpoch?.value ?? 0) == authRevision &&
                (bindingEpoch?.value ?? 0) == bindingRevision &&
                (bindingEpoch?.isAvailable ?? false) &&
                handshakeEpoch.value == handshakeRevision && activityEpoch.value == activityRevision &&
                GlobalSyncPreference.contractEpoch.value == globalRevision &&
                GlobalSyncPreference.isEnabled(in: defaults.value) &&
                localProjectEpoch?.value == localRevision && localProjectEpoch?.isAvailable == true &&
                structureAuthority.validates(structureProof)
            }
        }
        try authorize()

        let uploadPermit:
            SyncV2ProjectUploadPullCoordinator.UploadPermit?
        if let uploadPullCoordinator {
            let queue = try await store.uploadQueueSnapshot(
                localProjectID: localProjectID
            )
            structureAuthority.observeQueue(queue, projectID: localProjectID)
            try authorize()
            guard let permit = await uploadPullCoordinator.beginUploadDrain(
                localProjectID: localProjectID,
                queue: queue
            ) else {
                throw SyncV2ContractStructureError.uploadPullGateBusy
            }
            uploadPermit = permit
        } else {
            throw SyncV2ContractStructureError.structureAuthorityUnavailable
        }
        var claimed: SyncV2PendingContractBatch?
        let started = SyncV2ContractEpoch()
        do {
            let pending: SyncV2PendingContractBatch
            if let preparation {
                try await store.ensurePreparationQueueIsIdle(localProjectID: localProjectID, excluding: preparedBatchID)
                try authorize()
                pending = try await store.claimPreparedContractStructure(preparation)
            } else if generalOnly {
                pending = try await store.claimNextGeneralContract(localProjectID: localProjectID)
            } else {
                pending = try await store.claimNextContractStructure(localProjectID: localProjectID)
            }
            claimed = pending
            guard pending.serverProjectID == serverProjectID,
                  pending.localProjectID == localProjectID else {
                throw SyncV2ContractStructureError.invalidStoredRequest
            }
            if let preparation {
                guard try pending.request.json.sha256Hex() == preparation.requestSHA256 else {
                    throw SyncV2ContractStructureError.invalidStoredRequest
                }
                let currentLocal = try await localDocuments(localProjectID)
                let snapshot = try await transport.fetchPreparationSnapshot(projectID: serverProjectID)
                guard try snapshot.fingerprint() == preparation.serverFingerprint,
                      try snapshot.validate(local: currentLocal) == preparation.localFingerprint else {
                    throw SyncV2ContractStructureError.preparationChanged
                }
            }
            try pending.request.validateForTransmission(context: context, handshake: handshake,
                                                        writerDeviceID: writerDeviceID)
            let response = try await transport.commit(
                request: pending.request.json,
                authorize: {
                    try authorize(); started.advance()
                    SyncV2RecoveryDiagnostics.record(stage: .contractUpload, event: .started,
                        projectID: localProjectID, operationID: pending.request.batchID)
                }
            )
            let status: SyncV2CommitStatus
            do {
                if pending.request.json.objectValue?["kind"] == .string("document_commit_request") {
                    status = try SyncV2Contract.validateDocumentCommitResponse(request: pending.request, response: response)
                } else {
                    status = try SyncV2Contract.validateAtomicStructureResponse(request: pending.request, response: response)
                }
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
            var report = SyncV2ContractSendReport(
                batchID: pending.request.batchID,
                status: status,
                operationCount: pending.request.orderedIntents.count
            )
            await finishUploadPermit(
                uploadPermit,
                localProjectID: localProjectID
            )
            do { try authorize() } catch { report.mayPresentCompletion = false }
            SyncV2RecoveryDiagnostics.record(stage: .contractUpload, event: .finished,
                projectID: localProjectID, operationID: pending.request.batchID)
            return report
        } catch {
            SyncV2RecoveryDiagnostics.record(stage: .contractUpload, event: .failed,
                projectID: localProjectID, operationID: claimed?.request.batchID)
            // 서버 응답 검증 실패는 위에서 응답과 함께 이미 남겼다.
            // 전송 단계 실패만 재시도 가능 상태로 돌린다.
            if let stale = error as? SyncV2HandshakeError {
                await handshakeService.forgetIfStale(stale, expectedGeneration: handshakeRevision)
            }
            if let contractError = error as? SyncV2ContractError {
                await handshakeService.forgetIfStale(.incompatible(contractError), expectedGeneration: handshakeRevision)
            }
            if let claimed, started.value == 0 {
                let failure: Error = generalOnly && error as? SyncV2ContractStructureError == .invalidStoredRequest
                    ? SyncV2ContractStructureError.invalidStoredRequest : SyncV2ContractStructureError.transmissionNotStarted
                await store.failContractStructure(claimed, error: failure, response: nil)
            } else if let claimed,
                      error as? SyncV2ContractStructureError == .transportRejected || error is SyncV2HandshakeError || error is CancellationError {
                await store.failContractStructure(
                    claimed,
                    error: error is CancellationError ? SyncV2ContractStructureError.transportRejected : error, response: nil
                )
            }
            if generalOnly, let claimed {
                await store.failContractStructure(claimed, error: SyncV2ContractStructureError.transportRejected, response: nil)
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

/// 동기화 완료 표시와 별개인 계약 구조 쓰기 증명이다. 읽기 실패나 늦은 응답이
/// 새 차단 상태를 지우지 못하도록 실제 pull/작품 조회별 토큰을 따로 둔다.
final class SyncV2ContractStructureAuthority: @unchecked Sendable {
    struct Proof: Sendable {
        let context: SyncV2HandshakeContext
        let revision: UInt64
        let requiresActiveServer: Bool
    }
    private struct Entry {
        var revision: UInt64 = 0
        var baselineToken: UUID?
        var baselineContext: SyncV2HandshakeContext?
        var baselineAllowed = false
        var queueBlocked = false
        var serverToken: UUID?
        var serverReadRevision: UInt64?
        var serverContext: SyncV2HandshakeContext?
        var serverState: SyncV2ContractServerProjectState?
    }
    private let lock = NSLock()
    private var entries: [ProjectID: Entry] = [:]

    func beginBaseline(_ context: SyncV2HandshakeContext) -> UUID {
        lock.withLock {
            var e = entries[context.localProjectID] ?? Entry()
            let token = UUID()
            e.revision &+= 1; e.baselineToken = token
            e.baselineContext = context; e.baselineAllowed = false
            entries[context.localProjectID] = e
            return token
        }
    }
    func finishBaseline(_ context: SyncV2HandshakeContext, token: UUID, allowed: Bool) {
        lock.withLock {
            guard var e = entries[context.localProjectID], e.baselineToken == token else { return }
            e.revision &+= 1; e.baselineToken = nil; e.baselineAllowed = allowed
            entries[context.localProjectID] = e
        }
    }
    func observeQueue(_ queue: SyncV2UploadQueueSnapshot, projectID: ProjectID) {
        lock.withLock {
            var e = entries[projectID] ?? Entry()
            let blocked = queue.blockedCount > 0 || queue.conflictCount > 0
            if e.queueBlocked != blocked { e.revision &+= 1 }
            e.queueBlocked = blocked; entries[projectID] = e
        }
    }
    func beginServerRead(_ context: SyncV2HandshakeContext) -> UUID {
        lock.withLock {
            var e = entries[context.localProjectID] ?? Entry()
            let token = UUID()
            e.revision &+= 1; e.serverReadRevision = e.revision; e.serverToken = token; e.serverContext = context; e.serverState = nil
            entries[context.localProjectID] = e
            return token
        }
    }
    func finishServerRead(_ context: SyncV2HandshakeContext, token: UUID, state: SyncV2ContractServerProjectState?) {
        lock.withLock {
            guard var e = entries[context.localProjectID], e.serverToken == token, e.serverReadRevision == e.revision else { return }
            e.revision &+= 1; e.serverToken = nil; e.serverState = state
            entries[context.localProjectID] = e
        }
    }
    func proof(_ context: SyncV2HandshakeContext, requiresActiveServer: Bool) -> Proof? {
        lock.withLock {
            let e = entries[context.localProjectID] ?? Entry()
            guard allows(e, context: context, requiresActiveServer: requiresActiveServer) else { return nil }
            return Proof(context: context, revision: e.revision, requiresActiveServer: requiresActiveServer)
        }
    }
    func validates(_ proof: Proof) -> Bool {
        lock.withLock {
            let e = entries[proof.context.localProjectID] ?? Entry()
            return e.revision == proof.revision && allows(e, context: proof.context, requiresActiveServer: proof.requiresActiveServer)
        }
    }
    private func allows(_ e: Entry, context: SyncV2HandshakeContext, requiresActiveServer: Bool) -> Bool {
        guard e.baselineAllowed, e.baselineContext == context, !e.queueBlocked else { return false }
        if requiresActiveServer { return e.serverContext == context && e.serverState == .active }
        return e.serverContext != context || e.serverState == nil || e.serverState == .active
    }
}

enum SyncV2ContractServerProjectState: String, Decodable, Sendable {
    case active, trashed, purged
}

struct SyncV2ContractProjectStatus: Decodable {
    let projectID: UUID
    let state: SyncV2ContractServerProjectState
    enum CodingKeys: String, CodingKey { case projectID = "project_id", state }

    static func decode(_ data: Data, expectedProjectID: UUID) throws -> SyncV2ContractServerProjectState {
        let status = try JSONDecoder().decode(Self.self, from: data)
        guard status.projectID == expectedProjectID else { throw SyncV2ContractStructureError.projectNotConnected }
        return status.state
    }
}
