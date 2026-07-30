import Foundation
import Network

protocol SyncV2OpenLocalSnapshotProviding: Sendable {
    func latestOpenSnapshot(
        documentID: UUID
    ) async -> SyncV2RebaseLocalSnapshot?
    func isCurrent(
        documentID: UUID,
        snapshot: SyncV2RebaseLocalSnapshot
    ) async -> Bool
    func applyMergedIfCurrent(
        documentID: UUID,
        expected: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) async -> Bool
}

enum SyncV2AutomaticRebaseOutcome: Equatable, Sendable {
    case rebased
    case generationAdvanced
    case conflictPreserved
    case conflict(code: String, detail: String?)
}

actor SyncV2AutomaticRebaser {
    private let store: any SyncV2DispatchStoring
    private let snapshotClient: any SyncV2SnapshotClienting
    private let localApplier: (any SyncV2LocalSnapshotApplying)?
    private let openLocalProvider:
        (any SyncV2OpenLocalSnapshotProviding)?

    init(
        store: any SyncV2DispatchStoring,
        snapshotClient: any SyncV2SnapshotClienting,
        localApplier: (any SyncV2LocalSnapshotApplying)? = nil,
        openLocalProvider:
            (any SyncV2OpenLocalSnapshotProviding)? = nil
    ) {
        self.store = store
        self.snapshotClient = snapshotClient
        self.localApplier = localApplier
        self.openLocalProvider = openLocalProvider
    }

    func rebase(
        _ operation: SyncV2DispatchOperation
    ) async throws -> SyncV2AutomaticRebaseOutcome {
        guard operation.kind == .documentCommit,
              !operation.isDeleted,
              let remote = try await snapshotClient.fetchDocument(
                  projectID: operation.projectID,
                  documentID: operation.documentID
              )
        else {
            return .conflict(
                code: "DOCUMENT_NOT_FOUND",
                detail: "revision conflict 뒤 최신 서버 문서를 읽지 못했습니다."
            )
        }
        guard !remote.isDeleted else {
            return .conflict(
                code: "REMOTE_DELETION",
                detail: "서버에서 삭제된 문서는 자동 rebase하지 않습니다."
            )
        }
        guard remote.revision > operation.baseRevision else {
            throw SyncV2ClientError.invalidResponse
        }

        let queuedLocal = try await store.latestLocalSnapshot(
            for: operation
        )
        let openLocal = await openLocalProvider?.latestOpenSnapshot(
            documentID: operation.documentID
        )
        let local = Self.newest(queued: queuedLocal, open: openLocal)
        let merge = ThreeWayMerge.merge(
            base: operation.baseContent,
            local: local.content,
            remote: remote.content
        )
        if merge.hasConflicts {
            if let openLocalProvider,
               let openLocal,
               !(await openLocalProvider.isCurrent(
                   documentID: operation.documentID,
                   snapshot: openLocal
               )) {
                return .generationAdvanced
            }
            let detail =
                "본문 \(merge.conflictCount)곳이 겹쳐 자동 병합하지 않았습니다."
            let result = try await store.preserveConflict(
                operation,
                remote: remote,
                local: local,
                mergedContent: merge.content,
                conflictCount: merge.conflictCount,
                errorCode: "REVISION_CONFLICT",
                detail: detail
            )
            switch result {
            case .preserved:
                return .conflictPreserved
            case .localGenerationAdvanced:
                return .generationAdvanced
            }
        }
        guard let mergedPath = Self.mergePath(
            base: operation.baseServerPath,
            local: local.relativePath,
            remote: remote.relativePath
        ) else {
            return .conflict(
                code: "PATH_CONFLICT",
                detail: "로컬과 서버가 경로를 서로 다르게 변경했습니다."
            )
        }
        guard merge.content.utf8.count
                <= SyncV2Store.maximumContentByteCount
        else {
            return .conflict(
                code: SyncV2Store.contentTooLargeErrorCode,
                detail: "자동 병합 결과가 서버 본문 크기 제한을 초과합니다."
            )
        }

        if let openLocalProvider,
           let openLocal,
           !(await openLocalProvider.isCurrent(
               documentID: operation.documentID,
               snapshot: openLocal
           )) {
            return .generationAdvanced
        }

        if let localProjectID = operation.localProjectID,
           let localApplier {
            let localSnapshot = SyncV2RemoteDocumentSnapshot(
                documentID: operation.documentID,
                relativePath: mergedPath,
                content: merge.content,
                revision: remote.revision,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: remote.updatedAt
            )
            do {
                try await localApplier.apply(
                    localProjectID: localProjectID,
                    snapshot: localSnapshot
                )
            } catch SyncV2LocalSnapshotApplyError
                        .pathOccupiedByDifferentDocument {
                return .conflict(
                    code: "PATH_CONFLICT",
                    detail: "자동 병합 목적 경로를 다른 UUID 문서가 사용 중입니다."
                )
            } catch let error as SyncV2LocalSnapshotApplyError {
                return .conflict(
                    code: "PATH_CONFLICT",
                    detail: "자동 병합 경로를 로컬 바인더에 안전하게 적용할 수 없습니다: \(error)"
                )
            }
        }

        if let openLocalProvider, let openLocal {
            guard await openLocalProvider.applyMergedIfCurrent(
                documentID: operation.documentID,
                expected: openLocal,
                mergedContent: merge.content,
                mergedPath: mergedPath
            ) else {
                if let localProjectID = operation.localProjectID {
                    await localApplier?.rollback(
                        localProjectID: localProjectID,
                        documentID: operation.documentID
                    )
                }
                return .generationAdvanced
            }
            guard await openLocalProvider.isCurrent(
                documentID: operation.documentID,
                snapshot: SyncV2RebaseLocalSnapshot(
                    content: merge.content,
                    localPath: mergedPath,
                    relativePath: mergedPath,
                    localSaveGeneration:
                        openLocal.localSaveGeneration
                )
            ) else {
                if let localProjectID = operation.localProjectID {
                    await localApplier?.rollback(
                        localProjectID: localProjectID,
                        documentID: operation.documentID
                    )
                }
                return .generationAdvanced
            }
        }

        let result: SyncV2AutomaticRebaseStoreResult
        do {
            result = try await store.rebaseAfterRevisionConflict(
                operation,
                remote: remote,
                local: local,
                mergedContent: merge.content,
                mergedPath: mergedPath
            )
        } catch {
            if let localProjectID = operation.localProjectID {
                await localApplier?.rollback(
                    localProjectID: localProjectID,
                    documentID: operation.documentID
                )
            }
            throw error
        }
        switch result {
        case .rebased:
            if let localProjectID = operation.localProjectID {
                await localApplier?.finish(
                    localProjectID: localProjectID,
                    documentID: operation.documentID
                )
            }
            return .rebased
        case .localGenerationAdvanced:
            if let localProjectID = operation.localProjectID {
                await localApplier?.rollback(
                    localProjectID: localProjectID,
                    documentID: operation.documentID
                )
            }
            return .generationAdvanced
        case .pathOccupiedByDifferentDocument:
            if let localProjectID = operation.localProjectID {
                await localApplier?.rollback(
                    localProjectID: localProjectID,
                    documentID: operation.documentID
                )
            }
            return .conflict(
                code: "PATH_CONFLICT",
                detail: "자동 병합 목적 경로를 다른 UUID 문서가 사용 중입니다."
            )
        }
    }

    private static func newest(
        queued: SyncV2RebaseLocalSnapshot,
        open: SyncV2RebaseLocalSnapshot?
    ) -> SyncV2RebaseLocalSnapshot {
        guard let open else { return queued }
        let normalizedOpen = SyncV2RebaseLocalSnapshot(
            content: open.content,
            localPath: queued.localPath,
            relativePath: queued.relativePath,
            localSaveGeneration: open.localSaveGeneration
        )
        switch (queued.localSaveGeneration, open.localSaveGeneration) {
        case let (queuedGeneration?, openGeneration?):
            return openGeneration >= queuedGeneration
                ? normalizedOpen
                : queued
        case (nil, _?):
            return normalizedOpen
        default:
            return queued
        }
    }

    private static func mergePath(
        base: String,
        local: String,
        remote: String
    ) -> String? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }
        return nil
    }
}

