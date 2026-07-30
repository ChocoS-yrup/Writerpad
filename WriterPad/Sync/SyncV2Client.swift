import CryptoKit
import Foundation
import Supabase

enum SyncV2RemoteErrorCode: String, Codable, Error, CaseIterable, Sendable {
    case authRequired = "AUTH_REQUIRED"
    case forbidden = "FORBIDDEN"
    case invalidArgument = "INVALID_ARGUMENT"
    case documentNotFound = "DOCUMENT_NOT_FOUND"
    case documentAlreadyExists = "DOCUMENT_ALREADY_EXISTS"
    case revisionConflict = "REVISION_CONFLICT"
    case operationIDReused = "OPERATION_ID_REUSED"
    case leaseRequired = "LEASE_REQUIRED"
    case leaseConflict = "LEASE_CONFLICT"
    case leaseExpired = "LEASE_EXPIRED"
    case pathConflict = "PATH_CONFLICT"
}

struct SyncV2RemoteRejection: Equatable, Sendable {
    let postgresCode: String?
    let message: String
    let detail: String?
}

enum SyncV2ClientError: Error, Equatable, Sendable {
    case remote(code: SyncV2RemoteErrorCode, detail: String?)
    case networkUnavailable
    case timedOut
    case invalidResponse
    case serverRejected(SyncV2RemoteRejection)
}

struct SyncV2CommitDocumentParameters: Encodable, Equatable, Sendable {
    let documentID: UUID
    let projectID: UUID
    let baseServerRevision: Int64
    let operationID: UUID
    let deviceID: UUID
    let relativePath: String
    let content: String
    let isDeleted: Bool
    let leaseToken: UUID?

    init(
        documentID: UUID,
        projectID: UUID,
        baseServerRevision: Int64,
        operationID: UUID,
        deviceID: UUID,
        relativePath: String,
        content: String,
        isDeleted: Bool,
        leaseToken: UUID?
    ) {
        self.documentID = documentID
        self.projectID = projectID
        self.baseServerRevision = baseServerRevision
        self.operationID = operationID
        self.deviceID = deviceID
        self.relativePath = SyncV2ServerPath.canonical(relativePath)
        self.content = content
        self.isDeleted = isDeleted
        self.leaseToken = leaseToken
    }

    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case projectID = "p_project_id"
        case baseServerRevision = "p_base_revision"
        case operationID = "p_operation_id"
        case deviceID = "p_device_id"
        case relativePath = "p_relative_path"
        case content = "p_content"
        case isDeleted = "p_is_deleted"
        case leaseToken = "p_lease_token"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(projectID, forKey: .projectID)
        try values.encode(baseServerRevision, forKey: .baseServerRevision)
        try values.encode(operationID, forKey: .operationID)
        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(content, forKey: .content)
        try values.encode(isDeleted, forKey: .isDeleted)
        try values.encode(leaseToken, forKey: .leaseToken)
    }
}

enum SyncV2CommitStatus: String, Decodable, Equatable, Sendable {
    case committed
    case replayed
}

enum SyncV2RemoteOperationKind: String, Decodable, Equatable, Sendable {
    case create
    case update
    case move
    case delete
    case restore
}

struct SyncV2CommitDocumentResult: Decodable, Equatable, Sendable {
    let status: SyncV2CommitStatus
    let documentID: UUID
    let versionID: UUID
    let operationID: UUID
    let operationKind: SyncV2RemoteOperationKind
    let serverRevision: Int64
    let relativePath: String
    let isDeleted: Bool
    let contentHash: String
    let committedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case documentID = "document_id"
        case versionID = "version_id"
        case operationID = "operation_id"
        case operationKind = "operation_kind"
        case serverRevision = "revision"
        case relativePath = "relative_path"
        case isDeleted = "is_deleted"
        case contentHash = "content_hash"
        case committedAt = "committed_at"
    }

    init(
        status: SyncV2CommitStatus,
        documentID: UUID,
        versionID: UUID,
        operationID: UUID,
        operationKind: SyncV2RemoteOperationKind,
        serverRevision: Int64,
        relativePath: String,
        isDeleted: Bool,
        contentHash: String,
        committedAt: Date
    ) {
        self.status = status
        self.documentID = documentID
        self.versionID = versionID
        self.operationID = operationID
        self.operationKind = operationKind
        self.serverRevision = serverRevision
        self.relativePath = relativePath
        self.isDeleted = isDeleted
        self.contentHash = contentHash
        self.committedAt = committedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(SyncV2CommitStatus.self, forKey: .status)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        versionID = try values.decode(UUID.self, forKey: .versionID)
        operationID = try values.decode(UUID.self, forKey: .operationID)
        operationKind = try values.decode(
            SyncV2RemoteOperationKind.self,
            forKey: .operationKind
        )
        serverRevision = try values.decode(Int64.self, forKey: .serverRevision)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        isDeleted = try values.decode(Bool.self, forKey: .isDeleted)
        contentHash = try values.decode(String.self, forKey: .contentHash)
        let timestamp = try values.decode(String.self, forKey: .committedAt)
        guard let date = Self.decodeTimestamp(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .committedAt,
                in: values,
                debugDescription: "Invalid committed_at timestamp."
            )
        }
        committedAt = date
    }

    private static func decodeTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }
}

