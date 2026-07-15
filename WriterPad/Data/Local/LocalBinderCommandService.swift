import Foundation

struct BinderCommandJournal: Codable {
    enum Kind: String, Codable {
        case create
        case relocate
        case trash
    }

    enum Phase: String, Codable {
        case prepared
        case filesApplied = "files_applied"
        case metadataSaved = "metadata_saved"
    }

    let transactionID: UUID
    let projectID: ProjectID
    let kind: Kind
    var phase: Phase
    let sourcePath: RelativeDocumentPath?
    let destinationPath: RelativeDocumentPath
    let createdKind: DocumentKind?
    let oldNodes: [DocumentNode]
    let newNodes: [DocumentNode]
}

/// 파일 시스템과 SwiftData 사이의 바인더 변경을 직렬화하고 복구한다.
actor LocalBinderCommandService: BinderCommanding {
    static let journalPrefix = ".writerpad-binder-transaction-"
    static let journalSuffix = ".json"

    let metadataStore: any BinderMetadataStoring
    let workspaceStateRepository: any WorkspaceStateRepository
    let workspaceLocator: any ProjectWorkspaceLocating
    let pathPolicy: PathPolicy
    let ruleService: BinderRuleService
    let fileManager: FileManager
    let clock: any AppClock
    let uuidGenerator: any UUIDGenerating
    let hasher: any ContentHashing
    let faultPlan: BinderCommandFaultPlan?

    init(
        metadataStore: any BinderMetadataStoring,
        workspaceStateRepository: any WorkspaceStateRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        pathPolicy: PathPolicy = PathPolicy(),
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        faultPlan: BinderCommandFaultPlan? = nil
    ) {
        self.metadataStore = metadataStore
        self.workspaceStateRepository = workspaceStateRepository
        self.workspaceLocator = workspaceLocator
        self.pathPolicy = pathPolicy
        self.ruleService = BinderRuleService(pathPolicy: pathPolicy)
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.faultPlan = faultPlan
    }

    func recoverPendingTransactions(in projectID: ProjectID) async throws {
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let urls = try fileManager.contentsOfDirectory(
            at: workspaceRoot,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(Self.journalPrefix)
                && $0.lastPathComponent.hasSuffix(Self.journalSuffix)
        }
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let journal = try decoder.decode(
                    BinderCommandJournal.self,
                    from: Data(contentsOf: url)
                )
                guard journal.projectID == projectID else { continue }
                switch journal.phase {
                case .prepared:
                    try await rollback(journal, workspaceRoot: workspaceRoot)
                case .filesApplied:
                    try await saveMetadata(for: journal)
                case .metadataSaved:
                    let destination = try validatedURL(
                        journal.destinationPath,
                        workspaceRoot: workspaceRoot
                    )
                    guard fileManager.fileExists(atPath: destination.path) else {
                        throw BinderCommandError.sourceMissing(destination.path)
                    }
                }
                try removeIfExists(url)
            } catch {
                throw BinderCommandError.recoveryRequired(url.path)
            }
        }
    }

    func commandDescriptors(
        for documentID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderCommandDescriptor] {
        let documents = try await documentsAndRequireProject(projectID)
        let document = try requireDocument(documentID, in: documents)
        let subtree = subtreeRooted(at: document, in: documents)
        let isFixed = fixedCategory(for: document.relativePath) != nil
        let isOpen = try await containsOpenDocument(subtree, projectID: projectID)
        let isTrashed = isInTrash(document.relativePath)
        let protectedReason = isFixed
            ? "고정 바인더 항목은 변경할 수 없습니다."
            : (isOpen ? BinderCommandError.openDocument(document.id).localizedDescription : nil)

        return BinderCommandKind.allCases.map { kind in
            let reason: String?
            switch kind {
            case .createFolder, .createText:
                reason = document.kind != .folder
                    ? "새 항목은 폴더 안에서만 만들 수 있습니다."
                    : (isTrashed ? "휴지통 안에서는 새 항목을 만들 수 없습니다." : nil)
            case .rename, .move:
                reason = isTrashed
                    ? "휴지통 복원은 6단계에서 제공됩니다."
                    : protectedReason
            case .moveToTrash:
                reason = isTrashed ? "이미 휴지통에 있습니다." : protectedReason
            case .reorder:
                if isFixed {
                    reason = protectedReason
                } else {
                    reason = ruleService.evaluateReorder(
                        itemPath: document.relativePath,
                        proposedIndex: 1
                    ).userReason
                }
            }
            return BinderCommandDescriptor(
                kind: kind,
                isEnabled: reason == nil,
                denialReason: reason
            )
        }
    }

    func create(
        kind: DocumentKind,
        named displayName: String,
        in parentID: DocumentID,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let parent = try requireDocument(parentID, in: documents)
        guard parent.kind == .folder else {
            throw BinderCommandError.destinationIsNotFolder(parentID)
        }
        guard !isInTrash(parent.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통")
        }
        let storedName = try self.storedName(from: displayName, kind: kind)
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let existingNames = try names(in: parent.relativePath, workspaceRoot: workspaceRoot)
        let manuscriptPaths = try manuscriptChapterPaths(workspaceRoot: workspaceRoot)
        let decision = ruleService.evaluateCreation(
            BinderCreationRuleRequest(
                parentPath: parent.relativePath,
                kind: kind,
                storedName: storedName,
                existingSiblingNames: existingNames,
                existingManuscriptChapterPaths: manuscriptPaths
            )
        )
        try requireAllowed(decision, candidate: storedName, existingNames: existingNames)

        let now = clock.now()
        let relativePath = appending(storedName, to: parent.relativePath)
        try pathPolicy.validateRelativePath(relativePath)
        let siblings = documents.filter { $0.parentID == parent.id }
        let node = DocumentNode(
            id: DocumentID(rawValue: uuidGenerator.makeUUID()),
            projectID: projectID,
            kind: kind,
            parentID: parent.id,
            relativePath: relativePath,
            userOrder: (siblings.map(\.userOrder).max() ?? -1) + 1,
            modifiedAt: now,
            contentHash: kind == .text ? hasher.sha256(for: Data()) : nil
        )
        let journal = BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: .create,
            phase: .prepared,
            sourcePath: nil,
            destinationPath: relativePath,
            createdKind: kind,
            oldNodes: [],
            newNodes: [node]
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
        return BinderCommandResult(affectedDocumentID: node.id, relativePath: relativePath)
    }

    func rename(
        documentID: DocumentID,
        to displayName: String,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireMutableDocument(documentID, in: documents)
        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        guard let parentID = source.parentID,
              let parent = documents.first(where: { $0.id == parentID })
        else {
            throw BinderCommandError.fixedCategoryProtected(source.relativePath.rawValue)
        }
        let storedName = try self.storedName(from: displayName, kind: source.kind)
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let existingNames = try names(in: parent.relativePath, workspaceRoot: workspaceRoot)
        let decision = ruleService.evaluateRename(
            BinderRenameRuleRequest(
                sourcePath: source.relativePath,
                kind: source.kind,
                proposedStoredName: storedName,
                existingSiblingNames: existingNames
            )
        )
        try requireAllowed(decision, candidate: storedName, existingNames: existingNames)
        let destinationPath = appending(storedName, to: parent.relativePath)
        if destinationPath == source.relativePath {
            return BinderCommandResult(
                affectedDocumentID: source.id,
                relativePath: source.relativePath
            )
        }
        let relocated = relocatedSubtree(
            subtree,
            source: source,
            destinationPath: destinationPath,
            destinationParentID: parent.id,
            rootOrder: source.userOrder,
            trashed: false
        )
        let journal = relocationJournal(
            kind: .relocate,
            projectID: projectID,
            source: source,
            destinationPath: destinationPath,
            oldNodes: subtree,
            newNodes: relocated
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
        return BinderCommandResult(affectedDocumentID: source.id, relativePath: destinationPath)
    }

    func move(
        documentID: DocumentID,
        to target: BinderDropTarget,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        switch target {
        case .unresolved:
            throw BinderCommandError.unresolvedDropTarget
        case .outsideProject:
            throw BinderCommandError.destinationOutsideProject
        case let .folder(destinationID):
            return try await move(
                documentID: documentID,
                toFolderID: destinationID,
                projectID: projectID
            )
        }
    }

    func reorder(
        childIDs: [DocumentID],
        in parentID: DocumentID,
        projectID: ProjectID
    ) async throws {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let parent = try requireDocument(parentID, in: documents)
        let children = documents.filter { $0.parentID == parent.id }
        guard childIDs.count == children.count,
              Set(childIDs) == Set(children.map(\.id))
        else {
            throw BinderCommandError.invalidOrder
        }
        for (index, id) in childIDs.enumerated() {
            let child = try requireDocument(id, in: children)
            guard fixedCategory(for: child.relativePath) == nil else {
                throw BinderCommandError.fixedCategoryProtected(child.relativePath.rawValue)
            }
            try requireAllowed(
                ruleService.evaluateReorder(
                    itemPath: child.relativePath,
                    proposedIndex: index
                ),
                candidate: nil,
                existingNames: []
            )
        }
        let now = clock.now()
        let reordered = childIDs.enumerated().map { index, id in
            let child = children.first { $0.id == id }!
            return child.relocated(
                to: child.relativePath,
                parentID: child.parentID,
                userOrder: index,
                at: now
            )
        }
        try await metadataStore.reconcileBinderMetadata(
            in: projectID,
            upserting: reordered,
            removingSubtrees: []
        )
    }

    func moveToTrash(
        documentID: DocumentID,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireMutableDocument(documentID, in: documents)
        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        guard !isInTrash(source.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통 항목")
        }
        guard let trash = documents.first(where: {
            normalizedPathKey($0.relativePath)
                == normalizedPathKey(BinderFixedCategory.trash.relativePath)
        }) else {
            throw BinderCommandError.missingDocument(documentID)
        }
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let existingNames = try names(in: trash.relativePath, workspaceRoot: workspaceRoot)
        let decision = ruleService.evaluateTrash(
            sourcePath: source.relativePath,
            kind: source.kind,
            existingTrashNames: existingNames
        )
        try requireAllowed(
            decision,
            candidate: storedName(of: source.relativePath),
            existingNames: existingNames
        )
        let destinationPath = appending(storedName(of: source.relativePath), to: trash.relativePath)
        let trashSiblings = documents.filter { $0.parentID == trash.id }
        let relocated = relocatedSubtree(
            subtree,
            source: source,
            destinationPath: destinationPath,
            destinationParentID: trash.id,
            rootOrder: (trashSiblings.map(\.userOrder).max() ?? -1) + 1,
            trashed: true
        )
        let journal = relocationJournal(
            kind: .trash,
            projectID: projectID,
            source: source,
            destinationPath: destinationPath,
            oldNodes: subtree,
            newNodes: relocated
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
        return BinderCommandResult(affectedDocumentID: source.id, relativePath: destinationPath)
    }
}
