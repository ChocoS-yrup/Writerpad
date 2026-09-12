import Foundation

enum SyncV2GeneralRecoveryError: Error {
    case unavailable, invalidRecord, recordTooLarge, sourceChanged
}

struct SyncV2GeneralRecoveryRow: Identifiable, Equatable, Sendable {
    let queueID: Int64
    let batchID: UUID
    let sourceStatus: String
    let requestStatus: String?
    let errorCode: String?
    let createdAt: String
    let isQueueHead: Bool
    var id: UUID { batchID }

    var isConflictReviewCandidate: Bool {
        isQueueHead && (requestStatus == "conflict" ||
            (requestStatus == "blocked" && errorCode == "STRUCTURE_REVISION_CONFLICT"))
    }

    var isStructureReviewCandidate: Bool {
        isConflictReviewCandidate || (isQueueHead && sourceStatus == "blocked" && requestStatus == nil)
    }

    var statusText: String {
        if errorCode == "EXPANDED_CONTRACT_PLAN" { return "단계별 요청의 보관 원본" }
        if errorCode == "ADOPT_SERVER_STRUCTURE" { return "서버 구조 선택 기록" }
        if requestStatus == "superseded" { return "선택 반영 전의 보관본" }
        if requestStatus == "conflict" || (requestStatus == "blocked" && errorCode == "STRUCTURE_REVISION_CONFLICT") { return "충돌 확인 필요" }
        if sourceStatus == "blocked" || requestStatus == "blocked" { return "확인이 필요한 변경" }
        if !isQueueHead { return "앞선 변경의 완료를 기다리는 중" }
        if requestStatus == "processing" { return "응답 확인 중" }
        return "동기화 대기 중"
    }

    var guidance: String {
        switch errorCode {
        case "ADOPT_SERVER_STRUCTURE": return "서버 구조를 선택한 기록입니다. 이름·위치·순서는 일반 수신에서 반영되며 편집 중 변경은 보호됩니다."
        case "EXPANDED_CONTRACT_PLAN": return "여러 동기화 요청으로 나눈 작업의 원본입니다. 각 단계가 완료된 뒤에도 이 보관본을 유지합니다."
        case "SUPERSEDED_AFTER_CONFLICT": return "선택한 보관본으로 새 동기화 요청을 만들었습니다. 이 원본과 서버 비교 기록은 계속 보관됩니다."
        case "REVISION_CONFLICT": return "다른 변경으로 서버 기준이 달라졌습니다. 저장 당시 원고를 별도 파일로 보관한 뒤 최신 원고와 비교해 주세요."
        case "STRUCTURE_REVISION_CONFLICT", "STRUCTURE_BARRIER_MISMATCH": return "문서 이름이나 위치의 서버 기준이 달라졌습니다. 원고와 구조 기록을 보관한 뒤 변경 내용을 확인해 주세요."
        case "BATCH_ID_REUSED", "OPERATION_ID_REUSED": return "보관된 요청과 서버 기록의 식별 정보가 맞지 않습니다. 복구 기록을 저장하고 요청을 확인해야 합니다."
        case "PROTOCOL_TOO_OLD", "CONTRACT_DIGEST_MISMATCH", "CAPABILITY_MISMATCH": return "앱과 서버의 동기화 계약을 확인해야 합니다. 보관된 변경은 유지됩니다."
        default:
            if !isQueueHead { return "이 변경도 로컬에 보관되어 있습니다. 앞선 변경을 확인하는 동안 저장 당시 원고를 꺼낼 수 있습니다." }
            return "보관된 변경을 확인하고 필요한 원고를 별도 파일로 저장할 수 있습니다."
        }
    }
}

struct SyncV2GeneralRecoveryPage: Sendable {
    let rows: [SyncV2GeneralRecoveryRow]
    let nextCursor: Int64?
}

struct SyncV2GeneralRecoveryText: Identifiable, Equatable, Sendable {
    let operationID: UUID
    let documentID: DocumentID
    let relativePath: String
    let content: String
    var id: UUID { operationID }
    // 원고 경로를 저장 경로로 사용하지 않아 중복 제목과 경로 이탈을 피한다.
    var filename: String { "saved-manuscript-" + operationID.uuidString.lowercased() + ".txt" }
}

struct SyncV2GeneralRecoveryDetail: Sendable {
    static let maximumRecordBytes = 64 * 1_024 * 1_024
    let localProjectID: ProjectID
    let serverProjectID: UUID
    let row: SyncV2GeneralRecoveryRow
    let sourceJSON: String
    let requestJSON: String?
    let responseJSON: String?
    let resolutionJSON: String?
    let source: LocalMutationBatch

    init(localProjectID: ProjectID, serverProjectID: UUID, row: SyncV2GeneralRecoveryRow,
         sourceJSON: String, requestJSON: String?, responseJSON: String?, resolutionJSON: String? = nil) throws {
        guard sourceJSON.utf8.count + (requestJSON?.utf8.count ?? 0) + (responseJSON?.utf8.count ?? 0) + (resolutionJSON?.utf8.count ?? 0) <= Self.maximumRecordBytes else {
            throw SyncV2GeneralRecoveryError.recordTooLarge
        }
        let source = try JSONDecoder().decode(LocalMutationBatch.self, from: Data(sourceJSON.utf8))
        guard source.projectID == localProjectID, source.batchID == row.batchID else { throw SyncV2GeneralRecoveryError.invalidRecord }
        if let requestJSON {
            let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(requestJSON.utf8)))
            guard request.batchID == row.batchID,
                  request.json.objectValue?["project_id"] == .string(serverProjectID.uuidString.lowercased()),
                  try SyncV2JSON.array(request.orderedIntents).sha256Hex() == request.batchPayloadSHA256 else {
                throw SyncV2GeneralRecoveryError.invalidRecord
            }
        }
        self.localProjectID = localProjectID; self.serverProjectID = serverProjectID; self.row = row
        self.sourceJSON = sourceJSON; self.requestJSON = requestJSON; self.responseJSON = responseJSON; self.source = source; self.resolutionJSON = resolutionJSON
        _ = try manuscripts()
    }

    func manuscripts() throws -> [SyncV2GeneralRecoveryText] {
        var result: [SyncV2GeneralRecoveryText] = []
        for mutation in source.mutations {
            if case let .documentSnapshot(operationID, documentID, path, content, hash, _, _) = mutation {
                guard SHA256ContentHasher().sha256(for: Data(content.utf8)) == hash,
                      !result.contains(where: { $0.operationID == operationID }) else { throw SyncV2GeneralRecoveryError.invalidRecord }
                result.append(.init(operationID: operationID, documentID: documentID, relativePath: path.rawValue, content: content))
            }
        }
        return result
    }

    var structureDescriptions: [String] {
        source.mutations.compactMap {
            switch $0 {
            case let .folderSnapshot(_, _, _, name, deleted): return deleted ? "폴더 삭제: \(name)" : "폴더 변경: \(name)"
            case .treeOrder: return "문서·폴더 순서 변경"
            default: return nil
            }
        }
    }

    func exportData() throws -> Data {
        // 원본 문자열과 지문을 함께 보존한다. 진단 수집/서버 업로드 용도가 아니다.
        struct Archive: Encodable {
            let kind = "writerpad_general_sync_recovery"
            let version = 1
            let localProjectID: UUID
            let serverProjectID: UUID
            let batchID: UUID
            let sourceStatus: String
            let requestStatus: String?
            let errorCode: String?
            let sourceJSON: String
            let sourceSHA256: String
            let requestJSON: String?
            let responseJSON: String?
            let resolutionJSON: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Archive(localProjectID: localProjectID.rawValue, serverProjectID: serverProjectID,
            batchID: row.batchID, sourceStatus: row.sourceStatus, requestStatus: row.requestStatus, errorCode: row.errorCode,
            sourceJSON: sourceJSON, sourceSHA256: SHA256ContentHasher().sha256(for: Data(sourceJSON.utf8)).rawValue,
            requestJSON: requestJSON, responseJSON: responseJSON, resolutionJSON: resolutionJSON))
    }
}

