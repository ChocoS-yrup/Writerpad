import Foundation
import OSLog

let syncV2Logger = Logger(
    subsystem: "com.chocos.writerpad",
    category: "sync-v2"
)

enum SyncV2Diagnostics {
    static func workspaceState(
        localProjectID: ProjectID,
        from oldValue: SyncV2WorkspaceState,
        to newValue: SyncV2WorkspaceState
    ) {
        syncV2Logger.info(
            "event=workspaceState localProjectID=\(localProjectID.rawValue.uuidString, privacy: .public) from=\(oldValue.logName, privacy: .public) to=\(newValue.logName, privacy: .public)"
        )
        SyncV2PullDiagnostics.record(
            stage: "ui-state",
            phase: newValue.logName
        )
    }

    static func generation(
        scope: String,
        localProjectID: ProjectID? = nil,
        counter: String,
        value: UInt64,
        reason: String
    ) {
        syncV2Logger.info(
            "event=generation scope=\(scope, privacy: .public) localProjectID=\(localProjectID?.rawValue.uuidString ?? "none", privacy: .public) counter=\(counter, privacy: .public) value=\(value, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    /// 구조 동기화가 막히면 사용자에게는 "적용할 수 없습니다"만 보인다. 어떤
    /// 이름이 왜 거부됐는지는 여기서만 알 수 있으므로 이름을 그대로 남긴다.
    /// 폴더 이름은 작품 내용이 아니라 구조 정보다.
    static func rejectedStructureName(
        _ name: String,
        parent: String,
        reason: String
    ) {
        syncV2Logger.error(
            "event=rejectedStructureName name=\(name, privacy: .public) parent=\(parent, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    /// 재시도로는 풀리지 않아 세워 둔 폴더 작업이다.
    ///
    /// 이 줄은 서 있는 상태 하나를 가리킨다. 세워 둔 작업은 다시 claim되지
    /// 않으므로 한 상태에 한 줄만 남는다. operation_id는 일부러 싣지 않는다.
    /// 그것까지 넣으면 사용자가 같은 조작을 다시 시도할 때마다 서로 다른 줄이
    /// 되어, 하나의 상태가 여러 사건처럼 보인다.
    static func stalledFolderOperation(
        folderID: UUID,
        parentFolderID: UUID?,
        name: String,
        code: String
    ) {
        syncV2Logger.error(
            "event=stalledFolderOperation folderID=\(folderID.uuidString, privacy: .public) parentFolderID=\(parentFolderID?.uuidString ?? "none", privacy: .public) name=\(name, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    static func task(
        scope: String,
        localProjectID: ProjectID? = nil,
        name: String,
        action: String,
        reason: String
    ) {
        syncV2Logger.info(
            "event=task scope=\(scope, privacy: .public) localProjectID=\(localProjectID?.rawValue.uuidString ?? "none", privacy: .public) task=\(name, privacy: .public) action=\(action, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    static func raceTimedOut(_ race: String) {
        syncV2Logger.warning(
            "event=raceTimedOut race=\(race, privacy: .public)"
        )
    }

    static func realtimeConnectGate(
        action: String,
        isHeld: Bool,
        waiters: Int
    ) {
        syncV2Logger.info(
            "event=realtimeConnectGate action=\(action, privacy: .public) isHeld=\(isHeld, privacy: .public) waiters=\(waiters, privacy: .public)"
        )
    }

    static func documentMutationGate(
        action: String,
        documentID: UUID,
        waiters: Int
    ) {
        syncV2Logger.info(
            "event=documentMutationGate action=\(action, privacy: .public) documentID=\(documentID.uuidString, privacy: .public) waiters=\(waiters, privacy: .public)"
        )
    }

    static func supersededAuthOperation(
        operationID: UUID,
        activeOperationID: UUID?
    ) {
        syncV2Logger.warning(
            "event=authOperationSuperseded operationID=\(operationID.uuidString, privacy: .public) activeOperationID=\(activeOperationID?.uuidString ?? "none", privacy: .public)"
        )
    }
}

struct SyncV2PullDiagnosticEvent: Equatable, Sendable {
    let pullID: UUID
    let origin: String
    let stage: String
    let phase: String
    let elapsedMilliseconds: Double
    let durationMilliseconds: Double?
    let rowCount: Int?
    let payloadBytes: Int?
    let changedCount: Int?
    let valueMilliseconds: Double?
    let mainThread: Bool
}

final class SyncV2PullDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [SyncV2PullDiagnosticEvent] = []

    func append(_ event: SyncV2PullDiagnosticEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func events() -> [SyncV2PullDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

struct SyncV2PullDiagnosticContext: Sendable {
    let pullID: UUID
    let origin: String
    let startedAtNanoseconds: UInt64
    let recorder: SyncV2PullDiagnosticRecorder

    init(
        pullID: UUID = UUID(),
        origin: String,
        startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        recorder: SyncV2PullDiagnosticRecorder =
            SyncV2PullDiagnosticRecorder()
    ) {
        self.pullID = pullID
        self.origin = origin
        self.startedAtNanoseconds = startedAtNanoseconds
        self.recorder = recorder
    }
}

private final class SyncV2WorkspaceEntryRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [UUID: Int] = [:]

    func next(for projectID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = counts[projectID, default: 0] + 1
        counts[projectID] = value
        return value
    }
}

enum SyncV2PullDiagnostics {
    static let pullIDHeader = "X-WriterPad-Pull-ID"
    static let pullOriginHeader = "X-WriterPad-Pull-Origin"
    static let pullStageHeader = "X-WriterPad-Pull-Stage"
    static let pullStartHeader = "X-WriterPad-Pull-Start-Ns"

    @TaskLocal static var current: SyncV2PullDiagnosticContext?

    private static let workspaceEntries = SyncV2WorkspaceEntryRegistry()

    static func makeWorkspaceEntryContext(
        localProjectID: ProjectID
    ) -> SyncV2PullDiagnosticContext? {
#if DEBUG
        let ordinal = workspaceEntries.next(
            for: localProjectID.rawValue
        )
        return SyncV2PullDiagnosticContext(
            origin: ordinal == 1 ? "first-entry" : "reentry"
        )
#else
        _ = localProjectID
        return nil
#endif
    }

    static func makeContext(
        origin: String
    ) -> SyncV2PullDiagnosticContext? {
#if DEBUG
        SyncV2PullDiagnosticContext(origin: origin)
#else
        _ = origin
        return nil
#endif
    }

    static func withContext<T>(
        _ context: SyncV2PullDiagnosticContext?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        _ = isolation
        guard let context else {
            return try await operation()
        }
        return try await $current.withValue(
            context,
            operation: operation
        )
    }

    static func record(
        stage: String,
        phase: String,
        startedAtNanoseconds: UInt64? = nil,
        rowCount: Int? = nil,
        payloadBytes: Int? = nil,
        changedCount: Int? = nil,
        valueMilliseconds: Double? = nil
    ) {
#if DEBUG
        guard let context = current else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = milliseconds(
            from: context.startedAtNanoseconds,
            to: now
        )
        let duration = startedAtNanoseconds.map {
            milliseconds(from: $0, to: now)
        }
        let event = SyncV2PullDiagnosticEvent(
            pullID: context.pullID,
            origin: context.origin,
            stage: stage,
            phase: phase,
            elapsedMilliseconds: elapsed,
            durationMilliseconds: duration,
            rowCount: rowCount,
            payloadBytes: payloadBytes,
            changedCount: changedCount,
            valueMilliseconds: valueMilliseconds,
            mainThread: Thread.isMainThread
        )
        context.recorder.append(event)
        syncV2Logger.info(
            "event=pullTrace pullID=\(context.pullID.uuidString, privacy: .public) origin=\(context.origin, privacy: .public) stage=\(stage, privacy: .public) phase=\(phase, privacy: .public) elapsedMs=\(elapsed, privacy: .public) durationMs=\(duration ?? -1, privacy: .public) valueMs=\(valueMilliseconds ?? -1, privacy: .public) rows=\(rowCount ?? -1, privacy: .public) payloadBytes=\(payloadBytes ?? -1, privacy: .public) changed=\(changedCount ?? -1, privacy: .public) mainThread=\(Thread.isMainThread, privacy: .public)"
        )
#else
        _ = stage
        _ = phase
        _ = startedAtNanoseconds
        _ = rowCount
        _ = payloadBytes
        _ = changedCount
        _ = valueMilliseconds
#endif
    }

    static func recordNetworkMetrics(
        pullID: UUID,
        origin: String,
        stage: String,
        pullStartedAtNanoseconds: UInt64,
        taskMilliseconds: Double,
        ttfbMilliseconds: Double,
        receiveMilliseconds: Double,
        networkBytes: Int64,
        decodedBytes: Int64,
        transactionCount: Int
    ) {
#if DEBUG
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = milliseconds(
            from: pullStartedAtNanoseconds,
            to: now
        )
        syncV2Logger.info(
            "event=pullNetworkMetrics pullID=\(pullID.uuidString, privacy: .public) origin=\(origin, privacy: .public) stage=\(stage, privacy: .public) elapsedMs=\(elapsed, privacy: .public) taskMs=\(taskMilliseconds, privacy: .public) ttfbMs=\(ttfbMilliseconds, privacy: .public) receiveMs=\(receiveMilliseconds, privacy: .public) networkBytes=\(networkBytes, privacy: .public) decodedBytes=\(decodedBytes, privacy: .public) transactions=\(transactionCount, privacy: .public)"
        )
#else
        _ = pullID
        _ = origin
        _ = stage
        _ = pullStartedAtNanoseconds
        _ = taskMilliseconds
        _ = ttfbMilliseconds
        _ = receiveMilliseconds
        _ = networkBytes
        _ = decodedBytes
        _ = transactionCount
#endif
    }

    private static func milliseconds(
        from start: UInt64,
        to end: UInt64
    ) -> Double {
        Double(end >= start ? end - start : 0) / 1_000_000
    }
}

@MainActor
final class SyncV2MainActorLagProbe {
    private var task: Task<Double, Never>?

    func start(context: SyncV2PullDiagnosticContext?) {
#if DEBUG
        task?.cancel()
        task = Task { @MainActor in
            await SyncV2PullDiagnostics.withContext(context) {
                var maximumDelayMilliseconds = 0.0
                while !Task.isCancelled {
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        break
                    }
                    let endedAt = DispatchTime.now().uptimeNanoseconds
                    let elapsed = Double(endedAt - startedAt) / 1_000_000
                    maximumDelayMilliseconds = max(
                        maximumDelayMilliseconds,
                        elapsed - 50
                    )
                }
                return maximumDelayMilliseconds
            }
        }
#else
        _ = context
#endif
    }

    func finish() async {
#if DEBUG
        guard let task else { return }
        self.task = nil
        task.cancel()
        let maximumDelayMilliseconds = await task.value
        SyncV2PullDiagnostics.record(
            stage: "main-actor-heartbeat",
            phase: "finished",
            valueMilliseconds: maximumDelayMilliseconds
        )
#endif
    }
}

private extension SyncV2WorkspaceState {
    var logName: String {
        "progress=\(progress.logName),connection=\(connection.logName),lastResult=\(lastResult.logName)"
    }
}

private extension SyncV2WorkspaceState.Progress {
    var logName: String {
        switch self {
        case .idle: "idle"
        case .pulling: "pulling"
        case .checkingAuthentication: "checkingAuthentication"
        }
    }
}

private extension SyncV2WorkspaceState.Connection {
    var logName: String {
        switch self {
        case .unknown: "unknown"
        case .healthy: "healthy"
        case .reconnecting: "reconnecting"
        case .offline: "offline"
        }
    }
}

private extension SyncV2WorkspaceState.Result {
    var logName: String {
        switch self {
        case .idle: "idle"
        case .localOnly: "localOnly"
        case .synced: "synced"
        case .waiting: "waiting"
        case .uploadPending: "uploadPending"
        case .retryWaiting: "retryWaiting"
        case .actualConflict: "actualConflict"
        case .blocked: "blocked"
        case .authenticationRequired: "authenticationRequired"
        case .automaticallyMerged: "automaticallyMerged"
        case .conflictRequired: "conflictRequired"
        case .structuralConflict: "structuralConflict"
        case .notApplied: "notApplied"
        case .reconcilingStructure: "reconcilingStructure"
        case .notPublished: "notPublished"
        case .failed: "failed"
        }
    }
}
