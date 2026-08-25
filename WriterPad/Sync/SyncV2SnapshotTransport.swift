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

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
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
                .execute()
            return response.value
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

    /// 계약 tree_order를 서버가 말한 그대로 받아 온다.
    ///
    /// 이름이 아니라 id 목록이라 이름이 바뀌어도 순서가 끊기지 않고, revision은
    /// 쓰기 전에 반드시 있어야 하는 값이다. 없으면 base를 0으로 보내게 되고 서버가
    /// REVISION_CONFLICT로 막는다.
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        do {
            let response: PostgrestResponse<[SyncV2RemoteTreeOrder]> =
                try await client
                    .from("tree_orders")
                    .select(
                        "tree_order_id,parent_folder_id,children,revision,updated_at"
                    )
                    .eq(
                        "project_id",
                        value: projectID.uuidString.lowercased()
                    )
                    .execute()
            return response.value
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
            let response: PostgrestResponse<[SyncV2RemoteFolder]> =
                try await client
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
                    )
                    .execute()
            return response.value
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
