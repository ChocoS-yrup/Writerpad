import Foundation

enum ImportIssueSeverity: String, Codable, Equatable, Sendable {
    case warning
    case fatal
}

enum ImportIssueKind: String, Codable, Equatable, Sendable {
    case invalidSource
    case missingRequiredDirectory
    case missingOptionalDirectory
    case invalidUTF8
    case duplicateProject
    case duplicateChapterNumber
    case invalidVolumeName
    case invalidChapterName
    case hiddenItem
    case unknownItem
    case unreadableItem
    case nameCollision
    case invalidName
    case symbolicLink
    case legacyPlot
    case legacyMainStory
    case legacyPreMigrationBackup
}

struct ImportIssue: Codable, Equatable, Identifiable, Sendable {
    let severity: ImportIssueSeverity
    let kind: ImportIssueKind
    let relativePath: String
    let message: String

    var id: String {
        "\(severity.rawValue)|\(kind.rawValue)|\(relativePath)|\(message)"
    }
}

struct ImportReport: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceSelectionURL: URL
    let sourceWorkspaceURL: URL
    let proposedProjectName: String
    let scannedAt: Date
    let fingerprint: ContentHash
    let directoryCount: Int
    let fileCount: Int
    let textFileCount: Int
    let totalBytes: Int64
    let issues: [ImportIssue]

    var fatalIssues: [ImportIssue] {
        issues.filter { $0.severity == .fatal }
    }

    var warnings: [ImportIssue] {
        issues.filter { $0.severity == .warning }
    }

    var canImport: Bool { fatalIssues.isEmpty }
}

struct ProjectImportResult: Equatable, Sendable {
    let project: ManagedProject
    let documentCount: Int
    let preservedLegacyPaths: [RelativeDocumentPath]
}
