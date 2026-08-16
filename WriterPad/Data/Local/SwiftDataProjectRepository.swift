import SwiftData

extension SwiftDataMetadataRepository: ProjectRepository {
    func projects() async throws -> [Project] {
        let records = try modelContext.fetch(FetchDescriptor<ProjectRecord>())
        return records
            .map(domainProject)
            .sorted { lhs, rhs in
                if lhs.modifiedAt == rhs.modifiedAt {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return lhs.modifiedAt > rhs.modifiedAt
            }
    }

    func project(id: ProjectID) async throws -> Project? {
        try uniqueProjectRecord(id: id).map(domainProject)
    }

    func save(_ project: Project) async throws {
        if let record = try uniqueProjectRecord(id: project.id) {
            record.name = project.name
            record.createdAt = project.createdAt
            record.modifiedAt = project.modifiedAt
        } else {
            modelContext.insert(
                ProjectRecord(
                    id: project.id.rawValue,
                    name: project.name,
                    createdAt: project.createdAt,
                    modifiedAt: project.modifiedAt
                )
            )
        }
        try modelContext.save()
    }

    func remove(id: ProjectID) async throws {
        let project = try requireProjectRecord(id: id)
        for document in try documentRecords(in: id) {
            modelContext.delete(document)
        }
        if let workspace = try uniqueWorkspaceRecord(projectID: id) {
            modelContext.delete(workspace)
        }
        if let appState = try uniqueAppStateRecord(), appState.lastProjectID == id.rawValue {
            appState.lastProjectID = nil
        }
        modelContext.delete(project)
        try modelContext.save()
    }
}

extension SwiftDataMetadataRepository: ProjectCreationMetadataStoring {
    func saveProjectCreation(
        _ project: Project,
        standardNodes: [DocumentNode]
    ) async throws {
        guard standardNodes.allSatisfy({ $0.projectID == project.id }) else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: project.id.rawValue.uuidString,
                reason: "standard node belongs to another project"
            )
        }
        let incomingByID = Dictionary(
            standardNodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard incomingByID.count == standardNodes.count else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "DocumentRecord",
                identifier: project.id.rawValue.uuidString,
                reason: "duplicate standard document_id"
            )
        }

        let pathPolicy = PathPolicy()
        var pathKeys: Set<String> = []
        for node in standardNodes {
            try pathPolicy.validateRelativePath(node.relativePath)
            let key = node.relativePath.rawValue.split(separator: "/")
                .map { pathPolicy.collisionKey(for: String($0)) }
                .joined(separator: "/")
            guard pathKeys.insert(key).inserted else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: node.relativePath.rawValue,
                    reason: "duplicate normalized standard path"
                )
            }
            if let parentID = node.parentID {
                guard let parent = incomingByID[parentID], parent.kind == .folder else {
                    throw MetadataRepositoryError.missingParent(parentID)
                }
            }
        }

        var didSave = false
        defer {
            if !didSave { modelContext.rollback() }
        }

        if let record = try uniqueProjectRecord(id: project.id) {
            guard domainProject(from: record) == project else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "ProjectRecord",
                    identifier: project.id.rawValue.uuidString,
                    reason: "project creation replay changed identity metadata"
                )
            }
        } else {
            modelContext.insert(
                ProjectRecord(
                    id: project.id.rawValue,
                    name: project.name,
                    createdAt: project.createdAt,
                    modifiedAt: project.modifiedAt
                )
            )
        }

        let existingRecords = try documentRecords(in: project.id)
        let existingByID = Dictionary(
            existingRecords.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for record in existingRecords {
            guard let expected = incomingByID[DocumentID(rawValue: record.id)],
                  try domainDocument(from: record) == expected
            else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: record.id.uuidString,
                    reason: "project creation replay found unexpected binder metadata"
                )
            }
        }
        for node in standardNodes where existingByID[node.id.rawValue] == nil {
            let record = DocumentRecord(
                id: node.id.rawValue,
                projectID: project.id.rawValue,
                kindRawValue: node.kind.rawValue,
                parentID: node.parentID?.rawValue,
                relativePath: node.relativePath.rawValue,
                userOrder: node.userOrder,
                modifiedAt: node.modifiedAt,
                contentHash: node.contentHash?.rawValue,
                isDeleted: false,
                originalPath: nil,
                deletedAt: nil,
                cursorLocation: 0,
                selectionLength: 0,
                isExpanded: node.isExpanded
            )
            try apply(node, to: record)
            modelContext.insert(record)
        }
        try modelContext.save()
        didSave = true
    }
}
