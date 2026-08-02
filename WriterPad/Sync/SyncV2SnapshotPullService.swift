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
}

actor SyncV2SnapshotPullService: SyncV2SnapshotPulling {
    private struct ProcessedSnapshot: Sendable {
        let outcome: SyncV2SnapshotPullOutcome
        let appliedSnapshot: SyncV2RemoteDocumentSnapshot?
    }

    private let client: any SyncV2SnapshotClienting
    private let stateStore: any SyncV2SnapshotStateStoring
    private let localApplier: any SyncV2LocalSnapshotApplying
    private let mergeStore: any SyncV2SnapshotMergeStoring
    private let mutationGate: SyncV2DocumentMutationGate

    init(
        client: any SyncV2SnapshotClienting,
        stateStore: any SyncV2SnapshotStateStoring,
        localApplier: any SyncV2LocalSnapshotApplying,
        mergeStore: any SyncV2SnapshotMergeStoring,
        mutationGate: SyncV2DocumentMutationGate =
            SyncV2DocumentMutationGate()
    ) {
        self.client = client
        self.stateStore = stateStore
        self.localApplier = localApplier
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
        await localApplier.preparePull(
            localProjectID: localProjectID,
            remoteLiveDocumentPaths: Set(
                ordinarySnapshots
                    .filter { !$0.isDeleted }
                    .map(\.relativePath)
            )
        )
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
        outcomes.reserveCapacity(snapshots.count)

        var effectivePurgeState = await localApplier.trashPurgeState(
            localProjectID: localProjectID
        )
        for snapshot in orderedSnapshots {
            try Task.checkCancellation()
            let editing = editingGuards[snapshot.documentID] ?? .closed
            var eligibleDocumentIDs: Set<UUID> = []
            var lockedDocumentIDs = [snapshot.documentID]
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
                    effectivePurgeState: purgeStateForSnapshot,
                    eligibleDocumentIDs: eligibleIDsForSnapshot
                )
            }
            outcomes.append(processed.outcome)
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
            appliedSnapshots: appliedSnapshots
        )
    }

    private func process(
        _ snapshot: SyncV2RemoteDocumentSnapshot,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editing: SyncV2EditingGuard,
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
                   !isPurgedTombstone,
                   hiddenPath == nil {
                    requiresRecovery = await localApplier.requiresCopyRecovery(
                        localProjectID: localProjectID,
                        snapshot: snapshot
                    )
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
                        case .invalidHierarchy, .unsafePath:
                            .invalidLocalHierarchy
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
                            appliedSnapshot: nil
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
                        case .invalidHierarchy, .unsafePath:
                            .invalidLocalHierarchy
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
                            appliedSnapshot: nil
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
            switch error {
            case .pathOccupiedByDifferentDocument:
                reason = .pathOccupiedByDifferentDocument
            case .invalidHierarchy, .unsafePath:
                reason = .invalidLocalHierarchy
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
                appliedSnapshot: nil
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
        if snapshot.relativePath == syncV2TrashPurgePath {
            await mergeStore.resolve(
                localProjectID: localProjectID,
                documentID: snapshot.documentID
            )
        }
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

