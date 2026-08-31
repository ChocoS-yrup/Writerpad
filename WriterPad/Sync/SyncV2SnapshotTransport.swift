import Foundation
import Supabase

enum SyncV2SnapshotTransportError: Error, Equatable, Sendable {
    case postgrest(message: String, postgresCode: String?, detail: String?)
    case url(code: URLError.Code)
    case invalidResponse
    case unknown(message: String)
}

protocol SyncV2SnapshotTransporting: Sendable {
    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry]
    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot?
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder]
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder]
}

extension SyncV2SnapshotTransporting {
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        try await fetchDocuments(projectID: projectID).first {
            $0.documentID == documentID
        }
    }

    /// 두 단계를 나누지 않는 구현은 한 번에 받은 결과에서 표만 뽑는다.
    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        try await fetchDocuments(projectID: projectID).map(\.manifestEntry)
    }

    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        let wanted = Set(documentIDs)
        guard !wanted.isEmpty else { return [] }
        return try await fetchDocuments(projectID: projectID).filter {
            wanted.contains($0.documentID)
        }
    }

    /// 폴더 표를 아직 읽지 않는 구현은 빈 목록을 준다. 서버에 없는 폴더라는
    /// 이유만으로 로컬 폴더를 지우지 않으므로 빈 목록은 아무 일도 하지 않는다.
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] {
        _ = projectID
        return []
    }

}

protocol SyncV2SnapshotClienting: Sendable {
    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry]
    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot?
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder]
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder]
}

extension SyncV2SnapshotClienting {
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        try await fetchDocuments(projectID: projectID).first {
            $0.documentID == documentID
        }
    }

    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        try await fetchDocuments(projectID: projectID).map(\.manifestEntry)
    }

    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        let wanted = Set(documentIDs)
        guard !wanted.isEmpty else { return [] }
        return try await fetchDocuments(projectID: projectID).filter {
            wanted.contains($0.documentID)
        }
    }

    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] {
        _ = projectID
        return []
    }

}

