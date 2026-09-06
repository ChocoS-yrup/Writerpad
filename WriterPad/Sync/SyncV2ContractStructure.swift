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
    case structureAuthorityUnavailable
    case projectInactive
}

struct SyncV2AtomicStructureParameters: Encodable, Equatable, Sendable {
    let request: SyncV2JSON

    enum CodingKeys: String, CodingKey {
        case request = "p_request"
    }
}

protocol SyncV2AtomicStructureTransporting: Sendable {
    func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState
    func commit(request: SyncV2JSON) async throws -> SyncV2JSON
    func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON
}

extension SyncV2AtomicStructureTransporting {
    func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState {
        throw SyncV2ContractStructureError.unavailable
    }
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
    var mayPresentCompletion: Bool = true
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
    private let structureAuthority: SyncV2ContractStructureAuthority?
    private let localProjectEpoch: SyncV2ContractEpoch?
    private let isLocalProjectActive: @Sendable (ProjectID) async throws -> Bool
    private let bindingEpoch: SyncV2ContractEpoch?
    private let defaults: UserDefaults

    init(
        store: LazySyncV2ProjectBindingStore,
        handshakeService: SyncV2HandshakeService?,
        authenticationService: any AuthenticationServicing,
        defaults: UserDefaults = .standard,
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
        let localProjectEpoch = self.localProjectEpoch
        let localRevision = localProjectEpoch?.value
        guard let context, let structureAuthority,
              let proof = structureAuthority.proof(context, requiresActiveServer: false),
              (try? await isLocalProjectActive(batch.projectID)) == true,
              localProjectEpoch?.isAvailable == true
        else { return .localSavedButNotQueued(reason: "작품 활성 상태와 구조 기준을 다시 확인해야 합니다.") }
        let defaults = ContractDefaults(value: self.defaults)
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
    func contractQueueAuthorization(localProjectID: ProjectID) async throws -> @Sendable () throws -> Void
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
    private let structureAuthority: SyncV2ContractStructureAuthority?
    private let localProjectEpoch: SyncV2ContractEpoch?
    private let isLocalProjectActive: @Sendable (ProjectID) async throws -> Bool
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
        deviceIdentityProvider: (any DeviceIdentityProviding)? = nil,
        structureAuthority: SyncV2ContractStructureAuthority? = nil,
        localProjectEpoch: SyncV2ContractEpoch? = nil,
        isLocalProjectActive: @escaping @Sendable (ProjectID) async throws -> Bool = { _ in false }
    ) {
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
        guard let structureProof = structureAuthority.proof(context, requiresActiveServer: true)
        else { throw SyncV2ContractStructureError.structureAuthorityUnavailable }
        let writerDeviceID = try await deviceIdentityProvider.currentIdentifier().uuid
        let defaults = ContractDefaults(value: self.defaults)
        let bindingEpoch = self.bindingEpoch
        let authorize: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try authorizeQueue()
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
                authorize: {
                    try authorize(); started.advance()
                    SyncV2RecoveryDiagnostics.record(stage: .contractUpload, event: .started,
                        projectID: localProjectID, operationID: pending.request.batchID)
                }
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
