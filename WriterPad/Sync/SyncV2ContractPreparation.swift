import Foundation
import Supabase

/// Windows가 검증한 한 작품의 좁은 준비 범위다. 다른 작품·구조로 일반화하지 않는다.
enum SyncV2EmptyVolumeReview {
    static let stagingHost = "mhpnszcorfzrvhyondxr.supabase.co"
    static let projectID = UUID(uuidString: "1bd47431-0773-482c-8eb5-ac9e2952b6f4")!
    static let parentID = UUID(uuidString: "14df4a55-b7cd-4790-bc53-f84148418c0f")!
    static let volumeID = UUID(uuidString: "c0b43fc4-89a0-4a5a-b140-768a62cfde5a")!
    static let name = "2권"
}

struct SyncV2PreparationSnapshot: Codable, Equatable, Sendable {
    let folders: [SyncV2JSON]
    let documents: [SyncV2JSON]
    let treeOrders: [SyncV2JSON]

    func fingerprint() throws -> String {
        func sorted(_ rows: [SyncV2JSON]) throws -> SyncV2JSON {
            .array(try rows.sorted { try $0.canonicalJSON() < $1.canonicalJSON() })
        }
        return try SyncV2JSON.object([
            "folders": sorted(folders), "documents": sorted(documents), "tree_orders": sorted(treeOrders)
        ]).sha256Hex()
    }

