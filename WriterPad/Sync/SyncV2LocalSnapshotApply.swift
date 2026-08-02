import Foundation

protocol SyncV2SnapshotMergeStoring: Sendable {
    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws
    func resolve(
        localProjectID: ProjectID,
        documentID: UUID
    ) async
}

extension SyncV2SnapshotMergeStoring {
    func resolve(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        _ = (localProjectID, documentID)
    }
}

protocol SyncV2LocalSnapshotApplying: Sendable {
    func preparePull(
        localProjectID: ProjectID,
        remoteLiveDocumentPaths: Set<String>
    ) async
    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws
    func applyTrashPurge(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        eligibleDocumentIDs: Set<UUID>
    ) async throws
    func trashPurgeState(
        localProjectID: ProjectID
    ) async -> SyncV2TrashPurgePayload
    func trashDocumentIDs(
        localProjectID: ProjectID
    ) async -> Set<UUID>
    func requiresCopyRecovery(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool
    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async
    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async
}

extension SyncV2LocalSnapshotApplying {
    func preparePull(
        localProjectID: ProjectID,
        remoteLiveDocumentPaths: Set<String>
    ) async {}

    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {}

    func applyTrashPurge(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        eligibleDocumentIDs: Set<UUID>
    ) async throws {
        _ = eligibleDocumentIDs
        try await apply(
            localProjectID: localProjectID,
            snapshot: snapshot
        )
    }

    func trashPurgeState(
        localProjectID: ProjectID
    ) async -> SyncV2TrashPurgePayload {
        _ = localProjectID
        return .empty
    }

    func trashDocumentIDs(
        localProjectID: ProjectID
    ) async -> Set<UUID> {
        _ = localProjectID
        return []
    }

    func requiresCopyRecovery(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool {
        _ = (localProjectID, snapshot)
        return false
    }

    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {}
}

enum SyncV2LocalSnapshotApplyError: Error, Equatable, Sendable {
    case pathOccupiedByDifferentDocument
    case invalidHierarchy
    case unsafePath
}

actor LocalSyncV2SnapshotMergeStore: SyncV2SnapshotMergeStoring {
    static let prefix = ".writerpad-sync-merge-"
    static let suffix = ".json"

    private let workspaceLocator: any ProjectWorkspaceLocating

    init(workspaceLocator: any ProjectWorkspaceLocating) {
        self.workspaceLocator = workspaceLocator
    }

    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        let root = try await workspaceLocator.workspaceRoot(
            for: candidate.localProjectID
        )
        let url = root.appendingPathComponent(
            Self.prefix
                + candidate.snapshot.documentID.uuidString.lowercased()
                + Self.suffix
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(candidate).write(to: url, options: [.atomic])
    }

    func resolve(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        guard let root = try? await workspaceLocator.workspaceRoot(
            for: localProjectID
        ) else { return }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent(
                Self.prefix
                    + documentID.uuidString.lowercased()
                    + Self.suffix
            )
        )
    }
}

actor LocalSyncV2SnapshotApplier: SyncV2LocalSnapshotApplying {
    static let markerPrefix = ".writerpad-snapshot-pull-"
    static let markerSuffix = ".json"
    static let trashPurgeStateName = ".writerpad-trash-purge-state.json"
    static let trashPurgeStagePrefix = ".writerpad-trash-purge-stage-"

    private struct CreatedFolderRecovery: Codable, Sendable {
        let document: DocumentNode
        let createdDirectory: Bool
    }

    private struct EnsuredFolderHierarchy {
        let documents: [DocumentNode]
        let createdFolders: [CreatedFolderRecovery]
    }

    private struct TrashPurgeRecovery: Codable, Sendable {
        let document: DocumentNode
        let stagedFileName: String?
        let hadFile: Bool
        let stagedTrashRecordName: String?
        let hadTrashRecord: Bool
    }

    private struct RecoveryMarker: Codable, Sendable {
        let localProjectID: ProjectID
        let snapshot: SyncV2RemoteDocumentSnapshot
        let previousPath: RelativeDocumentPath?
        let previousDocument: DocumentNode?
        let previousContent: Data?
        let tombstonePath: RelativeDocumentPath?
        let trashRecord: TrashRecord?
        let createdFolders: [CreatedFolderRecovery]?
        let treeOrderPreviousDocuments: [DocumentNode]?
        let trashPurgeItems: [TrashPurgeRecovery]?
        let trashPurgePreviousState: Data?
        let trashPurgeAppliedState: Data?
        let isTombstoneRepair: Bool?
        let tombstoneRepairHadTrashRecord: Bool?

        init(
            localProjectID: ProjectID,
            snapshot: SyncV2RemoteDocumentSnapshot,
            previousPath: RelativeDocumentPath?,
            previousDocument: DocumentNode?,
            previousContent: Data?,
            tombstonePath: RelativeDocumentPath?,
            trashRecord: TrashRecord?,
            createdFolders: [CreatedFolderRecovery]?,
            treeOrderPreviousDocuments: [DocumentNode]?,
            trashPurgeItems: [TrashPurgeRecovery]? = nil,
            trashPurgePreviousState: Data? = nil,
            trashPurgeAppliedState: Data? = nil,
            isTombstoneRepair: Bool? = nil,
            tombstoneRepairHadTrashRecord: Bool? = nil
        ) {
            self.localProjectID = localProjectID
            self.snapshot = snapshot
            self.previousPath = previousPath
            self.previousDocument = previousDocument
            self.previousContent = previousContent
            self.tombstonePath = tombstonePath
            self.trashRecord = trashRecord
            self.createdFolders = createdFolders
            self.treeOrderPreviousDocuments = treeOrderPreviousDocuments
            self.trashPurgeItems = trashPurgeItems
            self.trashPurgePreviousState = trashPurgePreviousState
            self.trashPurgeAppliedState = trashPurgeAppliedState
            self.isTombstoneRepair = isTombstoneRepair
            self.tombstoneRepairHadTrashRecord =
                tombstoneRepairHadTrashRecord
        }
    }

    private struct TreeOrderPayload: Decodable {
        let version: Int
        let treeOrder: [String: [String]]

        private enum CodingKeys: String, CodingKey {
            case version
            case treeOrder = "tree_order"
        }
    }

    private let legacyRootTreeOrderAliases: [String: String] = [
        "📚 원고": "원고",
        "👤 캐릭터": "캐릭터",
        "📖 설정집": "설정집",
        "📝 메모장": "메모장",
        "🗺️ 메인 스토리 틀": "스토리 플롯",
        "🌊 흐름 정리": "흐름정리",
        "🔍 복선": "복선",
        "📌 장소": "장소",
        "🗑️ 휴지통": "휴지통",
        "메인 스토리 틀": "스토리 플롯",
        "플롯": "스토리 플롯",
    ]

    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let fileManager: FileManager
    private let writer = POSIXAtomicFileWriter()
    private let hasher: any ContentHashing
    private let pathPolicy = PathPolicy()
    private var remoteLiveDocumentPaths: [ProjectID: Set<String>] = [:]

    init(
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default,
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
        self.hasher = hasher
    }

    func preparePull(
        localProjectID: ProjectID,
        remoteLiveDocumentPaths: Set<String>
    ) async {
        if let root = try? await workspaceLocator.workspaceRoot(
            for: localProjectID
        ), let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            for url in urls where
                url.lastPathComponent.hasPrefix(Self.markerPrefix)
                && url.lastPathComponent.hasSuffix(Self.markerSuffix) {
                guard
                    let marker = recoveryMarker(at: url),
                    marker.localProjectID == localProjectID,
                    marker.snapshot.relativePath == syncV2TrashPurgePath
                else { continue }
                await rollbackTrashPurge(marker, root: root)
            }
        }
        self.remoteLiveDocumentPaths[localProjectID] = Set(
            remoteLiveDocumentPaths.map(normalized)
        )
    }

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws {
        if snapshot.relativePath == syncV2TrashPurgePath {
            let payload = try SyncV2TrashPurgePayload(
                strictContent: snapshot.content
            )
            try await applyTrashPurge(
                localProjectID: localProjectID,
                snapshot: snapshot,
                eligibleDocumentIDs: Set(payload.purgedRevisions.keys)
            )
            return
        }
        if snapshot.relativePath == syncV2TreeOrderPath {
            try await applyTreeOrder(
                localProjectID: localProjectID,
                snapshot: snapshot
            )
            return
        }
        let path = try validatedPath(snapshot.relativePath)
        var documents = try await documentRepository.documents(
            in: localProjectID
        )
        let documentID = DocumentID(rawValue: snapshot.documentID)
        let current = documents.first { $0.id == documentID }
        let root = try await workspaceLocator.workspaceRoot(
            for: localProjectID
        )
        if snapshot.isDeleted {
            try await applyTombstone(
                localProjectID: localProjectID,
                snapshot: snapshot,
                current: current,
                documents: documents,
                root: root
            )
            return
        }
        let hierarchy = try await ensureFolderHierarchy(
            for: path,
            localProjectID: localProjectID,
            documents: documents,
            root: root,
            modifiedAt: snapshot.updatedAt
        )
        documents = hierarchy.documents
        if documents.contains(where: {
            $0.id != documentID
                && normalized($0.relativePath.rawValue)
                    == normalized(path.rawValue)
        }) {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        let parentPath = (path.rawValue as NSString)
            .deletingLastPathComponent
        let parent: DocumentNode?
        if parentPath.isEmpty || parentPath == "." {
            parent = nil
        } else {
            parent = documents.first {
                $0.kind == .folder
                    && normalized($0.relativePath.rawValue)
                        == normalized(parentPath)
            }
            guard parent != nil else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
        }

        let destination = root.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw SyncV2LocalSnapshotApplyError.unsafePath
        }
        let parentURL = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: parentURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }

        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existingMarker: RecoveryMarker?
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder().decode(
               RecoveryMarker.self,
               from: data
           ) {
            existingMarker = marker
        } else {
            existingMarker = nil
        }
        let recoveringSameSnapshot =
            existingMarker?.localProjectID == localProjectID
            && existingMarker?.snapshot.documentID
                == snapshot.documentID
            && existingMarker?.snapshot.revision == snapshot.revision
            && normalized(
                existingMarker?.snapshot.relativePath ?? ""
            ) == normalized(snapshot.relativePath)
        if current?.relativePath != path,
           fileManager.fileExists(atPath: destination.path),
           !recoveringSameSnapshot {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        let data = Data(snapshot.content.utf8)
        if !recoveringSameSnapshot {
            let previousContent: Data?
            if let current {
                previousContent = try? Data(
                    contentsOf: root.appendingPathComponent(
                        current.relativePath.rawValue
                    )
                )
            } else {
                previousContent = nil
            }
            let marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: current?.relativePath,
                previousDocument: current,
                previousContent: previousContent,
                tombstonePath: nil,
                trashRecord: nil,
                createdFolders: hierarchy.createdFolders,
                treeOrderPreviousDocuments: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(
                to: markerURL,
                options: [.atomic]
            )
        }
        let temporary = parentURL.appendingPathComponent(
            LocalDocumentStore.temporaryPrefix
                + snapshot.documentID.uuidString.lowercased()
                + "-pull-\(UUID().uuidString.lowercased())"
                + LocalDocumentStore.temporarySuffix
        )
        try writer.writeTemporaryFile(data: data, at: temporary)
        try writer.replaceItem(at: destination, with: temporary)

        let hash = hasher.sha256(for: data)
        let siblings = documents.filter { $0.parentID == parent?.id }
        let node = DocumentNode(
            id: documentID,
            projectID: localProjectID,
            kind: .text,
            parentID: parent?.id,
            relativePath: path,
            userOrder: current?.userOrder
                ?? ((siblings.map(\.userOrder).max() ?? -1) + 1),
            modifiedAt: snapshot.updatedAt,
            contentHash: hash,
            deletionStatus: .active,
            cursor: current?.cursor ?? .start,
            isExpanded: current?.isExpanded ?? false
        )
        try await documentRepository.save(node)

        if let current, current.relativePath != path {
            let oldURL = root.appendingPathComponent(
                current.relativePath.rawValue
            ).standardizedFileURL
            if oldURL.path.hasPrefix(rootPrefix),
               fileManager.fileExists(atPath: oldURL.path) {
                try fileManager.removeItem(at: oldURL)
            }
        }
    }

