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
