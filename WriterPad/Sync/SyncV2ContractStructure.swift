import Foundation
import Supabase

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
}

struct SyncV2AtomicStructureParameters: Encodable, Equatable, Sendable {
    let request: SyncV2JSON

    enum CodingKeys: String, CodingKey {
        case request = "p_request"
    }
}

protocol SyncV2AtomicStructureTransporting: Sendable {
    func commit(request: SyncV2JSON) async throws -> SyncV2JSON
}

actor LiveSyncV2AtomicStructureTransport:
    SyncV2AtomicStructureTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func commit(request: SyncV2JSON) async throws -> SyncV2JSON {
        do {
            let response: PostgrestResponse<SyncV2JSON> = try await client
                .rpc(
                    "atomic_structure_commit",
                    params: SyncV2AtomicStructureParameters(request: request)
                )
                .execute()
            return response.value
        } catch {
            throw SyncV2ContractStructureError.transportRejected
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
    private let defaults: UserDefaults

    init(
        store: LazySyncV2ProjectBindingStore,
        handshakeService: SyncV2HandshakeService?,
        authenticationService: any AuthenticationServicing,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.defaults = defaults
    }

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        await store.requirement(for: projectID)
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
            serverProjectID: serverProjectID
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
        do {
            let operationIDs = try await store.enqueueContractStructure(
                batch,
                binding: binding,
                handshake: handshake
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

/// 자동 동기 토글과 분리된 진단용 1회 전송기다. 전송 직전에 관문과
/// 핸드셰크를 다시 확인하고, 로컬에 먼저 저장된 불변 요청만 보낸다.
actor SyncV2ContractStructureSender {
    private let store: LazySyncV2ProjectBindingStore
    private let transport: any SyncV2AtomicStructureTransporting
    private let handshakeService: SyncV2HandshakeService
    private let authenticationService: any AuthenticationServicing
    private let defaults: UserDefaults

    init(
        store: LazySyncV2ProjectBindingStore,
        transport: any SyncV2AtomicStructureTransporting,
        handshakeService: SyncV2HandshakeService,
        authenticationService: any AuthenticationServicing,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.transport = transport
        self.handshakeService = handshakeService
        self.authenticationService = authenticationService
        self.defaults = defaults
    }

    func sendNext(
        localProjectID: ProjectID
    ) async throws -> SyncV2ContractSendReport {
        guard ContractPathGate.isOpen(for: localProjectID, in: defaults)
        else { throw SyncV2ContractStructureError.gateClosed }
        guard let binding = try await store.binding(for: localProjectID),
              let serverProjectID = binding.serverProjectID,
              binding.kind != .localOnly
        else { throw SyncV2ContractStructureError.projectNotConnected }
        let context = SyncV2HandshakeContext.make(
            authenticationState: await authenticationService.currentState(),
            localProjectID: localProjectID,
            serverProjectID: serverProjectID
        )
        guard await handshakeService.usesContractStructure(
            context: context,
            gateIsOpen: true
        ) else { throw SyncV2ContractStructureError.handshakeMissing }

        let pending = try await store.claimNextContractStructure(
            localProjectID: localProjectID
        )
        do {
            let response = try await transport.commit(
                request: pending.request.json
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
            return SyncV2ContractSendReport(
                batchID: pending.request.batchID,
                status: status,
                operationCount: pending.request.orderedIntents.count
            )
        } catch {
            // 서버 응답 검증 실패는 위에서 응답과 함께 이미 남겼다.
            // 전송 단계 실패만 재시도 가능 상태로 돌린다.
            if error as? SyncV2ContractStructureError
                == .transportRejected {
                await store.failContractStructure(
                    pending,
                    error: error
                )
            }
            throw error
        }
    }
}
