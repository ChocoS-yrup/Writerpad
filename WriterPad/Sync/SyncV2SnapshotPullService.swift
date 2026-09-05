import Foundation

enum SyncV2SnapshotPullError: Error, Equatable {
    case alreadyRunning
}

protocol SyncV2SnapshotPulling: Sendable {
    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport
}

protocol SyncV2SnapshotStateStoring: Sendable {
    /// 변경 없는 pull의 SQLite 반복 조회를 줄이기 위한 선택적
    /// fast path다. `nil`은 batch 미지원을 뜻하고, 빈 Dictionary는
    /// 요청한 ID들의 로컬 기준선이 모두 없음을 뜻한다.
    func snapshotStates(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentIDs: Set<UUID>
    ) async throws -> [UUID: SyncV2SnapshotLocalState]?

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

    /// 계약 tree_order를 서버가 말한 그대로 적어 둔다. 순서는 자식 목록 전체를
    /// 보내는 구조라, 서버가 무엇을 담고 있는지와 그 revision을 모르면 안전하게
    /// 쓸 수 없다.
    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
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
    func snapshotStates(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentIDs: Set<UUID>
    ) async throws -> [UUID: SyncV2SnapshotLocalState]? {
        _ = (localProjectID, serverProjectID, documentIDs)
        return nil
    }

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
    private enum PrefetchedSnapshotState: Sendable {
        case unavailable
        case loaded(SyncV2SnapshotLocalState?)
    }

    private final class ProcessMeasurement: @unchecked Sendable {
        private let lock = NSLock()
        private var storedStateLookupNanoseconds: UInt64 = 0

        func recordStateLookup(nanoseconds: UInt64) {
            lock.withLock {
                storedStateLookupNanoseconds = nanoseconds
            }
        }

        func stateLookupNanoseconds() -> UInt64 {
            lock.withLock { storedStateLookupNanoseconds }
        }
    }

    private struct ProcessedSnapshot: Sendable {
        let outcome: SyncV2SnapshotPullOutcome
        let appliedSnapshot: SyncV2RemoteDocumentSnapshot?
        /// 구조를 막은 이름. 화면 문구로 올라간다.
        var rejectedName: SyncV2RejectedStructureName? = nil
    }

    private struct TimedProcessedSnapshot: Sendable {
        let processed: ProcessedSnapshot
        let gateWaitNanoseconds: UInt64
        let processNanoseconds: UInt64
        let stateLookupNanoseconds: UInt64
    }

    private let client: any SyncV2SnapshotClienting
    private let stateStore: any SyncV2SnapshotStateStoring
    private let localApplier: any SyncV2LocalSnapshotApplying
    private let folderApplier: (any SyncV2RemoteFolderApplying)?
    private let folderMigration: SyncV2FolderMigration?
    private let folderMarker: (any SyncV2FolderMigrationMarking)?
    private let folderDocuments: (any DocumentRepository)?
    private let mergeStore: any SyncV2SnapshotMergeStoring
    private let leaseManager: (any EditLeaseManaging)?
    private let mutationGate: SyncV2DocumentMutationGate
    private var activeProjects: Set<ProjectID> = []

