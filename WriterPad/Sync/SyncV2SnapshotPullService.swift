import Foundation

protocol SyncV2SnapshotPulling: Sendable {
    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport
}

protocol SyncV2SnapshotStateStoring: Sendable {
    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2SnapshotLocalState?

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) async throws -> Bool

    /// 서버 폴더를 로컬 바인더에 적용한 것과 같은 pull 안에서 동기화 장부의
    /// revision 기준선도 함께 전진시킨다. 이 기준선이 뒤처지면 다음 이름변경이
    /// 이미 지난 revision으로 전송되어 REVISION_CONFLICT가 난다.
    func applyFolderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        folders: [SyncV2RemoteFolder],
        excluding blockedFolderIDs: Set<UUID>
    ) async throws

    /// 두 기기가 빈 서버 작품을 동시에 채울면 같은 초기 문서에
    /// 서로 다른 UUID가 생길 수 있다. 로컬 대기열이 정말 revision 0의
    /// 동일한 초기 snapshot인 경우에만 서버 UUID를 정식 기준으로
    /// 채택한다.
    func adoptEquivalentInitialDocument(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws -> Bool
}

extension SyncV2SnapshotStateStoring {
    func applyFolderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        folders: [SyncV2RemoteFolder],
        excluding blockedFolderIDs: Set<UUID>
    ) async throws {
        _ = (
            localProjectID,
            serverProjectID,
            folders,
            blockedFolderIDs
        )
    }

    func adoptEquivalentInitialDocument(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws -> Bool {
        _ = (localProjectID, serverProjectID, localDocumentID, snapshot)
        return false
    }
}