protocol SyncV2GeneralRecoveryReading: Sendable {
    func generalRecoveryPage(localProjectID: ProjectID, after queueID: Int64?) async throws -> SyncV2GeneralRecoveryPage
    func generalRecoveryDetail(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRecoveryDetail
}

extension LazySyncV2ProjectBindingStore: SyncV2GeneralRecoveryReading {}

enum SyncV2GeneralConflictError: Error {
    case unsupported, changed, unavailable
    case localSelectionSavedNeedsReview
}

struct SyncV2GeneralConflictLocal: Sendable {
    let detail: SyncV2GeneralRecoveryDetail
    let baseline: SyncV2PreparationSnapshot
    var followers: [SyncV2GeneralRecoveryDetail] = []
    var records: [SyncV2GeneralRecoveryDetail] { [detail] + followers }
    /// 다른 문서나 구조 변경을 건너뛰어 뒤의 저장을 앞당기지 않는다.
    var resolutionRecords: [SyncV2GeneralRecoveryDetail] {
        guard case let .documentSnapshot(_, document, path, _, _, _, false) = detail.source.mutations.first else { return [detail] }
        return [detail] + followers.prefix { record in
            guard record.source.kind == .documentSave, record.source.structureSnapshot == nil,
                  record.source.mutations.count == 1,
                  case let .documentSnapshot(_, nextDocument, nextPath, _, _, _, false) = record.source.mutations[0] else { return false }
            return nextDocument == document && SyncV2ServerPath.canonical(nextPath.rawValue) == SyncV2ServerPath.canonical(path.rawValue)
        }
    }
    var deferredRecords: [SyncV2GeneralRecoveryDetail] { Array(records.dropFirst(resolutionRecords.count)) }
    var selected: SyncV2GeneralRecoveryDetail { resolutionRecords.last ?? detail }
}

/// 앞선 본문 충돌만 해결하며 뒤따르는 다른 문서와 구조 변경은 원래 순서로 남긴다.
struct SyncV2GeneralConflictReview: Sendable {
    let local: SyncV2GeneralConflictLocal
    let remote: SyncV2JSON
    let remoteBaseline: SyncV2PreparationSnapshot
    let context: SyncV2HandshakeContext
    let authorizationFingerprint: String
    let fingerprint: String
    let documentID: UUID
    let savedContent: String
    let remoteContent: String
    let remoteRevision: Int

    init(local: SyncV2GeneralConflictLocal, remote: SyncV2JSON, remoteBaseline: SyncV2PreparationSnapshot,
         context: SyncV2HandshakeContext, authorizationFingerprint: String) throws {
        let detail = local.detail
        guard detail.row.isQueueHead, detail.row.requestStatus == "conflict", detail.row.errorCode == "REVISION_CONFLICT",
              detail.source.kind == .documentSave, detail.source.structureSnapshot == nil,
              detail.source.mutations.count == 1,
              case let .documentSnapshot(operation, document, path, content, hash, _, false) = detail.source.mutations[0],
              let requestJSON = detail.requestJSON,
              context.localProjectID == detail.localProjectID, context.serverProjectID == detail.serverProjectID else {
            throw SyncV2GeneralConflictError.unsupported
        }
        let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(requestJSON.utf8)))
        let documentKey = document.rawValue.uuidString.lowercased()
        guard request.json.objectValue?["kind"] == .string("document_commit_request"), request.orderedIntents.count == 1,
              let intent = request.orderedIntents[0].objectValue, let payload = intent["payload"]?.objectValue,
              intent["operation_id"] == .string(operation.uuidString.lowercased()), intent["document_id"] == .string(documentKey),
              intent["intent_kind"] == .string("update"), payload["content"] == .string(content),
              payload["content_sha256"] == .string(hash.rawValue), payload["is_deleted"] == .bool(false),
              let original = local.baseline.documents.first(where: { $0.objectValue?["document_id"] == .string(documentKey) })?.objectValue,
              intent["base_revision"] == original["revision"],
              let remoteFields = remote.objectValue, let revision = remoteFields["revision"]?.intValue,
              revision > (original["revision"]?.intValue ?? 0),
              let remoteContent = remoteFields["content"]?.stringValue,
              remoteContent.utf8.count <= SyncV2Store.maximumContentByteCount,
              content.utf8.count <= SyncV2Store.maximumContentByteCount,
              remoteFields["document_id"] == .string(documentKey),
              remoteFields["project_id"] == .string(detail.serverProjectID.uuidString.lowercased()),
              remoteFields["is_deleted"] == .bool(false), original["is_deleted"] == .bool(false),
              remoteFields["relative_path"]?.stringValue.map(SyncV2ServerPath.canonical) == SyncV2ServerPath.canonical(path.rawValue)
        else { throw SyncV2GeneralConflictError.unsupported }
        for key in ["parent_folder_id", "name", "structure_revision"] {
            guard let expected = original[key], payload[key] == expected, remoteFields[key] == expected else {
                throw SyncV2GeneralConflictError.unsupported
            }
        }
        // 본문 조회와 전체 기준 조회가 같은 revision의 같은 문서를 가리켜야 한다.
        var projection = remoteFields; projection.removeValue(forKey: "content")
        guard remoteBaseline.documents.filter({ $0.objectValue?["document_id"] == .string(documentKey) }) == [.object(projection)] else {
            throw SyncV2GeneralConflictError.changed
        }
        let normalized = remoteBaseline.documents.map { row -> SyncV2JSON in
            guard var fields = row.objectValue, fields["document_id"] == .string(documentKey) else { return row }
            fields["revision"] = original["revision"]
            return .object(fields)
        }
        guard try SyncV2PreparationSnapshot(folders: remoteBaseline.folders, documents: normalized,
            treeOrders: remoteBaseline.treeOrders).fingerprint() == local.baseline.fingerprint() else {
            throw SyncV2GeneralConflictError.unsupported
        }
        guard local.records.count <= 50 else { throw SyncV2GeneralConflictError.unsupported }
        // 대체 head는 나중에 생성된 보관 ID를 가지지만 전송 순서는 원래 head를 잇는다.
        var previousQueueID: Int64 = 0
        var queueIDs: Set<Int64> = [detail.row.queueID]
        var batchIDs: Set<UUID> = [detail.row.batchID], operationIDs: Set<UUID> = [operation]
        var totalBytes = detail.sourceJSON.utf8.count + (detail.requestJSON?.utf8.count ?? 0) + (detail.responseJSON?.utf8.count ?? 0)
        for follower in local.followers {
            totalBytes += follower.sourceJSON.utf8.count
            guard totalBytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes,
                  follower.localProjectID == detail.localProjectID, follower.serverProjectID == detail.serverProjectID,
                  follower.row.queueID > previousQueueID, queueIDs.insert(follower.row.queueID).inserted, !follower.row.isQueueHead,
                  follower.row.sourceStatus == "waiting", follower.row.requestStatus == nil,
                  follower.requestJSON == nil, follower.responseJSON == nil, follower.resolutionJSON == nil,
                  batchIDs.insert(follower.row.batchID).inserted,
                  !follower.source.mutations.isEmpty else { throw SyncV2GeneralConflictError.unsupported }
            if follower.source.kind == .documentSave {
                guard follower.source.structureSnapshot == nil, follower.source.mutations.count == 1,
                      case .documentSnapshot = follower.source.mutations[0] else { throw SyncV2GeneralConflictError.unsupported }
            } else {
                guard follower.source.kind == .structureChange, let nodes = follower.source.structureSnapshot,
                      nodes.allSatisfy({ $0.projectID == detail.localProjectID }), Set(nodes.map(\.id)).count == nodes.count,
                      follower.source.mutations.contains(where: { if case .treeOrder = $0 { return true }; return false }) else {
                    throw SyncV2GeneralConflictError.unsupported
                }
            }
            for mutation in follower.source.mutations {
                let identifier: UUID
                switch mutation {
                case let .documentSnapshot(id, nextDocument, nextPath, nextContent, _, _, false):
                    identifier = id
                    guard nextContent.utf8.count <= SyncV2Store.maximumContentByteCount,
                          local.baseline.documents.contains(where: { $0.objectValue?["document_id"] == .string(nextDocument.rawValue.uuidString.lowercased()) }) else {
                        throw SyncV2GeneralConflictError.unsupported
                    }
                    // 구조 변경 전의 경로가 갑자기 달라지면 순서를 추정할 수 없다.
                    let hasEarlierStructure = local.followers.prefix { $0.row.batchID != follower.row.batchID }
                        .contains { $0.source.kind == .structureChange }
                    if follower.source.kind == .documentSave, !hasEarlierStructure {
                        let expected = local.baseline.documents.first { $0.objectValue?["document_id"] == .string(nextDocument.rawValue.uuidString.lowercased()) }
                        guard expected?.objectValue?["relative_path"]?.stringValue.map(SyncV2ServerPath.canonical) == SyncV2ServerPath.canonical(nextPath.rawValue) else {
                            throw SyncV2GeneralConflictError.unsupported
                        }
                    }
                case let .folderSnapshot(id, _, _, _, _), let .treeOrder(id, _, _): identifier = id
                default: throw SyncV2GeneralConflictError.unsupported
                }
                guard operationIDs.insert(identifier).inserted else { throw SyncV2GeneralConflictError.unsupported }
            }
            previousQueueID = follower.row.queueID
        }
        guard let selectedText = try local.selected.manuscripts().first else { throw SyncV2GeneralConflictError.unsupported }
        self.local = local; self.remote = remote; self.remoteBaseline = remoteBaseline; self.context = context
        self.authorizationFingerprint = authorizationFingerprint; self.documentID = document.rawValue
        self.savedContent = selectedText.content; self.remoteContent = remoteContent; self.remoteRevision = revision
        fingerprint = try SyncV2JSON.object([
            "source": .string(detail.sourceJSON), "request": .string(requestJSON), "remote": remote,
            "followers": .array(local.followers.map { .object(["queue_id": .int(Int($0.row.queueID)), "source": .string($0.sourceJSON)]) }),
            "baseline": .string(local.baseline.fingerprint()), "server_baseline": .string(remoteBaseline.fingerprint()),
            "account": .string(context.accountID.uuidString.lowercased()), "authorization": .string(authorizationFingerprint)
        ]).sha256Hex()
    }
}

