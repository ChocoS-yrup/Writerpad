import Foundation
import SwiftUI

@MainActor
final class ProjectListModel: ObservableObject {
    @Published private(set) var projects: [ManagedProject] = []
    @Published var selectedProjectID: ProjectID?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isWorking = false

    private let projectManager: any ProjectManaging

    init(projectManager: any ProjectManaging) {
        self.projectManager = projectManager
    }

    var selectedProject: ManagedProject? {
        projects.first { $0.id == selectedProjectID }
    }

    func load() async {
        await perform {
            projects = try await projectManager.projects()
            selectedProjectID = try await projectManager.restoreLastProject()?.id
        }
    }

    func create(named name: String) async {
        await perform {
            let created = try await projectManager.createProject(named: name)
            projects = try await projectManager.projects()
            selectedProjectID = created.id
        }
    }

    func select(_ id: ProjectID?) async {
        guard let id else { return }
        await perform {
            try await projectManager.selectProject(id: id)
        }
    }

    func rename(_ project: ManagedProject, to newName: String) async {
        await perform {
            _ = try await projectManager.renameProject(id: project.id, to: newName)
            projects = try await projectManager.projects()
            selectedProjectID = project.id
        }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) async {
        var reordered = projects
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        await perform {
            projects = try await projectManager.reorderProjects(reordered.map(\.id))
        }
    }

    func confirmDeletion(of project: ManagedProject) async {
        await perform {
            let confirmation = try await projectManager.prepareDeletion(id: project.id)
            try await projectManager.confirmDeletion(confirmation)
            projects = try await projectManager.projects()
            selectedProjectID = try await projectManager.restoreLastProject()?.id
        }
    }

    func cancelDeletion(of project: ManagedProject) async {
        await perform {
            try await projectManager.cancelDeletion(id: project.id)
            projects = try await projectManager.projects()
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
