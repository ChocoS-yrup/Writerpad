import Foundation

enum BackupReason: String, Codable, Equatable, Sendable {
    case automaticSave
    case editingInterval
    case documentTransition
    case documentClose
    case beforeStructureChange
    case beforeRestore
    case conflict
    case manual
}

struct BackupPolicy: Codable, Equatable, Sendable {
    static let `default` = BackupPolicy(
        isAutomaticBackupEnabled: true,
        maximumRecentSnapshots: 30,
        retentionDays: 30
    )

    let isAutomaticBackupEnabled: Bool
    let maximumRecentSnapshots: Int
    let retentionDays: Int

    init(
        isAutomaticBackupEnabled: Bool,
        maximumRecentSnapshots: Int,
        retentionDays: Int
    ) {
        self.isAutomaticBackupEnabled = isAutomaticBackupEnabled
        self.maximumRecentSnapshots = (1...500).contains(maximumRecentSnapshots)
            ? maximumRecentSnapshots : Self.default.maximumRecentSnapshots
        self.retentionDays = (1...3_650).contains(retentionDays)
            ? retentionDays : Self.default.retentionDays
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isAutomaticBackupEnabled: try values.decode(
                Bool.self,
                forKey: .isAutomaticBackupEnabled
            ),
            maximumRecentSnapshots: try values.decode(
                Int.self,
                forKey: .maximumRecentSnapshots
            ),
            retentionDays: try values.decode(Int.self, forKey: .retentionDays)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isAutomaticBackupEnabled = "is_automatic_backup_enabled"
        case maximumRecentSnapshots = "maximum_recent_snapshots"
        case retentionDays = "retention_days"
    }
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

struct BackupCleanupIssue: Equatable, Sendable {
    let snapshotID: BackupID
    let reason: String
}

struct BackupCleanupReport: Equatable, Sendable {
    let deletedSnapshotIDs: [BackupID]
    let issues: [BackupCleanupIssue]
}

struct BackupMaintenanceResult: Equatable, Sendable {
    let snapshot: BackupSnapshot
    let cleanup: BackupCleanupReport
}

struct DocumentRestoreRequest: Equatable, Sendable {
    let document: DocumentNode
    let snapshot: BackupSnapshot
    let currentText: String
    let saveGeneration: UInt64
}

/// 복원 코어가 검증하고 실제 디스크에 기록한 원문을 화면까지 그대로 전달한다.
/// 화면이 백업을 별도로 다시 읽으면 파일 변경 경쟁에서 표시 원문과 저장 원문이
/// 달라질 수 있으므로, 복원 성공의 단일 결과로 묶는다.
struct DocumentRestoreResult: Equatable, Sendable {
    let receipt: DocumentSaveReceipt
    let restoredText: String
}

enum BackupStoreError: Error, Equatable, LocalizedError, Sendable {
    case textDocumentRequired
    case snapshotNotFound(BackupID)
    case invalidUTF8(BackupID)
    case hashMismatch(BackupID)
    case wrongProject
    case wrongDocument
    case wrongPath

    var errorDescription: String? {
        switch self {
        case .textDocumentRequired: "TXT 문서만 백업할 수 있습니다."
        case .snapshotNotFound: "백업 파일을 찾을 수 없습니다."
        case .invalidUTF8: "백업이 올바른 UTF-8 TXT가 아닙니다."
        case .hashMismatch: "백업 해시가 일치하지 않아 복원을 중단했습니다."
        case .wrongProject: "다른 작품의 백업은 복원할 수 없습니다."
        case .wrongDocument: "다른 문서의 백업은 복원할 수 없습니다."
        case .wrongPath: "백업의 원래 경로가 현재 문서와 일치하지 않습니다."
        }
    }
}
