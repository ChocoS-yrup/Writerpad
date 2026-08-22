import Foundation
import SwiftData

extension SwiftDataMetadataRepository: DocumentRepository {
    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        _ = try requireProjectRecord(id: projectID)
        return try documentRecords(in: projectID)
            .map(domainDocument)
            .sorted { lhs, rhs in
                if lhs.userOrder == rhs.userOrder {
                    return lhs.relativePath.rawValue.localizedStandardCompare(
                        rhs.relativePath.rawValue
                    ) == .orderedAscending
                }
                return lhs.userOrder < rhs.userOrder
            }
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        try uniqueDocumentRecord(id: id).map(domainDocument)
    }

    func save(_ document: DocumentNode) async throws {
        _ = try requireProjectRecord(id: document.projectID)
        try validateParent(of: document)

        if let record = try uniqueDocumentRecord(id: document.id) {
            guard record.projectID == document.projectID.rawValue else {
                throw MetadataRepositoryError.documentProjectCannotChange(document.id)
            }
            try apply(document, to: record)
        } else {
            guard let cursorLocation = Int(exactly: document.cursor.location),
                  let selectionLength = Int(exactly: document.cursor.selectionLength)
            else {
                throw MetadataRepositoryError.invalidCursor(document.id)
            }
            let record = DocumentRecord(
                id: document.id.rawValue,
                projectID: document.projectID.rawValue,
                kindRawValue: document.kind.rawValue,
                parentID: document.parentID?.rawValue,
                relativePath: document.relativePath.rawValue,
                userOrder: document.userOrder,
                modifiedAt: document.modifiedAt,
                contentHash: document.contentHash?.rawValue,
                isDeleted: false,
                originalPath: nil,
                deletedAt: nil,
                cursorLocation: cursorLocation,
                selectionLength: selectionLength,
                isExpanded: document.isExpanded
            )
            try apply(document, to: record)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    func removeMetadata(id: DocumentID) async throws {
        let record = try requireDocumentRecord(id: id)
        let projectID = ProjectID(rawValue: record.projectID)
        if let workspace = try uniqueWorkspaceRecord(projectID: projectID) {
            if workspace.leftDocumentID == record.id {
                workspace.leftDocumentID = nil
            }
            if workspace.rightDocumentID == record.id {
                workspace.rightDocumentID = nil
            }
        }
        modelContext.delete(record)
        try modelContext.save()
    }

    private func validateParent(of document: DocumentNode) throws {
        guard let parentID = document.parentID else {
            return
        }
        guard parentID != document.id else {
            throw MetadataRepositoryError.parentIsSameDocument(document.id)
        }
        guard let parent = try uniqueDocumentRecord(id: parentID) else {
            throw MetadataRepositoryError.missingParent(parentID)
        }
        guard parent.projectID == document.projectID.rawValue else {
            throw MetadataRepositoryError.parentBelongsToAnotherProject(parentID)
        }
        guard parent.kindRawValue == DocumentKind.folder.rawValue else {
            throw MetadataRepositoryError.parentIsNotFolder(parentID)
        }
    }
}

extension SwiftDataMetadataRepository: DocumentIdentityReplacing {
    func replaceDocumentIdentity(
        from oldID: DocumentID,
        to newID: DocumentID,
        in projectID: ProjectID
    ) async throws {
        guard oldID != newID else { return }
        guard try uniqueDocumentRecord(id: newID) == nil else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: newID.rawValue.uuidString,
                reason: "replacement document identity already exists"
            )
        }
        let record = try requireDocumentRecord(id: oldID)
        guard record.projectID == projectID.rawValue else {
            throw MetadataRepositoryError.documentProjectCannotChange(oldID)
        }

        let children = try documentRecords(
            in: projectID,
            parentID: oldID
        )
        if let workspace = try uniqueWorkspaceRecord(projectID: projectID) {
            if workspace.leftDocumentID == oldID.rawValue {
                workspace.leftDocumentID = newID.rawValue
            }
            if workspace.rightDocumentID == oldID.rawValue {
                workspace.rightDocumentID = newID.rawValue
            }
        }
        record.id = newID.rawValue
        for child in children {
            child.parentID = newID.rawValue
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}

extension SwiftDataMetadataRepository: DocumentFileMetadataUpdating {
    func validateBeforeFileSave(
        _ request: DocumentSaveRequest
    ) async throws {
        let record = try requireDocumentRecord(id: request.documentID)
        guard record.projectID == request.projectID.rawValue,
              record.kindRawValue == DocumentKind.text.rawValue,
              !record.isTrashed,
              record.relativePath == request.relativePath.rawValue
        else {
            throw LocalDocumentStoreError.documentNoLongerWritable(
                request.documentID
            )
        }
    }

    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws {
        let record = try requireDocumentRecord(id: receipt.documentID)
        guard record.projectID == receipt.projectID.rawValue else {
            throw MetadataRepositoryError.documentProjectCannotChange(receipt.documentID)
        }
        guard record.kindRawValue == DocumentKind.text.rawValue else {
            throw MetadataRepositoryError.documentIsNotText(receipt.documentID)
        }
        record.relativePath = receipt.relativePath.rawValue
        record.contentHash = receipt.contentHash.rawValue
        record.modifiedAt = receipt.modifiedAt
        if let cursor = receipt.cursor {
            guard let location = Int(exactly: cursor.location),
                  let length = Int(exactly: cursor.selectionLength)
            else {
                throw MetadataRepositoryError.invalidCursor(receipt.documentID)
            }
            record.cursorLocation = location
            record.selectionLength = length
        }
        try modelContext.save()
    }
}
