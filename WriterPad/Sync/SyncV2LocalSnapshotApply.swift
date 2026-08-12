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
    func prepareRemoteFolders(
        localProjectID: ProjectID,
        remoteLiveFolderPaths: Set<String>
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

    /// 서버 snapshot과 경로·본문이 바이트 단위로 같고, 열린 편집기나
    /// 백업이 없는 로컬 문서의 UUID를 반환한다.
    func equivalentLocalDocumentID(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> UUID?

    func replaceEquivalentLocalDocumentIdentity(
        localProjectID: ProjectID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool
}

extension SyncV2LocalSnapshotApplying {
    func preparePull(
        localProjectID: ProjectID,
        remoteLiveDocumentPaths: Set<String>
    ) async {}

    func prepareRemoteFolders(
        localProjectID: ProjectID,
        remoteLiveFolderPaths: Set<String>
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

    func equivalentLocalDocumentID(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> UUID? {
        _ = (localProjectID, snapshot)
        return nil
    }

    func replaceEquivalentLocalDocumentIdentity(
        localProjectID: ProjectID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool {
        _ = (localProjectID, localDocumentID, snapshot)
        return false
    }
}

enum SyncV2LocalSnapshotApplyError: Error, Equatable, Sendable {
    case pathOccupiedByDifferentDocument
    case invalidHierarchy
    case unsafePath
    /// 어떤 이름이 왜 막혔는지까지 담는다. 화면에 그대로 보여 사용자가 보내는
    /// 쪽에서 고칠 수 있게 한다.
    case unsafeName(SyncV2RejectedStructureName)
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
        /// tree-order가 서버 TXT를 보기 전에 같은 경로를 빈 폴더로
        /// 잘못 물질화한 경우의 원본이다. 서버 baseline 저장이 실패하면
        /// 이 기록으로 빈 디렉터리와 메타데이터를 다시 만든다.
        let replacedTreeOrderPlaceholderFolder: DocumentNode?

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
            tombstoneRepairHadTrashRecord: Bool? = nil,
            replacedTreeOrderPlaceholderFolder: DocumentNode? = nil
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
            self.replacedTreeOrderPlaceholderFolder =
                replacedTreeOrderPlaceholderFolder
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
    private let backupStore: (any BackupStoring)?
    /// tree_order로 받은 폴더 이름 변경을 폴더 기록에도 올린다.
    private let folderIdentityPublisher: (any SyncV2FolderIdentityPublishing)?
    private var remoteLiveDocumentPaths: [ProjectID: Set<String>] = [:]
    private var remoteLiveFolderPaths: [ProjectID: Set<String>] = [:]

    init(
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default,
        hasher: any ContentHashing = SHA256ContentHasher(),
        backupStore: (any BackupStoring)? = nil,
        folderIdentityPublisher: (any SyncV2FolderIdentityPublishing)? = nil
    ) {
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
        self.hasher = hasher
        self.backupStore = backupStore
        self.folderIdentityPublisher = folderIdentityPublisher
    }

    func equivalentLocalDocumentID(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> UUID? {
        guard !snapshot.isDeleted,
              snapshot.relativePath != syncV2TreeOrderPath,
              snapshot.relativePath != syncV2TrashPurgePath,
              let backupStore,
              documentRepository is any DocumentIdentityReplacing
        else { return nil }

        guard let documents = try? await documentRepository.documents(
            in: localProjectID
        ) else { return nil }
        let targetID = DocumentID(rawValue: snapshot.documentID)
        guard !documents.contains(where: { $0.id == targetID }) else {
            return nil
        }
        let candidates = documents.filter {
            $0.id != targetID
                && $0.kind == .text
                && isActive($0)
                && normalized($0.relativePath.rawValue)
                    == normalized(snapshot.relativePath)
        }
        guard candidates.count == 1, let local = candidates.first else {
            return nil
        }
        guard let backups = try? await backupStore.snapshots(
            for: local.id,
            projectID: localProjectID
        ), backups.isEmpty else {
            return nil
        }
        guard let root = try? await workspaceLocator.workspaceRoot(
            for: localProjectID
        ), let data = try? Data(
            contentsOf: root.appendingPathComponent(
                local.relativePath.rawValue
            )
        ), data == Data(snapshot.content.utf8) else {
            return nil
        }
        return local.id.rawValue
    }

    func replaceEquivalentLocalDocumentIdentity(
        localProjectID: ProjectID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool {
        guard await equivalentLocalDocumentID(
            localProjectID: localProjectID,
            snapshot: snapshot
        ) == localDocumentID,
        let identityRepository =
            documentRepository as? any DocumentIdentityReplacing
        else { return false }
        do {
            try await identityRepository.replaceDocumentIdentity(
                from: DocumentID(rawValue: localDocumentID),
                to: DocumentID(rawValue: snapshot.documentID),
                in: localProjectID
            )
            return true
        } catch {
            return false
        }
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
        // 이번 pull의 폴더 목록은 아직 받지 않았다. 이전 pull 값을
        // 재사용하면 이번에는 서버에 없는 폴더를 잘못 보호할 수 있다.
        remoteLiveFolderPaths[localProjectID] = []
    }

    func prepareRemoteFolders(
        localProjectID: ProjectID,
        remoteLiveFolderPaths: Set<String>
    ) async {
        self.remoteLiveFolderPaths[localProjectID] = Set(
            remoteLiveFolderPaths.map(normalized)
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
        let occupyingDocument = documents.first(where: {
            $0.id != documentID
                && normalized($0.relativePath.rawValue)
                    == normalized(path.rawValue)
        })

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
        let placeholderFolder: DocumentNode?
        if recoveringSameSnapshot,
           let recorded = existingMarker?
               .replacedTreeOrderPlaceholderFolder {
            placeholderFolder = recorded
        } else if let occupyingDocument,
                  isReplaceableTreeOrderPlaceholder(
                      occupyingDocument,
                      path: path,
                      localProjectID: localProjectID,
                      documents: documents,
                      root: root
                  ) {
            placeholderFolder = occupyingDocument
        } else {
            placeholderFolder = nil
        }
        if occupyingDocument != nil, placeholderFolder == nil {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }
        if current?.relativePath != path,
           fileManager.fileExists(atPath: destination.path),
           !recoveringSameSnapshot,
           placeholderFolder == nil {
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
                treeOrderPreviousDocuments: nil,
                replacedTreeOrderPlaceholderFolder: placeholderFolder
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(
                to: markerURL,
                options: [.atomic]
            )
        }
        if let placeholderFolder {
            try await removeTreeOrderPlaceholder(
                placeholderFolder,
                path: path,
                documents: documents,
                root: root,
                recoveringSameSnapshot: recoveringSameSnapshot
            )
            documents.removeAll { $0.id == placeholderFolder.id }
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

    /// tree-order의 자식 이름은 종류 정보가 없다. 서버 문서 목록보다
    /// tree-order가 먼저 도착하면 `001화.txt`도 폴더로 물질화될 수 있다.
    /// 경로에서 파생한 UUID의 빈 로컬 폴더이고, 서버가 실제 폴더로
    /// 알고 있지 않을 때만 서버 TXT에 자리를 내준다.
    private func isReplaceableTreeOrderPlaceholder(
        _ candidate: DocumentNode,
        path: RelativeDocumentPath,
        localProjectID: ProjectID,
        documents: [DocumentNode],
        root: URL
    ) -> Bool {
        guard candidate.kind == .folder,
              isActive(candidate),
              candidate.id == syncedFolderIdentifier(
                  localProjectID: localProjectID,
                  path: path.rawValue
              ),
              remoteLiveDocumentPaths[localProjectID]?.contains(
                  normalized(path.rawValue)
              ) == true,
              remoteLiveFolderPaths[localProjectID]?.contains(
                  normalized(path.rawValue)
              ) != true,
              !documents.contains(where: {
                  $0.parentID == candidate.id || (
                      $0.id != candidate.id
                          && normalized($0.relativePath.rawValue).hasPrefix(
                              normalized(path.rawValue) + "/"
                          )
                  )
              })
        else { return false }

        let url = root.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
        (try? url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) != true,
        (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty
            == true
        else { return false }
        return true
    }

    private func removeTreeOrderPlaceholder(
        _ placeholder: DocumentNode,
        path: RelativeDocumentPath,
        documents: [DocumentNode],
        root: URL,
        recoveringSameSnapshot: Bool
    ) async throws {
        let url = root.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) {
            guard isDirectory.boolValue,
                  (try? url.resourceValues(
                      forKeys: [.isSymbolicLinkKey]
                  ).isSymbolicLink) != true,
                  (try? fileManager.contentsOfDirectory(
                      atPath: url.path
                  ))?.isEmpty == true
            else {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            try fileManager.removeItem(at: url)
        } else if !recoveringSameSnapshot {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        if let stored = try await documentRepository.document(
            id: placeholder.id
        ) {
            guard stored == placeholder,
                  !documents.contains(where: { $0.parentID == stored.id })
            else {
                throw SyncV2LocalSnapshotApplyError
                    .pathOccupiedByDifferentDocument
            }
            try await documentRepository.removeMetadata(id: placeholder.id)
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
        // 폴더를 만들기 전에 이름 변경부터 반영한다. 새 이름을 먼저 만들면
        // 옛 폴더가 그대로 남아 폴더가 둘로 늘어난다.
        documents = try await renameSyncedEmptyFolders(
            payload: payload,
            localProjectID: localProjectID,
            documents: documents,
            root: root
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

    /// 빈 폴더는 서버에 문서로 존재하지 않고 tree-order의 child name으로만
    /// 전달된다. 그래서 Windows의 이름 변경이 "옛 이름 사라짐 + 새 이름 생김"
    /// 으로 도착하고, 새 이름만 만들면 폴더가 둘로 늘어난다.
    ///
    /// 한 부모 안에서 사라진 폴더와 새로 생긴 이름이 각각 하나뿐일 때만 짝으로
    /// 보고 옮긴다. 여러 개가 동시에 바뀌면 어느 것이 어느 것인지 알 수 없으므로
    /// 기존 동작(새 이름만 만들고 옛 폴더는 유지)을 그대로 둔다.
    ///
    /// 지우지 않고 옮기므로, 추적하지 않는 파일이 디스크에 남아 있었더라도 함께
    /// 따라간다. 대상은 동기화가 만든 빈 폴더로 한정한다. 사용자가 직접 만든
    /// 폴더는 경로 파생 UUID가 아니라서 걸러지고, 문서가 들어 있는 폴더는 그
    /// 문서들의 경로가 서버를 따르므로 건드리면 안 된다.
    private func renameSyncedEmptyFolders(
        payload: TreeOrderPayload,
        localProjectID: ProjectID,
        documents initialDocuments: [DocumentNode],
        root: URL
    ) async throws -> [DocumentNode] {
        var documents = initialDocuments
        let remotePaths = remoteLiveDocumentPaths[localProjectID] ?? []

        for key in payload.treeOrder.keys.sorted() {
            guard let names = payload.treeOrder[key] else { continue }
            let parentValue = key == "<root>" ? "메인" : key
            let parentPath = RelativeDocumentPath(rawValue: parentValue)
            guard !isInTrash(parentPath) else { continue }
            guard let parent = documents.first(where: {
                $0.kind == .folder
                    && isActive($0)
                    && normalized($0.relativePath.rawValue)
                        == normalized(parentValue)
            }) else { continue }

            let remoteKeys = Set(names.map { pathPolicy.collisionKey(for: $0) })
            let children = documents.filter {
                $0.parentID == parent.id && isActive($0)
            }
            // 식별자가 어떻게 만들어졌는지는 따지지 않는다. 이관을 마친 폴더는
            // 서버와 공유하는 UUID를 갖게 되어 경로에서 계산한 값과 더는 같지
            // 않다. 그 조건을 남겨 두면 이관한 작품에서 이름 변경 처리가 통째로
            // 꺼져, Windows가 바꾼 이름이 새 폴더로 따로 생긴다.
            let vanished = children.filter { child in
                child.kind == .folder
                    && !remoteKeys.contains(
                        pathPolicy.collisionKey(for: storedName(of: child))
                    )
                    && !documents.contains { candidate in
                        isActive(candidate)
                            && candidate.id != child.id
                            && normalized(candidate.relativePath.rawValue)
                                .hasPrefix(
                                    normalized(child.relativePath.rawValue) + "/"
                                )
                    }
            }
            let childKeys = Set(
                children.map { pathPolicy.collisionKey(for: storedName(of: $0)) }
            )
            let added = names.filter { name in
                !childKeys.contains(pathPolicy.collisionKey(for: name))
                    && !remotePaths.contains(
                        normalized(parentValue + "/" + name)
                    )
            }

            // 문서가 든 폴더를 Windows에서 이름 변경하면 문서 snapshot이 먼저
            // 새 경로에 도착해, tree-order를 적용할 때는 새 이름의 폴더가 이미
            // 만들어져 있다. 그 폴더가 이번 pull이 경로에서 만든 임시 식별자이고
            // 서버 folders projection에는 아직 없는 경로임이 모두 확인될 때만
            // 옛 폴더 식별자를 새 경로에 승계한다.
            let remoteFolderPaths = remoteLiveFolderPaths[localProjectID] ?? []
            let materializedDestinations = children.filter { child in
                guard child.kind == .folder else { return false }
                let path = normalized(child.relativePath.rawValue)
                return remoteKeys.contains(
                    pathPolicy.collisionKey(for: storedName(of: child))
                )
                    && !remoteFolderPaths.contains(path)
                    && child.id == syncedFolderIdentifier(
                        localProjectID: localProjectID,
                        path: child.relativePath.rawValue
                    )
                    && remotePaths.contains(where: {
                        $0.hasPrefix(path + "/")
                    })
            }
            if vanished.count == 1,
               materializedDestinations.count == 1,
               let source = vanished.first,
               let destination = materializedDestinations.first,
               remoteFolderPaths.contains(
                   normalized(source.relativePath.rawValue)
               ),
               let promoted = try await promoteMaterializedFolderRename(
                   source: source,
                   destination: destination,
                   documents: documents,
                   root: root
               ) {
                documents = promoted
                await folderIdentityPublisher?.publishFolder(
                    localProjectID: localProjectID,
                    folderID: source.id,
                    parentFolderID: source.parentID,
                    name: storedName(of: destination)
                )
                continue
            }

            guard vanished.count == 1, added.count == 1,
                  let source = vanished.first,
                  let newName = added.first
            else { continue }

            let destinationValue = parentValue + "/" + newName
            let destinationPath = RelativeDocumentPath(
                rawValue: destinationValue
            )
            // iPad 경로 정책이 거부하는 이름이면 옮기지 않고 넘어간다. 여기서
            // PathPolicyError를 그대로 던지면 pull이 잡는 오류 종류가 아니어서
            // 그 폴더 하나가 아니라 동기화 전체가 멈춘다. 이름 검증은 뒤이은
            // planTreeOrderFolders가 unsafePath로 보고하고, pull은 그 문서만
            // 보류로 돌린다.
            do {
                try pathPolicy.validateName(newName)
                try pathPolicy.validateRelativePath(destinationPath)
            } catch {
                continue
            }
            let sourceURL = root.appendingPathComponent(
                source.relativePath.rawValue
            ).standardizedFileURL
            let destinationURL = root.appendingPathComponent(
                destinationValue
            ).standardizedFileURL
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } else {
                try fileManager.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: false
                )
            }
            // 식별자를 그대로 들고 옮긴다. 새로 계산하면 같은 폴더가 다른
            // 폴더가 되어, 서버 폴더 기록과 짝이 끊기고 받는 기기에 둘로 보인다.
            let moved = DocumentNode(
                id: source.id,
                projectID: source.projectID,
                kind: .folder,
                parentID: source.parentID,
                relativePath: destinationPath,
                userOrder: source.userOrder,
                modifiedAt: source.modifiedAt,
                contentHash: nil
            )
            try await documentRepository.save(moved)
            documents.removeAll { $0.id == source.id }
            documents.append(moved)
            // tree_order로만 온 변경이라 서버 폴더 행은 아직 옛 이름이다.
            // 올려 두지 않으면 그 낡은 행이 다음 pull에서 이 이름을 되돌린다.
            await folderIdentityPublisher?.publishFolder(
                localProjectID: localProjectID,
                folderID: moved.id,
                parentFolderID: moved.parentID,
                name: newName
            )
        }
        return documents
    }

    /// 문서 snapshot이 새 경로를 먼저 물질화한 경우의 폴더 ID 승계다.
    ///
    /// 디스크의 새 폴더와 그 안의 문서는 그대로 두고, 이번 pull이 만든 임시
    /// 폴더 메타데이터만 원래 공유 folder_id로 바꾼다. 옛 디렉터리는 숨김
    /// 파일까지 완전히 비었을 때만 제거한다. 어느 저장 단계든 실패하면 원래
    /// 메타데이터와 빈 디렉터리를 복원하므로 원고 파일은 이동하거나 지우지 않는다.
    private func promoteMaterializedFolderRename(
        source: DocumentNode,
        destination: DocumentNode,
        documents: [DocumentNode],
        root: URL
    ) async throws -> [DocumentNode]? {
        guard source.kind == .folder,
              destination.kind == .folder,
              source.parentID == destination.parentID,
              source.id != destination.id
        else { return nil }

        let sourceURL = root.appendingPathComponent(
            source.relativePath.rawValue
        ).standardizedFileURL
        let destinationURL = root.appendingPathComponent(
            destination.relativePath.rawValue
        ).standardizedFileURL
        var sourceIsDirectory: ObjCBool = false
        let sourceExists = fileManager.fileExists(
            atPath: sourceURL.path,
            isDirectory: &sourceIsDirectory
        )
        if sourceExists {
            guard sourceIsDirectory.boolValue,
                  (try? sourceURL.resourceValues(
                      forKeys: [.isSymbolicLinkKey]
                  ).isSymbolicLink) != true,
                  (try? fileManager.contentsOfDirectory(
                      atPath: sourceURL.path
                  ))?.isEmpty == true
            else { return nil }
        }
        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: destinationURL.path,
            isDirectory: &destinationIsDirectory
        ), destinationIsDirectory.boolValue,
        (try? destinationURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink) != true
        else { return nil }

        let directChildren = documents.filter {
            $0.parentID == destination.id && isActive($0)
        }
        let reparentedChildren = directChildren.map {
            $0.relocated(
                to: $0.relativePath,
                parentID: source.id,
                userOrder: $0.userOrder,
                at: $0.modifiedAt
            )
        }
        let movedSource = source.relocated(
            to: destination.relativePath,
            parentID: source.parentID,
            userOrder: source.userOrder,
            at: source.modifiedAt
        )

        do {
            for child in reparentedChildren {
                try await documentRepository.save(child)
            }
            try await documentRepository.removeMetadata(id: destination.id)
            try await documentRepository.save(movedSource)
            if sourceExists {
                try fileManager.removeItem(at: sourceURL)
            }
        } catch {
            // 파일 본문은 처음부터 새 디렉터리에 그대로 있다. 메타데이터만
            // 원상 복구하고, 지운 옛 빈 디렉터리가 있다면 다시 만든다.
            try? await documentRepository.save(source)
            try? await documentRepository.save(destination)
            for child in directChildren {
                try? await documentRepository.save(child)
            }
            if sourceExists,
               !fileManager.fileExists(atPath: sourceURL.path) {
                try? fileManager.createDirectory(
                    at: sourceURL,
                    withIntermediateDirectories: false
                )
            }
            throw error
        }

        let directChildIDs = Set(directChildren.map(\.id))
        var updated = documents.filter {
            $0.id != source.id
                && $0.id != destination.id
                && !directChildIDs.contains($0.id)
        }
        updated.append(movedSource)
        updated.append(contentsOf: reparentedChildren)
        return updated
    }

    /// 거부한 이름을 로그와 오류에 함께 싣는다. 로그는 개발자용이고, 오류에
    /// 담긴 값은 화면 문구가 된다. 폴더 이름은 원고 본문이 아니라 구조 정보다.
    private func rejectedName(
        _ name: String,
        parent: String,
        reason: String
    ) -> SyncV2LocalSnapshotApplyError {
        SyncV2Diagnostics.rejectedStructureName(
            name,
            parent: parent,
            reason: reason
        )
        return .unsafeName(
            SyncV2RejectedStructureName(
                name: name,
                parent: parent,
                reason: reason
            )
        )
    }

    /// 동기화가 tree-order에서 만든 폴더의 UUID는 경로에서 결정적으로 파생한다.
    /// 사용자가 직접 만든 폴더와 구별하는 기준이 된다.
    private func syncedFolderIdentifier(
        localProjectID: ProjectID,
        path: String
    ) -> DocumentID {
        DocumentID(
            rawValue: syncV2UUIDv5(
                namespace: localProjectID.rawValue,
                name: "writerpad-local-folder/" + normalized(path)
            )
        )
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
                    throw rejectedName(
                        name,
                        parent: parentValue,
                        reason: (error as? PathPolicyError)?.errorDescription
                            ?? "이 이름은 iPad에서 사용할 수 없습니다."
                    )
                }
                guard childKeys.insert(
                    pathPolicy.collisionKey(for: name)
                ).inserted else {
                    throw rejectedName(
                        name,
                        parent: parentValue,
                        reason: "정규화하면 같은 이름이 둘 이상입니다."
                    )
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
            if let placeholder = marker
                .replacedTreeOrderPlaceholderFolder {
                if let current = try await documentRepository.document(
                    id: DocumentID(rawValue: documentID)
                ), current.relativePath == appliedPath {
                    try await documentRepository.removeMetadata(id: current.id)
                }
                try fileManager.removeItem(at: appliedURL)
                try fileManager.createDirectory(
                    at: appliedURL,
                    withIntermediateDirectories: false
                )
                try await documentRepository.save(placeholder)
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
                return
            }
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