struct SyncV2RetryPolicy: Equatable, Sendable {
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval
    let jitterFraction: Double
    let leaseConflictDelay: TimeInterval

    init(
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        jitterFraction: Double,
        leaseConflictDelay: TimeInterval = 3
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.jitterFraction = jitterFraction
        self.leaseConflictDelay = leaseConflictDelay
    }

    static let `default` = SyncV2RetryPolicy(
        initialDelay: 2,
        maximumDelay: 5 * 60,
        jitterFraction: 0.2
    )

    func delay(attempt: Int, randomUnit: Double) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 30)
        let exponential = min(
            maximumDelay,
            initialDelay * pow(2, Double(exponent))
        )
        let unit = min(1, max(0, randomUnit))
        let jitter = (unit * 2 - 1) * jitterFraction
        return max(0, exponential * (1 + jitter))
    }

    func delay(
        errorCode: String,
        attempt: Int,
        randomUnit: Double
    ) -> TimeInterval {
        if errorCode == SyncV2RemoteErrorCode.leaseConflict.rawValue {
            return max(0, leaseConflictDelay)
        }
        return delay(attempt: attempt, randomUnit: randomUnit)
    }
}

/// durable queue에 새 operation이 들어온 순간 실행 중인 dispatcher를 깨운다.
///
/// 앱 시작 전에 enqueue된 작업도 첫 handler 설치 때 한 번 전달해,
/// foreground 재진입이나 수동 재시도를 기다리지 않게 한다.
actor SyncV2DispatchWakeup {
    private var handler:
        (id: UUID, action: @Sendable () -> Void)?
    private var hasPendingSignal = false

    func install(
        id: UUID,
        action: @escaping @Sendable () -> Void
    ) {
        handler = (id, action)
        guard hasPendingSignal else { return }
        hasPendingSignal = false
        action()
    }

    func remove(id: UUID) {
        guard handler?.id == id else { return }
        handler = nil
    }

    func signal() {
        guard let action = handler?.action else {
            hasPendingSignal = true
            return
        }
        action()
    }
}

