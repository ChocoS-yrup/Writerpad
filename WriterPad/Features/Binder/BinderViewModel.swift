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
        let isBackgroundRefresh = loadedProjectID == projectID && !roots.isEmpty
        loadedProjectID = projectID
        if isBackgroundRefresh {
            // 구조 변경 전에 접어 둔 폴더의 빈 자식 캐시를 남겨 두면,
            // 휴지통 이동 후 폴더를 다시 펼쳐도 재조회하지 않는다.
            // 펼쳐진 가지는 아래에서 즉시 다시 구성된다.
            childrenByParent = [:]
        } else {
            roots = []
            childrenByParent = [:]
            loadingFolderIDs = []
            workingDocumentIDs = []
            commandDescriptorsByDocument = [:]
            errorMessage = nil
            selectedNodeID = nil
        }
        do {
            try await commands.recoverPendingTransactions(in: projectID)
            let loadedRoots = try await repository.rootNodes(in: projectID)
            guard loadedProjectID == projectID else { return }
            roots = loadedRoots
            for root in loadedRoots where root.isExpanded {
                try await restoreExpandedBranch(from: root, projectID: projectID)
            }
            let loadedNodes = Array(
                Dictionary(
                    (loadedRoots + childrenByParent.values.flatMap { $0 })
                        .map { ($0.id, $0) },
                    uniquingKeysWith: { _, latest in latest }
                ).values
            )
            try await refreshCommandDescriptors(for: loadedNodes, projectID: projectID)
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

    func prepareDisclosureState(for node: BinderNode) async {
        guard node.isFolder,
              let projectID = loadedProjectID,
              childrenByParent[node.id] == nil,
              !loadingFolderIDs.contains(node.id)
        else { return }
        do {
            try await loadChildren(of: node, projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func hasChildren(_ node: BinderNode) -> Bool {
        childrenByParent[node.id]?.isEmpty == false
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
        guard let projectID = loadedProjectID else { return }
        workingDocumentIDs.insert(parent.id)
        defer { workingDocumentIDs.remove(parent.id) }
        do {
            let result = try await commands.create(
                kind: kind,
                named: name,
                in: parent.id,
                projectID: projectID
            )
            let refreshedChildren = try await repository.children(
                of: parent.id,
                in: projectID
            )
            guard loadedProjectID == projectID else { return }
            childrenByParent[parent.id] = refreshedChildren
            if let created = refreshedChildren.first(where: {
                $0.id == result.affectedDocumentID
            }) {
                try await refreshCommandDescriptors(for: [created], projectID: projectID)
            }
            selectedNodeID = result.affectedDocumentID
        } catch {
            errorMessage = simplifiedCollisionMessage(for: error, kind: kind)
        }
    }

    func createRootFolder(named name: String) async {
        guard let projectID = loadedProjectID else { return }
        do {
            let rootID = try await repository.rootContainerID(in: projectID)
            let result = try await commands.create(
                kind: .folder,
                named: name,
                in: rootID,
                projectID: projectID
            )
            let refreshedRoots = try await repository.rootNodes(in: projectID)
            guard loadedProjectID == projectID else { return }
            roots = refreshedRoots
            if let created = refreshedRoots.first(where: {
                $0.id == result.affectedDocumentID
            }) {
                try await refreshCommandDescriptors(for: [created], projectID: projectID)
            }
            selectedNodeID = result.affectedDocumentID
        } catch {
            errorMessage = simplifiedCollisionMessage(for: error, kind: .folder)
        }
    }

    @discardableResult
    func addNewVolume(in manuscript: BinderNode) async -> BinderNode? {
        guard let projectID = loadedProjectID else { return nil }
        workingDocumentIDs.insert(manuscript.id)
        defer { workingDocumentIDs.remove(manuscript.id) }
        do {
            let result = try await commands.addNewVolume(projectID: projectID)
            if result.shouldRefreshBinder {
                try await repository.setExpanded(true, for: manuscript.id)
                try await repository.setExpanded(true, for: result.folderToExpandID)
                await load(projectID: projectID)
            }
            selectedNodeID = result.documentToOpenID
            return visibleRows.first { $0.node.id == result.documentToOpenID }?.node
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func rename(_ node: BinderNode, to name: String) async -> Bool {
        await perform(on: node.id, collisionKind: node.kind) { projectID in
            let result = try await commands.rename(
                documentID: node.id,
                to: name,
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    @discardableResult
    func renameChapter(_ node: BinderNode, titleSuffix: String) async -> Bool {
        await perform(on: node.id, collisionKind: node.kind) { projectID in
            let result = try await commands.renameChapter(
                documentID: node.id,
                titleSuffix: titleSuffix,
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func move(_ nodeID: DocumentID, to destination: BinderNode) async {
        // 접힌 대상 폴더가 이전에 빈 폴더로 캐시되어 있으면 이동 후에도
        // 펼칠 때 새 자식을 불러오지 못한다. 대상 캐시만 무효화해 다음
        // 펼침에서 저장소의 최신 자식 목록을 읽도록 한다.
        childrenByParent[destination.id] = nil
        _ = await perform(on: nodeID) { projectID in
            let result = try await commands.move(
                documentID: nodeID,
                to: .folder(destination.id),
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func moveToTopLevel(_ nodeID: DocumentID) async {
        _ = await perform(on: nodeID) { projectID in
            let result = try await commands.move(
                documentID: nodeID,
                to: .topLevel,
                projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func moveToTrash(_ node: BinderNode) async {
        _ = await perform(on: node.id) { projectID in
            _ = try await commands.moveToTrash(
                documentID: node.id,
                projectID: projectID
            )
            return nil
        }
    }

    func reorder(
        _ draggedID: DocumentID,
        relativeTo targetID: DocumentID,
        placeAfter: Bool
    ) async -> Bool {
        guard draggedID != targetID, let projectID = loadedProjectID else { return false }
        let parent: (id: DocumentID, nodes: [BinderNode], isRoot: Bool)?
        if roots.contains(where: { $0.id == targetID }) {
            guard roots.contains(where: { $0.id == draggedID }) else { return false }
            do {
                parent = (
                    try await repository.rootContainerID(in: projectID),
                    roots,
                    true
                )
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        } else {
            parent = childrenByParent.first { _, nodes in
                nodes.contains(where: { $0.id == targetID }) && nodes.contains(where: { $0.id == draggedID })
            }.map { ($0.key, $0.value, false) }
        }
        guard let parent,
              !workingDocumentIDs.contains(parent.id)
        else { return false }
        var orderedIDs = parent.nodes.filter(isOrderable).map(\.id)
        orderedIDs.removeAll { $0 == draggedID }
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else { return false }
        orderedIDs.insert(draggedID, at: targetIndex + (placeAfter ? 1 : 0))

        let reorderedByID = Dictionary(
            uniqueKeysWithValues: parent.nodes.map { ($0.id, $0) }
        )
        var reorderedIterator = orderedIDs.makeIterator()
        let reorderedNodes = parent.nodes.map { node in
            guard isOrderable(node),
                  let nextID = reorderedIterator.next(),
                  let reordered = reorderedByID[nextID]
            else { return node }
            return reordered
        }

        // SwiftUI List의 임시 배치를 즉시 실제 모델로 확정한다.
        // 저장이 느려도 행이 겹치거나 마지막 위치에서 멈추지 않는다.
        if parent.isRoot {
            roots = reorderedNodes
        } else {
            childrenByParent[parent.id] = reorderedNodes
        }
        guard reorderedNodes.map(\.id) != parent.nodes.map(\.id) else {
            return false
        }

        workingDocumentIDs.insert(parent.id)
        defer { workingDocumentIDs.remove(parent.id) }
        do {
            try await commands.reorder(childIDs: orderedIDs, in: parent.id, projectID: projectID)
            return true
        } catch {
            if parent.isRoot {
                roots = parent.nodes
            } else {
                childrenByParent[parent.id] = parent.nodes
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func isOrderable(_ node: BinderNode) -> Bool {
        let manuscriptPath = BinderFixedCategory.manuscript.relativePath.rawValue + "/"
        let trashPath = BinderFixedCategory.trash.relativePath.rawValue + "/"
        return node.fixedCategory != .manuscript
            && node.fixedCategory != .trash
            && !node.relativePath.rawValue.hasPrefix(manuscriptPath)
            && !node.relativePath.rawValue.hasPrefix(trashPath)
    }

    func restoreFromTrash(_ node: BinderNode) async {
        _ = await perform(on: node.id) { projectID in
            let result = try await commands.restoreFromTrash(
                documentID: node.id, toFolderID: nil, projectID: projectID
            )
            return result.affectedDocumentID
        }
    }

    func permanentlyDelete(_ node: BinderNode) async {
        _ = await perform(on: node.id) { projectID in
            try await commands.permanentlyDelete(
                documentID: node.id, projectID: projectID, confirmsPermanentDeletion: true
            )
            return nil
        }
    }

    func emptyTrash() async {
        guard let projectID = loadedProjectID else { return }
        do {
            let result = try await commands.emptyTrash(
                projectID: projectID, confirmsPermanentDeletion: true
            )
            if let failure = result.failures.first {
                errorMessage = "일부 휴지통 항목을 삭제하지 못했습니다: \(failure.message)"
            }
            await load(projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreExpandedBranch(
        from node: BinderNode,
        projectID: ProjectID
    ) async throws {
        try await loadChildren(
            of: node,
            projectID: projectID,
            refreshesCommandDescriptors: false
        )
        for child in childrenByParent[node.id] ?? []
        where child.isFolder && child.isExpanded {
            try await restoreExpandedBranch(from: child, projectID: projectID)
        }
    }

    private func loadChildren(
        of node: BinderNode,
        projectID: ProjectID,
        refreshesCommandDescriptors: Bool = true
    ) async throws {
        loadingFolderIDs.insert(node.id)
        defer { loadingFolderIDs.remove(node.id) }
        let children = try await repository.children(of: node.id, in: projectID)
        guard loadedProjectID == projectID else { return }
        childrenByParent[node.id] = children
        if refreshesCommandDescriptors {
            try await refreshCommandDescriptors(for: children, projectID: projectID)
        }
    }

    private func refreshCommandDescriptors(
        for nodes: [BinderNode],
        projectID: ProjectID
    ) async throws {
        let refreshed = try await commands.commandDescriptors(
            for: nodes.map(\.id),
            in: projectID
        )
        commandDescriptorsByDocument.merge(refreshed) { _, new in new }
    }

    private func perform(
        on documentID: DocumentID,
        collisionKind: DocumentKind? = nil,
        operation: (ProjectID) async throws -> DocumentID?
    ) async -> Bool {
        guard let projectID = loadedProjectID else { return false }
        workingDocumentIDs.insert(documentID)
        defer { workingDocumentIDs.remove(documentID) }
        do {
            let selection = try await operation(projectID)
            await load(projectID: projectID)
            selectedNodeID = selection
            return true
        } catch {
            errorMessage = simplifiedCollisionMessage(for: error, kind: collisionKind)
            return false
        }
    }

    private func simplifiedCollisionMessage(
        for error: Error,
        kind: DocumentKind?
    ) -> String {
        let message = error.localizedDescription
        let isNameCollision = message.contains("같은 이름")
            || message.contains("동일한 이름")
            || message.contains("정규화 기준으로 같은 이름")
        guard isNameCollision, let kind else { return message }
        return kind == .folder
            ? "같은 이름의 폴더가 존재합니다."
            : "같은 이름의 파일이 존재합니다."
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
