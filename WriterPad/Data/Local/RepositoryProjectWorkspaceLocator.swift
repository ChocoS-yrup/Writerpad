import Foundation

struct RepositoryProjectWorkspaceLocator: ProjectWorkspaceLocating {
    let projectRepository: any ProjectRepository
    let pathResolver: ProjectPathResolver

    func workspaceRoot(for projectID: ProjectID) async throws -> URL {
        guard let project = try await projectRepository.project(id: projectID) else {
            throw MetadataRepositoryError.missingProject(projectID)
        }
        return try pathResolver.standardPaths(forProjectNamed: project.name).workspaceRootURL
    }
}