actor LiveSyncV2SnapshotTransport: SyncV2SnapshotTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    private func executeRows<Row: Decodable>(
        _ builder: PostgrestFilterBuilder,
        stage: String,
        as type: Row.Type
    ) async throws -> [Row] {
        _ = type
        if let context = SyncV2PullDiagnostics.current {
            builder
                .setHeader(
                    name: SyncV2PullDiagnostics.pullIDHeader,
                    value: context.pullID.uuidString
                )
                .setHeader(
                    name: SyncV2PullDiagnostics.pullOriginHeader,
                    value: context.origin
                )
                .setHeader(
                    name: SyncV2PullDiagnostics.pullStageHeader,
                    value: stage
                )
                .setHeader(
                    name: SyncV2PullDiagnostics.pullStartHeader,
                    value: String(context.startedAtNanoseconds)
                )
        }
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        SyncV2PullDiagnostics.record(
            stage: stage,
            phase: "request-start"
        )
        let response: PostgrestResponse<Void> = try await builder.execute()
        SyncV2PullDiagnostics.record(
            stage: stage,
            phase: "response-received",
            startedAtNanoseconds: requestStartedAt,
            payloadBytes: response.data.count
        )
        let decodeStartedAt = DispatchTime.now().uptimeNanoseconds
        let rows = try PostgrestClient.Configuration.jsonDecoder.decode(
            [Row].self,
            from: response.data
        )
        SyncV2PullDiagnostics.record(
            stage: stage,
            phase: "decode-finished",
            startedAtNanoseconds: decodeStartedAt,
            rowCount: rows.count,
            payloadBytes: response.data.count
        )
        return rows
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        do {
            return try await executeRows(
                client
                .from("documents")
                .select(
                    """
                    document_id,relative_path,content,revision,is_deleted,\
                    deleted_at,updated_at
                    """
                )
                .eq("project_id", value: projectID.uuidString.lowercased()),
                stage: "documents",
                as: SyncV2RemoteDocumentSnapshot.self
            )
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }

    /// 본문을 뺀 문서 표를 받는다. 변경 판정에 필요한 필드만 담긴다.
    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        do {
            return try await executeRows(
                client
                .from("documents")
                .select(
                    """
                    document_id,relative_path,revision,is_deleted,\
                    deleted_at,updated_at
                    """
                )
                .eq("project_id", value: projectID.uuidString.lowercased()),
                stage: "document-manifest",
                as: SyncV2RemoteDocumentManifestEntry.self
            )
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }

    /// UUID 목록은 질의 문자열에 그대로 들어간다. 한 요청에 다 넣으면 URL이
    /// 서버·중간 장비의 상한을 넘길 수 있으므로 나눠 보낸다.
    static let contentFetchChunkSize = 80

    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        let identifiers = Array(Set(documentIDs))
        guard !identifiers.isEmpty else { return [] }
        var collected: [SyncV2RemoteDocumentSnapshot] = []
        collected.reserveCapacity(identifiers.count)
        var index = 0
        while index < identifiers.count {
            let end = min(
                index + Self.contentFetchChunkSize,
                identifiers.count
            )
            let chunk = identifiers[index..<end].map {
                $0.uuidString.lowercased()
            }
            index = end
            do {
                let rows = try await executeRows(
                    client
                    .from("documents")
                    .select(
                        """
                        document_id,relative_path,content,revision,\
                        is_deleted,deleted_at,updated_at
                        """
                    )
                    .eq(
                        "project_id",
                        value: projectID.uuidString.lowercased()
                    )
                    .in("document_id", values: chunk),
                    stage: "document-contents",
                    as: SyncV2RemoteDocumentSnapshot.self
                )
                collected.append(contentsOf: rows)
            } catch let error as PostgrestError {
                throw SyncV2SnapshotTransportError.postgrest(
                    message: error.message,
                    postgresCode: error.code,
                    detail: error.detail
                )
            } catch let error as URLError {
                throw SyncV2SnapshotTransportError.url(code: error.code)
            } catch is DecodingError {
                throw SyncV2SnapshotTransportError.invalidResponse
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain {
                    throw SyncV2SnapshotTransportError.url(
                        code: URLError.Code(rawValue: nsError.code)
                    )
                }
                throw SyncV2SnapshotTransportError.unknown(
                    message: error.localizedDescription
                )
            }
        }
        return collected
    }

    /// 계약 tree_order를 서버가 말한 그대로 받아 온다.
    ///
    /// 이름이 아니라 id 목록이라 이름이 바뀌어도 순서가 끊기지 않고, revision은
    /// 쓰기 전에 반드시 있어야 하는 값이다. 없으면 base를 0으로 보내게 되고 서버가
    /// REVISION_CONFLICT로 막는다.
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        do {
            return try await executeRows(
                client
                    .from("tree_orders")
                    .select(
                        "tree_order_id,parent_folder_id,children,revision,updated_at"
                    )
                    .eq(
                        "project_id",
                        value: projectID.uuidString.lowercased()
                    ),
                stage: "tree-orders",
                as: SyncV2RemoteTreeOrder.self
            )
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }

    func fetchFolders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteFolder] {
        do {
            return try await executeRows(
                client
                    .from("folders")
                    .select(
                        """
                        folder_id,parent_folder_id,name,revision,\
                        is_deleted,updated_at
                        """
                    )
                    .eq(
                        "project_id",
                        value: projectID.uuidString.lowercased()
                    ),
                stage: "folders",
                as: SyncV2RemoteFolder.self
            )
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        do {
            let response: PostgrestResponse<
                [SyncV2RemoteDocumentSnapshot]
            > = try await client
                .from("documents")
                .select(
                    """
                    document_id,relative_path,content,revision,is_deleted,\
                    deleted_at,updated_at
                    """
                )
                .eq("project_id", value: projectID.uuidString.lowercased())
                .eq(
                    "document_id",
                    value: documentID.uuidString.lowercased()
                )
                .limit(1)
                .execute()
            return response.value.first
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }
}

actor SyncV2SnapshotClient: SyncV2SnapshotClienting {
    private let transport: any SyncV2SnapshotTransporting

    init(transport: any SyncV2SnapshotTransporting) {
        self.transport = transport
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        do {
            let documents = try await transport.fetchDocuments(
                projectID: projectID
            )
            var identifiers = Set<UUID>()
            for snapshot in documents {
                guard identifiers.insert(snapshot.documentID).inserted,
                      Self.isValid(snapshot)
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            return documents.sorted {
                $0.documentID.uuidString < $1.documentID.uuidString
            }
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        do {
            let entries = try await transport.fetchDocumentManifest(
                projectID: projectID
            )
            var identifiers = Set<UUID>()
            for entry in entries {
                guard identifiers.insert(entry.documentID).inserted,
                      Self.isValid(entry)
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            return entries.sorted {
                $0.documentID.uuidString < $1.documentID.uuidString
            }
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.invalidResponse
        }
    }

    /// 요청한 UUID가 하나라도 빠지거나 겹쳐 오면 표와 본문을 짝지을 수 없다.
    /// 반쯤 맞는 결과로 진행하지 않고 실패로 돌린다.
    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        let requested = Set(documentIDs)
        guard !requested.isEmpty else { return [] }
        do {
            let rows = try await transport.fetchDocumentContents(
                projectID: projectID,
                documentIDs: Array(requested)
            )
            var identifiers = Set<UUID>()
            for row in rows {
                guard identifiers.insert(row.documentID).inserted,
                      requested.contains(row.documentID),
                      Self.isValid(row)
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            guard identifiers == requested else {
                throw SyncV2ClientError.invalidResponse
            }
            return rows.sorted {
                $0.documentID.uuidString < $1.documentID.uuidString
            }
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.invalidResponse
        }
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        do {
            guard let snapshot = try await transport.fetchDocument(
                projectID: projectID,
                documentID: documentID
            ) else {
                return nil
            }
            guard snapshot.documentID == documentID,
                  Self.isValid(snapshot)
            else {
                throw SyncV2ClientError.invalidResponse
            }
            return snapshot
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    /// 계약 tree_order를 그대로 넘긴다. 한 부모에 줄이 둘 오면 어느 쪽이 참인지
    /// 고를 수 없으므로 거절한다. revision이 1 미만인 줄도 계약이 허용하지 않는다.
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        do {
            let treeOrders = try await transport.fetchTreeOrders(
                projectID: projectID
            )
            var parents = Set<UUID?>()
            for treeOrder in treeOrders {
                guard
                    parents.insert(treeOrder.parentFolderID).inserted,
                    treeOrder.revision >= 1,
                    Set(treeOrder.children).count == treeOrder.children.count
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            return treeOrders
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    func fetchFolders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteFolder] {
        do {
            let folders = try await transport.fetchFolders(
                projectID: projectID
            )
            var identifiers = Set<UUID>()
            for folder in folders {
                guard identifiers.insert(folder.folderID).inserted,
                      Self.isValid(folder)
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            // 부모가 먼저 오도록 정렬하지 않는다. 사슬은 받는 쪽에서 풀고,
            // 순서에 기대면 서버가 준 순서가 바뀔 때 조용히 어긋난다.
            return folders.sorted {
                $0.folderID.uuidString < $1.folderID.uuidString
            }
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    private static func isValid(_ folder: SyncV2RemoteFolder) -> Bool {
        guard folder.revision > 0,
              folder.parentFolderID != folder.folderID,
              SyncV2Client.isValidFolderName(folder.name)
        else { return false }
        return true
    }

    private static func isValid(
        _ entry: SyncV2RemoteDocumentManifestEntry
    ) -> Bool {
        guard entry.revision > 0,
              SyncV2Client.isValidServerPath(entry.relativePath)
        else { return false }
        return entry.isDeleted
            ? entry.deletedAt != nil
            : entry.deletedAt == nil
    }

    private static func isValid(
        _ snapshot: SyncV2RemoteDocumentSnapshot
    ) -> Bool {
        guard snapshot.revision > 0,
              snapshot.content.utf8.count
                <= SyncV2Store.maximumContentByteCount,
              SyncV2Client.isValidServerPath(snapshot.relativePath)
        else { return false }
        return snapshot.isDeleted
            ? snapshot.deletedAt != nil
            : snapshot.deletedAt == nil
    }

    private static func classify(
        _ error: SyncV2SnapshotTransportError
    ) -> SyncV2ClientError {
        switch error {
        case let .postgrest(message, postgresCode, detail):
            if postgresCode == "42501" {
                return .remote(code: .forbidden, detail: detail)
            }
            if postgresCode == "PGRST301" || postgresCode == "PGRST302" {
                return .remote(code: .authRequired, detail: detail)
            }
            return .serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: postgresCode,
                    message: message,
                    detail: detail
                )
            )
        case .url(let code):
            return code == .timedOut ? .timedOut : .networkUnavailable
        case .invalidResponse:
            return .invalidResponse
        case .unknown(let message):
            return .serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: message,
                    detail: nil
                )
            )
        }
    }
}