    func requiresCopyRecovery(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool {
        guard snapshot.relativePath != syncV2TreeOrderPath,
              snapshot.relativePath != syncV2TrashPurgePath,
              let root = try? await workspaceLocator.workspaceRoot(
                  for: localProjectID
              )
        else { return false }
        if isSameRecovery(
            recoveryMarker(
                at: recoveryMarkerURL(
                    documentID: snapshot.documentID,
                    root: root
                )
            ),
            localProjectID: localProjectID,
            snapshot: snapshot
        ) {
            return true
        }
        guard
            let documents = try? await documentRepository.documents(
                in: localProjectID
            ),
            let current = documents.first(where: {
                $0.id.rawValue == snapshot.documentID
            }),
            current.kind == .text
        else { return false }
        let currentURL = root.appendingPathComponent(
            current.relativePath.rawValue
        ).standardizedFileURL
        if snapshot.isDeleted {
            guard isTrashed(current) else { return false }
            return !isInTrash(current.relativePath)
                || !fileManager.fileExists(atPath: currentURL.path)
        }
        return isActive(current)
            && normalized(current.relativePath.rawValue)
                == normalized(snapshot.relativePath)
            && !fileManager.fileExists(atPath: currentURL.path)
    }

    func trashPurgeState(
        localProjectID: ProjectID
    ) async -> SyncV2TrashPurgePayload {
        guard
            let root = try? await workspaceLocator.workspaceRoot(
                for: localProjectID
            ),
            let data = try? Data(contentsOf: trashPurgeStateURL(root: root)),
            let content = String(data: data, encoding: .utf8),
            let state = try? SyncV2TrashPurgePayload(strictContent: content)
        else { return .empty }
        return state
    }

    func trashDocumentIDs(
        localProjectID: ProjectID
    ) async -> Set<UUID> {
        guard let documents = try? await documentRepository.documents(
            in: localProjectID
        ) else { return [] }
        return Set(
            documents.compactMap {
                guard
                    $0.relativePath != BinderFixedCategory.trash.relativePath,
                    isInTrash($0.relativePath)
                else { return nil }
                return $0.id.rawValue
            }
        )
    }

    func applyTrashPurge(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        eligibleDocumentIDs: Set<UUID>
    ) async throws {
        guard
            !snapshot.isDeleted,
            snapshot.relativePath == syncV2TrashPurgePath
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let remote: SyncV2TrashPurgePayload
        do {
            remote = try SyncV2TrashPurgePayload(
                strictContent: snapshot.content
            )
        } catch {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let root = try await workspaceLocator.workspaceRoot(
            for: localProjectID
        )
        let stateURL = trashPurgeStateURL(root: root)
        let previousStateData = try? Data(contentsOf: stateURL)
        let previousState: SyncV2TrashPurgePayload
        if let previousStateData {
            guard
                let content = String(
                    data: previousStateData,
                    encoding: .utf8
                ),
                let decoded = try? SyncV2TrashPurgePayload(
                    strictContent: content
                )
            else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            previousState = decoded
        } else {
            previousState = .empty
        }
        let merged = previousState.merging(remote)
        let isNewEmptyGeneration = !remote.emptyGeneration.isEmpty
            && remote.emptyGeneration != previousState.emptyGeneration
        let appliedStateData: Data
        do {
            appliedStateData = Data(try merged.canonicalContent().utf8)
        } catch {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }

        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existingMarker = recoveryMarker(at: markerURL)
        let marker: RecoveryMarker
        if isSameRecovery(
            existingMarker,
            localProjectID: localProjectID,
            snapshot: snapshot
        ), let existingMarker,
           existingMarker.trashPurgeItems != nil,
           existingMarker.trashPurgeAppliedState == appliedStateData {
            marker = existingMarker
        } else {
            let documents = try await documentRepository.documents(
                in: localProjectID
            )
            let targetIDs: Set<DocumentID>
            if isNewEmptyGeneration {
                targetIDs = Set(documents.compactMap {
                    guard
                        $0.relativePath
                            != BinderFixedCategory.trash.relativePath,
                        isInTrash($0.relativePath)
                    else { return nil }
                    return $0.id
                })
            } else {
                targetIDs = Set(eligibleDocumentIDs.map(DocumentID.init))
            }
            let targets = documents.filter {
                targetIDs.contains($0.id)
                    && isInTrash($0.relativePath)
                    && $0.relativePath
                        != BinderFixedCategory.trash.relativePath
                    && (isNewEmptyGeneration
                        || ($0.kind == .text && isTrashed($0)))
            }
            let items = targets.map { document in
                let fileURL = root.appendingPathComponent(
                    document.relativePath.rawValue
                ).standardizedFileURL
                let recordURL = trashRecordURL(
                    documentID: document.id,
                    root: root
                )
                return TrashPurgeRecovery(
                    document: document,
                    stagedFileName: document.kind == .text
                        ? document.id.rawValue.uuidString.lowercased()
                            + ".item"
                        : nil,
                    hadFile: document.kind == .text
                        && fileManager.fileExists(atPath: fileURL.path),
                    stagedTrashRecordName: document.kind == .text
                        ? document.id.rawValue.uuidString.lowercased()
                            + ".trash-record"
                        : nil,
                    hadTrashRecord: document.kind == .text
                        && fileManager.fileExists(atPath: recordURL.path)
                )
            }
            marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: nil,
                previousDocument: nil,
                previousContent: nil,
                tombstonePath: nil,
                trashRecord: nil,
                createdFolders: nil,
                treeOrderPreviousDocuments: nil,
                trashPurgeItems: items,
                trashPurgePreviousState: previousStateData,
                trashPurgeAppliedState: appliedStateData
            )
            try writeRecoveryMarker(marker, to: markerURL)
        }

        do {
            try await applyTrashPurgeMarker(marker, root: root)
        } catch {
            await rollbackTrashPurge(marker, root: root)
            throw error
        }
    }

    private func applyTrashPurgeMarker(
        _ marker: RecoveryMarker,
        root: URL
    ) async throws {
        guard
            let items = marker.trashPurgeItems,
            let appliedState = marker.trashPurgeAppliedState
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let stage = trashPurgeStageURL(
            documentID: marker.snapshot.documentID,
            root: root
        )
        try fileManager.createDirectory(
            at: stage,
            withIntermediateDirectories: true
        )
        for item in items where item.document.kind == .text {
            if let stagedName = item.stagedFileName {
                try stageTrashPurgeFile(
                    source: root.appendingPathComponent(
                        item.document.relativePath.rawValue
                    ).standardizedFileURL,
                    destination: stage.appendingPathComponent(stagedName),
                    expected: item.hadFile
                )
            }
            if let stagedName = item.stagedTrashRecordName {
                try stageTrashPurgeFile(
                    source: trashRecordURL(
                        documentID: item.document.id,
                        root: root
                    ),
                    destination: stage.appendingPathComponent(stagedName),
                    expected: item.hadTrashRecord
                )
            }
        }

        let folders = items.filter { $0.document.kind == .folder }.sorted {
            pathDepth($0.document.relativePath) > pathDepth($1.document.relativePath)
        }
        for folder in folders {
            let url = root.appendingPathComponent(
                folder.document.relativePath.rawValue
            ).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard
                (try fileManager.contentsOfDirectory(atPath: url.path)).isEmpty
            else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            try fileManager.removeItem(at: url)
        }

        for item in items.sorted(by: {
            pathDepth($0.document.relativePath)
                > pathDepth($1.document.relativePath)
        }) {
            try await documentRepository.removeMetadata(id: item.document.id)
        }
        try appliedState.write(
            to: trashPurgeStateURL(root: root),
            options: [.atomic]
        )
    }

    private func stageTrashPurgeFile(
        source: URL,
        destination: URL,
        expected: Bool
    ) throws {
        let sourceExists = fileManager.fileExists(atPath: source.path)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        switch (sourceExists, destinationExists) {
        case (true, false):
            try fileManager.moveItem(at: source, to: destination)
        case (false, true):
            guard expected else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
        case (false, false):
            guard !expected else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
        case (true, true):
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
    }

    private func ensureFolderHierarchy(
        for documentPath: RelativeDocumentPath,
        localProjectID: ProjectID,
        documents initialDocuments: [DocumentNode],
        root: URL,
        modifiedAt: Date
    ) async throws -> EnsuredFolderHierarchy {
        do {
            try pathPolicy.validateRelativePath(documentPath)
        } catch {
            throw SyncV2LocalSnapshotApplyError.unsafePath
        }
        let parentPathValue = (documentPath.rawValue as NSString)
            .deletingLastPathComponent
        if initialDocuments.contains(where: {
            $0.kind == .folder
                && isActive($0)
                && normalized($0.relativePath.rawValue)
                    == normalized(parentPathValue)
        }) {
            return EnsuredFolderHierarchy(
                documents: initialDocuments,
                createdFolders: []
            )
        }
        let components = documentPath.rawValue.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 2, components.first == "메인" else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        var documents = initialDocuments
        guard var parent = documents.first(where: {
            $0.kind == .folder
                && normalized($0.relativePath.rawValue) == normalized("메인")
                && isActive($0)
        }) else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        var createdFolders: [CreatedFolderRecovery] = []
        var accumulated = components[0]

        for component in components.dropFirst().dropLast() {
            accumulated += "/" + component
            let folderPath = RelativeDocumentPath(rawValue: accumulated)
            if let existing = documents.first(where: {
                normalized($0.relativePath.rawValue)
                    == normalized(folderPath.rawValue)
            }) {
                guard existing.kind == .folder,
                      existing.parentID == parent.id,
                      isActive(existing)
                else {
                    throw SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument
                }
                parent = existing
                continue
            }

            let parentURL = root.appendingPathComponent(
                parent.relativePath.rawValue
            ).standardizedFileURL
            let destination = root.appendingPathComponent(
                folderPath.rawValue
            ).standardizedFileURL
            let rootPrefix = root.standardizedFileURL.path + "/"
            guard destination.path.hasPrefix(rootPrefix) else {
                throw SyncV2LocalSnapshotApplyError.unsafePath
            }
            let siblingNames = try fileManager.contentsOfDirectory(
                atPath: parentURL.path
            )
            if let collision = siblingNames.first(where: {
                pathPolicy.collisionKey(for: $0)
                    == pathPolicy.collisionKey(for: component)
            }), collision.precomposedStringWithCanonicalMapping
                != component.precomposedStringWithCanonicalMapping {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }

            var isDirectory: ObjCBool = false
            let existed = fileManager.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            )
            if existed, !isDirectory.boolValue {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            if existed,
               (try? destination.resourceValues(
                    forKeys: [.isSymbolicLinkKey]
               ).isSymbolicLink) == true {
                throw SyncV2LocalSnapshotApplyError.unsafePath
            }
            if !existed {
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: false
                )
            }

            let identifier = DocumentID(
                rawValue: syncV2UUIDv5(
                    namespace: localProjectID.rawValue,
                    name: "writerpad-local-folder/" + normalized(accumulated)
                )
            )
            if let occupied = documents.first(where: { $0.id == identifier }),
               normalized(occupied.relativePath.rawValue)
                    != normalized(folderPath.rawValue) {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            let siblings = documents.filter { $0.parentID == parent.id }
            let folder = DocumentNode(
                id: identifier,
                projectID: localProjectID,
                kind: .folder,
                parentID: parent.id,
                relativePath: folderPath,
                userOrder: (siblings.map(\.userOrder).max() ?? -1) + 1,
                modifiedAt: modifiedAt,
                contentHash: nil
            )
            try await documentRepository.save(folder)
            documents.append(folder)
            createdFolders.append(
                CreatedFolderRecovery(
                    document: folder,
                    createdDirectory: !existed
                )
            )
            parent = folder
        }
        return EnsuredFolderHierarchy(
            documents: documents,
            createdFolders: createdFolders
        )
    }

    private func applyTreeOrder(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws {
        guard !snapshot.isDeleted,
              let decodedPayload = try? JSONDecoder().decode(
                  TreeOrderPayload.self,
                  from: Data(snapshot.content.utf8)
              ),
              decodedPayload.version == 1
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let payload = try canonicalTreeOrderPayload(decodedPayload)
        var documents = try await documentRepository.documents(
            in: localProjectID
        )
        let root = try await workspaceLocator.workspaceRoot(
            for: localProjectID
        )
        let hierarchy = try planTreeOrderFolders(
            payload: payload,
            localProjectID: localProjectID,
            documents: documents,
            root: root,
            modifiedAt: snapshot.updatedAt
        )
        documents = hierarchy.documents
        let ruleService = BinderRuleService(pathPolicy: pathPolicy)
        var replacements: [DocumentNode] = []
        var previousByID: [DocumentID: DocumentNode] = [:]
        let createdFolderIDs = Set(
            hierarchy.createdFolders.map(\.document.id)
        )

        for key in payload.treeOrder.keys.sorted() {
            guard let names = payload.treeOrder[key] else { continue }
            let parentPath: RelativeDocumentPath
            if key == "<root>" {
                parentPath = RelativeDocumentPath(rawValue: "메인")
            } else {
                parentPath = RelativeDocumentPath(rawValue: key)
                do {
                    try pathPolicy.validateRelativePath(parentPath)
                } catch {
                    throw SyncV2LocalSnapshotApplyError.unsafePath
                }
                guard key == "메인" || key.hasPrefix("메인/") else {
                    throw SyncV2LocalSnapshotApplyError.invalidHierarchy
                }
            }
            if isInTrash(parentPath)
                || ruleService.usesManuscriptNaturalOrder(in: parentPath) {
                continue
            }
            var remoteKeys = Set<String>()
            for name in names {
                do {
                    try pathPolicy.validateName(name)
                } catch {
                    throw SyncV2LocalSnapshotApplyError.unsafePath
                }
                guard remoteKeys.insert(
                    pathPolicy.collisionKey(for: name)
                ).inserted else {
                    throw SyncV2LocalSnapshotApplyError.invalidHierarchy
                }
            }
            guard let parent = documents.first(where: {
                $0.kind == .folder
                    && isActive($0)
                    && normalized($0.relativePath.rawValue)
                        == normalized(parentPath.rawValue)
            }) else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            let children = documents.filter {
                $0.parentID == parent.id && isActive($0)
            }
            var byName: [String: DocumentNode] = [:]
            for child in children {
                let childKey = pathPolicy.collisionKey(
                    for: storedName(of: child)
                )
                guard byName.updateValue(child, forKey: childKey) == nil else {
                    throw SyncV2LocalSnapshotApplyError.invalidHierarchy
                }
            }
            var ordered: [DocumentNode] = []
            var used = Set<DocumentID>()
            for name in names {
                if let child = byName[pathPolicy.collisionKey(for: name)] {
                    ordered.append(child)
                    used.insert(child.id)
                }
            }
            ordered.append(
                contentsOf: children.filter { !used.contains($0.id) }.sorted {
                    if $0.userOrder != $1.userOrder {
                        return $0.userOrder < $1.userOrder
                    }
                    return $0.relativePath.rawValue < $1.relativePath.rawValue
                }
            )
            if parentPath.rawValue == "메인" {
                ordered = ordered.filter {
                    $0.relativePath != BinderFixedCategory.manuscript.relativePath
                        && $0.relativePath != BinderFixedCategory.trash.relativePath
                }
            }
            let offset = parentPath.rawValue == "메인"
                ? BinderOrderingPolicy.customizedRootOrderOffset
                : 0
            for (index, child) in ordered.enumerated() {
                let desiredOrder = offset + index
                guard child.userOrder != desiredOrder else { continue }
                if !createdFolderIDs.contains(child.id) {
                    previousByID[child.id] = child
                }
                replacements.append(
                    DocumentNode(
                        id: child.id,
                        projectID: child.projectID,
                        kind: child.kind,
                        parentID: child.parentID,
                        relativePath: child.relativePath,
                        userOrder: desiredOrder,
                        modifiedAt: snapshot.updatedAt,
                        contentHash: child.contentHash,
                        deletionStatus: child.deletionStatus,
                        cursor: child.cursor,
                        isExpanded: child.isExpanded
                    )
                )
            }
        }

        guard !replacements.isEmpty || !hierarchy.createdFolders.isEmpty else {
            return
        }
        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existing = recoveryMarker(at: markerURL)
        let marker: RecoveryMarker
        if isSameRecovery(
            existing,
            localProjectID: localProjectID,
            snapshot: snapshot
        ), let existing,
           existing.treeOrderPreviousDocuments != nil {
            marker = existing
        } else {
            marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: nil,
                previousDocument: nil,
                previousContent: nil,
                tombstonePath: nil,
                trashRecord: nil,
                createdFolders: hierarchy.createdFolders,
                treeOrderPreviousDocuments: Array(previousByID.values)
            )
            try writeRecoveryMarker(
                marker,
                to: markerURL
            )
        }
        do {
            for recovery in hierarchy.createdFolders {
                let url = root.appendingPathComponent(
                    recovery.document.relativePath.rawValue
                ).standardizedFileURL
                if recovery.createdDirectory {
                    try fileManager.createDirectory(
                        at: url,
                        withIntermediateDirectories: false
                    )
                }
                try await documentRepository.save(recovery.document)
            }
            for replacement in replacements {
                try await documentRepository.save(replacement)
            }
        } catch {
            await rollbackTreeOrder(marker, root: root)
            throw error
        }
    }

    private func canonicalTreeOrderPayload(
        _ payload: TreeOrderPayload
    ) throws -> TreeOrderPayload {
        var result: [String: [String]] = [:]
        for key in payload.treeOrder.keys.sorted() {
            guard let names = payload.treeOrder[key] else { continue }
            let canonicalKey = canonicalTreeOrderKey(key)
            let canonicalNames = key == "<root>"
                ? names.map(canonicalRootTreeOrderName)
                : names
            guard result[canonicalKey] == nil else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            result[canonicalKey] = canonicalNames
        }
        return TreeOrderPayload(version: payload.version, treeOrder: result)
    }

    private func canonicalTreeOrderKey(_ key: String) -> String {
        guard key != "<root>" else { return key }
        var components = key.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count >= 2, components[0] == "메인" else {
            return key
        }
        components[1] = canonicalRootTreeOrderName(components[1])
        return components.joined(separator: "/")
    }

    private func canonicalRootTreeOrderName(_ name: String) -> String {
        legacyRootTreeOrderAliases[name] ?? name
    }

    private func planTreeOrderFolders(
        payload: TreeOrderPayload,
        localProjectID: ProjectID,
        documents initialDocuments: [DocumentNode],
        root: URL,
        modifiedAt: Date
    ) throws -> EnsuredFolderHierarchy {
        var folderPaths = Set<String>()
        let remotePaths = remoteLiveDocumentPaths[localProjectID] ?? []

        for key in payload.treeOrder.keys.sorted() {
            guard let names = payload.treeOrder[key] else { continue }
            let parentValue: String
            if key == "<root>" {
                parentValue = "메인"
            } else {
                let parentPath = RelativeDocumentPath(rawValue: key)
                do {
                    try pathPolicy.validateRelativePath(parentPath)
                } catch {
                    throw SyncV2LocalSnapshotApplyError.unsafePath
                }
                guard key == "메인" || key.hasPrefix("메인/") else {
                    throw SyncV2LocalSnapshotApplyError.invalidHierarchy
                }
                parentValue = key
                if !isInTrash(parentPath) {
                    folderPaths.insert(key)
                }
            }

            var childKeys = Set<String>()
            for name in names {
                do {
                    try pathPolicy.validateName(name)
                } catch {
                    throw SyncV2LocalSnapshotApplyError.unsafePath
                }
                guard childKeys.insert(
                    pathPolicy.collisionKey(for: name)
                ).inserted else {
                    throw SyncV2LocalSnapshotApplyError.invalidHierarchy
                }
                let childValue = parentValue + "/" + name
                let childPath = RelativeDocumentPath(rawValue: childValue)
                do {
                    try pathPolicy.validateRelativePath(childPath)
                } catch {
                    throw SyncV2LocalSnapshotApplyError.unsafePath
                }
                guard !isInTrash(childPath),
                      !remotePaths.contains(normalized(childValue))
                else { continue }
                if let existing = initialDocuments.first(where: {
                    isActive($0)
                        && normalized($0.relativePath.rawValue)
                            == normalized(childValue)
                }) {
                    guard existing.kind == .folder else { continue }
                }
                folderPaths.insert(childValue)
            }
        }

        var expandedPaths = folderPaths
        for value in folderPaths {
            let components = value.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard components.count >= 2, components.first == "메인" else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            for endIndex in 2...components.count {
                let ancestor = components.prefix(endIndex).joined(separator: "/")
                if remotePaths.contains(normalized(ancestor)) {
                    throw SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument
                }
                expandedPaths.insert(ancestor)
            }
        }

        let orderedPaths = expandedPaths.sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0 < $1
        }
        var documents = initialDocuments
        guard documents.contains(where: {
            $0.kind == .folder
                && isActive($0)
                && normalized($0.relativePath.rawValue) == normalized("메인")
        }) else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        var createdFolders: [CreatedFolderRecovery] = []
        let rootPrefix = root.standardizedFileURL.path + "/"

        for value in orderedPaths {
            let path = RelativeDocumentPath(rawValue: value)
            if isInTrash(path) { continue }
            if let existing = documents.first(where: {
                normalized($0.relativePath.rawValue) == normalized(value)
            }) {
                guard existing.kind == .folder, isActive(existing) else {
                    throw SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument
                }
                continue
            }
            let parentValue = (value as NSString).deletingLastPathComponent
            guard let parent = documents.first(where: {
                $0.kind == .folder
                    && isActive($0)
                    && normalized($0.relativePath.rawValue)
                        == normalized(parentValue)
            }) else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            let component = (value as NSString).lastPathComponent
            let parentURL = root.appendingPathComponent(parentValue)
                .standardizedFileURL
            let destination = root.appendingPathComponent(value)
                .standardizedFileURL
            guard destination.path.hasPrefix(rootPrefix) else {
                throw SyncV2LocalSnapshotApplyError.unsafePath
            }
            var parentIsDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: parentURL.path,
                isDirectory: &parentIsDirectory
            ) {
                guard parentIsDirectory.boolValue else {
                    throw SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument
                }
                let siblingNames = try fileManager.contentsOfDirectory(
                    atPath: parentURL.path
                )
                if let collision = siblingNames.first(where: {
                    pathPolicy.collisionKey(for: $0)
                        == pathPolicy.collisionKey(for: component)
                }), collision.precomposedStringWithCanonicalMapping
                    != component.precomposedStringWithCanonicalMapping {
                    throw SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument
                }
            }
            var isDirectory: ObjCBool = false
            let existed = fileManager.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            )
            if existed, !isDirectory.boolValue {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            if existed,
               (try? destination.resourceValues(
                   forKeys: [.isSymbolicLinkKey]
               ).isSymbolicLink) == true {
                throw SyncV2LocalSnapshotApplyError.unsafePath
            }
            let identifier = DocumentID(
                rawValue: syncV2UUIDv5(
                    namespace: localProjectID.rawValue,
                    name: "writerpad-local-folder/" + normalized(value)
                )
            )
            if let occupied = documents.first(where: { $0.id == identifier }),
               normalized(occupied.relativePath.rawValue) != normalized(value) {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            let siblings = documents.filter { $0.parentID == parent.id }
            let folder = DocumentNode(
                id: identifier,
                projectID: localProjectID,
                kind: .folder,
                parentID: parent.id,
                relativePath: path,
                userOrder: (siblings.map(\.userOrder).max() ?? -1) + 1,
                modifiedAt: modifiedAt,
                contentHash: nil
            )
            documents.append(folder)
            createdFolders.append(
                CreatedFolderRecovery(
                    document: folder,
                    createdDirectory: !existed
                )
            )
        }
        return EnsuredFolderHierarchy(
            documents: documents,
            createdFolders: createdFolders
        )
    }

    private func storedName(of document: DocumentNode) -> String {
        (document.relativePath.rawValue as NSString).lastPathComponent
    }

    private func isActive(_ document: DocumentNode) -> Bool {
        if case .active = document.deletionStatus { return true }
        return false
    }

    private func isTrashed(_ document: DocumentNode) -> Bool {
        if case .trashed = document.deletionStatus { return true }
        return false
    }

    private func isInTrash(_ path: RelativeDocumentPath) -> Bool {
        let key = normalized(path.rawValue)
        let trash = normalized(BinderFixedCategory.trash.relativePath.rawValue)
        return key == trash || key.hasPrefix(trash + "/")
    }

    private func applyTombstone(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        current: DocumentNode?,
        documents: [DocumentNode],
        root: URL
    ) async throws {
        guard let current else {
            // 이 기기에 live 사본이 없는 tombstone도 SyncV2Store baseline에는
            // 기록한다. 만들거나 삭제할 로컬 TXT는 없다.
            return
        }
        guard current.kind == .text else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        if case .trashed = current.deletionStatus {
            let currentURL = root.appendingPathComponent(
                current.relativePath.rawValue
            ).standardizedFileURL
            if isInTrash(current.relativePath),
               fileManager.fileExists(atPath: currentURL.path) {
                return
            }
            try await repairTombstoneCopy(
                localProjectID: localProjectID,
                snapshot: snapshot,
                current: current,
                documents: documents,
                root: root
            )
            return
        }
        guard let originalParentID = current.parentID,
              let trash = documents.first(where: {
                  $0.kind == .folder
                      && $0.relativePath
                          == BinderFixedCategory.trash.relativePath
              })
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }

        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existingMarker = recoveryMarker(at: markerURL)
        let marker: RecoveryMarker
        if isSameRecovery(
            existingMarker,
            localProjectID: localProjectID,
            snapshot: snapshot
        ), let existingMarker,
           existingMarker.previousDocument?.id == current.id,
           existingMarker.tombstonePath != nil,
           existingMarker.trashRecord != nil {
            marker = existingMarker
        } else {
            let sourceURL = root.appendingPathComponent(
                current.relativePath.rawValue
            ).standardizedFileURL
            guard let previousContent = try? Data(contentsOf: sourceURL) else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            let destinationPath = try tombstoneDestinationPath(
                for: current,
                root: root
            )
            let deletedAt = snapshot.deletedAt ?? snapshot.updatedAt
            let record = TrashRecord(
                documentID: current.id,
                originalPath: current.relativePath,
                originalParentID: originalParentID,
                originalUserOrder: current.userOrder,
                deletedAt: deletedAt
            )
            marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: current.relativePath,
                previousDocument: current,
                previousContent: previousContent,
                tombstonePath: destinationPath,
                trashRecord: record,
                createdFolders: nil,
                treeOrderPreviousDocuments: nil
            )
            try writeRecoveryMarker(marker, to: markerURL)
        }