    init(
        client: any SyncV2SnapshotClienting,
        stateStore: any SyncV2SnapshotStateStoring,
        localApplier: any SyncV2LocalSnapshotApplying,
        mergeStore: any SyncV2SnapshotMergeStoring,
        folderApplier: (any SyncV2RemoteFolderApplying)? = nil,
        folderMigration: SyncV2FolderMigration? = nil,
        folderMarker: (any SyncV2FolderMigrationMarking)? = nil,
        folderDocuments: (any DocumentRepository)? = nil,
        leaseManager: (any EditLeaseManaging)? = nil,
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
        self.leaseManager = leaseManager
        self.mutationGate = mutationGate
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard] = [:]
    ) async throws -> SyncV2SnapshotPullReport {
        guard activeProjects.insert(localProjectID).inserted else {
            throw SyncV2SnapshotPullError.alreadyRunning
        }
        defer { activeProjects.remove(localProjectID) }
        try Task.checkCancellation()
        // 내부 async let 네트워크 요청까지 실제로 종료한 다음에 슬롯을 돌려준다.
        return try await performPull(localProjectID: localProjectID,
                                     serverProjectID: serverProjectID, editingGuards: editingGuards)
    }

    private func performPull(
        localProjectID: ProjectID, serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        let pullStartedAt = DispatchTime.now().uptimeNanoseconds
        SyncV2PullDiagnostics.record(
            stage: "snapshot-service",
            phase: "started"
        )
        let shouldFetchFolders = folderApplier != nil
        // 1단계: 본문 없는 표만 받는다. 어떤 문서의 본문이 실제로 필요한지는
        // 이 표와 로컬 상태만으로 정할 수 있다.
        async let manifestRequest = client.fetchDocumentManifest(
            projectID: serverProjectID
        )
        async let foldersRequest: [SyncV2RemoteFolder]? =
            shouldFetchFolders
            ? (try? await client.fetchFolders(projectID: serverProjectID))
            : nil
        async let treeOrdersRequest = client.fetchTreeOrders(
            projectID: serverProjectID
        )
        let manifest = try await manifestRequest
        try Task.checkCancellation()
        SyncV2PullDiagnostics.record(
            stage: "document-manifest",
            phase: "available-to-service",
            rowCount: manifest.count
        )
        // 실제 TXT 경로에서 폴더 메타데이터를 먼저 재구성한 뒤 순서를
        // 적용해야 새 Windows 폴더의 첫 pull에도 userOrder가 반영된다.
        let ordinaryEntries = manifest.filter {
            $0.relativePath != syncV2TreeOrderPath
                && $0.relativePath != syncV2TrashPurgePath
        }
        if let leaseManager {
            for entry in ordinaryEntries {
                if entry.isDeleted {
                    await leaseManager.documentBecameTombstone(
                        documentID: entry.documentID
                    )
                } else {
                    await leaseManager.ensureLeaseForActiveLiveDocument(
                        documentID: entry.documentID,
                        serverRevision: entry.revision
                    )
                }
            }
        }
        let remoteLiveDocumentPaths = Set(
            ordinaryEntries
                .filter { !$0.isDeleted }
                .map(\.relativePath)
        )
        let preparePullStartedAt = DispatchTime.now().uptimeNanoseconds
        try await mutationGate.withCriticalSection(
            documentID: syncV2ProjectStructureMutationID(localProjectID)
        ) { [self] in
            await localApplier.preparePull(
                localProjectID: localProjectID,
                remoteLiveDocumentPaths: remoteLiveDocumentPaths
            )
        }
        SyncV2PullDiagnostics.record(
            stage: "identity-audit",
            phase: "finished",
            startedAtNanoseconds: preparePullStartedAt,
            rowCount: ordinaryEntries.count
        )
        // 폴더를 문서보다 먼저 제자리에 놓는다. 이름이 바뀐 폴더에 문서가 먼저
        // 도착하면 옛 경로에 자리를 잡아, 뒤이은 폴더 이동이 목적지 충돌로
        // 막힌다.
        var folderReport = SyncV2RemoteFolderApplyReport()
        var fetchedRemoteFolders: [SyncV2RemoteFolder]?
        var permanentFolderBaselineExclusions: Set<UUID> = []
        // 성공적으로 평가한 folder projection이 실제로 변하지 않았음이
        // 입증되기 전까지는 같은 revision의 LEGACY tree_order를 재적용한다.
        // fetch/read/migration/pending 중 하나라도 불확실하면 fail-closed다.
        var folderProjectionIsStable = false
        let folderApplyStartedAt = DispatchTime.now().uptimeNanoseconds
        folderStage: if let folderApplier {
            // fetch는 Gate 밖에서 한다. 네트워크를 기다리는 동안
            // 사용자의 폴더 작업을 막지 않고, 디스크·메타데이터를
            // 실제로 읽고 바꾸는 구간만 직렬화한다.
            //
            // 실패를 삼켜 빈 목록으로 바꾸지 않는다. 삼키면 "서버에 폴더가
            // 없다"와 같은 값이 되어 tree_order 이름으로 유령 폴더를 짓는다.
            // 던지지도 않는다. 폴더 하나 때문에 문서 pull까지 막을 이유가
            // 없고, 폴더가 없던 시절 작품이 통째로 막힌다.
            // 실패는 값으로 남겨 폴더 판정만 보류시킨다.
            let fetchedFolders = await foldersRequest
            guard let folders = fetchedFolders else {
                await localApplier.prepareRemoteFolders(
                    localProjectID: localProjectID,
                    projection: .unavailable(code: "FOLDER_FETCH_FAILED")
                )
                break folderStage
            }
            fetchedRemoteFolders = folders
            let stage = try await mutationGate.withCriticalSection(
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
                    projection: .known(Set(serverFolderIDsByPath.keys))
                )
                // 이관을 먼저 돌린다. 기존 폴더에 공유 UUID가 붙어 있어야
                // 서버가 보낸 폴더와 짝이 맞는다.
                var migrationRequiresTreeOrderRecovery = false
                if let folderMigration {
                    let migrationResult = await folderMigration.migrateIfNeeded(
                        localProjectID: localProjectID,
                        serverProjectID: serverProjectID,
                        serverFolderIDsByPath: serverFolderIDsByPath
                    )
                    switch migrationResult {
                    case .alreadyCompleted, .nothingToMigrate:
                        break
                    case .migrated, .postponed:
                        migrationRequiresTreeOrderRecovery = true
                    }
                }
                let blockedServerFolderIDs: Set<UUID>
                var pendingOperationLookupSucceeded = true
                if let folderMarker {
                    do {
                        blockedServerFolderIDs = try await folderMarker
                            .foldersWithPendingOperations(
                                localProjectID: localProjectID
                            )
                    } catch {
                        blockedServerFolderIDs = []
                        pendingOperationLookupSucceeded = false
                    }
                } else {
                    blockedServerFolderIDs = []
                }
                let blockedFolderIDs = Set(
                    blockedServerFolderIDs.map(DocumentID.init(rawValue:))
                )
                let report = await folderApplier
                    .stageRemoteFoldersDeferringNonEmptyDeletions(
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
                    ).union(
                        report.deferredFolderIDs.map(\.rawValue)
                    )
                )
                let projectionIsStable = report.projectionWasEvaluated
                    && report.isEmpty
                    && blockedServerFolderIDs.isEmpty
                    && pendingOperationLookupSucceeded
                    && !migrationRequiresTreeOrderRecovery
                return (
                    report,
                    blockedServerFolderIDs,
                    projectionIsStable
                )
            }
            folderReport = stage.0
            folderProjectionIsStable = stage.2
            permanentFolderBaselineExclusions = stage.1.union(
                folderReport.rejectedFolderIDs.map(\.rawValue)
            )
        } else {
            // 이 작품에는 폴더 모형이 없다. 보류가 아니라 "없음"이므로 옛
            // tree_order 이름 추측을 그대로 쓴다. 보류로 두면 폴더 동기화가
            // 없던 시절 작품에서 폴더가 하나도 안 보이게 된다.
            await localApplier.prepareRemoteFolders(
                localProjectID: localProjectID,
                projection: .unsupported
            )
        }
        SyncV2PullDiagnostics.record(
            stage: "folder-local-apply",
            phase: "finished",
            startedAtNanoseconds: folderApplyStartedAt,
            rowCount: fetchedRemoteFolders?.count
        )

        // 폴더가 제자리에 놓인 뒤에 순서를 받는다. 순서는 folder_id를 가리키므로
        // 폴더가 먼저 있어야 가리킬 대상이 있다.
        let treeOrders = try await treeOrdersRequest
        let treeOrderApplyStartedAt =
            DispatchTime.now().uptimeNanoseconds
        if !treeOrders.isEmpty {
            try await stateStore.applyTreeOrderSnapshotBaselines(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                treeOrders: treeOrders
            )
        }
        SyncV2PullDiagnostics.record(
            stage: "tree-order-local-apply",
            phase: "finished",
            startedAtNanoseconds: treeOrderApplyStartedAt,
            rowCount: treeOrders.count
        )

        let orderedEntries = manifest.filter {
            $0.relativePath == syncV2TrashPurgePath
        }
            + ordinaryEntries.filter(\.isDeleted)
            + ordinaryEntries.filter { !$0.isDeleted }
            + manifest.filter {
            $0.relativePath == syncV2TreeOrderPath
        }
        var outcomes: [SyncV2SnapshotPullOutcome] = []
        var appliedSnapshots: [SyncV2RemoteDocumentSnapshot] = []
        var rejectedStructureNames = folderReport.rejectedNames
        outcomes.reserveCapacity(manifest.count)

        var effectivePurgeState = await localApplier.trashPurgeState(
            localProjectID: localProjectID
        )
        let documentLoopStartedAt =
            DispatchTime.now().uptimeNanoseconds
        var identityLookupNanoseconds: UInt64 = 0
        var gateWaitNanoseconds: UInt64 = 0
        var processNanoseconds: UInt64 = 0
        var stateLookupNanoseconds: UInt64 = 0
        var equivalentIdentityCount = 0
        let sameRevisionTreeOrderRequiresRecovery =
            !folderProjectionIsStable
        let batchStateLookupStartedAt =
            DispatchTime.now().uptimeNanoseconds
        let prefetchedStates: [UUID: SyncV2SnapshotLocalState]?
        do {
            prefetchedStates = try await stateStore.snapshotStates(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                documentIDs: Set(orderedEntries.map(\.documentID))
            )
        } catch {
            // batch는 최적화일 뿐이다. 실패하면 각 문서 gate 안의
            // 기존 단건 조회로 돌아가 안전 판정을 유지한다.
            prefetchedStates = nil
        }
        SyncV2PullDiagnostics.record(
            stage: "snapshot-state-batch",
            phase: prefetchedStates == nil ? "fallback" : "finished",
            startedAtNanoseconds: batchStateLookupStartedAt,
            rowCount: orderedEntries.count,
            changedCount: prefetchedStates?.count
        )

        // 2단계: 본문이 실제로 필요한 문서만 고른다. batch 상태 조회가 실패한
        // pull은 판정 근거가 없으므로 예전처럼 전부 받는다.
        let hydrationDecisionStartedAt =
            DispatchTime.now().uptimeNanoseconds
        var resolvedOutcomes: [UUID: SyncV2SnapshotPullOutcome] = [:]
        var hydrationTargets: [UUID] = []
        for entry in orderedEntries {
            try Task.checkCancellation()
            guard let prefetchedStates else {
                SyncV2Diagnostics.hydrationRequired(
                    documentID: entry.documentID,
                    reason: "state-batch-unavailable",
                    sentinelPath: nil
                )
                hydrationTargets.append(entry.documentID)
                continue
            }
            let decision = await hydrationDecision(
                entry: entry,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                state: prefetchedStates[entry.documentID],
                editing: editingGuards[entry.documentID] ?? .closed,
                effectivePurgeState: effectivePurgeState,
                sameRevisionTreeOrderRequiresRecovery:
                    sameRevisionTreeOrderRequiresRecovery
            )
            switch decision {
            case let .resolved(outcome):
                resolvedOutcomes[entry.documentID] = outcome
            case let .hydrate(reason):
                let sentinelPath: String? = switch entry.relativePath {
                case syncV2TreeOrderPath: syncV2TreeOrderPath
                case syncV2TrashPurgePath: syncV2TrashPurgePath
                default: nil
                }
                SyncV2Diagnostics.hydrationRequired(
                    documentID: entry.documentID,
                    reason: reason,
                    sentinelPath: sentinelPath
                )
                hydrationTargets.append(entry.documentID)
            }
        }
        SyncV2PullDiagnostics.record(
            stage: "hydration-decision",
            phase: "finished",
            startedAtNanoseconds: hydrationDecisionStartedAt,
            rowCount: orderedEntries.count,
            changedCount: hydrationTargets.count
        )

        let hydrationStartedAt = DispatchTime.now().uptimeNanoseconds
        var hydratedByID: [UUID: SyncV2RemoteDocumentSnapshot] = [:]
        if !hydrationTargets.isEmpty {
            let hydrated = try await client.fetchDocumentContents(
                projectID: serverProjectID,
                documentIDs: hydrationTargets
            )
            for snapshot in hydrated {
                hydratedByID[snapshot.documentID] = snapshot
            }
        }
        SyncV2PullDiagnostics.record(
            stage: "document-contents",
            phase: "available-to-service",
            startedAtNanoseconds: hydrationStartedAt,
            rowCount: hydrationTargets.count
        )

        // 표와 본문은 서로 다른 요청이다. 그 사이에 서버가 앞서갔다면 본문 쪽이
        // 더 최신이므로 아래 루프가 본문을 정본으로 쓴다. 여기서는 표를 근거로
        // 내린 사전 판정을 거두고, 얼마나 자주 어긋나는지를 남긴다.
        var advancedRowCount = 0
        for entry in orderedEntries {
            guard let hydrated = hydratedByID[entry.documentID],
                  !entry.describesSameRow(as: hydrated)
            else { continue }
            advancedRowCount += 1
            resolvedOutcomes[entry.documentID] = nil
        }
        if advancedRowCount > 0 {
            SyncV2PullDiagnostics.record(
                stage: "document-contents",
                phase: "row-advanced-during-hydration",
                rowCount: hydrationTargets.count,
                changedCount: advancedRowCount
            )
        }
        for entry in orderedEntries {
            try Task.checkCancellation()
            // 본문 없이 결론이 난 문서는 여기서 끝난다. 판정은 본문을 한 번도
            // 보지 않는 기존 경로와 같은 규칙을 쓴다.
            if let resolved = resolvedOutcomes[entry.documentID] {
                outcomes.append(resolved)
                continue
            }
            guard let snapshot = hydratedByID[entry.documentID] else {
                // 본문을 받기로 했는데 없다. 검증 계층이 막지 못한 경우이므로
                // 조용히 건너뛰지 않고 이 pull을 실패로 돌린다.
                throw SyncV2ClientError.invalidResponse
            }
            let editing = editingGuards[snapshot.documentID] ?? .closed
            let identityLookupStartedAt =
                DispatchTime.now().uptimeNanoseconds
            let equivalentLocalDocumentID =
                await localApplier.equivalentLocalDocumentID(
                    localProjectID: localProjectID,
                    snapshot: snapshot
                )
            let identityLookupFinishedAt =
                DispatchTime.now().uptimeNanoseconds
            identityLookupNanoseconds += Self.elapsedNanoseconds(
                from: identityLookupStartedAt,
                to: identityLookupFinishedAt
            )
            if equivalentLocalDocumentID != nil {
                equivalentIdentityCount += 1
            }
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
                    manifest.compactMap { candidate in
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
            let gateWaitStartedAt =
                DispatchTime.now().uptimeNanoseconds
            let measurement = ProcessMeasurement()
            let prefetchedState: PrefetchedSnapshotState
            if let prefetchedStates {
                prefetchedState = .loaded(
                    prefetchedStates[snapshot.documentID]
                )
            } else {
                prefetchedState = .unavailable
            }
            let timed = try await mutationGate.withCriticalSections(
                documentIDs: lockedDocumentIDs
            ) { [self] in
                let processStartedAt =
                    DispatchTime.now().uptimeNanoseconds
                let processed = try await process(
                    snapshot,
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editing: editing,
                    equivalentLocalDocumentID:
                        equivalentLocalDocumentID,
                    equivalentLocalEditing: equivalentLocalEditing,
                    effectivePurgeState: purgeStateForSnapshot,
                    eligibleDocumentIDs: eligibleIDsForSnapshot,
                    sameRevisionTreeOrderRequiresRecovery:
                        sameRevisionTreeOrderRequiresRecovery,
                    prefetchedState: prefetchedState,
                    measurement: measurement
                )
                let processFinishedAt =
                    DispatchTime.now().uptimeNanoseconds
                return TimedProcessedSnapshot(
                    processed: processed,
                    gateWaitNanoseconds: Self.elapsedNanoseconds(
                        from: gateWaitStartedAt,
                        to: processStartedAt
                    ),
                    processNanoseconds: Self.elapsedNanoseconds(
                        from: processStartedAt,
                        to: processFinishedAt
                    ),
                    stateLookupNanoseconds:
                        measurement.stateLookupNanoseconds()
                )
            }
            gateWaitNanoseconds += timed.gateWaitNanoseconds
            processNanoseconds += timed.processNanoseconds
            stateLookupNanoseconds += timed.stateLookupNanoseconds
            let processed = timed.processed
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
        let processRemainderNanoseconds = processNanoseconds
            >= stateLookupNanoseconds
            ? processNanoseconds - stateLookupNanoseconds
            : 0
        SyncV2PullDiagnostics.record(
            stage: "document-loop-breakdown",
            phase: "identity-lookup",
            rowCount: orderedEntries.count,
            changedCount: equivalentIdentityCount,
            valueMilliseconds: Self.milliseconds(
                identityLookupNanoseconds
            )
        )
        SyncV2PullDiagnostics.record(
            stage: "document-loop-breakdown",
            phase: "mutation-gate-wait",
            rowCount: orderedEntries.count,
            valueMilliseconds: Self.milliseconds(
                gateWaitNanoseconds
            )
        )
        SyncV2PullDiagnostics.record(
            stage: "document-loop-breakdown",
            phase: "state-store-lookup",
            rowCount: orderedEntries.count,
            valueMilliseconds: Self.milliseconds(
                stateLookupNanoseconds
            )
        )
        SyncV2PullDiagnostics.record(
            stage: "document-loop-breakdown",
            phase: "process-after-state-lookup",
            rowCount: orderedEntries.count,
            valueMilliseconds: Self.milliseconds(
                processRemainderNanoseconds
            )
        )
        SyncV2PullDiagnostics.record(
            stage: "document-local-compare-apply",
            phase: "finished",
            startedAtNanoseconds: documentLoopStartedAt,
            rowCount: orderedEntries.count,
            changedCount: appliedSnapshots.count
        )

        let deferredFolderCount = folderReport.deferredFolderIDs.count
        let folderFinalizeStartedAt =
            DispatchTime.now().uptimeNanoseconds
        if let folderApplier,
           let folders = fetchedRemoteFolders,
           !folderReport.deferredFolderIDs.isEmpty {
            let deferredFolderIDs = folderReport.deferredFolderIDs
            let baselineExclusions = permanentFolderBaselineExclusions
            let completedOutcomes = outcomes
            let finalReport = try await mutationGate.withCriticalSection(
                documentID: syncV2ProjectStructureMutationID(localProjectID)
            ) { [self] in
                let latestDocuments = try await folderDocuments?.documents(
                    in: localProjectID
                ) ?? []
                let latestBlockedServerFolderIDs: Set<UUID>
                if let folderMarker {
                    latestBlockedServerFolderIDs = try await folderMarker
                        .foldersWithPendingOperations(
                            localProjectID: localProjectID
                        )
                } else {
                    latestBlockedServerFolderIDs = []
                }
                let latestBlockedFolderIDs = Set(
                    latestBlockedServerFolderIDs.map(
                        DocumentID.init(rawValue:)
                    )
                )
                let waitingFolderIDs = Self
                    .foldersWaitingForRemoteChildren(
                        folderIDs: deferredFolderIDs,
                        documents: latestDocuments,
                        entries: ordinaryEntries,
                        outcomes: completedOutcomes,
                        remoteFolders: folders,
                        blockedFolderIDs: latestBlockedFolderIDs
                    )
                let report = await folderApplier
                    .finalizeDeferredFolderDeletions(
                        localProjectID: localProjectID,
                        remote: folders,
                        deferredFolderIDs: deferredFolderIDs,
                        blockedFolderIDs: latestBlockedFolderIDs,
                        waitingForRemoteChildrenFolderIDs: waitingFolderIDs
                    )
                let finalExclusions = baselineExclusions
                    .union(latestBlockedServerFolderIDs)
                    .union(report.rejectedFolderIDs.map(\.rawValue))
                try await stateStore.applyFolderSnapshotBaselines(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    folders: folders,
                    excluding: finalExclusions
                )
                return report
            }
            folderReport.deletedFolderIDs.append(
                contentsOf: finalReport.deletedFolderIDs
            )
            folderReport.pendingChildTombstoneFolderIDs.formUnion(
                finalReport.pendingChildTombstoneFolderIDs
            )
            folderReport.rejectedFolderIDs.formUnion(
                finalReport.rejectedFolderIDs
            )
            rejectedStructureNames.append(
                contentsOf: finalReport.rejectedNames
            )
            folderReport.deferredFolderIDs.removeAll()
        }
        SyncV2PullDiagnostics.record(
            stage: "folder-tombstone-finalize",
            phase: "finished",
            startedAtNanoseconds: folderFinalizeStartedAt,
            rowCount: deferredFolderCount,
            changedCount: folderReport.deletedFolderIDs.count
        )
        let report = SyncV2SnapshotPullReport(
            outcomes: outcomes,
            appliedSnapshots: appliedSnapshots,
            rejectedStructureNames: rejectedStructureNames,
            pendingChildTombstoneFolderCount:
                folderReport.pendingChildTombstoneFolderIDs.count,
            deferredLocalApplicationCount: outcomes.reduce(into: 0) {
                count, outcome in
                if case .mergeRequired(_, _, .remoteDeletion) = outcome {
                    count += 1
                }
            }
        )
        SyncV2PullDiagnostics.record(
            stage: "snapshot-service",
            phase: "finished",
            startedAtNanoseconds: pullStartedAt,
            rowCount: manifest.count,
            changedCount: appliedSnapshots.count
        )
        return report
    }

    /// 로컬에 남은 모든 자식이 완전한 원격 projection에도
    /// 같은 UUID로 있을 때만 "자식 tombstone 대기"로 분류한다.
    /// 원격에 없는 로컬 자식이나 pending 폴더가 하나라도 있으면
    /// 진짜 로컬 자료 위험이므로 대기 집합에 넣지 않는다.
    private static func foldersWaitingForRemoteChildren(
        folderIDs: Set<DocumentID>,
        documents: [DocumentNode],
        entries: [SyncV2RemoteDocumentManifestEntry],
        outcomes: [SyncV2SnapshotPullOutcome],
        remoteFolders: [SyncV2RemoteFolder],
        blockedFolderIDs: Set<DocumentID>
    ) -> Set<DocumentID> {
        let snapshotsByID = Dictionary(
            entries.map { ($0.documentID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let remoteFolderIDs = Set(remoteFolders.map(\.folderID))
        let safelyProcessedDocumentIDs: Set<UUID> = Set(
            outcomes.compactMap { outcome -> UUID? in
            switch outcome {
            case let .applied(documentID, _, _),
                 let .upToDate(documentID, _):
                return documentID
            case let .mergeRequired(documentID, revision, reason):
                guard reason == .remoteDeletion,
                      let snapshot = snapshotsByID[documentID],
                      snapshot.isDeleted,
                      snapshot.revision == revision
                else { return nil }
                return documentID
            }
        })
        var waiting: Set<DocumentID> = []
        for folderID in folderIDs {
            guard !blockedFolderIDs.contains(folderID),
                  let folder = documents.first(where: {
                      $0.id == folderID && $0.kind == .folder
                  })
            else { continue }
            let prefix = SyncV2FolderIdentity.canonicalPath(
                folder.relativePath.rawValue
            ) + "/"
            let descendants = documents.filter {
                $0.id != folderID
                    && SyncV2FolderIdentity.canonicalPath(
                        $0.relativePath.rawValue
                    ).hasPrefix(prefix)
            }
            guard !descendants.isEmpty else { continue }
            let allChildrenBelongToRemoteProjection = descendants.allSatisfy {
                child in
                if child.kind == .folder {
                    return !blockedFolderIDs.contains(child.id)
                        && remoteFolderIDs.contains(child.id.rawValue)
                }
                return snapshotsByID[child.id.rawValue] != nil
                    && safelyProcessedDocumentIDs.contains(child.id.rawValue)
            }
            if allChildrenBelongToRemoteProjection {
                waiting.insert(folderID)
            }
        }
        return waiting
    }

    private func process(
        _ snapshot: SyncV2RemoteDocumentSnapshot,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editing: SyncV2EditingGuard,
        equivalentLocalDocumentID: UUID?,
        equivalentLocalEditing: SyncV2EditingGuard,
        effectivePurgeState: SyncV2TrashPurgePayload,
        eligibleDocumentIDs: Set<UUID>,
        sameRevisionTreeOrderRequiresRecovery: Bool,
        prefetchedState: PrefetchedSnapshotState,
        measurement: ProcessMeasurement
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
        if equivalentLocalDocumentID == nil,
           case let .loaded(state) = prefetchedState,
           let outcome = await prefetchedReadOnlyOutcome(
               snapshot: snapshot,
               state: state,
               localProjectID: localProjectID,
               effectivePurgeState: effectivePurgeState,
               sameRevisionTreeOrderRequiresRecovery:
                   sameRevisionTreeOrderRequiresRecovery
           ) {
            return ProcessedSnapshot(
                outcome: outcome,
                appliedSnapshot: nil
            )
        }
        let stateLookupStartedAt =
            DispatchTime.now().uptimeNanoseconds
        let state = try await stateStore.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: snapshot.documentID
        )
        let stateLookupFinishedAt =
            DispatchTime.now().uptimeNanoseconds
        measurement.recordStateLookup(
            nanoseconds: Self.elapsedNanoseconds(
                from: stateLookupStartedAt,
                to: stateLookupFinishedAt
            )
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
                        requiresRecovery =
                            sameRevisionTreeOrderRequiresRecovery
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

    /// Batch 결과는 각 문서 gate를 잡기 전의 snapshot이다.
    /// 그 값으로 로컬을 바꾸지 않고 종료할 수 있는 경우만 사용한다.
    /// 복구나 새 revision 적용이 필요하면 `nil`로 단건 재조회를
    /// 강제해 enqueue·conflict와의 경합을 닫는다.
    /// 본문을 받아야 하는가, 아니면 표와 로컬 상태만으로 결론이 나는가.
    ///
    /// 본문을 생략해도 되는 경우는 `prefetchedReadOnlyOutcome`이 본문을 한 번도
    /// 보지 않고 답을 내는 경우와 정확히 같아야 한다. 모르면 받는 쪽으로 답한다.
    enum HydrationDecision: Sendable {
        /// 본문 없이 결론이 났다.
        case resolved(SyncV2SnapshotPullOutcome)
        /// 본문을 받아 기존 판정 경로로 내려간다.
        case hydrate(reason: String)
    }

    func hydrationDecision(
        entry: SyncV2RemoteDocumentManifestEntry,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        state: SyncV2SnapshotLocalState?,
        editing: SyncV2EditingGuard,
        effectivePurgeState: SyncV2TrashPurgePayload,
        sameRevisionTreeOrderRequiresRecovery: Bool
    ) async -> HydrationDecision {
        // ⑤ 숨은 문서가 계약과 다르면 원격 본문을 보존 대상으로 남긴다.
        let hiddenPath: String? = switch entry.relativePath {
        case syncV2TreeOrderPath: syncV2TreeOrderPath
        case syncV2TrashPurgePath: syncV2TrashPurgePath
        default: nil
        }
        if let hiddenPath,
           entry.isDeleted
               || entry.documentID != syncV2UUIDv5(
                   namespace: serverProjectID,
                   name: hiddenPath
               ) {
            return .hydrate(reason: "hidden-document-contract")
        }

        // ④ 휴지통 비움 payload는 같은 revision이어도 멱등 병합이 필요하다.
        if entry.relativePath == syncV2TrashPurgePath {
            return .hydrate(reason: "trash-purge")
        }

        // ① 로컬 기준선이 없거나 서버가 앞서면 받아야 한다.
        guard let state else {
            return .hydrate(reason: "no-local-baseline")
        }
        guard entry.revision <= state.serverRevision else {
            return .hydrate(reason: "server-revision-advanced")
        }

        // ⑥ 서버 UUID가 로컬에 없으면 같은 경로의 다른 UUID를 채택할지
        // 따져야 하고, 그 판정은 본문 바이트 비교로만 끝난다.
        //
        // 채택 대상이 될 수 없는 문서는 확인하지 않는다. 숨은 계약 문서는
        // 로컬에 짝이 없는 것이 정상이고, tombstone은 채택 대상이 아니다.
        // 이 제외가 없으면 작품마다 tree-order 하나가 변경이 없는데도 매번
        // 본문을 받아 두 단계로 나눈 뜻이 없어진다. 제외 조건은
        // `equivalentLocalDocumentID`가 스스로 거르는 것과 같아야 한다.
        if hiddenPath == nil, !entry.isDeleted,
           !editing.isOpen, !editing.isDirty, !editing.isComposing,
           await !localApplier.hasLocalDocument(
               localProjectID: localProjectID,
               documentID: entry.documentID
           ) {
            return .hydrate(reason: "local-uuid-absent")
        }

        if state.hasUnresolvedConflict {
            return .resolved(
                .mergeRequired(
                    documentID: entry.documentID,
                    revision: state.serverRevision,
                    reason: .unresolvedConflict
                )
            )
        }
        if state.blockingErrorCode != nil {
            return .resolved(
                .mergeRequired(
                    documentID: entry.documentID,
                    revision: state.serverRevision,
                    reason: .blockedOperation
                )
            )
        }
        if state.hasPathCollision {
            return .resolved(
                .mergeRequired(
                    documentID: entry.documentID,
                    revision: state.serverRevision,
                    reason: .pathOccupiedByDifferentDocument
                )
            )
        }
        if state.hasActiveOperation {
            return .resolved(
                .mergeRequired(
                    documentID: entry.documentID,
                    revision: state.serverRevision,
                    reason: .pendingOperation
                )
            )
        }

        let isPurgedTombstone = entry.isDeleted
            && effectivePurgeState.purgedRevisions[
                entry.documentID
            ].map { $0 >= entry.revision } == true
        if entry.revision == state.serverRevision,
           entry.relativePath == state.serverPath,
           !isPurgedTombstone {
            if entry.relativePath == syncV2TreeOrderPath {
                // ③ 같은 revision의 순서를 다시 적용해야 하면 본문이 필요하다.
                if sameRevisionTreeOrderRequiresRecovery {
                    return .hydrate(reason: "tree-order-recovery")
                }
            } else {
                // ② 로컬 TXT가 사라졌으면 서버 본문으로 되살려야 한다.
                if await localApplier.requiresCopyRecovery(
                    localProjectID: localProjectID,
                    manifestEntry: entry
                ) {
                    return .hydrate(reason: "copy-recovery")
                }
            }
        }

        return .resolved(
            .upToDate(
                documentID: entry.documentID,
                revision: state.serverRevision
            )
        )
    }

    private func prefetchedReadOnlyOutcome(
        snapshot: SyncV2RemoteDocumentSnapshot,
        state: SyncV2SnapshotLocalState?,
        localProjectID: ProjectID,
        effectivePurgeState: SyncV2TrashPurgePayload,
        sameRevisionTreeOrderRequiresRecovery: Bool
    ) async -> SyncV2SnapshotPullOutcome? {
        guard let state,
              snapshot.revision <= state.serverRevision
        else { return nil }

        if state.hasUnresolvedConflict {
            return .mergeRequired(
                documentID: snapshot.documentID,
                revision: state.serverRevision,
                reason: .unresolvedConflict
            )
        }
        if state.blockingErrorCode != nil {
            return .mergeRequired(
                documentID: snapshot.documentID,
                revision: state.serverRevision,
                reason: .blockedOperation
            )
        }
        if state.hasPathCollision {
            return .mergeRequired(
                documentID: snapshot.documentID,
                revision: state.serverRevision,
                reason: .pathOccupiedByDifferentDocument
            )
        }
        if state.hasActiveOperation {
            return .mergeRequired(
                documentID: snapshot.documentID,
                revision: state.serverRevision,
                reason: .pendingOperation
            )
        }

        // purge payload는 같은 revision이어도 휴지통 상태를
        // 멱등하게 합치는 부수 작업이 있으므로 단건 경로를 유지한다.
        guard snapshot.relativePath != syncV2TrashPurgePath else {
            return nil
        }

        let isPurgedTombstone = snapshot.isDeleted
            && effectivePurgeState.purgedRevisions[
                snapshot.documentID
            ].map { $0 >= snapshot.revision } == true
        if snapshot.revision == state.serverRevision,
           snapshot.relativePath == state.serverPath,
           !isPurgedTombstone {
            if snapshot.relativePath == syncV2TreeOrderPath {
                guard !sameRevisionTreeOrderRequiresRecovery else {
                    return nil
                }
            } else {
                let requiresRecovery = await localApplier
                    .requiresCopyRecovery(
                        localProjectID: localProjectID,
                        snapshot: snapshot
                    )
                guard !requiresRecovery else { return nil }
            }
        }

        return .upToDate(
            documentID: snapshot.documentID,
            revision: state.serverRevision
        )
    }

    private static func elapsedNanoseconds(
        from start: UInt64,
        to end: UInt64
    ) -> UInt64 {
        end >= start ? end - start : 0
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
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
