import Foundation
import Supabase

enum SyncV2TransitionProfile {
    // SHA-256 of the exact UTF-8 extension file, not a replacement protocol pin.
    static let sha256 = "5c5736ec9bda42f80b75dd8f863bb01b0bba8cef1ebe96675333db634b560c81"
    static let storageV2SHA256 = "07e2e557921c17750f960d6b88b72dadb15d3aee45658d5260a3494607012b77"
    static func sha256(for contract: SyncV2ReleasedContract) -> String {
        contract == .v02 ? sha256 : storageV2SHA256
    }
}

struct SyncV2TransitionPlan: Equatable, Sendable {
    let mode: SyncV2ProjectSyncMode
    let epoch: Int
    let payload: SyncV2JSON
    let handshake: SyncV2ValidatedHandshake?

    init(_ json: SyncV2JSON, projectID: UUID, accountID: UUID, deviceID: UUID,
         contract: SyncV2ReleasedContract = .v02) throws {
        let profile = SyncV2TransitionProfile.sha256(for: contract)
        guard let fields = json.objectValue,
              fields["profile_sha256"] == .string(profile),
              fields["project_id"] == .string(projectID.uuidString.lowercased()),
              let modeValue = fields["mode"]?.stringValue,
              let mode = SyncV2ProjectSyncMode(rawValue: modeValue),
              let epoch = fields["epoch"]?.intValue,
              (mode == .legacy ? epoch == 0 : epoch == 1),
              let payload = fields["payload"] else { throw SyncV2ContractError("TRANSITION_UNSUPPORTED") }
        if contract == .v03 || fields["handshake"] != nil {
            guard fields["target_contract_sha256"] == .string(contract.sha256), let wire = fields["handshake"]
            else { throw SyncV2ContractError("TRANSITION_UNSUPPORTED") }
            let response = try JSONDecoder().decode(SyncV2HandshakeResponse.self, from: JSONEncoder().encode(wire))
            let verified = try SyncV2Contract.readHandshakeCompatibility(response, contract: contract)
            guard verified.serverProjectID == projectID, verified.projectSyncMode == mode, verified.migrationEpoch == epoch
            else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            self.handshake = verified
        } else { self.handshake = nil }
        if mode == .migrating {
            guard fields["started_by_device_id"] == .string(deviceID.uuidString.lowercased()),
                  fields["started_by_user_id"] == .string(accountID.uuidString.lowercased())
            else { throw SyncV2ContractError("MIGRATION_LOCKED") }
        }
        if mode != .idBased {
            guard let p = payload.objectValue,
                  p["profile_sha256"] == .string(profile),
                  let baseline = p["baseline_sha256"]?.stringValue,
                  SyncV2Contract.isSHA256Hex(baseline),
                  let documents = p["documents"]?.arrayValue, documents.count <= 1000,
                  let orders = p["orders"]?.arrayValue, orders.count <= 1000
            else { throw SyncV2ContractError("TRANSITION_UNSUPPORTED") }
            if contract == .v03 && p["target_contract_sha256"] != .string(contract.sha256) {
                throw SyncV2ContractError("TRANSITION_UNSUPPORTED")
            }
        }
        self.mode = mode; self.epoch = epoch; self.payload = payload
    }
}

