import Foundation
import SwiftData

/// SwiftData 접근을 단일 actor에 격리하는 메타데이터 저장소다.
@ModelActor
actor SwiftDataMetadataRepository {
    static let defaultBinderWidth = 320.0
}

extension SwiftDataMetadataRepository {
    func uniqueProjectRecord(id: ProjectID) throws -> ProjectRecord? {
        let rawID = id.rawValue
        let records = try modelContext.fetch(FetchDescriptor<ProjectRecord>())
            .filter { $0.id == rawID }
        guard records.count <= 1 else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "ProjectRecord",
                identifier: rawID.uuidString,
                reason: "duplicate project_id"
            )
        }
        return records.first
    }

    func requireProjectRecord(id: ProjectID) throws -> ProjectRecord {
        guard let record = try uniqueProjectRecord(id: id) else {
            throw MetadataRepositoryError.missingProject(id)
        }
        return record
    }

    func uniqueDocumentRecord(id: DocumentID) throws -> DocumentRecord? {
        let rawID = id.rawValue
        let records = try modelContext.fetch(FetchDescriptor<DocumentRecord>())
            .filter { $0.id == rawID }
        guard records.count <= 1 else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: rawID.uuidString,
                reason: "duplicate document_id"
            )
        }
        return records.first
    }

    func requireDocumentRecord(id: DocumentID) throws -> DocumentRecord {
        guard let record = try uniqueDocumentRecord(id: id) else {
            throw MetadataRepositoryError.missingDocument(id)
        }
        return record
    }

    func documentRecords(in projectID: ProjectID) throws -> [DocumentRecord] {
        let rawProjectID = projectID.rawValue
        return try modelContext.fetch(FetchDescriptor<DocumentRecord>())
            .filter { $0.projectID == rawProjectID }
    }

    func uniqueWorkspaceRecord(projectID: ProjectID) throws -> WorkspaceRecord? {
        let rawProjectID = projectID.rawValue
        let records = try modelContext.fetch(FetchDescriptor<WorkspaceRecord>())
            .filter { $0.projectID == rawProjectID }
        guard records.count <= 1 else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "WorkspaceRecord",
                identifier: rawProjectID.uuidString,
                reason: "duplicate project_id"
            )
        }
        return records.first
    }

    func uniqueAppStateRecord() throws -> AppStateRecord? {
        let key = "writerpad.app-state"
        let records = try modelContext.fetch(FetchDescriptor<AppStateRecord>())
            .filter { $0.key == key }
        guard records.count <= 1 else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "AppStateRecord",
                identifier: key,
                reason: "duplicate singleton"
            )
        }
        return records.first
    }

    func domainProject(from record: ProjectRecord) -> Project {
        Project(
            id: ProjectID(rawValue: record.id),
            name: record.name,
            createdAt: record.createdAt,
            modifiedAt: record.modifiedAt
        )
    }

    func domainDocument(from record: DocumentRecord) throws -> DocumentNode {
        let id = DocumentID(rawValue: record.id)
        guard let kind = DocumentKind(rawValue: record.kindRawValue) else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: record.id.uuidString,
                reason: "unknown document kind"
            )
        }
        guard record.cursorLocation >= 0, record.selectionLength >= 0 else {
            throw MetadataRepositoryError.invalidCursor(id)
        }

        let hash: ContentHash?
        if let rawHash = record.contentHash {
            guard let validHash = ContentHash(rawValue: rawHash) else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: record.id.uuidString,
                    reason: "invalid content hash"
                )
            }
            hash = validHash
        } else {
            hash = nil
        }

        let deletionStatus: DocumentDeletionStatus
        if record.isTrashed {
            guard let originalPath = record.originalPath, let deletedAt = record.deletedAt else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: record.id.uuidString,
                    reason: "missing trash restoration metadata"
                )
            }
            deletionStatus = .trashed(
                originalPath: RelativeDocumentPath(rawValue: originalPath),
                deletedAt: deletedAt
            )
        } else {
            deletionStatus = .active
        }

        return DocumentNode(
            id: id,
            projectID: ProjectID(rawValue: record.projectID),
            kind: kind,
            parentID: record.parentID.map(DocumentID.init(rawValue:)),
            relativePath: RelativeDocumentPath(rawValue: record.relativePath),
            userOrder: record.userOrder,
            modifiedAt: record.modifiedAt,
            contentHash: hash,
            deletionStatus: deletionStatus,
            cursor: TextCursorState(
                location: UInt(record.cursorLocation),
                selectionLength: UInt(record.selectionLength)
            ),
            isExpanded: record.isExpanded
        )
    }

    func apply(_ document: DocumentNode, to record: DocumentRecord) throws {
        guard let cursorLocation = Int(exactly: document.cursor.location),
              let selectionLength = Int(exactly: document.cursor.selectionLength)
        else {
            throw MetadataRepositoryError.invalidCursor(document.id)
        }

        record.projectID = document.projectID.rawValue
        record.kindRawValue = document.kind.rawValue
        record.parentID = document.parentID?.rawValue
        record.relativePath = document.relativePath.rawValue
        record.userOrder = document.userOrder
        record.modifiedAt = document.modifiedAt
        record.contentHash = document.contentHash?.rawValue
        record.cursorLocation = cursorLocation
        record.selectionLength = selectionLength
        record.isExpanded = document.isExpanded

        switch document.deletionStatus {
        case .active:
            record.isTrashed = false
            record.originalPath = nil
            record.deletedAt = nil
        case let .trashed(originalPath, deletedAt):
            record.isTrashed = true
            record.originalPath = originalPath.rawValue
            record.deletedAt = deletedAt
        }
    }
}
