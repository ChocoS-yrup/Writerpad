import Foundation

/// 바인더 노드가 폴더인지 UTF-8 TXT 문서인지 나타낸다.
enum DocumentKind: String, Codable, Equatable, Sendable {
    case folder
    case text
}

/// 영구 모델에서 UIKit의 NSRange를 사용하지 않기 위한 UTF-16 기반 커서 값이다.
struct TextCursorState: Codable, Equatable, Sendable {
    let location: UInt
    let selectionLength: UInt

    static let start = TextCursorState(location: 0, selectionLength: 0)
}

/// 활성 문서와 휴지통 문서를 구분하고 복원에 필요한 원래 위치를 보존한다.
enum DocumentDeletionStatus: Codable, Equatable, Sendable {
    case active
    case trashed(originalPath: RelativeDocumentPath, deletedAt: Date)
}

/// 바인더의 한 폴더 또는 TXT 문서를 나타내는 순수 Swift 메타데이터다.
/// 본문 문자열은 의도적으로 포함하지 않는다.
struct DocumentNode: Codable, Equatable, Sendable {
    let id: DocumentID
    let projectID: ProjectID
    let kind: DocumentKind
    let parentID: DocumentID?
    let relativePath: RelativeDocumentPath
    let userOrder: Int
    let modifiedAt: Date
    let contentHash: ContentHash?
    let deletionStatus: DocumentDeletionStatus
    let cursor: TextCursorState
    let isExpanded: Bool

    init(
        id: DocumentID,
        projectID: ProjectID,
        kind: DocumentKind,
        parentID: DocumentID?,
        relativePath: RelativeDocumentPath,
        userOrder: Int,
        modifiedAt: Date,
        contentHash: ContentHash?,
        deletionStatus: DocumentDeletionStatus = .active,
        cursor: TextCursorState = .start,
        isExpanded: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.parentID = parentID
        self.relativePath = relativePath
        self.userOrder = userOrder
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.deletionStatus = deletionStatus
        self.cursor = cursor
        self.isExpanded = isExpanded
    }

    /// 같은 문서 ID를 유지하면서 부모와 현재 위치를 바꾼다.
    func relocated(
        to relativePath: RelativeDocumentPath,
        parentID: DocumentID?,
        userOrder: Int,
        at date: Date
    ) -> DocumentNode {
        replacing(
            parentID: parentID,
            relativePath: relativePath,
            userOrder: userOrder,
            modifiedAt: date,
            deletionStatus: deletionStatus
        )
    }

    /// 같은 문서 ID를 유지하고 원래 위치를 기록한 채 휴지통 위치로 옮긴다.
    func movedToTrash(
        at trashPath: RelativeDocumentPath,
        trashParentID: DocumentID?,
        deletedAt: Date
    ) -> DocumentNode {
        replacing(
            parentID: trashParentID,
            relativePath: trashPath,
            userOrder: userOrder,
            modifiedAt: deletedAt,
            deletionStatus: .trashed(originalPath: relativePath, deletedAt: deletedAt)
        )
    }

    private func replacing(
        parentID: DocumentID?,
        relativePath: RelativeDocumentPath,
        userOrder: Int,
        modifiedAt: Date,
        deletionStatus: DocumentDeletionStatus
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: kind,
            parentID: parentID,
            relativePath: relativePath,
            userOrder: userOrder,
            modifiedAt: modifiedAt,
            contentHash: contentHash,
            deletionStatus: deletionStatus,
            cursor: cursor,
            isExpanded: isExpanded
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id = "document_id"
        case projectID = "project_id"
        case kind
        case parentID = "parent_id"
        case relativePath = "relative_path"
        case userOrder = "user_order"
        case modifiedAt = "modified_at"
        case contentHash = "content_hash"
        case deletionStatus = "deletion_status"
        case cursor
        case isExpanded = "is_expanded"
    }
}
