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
/// 로컬에 적어 둔 계약 tree_order 한 줄이다. 쓰기 전에 `serverRevision`을 base로
/// 싣고, `children`으로 서버가 아는 목록을 확인한다.
struct SyncV2StoredTreeOrder: Equatable, Sendable {
    let treeOrderID: UUID
    let parentFolderID: UUID?
    let children: [UUID]
    let serverRevision: Int64
}

/// 계약이 정한 tree_order 한 줄이다.
///
/// 자식을 이름이 아니라 `folder_id`/`document_id`로 적는다. 이름으로 두면 이름이
/// 바뀌는 순간 순서가 어느 것을 가리키는지 알 수 없다. 그리고 revision은 우리가
/// 만들어낼 수 없는 값이라, 이 줄을 받아 두지 않으면 순서를 안전하게 쓸 수 없다.
struct SyncV2RemoteTreeOrder: Codable, Equatable, Sendable {
    let treeOrderID: UUID
    /// `nil`이면 작품 최상위다.
    let parentFolderID: UUID?
    let children: [UUID]
    let revision: Int64
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case treeOrderID = "tree_order_id"
        case parentFolderID = "parent_folder_id"
        case children
        case revision
        case updatedAt = "updated_at"
    }
}


/// 서버 folders 한 줄이다. 문서와 달리 본문도 경로도 없다. 위치는
/// parentFolderID 사슬로만 나타내므로, 경로는 받는 쪽에서 이름을 이어 붙여
/// 만든다. 그래야 이름이 바뀌어도 같은 폴더임을 알아볼 수 있다.
struct SyncV2RemoteFolder: Codable, Equatable, Sendable {
    let folderID: UUID
    let parentFolderID: UUID?
    let name: String
    let revision: Int64
    let isDeleted: Bool
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case folderID = "folder_id"
        case parentFolderID = "parent_folder_id"
        case name
        case revision
        case isDeleted = "is_deleted"
        case updatedAt = "updated_at"
    }

    init(
        folderID: UUID,
        parentFolderID: UUID?,
        name: String,
        revision: Int64,
        isDeleted: Bool,
        updatedAt: Date
    ) {
        self.folderID = folderID
        self.parentFolderID = parentFolderID
        self.name = name
        self.revision = revision
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folderID = try values.decode(UUID.self, forKey: .folderID)
        parentFolderID = try values.decodeIfPresent(
            UUID.self,
            forKey: .parentFolderID
        )
        name = try values.decode(String.self, forKey: .name)
        revision = try values.decode(Int64.self, forKey: .revision)
        isDeleted = try values.decode(Bool.self, forKey: .isDeleted)
        updatedAt = try SyncV2RemoteFolder.decodeDate(
            values,
            key: .updatedAt
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(folderID, forKey: .folderID)
        try values.encode(parentFolderID, forKey: .parentFolderID)
        try values.encode(name, forKey: .name)
        try values.encode(revision, forKey: .revision)
        try values.encode(isDeleted, forKey: .isDeleted)
        try values.encode(
            SyncV2RemoteFolder.encodeDate(updatedAt),
            forKey: .updatedAt
        )
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
    /// 서버가 같은 경로를 다른 문서에 이미 내준 상태다. `conflict` 상태
    /// operation은 진행 중으로도 집계되므로, 이 값이 없으면 사용자에게는
    /// 끝나지 않는 "동기화 중"으로만 보인다.
    var hasPathCollision: Bool = false
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
    /// 구조를 적용하지 못하게 만든 이름과 사유다. merge reason은 문자열 raw
    /// value라 값을 담을 수 없어 보고서로 따로 올린다. 이것이 없으면 사용자는
    /// 무엇을 고쳐야 할지 알 수 없어 상태에서 빠져나올 수 없다.
    var rejectedStructureNames: [SyncV2RejectedStructureName] = []
}

struct SyncV2RejectedStructureName: Equatable, Sendable {
    let name: String
    let parent: String
    let reason: String
}

/// Watchdog와 실제 작업 중 먼저 끝난 값을 한 번만 채택하는 one-shot Race다.
/// `value()`의 대기는 의도적으로 취소 불가다. 참여 작업 또는 watchdog이
/// 반드시 `resolve`하므로 취소된 대기자를 별도로 제거하지 않는 것이 정상이다.
/// 상호 배제 Gate에는 사용하지 말고 반드시 보유 시간 상한을 적용해야 한다.
