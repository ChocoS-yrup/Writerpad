import CryptoKit
import CoreFoundation
import Foundation
import SQLite3

// sqlite3.h의 함수형 매크로는 Swift importer가 노출하지 않으므로
// SQLITE_CONSTRAINT | (subtype << 8)의 문서화된 extended code를 고정한다.
private let sqliteConstraintPrimaryKeyCode: Int32 = 1_555
private let sqliteConstraintUniqueCode: Int32 = 2_067

private final class SQLiteConnection: @unchecked Sendable {
    private(set) var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
    }
}

enum SyncV2StoreDiagnosticReason: String, Equatable, Sendable {
    case applicationSupportUnavailable
    case resourceMissing
    case directoryCreationFailed
    case databaseOpenFailed
    case pragmaVerificationFailed
    case unrecognizedSchema
    case schemaTooNew
    case migrationFailed
    case migrationMismatch
    case integrityCheckFailed
    case recoveryFailed
    case databaseClosed
}

struct SyncV2StoreDiagnostic: Equatable, Sendable {
    let reason: SyncV2StoreDiagnosticReason
    let sqliteCode: Int32?
    let schemaVersion: Int?
}

enum SyncV2StoreAvailability: Sendable {
    case available(SyncV2Store)
    case unavailable(SyncV2StoreDiagnostic)
}

enum SyncV2StoreError: Error, Equatable, Sendable {
    case unavailable(SyncV2StoreDiagnostic)
    case sqlite(code: Int32)
    case invalidStoredData
}

enum SyncV2BatchKind: String, Codable, Equatable, Sendable {
    case projectBinding = "project_binding"
    case documentSave = "document_save"
    case structureChange = "structure_change"
    case volumeCreation = "volume_creation"
    case trashChange = "trash_change"
    case backupRestore = "backup_restore"
    case windowsImport = "windows_import"
}

let syncV2TreeOrderPath = "__antigravity__/tree-order.json"
let syncV2TrashPurgePath = "__antigravity__/trash-purge.json"
private let syncV2TombstoneLocalPathPrefix = "__writerpad_tombstone__/"

enum SyncV2TrashPurgePayloadError: Error, Equatable, Sendable {
    case invalidEnvelope
    case invalidWireTypes
    case invalidVersion
    case invalidGeneration
    case invalidRevision
}

struct SyncV2TrashPurgePayload: Equatable, Sendable {
    private struct StrictWirePayload: Decodable {
        let version: Int64
        let purgedRevisions: [String: Int64]
        let emptyGeneration: String

        private enum CodingKeys: String, CodingKey {
            case version
            case purgedRevisions = "purged_revisions"
            case emptyGeneration = "empty_generation"
        }
    }

    let purgedRevisions: [UUID: Int64]
    let emptyGeneration: String

    static let empty = SyncV2TrashPurgePayload(
        purgedRevisions: [:],
        emptyGeneration: ""
    )

    init(purgedRevisions: [UUID: Int64], emptyGeneration: String) {
        self.purgedRevisions = purgedRevisions
        self.emptyGeneration = emptyGeneration
    }

    init(strictContent content: String) throws {
        let data = Data(content.utf8)
        guard let object = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        Set(object.keys) == Set([
            "version", "purged_revisions", "empty_generation",
        ]),
        Self.isStrictJSONInteger(object["version"]),
        let rawPurges = object["purged_revisions"] as? [String: Any],
        rawPurges.values.allSatisfy(Self.isStrictJSONInteger)
        else {
            throw SyncV2TrashPurgePayloadError.invalidEnvelope
        }
        guard let wire = try? JSONDecoder().decode(
            StrictWirePayload.self,
            from: data
        ) else {
            throw SyncV2TrashPurgePayloadError.invalidWireTypes
        }
        guard wire.version == 1 else {
            throw SyncV2TrashPurgePayloadError.invalidVersion
        }
        guard wire.emptyGeneration.isEmpty
                || Self.isCanonicalUUID(wire.emptyGeneration) else {
            throw SyncV2TrashPurgePayloadError.invalidGeneration
        }

        var purges: [UUID: Int64] = [:]
        purges.reserveCapacity(wire.purgedRevisions.count)
        for (rawID, revision) in wire.purgedRevisions {
            guard
                Self.isCanonicalUUID(rawID),
                let documentID = UUID(uuidString: rawID),
                revision >= 0
            else {
                throw SyncV2TrashPurgePayloadError.invalidRevision
            }
            purges[documentID] = revision
        }
        self.purgedRevisions = purges
        self.emptyGeneration = wire.emptyGeneration
    }

    func merging(_ other: SyncV2TrashPurgePayload)
        -> SyncV2TrashPurgePayload {
        var merged = purgedRevisions
        for (documentID, revision) in other.purgedRevisions {
            merged[documentID] = max(merged[documentID] ?? 0, revision)
        }
        return SyncV2TrashPurgePayload(
            purgedRevisions: merged,
            emptyGeneration: other.emptyGeneration.isEmpty
                ? emptyGeneration
                : other.emptyGeneration
        )
    }

    func canonicalContent() throws -> String {
        let purges = Dictionary(
            uniqueKeysWithValues: purgedRevisions.map {
                ($0.key.uuidString.lowercased(), $0.value)
            }
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "purged_revisions": purges,
                "empty_generation": emptyGeneration,
            ],
            options: [.sortedKeys]
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw SyncV2TrashPurgePayloadError.invalidEnvelope
        }
        return content
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36, UUID(uuidString: value) != nil else {
            return false
        }
        let hyphens: Set<Int> = [8, 13, 18, 23]
        for (index, byte) in bytes.enumerated() {
            if hyphens.contains(index) {
                guard byte == 45 else { return false }
            } else {
                guard (48...57).contains(byte) || (97...102).contains(byte)
                else { return false }
            }
        }
        return true
    }

    private static func isStrictJSONInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
            && !CFNumberIsFloatType(number)
    }
}

private func syncV2TombstoneLocalPath(documentID: UUID) -> String {
    syncV2TombstoneLocalPathPrefix
        + documentID.uuidString.lowercased()
}

enum SyncV2ServerPath {
    static func canonical(_ path: String) -> String {
        path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        .map {
            String($0).precomposedStringWithCanonicalMapping
        }
        .joined(separator: "/")
    }

    static func hasExactBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}

func syncV2UUIDv5(namespace: UUID, name: String) -> UUID {
    var namespaceBytes = namespace.uuid
    var data = withUnsafeBytes(of: &namespaceBytes) { Data($0) }
    data.append(contentsOf: name.utf8)
    var digest = Array(Insecure.SHA1.hash(data: data).prefix(16))
    digest[6] = (digest[6] & 0x0f) | 0x50
    digest[8] = (digest[8] & 0x3f) | 0x80
    return UUID(uuid: (
        digest[0], digest[1], digest[2], digest[3],
        digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15]
    ))
}

enum SyncV2OperationKind: String, Codable, Equatable, Sendable {
    case ensureProject = "ensure_project"
    case documentCommit = "document_commit"
    case treeOrder = "tree_order"
    case trashPurge = "trash_purge"
    case folderCommit = "folder_commit"
}

enum SyncV2OperationStatus: String, Codable, Equatable, Sendable {
    case pending
    case inflight
    case retryWait = "retry_wait"
    case conflict
    case completed
    case cancelled
    case blocked
}

struct SyncV2EnsureProjectMutation: Equatable, Sendable {
    let operationID: UUID
    let projectName: String
}

struct SyncV2DocumentMutation: Equatable, Sendable {
    let operationID: UUID
    let documentID: UUID
    let deviceID: UUID
    let localSaveGeneration: Int?
    let kind: SyncV2OperationKind
    let localPath: String
    let relativePath: String
    let content: String
    let isDeleted: Bool
}

/// 폴더는 본문이 없고 이름과 부모 연결만 바뀐다. 이름 변경·이동·삭제·복원이
/// 모두 같은 folderID로 나가야 받는 기기가 같은 폴더임을 알 수 있다.
struct SyncV2FolderMutation: Equatable, Sendable {
    let operationID: UUID
    let folderID: UUID
    /// 최상위 폴더는 nil이다.
    let parentFolderID: UUID?
    let deviceID: UUID
    let name: String
    let isDeleted: Bool
}

enum SyncV2Mutation: Equatable, Sendable {
    case ensureProject(SyncV2EnsureProjectMutation)
    case document(SyncV2DocumentMutation)
    case folder(SyncV2FolderMutation)

    var operationID: UUID {
        switch self {
        case .ensureProject(let mutation):
            mutation.operationID
        case .document(let mutation):
            mutation.operationID
        case .folder(let mutation):
            mutation.operationID
        }
    }
}

struct SyncV2EnqueueBatch: Equatable, Sendable {
    let batchID: UUID
    let localProjectID: ProjectID
    let localTransactionID: UUID?
    let kind: SyncV2BatchKind
    let mutations: [SyncV2Mutation]
}

struct SyncV2EnqueueReceipt: Equatable, Sendable {
    let batchID: UUID
    let operationIDs: [UUID]
    let noOpOperationIDs: [UUID]
    let blockedOperations: [SyncV2BlockedOperation]
    let replayed: Bool
}

struct SyncV2BlockedOperation: Equatable, Sendable {
    let operationID: UUID
    let contentByteCount: Int
    let limit: Int
}

struct SyncV2QueuedOperation: Equatable, Sendable {
    let operationID: UUID
    let documentID: UUID?
    let documentSequence: Int?
    let kind: SyncV2OperationKind
    let status: SyncV2OperationStatus
    let baseRevision: Int?
    let localPath: String
    let relativePath: String
    let content: String
    let contentByteCount: Int
    let contentHash: String
    let isDeleted: Bool
}

struct SyncV2DispatchOperation: Equatable, Sendable {
    let operationID: UUID
    let batchID: UUID
    let localProjectID: ProjectID?
    let projectID: UUID
    let documentID: UUID
    let deviceID: UUID
    let documentSequence: Int
    let localSaveGeneration: UInt64?
    let kind: SyncV2OperationKind
    let baseRevision: Int64
    let baseContent: String
    let baseServerPath: String
    let localPath: String
    let relativePath: String
    let content: String
    let isDeleted: Bool
    /// 이번 claim을 포함한 누적 시도 횟수다.
    let attempts: Int

    init(
        operationID: UUID,
        batchID: UUID,
        localProjectID: ProjectID? = nil,
        projectID: UUID,
        documentID: UUID,
        deviceID: UUID,
        documentSequence: Int,
        localSaveGeneration: UInt64? = nil,
        kind: SyncV2OperationKind,
        baseRevision: Int64,
        baseContent: String = "",
        baseServerPath: String? = nil,
        localPath: String? = nil,
        relativePath: String,
        content: String,
        isDeleted: Bool,
        attempts: Int
    ) {
        self.operationID = operationID
        self.batchID = batchID
        self.localProjectID = localProjectID
        self.projectID = projectID
        self.documentID = documentID
        self.deviceID = deviceID
        self.documentSequence = documentSequence
        self.localSaveGeneration = localSaveGeneration
        self.kind = kind
        self.baseRevision = baseRevision
        self.baseContent = baseContent
        self.baseServerPath = baseServerPath ?? relativePath
        self.localPath = localPath ?? relativePath
        self.relativePath = relativePath
        self.content = content
        self.isDeleted = isDeleted
        self.attempts = attempts
    }

    var commitParameters: SyncV2CommitDocumentParameters {
        commitParameters(leaseToken: nil)
    }

    func commitParameters(
        leaseToken: UUID?
    ) -> SyncV2CommitDocumentParameters {
        SyncV2CommitDocumentParameters(
            documentID: documentID,
            projectID: projectID,
            baseServerRevision: baseRevision,
            operationID: operationID,
            deviceID: deviceID,
            relativePath: relativePath,
            content: content,
            isDeleted: isDeleted,
            leaseToken: leaseToken
        )
    }
}

/// 폴더는 서버 folders 행 하나에 대응하므로 문서 전송값과 겹치는 칸이 거의
/// 없다. 문서 쪽 필수 칸(documentID, 본문, 경로)을 옵션으로 늘리는 대신 따로
/// 둔다.
struct SyncV2FolderDispatchOperation: Equatable, Sendable {
    let operationID: UUID
    let batchID: UUID
    let localProjectID: ProjectID
    let projectID: UUID
    let folderID: UUID
    let parentFolderID: UUID?
    let deviceID: UUID
    let folderSequence: Int
    let name: String
    let baseRevision: Int64
    let isDeleted: Bool
    /// 이번 claim을 포함한 누적 시도 횟수다.
    let attempts: Int
}

struct SyncV2RebaseLocalSnapshot: Equatable, Sendable {
    let content: String
    let localPath: String
    let relativePath: String
    let localSaveGeneration: UInt64?
}

struct SyncV2ConflictSnapshot: Equatable, Sendable {
    let baseContent: String
    let localContent: String
    let remoteContent: String
    let mergedContent: String
    let remoteRevision: Int64
    let remotePath: String
    let conflictCount: Int
}

struct SyncV2ConflictRecord: Equatable, Sendable {
    let conflictID: UUID
    let operationID: UUID
    let documentID: UUID
    let snapshot: SyncV2ConflictSnapshot
    let createdAt: Date
}

enum SyncV2ConflictResolutionKind: String, Equatable, Sendable {
    case keepLocal = "keep_local"
    case useRemote = "use_remote"
    case manualMerge = "manual_merge"
}

struct SyncV2ConflictResolutionRequest: Equatable, Sendable {
    let conflictID: UUID
    let documentID: UUID
    let resolutionOperationID: UUID
    let resolvedContent: String
    let kind: SyncV2ConflictResolutionKind
}

enum SyncV2ConflictResolutionError: Error, Equatable, Sendable {
    case conflictNotFound
    case conflictChanged
    case resolutionOperationNotReady
    case contentTooLarge(byteCount: Int, limit: Int)
    case integrityFailure
    case unavailable
}

extension SyncV2ConflictResolutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .conflictNotFound:
            "이미 해결되었거나 찾을 수 없는 충돌입니다."
        case .conflictChanged:
            "충돌 상태가 바뀌었습니다. 최신 상태를 다시 불러와 주세요."
        case .resolutionOperationNotReady:
            "해결 원고의 로컬 저장과 동기화 대기열 기록을 확인할 수 없습니다."
        case let .contentTooLarge(byteCount, limit):
            "해결 원고가 서버 제한을 초과합니다. (\(byteCount) / \(limit)바이트)"
        case .integrityFailure:
            "충돌 해결 데이터의 무결성을 확인하지 못했습니다."
        case .unavailable:
            "충돌 저장소를 사용할 수 없습니다."
        }
    }
}

protocol SyncV2ConflictResolving: Sendable {
    func unresolvedConflict(
        documentID: UUID
    ) async throws -> SyncV2ConflictRecord?
    func unresolvedConflicts(
        localProjectID: ProjectID
    ) async throws -> [SyncV2ConflictRecord]
    func resolveConflict(
        _ request: SyncV2ConflictResolutionRequest
    ) async throws
}

enum SyncV2AutomaticRebaseStoreResult: Equatable, Sendable {
    case rebased
    case localGenerationAdvanced
    case pathOccupiedByDifferentDocument
}

enum SyncV2ConflictPreservationResult: Equatable, Sendable {
    case preserved
    case localGenerationAdvanced
}

enum SyncV2DispatchStoreError: Error, Equatable, Sendable {
    case operationStateChanged
    case integrityFailure
    case unavailable
}