actor SyncV2NetworkRecoveryHub {
    private var handler: (@Sendable () async -> Void)?
    private var pendingSignal = false
    private var activeTask: (id: UUID, task: Task<Void, Never>)?

    func install(
        handler: @escaping @Sendable () async -> Void
    ) {
        self.handler = handler
        guard pendingSignal else { return }
        pendingSignal = false
        startIfNeeded()
    }

    func signal() {
        guard handler != nil else {
            pendingSignal = true
            return
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard activeTask == nil, let handler else { return }
        let id = UUID()
        let task = Task { [weak self] in
            await handler()
            await self?.finished(id: id)
        }
        activeTask = (id, task)
    }

    private func finished(id: UUID) {
        guard activeTask?.id == id else { return }
        activeTask = nil
        if pendingSignal {
            pendingSignal = false
            startIfNeeded()
        }
    }
}

actor SyncV2Dispatcher {
    private struct ProjectLane {
        let generation: UUID
        let task: Task<Void, Never>
    }

    private let store: any SyncV2DispatchStoring
    private let client: any SyncV2CommitClienting
    private let maximumConcurrentDocuments: Int
    private let retryPolicy: SyncV2RetryPolicy
    private let randomUnit: @Sendable () -> Double
    private let networkMonitor: SyncV2NetworkRecoveryMonitor
    private let leaseManager: (any EditLeaseManaging)?
    private let projectRecoveryTransport:
        (any EnsureProjectTransporting)?
    private let automaticRebaser: SyncV2AutomaticRebaser?
    private let wakeup: SyncV2DispatchWakeup?
    private let networkRecoveryHub: SyncV2NetworkRecoveryHub?
    private let wakeupID = UUID()

    private var isStarted = false
    private var activeLocalProjectID: ProjectID?
    private var projectLanes: [ProjectID: ProjectLane] = [:]
    private var scheduledWake: Task<Void, Never>?

    init(
        store: any SyncV2DispatchStoring,
        client: any SyncV2CommitClienting,
        maximumConcurrentDocuments: Int = 3,
        retryPolicy: SyncV2RetryPolicy = .default,
        randomUnit: @escaping @Sendable () -> Double = {
            Double.random(in: 0 ... 1)
        },
        networkMonitor: SyncV2NetworkRecoveryMonitor =
            SyncV2NetworkRecoveryMonitor(),
        leaseManager: (any EditLeaseManaging)? = nil,
        projectRecoveryTransport:
            (any EnsureProjectTransporting)? = nil,
        automaticRebaser: SyncV2AutomaticRebaser? = nil,
        wakeup: SyncV2DispatchWakeup? = nil,
        networkRecoveryHub: SyncV2NetworkRecoveryHub? = nil
    ) {
        self.store = store
        self.client = client
        self.maximumConcurrentDocuments = max(
            1,
            maximumConcurrentDocuments
        )
        self.retryPolicy = retryPolicy
        self.randomUnit = randomUnit
        self.networkMonitor = networkMonitor
        self.leaseManager = leaseManager
        self.projectRecoveryTransport = projectRecoveryTransport
        self.automaticRebaser = automaticRebaser
        self.wakeup = wakeup
        self.networkRecoveryHub = networkRecoveryHub
    }

    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await wakeup?.install(id: wakeupID) { [weak self] in
            Task {
                await self?.newOperationsEnqueued()
            }
        }
        try? await store.recoverInterruptedWork()
        networkMonitor.start { [weak self] in
            Task {
                await self?.networkRecovered()
            }
        }
        // 재실행 전에 이미 pending이던 operation도 작품별 lane으로 즉시 복구한다.
        await refreshProjectLanesAndSchedule()
    }

    func stop() async {
        isStarted = false
        scheduledWake?.cancel()
        scheduledWake = nil
        projectLanes.values.forEach { $0.task.cancel() }
        projectLanes.removeAll()
        networkMonitor.cancel()
        await wakeup?.remove(id: wakeupID)
    }

    /// 열린 작품에 더 많은 문서 동시 처리량을 배정한다.
    /// 다른 작품의 lane은 중단하지 않으므로 백그라운드 동기화가 유지된다.
    func prioritizeProject(_ localProjectID: ProjectID?) async {
        activeLocalProjectID = localProjectID
        await refreshProjectLanesAndSchedule()
    }

    /// 인증 서비스가 검증된 authenticated 상태로 전이한 직후 호출한다.
    func loginSucceeded() async {
        await immediateRetryOpportunity()
    }

    /// scenePhase가 active로 돌아온 시점에 호출한다.
    func appEnteredForeground() async {
        await immediateRetryOpportunity()
    }

    /// 사용자가 동기화 상세 화면에서 명시적으로 재시도를 선택할 때 호출한다.
    func userRequestedRetry() async {
        await immediateRetryOpportunity()
    }

    /// NWPathMonitor가 unsatisfied/requiresConnection에서 satisfied로 바뀔 때만 호출된다.
    func networkRecovered() async {
        await networkRecoveryHub?.signal()
        await immediateRetryOpportunity()
    }

    private func newOperationsEnqueued() async {
        await refreshProjectLanesAndSchedule()
    }

    /// 자동 테스트가 고정 시각으로 한 cycle을 끝까지 비울 수 있는 결정적 진입점이다.
    func dispatchReadyOperations(now: Date) async {
        guard let projectIDs = try? await store.readyLocalProjectIDs(
            now: now
        ) else { return }
        let orderedProjectIDs = prioritized(projectIDs)
        let store = self.store
        let client = self.client
        let retryPolicy = self.retryPolicy
        let randomUnit = self.randomUnit
        let leaseManager = self.leaseManager
        let projectRecoveryTransport = self.projectRecoveryTransport
        let automaticRebaser = self.automaticRebaser
        let activeLocalProjectID = self.activeLocalProjectID
        let maximumConcurrentDocuments = self.maximumConcurrentDocuments
        await withTaskGroup(of: Void.self) { group in
            for projectID in orderedProjectIDs {
                group.addTask {
                    _ = await Self.drainReadyOperations(
                        localProjectID: projectID,
                        limit:
                            projectID == activeLocalProjectID
                            ? maximumConcurrentDocuments
                            : 1,
                        store: store,
                        client: client,
                        retryPolicy: retryPolicy,
                        randomUnit: randomUnit,
                        leaseManager: leaseManager,
                        projectRecoveryTransport:
                            projectRecoveryTransport,
                        automaticRebaser: automaticRebaser,
                        now: { now }
                    )
                }
            }
        }
    }

    private func immediateRetryOpportunity() async {
        try? await store.makeRetryWaitOperationsReady(
            localProjectID: nil
        )
        await refreshProjectLanesAndSchedule()
    }

    private func refreshProjectLanesAndSchedule() async {
        guard isStarted else { return }
        scheduledWake?.cancel()
        scheduledWake = nil
        guard let readyProjectIDs = try? await store.readyLocalProjectIDs(
            now: Date()
        ) else {
            return
        }
        for projectID in prioritized(readyProjectIDs)
        where projectLanes[projectID] == nil {
            startProjectLane(projectID)
        }
        await scheduleNextRetry()
    }

    private func startProjectLane(_ localProjectID: ProjectID) {
        let generation = UUID()
        let limit =
            localProjectID == activeLocalProjectID
            ? maximumConcurrentDocuments
            : 1
        let task = Task { [weak self] in
            guard let self else { return }
            let completedNormally = await Self.drainReadyOperations(
                localProjectID: localProjectID,
                limit: limit,
                store: self.store,
                client: self.client,
                retryPolicy: self.retryPolicy,
                randomUnit: self.randomUnit,
                leaseManager: self.leaseManager,
                projectRecoveryTransport:
                    self.projectRecoveryTransport,
                automaticRebaser: self.automaticRebaser,
                now: Date.init
            )
            await self.projectLaneFinished(
                localProjectID,
                generation: generation,
                completedNormally: completedNormally
            )
        }
        projectLanes[localProjectID] = ProjectLane(
            generation: generation,
            task: task
        )
    }

    private func projectLaneFinished(
        _ localProjectID: ProjectID,
        generation: UUID,
        completedNormally: Bool
    ) async {
        guard projectLanes[localProjectID]?.generation == generation else {
            return
        }
        projectLanes[localProjectID] = nil
        guard isStarted else { return }
        if completedNormally {
            // 마지막 empty claim과 새 enqueue가 교차해도 새 작업을 놓치지 않는다.
            await refreshProjectLanesAndSchedule()
        } else {
            await scheduleNextRetry()
        }
    }

    private func prioritized(
        _ projectIDs: [ProjectID]
    ) -> [ProjectID] {
        guard let activeLocalProjectID,
              projectIDs.contains(activeLocalProjectID) else {
            return projectIDs
        }
        return [activeLocalProjectID]
            + projectIDs.filter { $0 != activeLocalProjectID }
    }

    private static func drainReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        store: any SyncV2DispatchStoring,
        client: any SyncV2CommitClienting,
        retryPolicy: SyncV2RetryPolicy,
        randomUnit: @escaping @Sendable () -> Double,
        leaseManager: (any EditLeaseManaging)?,
        projectRecoveryTransport:
            (any EnsureProjectTransporting)?,
        automaticRebaser: SyncV2AutomaticRebaser?,
        now: @escaping @Sendable () -> Date
    ) async -> Bool {
        while !Task.isCancelled {
            let operations: [SyncV2DispatchOperation]
            do {
                operations = try await store.claimReadyOperations(
                    localProjectID: localProjectID,
                    limit: limit,
                    now: now()
                )
            } catch {
                return false
            }
            guard !operations.isEmpty else { return true }

            await withTaskGroup(of: Void.self) { group in
                for operation in operations {
                    group.addTask {
                        await Self.dispatch(
                            operation,
                            store: store,
                            client: client,
                            retryPolicy: retryPolicy,
                            randomUnit: randomUnit,
                            leaseManager: leaseManager,
                            projectRecoveryTransport:
                                projectRecoveryTransport,
                            automaticRebaser: automaticRebaser,
                            now: now()
                        )
                    }
                }
            }
        }
        return false
    }

    private func scheduleNextRetry() async {
        guard isStarted,
              scheduledWake == nil,
              let date = try? await store.nextRetryDate(
                  localProjectID: nil
              ) else {
            return
        }
        let delay = max(0, date.timeIntervalSinceNow)
        let nanoseconds = UInt64(
            min(delay, TimeInterval(UInt64.max) / 1_000_000_000)
                * 1_000_000_000
        )
        scheduledWake = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.scheduledRetryFired()
        }
    }

    private func scheduledRetryFired() async {
        scheduledWake = nil
        await refreshProjectLanesAndSchedule()
    }

    private static func dispatch(
        _ operation: SyncV2DispatchOperation,
        store: any SyncV2DispatchStoring,
        client: any SyncV2CommitClienting,
        retryPolicy: SyncV2RetryPolicy,
        randomUnit: @Sendable () -> Double,
        leaseManager: (any EditLeaseManaging)?,
        projectRecoveryTransport:
            (any EnsureProjectTransporting)?,
        automaticRebaser: SyncV2AutomaticRebaser?,
        now: Date
    ) async {
        do {
            let leaseToken = try await leaseManager?.leaseTokenForCommit(
                documentID: operation.documentID,
                deviceID: operation.deviceID,
                baseRevision: operation.baseRevision
            )
            let result = try await client.commitDocument(
                operation.commitParameters(leaseToken: leaseToken ?? nil)
            )
            await leaseManager?.commitSucceeded(
                documentID: operation.documentID,
                deviceID: operation.deviceID,
                isDeleted: operation.isDeleted
            )
            try await store.complete(operation, result: result)
        } catch let error as SyncV2ClientError {
            await leaseManager?.commitFailed(
                documentID: operation.documentID,
                deviceID: operation.deviceID,
                error: error
            )
            if case .remote(code: .documentNotFound, detail: _) = error,
               !operation.isDeleted {
                do {
                    try await store.recoverMissingRemoteDocument(operation)
                    return
                } catch {
                    // 로컬 기준선 복구 자체가 실패했을 때만 기존 충돌
                    // 처리로 내려가 사용자의 입력을 보존한다.
                }
            }
            if case .remote(code: .forbidden, detail: _) = error,
               let projectRecoveryTransport {
                do {
                    let projectName = try await store.projectName(
                        for: operation
                    )
                    let ensured = try await projectRecoveryTransport
                        .ensureProject(
                            parameters: EnsureProjectParameters(
                                projectID: operation.projectID,
                                name: projectName
                            )
                        )
                    guard ensured.projectID == operation.projectID,
                          ensured.name.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ) == projectName.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          )
                    else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    if operation.baseRevision == 0,
                       !operation.isDeleted {
                        try await store.recoverMissingRemoteProject(operation)
                    }
                    try await store.deferRetry(
                        operation,
                        errorCode:
                            operation.baseRevision == 0
                            ? "PROJECT_RECREATED"
                            : "PROJECT_ACCESS_REPAIRED",
                        detail: nil,
                        nextAttemptAt: now
                    )
                    return
                } catch {
                    // 작품이 실제로 다른 계정 소유이거나 서버 복구 함수가
                    // 아직 배포되지 않았다면 ensure_project도 FORBIDDEN이다.
                    // 이 경우 기존 blocked 처리로 내려간다.
                }
            }
            if case .remote(code: .revisionConflict, detail: _) = error,
               let automaticRebaser {
                do {
                    switch try await automaticRebaser.rebase(operation) {
                    case .rebased:
                        return
                    case .conflictPreserved:
                        return
                    case .generationAdvanced:
                        try await store.deferRetry(
                            operation,
                            errorCode: "LOCAL_GENERATION_ADVANCED",
                            detail: "병합 중 더 최신 로컬 입력이 생겨 다시 시도합니다.",
                            nextAttemptAt:
                                now.addingTimeInterval(0.25)
                        )
                        return
                    case let .conflict(code, detail):
                        try await store.markConflict(
                            operation,
                            errorCode: code,
                            detail: detail
                        )
                        return
                    }
                } catch {
                    let delay = retryPolicy.delay(
                        attempt: operation.attempts,
                        randomUnit: randomUnit()
                    )
                    try? await store.deferRetry(
                        operation,
                        errorCode: "AUTO_REBASE_FAILED",
                        detail: error.localizedDescription,
                        nextAttemptAt: now.addingTimeInterval(delay)
                    )
                    return
                }
            }
            let handling = handling(for: error)
            do {
                switch handling {
                case let .retry(code, detail):
                    let delay = retryPolicy.delay(
                        errorCode: code,
                        attempt: operation.attempts,
                        randomUnit: randomUnit()
                    )
                    try await store.deferRetry(
                        operation,
                        errorCode: code,
                        detail: detail,
                        nextAttemptAt: now.addingTimeInterval(delay)
                    )
                case let .conflict(code, detail):
                    try await store.markConflict(
                        operation,
                        errorCode: code,
                        detail: detail
                    )
                case let .blocked(code, detail):
                    try await store.markBlocked(
                        operation,
                        errorCode: code,
                        detail: detail
                    )
                }
            } catch {
                // 서버 성공/실패와 SQLite 반영 사이의 중단은 inflight recovery가
                // 같은 operation_id를 다시 보내도록 그대로 둔다.
            }
        } catch {
            let delay = retryPolicy.delay(
                attempt: operation.attempts,
                randomUnit: randomUnit()
            )
            try? await store.deferRetry(
                operation,
                errorCode: "UNKNOWN_CLIENT_ERROR",
                detail: error.localizedDescription,
                nextAttemptAt: now.addingTimeInterval(delay)
            )
        }
    }

    private static func handling(
        for error: SyncV2ClientError
    ) -> DispatchErrorHandling {
        switch error {
        case .networkUnavailable:
            return .retry(code: "NETWORK_UNAVAILABLE", detail: nil)
        case .timedOut:
            return .retry(code: "TIMEOUT", detail: nil)
        case .invalidResponse:
            return .retry(code: "INVALID_RESPONSE", detail: nil)
        case .serverRejected(let rejection):
            return .retry(
                code: rejection.postgresCode ?? "SERVER_REJECTED",
                detail: [rejection.message, rejection.detail]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            )
        case let .remote(code, detail):
            switch code {
            case .authRequired, .leaseRequired, .leaseConflict,
                 .leaseExpired:
                return .retry(code: code.rawValue, detail: detail)
            case .forbidden, .invalidArgument:
                return .blocked(code: code.rawValue, detail: detail)
            case .documentNotFound, .documentAlreadyExists,
                 .revisionConflict, .operationIDReused,
                 .pathConflict:
                return .conflict(code: code.rawValue, detail: detail)
            }
        }
    }
}

