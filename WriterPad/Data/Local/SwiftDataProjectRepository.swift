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