protocol SyncV2TransitionTransporting: Sendable {
    func call(_ rpc: String, parameters: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON
}

struct LiveSyncV2TransitionTransport: SyncV2TransitionTransporting {
    let http: SyncV2ContractHTTPClient
    init(client: SupabaseClient, configuration: SupabasePublicConfiguration) {
        http = SyncV2ContractHTTPClient(configuration: configuration, accessToken: { client.auth.currentSession?.accessToken })
    }
    func call(_ rpc: String, parameters: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        guard ["get_project_sync_transition_plan", "get_project_sync_transition_plan_for_contract", "prepare_project_sync_transition",
               "validate_project_sync_migration", "complete_project_sync_migration"].contains(rpc)
        else { throw SyncV2ContractError.invalidArgument }
        if rpc == "prepare_project_sync_transition" || rpc == "complete_project_sync_migration" {
            try ReceiveValidationPolicy.current.requireSending()
        }
        do {
            let data = try await http.call(rpc: rpc, body: JSONEncoder().encode(parameters), authorize: authorize)
            return try JSONDecoder().decode(SyncV2JSON.self, from: data)
        } catch let error as HTTPError {
            if let remote = try? JSONDecoder().decode(PostgrestError.self, from: error.data),
               remote.code == "P0001", remote.message == "TRANSITION_BASELINE_CHANGED" {
                throw SyncV2ContractError("TRANSITION_BASELINE_CHANGED")
            }
            throw error
        }
    }
}

struct SyncV2TransitionIdentity: Codable, Equatable, Sendable {
    let localID: UUID
    let serverID: UUID
    let accountID: UUID
    let deviceID: UUID
}

struct SyncV2TransitionAuthority: Sendable {
    let identity: SyncV2TransitionIdentity
    let check: @Sendable () throws -> Void
}

/// A separate journal: conversion never enters the ordinary sending queue or
/// opens its gate. An uncertain request is retained byte-for-byte across restart.
actor SyncV2TransitionJournal {
    static let shared = SyncV2TransitionJournal(root: URL.applicationSupportDirectory.appendingPathComponent("SyncProjectTransitions"))
    private let root: URL
    struct Entry: Codable, Equatable, Sendable {
        let identity: SyncV2TransitionIdentity
        let request: SyncV2JSON
    }
    init(root: URL) { self.root = root }
    private func url(_ identity: SyncV2TransitionIdentity) -> URL {
        root.appendingPathComponent([identity.accountID, identity.localID, identity.serverID, identity.deviceID]
            .map { $0.uuidString.lowercased() }.joined(separator: "_") + ".json")
    }
    func load(_ identity: SyncV2TransitionIdentity) throws -> Entry? {
        let path = url(identity)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: path))
        guard entry.identity == identity else { throw SyncV2ContractError("TRANSITION_JOURNAL_MISMATCH") }
        return entry
    }
    func save(_ entry: Entry) throws {
        if let existing = try load(entry.identity) {
            guard existing == entry else { throw SyncV2ContractError("TRANSITION_JOURNAL_MISMATCH") }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url(entry.identity), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func remove(_ identity: SyncV2TransitionIdentity) throws {
        let path = url(identity)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

@MainActor
final class SyncV2ProjectTransitionModel: ObservableObject {
    @Published private(set) var plan: SyncV2TransitionPlan?
    @Published private(set) var busy = false
    @Published private(set) var validated = false
    @Published private(set) var hasPendingRequest = false
    @Published private(set) var message = "전체 동기화와 이 작품의 일반 동기화를 끈 뒤 계획을 확인하세요. 조회만으로는 전환하지 않습니다."
    private let transport: any SyncV2TransitionTransporting
    private let journal: SyncV2TransitionJournal
    let contract: SyncV2ReleasedContract
    private let authority: @MainActor (Bool) async throws -> SyncV2TransitionAuthority
    private let screen = SyncV2ContractEpoch()
    private var plannedIdentity: SyncV2TransitionIdentity?
    private var plannedCheck: (@Sendable () throws -> Void)?

    init(transport: any SyncV2TransitionTransporting, journal: SyncV2TransitionJournal,
         contract: SyncV2ReleasedContract = .v02,
         authority: @escaping @MainActor (Bool) async throws -> SyncV2TransitionAuthority) {
        self.transport = transport; self.journal = journal; self.authority = authority; self.contract = contract
    }
    func invalidate() {
        screen.advance(); plan = nil; validated = false; plannedIdentity = nil; plannedCheck = nil
    }
    private func checkedAuthority(forWrite: Bool = false) async throws -> SyncV2TransitionAuthority {
        let revision = screen.value
        let value = try await authority(forWrite)
        let screen = screen
        let check: @Sendable () throws -> Void = {
            try Task.checkCancellation()
            try value.check()
            guard screen.value == revision else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
        }
        try check()
        return .init(identity: value.identity, check: check)
    }
    private func projectParameters(_ identity: SyncV2TransitionIdentity) -> SyncV2JSON {
        .object(["p_project_id": .string(identity.serverID.uuidString.lowercased())])
    }
    private func readPlan(_ auth: SyncV2TransitionAuthority) async throws {
        let rpc = contract == .v02 ? "get_project_sync_transition_plan" : "get_project_sync_transition_plan_for_contract"
        let parameters: SyncV2JSON = contract == .v02 ? projectParameters(auth.identity) : .object([
            "p_project_id": .string(auth.identity.serverID.uuidString.lowercased()),
            "p_target_contract_sha256": .string(contract.sha256)])
        let result = try await transport.call(rpc, parameters: parameters, authorize: auth.check)
        try auth.check()
        let value = try SyncV2TransitionPlan(result, projectID: auth.identity.serverID,
            accountID: auth.identity.accountID, deviceID: auth.identity.deviceID, contract: contract)
        let pending = try await journal.load(auth.identity)
        try auth.check()
        if let pending {
            guard pending.request.objectValue?["batch"]?.objectValue?["canonical_contract_sha256"] == .string(contract.sha256),
                  pending.request.objectValue?["ordered_intents"]?.arrayValue?.first?.objectValue?["payload"]?.objectValue?["profile_sha256"]
                    == .string(SyncV2TransitionProfile.sha256(for: contract))
            else { throw SyncV2ContractError("TRANSITION_JOURNAL_MISMATCH") }
        }
        plan = value; plannedIdentity = auth.identity; plannedCheck = auth.check; validated = false
        hasPendingRequest = pending != nil
        if value.mode == .idBased {
            try await journal.remove(auth.identity)
            try auth.check()
            hasPendingRequest = false
            message = contract == .v03
                ? "ID_BASED · 계약 0.3 / storage-name-v2 handshake 확인됨. 작품 설정에서 계약 0.3을 선택하고 일반 동기화 준비를 새로 확인하세요. 이 화면에서는 활성화하지 않습니다."
                : "ID_BASED 확인됨. 전환은 완료 상태이며 일반 동기화는 별도로 활성화하세요."
        } else {
            message = pending != nil ? "저장된 전환 요청이 있습니다. 같은 요청으로 결과를 확인·재시도할 수 있습니다."
                : "\(value.mode.rawValue) · 구조 초기화 \(value.payload.objectValue?["documents"]?.arrayValue?.count ?? 0)개. 본문과 과거 버전은 변경하지 않습니다."
        }
    }
    func inspect() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        do { try await readPlan(checkedAuthority()) }
        catch { fail(error) }
    }
    func prepare() async {
        guard !busy, let plan, plan.mode != .idBased else { return }; busy = true
        defer { busy = false }
        do {
            let auth = try await checkedAuthority(forWrite: true)
            try plannedCheck?()
            guard plannedIdentity == auth.identity else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            let stored = try await journal.load(auth.identity)
            let request: SyncV2ContractRequest
            if let stored {
                request = try SyncV2ContractRequest(storedJSON: stored.request)
            } else {
                request = try SyncV2Contract.buildAtomicStructureRequest(projectID: auth.identity.serverID,
                    projectSyncMode: .migrating, migrationEpoch: 1, writerDeviceID: auth.identity.deviceID,
                    orderedIntents: [.init(entityKind: .project, entityID: auth.identity.serverID,
                        intentKind: .migrate, payload: plan.payload)],
                    clientBuildID: "writerpad-ipad-transition-contract-\(contract.version)", contract: contract)
                try await journal.save(.init(identity: auth.identity, request: request.json))
            }
            // Revalidate the disk record, not only its filename, before transmission.
            let fields = request.json.objectValue
            let batch = fields?["batch"]?.objectValue
            let intent = request.orderedIntents.first?.objectValue
            guard fields?["kind"] == .string("atomic_structure_commit_request"),
                  fields?["project_id"] == .string(auth.identity.serverID.uuidString.lowercased()),
                  fields?["project_sync_mode"] == .string("MIGRATING"), fields?["migration_epoch"] == .int(1),
                  batch?["writer_device_id"] == .string(auth.identity.deviceID.uuidString.lowercased()),
                  batch?["canonical_contract_sha256"] == .string(contract.sha256),
                  batch?["contract_version"] == .string(contract.version), batch?["sync_protocol_version"] == .int(3),
                  batch?["client_capabilities"] == .array(contract.clientCapabilities.map { .string($0) }),
                  request.orderedIntents.count == 1,
                  intent?["entity_kind"] == .string("project"), intent?["intent_kind"] == .string("migrate"),
                  intent?["entity_id"] == fields?["project_id"], intent?["base_revision"] == .int(0), intent?["sequence"] == .int(1),
                  intent?["batch_id"] == batch?["batch_id"],
                  UUID(uuidString: intent?["operation_id"]?.stringValue ?? "") != nil,
                  try SyncV2JSON.array(request.orderedIntents).sha256Hex() == request.batchPayloadSHA256,
                  try intent?["payload"]?.sha256Hex() == intent?["payload_sha256"]?.stringValue,
                  intent?["payload"]?.objectValue?["profile_sha256"] == .string(SyncV2TransitionProfile.sha256(for: contract)),
                  (contract == .v02 || intent?["payload"]?.objectValue?["target_contract_sha256"] == .string(contract.sha256))
            else { throw SyncV2ContractError("TRANSITION_JOURNAL_MISMATCH") }
            try auth.check()
            validated = false; hasPendingRequest = true
            let result: SyncV2JSON
            do {
                result = try await transport.call("prepare_project_sync_transition",
                    parameters: .object(["p_request": request.json]), authorize: auth.check)
            } catch let error as SyncV2ContractError where error.code == "TRANSITION_BASELINE_CHANGED" {
                // A definitive SQL rejection occurs before begin, unlike a timeout.
                try auth.check()
                try await journal.remove(auth.identity)
                hasPendingRequest = false
                throw error
            }
            _ = try SyncV2Contract.validateAtomicStructureResponse(request: request, response: result)
            try auth.check()
            try await readPlan(auth)
            if self.plan?.mode == .migrating {
                message = "구조 준비 완료 · 아직 MIGRATING입니다. 검증 후 별도의 완료 버튼을 눌러 주세요."
            }
        } catch { fail(error) }
    }
    func validate() async {
        guard !busy, plan?.mode == .migrating else { return }; busy = true
        defer { busy = false }
        do {
            let auth = try await checkedAuthority()
            try plannedCheck?()
            guard plannedIdentity == auth.identity else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            let result = try await transport.call("validate_project_sync_migration", parameters: projectParameters(auth.identity), authorize: auth.check)
            try auth.check()
            guard result.objectValue?["project_id"] == .string(auth.identity.serverID.uuidString.lowercased()),
                  result.objectValue?["valid"] == .bool(true), result.objectValue?["issues"] == .array([])
            else { throw SyncV2ContractError("TRANSITION_VALIDATION_FAILED") }
            validated = true; message = "검증 통과. ‘전환 완료’를 명시적으로 선택해야 ID_BASED로 변경됩니다."
        } catch { fail(error) }
    }
    func complete() async {
        guard !busy, validated, plan?.mode == .migrating else { return }; busy = true
        defer { busy = false }
        do {
            let auth = try await checkedAuthority(forWrite: true)
            try plannedCheck?()
            guard plannedIdentity == auth.identity else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            let result = try await transport.call("complete_project_sync_migration", parameters: .object([
                "p_project_id": .string(auth.identity.serverID.uuidString.lowercased()),
                "p_writer_device_id": .string(auth.identity.deviceID.uuidString.lowercased()), "p_migration_epoch": .int(1)]), authorize: auth.check)
            try auth.check()
            guard result.objectValue?["status"] == .string("id_based"),
                  result.objectValue?["project_id"] == .string(auth.identity.serverID.uuidString.lowercased()),
                  result.objectValue?["migration_epoch"] == .int(1)
            else { throw SyncV2ContractError("TRANSITION_VALIDATION_FAILED") }
            try await readPlan(auth)
        } catch { fail(error) }
    }
    private func fail(_ error: Error) {
        plan = nil; validated = false; plannedIdentity = nil; plannedCheck = nil
        if (error as? SyncV2ContractError)?.code == "TRANSITION_BASELINE_CHANGED" {
            message = "계획 이후 서버 상태가 바뀌어 시작 전에 거부됐습니다. 거부된 요청은 제거했으니 새 계획을 조회해 주세요."
            return
        }
        message = "진행을 확인하지 못했습니다. 계획을 다시 조회하세요. 응답 유실 시 저장된 요청은 유지되며 자동 완료하지 않습니다. (\((error as? SyncV2ContractError)?.code ?? "SERVER_OR_NETWORK_UNAVAILABLE"))"
    }
}
