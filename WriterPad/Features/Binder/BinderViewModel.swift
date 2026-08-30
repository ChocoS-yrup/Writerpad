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
    private var loadGeneration: UInt64 = 0
    private var pendingCommandDescriptorDocumentIDs: Set<DocumentID> = []
    private var isRefreshingCommandDescriptors = false

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
        loadGeneration &+= 1
        let generation = loadGeneration
        loadedProjectID = projectID
        if !isBackgroundRefresh {
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
            try Task.checkCancellation()
            let loadedRoots = try await repository.rootNodes(in: projectID)
            try Task.checkCancellation()
            let loadedChildren = try await expandedChildrenSnapshot(
                from: loadedRoots,
                projectID: projectID
            )
            let loadedNodes = Array(
                Dictionary(
                    (loadedRoots + loadedChildren.values.flatMap { $0 })
                        .map { ($0.id, $0) },
                    uniquingKeysWith: { _, latest in latest }
                ).values
            )
            let loadedDescriptors = try await commands.commandDescriptors(
                for: loadedNodes.map(\.id),
                in: projectID
            )
            try Task.checkCancellation()
            guard loadedProjectID == projectID,
                  loadGeneration == generation
            else { return }

            let loadedIDs = Set(loadedNodes.map(\.id))
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // 백그라운드 갱신 중에는 기존 행을 유지하고, 펼친 가지까지
                // 모두 준비된 뒤 완성된 트리를 한 번에 화면에 반영한다.
                roots = loadedRoots
                childrenByParent = loadedChildren
                commandDescriptorsByDocument = loadedDescriptors
                if let selectedNodeID, !loadedIDs.contains(selectedNodeID) {
                    self.selectedNodeID = nil
                }
                errorMessage = nil
            }
        } catch {
            guard !Task.isCancelled,
                  loadedProjectID == projectID,
                  loadGeneration == generation
            else { return }
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

    func refreshCommandDescriptors(forDocumentIDs documentIDs: Set<DocumentID>) async {
        pendingCommandDescriptorDocumentIDs.formUnion(documentIDs)
        guard !isRefreshingCommandDescriptors else { return }

        isRefreshingCommandDescriptors = true
        defer { isRefreshingCommandDescriptors = false }

        while !pendingCommandDescriptorDocumentIDs.isEmpty {
            guard let projectID = loadedProjectID else {
                pendingCommandDescriptorDocumentIDs.removeAll()
                return
            }
            let generation = loadGeneration
            let loadedIDs = Set(
                (roots + childrenByParent.values.flatMap { $0 }).map(\.id)
            )
            let pendingIDs = pendingCommandDescriptorDocumentIDs
            pendingCommandDescriptorDocumentIDs.removeAll()
            let requestedIDs = pendingIDs.intersection(loadedIDs)
            guard !requestedIDs.isEmpty else { continue }

            do {
                let refreshed = try await commands.commandDescriptors(
                    for: Array(requestedIDs),
                    in: projectID
                )
                guard loadedProjectID == projectID,
                      loadGeneration == generation
                else { continue }
                commandDescriptorsByDocument.merge(refreshed) { _, new in new }
            } catch {
                guard loadedProjectID == projectID,
                      loadGeneration == generation
                else { continue }
                errorMessage = error.localizedDescription
            }
        }
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

        let result: BinderVolumeCreationResult
        do {
            result = try await commands.addNewVolume(projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        var expansionError: Error?
        if result.shouldRefreshBinder {
            do {
                // 명령이 실행되는 동안 폴더 UUID 이관이 완료될 수
                // 있다. 버튼을 누를 때의 BinderNode가 아니라 명령이
                // 최신 메타데이터에서 반환한 ID를 사용한다.
                try await repository.setExpanded(
                    true,
                    for: result.manuscriptFolderID
                )
                try await repository.setExpanded(
                    true,
                    for: result.folderToExpandID
                )
            } catch {
                // 새 권과 회차는 이미 저장됐다. 성공한 생성을
                // 실패로 보이지 않고, 재스캔이 회복할 기회를 준다.
                expansionError = error
            }
            await load(projectID: projectID)
            if let loadError = errorMessage {
                let detail = expansionError?.localizedDescription ?? loadError
                errorMessage =
                    "새 권은 정상적으로 만들었지만 바인더 표시를 "
                    + "갱신하지 못했습니다: \(detail)"
            }
        }
        selectedNodeID = result.documentToOpenID
        return visibleRows.first {
            $0.node.id == result.documentToOpenID
        }?.node
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

    private func expandedChildrenSnapshot(
        from nodes: [BinderNode],
        projectID: ProjectID
    ) async throws -> [DocumentID: [BinderNode]] {
        var result: [DocumentID: [BinderNode]] = [:]
        for node in nodes where node.isFolder && node.isExpanded {
            try Task.checkCancellation()
            let children = try await repository.children(
                of: node.id,
                in: projectID
            )
            result[node.id] = children
            let descendants = try await expandedChildrenSnapshot(
                from: children,
                projectID: projectID
            )
            result.merge(descendants) { _, latest in latest }
        }
        return result
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

    /// 이름 자체가 정책에 맞지 않아 거부된 경우다. 이때는 파일 시스템도 서버도
    /// 건드리지 않았고 바인더에는 이전 이름이 그대로 남아 있다. 사유가 여러
    /// 가지라 한 문장으로 묶어 보여준다. 표시 후 2초 뒤 자동으로 사라진다.
    static let unsupportedNameMessage = "지원하지 않는 파일명 입니다."

    private func simplifiedCollisionMessage(
        for error: Error,
        kind: DocumentKind?
    ) -> String {
        if let policyError = error as? PathPolicyError,
           Self.isUnsupportedName(policyError) {
            return Self.unsupportedNameMessage
        }
        let message = error.localizedDescription
        let isNameCollision = message.contains("같은 이름")
            || message.contains("동일한 이름")
            || message.contains("정규화 기준으로 같은 이름")
        guard isNameCollision, let kind else { return message }
        return kind == .folder
            ? "같은 이름의 폴더가 존재합니다."
            : "같은 이름의 파일이 존재합니다."
    }

    /// 같은 이름 충돌은 사용자가 다른 이름을 고르면 되는 별개 사유라 제외한다.
    /// 경로 길이·루트 이탈처럼 이름 입력과 무관한 것도 원래 문구를 유지한다.
    private static func isUnsupportedName(_ error: PathPolicyError) -> Bool {
        switch error {
        case .emptyName, .forbiddenCharacter, .controlCharacter,
             .trailingSpaceOrPeriod, .dotPathSegment,
             .reservedWindowsName, .nameTooLong:
            return true
        case .relativePathTooLong, .absolutePath, .pathEscapesRoot,
             .nameCollision:
            return false
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