/// 항목의 구성은 그대로이고 한 부모의 순서만 달라진 충돌을 비교한다.
struct SyncV2GeneralOrderConflictReview: Sendable {
    let local: SyncV2GeneralConflictLocal
    let remoteBaseline: SyncV2PreparationSnapshot
    let context: SyncV2HandshakeContext
    let authorizationFingerprint: String
    let fingerprint: String
    let treeOrderID: UUID
    let remoteRevision: Int
    let payload: SyncV2JSON
    let remoteOrder: SyncV2JSON
    let savedChildren: [UUID]
    let remoteChildren: [UUID]

    init(local: SyncV2GeneralConflictLocal, remoteBaseline: SyncV2PreparationSnapshot,
         context: SyncV2HandshakeContext, authorizationFingerprint: String) throws {
        let detail = local.detail
        guard detail.row.isQueueHead, detail.row.requestStatus == "conflict",
              detail.row.errorCode == "REVISION_CONFLICT",
              detail.source.kind == .structureChange, detail.source.structureSnapshot != nil,
              detail.source.mutations.count == 1, case let .treeOrder(operation, _, _) = detail.source.mutations[0],
              context.localProjectID == detail.localProjectID, context.serverProjectID == detail.serverProjectID,
              let requestJSON = detail.requestJSON else { throw SyncV2GeneralConflictError.unsupported }
        let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(requestJSON.utf8)))
        guard request.json.objectValue?["kind"] == .string("atomic_structure_commit_request"),
              request.orderedIntents.count == 1, let intent = request.orderedIntents[0].objectValue,
              intent["entity_kind"] == .string("tree_order"), intent["intent_kind"] == .string("reorder"),
              let id = intent["entity_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
              intent["operation_id"] == .string(syncV2UUIDv5(namespace: operation, name: id.uuidString.lowercased()).uuidString.lowercased()),
              let payload = intent["payload"], let fields = payload.objectValue,
              Set(fields.keys) == Set(["parent_folder_id", "children"]),
              let original = local.baseline.treeOrders.first(where: { $0.objectValue?["tree_order_id"] == intent["entity_id"] }),
              let old = original.objectValue, intent["base_revision"] == old["revision"],
              fields["parent_folder_id"] == old["parent_folder_id"],
              let remote = remoteBaseline.treeOrders.first(where: { $0.objectValue?["tree_order_id"] == intent["entity_id"] }),
              let remoteFields = remote.objectValue, let revision = remoteFields["revision"]?.intValue,
              revision > (old["revision"]?.intValue ?? 0),
              remoteFields["parent_folder_id"] == old["parent_folder_id"],
              remoteFields["project_id"] == .string(context.serverProjectID.uuidString.lowercased()) else {
            throw SyncV2GeneralConflictError.unsupported
        }
        func children(_ value: SyncV2JSON?) throws -> [UUID] {
            guard let values = value?.arrayValue else { throw SyncV2GeneralConflictError.unsupported }
            let ids = values.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
            guard ids.count == values.count, Set(ids).count == ids.count else { throw SyncV2GeneralConflictError.unsupported }
            return ids
        }
        let saved = try children(fields["children"]), previous = try children(old["children"]), current = try children(remoteFields["children"])
        guard Set(saved) == Set(previous), Set(current) == Set(previous) else { throw SyncV2GeneralConflictError.unsupported }
        let members = (local.baseline.folders + local.baseline.documents).filter {
            $0.objectValue?["parent_folder_id"] == old["parent_folder_id"] && $0.objectValue?["is_deleted"] == .bool(false)
        }.compactMap { row in (row.objectValue?["folder_id"] ?? row.objectValue?["document_id"])?.stringValue.flatMap(UUID.init(uuidString:)) }
        guard Set(members) == Set(previous), members.count == previous.count else { throw SyncV2GeneralConflictError.unsupported }
        // revision만 올려 다른 구조 변경까지 승인하지 않는다. 비교한 순서 행 외에는 모두 같아야 한다.
        var normalizedOrder = remoteFields
        normalizedOrder["revision"] = old["revision"]; normalizedOrder["children"] = old["children"]
        guard normalizedOrder == old, (old["revision"]?.intValue ?? 0) > 0 else { throw SyncV2GeneralConflictError.unsupported }
        let normalized = remoteBaseline.treeOrders.map { $0.objectValue?["tree_order_id"] == intent["entity_id"] ? original : $0 }
        guard try SyncV2PreparationSnapshot(folders: remoteBaseline.folders, documents: remoteBaseline.documents,
            treeOrders: normalized).fingerprint() == local.baseline.fingerprint(),
              local.records.count <= 50 else { throw SyncV2GeneralConflictError.unsupported }
        var ids: Set<UUID> = [detail.row.batchID], queueIDs: Set<Int64> = [detail.row.queueID]
        var previousQueueID: Int64 = 0
        var bytes = detail.sourceJSON.utf8.count + requestJSON.utf8.count + (detail.responseJSON?.utf8.count ?? 0)
        for follower in local.followers {
            bytes += follower.sourceJSON.utf8.count
            guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes,
                  follower.localProjectID == detail.localProjectID, follower.serverProjectID == detail.serverProjectID,
                  follower.row.queueID > previousQueueID, queueIDs.insert(follower.row.queueID).inserted,
                  ids.insert(follower.row.batchID).inserted, !follower.row.isQueueHead,
                  follower.row.sourceStatus == "waiting", follower.row.requestStatus == nil,
                  follower.requestJSON == nil, follower.responseJSON == nil, follower.resolutionJSON == nil else {
                throw SyncV2GeneralConflictError.unsupported
            }
            previousQueueID = follower.row.queueID
        }
        self.local = local; self.remoteBaseline = remoteBaseline; self.context = context
        self.authorizationFingerprint = authorizationFingerprint; self.treeOrderID = id
        self.remoteRevision = revision; self.payload = payload; self.remoteOrder = remote
        self.savedChildren = saved; self.remoteChildren = current
        self.fingerprint = try SyncV2JSON.object([
            "source": .string(detail.sourceJSON), "request": .string(requestJSON),
            "followers": .array(local.followers.map { .object(["queue_id": .int(Int($0.row.queueID)), "source": .string($0.sourceJSON)]) }),
            "baseline": .string(local.baseline.fingerprint()), "server_baseline": .string(remoteBaseline.fingerprint()),
            "account": .string(context.accountID.uuidString.lowercased()), "authorization": .string(authorizationFingerprint)
        ]).sha256Hex()
    }

    var parentName: String {
        guard let parent = payload.objectValue?["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return "작품 최상위" }
        return name(for: parent)
    }

    func name(for id: UUID) -> String {
        let key = SyncV2JSON.string(id.uuidString.lowercased())
        let row = (local.baseline.folders + local.baseline.documents).first {
            $0.objectValue?["folder_id"] == key || $0.objectValue?["document_id"] == key
        }
        return row?.objectValue?["name"]?.stringValue ?? id.uuidString.lowercased()
    }
}