        guard let previous = marker.previousDocument,
              let destinationPath = marker.tombstonePath,
              let record = marker.trashRecord,
              let previousContent = marker.previousContent
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let sourceURL = root.appendingPathComponent(
            previous.relativePath.rawValue
        ).standardizedFileURL
        let destinationURL = root.appendingPathComponent(
            destinationPath.rawValue
        ).standardizedFileURL
        let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
        let destinationExists = fileManager.fileExists(
            atPath: destinationURL.path
        )
        switch (sourceExists, destinationExists) {
        case (true, false):
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        case (false, true):
            guard (try? Data(contentsOf: destinationURL)) == previousContent else {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
        default:
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        try writeTrashRecord(record, root: root)
        let siblings = documents.filter { $0.parentID == trash.id }
        try await documentRepository.save(
            DocumentNode(
                id: previous.id,
                projectID: previous.projectID,
                kind: previous.kind,
                parentID: trash.id,
                relativePath: destinationPath,
                userOrder: (siblings.map(\.userOrder).max() ?? -1) + 1,
                modifiedAt: record.deletedAt,
                contentHash: previous.contentHash,
                deletionStatus: .trashed(
                    originalPath: previous.relativePath,
                    deletedAt: record.deletedAt
                ),
                cursor: previous.cursor,
                isExpanded: previous.isExpanded
            )
        )
    }

    private func repairTombstoneCopy(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        current: DocumentNode,
        documents: [DocumentNode],
        root: URL
    ) async throws {
        guard case let .trashed(originalPath, localDeletedAt) =
                current.deletionStatus,
              let trash = documents.first(where: {
                  $0.kind == .folder
                      && $0.relativePath
                          == BinderFixedCategory.trash.relativePath
              })
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existingMarker = recoveryMarker(at: markerURL)
        let marker: RecoveryMarker
        if isSameRecovery(
            existingMarker,
            localProjectID: localProjectID,
            snapshot: snapshot
        ), let existingMarker,
           existingMarker.isTombstoneRepair == true,
           existingMarker.previousDocument?.id == current.id,
           existingMarker.tombstonePath != nil,
           existingMarker.trashRecord != nil {
            marker = existingMarker
        } else {
            let previousRecord = readTrashRecord(
                documentID: current.id,
                root: root
            )
            let originalParentPath = (originalPath.rawValue as NSString)
                .deletingLastPathComponent
            let originalParent = documents.first {
                $0.kind == .folder
                    && normalized($0.relativePath.rawValue)
                        == normalized(originalParentPath)
            }
            guard let originalParentID = previousRecord?.originalParentID
                    ?? originalParent?.id
            else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
            let destinationPath = try recoveredTombstoneDestinationPath(
                remotePath: snapshot.relativePath,
                documentID: snapshot.documentID,
                root: root
            )
            let record = previousRecord ?? TrashRecord(
                documentID: current.id,
                originalPath: originalPath,
                originalParentID: originalParentID,
                originalUserOrder: current.userOrder,
                deletedAt: snapshot.deletedAt
                    ?? snapshot.updatedAt
            )
            let currentURL = root.appendingPathComponent(
                current.relativePath.rawValue
            ).standardizedFileURL
            marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: current.relativePath,
                previousDocument: current,
                previousContent: try? Data(contentsOf: currentURL),
                tombstonePath: destinationPath,
                trashRecord: record,
                createdFolders: nil,
                treeOrderPreviousDocuments: nil,
                isTombstoneRepair: true,
                tombstoneRepairHadTrashRecord: previousRecord != nil
            )
            try writeRecoveryMarker(marker, to: markerURL)
        }

        guard let destinationPath = marker.tombstonePath,
              let record = marker.trashRecord
        else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let destinationURL = root.appendingPathComponent(
            destinationPath.rawValue
        ).standardizedFileURL
        let data = Data(snapshot.content.utf8)
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard (try? Data(contentsOf: destinationURL)) == data else {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
        } else {
            let temporary = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(
                    LocalDocumentStore.temporaryPrefix
                        + snapshot.documentID.uuidString.lowercased()
                        + "-tombstone-repair-"
                        + UUID().uuidString.lowercased()
                        + LocalDocumentStore.temporarySuffix
                )
            try writer.writeTemporaryFile(data: data, at: temporary)
            try writer.replaceItem(at: destinationURL, with: temporary)
        }
        try writeTrashRecord(record, root: root)
        let siblings = documents.filter { $0.parentID == trash.id }
        try await documentRepository.save(
            DocumentNode(
                id: current.id,
                projectID: current.projectID,
                kind: current.kind,
                parentID: trash.id,
                relativePath: destinationPath,
                userOrder: current.parentID == trash.id
                    ? current.userOrder
                    : ((siblings.map(\.userOrder).max() ?? -1) + 1),
                modifiedAt: record.deletedAt,
                contentHash: hasher.sha256(for: data),
                deletionStatus: .trashed(
                    originalPath: originalPath,
                    deletedAt: localDeletedAt
                ),
                cursor: current.cursor,
                isExpanded: current.isExpanded
            )
        )
    }

    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        guard let root = try? await workspaceLocator.workspaceRoot(
            for: localProjectID
        ) else { return }
        let markerURL = recoveryMarkerURL(
            documentID: documentID,
            root: root
        )
        if let marker = recoveryMarker(at: markerURL),
           marker.snapshot.relativePath == syncV2TrashPurgePath {
            try? fileManager.removeItem(
                at: trashPurgeStageURL(
                    documentID: documentID,
                    root: root
                )
            )
            try? fileManager.removeItem(at: markerURL)
            return
        }
        if let marker = recoveryMarker(at: markerURL),
           !marker.snapshot.isDeleted,
           let previous = marker.previousDocument,
           case .trashed = previous.deletionStatus {
            try? fileManager.removeItem(
                at: trashRecordURL(documentID: previous.id, root: root)
            )
        }
        try? fileManager.removeItem(
            at: markerURL
        )
    }

    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        guard
            let root = try? await workspaceLocator.workspaceRoot(
                for: localProjectID
            ),
            let markerData = try? Data(
                contentsOf: recoveryMarkerURL(
                    documentID: documentID,
                    root: root
                )
            ),
            let marker = try? JSONDecoder().decode(
                RecoveryMarker.self,
                from: markerData
            ),
            marker.localProjectID == localProjectID,
            marker.snapshot.documentID == documentID
        else { return }

        if marker.snapshot.relativePath == syncV2TreeOrderPath {
            await rollbackTreeOrder(marker, root: root)
            return
        }

        if marker.snapshot.relativePath == syncV2TrashPurgePath {
            await rollbackTrashPurge(marker, root: root)
            return
        }

        if marker.snapshot.isDeleted {
            if marker.isTombstoneRepair == true {
                await rollbackTombstoneRepair(marker, root: root)
                return
            }
            await rollbackTombstone(marker, root: root)
            return
        }

        guard
            let appliedPath = try? validatedPath(
                marker.snapshot.relativePath
            )
        else { return }

        let appliedURL = root.appendingPathComponent(
            appliedPath.rawValue
        ).standardizedFileURL
        let appliedData = Data(marker.snapshot.content.utf8)
        guard
            let currentData = try? Data(contentsOf: appliedURL),
            currentData == appliedData
        else {
            // 적용 뒤 더 최신 로컬 저장이 있었다면 절대 되돌리지 않는다.
            return
        }

        do {
            if let previousDocument = marker.previousDocument,
               let previousContent = marker.previousContent {
                let previousURL = root.appendingPathComponent(
                    previousDocument.relativePath.rawValue
                ).standardizedFileURL
                let temporary = previousURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        LocalDocumentStore.temporaryPrefix
                            + documentID.uuidString.lowercased()
                            + "-rollback-\(UUID().uuidString.lowercased())"
                            + LocalDocumentStore.temporarySuffix
                    )
                try writer.writeTemporaryFile(
                    data: previousContent,
                    at: temporary
                )
                try writer.replaceItem(
                    at: previousURL,
                    with: temporary
                )
                try await documentRepository.save(previousDocument)
                if previousURL != appliedURL {
                    try? fileManager.removeItem(at: appliedURL)
                }
            } else if marker.previousDocument == nil {
                try? fileManager.removeItem(at: appliedURL)
                try await documentRepository.removeMetadata(
                    id: DocumentID(rawValue: documentID)
                )
            } else {
                return
            }
            await rollbackCreatedFolders(
                marker.createdFolders ?? [],
                root: root
            )
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: documentID,
                    root: root
                )
            )
        } catch {
            // marker를 남겨 다음 복구가 동일한 보상 작업을 재개하게 한다.
        }
    }

    private func rollbackTreeOrder(
        _ marker: RecoveryMarker,
        root: URL
    ) async {
        guard let previous = marker.treeOrderPreviousDocuments else {
            return
        }
        do {
            for document in previous {
                try await documentRepository.save(document)
            }
            await rollbackCreatedFolders(
                marker.createdFolders ?? [],
                root: root
            )
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: marker.snapshot.documentID,
                    root: root
                )
            )
        } catch {
            // marker를 남겨 다음 pull 또는 복구가 원래 순서를 다시 적용한다.
        }
    }

    private func rollbackTrashPurge(
        _ marker: RecoveryMarker,
        root: URL
    ) async {
        guard let items = marker.trashPurgeItems else { return }
        let stage = trashPurgeStageURL(
            documentID: marker.snapshot.documentID,
            root: root
        )
        do {
            let folders = items.filter {
                $0.document.kind == .folder
            }.sorted {
                pathDepth($0.document.relativePath)
                    < pathDepth($1.document.relativePath)
            }
            for folder in folders {
                let url = root.appendingPathComponent(
                    folder.document.relativePath.rawValue
                ).standardizedFileURL
                if !fileManager.fileExists(atPath: url.path) {
                    try fileManager.createDirectory(
                        at: url,
                        withIntermediateDirectories: true
                    )
                }
            }
            for item in items where item.document.kind == .text {
                if item.hadFile, let stagedName = item.stagedFileName {
                    let source = stage.appendingPathComponent(stagedName)
                    let destination = root.appendingPathComponent(
                        item.document.relativePath.rawValue
                    ).standardizedFileURL
                    if fileManager.fileExists(atPath: source.path),
                       !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                }
                if item.hadTrashRecord,
                   let stagedName = item.stagedTrashRecordName {
                    let source = stage.appendingPathComponent(stagedName)
                    let destination = trashRecordURL(
                        documentID: item.document.id,
                        root: root
                    )
                    if fileManager.fileExists(atPath: source.path),
                       !fileManager.fileExists(atPath: destination.path) {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                }
            }
            for item in items.sorted(by: {
                pathDepth($0.document.relativePath)
                    < pathDepth($1.document.relativePath)
            }) {
                try await documentRepository.save(item.document)
            }

            let stateURL = trashPurgeStateURL(root: root)
            let currentState = try? Data(contentsOf: stateURL)
            if currentState == marker.trashPurgeAppliedState {
                if let previous = marker.trashPurgePreviousState {
                    try previous.write(to: stateURL, options: [.atomic])
                } else if fileManager.fileExists(atPath: stateURL.path) {
                    try fileManager.removeItem(at: stateURL)
                }
            }
            try? fileManager.removeItem(at: stage)
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: marker.snapshot.documentID,
                    root: root
                )
            )
        } catch {
            // stage와 marker를 남겨 다음 pull이 같은 복구를 재개한다.
        }
    }

    private func rollbackCreatedFolders(
        _ folders: [CreatedFolderRecovery],
        root: URL
    ) async {
        for recovery in folders.reversed() {
            guard let documents = try? await documentRepository.documents(
                in: recovery.document.projectID
            ) else { continue }
            let current = documents.first(where: {
                $0.id == recovery.document.id
                    && $0.relativePath == recovery.document.relativePath
                    && $0.kind == .folder
            })
            if let current,
               documents.contains(where: { $0.parentID == current.id }) {
                continue
            }
            let url = root.appendingPathComponent(
                recovery.document.relativePath.rawValue
            ).standardizedFileURL
            let entries = (try? fileManager.contentsOfDirectory(
                atPath: url.path
            )) ?? []
            guard entries.isEmpty else { continue }
            if let current {
                try? await documentRepository.removeMetadata(id: current.id)
            }
            if recovery.createdDirectory {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func rollbackTombstone(
        _ marker: RecoveryMarker,
        root: URL
    ) async {
        guard let previous = marker.previousDocument,
              let previousContent = marker.previousContent,
              let tombstonePath = marker.tombstonePath
        else { return }
        let originalURL = root.appendingPathComponent(
            previous.relativePath.rawValue
        ).standardizedFileURL
        let tombstoneURL = root.appendingPathComponent(
            tombstonePath.rawValue
        ).standardizedFileURL
        let originalData = try? Data(contentsOf: originalURL)
        let tombstoneData = try? Data(contentsOf: tombstoneURL)
        guard originalData == previousContent
                || (originalData == nil && tombstoneData == previousContent)
        else {
            // 다른 UUID 또는 더 최신 로컬 변경이 원래 경로를 점유했다.
            return
        }

        do {
            if originalData == nil {
                let temporary = originalURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        LocalDocumentStore.temporaryPrefix
                            + previous.id.rawValue.uuidString.lowercased()
                            + "-tombstone-rollback-"
                            + UUID().uuidString.lowercased()
                            + LocalDocumentStore.temporarySuffix
                    )
                try writer.writeTemporaryFile(
                    data: previousContent,
                    at: temporary
                )
                try writer.replaceItem(at: originalURL, with: temporary)
            }
            try await documentRepository.save(previous)
            if (try? Data(contentsOf: tombstoneURL)) == previousContent {
                try? fileManager.removeItem(at: tombstoneURL)
            }
            try? fileManager.removeItem(
                at: trashRecordURL(documentID: previous.id, root: root)
            )
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: previous.id.rawValue,
                    root: root
                )
            )
        } catch {
            // marker와 두 사본 중 적어도 하나를 남겨 다음 복구가 이어받는다.
        }
    }

    private func rollbackTombstoneRepair(
        _ marker: RecoveryMarker,
        root: URL
    ) async {
        guard let previous = marker.previousDocument,
              let tombstonePath = marker.tombstonePath
        else { return }
        let destinationURL = root.appendingPathComponent(
            tombstonePath.rawValue
        ).standardizedFileURL
        let appliedData = Data(marker.snapshot.content.utf8)
        guard (try? Data(contentsOf: destinationURL)) == appliedData,
              let documents = try? await documentRepository.documents(
                  in: marker.localProjectID
              ),
              !documents.contains(where: {
                  $0.id != previous.id
                      && normalized($0.relativePath.rawValue)
                          == normalized(tombstonePath.rawValue)
              })
        else {
            return
        }
        do {
            try await documentRepository.save(previous)
            try fileManager.removeItem(at: destinationURL)
            if marker.tombstoneRepairHadTrashRecord != true {
                try? fileManager.removeItem(
                    at: trashRecordURL(
                        documentID: previous.id,
                        root: root
                    )
                )
            }
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: previous.id.rawValue,
                    root: root
                )
            )
        } catch {
            // 생성 사본과 marker를 남겨 다음 복구가 같은 보상 작업을 재개한다.
        }
    }

    private func recoveryMarker(at url: URL) -> RecoveryMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecoveryMarker.self, from: data)
    }

    private func isSameRecovery(
        _ marker: RecoveryMarker?,
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) -> Bool {
        marker?.localProjectID == localProjectID
            && marker?.snapshot.documentID == snapshot.documentID
            && marker?.snapshot.revision == snapshot.revision
            && marker?.snapshot.isDeleted == snapshot.isDeleted
            && normalized(marker?.snapshot.relativePath ?? "")
                == normalized(snapshot.relativePath)
    }

    private func writeRecoveryMarker(
        _ marker: RecoveryMarker,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: url, options: [.atomic])
    }

    private func tombstoneDestinationPath(
        for document: DocumentNode,
        root: URL
    ) throws -> RelativeDocumentPath {
        let trashPath = BinderFixedCategory.trash.relativePath
        let trashURL = root.appendingPathComponent(trashPath.rawValue)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: trashURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let originalName = (document.relativePath.rawValue as NSString)
            .lastPathComponent
        let stem = (originalName as NSString).deletingPathExtension
        let pathExtension = (originalName as NSString).pathExtension
        let existing = Set(
            try fileManager.contentsOfDirectory(atPath: trashURL.path)
                .map(normalized)
        )
        var candidate = originalName
        var suffix = 2
        while existing.contains(normalized(candidate)) {
            candidate = stem + "_\(suffix)"
                + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            suffix += 1
        }
        return RelativeDocumentPath(
            rawValue: trashPath.rawValue + "/" + candidate
        )
    }

    private func recoveredTombstoneDestinationPath(
        remotePath: String,
        documentID: UUID,
        root: URL
    ) throws -> RelativeDocumentPath {
        let trashPath = BinderFixedCategory.trash.relativePath
        let trashURL = root.appendingPathComponent(trashPath.rawValue)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: trashURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }
        let originalName = (remotePath as NSString).lastPathComponent
        let stem = (originalName as NSString).deletingPathExtension
        let pathExtension = (originalName as NSString).pathExtension
        let identifier = documentID.uuidString.lowercased()
        let existing = Set(
            try fileManager.contentsOfDirectory(atPath: trashURL.path)
                .map(normalized)
        )
        var suffix = 1
        var candidate: String
        repeat {
            let numbered = suffix == 1 ? "" : "_\(suffix)"
            candidate = stem + "__" + identifier + numbered
                + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            suffix += 1
        } while existing.contains(normalized(candidate))
        return RelativeDocumentPath(
            rawValue: trashPath.rawValue + "/" + candidate
        )
    }

    private func readTrashRecord(
        documentID: DocumentID,
        root: URL
    ) -> TrashRecord? {
        guard let data = try? Data(
            contentsOf: trashRecordURL(
                documentID: documentID,
                root: root
            )
        ) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TrashRecord.self, from: data)
    }

    private func writeTrashRecord(
        _ record: TrashRecord,
        root: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(
            to: trashRecordURL(documentID: record.documentID, root: root),
            options: [.atomic]
        )
    }

    private func trashRecordURL(
        documentID: DocumentID,
        root: URL
    ) -> URL {
        root.appendingPathComponent(
            ".writerpad-trash-"
                + documentID.rawValue.uuidString.lowercased()
                + ".json"
        )
    }

    private func validatedPath(
        _ value: String
    ) throws -> RelativeDocumentPath {
        guard SyncV2Client.isValidServerPath(value),
              value.lowercased().hasSuffix(".txt"),
              !value.hasPrefix("__antigravity__/")
        else {
            throw SyncV2LocalSnapshotApplyError.unsafePath
        }
        return RelativeDocumentPath(rawValue: value)
    }

    private func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func recoveryMarkerURL(
        documentID: UUID,
        root: URL
    ) -> URL {
        root.appendingPathComponent(
            Self.markerPrefix
                + documentID.uuidString.lowercased()
                + Self.markerSuffix
        )
    }

    private func trashPurgeStateURL(root: URL) -> URL {
        root.appendingPathComponent(Self.trashPurgeStateName)
    }

    private func trashPurgeStageURL(
        documentID: UUID,
        root: URL
    ) -> URL {
        root.appendingPathComponent(
            Self.trashPurgeStagePrefix
                + documentID.uuidString.lowercased()
        )
    }

    private func pathDepth(_ path: RelativeDocumentPath) -> Int {
        path.rawValue.split(separator: "/").count
    }
}
