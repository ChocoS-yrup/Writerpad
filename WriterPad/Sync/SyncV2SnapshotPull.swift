import Combine
import Foundation

actor SyncV2OneShotRace<Value: Sendable> {
    private enum State {
        case waiting([CheckedContinuation<Value, Never>])
        case resolved(Value)
    }

    private var state: State = .waiting([])

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        guard case .waiting(let waiters) = state else { return false }
        state = .resolved(value)
        waiters.forEach { $0.resume(returning: value) }
        return true
    }

    func value() async -> Value {
        if case .resolved(let value) = state {
            return value
        }
        return await withCheckedContinuation { continuation in
            switch state {
            case .waiting(var waiters):
                waiters.append(continuation)
                state = .waiting(waiters)
            case .resolved(let value):
                continuation.resume(returning: value)
            }
        }
    }
}

typealias SyncV2GateTimeoutSleep =
    @Sendable (Duration) async throws -> Void

enum SyncV2DocumentMutationGateError: Error, Equatable, Sendable {
    case holdTimedOut
}

private enum SyncV2GateHoldOutcome: Sendable {
    case operationFinished
    case timedOut
}

/// Gate가 작업의 취소 협조 여부와 무관하게 정해진 시간 안에 보유권을
/// 반환하도록 하는 공통 상한이다. 시간 초과 뒤 작업은 취소만 요청하고
/// 기다리지 않아 다음 waiter에게 Gate를 넘길 수 있게 한다.
private func withSyncV2GateHoldLimit<
    Value: Sendable,
    TimeoutError: Error & Sendable
>(
    timeout: Duration,
    timeoutSleep: @escaping SyncV2GateTimeoutSleep,
    timeoutError: TimeoutError,
    timeoutDiagnosticName: String,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = SyncV2OneShotRace<SyncV2GateHoldOutcome>()
    let operationTask = Task {
        do {
            let value = try await operation()
            await race.resolve(.operationFinished)
            return value
        } catch {
            await race.resolve(.operationFinished)
            throw error
        }
    }
    let timeoutTask = Task {
        do {
            try await timeoutSleep(timeout)
            if await race.resolve(.timedOut) {
                SyncV2Diagnostics.raceTimedOut(timeoutDiagnosticName)
            }
        } catch {
            // 작업 완료 또는 상위 수명주기 종료가 먼저 끝났다.
        }
    }
    let outcome = await race.value()
    operationTask.cancel()
    timeoutTask.cancel()
    switch outcome {
    case .operationFinished:
        return try await operationTask.value
    case .timedOut:
        throw timeoutError
    }
}

/// 로컬 자동 저장과 서버 snapshot 적용이 같은 문서의 TXT를 동시에
/// 교체하지 않도록 하는 실행 중 전용 경계다.
/// 이 Gate 안의 operation이 반환하지 않으면 공유 인스턴스를 사용하는
/// 프로세스 전역 동기화가 멈추므로 보유 시간 상한을 제거하면 안 된다.
///
/// 폴더는 빈 경우 잠글 문서 UUID가 하나도 없다. 그래서 작품별
/// 구조 변경은 아래의 전용 키를 같이 잠그고, 문서 UUID와 충돌하지
/// 않도록 작품 UUID에서 다른 namespace로 파생한다.
func syncV2ProjectStructureMutationID(_ projectID: ProjectID) -> UUID {
    syncV2UUIDv5(
        namespace: projectID.rawValue,
        name: "writerpad-project-structure-mutation"
    )
}

actor SyncV2DocumentMutationGate {
    private var lockedDocumentIDs: Set<UUID> = []
    private var waiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]

    func withCriticalSection<Value: Sendable>(
        documentID: UUID,
        holdTimeout: Duration = SyncV2Timing.standard.gateHoldTimeout,
        timeoutSleep: @escaping SyncV2GateTimeoutSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire(documentID)
        defer { release(documentID) }
        try Task.checkCancellation()
        return try await withSyncV2GateHoldLimit(
            timeout: holdTimeout,
            timeoutSleep: timeoutSleep,
            timeoutError: SyncV2DocumentMutationGateError.holdTimedOut,
            timeoutDiagnosticName: "SyncV2DocumentMutationGate",
            operation: operation
        )
    }

    func withCriticalSections<Value: Sendable>(
        documentIDs: [UUID],
        holdTimeout: Duration = SyncV2Timing.standard.gateHoldTimeout,
        timeoutSleep: @escaping SyncV2GateTimeoutSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let identifiers = Array(Set(documentIDs)).sorted {
            $0.uuidString < $1.uuidString
        }
        return try await withCriticalSections(
            identifiers[...],
            holdTimeout: holdTimeout,
            timeoutSleep: timeoutSleep,
            operation: operation
        )
    }

    private func withCriticalSections<Value: Sendable>(
        _ documentIDs: ArraySlice<UUID>,
        holdTimeout: Duration,
        timeoutSleep: @escaping SyncV2GateTimeoutSleep,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let documentID = documentIDs.first else {
            return try await operation()
        }
        return try await withCriticalSection(
            documentID: documentID,
            holdTimeout: holdTimeout,
            timeoutSleep: timeoutSleep
        ) {
            try await self.withCriticalSections(
                documentIDs.dropFirst(),
                holdTimeout: holdTimeout,
                timeoutSleep: timeoutSleep,
                operation: operation
            )
        }
    }

    private func acquire(_ documentID: UUID) async {
        guard lockedDocumentIDs.contains(documentID) else {
            lockedDocumentIDs.insert(documentID)
            SyncV2Diagnostics.documentMutationGate(
                action: "acquire",
                documentID: documentID,
                waiters: waiters[documentID]?.count ?? 0
            )
            return
        }
        await withCheckedContinuation { continuation in
            waiters[documentID, default: []].append(continuation)
            SyncV2Diagnostics.documentMutationGate(
                action: "acquire-wait",
                documentID: documentID,
                waiters: waiters[documentID]?.count ?? 0
            )
        }
    }

    private func release(_ documentID: UUID) {
        guard var pending = waiters[documentID], !pending.isEmpty else {
            waiters[documentID] = nil
            lockedDocumentIDs.remove(documentID)
            SyncV2Diagnostics.documentMutationGate(
                action: "release",
                documentID: documentID,
                waiters: 0
            )
            return
        }
        let next = pending.removeFirst()
        waiters[documentID] = pending.isEmpty ? nil : pending
        SyncV2Diagnostics.documentMutationGate(
            action: "release-handoff",
            documentID: documentID,
            waiters: pending.count
        )
        next.resume()
    }
}

private final class SingleFlightTaskStorage: @unchecked Sendable {
    enum CompletionPolicy: Sendable {
        case clear
        case retainUntilCancelled
    }

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    var isScheduled: Bool {
        lock.withLock { task != nil }
    }

    func cancel() {
        let taskToCancel = lock.withLock {
            generation &+= 1
            defer { task = nil }
            return task
        }
        taskToCancel?.cancel()
    }

    func schedule(
        completionPolicy: CompletionPolicy,
        operation: @escaping @Sendable (
            _ finish: @escaping @Sendable () -> Void
        ) async -> Void
    ) {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return
        }
        generation &+= 1
        let taskGeneration = generation
        task = Task { [weak self] in
            let finish: @Sendable () -> Void = { [weak self] in
                self?.finish(generation: taskGeneration)
            }
            await operation(finish)
            if completionPolicy == .clear {
                finish()
            }
        }
        lock.unlock()
    }

    private func finish(generation taskGeneration: UInt64) {
        lock.withLock {
            guard generation == taskGeneration else { return }
            task = nil
        }
    }
}

@MainActor
struct SingleFlightTask {
    private let storage = SingleFlightTaskStorage()

    var isScheduled: Bool { storage.isScheduled }

    mutating func cancel() {
        storage.cancel()
    }

    mutating func schedule(
        operation: @escaping @MainActor @Sendable (
            _ finish: @escaping @Sendable () -> Void
        ) async -> Void
    ) {
        storage.schedule(completionPolicy: .clear) { finish in
            await operation(finish)
        }
    }
}

private struct ActorSingleFlightTask {
    private let storage = SingleFlightTaskStorage()

    var isScheduled: Bool { storage.isScheduled }

    mutating func cancel() {
        storage.cancel()
    }