/// 위치·순서·본문이 같은 단일 문서의 이름 충돌만 선택한다.
struct SyncV2GeneralRenameConflictReview: Sendable {
    let local: SyncV2GeneralConflictLocal
    let remote: SyncV2JSON
    let remoteBaseline: SyncV2PreparationSnapshot
    let context: SyncV2HandshakeContext
    let authorizationFingerprint: String
    let fingerprint: String
    let entityID: UUID
    let isFolder: Bool
    var descendantDocuments: [SyncV2JSON] { isFolder ? (remote.objectValue?["descendant_documents"]?.arrayValue ?? []) : [] }
    let savedName: String
    let remoteName: String
    let remotePath: String
    let remoteRevision: Int

    init(local: SyncV2GeneralConflictLocal, remote: SyncV2JSON, remoteBaseline: SyncV2PreparationSnapshot,
         context: SyncV2HandshakeContext, authorizationFingerprint: String) throws {
        if local.detail.source.mutations.contains(where: { if case .folderSnapshot = $0 { return true }; return false }) {
            self = try Self(folderLocal: local, remote: remote, remoteBaseline: remoteBaseline,
                context: context, authorizationFingerprint: authorizationFingerprint)
            return
        }
        let detail = local.detail
        guard detail.row.isConflictReviewCandidate,
              ["REVISION_CONFLICT", "STRUCTURE_REVISION_CONFLICT"].contains(detail.row.errorCode ?? ""),
              detail.source.kind == .structureChange, detail.source.mutations.count == 2,
              let nodes = detail.source.structureSnapshot,
              let manuscript = try detail.manuscripts().first, try detail.manuscripts().count == 1,
              detail.source.mutations.contains(where: { if case .treeOrder = $0 { return true }; return false }),
              detail.source.mutations.contains(where: { if case .documentSnapshot(_, _, _, _, _, _, false) = $0 { return true }; return false }),
              let node = nodes.first(where: { $0.id == manuscript.documentID }), node.kind == .text, node.isIncludedInTree,
              node.relativePath.rawValue == manuscript.relativePath,
              context.localProjectID == detail.localProjectID, context.serverProjectID == detail.serverProjectID,
              let requestJSON = detail.requestJSON else { throw SyncV2GeneralConflictError.unsupported }
        let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(requestJSON.utf8)))
        let key = SyncV2JSON.string(manuscript.documentID.rawValue.uuidString.lowercased())
        guard request.json.objectValue?["kind"] == .string("atomic_structure_commit_request"), request.orderedIntents.count == 1,
              let intent = request.orderedIntents[0].objectValue, intent["entity_kind"] == .string("document"),
              intent["entity_id"] == key, intent["intent_kind"] == .string("rename"),
              intent["operation_id"] == .string(manuscript.operationID.uuidString.lowercased()),
              let payload = intent["payload"]?.objectValue, Set(payload.keys) == Set(["name"]),
              let name = payload["name"]?.stringValue, name == (manuscript.relativePath as NSString).lastPathComponent,
              let original = local.baseline.documents.first(where: { $0.objectValue?["document_id"] == key })?.objectValue,
              original["is_deleted"] == .bool(false), intent["base_revision"] == original["structure_revision"],
              let fields = remote.objectValue, fields["document_id"] == key,
              fields["project_id"] == .string(context.serverProjectID.uuidString.lowercased()),
              fields["is_deleted"] == .bool(false), fields["revision"] == original["revision"],
              fields["parent_folder_id"] == original["parent_folder_id"],
              fields["parent_folder_id"] == (node.parentID.map { .string($0.rawValue.uuidString.lowercased()) } ?? .null),
              let revision = fields["structure_revision"]?.intValue, revision > (original["structure_revision"]?.intValue ?? 0),
              let remoteName = fields["name"]?.stringValue, let remotePath = fields["relative_path"]?.stringValue,
              let originalPath = original["relative_path"]?.stringValue, let content = fields["content"]?.stringValue,
              content.utf8.count <= SyncV2Store.maximumContentByteCount,
              Data(content.utf8) == Data(manuscript.content.utf8) else { throw SyncV2GeneralConflictError.unsupported }
        func parentPath(_ path: String) -> String { (SyncV2ServerPath.canonical(path) as NSString).deletingLastPathComponent }
        guard parentPath(originalPath) == parentPath(remotePath), parentPath(originalPath) == parentPath(manuscript.relativePath),
              (remotePath as NSString).lastPathComponent == remoteName else { throw SyncV2GeneralConflictError.unsupported }
        let nameKey = try SyncV2StorageName.normalize(name)
        _ = try SyncV2StorageName.normalize(remoteName)
        for row in remoteBaseline.documents + remoteBaseline.folders {
            let fields = row.objectValue ?? [:]
            if fields["document_id"] == key || fields["is_deleted"] != .bool(false) || fields["parent_folder_id"] != original["parent_folder_id"] { continue }
            guard let otherName = fields["name"]?.stringValue, try SyncV2StorageName.normalize(otherName) != nameKey else {
                throw SyncV2GeneralConflictError.unsupported
            }
        }
        var projection = fields; projection.removeValue(forKey: "content")
        guard remoteBaseline.documents.filter({ $0.objectValue?["document_id"] == key }) == [.object(projection)] else {
            throw SyncV2GeneralConflictError.changed
        }
        for field in ["name", "relative_path", "structure_revision"] { projection[field] = original[field] }
        guard projection == original else { throw SyncV2GeneralConflictError.unsupported }
        let normalized = remoteBaseline.documents.map { $0.objectValue?["document_id"] == key ? .object(original) : $0 }
        guard try SyncV2PreparationSnapshot(folders: remoteBaseline.folders, documents: normalized,
            treeOrders: remoteBaseline.treeOrders).fingerprint() == local.baseline.fingerprint(),
              local.records.count <= 50 else { throw SyncV2GeneralConflictError.unsupported }
        var ids: Set<UUID> = [detail.row.batchID], queueIDs: Set<Int64> = [detail.row.queueID]
        var previousQueueID: Int64 = 0
        var bytes = detail.sourceJSON.utf8.count + requestJSON.utf8.count + (detail.responseJSON?.utf8.count ?? 0)
        for follower in local.followers {
            bytes += follower.sourceJSON.utf8.count
            guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes,
                  follower.localProjectID == detail.localProjectID, follower.serverProjectID == detail.serverProjectID,
                  follower.row.queueID > previousQueueID, queueIDs.insert(follower.row.queueID).inserted,
                  ids.insert(follower.row.batchID).inserted, !follower.row.isQueueHead,
                  follower.row.sourceStatus == "waiting", follower.row.requestStatus == nil,
                  follower.requestJSON == nil, follower.responseJSON == nil, follower.resolutionJSON == nil else {
                throw SyncV2GeneralConflictError.unsupported
            }
            previousQueueID = follower.row.queueID
        }
        self.local = local; self.remote = remote; self.remoteBaseline = remoteBaseline; self.context = context
        self.authorizationFingerprint = authorizationFingerprint; self.entityID = manuscript.documentID.rawValue; self.isFolder = false
        self.savedName = name; self.remoteName = remoteName; self.remotePath = remotePath; self.remoteRevision = revision
        fingerprint = try SyncV2JSON.object([
            "source": .string(detail.sourceJSON), "request": .string(requestJSON), "remote": remote,
            "followers": .array(local.followers.map { .object(["queue_id": .int(Int($0.row.queueID)), "source": .string($0.sourceJSON)]) }),
            "baseline": .string(local.baseline.fingerprint()), "server_baseline": .string(remoteBaseline.fingerprint()),
            "account": .string(context.accountID.uuidString.lowercased()), "authorization": .string(authorizationFingerprint)
        ]).sha256Hex()
    }
    private init(folderLocal local: SyncV2GeneralConflictLocal, remote: SyncV2JSON,
        remoteBaseline: SyncV2PreparationSnapshot, context: SyncV2HandshakeContext, authorizationFingerprint: String) throws {
        let detail = local.detail
        let manuscripts = try detail.manuscripts()
        let remoteDocuments = remote.objectValue?["descendant_documents"]?.arrayValue ?? []
        var folderFields = remote.objectValue ?? [:]; folderFields.removeValue(forKey: "descendant_documents")
        guard detail.row.isQueueHead, detail.row.requestStatus == "conflict", detail.row.errorCode == "REVISION_CONFLICT",
              detail.source.kind == .structureChange,
              detail.source.mutations.allSatisfy({
                  switch $0 {
                  case .folderSnapshot(_, _, _, _, false), .documentSnapshot(_, _, _, _, _, _, false), .treeOrder: return true
                  default: return false
                  }
              }), detail.source.mutations.count == manuscripts.count + 2, manuscripts.count <= 50,
              Set(manuscripts.map(\.documentID)).count == manuscripts.count, remoteDocuments.count == manuscripts.count,
              let nodes = detail.source.structureSnapshot,
              nodes.allSatisfy({ $0.projectID == detail.localProjectID }), Set(nodes.map(\.id)).count == nodes.count,
              let mutation = detail.source.mutations.first(where: { if case .folderSnapshot = $0 { return true }; return false }),
              case let .folderSnapshot(operation, folder, parent, name, false) = mutation,
              detail.source.mutations.contains(where: { if case .treeOrder = $0 { return true }; return false }),
              let node = nodes.first(where: { $0.id == folder }), node.kind == .folder, node.isIncludedInTree,
              node.parentID == parent,
              context.localProjectID == detail.localProjectID, context.serverProjectID == detail.serverProjectID,
              let requestJSON = detail.requestJSON else { throw SyncV2GeneralConflictError.unsupported }
        let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(requestJSON.utf8)))
        let key = SyncV2JSON.string(folder.rawValue.uuidString.lowercased())
        guard request.json.objectValue?["kind"] == .string("atomic_structure_commit_request"), request.orderedIntents.count == manuscripts.count + 1,
              let intent = request.orderedIntents[0].objectValue, intent["entity_kind"] == .string("folder"),
              intent["entity_id"] == key, intent["intent_kind"] == .string("update"),
              intent["operation_id"] == .string(operation.uuidString.lowercased()),
              let original = local.baseline.folders.first(where: { $0.objectValue?["folder_id"] == key })?.objectValue,
              original["is_deleted"] == .bool(false), (original["revision"]?.intValue ?? 0) > 0,
              let originalName = original["name"]?.stringValue,
              intent["base_revision"] == original["revision"],
              original["parent_folder_id"] == (parent.map { .string($0.rawValue.uuidString.lowercased()) } ?? .null),
              intent["payload"] == .object(["name": .string(name), "parent_folder_id": original["parent_folder_id"]!]),
              case let fields = folderFields, fields["folder_id"] == key,
              fields["project_id"] == .string(context.serverProjectID.uuidString.lowercased()),
              fields["is_deleted"] == .bool(false), fields["parent_folder_id"] == original["parent_folder_id"],
              let revision = fields["revision"]?.intValue, revision > (original["revision"]?.intValue ?? 0),
              let remoteName = fields["name"]?.stringValue,
              remoteBaseline.folders.filter({ $0.objectValue?["folder_id"] == key }) == [.object(fields)] else {
            throw SyncV2GeneralConflictError.unsupported
        }
        var normalizedFolder = fields; normalizedFolder["name"] = original["name"]; normalizedFolder["revision"] = original["revision"]
        let normalized = remoteBaseline.folders.map { $0.objectValue?["folder_id"] == key ? .object(original) : $0 }
        guard normalizedFolder == original, local.records.count <= 50 else { throw SyncV2GeneralConflictError.unsupported }
        let nameKey = try SyncV2StorageName.normalize(name)
        _ = try SyncV2StorageName.normalize(remoteName)
        for row in remoteBaseline.folders + remoteBaseline.documents {
            let sibling = row.objectValue ?? [:]
            if sibling["folder_id"] == key || sibling["is_deleted"] != .bool(false) || sibling["parent_folder_id"] != fields["parent_folder_id"] { continue }
            guard let siblingName = sibling["name"]?.stringValue, try SyncV2StorageName.normalize(siblingName) != nameKey else {
                throw SyncV2GeneralConflictError.unsupported
            }
        }
        // 부모 관계로 전체 하위를 찾는다. 빠진 원고나 삭제 항목을 이름 복구에 섞지 않는다.
        var descendants: Set<UUID> = [folder.rawValue]
        for _ in 0..<local.baseline.folders.count {
            let before = descendants.count
            for row in local.baseline.folders {
                if let fields = row.objectValue,
                   let parent = fields["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)), descendants.contains(parent),
                   let id = fields["folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)) { descendants.insert(id) }
            }
            if descendants.count == before { break }
        }
        func folderPath(_ id: UUID, renamed: String, visited: Set<UUID> = []) throws -> String {
            guard !visited.contains(id), let fields = local.baseline.folders.first(where: {
                $0.objectValue?["folder_id"] == .string(id.uuidString.lowercased())
            })?.objectValue, fields["is_deleted"] == .bool(false), let storedName = fields["name"]?.stringValue else {
                throw SyncV2GeneralConflictError.unsupported
            }
            let component = id == folder.rawValue ? renamed : storedName
            _ = try SyncV2StorageName.normalize(component)
            if fields["parent_folder_id"] == .null { return component }
            guard let parent = fields["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw SyncV2GeneralConflictError.unsupported }
            return try folderPath(parent, renamed: renamed, visited: visited.union([id])) + "/" + component
        }
        for id in descendants {
            guard let saved = nodes.first(where: { $0.id.rawValue == id }), saved.kind == .folder, saved.isIncludedInTree,
                  SyncV2ServerPath.canonical(saved.relativePath.rawValue) == SyncV2ServerPath.canonical(try folderPath(id, renamed: name)) else {
                throw SyncV2GeneralConflictError.unsupported
            }
        }
        let descendantsInBaseline = local.baseline.documents.filter {
            $0.objectValue?["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(descendants.contains) ?? false
        }
        let documentKeys = Set(manuscripts.map { $0.documentID.rawValue.uuidString.lowercased() })
        guard Set(descendantsInBaseline.compactMap { $0.objectValue?["document_id"]?.stringValue }) == documentKeys,
              descendantsInBaseline.count == manuscripts.count,
              Set(nodes.filter { $0.kind == .text && $0.parentID.map { descendants.contains($0.rawValue) } == true }
                .map { $0.id.rawValue.uuidString.lowercased() }) == documentKeys else { throw SyncV2GeneralConflictError.unsupported }
        var normalizedDocuments = remoteBaseline.documents
        var comparedBytes = detail.sourceJSON.utf8.count + requestJSON.utf8.count + (detail.responseJSON?.utf8.count ?? 0)
        for (index, manuscript) in manuscripts.enumerated() {
            let documentKey = SyncV2JSON.string(manuscript.documentID.rawValue.uuidString.lowercased())
            guard let old = descendantsInBaseline.first(where: { $0.objectValue?["document_id"] == documentKey })?.objectValue,
                  old["is_deleted"] == .bool(false), let oldRevision = old["structure_revision"]?.intValue, oldRevision > 0,
                  let oldName = old["name"]?.stringValue, let oldPath = old["relative_path"]?.stringValue,
                  let parent = old["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let saved = nodes.first(where: { $0.id == manuscript.documentID }), saved.kind == .text, saved.isIncludedInTree,
                  saved.parentID?.rawValue == parent, saved.relativePath.rawValue == manuscript.relativePath,
                  SyncV2ServerPath.canonical(oldPath) == SyncV2ServerPath.canonical(try folderPath(parent, renamed: originalName) + "/" + oldName),
                  SyncV2ServerPath.canonical(manuscript.relativePath) == SyncV2ServerPath.canonical(try folderPath(parent, renamed: name) + "/" + oldName),
                  let childIntent = request.orderedIntents[index + 1].objectValue,
                  childIntent["entity_kind"] == .string("document"), childIntent["entity_id"] == documentKey,
                  childIntent["intent_kind"] == .string("rename"), childIntent["base_revision"] == .int(oldRevision),
                  childIntent["operation_id"] == .string(manuscript.operationID.uuidString.lowercased()),
                  childIntent["payload"] == .object(["name": .string(oldName)]),
                  let child = remoteDocuments[index].objectValue, child["document_id"] == documentKey,
                  let content = child["content"]?.stringValue, content.utf8.count <= SyncV2Store.maximumContentByteCount,
                  Data(content.utf8) == Data(manuscript.content.utf8),
                  let path = child["relative_path"]?.stringValue, let revision = child["structure_revision"]?.intValue,
                  let remoteRow = remoteBaseline.documents.firstIndex(where: { $0.objectValue?["document_id"] == documentKey }) else {
                throw SyncV2GeneralConflictError.unsupported
            }
            _ = try SyncV2StorageName.normalize(oldName)
            comparedBytes += try remoteDocuments[index].canonicalJSON().utf8.count
            guard comparedBytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes else { throw SyncV2GeneralConflictError.unsupported }
            // 서버가 폴더만 바꾼 경우와 자식 경로까지 갱신한 경우를 모두 명시적으로 검증한다.
            let refreshedPath = try folderPath(parent, renamed: remoteName) + "/" + oldName
            guard (path == oldPath && revision == oldRevision)
                || (SyncV2ServerPath.canonical(path) == SyncV2ServerPath.canonical(refreshedPath) && revision > oldRevision) else {
                throw SyncV2GeneralConflictError.unsupported
            }
            var projection = child; projection.removeValue(forKey: "content")
            guard remoteBaseline.documents[remoteRow] == .object(projection) else { throw SyncV2GeneralConflictError.changed }
            projection["relative_path"] = old["relative_path"]; projection["structure_revision"] = old["structure_revision"]
            guard projection == old else { throw SyncV2GeneralConflictError.unsupported }
            normalizedDocuments[remoteRow] = .object(old)
        }
        guard try SyncV2PreparationSnapshot(folders: normalized, documents: normalizedDocuments,
            treeOrders: remoteBaseline.treeOrders).fingerprint() == local.baseline.fingerprint() else {
            throw SyncV2GeneralConflictError.unsupported
        }
        var ids: Set<UUID> = [detail.row.batchID], queueIDs: Set<Int64> = [detail.row.queueID]
        var previousQueueID: Int64 = 0
        var bytes = comparedBytes
        for follower in local.followers {
            bytes += follower.sourceJSON.utf8.count
            guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes,
                  follower.localProjectID == detail.localProjectID, follower.serverProjectID == detail.serverProjectID,
                  follower.row.queueID > previousQueueID, queueIDs.insert(follower.row.queueID).inserted,
                  ids.insert(follower.row.batchID).inserted, !follower.row.isQueueHead,
                  follower.row.sourceStatus == "waiting", follower.row.requestStatus == nil,
                  follower.requestJSON == nil, follower.responseJSON == nil, follower.resolutionJSON == nil else {
                throw SyncV2GeneralConflictError.unsupported
            }
            previousQueueID = follower.row.queueID
        }
        self.local = local; self.remote = remote; self.remoteBaseline = remoteBaseline; self.context = context
        self.authorizationFingerprint = authorizationFingerprint; self.entityID = folder.rawValue; self.isFolder = true
        self.savedName = name; self.remoteName = remoteName; self.remoteRevision = revision
        self.remotePath = try folderPath(folder.rawValue, renamed: remoteName)
        fingerprint = try SyncV2JSON.object([
            "source": .string(detail.sourceJSON), "request": .string(requestJSON), "remote": remote,
            "followers": .array(local.followers.map { .object(["queue_id": .int(Int($0.row.queueID)), "source": .string($0.sourceJSON)]) }),
            "baseline": .string(local.baseline.fingerprint()), "server_baseline": .string(remoteBaseline.fingerprint()),
            "account": .string(context.accountID.uuidString.lowercased()), "authorization": .string(authorizationFingerprint)
        ]).sha256Hex()
    }
}

protocol SyncV2GeneralConflictStoring: Sendable {
    func replaceGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID
    func replaceGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID
    func generalConflictLocal(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralConflictLocal
    func replaceGeneralConflict(_ review: SyncV2GeneralConflictReview,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID
}

protocol SyncV2GeneralConflictResolving: Sendable {
    func prepareGeneralRenameConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRenameConflictReview
    func keepSavedGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview) async throws -> UUID
    func prepareGeneralOrderConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralOrderConflictReview
    func keepSavedGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview) async throws -> UUID
    func prepareGeneralConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralConflictReview
    func keepSavedGeneralConflict(_ review: SyncV2GeneralConflictReview) async throws -> UUID
    func selectGeneralConflict(_ review: SyncV2GeneralConflictReview, content: String,
        saveLocal: @escaping SyncV2GeneralConflictLocalSaving) async throws -> UUID
}

typealias SyncV2GeneralConflictLocalSaving = @MainActor @Sendable (SyncV2GeneralConflictReview, String, @escaping @Sendable () throws -> Void) async throws -> UUID

extension SyncV2GeneralConflictResolving {
    func selectGeneralConflict(_ review: SyncV2GeneralConflictReview, content: String,
        saveLocal: @escaping SyncV2GeneralConflictLocalSaving) async throws -> UUID {
        throw SyncV2GeneralConflictError.unavailable
    }
}

extension LazySyncV2ProjectBindingStore: SyncV2GeneralConflictStoring {}

extension SyncV2GeneralConflictStoring {
    func replaceGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID { throw SyncV2GeneralConflictError.unavailable }
}

extension SyncV2GeneralConflictResolving {
    func prepareGeneralOrderConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralOrderConflictReview {
        throw SyncV2GeneralConflictError.unavailable
    }
    func keepSavedGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview) async throws -> UUID {
        throw SyncV2GeneralConflictError.unavailable
    }
}

extension SyncV2GeneralConflictStoring {
    func replaceGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID { throw SyncV2GeneralConflictError.unavailable }
}

extension SyncV2GeneralConflictResolving {
    func prepareGeneralRenameConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRenameConflictReview {
        throw SyncV2GeneralConflictError.unavailable
    }
    func keepSavedGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview) async throws -> UUID {
        throw SyncV2GeneralConflictError.unavailable
    }
}

/// 분할된 작업은 당시 원본과 단계를 함께 보관해 재시작 후 의미를 다시 추측하지 않는다.
enum SyncV2GeneralContractStep: String, Codable, Sendable {
    case folders, removeOrders, orders, create, update, delete, restore, structure, purge
}

/// 서버와 보관 구조를 UUID로 비교한다. 경로는 부모 사슬에서 검증하며 중간 이름 충돌도 피한다.
struct SyncV2GeneralTree {
    let folders: [UUID: [String: SyncV2JSON]]
    let documents: [UUID: [String: SyncV2JSON]]
    let orders: [UUID?: [String: SyncV2JSON]]

    init(_ snapshot: SyncV2PreparationSnapshot) throws {
        func indexed(_ rows: [SyncV2JSON], key: String) throws -> [UUID: [String: SyncV2JSON]] {
            var result: [UUID: [String: SyncV2JSON]] = [:]
            for row in rows {
                guard let f = row.objectValue, let id = f[key]?.stringValue.flatMap(UUID.init(uuidString:)), result[id] == nil else {
                    throw SyncV2GeneralConflictError.unsupported
                }
                result[id] = f
            }
            return result
        }
        folders = try indexed(snapshot.folders, key: "folder_id")
        documents = try indexed(snapshot.documents, key: "document_id")
        var orders: [UUID?: [String: SyncV2JSON]] = [:]
        for row in snapshot.treeOrders {
            guard let fields = row.objectValue, let _ = fields["tree_order_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw SyncV2GeneralConflictError.unsupported
            }
            let parent = try Self.parent(fields)
            guard orders[parent] == nil else { throw SyncV2GeneralConflictError.unsupported }
            orders[parent] = fields
        }
        self.orders = orders
    }

    static func parent(_ fields: [String: SyncV2JSON]) throws -> UUID? {
        if fields["parent_folder_id"] == .null { return nil }
        guard let id = fields["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw SyncV2GeneralConflictError.unsupported }
        return id
    }
    func folderPath(_ id: UUID, visited: Set<UUID> = []) throws -> String {
        guard !visited.contains(id), let f = folders[id], f["is_deleted"] == .bool(false), let name = f["name"]?.stringValue else {
            throw SyncV2GeneralConflictError.unsupported
        }
        _ = try SyncV2StorageName.normalize(name)
        if let parent = try Self.parent(f) { return try folderPath(parent, visited: visited.union([id])) + "/" + name }
        return name
    }
    func documentPath(_ f: [String: SyncV2JSON]) throws -> String {
        guard let name = f["name"]?.stringValue else { throw SyncV2GeneralConflictError.unsupported }
        _ = try SyncV2StorageName.normalize(name)
        return try Self.parent(f).map { try folderPath($0) + "/" + name } ?? name
    }
    var activeDocumentIDs: Set<UUID> {
        Set(documents.filter { $0.value["is_deleted"] == .bool(false) && $0.value["relative_path"]?.stringValue?.hasPrefix("__antigravity__/") != true }.keys)
    }
    var activeFolderIDs: Set<UUID> { Set(folders.filter { $0.value["is_deleted"] == .bool(false) }.keys) }
    func validateNames() throws {
        var names: [UUID?: Set<String>] = [:]
        for f in folders.filter({ activeFolderIDs.contains($0.key) }).map(\.value) + documents.filter({ activeDocumentIDs.contains($0.key) }).map(\.value) {
            let parent = try Self.parent(f)
            if let parent { _ = try folderPath(parent) }
            guard let name = f["name"]?.stringValue else { throw SyncV2GeneralConflictError.unsupported }
            let key = try SyncV2StorageName.normalize(name)
            guard names[parent, default: []].insert(key).inserted else { throw SyncV2GeneralConflictError.unsupported }
        }
        for id in activeFolderIDs { _ = try folderPath(id) }
    }
    func nodes(projectID: ProjectID) throws -> [DocumentNode] {
        try validateNames()
        func order(_ id: UUID, parent: UUID?) throws -> Int {
            guard let values = orders[parent]?["children"]?.arrayValue,
                  let index = values.firstIndex(of: .string(id.uuidString.lowercased())) else { throw SyncV2GeneralConflictError.unsupported }
            return index
        }
        var nodes: [DocumentNode] = []
        for id in activeFolderIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let parent = try Self.parent(folders[id]!)
            nodes.append(.init(id: .init(rawValue: id), projectID: projectID, kind: .folder, parentID: parent.map(DocumentID.init(rawValue:)),
                relativePath: .init(rawValue: try folderPath(id)), userOrder: try order(id, parent: parent), modifiedAt: Date(), contentHash: nil))
        }
        for id in activeDocumentIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let fields = documents[id]!, parent = try Self.parent(fields)
            nodes.append(.init(id: .init(rawValue: id), projectID: projectID, kind: .text, parentID: parent.map(DocumentID.init(rawValue:)),
                relativePath: .init(rawValue: try documentPath(fields)), userOrder: try order(id, parent: parent), modifiedAt: Date(), contentHash: nil))
        }
        for (parent, f) in orders {
            guard let children = f["children"]?.arrayValue else { throw SyncV2GeneralConflictError.unsupported }
            let expected = nodes.filter { $0.parentID?.rawValue == parent }.sorted { $0.userOrder < $1.userOrder }.map { SyncV2JSON.string($0.id.rawValue.uuidString.lowercased()) }
            guard expected == children, Set(children.compactMap(\.stringValue)).count == children.count else { throw SyncV2GeneralConflictError.unsupported }
        }
        return nodes
    }
}

