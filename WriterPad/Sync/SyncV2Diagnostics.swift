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
        case .authenticationRequired: "authenticationRequired"
        case .automaticallyMerged: "automaticallyMerged"
        case .conflictRequired: "conflictRequired"
        case .structuralConflict: "structuralConflict"
        case .failed: "failed"
        }
    }
}
