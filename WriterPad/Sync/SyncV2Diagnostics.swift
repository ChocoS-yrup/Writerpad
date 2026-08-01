import Foundation
import OSLog

let syncV2Logger = Logger(
    subsystem: "com.chocos.writerpad",
    category: "sync-v2"
)

enum SyncV2Diagnostics {
    static func serverState(
        localProjectID: ProjectID,
        from oldValue: SyncV2WorkspaceServerState,
        to newValue: SyncV2WorkspaceServerState
    ) {
        syncV2Logger.info(
            "event=serverState localProjectID=\(localProjectID.rawValue.uuidString, privacy: .public) from=\(oldValue.logName, privacy: .public) to=\(newValue.logName, privacy: .public)"
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

private extension SyncV2WorkspaceServerState {
    var logName: String {
        switch self {
        case .localOnly: "localOnly"
        case .idle: "idle"
        case .checkingAuthentication: "checkingAuthentication"
        case .connectionChecking: "connectionChecking"
        case .reconnecting: "reconnecting"
        case .syncing: "syncing"
        case .synced: "synced"
        case .offlineSaved: "offlineSaved"
        case .waiting: "waiting"
        case .authenticationRequired: "authenticationRequired"
        case .automaticallyMerged: "automaticallyMerged"
        case .conflictRequired: "conflictRequired"
        case .structuralConflict: "structuralConflict"
        case .failed: "failed"
        }
    }
}
