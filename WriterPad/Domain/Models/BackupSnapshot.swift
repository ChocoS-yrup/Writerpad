import Foundation

enum BackupReason: String, Codable, Equatable, Sendable {
    case automaticSave
    case beforeRestore
    case conflict
    case manual
}

/// 백업 파일의 위치와 원본 문서 연결만 보관하는 메타데이터다.
struct BackupSnapshot: Codable, Equatable, Sendable {
    let id: BackupID
    let projectID: ProjectID
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let createdAt: Date
    let contentHash: ContentHash
    let reason: BackupReason
    let isPinned: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "backup_id"
        case projectID = "project_id"
        case documentID = "document_id"
        case relativePath = "relative_path"
        case createdAt = "created_at"
        case contentHash = "content_hash"
        case reason
        case isPinned = "is_pinned"
    }
}
