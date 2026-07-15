import Foundation
import SwiftData

extension SwiftDataMetadataRepository: ProjectImportMetadataRegistering {
    func registerImportedProject(
        _ project: Project,
        documents: [DocumentNode]
    ) async throws {
        guard try uniqueProjectRecord(id: project.id) == nil else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "ProjectRecord",
                identifier: project.id.rawValue.uuidString,
                reason: "import project_id already exists"
            )
        }

        var documentByID: [DocumentID: DocumentNode] = [:]
        for document in documents {
            guard documentByID.updateValue(document, forKey: document.id) == nil else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: document.id.rawValue.uuidString,
                    reason: "duplicate imported document_id"
                )
            }
        }

        var pathKeys: Set<String> = []
        let pathPolicy = PathPolicy()
        for document in documents {
            guard document.projectID == project.id else {
                throw MetadataRepositoryError.documentProjectCannotChange(document.id)
            }
            try pathPolicy.validateRelativePath(document.relativePath)
            let pathKey = document.relativePath.rawValue
                .split(separator: "/")
                .map { pathPolicy.collisionKey(for: String($0)) }
                .joined(separator: "/")
            guard pathKeys.insert(pathKey).inserted else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: document.id.rawValue.uuidString,
                    reason: "duplicate normalized relative path"
                )
            }
            if let parentID = document.parentID {
                guard parentID != document.id else {
                    throw MetadataRepositoryError.parentIsSameDocument(document.id)
                }
                guard let parent = documentByID[parentID] else {
                    throw MetadataRepositoryError.missingParent(parentID)
                }
                guard parent.projectID == project.id else {
                    throw MetadataRepositoryError.parentBelongsToAnotherProject(parentID)
                }
                guard parent.kind == .folder else {
                    throw MetadataRepositoryError.parentIsNotFolder(parentID)
                }
            }
        }

        var didSave = false
        defer {
            if !didSave { modelContext.rollback() }
        }

        modelContext.insert(
            ProjectRecord(
                id: project.id.rawValue,
                name: project.name,
                createdAt: project.createdAt,
                modifiedAt: project.modifiedAt
            )
        )

        for document in documents {
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
        didSave = true
    }
}
