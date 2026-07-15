import Foundation
import SwiftData

extension SwiftDataMetadataRepository: BinderMetadataStoring {
    func binderDocuments(in projectID: ProjectID) async throws -> [DocumentNode] {
        _ = try requireProjectRecord(id: projectID)
        return try documentRecords(in: projectID).map(domainDocument)
    }

    func binderDocument(id: DocumentID) async throws -> DocumentNode? {
        try uniqueDocumentRecord(id: id).map(domainDocument)
    }

    func binderDocument(
        in projectID: ProjectID,
        at relativePath: RelativeDocumentPath
    ) async throws -> DocumentNode? {
        _ = try requireProjectRecord(id: projectID)
        let targetKey = binderPathKey(relativePath.rawValue)
        let matches = try documentRecords(in: projectID).filter {
            binderPathKey($0.relativePath) == targetKey
        }
        guard matches.count <= 1 else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: relativePath.rawValue,
                reason: "duplicate normalized relative path"
            )
        }
        return try matches.first.map(domainDocument)
    }

    func binderChildren(
        in projectID: ProjectID,
        parentID: DocumentID
    ) async throws -> [DocumentNode] {
        _ = try requireProjectRecord(id: projectID)
        let rawParentID = parentID.rawValue
        return try documentRecords(in: projectID)
            .filter { $0.parentID == rawParentID }
            .map(domainDocument)
    }

    func reconcileBinderMetadata(
        in projectID: ProjectID,
        upserting documents: [DocumentNode],
        removingSubtrees rootedAt: [DocumentID]
    ) async throws {
        _ = try requireProjectRecord(id: projectID)
        var didSave = false
        defer {
            if !didSave { modelContext.rollback() }
        }

        let currentRecords = try documentRecords(in: projectID)
        let rootRecords = currentRecords.filter { record in
            rootedAt.contains { $0.rawValue == record.id }
        }
        let rootKeys = rootRecords.map { binderPathKey($0.relativePath) }
        let removedRecords = currentRecords.filter { record in
            let key = binderPathKey(record.relativePath)
            return rootKeys.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        let removedIDs = Set(removedRecords.map(\.id))

        var remainingPathKeys = Set(
            currentRecords
                .filter { !removedIDs.contains($0.id) }
                .map { binderPathKey($0.relativePath) }
        )
        for document in documents {
            guard document.projectID == projectID else {
                throw MetadataRepositoryError.documentProjectCannotChange(document.id)
            }
            try PathPolicy().validateRelativePath(document.relativePath)
            let key = binderPathKey(document.relativePath.rawValue)
            if let existing = try uniqueDocumentRecord(id: document.id) {
                remainingPathKeys.remove(binderPathKey(existing.relativePath))
            }
            guard remainingPathKeys.insert(key).inserted else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: document.id.rawValue.uuidString,
                    reason: "duplicate normalized relative path"
                )
            }
            if let parentID = document.parentID {
                guard parentID != document.id,
                      let parent = try uniqueDocumentRecord(id: parentID),
                      parent.projectID == projectID.rawValue,
                      parent.kindRawValue == DocumentKind.folder.rawValue,
                      !removedIDs.contains(parent.id)
                else {
                    throw MetadataRepositoryError.missingParent(parentID)
                }
            }
        }

        if let workspace = try uniqueWorkspaceRecord(projectID: projectID) {
            if let left = workspace.leftDocumentID, removedIDs.contains(left) {
                workspace.leftDocumentID = nil
            }
            if let right = workspace.rightDocumentID, removedIDs.contains(right) {
                workspace.rightDocumentID = nil
            }
        }
        for record in removedRecords {
            modelContext.delete(record)
        }
        for document in documents {
            if let record = try uniqueDocumentRecord(id: document.id) {
                try apply(document, to: record)
            } else {
                let record = DocumentRecord(
                    id: document.id.rawValue,
                    projectID: projectID.rawValue,
                    kindRawValue: document.kind.rawValue,
                    parentID: document.parentID?.rawValue,
                    relativePath: document.relativePath.rawValue,
                    userOrder: document.userOrder,
                    modifiedAt: document.modifiedAt,
                    contentHash: document.contentHash?.rawValue,
                    isDeleted: false,
                    originalPath: nil,
                    deletedAt: nil,
                    cursorLocation: 0,
                    selectionLength: 0,
                    isExpanded: document.isExpanded
                )
                try apply(document, to: record)
                modelContext.insert(record)
            }
        }
        try modelContext.save()
        didSave = true
    }

    private func binderPathKey(_ path: String) -> String {
        let policy = PathPolicy()
        return path.split(separator: "/")
            .map { policy.collisionKey(for: String($0)) }
            .joined(separator: "/")
    }
}