    mutating func schedule(
        completionPolicy: SingleFlightTaskStorage.CompletionPolicy = .clear,
        operation: @escaping @Sendable (
            _ finish: @escaping @Sendable () -> Void
        ) async -> Void
    ) {
        storage.schedule(
            completionPolicy: completionPolicy,
            operation: operation
        )
    }
}

/// 열지 않은 작품의 서버 변경도 계속 받아오되, 열린 작품은 편집 보호를
/// 가진 `SyncV2WorkspaceSyncModel`에 맡긴다. 작품별 pull Task를 사용하므로
/// 한 작품의 지연이나 오류가 다른 작품을 기다리게 하지 않는다.
actor SyncV2BackgroundSyncCoordinator {
    private let puller: any SyncV2SnapshotPulling
    private let realtime: any SyncV2RealtimeTriggering
    private let projectBindingService: any ProjectBindingServicing
    private let authenticationService: (any AuthenticationServicing)?
    private let debounceDelay: Duration
    private let periodicDelay: Duration
    private let realtimeSubscriptionTimeout: Duration
    private let pullTimeout: Duration
    private let retryDelays: [Duration]
    private let sleep: SyncV2WorkspaceSleep
    private let realtimeTimeoutSleep: SyncV2WorkspaceSleep
    private let pullTimeoutSleep: SyncV2WorkspaceSleep

    private var isStarted = false
    private var activeLocalProjectID: ProjectID?
    private var pullTasks: [ProjectID: Task<Void, Never>] = [:]
    private var pullGenerations: [ProjectID: UInt64] = [:]
    private var pendingProjects = Set<ProjectID>()
    private var debounceTask = ActorSingleFlightTask()
    private var periodicTask = ActorSingleFlightTask()
    private var realtimeTask = ActorSingleFlightTask()
    private var reconnectTask = ActorSingleFlightTask()
    private var realtimeGeneration: UInt64 = 0
    private var reconnectAttempt = 0

    private func logTask(
        _ name: String,
        action: String,
        reason: String
    ) {
        SyncV2Diagnostics.task(
            scope: "background",
            name: name,
            action: action,
            reason: reason
        )
    }

    init(
        puller: any SyncV2SnapshotPulling,
        realtime: any SyncV2RealtimeTriggering,
        projectBindingService: any ProjectBindingServicing,
        authenticationService: (any AuthenticationServicing)? = nil,
        debounceDelay: Duration = SyncV2Timing.standard.debounceDelay,
        periodicDelay: Duration = SyncV2Timing.standard.periodicDelay,
        realtimeSubscriptionTimeout: Duration =
            SyncV2Timing.standard.realtimeSubscriptionTimeout,
        pullTimeout: Duration = SyncV2Timing.standard.pullTimeout,
        retryDelays: [Duration] = SyncV2Timing.standard.backoff,
        realtimeTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        pullTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        sleep: @escaping SyncV2WorkspaceSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.puller = puller
        self.realtime = realtime
        self.projectBindingService = projectBindingService
        self.authenticationService = authenticationService
        self.debounceDelay = debounceDelay
        self.periodicDelay = periodicDelay
        self.realtimeSubscriptionTimeout = realtimeSubscriptionTimeout
        self.pullTimeout = pullTimeout
        self.retryDelays = retryDelays
        self.realtimeTimeoutSleep = realtimeTimeoutSleep
        self.pullTimeoutSleep = pullTimeoutSleep
        self.sleep = sleep
    }

    func start() async {
        guard !isStarted, GlobalSyncPreference.isEnabled() else { return }
        isStarted = true
        startRealtime()
        startPeriodicPull()
        await pullInactiveProjects()
    }

    func stop() async {
        isStarted = false
        logTask("debounceTask", action: "cancel", reason: "stop")
        debounceTask.cancel()
        logTask("periodicTask", action: "cancel", reason: "stop")
        periodicTask.cancel()
        realtimeTask.cancel()
        logTask("reconnectTask", action: "cancel", reason: "stop")
        reconnectTask.cancel()
        pullTasks.values.forEach { $0.cancel() }
        logTask("debounceTask", action: "clear", reason: "stop")
        logTask("periodicTask", action: "clear", reason: "stop")
        logTask("reconnectTask", action: "clear", reason: "stop")
        pullTasks.removeAll()
        pullGenerations.removeAll()
        pendingProjects.removeAll()
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "background",
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "stop"
        )
        await realtime.stop()
    }

    func prioritizeProject(_ localProjectID: ProjectID?) async {
        let previous = activeLocalProjectID
        activeLocalProjectID = localProjectID
        if let localProjectID,
           let activePull = pullTasks.removeValue(
               forKey: localProjectID
           ) {
            activePull.cancel()
            pullGenerations[localProjectID, default: 0] &+= 1
        }
        guard isStarted, previous != localProjectID else { return }
        await pullInactiveProjects()
    }

    func appEnteredForeground() async {
        guard isStarted else { return }
        // 앱 최초 active 진입에서는 `start()`와 이 호출이 연달아 온다.
        // 진행 중인 phx_join을 stop/start하면 SDK 내부에 같은 topic의
        // 고아 join이 남아 이후 응답까지 가로막을 수 있다. scene inactive는
        // coordinator 자체를 stop하므로, 이미 시작된 foreground 경로에서는
        // 현재 구독 또는 재연결 task를 그대로 유지한다.
        if !realtimeTask.isScheduled, !reconnectTask.isScheduled {
            startRealtime()
        }
        await pullInactiveProjects()
    }

    private func startRealtime() {
        guard isStarted else { return }
        realtimeTask.cancel()
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "background",
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "startRealtime"
        )
        let generation = realtimeGeneration
        realtimeTask.schedule(
            completionPolicy: .retainUntilCancelled
        ) { [weak self] finish in
            guard let self else { return }
            let race = SyncV2RealtimeStartRace()
            let operation = Task {
                do {
                    try await self.realtime.startAll(
                        onChange: { [weak self] in
                            Task { await self?.realtimeChanged() }
                        },
                        onStatus: { [weak self] status in
                            Task {
                                await self?.receivedRealtimeStatus(
                                    status,
                                    generation: generation
                                )
                            }
                        }
                    )
                    await race.resolve(.completed)
                } catch {
                    await race.resolve(.failed)
                }
            }
            let timeout = self.realtimeSubscriptionTimeout
            let timeoutSleep = self.realtimeTimeoutSleep
            let watchdog = Task {
                do {
                    try await timeoutSleep(timeout)
                    if await race.resolve(.timedOut) {
                        SyncV2Diagnostics.raceTimedOut(
                            "SyncV2RealtimeStartRace"
                        )
                    }
                } catch {
                    // 정상 구독 또는 coordinator 종료가 먼저 끝났다.
                }
            }
            let outcome = await race.value()
            operation.cancel()
            watchdog.cancel()
            await self.realtimeStartFinished(
                outcome,
                generation: generation,
                finish: finish
            )
        }
    }

    private func realtimeStartFinished(
        _ outcome: SyncV2RealtimeStartOutcome,
        generation: UInt64,
        finish: @escaping @Sendable () -> Void
    ) async {
        guard isStarted,
              realtimeGeneration == generation
        else { return }
        switch outcome {
        case .completed:
            // 완료된 Task 참조는 foreground 중복 start를 막는 생존 표식이다.
            break
        case .failed:
            finish()
            await receivedRealtimeStatus(
                .channelError,
                generation: generation
            )
        case .timedOut:
            finish()
            await realtime.stop()
            guard isStarted,
                  realtimeGeneration == generation
            else { return }
            await receivedRealtimeStatus(
                .timedOut,
                generation: generation
            )
        }
    }

    private func receivedRealtimeStatus(
        _ status: SyncV2RealtimeConnectionStatus,
        generation: UInt64
    ) async {
        guard isStarted, realtimeGeneration == generation else { return }
        switch status {
        case .subscribed:
            reconnectAttempt = 0
            logTask(
                "reconnectTask",
                action: "cancel",
                reason: "realtime-subscribed"
            )
            reconnectTask.cancel()
            logTask(
                "reconnectTask",
                action: "clear",
                reason: "realtime-subscribed"
            )
            // 재구독 직후에는 debounce 없이 누락 구간을 바로 확인한다.
            await pullInactiveProjects()
        case .closed, .channelError, .timedOut:
            scheduleRealtimeReconnect()
        case .subscribing:
            break
        }
    }

    private func scheduleRealtimeReconnect() {
        guard !reconnectTask.isScheduled, isStarted else { return }
        let delay: Duration
        if retryDelays.isEmpty {
            delay = SyncV2Timing.standard.maximumBackoff
        } else {
            delay = retryDelays[
                min(reconnectAttempt, retryDelays.count - 1)
            ]
        }
        reconnectAttempt += 1
        logTask(
            "reconnectTask",
            action: "create",
            reason: "scheduleRealtimeReconnect"
        )
        reconnectTask.schedule { [weak self] finish in
            await self?.performRealtimeReconnect(
                after: delay,
                finish: finish
            )
        }
    }

    private func performRealtimeReconnect(
        after delay: Duration,
        finish: @escaping @Sendable () -> Void
    ) async {
        if let authenticationService {
            _ = await authenticationService.refreshSession(force: false)
        }
        do {
            try await sleep(delay)
            try Task.checkCancellation()
        } catch {
            return
        }
        guard isStarted else { return }
        logTask(
            "reconnectTask",
            action: "clear",
            reason: "performRealtimeReconnect"
        )
        finish()
        await realtime.stop()
        startRealtime()
    }

    private func realtimeChanged() {
        guard isStarted else { return }
        logTask(
            "debounceTask",
            action: "cancel",
            reason: "realtimeChanged"
        )
        debounceTask.cancel()
        let delay = debounceDelay
        let sleep = self.sleep
        logTask(
            "debounceTask",
            action: "create",
            reason: "realtimeChanged"
        )
        debounceTask.schedule { [weak self] _ in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.pullInactiveProjects()
        }
    }

    private func startPeriodicPull() {
        logTask(
            "periodicTask",
            action: "cancel",
            reason: "startPeriodicPull"
        )
        periodicTask.cancel()
        let delay = periodicDelay
        let sleep = self.sleep
        logTask(
            "periodicTask",
            action: "create",
            reason: "startPeriodicPull"
        )
        periodicTask.schedule { [weak self] _ in
            while !Task.isCancelled {
                do {
                    try await sleep(delay)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                await self?.pullInactiveProjects()
            }
        }
    }

    private func pullInactiveProjects() async {
        guard isStarted else { return }
        let bindings = await projectBindingService.connectedBindings()
        for binding in bindings {
            guard binding.localProjectID != activeLocalProjectID,
                  let serverProjectID = binding.serverProjectID
            else { continue }
            let localProjectID = binding.localProjectID
            if pullTasks[localProjectID] != nil {
                pendingProjects.insert(localProjectID)
                continue
            }
            startPull(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID
            )
        }
    }

    private func startPull(
        localProjectID: ProjectID,
        serverProjectID: UUID
    ) {
        pullGenerations[localProjectID, default: 0] &+= 1
        let pullGeneration = pullGenerations[localProjectID] ?? 0
        let puller = self.puller
        let timeout = pullTimeout
        let timeoutSleep = pullTimeoutSleep
        pullTasks[localProjectID] = Task { [weak self] in
            let race = SyncV2WorkspacePullRace()
            let operation = Task {
                do {
                    let report = try await puller.pull(
                        localProjectID: localProjectID,
                        serverProjectID: serverProjectID,
                        editingGuards: [:]
                    )
                    await race.resolve(.success(report))
                } catch let error as SyncV2ClientError {
                    await race.resolve(.clientError(error))
                } catch {
                    await race.resolve(
                        .failure(error.localizedDescription)
                    )
                }
            }
            let watchdog = Task {
                do {
                    try await timeoutSleep(timeout)
                    if await race.resolve(.timedOut) {
                        SyncV2Diagnostics.raceTimedOut(
                            "SyncV2WorkspacePullRace"
                        )
                    }
                } catch {
                    // 정상 pull 또는 coordinator 종료가 먼저 끝났다.
                }
            }
            _ = await race.value()
            operation.cancel()
            watchdog.cancel()
            await self?.pullFinished(
                localProjectID,
                serverProjectID: serverProjectID,
                generation: pullGeneration
            )
        }
    }

    private func pullFinished(
        _ localProjectID: ProjectID,
        serverProjectID: UUID,
        generation: UInt64
    ) {
        guard pullGenerations[localProjectID] == generation else { return }
        pullTasks[localProjectID] = nil
        guard isStarted,
              activeLocalProjectID != localProjectID,
              pendingProjects.remove(localProjectID) != nil
        else { return }
        startPull(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID
        )
    }
}