protocol SyncV2DispatchStoring: Sendable {
    func recoverInterruptedWork() async throws
    func readyLocalProjectIDs(
        now: Date
    ) async throws -> [ProjectID]
    func claimReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2DispatchOperation]
    /// 폴더 줄은 문서 줄과 나란히 흐른다. 폴더 대기열이 없는 구현은 기본값을
    /// 그대로 쓴다.
    func claimReadyFolderOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2FolderDispatchOperation]
    func complete(
        _ operation: SyncV2FolderDispatchOperation,
        result: SyncV2CommitFolderResult
    ) async throws
    func deferRetry(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws
    func markConflict(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws
    func markBlocked(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws
    func rebaseFolderAfterRevisionConflict(
        _ operation: SyncV2FolderDispatchOperation,
        remote: SyncV2RemoteFolder
    ) async throws
    func complete(
        _ operation: SyncV2DispatchOperation,
        result: SyncV2CommitDocumentResult
    ) async throws
    func deferRetry(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws
    func markConflict(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws
    func preserveConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        conflictCount: Int,
        errorCode: String,
        detail: String?
    ) async throws -> SyncV2ConflictPreservationResult
    func markBlocked(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws
    func recoverMissingRemoteDocument(
        _ operation: SyncV2DispatchOperation
    ) async throws
    func recoverMissingRemoteProject(
        _ operation: SyncV2DispatchOperation
    ) async throws
    func projectName(
        for operation: SyncV2DispatchOperation
    ) async throws -> String
    func latestLocalSnapshot(
        for operation: SyncV2DispatchOperation
    ) async throws -> SyncV2RebaseLocalSnapshot
    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) async throws -> SyncV2AutomaticRebaseStoreResult
    func makeRetryWaitOperationsReady(
        localProjectID: ProjectID?
    ) async throws
    func nextRetryDate(
        localProjectID: ProjectID?
    ) async throws -> Date?
}

extension SyncV2DispatchStoring {
    func rebaseFolderAfterRevisionConflict(
        _ operation: SyncV2FolderDispatchOperation,
        remote: SyncV2RemoteFolder
    ) async throws {
        _ = (operation, remote)
        throw SyncV2DispatchStoreError.unavailable
    }

    func recoverMissingRemoteDocument(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        _ = operation
        throw SyncV2DispatchStoreError.unavailable
    }

    func recoverMissingRemoteProject(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        _ = operation
        throw SyncV2DispatchStoreError.unavailable
    }

    func projectName(
        for operation: SyncV2DispatchOperation
    ) async throws -> String {
        _ = operation
        throw SyncV2DispatchStoreError.unavailable
    }

    func latestLocalSnapshot(
        for operation: SyncV2DispatchOperation
    ) async throws -> SyncV2RebaseLocalSnapshot {
        SyncV2RebaseLocalSnapshot(
            content: operation.content,
            localPath: operation.localPath,
            relativePath: operation.relativePath,
            localSaveGeneration: operation.localSaveGeneration
        )
    }

    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) async throws -> SyncV2AutomaticRebaseStoreResult {
        _ = (operation, remote, local, mergedContent, mergedPath)
        throw SyncV2DispatchStoreError.unavailable
    }
}

enum SyncV2EnqueueError: Error, Equatable, Sendable {
    case unavailable
    case emptyBatch
    case invalidMutation
    case projectNotConnected
    case batchIDReused
    case operationIDReused
    case integrityFailure
    case storageFailure(code: Int32)
}

private final class SyncV2StoreBundleToken {}

actor SyncV2Store:
    ProjectBindingStoring,
    SyncV2DispatchStoring,
    SyncV2ConflictResolving,
    SyncV2DocumentRevisionProviding,
    SyncV2FolderMigrationMarking,
    SyncV2SnapshotStateStoring {
    static let currentSchemaVersion = 5
    static let migrationName = "SyncV2StoreSchemaV5"
    static let maximumContentByteCount = 10 * 1_024 * 1_024
    static let contentTooLargeErrorCode = "CONTENT_TOO_LARGE"

    private let connection: SQLiteConnection
    private let migrationChecksum: String
    private var openDiagnostic: SyncV2StoreDiagnostic?

    private init(
        connection: SQLiteConnection,
        migrationChecksum: String
    ) {
        self.connection = connection
        self.migrationChecksum = migrationChecksum
    }

    static func defaultDatabaseURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return applicationSupport
            .appendingPathComponent("WriterPad", isDirectory: true)
            .appendingPathComponent("SyncV2", isDirectory: true)
            .appendingPathComponent("sync-v2.sqlite3", isDirectory: false)
    }

    static func open(
        at url: URL,
        fileManager: FileManager = .default,
        resourceBundle: Bundle? = nil
    ) async -> SyncV2StoreAvailability {
        let migration: MigrationPlan
        do {
            migration = try loadMigrationResource(
                bundle: resourceBundle
                    ?? Bundle(for: SyncV2StoreBundleToken.self)
            )
        } catch {
            return .unavailable(
                diagnostic(.resourceMissing)
            )
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .unavailable(
                diagnostic(.directoryCreationFailed)
            )
        }

        var handle: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE
                | SQLITE_OPEN_CREATE
                | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let handle else {
            if let handle {
                sqlite3_close_v2(handle)
            }
            return .unavailable(
                diagnostic(
                    .databaseOpenFailed,
                    sqliteCode: openStatus
                )
            )
        }

        sqlite3_extended_result_codes(handle, 1)
        let connection = SQLiteConnection(handle: handle)
        let store = SyncV2Store(
            connection: connection,
            migrationChecksum: migration.head.checksum
        )
        do {
            try await store.prepare(migration: migration)
            return .available(store)
        } catch let failure as StorePreparationFailure {
            await store.close()
            return .unavailable(failure.diagnostic)
        } catch {
            let code = await store.lastSQLiteCode()
            await store.close()
            return .unavailable(
                diagnostic(.databaseOpenFailed, sqliteCode: code)
            )
        }
    }

    func availability() -> ProjectBindingStoreAvailability {
        connection.handle == nil || openDiagnostic != nil
            ? .unavailable
            : .available
    }

    func binding(
        for localProjectID: ProjectID
    ) throws -> ProjectSyncBinding? {
        try readBinding(
            sql: """
            SELECT local_project_id, server_project_id, binding_kind,
                   project_name, owner_subject
            FROM sync_projects
            WHERE local_project_id = ?
            LIMIT 1;
            """,
            value: localProjectID.rawValue.uuidString.lowercased()
        )
    }

    func serverRevision(for documentID: UUID) throws -> Int64? {
        try withStatement(
            """
            SELECT server_revision
            FROM sync_documents
            WHERE document_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw SyncV2StoreError.sqlite(
                    code: sqlite3_errcode(connection.handle)
                )
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) throws -> SyncV2SnapshotLocalState? {
        try withStatement(
            """
            SELECT d.server_revision, d.server_path,
                   EXISTS(
                       SELECT 1
                       FROM sync_operations o
                       WHERE o.document_id = d.document_id
                         AND o.status NOT IN ('completed', 'cancelled')
                   ),
                   EXISTS(
                       SELECT 1
                       FROM sync_conflicts c
                       WHERE c.document_id = d.document_id
                         AND c.resolved_at IS NULL
                   ),
                   (
                       SELECT o.last_error_code
                       FROM sync_operations o
                       WHERE o.document_id = d.document_id
                         AND o.status = 'blocked'
                       ORDER BY o.document_sequence, o.queue_id
                       LIMIT 1
                   ),
                   EXISTS(
                       SELECT 1
                       FROM sync_operations o
                       WHERE o.document_id = d.document_id
                         AND o.status = 'conflict'
                         AND o.last_error_code = 'PATH_CONFLICT'
                   )
            FROM sync_documents d
            WHERE d.local_project_id = ?
              AND d.project_id = ?
              AND d.document_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                serverProjectID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                documentID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW,
                  let path = columnText(statement, at: 1) else {
                throw SyncV2StoreError.invalidStoredData
            }
            return SyncV2SnapshotLocalState(
                serverRevision: sqlite3_column_int64(statement, 0),
                serverPath: path,
                hasActiveOperation: sqlite3_column_int(statement, 2) == 1,
                hasUnresolvedConflict:
                    sqlite3_column_int(statement, 3) == 1,
                blockingErrorCode: columnText(statement, at: 4),
                hasPathCollision:
                    sqlite3_column_int(statement, 5) == 1
            )
        }
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) throws -> Bool {
        try transaction {
            let latest = try snapshotState(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                documentID: snapshot.documentID
            )
            guard latest?.serverRevision == expectedRevision,
                  latest?.hasActiveOperation != true,
                  latest?.hasUnresolvedConflict != true,
                  snapshot.revision > (latest?.serverRevision ?? 0)
            else {
                return false
            }

            let localPath = snapshot.isDeleted
                ? syncV2TombstoneLocalPath(documentID: snapshot.documentID)
                : snapshot.relativePath
            let pathOccupied = try withStatement(
                """
                SELECT EXISTS(
                    SELECT 1
                    FROM sync_documents
                    WHERE local_project_id = ?
                      AND local_path = ?
                      AND document_id <> ?
                );
                """
            ) { statement in
                try bind(
                    localProjectID.rawValue.uuidString.lowercased(),
                    at: 1,
                    to: statement
                )
                try bind(localPath, at: 2, to: statement)
                try bind(
                    snapshot.documentID.uuidString.lowercased(),
                    at: 3,
                    to: statement
                )
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError()
                }
                return sqlite3_column_int(statement, 0) == 1
            }
            guard !pathOccupied else { return false }

            let hash = SHA256.hash(data: Data(snapshot.content.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let timestamp = Self.timestamp()
            let serverUpdatedAt = Self.timestamp(snapshot.updatedAt)
            if latest == nil {
                try withStatement(
                    """
                    INSERT INTO sync_documents(
                        document_id, local_project_id, project_id,
                        local_path, server_path, server_revision,
                        base_content, base_hash, is_deleted,
                        server_updated_at, sync_state,
                        next_document_sequence, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced', 1, ?, ?);
                    """
                ) { statement in
                    try bind(
                        snapshot.documentID.uuidString.lowercased(),
                        at: 1,
                        to: statement
                    )
                    try bind(
                        localProjectID.rawValue.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        serverProjectID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try bind(localPath, at: 4, to: statement)
                    try bind(snapshot.relativePath, at: 5, to: statement)
                    try bind(snapshot.revision, at: 6, to: statement)
                    try bind(snapshot.content, at: 7, to: statement)
                    try bind(hash, at: 8, to: statement)
                    try bind(snapshot.isDeleted ? 1 : 0, at: 9, to: statement)
                    try bind(serverUpdatedAt, at: 10, to: statement)
                    try bind(timestamp, at: 11, to: statement)
                    try bind(timestamp, at: 12, to: statement)
                    try stepDone(statement)
                }
            } else {
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET local_path = ?, server_path = ?,
                        server_revision = ?, base_content = ?,
                        base_hash = ?, is_deleted = ?,
                        server_updated_at = ?, sync_state = 'synced',
                        last_error_code = NULL, updated_at = ?
                    WHERE local_project_id = ?
                      AND project_id = ?
                      AND document_id = ?;
                    """
                ) { statement in
                    try bind(localPath, at: 1, to: statement)
                    try bind(snapshot.relativePath, at: 2, to: statement)
                    try bind(snapshot.revision, at: 3, to: statement)
                    try bind(snapshot.content, at: 4, to: statement)
                    try bind(hash, at: 5, to: statement)
                    try bind(snapshot.isDeleted ? 1 : 0, at: 6, to: statement)
                    try bind(serverUpdatedAt, at: 7, to: statement)
                    try bind(timestamp, at: 8, to: statement)
                    try bind(
                        localProjectID.rawValue.uuidString.lowercased(),
                        at: 9,
                        to: statement
                    )
                    try bind(
                        serverProjectID.uuidString.lowercased(),
                        at: 10,
                        to: statement
                    )
                    try bind(
                        snapshot.documentID.uuidString.lowercased(),
                        at: 11,
                        to: statement
                    )
                    try stepDone(statement)
                }
            }
            return true
        }
    }

    func applyFolderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        folders: [SyncV2RemoteFolder],
        excluding blockedFolderIDs: Set<UUID>
    ) async throws {
        let timestamp = Self.timestamp()
        try transaction {
            for folder in folders where
                !blockedFolderIDs.contains(folder.folderID) {
                let folderValue = folder.folderID.uuidString.lowercased()
                let hasActiveOperation = try withStatement(
                    """
                    SELECT EXISTS(
                        SELECT 1 FROM sync_operations
                        WHERE folder_id = ?
                          AND status NOT IN ('completed', 'cancelled')
                    );
                    """
                ) { statement in
                    try bind(folderValue, at: 1, to: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    return sqlite3_column_int(statement, 0) == 1
                }
                guard !hasActiveOperation else { continue }

                let existing = try withStatement(
                    """
                    SELECT local_project_id, project_id, server_revision
                    FROM sync_folders
                    WHERE folder_id = ?
                    LIMIT 1;
                    """
                ) { statement -> (String, String, Int64)? in
                    try bind(folderValue, at: 1, to: statement)
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { return nil }
                    guard
                        status == SQLITE_ROW,
                        let localValue = columnText(statement, at: 0),
                        let projectValue = columnText(statement, at: 1)
                    else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    return (
                        localValue,
                        projectValue,
                        sqlite3_column_int64(statement, 2)
                    )
                }
                if let existing {
                    guard
                        existing.0 == localProjectID.rawValue.uuidString
                            .lowercased(),
                        existing.1 == serverProjectID.uuidString.lowercased()
                    else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    guard folder.revision >= existing.2 else { continue }
                    try withStatement(
                        """
                        UPDATE sync_folders
                        SET parent_folder_id = ?,
                            name = ?,
                            server_revision = ?,
                            is_deleted = ?,
                            server_updated_at = ?,
                            sync_state = 'synced',
                            last_error_code = NULL,
                            updated_at = ?
                        WHERE folder_id = ?;
                        """
                    ) { statement in
                        try bind(
                            folder.parentFolderID?.uuidString.lowercased(),
                            at: 1,
                            to: statement
                        )
                        try bind(folder.name, at: 2, to: statement)
                        try bind(folder.revision, at: 3, to: statement)
                        try bind(folder.isDeleted ? 1 : 0, at: 4, to: statement)
                        try bind(
                            Self.timestamp(folder.updatedAt),
                            at: 5,
                            to: statement
                        )
                        try bind(timestamp, at: 6, to: statement)
                        try bind(folderValue, at: 7, to: statement)
                        try stepDone(statement)
                    }
                } else {
                    try withStatement(
                        """
                        INSERT INTO sync_folders(
                            folder_id, local_project_id, project_id,
                            parent_folder_id, name, server_revision,
                            is_deleted, server_updated_at, sync_state,
                            next_folder_sequence, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'synced', 1, ?, ?);
                        """
                    ) { statement in
                        try bind(folderValue, at: 1, to: statement)
                        try bind(
                            localProjectID.rawValue.uuidString.lowercased(),
                            at: 2,
                            to: statement
                        )
                        try bind(
                            serverProjectID.uuidString.lowercased(),
                            at: 3,
                            to: statement
                        )
                        try bind(
                            folder.parentFolderID?.uuidString.lowercased(),
                            at: 4,
                            to: statement
                        )
                        try bind(folder.name, at: 5, to: statement)
                        try bind(folder.revision, at: 6, to: statement)
                        try bind(folder.isDeleted ? 1 : 0, at: 7, to: statement)
                        try bind(
                            Self.timestamp(folder.updatedAt),
                            at: 8,
                            to: statement
                        )
                        try bind(timestamp, at: 9, to: statement)
                        try bind(timestamp, at: 10, to: statement)
                        try stepDone(statement)
                    }
                }
            }
        }
    }

    func adoptEquivalentInitialDocument(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws -> Bool {
        guard localDocumentID != snapshot.documentID,
              snapshot.revision == 1,
              !snapshot.isDeleted,
              snapshot.relativePath != syncV2TreeOrderPath,
              snapshot.relativePath != syncV2TrashPurgePath
        else { return false }

        let localIdentifier = localDocumentID.uuidString.lowercased()
        let remoteIdentifier = snapshot.documentID.uuidString.lowercased()
        let supersededPath =
            "__antigravity__/identity-superseded/\(localIdentifier).txt"
        let hash = SHA256.hash(data: Data(snapshot.content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return try transaction {
            let remoteState = try snapshotState(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                documentID: snapshot.documentID
            )
            if let remoteState,
               remoteState.serverRevision == snapshot.revision,
               remoteState.serverPath == snapshot.relativePath {
                let oldPath = try withStatement(
                    """
                    SELECT local_path
                    FROM sync_documents
                    WHERE document_id = ?
                      AND local_project_id = ?
                      AND project_id = ?
                    LIMIT 1;
                    """
                ) { statement -> String? in
                    try bind(localIdentifier, at: 1, to: statement)
                    try bind(
                        localProjectID.rawValue.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        serverProjectID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        return nil
                    }
                    return columnText(statement, at: 0)
                }
                return oldPath == supersededPath
            }
            guard remoteState == nil else { return false }

            let localRow = try withStatement(
                """
                SELECT server_revision, server_path
                FROM sync_documents
                WHERE document_id = ?
                  AND local_project_id = ?
                  AND project_id = ?
                LIMIT 1;
                """
            ) { statement -> (Int64, String)? in
                try bind(localIdentifier, at: 1, to: statement)
                try bind(
                    localProjectID.rawValue.uuidString.lowercased(),
                    at: 2,
                    to: statement
                )
                try bind(
                    serverProjectID.uuidString.lowercased(),
                    at: 3,
                    to: statement
                )
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let serverPath = columnText(statement, at: 1)
                else { return nil }
                return (
                    sqlite3_column_int64(statement, 0),
                    serverPath
                )
            }
            guard let localRow,
                  localRow.0 == 0,
                  localRow.1 == snapshot.relativePath
            else { return false }

            let hasHistoryOrConflict = try withStatement(
                """
                SELECT
                    EXISTS(
                        SELECT 1
                        FROM sync_operations
                        WHERE document_id = ?
                          AND status = 'completed'
                    ),
                    EXISTS(
                        SELECT 1
                        FROM sync_conflicts
                        WHERE document_id = ?
                    );
                """
            ) { statement in
                try bind(localIdentifier, at: 1, to: statement)
                try bind(localIdentifier, at: 2, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError()
                }
                return sqlite3_column_int(statement, 0) == 1
                    || sqlite3_column_int(statement, 1) == 1
            }
            guard !hasHistoryOrConflict else { return false }

            let operationEligibility = try withStatement(
                """
                SELECT COUNT(*), COALESCE(SUM(
                    CASE WHEN operation_kind = 'document_commit'
                           AND base_revision = 0
                           AND base_content = ''
                           AND local_path = ?
                           AND relative_path = ?
                           AND content = ?
                           AND content_hash = ?
                           AND local_save_generation = 0
                           AND is_deleted = 0
                         THEN 1 ELSE 0 END
                ), 0)
                FROM sync_operations
                WHERE document_id = ?
                  AND status NOT IN ('completed', 'cancelled')
                """
            ) { statement -> (Int, Int) in
                try bind(snapshot.relativePath, at: 1, to: statement)
                try bind(snapshot.relativePath, at: 2, to: statement)
                try bind(snapshot.content, at: 3, to: statement)
                try bind(hash, at: 4, to: statement)
                try bind(localIdentifier, at: 5, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError()
                }
                return (
                    Int(sqlite3_column_int64(statement, 0)),
                    Int(sqlite3_column_int64(statement, 1))
                )
            }
            guard operationEligibility.0 > 0,
                  operationEligibility.0 == operationEligibility.1
            else { return false }
            let affectedBatchIDs = try withStatement(
                """
                SELECT DISTINCT batch_id
                FROM sync_operations
                WHERE document_id = ?
                  AND status NOT IN ('completed', 'cancelled');
                """
            ) { statement -> [UUID] in
                try bind(localIdentifier, at: 1, to: statement)
                var values: [UUID] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE { return values }
                    guard status == SQLITE_ROW,
                          let value = columnText(statement, at: 0),
                          let identifier = UUID(uuidString: value)
                    else { throw SyncV2StoreError.invalidStoredData }
                    values.append(identifier)
                }
            }

            let timestamp = Self.timestamp()
            // 문서의 신원이 서버 것으로 넘어갔다. 옛 신원으로 보내려던 것들은
            // 밀려난 것이지 취소된 것이 아니다. 이어받을 작업이 따로 없으므로
            // 가리킬 상대는 없다.
            let superseded = try prepareOperationEvents(
                where: """
                document_id = ?
                  AND status NOT IN ('completed', 'cancelled')
                """,
                timestamp: timestamp
            ) { statement in
                try bind(localIdentifier, at: 1, to: statement)
            }
            try withStatement(
                """
                UPDATE sync_operations
                SET status = 'cancelled',
                    last_error_code = 'SUPERSEDED_BY_SERVER_IDENTITY',
                    last_error_detail = NULL,
                    next_attempt_at = NULL,
                    updated_at = ?
                WHERE document_id = ?
                  AND status NOT IN ('completed', 'cancelled');
                """
            ) { statement in
                try bind(timestamp, at: 1, to: statement)
                try bind(localIdentifier, at: 2, to: statement)
                try stepDone(statement)
            }
            try recordOperationEvents(
                superseded,
                type: .superseded,
                errorCode: "SUPERSEDED_BY_SERVER_IDENTITY",
                timestamp: timestamp
            )
            try withStatement(
                """
                UPDATE sync_documents
                SET local_path = ?, is_deleted = 1,
                    sync_state = 'synced', last_error_code = NULL,
                    updated_at = ?
                WHERE document_id = ?;
                """
            ) { statement in
                try bind(supersededPath, at: 1, to: statement)
                try bind(timestamp, at: 2, to: statement)
                try bind(localIdentifier, at: 3, to: statement)
                try stepDone(statement)
                guard sqlite3_changes(connection.handle) == 1 else {
                    throw SyncV2StoreError.invalidStoredData
                }
            }
            try withStatement(
                """
                INSERT INTO sync_documents(
                    document_id, local_project_id, project_id,
                    local_path, server_path, server_revision,
                    base_content, base_hash, is_deleted,
                    server_updated_at, sync_state,
                    next_document_sequence, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 'synced', 1, ?, ?);
                """
            ) { statement in
                try bind(remoteIdentifier, at: 1, to: statement)
                try bind(
                    localProjectID.rawValue.uuidString.lowercased(),
                    at: 2,
                    to: statement
                )
                try bind(
                    serverProjectID.uuidString.lowercased(),
                    at: 3,
                    to: statement
                )
                try bind(snapshot.relativePath, at: 4, to: statement)
                try bind(snapshot.relativePath, at: 5, to: statement)
                try bind(snapshot.revision, at: 6, to: statement)
                try bind(snapshot.content, at: 7, to: statement)
                try bind(hash, at: 8, to: statement)
                try bind(Self.timestamp(snapshot.updatedAt), at: 9, to: statement)
                try bind(timestamp, at: 10, to: statement)
                try bind(timestamp, at: 11, to: statement)
                try stepDone(statement)
            }
            for batchID in affectedBatchIDs {
                try refreshBatchState(
                    batchID: batchID,
                    timestamp: timestamp
                )
            }
            return true
        }
    }

    func binding(
        forServerProjectID serverProjectID: UUID
    ) throws -> ProjectSyncBinding? {
        try readBinding(
            sql: """
            SELECT local_project_id, server_project_id, binding_kind,
                   project_name, owner_subject
            FROM sync_projects
            WHERE server_project_id = ?
            LIMIT 1;
            """,
            value: serverProjectID.uuidString.lowercased()
        )
    }

    func allBindings() async throws -> [ProjectSyncBinding] {
        guard availability() == .available else {
            throw ProjectBindingStoreError.unavailable
        }
        do {
            return try withStatement(
                """
                SELECT local_project_id, server_project_id, binding_kind,
                       project_name, owner_subject
                FROM sync_projects
                ORDER BY created_at, local_project_id;
                """
            ) { statement in
                var bindings: [ProjectSyncBinding] = []
                while true {
                    let status = sqlite3_step(statement)
                    if status == SQLITE_DONE {
                        return bindings
                    }
                    guard
                        status == SQLITE_ROW,
                        let localValue = columnText(statement, at: 0),
                        let localUUID = UUID(uuidString: localValue),
                        let kindValue = columnText(statement, at: 2),
                        let kind = ProjectBindingKind(rawValue: kindValue),
                        let name = columnText(statement, at: 3)
                    else {
                        throw SyncV2StoreError.invalidStoredData
                    }
                    bindings.append(
                        ProjectSyncBinding(
                            localProjectID: ProjectID(
                                rawValue: localUUID
                            ),
                            serverProjectID: columnText(
                                statement,
                                at: 1
                            ).flatMap(UUID.init(uuidString:)),
                            kind: kind,
                            projectName: name,
                            ownerSubject: columnText(
                                statement,
                                at: 4
                            ).flatMap(UUID.init(uuidString:))
                        )
                    )
                }
            }
        } catch {
            throw ProjectBindingStoreError.invalidBinding
        }
    }

    func save(_ binding: ProjectSyncBinding) throws {
        guard availability() == .available else {
            throw ProjectBindingStoreError.unavailable
        }
        let name = binding.projectName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw ProjectBindingStoreError.invalidBinding
        }
        switch binding.kind {
        case .localOnly:
            guard
                binding.serverProjectID == nil,
                binding.ownerSubject == nil
            else {
                throw ProjectBindingStoreError.invalidBinding
            }
        case .newServerProject, .existingServerProject, .windowsImport:
            guard
                binding.serverProjectID != nil,
                binding.ownerSubject != nil
            else {
                throw ProjectBindingStoreError.invalidBinding
            }
        }

        let now = Self.timestamp()
        let sql = """
        INSERT INTO sync_projects(
            local_project_id, server_project_id, binding_kind, project_name,
            owner_subject, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(local_project_id) DO UPDATE SET
            server_project_id = excluded.server_project_id,
            binding_kind = excluded.binding_kind,
            project_name = excluded.project_name,
            owner_subject = excluded.owner_subject,
            updated_at = excluded.updated_at;
        """
        do {
            try withStatement(sql) { statement in
                try bind(
                    binding.localProjectID.rawValue.uuidString.lowercased(),
                    at: 1,
                    to: statement
                )
                try bind(
                    binding.serverProjectID?.uuidString.lowercased(),
                    at: 2,
                    to: statement
                )
                try bind(binding.kind.rawValue, at: 3, to: statement)
                try bind(name, at: 4, to: statement)
                try bind(
                    binding.ownerSubject?.uuidString.lowercased(),
                    at: 5,
                    to: statement
                )
                try bind(now, at: 6, to: statement)
                try bind(now, at: 7, to: statement)
                try stepDone(statement)
            }
        } catch let error as SyncV2StoreError {
            if case let .sqlite(code) = error,
               code == sqliteConstraintUniqueCode
                    || code == sqliteConstraintPrimaryKeyCode {
                throw ProjectBindingStoreError.serverProjectAlreadyBound
            }
            throw ProjectBindingStoreError.invalidBinding
        } catch {
            throw ProjectBindingStoreError.unavailable
        }
    }

    /// 폴더 UUID 이관이 이 작품에서 이미 끝났는지 본다.
    ///
    /// 경로로는 판단할 수 없다. 이관된 폴더의 이름이 바뀌면 경로와 UUID가
    /// 어긋나므로 다시 계산하면 같은 폴더를 또 이관하게 된다.
    func isFolderMigrationCompleted(
        localProjectID: ProjectID
    ) throws -> Bool {
        guard availability() == .available else {
            throw SyncV2StoreError.invalidStoredData
        }
        return try withStatement(
            """
            SELECT folder_migration_completed_at IS NOT NULL
            FROM sync_projects
            WHERE local_project_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return false
            }
            guard status == SQLITE_ROW else {
                throw SyncV2StoreError.invalidStoredData
            }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    /// 아직 서버로 못 간 작업이 걸린 폴더다. 원격 변경으로 덮으면 사용자가 방금
    /// 한 일이 사라지므로 반영에서 빼야 한다.
    func foldersWithPendingOperations(
        localProjectID: ProjectID
    ) throws -> Set<UUID> {
        guard availability() == .available else {
            throw SyncV2StoreError.invalidStoredData
        }
        return try withStatement(
            """
            SELECT DISTINCT folder_id
            FROM sync_operations
            WHERE folder_id IS NOT NULL
              AND local_project_id = ?
              AND status NOT IN ('completed', 'cancelled');
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            var identifiers: Set<UUID> = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return identifiers
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2StoreError.invalidStoredData
                }
                identifiers.insert(identifier)
            }
        }
    }

    func markFolderMigrationCompleted(
        localProjectID: ProjectID
    ) throws {
        guard availability() == .available else {
            throw SyncV2StoreError.invalidStoredData
        }
        let timestamp = Self.timestamp()
        try withStatement(
            """
            UPDATE sync_projects
            SET folder_migration_completed_at = ?,
                updated_at = ?
            WHERE local_project_id = ?
              AND folder_migration_completed_at IS NULL;
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(timestamp, at: 2, to: statement)
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try stepDone(statement)
        }
    }

    func enqueue(
        _ batch: SyncV2EnqueueBatch
    ) throws -> SyncV2EnqueueReceipt {
        guard availability() == .available else {
            throw SyncV2EnqueueError.unavailable
        }
        guard !batch.mutations.isEmpty else {
            throw SyncV2EnqueueError.emptyBatch
        }
        let requestedOperationIDs = batch.mutations.map(\.operationID)
        guard
            Set(requestedOperationIDs).count
                == requestedOperationIDs.count
        else {
            throw SyncV2EnqueueError.operationIDReused
        }

        let projectBinding: ProjectSyncBinding
        do {
            guard let stored = try binding(for: batch.localProjectID) else {
                throw SyncV2EnqueueError.projectNotConnected
            }
            projectBinding = stored
        } catch let error as SyncV2EnqueueError {
            throw error
        } catch {
            throw SyncV2EnqueueError.unavailable
        }
        guard
            projectBinding.kind != .localOnly,
            let serverProjectID = projectBinding.serverProjectID,
            let ownerSubject = projectBinding.ownerSubject
        else {
            throw SyncV2EnqueueError.projectNotConnected
        }

        let materialized: MaterializedBatch
        do {
            materialized = try materialize(
                batch,
                serverProjectID: serverProjectID,
                ownerSubject: ownerSubject
            )
        } catch let error as SyncV2EnqueueError {
            throw error
        } catch {
            throw SyncV2EnqueueError.invalidMutation
        }

        do {
            return try transaction {
                if let existing = try existingBatch(
                    batchID: materialized.batchID
                ) {
                    guard
                        existing.localProjectID
                            == materialized.localProjectID,
                        existing.payloadHash == materialized.payloadHash,
                        existing.mutationCount
                            == materialized.operations.count
                    else {
                        throw SyncV2EnqueueError.batchIDReused
                    }
                    let storedIDs = try operationIDs(
                        batchID: materialized.batchID
                    )
                    let requestedIDs = materialized.operations.map(
                        \.operationID
                    )
                    let storedIDSet = Set(storedIDs)
                    let expectedStoredIDs = requestedIDs.filter {
                        storedIDSet.contains($0)
                    }
                    guard storedIDs == expectedStoredIDs else {
                        throw SyncV2EnqueueError.integrityFailure
                    }
                    return SyncV2EnqueueReceipt(
                        batchID: batch.batchID,
                        operationIDs: storedIDs,
                        noOpOperationIDs: requestedIDs.filter {
                            !storedIDSet.contains($0)
                        },
                        blockedOperations: try blockedOperations(
                            batchID: materialized.batchID
                        ),
                        replayed: true
                    )
                }

                try insertBatch(materialized)
                var noOpOperationIDs: [UUID] = []
                for operation in materialized.operations {
                    guard
                        try !operationIDExists(operation.operationID)
                    else {
                        throw SyncV2EnqueueError.operationIDReused
                    }
                    switch operation.payload {
                    case .ensureProject(let payload):
                        try insertEnsureProjectOperation(
                            operation,
                            batch: materialized,
                            payload: payload,
                            timestamp: materialized.timestamp
                        )
                    case .document(let payload):
                        let disposition = try insertDocumentOperation(
                            operation,
                            batch: materialized,
                            payload: payload,
                            timestamp: materialized.timestamp
                        )
                        if disposition == .noOp {
                            noOpOperationIDs.append(operation.operationID)
                        }
                    case .folder(let payload):
                        try insertFolderOperation(
                            operation,
                            batch: materialized,
                            payload: payload,
                            timestamp: materialized.timestamp
                        )
                    }
                }
                let insertedIDs = try operationIDs(
                    batchID: materialized.batchID
                )
                let noOpIDSet = Set(noOpOperationIDs)
                let expectedInsertedIDs = materialized.operations
                    .map(\.operationID)
                    .filter { !noOpIDSet.contains($0) }
                guard insertedIDs == expectedInsertedIDs else {
                    throw SyncV2EnqueueError.integrityFailure
                }
                let blocked = try blockedOperations(
                    batchID: materialized.batchID
                )
                try finalizeBatchAfterPreflight(
                    batchID: materialized.batchID,
                    insertedOperationCount: insertedIDs.count,
                    blockedOperationCount: blocked.count,
                    timestamp: materialized.timestamp
                )
                return SyncV2EnqueueReceipt(
                    batchID: batch.batchID,
                    operationIDs: insertedIDs,
                    noOpOperationIDs: noOpOperationIDs,
                    blockedOperations: blocked,
                    replayed: false
                )
            }
        } catch let error as SyncV2EnqueueError {
            throw error
        } catch let error as SyncV2StoreError {
            if case .sqlite(let code) = error {
                if code == sqliteConstraintUniqueCode
                    || code == sqliteConstraintPrimaryKeyCode {
                    throw SyncV2EnqueueError.invalidMutation
                }
                throw SyncV2EnqueueError.storageFailure(code: code)
            }
            throw SyncV2EnqueueError.integrityFailure
        } catch {
            throw SyncV2EnqueueError.storageFailure(
                code: currentSQLiteCode()
            )
        }
    }

    func queuedOperations(
        documentID: UUID? = nil
    ) throws -> [SyncV2QueuedOperation] {
        let sql: String
        if documentID == nil {
            sql = """
            SELECT operation_id, document_id, document_sequence,
                   operation_kind, status, base_revision, local_path,
                   relative_path, content, content_byte_count, content_hash,
                   is_deleted
            FROM sync_operations
            ORDER BY queue_id;
            """
        } else {
            sql = """
            SELECT operation_id, document_id, document_sequence,
                   operation_kind, status, base_revision, local_path,
                   relative_path, content, content_byte_count, content_hash,
                   is_deleted
            FROM sync_operations
            WHERE document_id = ?
            ORDER BY document_sequence, queue_id;
            """
        }
        return try withStatement(sql) { statement in
            if let documentID {
                try bind(
                    documentID.uuidString.lowercased(),
                    at: 1,
                    to: statement
                )
            }
            var operations: [SyncV2QueuedOperation] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return operations
                }
                guard status == SQLITE_ROW else {
                    throw sqliteError()
                }
                operations.append(
                    try queuedOperation(from: statement)
                )
            }
        }
    }

    func unresolvedConflict(
        documentID: UUID
    ) throws -> SyncV2ConflictRecord? {
        try withStatement(
            """
            SELECT conflict_id, operation_id, document_id,
                   base_content, local_content, remote_content,
                   merged_content, remote_revision, remote_path,
                   conflict_count, created_at
            FROM sync_conflicts
            WHERE document_id = ?
              AND resolved_at IS NULL
            LIMIT 1;
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw SyncV2StoreError.invalidStoredData
            }
            let conflict = try conflictRecord(from: statement)
            guard conflict.documentID == documentID else {
                throw SyncV2StoreError.invalidStoredData
            }
            return conflict
        }
    }

    func unresolvedConflicts(
        localProjectID: ProjectID
    ) throws -> [SyncV2ConflictRecord] {
        try withStatement(
            """
            SELECT c.conflict_id, c.operation_id, c.document_id,
                   c.base_content, c.local_content, c.remote_content,
                   c.merged_content, c.remote_revision, c.remote_path,
                   c.conflict_count, c.created_at
            FROM sync_conflicts c
            JOIN sync_documents d ON d.document_id = c.document_id
            WHERE d.local_project_id = ?
              AND c.resolved_at IS NULL
            ORDER BY c.created_at, c.conflict_id;
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            var conflicts: [SyncV2ConflictRecord] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return conflicts
                }
                guard status == SQLITE_ROW else {
                    throw SyncV2StoreError.invalidStoredData
                }
                conflicts.append(
                    try conflictRecord(from: statement)
                )
            }
        }
    }

    func schemaVersion() throws -> Int {
        try scalarInt("PRAGMA user_version;")
    }

    func journalMode() throws -> String {
        try scalarText("PRAGMA journal_mode;")
    }

    func operationCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM sync_operations;")
    }

    /// 작업의 지금 상태다.
    ///
    /// 저장된 칸이 아니라 사건 기록에서 계산한다. 칸은 계산 결과를 그대로
    /// 비추어 두는 자리일 뿐이고, 둘이 갈라지면 사건 쪽이 옳다. 기록이 아직
    /// 없는 작업만 칸을 그대로 읽는다.
    func operationStatus(
        operationID: UUID
    ) throws -> String? {
        let events = try operationEvents(operationID: operationID)
        if let derived = try? SyncV2OperationStateDerivation.state(from: events) {
            return derived.rawValue
        }
        return try storedOperationStatus(operationID: operationID)
    }

    private func storedOperationStatus(
        operationID: UUID
    ) throws -> String? {
        try withStatement(
            """
            SELECT status
            FROM sync_operations
            WHERE operation_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw sqliteError()
            }
            return columnText(statement, at: 0)
        }
    }

    func operationAttempts(
        operationID: UUID
    ) throws -> Int? {
        try withStatement(
            """
            SELECT attempts
            FROM sync_operations
            WHERE operation_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw sqliteError()
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func preservedSizeLimitResult(
        localProjectID: ProjectID,
        documentID: DocumentID
    ) throws -> DurableRecordResult? {
        try withStatement(
            """
            SELECT o.content_byte_count
            FROM sync_operations o
            JOIN sync_documents d ON d.document_id = o.document_id
            WHERE d.local_project_id = ?
              AND d.document_id = ?
              AND d.sync_state = 'blocked'
              AND d.last_error_code = ?
              AND o.status = 'blocked'
              AND o.last_error_code = ?
            ORDER BY o.document_sequence DESC, o.queue_id DESC
            LIMIT 1;
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                documentID.rawValue.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(Self.contentTooLargeErrorCode, at: 3, to: statement)
            try bind(Self.contentTooLargeErrorCode, at: 4, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw sqliteError()
            }
            return .serverSizeLimitExceeded(
                byteCount: Int(sqlite3_column_int64(statement, 0)),
                limit: Self.maximumContentByteCount
            )
        }
    }

    func recoverInterruptedWork() throws {
        do {
            try transaction {
                let timestamp = Self.timestamp()
                try recoverPersistedLeaseConflicts(
                    localProjectID: nil,
                    timestamp: timestamp
                )
                try recoverPersistedAlreadyExistsConflicts(
                    localProjectID: nil,
                    timestamp: timestamp
                )
                // ensure_project는 서버 ensure RPC가 성공하고 binding이 저장된
                // 뒤에 남기는 durable 감사 기록이다. 별도 dispatcher lane이
                // 없으므로 pending으로 두면 같은 초기 batch의 tree-order를
                // 영구히 막는다. 예전 빌드가 남긴 행도 완료로 정리한다.
                let settledEnsures = try prepareOperationEvents(
                    where: """
                    operation_kind = 'ensure_project'
                      AND status NOT IN ('completed', 'cancelled')
                      AND EXISTS (
                          SELECT 1 FROM sync_projects p
                          WHERE p.local_project_id =
                                sync_operations.local_project_id
                            AND p.server_project_id =
                                sync_operations.project_id
                            AND p.owner_subject =
                                sync_operations.owner_subject
                            AND p.binding_kind <> 'local_only'
                      )
                    """,
                    timestamp: timestamp
                )
                try execute(
                    """
                    UPDATE sync_operations
                    SET status = 'completed',
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = strftime(
                            '%Y-%m-%dT%H:%M:%fZ', 'now'
                        )
                    WHERE operation_kind = 'ensure_project'
                      AND status NOT IN ('completed', 'cancelled')
                      AND EXISTS (
                          SELECT 1 FROM sync_projects p
                          WHERE p.local_project_id =
                                sync_operations.local_project_id
                            AND p.server_project_id =
                                sync_operations.project_id
                            AND p.owner_subject =
                                sync_operations.owner_subject
                            AND p.binding_kind <> 'local_only'
                      );
                    """
                )
                try recordOperationEvents(
                    settledEnsures,
                    type: .committed,
                    errorCode: nil,
                    timestamp: timestamp
                )
                // 폴더 revision 충돌은 최신 folders snapshot 위로 자동 rebase할
                // 수 있다. 앱이 충돌을 기록한 직후 종료됐어도 다음 실행에서
                // dispatcher가 다시 받아 영구 대기에 남지 않게 한다.
                let rebasableFolders = try prepareOperationEvents(
                    where: """
                    folder_id IS NOT NULL
                      AND status = 'conflict'
                      AND last_error_code = 'REVISION_CONFLICT'
                    """,
                    timestamp: timestamp
                )
                try execute(
                    """
                    UPDATE sync_operations
                    SET status = 'pending',
                        attempts = 0,
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = strftime(
                            '%Y-%m-%dT%H:%M:%fZ', 'now'
                        )
                    WHERE folder_id IS NOT NULL
                      AND status = 'conflict'
                      AND last_error_code = 'REVISION_CONFLICT';
                    """
                )
                try recordOperationEvents(
                    rebasableFolders,
                    type: .enqueued,
                    errorCode: nil,
                    timestamp: timestamp
                )
                // 서버 프로젝트가 삭제 후 같은 UUID로 다시 만들어지는 등
                // 로컬 revision 기준선만 남은 경우, 이전 실행에서
                // DOCUMENT_NOT_FOUND로 막힌 첫 operation을 create로 되돌린다.
                // 같은 경로를 다른 UUID가 점유 중이면 서버가 PATH_CONFLICT로
                // 다시 거부하므로 기존 문서를 조용히 덮어쓰지 않는다.
                try execute(
                    """
                    UPDATE sync_documents
                    SET server_path = COALESCE((
                            SELECT o.relative_path
                            FROM sync_operations o
                            WHERE o.document_id = sync_documents.document_id
                              AND o.status = 'conflict'
                              AND o.last_error_code = 'DOCUMENT_NOT_FOUND'
                              AND o.is_deleted = 0
                              AND NOT EXISTS (
                                  SELECT 1
                                  FROM sync_operations earlier
                                  WHERE earlier.document_id = o.document_id
                                    AND earlier.document_sequence
                                        < o.document_sequence
                                    AND earlier.status NOT IN (
                                        'completed', 'cancelled'
                                    )
                              )
                            ORDER BY o.document_sequence, o.queue_id
                            LIMIT 1
                        ), server_path),
                        server_revision = 0,
                        base_content = '',
                        base_hash = '',
                        is_deleted = 0,
                        server_updated_at = NULL,
                        sync_state = 'pending',
                        last_error_code = NULL,
                        updated_at = strftime(
                            '%Y-%m-%dT%H:%M:%fZ', 'now'
                        )
                    WHERE document_id IN (
                        SELECT o.document_id
                        FROM sync_operations o
                        WHERE o.status = 'conflict'
                          AND o.last_error_code = 'DOCUMENT_NOT_FOUND'
                          AND o.is_deleted = 0
                          AND NOT EXISTS (
                              SELECT 1
                              FROM sync_operations earlier
                              WHERE earlier.document_id = o.document_id
                                AND earlier.document_sequence
                                    < o.document_sequence
                                AND earlier.status NOT IN (
                                    'completed', 'cancelled'
                                )
                          )
                    );
                    """
                )
                try execute(
                    """
                    UPDATE sync_operations
                    SET base_revision = 0,
                        base_content = '',
                        status = 'pending',
                        attempts = 0,
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = strftime(
                            '%Y-%m-%dT%H:%M:%fZ', 'now'
                        )
                    WHERE status = 'conflict'
                      AND last_error_code = 'DOCUMENT_NOT_FOUND'
                      AND is_deleted = 0
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_operations earlier
                          WHERE earlier.document_id =
                                sync_operations.document_id
                            AND earlier.document_sequence
                                < sync_operations.document_sequence
                            AND earlier.status NOT IN (
                                'completed', 'cancelled'
                            )
                      );
                    """
                )
                // 이전 실행에서 권한·인증 상태 때문에 막힌 문서별 선두 작업을
                // 한 번 다시 검증한다. 후속 작업은 순서를 지키며 그대로 대기한다.
                try recoverPersistedForbiddenBlocks(
                    localProjectID: nil,
                    timestamp: timestamp
                )
                // 발송 도중 앱이 꺼진 작업이다. 계속 발송 중이라고 믿으면
                // 아무도 다시 손대지 않아 영영 대기에 남는다.
                let interrupted = try prepareOperationEvents(
                    where: "status = 'inflight'",
                    timestamp: timestamp
                )
                try execute(
                    """
                    UPDATE sync_operations
                    SET status = 'pending',
                        next_attempt_at = NULL,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                    WHERE status = 'inflight';
                    """
                )
                try recordOperationEvents(
                    interrupted,
                    type: .enqueued,
                    errorCode: nil,
                    timestamp: timestamp
                )
                try execute(
                    """
                    UPDATE sync_batches
                    SET status = CASE
                        WHEN EXISTS (
                            SELECT 1 FROM sync_operations o
                            WHERE o.batch_id = sync_batches.batch_id
                              AND o.status IN ('conflict', 'blocked')
                        ) THEN 'attention'
                        WHEN EXISTS (
                            SELECT 1 FROM sync_operations o
                            WHERE o.batch_id = sync_batches.batch_id
                              AND o.status NOT IN ('completed', 'cancelled')
                        ) THEN 'ready'
                        ELSE 'completed'
                    END,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                    """
                )
                // 상태 정리가 모두 끝난 뒤에 사건 기록을 채운다. 앞의 정리들이
                // status를 바꾸므로, 먼저 채우면 기록과 칸이 어긋난 채로 남는다.
                try backfillOperationEvents()
            }
        } catch {
            throw SyncV2StoreError.unavailable(
                Self.diagnostic(
                    .recoveryFailed,
                    sqliteCode: currentSQLiteCode()
                )
            )
        }
    }

    func claimReadyOperations(
        limit: Int,
        now: Date
    ) throws -> [SyncV2DispatchOperation] {
        try claimReadyOperations(
            localProjectID: nil,
            limit: limit,
            now: now
        )
    }

    func readyLocalProjectIDs(
        now: Date
    ) throws -> [ProjectID] {
        guard availability() == .available else {
            throw SyncV2DispatchStoreError.unavailable
        }
        let nowValue = Self.timestamp(now)
        return try withStatement(
            """
            SELECT o.local_project_id
            FROM sync_operations o
            WHERE o.local_project_id IS NOT NULL
              AND o.base_revision IS NOT NULL
              AND (
                  o.status = 'pending'
                  OR (
                      o.status = 'retry_wait'
                      AND (
                          o.next_attempt_at IS NULL
                          OR o.next_attempt_at <= ?
                      )
                  )
              )
              AND (
                  (
                      o.document_id IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_operations earlier
                          WHERE earlier.document_id = o.document_id
                            AND earlier.document_sequence
                                < o.document_sequence
                            AND earlier.status NOT IN (
                                'completed', 'cancelled'
                            )
                      )
                      AND (
                          o.operation_kind = 'tree_order'
                          OR NOT EXISTS (
                              SELECT 1
                              FROM sync_operations folderDependency
                              WHERE folderDependency.batch_id = o.batch_id
                                AND folderDependency.folder_id IS NOT NULL
                                AND folderDependency.status NOT IN (
                                    'completed', 'cancelled'
                                )
                          )
                      )
                      AND (
                          o.operation_kind <> 'tree_order'
                          OR NOT EXISTS (
                              SELECT 1
                              FROM sync_operations batchDependency
                              WHERE batchDependency.batch_id = o.batch_id
                                AND batchDependency.operation_id
                                    <> o.operation_id
                                AND batchDependency.status NOT IN (
                                    'completed', 'cancelled'
                                )
                          )
                      )
                      AND (
                          o.operation_kind <> 'tree_order'
                          OR NOT EXISTS (
                              SELECT 1
                              FROM sync_operations structuralDependency
                              JOIN sync_batches structuralBatch
                                ON structuralBatch.batch_id
                                    = structuralDependency.batch_id
                              WHERE structuralDependency.local_project_id
                                    = o.local_project_id
                                AND structuralDependency.queue_id < o.queue_id
                                AND structuralDependency.status NOT IN (
                                    'completed', 'cancelled'
                                )
                                AND structuralBatch.batch_kind IN (
                                    'structure_change', 'volume_creation',
                                    'trash_change', 'backup_restore',
                                    'windows_import'
                                )
                          )
                      )
                  )
                  OR (
                      o.folder_id IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_operations earlier
                          WHERE earlier.folder_id = o.folder_id
                            AND earlier.document_sequence
                                < o.document_sequence
                            AND earlier.status NOT IN (
                                'completed', 'cancelled'
                            )
                      )
                      AND (
                          o.is_deleted = 1
                          OR NOT EXISTS (
                              SELECT 1
                              FROM sync_operations parentOperation
                              WHERE parentOperation.folder_id
                                    = o.parent_folder_id
                                AND parentOperation.status NOT IN (
                                    'completed', 'cancelled'
                                )
                          )
                      )
                  )
              )
            GROUP BY o.local_project_id
            ORDER BY MIN(o.queue_id);
            """
        ) { statement in
            try bind(nowValue, at: 1, to: statement)
            var projectIDs: [ProjectID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return projectIDs
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                projectIDs.append(ProjectID(rawValue: identifier))
            }
        }
    }

    func claimReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) throws -> [SyncV2DispatchOperation] {
        try claimReadyOperations(
            localProjectID: Optional(localProjectID),
            limit: limit,
            now: now
        )
    }

    private func claimReadyOperations(
        localProjectID: ProjectID?,
        limit: Int,
        now: Date
    ) throws -> [SyncV2DispatchOperation] {
        guard availability() == .available else {
            throw SyncV2DispatchStoreError.unavailable
        }
        guard limit > 0 else { return [] }
        let nowValue = Self.timestamp(now)
        do {
            return try transaction {
                let candidates = try dispatchCandidates(
                    localProjectID: localProjectID,
                    limit: limit,
                    nowValue: nowValue
                )
                for operation in candidates {
                    let operationKey = operation.operationID.uuidString.lowercased()
                    try ensureOperationEventHistory(
                        operationID: operationKey,
                        timestamp: nowValue
                    )
                    try withStatement(
                        """
                        UPDATE sync_operations
                        SET status = 'inflight',
                            attempts = attempts + 1,
                            next_attempt_at = NULL,
                            updated_at = ?
                        WHERE operation_id = ?
                          AND status IN ('pending', 'retry_wait');
                        """
                    ) { statement in
                        try bind(nowValue, at: 1, to: statement)
                        try bind(operationKey, at: 2, to: statement)
                        try stepDone(statement)
                        guard sqlite3_changes(connection.handle) == 1 else {
                            throw SyncV2DispatchStoreError
                                .operationStateChanged
                        }
                    }
                    try appendOperationEvent(
                        operationID: operationKey,
                        type: .dispatchStarted,
                        errorCode: nil,
                        timestamp: nowValue
                    )
                    try withStatement(
                        """
                        UPDATE sync_batches
                        SET status = 'processing', updated_at = ?
                        WHERE batch_id = ?;
                        """
                    ) { statement in
                        try bind(nowValue, at: 1, to: statement)
                        try bind(
                            operation.batchID.uuidString.lowercased(),
                            at: 2,
                            to: statement
                        )
                        try stepDone(statement)
                    }
                }
                return candidates.map {
                    SyncV2DispatchOperation(
                        operationID: $0.operationID,
                        batchID: $0.batchID,
                        localProjectID: $0.localProjectID,
                        projectID: $0.projectID,
                        documentID: $0.documentID,
                        deviceID: $0.deviceID,
                        documentSequence: $0.documentSequence,
                        localSaveGeneration: $0.localSaveGeneration,
                        kind: $0.kind,
                        baseRevision: $0.baseRevision,
                        baseContent: $0.baseContent,
                        baseServerPath: $0.baseServerPath,
                        localPath: $0.localPath,
                        relativePath: $0.relativePath,
                        content: $0.content,
                        isDeleted: $0.isDeleted,
                        attempts: $0.attempts + 1
                    )
                }
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    func claimReadyFolderOperations(
        limit: Int,
        now: Date
    ) throws -> [SyncV2FolderDispatchOperation] {
        try claimReadyFolderOperations(
            localProjectID: nil,
            limit: limit,
            now: now
        )
    }

    func claimReadyFolderOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) throws -> [SyncV2FolderDispatchOperation] {
        try claimReadyFolderOperations(
            localProjectID: Optional(localProjectID),
            limit: limit,
            now: now
        )
    }

    /// 폴더 대기열은 문서와 나란히 흐른다. 서로 다른 줄이므로 한쪽이 막혀도
    /// 다른 쪽은 계속 나간다. 같은 폴더 안에서는 순번대로만 나간다.
    private func claimReadyFolderOperations(
        localProjectID: ProjectID?,
        limit: Int,
        now: Date
    ) throws -> [SyncV2FolderDispatchOperation] {
        guard availability() == .available else {
            throw SyncV2DispatchStoreError.unavailable
        }
        guard limit > 0 else { return [] }
        let nowValue = Self.timestamp(now)
        return try transaction {
            let candidates = try folderDispatchCandidates(
                localProjectID: localProjectID,
                limit: limit,
                nowValue: nowValue
            )
            for operation in candidates {
                let operationKey = operation.operationID.uuidString.lowercased()
                try ensureOperationEventHistory(
                    operationID: operationKey,
                    timestamp: nowValue
                )
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET status = 'inflight',
                        attempts = attempts + 1,
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE operation_id = ?
                      AND status IN ('pending', 'retry_wait');
                    """
                ) { statement in
                    try bind(nowValue, at: 1, to: statement)
                    try bind(operationKey, at: 2, to: statement)
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.operationStateChanged
                    }
                }
                try appendOperationEvent(
                    operationID: operationKey,
                    type: .dispatchStarted,
                    errorCode: nil,
                    timestamp: nowValue
                )
                try withStatement(
                    """
                    UPDATE sync_batches
                    SET status = 'processing', updated_at = ?
                    WHERE batch_id = ?;
                    """
                ) { statement in
                    try bind(nowValue, at: 1, to: statement)
                    try bind(
                        operation.batchID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try stepDone(statement)
                }
            }
            return candidates
        }
    }

    private func folderDispatchCandidates(
        localProjectID: ProjectID?,
        limit: Int,
        nowValue: String
    ) throws -> [SyncV2FolderDispatchOperation] {
        try withStatement(
            """
            -- 서버는 내용이 있는 폴더의 삭제를 거부한다. 폴더가 자기 경로를
            -- 알아야 그 아래 문서 작업이 끝났는지 볼 수 있는데, sync_folders는
            -- 경로를 두지 않으므로 부모 사슬을 따라 여기서 만든다. 사슬이 고리를
            -- 이루면 끝나지 않으므로 깊이로 막는다.
            WITH RECURSIVE folder_path(folder_id, path, depth) AS (
                SELECT folder_id, name, 1
                FROM sync_folders
                WHERE parent_folder_id IS NULL
                UNION ALL
                SELECT f.folder_id, fp.path || '/' || f.name, fp.depth + 1
                FROM sync_folders f
                JOIN folder_path fp ON f.parent_folder_id = fp.folder_id
                WHERE fp.depth < 64
            )
            SELECT o.operation_id, o.batch_id, o.local_project_id,
                   o.project_id, o.folder_id, o.parent_folder_id,
                   o.device_id, o.document_sequence, o.folder_name,
                   o.base_revision, o.is_deleted, o.attempts
            FROM sync_operations o
            LEFT JOIN folder_path fp ON fp.folder_id = o.folder_id
            WHERE o.folder_id IS NOT NULL
              AND o.base_revision IS NOT NULL
              AND (? IS NULL OR o.local_project_id = ?)
              AND (
                  o.status = 'pending'
                  OR (
                      o.status = 'retry_wait'
                      AND (
                          o.next_attempt_at IS NULL
                          OR o.next_attempt_at <= ?
                      )
                  )
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_operations earlier
                  WHERE earlier.folder_id = o.folder_id
                    AND earlier.document_sequence < o.document_sequence
                    AND earlier.status NOT IN ('completed', 'cancelled')
              )
              AND (
                  (
                      o.is_deleted = 0
                      -- 생성·이동·복원은 부모 폴더의 현재
                      -- 작업을 먼저 확정해 FOLDER_NOT_FOUND를 막는다.
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_operations parentOperation
                          WHERE parentOperation.folder_id = o.parent_folder_id
                            AND parentOperation.status NOT IN (
                                'completed', 'cancelled'
                            )
                      )
                  )
                  OR (
                      o.is_deleted = 1
                      -- 바로 아래 폴더만 본다. 그 폴더도 자기 자식을 기다리므로
                      -- 가장 깊은 곳부터 차례로 풀린다.
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_folders child
                          JOIN sync_operations childOperation
                              ON childOperation.folder_id = child.folder_id
                          WHERE child.parent_folder_id = o.folder_id
                            AND childOperation.status NOT IN (
                                'completed', 'cancelled'
                            )
                      )
                      -- 폴더 안 문서가 아직 남아 있으면 부모를 먼저 지울 수
                      -- 없다. LIKE는 이름에 %나 _가 있으면 어긋나므로 앞부분을
                      -- 그대로 잘라 비교한다.
                      AND NOT EXISTS (
                          SELECT 1
                          FROM sync_operations documentOperation
                          WHERE documentOperation.document_id IS NOT NULL
                            AND documentOperation.status NOT IN (
                                'completed', 'cancelled'
                            )
                            AND fp.path IS NOT NULL
                            AND substr(
                                documentOperation.relative_path,
                                1,
                                length(fp.path) + 1
                            ) = fp.path || '/'
                      )
                  )
              )
            ORDER BY o.queue_id
            """
        ) { statement in
            let projectValue =
                localProjectID?.rawValue.uuidString.lowercased()
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(nowValue, at: 3, to: statement)
            var candidates: [SyncV2FolderDispatchOperation] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return candidates
                }
                guard
                    status == SQLITE_ROW,
                    let operationValue = columnText(statement, at: 0),
                    let operationID = UUID(uuidString: operationValue),
                    let batchValue = columnText(statement, at: 1),
                    let batchID = UUID(uuidString: batchValue),
                    let localProjectValue = columnText(statement, at: 2),
                    let localProjectID = UUID(uuidString: localProjectValue),
                    let projectValue = columnText(statement, at: 3),
                    let projectID = UUID(uuidString: projectValue),
                    let folderValue = columnText(statement, at: 4),
                    let folderID = UUID(uuidString: folderValue),
                    let deviceValue = columnText(statement, at: 6),
                    let deviceID = UUID(uuidString: deviceValue),
                    let name = columnText(statement, at: 8)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                let parentFolderID: UUID?
                if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                    parentFolderID = nil
                } else {
                    guard
                        let parentValue = columnText(statement, at: 5),
                        let parsed = UUID(uuidString: parentValue)
                    else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    parentFolderID = parsed
                }
                candidates.append(
                    SyncV2FolderDispatchOperation(
                        operationID: operationID,
                        batchID: batchID,
                        localProjectID: ProjectID(rawValue: localProjectID),
                        projectID: projectID,
                        folderID: folderID,
                        parentFolderID: parentFolderID,
                        deviceID: deviceID,
                        folderSequence: Int(
                            sqlite3_column_int64(statement, 7)
                        ),
                        name: name,
                        baseRevision: sqlite3_column_int64(statement, 9),
                        isDeleted: sqlite3_column_int(statement, 10) == 1,
                        attempts: Int(sqlite3_column_int(statement, 11)) + 1
                    )
                )
                if candidates.count == limit {
                    return candidates
                }
            }
        }
    }

    func complete(
        _ operation: SyncV2DispatchOperation,
        result: SyncV2CommitDocumentResult
    ) throws {
        guard
            result.operationID == operation.operationID,
            result.documentID == operation.documentID,
            result.serverRevision == operation.baseRevision + 1,
            SyncV2ServerPath.hasExactBytes(
                result.relativePath,
                SyncV2ServerPath.canonical(operation.relativePath)
            ),
            result.isDeleted == operation.isDeleted
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        do {
            try transaction {
                try transitionInflightOperation(
                    operation,
                    status: .completed,
                    errorCode: nil,
                    detail: nil,
                    nextAttemptAt: nil,
                    timestamp: timestamp,
                    // 같은 작업을 다시 보내 받은 멱등 응답이면 그대로 적는다.
                    // 처음 올린 것과 다시 확인한 것은 다른 일이다.
                    eventType: result.status == .replayed ? .replayed : .committed
                )
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET server_path = ?,
                        server_revision = ?,
                        base_content = ?,
                        base_hash = ?,
                        is_deleted = ?,
                        server_updated_at = ?,
                        sync_state = CASE
                            WHEN EXISTS (
                                SELECT 1
                                FROM sync_operations pending
                                WHERE pending.document_id = ?
                                  AND pending.status NOT IN (
                                      'completed', 'cancelled'
                                  )
                            ) THEN 'pending'
                            ELSE 'synced'
                        END,
                        last_error_code = NULL,
                        last_applied_operation_id = ?,
                        updated_at = ?
                    WHERE document_id = ?;
                    """
                ) { statement in
                    try bind(result.relativePath, at: 1, to: statement)
                    try bind(result.serverRevision, at: 2, to: statement)
                    try bind(operation.content, at: 3, to: statement)
                    try bind(result.contentHash, at: 4, to: statement)
                    try bind(result.isDeleted ? 1 : 0, at: 5, to: statement)
                    try bind(Self.timestamp(result.committedAt), at: 6, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 7,
                        to: statement
                    )
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 8,
                        to: statement
                    )
                    try bind(timestamp, at: 9, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 10,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                }
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET base_revision = ?,
                        base_content = ?,
                        updated_at = ?
                    WHERE document_id = ?
                      AND document_sequence = ?
                      AND status IN ('pending', 'retry_wait')
                      AND base_revision IS NULL;
                    """
                ) { statement in
                    try bind(result.serverRevision, at: 1, to: statement)
                    try bind(operation.content, at: 2, to: statement)
                    try bind(timestamp, at: 3, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 4,
                        to: statement
                    )
                    try bind(operation.documentSequence + 1, at: 5, to: statement)
                    try stepDone(statement)
                }
                try refreshBatchState(
                    batchID: operation.batchID,
                    timestamp: timestamp
                )
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    /// 서버가 준 revision을 폴더에 남기고, 같은 폴더의 다음 작업이 그 값을
    /// 기준선으로 삼게 이어 준다. 문서 쪽과 같은 사슬이다.
    func complete(
        _ operation: SyncV2FolderDispatchOperation,
        result: SyncV2CommitFolderResult
    ) throws {
        guard
            result.operationID == operation.operationID,
            result.folderID == operation.folderID,
            result.serverRevision == operation.baseRevision + 1,
            result.isDeleted == operation.isDeleted
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        try transaction {
            try transitionInflightOperation(
                operationID: operation.operationID,
                attempts: operation.attempts,
                status: .completed,
                errorCode: nil,
                detail: nil,
                nextAttemptAt: nil,
                timestamp: timestamp,
                eventType: result.status == .replayed ? .replayed : .committed
            )
            try withStatement(
                """
                UPDATE sync_folders
                SET server_revision = ?,
                    is_deleted = ?,
                    server_updated_at = ?,
                    sync_state = CASE
                        WHEN EXISTS (
                            SELECT 1
                            FROM sync_operations pending
                            WHERE pending.folder_id = ?
                              AND pending.status NOT IN (
                                  'completed', 'cancelled'
                              )
                        ) THEN 'pending'
                        ELSE 'synced'
                    END,
                    last_error_code = NULL,
                    last_applied_operation_id = ?,
                    updated_at = ?
                WHERE folder_id = ?;
                """
            ) { statement in
                let folderValue = operation.folderID.uuidString.lowercased()
                try bind(result.serverRevision, at: 1, to: statement)
                try bind(result.isDeleted ? 1 : 0, at: 2, to: statement)
                try bind(
                    Self.timestamp(result.committedAt),
                    at: 3,
                    to: statement
                )
                try bind(folderValue, at: 4, to: statement)
                try bind(
                    operation.operationID.uuidString.lowercased(),
                    at: 5,
                    to: statement
                )
                try bind(timestamp, at: 6, to: statement)
                try bind(folderValue, at: 7, to: statement)
                try stepDone(statement)
                guard sqlite3_changes(connection.handle) == 1 else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
            }
            try withStatement(
                """
                UPDATE sync_operations
                SET base_revision = ?,
                    updated_at = ?
                WHERE folder_id = ?
                  AND document_sequence = ?
                  AND status IN ('pending', 'retry_wait')
                  AND base_revision IS NULL;
                """
            ) { statement in
                try bind(result.serverRevision, at: 1, to: statement)
                try bind(timestamp, at: 2, to: statement)
                try bind(
                    operation.folderID.uuidString.lowercased(),
                    at: 3,
                    to: statement
                )
                try bind(
                    operation.folderSequence + 1,
                    at: 4,
                    to: statement
                )
                try stepDone(statement)
            }
            try refreshBatchState(
                batchID: operation.batchID,
                timestamp: timestamp
            )
        }
    }

    func deferRetry(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) throws {
        try recordFolderDispatchFailure(
            operation,
            status: .retryWait,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nextAttemptAt
        )
    }

    func markConflict(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) throws {
        try recordFolderDispatchFailure(
            operation,
            status: .conflict,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nil
        )
    }

    func markBlocked(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) throws {
        try recordFolderDispatchFailure(
            operation,
            status: .blocked,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nil
        )
    }

    func rebaseFolderAfterRevisionConflict(
        _ operation: SyncV2FolderDispatchOperation,
        remote: SyncV2RemoteFolder
    ) async throws {
        guard
            remote.folderID == operation.folderID,
            remote.revision > operation.baseRevision,
            !remote.isDeleted || operation.isDeleted
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        try transaction {
            try withStatement(
                """
                UPDATE sync_operations
                SET base_revision = ?,
                    status = 'pending',
                    attempts = 0,
                    last_error_code = NULL,
                    last_error_detail = NULL,
                    next_attempt_at = NULL,
                    updated_at = ?
                WHERE operation_id = ?
                  AND folder_id = ?
                  AND status = 'inflight'
                  AND attempts = ?;
                """
            ) { statement in
                try bind(remote.revision, at: 1, to: statement)
                try bind(timestamp, at: 2, to: statement)
                try bind(
                    operation.operationID.uuidString.lowercased(),
                    at: 3,
                    to: statement
                )
                try bind(
                    operation.folderID.uuidString.lowercased(),
                    at: 4,
                    to: statement
                )
                try bind(operation.attempts, at: 5, to: statement)
                try stepDone(statement)
                guard sqlite3_changes(connection.handle) == 1 else {
                    throw SyncV2DispatchStoreError.operationStateChanged
                }
            }
            // name과 parent는 사용자가 막 바꾼 로컬 목표값이므로 유지한다.
            // 여기서는 서버에서 확인한 기준 revision만 전진시킨다.
            try withStatement(
                """
                UPDATE sync_folders
                SET server_revision = ?,
                    server_updated_at = ?,
                    sync_state = 'pending',
                    last_error_code = NULL,
                    updated_at = ?
                WHERE folder_id = ?
                  AND local_project_id = ?
                  AND project_id = ?;
                """
            ) { statement in
                try bind(remote.revision, at: 1, to: statement)
                try bind(Self.timestamp(remote.updatedAt), at: 2, to: statement)
                try bind(timestamp, at: 3, to: statement)
                try bind(
                    operation.folderID.uuidString.lowercased(),
                    at: 4,
                    to: statement
                )
                try bind(
                    operation.localProjectID.rawValue.uuidString.lowercased(),
                    at: 5,
                    to: statement
                )
                try bind(operation.projectID.uuidString.lowercased(), at: 6, to: statement)
                try stepDone(statement)
                guard sqlite3_changes(connection.handle) == 1 else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
            }
            try refreshBatchState(
                batchID: operation.batchID,
                timestamp: timestamp
            )
        }
    }

    private func recordFolderDispatchFailure(
        _ operation: SyncV2FolderDispatchOperation,
        status: SyncV2OperationStatus,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date?
    ) throws {
        let timestamp = Self.timestamp()
        try transaction {
            try transitionInflightOperation(
                operationID: operation.operationID,
                attempts: operation.attempts,
                status: status,
                errorCode: errorCode,
                detail: detail,
                nextAttemptAt: nextAttemptAt,
                timestamp: timestamp
            )
            try withStatement(
                """
                UPDATE sync_folders
                SET sync_state = ?,
                    last_error_code = ?,
                    updated_at = ?
                WHERE folder_id = ?;
                """
            ) { statement in
                let folderState =
                    status == .conflict ? "conflict"
                    : status == .blocked ? "blocked"
                    : "pending"
                try bind(folderState, at: 1, to: statement)
                try bind(errorCode, at: 2, to: statement)
                try bind(timestamp, at: 3, to: statement)
                try bind(
                    operation.folderID.uuidString.lowercased(),
                    at: 4,
                    to: statement
                )
                try stepDone(statement)
            }
            try refreshBatchState(
                batchID: operation.batchID,
                timestamp: timestamp
            )
        }
    }

    func deferRetry(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) throws {
        try recordDispatchFailure(
            operation,
            status: .retryWait,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nextAttemptAt
        )
    }

    func markConflict(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) throws {
        try recordDispatchFailure(
            operation,
            status: .conflict,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nil
        )
    }

    func preserveConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        conflictCount: Int,
        errorCode: String,
        detail: String?
    ) async throws -> SyncV2ConflictPreservationResult {
        guard remote.documentID == operation.documentID,
              remote.revision > operation.baseRevision,
              !remote.isDeleted,
              validRelativePath(remote.relativePath),
              conflictCount > 0
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        let conflictID = UUID()
        do {
            return try transaction {
                let latest = try latestLocalSnapshotValue(for: operation)
                guard Self.isSameLocalGeneration(
                    latest,
                    as: local
                ) else {
                    try returnInflightToPending(
                        operation,
                        errorCode: "LOCAL_GENERATION_ADVANCED",
                        timestamp: timestamp
                    )
                    return .localGenerationAdvanced
                }

                let affectedBatchIDs = try activeBatchIDs(
                    documentID: operation.documentID
                )
                let superseded = try prepareSupersededSiblings(
                    documentID: operation.documentID,
                    survivingOperationID: operation.operationID,
                    timestamp: timestamp
                )
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET status = 'cancelled',
                        last_error_code = 'SUPERSEDED_BY_CONFLICT_SNAPSHOT',
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE document_id = ?
                      AND operation_id <> ?
                      AND status NOT IN ('completed', 'cancelled');
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try stepDone(statement)
                }
                // 밀려난 작업마다 누구에게 밀렸는지 함께 적는다. 나중에 왜
                // 사라졌는지 되짚으려면 가리킬 상대가 있어야 한다.
                try recordOperationEvents(
                    superseded,
                    type: .superseded,
                    errorCode: "SUPERSEDED_BY_CONFLICT_SNAPSHOT",
                    timestamp: timestamp,
                    relatedOperationID:
                        operation.operationID.uuidString.lowercased()
                )
                try transitionInflightOperation(
                    operation,
                    status: .conflict,
                    errorCode: errorCode,
                    detail: detail,
                    nextAttemptAt: nil,
                    timestamp: timestamp
                )
                try withStatement(
                    """
                    INSERT INTO sync_conflicts(
                        conflict_id, operation_id, document_id,
                        base_content, local_content, remote_content,
                        merged_content, remote_revision, remote_path,
                        conflict_count, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """
                ) { statement in
                    try bind(
                        conflictID.uuidString.lowercased(),
                        at: 1,
                        to: statement
                    )
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try bind(operation.baseContent, at: 4, to: statement)
                    try bind(local.content, at: 5, to: statement)
                    try bind(remote.content, at: 6, to: statement)
                    try bind(mergedContent, at: 7, to: statement)
                    try bind(remote.revision, at: 8, to: statement)
                    try bind(remote.relativePath, at: 9, to: statement)
                    try bind(conflictCount, at: 10, to: statement)
                    try bind(timestamp, at: 11, to: statement)
                    try stepDone(statement)
                }

                let remoteHash = Self.sha256Hex(Data(remote.content.utf8))
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET server_path = ?,
                        server_revision = ?,
                        base_content = ?,
                        base_hash = ?,
                        is_deleted = 0,
                        server_updated_at = ?,
                        sync_state = 'conflict',
                        last_error_code = ?,
                        updated_at = ?
                    WHERE document_id = ?;
                    """
                ) { statement in
                    try bind(remote.relativePath, at: 1, to: statement)
                    try bind(remote.revision, at: 2, to: statement)
                    try bind(remote.content, at: 3, to: statement)
                    try bind(remoteHash, at: 4, to: statement)
                    try bind(Self.timestamp(remote.updatedAt), at: 5, to: statement)
                    try bind(errorCode, at: 6, to: statement)
                    try bind(timestamp, at: 7, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 8,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                }
                for batchID in affectedBatchIDs {
                    try refreshBatchState(
                        batchID: batchID,
                        timestamp: timestamp
                    )
                }
                return .preserved
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    func resolveConflict(
        _ request: SyncV2ConflictResolutionRequest
    ) throws {
        let resolvedData = Data(request.resolvedContent.utf8)
        guard resolvedData.count <= Self.maximumContentByteCount else {
            throw SyncV2ConflictResolutionError.contentTooLarge(
                byteCount: resolvedData.count,
                limit: Self.maximumContentByteCount
            )
        }
        let timestamp = Self.timestamp()
        do {
            try transaction {
                guard let conflict = try unresolvedConflict(
                    documentID: request.documentID
                ) else {
                    throw SyncV2ConflictResolutionError.conflictNotFound
                }
                guard conflict.conflictID == request.conflictID,
                      conflict.operationID != request.resolutionOperationID
                else {
                    throw SyncV2ConflictResolutionError.conflictChanged
                }
                switch request.kind {
                case .keepLocal:
                    guard request.resolvedContent
                        == conflict.snapshot.localContent
                    else {
                        throw SyncV2ConflictResolutionError.integrityFailure
                    }
                case .useRemote:
                    guard request.resolvedContent
                        == conflict.snapshot.remoteContent
                    else {
                        throw SyncV2ConflictResolutionError.integrityFailure
                    }
                case .manualMerge:
                    break
                }

                let resolution = try conflictResolutionOperation(
                    operationID: request.resolutionOperationID,
                    documentID: request.documentID
                )
                guard resolution.content == request.resolvedContent,
                      resolution.kind == .documentCommit,
                      resolution.status == .pending,
                      !resolution.isDeleted
                else {
                    throw SyncV2ConflictResolutionError
                        .resolutionOperationNotReady
                }
                let conflictSequence = try operationSequence(
                    operationID: conflict.operationID,
                    documentID: request.documentID,
                    expectedStatus: .conflict
                )
                guard resolution.documentSequence > conflictSequence,
                      try latestActiveResolutionSequence(
                        documentID: request.documentID,
                        excluding: conflict.operationID
                      ) == resolution.documentSequence
                else {
                    throw SyncV2ConflictResolutionError
                        .resolutionOperationNotReady
                }
                guard try documentMatches(
                    conflict: conflict,
                    localProjectID: resolution.localProjectID
                ) else {
                    throw SyncV2ConflictResolutionError.conflictChanged
                }

                let affectedBatchIDs = try activeBatchIDs(
                    documentID: request.documentID
                )
                let superseded = try prepareSupersededSiblings(
                    documentID: request.documentID,
                    survivingOperationID: request.resolutionOperationID,
                    timestamp: timestamp
                )
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET status = 'cancelled',
                        last_error_code =
                            'SUPERSEDED_BY_CONFLICT_RESOLUTION',
                        last_error_detail = ?,
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE document_id = ?
                      AND operation_id <> ?
                      AND status NOT IN ('completed', 'cancelled');
                    """
                ) { statement in
                    try bind(
                        request.resolutionOperationID.uuidString.lowercased(),
                        at: 1,
                        to: statement
                    )
                    try bind(timestamp, at: 2, to: statement)
                    try bind(
                        request.documentID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try bind(
                        request.resolutionOperationID.uuidString.lowercased(),
                        at: 4,
                        to: statement
                    )
                    try stepDone(statement)
                }
                try recordOperationEvents(
                    superseded,
                    type: .superseded,
                    errorCode: "SUPERSEDED_BY_CONFLICT_RESOLUTION",
                    timestamp: timestamp,
                    relatedOperationID:
                        request.resolutionOperationID.uuidString.lowercased()
                )
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET base_revision = ?,
                        base_content = ?,
                        status = 'pending',
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE operation_id = ?
                      AND document_id = ?
                      AND status = 'pending';
                    """
                ) { statement in
                    try bind(
                        conflict.snapshot.remoteRevision,
                        at: 1,
                        to: statement
                    )
                    try bind(
                        conflict.snapshot.remoteContent,
                        at: 2,
                        to: statement
                    )
                    try bind(timestamp, at: 3, to: statement)
                    try bind(
                        request.resolutionOperationID.uuidString.lowercased(),
                        at: 4,
                        to: statement
                    )
                    try bind(
                        request.documentID.uuidString.lowercased(),
                        at: 5,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2ConflictResolutionError
                            .resolutionOperationNotReady
                    }
                }
                try withStatement(
                    """
                    UPDATE sync_conflicts
                    SET resolved_at = ?, resolution_kind = ?
                    WHERE conflict_id = ?
                      AND operation_id = ?
                      AND document_id = ?
                      AND resolved_at IS NULL;
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(request.kind.rawValue, at: 2, to: statement)
                    try bind(
                        request.conflictID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try bind(
                        conflict.operationID.uuidString.lowercased(),
                        at: 4,
                        to: statement
                    )
                    try bind(
                        request.documentID.uuidString.lowercased(),
                        at: 5,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2ConflictResolutionError.conflictChanged
                    }
                }
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET sync_state = 'pending',
                        last_error_code = NULL,
                        updated_at = ?
                    WHERE document_id = ?
                      AND local_project_id = ?
                      AND server_revision = ?
                      AND server_path = ?
                      AND base_content = ?
                      AND sync_state IN ('conflict', 'pending');
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(
                        request.documentID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        resolution.localProjectID.rawValue.uuidString
                            .lowercased(),
                        at: 3,
                        to: statement
                    )
                    try bind(
                        conflict.snapshot.remoteRevision,
                        at: 4,
                        to: statement
                    )
                    try bind(
                        conflict.snapshot.remotePath,
                        at: 5,
                        to: statement
                    )
                    try bind(
                        conflict.snapshot.remoteContent,
                        at: 6,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2ConflictResolutionError.conflictChanged
                    }
                }
                for batchID in affectedBatchIDs {
                    try refreshBatchState(
                        batchID: batchID,
                        timestamp: timestamp
                    )
                }
            }
        } catch let error as SyncV2ConflictResolutionError {
            throw error
        } catch {
            throw error
        }
    }

    func markBlocked(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) throws {
        try recordDispatchFailure(
            operation,
            status: .blocked,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nil
        )
    }

    func recoverMissingRemoteDocument(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        guard operation.baseRevision > 0, !operation.isDeleted else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        do {
            try transaction {
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET base_revision = 0,
                        base_content = '',
                        status = 'pending',
                        attempts = 0,
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE operation_id = ?
                      AND status = 'inflight'
                      AND attempts = ?;
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(operation.attempts, at: 3, to: statement)
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError
                            .operationStateChanged
                    }
                }
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET server_path = ?,
                        server_revision = 0,
                        base_content = '',
                        base_hash = '',
                        is_deleted = 0,
                        server_updated_at = NULL,
                        sync_state = 'pending',
                        last_error_code = NULL,
                        updated_at = ?
                    WHERE document_id = ?;
                    """
                ) { statement in
                    try bind(
                        SyncV2ServerPath.canonical(
                            operation.relativePath
                        ),
                        at: 1,
                        to: statement
                    )
                    try bind(timestamp, at: 2, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                }
                try refreshBatchState(
                    batchID: operation.batchID,
                    timestamp: timestamp
                )
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    /// 서버 작품이 재생성된 경우, 아직 편집하지 않은 문서에 남아 있는
    /// 과거 서버 revision도 한 번에 폐기하고 현재 로컬 기준본을 다시
    /// 생성 작업으로 등록한다. 활성 작업이 있는 문서는 해당 문서 lane의
    /// DOCUMENT_NOT_FOUND 복구가 최신 로컬 입력을 보존하도록 건드리지 않는다.
    func recoverMissingRemoteProject(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        guard
            operation.baseRevision == 0,
            !operation.isDeleted,
            let localProjectID = operation.localProjectID,
            let binding = try binding(for: localProjectID),
            binding.serverProjectID == operation.projectID,
            let ownerSubject = binding.ownerSubject
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }

        let candidates = try missingProjectRecoveryCandidates(
            localProjectID: localProjectID
        )
        guard !candidates.isEmpty else { return }

        let batch = SyncV2EnqueueBatch(
            batchID: UUID(),
            localProjectID: localProjectID,
            localTransactionID: nil,
            kind: .backupRestore,
            mutations: candidates.map { candidate in
                .document(
                    SyncV2DocumentMutation(
                        operationID: UUID(),
                        documentID: candidate.documentID,
                        deviceID: operation.deviceID,
                        localSaveGeneration: nil,
                        kind: candidate.kind,
                        localPath: candidate.localPath,
                        relativePath: candidate.serverPath,
                        content: candidate.content,
                        isDeleted: false
                    )
                )
            }
        )
        let materialized = try materialize(
            batch,
            serverProjectID: operation.projectID,
            ownerSubject: ownerSubject
        )

        do {
            try transaction {
                for candidate in candidates {
                    try withStatement(
                        """
                        UPDATE sync_documents
                        SET server_revision = 0,
                            base_content = '',
                            base_hash = '',
                            server_updated_at = NULL,
                            sync_state = 'pending',
                            last_error_code = NULL,
                            updated_at = ?
                        WHERE document_id = ?
                          AND local_project_id = ?
                          AND server_revision > 0
                          AND is_deleted = 0
                          AND NOT EXISTS (
                              SELECT 1
                              FROM sync_operations o
                              WHERE o.document_id = sync_documents.document_id
                                AND o.status NOT IN ('completed', 'cancelled')
                          );
                        """
                    ) { statement in
                        try bind(materialized.timestamp, at: 1, to: statement)
                        try bind(
                            candidate.documentID.uuidString.lowercased(),
                            at: 2,
                            to: statement
                        )
                        try bind(
                            localProjectID.rawValue.uuidString.lowercased(),
                            at: 3,
                            to: statement
                        )
                        try stepDone(statement)
                        guard sqlite3_changes(connection.handle) == 1 else {
                            throw SyncV2DispatchStoreError
                                .operationStateChanged
                        }
                    }
                }

                try insertBatch(materialized)
                var blockedOperationCount = 0
                for materializedOperation in materialized.operations {
                    guard
                        try !operationIDExists(
                            materializedOperation.operationID
                        )
                    else {
                        throw SyncV2EnqueueError.operationIDReused
                    }
                    guard case let .document(payload) =
                        materializedOperation.payload
                    else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    let disposition = try insertDocumentOperation(
                        materializedOperation,
                        batch: materialized,
                        payload: payload,
                        timestamp: materialized.timestamp
                    )
                    guard disposition != .noOp else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                    if disposition == .blockedBySize {
                        blockedOperationCount += 1
                    }
                }
                try finalizeBatchAfterPreflight(
                    batchID: materialized.batchID,
                    insertedOperationCount: materialized.operations.count,
                    blockedOperationCount: blockedOperationCount,
                    timestamp: materialized.timestamp
                )
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    private func missingProjectRecoveryCandidates(
        localProjectID: ProjectID
    ) throws -> [MissingProjectRecoveryCandidate] {
        try withStatement(
            """
            SELECT d.document_id, d.local_path, d.server_path, d.base_content
            FROM sync_documents d
            WHERE d.local_project_id = ?
              AND d.server_revision > 0
              AND d.is_deleted = 0
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_operations o
                  WHERE o.document_id = d.document_id
                    AND o.status NOT IN ('completed', 'cancelled')
              )
            ORDER BY d.document_id;
            """
        ) { statement in
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            var candidates: [MissingProjectRecoveryCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let documentValue = columnText(statement, at: 0),
                    let documentID = UUID(uuidString: documentValue),
                    let localPath = columnText(statement, at: 1),
                    let serverPath = columnText(statement, at: 2),
                    let content = columnText(statement, at: 3)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                let kind: SyncV2OperationKind =
                    serverPath == syncV2TreeOrderPath
                    ? .treeOrder
                    : .documentCommit
                candidates.append(
                    MissingProjectRecoveryCandidate(
                        documentID: documentID,
                        kind: kind,
                        localPath: localPath,
                        serverPath: serverPath,
                        content: content
                    )
                )
            }
            return candidates
        }
    }

    func projectName(
        for operation: SyncV2DispatchOperation
    ) async throws -> String {
        try withStatement(
            """
            SELECT project_name
            FROM sync_projects
            WHERE local_project_id = ?
              AND server_project_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operation.localProjectID?.rawValue.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                operation.projectID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let name = columnText(statement, at: 0),
                  !name.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                throw SyncV2DispatchStoreError.integrityFailure
            }
            return name
        }
    }

    func latestLocalSnapshot(
        for operation: SyncV2DispatchOperation
    ) async throws -> SyncV2RebaseLocalSnapshot {
        try latestLocalSnapshotValue(for: operation)
    }

    private func latestLocalSnapshotValue(
        for operation: SyncV2DispatchOperation
    ) throws -> SyncV2RebaseLocalSnapshot {
        try withStatement(
            """
            SELECT content, local_path, relative_path,
                   local_save_generation
            FROM sync_operations
            WHERE document_id = ?
              AND status NOT IN ('completed', 'cancelled')
            ORDER BY
                CASE WHEN local_save_generation IS NULL THEN 0 ELSE 1 END DESC,
                local_save_generation DESC,
                document_sequence DESC,
                queue_id DESC
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operation.documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            guard
                sqlite3_step(statement) == SQLITE_ROW,
                let content = columnText(statement, at: 0),
                let localPath = columnText(statement, at: 1),
                let relativePath = columnText(statement, at: 2)
            else {
                throw SyncV2DispatchStoreError.operationStateChanged
            }
            let generation: UInt64?
            if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                generation = nil
            } else {
                let value = sqlite3_column_int64(statement, 3)
                guard value >= 0 else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                generation = UInt64(value)
            }
            return SyncV2RebaseLocalSnapshot(
                content: content,
                localPath: localPath,
                relativePath: relativePath,
                localSaveGeneration: generation
            )
        }
    }

    private static func isSameLocalGeneration(
        _ latest: SyncV2RebaseLocalSnapshot,
        as captured: SyncV2RebaseLocalSnapshot
    ) -> Bool {
        switch (
            latest.localSaveGeneration,
            captured.localSaveGeneration
        ) {
        case let (latestGeneration?, capturedGeneration?):
            return latestGeneration < capturedGeneration
                || (
                    latestGeneration == capturedGeneration
                    && latest == captured
                )
        case (nil, nil):
            return latest == captured
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        }
    }

    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) async throws -> SyncV2AutomaticRebaseStoreResult {
        guard remote.documentID == operation.documentID,
              remote.revision > operation.baseRevision,
              !remote.isDeleted,
              mergedContent.utf8.count <= Self.maximumContentByteCount
        else {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        let timestamp = Self.timestamp()
        do {
            return try transaction {
                let latest = try latestLocalSnapshotValue(for: operation)
                guard Self.isSameLocalGeneration(
                    latest,
                    as: local
                ) else {
                    try returnInflightToPending(
                        operation,
                        errorCode: "LOCAL_GENERATION_ADVANCED",
                        timestamp: timestamp
                    )
                    return .localGenerationAdvanced
                }

                let occupied = try withStatement(
                    """
                    SELECT EXISTS(
                        SELECT 1
                        FROM sync_documents
                        WHERE local_project_id = (
                            SELECT local_project_id
                            FROM sync_documents
                            WHERE document_id = ?
                        )
                          AND local_path = ?
                          AND document_id <> ?
                    );
                    """
                ) { statement in
                    let identifier =
                        operation.documentID.uuidString.lowercased()
                    try bind(identifier, at: 1, to: statement)
                    try bind(mergedPath, at: 2, to: statement)
                    try bind(identifier, at: 3, to: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw sqliteError()
                    }
                    return sqlite3_column_int(statement, 0) == 1
                }
                guard !occupied else {
                    return .pathOccupiedByDifferentDocument
                }

                let affectedBatchIDs = try activeBatchIDs(
                    documentID: operation.documentID
                )
                let superseded = try prepareSupersededSiblings(
                    documentID: operation.documentID,
                    survivingOperationID: operation.operationID,
                    timestamp: timestamp
                )
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET status = 'cancelled',
                        last_error_code = 'SUPERSEDED_BY_AUTO_REBASE',
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE document_id = ?
                      AND operation_id <> ?
                      AND status NOT IN ('completed', 'cancelled');
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 2,
                        to: statement
                    )
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 3,
                        to: statement
                    )
                    try stepDone(statement)
                }
                try recordOperationEvents(
                    superseded,
                    type: .superseded,
                    errorCode: "SUPERSEDED_BY_AUTO_REBASE",
                    timestamp: timestamp,
                    relatedOperationID:
                        operation.operationID.uuidString.lowercased()
                )

                let mergedData = Data(mergedContent.utf8)
                let mergedHash = Self.sha256Hex(mergedData)
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET base_revision = ?,
                        base_content = ?,
                        local_path = ?,
                        relative_path = ?,
                        content = ?,
                        content_byte_count = ?,
                        content_hash = ?,
                        local_save_generation = ?,
                        status = 'pending',
                        last_error_code = NULL,
                        last_error_detail = NULL,
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE operation_id = ?
                      AND status = 'inflight'
                      AND attempts = ?;
                    """
                ) { statement in
                    try bind(remote.revision, at: 1, to: statement)
                    try bind(remote.content, at: 2, to: statement)
                    try bind(mergedPath, at: 3, to: statement)
                    try bind(mergedPath, at: 4, to: statement)
                    try bind(mergedContent, at: 5, to: statement)
                    try bind(mergedData.count, at: 6, to: statement)
                    try bind(mergedHash, at: 7, to: statement)
                    try bind(
                        local.localSaveGeneration.flatMap(Int64.init(exactly:)),
                        at: 8,
                        to: statement
                    )
                    try bind(timestamp, at: 9, to: statement)
                    try bind(
                        operation.operationID.uuidString.lowercased(),
                        at: 10,
                        to: statement
                    )
                    try bind(operation.attempts, at: 11, to: statement)
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.operationStateChanged
                    }
                }

                let remoteHash = Self.sha256Hex(Data(remote.content.utf8))
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET local_path = ?,
                        server_path = ?,
                        server_revision = ?,
                        base_content = ?,
                        base_hash = ?,
                        is_deleted = 0,
                        server_updated_at = ?,
                        sync_state = 'pending',
                        last_error_code = NULL,
                        updated_at = ?
                    WHERE document_id = ?;
                    """
                ) { statement in
                    try bind(mergedPath, at: 1, to: statement)
                    try bind(remote.relativePath, at: 2, to: statement)
                    try bind(remote.revision, at: 3, to: statement)
                    try bind(remote.content, at: 4, to: statement)
                    try bind(remoteHash, at: 5, to: statement)
                    try bind(Self.timestamp(remote.updatedAt), at: 6, to: statement)
                    try bind(timestamp, at: 7, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 8,
                        to: statement
                    )
                    try stepDone(statement)
                    guard sqlite3_changes(connection.handle) == 1 else {
                        throw SyncV2DispatchStoreError.integrityFailure
                    }
                }
                for batchID in affectedBatchIDs {
                    try refreshBatchState(
                        batchID: batchID,
                        timestamp: timestamp
                    )
                }
                return .rebased
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch let error as SyncV2StoreError {
            throw error
        } catch {
            throw error
        }
    }

    private func returnInflightToPending(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        timestamp: String
    ) throws {
        let operationKey = operation.operationID.uuidString.lowercased()
        try ensureOperationEventHistory(
            operationID: operationKey,
            timestamp: timestamp
        )
        try withStatement(
            """
            UPDATE sync_operations
            SET status = 'pending',
                last_error_code = ?,
                next_attempt_at = NULL,
                updated_at = ?
            WHERE operation_id = ?
              AND status = 'inflight'
              AND attempts = ?;
            """
        ) { statement in
            try bind(errorCode, at: 1, to: statement)
            try bind(timestamp, at: 2, to: statement)
            try bind(operationKey, at: 3, to: statement)
            try bind(operation.attempts, at: 4, to: statement)
            try stepDone(statement)
            guard sqlite3_changes(connection.handle) == 1 else {
                throw SyncV2DispatchStoreError.operationStateChanged
            }
        }
        try appendOperationEvent(
            operationID: operationKey,
            type: .enqueued,
            errorCode: errorCode,
            timestamp: timestamp
        )
    }

    private func activeBatchIDs(documentID: UUID) throws -> [UUID] {
        try withStatement(
            """
            SELECT DISTINCT batch_id
            FROM sync_operations
            WHERE document_id = ?
              AND status NOT IN ('completed', 'cancelled');
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            var identifiers: [UUID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return identifiers
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                identifiers.append(identifier)
            }
        }
    }

    private func conflictResolutionOperation(
        operationID: UUID,
        documentID: UUID
    ) throws -> ConflictResolutionOperation {
        try withStatement(
            """
            SELECT local_project_id, document_sequence,
                   operation_kind, status, content, is_deleted
            FROM sync_operations
            WHERE operation_id = ?
              AND document_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                documentID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            guard
                sqlite3_step(statement) == SQLITE_ROW,
                let projectValue = columnText(statement, at: 0),
                let localProjectID = UUID(uuidString: projectValue),
                let kindValue = columnText(statement, at: 2),
                let kind = SyncV2OperationKind(rawValue: kindValue),
                let statusValue = columnText(statement, at: 3),
                let status = SyncV2OperationStatus(rawValue: statusValue),
                let content = columnText(statement, at: 4)
            else {
                throw SyncV2ConflictResolutionError
                    .resolutionOperationNotReady
            }
            return ConflictResolutionOperation(
                localProjectID: ProjectID(rawValue: localProjectID),
                documentSequence: Int(
                    sqlite3_column_int64(statement, 1)
                ),
                kind: kind,
                status: status,
                content: content,
                isDeleted: sqlite3_column_int(statement, 5) == 1
            )
        }
    }

    private func operationSequence(
        operationID: UUID,
        documentID: UUID,
        expectedStatus: SyncV2OperationStatus
    ) throws -> Int {
        try withStatement(
            """
            SELECT document_sequence
            FROM sync_operations
            WHERE operation_id = ?
              AND document_id = ?
              AND status = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                documentID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(expectedStatus.rawValue, at: 3, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SyncV2ConflictResolutionError.conflictChanged
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func latestActiveResolutionSequence(
        documentID: UUID,
        excluding conflictOperationID: UUID
    ) throws -> Int? {
        try withStatement(
            """
            SELECT MAX(document_sequence)
            FROM sync_operations
            WHERE document_id = ?
              AND operation_id <> ?
              AND status NOT IN ('completed', 'cancelled');
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                conflictOperationID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SyncV2ConflictResolutionError.integrityFailure
            }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else {
                return nil
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func documentMatches(
        conflict: SyncV2ConflictRecord,
        localProjectID: ProjectID
    ) throws -> Bool {
        try withStatement(
            """
            SELECT EXISTS(
                SELECT 1
                FROM sync_documents
                WHERE document_id = ?
                  AND local_project_id = ?
                  AND server_revision = ?
                  AND server_path = ?
                  AND base_content = ?
                  AND sync_state IN ('conflict', 'pending')
            );
            """
        ) { statement in
            try bind(
                conflict.documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                localProjectID.rawValue.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                conflict.snapshot.remoteRevision,
                at: 3,
                to: statement
            )
            try bind(
                conflict.snapshot.remotePath,
                at: 4,
                to: statement
            )
            try bind(
                conflict.snapshot.remoteContent,
                at: 5,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SyncV2ConflictResolutionError.integrityFailure
            }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    func makeRetryWaitOperationsReady() throws {
        try makeRetryWaitOperationsReady(localProjectID: nil)
    }

    func makeRetryWaitOperationsReady(
        localProjectID: ProjectID?
    ) throws {
        guard availability() == .available else {
            throw SyncV2DispatchStoreError.unavailable
        }
        do {
            try transaction {
                let timestamp = Self.timestamp()
                try recoverPersistedLeaseConflicts(
                    localProjectID: localProjectID,
                    timestamp: timestamp
                )
                try recoverPersistedForbiddenBlocks(
                    localProjectID: localProjectID,
                    timestamp: timestamp
                )
                let projectValue =
                    localProjectID?.rawValue.uuidString.lowercased()
                // 바꾸기 전에 대상을 모은다. 바꾼 뒤에는 조건에 걸리지 않아
                // 누구에게 사건을 남겨야 할지 알 수 없다.
                let waiting = try operationIDs(
                    where: "status = 'retry_wait' AND (? IS NULL OR local_project_id = ?)"
                ) { statement in
                    try bind(projectValue, at: 1, to: statement)
                    try bind(projectValue, at: 2, to: statement)
                }
                try withStatement(
                    """
                    UPDATE sync_operations
                    SET status = 'pending',
                        next_attempt_at = NULL,
                        updated_at = ?
                    WHERE status = 'retry_wait'
                      AND (? IS NULL OR local_project_id = ?);
                    """
                ) { statement in
                    try bind(timestamp, at: 1, to: statement)
                    try bind(projectValue, at: 2, to: statement)
                    try bind(projectValue, at: 3, to: statement)
                    try stepDone(statement)
                }
                // 대기로 돌아왔다는 것을 적는다. 계약이 정한 사건 가운데
                // 대기로 이어지는 것은 이것뿐이다.
                try recordOperationEvents(
                    waiting,
                    type: .enqueued,
                    errorCode: nil,
                    timestamp: timestamp
                )
            }
        } catch {
            throw SyncV2DispatchStoreError.unavailable
        }
    }

    private func recoverPersistedForbiddenBlocks(
        localProjectID: ProjectID?,
        timestamp: String
    ) throws {
        let projectValue =
            localProjectID?.rawValue.uuidString.lowercased()
        let laneHeadPredicate = """
        (
            o.document_id IS NULL
            OR NOT EXISTS (
                SELECT 1
                FROM sync_operations earlier
                WHERE earlier.document_id = o.document_id
                  AND earlier.document_sequence < o.document_sequence
                  AND earlier.status NOT IN ('completed', 'cancelled')
            )
        )
        """
        let affectedBatchIDs = try withStatement(
            """
            SELECT DISTINCT o.batch_id
            FROM sync_operations o
            WHERE o.status = 'blocked'
              AND o.last_error_code = 'FORBIDDEN'
              AND (? IS NULL OR o.local_project_id = ?)
              AND \(laneHeadPredicate);
            """
        ) { statement in
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            var batchIDs: [UUID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return batchIDs
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let batchID = UUID(uuidString: value)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                batchIDs.append(batchID)
            }
        }

        try withStatement(
            """
            UPDATE sync_documents
            SET sync_state = 'pending',
                last_error_code = NULL,
                updated_at = ?
            WHERE EXISTS (
                SELECT 1
                FROM sync_operations o
                WHERE o.document_id = sync_documents.document_id
                  AND o.status = 'blocked'
                  AND o.last_error_code = 'FORBIDDEN'
                  AND (? IS NULL OR o.local_project_id = ?)
                  AND \(laneHeadPredicate)
            );
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(projectValue, at: 3, to: statement)
            try stepDone(statement)
        }
        let unblocked = try prepareOperationEvents(
            where: """
            o.status = 'blocked'
              AND o.last_error_code = 'FORBIDDEN'
              AND (? IS NULL OR o.local_project_id = ?)
              AND \(laneHeadPredicate)
            """,
            alias: "o",
            timestamp: timestamp
        ) { statement in
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
        }
        try withStatement(
            """
            UPDATE sync_operations AS o
            SET status = 'pending',
                attempts = 0,
                last_error_code = NULL,
                last_error_detail = NULL,
                next_attempt_at = NULL,
                updated_at = ?
            WHERE o.status = 'blocked'
              AND o.last_error_code = 'FORBIDDEN'
              AND (? IS NULL OR o.local_project_id = ?)
              AND \(laneHeadPredicate);
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(projectValue, at: 3, to: statement)
            try stepDone(statement)
        }
        try recordOperationEvents(
            unblocked,
            type: .enqueued,
            errorCode: nil,
            timestamp: timestamp
        )
        for batchID in affectedBatchIDs {
            try refreshBatchState(
                batchID: batchID,
                timestamp: timestamp
            )
        }
    }

    /// 편집 lease는 시간이 지나면 저절로 풀리므로 굳은 operation을 그대로
    /// 다시 세운다. 기준선은 건드리지 않는다.
    private static let leaseConflictErrorCodeList =
        "'LEASE_REQUIRED', 'LEASE_CONFLICT', 'LEASE_EXPIRED'"

    /// base revision 0으로 보낸 create가 이미 있는 문서를 만난 경우다. 서버가
    /// 최신 문서를 갖고 있으므로 DOCUMENT_NOT_FOUND 복구와 달리 기준선을 0으로
    /// 되돌리면 안 된다. 그대로 다시 세우면 자동 rebase가 서버 revision을 읽어
    /// 기준선을 맞춘다. 구버전에서 굳은 기록은 이 경로로만 풀린다.
    private static let alreadyExistsErrorCodeList =
        "'DOCUMENT_ALREADY_EXISTS'"

    private func recoverPersistedLeaseConflicts(
        localProjectID: ProjectID?,
        timestamp: String
    ) throws {
        try requeuePersistedConflicts(
            errorCodeList: Self.leaseConflictErrorCodeList,
            localProjectID: localProjectID,
            timestamp: timestamp
        )
    }

    private func recoverPersistedAlreadyExistsConflicts(
        localProjectID: ProjectID?,
        timestamp: String
    ) throws {
        try requeuePersistedConflicts(
            errorCodeList: Self.alreadyExistsErrorCodeList,
            localProjectID: localProjectID,
            timestamp: timestamp
        )
    }

    /// `errorCodeList`는 위의 private 상수만 받는 SQL 리터럴 조각이다. 외부
    /// 입력이 들어오는 경로가 아니므로 바인딩 대신 문자열로 합친다.
    private func requeuePersistedConflicts(
        errorCodeList: String,
        localProjectID: ProjectID?,
        timestamp: String
    ) throws {
        let projectValue =
            localProjectID?.rawValue.uuidString.lowercased()
        let affectedBatchIDs = try withStatement(
            """
            SELECT DISTINCT o.batch_id
            FROM sync_operations o
            WHERE o.status = 'conflict'
              AND o.last_error_code IN (\(errorCodeList))
              AND (? IS NULL OR o.local_project_id = ?)
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_conflicts c
                  WHERE c.document_id = o.document_id
                    AND c.resolved_at IS NULL
              );
            """
        ) { statement in
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            var batchIDs: [UUID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return batchIDs
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let batchID = UUID(uuidString: value)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                batchIDs.append(batchID)
            }
        }

        try withStatement(
            """
            UPDATE sync_documents
            SET sync_state = 'pending',
                last_error_code = NULL,
                updated_at = ?
            WHERE EXISTS (
                SELECT 1
                FROM sync_operations o
                WHERE o.document_id = sync_documents.document_id
                  AND o.status = 'conflict'
                  AND o.last_error_code IN (\(errorCodeList))
                  AND (? IS NULL OR o.local_project_id = ?)
            )
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_conflicts c
                  WHERE c.document_id = sync_documents.document_id
                    AND c.resolved_at IS NULL
              );
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(projectValue, at: 3, to: statement)
            try stepDone(statement)
        }
        let requeued = try prepareOperationEvents(
            where: """
            status = 'conflict'
              AND last_error_code IN (\(errorCodeList))
              AND (? IS NULL OR local_project_id = ?)
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_conflicts c
                  WHERE c.document_id = sync_operations.document_id
                    AND c.resolved_at IS NULL
              )
            """,
            timestamp: timestamp
        ) { statement in
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
        }
        try withStatement(
            """
            UPDATE sync_operations
            SET status = 'pending',
                attempts = 0,
                last_error_code = NULL,
                last_error_detail = NULL,
                next_attempt_at = NULL,
                updated_at = ?
            WHERE status = 'conflict'
              AND last_error_code IN (\(errorCodeList))
              AND (? IS NULL OR local_project_id = ?)
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_conflicts c
                  WHERE c.document_id = sync_operations.document_id
                    AND c.resolved_at IS NULL
              );
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(projectValue, at: 3, to: statement)
            try stepDone(statement)
        }
        try recordOperationEvents(
            requeued,
            type: .enqueued,
            errorCode: nil,
            timestamp: timestamp
        )
        for batchID in affectedBatchIDs {
            try refreshBatchState(
                batchID: batchID,
                timestamp: timestamp
            )
        }
    }

    func nextRetryDate() throws -> Date? {
        try nextRetryDate(localProjectID: nil)
    }

    func nextRetryDate(
        localProjectID: ProjectID?
    ) throws -> Date? {
        guard availability() == .available else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try withStatement(
            """
            SELECT o.next_attempt_at
            FROM sync_operations o
            WHERE o.status = 'retry_wait'
              AND o.next_attempt_at IS NOT NULL
              AND o.document_id IS NOT NULL
              AND o.base_revision IS NOT NULL
              AND (? IS NULL OR o.local_project_id = ?)
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_operations earlier
                  WHERE earlier.document_id = o.document_id
                    AND earlier.document_sequence < o.document_sequence
                    AND earlier.status NOT IN ('completed', 'cancelled')
              )
            ORDER BY o.next_attempt_at, o.queue_id
            LIMIT 1;
            """
        ) { statement in
            let projectValue =
                localProjectID?.rawValue.uuidString.lowercased()
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard
                status == SQLITE_ROW,
                let value = columnText(statement, at: 0),
                let date = Self.date(value)
            else {
                throw SyncV2DispatchStoreError.integrityFailure
            }
            return date
        }
    }

    func close() {
        guard connection.handle != nil else { return }
        connection.close()
        openDiagnostic = Self.diagnostic(.databaseClosed)
    }

    private func dispatchCandidates(
        localProjectID: ProjectID?,
        limit: Int,
        nowValue: String
    ) throws -> [DispatchCandidate] {
        try withStatement(
            """
            SELECT o.operation_id, o.batch_id, o.local_project_id,
                   o.project_id, o.document_id, o.device_id,
                   o.document_sequence, o.local_save_generation,
                   o.operation_kind, o.base_revision, o.base_content,
                   d.server_path, o.local_path, o.relative_path,
                   o.content, o.is_deleted, o.attempts
            FROM sync_operations o
            JOIN sync_documents d ON d.document_id = o.document_id
            WHERE o.document_id IS NOT NULL
              AND o.base_revision IS NOT NULL
              AND (? IS NULL OR o.local_project_id = ?)
              AND (
                  o.status = 'pending'
                  OR (
                      o.status = 'retry_wait'
                      AND (
                          o.next_attempt_at IS NULL
                          OR o.next_attempt_at <= ?
                      )
                  )
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM sync_operations earlier
                  WHERE earlier.document_id = o.document_id
                    AND earlier.document_sequence < o.document_sequence
                    AND earlier.status NOT IN ('completed', 'cancelled')
              )
              -- 구조 변경 batch의 문서 경로는 폴더 행이
              -- 서버에 확정된 뒤에만 공개한다.
              AND (
                  o.operation_kind = 'tree_order'
                  OR NOT EXISTS (
                      SELECT 1
                      FROM sync_operations folderDependency
                      WHERE folderDependency.batch_id = o.batch_id
                        AND folderDependency.folder_id IS NOT NULL
                        AND folderDependency.status NOT IN (
                            'completed', 'cancelled'
                        )
                  )
              )
              -- tree_order는 같은 batch의 폴더·문서가 모두
              -- 확정된 뒤에만 최종 바인더 순서로 발행한다.
              AND (
                  o.operation_kind <> 'tree_order'
                  OR NOT EXISTS (
                      SELECT 1
                      FROM sync_operations batchDependency
                      WHERE batchDependency.batch_id = o.batch_id
                        AND batchDependency.operation_id <> o.operation_id
                        AND batchDependency.status NOT IN (
                            'completed', 'cancelled'
                        )
                  )
              )
              -- 빠른 연속 변경에서는 앞 tree_order가 최신 snapshot으로
              -- 합쳐진다. 최신 줄은 앞선 모든 구조 작업까지 기다려야 한다.
              AND (
                  o.operation_kind <> 'tree_order'
                  OR NOT EXISTS (
                      SELECT 1
                      FROM sync_operations structuralDependency
                      JOIN sync_batches structuralBatch
                        ON structuralBatch.batch_id
                            = structuralDependency.batch_id
                      WHERE structuralDependency.local_project_id
                            = o.local_project_id
                        AND structuralDependency.queue_id < o.queue_id
                        AND structuralDependency.status NOT IN (
                            'completed', 'cancelled'
                        )
                        AND structuralBatch.batch_kind IN (
                            'structure_change', 'volume_creation',
                            'trash_change', 'backup_restore',
                            'windows_import'
                        )
                  )
              )
            ORDER BY o.queue_id
            """
        ) { statement in
            let projectValue =
                localProjectID?.rawValue.uuidString.lowercased()
            try bind(projectValue, at: 1, to: statement)
            try bind(projectValue, at: 2, to: statement)
            try bind(nowValue, at: 3, to: statement)
            var candidates: [DispatchCandidate] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return candidates
                }
                guard
                    status == SQLITE_ROW,
                    let operationValue = columnText(statement, at: 0),
                    let operationID = UUID(uuidString: operationValue),
                    let batchValue = columnText(statement, at: 1),
                    let batchID = UUID(uuidString: batchValue),
                    let localProjectValue = columnText(statement, at: 2),
                    let localProjectID = UUID(uuidString: localProjectValue),
                    let projectValue = columnText(statement, at: 3),
                    let projectID = UUID(uuidString: projectValue),
                    let documentValue = columnText(statement, at: 4),
                    let documentID = UUID(uuidString: documentValue),
                    let deviceValue = columnText(statement, at: 5),
                    let deviceID = UUID(uuidString: deviceValue),
                    let kindValue = columnText(statement, at: 8),
                    let kind = SyncV2OperationKind(rawValue: kindValue),
                    let baseContent = columnText(statement, at: 10),
                    let baseServerPath = columnText(statement, at: 11),
                    let localPath = columnText(statement, at: 12),
                    let relativePath = columnText(statement, at: 13),
                    let content = columnText(statement, at: 14)
                else {
                    throw SyncV2DispatchStoreError.integrityFailure
                }
                let localSaveGeneration: UInt64?
                if sqlite3_column_type(statement, 7) == SQLITE_NULL {
                    localSaveGeneration = nil
                } else {
                    localSaveGeneration = UInt64(
                        sqlite3_column_int64(statement, 7)
                    )
                }
                var dispatchContent = content
                if kind == .trashPurge {
                    guard let materialized = try materializedTrashPurgeContent(
                        content,
                        operationID: operationID
                    ) else {
                        continue
                    }
                    dispatchContent = materialized
                    if materialized != content {
                        let data = Data(materialized.utf8)
                        try withStatement(
                            """
                            UPDATE sync_operations
                            SET content = ?, content_byte_count = ?,
                                content_hash = ?, updated_at = ?
                            WHERE operation_id = ?
                              AND status IN ('pending', 'retry_wait');
                            """
                        ) { update in
                            try bind(materialized, at: 1, to: update)
                            try bind(data.count, at: 2, to: update)
                            try bind(Self.sha256Hex(data), at: 3, to: update)
                            try bind(nowValue, at: 4, to: update)
                            try bind(
                                operationID.uuidString.lowercased(),
                                at: 5,
                                to: update
                            )
                            try stepDone(update)
                        }
                    }
                }
                candidates.append(
                    DispatchCandidate(
                        operationID: operationID,
                        batchID: batchID,
                        localProjectID: ProjectID(
                            rawValue: localProjectID
                        ),
                        projectID: projectID,
                        documentID: documentID,
                        deviceID: deviceID,
                        documentSequence: Int(
                            sqlite3_column_int64(statement, 6)
                        ),
                        localSaveGeneration: localSaveGeneration,
                        kind: kind,
                        baseRevision: sqlite3_column_int64(statement, 9),
                        baseContent: baseContent,
                        baseServerPath: baseServerPath,
                        localPath: localPath,
                        relativePath: relativePath,
                        content: dispatchContent,
                        isDeleted: sqlite3_column_int(statement, 15) == 1,
                        attempts: Int(sqlite3_column_int(statement, 16))
                    )
                )
                if candidates.count == limit {
                    return candidates
                }
            }
        }
    }

    private func materializedTrashPurgeContent(
        _ content: String,
        operationID: UUID
    ) throws -> String? {
        let payload: SyncV2TrashPurgePayload
        do {
            payload = try SyncV2TrashPurgePayload(strictContent: content)
        } catch {
            throw SyncV2DispatchStoreError.integrityFailure
        }
        var revisions = payload.purgedRevisions
        for documentID in payload.purgedRevisions.keys {
            let values = try withStatement(
                """
                SELECT
                    EXISTS(
                        SELECT 1
                        FROM sync_operations active
                        WHERE active.document_id = ?
                          AND active.operation_id <> ?
                          AND active.status NOT IN ('completed', 'cancelled')
                    ),
                    COALESCE((
                        SELECT MAX(completed.base_revision + 1)
                        FROM sync_operations completed
                        WHERE completed.document_id = ?
                          AND completed.is_deleted = 1
                          AND completed.status = 'completed'
                          AND completed.base_revision IS NOT NULL
                    ), 0),
                    COALESCE((
                        SELECT CASE WHEN d.is_deleted = 1
                            THEN d.server_revision ELSE 0 END
                        FROM sync_documents d
                        WHERE d.document_id = ?
                    ), 0);
                """
            ) { statement in
                let identifier = documentID.uuidString.lowercased()
                try bind(identifier, at: 1, to: statement)
                try bind(
                    operationID.uuidString.lowercased(),
                    at: 2,
                    to: statement
                )
                try bind(identifier, at: 3, to: statement)
                try bind(identifier, at: 4, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError()
                }
                return (
                    sqlite3_column_int(statement, 0) == 1,
                    sqlite3_column_int64(statement, 1),
                    sqlite3_column_int64(statement, 2)
                )
            }
            guard !values.0 else { return nil }
            let revision = max(values.1, values.2)
            guard revision > 0 else { return nil }
            revisions[documentID] = max(
                revisions[documentID] ?? 0,
                revision
            )
        }
        do {
            return try SyncV2TrashPurgePayload(
                purgedRevisions: revisions,
                emptyGeneration: payload.emptyGeneration
            ).canonicalContent()
        } catch {
            throw SyncV2DispatchStoreError.integrityFailure
        }
    }

    private func recordDispatchFailure(
        _ operation: SyncV2DispatchOperation,
        status: SyncV2OperationStatus,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date?
    ) throws {
        let timestamp = Self.timestamp()
        do {
            try transaction {
                try transitionInflightOperation(
                    operation,
                    status: status,
                    errorCode: errorCode,
                    detail: detail,
                    nextAttemptAt: nextAttemptAt,
                    timestamp: timestamp
                )
                try withStatement(
                    """
                    UPDATE sync_documents
                    SET sync_state = ?,
                        last_error_code = ?,
                        updated_at = ?
                    WHERE document_id = ?;
                    """
                ) { statement in
                    let documentState =
                        status == .conflict ? "conflict"
                        : status == .blocked ? "blocked"
                        : "pending"
                    try bind(documentState, at: 1, to: statement)
                    try bind(errorCode, at: 2, to: statement)
                    try bind(timestamp, at: 3, to: statement)
                    try bind(
                        operation.documentID.uuidString.lowercased(),
                        at: 4,
                        to: statement
                    )
                    try stepDone(statement)
                }
                try refreshBatchState(
                    batchID: operation.batchID,
                    timestamp: timestamp
                )
            }
        } catch let error as SyncV2DispatchStoreError {
            throw error
        } catch {
            throw SyncV2DispatchStoreError.unavailable
        }
    }

    private func transitionInflightOperation(
        _ operation: SyncV2DispatchOperation,
        status: SyncV2OperationStatus,
        errorCode: String?,
        detail: String?,
        nextAttemptAt: Date?,
        timestamp: String,
        eventType: SyncV2OperationEventType? = nil
    ) throws {
        try transitionInflightOperation(
            operationID: operation.operationID,
            attempts: operation.attempts,
            status: status,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nextAttemptAt,
            timestamp: timestamp,
            eventType: eventType
        )
    }

    /// 문서와 폴더가 같은 표를 쓰므로 상태 전이도 같다. 시도 횟수를 조건에 넣어
    /// 이미 다른 흐름이 건드린 줄은 바꾸지 않는다.
    ///
    /// status 칸을 바꾸는 것과 사건을 남기는 것이 한 거래 안에서 함께 일어난다.
    /// 둘 중 하나만 남으면 그때부터 기록과 칸이 갈라진다.
    private func transitionInflightOperation(
        operationID: UUID,
        attempts: Int,
        status: SyncV2OperationStatus,
        errorCode: String?,
        detail: String?,
        nextAttemptAt: Date?,
        timestamp: String,
        eventType: SyncV2OperationEventType? = nil
    ) throws {
        // 칸을 바꾸기 전에 지난 일을 채워 둔다. 바꾼 뒤에 채우면 바뀐 상태를
        // 지난 일로 잘못 적는다.
        try ensureOperationEventHistory(
            operationID: operationID.uuidString.lowercased(),
            timestamp: timestamp
        )
        try withStatement(
            """
            UPDATE sync_operations
            SET status = ?,
                last_error_code = ?,
                last_error_detail = ?,
                next_attempt_at = ?,
                updated_at = ?
            WHERE operation_id = ?
              AND status = 'inflight'
              AND attempts = ?;
            """
        ) { statement in
            try bind(status.rawValue, at: 1, to: statement)
            try bind(errorCode, at: 2, to: statement)
            try bind(detail, at: 3, to: statement)
            try bind(nextAttemptAt.map(Self.timestamp), at: 4, to: statement)
            try bind(timestamp, at: 5, to: statement)
            try bind(
                operationID.uuidString.lowercased(),
                at: 6,
                to: statement
            )
            try bind(attempts, at: 7, to: statement)
            try stepDone(statement)
            guard sqlite3_changes(connection.handle) == 1 else {
                throw SyncV2DispatchStoreError.operationStateChanged
            }
        }
        try appendOperationEvent(
            operationID: operationID.uuidString.lowercased(),
            type: eventType ?? Self.eventType(reaching: status),
            errorCode: errorCode,
            timestamp: timestamp
        )
    }

    private func refreshBatchState(
        batchID: UUID,
        timestamp: String
    ) throws {
        try withStatement(
            """
            UPDATE sync_batches
            SET status = CASE
                    WHEN EXISTS (
                        SELECT 1
                        FROM sync_operations o
                        WHERE o.batch_id = sync_batches.batch_id
                          AND o.status IN ('conflict', 'blocked')
                    ) THEN 'attention'
                    WHEN EXISTS (
                        SELECT 1
                        FROM sync_operations o
                        WHERE o.batch_id = sync_batches.batch_id
                          AND o.status NOT IN ('completed', 'cancelled')
                    ) THEN 'ready'
                    ELSE 'completed'
                END,
                last_error_code = (
                    SELECT o.last_error_code
                    FROM sync_operations o
                    WHERE o.batch_id = sync_batches.batch_id
                      AND o.last_error_code IS NOT NULL
                    ORDER BY o.queue_id
                    LIMIT 1
                ),
                updated_at = ?
            WHERE batch_id = ?;
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(batchID.uuidString.lowercased(), at: 2, to: statement)
            try stepDone(statement)
        }
    }

    private func materialize(
        _ batch: SyncV2EnqueueBatch,
        serverProjectID: UUID,
        ownerSubject: UUID
    ) throws -> MaterializedBatch {
        let localProjectID = batch.localProjectID.rawValue
        var operations: [MaterializedOperation] = []
        operations.reserveCapacity(batch.mutations.count)

        for mutation in batch.mutations {
            switch mutation {
            case .ensureProject(let ensure):
                let projectName = ensure.projectName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !projectName.isEmpty else {
                    throw SyncV2EnqueueError.invalidMutation
                }
                operations.append(
                    MaterializedOperation(
                        operationID: ensure.operationID,
                        payload: .ensureProject(
                            MaterializedEnsureProject(
                                projectName: projectName
                            )
                        )
                    )
                )
            case .document(let document):
                let serverPath = SyncV2ServerPath.canonical(
                    document.relativePath
                )
                guard
                    document.kind != .ensureProject,
                    document.localSaveGeneration.map({ $0 >= 0 }) ?? true,
                    validLocalPath(document.localPath),
                    validRelativePath(serverPath)
                else {
                    throw SyncV2EnqueueError.invalidMutation
                }
                let data = Data(document.content.utf8)
                operations.append(
                    MaterializedOperation(
                        operationID: document.operationID,
                        payload: .document(
                            MaterializedDocument(
                                documentID: document.documentID,
                                deviceID: document.deviceID,
                                localSaveGeneration:
                                    document.localSaveGeneration,
                                kind: document.kind,
                                localPath: document.localPath,
                                relativePath: serverPath,
                                content: document.content,
                                contentByteCount: data.count,
                                contentHash: Self.sha256Hex(data),
                                isDeleted: document.isDeleted
                            )
                        )
                    )
                )
            case .folder(let folder):
                guard validFolderName(folder.name),
                      folder.parentFolderID != folder.folderID
                else {
                    throw SyncV2EnqueueError.invalidMutation
                }
                operations.append(
                    MaterializedOperation(
                        operationID: folder.operationID,
                        payload: .folder(
                            MaterializedFolder(
                                folderID: folder.folderID,
                                parentFolderID: folder.parentFolderID,
                                deviceID: folder.deviceID,
                                name: folder.name,
                                isDeleted: folder.isDeleted
                            )
                        )
                    )
                )
            }
        }

        let canonical = CanonicalBatch(
            version: 1,
            batchID: batch.batchID.uuidString.lowercased(),
            localProjectID: localProjectID.uuidString.lowercased(),
            serverProjectID: serverProjectID.uuidString.lowercased(),
            ownerSubject: ownerSubject.uuidString.lowercased(),
            localTransactionID: batch.localTransactionID?
                .uuidString.lowercased(),
            kind: batch.kind,
            operations: operations.map {
                $0.canonical(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    ownerSubject: ownerSubject
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalData = try encoder.encode(canonical)
        return MaterializedBatch(
            batchID: batch.batchID,
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            ownerSubject: ownerSubject,
            localTransactionID: batch.localTransactionID,
            kind: batch.kind,
            operations: operations,
            payloadHash: Self.sha256Hex(canonicalData),
            timestamp: Self.timestamp()
        )
    }

    private func validLocalPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\\")
    }

    /// 폴더 이름은 경로 한 칸이다. 구분자가 들어오면 부모 사슬이 아니라
    /// 이름으로 위치를 표현하려는 것이라 받지 않는다. 앞뒤 공백 정리는 저장
    /// 전에 이미 끝나 있어야 하므로 여기서 조용히 고치지 않고 되돌려보낸다.
    private func validFolderName(_ name: String) -> Bool {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != ".."
        else {
            return false
        }
        return name == name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validRelativePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\\")
        else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }

    private func existingBatch(
        batchID: UUID
    ) throws -> ExistingBatch? {
        try withStatement(
            """
            SELECT local_project_id, mutation_count, payload_hash
            FROM sync_batches
            WHERE batch_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(batchID.uuidString.lowercased(), at: 1, to: statement)
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard
                status == SQLITE_ROW,
                let localProjectValue = columnText(statement, at: 0),
                let localProjectID = UUID(uuidString: localProjectValue),
                let payloadHash = columnText(statement, at: 2)
            else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return ExistingBatch(
                localProjectID: localProjectID,
                mutationCount: Int(sqlite3_column_int64(statement, 1)),
                payloadHash: payloadHash
            )
        }
    }

    private func operationIDs(
        batchID: UUID
    ) throws -> [UUID] {
        try withStatement(
            """
            SELECT operation_id
            FROM sync_operations
            WHERE batch_id = ?
            ORDER BY queue_id;
            """
        ) { statement in
            try bind(batchID.uuidString.lowercased(), at: 1, to: statement)
            var identifiers: [UUID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return identifiers
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2EnqueueError.integrityFailure
                }
                identifiers.append(identifier)
            }
        }
    }

    private func blockedOperations(
        batchID: UUID
    ) throws -> [SyncV2BlockedOperation] {
        try withStatement(
            """
            SELECT operation_id, content_byte_count
            FROM sync_operations
            WHERE batch_id = ?
              AND status = 'blocked'
              AND last_error_code = ?
            ORDER BY queue_id;
            """
        ) { statement in
            try bind(batchID.uuidString.lowercased(), at: 1, to: statement)
            try bind(Self.contentTooLargeErrorCode, at: 2, to: statement)
            var blocked: [SyncV2BlockedOperation] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return blocked
                }
                guard
                    status == SQLITE_ROW,
                    let value = columnText(statement, at: 0),
                    let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2EnqueueError.integrityFailure
                }
                blocked.append(
                    SyncV2BlockedOperation(
                        operationID: identifier,
                        contentByteCount: Int(
                            sqlite3_column_int64(statement, 1)
                        ),
                        limit: Self.maximumContentByteCount
                    )
                )
            }
        }
    }

    private func finalizeBatchAfterPreflight(
        batchID: UUID,
        insertedOperationCount: Int,
        blockedOperationCount: Int,
        timestamp: String
    ) throws {
        let status: String
        let errorCode: String?
        if insertedOperationCount == 0 {
            status = "completed"
            errorCode = nil
        } else if blockedOperationCount == insertedOperationCount {
            status = "attention"
            errorCode = Self.contentTooLargeErrorCode
        } else {
            return
        }
        try withStatement(
            """
            UPDATE sync_batches
            SET status = ?, last_error_code = ?, updated_at = ?
            WHERE batch_id = ?;
            """
        ) { statement in
            try bind(status, at: 1, to: statement)
            try bind(errorCode, at: 2, to: statement)
            try bind(timestamp, at: 3, to: statement)
            try bind(batchID.uuidString.lowercased(), at: 4, to: statement)
            try stepDone(statement)
        }
    }

    private func operationIDExists(_ operationID: UUID) throws -> Bool {
        try withStatement(
            """
            SELECT EXISTS(
                SELECT 1 FROM sync_operations WHERE operation_id = ?
            );
            """
        ) { statement in
            try bind(
                operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError()
            }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func insertBatch(_ batch: MaterializedBatch) throws {
        try withStatement(
            """
            INSERT INTO sync_batches(
                batch_id, local_project_id, local_transaction_id, batch_kind,
                mutation_count, payload_hash, status, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 'ready', ?, ?);
            """
        ) { statement in
            try bind(
                batch.batchID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.localTransactionID?.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(batch.kind.rawValue, at: 4, to: statement)
            try bind(batch.operations.count, at: 5, to: statement)
            try bind(batch.payloadHash, at: 6, to: statement)
            try bind(batch.timestamp, at: 7, to: statement)
            try bind(batch.timestamp, at: 8, to: statement)
            try stepDone(statement)
        }
    }

    private func insertEnsureProjectOperation(
        _ operation: MaterializedOperation,
        batch: MaterializedBatch,
        payload: MaterializedEnsureProject,
        timestamp: String
    ) throws {
        try withStatement(
            """
            INSERT INTO sync_operations(
                operation_id, batch_id, local_project_id, project_id,
                owner_subject, operation_kind, project_name, status,
                attempts, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 'ensure_project', ?, 'completed', 0, ?, ?);
            """
        ) { statement in
            try bind(
                operation.operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.batchID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(
                batch.serverProjectID.uuidString.lowercased(),
                at: 4,
                to: statement
            )
            try bind(
                batch.ownerSubject.uuidString.lowercased(),
                at: 5,
                to: statement
            )
            try bind(payload.projectName, at: 6, to: statement)
            try bind(timestamp, at: 7, to: statement)
            try bind(timestamp, at: 8, to: statement)
            try stepDone(statement)
        }
        // 만들어지는 순간의 상태를 지난 일로 적어 둔다. 이것이 없으면 뒤에
        // 붙는 사건이 시작 없이 끝만 있는 기록이 된다.
        try ensureOperationEventHistory(
            operationID: operation.operationID.uuidString.lowercased(),
            timestamp: timestamp
        )
        try withStatement(
            """
            UPDATE sync_projects
            SET project_name = ?, updated_at = ?
            WHERE local_project_id = ?;
            """
        ) { statement in
            try bind(payload.projectName, at: 1, to: statement)
            try bind(timestamp, at: 2, to: statement)
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try stepDone(statement)
        }
    }

    private func insertDocumentOperation(
        _ operation: MaterializedOperation,
        batch: MaterializedBatch,
        payload: MaterializedDocument,
        timestamp: String
    ) throws -> DocumentOperationDisposition {
        let existingState = try documentState(
            documentID: payload.documentID
        )
        if let existingState {
            guard
                existingState.localProjectID == batch.localProjectID,
                existingState.serverProjectID == batch.serverProjectID
            else {
                throw SyncV2EnqueueError.invalidMutation
            }
        }
        if payload.kind == .treeOrder {
            try coalescePendingTreeOrderOperations(
                documentID: payload.documentID,
                preserveEarlierCheckpoint: batch.operations.contains {
                    guard case let .document(document) = $0.payload else {
                        return false
                    }
                    return document.kind != .treeOrder
                },
                timestamp: timestamp
            )
        }
        let latestLifecycle = try latestActiveDocumentLifecycle(
            documentID: payload.documentID
        )
        if batch.kind == .documentSave,
           payload.kind == .documentCommit,
           !payload.isDeleted {
            if latestLifecycle?.isDeleted == true
                || (latestLifecycle == nil && existingState?.isDeleted == true) {
                // 휴지통 이동보다 늦게 도착한 편집 handoff는 서버 문서를
                // 조용히 복원하지 않는다. 로컬 휴지통 사본이 최신 원본이다.
                return .noOp
            }
            if let latestLifecycle,
               latestLifecycle.batchKind == .trashChange,
               !latestLifecycle.isDeleted,
               SyncV2ServerPath.hasExactBytes(
                   latestLifecycle.relativePath,
                   payload.relativePath
               ),
               latestLifecycle.content == payload.content {
                // 복원 전에 만들어진 동일 snapshot이 뒤늦게 flush된 경우다.
                return .noOp
            }
        }
        let hasEarlierOperation = try hasActiveOperation(
            documentID: payload.documentID
        )
        if let existingState,
           batch.kind == .documentSave,
           payload.kind == .documentCommit,
           existingState.serverRevision > 0,
           !existingState.isDeleted,
           !payload.isDeleted,
           SyncV2ServerPath.hasExactBytes(
               existingState.serverPath,
               payload.relativePath
           ),
           existingState.baseContent == payload.content,
           !hasEarlierOperation {
            try applyNoOpDocumentState(
                documentID: payload.documentID,
                localPath: payload.localPath,
                timestamp: timestamp
            )
            return .noOp
        }

        let state = try existingState ?? insertDocument(
            batch: batch,
            payload: payload,
            timestamp: timestamp
        )
        guard
            state.localProjectID == batch.localProjectID,
            state.serverProjectID == batch.serverProjectID
        else {
            throw SyncV2EnqueueError.invalidMutation
        }

        let isOversized =
            payload.contentByteCount > Self.maximumContentByteCount
        let operationStatus = isOversized ? "blocked" : "pending"
        let errorCode = isOversized
            ? Self.contentTooLargeErrorCode
            : nil
        let errorDetail = isOversized
            ? "\(payload.contentByteCount) > \(Self.maximumContentByteCount)"
            : nil
        let baseRevision = hasEarlierOperation
            ? nil
            : state.serverRevision
        let baseContent = hasEarlierOperation
            ? ""
            : state.baseContent

        let storedLocalPath = payload.isDeleted
            ? syncV2TombstoneLocalPath(documentID: payload.documentID)
            : payload.localPath
        try withStatement(
            """
            INSERT INTO sync_operations(
                operation_id, batch_id, local_project_id, project_id,
                owner_subject, document_id, device_id, document_sequence,
                local_save_generation, operation_kind, base_revision,
                base_content, local_path, relative_path, content,
                content_byte_count, content_hash, is_deleted, status,
                attempts, last_error_code, last_error_detail,
                created_at, updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                ?, 0, ?, ?, ?, ?
            );
            """
        ) { statement in
            try bind(
                operation.operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.batchID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(
                batch.serverProjectID.uuidString.lowercased(),
                at: 4,
                to: statement
            )
            try bind(
                batch.ownerSubject.uuidString.lowercased(),
                at: 5,
                to: statement
            )
            try bind(
                payload.documentID.uuidString.lowercased(),
                at: 6,
                to: statement
            )
            try bind(
                payload.deviceID.uuidString.lowercased(),
                at: 7,
                to: statement
            )
            try bind(state.nextSequence, at: 8, to: statement)
            try bind(
                payload.localSaveGeneration,
                at: 9,
                to: statement
            )
            try bind(payload.kind.rawValue, at: 10, to: statement)
            try bind(baseRevision, at: 11, to: statement)
            try bind(baseContent, at: 12, to: statement)
            try bind(storedLocalPath, at: 13, to: statement)
            try bind(payload.relativePath, at: 14, to: statement)
            try bind(payload.content, at: 15, to: statement)
            try bind(payload.contentByteCount, at: 16, to: statement)
            try bind(payload.contentHash, at: 17, to: statement)
            try bind(payload.isDeleted ? 1 : 0, at: 18, to: statement)
            try bind(operationStatus, at: 19, to: statement)
            try bind(errorCode, at: 20, to: statement)
            try bind(errorDetail, at: 21, to: statement)
            try bind(timestamp, at: 22, to: statement)
            try bind(timestamp, at: 23, to: statement)
            try stepDone(statement)
        }
        // 대기열에 올랐다는 것이 이 작업의 첫 사건이다.
        try ensureOperationEventHistory(
            operationID: operation.operationID.uuidString.lowercased(),
            timestamp: timestamp
        )

        try withStatement(
            """
            UPDATE sync_documents
            SET local_path = ?,
                next_document_sequence = ?,
                sync_state = ?,
                last_error_code = ?,
                updated_at = ?
            WHERE document_id = ?;
            """
        ) { statement in
            try bind(storedLocalPath, at: 1, to: statement)
            try bind(state.nextSequence + 1, at: 2, to: statement)
            try bind(isOversized ? "blocked" : "pending", at: 3, to: statement)
            try bind(errorCode, at: 4, to: statement)
            try bind(timestamp, at: 5, to: statement)
            try bind(
                payload.documentID.uuidString.lowercased(),
                at: 6,
                to: statement
            )
            try stepDone(statement)
        }
        return isOversized ? .blockedBySize : .queued
    }

    private func coalescePendingTreeOrderOperations(
        documentID: UUID,
        preserveEarlierCheckpoint: Bool,
        timestamp: String
    ) throws {
        // 이번 batch에 일반 문서 경로 변경이 있으면 편집 lease 때문에 오래
        // 기다릴 수 있다. 그 경우 앞선 빈 폴더용 체크포인트까지 취소하면
        // 관련 없는 문서 하나가 빈 폴더 공개를 함께 막으므로 그대로 둔다.
        guard !preserveEarlierCheckpoint else { return }
        let affectedBatchIDs = try withStatement(
            """
            SELECT DISTINCT batch_id
            FROM sync_operations
            WHERE document_id = ?
              AND operation_kind = 'tree_order'
              AND status IN ('pending', 'retry_wait', 'blocked');
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            var identifiers: [UUID] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return identifiers }
                guard status == SQLITE_ROW,
                      let value = columnText(statement, at: 0),
                      let identifier = UUID(uuidString: value)
                else {
                    throw SyncV2EnqueueError.integrityFailure
                }
                identifiers.append(identifier)
            }
        }
        guard !affectedBatchIDs.isEmpty else { return }
        // 아직 못 보낸 옛 순서들은 새 순서에 밀려난다. 여섯 번 자리를 옮겨도
        // 서버에 가는 것은 마지막 하나면 된다.
        let superseded = try prepareOperationEvents(
            where: """
            document_id = ?
              AND operation_kind = 'tree_order'
              AND status IN ('pending', 'retry_wait', 'blocked')
            """,
            timestamp: timestamp
        ) { statement in
            try bind(documentID.uuidString.lowercased(), at: 1, to: statement)
        }
        try withStatement(
            """
            UPDATE sync_operations
            SET status = 'cancelled',
                last_error_code = 'SUPERSEDED_BY_TREE_ORDER',
                last_error_detail = NULL,
                next_attempt_at = NULL,
                updated_at = ?
            WHERE document_id = ?
              AND operation_kind = 'tree_order'
              AND status IN ('pending', 'retry_wait', 'blocked');
            """
        ) { statement in
            try bind(timestamp, at: 1, to: statement)
            try bind(
                documentID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try stepDone(statement)
        }
        try recordOperationEvents(
            superseded,
            type: .superseded,
            errorCode: "SUPERSEDED_BY_TREE_ORDER",
            timestamp: timestamp
        )
        for batchID in affectedBatchIDs {
            try refreshBatchState(batchID: batchID, timestamp: timestamp)
        }
    }

    private func latestActiveDocumentLifecycle(
        documentID: UUID
    ) throws -> ActiveDocumentLifecycle? {
        try withStatement(
            """
            SELECT o.is_deleted, o.relative_path, o.content, b.batch_kind
            FROM sync_operations o
            JOIN sync_batches b ON b.batch_id = o.batch_id
            WHERE o.document_id = ?
              AND o.status NOT IN ('completed', 'cancelled')
            ORDER BY o.document_sequence DESC, o.queue_id DESC
            LIMIT 1;
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW,
                  let relativePath = columnText(statement, at: 1),
                  let content = columnText(statement, at: 2),
                  let kindValue = columnText(statement, at: 3),
                  let batchKind = SyncV2BatchKind(rawValue: kindValue)
            else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return ActiveDocumentLifecycle(
                isDeleted: sqlite3_column_int(statement, 0) == 1,
                relativePath: relativePath,
                content: content,
                batchKind: batchKind
            )
        }
    }

    private func hasActiveOperation(documentID: UUID) throws -> Bool {
        try withStatement(
            """
            SELECT EXISTS(
                SELECT 1
                FROM sync_operations
                WHERE document_id = ?
                  AND status NOT IN ('completed', 'cancelled')
            );
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError()
            }
            return sqlite3_column_int(statement, 0) == 1
        }
    }

    private func applyNoOpDocumentState(
        documentID: UUID,
        localPath: String,
        timestamp: String
    ) throws {
        try withStatement(
            """
            UPDATE sync_documents
            SET local_path = ?, sync_state = 'synced',
                last_error_code = NULL, updated_at = ?
            WHERE document_id = ?;
            """
        ) { statement in
            try bind(localPath, at: 1, to: statement)
            try bind(timestamp, at: 2, to: statement)
            try bind(
                documentID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try stepDone(statement)
        }
    }

    private func documentState(
        documentID: UUID
    ) throws -> DocumentState? {
        try withStatement(
            """
            SELECT local_project_id, project_id, server_revision,
                   server_path, base_content, is_deleted,
                   next_document_sequence
            FROM sync_documents
            WHERE document_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard
                status == SQLITE_ROW,
                let localValue = columnText(statement, at: 0),
                let localProjectID = UUID(uuidString: localValue),
                let serverValue = columnText(statement, at: 1),
                let serverProjectID = UUID(uuidString: serverValue),
                let serverPath = columnText(statement, at: 3),
                let baseContent = columnText(statement, at: 4)
            else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return DocumentState(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                serverRevision: Int(sqlite3_column_int64(statement, 2)),
                serverPath: serverPath,
                baseContent: baseContent,
                isDeleted: sqlite3_column_int(statement, 5) == 1,
                nextSequence: Int(sqlite3_column_int64(statement, 6))
            )
        }
    }

    private func insertDocument(
        batch: MaterializedBatch,
        payload: MaterializedDocument,
        timestamp: String
    ) throws -> DocumentState {
        try withStatement(
            """
            INSERT INTO sync_documents(
                document_id, local_project_id, project_id, local_path,
                server_path, server_revision, base_content, base_hash,
                is_deleted, sync_state, next_document_sequence,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 0, '', '', 0, 'local', 1, ?, ?);
            """
        ) { statement in
            try bind(
                payload.documentID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.serverProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(payload.localPath, at: 4, to: statement)
            try bind(payload.relativePath, at: 5, to: statement)
            try bind(timestamp, at: 6, to: statement)
            try bind(timestamp, at: 7, to: statement)
            try stepDone(statement)
        }
        return DocumentState(
            localProjectID: batch.localProjectID,
            serverProjectID: batch.serverProjectID,
            serverRevision: 0,
            serverPath: payload.relativePath,
            baseContent: "",
            isDeleted: false,
            nextSequence: 1
        )
    }

    /// 폴더 작업을 문서와 같은 대기열에 세운다. 폴더에는 본문도 경로도 없고
    /// 이름과 부모 연결만 있으므로 문서보다 훨씬 짧다.
    private func insertFolderOperation(
        _ operation: MaterializedOperation,
        batch: MaterializedBatch,
        payload: MaterializedFolder,
        timestamp: String
    ) throws {
        guard try !folderCycleWouldForm(
            folderID: payload.folderID,
            parentFolderID: payload.parentFolderID
        ) else {
            throw SyncV2EnqueueError.invalidMutation
        }
        let existingState = try folderState(folderID: payload.folderID)
        let state = try existingState ?? insertFolder(
            batch: batch,
            payload: payload,
            timestamp: timestamp
        )
        guard
            state.localProjectID == batch.localProjectID,
            state.serverProjectID == batch.serverProjectID
        else {
            throw SyncV2EnqueueError.invalidMutation
        }

        // 앞선 작업이 아직 남아 있으면 그 작업이 서버에서 받아올 revision을
        // 알 수 없다. 문서와 같이 비워 두고, 앞 작업이 끝날 때 채운다.
        let hasEarlierOperation = try hasActiveFolderOperation(
            folderID: payload.folderID
        )
        let baseRevision = hasEarlierOperation ? nil : state.serverRevision

        try withStatement(
            """
            INSERT INTO sync_operations(
                operation_id, batch_id, local_project_id, project_id,
                owner_subject, folder_id, parent_folder_id, folder_name,
                device_id, document_sequence, operation_kind, base_revision,
                is_deleted, status, attempts, created_at, updated_at
            ) VALUES (
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'folder_commit', ?, ?,
                'pending', 0, ?, ?
            );
            """
        ) { statement in
            try bind(
                operation.operationID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.batchID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(
                batch.serverProjectID.uuidString.lowercased(),
                at: 4,
                to: statement
            )
            try bind(
                batch.ownerSubject.uuidString.lowercased(),
                at: 5,
                to: statement
            )
            try bind(
                payload.folderID.uuidString.lowercased(),
                at: 6,
                to: statement
            )
            try bind(
                payload.parentFolderID?.uuidString.lowercased(),
                at: 7,
                to: statement
            )
            try bind(payload.name, at: 8, to: statement)
            try bind(
                payload.deviceID.uuidString.lowercased(),
                at: 9,
                to: statement
            )
            try bind(state.nextSequence, at: 10, to: statement)
            try bind(baseRevision, at: 11, to: statement)
            try bind(payload.isDeleted ? 1 : 0, at: 12, to: statement)
            try bind(timestamp, at: 13, to: statement)
            try bind(timestamp, at: 14, to: statement)
            try stepDone(statement)
        }
        // 폴더 작업도 대기열에 올랐다는 첫 사건을 남긴다.
        try ensureOperationEventHistory(
            operationID: operation.operationID.uuidString.lowercased(),
            timestamp: timestamp
        )

        try withStatement(
            """
            UPDATE sync_folders
            SET parent_folder_id = ?,
                name = ?,
                next_folder_sequence = ?,
                sync_state = 'pending',
                last_error_code = NULL,
                updated_at = ?
            WHERE folder_id = ?;
            """
        ) { statement in
            try bind(
                payload.parentFolderID?.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(payload.name, at: 2, to: statement)
            try bind(state.nextSequence + 1, at: 3, to: statement)
            try bind(timestamp, at: 4, to: statement)
            try bind(
                payload.folderID.uuidString.lowercased(),
                at: 5,
                to: statement
            )
            try stepDone(statement)
        }
    }

    /// 옮기려는 부모가 자기 자신이나 자기 자손이면 사슬이 고리가 되어 경로를
    /// 만들 수 없다. 제안된 부모에서 위로 거슬러 올라가며 확인한다.
    private func folderCycleWouldForm(
        folderID: UUID,
        parentFolderID: UUID?
    ) throws -> Bool {
        guard var current = parentFolderID else { return false }
        var visited: Set<UUID> = [folderID]
        while true {
            guard visited.insert(current).inserted else {
                // 자기 자신에 닿았거나 기존 사슬이 이미 고리다. 어느 쪽이든
                // 이 이동을 받아 주면 안 된다.
                return true
            }
            guard let next = try folderParentID(folderID: current) else {
                return false
            }
            current = next
        }
    }

    private func folderParentID(folderID: UUID) throws -> UUID? {
        try withStatement(
            """
            SELECT parent_folder_id FROM sync_folders
            WHERE folder_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                folderID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw SyncV2EnqueueError.integrityFailure
            }
            if sqlite3_column_type(statement, 0) == SQLITE_NULL {
                return nil
            }
            guard
                let value = columnText(statement, at: 0),
                let parentID = UUID(uuidString: value)
            else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return parentID
        }
    }

    private func hasActiveFolderOperation(folderID: UUID) throws -> Bool {
        try withStatement(
            """
            SELECT COUNT(*) FROM sync_operations
            WHERE folder_id = ?
              AND status NOT IN ('completed', 'cancelled');
            """
        ) { statement in
            try bind(
                folderID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return sqlite3_column_int64(statement, 0) > 0
        }
    }

    private func folderState(folderID: UUID) throws -> FolderState? {
        try withStatement(
            """
            SELECT local_project_id, project_id, server_revision,
                   is_deleted, next_folder_sequence
            FROM sync_folders
            WHERE folder_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(
                folderID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard
                status == SQLITE_ROW,
                let localValue = columnText(statement, at: 0),
                let localProjectID = UUID(uuidString: localValue),
                let serverValue = columnText(statement, at: 1),
                let serverProjectID = UUID(uuidString: serverValue)
            else {
                throw SyncV2EnqueueError.integrityFailure
            }
            return FolderState(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                serverRevision: Int(sqlite3_column_int64(statement, 2)),
                isDeleted: sqlite3_column_int(statement, 3) == 1,
                nextSequence: Int(sqlite3_column_int64(statement, 4))
            )
        }
    }

    private func insertFolder(
        batch: MaterializedBatch,
        payload: MaterializedFolder,
        timestamp: String
    ) throws -> FolderState {
        try withStatement(
            """
            INSERT INTO sync_folders(
                folder_id, local_project_id, project_id, parent_folder_id,
                name, server_revision, is_deleted, sync_state,
                next_folder_sequence, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, 0, 0, 'local', 1, ?, ?);
            """
        ) { statement in
            try bind(
                payload.folderID.uuidString.lowercased(),
                at: 1,
                to: statement
            )
            try bind(
                batch.localProjectID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
            try bind(
                batch.serverProjectID.uuidString.lowercased(),
                at: 3,
                to: statement
            )
            try bind(
                payload.parentFolderID?.uuidString.lowercased(),
                at: 4,
                to: statement
            )
            try bind(payload.name, at: 5, to: statement)
            try bind(timestamp, at: 6, to: statement)
            try bind(timestamp, at: 7, to: statement)
            try stepDone(statement)
        }
        return FolderState(
            localProjectID: batch.localProjectID,
            serverProjectID: batch.serverProjectID,
            serverRevision: 0,
            isDeleted: false,
            nextSequence: 1
        )
    }

    private func queuedOperation(
        from statement: OpaquePointer
    ) throws -> SyncV2QueuedOperation {
        guard
            let operationValue = columnText(statement, at: 0),
            let operationID = UUID(uuidString: operationValue),
            let kindValue = columnText(statement, at: 3),
            let kind = SyncV2OperationKind(rawValue: kindValue),
            let statusValue = columnText(statement, at: 4),
            let status = SyncV2OperationStatus(rawValue: statusValue),
            let localPath = columnText(statement, at: 6),
            let relativePath = columnText(statement, at: 7),
            let content = columnText(statement, at: 8),
            let contentHash = columnText(statement, at: 10)
        else {
            throw SyncV2EnqueueError.integrityFailure
        }
        let documentID = columnText(statement, at: 1)
            .flatMap(UUID.init(uuidString:))
        let documentSequence = sqlite3_column_type(statement, 2)
            == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, 2))
        let baseRevision = sqlite3_column_type(statement, 5)
            == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, 5))
        return SyncV2QueuedOperation(
            operationID: operationID,
            documentID: documentID,
            documentSequence: documentSequence,
            kind: kind,
            status: status,
            baseRevision: baseRevision,
            localPath: localPath,
            relativePath: relativePath,
            content: content,
            contentByteCount: Int(
                sqlite3_column_int64(statement, 9)
            ),
            contentHash: contentHash,
            isDeleted: sqlite3_column_int(statement, 11) == 1
        )
    }

    private func conflictRecord(
        from statement: OpaquePointer
    ) throws -> SyncV2ConflictRecord {
        guard
            let conflictValue = columnText(statement, at: 0),
            let conflictID = UUID(uuidString: conflictValue),
            let operationValue = columnText(statement, at: 1),
            let operationID = UUID(uuidString: operationValue),
            let documentValue = columnText(statement, at: 2),
            let documentID = UUID(uuidString: documentValue),
            let baseContent = columnText(statement, at: 3),
            let localContent = columnText(statement, at: 4),
            let remoteContent = columnText(statement, at: 5),
            let mergedContent = columnText(statement, at: 6),
            let remotePath = columnText(statement, at: 8),
            let createdValue = columnText(statement, at: 10),
            let createdAt = Self.date(createdValue)
        else {
            throw SyncV2StoreError.invalidStoredData
        }
        let remoteRevision = sqlite3_column_int64(statement, 7)
        let conflictCount = Int(sqlite3_column_int64(statement, 9))
        guard remoteRevision > 0, conflictCount > 0 else {
            throw SyncV2StoreError.invalidStoredData
        }
        return SyncV2ConflictRecord(
            conflictID: conflictID,
            operationID: operationID,
            documentID: documentID,
            snapshot: SyncV2ConflictSnapshot(
                baseContent: baseContent,
                localContent: localContent,
                remoteContent: remoteContent,
                mergedContent: mergedContent,
                remoteRevision: remoteRevision,
                remotePath: remotePath,
                conflictCount: conflictCount
            ),
            createdAt: createdAt
        )
    }

    private func prepare(
        migration: MigrationPlan
    ) throws {
        try configureConnection()
        let version = try schemaVersion()
        if version == 0 {
            let userTableCount = try scalarInt(
                """
                SELECT COUNT(*)
                FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%';
                """
            )
            guard userTableCount == 0 else {
                throw preparationFailure(
                    .unrecognizedSchema,
                    schemaVersion: version
                )
            }
            do {
                for step in migration.steps {
                    try execute(step.executableSQL)
                }
            } catch {
                throw preparationFailure(
                    .migrationFailed,
                    sqliteCode: currentSQLiteCode(),
                    schemaVersion: version
                )
            }
        } else if version > Self.currentSchemaVersion {
            throw preparationFailure(
                .schemaTooNew,
                schemaVersion: version
            )
        } else if version < Self.currentSchemaVersion {
            // 이미 열려 있던 저장소는 남은 단계만 이어서 적용한다. 대기 중인
            // 작업을 그대로 옮기므로 미전송 저장이 사라지지 않는다.
            do {
                for step in migration.steps(after: version) {
                    try execute(step.executableSQL)
                }
            } catch {
                throw preparationFailure(
                    .migrationFailed,
                    sqliteCode: currentSQLiteCode(),
                    schemaVersion: version
                )
            }
        }

        try verifyPragmas()
        try verifySchema()
        try verifyIntegrity()
        do {
            try recoverInterruptedWork()
        } catch {
            throw preparationFailure(
                .recoveryFailed,
                sqliteCode: currentSQLiteCode(),
                schemaVersion: Self.currentSchemaVersion
            )
        }
    }

    private func configureConnection() throws {
        guard let database = connection.handle else {
            throw preparationFailure(.databaseClosed)
        }
        guard sqlite3_busy_timeout(database, 10_000) == SQLITE_OK else {
            throw preparationFailure(
                .pragmaVerificationFailed,
                sqliteCode: currentSQLiteCode()
            )
        }
        do {
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = FULL;")
        } catch {
            throw preparationFailure(
                .pragmaVerificationFailed,
                sqliteCode: currentSQLiteCode()
            )
        }
    }

    private func verifyPragmas() throws {
        guard
            try scalarInt("PRAGMA foreign_keys;") == 1,
            try journalMode().lowercased() == "wal",
            try scalarInt("PRAGMA synchronous;") == 2
        else {
            throw preparationFailure(
                .pragmaVerificationFailed,
                sqliteCode: currentSQLiteCode()
            )
        }
    }

    private func verifySchema() throws {
        let version = try schemaVersion()
        guard version == Self.currentSchemaVersion else {
            throw preparationFailure(
                .migrationMismatch,
                schemaVersion: version
            )
        }
        let storedChecksum = try withStatement(
            """
            SELECT checksum
            FROM schema_migrations
            WHERE version = ? AND name = ?
            LIMIT 1;
            """
        ) { statement in
            guard
                sqlite3_bind_int(
                    statement,
                    1,
                    Int32(Self.currentSchemaVersion)
                ) == SQLITE_OK
            else {
                throw sqliteError()
            }
            try bind(Self.migrationName, at: 2, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw preparationFailure(
                    .migrationMismatch,
                    schemaVersion: version
                )
            }
            return columnText(statement, at: 0)
        }
        guard storedChecksum == migrationChecksum else {
            throw preparationFailure(
                .migrationMismatch,
                schemaVersion: version
            )
        }

        let expectedTables = [
            "schema_migrations",
            "sync_projects",
            "sync_documents",
            "sync_folders",
            "sync_batches",
            "sync_operations",
            "sync_conflicts",
        ]
        for table in expectedTables {
            let count = try withStatement(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = ?;
                """
            ) { statement in
                try bind(table, at: 1, to: statement)
                guard sqlite3_step(statement) == SQLITE_ROW else {
                    throw sqliteError()
                }
                return Int(sqlite3_column_int(statement, 0))
            }
            guard count == 1 else {
                throw preparationFailure(
                    .migrationMismatch,
                    schemaVersion: version
                )
            }
        }
    }

    private func verifyIntegrity() throws {
        let quickCheck = try scalarText("PRAGMA quick_check;")
        guard quickCheck == "ok" else {
            throw preparationFailure(
                .integrityCheckFailed,
                sqliteCode: currentSQLiteCode(),
                schemaVersion: try? schemaVersion()
            )
        }
        let violations = try withStatement(
            "PRAGMA foreign_key_check;"
        ) { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw sqliteError()
            }
            return status == SQLITE_ROW
        }
        guard !violations else {
            throw preparationFailure(
                .integrityCheckFailed,
                sqliteCode: currentSQLiteCode(),
                schemaVersion: try? schemaVersion()
            )
        }
        do {
            try verifyStoredIdentifiers()
        } catch {
            throw preparationFailure(
                .integrityCheckFailed,
                sqliteCode: currentSQLiteCode(),
                schemaVersion: try? schemaVersion()
            )
        }
    }

    private func verifyStoredIdentifiers() throws {
        try verifyUUIDColumns(
            """
            SELECT local_project_id, server_project_id, owner_subject
            FROM sync_projects;
            """,
            nullableColumns: [1, 2]
        )
        try verifyUUIDColumns(
            """
            SELECT document_id, local_project_id, project_id
            FROM sync_documents;
            """
        )
        try verifyUUIDColumns(
            """
            SELECT batch_id, local_project_id
            FROM sync_batches;
            """
        )
        try verifyUUIDColumns(
            """
            SELECT folder_id, local_project_id, project_id, parent_folder_id
            FROM sync_folders;
            """,
            nullableColumns: [3]
        )
        try verifyUUIDColumns(
            """
            SELECT operation_id, batch_id, local_project_id, project_id,
                   owner_subject, document_id, device_id, folder_id,
                   parent_folder_id
            FROM sync_operations;
            """,
            nullableColumns: [5, 6, 7, 8]
        )
        try verifyUUIDColumns(
            """
            SELECT conflict_id, operation_id, document_id
            FROM sync_conflicts;
            """
        )
    }

    private func verifyUUIDColumns(
        _ sql: String,
        nullableColumns: Set<Int32> = []
    ) throws {
        try withStatement(sql) { statement in
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return
                }
                guard status == SQLITE_ROW else {
                    throw sqliteError()
                }
                for index in 0..<sqlite3_column_count(statement) {
                    if sqlite3_column_type(statement, index) == SQLITE_NULL,
                       nullableColumns.contains(index) {
                        continue
                    }
                    guard
                        let value = columnText(statement, at: index),
                        UUID(uuidString: value) != nil
                    else {
                        throw SyncV2StoreError.invalidStoredData
                    }
                }
            }
        }
    }

    private func readBinding(
        sql: String,
        value: String
    ) throws -> ProjectSyncBinding? {
        guard availability() == .available else {
            throw ProjectBindingStoreError.unavailable
        }
        do {
            return try withStatement(sql) { statement in
                try bind(value, at: 1, to: statement)
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return nil
                }
                guard status == SQLITE_ROW else {
                    throw sqliteError()
                }
                guard
                    let localValue = columnText(statement, at: 0),
                    let localUUID = UUID(uuidString: localValue),
                    let kindValue = columnText(statement, at: 2),
                    let kind = ProjectBindingKind(rawValue: kindValue),
                    let name = columnText(statement, at: 3)
                else {
                    throw SyncV2StoreError.invalidStoredData
                }
                let serverID = columnText(statement, at: 1)
                    .flatMap(UUID.init(uuidString:))
                let ownerSubject = columnText(statement, at: 4)
                    .flatMap(UUID.init(uuidString:))
                return ProjectSyncBinding(
                    localProjectID: ProjectID(rawValue: localUUID),
                    serverProjectID: serverID,
                    kind: kind,
                    projectName: name,
                    ownerSubject: ownerSubject
                )
            }
        } catch {
            throw ProjectBindingStoreError.invalidBinding
        }
    }

    // MARK: - 사건 기록

    /// 사건 기록이 없는 작업에 지금 상태를 되만들어 넣는다.
    ///
    /// 이미 대기열에 쌓여 있던 작업들은 사건 기록 없이 status 칸만 들고 있다.
    /// 읽는 쪽을 사건 계산으로 옮기려면 그 전에 기록이 있어야 한다.
    ///
    /// 되만든 기록은 **다시 계산했을 때 지금 status와 같은 값이 나오도록** 만든다.
    /// 그래야 읽는 쪽을 옮기는 순간 아무것도 달라지지 않고, 그 뒤에 생기는
    /// 어긋남은 전부 진짜 신호가 된다.
    ///
    /// 발송 도중 꺼진 작업을 어떻게 되살릴지는 여기서 정하지 않는다. 그것은
    /// 복구의 문제이고, 이 함수는 지금 있는 것을 옮겨 적기만 한다.
    ///
    /// 같은 작업에 여러 번 돌아도 결과가 같다. 사건 식별자를 작업 식별자와
    /// 사건 종류에서 계산하고, 이미 기록이 있는 작업은 건너뛴다.
    func backfillOperationEvents() throws {
        let pending = try withStatement(
            """
            SELECT operation_id, status, last_error_code
            FROM sync_operations
            WHERE NOT EXISTS (
                SELECT 1 FROM sync_operation_events e
                WHERE e.operation_id = sync_operations.operation_id
            )
            ORDER BY queue_id;
            """
        ) { statement -> [(String, String, String?)] in
            var rows: [(String, String, String?)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let operationID = sqlite3_column_text(statement, 0),
                      let status = sqlite3_column_text(statement, 1)
                else {
                    throw SyncV2StoreError.invalidStoredData
                }
                let errorCode = sqlite3_column_text(statement, 2)
                    .map { String(cString: $0) }
                rows.append((
                    String(cString: operationID),
                    String(cString: status),
                    errorCode
                ))
            }
            return rows
        }
        guard !pending.isEmpty else { return }

        let recordedAt = Self.timestamp()
        for (operationID, status, errorCode) in pending {
            guard let state = SyncV2OperationStatus(rawValue: status) else {
                throw SyncV2StoreError.invalidStoredData
            }
            try seedOperationEvents(
                operationID: operationID,
                state: state,
                errorCode: errorCode,
                recordedAt: recordedAt,
                skipIfPresent: false
            )
        }
    }

    /// 그 상태에 이르게 하는 사건이다.
    ///
    /// `completed`는 `committed`와 `replayed` 둘 다에서 나온다. 둘을 가릴 수
    /// 있는 자리에서는 부르는 쪽이 직접 알려 준다. 여기서는 흔한 쪽을 고른다.
    static func eventType(
        reaching status: SyncV2OperationStatus
    ) -> SyncV2OperationEventType {
        switch status {
        case .pending: return .enqueued
        case .inflight: return .dispatchStarted
        case .retryWait: return .retryScheduled
        case .blocked: return .blocked
        case .conflict: return .conflictDetected
        case .completed: return .committed
        case .cancelled: return .cancelRequested
        }
    }

    /// 사건 기록이 아직 없는 작업에 지금 상태를 되만들어 넣는다.
    ///
    /// 쓰기 경로를 하나씩 옮기는 동안에는, 아직 안 옮긴 경로가 만든 작업이
    /// 기록 없이 들어와 있을 수 있다. 그 위에 곧바로 사건을 얹으면 시작도
    /// 없이 끝만 있는 기록이 된다. 그래서 얹기 전에 지난 일을 채운다.
    ///
    /// 쓰기 경로를 다 옮기고 나면 이 되만들기는 아무 일도 하지 않는다.
    private func ensureOperationEventHistory(
        operationID: String,
        timestamp: String
    ) throws {
        let status = try withStatement(
            """
            SELECT status FROM sync_operations WHERE operation_id = ?;
            """
        ) { statement -> String? in
            try bind(operationID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0)
            else {
                return nil
            }
            return String(cString: value)
        }
        guard let status, let state = SyncV2OperationStatus(rawValue: status) else {
            return
        }
        try seedOperationEvents(
            operationID: operationID,
            state: state,
            errorCode: nil,
            recordedAt: timestamp,
            skipIfPresent: true
        )
    }

    /// 조건에 걸리는 작업의 식별자를 모은다.
    ///
    /// 여러 줄을 한꺼번에 바꾸는 자리에서 쓴다. 바꾸기 **전에** 불러야 한다.
    /// 바꾼 뒤에는 조건에 더 이상 걸리지 않아 누구에게 사건을 남겨야 할지
    /// 알 수 없다.
    ///
    /// 조건이 별칭으로 자기 표를 가리키면 `alias`를 준다. 상관 부질의가
    /// `sync_operations`라는 이름을 그대로 쓰는 조건에는 주지 않는다. 별칭을
    /// 붙이면 그 이름으로는 더 이상 가리킬 수 없다.
    private func operationIDs(
        where condition: String,
        alias: String? = nil,
        bind binder: (OpaquePointer) throws -> Void
    ) throws -> [String] {
        let target = alias.map { "sync_operations AS \($0)" } ?? "sync_operations"
        return try withStatement(
            "SELECT operation_id FROM \(target) WHERE \(condition);"
        ) { statement in
            try binder(statement)
            var ids: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let value = sqlite3_column_text(statement, 0) else {
                    throw SyncV2StoreError.invalidStoredData
                }
                ids.append(String(cString: value))
            }
            return ids
        }
    }

    /// 여럿을 한꺼번에 바꾸기 직전에 부른다. 대상을 모으고, 각자의 지난 일을
    /// 채워 둔 뒤 식별자를 돌려준다.
    ///
    /// 바꾼 다음에 `recordOperationEvents`로 사건을 남기면 된다.
    ///
    /// 이미 끝난 것으로 계산되는 작업은 목록에서 뺀다. 계약이 끝난 작업에는
    /// 사건을 못 붙이게 하는데, 여기서 그걸 오류로 올리면 장부 한 줄이
    /// 어긋났다는 이유로 저장소가 아예 열리지 않는다. 그러면 사용자는 동기화를
    /// 통째로 잃는다. 대신 그냥 두고 `operationStateDivergences()`에 드러나게
    /// 한다. 고칠 것이 있으면 그걸 보고 고치면 된다.
    private func prepareOperationEvents(
        where condition: String,
        alias: String? = nil,
        timestamp: String,
        bind binder: (OpaquePointer) throws -> Void = { _ in }
    ) throws -> [String] {
        let targets = try operationIDs(
            where: condition,
            alias: alias,
            bind: binder
        )
        var appendable: [String] = []
        for operationID in targets {
            try ensureOperationEventHistory(
                operationID: operationID,
                timestamp: timestamp
            )
            let events = try operationEvents(operationID: operationID)
            guard (try? SyncV2OperationStateDerivation
                .requireAppendable(to: events)) != nil
            else {
                continue
            }
            appendable.append(operationID)
        }
        return appendable
    }

    /// 여러 작업에 같은 사건을 남긴다.
    private func recordOperationEvents(
        _ operationIDs: [String],
        type: SyncV2OperationEventType,
        errorCode: String?,
        timestamp: String,
        relatedOperationID: String? = nil
    ) throws {
        for operationID in operationIDs {
            try appendOperationEvent(
                operationID: operationID,
                type: type,
                errorCode: errorCode,
                timestamp: timestamp,
                relatedOperationID: relatedOperationID
            )
        }
    }

    /// 한 문서에 걸려 있던 다른 작업들을 밀어낼 준비를 한다.
    ///
    /// 살아남는 작업 하나만 남기고 나머지를 고른다. 밀어낸 뒤에는 조건에
    /// 걸리지 않으므로 바꾸기 전에 불러야 한다.
    private func prepareSupersededSiblings(
        documentID: UUID,
        survivingOperationID: UUID,
        timestamp: String
    ) throws -> [String] {
        try prepareOperationEvents(
            where: """
            document_id = ?
              AND operation_id <> ?
              AND status NOT IN ('completed', 'cancelled')
            """,
            timestamp: timestamp
        ) { statement in
            try bind(documentID.uuidString.lowercased(), at: 1, to: statement)
            try bind(
                survivingOperationID.uuidString.lowercased(),
                at: 2,
                to: statement
            )
        }
    }

    /// 사건을 하나 덧붙인다.
    ///
    /// 이미 끝난 작업에는 붙이지 않는다. 붙이면 끝난 작업이 되살아나 다시
    /// 발송된다. 계약이 `OPERATION_TERMINAL`로 막으라고 한 자리다.
    private func appendOperationEvent(
        operationID: String,
        type: SyncV2OperationEventType,
        errorCode: String?,
        timestamp: String,
        relatedOperationID: String? = nil
    ) throws {
        let events = try operationEvents(operationID: operationID)
        try SyncV2OperationStateDerivation.requireAppendable(to: events)
        try insertOperationEvent(
            eventID: UUID().uuidString.lowercased(),
            operationID: operationID,
            sequence: events.count + 1,
            type: type,
            recordedAt: timestamp,
            errorCode: errorCode,
            relatedOperationID: relatedOperationID
        )
    }

    /// 한 작업의 지난 일을 되만들어 넣는다.
    private func seedOperationEvents(
        operationID: String,
        state: SyncV2OperationStatus,
        errorCode: String?,
        recordedAt: String,
        skipIfPresent: Bool
    ) throws {
        if skipIfPresent,
           try !operationEvents(operationID: operationID).isEmpty {
            return
        }
        let types = Self.seedEventTypes(for: state)
        for (index, type) in types.enumerated() {
            // 마지막 사건만 오류를 안고 간다. 그 앞의 사건들은 이 작업이 어떤
            // 길을 지나왔는지 표시할 뿐 오류를 낸 적이 없다.
            try insertOperationEvent(
                eventID: Self.legacyEventID(
                    operationID: operationID,
                    eventType: type
                ),
                operationID: operationID,
                sequence: index + 1,
                type: type,
                recordedAt: recordedAt,
                errorCode: index == types.count - 1 ? errorCode : nil
            )
        }
    }

    /// 지금 상태를 그대로 되돌려 주는 최소한의 사건 줄기다.
    ///
    /// 각 줄기의 마지막 사건이 그 상태로 이어져야 한다. 그렇지 않으면 되만든
    /// 순간부터 기록과 칸이 어긋난다.
    static func seedEventTypes(
        for state: SyncV2OperationStatus
    ) -> [SyncV2OperationEventType] {
        switch state {
        case .pending: return [.enqueued]
        case .inflight: return [.enqueued, .dispatchStarted]
        case .retryWait: return [.enqueued, .dispatchStarted, .retryScheduled]
        case .blocked: return [.enqueued, .blocked]
        case .conflict: return [.enqueued, .dispatchStarted, .conflictDetected]
        case .completed: return [.enqueued, .dispatchStarted, .committed]
        case .cancelled: return [.enqueued, .cancelRequested]
        }
    }

    /// 되만든 사건의 식별자다. 무작위로 만들면 다시 돌릴 때마다 달라져
    /// 같은 사건이 여러 벌 쌓인다. Windows도 같은 이름으로 계산한다.
    static func legacyEventID(operationID: String, eventType: SyncV2OperationEventType) -> String {
        let namespaceURL = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
        return syncV2UUIDv5(
            namespace: namespaceURL,
            name: "writerpad:stage8:legacy:\(operationID):\(eventType.rawValue)"
        ).uuidString.lowercased()
    }

    private func insertOperationEvent(
        eventID: String,
        operationID: String,
        sequence: Int,
        type: SyncV2OperationEventType,
        recordedAt: String,
        errorCode: String?,
        relatedOperationID: String? = nil
    ) throws {
        try withStatement(
            """
            INSERT OR IGNORE INTO sync_operation_events (
                event_id, operation_id, event_sequence, event_type,
                recorded_at, error_code, related_operation_id, detail_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, '{}');
            """
        ) { statement in
            try bind(eventID, at: 1, to: statement)
            try bind(operationID, at: 2, to: statement)
            try bind(sequence, at: 3, to: statement)
            try bind(type.rawValue, at: 4, to: statement)
            try bind(recordedAt, at: 5, to: statement)
            try bind(errorCode, at: 6, to: statement)
            try bind(relatedOperationID, at: 7, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError()
            }
        }
    }

    /// 한 작업의 사건 기록을 차례대로 읽는다.
    ///
    /// 저장소는 식별자를 소문자로 적는다. 문자열을 그대로 받으면 대소문자가
    /// 어긋난 조회가 조용히 빈 결과를 내므로 UUID로 받아 안에서 맞춘다.
    func operationEvents(operationID: UUID) throws -> [SyncV2OperationEvent] {
        try operationEvents(operationID: operationID.uuidString.lowercased())
    }

    private func operationEvents(operationID: String) throws -> [SyncV2OperationEvent] {
        try withStatement(
            """
            SELECT event_sequence, event_type, error_code
            FROM sync_operation_events
            WHERE operation_id = ?
            ORDER BY event_sequence;
            """
        ) { statement in
            try bind(operationID, at: 1, to: statement)
            var events: [SyncV2OperationEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawType = sqlite3_column_text(statement, 1),
                      let type = SyncV2OperationEventType(
                          rawValue: String(cString: rawType)
                      )
                else {
                    throw SyncV2StoreError.invalidStoredData
                }
                let errorCode = sqlite3_column_text(statement, 2)
                    .map { String(cString: $0) }
                events.append(
                    SyncV2OperationEvent(
                        sequence: Int(sqlite3_column_int64(statement, 0)),
                        type: type,
                        errorCode: errorCode
                    )
                )
            }
            return events
        }
    }

    /// 작업을 취소한다.
    ///
    /// 계약이 정한 세 가지를 지킨다. 같은 사건 식별자로 다시 오면 기록을
    /// 늘리지 않고 이미 취소됐다고 답한다. 이미 취소된 작업에 다시 요청해도
    /// 오류가 아니다. 그러나 이미 끝난 작업은 `OPERATION_TERMINAL`로 거절한다.
    /// 완료된 작업을 취소로 덮으면 서버에 이미 올라간 글이 안 올라간 것처럼
    /// 보인다.
    @discardableResult
    func cancelOperation(
        operationID: UUID,
        cancelEventID: UUID
    ) throws -> SyncV2OperationCancelOutcome {
        let operationKey = operationID.uuidString.lowercased()
        let eventKey = cancelEventID.uuidString.lowercased()
        return try transaction {
            guard try storedOperationStatus(operationID: operationID) != nil else {
                throw SyncV2ContractError("INVALID_ARGUMENT", "모르는 작업이다")
            }
            if let owner = try operationEventOwner(eventID: eventKey) {
                guard owner.operationID == operationKey,
                      owner.type == .cancelRequested
                else {
                    throw SyncV2ContractError("EVENT_ID_REUSED")
                }
                return .alreadyCancelled(eventID: cancelEventID)
            }

            let timestamp = Self.timestamp()
            try ensureOperationEventHistory(
                operationID: operationKey,
                timestamp: timestamp
            )
            let current = try SyncV2OperationStateDerivation.state(
                from: try operationEvents(operationID: operationKey)
            )
            if current == .completed {
                throw SyncV2ContractError.operationTerminal
            }
            if current == .cancelled {
                return .alreadyCancelled(eventID: nil)
            }

            try withStatement(
                """
                UPDATE sync_operations
                SET status = 'cancelled',
                    next_attempt_at = NULL,
                    updated_at = ?
                WHERE operation_id = ?;
                """
            ) { statement in
                try bind(timestamp, at: 1, to: statement)
                try bind(operationKey, at: 2, to: statement)
                try stepDone(statement)
            }
            try insertOperationEvent(
                eventID: eventKey,
                operationID: operationKey,
                sequence: try operationEvents(operationID: operationKey).count + 1,
                type: .cancelRequested,
                recordedAt: timestamp,
                errorCode: nil
            )
            return .cancelled(eventID: cancelEventID)
        }
    }

    /// 사건 식별자가 어느 작업의 무슨 사건이었는지 찾는다.
    private func operationEventOwner(
        eventID: String
    ) throws -> (operationID: String, type: SyncV2OperationEventType)? {
        try withStatement(
            """
            SELECT operation_id, event_type
            FROM sync_operation_events
            WHERE event_id = ?
            LIMIT 1;
            """
        ) { statement in
            try bind(eventID, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let operationID = sqlite3_column_text(statement, 0),
                  let rawType = sqlite3_column_text(statement, 1),
                  let type = SyncV2OperationEventType(
                      rawValue: String(cString: rawType)
                  )
            else {
                return nil
            }
            return (String(cString: operationID), type)
        }
    }

    /// 사건에서 계산한 상태와 status 칸이 어긋난 작업이다.
    ///
    /// 읽는 쪽을 옮기기 전에 이것이 비어 있어야 한다. 비어 있지 않다면 어느
    /// 쓰기 경로가 칸만 고치고 사건을 남기지 않았다는 뜻이고, 그 경로를 찾기
    /// 전에는 옮기면 안 된다.
    func operationStateDivergences() throws -> [SyncV2OperationStateDivergence] {
        let rows = try withStatement(
            """
            SELECT operation_id, status FROM sync_operations ORDER BY queue_id;
            """
        ) { statement -> [(String, String)] in
            var rows: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let operationID = sqlite3_column_text(statement, 0),
                      let status = sqlite3_column_text(statement, 1)
                else {
                    throw SyncV2StoreError.invalidStoredData
                }
                rows.append((String(cString: operationID), String(cString: status)))
            }
            return rows
        }

        var divergences: [SyncV2OperationStateDivergence] = []
        for (operationID, status) in rows {
            let stored = SyncV2OperationStatus(rawValue: status)
            let events = try operationEvents(operationID: operationID)
            let derived = try? SyncV2OperationStateDerivation.state(from: events)
            if derived != stored {
                divergences.append(
                    SyncV2OperationStateDivergence(
                        operationID: operationID,
                        storedStatus: stored,
                        derivedStatus: derived
                    )
                )
            }
        }
        return divergences
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database = connection.handle else {
            throw SyncV2StoreError.unavailable(
                Self.diagnostic(.databaseClosed)
            )
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(
            database,
            sql,
            nil,
            nil,
            &errorMessage
        )
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database = connection.handle else {
            throw SyncV2StoreError.unavailable(
                Self.diagnostic(.databaseClosed)
            )
        }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        )
        guard status == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError()
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func scalarText(_ sql: String) throws -> String {
        try withStatement(sql) { statement in
            guard
                sqlite3_step(statement) == SQLITE_ROW,
                let value = columnText(statement, at: 0)
            else {
                throw sqliteError()
            }
            return value
        }
    }

    private func bind(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                unsafeBitCast(
                    -1,
                    to: sqlite3_destructor_type.self
                )
            )
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(
        _ value: Int?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_int64(
                statement,
                index,
                Int64(value)
            )
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func bind(
        _ value: Int64?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let status: Int32
        if let value {
            status = sqlite3_bind_int64(statement, index, value)
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else {
            throw sqliteError()
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func columnText(
        _ statement: OpaquePointer,
        at index: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: value)
    }

    private func sqliteError() -> SyncV2StoreError {
        .sqlite(code: currentSQLiteCode())
    }

    private func currentSQLiteCode() -> Int32 {
        guard let database = connection.handle else { return SQLITE_MISUSE }
        return sqlite3_extended_errcode(database)
    }

    private func lastSQLiteCode() -> Int32 {
        currentSQLiteCode()
    }

    private func preparationFailure(
        _ reason: SyncV2StoreDiagnosticReason,
        sqliteCode: Int32? = nil,
        schemaVersion: Int? = nil
    ) -> StorePreparationFailure {
        StorePreparationFailure(
            diagnostic: Self.diagnostic(
                reason,
                sqliteCode: sqliteCode,
                schemaVersion: schemaVersion
            )
        )
    }

    private static func loadMigrationResource(
        bundle: Bundle
    ) throws -> MigrationPlan {
        let steps = try (1...currentSchemaVersion).map { version in
            try loadMigrationStep(bundle: bundle, version: version)
        }
        guard let head = steps.last else {
            throw ResourceError.missing
        }
        return MigrationPlan(steps: steps, head: head)
    }

    /// 버전별 SQL을 각각 읽는다. 새로 만드는 저장소는 V1부터 차례로 올리고,
    /// 이미 열려 있던 저장소는 자기 버전보다 높은 단계만 적용한다. 두 경로가
    /// 같은 파일을 쓰므로 스키마 정의가 갈라지지 않는다.
    private static func loadMigrationStep(
        bundle: Bundle,
        version: Int
    ) throws -> MigrationResource {
        guard let url = bundle.url(
            forResource: "SyncV2StoreSchemaV\(version)",
            withExtension: "sql"
        ) else {
            throw ResourceError.missing
        }
        let data = try Data(contentsOf: url)
        guard let template = String(data: data, encoding: .utf8) else {
            throw ResourceError.invalidUTF8
        }
        let checksum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let marker = "design-fixture-v\(version)"
        guard template.contains("'\(marker)'") else {
            throw ResourceError.markerMissing
        }
        return MigrationResource(
            version: version,
            executableSQL: template.replacingOccurrences(
                of: "'\(marker)'",
                with: "'\(checksum)'"
            ),
            checksum: checksum
        )
    }

    private static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func diagnostic(
        _ reason: SyncV2StoreDiagnosticReason,
        sqliteCode: Int32? = nil,
        schemaVersion: Int? = nil
    ) -> SyncV2StoreDiagnostic {
        SyncV2StoreDiagnostic(
            reason: reason,
            sqliteCode: sqliteCode,
            schemaVersion: schemaVersion
        )
    }
}

actor LazySyncV2ProjectBindingStore:
    ProjectBindingStoring,
    DurableLocalChangeRecording,
    SyncV2DispatchStoring,
    SyncV2ConflictResolving,
    SyncV2DocumentRevisionProviding,
    SyncV2FolderMigrationMarking,
    SyncV2SnapshotStateStoring {
    private let databaseURL: URL?
    private let deviceIdentityProvider: (any DeviceIdentityProviding)?
    private let dispatchWakeup: SyncV2DispatchWakeup?
    private var store: SyncV2Store?
    private(set) var diagnostic: SyncV2StoreDiagnostic?

    init(
        databaseURL: URL?,
        deviceIdentityProvider: (any DeviceIdentityProviding)? = nil,
        dispatchWakeup: SyncV2DispatchWakeup? = nil
    ) {
        self.databaseURL = databaseURL
        self.deviceIdentityProvider = deviceIdentityProvider
        self.dispatchWakeup = dispatchWakeup
    }

    func availability() async -> ProjectBindingStoreAvailability {
        await resolvedStore() == nil ? .unavailable : .available
    }

    func binding(
        for localProjectID: ProjectID
    ) async throws -> ProjectSyncBinding? {
        guard let store = await resolvedStore() else {
            throw ProjectBindingStoreError.unavailable
        }
        return try await store.binding(for: localProjectID)
    }

    func binding(
        forServerProjectID serverProjectID: UUID
    ) async throws -> ProjectSyncBinding? {
        guard let store = await resolvedStore() else {
            throw ProjectBindingStoreError.unavailable
        }
        return try await store.binding(
            forServerProjectID: serverProjectID
        )
    }

    func allBindings() async throws -> [ProjectSyncBinding] {
        guard let store = await resolvedStore() else {
            throw ProjectBindingStoreError.unavailable
        }
        return try await store.allBindings()
    }

    func save(_ binding: ProjectSyncBinding) async throws {
        guard let store = await resolvedStore() else {
            throw ProjectBindingStoreError.unavailable
        }
        try await store.save(binding)
    }

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        guard let store = await resolvedStore() else {
            // DB를 열 수 없을 때는 기존 연결 여부를 판정할 수 없으므로
            // snapshot을 잃지 않는 보수적인 경계를 사용한다.
            return .durableQueue
        }
        do {
            guard let binding = try await store.binding(for: projectID),
                  binding.kind != .localOnly
            else {
                return .localOnly
            }
            return .durableQueue
        } catch {
            return .durableQueue
        }
    }

    func record(
        _ batch: LocalMutationBatch
    ) async -> DurableRecordResult {
        guard let store = await resolvedStore() else {
            return .localSavedButNotQueued(
                reason: "동기화 저장소를 열 수 없습니다."
            )
        }

        let binding: ProjectSyncBinding?
        do {
            binding = try await store.binding(for: batch.projectID)
        } catch {
            return .localSavedButNotQueued(
                reason: "프로젝트 연결 상태를 확인할 수 없습니다."
            )
        }
        guard let binding, binding.kind != .localOnly else {
            return .localOnly
        }
        guard let deviceIdentityProvider else {
            return .localSavedButNotQueued(
                reason: "기기 식별 정보를 사용할 수 없습니다."
            )
        }

        let deviceID: UUID
        do {
            deviceID = try await deviceIdentityProvider.currentIdentifier().uuid
        } catch {
            return .localSavedButNotQueued(
                reason: "기기 식별 정보를 불러올 수 없습니다."
            )
        }

        var syncMutations: [SyncV2Mutation] = []
        syncMutations.reserveCapacity(batch.mutations.count)
        for mutation in batch.mutations {
            switch mutation {
            case let .ensureProject(operationID, name):
                guard !name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    return .localSavedButNotQueued(
                        reason: "프로젝트 snapshot 검증에 실패했습니다."
                    )
                }
                syncMutations.append(
                    .ensureProject(
                        SyncV2EnsureProjectMutation(
                            operationID: operationID,
                            projectName: name
                        )
                    )
                )
            case let .documentSnapshot(
                operationID,
                documentID,
                relativePath,
                content,
                contentHash,
                localSaveGeneration,
                isDeleted
            ):
                let actualHash = SHA256ContentHasher().sha256(
                    for: Data(content.utf8)
                )
                guard
                    actualHash == contentHash,
                    let generation = Int(exactly: localSaveGeneration)
                else {
                    return .localSavedButNotQueued(
                        reason: "저장 snapshot 검증에 실패했습니다."
                    )
                }
                syncMutations.append(
                    .document(
                        SyncV2DocumentMutation(
                            operationID: operationID,
                            documentID: documentID.rawValue,
                            deviceID: deviceID,
                            localSaveGeneration: generation,
                            kind: .documentCommit,
                            localPath: relativePath.rawValue,
                            relativePath: relativePath.rawValue,
                            content: content,
                            isDeleted: isDeleted
                        )
                    )
                )
            case let .treeOrder(operationID, content, generation):
                guard Int(exactly: generation) != nil else {
                    return .localSavedButNotQueued(
                        reason: "바인더 순서 snapshot 검증에 실패했습니다."
                    )
                }
                let path = syncV2TreeOrderPath
                let serverProjectID = binding.serverProjectID!
                syncMutations.append(
                    .document(
                        SyncV2DocumentMutation(
                            operationID: operationID,
                            documentID: syncV2UUIDv5(
                                namespace: serverProjectID,
                                name: path
                            ),
                            deviceID: deviceID,
                            localSaveGeneration: Int(generation),
                            kind: .treeOrder,
                            localPath: path,
                            relativePath: path,
                            content: content,
                            isDeleted: false
                        )
                    )
                )
            case let .trashPurge(operationID, content, _):
                let path = syncV2TrashPurgePath
                let serverProjectID = binding.serverProjectID!
                syncMutations.append(
                    .document(
                        SyncV2DocumentMutation(
                            operationID: operationID,
                            documentID: syncV2UUIDv5(
                                namespace: serverProjectID,
                                name: path
                            ),
                            deviceID: deviceID,
                            localSaveGeneration: nil,
                            kind: .trashPurge,
                            localPath: path,
                            relativePath: path,
                            content: content,
                            isDeleted: false
                        )
                    )
                )
            case let .folderSnapshot(
                operationID,
                folderID,
                parentFolderID,
                name,
                isDeleted
            ):
                syncMutations.append(
                    .folder(
                        SyncV2FolderMutation(
                            operationID: operationID,
                            folderID: folderID.rawValue,
                            parentFolderID: parentFolderID?.rawValue,
                            deviceID: deviceID,
                            name: name,
                            isDeleted: isDeleted
                        )
                    )
                )
            }
        }

        do {
            let receipt = try await store.enqueue(
                SyncV2EnqueueBatch(
                    batchID: batch.batchID,
                    localProjectID: batch.projectID,
                    localTransactionID: batch.localTransactionID,
                    kind: Self.syncBatchKind(batch.kind),
                    mutations: syncMutations
                )
            )
            if let blocked = receipt.blockedOperations.max(
                by: { $0.contentByteCount < $1.contentByteCount }
            ) {
                return .serverSizeLimitExceeded(
                    byteCount: blocked.contentByteCount,
                    limit: blocked.limit
                )
            }
            if receipt.operationIDs.isEmpty,
               !receipt.noOpOperationIDs.isEmpty {
                return .notNeeded
            }
            if !receipt.operationIDs.isEmpty {
                await dispatchWakeup?.signal()
            }
            return .queued(operationIDs: receipt.operationIDs)
        } catch let error as SyncV2EnqueueError {
            return .localSavedButNotQueued(
                reason: Self.recordFailureMessage(error)
            )
        } catch {
            return .localSavedButNotQueued(
                reason: "동기화 기록 중 알 수 없는 오류가 발생했습니다."
            )
        }
    }

    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) async -> DurableRecordResult? {
        guard let store = await resolvedStore() else { return nil }
        return try? await store.preservedSizeLimitResult(
            localProjectID: projectID,
            documentID: documentID
        )
    }

    func recoverInterruptedWork() async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.recoverInterruptedWork()
    }

    func serverRevision(for documentID: UUID) async throws -> Int64? {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.serverRevision(for: documentID)
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2SnapshotLocalState? {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: documentID
        )
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) async throws -> Bool {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: snapshot,
            expectedRevision: expectedRevision
        )
    }

    func applyFolderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        folders: [SyncV2RemoteFolder],
        excluding blockedFolderIDs: Set<UUID>
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.applyFolderSnapshotBaselines(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            folders: folders,
            excluding: blockedFolderIDs
        )
    }

    func adoptEquivalentInitialDocument(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws -> Bool {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.adoptEquivalentInitialDocument(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            localDocumentID: localDocumentID,
            snapshot: snapshot
        )
    }

    func claimReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2DispatchOperation] {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.claimReadyOperations(
            localProjectID: localProjectID,
            limit: limit,
            now: now
        )
    }

    func claimReadyFolderOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2FolderDispatchOperation] {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.claimReadyFolderOperations(
            localProjectID: localProjectID,
            limit: limit,
            now: now
        )
    }

    func complete(
        _ operation: SyncV2FolderDispatchOperation,
        result: SyncV2CommitFolderResult
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.complete(operation, result: result)
    }

    func deferRetry(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.deferRetry(
            operation,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nextAttemptAt
        )
    }

    func markConflict(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.markConflict(
            operation,
            errorCode: errorCode,
            detail: detail
        )
    }

    func markBlocked(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.markBlocked(
            operation,
            errorCode: errorCode,
            detail: detail
        )
    }

    func rebaseFolderAfterRevisionConflict(
        _ operation: SyncV2FolderDispatchOperation,
        remote: SyncV2RemoteFolder
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.rebaseFolderAfterRevisionConflict(
            operation,
            remote: remote
        )
    }

    /// 저장소를 열 수 없으면 이관이 끝난 것으로 보지 않는다. 표식을 확인하지
    /// 못한 채 끝났다고 하면 이관 자체를 건너뛰게 된다.
    func isFolderMigrationCompleted(
        localProjectID: ProjectID
    ) async throws -> Bool {
        guard let store = await resolvedStore() else {
            throw SyncV2StoreError.invalidStoredData
        }
        return try await store.isFolderMigrationCompleted(
            localProjectID: localProjectID
        )
    }

    func markFolderMigrationCompleted(
        localProjectID: ProjectID
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2StoreError.invalidStoredData
        }
        try await store.markFolderMigrationCompleted(
            localProjectID: localProjectID
        )
    }

    func foldersWithPendingOperations(
        localProjectID: ProjectID
    ) async throws -> Set<UUID> {
        guard let store = await resolvedStore() else {
            throw SyncV2StoreError.invalidStoredData
        }
        return try await store.foldersWithPendingOperations(
            localProjectID: localProjectID
        )
    }

    func readyLocalProjectIDs(
        now: Date
    ) async throws -> [ProjectID] {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.readyLocalProjectIDs(now: now)
    }

    func complete(
        _ operation: SyncV2DispatchOperation,
        result: SyncV2CommitDocumentResult
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.complete(operation, result: result)
    }

    func deferRetry(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.deferRetry(
            operation,
            errorCode: errorCode,
            detail: detail,
            nextAttemptAt: nextAttemptAt
        )
    }

    func markConflict(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.markConflict(
            operation,
            errorCode: errorCode,
            detail: detail
        )
    }

    func preserveConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        conflictCount: Int,
        errorCode: String,
        detail: String?
    ) async throws -> SyncV2ConflictPreservationResult {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.preserveConflict(
            operation,
            remote: remote,
            local: local,
            mergedContent: mergedContent,
            conflictCount: conflictCount,
            errorCode: errorCode,
            detail: detail
        )
    }

    func unresolvedConflict(
        documentID: UUID
    ) async throws -> SyncV2ConflictRecord? {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.unresolvedConflict(
            documentID: documentID
        )
    }

    func unresolvedConflicts(
        localProjectID: ProjectID
    ) async throws -> [SyncV2ConflictRecord] {
        guard let store = await resolvedStore() else {
            throw SyncV2ConflictResolutionError.unavailable
        }
        return try await store.unresolvedConflicts(
            localProjectID: localProjectID
        )
    }

    func resolveConflict(
        _ request: SyncV2ConflictResolutionRequest
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2ConflictResolutionError.unavailable
        }
        try await store.resolveConflict(request)
        await dispatchWakeup?.signal()
    }

    func markBlocked(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.markBlocked(
            operation,
            errorCode: errorCode,
            detail: detail
        )
    }

    func latestLocalSnapshot(
        for operation: SyncV2DispatchOperation
    ) async throws -> SyncV2RebaseLocalSnapshot {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.latestLocalSnapshot(for: operation)
    }

    func recoverMissingRemoteDocument(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.recoverMissingRemoteDocument(operation)
    }

    func recoverMissingRemoteProject(
        _ operation: SyncV2DispatchOperation
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.recoverMissingRemoteProject(operation)
    }

    func projectName(
        for operation: SyncV2DispatchOperation
    ) async throws -> String {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.projectName(for: operation)
    }

    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) async throws -> SyncV2AutomaticRebaseStoreResult {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.rebaseAfterRevisionConflict(
            operation,
            remote: remote,
            local: local,
            mergedContent: mergedContent,
            mergedPath: mergedPath
        )
    }

    func makeRetryWaitOperationsReady(
        localProjectID: ProjectID?
    ) async throws {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        try await store.makeRetryWaitOperationsReady(
            localProjectID: localProjectID
        )
    }

    func nextRetryDate(
        localProjectID: ProjectID?
    ) async throws -> Date? {
        guard let store = await resolvedStore() else {
            throw SyncV2DispatchStoreError.unavailable
        }
        return try await store.nextRetryDate(
            localProjectID: localProjectID
        )
    }

    private static func syncBatchKind(
        _ kind: DurableLocalBatchKind
    ) -> SyncV2BatchKind {
        switch kind {
        case .projectBinding: .projectBinding
        case .documentSave: .documentSave
        case .structureChange: .structureChange
        case .volumeCreation: .volumeCreation
        case .trashChange: .trashChange
        case .backupRestore: .backupRestore
        case .windowsImport: .windowsImport
        }
    }

    private func resolvedStore() async -> SyncV2Store? {
        if let store {
            return store
        }
        guard let databaseURL else {
            diagnostic = SyncV2StoreDiagnostic(
                reason: .applicationSupportUnavailable,
                sqliteCode: nil,
                schemaVersion: nil
            )
            return nil
        }
        switch await SyncV2Store.open(at: databaseURL) {
        case .available(let opened):
            store = opened
            diagnostic = nil
            return opened
        case .unavailable(let failure):
            diagnostic = failure
            return nil
        }
    }

    private static func recordFailureMessage(
        _ error: SyncV2EnqueueError
    ) -> String {
        switch error {
        case .unavailable:
            "동기화 저장소를 사용할 수 없습니다."
        case .projectNotConnected:
            "프로젝트 연결 상태가 변경되었습니다."
        case .emptyBatch, .invalidMutation:
            "저장 snapshot이 올바르지 않습니다."
        case .batchIDReused, .operationIDReused:
            "동기화 기록 식별자가 충돌했습니다."
        case .integrityFailure:
            "동기화 기록 무결성을 확인할 수 없습니다."
        case .storageFailure:
            "동기화 기록을 디스크에 저장하지 못했습니다."
        }
    }
}

