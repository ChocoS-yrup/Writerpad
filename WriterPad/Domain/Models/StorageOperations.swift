import Foundation

/// TXT 파일 쓰기에만 사용하는 일시적 요청이다. 메타데이터 저장 대상이 아니다.
struct DocumentSaveRequest: Equatable, Sendable {
    let projectID: ProjectID
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let text: String
    let generation: UInt64
    let cursor: TextCursorState?

    init(
        projectID: ProjectID,
        documentID: DocumentID,
        relativePath: RelativeDocumentPath,
        text: String,
        generation: UInt64,
        cursor: TextCursorState? = nil
    ) {
        self.projectID = projectID
        self.documentID = documentID
        self.relativePath = relativePath
        self.text = text
        self.generation = generation
        self.cursor = cursor
    }
}

/// TXT 저장 과정에서 이미 만든 바이트와 해시를 후속 작업이 재사용하기 위한 일시적 결과다.
/// 복구 표식이나 SwiftData 메타데이터에는 저장하지 않는다.
struct SavedDocumentContent: Equatable, Sendable {
    let utf8Data: Data
    let contentHash: ContentHash
}

struct DocumentSaveReceipt: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let contentHash: ContentHash
    let modifiedAt: Date
    let generation: UInt64
    let cursor: TextCursorState?
    let savedContent: SavedDocumentContent?

    init(
        projectID: ProjectID,
        documentID: DocumentID,
        relativePath: RelativeDocumentPath,
        contentHash: ContentHash,
        modifiedAt: Date,
        generation: UInt64,
        cursor: TextCursorState? = nil,
        savedContent: SavedDocumentContent? = nil
    ) {
        self.projectID = projectID
        self.documentID = documentID
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
        self.generation = generation
        self.cursor = cursor
        self.savedContent = savedContent
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case documentID
        case relativePath
        case contentHash
        case modifiedAt
        case generation
        case cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        documentID = try container.decode(DocumentID.self, forKey: .documentID)
        relativePath = try container.decode(RelativeDocumentPath.self, forKey: .relativePath)
        contentHash = try container.decode(ContentHash.self, forKey: .contentHash)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        generation = try container.decode(UInt64.self, forKey: .generation)
        cursor = try container.decodeIfPresent(TextCursorState.self, forKey: .cursor)
        savedContent = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(documentID, forKey: .documentID)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(generation, forKey: .generation)
        try container.encodeIfPresent(cursor, forKey: .cursor)
    }
}

struct DocumentSearchRequest: Equatable, Sendable {
    let projectID: ProjectID
    let query: String
    /// 아직 자동 저장되지 않은 편집기 본문은 디스크 대신 이 스냅샷을 검색한다.
    let textOverrides: [DocumentID: String]

    init(
        projectID: ProjectID,
        query: String,
        textOverrides: [DocumentID: String] = [:]
    ) {
        self.projectID = projectID
        self.query = query
        self.textOverrides = textOverrides
    }
}

struct DocumentSearchHit: Equatable, Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let documentID: DocumentID
        let utf16Location: UInt
        let utf16Length: UInt
    }

    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let utf16Location: UInt
    let utf16Length: UInt
    let preview: String
    /// 미리보기 안에서 검색어가 시작되는 UTF-16 위치다.
    let previewUTF16Location: UInt

    var id: ID {
        ID(
            documentID: documentID,
            utf16Location: utf16Location,
            utf16Length: utf16Length
        )
    }
}

struct DocumentSearchProgress: Equatable, Sendable {
    let completedDocumentCount: Int
    let totalDocumentCount: Int
    let hitCount: Int
}

struct DocumentSearchIssue: Equatable, Identifiable, Sendable {
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let message: String

    var id: DocumentID { documentID }
}

struct ProjectSearchReport: Equatable, Sendable {
    let hits: [DocumentSearchHit]
    let searchedDocumentCount: Int
    let totalDocumentCount: Int
    let issues: [DocumentSearchIssue]
}

enum ManuscriptExportScope: Equatable, Sendable {
    case all
    case range(start: Int, end: Int)
}

enum ManuscriptExportFormat: String, CaseIterable, Codable, Equatable, Sendable {
    case plainText
    case pdf

    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .pdf: "pdf"
        }
    }
}

struct ExportRequest: Equatable, Sendable {
    let projectID: ProjectID
    let scope: ManuscriptExportScope
    let format: ManuscriptExportFormat
    let excludesEmptyChapters: Bool
    let includesChapterTitles: Bool
    let stopsAtChapterShorterThan300Characters: Bool
    let destinationDirectoryURL: URL
}

struct ExportReport: Equatable, Sendable {
    let outputURL: URL
    let requestedScope: ManuscriptExportScope
    let format: ManuscriptExportFormat
    let exportedDocumentIDs: [DocumentID]
    let firstIncludedChapterNumber: Int
    let lastIncludedChapterNumber: Int
    let missingChapterNumbers: [Int]
    let emptyExcludedChapterNumbers: [Int]
    let firstShortChapterNumber: Int?
}
