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
}

protocol SyncV2SnapshotClienting: Sendable {
    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot?
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

