import Foundation
import SwiftUI

struct BinderVisibleRow: Identifiable, Equatable {
    let node: BinderNode
    let depth: Int

    var id: DocumentID { node.id }
}

@MainActor
final class BinderViewModel: ObservableObject {
    @Published private(set) var roots: [BinderNode] = []
    @Published private(set) var childrenByParent: [DocumentID: [BinderNode]] = [:]
    @Published private(set) var loadingFolderIDs: Set<DocumentID> = []
    @Published private(set) var errorMessage: String?
    @Published var selectedNodeID: DocumentID?

    private let repository: any BinderRepository
    private var loadedProjectID: ProjectID?

    init(repository: any BinderRepository) {
        self.repository = repository
    }

    var visibleRows: [BinderVisibleRow] {
        var result: [BinderVisibleRow] = []
        appendVisible(roots, depth: 0, to: &result)
        return result
    }

    func load(projectID: ProjectID) async {
        loadedProjectID = projectID
        roots = []
        childrenByParent = [:]
        loadingFolderIDs = []
        errorMessage = nil
        selectedNodeID = nil
        do {
            let loadedRoots = try await repository.rootNodes(in: projectID)
            guard loadedProjectID == projectID else { return }
            roots = loadedRoots
            for root in loadedRoots where root.isExpanded {
                try await restoreExpandedBranch(from: root, projectID: projectID)
            }
        } catch {
            guard loadedProjectID == projectID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func toggleExpansion(of node: BinderNode) async {
        guard node.isFolder, let projectID = loadedProjectID else { return }
        let newValue = !node.isExpanded
        updateExpansion(id: node.id, isExpanded: newValue)
        do {
            try await repository.setExpanded(newValue, for: node.id)
            if newValue, childrenByParent[node.id] == nil {
                try await loadChildren(of: node, projectID: projectID)
            }
        } catch {
            updateExpansion(id: node.id, isExpanded: !newValue)
            errorMessage = error.localizedDescription
        }
    }

    func select(_ node: BinderNode) {
        selectedNodeID = node.id
    }

    func clearError() {
        errorMessage = nil
    }

    private func restoreExpandedBranch(
        from node: BinderNode,
        projectID: ProjectID
    ) async throws {
        try await loadChildren(of: node, projectID: projectID)
        for child in childrenByParent[node.id] ?? []
        where child.isFolder && child.isExpanded {
            try await restoreExpandedBranch(from: child, projectID: projectID)
        }
    }

    private func loadChildren(
        of node: BinderNode,
        projectID: ProjectID
    ) async throws {
        loadingFolderIDs.insert(node.id)
        defer { loadingFolderIDs.remove(node.id) }
        let children = try await repository.children(of: node.id, in: projectID)
        guard loadedProjectID == projectID else { return }
        childrenByParent[node.id] = children
    }

    private func updateExpansion(id: DocumentID, isExpanded: Bool) {
        if let index = roots.firstIndex(where: { $0.id == id }) {
            roots[index].isExpanded = isExpanded
            return
        }
        for parentID in childrenByParent.keys {
            guard let index = childrenByParent[parentID]?.firstIndex(where: { $0.id == id })
            else { continue }
            childrenByParent[parentID]?[index].isExpanded = isExpanded
            return
        }
    }

    private func appendVisible(
        _ nodes: [BinderNode],
        depth: Int,
        to rows: inout [BinderVisibleRow]
    ) {
        for node in nodes {
            rows.append(BinderVisibleRow(node: node, depth: depth))
            if node.isFolder, node.isExpanded,
               let children = childrenByParent[node.id] {
                appendVisible(children, depth: depth + 1, to: &rows)
            }
        }
    }
}