/// 새 서버 작품과 Windows 가져오기는 binding 저장 직후 프로젝트 전체를
/// 하나의 durable batch로 등록해 연결 전 로컬 저장을 빠짐없이 보강한다.
actor ProjectInitialSyncRecorder: InitialProjectSyncRecording {
    static let markerName = ".writerpad-windows-import-sync-handoff.json"
    static let newProjectMarkerName =
        ".writerpad-new-project-sync-handoff.json"

    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let durableChangeRecorder: any DurableLocalChangeRecording
    private let fileManager: FileManager
    private let uuidGenerator: any UUIDGenerating
    private let hasher: any ContentHashing

    init(
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        durableChangeRecorder: any DurableLocalChangeRecording,
        fileManager: FileManager = .default,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.durableChangeRecorder = durableChangeRecorder
        self.fileManager = fileManager
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
    }

    func recordInitialSnapshot(
        projectID: ProjectID,
        projectName: String,
        batchKind: DurableLocalBatchKind
    ) async -> DurableRecordResult {
        guard batchKind == .projectBinding
                || batchKind == .windowsImport
        else {
            return .localSavedButNotQueued(
                reason: "초기 작품 동기화 종류가 올바르지 않습니다."
            )
        }
        guard await durableChangeRecorder.requirement(for: projectID)
            == .durableQueue else {
            return .localOnly
        }

        let workspaceRoot: URL
        do {
            workspaceRoot = try await workspaceLocator.workspaceRoot(
                for: projectID
            )
        } catch {
            return .localSavedButNotQueued(
                reason: "작품의 저장 위치를 확인할 수 없습니다."
            )
        }
        let markerURL = workspaceRoot.appendingPathComponent(
            batchKind == .windowsImport
                ? Self.markerName
                : Self.newProjectMarkerName
        )

        let batch: LocalMutationBatch
        do {
            if fileManager.fileExists(atPath: markerURL.path) {
                batch = try JSONDecoder().decode(
                    LocalMutationBatch.self,
                    from: Data(contentsOf: markerURL)
                )
                guard batch.projectID == projectID,
                      batch.kind == batchKind else {
                    return .localSavedButNotQueued(
                        reason: "초기 작품 동기화 복구 표식이 올바르지 않습니다."
                    )
                }
            } else {
                batch = try await makeBatch(
                    projectID: projectID,
                    projectName: projectName,
                    workspaceRoot: workspaceRoot,
                    batchKind: batchKind
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(batch).write(
                    to: markerURL,
                    options: [.atomic]
                )
            }
        } catch {
            return .localSavedButNotQueued(
                reason: "초기 작품 동기화 snapshot을 보존할 수 없습니다."
            )
        }

        let result = await durableChangeRecorder.record(batch)
        switch result {
        case .queued, .notNeeded, .serverSizeLimitExceeded:
            try? fileManager.removeItem(at: markerURL)
        case .localOnly, .localSavedButNotQueued:
            break
        }
        return result
    }

    private func makeBatch(
        projectID: ProjectID,
        projectName: String,
        workspaceRoot: URL,
        batchKind: DurableLocalBatchKind
    ) async throws -> LocalMutationBatch {
        let documents = try await documentRepository.documents(in: projectID)
        let live = documents.filter {
            if case .active = $0.deletionStatus {
                let key = $0.relativePath.rawValue
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
                let trash = BinderFixedCategory.trash.relativePath.rawValue
                    .precomposedStringWithCanonicalMapping
                    .lowercased()
                return key != trash && !key.hasPrefix(trash + "/")
            }
            return false
        }
        var mutations: [DurableLocalMutation] = [
            .ensureProject(
                operationID: uuidGenerator.makeUUID(),
                name: projectName
            ),
        ]
        for document in live
            .filter({ $0.kind == .text })
            .sorted(by: { $0.relativePath.rawValue < $1.relativePath.rawValue }) {
            let url = workspaceRoot.appendingPathComponent(
                document.relativePath.rawValue
            )
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else {
                throw LocalDocumentStoreError.invalidUTF8(url.path)
            }
            mutations.append(
                .documentSnapshot(
                    operationID: uuidGenerator.makeUUID(),
                    documentID: document.id,
                    relativePath: document.relativePath,
                    content: content,
                    contentHash: hasher.sha256(for: data),
                    localSaveGeneration: 0,
                    isDeleted: false
                )
            )
        }
        mutations.append(
            .treeOrder(
                operationID: uuidGenerator.makeUUID(),
                content: try treeOrderContent(live),
                generation: UInt64(
                    max(0, Int(Date().timeIntervalSince1970 * 1_000))
                )
            )
        )
        let batchID = uuidGenerator.makeUUID()
        return LocalMutationBatch(
            batchID: batchID,
            projectID: projectID,
            localTransactionID: batchID,
            kind: batchKind,
            mutations: mutations
        )
    }

    private func treeOrderContent(
        _ documents: [DocumentNode]
    ) throws -> String {
        let folders = documents.filter { $0.kind == .folder }
        var order: [String: [String]] = [:]
        for parent in folders {
            let children = documents
                .filter { $0.parentID == parent.id }
                .sorted {
                    if $0.userOrder != $1.userOrder {
                        return $0.userOrder < $1.userOrder
                    }
                    return $0.relativePath.rawValue < $1.relativePath.rawValue
                }
            let canonicalParentPath = SyncV2ServerPath.canonical(
                parent.relativePath.rawValue
            )
            let key = canonicalParentPath == "메인"
                ? "<root>"
                : canonicalParentPath
            order[key] = children.map {
                SyncV2ServerPath.canonical(
                    URL(fileURLWithPath: $0.relativePath.rawValue)
                        .lastPathComponent
                )
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "tree_order": order,
            ],
            options: [.sortedKeys]
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw SyncV2EnqueueError.invalidMutation
        }
        return content
    }
}

private struct MaterializedBatch {
    let batchID: UUID
    let localProjectID: UUID
    let serverProjectID: UUID
    let ownerSubject: UUID
    let localTransactionID: UUID?
    let kind: SyncV2BatchKind
    let operations: [MaterializedOperation]
    let payloadHash: String
    let timestamp: String
}

private struct MaterializedOperation {
    let operationID: UUID
    let payload: MaterializedOperationPayload

    func canonical(
        localProjectID: UUID,
        serverProjectID: UUID,
        ownerSubject: UUID
    ) -> CanonicalOperation {
        switch payload {
        case .ensureProject(let ensure):
            return CanonicalOperation(
                operationID: operationID.uuidString.lowercased(),
                localProjectID: localProjectID.uuidString.lowercased(),
                serverProjectID: serverProjectID.uuidString.lowercased(),
                ownerSubject: ownerSubject.uuidString.lowercased(),
                documentID: nil,
                deviceID: nil,
                localSaveGeneration: nil,
                kind: .ensureProject,
                projectName: ensure.projectName,
                localPath: "",
                relativePath: "",
                content: "",
                contentByteCount: 0,
                contentHash: "",
                isDeleted: false
            )
        case .document(let document):
            return CanonicalOperation(
                operationID: operationID.uuidString.lowercased(),
                localProjectID: localProjectID.uuidString.lowercased(),
                serverProjectID: serverProjectID.uuidString.lowercased(),
                ownerSubject: ownerSubject.uuidString.lowercased(),
                documentID: document.documentID.uuidString.lowercased(),
                deviceID: document.deviceID.uuidString.lowercased(),
                localSaveGeneration: document.localSaveGeneration,
                kind: document.kind,
                projectName: nil,
                localPath: document.localPath,
                relativePath: document.relativePath,
                content: document.content,
                contentByteCount: document.contentByteCount,
                contentHash: document.contentHash,
                isDeleted: document.isDeleted
            )
        case .folder(let folder):
            return CanonicalOperation(
                operationID: operationID.uuidString.lowercased(),
                localProjectID: localProjectID.uuidString.lowercased(),
                serverProjectID: serverProjectID.uuidString.lowercased(),
                ownerSubject: ownerSubject.uuidString.lowercased(),
                documentID: nil,
                deviceID: folder.deviceID.uuidString.lowercased(),
                localSaveGeneration: nil,
                kind: .folderCommit,
                projectName: nil,
                folderID: folder.folderID.uuidString.lowercased(),
                parentFolderID: folder.parentFolderID?
                    .uuidString.lowercased(),
                folderName: folder.name,
                localPath: "",
                relativePath: "",
                content: "",
                contentByteCount: 0,
                contentHash: "",
                isDeleted: folder.isDeleted
            )
        }
    }
}

private enum MaterializedOperationPayload {
    case ensureProject(MaterializedEnsureProject)
    case document(MaterializedDocument)
    case folder(MaterializedFolder)
}

private struct MaterializedEnsureProject {
    let projectName: String
}

private struct MaterializedDocument {
    let documentID: UUID
    let deviceID: UUID
    let localSaveGeneration: Int?
    let kind: SyncV2OperationKind
    let localPath: String
    let relativePath: String
    let content: String
    let contentByteCount: Int
    let contentHash: String
    let isDeleted: Bool
}

private struct MaterializedFolder {
    let folderID: UUID
    let parentFolderID: UUID?
    let deviceID: UUID
    let name: String
    let isDeleted: Bool
}

private struct CanonicalBatch: Encodable {
    let version: Int
    let batchID: String
    let localProjectID: String
    let serverProjectID: String
    let ownerSubject: String
    let localTransactionID: String?
    let kind: SyncV2BatchKind
    let operations: [CanonicalOperation]
}

private struct CanonicalOperation: Encodable {
    let operationID: String
    let localProjectID: String
    let serverProjectID: String
    let ownerSubject: String
    let documentID: String?
    let deviceID: String?
    let localSaveGeneration: Int?
    let kind: SyncV2OperationKind
    let projectName: String?
    /// 폴더 작업만 채운다. nil인 칸은 인코딩에서 빠지므로 이 칸이 생기기 전에
    /// 만들어진 문서 batch의 payload 해시는 그대로 유지된다.
    var folderID: String? = nil
    var parentFolderID: String? = nil
    var folderName: String? = nil
    let localPath: String
    let relativePath: String
    let content: String
    let contentByteCount: Int
    let contentHash: String
    let isDeleted: Bool
}

private struct ExistingBatch {
    let localProjectID: UUID
    let mutationCount: Int
    let payloadHash: String
}

private struct MissingProjectRecoveryCandidate {
    let documentID: UUID
    let kind: SyncV2OperationKind
    let localPath: String
    let serverPath: String
    let content: String
}

private struct DispatchCandidate {
    let operationID: UUID
    let batchID: UUID
    let localProjectID: ProjectID
    let projectID: UUID
    let documentID: UUID
    let deviceID: UUID
    let documentSequence: Int
    let localSaveGeneration: UInt64?
    let kind: SyncV2OperationKind
    let baseRevision: Int64
    let baseContent: String
    let baseServerPath: String
    let localPath: String
    let relativePath: String
    let content: String
    let isDeleted: Bool
    let attempts: Int
}

private struct DocumentState {
    let localProjectID: UUID
    let serverProjectID: UUID
    let serverRevision: Int
    let serverPath: String
    let baseContent: String
    let isDeleted: Bool
    let nextSequence: Int
}

private struct FolderState {
    let localProjectID: UUID
    let serverProjectID: UUID
    let serverRevision: Int
    let isDeleted: Bool
    let nextSequence: Int
}

private struct ActiveDocumentLifecycle {
    let isDeleted: Bool
    let relativePath: String
    let content: String
    let batchKind: SyncV2BatchKind
}

private struct ConflictResolutionOperation {
    let localProjectID: ProjectID
    let documentSequence: Int
    let kind: SyncV2OperationKind
    let status: SyncV2OperationStatus
    let content: String
    let isDeleted: Bool
}

private enum DocumentOperationDisposition {
    case queued
    case noOp
    case blockedBySize
}

private struct MigrationResource {
    let version: Int
    let executableSQL: String
    let checksum: String
}

/// 새 저장소는 모든 단계를, 기존 저장소는 자기 버전보다 높은 단계만 적용한다.
private struct MigrationPlan {
    /// 버전 오름차순이다.
    let steps: [MigrationResource]
    let head: MigrationResource

    func steps(after version: Int) -> [MigrationResource] {
        steps.filter { $0.version > version }
    }
}

private struct StorePreparationFailure: Error {
    let diagnostic: SyncV2StoreDiagnostic
}

private enum ResourceError: Error {
    case missing
    case invalidUTF8
    case markerMissing
}
