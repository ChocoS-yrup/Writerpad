import Foundation

actor LocalBinderRepository: BinderRepository {
    private let metadataStore: any BinderMetadataStoring
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let scanner: any BinderDirectoryScanning
    private let pathPolicy: PathPolicy
    private let ruleService: BinderRuleService
    private let hierarchyPolicy = BinderHierarchyPolicy()
    private let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let syncMutationGate: SyncV2DocumentMutationGate
    private let fileManager: FileManager

    init(
        metadataStore: any BinderMetadataStoring,
        workspaceStateRepository: any WorkspaceStateRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        scanner: any BinderDirectoryScanning,
        pathPolicy: PathPolicy = PathPolicy(),
        clock: any AppClock,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        syncMutationGate: SyncV2DocumentMutationGate =
            SyncV2DocumentMutationGate(),
        fileManager: FileManager = .default
    ) {
        self.metadataStore = metadataStore
        self.workspaceStateRepository = workspaceStateRepository
        self.workspaceLocator = workspaceLocator
        self.scanner = scanner
        self.pathPolicy = pathPolicy
        self.ruleService = BinderRuleService(pathPolicy: pathPolicy)
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.syncMutationGate = syncMutationGate
        self.fileManager = fileManager
    }

    func rootContainerID(in projectID: ProjectID) async throws -> DocumentID {
        try await syncMutationGate.withCriticalSection(
            documentID: syncV2ProjectStructureMutationID(projectID)
        ) { [self] in
            try await rootContainerIDInsideMutationGate(in: projectID)
        }
    }

    private func rootContainerIDInsideMutationGate(
        in projectID: ProjectID
    ) async throws -> DocumentID {
        let mainPath = RelativeDocumentPath(rawValue: "메인")
        return try await ensureMainDocument(in: projectID, path: mainPath).id
    }

    func rootNodes(in projectID: ProjectID) async throws -> [BinderNode] {
        try await syncMutationGate.withCriticalSection(
            documentID: syncV2ProjectStructureMutationID(projectID)
        ) { [self] in
            try await rootNodesInsideMutationGate(in: projectID)
        }
    }

    private func rootNodesInsideMutationGate(
        in projectID: ProjectID
    ) async throws -> [BinderNode] {
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let mainPath = RelativeDocumentPath(rawValue: "메인")
        var entries = try await scanner.children(
            in: workspaceRoot,
            parentPath: mainPath
        )
        // 고정 폴더는 사용자가 이름을 바꾸거나 삭제할 수 없는
        // 앱 구조다. 예전 테스트 빌드나 낡은 원격 tombstone으로
        // 빈 고정 폴더 하나가 사라졌다면, 다른 경로는 전혀 건드리지
        // 않고 그 빈 디렉터리만 다시 추가한다.
        if try ensureFixedCategoryDirectories(
            in: workspaceRoot,
            scannedEntries: entries
        ) {
            entries = try await scanner.children(
                in: workspaceRoot,
                parentPath: mainPath
            )
        }
        let main = try await ensureMainDocument(in: projectID, path: mainPath)
        if let invalidEntry = entries.first(where: { $0.kind == .text }) {
            throw BinderRepositoryError.documentAtTopLevel(
                invalidEntry.relativePath.rawValue
            )
        }
        let storedChildren = try await metadataStore.binderChildren(
            in: projectID,
            parentID: main.id
        )
        if let invalidDocument = hierarchyPolicy.invalidTopLevelDocuments(
            in: [main] + storedChildren
        ).first {
            throw BinderRepositoryError.documentAtTopLevel(
                invalidDocument.relativePath.rawValue
            )
        }
        let nodes = try await reconcile(
            entries: entries,
            parent: main,
            projectID: projectID,
            existingChildren: storedChildren
        )

        for category in BinderFixedCategory.allCases {
            guard nodes.contains(where: {
                $0.fixedCategory == category && $0.kind == .folder
            }) else {
                throw BinderRepositoryError.missingFixedCategory(category.displayName)
            }
        }
        return nodes.sorted(by: rootOrdering)
    }

    /// 반환값은 디렉터리를 하나라도 새로 만들었는지다.
    /// 같은 이름의 파일이나 심볼릭크가 있으면 덮어쓰지 않고,
    /// 뒤의 기존 검증이 원래 오류를 보여 주게 둔다.
    private func ensureFixedCategoryDirectories(
        in workspaceRoot: URL,
        scannedEntries: [BinderDiskEntry]
    ) throws -> Bool {
        let existing = Set(scannedEntries.map {
            normalizedPathKey($0.relativePath)
        })
        let standardizedRoot = workspaceRoot.standardizedFileURL
        let rootPrefix = standardizedRoot.path + "/"
        var didCreate = false

        for category in BinderFixedCategory.allCases where
            !existing.contains(normalizedPathKey(category.relativePath)) {
            let target = standardizedRoot
                .appendingPathComponent(category.relativePath.rawValue)
                .standardizedFileURL
            guard target.path.hasPrefix(rootPrefix) else { continue }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: target.path,
                isDirectory: &isDirectory
            ) {
                continue
            }
            try fileManager.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            didCreate = true
        }
        return didCreate
    }

    func children(
        of folderID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderNode] {
        try await syncMutationGate.withCriticalSection(
            documentID: syncV2ProjectStructureMutationID(projectID)
        ) { [self] in
            try await childrenInsideMutationGate(
                of: folderID,
                in: projectID
            )
        }
    }

    private func childrenInsideMutationGate(
        of folderID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderNode] {
        guard let parent = try await metadataStore.binderDocument(id: folderID),
              parent.projectID == projectID
        else {
            throw BinderRepositoryError.missingNode(folderID)
        }
        guard parent.kind == .folder else {
            throw BinderRepositoryError.nodeIsNotFolder(folderID)
        }
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        let entries = try await scanner.children(
            in: workspaceRoot,
            parentPath: parent.relativePath
        )
        let nodes = try await reconcile(
            entries: entries,
            parent: parent,
            projectID: projectID
        )
        return orderedChildren(nodes, parentPath: parent.relativePath)
    }

    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) async throws {
        try await workspaceStateRepository.setExpanded(isExpanded, for: folderID)
    }

    private func ensureMainDocument(
        in projectID: ProjectID,
        path: RelativeDocumentPath
    ) async throws -> DocumentNode {
        if let existing = try await metadataStore.binderDocument(
            in: projectID,
            at: path
        ) {
            guard existing.kind == .folder else {
                throw BinderRepositoryError.missingMainFolder
            }
            return existing
        }
        let document = DocumentNode(
            id: DocumentID(rawValue: uuidGenerator.makeUUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: path,
            userOrder: -1,
            modifiedAt: clock.now(),
            contentHash: nil
        )
        try await metadataStore.reconcileBinderMetadata(
            in: projectID,
            upserting: [document],
            removingSubtrees: []
        )
        return document
    }

    private func reconcile(
        entries: [BinderDiskEntry],
        parent: DocumentNode,
        projectID: ProjectID,
        existingChildren: [DocumentNode]? = nil
    ) async throws -> [BinderNode] {
        let existing = if let existingChildren {
            existingChildren
        } else {
            try await metadataStore.binderChildren(
                in: projectID,
                parentID: parent.id
            )
        }
        var unmatchedExisting = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var matchByEntryPath: [String: DocumentNode] = [:]

        for entry in entries {
            let key = normalizedPathKey(entry.relativePath)
            if let exact = unmatchedExisting.values.first(where: {
                normalizedPathKey($0.relativePath) == key && $0.kind == entry.kind
            }) {
                matchByEntryPath[key] = exact
                unmatchedExisting.removeValue(forKey: exact.id)
            }
        }

        for entry in entries where matchByEntryPath[normalizedPathKey(entry.relativePath)] == nil {
            guard entry.kind == .text, let hash = entry.contentHash else { continue }
            let candidates = unmatchedExisting.values.filter {
                $0.kind == .text && $0.contentHash == hash
            }
            if candidates.count == 1, let match = candidates.first {
                matchByEntryPath[normalizedPathKey(entry.relativePath)] = match
                unmatchedExisting.removeValue(forKey: match.id)
            }
        }

        var nextOrder = (existing.map(\.userOrder).max() ?? -1) + 1
        var documents: [DocumentNode] = []
        var entryByDocumentID: [DocumentID: BinderDiskEntry] = [:]
        for entry in entries {
            let key = normalizedPathKey(entry.relativePath)
            let prior = matchByEntryPath[key]
            let document = DocumentNode(
                id: prior?.id ?? DocumentID(rawValue: uuidGenerator.makeUUID()),
                projectID: projectID,
                kind: entry.kind,
                parentID: parent.id,
                relativePath: entry.relativePath,
                userOrder: prior?.userOrder ?? nextOrder,
                modifiedAt: entry.modifiedAt,
                contentHash: entry.contentHash,
                deletionStatus: prior?.deletionStatus ?? .active,
                cursor: prior?.cursor ?? .start,
                isExpanded: prior?.isExpanded ?? false
            )
            if prior == nil { nextOrder += 1 }
            documents.append(document)
            entryByDocumentID[document.id] = entry
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let requiresMetadataUpdate = !unmatchedExisting.isEmpty || documents.contains {
            existingByID[$0.id] != $0
        }
        if requiresMetadataUpdate {
            try await metadataStore.reconcileBinderMetadata(
                in: projectID,
                upserting: documents,
                removingSubtrees: Array(unmatchedExisting.keys)
            )
        }
        return documents.compactMap { document in
            entryByDocumentID[document.id].map { makeNode(document: document, entry: $0) }
        }
    }

    private func makeNode(
        document: DocumentNode,
        entry: BinderDiskEntry
    ) -> BinderNode {
        let documentPathKey = normalizedPathKey(document.relativePath)
        let category = BinderFixedCategory.allCases.first {
            normalizedPathKey($0.relativePath) == documentPathKey
        }
        let displayName = category?.displayName
            ?? pathPolicy.binderDisplayName(forStoredName: entry.storedName)
        let contentState: BinderTextContentState = document.kind == .folder
            ? .notText
            : (entry.byteCount == 0 ? .empty : .written)
        return BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: document.kind,
            relativePath: document.relativePath,
            displayName: displayName,
            fixedCategory: category,
            userOrder: document.userOrder,
            contentState: contentState,
            isExpanded: document.isExpanded
        )
    }

    private func normalizedPathKey(_ path: RelativeDocumentPath) -> String {
        path.rawValue.split(separator: "/")
            .map { pathPolicy.collisionKey(for: String($0)) }
            .joined(separator: "/")
    }

    private func rootOrdering(_ lhs: BinderNode, _ rhs: BinderNode) -> Bool {
        BinderOrderingPolicy.rootItemPrecedes(
            lhsUserOrder: lhs.userOrder,
            lhsFixedCategory: lhs.fixedCategory,
            lhsStableName: lhs.relativePath.rawValue.precomposedStringWithCanonicalMapping,
            rhsUserOrder: rhs.userOrder,
            rhsFixedCategory: rhs.fixedCategory,
            rhsStableName: rhs.relativePath.rawValue.precomposedStringWithCanonicalMapping
        )
    }

    private func childOrdering(_ lhs: BinderNode, _ rhs: BinderNode) -> Bool {
        if lhs.userOrder != rhs.userOrder { return lhs.userOrder < rhs.userOrder }
        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func orderedChildren(
        _ nodes: [BinderNode],
        parentPath: RelativeDocumentPath
    ) -> [BinderNode] {
        guard ruleService.usesManuscriptNaturalOrder(in: parentPath) else {
            return nodes.sorted(by: childOrdering)
        }
        return nodes.sorted {
            ruleService.manuscriptItemPrecedes(
                $0.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? "",
                $1.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? ""
            )
        }
    }
}