struct SyncV2GeneralStructureReview: Sendable {
    let local: SyncV2GeneralConflictLocal
    let remoteBaseline: SyncV2PreparationSnapshot
    let remoteDocuments: [SyncV2JSON]
    let context: SyncV2HandshakeContext
    let authorizationFingerprint: String
    let fingerprint: String
    let savedNodes: [LocalStructureSnapshotNode]
    let serverNodes: [LocalStructureSnapshotNode]
    let repairsHistoricalPath: Bool
    var canAdoptServer: Bool {
        guard local.followers.isEmpty, !repairsHistoricalPath, local.detail.source.contractStep == nil else { return false }
        let paths = Dictionary(uniqueKeysWithValues: serverNodes.filter { $0.kind == .text }.map { ($0.id.rawValue, SyncV2ServerPath.canonical($0.relativePath.rawValue)) })
        // 수신은 서버 relative_path를 사용하므로 부모에서 계산한 미반영 경로를 선택 결과로 약속하지 않는다.
        return remoteDocuments.allSatisfy { value in
            guard let f = value.objectValue, let id = f["document_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let path = f["relative_path"]?.stringValue else { return false }
            return paths[id] == SyncV2ServerPath.canonical(path)
        }
    }

    init(local: SyncV2GeneralConflictLocal, remoteBaseline: SyncV2PreparationSnapshot, remoteDocuments: [SyncV2JSON],
         context: SyncV2HandshakeContext, authorizationFingerprint: String) throws {
        let detail = local.detail, old = try SyncV2GeneralTree(local.baseline), remote = try SyncV2GeneralTree(remoteBaseline)
        guard detail.row.isQueueHead, detail.row.isStructureReviewCandidate,
              context.localProjectID == detail.localProjectID, context.serverProjectID == detail.serverProjectID,
              old.activeDocumentIDs == remote.activeDocumentIDs, old.activeFolderIDs == remote.activeFolderIDs,
              Set(old.documents.keys) == Set(remote.documents.keys), Set(old.folders.keys) == Set(remote.folders.keys),
              local.records.count <= 1000 else { throw SyncV2GeneralConflictError.unsupported }
        if let json = detail.requestJSON {
            let request = try SyncV2ContractRequest(storedJSON: JSONDecoder().decode(SyncV2JSON.self, from: Data(json.utf8)))
            guard request.json.objectValue?["kind"] == .string("atomic_structure_commit_request"), request.orderedIntents.allSatisfy({
                let f = $0.objectValue ?? [:]
                return (f["entity_kind"] == .string("document") && ["rename", "move"].contains(f["intent_kind"]?.stringValue ?? "")) ||
                    (f["entity_kind"] == .string("folder") && ["update", "rename", "move"].contains(f["intent_kind"]?.stringValue ?? "")) ||
                    (f["entity_kind"] == .string("tree_order") && f["intent_kind"] == .string("reorder"))
            }) else { throw SyncV2GeneralConflictError.unsupported }
        }
        try remote.validateNames()
        let serverNodes = try remote.nodes(projectID: detail.localProjectID).map(LocalStructureSnapshotNode.init)
        let historical = detail.source.structureSnapshot == nil && detail.source.mutations.count == 1 && detail.requestJSON == nil
        let desired: [LocalStructureSnapshotNode]
        if historical {
            guard case .documentSnapshot(_, _, _, _, _, _, false) = detail.source.mutations[0],
                  let manuscript = try detail.manuscripts().first,
                  let fields = remote.documents[manuscript.documentID.rawValue],
                  SyncV2ServerPath.canonical(try remote.documentPath(fields)) == SyncV2ServerPath.canonical(manuscript.relativePath),
                  old.folders == remote.folders, old.orders == remote.orders else { throw SyncV2GeneralConflictError.unsupported }
            desired = serverNodes
        } else {
            guard let nodes = detail.source.structureSnapshot else { throw SyncV2GeneralConflictError.unsupported }
            desired = nodes.filter(\.isIncludedInTree)
        }
        guard Set(desired.filter { $0.kind == .folder }.map { $0.id.rawValue }) == old.activeFolderIDs,
              Set(desired.filter { $0.kind == .text }.map { $0.id.rawValue }) == old.activeDocumentIDs,
              Set(desired.map(\.id)).count == desired.count, desired.allSatisfy({ $0.projectID == detail.localProjectID }) else {
            throw SyncV2GeneralConflictError.unsupported
        }
        let bodies = try Dictionary(remoteDocuments.map { value -> (UUID, SyncV2JSON) in
            guard let id = value.objectValue?["document_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw SyncV2GeneralConflictError.unsupported }
            return (id, value)
        }, uniquingKeysWith: { _, _ in .null })
        guard Set(bodies.keys) == old.activeDocumentIDs else { throw SyncV2GeneralConflictError.unsupported }
        for (id, fields) in old.documents {
            guard var actual = remote.documents[id] else { throw SyncV2GeneralConflictError.unsupported }
            if old.activeDocumentIDs.contains(id) {
                guard let body = bodies[id]?.objectValue, let content = body["content"]?.stringValue,
                      content.utf8.count <= SyncV2Store.maximumContentByteCount,
                      actual["revision"] == fields["revision"], actual["is_deleted"] == fields["is_deleted"],
                      (actual["structure_revision"]?.intValue ?? 0) >= (fields["structure_revision"]?.intValue ?? 1) else { throw SyncV2GeneralConflictError.unsupported }
                if historical {
                    guard actual["name"] == fields["name"], actual["parent_folder_id"] == fields["parent_folder_id"],
                          actual["structure_revision"] == fields["structure_revision"] else { throw SyncV2GeneralConflictError.unsupported }
                }
                var projection = body; projection.removeValue(forKey: "content")
                guard projection == actual else { throw SyncV2GeneralConflictError.changed }
                if !historical, let manuscript = try detail.manuscripts().first(where: { $0.documentID.rawValue == id }) {
                    guard Data(manuscript.content.utf8) == Data(content.utf8) else { throw SyncV2GeneralConflictError.unsupported }
                }
                for key in ["name", "parent_folder_id", "relative_path", "structure_revision"] { actual[key] = fields[key] }
            }
            guard actual == fields else { throw SyncV2GeneralConflictError.unsupported }
        }
        for (id, fields) in old.folders {
            guard var actual = remote.folders[id] else { throw SyncV2GeneralConflictError.unsupported }
            if old.activeFolderIDs.contains(id) {
                guard (actual["revision"]?.intValue ?? 0) >= (fields["revision"]?.intValue ?? 1) else { throw SyncV2GeneralConflictError.unsupported }
                for key in ["name", "parent_folder_id", "revision"] { actual[key] = fields[key] }
            }
            guard actual == fields else { throw SyncV2GeneralConflictError.unsupported }
        }
        var orderIDs = Set<UUID>()
        for (parent, fields) in remote.orders {
            guard let id = fields["tree_order_id"]?.stringValue.flatMap(UUID.init(uuidString:)), orderIDs.insert(id).inserted,
                  fields["project_id"] == .string(context.serverProjectID.uuidString.lowercased()),
                  let revision = fields["revision"]?.intValue, revision > 0 else { throw SyncV2GeneralConflictError.unsupported }
            if let previous = old.orders[parent] {
                guard previous["tree_order_id"] == fields["tree_order_id"], revision >= (previous["revision"]?.intValue ?? 1) else { throw SyncV2GeneralConflictError.unsupported }
                var normalized = fields
                normalized["children"] = previous["children"]; normalized["revision"] = previous["revision"]
                guard normalized == previous else { throw SyncV2GeneralConflictError.unsupported }
            }
        }
        guard Set(old.orders.keys).isSubset(of: Set(remote.orders.keys)) else { throw SyncV2GeneralConflictError.unsupported }
        var bytes = try remoteDocuments.reduce(0) { try $0 + $1.canonicalJSON().utf8.count }
        var batchIDs = Set<UUID>(), queueIDs = Set<Int64>()
        for record in local.records {
            bytes += record.sourceJSON.utf8.count + (record.requestJSON?.utf8.count ?? 0) + (record.responseJSON?.utf8.count ?? 0)
            guard bytes <= SyncV2GeneralRecoveryDetail.maximumRecordBytes, batchIDs.insert(record.row.batchID).inserted,
                  queueIDs.insert(record.row.queueID).inserted,
                  record.localProjectID == detail.localProjectID, record.serverProjectID == detail.serverProjectID else { throw SyncV2GeneralConflictError.unsupported }
        }
        guard local.followers.allSatisfy({ $0.row.sourceStatus == "waiting" && $0.requestJSON == nil && $0.responseJSON == nil && $0.resolutionJSON == nil }) else {
            throw SyncV2GeneralConflictError.unsupported
        }
        self.local = local; self.remoteBaseline = remoteBaseline; self.remoteDocuments = remoteDocuments; self.context = context
        self.savedNodes = desired; self.serverNodes = serverNodes; self.repairsHistoricalPath = historical
        self.authorizationFingerprint = authorizationFingerprint
        fingerprint = try SyncV2JSON.object(["source": .string(detail.sourceJSON), "request": detail.requestJSON.map(SyncV2JSON.string) ?? .null,
            "local": .string(local.baseline.fingerprint()), "remote": .string(remoteBaseline.fingerprint()), "bodies": .array(remoteDocuments),
            "tail": .array(local.followers.map { .string($0.sourceJSON) }), "auth": .string(authorizationFingerprint),
            "account": .string(context.accountID.uuidString.lowercased())]).sha256Hex()
    }
}

extension SyncV2GeneralTree {
    func replacingStructure(with nodes: [LocalStructureSnapshotNode], projectID: UUID) throws -> SyncV2PreparationSnapshot {
        var fs = folders, ds = documents
        for node in nodes {
            let id = node.id.rawValue
            var fields = node.kind == .folder ? fs[id] : ds[id]
            guard fields != nil else { throw SyncV2GeneralConflictError.unsupported }
            fields!["parent_folder_id"] = node.parentID.map { .string($0.rawValue.uuidString.lowercased()) } ?? .null
            fields!["name"] = .string((node.relativePath.rawValue as NSString).lastPathComponent)
            if node.kind == .text { fields!["relative_path"] = .string(SyncV2ServerPath.canonical(node.relativePath.rawValue)) }
            if node.kind == .folder { fs[id] = fields } else { ds[id] = fields }
        }
        let parents = Set(orders.keys).union([nil]).union(nodes.filter { $0.kind == .folder }.map { Optional($0.id.rawValue) })
        let os: [SyncV2JSON] = parents.map { parent in
            var f = orders[parent] ?? ["tree_order_id": .string(syncV2UUIDv5(namespace: projectID, name: "tree-order:\(parent?.uuidString.lowercased() ?? "root")").uuidString.lowercased()),
                "project_id": .string(projectID.uuidString.lowercased()), "parent_folder_id": parent.map { .string($0.uuidString.lowercased()) } ?? .null, "revision": .int(0)]
            let children = nodes.filter { $0.parentID?.rawValue == parent }.sorted {
                $0.userOrder == $1.userOrder ? $0.relativePath.rawValue < $1.relativePath.rawValue : $0.userOrder < $1.userOrder
            }
            f["children"] = .array(children.map { .string($0.id.rawValue.uuidString.lowercased()) })
            return .object(f)
        }
        let snapshot = SyncV2PreparationSnapshot(folders: fs.keys.sorted { $0.uuidString < $1.uuidString }.map { .object(fs[$0]!) },
            documents: ds.keys.sorted { $0.uuidString < $1.uuidString }.map { .object(ds[$0]!) }, treeOrders: os)
        let tree = try SyncV2GeneralTree(snapshot); try tree.validateNames()
        for node in nodes {
            let path = try node.kind == .folder ? tree.folderPath(node.id.rawValue) : tree.documentPath(ds[node.id.rawValue]!)
            guard SyncV2ServerPath.canonical(path) == SyncV2ServerPath.canonical(node.relativePath.rawValue) else { throw SyncV2GeneralConflictError.unsupported }
        }
        return snapshot
    }
}

protocol SyncV2GeneralStructureResolving: Sendable {
    func prepareGeneralStructureConflict(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralStructureReview
    func resolveGeneralStructureConflict(_ review: SyncV2GeneralStructureReview, adoptServer: Bool,
        validateLocal: (@Sendable (SyncV2GeneralStructureReview) async throws -> Void)?) async throws -> UUID
}
protocol SyncV2GeneralStructureStoring: Sendable {
    func replaceGeneralStructureConflict(_ review: SyncV2GeneralStructureReview, adoptServer: Bool,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID
}

extension LazySyncV2ProjectBindingStore: SyncV2GeneralStructureStoring {}