struct SyncV2WorkspaceState: Equatable, Sendable {
    enum Progress: Equatable, Sendable {
        case idle
        case pulling
        case checkingAuthentication
    }

    enum Connection: Equatable, Sendable {
        case unknown
        case healthy
        case reconnecting
        case offline
    }

    enum Result: Equatable, Sendable {
        case idle
        case localOnly
        case synced(at: Date)
        case waiting
        case authenticationRequired
        case automaticallyMerged
        case conflictRequired(detail: String)
        case structuralConflict(detail: String)
        /// 서버가 알린 구조 변경 중 일부를 일부러 적용하지 않았다.
        ///
        /// 실패가 아니라 의도한 안전 동작이다. 이름을 고쳐서 풀리는 상태도
        /// 아니고, 다시 시도해서 풀리는 상태도 아니다. 그래서
        /// `structuralConflict`와 같은 자리에 둘 수 없다. 저쪽 제목과 재시도
        /// 버튼이 이 상태에서는 전부 거짓이 된다.
        case notApplied(detail: String)
        /// 이 기기가 한 폴더 변경이 서버에 올라가지 못한 채 서 있다.
        ///
        /// 들어오는 변경을 적용하지 않은 `notApplied`와 방향이 반대다. 저쪽은
        /// 서버 것을 안 받은 것이고 이쪽은 내 것을 못 보낸 것이라, 같은 문장으로
        /// 말하면 둘 다 틀린다. 재시도로는 풀리지 않으므로 버튼을 달지 않는다.
        case notPublished(detail: String)
        case failed(detail: String)
    }

    var progress: Progress = .idle
    var connection: Connection = .healthy
    var lastResult: Result = .idle
}

typealias SyncV2WorkspaceSleep =
    @Sendable (Duration) async throws -> Void
typealias SyncV2WorkspaceDispatchRetry =
    @Sendable () async -> Void
/// 서버가 거절해 세워 둔 폴더 변경을 읽는다. 화면이 pull 결과만 보고 상태를
/// 정하므로, 이것이 없으면 나가는 쪽 굳음은 드러나지 않는다.
typealias SyncV2WorkspaceStalledFolderReader =
    @Sendable (ProjectID) async -> [SyncV2StalledFolderChange]

