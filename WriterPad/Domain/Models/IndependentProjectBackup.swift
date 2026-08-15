import Foundation

/// 독립 프로젝트 백업 디렉터리의 자체 설명 manifest다.
///
/// 파일 본문은 `files/` 아래에 사람이 읽을 수 있는 UTF-8 원문으로 두고,
/// 이 manifest가 작품·폴더·문서 정체성과 무결성 정보를 보존한다.
struct IndependentProjectBackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let formatName = "writerpad-independent-project-backup"

    let format: String
    let formatVersion: Int
    let backupID: UUID
    let createdAt: Date
    let project: Project
    let entries: [Entry]

    init(
        backupID: UUID,
        createdAt: Date,
        project: Project,
        entries: [Entry]
    ) {
        format = Self.formatName
        formatVersion = Self.currentFormatVersion
        self.backupID = backupID
        self.createdAt = createdAt
        self.project = project
        self.entries = entries
    }

    struct Entry: Codable, Equatable, Sendable {
        let node: DocumentNode
        let content: Content?
    }

    struct Content: Codable, Equatable, Sendable {
        let packagePath: String
        let utf8ByteCount: Int
        let sha256: ContentHash

        private enum CodingKeys: String, CodingKey {
            case packagePath = "package_path"
            case utf8ByteCount = "utf8_byte_count"
            case sha256
        }
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case formatVersion = "format_version"
        case backupID = "backup_id"
        case createdAt = "created_at"
        case project
        case entries
    }
}
struct IndependentProjectBackupReceipt: Equatable, Sendable {
    let packageURL: URL
    let manifest: IndependentProjectBackupManifest
}

struct IndependentProjectRestoreReceipt: Equatable, Sendable {
    let restoredWorkspaceURL: URL
    let identityManifestURL: URL
    let manifest: IndependentProjectBackupManifest
}

/// 보존 기간 계산은 삭제와 분리한다. A1에서는 후보만 반환하며 파일을 지우지 않는다.
struct IndependentProjectBackupInventoryItem: Equatable, Sendable {
    let packageURL: URL
    let createdAt: Date
    let isPinned: Bool
}

enum IndependentProjectBackupRetention {
    static let defaultRetentionDays = 30

    static func candidates(
        from items: [IndependentProjectBackupInventoryItem],
        now: Date,
        retentionDays: Int = defaultRetentionDays
    ) -> [IndependentProjectBackupInventoryItem] {
        guard retentionDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        return items
            .filter { !$0.isPinned && $0.createdAt < cutoff }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.packageURL.path < $1.packageURL.path
            }
    }
}