    /// UUID와 실제 LEGACY 경로를 함께 확인한다. null parent를 최상위로 추정하지 않는다.
    func validate(local: [DocumentNode]) throws -> String {
        let scope = SyncV2EmptyVolumeReview.self
        guard folders.count == 11, documents.count == 26, treeOrders.isEmpty else {
            throw SyncV2ContractStructureError.unsupportedPreparationBaseline
        }
        var folderPaths: [UUID: String] = [:]
        var pending = folders
        for _ in 0..<11 {
            var rest: [SyncV2JSON] = []
            for row in pending {
                guard let f = row.objectValue,
                      let id = f["folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      f["project_id"]?.stringValue == scope.projectID.uuidString.lowercased(),
                      let name = f["name"]?.stringValue, (f["revision"]?.intValue ?? 0) > 0,
                      f["is_deleted"] == .bool(false), folderPaths[id] == nil else {
                    throw SyncV2ContractStructureError.unsupportedPreparationBaseline
                }
                if f["parent_folder_id"] == .null {
                    folderPaths[id] = name
                } else if let parent = f["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                          let path = folderPaths[parent] {
                    folderPaths[id] = path + "/" + name
                } else { rest.append(row) }
            }
            pending = rest
            if rest.isEmpty { break }
        }
        let fixedPaths = Set(BinderFixedCategory.allCases.map { $0.relativePath.rawValue })
            .union(["메인", "메인/원고/1권"])
        guard pending.isEmpty, folderPaths.count == 11, Set(folderPaths.values) == fixedPaths,
              folderPaths[scope.parentID] == "메인/원고",
              folderPaths[scope.volumeID] == "메인/원고/1권" else {
            throw SyncV2ContractStructureError.unsupportedPreparationBaseline
        }
        var remotePaths = folderPaths
        var hiddenCount = 0
        for row in documents {
            guard let d = row.objectValue,
                  let id = d["document_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  d["project_id"]?.stringValue == scope.projectID.uuidString.lowercased(),
                  let path = d["relative_path"]?.stringValue,
                  (d["revision"]?.intValue ?? 0) > 0, d["is_deleted"] == .bool(false),
                  d["parent_folder_id"] == .null, d["name"] == .null,
                  d["structure_revision"] == .null else {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            if path == syncV2TreeOrderPath { hiddenCount += 1; continue }
            guard path.hasPrefix("메인/원고/1권/"), path.split(separator: "/").count == 4,
                  remotePaths[id] == nil else { throw SyncV2ContractStructureError.unsupportedPreparationBaseline }
            remotePaths[id] = path
        }
        guard hiddenCount == 1, remotePaths.count == 36,
              Set(remotePaths.values).count == 36 else {
            throw SyncV2ContractStructureError.unsupportedPreparationBaseline
        }
        var localPaths: [UUID: String] = [:]
        var localRows: [SyncV2JSON] = []
        for node in local {
            guard case .active = node.deletionStatus else { continue }
            let id = node.id.rawValue
            guard localPaths[id] == nil else { throw SyncV2ContractStructureError.unsupportedPreparationBaseline }
            localPaths[id] = node.relativePath.rawValue
            if fixedPaths.contains(node.relativePath.rawValue), node.userOrder >= BinderOrderingPolicy.customizedRootOrderOffset {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            let isFolder = folderPaths[id] != nil
            guard (node.kind == .folder) == isFolder else {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            let expectedParent = folderPaths.first { $0.value == node.relativePath.rawValue.split(separator: "/").dropLast().joined(separator: "/") }?.key
            guard node.parentID?.rawValue == expectedParent else {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            localRows.append(.object(["id": .string(id.uuidString.lowercased()),
                "path": .string(node.relativePath.rawValue), "order": .int(node.userOrder)]))
        }
        guard localPaths == remotePaths else { throw SyncV2ContractStructureError.unsupportedPreparationBaseline }
        // 권/화 자연 정렬 이외의 사용자 정렬이 바뀌어도 이전 검토를 재사용하지 않는다.
        return try SyncV2JSON.array(localRows.sorted { try $0.canonicalJSON() < $1.canonicalJSON() }).sha256Hex()
    }
}

struct SyncV2ContractPreparation: Codable, Equatable, Sendable {
    let localProjectID: ProjectID
    let accountID: UUID
    let serverFingerprint: String
    let localFingerprint: String
    let requestJSON: SyncV2JSON
    let requestSHA256: String
    let preparedAt: Date

    var request: SyncV2ContractRequest {
        get throws { try SyncV2ContractRequest(storedJSON: requestJSON) }
    }

    func validateIntegrity() throws {
        let request = try request
        let scope = SyncV2EmptyVolumeReview.self
        guard try requestJSON.sha256Hex() == requestSHA256,
              requestJSON.objectValue?["project_id"]?.stringValue == scope.projectID.uuidString.lowercased(),
              request.orderedIntents.count == 2,
              requestJSON.objectValue?["batch"]?.objectValue?["client_build_id"]?.stringValue == SyncV2Contract.clientBuildID else {
            throw SyncV2ContractStructureError.invalidStoredRequest
        }
        let first = request.orderedIntents[0].objectValue, second = request.orderedIntents[1].objectValue
        guard let folder = first?["entity_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let order = second?["entity_id"]?.stringValue.flatMap(UUID.init(uuidString:)), folder != order,
              first?["entity_kind"] == .string("folder"), first?["intent_kind"] == .string("create"),
              first?["sequence"] == .int(1), first?["base_revision"] == .int(0),
              first?["payload"] == .object(["parent_folder_id": .string(scope.parentID.uuidString.lowercased()), "name": .string(scope.name)]),
              second?["entity_kind"] == .string("tree_order"), second?["intent_kind"] == .string("reorder"),
              second?["sequence"] == .int(2), second?["base_revision"] == .int(0),
              second?["payload"] == .object(["parent_folder_id": .string(scope.parentID.uuidString.lowercased()),
                  "children": .array([.string(scope.volumeID.uuidString.lowercased()), .string(folder.uuidString.lowercased())])]) else {
            throw SyncV2ContractStructureError.invalidStoredRequest
        }
        let ids = [request.batchID, folder, order] + request.orderedIntents.compactMap { $0.objectValue?["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) }
        guard ids.count == 5, Set(ids).count == 5,
              !ids.contains(scope.parentID), !ids.contains(scope.volumeID), !ids.contains(scope.projectID),
              try SyncV2JSON.array(request.orderedIntents).sha256Hex() == request.batchPayloadSHA256 else {
            throw SyncV2ContractStructureError.invalidStoredRequest
        }
        for intent in request.orderedIntents {
            guard let fields = intent.objectValue, let payload = fields["payload"],
                  fields["batch_id"] == .string(request.batchID.uuidString.lowercased()),
                  try payload.sha256Hex() == fields["payload_sha256"]?.stringValue else {
                throw SyncV2ContractStructureError.invalidStoredRequest
            }
        }
    }

    func exportData() throws -> Data {
        try validateIntegrity()
        // 원고 경로·계정·본문은 내보내지 않고, 송신 요청과 검토 지문만 공유한다.
        let json = SyncV2JSON.object(["kind": .string("writerpad_contract_preparation_review"),
            "request": requestJSON, "request_sha256": .string(requestSHA256),
            "server_structure_sha256": .string(serverFingerprint), "local_structure_sha256": .string(localFingerprint),
            "prepared_at": .string(ISO8601DateFormatter().string(from: preparedAt))])
        return Data(try json.canonicalJSON().utf8)
    }
}

/// 재전송 없이도 서버가 이미 적용한 원본 응답임을 대조할 수 있는 읽기 기록이다.
struct SyncV2GeneralCommitReceipt: Equatable, Sendable {
    let batch: SyncV2JSON
    let result: SyncV2JSON

    func validatedResponse(for pending: SyncV2PendingContractBatch, accountID: UUID) throws -> SyncV2JSON {
        let request = pending.request.json.objectValue
        guard let storedBatch = batch.objectValue, let originalBatch = request?["batch"]?.objectValue,
              let storedResult = result.objectValue,
              storedBatch["project_id"] == request?["project_id"],
              storedBatch["writer_user_id"] == .string(accountID.uuidString.lowercased()),
              storedBatch["project_sync_mode"] == request?["project_sync_mode"],
              storedBatch["migration_epoch"] == request?["migration_epoch"],
              storedBatch["request_sha256"] == .string(try pending.request.json.sha256Hex()),
              storedResult["batch_id"] == originalBatch["batch_id"],
              storedResult["applied"] == .bool(true), let response = storedResult["response"],
              storedResult["response_sha256"] == .string(try response.sha256Hex()) else {
            throw SyncV2ContractStructureError.invalidRecoveryReceipt
        }
        for key in ["batch_id", "writer_device_id", "client_build_id", "sync_protocol_version", "contract_version",
                    "canonical_contract_sha256", "client_capabilities", "batch_payload_sha256"] {
            guard let expected = originalBatch[key], storedBatch[key] == expected else {
                throw SyncV2ContractStructureError.invalidRecoveryReceipt
            }
        }
        if request?["kind"] == .string("document_commit_request") {
            try SyncV2Contract.validateDocumentCommitResponse(request: pending.request, response: response)
        } else {
            try SyncV2Contract.validateAtomicStructureResponse(request: pending.request, response: response)
        }
        return response
    }
}

/// 행 수까지 확인해서 API의 응답 제한을 완전한 기준으로 오인하지 않는다.
struct LiveSyncV2PreparationMetadata: Sendable {
    let client: SupabaseClient
    let serverURL: URL

    func fetchGeneralReceipt(projectID: UUID, batchID: UUID) async throws -> SyncV2GeneralCommitReceipt? {
        guard serverURL.scheme == "https" else { throw SyncV2ContractStructureError.unavailable }
        let batches = try await client.from("sync_batches").select(
            "batch_id,project_id,writer_user_id,writer_device_id,client_build_id,sync_protocol_version,contract_version,canonical_contract_sha256,client_capabilities,batch_payload_sha256,project_sync_mode,migration_epoch,request_sha256", count: .exact)
            .eq("project_id", value: projectID.uuidString.lowercased()).eq("batch_id", value: batchID.uuidString.lowercased())
            .limit(2).execute()
        let batchRows = try JSONDecoder().decode([SyncV2JSON].self, from: batches.data)
        guard batches.count == batchRows.count, batchRows.count <= 1 else { throw SyncV2ContractStructureError.invalidRecoveryReceipt }
        // 빈 조회는 미적용 증명이 아니다. 기존 C9 재개 판정을 그대로 거친다.
        guard let batch = batchRows.first else { return nil }
        let results = try await client.from("sync_batch_results")
            .select("batch_id,applied,response,response_sha256", count: .exact)
            .eq("batch_id", value: batchID.uuidString.lowercased()).limit(2).execute()
        let resultRows = try JSONDecoder().decode([SyncV2JSON].self, from: results.data)
        guard results.count == 1, resultRows.count == 1 else { throw SyncV2ContractStructureError.invalidRecoveryReceipt }
        return SyncV2GeneralCommitReceipt(batch: batch, result: resultRows[0])
    }

    func fetchGeneralConflictDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2JSON {
        guard serverURL.scheme == "https" else { throw SyncV2GeneralConflictError.unavailable }
        let response = try await client.from("documents")
            .select("document_id,project_id,parent_folder_id,name,structure_revision,relative_path,content,revision,is_deleted", count: .exact)
            .eq("project_id", value: projectID.uuidString.lowercased())
            .eq("document_id", value: documentID.uuidString.lowercased()).limit(2).execute()
        guard response.data.count <= SyncV2GeneralRecoveryDetail.maximumRecordBytes else { throw SyncV2GeneralConflictError.unsupported }
        let rows = try JSONDecoder().decode([SyncV2JSON].self, from: response.data)
        guard response.count == 1, rows.count == 1 else { throw SyncV2GeneralConflictError.changed }
        return rows[0]
    }

    /// 일반 재개는 별도 조회다. 고정 작품 검토의 필터나 허용 범위를 넓히지 않는다.
    func fetchGeneralBaseline(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        guard serverURL.scheme == "https" else { throw SyncV2ContractStructureError.unavailable }
        func rows(_ table: String, _ columns: String) async throws -> [SyncV2JSON] {
            let response = try await client.from(table).select(columns, count: .exact)
                .eq("project_id", value: projectID.uuidString.lowercased()).limit(1000).execute()
            let decoded = try JSONDecoder().decode([SyncV2JSON].self, from: response.data)
            // 잘린 목록을 전체 기준으로 승인하지 않는다. 삭제 행도 비교에 포함한다.
            guard response.count == decoded.count, decoded.count < 1000 else {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            return decoded
        }
        return try await SyncV2PreparationSnapshot(
            folders: rows("folders", "folder_id,project_id,parent_folder_id,name,revision,is_deleted"),
            documents: rows("documents", "document_id,project_id,relative_path,revision,parent_folder_id,name,structure_revision,is_deleted"),
            treeOrders: rows("tree_orders", "tree_order_id,project_id,parent_folder_id,children,revision"))
    }
    func fetch(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
        guard serverURL.scheme == "https", serverURL.host == SyncV2EmptyVolumeReview.stagingHost,
              projectID == SyncV2EmptyVolumeReview.projectID else { throw SyncV2ContractStructureError.projectNotConnected }
        func rows(_ table: String, _ columns: String, liveOnly: Bool) async throws -> [SyncV2JSON] {
            let query = client.from(table).select(columns, count: .exact).eq("project_id", value: projectID.uuidString.lowercased())
            if liveOnly { _ = query.eq("is_deleted", value: false) }
            let response = try await query.limit(100).execute()
            let decoded = try JSONDecoder().decode([SyncV2JSON].self, from: response.data)
            guard response.count == decoded.count, decoded.count < 100 else {
                throw SyncV2ContractStructureError.unsupportedPreparationBaseline
            }
            return decoded
        }
        return try await SyncV2PreparationSnapshot(
            folders: rows("folders", "folder_id,project_id,parent_folder_id,name,revision,is_deleted", liveOnly: true),
            documents: rows("documents", "document_id,project_id,relative_path,revision,parent_folder_id,name,structure_revision,is_deleted", liveOnly: true),
            treeOrders: rows("tree_orders", "tree_order_id,project_id,parent_folder_id,children,revision", liveOnly: false))
    }
}
