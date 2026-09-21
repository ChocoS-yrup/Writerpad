import Foundation
import OSLog

struct BinderCommandJournal: Codable {
    enum Kind: String, Codable {
        case create
        case createVolume = "create_volume"
        case relocate
        case trash
        case restore
        case reorder
        case emptyTrash = "empty_trash"
        case permanentDelete = "permanent_delete"
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
    let trashRecord: TrashRecord?
    var durableBatch: LocalMutationBatch?

    init(
        transactionID: UUID,
        projectID: ProjectID,
        kind: Kind,
        phase: Phase,
        sourcePath: RelativeDocumentPath?,
        destinationPath: RelativeDocumentPath,
        createdKind: DocumentKind?,
        oldNodes: [DocumentNode],
        newNodes: [DocumentNode],
        trashRecord: TrashRecord?,
        durableBatch: LocalMutationBatch? = nil
    ) {
        self.transactionID = transactionID
        self.projectID = projectID
        self.kind = kind
        self.phase = phase
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.createdKind = createdKind
        self.oldNodes = oldNodes
        self.newNodes = newNodes
        self.trashRecord = trashRecord
        self.durableBatch = durableBatch
    }
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
    let hierarchyPolicy: BinderHierarchyPolicy
    let fileManager: FileManager
    let clock: any AppClock
    let uuidGenerator: any UUIDGenerating
    let hasher: any ContentHashing
    let futureChangeNotifier: any FutureChangeNotifying
    let durableChangeRecorder: any DurableLocalChangeRecording
    let syncMutationGate: SyncV2DocumentMutationGate
    let backupStore: (any BackupStoring)?
    let backupPolicyStore: (any BackupPolicyStoring)?
    let faultPlan: BinderCommandFaultPlan?
    var volumeCreationProjects: Set<ProjectID> = []
    let hierarchyLogger = Logger(
        subsystem: "com.chocos.writerpad",
        category: "BinderHierarchy"
    )