enum SyncV2CommitTransportError: Error, Equatable, Sendable {
    case postgrest(
        message: String,
        postgresCode: String?,
        detail: String?
    )
    case url(code: URLError.Code)
    case invalidResponse
    case unknown(message: String)
}

protocol SyncV2CommitTransporting: Sendable {
    func commitDocument(
        parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult
}

protocol SyncV2CommitClienting: Sendable {
    func commitDocument(
        _ parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult
}

actor LiveSyncV2CommitTransport: SyncV2CommitTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func commitDocument(
        parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult {
        do {
            let response: PostgrestResponse<SyncV2CommitDocumentResult> =
                try await client
                    .rpc("commit_document", params: parameters)
                    .execute()
            return response.value
        } catch let error as PostgrestError {
            throw SyncV2CommitTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2CommitTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2CommitTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2CommitTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2CommitTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }
}

actor SyncV2Client: SyncV2CommitClienting {
    private let transport: any SyncV2CommitTransporting

    init(transport: any SyncV2CommitTransporting) {
        self.transport = transport
    }

    func commitDocument(
        _ parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult {
        guard Self.isValid(parameters) else {
            throw SyncV2ClientError.remote(
                code: .invalidArgument,
                detail: nil
            )
        }
        do {
            let response = try await transport.commitDocument(
                parameters: parameters
            )
            guard Self.isValid(response, for: parameters) else {
                throw SyncV2ClientError.invalidResponse
            }
            return response
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2CommitTransportError {
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

    static func classify(
        _ error: SyncV2CommitTransportError
    ) -> SyncV2ClientError {
        switch error {
        case let .postgrest(message, postgresCode, detail):
            if let code = SyncV2RemoteErrorCode(rawValue: message) {
                return .remote(code: code, detail: detail)
            }
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
            if code == .timedOut {
                return .timedOut
            }
            if code == .userAuthenticationRequired {
                return .remote(code: .authRequired, detail: nil)
            }
            return .networkUnavailable
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

    private static func isValid(
        _ parameters: SyncV2CommitDocumentParameters
    ) -> Bool {
        guard parameters.baseServerRevision >= 0,
              parameters.baseServerRevision < Int64.max,
              parameters.content.utf8.count
                <= SyncV2Store.maximumContentByteCount,
              isValidServerPath(parameters.relativePath)
        else { return false }
        if parameters.baseServerRevision == 0 {
            return !parameters.isDeleted && parameters.leaseToken == nil
        }
        return parameters.leaseToken != nil
    }

    static func isValidServerPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == path.trimmingCharacters(in: .whitespacesAndNewlines),
              path.unicodeScalars.count <= 1_024,
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("\\"),
              !path.contains("//")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { $0 != "." && $0 != ".." }
    }

    private static func isValid(
        _ response: SyncV2CommitDocumentResult,
        for parameters: SyncV2CommitDocumentParameters
    ) -> Bool {
        let expectedHash = SHA256.hash(data: Data(parameters.content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard response.documentID == parameters.documentID,
              response.operationID == parameters.operationID,
              SyncV2ServerPath.hasExactBytes(
                  response.relativePath,
                  parameters.relativePath
              ),
              response.isDeleted == parameters.isDeleted,
              response.contentHash == expectedHash,
              response.contentHash == response.contentHash.lowercased(),
              ContentHash(rawValue: response.contentHash) != nil,
              response.serverRevision == parameters.baseServerRevision + 1
        else { return false }
        if parameters.baseServerRevision == 0 {
            return response.operationKind == .create
        }
        return response.operationKind != .create
    }
}