private enum DispatchErrorHandling {
    case retry(code: String, detail: String?)
    case conflict(code: String, detail: String?)
    case blocked(code: String, detail: String?)
}

struct SyncV2NetworkRecoveryDetector: Sendable {
    private var previousSatisfied: Bool?

    mutating func receive(isSatisfied: Bool) -> Bool {
        defer { previousSatisfied = isSatisfied }
        guard let previousSatisfied else {
            return false
        }
        return !previousSatisfied && isSatisfied
    }
}

final class SyncV2NetworkRecoveryMonitor: @unchecked Sendable {
    private let monitorFactory: () -> NWPathMonitor
    private let queue = DispatchQueue(
        label: "com.chocos.writerpad.sync-v2-network"
    )
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var recoveryDetector = SyncV2NetworkRecoveryDetector()
    private var recoveryHandler: (@Sendable () -> Void)?
    private var isRunning = false

    init(
        monitorFactory: @escaping () -> NWPathMonitor = {
            NWPathMonitor()
        }
    ) {
        self.monitorFactory = monitorFactory
    }

    func start(recoveryHandler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        let monitor = monitorFactory()
        isRunning = true
        self.monitor = monitor
        self.recoveryHandler = recoveryHandler
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.receive(path.status)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        recoveryHandler = nil
        recoveryDetector = SyncV2NetworkRecoveryDetector()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }

    private func receive(_ status: NWPath.Status) {
        let handler: (@Sendable () -> Void)?
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        let recovered = recoveryDetector.receive(
            isSatisfied: status == .satisfied
        )
        handler = recovered ? recoveryHandler : nil
        lock.unlock()
        handler?()
    }
}
