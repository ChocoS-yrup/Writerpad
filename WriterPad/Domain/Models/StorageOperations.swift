import Foundation

/// TXT 파일 쓰기에만 사용하는 일시적 요청이다. 메타데이터 저장 대상이 아니다.
struct DocumentSaveRequest: Equatable, Sendable {
    let projectID: ProjectID
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let text: String
    let generation: UInt64
}

struct DocumentSaveReceipt: Equatable, Sendable {
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let contentHash: ContentHash
    let modifiedAt: Date
    let generation: UInt64
}

struct DocumentSearchRequest: Equatable, Sendable {
    let projectID: ProjectID
    let query: String
}

struct DocumentSearchHit: Equatable, Sendable {
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let utf16Location: UInt
    let utf16Length: UInt
    let preview: String
}

struct ExportRequest: Equatable, Sendable {
    let projectID: ProjectID
    let documentIDs: [DocumentID]?
    let destinationURL: URL
}

struct ExportReport: Equatable, Sendable {
    let outputURL: URL
    let exportedDocumentIDs: [DocumentID]
    let skippedDocumentIDs: [DocumentID]
}
