import Foundation

struct SyncV2RemoteDocumentSnapshot: Codable, Equatable, Sendable {
    let documentID: UUID
    let relativePath: String
    let content: String
    let revision: Int64
    let isDeleted: Bool
    let deletedAt: Date?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case relativePath = "relative_path"
        case content
        case revision
        case isDeleted = "is_deleted"
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
    }

    init(
        documentID: UUID,
        relativePath: String,
        content: String,
        revision: Int64,
        isDeleted: Bool,
        deletedAt: Date?,
        updatedAt: Date
    ) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.content = content
        self.revision = revision
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        content = try values.decode(String.self, forKey: .content)
        revision = try values.decode(Int64.self, forKey: .revision)
        isDeleted = try values.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try Self.decodeOptionalDate(
            values,
            key: .deletedAt
        )
        updatedAt = try Self.decodeDate(values, key: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(content, forKey: .content)
        try values.encode(revision, forKey: .revision)
        try values.encode(isDeleted, forKey: .isDeleted)
        try values.encode(
            deletedAt.map(Self.encodeDate),
            forKey: .deletedAt
        )
        try values.encode(
            Self.encodeDate(updatedAt),
            forKey: .updatedAt
        )
    }

    private static func decodeOptionalDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        guard try !values.decodeNil(forKey: key) else { return nil }
        return try decodeDate(values, key: key)
    }

    private static func decodeDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date {
        let value = try values.decode(String.self, forKey: key)
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
        guard let date = seconds.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Invalid server timestamp."
            )
        }
        return date
    }

    private static func encodeDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}

struct SyncV2SnapshotLocalState: Equatable, Sendable {
    let serverRevision: Int64
    let serverPath: String
    let hasActiveOperation: Bool
    let hasUnresolvedConflict: Bool
    let blockingErrorCode: String?
}

struct SyncV2EditingGuard: Equatable, Sendable {
    let isOpen: Bool
    let isDirty: Bool
    let isComposing: Bool

    static let closed = SyncV2EditingGuard(
        isOpen: false,
        isDirty: false,
        isComposing: false
    )
}

enum SyncV2SnapshotMergeReason:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable {
    case pendingOperation
    case blockedOperation
    case unresolvedConflict
    case dirtyEditor
    case markedTextComposition
    case remoteDeletion
    case pathOccupiedByDifferentDocument
    case invalidLocalHierarchy
}

struct SyncV2SnapshotMergeCandidate: Codable, Equatable, Sendable {
    let localProjectID: ProjectID
    let serverProjectID: UUID
    let snapshot: SyncV2RemoteDocumentSnapshot
    let reason: SyncV2SnapshotMergeReason
}

enum SyncV2SnapshotPullOutcome: Equatable, Sendable {
    case applied(documentID: UUID, revision: Int64, wasOpen: Bool)
    case upToDate(documentID: UUID, revision: Int64)
    case mergeRequired(
        documentID: UUID,
        revision: Int64,
        reason: SyncV2SnapshotMergeReason
    )
}

struct SyncV2SnapshotPullReport: Equatable, Sendable {
    let outcomes: [SyncV2SnapshotPullOutcome]
    let appliedSnapshots: [SyncV2RemoteDocumentSnapshot]
}

/// Watchdog와 실제 작업 중 먼저 끝난 값을 한 번만 채택하는 one-shot Race다.
/// `value()`의 대기는 의도적으로 취소 불가다. 참여 작업 또는 watchdog이
/// 반드시 `resolve`하므로 취소된 대기자를 별도로 제거하지 않는 것이 정상이다.
/// 상호 배제 Gate에는 사용하지 말고 반드시 보유 시간 상한을 적용해야 한다.
