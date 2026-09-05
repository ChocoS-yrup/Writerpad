import Foundation

struct WorkspaceRestoration: Equatable, Sendable {
    let savedState: EditorWorkspaceState
    let resolvedState: EditorWorkspaceState
}

enum WorkspaceStorageCoordinatorError: LocalizedError, Equatable, Sendable {
    case projectMismatch

    var errorDescription: String? {
        switch self {
        case .projectMismatch:
            "다른 작품의 작업공간 상태를 저장할 수 없습니다."
        }
    }
}

actor WorkspaceStorageCoordinator {
    private let projectID: ProjectID
    private let binderRepository: any BinderRepository
    private let documentRepository: any DocumentRepository
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let binderRules = BinderRuleService()

    init(
        projectID: ProjectID,
        binderRepository: any BinderRepository,
        documentRepository: any DocumentRepository,
        workspaceStateRepository: any WorkspaceStateRepository
    ) {
        self.projectID = projectID
        self.binderRepository = binderRepository
        self.documentRepository = documentRepository
        self.workspaceStateRepository = workspaceStateRepository
    }

    func documents() async throws -> [DocumentNode] {
        try await documentRepository.documents(in: projectID)
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        try await documentRepository.document(id: id)
    }

    func manuscriptTextNodes() async throws -> [BinderNode] {
        let roots = try await binderRepository.rootNodes(in: projectID)
        guard let manuscriptRoot = roots.first(where: {
            $0.fixedCategory == .manuscript
        }) else {
            return []
        }

        var pending = [manuscriptRoot]
        var result: [BinderNode] = []
        while let node = pending.popLast() {
            try Task.checkCancellation()
            if node.kind == .text {
                if chapterNumber(in: node.relativePath) != nil {
                    result.append(node)
                }
                continue
            }
            let children = try await binderRepository.children(
                of: node.id,
                in: projectID
            )
            pending.append(contentsOf: children.reversed())
        }
        return result
    }

    func lastManuscriptChapterNumber() async throws -> Int {
        let documents = try await documentRepository.documents(in: projectID)
        return documents.compactMap { document in
            guard document.kind == .text,
                  case .active = document.deletionStatus
            else { return nil }
            return chapterNumber(in: document.relativePath)
        }.max() ?? 1
    }

    func restoration() async throws -> WorkspaceRestoration {
        let savedState = try await workspaceStateRepository.editorState(
            for: projectID
        )
        let availableDocuments = try await documentRepository.documents(
            in: projectID
        )
        return WorkspaceRestoration(
            savedState: savedState,
            resolvedState: WorkspaceRestorePolicy.resolvedState(
                from: savedState,
                availableDocuments: availableDocuments
            )
        )
    }

    func saveWorkspaceState(_ state: EditorWorkspaceState) async throws {
        guard state.projectID == projectID else {
            throw WorkspaceStorageCoordinatorError.projectMismatch
        }
        try await workspaceStateRepository.saveEditorState(state)
    }

    // 바인더에서 허용한 제목 회차가 이동 목록과 마지막 화수에서도
    // 같은 회차로 인식되도록 이름 규칙을 한곳에서 사용한다.
    private func chapterNumber(in path: RelativeDocumentPath) -> Int? {
        let components = path.rawValue.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "메인",
              components[1] == "원고",
              binderRules.volumeNumber(fromStoredName: components[2]) != nil
        else { return nil }
        return binderRules.titledChapterIdentity(
            fromStoredName: components[3]
        )?.number
    }
}
