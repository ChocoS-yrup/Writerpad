import Foundation

enum ReceiveEditableExportError: Error, Equatable {
    case document
    case unsavedDraft
    case body
    case externalMismatch
    case workspaceChanged
}

/// Immutable bytes and internal binding captured before the system file exporter opens.
struct ReceiveEditableExportPayload: Equatable, Identifiable, Sendable {
    let documentID: UUID
    let fileName: String
    let revision: Int
    let bytes: Data
    let sha256: String
    let workspaceSHA256: String
    var id: UUID { documentID }

    func verifyExternal(_ result: Data) throws {
        guard result.count == bytes.count,
              byteHash(result) == sha256,
              result == bytes else {
            throw ReceiveEditableExportError.externalMismatch
        }
    }

    func verifyCurrent(_ snapshot: ReceiveEditableSnapshot) throws {
        guard try ReceiveEditableExport.workspaceSHA256(snapshot) == workspaceSHA256,
              let document = snapshot.documents.first(where: { $0.id == documentID }),
              document.revision == revision,
              Data(document.text.utf8) == bytes else {
            throw ReceiveEditableExportError.workspaceChanged
        }
    }
}

enum ReceiveEditableExport {
    private static let maximumDocumentBytes = 4 * 1024 * 1024

    private struct BoundDocument: Codable {
        let id: String
        let name: String
        let revision: Int
        let bytes: Int
        let sha256: String
    }

    private struct WorkspaceBinding: Codable {
        let sourceRun: String
        let folderName: String
        let documents: [BoundDocument]
    }

    static func prepare(
        snapshot: ReceiveEditableSnapshot,
        documentID: UUID,
        draftText: String
    ) throws -> ReceiveEditableExportPayload {
        guard let document = snapshot.documents.first(where: { $0.id == documentID }) else {
            throw ReceiveEditableExportError.document
        }
        guard draftText == document.text else {
            throw ReceiveEditableExportError.unsavedDraft
        }
        try validateComponent(document.name)
        let fileName = document.name.lowercased().hasSuffix(".txt")
            ? document.name
            : document.name + ".txt"
        try validateComponent(fileName)
        let bytes = Data(document.text.utf8)
        guard bytes.count <= maximumDocumentBytes,
              String(data: bytes, encoding: .utf8) != nil else {
            throw ReceiveEditableExportError.body
        }
        return .init(
            documentID: document.id,
            fileName: fileName,
            revision: document.revision,
            bytes: bytes,
            sha256: byteHash(bytes),
            workspaceSHA256: try workspaceSHA256(snapshot)
        )
    }

    fileprivate static func workspaceSHA256(_ snapshot: ReceiveEditableSnapshot) throws -> String {
        guard UUID(uuidString: snapshot.sourceRun)?.uuidString.lowercased() == snapshot.sourceRun,
              !snapshot.documents.isEmpty,
              Set(snapshot.documents.map(\.id)).count == snapshot.documents.count else {
            throw ReceiveEditableExportError.workspaceChanged
        }
        try validateComponent(snapshot.folderName)
        let documents = try snapshot.documents.map { document -> BoundDocument in
            try validateComponent(document.name)
            let bytes = Data(document.text.utf8)
            guard document.revision >= 0,
                  bytes.count <= maximumDocumentBytes,
                  String(data: bytes, encoding: .utf8) != nil else {
                throw ReceiveEditableExportError.workspaceChanged
            }
            return .init(
                id: document.id.uuidString.lowercased(),
                name: document.name,
                revision: document.revision,
                bytes: bytes.count,
                sha256: byteHash(bytes)
            )
        }.sorted { $0.id < $1.id }
        return byteHash(try canonical(WorkspaceBinding(
            sourceRun: snapshot.sourceRun,
            folderName: snapshot.folderName,
            documents: documents
        )))
    }
}