    init(
        metadataStore: any BinderMetadataStoring,
        workspaceStateRepository: any WorkspaceStateRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        pathPolicy: PathPolicy = PathPolicy(),
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        futureChangeNotifier: any FutureChangeNotifying = NoOpFutureChangeNotifier(),
        durableChangeRecorder: any DurableLocalChangeRecording =
            NoOpDurableLocalChangeRecorder(),
        syncMutationGate: SyncV2DocumentMutationGate =
            SyncV2DocumentMutationGate(),
        backupStore: (any BackupStoring)? = nil,
        backupPolicyStore: (any BackupPolicyStoring)? = nil,
        faultPlan: BinderCommandFaultPlan? = nil
    ) {
        self.metadataStore = metadataStore
        self.workspaceStateRepository = workspaceStateRepository
        self.workspaceLocator = workspaceLocator
        self.pathPolicy = pathPolicy
        self.ruleService = BinderRuleService(pathPolicy: pathPolicy)
        self.hierarchyPolicy = BinderHierarchyPolicy()
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.futureChangeNotifier = futureChangeNotifier
        self.durableChangeRecorder = durableChangeRecorder
        self.syncMutationGate = syncMutationGate
        self.backupStore = backupStore
        self.backupPolicyStore = backupPolicyStore
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
                var journal = try decoder.decode(
                    BinderCommandJournal.self,
                    from: Data(contentsOf: url)
                )
                guard journal.projectID == projectID else { continue }
                switch journal.phase {
                case .prepared:
                    try await rollback(journal, workspaceRoot: workspaceRoot)
                    try removeIfExists(url)
                    continue
                case .filesApplied:
                    try await saveMetadata(for: journal)
                    journal.phase = .metadataSaved
                    try writeJournal(journal, to: url)
                case .metadataSaved:
                    let destination = try validatedURL(
                        journal.destinationPath,
                        workspaceRoot: workspaceRoot
                    )
                    if !fileManager.fileExists(atPath: destination.path),
                       journal.kind != .permanentDelete {
                        throw BinderCommandError.sourceMissing(destination.path)
                    }
                }
                guard try await completeDurableHandoff(
                    journal: &journal,
                    journalURL: url,
                    workspaceRoot: workspaceRoot
                ) else {
                    throw BinderCommandError.recoveryRequired(url.path)
                }
                if journal.kind == .permanentDelete, journal.phase != .prepared {
                    try removeIfExists(try validatedURL(journal.destinationPath, workspaceRoot: workspaceRoot))
                }
                if (journal.kind == .restore || journal.kind == .permanentDelete),
                   journal.phase != .prepared,
                   let record = journal.trashRecord {
                    try removeIfExists(trashRecordURL(record.documentID, workspaceRoot: workspaceRoot))
                }
                try removeIfExists(url)
            } catch {
                throw BinderCommandError.recoveryRequired(url.path)
            }
        }
        try await removeEmptyLegacySyncRootAliases(
            in: projectID,
            workspaceRoot: workspaceRoot
        )
        try await ensureCanonicalStoryPlotFolder(
            in: projectID,
            workspaceRoot: workspaceRoot
        )
    }

    func commandDescriptors(
        for documentID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderCommandDescriptor] {
        let result = try await commandDescriptors(
            for: [documentID],
            in: projectID
        )
        guard let descriptors = result[documentID] else {
            throw BinderCommandError.missingDocument(documentID)
        }
        return descriptors
    }

    func commandDescriptors(
        for documentIDs: [DocumentID],
        in projectID: ProjectID
    ) async throws -> [DocumentID: [BinderCommandDescriptor]] {
        guard !documentIDs.isEmpty else { return [:] }
        let documents = try await documentsAndRequireProject(projectID)
        let state = try await workspaceStateRepository.editorState(for: projectID)
        let openIDs = Set([state.left.documentID, state.right?.documentID].compactMap { $0 })
        var result: [DocumentID: [BinderCommandDescriptor]] = [:]
        for documentID in documentIDs {
            let document = try requireDocument(documentID, in: documents)
            result[documentID] = descriptors(
                for: document,
                in: documents,
                openDocumentIDs: openIDs
            )
        }
        return result
    }

    private func descriptors(
        for document: DocumentNode,
        in documents: [DocumentNode],
        openDocumentIDs: Set<DocumentID>
    ) -> [BinderCommandDescriptor] {
        let subtree = subtreeRooted(at: document, in: documents)
        let isFixed = fixedCategory(for: document.relativePath) != nil
        let isManuscriptItem = isInManuscript(document.relativePath)
        let isOpen = subtree.contains { openDocumentIDs.contains($0.id) }
        let isTrashed = isInTrash(document.relativePath)
        let protectedReason = isFixed
            ? "고정 바인더 항목은 변경할 수 없습니다."
            : (isOpen ? BinderCommandError.openDocument(document.id).localizedDescription : nil)

        return BinderCommandKind.allCases.map { kind in
            let reason: String?
            switch kind {
            case .addVolume:
                reason = fixedCategory(for: document.relativePath) == .manuscript
                    ? nil
                    : "새 권은 원고 최상위에서만 만들 수 있습니다."
            case .createFolder, .createText:
                if document.kind != .folder {
                    reason = "새 항목은 폴더 안에서만 만들 수 있습니다."
                } else if isTrashed {
                    reason = "휴지통 안에서는 새 항목을 만들 수 없습니다."
                } else if kind == .createText,
                          hierarchyPolicy.isTopLevelContainer(document) {
                    reason = BinderCommandError.topLevelRequiresFolder.localizedDescription
                } else {
                    reason = nil
                }
            case .rename, .move:
                reason = isTrashed
                    ? "휴지통 복원은 6단계에서 제공됩니다."
                    : protectedReason
            case .moveToTrash:
                if isTrashed {
                    reason = "이미 휴지통에 있습니다."
                } else if isManuscriptItem {
                    reason = "원고와 권·화는 삭제할 수 없습니다."
                } else {
                    reason = protectedReason
                }
            case .reorder:
                if isReorderProtected(document) {
                    reason = document.relativePath == BinderFixedCategory.trash.relativePath
                        ? "휴지통은 항상 바인더 최하단에 위치합니다."
                        : "원고와 권·화의 순서는 변경할 수 없습니다."
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
        try requireValidHierarchyPlacement(kind: kind, in: parent)
        let requestedStoredName = try self.storedName(
            from: displayName,
            kind: kind
        )
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let existingNames = try names(in: parent.relativePath, workspaceRoot: workspaceRoot)
        let storedName = numberedCollisionName(
            requestedStoredName,
            existingNames: existingNames
        )
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
            newNodes: [node],
            trashRecord: nil
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
        try await createStructuralBackups(for: subtree)
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

    /// 회차 이름 변경은 입력값의 번호를 신뢰하지 않고, 저장된 원래 번호를 다시 붙인다.
    func renameChapter(
        documentID: DocumentID,
        titleSuffix: String,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireMutableDocument(documentID, in: documents)
        guard source.kind == .text, isInManuscript(source.relativePath) else {
            return try await rename(
                documentID: documentID,
                to: titleSuffix,
                projectID: projectID
            )
        }
        let displayName = pathPolicy.binderDisplayName(
            forStoredName: storedName(of: source.relativePath)
        )
        guard let chapterName = ChapterRenameName.parse(displayName: displayName) else {
            return try await rename(
                documentID: documentID,
                to: titleSuffix,
                projectID: projectID
            )
        }
        let normalizedSuffix = titleSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await rename(
            documentID: documentID,
            to: chapterName.displayPrefix + normalizedSuffix,
            projectID: projectID
        )
    }

    func move(
        documentID: DocumentID,
        to target: BinderDropTarget,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        switch target {
        case .topLevel:
            let documents = try await documentsAndRequireProject(projectID)
            guard let root = documents.first(where: hierarchyPolicy.isTopLevelContainer) else {
                throw BinderCommandError.missingDocument(documentID)
            }
            return try await move(
                documentID: documentID,
                toFolderID: root.id,
                projectID: projectID
            )
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
        if hierarchyPolicy.isTopLevelContainer(parent),
           children.contains(where: { $0.kind != .folder }) {
            throw BinderCommandError.topLevelRequiresFolder
        }
        // 원고 계층과 휴지통만 보호하고, 나머지 고정 바인더와 사용자 항목은 함께 재정렬한다.
        let reorderableChildren = children.filter { !isReorderProtected($0) }
        guard childIDs.count == reorderableChildren.count,
              Set(childIDs) == Set(reorderableChildren.map(\.id))
        else {
            throw BinderCommandError.invalidOrder
        }
        for (index, id) in childIDs.enumerated() {
            let child = try requireDocument(id, in: reorderableChildren)
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
        let orderOffset = normalizedPathKey(parent.relativePath)
            == normalizedPathKey(RelativeDocumentPath(rawValue: "메인"))
            ? BinderOrderingPolicy.customizedRootOrderOffset
            : 0
        let reordered = childIDs.enumerated().map { index, id in
            let child = reorderableChildren.first { $0.id == id }!
            return child.relocated(
                to: child.relativePath,
                parentID: child.parentID,
                userOrder: orderOffset + index,
                at: now
            )
        }
        let journal = BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: .reorder,
            phase: .prepared,
            sourcePath: nil,
            destinationPath: parent.relativePath,
            createdKind: nil,
            oldNodes: reorderableChildren,
            newNodes: reordered,
            trashRecord: nil
        )
        let workspaceRoot = try await workspaceLocator.workspaceRoot(
            for: projectID
        )
        try await execute(journal, workspaceRoot: workspaceRoot)
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
        try await createStructuralBackups(for: subtree)
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
        let sourceStoredName = storedName(of: source.relativePath)
        let destinationStoredName = numberedCollisionName(
            sourceStoredName,
            existingNames: existingNames
        )
        let decision = ruleService.evaluateTrash(
            sourcePath: source.relativePath,
            destinationStoredName: destinationStoredName,
            kind: source.kind,
            existingTrashNames: existingNames
        )
        try requireAllowed(
            decision,
            candidate: destinationStoredName,
            existingNames: existingNames
        )
        let destinationPath = appending(destinationStoredName, to: trash.relativePath)
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
        if let record = journal.trashRecord {
            try writeTrashRecord(record, workspaceRoot: workspaceRoot)
        }
        try await execute(journal, workspaceRoot: workspaceRoot)
        await futureChangeNotifier.record(
            .documentTrashed(projectID: projectID, documentID: source.id)
        )
        return BinderCommandResult(affectedDocumentID: source.id, relativePath: destinationPath)
    }

    func restoreFromTrash(
        documentID: DocumentID,
        toFolderID: DocumentID?,
        projectID: ProjectID
    ) async throws -> BinderCommandResult {
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireDocument(documentID, in: documents)
        guard isInTrash(source.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통 밖의 항목")
        }
        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        let root = try await workspaceLocator.workspaceRoot(for: projectID)
        let record = try readTrashRecord(documentID, workspaceRoot: root)
        let destinationParent: DocumentNode
        let restoresToOriginalParent: Bool
        if let toFolderID {
            destinationParent = try requireDocument(toFolderID, in: documents)
            restoresToOriginalParent = false
            guard destinationParent.kind == .folder, !isInTrash(destinationParent.relativePath) else {
                throw BinderCommandError.destinationIsNotFolder(toFolderID)
            }
        } else if let originalParent = documents.first(where: {
            $0.id == record.originalParentID
                && $0.kind == .folder
                && !isInTrash($0.relativePath)
        }) {
            destinationParent = originalParent
            restoresToOriginalParent = true
        } else {
            guard let rootContainer = documents.first(where: hierarchyPolicy.isTopLevelContainer) else {
                throw BinderCommandError.missingDocument(record.originalParentID)
            }
            destinationParent = rootContainer
            restoresToOriginalParent = false
        }
        if hierarchyPolicy.placementViolation(
            for: source.kind,
            in: destinationParent
        ) != nil {
            throw hierarchyPolicy.isTopLevelContainer(destinationParent)
                ? BinderCommandError.documentCannotRestoreToTopLevel
                : BinderCommandError.topLevelRequiresFolder
        }

        let existingNames = try names(in: destinationParent.relativePath, workspaceRoot: root)
        let originalStoredName = storedName(of: record.originalPath)
        let candidate = isInManuscript(record.originalPath)
            ? originalStoredName
            : numberedCollisionName(originalStoredName, existingNames: existingNames)
        let destinationPath = appending(candidate, to: destinationParent.relativePath)
        let decision = ruleService.evaluateDrop(
            BinderMoveRuleRequest(
                sourcePath: record.originalPath,
                kind: source.kind,
                destinationFolderPath: destinationParent.relativePath,
                proposedStoredName: candidate,
                existingDestinationNames: existingNames,
                existingManuscriptChapterPaths: try manuscriptChapterPaths(workspaceRoot: root)
            )
        )
        try requireAllowed(decision, candidate: candidate, existingNames: existingNames)
        let siblings = documents.filter { $0.parentID == destinationParent.id && $0.id != source.id }
        // 루트 사용자 정렬은 offset 이상의 값으로 정렬 영역을 구분한다.
        // 형제 개수로 clamp하면 이 영역 정보가 사라져 복원 항목이 캐릭터 앞으로
        // 이동하고, 그 잘못된 순서가 tree-order에도 기록된다.
        let order = restoresToOriginalParent
            ? max(record.originalUserOrder, 0)
            : (siblings.map(\.userOrder).max() ?? -1) + 1
        let restored = relocatedSubtree(
            subtree,
            source: source,
            destinationPath: destinationPath,
            destinationParentID: destinationParent.id,
            rootOrder: order,
            trashed: false
        )
        let journal = BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: .restore,
            phase: .prepared,
            sourcePath: source.relativePath,
            destinationPath: destinationPath,
            createdKind: nil,
            oldNodes: subtree,
            newNodes: restored,
            trashRecord: record
        )
        try await execute(journal, workspaceRoot: root)
        await futureChangeNotifier.record(
            .documentRestoredFromTrash(projectID: projectID, documentID: source.id)
        )
        return BinderCommandResult(affectedDocumentID: source.id, relativePath: destinationPath)
    }

    func permanentlyDelete(
        documentID: DocumentID,
        projectID: ProjectID,
        confirmsPermanentDeletion: Bool
    ) async throws {
        guard confirmsPermanentDeletion else { throw BinderCommandError.trashConfirmationRequired }
        try await recoverPendingTransactions(in: projectID)
        let documents = try await documentsAndRequireProject(projectID)
        let source = try requireDocument(documentID, in: documents)
        guard isInTrash(source.relativePath) else {
            throw BinderCommandError.fixedCategoryProtected("휴지통 밖의 항목")
        }
        let subtree = subtreeRooted(at: source, in: documents)
        try await requireNoOpenDocument(subtree, projectID: projectID)
        let root = try await workspaceLocator.workspaceRoot(for: projectID)
        let record = try readTrashRecord(documentID, workspaceRoot: root)
        let quarantine = RelativeDocumentPath(
            rawValue: "메인/휴지통/.writerpad-delete-" + uuidGenerator.makeUUID().uuidString.lowercased()
        )
        let journal = BinderCommandJournal(
            transactionID: uuidGenerator.makeUUID(),
            projectID: projectID,
            kind: .permanentDelete,
            phase: .prepared,
            sourcePath: source.relativePath,
            destinationPath: quarantine,
            createdKind: nil,
            oldNodes: subtree,
            newNodes: [],
            trashRecord: record
        )
        try await execute(journal, workspaceRoot: root)
        await futureChangeNotifier.record(
            .documentPermanentlyDeleted(projectID: projectID, documentID: source.id)
        )
    }

    func emptyTrash(
        projectID: ProjectID,
        confirmsPermanentDeletion: Bool
    ) async throws -> TrashDeletionResult {
        guard confirmsPermanentDeletion else { throw BinderCommandError.trashConfirmationRequired }
        let documents = try await documentsAndRequireProject(projectID)
        guard let trash = documents.first(where: { fixedCategory(for: $0.relativePath) == .trash }) else {
            throw BinderCommandError.missingDocument(DocumentID(rawValue: UUID()))
        }
        let roots = documents.filter { $0.parentID == trash.id }
        let originalSubtrees = Dictionary(
            uniqueKeysWithValues: roots.map {
                ($0.id, subtreeRooted(at: $0, in: documents))
            }
        )
        var deleted: [DocumentID] = []
        var failures: [TrashDeletionFailure] = []
        for item in roots {
            do {
                try await permanentlyDelete(
                    documentID: item.id,
                    projectID: projectID,
                    confirmsPermanentDeletion: true
                )
                deleted.append(item.id)
            } catch {
                failures.append(.init(documentID: item.id, message: error.localizedDescription))
            }
        }
        let deletedNodes = deleted.flatMap { originalSubtrees[$0] ?? [] }
        await recordEmptyTrashHandoff(
            projectID: projectID,
            deletedNodes: deletedNodes,
            trashPath: trash.relativePath
        )
        return TrashDeletionResult(deletedDocumentIDs: deleted, failures: failures)
    }
}