private actor SyncV2WorkspaceAuthenticationOutcome {
    private var state: AuthenticationState?
    private var continuations:
        [CheckedContinuation<AuthenticationState, Never>] = []

    func resolve(_ state: AuthenticationState) {
        guard self.state == nil else { return }
        self.state = state
        let waiters = continuations
        continuations.removeAll()
        waiters.forEach { $0.resume(returning: state) }
    }

    func value() async -> AuthenticationState {
        if let state { return state }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

private enum SyncV2WorkspacePullOutcome: Sendable {
    case success(SyncV2SnapshotPullReport)
    case clientError(SyncV2ClientError)
    case failure(String)
    case timedOut
}

private enum SyncV2RealtimeStartOutcome: Sendable {
    case completed
    case failed
    case timedOut
}

private typealias SyncV2RealtimeStartRace =
    SyncV2OneShotRace<SyncV2RealtimeStartOutcome>
private typealias SyncV2WorkspacePullRace =
    SyncV2OneShotRace<SyncV2WorkspacePullOutcome>

@MainActor
final class SyncV2WorkspaceSyncModel: ObservableObject {
    @Published private(set) var state = SyncV2WorkspaceState() {
        didSet {
            guard oldValue != state else { return }
            SyncV2Diagnostics.workspaceState(
                localProjectID: localProjectID,
                from: oldValue,
                to: state
            )
        }
    }

    private let localProjectID: ProjectID
    private let puller: (any SyncV2SnapshotPulling)?
    private let realtime: (any SyncV2RealtimeTriggering)?
    private let authenticationService: any AuthenticationServicing
    private let projectBindingService: any ProjectBindingServicing
    private let requestDispatchRetry: SyncV2WorkspaceDispatchRetry?
    private let readStalledFolderChanges:
        SyncV2WorkspaceStalledFolderReader?
    private let sleep: SyncV2WorkspaceSleep
    private let debounceDelay: Duration
    private let periodicDelay: Duration
    private let authenticationTimeout: Duration
    private let authenticationRetryDelay: Duration
    private let authenticationSleep: SyncV2WorkspaceSleep
    private let realtimeSubscriptionTimeout: Duration
    private let realtimeTimeoutSleep: SyncV2WorkspaceSleep
    private let pullTimeout: Duration
    private let pullTimeoutSleep: SyncV2WorkspaceSleep
    private let retryDelays: [Duration]
    private let realtimeHardResetAttemptThreshold: Int
    private let recoverySleep: SyncV2WorkspaceSleep
    private let networkMonitor: SyncV2NetworkRecoveryMonitor
    private var editingGuards:
        (@MainActor @Sendable () -> [UUID: SyncV2EditingGuard])?
    private var applyOpenSnapshots:
        (@MainActor @Sendable ([SyncV2RemoteDocumentSnapshot]) -> Void)?
    private var debounceTask = SingleFlightTask()
    private var periodicTask = SingleFlightTask()
    private var pullTask = SingleFlightTask()
    private var realtimeStartTask = SingleFlightTask()
    private var reconnectTask = SingleFlightTask()
    private var pullRetryTask = SingleFlightTask()
    private var authenticationCheckTask = SingleFlightTask()
    private var authenticationUpdateTask: Task<Void, Never>?
    private var bindingUpdateTask = SingleFlightTask()
    private var serverProjectID: UUID?
    private var isActive = false
    private var generation: UInt64 = 0
    private var realtimeGeneration: UInt64 = 0
    private var pullRequestID: UInt64 = 0
    private var authenticationCheckGeneration: UInt64 = 0
    private var authenticationCheckDeadline: ContinuousClock.Instant?
    private var authenticationCheckHasTimedOut = false
    private var quietProgressUntil: ContinuousClock.Instant?
    private var pullPending = false
    private var pullRetryAttempt = 0
    private var reconnectAttempt = 0
    private var lastSubscribedAt: ContinuousClock.Instant?
    private var realtimeHealthy = false
    private var hasRealtimeSubscribed = false

    private func logTask(
        _ name: String,
        action: String,
        reason: String
    ) {
        SyncV2Diagnostics.task(
            scope: "workspace",
            localProjectID: localProjectID,
            name: name,
            action: action,
            reason: reason
        )
    }

    init(
        localProjectID: ProjectID,
        puller: (any SyncV2SnapshotPulling)?,
        realtime: (any SyncV2RealtimeTriggering)?,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        requestDispatchRetry: SyncV2WorkspaceDispatchRetry? = nil,
        readStalledFolderChanges:
            SyncV2WorkspaceStalledFolderReader? = nil,
        debounceDelay: Duration = SyncV2Timing.standard.debounceDelay,
        // Realtime 누락에 대비한 저빈도 안전망이다. 실제 재연결 복구는
        // reachability 이벤트가 즉시 시작하므로 이 주기를 기다리지 않는다.
        periodicDelay: Duration = SyncV2Timing.standard.periodicDelay,
        authenticationTimeout: Duration =
            SyncV2Timing.standard.workspaceAuthenticationTimeout,
        authenticationRetryDelay: Duration =
            SyncV2Timing.standard.authenticationRetryDelay,
        realtimeSubscriptionTimeout: Duration =
            SyncV2Timing.standard.realtimeSubscriptionTimeout,
        pullTimeout: Duration = SyncV2Timing.standard.pullTimeout,
        retryDelays: [Duration] = SyncV2Timing.standard.backoff,
        realtimeHardResetAttemptThreshold: Int = 3,
        authenticationSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        networkMonitor: SyncV2NetworkRecoveryMonitor =
            SyncV2NetworkRecoveryMonitor(),
        realtimeTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        pullTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        recoverySleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        sleep: @escaping SyncV2WorkspaceSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.localProjectID = localProjectID
        self.puller = puller
        self.realtime = realtime
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.requestDispatchRetry = requestDispatchRetry
        self.readStalledFolderChanges = readStalledFolderChanges
        self.debounceDelay = debounceDelay
        self.periodicDelay = periodicDelay
        self.authenticationTimeout = authenticationTimeout
        self.authenticationRetryDelay = authenticationRetryDelay
        self.authenticationSleep = authenticationSleep
        self.realtimeSubscriptionTimeout = realtimeSubscriptionTimeout
        self.realtimeTimeoutSleep = realtimeTimeoutSleep
        self.pullTimeout = pullTimeout
        self.pullTimeoutSleep = pullTimeoutSleep
        self.retryDelays = retryDelays
        self.realtimeHardResetAttemptThreshold = max(
            1,
            realtimeHardResetAttemptThreshold
        )
        self.recoverySleep = recoverySleep
        self.networkMonitor = networkMonitor
        self.sleep = sleep
    }

    func start(
        sceneIsActive: Bool = true,
        editingGuards:
            @escaping @MainActor @Sendable
            () -> [UUID: SyncV2EditingGuard],
        applyOpenSnapshots:
            @escaping @MainActor @Sendable
            ([SyncV2RemoteDocumentSnapshot]) -> Void
    ) async {
        self.editingGuards = editingGuards
        self.applyOpenSnapshots = applyOpenSnapshots
        await updateSceneActivity(sceneIsActive)
    }

    func updateSceneActivity(_ active: Bool) async {
        guard active != isActive else { return }
        generation &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "generation",
            value: generation,
            reason: active ? "scene-active" : "scene-inactive"
        )
        isActive = active
        if active {
            await startAuthenticationObservation()
            networkMonitor.start { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.networkRecovered()
                }
            }
            startBindingObservation()
            await activate()
        } else {
            realtimeGeneration &+= 1
            SyncV2Diagnostics.generation(
                scope: "workspace",
                localProjectID: localProjectID,
                counter: "realtimeGeneration",
                value: realtimeGeneration,
                reason: "scene-inactive"
            )
            logTask("debounceTask", action: "cancel", reason: "scene-inactive")
            debounceTask.cancel()
            logTask("periodicTask", action: "cancel", reason: "scene-inactive")
            periodicTask.cancel()
            logTask("pullTask", action: "cancel", reason: "scene-inactive")
            pullTask.cancel()
            logTask("realtimeStartTask", action: "cancel", reason: "scene-inactive")
            realtimeStartTask.cancel()
            logTask("reconnectTask", action: "cancel", reason: "scene-inactive")
            reconnectTask.cancel()
            logTask("pullRetryTask", action: "cancel", reason: "scene-inactive")
            pullRetryTask.cancel()
            cancelAuthenticationCheck()
            authenticationUpdateTask?.cancel()
            bindingUpdateTask.cancel()
            logTask("debounceTask", action: "clear", reason: "scene-inactive")
            logTask("periodicTask", action: "clear", reason: "scene-inactive")
            logTask("pullTask", action: "clear", reason: "scene-inactive")
            logTask("realtimeStartTask", action: "clear", reason: "scene-inactive")
            logTask("reconnectTask", action: "clear", reason: "scene-inactive")
            logTask("pullRetryTask", action: "clear", reason: "scene-inactive")
            authenticationUpdateTask = nil
            pullPending = false
            networkMonitor.cancel()
            await realtime?.stop()
        }
    }

    func retry() async {
        await requestDispatchRetry?()
        await pullNow(forceVisibleProgress: true)
    }

    func stop() async {
        generation &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "generation",
            value: generation,
            reason: "stop"
        )
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "stop"
        )
        isActive = false
        logTask("debounceTask", action: "cancel", reason: "stop")
        debounceTask.cancel()
        logTask("periodicTask", action: "cancel", reason: "stop")
        periodicTask.cancel()
        logTask("pullTask", action: "cancel", reason: "stop")
        pullTask.cancel()
        logTask("realtimeStartTask", action: "cancel", reason: "stop")
        realtimeStartTask.cancel()
        logTask("reconnectTask", action: "cancel", reason: "stop")
        reconnectTask.cancel()
        logTask("pullRetryTask", action: "cancel", reason: "stop")
        pullRetryTask.cancel()
        cancelAuthenticationCheck()
        authenticationUpdateTask?.cancel()
        bindingUpdateTask.cancel()
        logTask("debounceTask", action: "clear", reason: "stop")
        logTask("periodicTask", action: "clear", reason: "stop")
        logTask("pullTask", action: "clear", reason: "stop")
        logTask("realtimeStartTask", action: "clear", reason: "stop")
        logTask("reconnectTask", action: "clear", reason: "stop")
        logTask("pullRetryTask", action: "clear", reason: "stop")
        authenticationUpdateTask = nil
        pullPending = false
        networkMonitor.cancel()
        await realtime?.stop()
    }

    func realtimeChanged() {
        scheduleDebouncedPull()
    }

    func networkRecovered() async {
        guard isActive else { return }
        // NWPath가 반복해서 흔들려도 사용자에게 보이는 12초 제한을
        // 초기화하지 않는다. 진행 중인 확인이 없을 때만 조용히 재시도한다.
        if !authenticationCheckTask.isScheduled {
            scheduleAuthenticationCheck()
        }
        logTask("reconnectTask", action: "cancel", reason: "networkRecovered")
        reconnectTask.cancel()
        logTask("reconnectTask", action: "clear", reason: "networkRecovered")
        if realtime != nil, serverProjectID != nil {
            realtimeHealthy = false
            state.connection = .reconnecting
            await realtime?.stop()
            startRealtime(reconnecting: true)
        }
        await pullNow(forceVisibleProgress: true)
    }

    private func activate() async {
        guard GlobalSyncPreference.isEnabled(),
              puller != nil else {
            state = SyncV2WorkspaceState(lastResult: .localOnly)
            return
        }
        let authentication = await authenticationService.currentState()
        guard isActive else { return }
        switch authentication {
        case .authenticated:
            cancelAuthenticationCheck()
            authenticationCheckHasTimedOut = false
        case .localOnly, .restoring:
            if !authenticationCheckHasTimedOut {
                state = SyncV2WorkspaceState(
                    progress: .checkingAuthentication
                )
            }
            scheduleAuthenticationCheck()
            return
        case .unavailable(.networkUnavailable):
            state = SyncV2WorkspaceState(connection: .offline)
            return
        case .signedOut, .unavailable:
            state = SyncV2WorkspaceState(
                lastResult: .authenticationRequired
            )
            return
        }
        guard let binding = await projectBindingService.currentBinding(
            for: localProjectID
        ), let serverProjectID = binding.serverProjectID else {
            state = SyncV2WorkspaceState(lastResult: .localOnly)
            return
        }
        guard isActive else { return }
        self.serverProjectID = serverProjectID
        if state.lastResult == .localOnly
            || state.lastResult == .authenticationRequired
        {
            state.lastResult = .idle
        }
        // 기존 pending operation을 먼저 dispatch해야 첫 pull이 단순
        // waiting이 아니라 자동 rebase/conflict 결과를 관찰할 수 있다.
        await requestDispatchRetry?()
        realtimeHealthy = realtime == nil
        hasRealtimeSubscribed = false
        startRealtime(reconnecting: false)
        startPeriodicPull()
        await pullNow(forceVisibleProgress: true)
    }

    private func startAuthenticationObservation() async {
        guard authenticationUpdateTask == nil, isActive else { return }
        let updates = await authenticationService.stateUpdates()
        guard isActive else { return }
        authenticationUpdateTask = Task { [weak self] in
            for await state in updates {
                guard !Task.isCancelled, let self, self.isActive else {
                    return
                }
                await self.authenticationChanged(state)
            }
        }
    }

    private func authenticationChanged(
        _ state: AuthenticationState
    ) async {
        guard isActive else { return }
        switch state {
        case .authenticated:
            await activate()
        case .restoring:
            if !authenticationCheckHasTimedOut {
                self.state = SyncV2WorkspaceState(
                    progress: .checkingAuthentication
                )
            }
            scheduleAuthenticationCheck()
        case .localOnly:
            await suspendCloudActivityForAuthentication(
                connection: .healthy,
                lastResult: .localOnly
            )
        case .signedOut:
            await suspendCloudActivityForAuthentication(
                connection: .healthy,
                lastResult: .authenticationRequired
            )
        case .unavailable(.networkUnavailable):
            await suspendCloudActivityForAuthentication(
                connection: .offline,
                lastResult: .idle
            )
        case .unavailable:
            await suspendCloudActivityForAuthentication(
                connection: .healthy,
                lastResult: .authenticationRequired
            )
        }
    }

    private func suspendCloudActivityForAuthentication(
        connection: SyncV2WorkspaceState.Connection,
        lastResult: SyncV2WorkspaceState.Result
    ) async {
        generation &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "generation",
            value: generation,
            reason: "authentication-state-change"
        )
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "authentication-state-change"
        )
        logTask(
            "debounceTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        debounceTask.cancel()
        logTask(
            "periodicTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        periodicTask.cancel()
        logTask(
            "pullTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        pullTask.cancel()
        logTask(
            "realtimeStartTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        realtimeStartTask.cancel()
        logTask(
            "reconnectTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        reconnectTask.cancel()
        logTask(
            "pullRetryTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        pullRetryTask.cancel()
        cancelAuthenticationCheck()
        logTask(
            "debounceTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        logTask(
            "periodicTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        logTask(
            "pullTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        logTask(
            "realtimeStartTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        logTask(
            "reconnectTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        logTask(
            "pullRetryTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        pullPending = false
        realtimeHealthy = false
        state = SyncV2WorkspaceState(
            connection: connection,
            lastResult: lastResult
        )
        await realtime?.stop()
    }

    private func scheduleAuthenticationCheck() {
        guard !authenticationCheckTask.isScheduled, isActive else { return }
        let clock = ContinuousClock()
        let deadline =
            authenticationCheckDeadline
            ?? clock.now.advanced(by: authenticationTimeout)
        authenticationCheckDeadline = deadline
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            authenticationCheckDeadline = nil
            authenticationCheckHasTimedOut = true
            state = SyncV2WorkspaceState(connection: .offline)
            scheduleAuthenticationRetry()
            return
        }
        authenticationCheckGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "authenticationCheckGeneration",
            value: authenticationCheckGeneration,
            reason: "scheduleAuthenticationCheck"
        )
        let requestGeneration = authenticationCheckGeneration
        let authenticationService = self.authenticationService
        let authenticationSleep = self.authenticationSleep
        authenticationCheckTask.schedule { [weak self] finish in
            guard let self else { return }
            let outcome = SyncV2WorkspaceAuthenticationOutcome()
            let restoreTask = Task {
                let state = await authenticationService.restoreSession()
                await outcome.resolve(state)
            }
            let timeoutTask = Task {
                do {
                    try await authenticationSleep(remaining)
                    await outcome.resolve(
                        .unavailable(.networkUnavailable)
                    )
                } catch {
                    // 인증 완료, scene 전환 또는 새 재연결 요청이 먼저 끝난 경로다.
                }
            }
            let state = await outcome.value()
            restoreTask.cancel()
            timeoutTask.cancel()
            guard !Task.isCancelled,
                  self.isActive,
                  self.authenticationCheckGeneration == requestGeneration
            else { return }
            switch state {
            case .authenticated:
                finish()
                self.authenticationCheckDeadline = nil
                await self.activate()
            case .unavailable(.networkUnavailable):
                self.authenticationCheckHasTimedOut = true
                self.state = SyncV2WorkspaceState(connection: .offline)
                finish()
                self.authenticationCheckDeadline = nil
                self.scheduleAuthenticationRetry()
            case .restoring:
                // 다른 복원 요청에 밀린 호출은 `.restoring`을 돌려줄 수 있다.
                // 즉시 재귀하면 응답이 계속 restoring일 때 busy loop가 되므로
                // 짧게 양보한 뒤, 이 scene의 최신 요청일 때만 다시 확인한다.
                do {
                    try await Task.sleep(
                        for: SyncV2Timing.standard
                            .authenticationRestoringYieldDelay
                    )
                } catch {
                    return
                }
                guard self.isActive,
                      self.authenticationCheckGeneration == requestGeneration
                else { return }
                finish()
                self.scheduleAuthenticationCheck()
            case .localOnly:
                finish()
                self.authenticationCheckDeadline = nil
                self.authenticationCheckHasTimedOut = false
                self.state = SyncV2WorkspaceState(
                    lastResult: .localOnly
                )
            case .signedOut, .unavailable:
                finish()
                self.authenticationCheckDeadline = nil
                self.authenticationCheckHasTimedOut = false
                self.state = SyncV2WorkspaceState(
                    lastResult: .authenticationRequired
                )
            }
        }
    }

    private func scheduleAuthenticationRetry() {
        guard !authenticationCheckTask.isScheduled, isActive else { return }
        authenticationCheckGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "authenticationCheckGeneration",
            value: authenticationCheckGeneration,
            reason: "scheduleAuthenticationRetry"
        )
        let requestGeneration = authenticationCheckGeneration
        let delay = authenticationRetryDelay
        authenticationCheckTask.schedule { [weak self] finish in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.isActive,
                  self.authenticationCheckGeneration == requestGeneration
            else { return }
            finish()
            self.scheduleAuthenticationCheck()
        }
    }

    private func cancelAuthenticationCheck() {
        authenticationCheckGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "authenticationCheckGeneration",
            value: authenticationCheckGeneration,
            reason: "cancelAuthenticationCheck"
        )
        authenticationCheckTask.cancel()
        authenticationCheckDeadline = nil
    }

    private func startBindingObservation() {
        guard !bindingUpdateTask.isScheduled else { return }
        let service = projectBindingService
        let localProjectID = self.localProjectID
        bindingUpdateTask.schedule { [weak self] _ in
            let updates = await service.bindingUpdates(
                for: localProjectID
            )
            for await binding in updates {
                guard !Task.isCancelled, let self, self.isActive else {
                    return
                }
                await self.bindingChanged(binding)
            }
        }
    }

    private func bindingChanged(
        _ binding: ProjectSyncBinding?
    ) async {
        guard isActive else { return }
        guard let serverProjectID = binding?.serverProjectID else {
            self.serverProjectID = nil
            logTask("debounceTask", action: "cancel", reason: "bindingRemoved")
            debounceTask.cancel()
            logTask("periodicTask", action: "cancel", reason: "bindingRemoved")
            periodicTask.cancel()
            logTask("pullTask", action: "cancel", reason: "bindingRemoved")
            pullTask.cancel()
            logTask("realtimeStartTask", action: "cancel", reason: "bindingRemoved")
            realtimeStartTask.cancel()
            logTask("reconnectTask", action: "cancel", reason: "bindingRemoved")
            reconnectTask.cancel()
            logTask("pullRetryTask", action: "cancel", reason: "bindingRemoved")
            pullRetryTask.cancel()
            logTask("debounceTask", action: "clear", reason: "bindingRemoved")
            logTask("periodicTask", action: "clear", reason: "bindingRemoved")
            logTask("realtimeStartTask", action: "clear", reason: "bindingRemoved")
            logTask("reconnectTask", action: "clear", reason: "bindingRemoved")
            logTask("pullRetryTask", action: "clear", reason: "bindingRemoved")
            realtimeGeneration &+= 1
            SyncV2Diagnostics.generation(
                scope: "workspace",
                localProjectID: localProjectID,
                counter: "realtimeGeneration",
                value: realtimeGeneration,
                reason: "bindingRemoved"
            )
            await realtime?.stop()
            state = SyncV2WorkspaceState(lastResult: .localOnly)
            return
        }
        guard self.serverProjectID != serverProjectID else { return }
        self.serverProjectID = nil
        logTask("pullTask", action: "cancel", reason: "bindingChanged")
        pullTask.cancel()
        logTask("realtimeStartTask", action: "cancel", reason: "bindingChanged")
        realtimeStartTask.cancel()
        logTask("reconnectTask", action: "cancel", reason: "bindingChanged")
        reconnectTask.cancel()
        logTask("pullRetryTask", action: "cancel", reason: "bindingChanged")
        pullRetryTask.cancel()
        logTask("realtimeStartTask", action: "clear", reason: "bindingChanged")
        logTask("reconnectTask", action: "clear", reason: "bindingChanged")
        logTask("pullRetryTask", action: "clear", reason: "bindingChanged")
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "bindingChanged"
        )
        await realtime?.stop()
        await activate()
    }

    private func startRealtime(reconnecting: Bool) {
        guard isActive,
              let realtime,
              let serverProjectID
        else { return }
        logTask(
            "realtimeStartTask",
            action: "cancel",
            reason: "startRealtime"
        )
        realtimeStartTask.cancel()
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: reconnecting ? "startRealtime-reconnect" : "startRealtime-initial"
        )
        let requestGeneration = realtimeGeneration
        realtimeHealthy = false
        state.connection = reconnecting
            ? .reconnecting
            : .unknown
        logTask(
            "realtimeStartTask",
            action: "create",
            reason: reconnecting
                ? "startRealtime-reconnect"
                : "startRealtime-initial"
        )
        realtimeStartTask.schedule { [weak self] _ in
            guard let self else { return }
            let race = SyncV2RealtimeStartRace()
            let operation = Task {
                do {
                    try await realtime.start(
                        projectID: serverProjectID,
                        onChange: { [weak self] in
                            Task { @MainActor in
                                guard let self,
                                      self.realtimeGeneration
                                        == requestGeneration
                                else { return }
                                self.realtimeChanged()
                            }
                        },
                        onStatus: { [weak self] status in
                            Task { @MainActor in
                                self?.receivedRealtimeStatus(
                                    status,
                                    generation: requestGeneration
                                )
                            }
                        }
                    )
                    await race.resolve(.completed)
                } catch {
                    await race.resolve(.failed)
                }
            }
            let timeout = realtimeSubscriptionTimeout
            let timeoutSleep = realtimeTimeoutSleep
            let watchdog = Task {
                do {
                    try await timeoutSleep(timeout)
                    if await race.resolve(.timedOut) {
                        SyncV2Diagnostics.raceTimedOut(
                            "SyncV2RealtimeStartRace"
                        )
                    }
                } catch {
                    // 구독 완료, generation 교체 또는 scene 종료가 먼저 끝났다.
                }
            }
            let outcome = await race.value()
            operation.cancel()
            watchdog.cancel()
            guard isActive,
                  realtimeGeneration == requestGeneration
            else { return }
            logTask(
                "realtimeStartTask",
                action: "clear",
                reason: "realtimeStart-finished"
            )
            switch outcome {
            case .completed:
                break
            case .failed:
                receivedRealtimeStatus(
                    .channelError,
                    generation: requestGeneration
                )
            case .timedOut:
                // SDK subscribeWithError 자체가 영구 대기하더라도 actor의
                // reentrancy를 이용해 in-flight join을 명시적으로 취소한다.
                await realtime.stop()
                guard isActive,
                      realtimeGeneration == requestGeneration
                else { return }
                receivedRealtimeStatus(
                    .timedOut,
                    generation: requestGeneration
                )
            }
        }
    }

    private func receivedRealtimeStatus(
        _ status: SyncV2RealtimeConnectionStatus,
        generation requestGeneration: UInt64
    ) {
        guard isActive,
              realtimeGeneration == requestGeneration
        else { return }
        switch status {
        case .subscribing:
            realtimeHealthy = false
            state.connection = realtimeProgressConnection
        case .subscribed:
            realtimeHealthy = true
            hasRealtimeSubscribed = true
            lastSubscribedAt = ContinuousClock().now
            logTask(
                "reconnectTask",
                action: "cancel",
                reason: "realtime-subscribed"
            )
            reconnectTask.cancel()
            logTask(
                "reconnectTask",
                action: "clear",
                reason: "realtime-subscribed"
            )
            state.connection = .healthy
            Task { @MainActor [weak self] in
                // 재구독 직후 이벤트를 기다리지 않고 누락 snapshot을 확인한다.
                await self?.pullNow(forceVisibleProgress: true)
            }
        case .closed, .channelError, .timedOut:
            let terminalReason: String
            switch status {
            case .closed:
                terminalReason = "closed"
            case .channelError:
                terminalReason = "channel-error"
            case .timedOut:
                terminalReason = "timed-out"
            case .subscribing, .subscribed:
                terminalReason = "non-terminal"
            }
            logTask(
                "realtimeConnection",
                action: "terminal",
                reason: terminalReason
            )
            let now = ContinuousClock().now
            if let lastSubscribedAt,
               lastSubscribedAt.duration(to: now)
                >= SyncV2Timing.standard.stableSubscriptionResetInterval
            {
                reconnectAttempt = 0
            }
            lastSubscribedAt = nil
            realtimeHealthy = false
            state.connection = .reconnecting
            scheduleRealtimeReconnect()
        }
    }

    private var realtimeProgressConnection:
        SyncV2WorkspaceState.Connection {
        // 최초 연결만 "확인 중"이다. 한 번도 subscribed 되지 못했더라도
        // terminal 상태 뒤 backoff 재시도를 시작했다면 실제 수명주기 상태는
        // "재연결 중"이며, 뒤늦은 subscribing callback이 이를 되돌리면 안 된다.
        hasRealtimeSubscribed || reconnectAttempt > 0
            ? .reconnecting
            : .unknown
    }

    private func scheduleRealtimeReconnect() {
        guard !reconnectTask.isScheduled,
              isActive,
              realtime != nil,
              serverProjectID != nil
        else { return }
        let index = min(
            reconnectAttempt,
            max(0, retryDelays.count - 1)
        )
        let delay = retryDelays.isEmpty
            ? SyncV2Timing.standard.maximumBackoff
            : retryDelays[index]
        reconnectAttempt += 1
        let sleep = recoverySleep
        logTask(
            "reconnectTask",
            action: "create",
            reason: "scheduleRealtimeReconnect"
        )
        reconnectTask.schedule { [weak self] finish in
            let didSleep: Bool
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                didSleep = true
            } catch {
                didSleep = false
            }
            guard let self else { return }
            self.logTask(
                "reconnectTask",
                action: "clear",
                reason: didSleep
                    ? "reconnect-delay-finished"
                    : "reconnect-delay-cancelled"
            )
            finish()
            guard didSleep, self.isActive else { return }
            _ = await self.authenticationService.refreshSession(force: false)
            await self.realtime?.stop()
            if self.reconnectAttempt
                >= self.realtimeHardResetAttemptThreshold {
                self.logTask(
                    "realtimeConnection",
                    action: "reset",
                    reason: "rapid-terminal-statuses"
                )
                await self.realtime?.resetConnection()
                self.reconnectAttempt = 0
            }
            self.startRealtime(reconnecting: true)
        }
    }

    private func scheduleDebouncedPull() {
        guard isActive else { return }
        logTask(
            "debounceTask",
            action: "cancel",
            reason: "scheduleDebouncedPull"
        )
        debounceTask.cancel()
        let delay = debounceDelay
        let sleep = sleep
        logTask(
            "debounceTask",
            action: "create",
            reason: "scheduleDebouncedPull"
        )
        debounceTask.schedule { [weak self] _ in
            do {
                try await sleep(delay)
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.pullNow()
        }
    }

    private func startPeriodicPull() {
        logTask(
            "periodicTask",
            action: "cancel",
            reason: "startPeriodicPull"
        )
        periodicTask.cancel()
        let delay = periodicDelay
        let sleep = sleep
        logTask(
            "periodicTask",
            action: "create",
            reason: "startPeriodicPull"
        )
        periodicTask.schedule { [weak self] _ in
            while !Task.isCancelled {
                do {
                    try await sleep(delay)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                await self?.pullNow()
            }
        }
    }

    private func pullNow(
        forceVisibleProgress: Bool = false
    ) async {
        guard isActive, let puller, let serverProjectID else { return }
        if pullTask.isScheduled {
            pullPending = true
            return
        }
        logTask(
            "pullRetryTask",
            action: "cancel",
            reason: "pullNow-start"
        )
        pullRetryTask.cancel()
        logTask(
            "pullRetryTask",
            action: "clear",
            reason: "pullNow-start"
        )
        let now = ContinuousClock().now
        let isQuietFollowUp =
            !forceVisibleProgress
            && quietProgressUntil.map { now < $0 } == true
            && {
                if case .synced = state.lastResult { return true }
                return false
            }()
        if !isQuietFollowUp {
            state.progress = .pulling
        }
        let guards = editingGuards?() ?? [:]
        let localProjectID = self.localProjectID
        let generation = self.generation
        pullRequestID &+= 1
        SyncV2Diagnostics.generation(
            scope: "workspace",
            localProjectID: localProjectID,
            counter: "pullRequestID",
            value: pullRequestID,
            reason: "pullNow"
        )
        let requestID = pullRequestID
        logTask(
            "pullTask",
            action: "create",
            reason: "pullNow-start"
        )
        pullTask.schedule { [weak self] finish in
            guard let self else { return }
            let outcome = await self.performPullWithAuthenticationRetry(
                puller: puller,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                editingGuards: guards
            )
            await self.finishPull(
                outcome,
                requestID: requestID,
                generation: generation,
                finish: finish
            )
        }
    }

    private func performPullWithAuthenticationRetry(
        puller: any SyncV2SnapshotPulling,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async -> SyncV2WorkspacePullOutcome {
        var didRefresh = false
        while true {
            let outcome = await performWatchdogPull(
                puller: puller,
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                editingGuards: editingGuards
            )
            guard !didRefresh,
                  case .clientError(
                    .remote(code: .authRequired, detail: _)
                  ) = outcome
            else { return outcome }
            didRefresh = true
            let state = await refreshWithTimeout()
            guard state.isAuthenticated else { return outcome }
            // 회전된 토큰을 Keychain과 Supabase client에 반영한 뒤 원래
            // snapshot 요청만 정확히 한 번 재시도한다.
        }
    }

    private func refreshWithTimeout() async -> AuthenticationState {
        let outcome = SyncV2WorkspaceAuthenticationOutcome()
        let authenticationService = self.authenticationService
        let refreshTask = Task {
            let state = await authenticationService.refreshSession(
                force: true
            )
            await outcome.resolve(state)
        }
        let timeout = pullTimeout
        let timeoutSleep = pullTimeoutSleep
        let timeoutTask = Task {
            do {
                try await timeoutSleep(timeout)
                await outcome.resolve(
                    .unavailable(.networkUnavailable)
                )
            } catch {
                // refresh 완료 또는 scene 종료가 먼저 끝났다.
            }
        }
        let state = await outcome.value()
        refreshTask.cancel()
        timeoutTask.cancel()
        return state
    }

    private func performWatchdogPull(
        puller: any SyncV2SnapshotPulling,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async -> SyncV2WorkspacePullOutcome {
        let race = SyncV2WorkspacePullRace()
        let operation = Task {
            do {
                let report = try await puller.pull(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editingGuards: editingGuards
                )
                await race.resolve(.success(report))
            } catch let error as SyncV2ClientError {
                await race.resolve(.clientError(error))
            } catch {
                await race.resolve(.failure(error.localizedDescription))
            }
        }
        let timeout = pullTimeout
        let timeoutSleep = pullTimeoutSleep
        let watchdog = Task {
            do {
                try await timeoutSleep(timeout)
                if await race.resolve(.timedOut) {
                    SyncV2Diagnostics.raceTimedOut(
                        "SyncV2WorkspacePullRace"
                    )
                }
            } catch {
                // 정상 완료 또는 scene 종료가 먼저 끝났다.
            }
        }
        let outcome = await race.value()
        operation.cancel()
        watchdog.cancel()
        return outcome
    }

    private func finishPull(
        _ outcome: SyncV2WorkspacePullOutcome,
        requestID: UInt64,
        generation requestGeneration: UInt64,
        finish: @escaping @Sendable () -> Void
    ) async {
        guard pullRequestID == requestID else { return }
        logTask(
            "pullTask",
            action: "clear",
            reason: "finishPull"
        )
        finish()
        guard generation == requestGeneration, isActive else {
            pullPending = false
            state.progress = .idle
            return
        }
        // 나가는 쪽이 굳었는지는 pull 보고서에 없다. 화면을 정하기 직전에
        // 대기열에서 읽어 와야 "동기화됨"이 거짓이 되지 않는다.
        let stalled = await readStalledFolderChanges?(localProjectID) ?? []
        switch outcome {
        case .success(let report):
            pullRetryAttempt = 0
            complete(report, stalled: stalled)
        case .clientError(let error):
            complete(error)
            schedulePullRetry()
        case .failure(let detail):
            completeFailure(detail)
            schedulePullRetry()
        case .timedOut:
            complete(.timedOut)
            schedulePullRetry()
        }

        if pullPending {
            pullPending = false
            await pullNow()
        }
    }

    private func schedulePullRetry() {
        guard !pullRetryTask.isScheduled, isActive else { return }
        let index = min(
            pullRetryAttempt,
            max(0, retryDelays.count - 1)
        )
        let delay = retryDelays.isEmpty
            ? SyncV2Timing.standard.maximumBackoff
            : retryDelays[index]
        pullRetryAttempt += 1
        let sleep = recoverySleep
        logTask(
            "pullRetryTask",
            action: "create",
            reason: "schedulePullRetry"
        )
        pullRetryTask.schedule { [weak self] finish in
            let didSleep: Bool
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                didSleep = true
            } catch {
                didSleep = false
            }
            guard let self else { return }
            self.logTask(
                "pullRetryTask",
                action: "clear",
                reason: didSleep
                    ? "pullRetry-delay-finished"
                    : "pullRetry-delay-cancelled"
            )
            finish()
            guard didSleep, self.isActive else { return }
            await self.pullNow()
        }
    }

    /// 이름을 고치면 풀리는 항목만 고른다.
    private static func unusableName(
        in report: SyncV2SnapshotPullReport
    ) -> SyncV2RejectedStructureName? {
        report.rejectedStructureNames.first { $0.kind == .unusableName }
    }

    /// 이름 문제가 아니어서 적용하지 않은 항목만 고른다.
    private static func notAppliedItem(
        in report: SyncV2SnapshotPullReport
    ) -> SyncV2RejectedStructureName? {
        report.rejectedStructureNames.first { $0.kind == .notApplied }
    }

    private static func notAppliedCount(
        in report: SyncV2SnapshotPullReport
    ) -> Int {
        report.rejectedStructureNames.filter { $0.kind == .notApplied }.count
    }

    private func complete(
        _ report: SyncV2SnapshotPullReport,
        stalled: [SyncV2StalledFolderChange] = []
    ) {
        if !report.appliedSnapshots.isEmpty {
            applyOpenSnapshots?(report.appliedSnapshots)
        }
        let mergeOutcomes = report.outcomes.compactMap {
            if case let .mergeRequired(_, _, reason) = $0 {
                return reason
            }
            return nil
        }
        let lastResult: SyncV2WorkspaceState.Result
        if mergeOutcomes.contains(.unresolvedConflict) {
            lastResult = .conflictRequired(
                detail: "본문 변경이 겹쳐 원본과 병합 후보를 보존했습니다."
            )
        } else if mergeOutcomes.contains(.blockedOperation) {
            lastResult = .failed(
                detail: "서버가 저장 작업을 거부했습니다. 로그인 계정과 작품 접근 권한을 확인한 뒤 다시 시도하세요. 로컬 TXT는 보존되어 있습니다."
            )
        } else if mergeOutcomes.contains(
            .pathOccupiedByDifferentDocument
        ) {
            lastResult = .structuralConflict(
                detail: "서버 문서의 새 제목과 같은 경로를 다른 로컬 문서가 사용 중입니다. 로컬 TXT는 덮어쓰지 않았습니다."
            )
        } else if mergeOutcomes.contains(.invalidLocalHierarchy) {
            // 무엇을 고쳐야 하는지 알려주지 않으면 사용자는 이 상태에서
            // 빠져나올 수 없다. 실기기에서 폴더 이름 끝의 공백 하나로 구조
            // 동기화가 멈췄고, 화면에는 원인이 드러나지 않았다. 이름을 알아낸
            // 경우에는 그 이름을 그대로 보여준다.
            //
            // 이름 문제인 항목만 고른다. 목록에는 이름과 무관한 거부도 함께
            // 들어 있고, 그것을 이 문장에 끼우면 사용자가 손댈 필요 없는
            // 이름을 고치러 간다.
            lastResult = .structuralConflict(
                detail: Self.unusableName(in: report).map { rejected in
                    """
                    \(rejected.parent) 안의 '\(rejected.name)' \
                    이름을 iPad에 적용할 수 없습니다. \
                    \(rejected.reason) \
                    보낸 기기에서 이 이름을 고친 뒤 다시 동기화해 주세요. \
                    로컬 TXT는 덮어쓰지 않았습니다.
                    """
                } ?? "서버의 폴더나 문서 제목 중 iPad에서 쓸 수 없는 이름이 있어 구조를 적용하지 못했습니다. 이름 끝의 공백과 마침표를 지우고 < > : \" / \\ | ? * 문자를 뺀 뒤 다시 동기화해 주세요. 로컬 TXT는 덮어쓰지 않았습니다."
            )
        } else if let stalledChange = stalled.first {
            // 사용자가 한 조작이 서버에 없는데 화면이 조용하면 그것도 거짓이다.
            // 이름을 고치라고 단정하지 않는다 — 코드마다 할 일이 다르다.
            let others = stalled.count - 1
            let tail = others > 0 ? " 외 \(others)건." : ""
            lastResult = .notPublished(
                detail: """
                '\(stalledChange.name)' 폴더 변경이 서버에 올라가지 \
                못했습니다. (\(stalledChange.errorCode))\(tail) \
                로컬 TXT는 그대로입니다.
                """
            )
        } else if let skipped = Self.notAppliedItem(in: report) {
            // 덮어쓰지 않으려고 적용하지 않은 항목이다. 아무 일도 없었던 것처럼
            // 끝나면 사용자는 서버와 화면이 다른 이유를 알 수 없다. 이름을
            // 고치라고도, 다시 시도하라고도 하지 않는다.
            let others = Self.notAppliedCount(in: report) - 1
            let tail = others > 0 ? " 외 \(others)건." : ""
            lastResult = .notApplied(
                detail: """
                \(skipped.parent) 안의 '\(skipped.name)'을(를) \
                적용하지 않았습니다. \(skipped.reason).\(tail) \
                로컬 TXT는 그대로입니다.
                """
            )
        } else if !mergeOutcomes.isEmpty {
            lastResult = .waiting
        } else {
            lastResult = .synced(at: Date())
        }
        var completedState = state
        completedState.progress = .idle
        completedState.lastResult = lastResult
        if realtimeHealthy {
            completedState.connection = .healthy
        }
        state = completedState
        quietProgressUntil = ContinuousClock().now.advanced(
            by: SyncV2Timing.standard.quietProgressInterval
        )
    }

    private func complete(_ error: SyncV2ClientError) {
        var completedState = state
        completedState.progress = .idle
        switch error {
        case .networkUnavailable, .timedOut:
            completedState.connection = .offline
        case .remote(code: .authRequired, detail: _):
            completedState.lastResult = .authenticationRequired
        default:
            completedState.lastResult = .failed(
                detail: Self.detail(for: error)
            )
        }
        state = completedState
    }

    private func completeFailure(_ detail: String) {
        var completedState = state
        completedState.progress = .idle
        completedState.lastResult = .failed(detail: detail)
        state = completedState
    }

    private static func detail(for error: SyncV2ClientError) -> String {
        switch error {
        case let .remote(code, detail):
            detail ?? code.rawValue
        case .networkUnavailable:
            "네트워크에 연결할 수 없습니다."
        case .timedOut:
            "서버 응답 시간이 초과되었습니다."
        case .invalidResponse:
            "서버 snapshot 응답을 검증하지 못했습니다."
        case let .serverRejected(rejection):
            rejection.detail ?? rejection.message
        }
    }
}

/// Supabase realtime 연결 시작을 프로세스 전체에서 직렬화하는 Gate다.
/// 이 Gate 안의 operation이 반환하지 않으면 프로세스 전역 realtime 시작이
/// 멈추므로 보유 시간 상한을 제거하면 안 된다.
actor SyncV2RealtimeConnectGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withSubscription(
        timeout: Duration = SyncV2Timing.standard.gateHoldTimeout,
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            duration in
            try await ContinuousClock().sleep(for: duration)
        },
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await withSyncV2GateHoldLimit(
            timeout: timeout,
            timeoutSleep: timeoutSleep,
            timeoutError: SyncV2RealtimeTriggerError.subscriptionTimedOut,
            timeoutDiagnosticName: "SyncV2RealtimeStartRace",
            operation: operation
        )
    }

    private func acquire() async {
        guard isHeld else {
            isHeld = true
            SyncV2Diagnostics.realtimeConnectGate(
                action: "acquire",
                isHeld: isHeld,
                waiters: waiters.count
            )
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            SyncV2Diagnostics.realtimeConnectGate(
                action: "acquire-wait",
                isHeld: isHeld,
                waiters: waiters.count
            )
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            SyncV2Diagnostics.realtimeConnectGate(
                action: "release",
                isHeld: isHeld,
                waiters: waiters.count
            )
            return
        }
        waiters.removeFirst().resume()
        SyncV2Diagnostics.realtimeConnectGate(
            action: "release-handoff",
            isHeld: isHeld,
            waiters: waiters.count
        )
    }
}