actor SyncV2SnapshotPullService: SyncV2SnapshotPulling {
    private struct ProcessedSnapshot: Sendable {
        let outcome: SyncV2SnapshotPullOutcome
        let appliedSnapshot: SyncV2RemoteDocumentSnapshot?
        /// 구조를 막은 이름. 화면 문구로 올라간다.
        var rejectedName: SyncV2RejectedStructureName? = nil
    }

    private let client: any SyncV2SnapshotClienting
    private let stateStore: any SyncV2SnapshotStateStoring
    private let localApplier: any SyncV2LocalSnapshotApplying
    private let folderApplier: (any SyncV2RemoteFolderApplying)?
    private let folderMigration: SyncV2FolderMigration?
    private let folderMarker: (any SyncV2FolderMigrationMarking)?
    private let folderDocuments: (any DocumentRepository)?
    private let mergeStore: any SyncV2SnapshotMergeStoring
    private let mutationGate: SyncV2DocumentMutationGate

    init(
        client: any SyncV2SnapshotClienting,
        stateStore: any SyncV2SnapshotStateStoring,
        localApplier: any SyncV2LocalSnapshotApplying,
        mergeStore: any SyncV2SnapshotMergeStoring,
        folderApplier: (any SyncV2RemoteFolderApplying)? = nil,
        folderMigration: SyncV2FolderMigration? = nil,
        folderMarker: (any SyncV2FolderMigrationMarking)? = nil,
        folderDocuments: (any DocumentRepository)? = nil,
        mutationGate: SyncV2DocumentMutationGate =
            SyncV2DocumentMutationGate()
    ) {
        self.client = client
        self.stateStore = stateStore
        self.localApplier = localApplier
        self.folderApplier = folderApplier
        self.folderMigration = folderMigration
        self.folderMarker = folderMarker
        self.folderDocuments = folderDocuments
        self.mergeStore = mergeStore
        self.mutationGate = mutationGate
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard] = [:]
    ) async throws -> SyncV2SnapshotPullReport {
        let snapshots = try await client.fetchDocuments(
            projectID: serverProjectID
        )
        // 실제 TXT 경로에서 폴더 메타데이터를 먼저 재구성한 뒤 순서를
        // 적용해야 새 Windows 폴더의 첫 pull에도 userOrder가 반영된다.
        let ordinarySnapshots = snapshots.filter {
            $0.relativePath != syncV2TreeOrderPath
                && $0.relativePath != syncV2TrashPurgePath
        }
        let remoteLiveDocumentPaths = Set(
            ordinarySnapshots
                .filter { !$0.isDeleted }
                .map(\.relativePath)
        )
        try await mutationGate.withCriticalSection(
            documentID: syncV2ProjectStructureMutationID(localProjectID)
        ) { [self] in
            await localApplier.preparePull(
                localProjectID: localProjectID,
                remoteLiveDocumentPaths: remoteLiveDocumentPaths
            )
        }
        // 폴더를 문서보다 먼저 제자리에 놓는다. 이름이 바뀐 폴더에 문서가 먼저
        // 도착하면 옛 경로에 자리를 잡아, 뒤이은 폴더 이동이 목적지 충돌로
        // 막힌다.
        var folderRejections: [SyncV2RejectedStructureName] = []
        if let folderApplier {
            let folders = try await client.fetchFolders(
                projectID: serverProjectID
            )
            // fetch는 Gate 밖에서 한다. 네트워크를 기다리는 동안
            // 사용자의 폴더 작업을 막지 않고, 디스크·메타데이터를
            // 실제로 읽고 바꾸는 구간만 직렬화한다.
            folderRejections = try await mutationGate.withCriticalSection(
                documentID: syncV2ProjectStructureMutationID(localProjectID)
            ) { [self] in
                let folderDocuments =
                    (try? await self.folderDocuments?.documents(
                        in: localProjectID
                    )) ?? nil ?? []
                let serverFolderIDsByPath =
                    SyncV2RemoteFolderPlanner.serverFolderIDsByPath(
                        remote: folders,
                        documents: folderDocuments
                    )
                await localApplier.prepareRemoteFolders(
                    localProjectID: localProjectID,
                    remoteLiveFolderPaths: Set(serverFolderIDsByPath.keys)
                )
                // 이관을 먼저 돌린다. 기존 폴더에 공유 UUID가 붙어 있어야
                // 서버가 보낸 폴더와 짝이 맞는다.
                if let folderMigration {
                    _ = await folderMigration.migrateIfNeeded(
                        localProjectID: localProjectID,
                        serverProjectID: serverProjectID,
                        serverFolderIDsByPath: serverFolderIDsByPath
                    )
                }
                let blockedServerFolderIDs = Set(
                    (try? await folderMarker?.foldersWithPendingOperations(
                        localProjectID: localProjectID
                    )) ?? []
                )
                let blockedFolderIDs = Set(
                    blockedServerFolderIDs.map(DocumentID.init(rawValue:))
                )
                let report = await folderApplier.applyRemoteFolders(
                    localProjectID: localProjectID,
                    remote: folders,
                    blockedFolderIDs: blockedFolderIDs
                )
                try await stateStore.applyFolderSnapshotBaselines(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    folders: folders,
                    excluding: blockedServerFolderIDs.union(
                        report.rejectedFolderIDs.map(\.rawValue)
                    )
                )
                return report.rejectedNames
            }
        }

        let orderedSnapshots = snapshots.filter {
            $0.relativePath == syncV2TrashPurgePath
        }
            + ordinarySnapshots.filter(\.isDeleted)
            + ordinarySnapshots.filter { !$0.isDeleted }
            + snapshots.filter {
            $0.relativePath == syncV2TreeOrderPath
        }
        var outcomes: [SyncV2SnapshotPullOutcome] = []
        var appliedSnapshots: [SyncV2RemoteDocumentSnapshot] = []
        var rejectedStructureNames = folderRejections
        outcomes.reserveCapacity(snapshots.count)

        var effectivePurgeState = await localApplier.trashPurgeState(
            localProjectID: localProjectID
        )
        for snapshot in orderedSnapshots {
            try Task.checkCancellation()
            let editing = editingGuards[snapshot.documentID] ?? .closed
            let equivalentLocalDocumentID =
                await localApplier.equivalentLocalDocumentID(
                    localProjectID: localProjectID,
                    snapshot: snapshot
                )
            let equivalentLocalEditing = equivalentLocalDocumentID.map {
                editingGuards[$0] ?? .closed
            } ?? .closed
            var eligibleDocumentIDs: Set<UUID> = []
            var lockedDocumentIDs = [snapshot.documentID]
            // 일반 TXT snapshot까지 작품 전체를 잠그면 처음 열 때
            // 모든 문서를 받는 동안 바인더가 느린 로딩에 머문다.
            // 폴더 전체를 바꾸는 숨은 구조 문서만 작품 키를 잠근다.
            if snapshot.relativePath == syncV2TreeOrderPath
                || snapshot.relativePath == syncV2TrashPurgePath {
                lockedDocumentIDs.append(
                    syncV2ProjectStructureMutationID(localProjectID)
                )
            }
            if let equivalentLocalDocumentID {
                lockedDocumentIDs.append(equivalentLocalDocumentID)
            }
            if snapshot.relativePath == syncV2TrashPurgePath,
               let remotePurge = try? SyncV2TrashPurgePayload(
                   strictContent: snapshot.content
               ) {
                let merged = effectivePurgeState.merging(remotePurge)
                eligibleDocumentIDs = Set(
                    snapshots.compactMap { candidate in
                        guard
                            candidate.isDeleted,
                            let purgedRevision = merged.purgedRevisions[
                                candidate.documentID
                            ],
                            candidate.revision <= purgedRevision
                        else { return nil }
                        return candidate.documentID
                    }
                )
                lockedDocumentIDs.append(contentsOf: eligibleDocumentIDs)
                if !remotePurge.emptyGeneration.isEmpty,
                   remotePurge.emptyGeneration
                       != effectivePurgeState.emptyGeneration {
                    lockedDocumentIDs.append(
                        contentsOf: await localApplier.trashDocumentIDs(
                            localProjectID: localProjectID
                        )
                    )
                }
            }
            let purgeStateForSnapshot = effectivePurgeState
            let eligibleIDsForSnapshot = eligibleDocumentIDs
            let processed = try await mutationGate.withCriticalSections(
                documentIDs: lockedDocumentIDs
            ) { [self] in
                try await process(
                    snapshot,
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editing: editing,
                    equivalentLocalDocumentID:
                        equivalentLocalDocumentID,
                    equivalentLocalEditing: equivalentLocalEditing,
                    effectivePurgeState: purgeStateForSnapshot,
                    eligibleDocumentIDs: eligibleIDsForSnapshot
                )
            }
            outcomes.append(processed.outcome)
            if let rejectedName = processed.rejectedName {
                rejectedStructureNames.append(rejectedName)
            }
            if let appliedSnapshot = processed.appliedSnapshot {
                appliedSnapshots.append(appliedSnapshot)
                if appliedSnapshot.relativePath == syncV2TrashPurgePath {
                    effectivePurgeState = await localApplier.trashPurgeState(
                        localProjectID: localProjectID
                    )
                }
            }
        }
        return SyncV2SnapshotPullReport(
            outcomes: outcomes,
            appliedSnapshots: appliedSnapshots,
            rejectedStructureNames: rejectedStructureNames
        )
    }

    private func process(
        _ snapshot: SyncV2RemoteDocumentSnapshot,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editing: SyncV2EditingGuard,
        equivalentLocalDocumentID: UUID?,
        equivalentLocalEditing: SyncV2EditingGuard,
        effectivePurgeState: SyncV2TrashPurgePayload,
        eligibleDocumentIDs: Set<UUID>
    ) async throws -> ProcessedSnapshot {
        try Task.checkCancellation()
        let hiddenPath: String? = switch snapshot.relativePath {
        case syncV2TreeOrderPath: syncV2TreeOrderPath
        case syncV2TrashPurgePath: syncV2TrashPurgePath
        default: nil
        }
        if let hiddenPath,
           snapshot.isDeleted
                || snapshot.documentID != syncV2UUIDv5(
                    namespace: serverProjectID,
                    name: hiddenPath
                ) {
            let reason = SyncV2SnapshotMergeReason.invalidLocalHierarchy
            try await preserve(
                snapshot,
                reason: reason,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
            return ProcessedSnapshot(
                outcome: .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: snapshot.revision,
                    reason: reason
                ),
                appliedSnapshot: nil
            )
        }
        if snapshot.relativePath == syncV2TrashPurgePath,
           (try? SyncV2TrashPurgePayload(
               strictContent: snapshot.content
           )) == nil {
            let reason = SyncV2SnapshotMergeReason.invalidLocalHierarchy
            try await preserve(
                snapshot,
                reason: reason,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
            return ProcessedSnapshot(
                outcome: .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: snapshot.revision,
                    reason: reason
                ),
                appliedSnapshot: nil
            )
        }
        if let equivalentLocalDocumentID,
           !editing.isOpen,
           !editing.isDirty,
           !editing.isComposing,
           !equivalentLocalEditing.isOpen,
           !equivalentLocalEditing.isDirty,
           !equivalentLocalEditing.isComposing,
           try await stateStore.adoptEquivalentInitialDocument(
               localProjectID: localProjectID,
               serverProjectID: serverProjectID,
               localDocumentID: equivalentLocalDocumentID,
               snapshot: snapshot
           ),
           await localApplier.replaceEquivalentLocalDocumentIdentity(
               localProjectID: localProjectID,
               localDocumentID: equivalentLocalDocumentID,
               snapshot: snapshot
           ) {
            await mergeStore.resolve(
                localProjectID: localProjectID,
                documentID: snapshot.documentID
            )
        }
        let state = try await stateStore.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: snapshot.documentID
        )
        if let state, snapshot.revision <= state.serverRevision {
            let outcome: SyncV2SnapshotPullOutcome
            if state.hasUnresolvedConflict {
                outcome = .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision,
                    reason: .unresolvedConflict
                )
            } else if state.blockingErrorCode != nil {
                outcome = .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision,
                    reason: .blockedOperation
                )
            } else if state.hasPathCollision {
                // `conflict` 상태 operation은 아래 hasActiveOperation에도 걸려
                // 진행 중으로 보고된다. 경로 충돌은 저절로 풀리지 않으므로 더
                // 먼저 판정해 사용자에게 해결이 필요한 상태로 알린다.
                outcome = .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision,
                    reason: .pathOccupiedByDifferentDocument
                )
            } else if state.hasActiveOperation {
                outcome = .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision,
                    reason: .pendingOperation
                )
            } else {
                let isPurgedTombstone = snapshot.isDeleted
                    && effectivePurgeState.purgedRevisions[
                        snapshot.documentID
                    ].map { $0 >= snapshot.revision } == true
                var requiresRecovery = false
                if snapshot.revision == state.serverRevision,
                   snapshot.relativePath == state.serverPath,
                   !isPurgedTombstone {
                    if snapshot.relativePath == syncV2TreeOrderPath {
                        // Windows는 folders 행을 갱신하지 못하고 tree_order만
                        // 바꾼다. pull 앞부분에서 아직 옛 이름인 folders 행을
                        // 적용하면, 이미 받아 둔 같은 revision의 tree_order를
                        // 다시 실행해 새 이름으로 복구하고 folder commit을
                        // 올려야 한다. 숨은 문서라고 무조건 up-to-date로 넘기면
                        // Windows에서 바꾼 빈 폴더 이름이 옛 이름으로 회귀한다.
                        requiresRecovery = true
                    } else if hiddenPath == nil {
                        requiresRecovery = await localApplier.requiresCopyRecovery(
                            localProjectID: localProjectID,
                            snapshot: snapshot
                        )
                    }
                }
                if requiresRecovery {
                    if let reason = Self.mergeReason(
                        snapshot: snapshot,
                        state: state,
                        editing: editing
                    ) {
                        try await preserve(
                            snapshot,
                            reason: reason,
                            localProjectID: localProjectID,
                            serverProjectID: serverProjectID
                        )
                        return ProcessedSnapshot(
                            outcome: .mergeRequired(
                                documentID: snapshot.documentID,
                                revision: state.serverRevision,
                                reason: reason
                            ),
                            appliedSnapshot: nil
                        )
                    }
                    do {
                        try await localApplier.apply(
                            localProjectID: localProjectID,
                            snapshot: snapshot
                        )
                    } catch let error as SyncV2LocalSnapshotApplyError {
                        let reason: SyncV2SnapshotMergeReason = switch error {
                        case .pathOccupiedByDifferentDocument:
                            .pathOccupiedByDifferentDocument
                        case .invalidHierarchy, .unsafePath,
                             .unsafeName:
                            .invalidLocalHierarchy
                        }
                        var rejectedName: SyncV2RejectedStructureName?
                        if case let .unsafeName(value) = error {
                            rejectedName = value
                        }
                        try await preserve(
                            snapshot,
                            reason: reason,
                            localProjectID: localProjectID,
                            serverProjectID: serverProjectID
                        )
                        return ProcessedSnapshot(
                            outcome: .mergeRequired(
                                documentID: snapshot.documentID,
                                revision: state.serverRevision,
                                reason: reason
                            ),
                            appliedSnapshot: nil,
                            rejectedName: rejectedName
                        )
                    }
                    await localApplier.finish(
                        localProjectID: localProjectID,
                        documentID: snapshot.documentID
                    )
                    await mergeStore.resolve(
                        localProjectID: localProjectID,
                        documentID: snapshot.documentID
                    )
                    return ProcessedSnapshot(
                        outcome: .applied(
                            documentID: snapshot.documentID,
                            revision: state.serverRevision,
                            wasOpen: editing.isOpen
                        ),
                        appliedSnapshot: snapshot
                    )
                }
                if snapshot.relativePath == syncV2TrashPurgePath {
                    do {
                        try await localApplier.applyTrashPurge(
                            localProjectID: localProjectID,
                            snapshot: snapshot,
                            eligibleDocumentIDs: eligibleDocumentIDs
                        )
                        await localApplier.finish(
                            localProjectID: localProjectID,
                            documentID: snapshot.documentID
                        )
                    } catch let error as SyncV2LocalSnapshotApplyError {
                        let reason: SyncV2SnapshotMergeReason = switch error {
                        case .pathOccupiedByDifferentDocument:
                            .pathOccupiedByDifferentDocument
                        case .invalidHierarchy, .unsafePath,
                             .unsafeName:
                            .invalidLocalHierarchy
                        }
                        var rejectedName: SyncV2RejectedStructureName?
                        if case let .unsafeName(value) = error {
                            rejectedName = value
                        }
                        try await preserve(
                            snapshot,
                            reason: reason,
                            localProjectID: localProjectID,
                            serverProjectID: serverProjectID
                        )
                        return ProcessedSnapshot(
                            outcome: .mergeRequired(
                                documentID: snapshot.documentID,
                                revision: state.serverRevision,
                                reason: reason
                            ),
                            appliedSnapshot: nil,
                            rejectedName: rejectedName
                        )
                    }
                }
                outcome = .upToDate(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision
                )
                if snapshot.relativePath == syncV2TrashPurgePath,
                   (try? SyncV2TrashPurgePayload(
                       strictContent: snapshot.content
                   )) != nil {
                    await mergeStore.resolve(
                        localProjectID: localProjectID,
                        documentID: snapshot.documentID
                    )
                }
            }
            return ProcessedSnapshot(
                outcome: outcome,
                appliedSnapshot: nil
            )
        }

        if let reason = Self.mergeReason(
            snapshot: snapshot,
            state: state,
            editing: editing
        ) {
            try await preserve(
                snapshot,
                reason: reason,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
            return ProcessedSnapshot(
                outcome: .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: snapshot.revision,
                    reason: reason
                ),
                appliedSnapshot: nil
            )
        }

        do {
            try Task.checkCancellation()
            if snapshot.isDeleted,
               effectivePurgeState.purgedRevisions[
                   snapshot.documentID
               ].map({ $0 >= snapshot.revision }) == true {
                // purge가 먼저 닫은 tombstone은 baseline만 전진시키고
                // 휴지통 사본을 다시 만들지 않는다.
            } else if snapshot.relativePath == syncV2TrashPurgePath {
                try await localApplier.applyTrashPurge(
                    localProjectID: localProjectID,
                    snapshot: snapshot,
                    eligibleDocumentIDs: eligibleDocumentIDs
                )
            } else {
                try await localApplier.apply(
                    localProjectID: localProjectID,
                    snapshot: snapshot
                )
            }
        } catch let error as SyncV2LocalSnapshotApplyError {
            let reason: SyncV2SnapshotMergeReason
            var rejectedName: SyncV2RejectedStructureName?
            switch error {
            case .pathOccupiedByDifferentDocument:
                reason = .pathOccupiedByDifferentDocument
            case .invalidHierarchy, .unsafePath:
                reason = .invalidLocalHierarchy
            case let .unsafeName(value):
                reason = .invalidLocalHierarchy
                rejectedName = value
            }
            try await preserve(
                snapshot,
                reason: reason,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
            return ProcessedSnapshot(
                outcome: .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: snapshot.revision,
                    reason: reason
                ),
                appliedSnapshot: nil,
                rejectedName: rejectedName
            )
        }

        let committed = try await stateStore.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: snapshot,
            expectedRevision: state?.serverRevision
        )
        guard committed else {
            await localApplier.rollback(
                localProjectID: localProjectID,
                documentID: snapshot.documentID
            )
            try await preserve(
                snapshot,
                reason: .pendingOperation,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
            return ProcessedSnapshot(
                outcome: .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: snapshot.revision,
                    reason: .pendingOperation
                ),
                appliedSnapshot: nil
            )
        }
        await localApplier.finish(
            localProjectID: localProjectID,
            documentID: snapshot.documentID
        )
        // 이전 pull이 경로 충돌 marker를 남겼더라도 이번 snapshot을
        // 실제 파일과 baseline에 모두 적용했으면 해결된 것이다.
        await mergeStore.resolve(
            localProjectID: localProjectID,
            documentID: snapshot.documentID
        )
        return ProcessedSnapshot(
            outcome: .applied(
                documentID: snapshot.documentID,
                revision: snapshot.revision,
                wasOpen: editing.isOpen
            ),
            appliedSnapshot: snapshot
        )
    }

    private static func mergeReason(
        snapshot: SyncV2RemoteDocumentSnapshot,
        state: SyncV2SnapshotLocalState?,
        editing: SyncV2EditingGuard
    ) -> SyncV2SnapshotMergeReason? {
        if state?.hasUnresolvedConflict == true {
            return .unresolvedConflict
        }
        if state?.blockingErrorCode != nil {
            return .blockedOperation
        }
        if state?.hasActiveOperation == true {
            return .pendingOperation
        }
        if editing.isComposing {
            return .markedTextComposition
        }
        if editing.isDirty {
            return .dirtyEditor
        }
        if snapshot.isDeleted && editing.isOpen {
            return .remoteDeletion
        }
        return nil
    }

    private func preserve(
        _ snapshot: SyncV2RemoteDocumentSnapshot,
        reason: SyncV2SnapshotMergeReason,
        localProjectID: ProjectID,
        serverProjectID: UUID
    ) async throws {
        try await mergeStore.preserve(
            SyncV2SnapshotMergeCandidate(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                snapshot: snapshot,
                reason: reason
            )
        )
    }
}
