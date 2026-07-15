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
    @Published private(set) var workingDocumentIDs: Set<DocumentID> = []
    @Published private(set) var commandDescriptorsByDocument: [DocumentID: [BinderCommandDescriptor]] = [:]
    @Published private(set) var errorMessage: String?
    @Published var selectedNodeID: DocumentID?

    private let repository: any BinderRepository
    private let commands: any BinderCommanding
    private var loadedProjectID: ProjectID?

    init(repository: any BinderRepository, commands: any BinderCommanding) {
        self.repository = repository
        self.commands = commands
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
        workingDocumentIDs = []
        commandDescriptorsByDocument = [:]
        errorMessage = nil
        selectedNodeID = nil
        do {
            try await commands.recoverPendingTransactions(in: projectID)
            let loadedRoots = try await repository.rootNodes(in: projectID)
            guard loadedProjectID == projectID else { return }
            roots = loadedRoots
            try await refreshCommandDescriptors(for: loadedRoots, projectID: projectID)
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

    func descriptor(
        _ kind: BinderCommandKind,
        for node: BinderNode
    ) -> BinderCommandDescriptor {
        commandDescriptorsByDocument[node.id]?.first { $0.kind == kind }
            ?? BinderCommandDescriptor(
                kind: kind,
                isEnabled: false,
                denialReason: "명령 상태를 확인하는 중입니다."
            )
    }

    func create(kind: DocumentKind, named name: String, in parent: BinderNode) async {
        await perform(on: parent.id) { projectID in
            let result = try await commands.create(
                kind: kind,
                named: name,
                in: parent.id,
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func rename(_ node: BinderNode, to name: String) async {
        await perform(on: node.id) { projectID in
            let result = try await commands.rename(
                documentID: node.id,
                to: name,
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func move(_ nodeID: DocumentID, to destination: BinderNode) async {
        await perform(on: nodeID) { projectID in
            let result = try await commands.move(
                documentID: nodeID,
                to: .folder(destination.id),
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func moveToTrash(_ node: BinderNode) async {
        await perform(on: node.id) { projectID in
            _ = try await commands.moveToTrash(
                documentID: node.id,
                projectID: projectID
            )
            return nil
        }
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
        try await refreshCommandDescriptors(for: children, projectID: projectID)
    }

    private func refreshCommandDescriptors(
        for nodes: [BinderNode],
        projectID: ProjectID
    ) async throws {
        for node in nodes {
            commandDescriptorsByDocument[node.id] = try await commands.commandDescriptors(
                for: node.id,
                in: projectID
            )
        }
    }

    private func perform(
        on documentID: DocumentID,
        operation: (ProjectID) async throws -> DocumentID?
    ) async {
        guard let projectID = loadedProjectID else { return }
        workingDocumentIDs.insert(documentID)
        defer { workingDocumentIDs.remove(documentID) }
        do {
            let selection = try await operation(projectID)
            await load(projectID: projectID)
            selectedNodeID = selection
        } catch {
            errorMessage = error.localizedDescription
        }
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
