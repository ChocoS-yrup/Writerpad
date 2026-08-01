import Combine
import Foundation
import Supabase

struct SyncV2RemoteDocumentSnapshot: Codable, Equatable, Sendable {
    let documentID: UUID
    let relativePath: String
    let content: String
    let revision: Int64
    let isDeleted: Bool
    let deletedAt: Date?
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case relativePath = "relative_path"
        case content
        case revision
        case isDeleted = "is_deleted"
        case deletedAt = "deleted_at"
        case updatedAt = "updated_at"
    }

    init(
        documentID: UUID,
        relativePath: String,
        content: String,
        revision: Int64,
        isDeleted: Bool,
        deletedAt: Date?,
        updatedAt: Date
    ) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.content = content
        self.revision = revision
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        content = try values.decode(String.self, forKey: .content)
        revision = try values.decode(Int64.self, forKey: .revision)
        isDeleted = try values.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try Self.decodeOptionalDate(
            values,
            key: .deletedAt
        )
        updatedAt = try Self.decodeDate(values, key: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(content, forKey: .content)
        try values.encode(revision, forKey: .revision)
        try values.encode(isDeleted, forKey: .isDeleted)
        try values.encode(
            deletedAt.map(Self.encodeDate),
            forKey: .deletedAt
        )
        try values.encode(
            Self.encodeDate(updatedAt),
            forKey: .updatedAt
        )
    }

    private static func decodeOptionalDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date? {
        guard try !values.decodeNil(forKey: key) else { return nil }
        return try decodeDate(values, key: key)
    }

    private static func decodeDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date {
        let value = try values.decode(String.self, forKey: key)
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
        guard let date = seconds.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: values,
                debugDescription: "Invalid server timestamp."
            )
        }
        return date
    }

    private static func encodeDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}

enum SyncV2SnapshotTransportError: Error, Equatable, Sendable {
    case postgrest(message: String, postgresCode: String?, detail: String?)
    case url(code: URLError.Code)
    case invalidResponse
    case unknown(message: String)
}

protocol SyncV2SnapshotTransporting: Sendable {
    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot?
}

extension SyncV2SnapshotTransporting {
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        try await fetchDocuments(projectID: projectID).first {
            $0.documentID == documentID
        }
    }
}

protocol SyncV2SnapshotClienting: Sendable {
    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot]
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot?
}

extension SyncV2SnapshotClienting {
    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        try await fetchDocuments(projectID: projectID).first {
            $0.documentID == documentID
        }
    }
}

protocol SyncV2SnapshotPulling: Sendable {
    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport
}

actor LiveSyncV2SnapshotTransport: SyncV2SnapshotTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        do {
            let response: PostgrestResponse<
                [SyncV2RemoteDocumentSnapshot]
            > = try await client
                .from("documents")
                .select(
                    """
                    document_id,relative_path,content,revision,is_deleted,\
                    deleted_at,updated_at
                    """
                )
                .eq("project_id", value: projectID.uuidString.lowercased())
                .execute()
            return response.value
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        do {
            let response: PostgrestResponse<
                [SyncV2RemoteDocumentSnapshot]
            > = try await client
                .from("documents")
                .select(
                    """
                    document_id,relative_path,content,revision,is_deleted,\
                    deleted_at,updated_at
                    """
                )
                .eq("project_id", value: projectID.uuidString.lowercased())
                .eq(
                    "document_id",
                    value: documentID.uuidString.lowercased()
                )
                .limit(1)
                .execute()
            return response.value.first
        } catch let error as PostgrestError {
            throw SyncV2SnapshotTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2SnapshotTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2SnapshotTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2SnapshotTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2SnapshotTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }
}

actor SyncV2SnapshotClient: SyncV2SnapshotClienting {
    private let transport: any SyncV2SnapshotTransporting

    init(transport: any SyncV2SnapshotTransporting) {
        self.transport = transport
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        do {
            let documents = try await transport.fetchDocuments(
                projectID: projectID
            )
            var identifiers = Set<UUID>()
            for snapshot in documents {
                guard identifiers.insert(snapshot.documentID).inserted,
                      Self.isValid(snapshot)
                else {
                    throw SyncV2ClientError.invalidResponse
                }
            }
            return documents.sorted {
                $0.documentID.uuidString < $1.documentID.uuidString
            }
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2RemoteDocumentSnapshot? {
        do {
            guard let snapshot = try await transport.fetchDocument(
                projectID: projectID,
                documentID: documentID
            ) else {
                return nil
            }
            guard snapshot.documentID == documentID,
                  Self.isValid(snapshot)
            else {
                throw SyncV2ClientError.invalidResponse
            }
            return snapshot
        } catch let error as SyncV2ClientError {
            throw error
        } catch let error as SyncV2SnapshotTransportError {
            throw Self.classify(error)
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    private static func isValid(
        _ snapshot: SyncV2RemoteDocumentSnapshot
    ) -> Bool {
        guard snapshot.revision > 0,
              snapshot.content.utf8.count
                <= SyncV2Store.maximumContentByteCount,
              SyncV2Client.isValidServerPath(snapshot.relativePath)
        else { return false }
        return snapshot.isDeleted
            ? snapshot.deletedAt != nil
            : snapshot.deletedAt == nil
    }

    private static func classify(
        _ error: SyncV2SnapshotTransportError
    ) -> SyncV2ClientError {
        switch error {
        case let .postgrest(message, postgresCode, detail):
            if postgresCode == "42501" {
                return .remote(code: .forbidden, detail: detail)
            }
            if postgresCode == "PGRST301" || postgresCode == "PGRST302" {
                return .remote(code: .authRequired, detail: detail)
            }
            return .serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: postgresCode,
                    message: message,
                    detail: detail
                )
            )
        case .url(let code):
            return code == .timedOut ? .timedOut : .networkUnavailable
        case .invalidResponse:
            return .invalidResponse
        case .unknown(let message):
            return .serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: message,
                    detail: nil
                )
            )
        }
    }
}

struct SyncV2SnapshotLocalState: Equatable, Sendable {
    let serverRevision: Int64
    let serverPath: String
    let hasActiveOperation: Bool
    let hasUnresolvedConflict: Bool
    let blockingErrorCode: String?
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

struct SyncV2EditingGuard: Equatable, Sendable {
    let isOpen: Bool
    let isDirty: Bool
    let isComposing: Bool

    static let closed = SyncV2EditingGuard(
        isOpen: false,
        isDirty: false,
        isComposing: false
    )
}

enum SyncV2SnapshotMergeReason:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable {
    case pendingOperation
    case blockedOperation
    case unresolvedConflict
    case dirtyEditor
    case markedTextComposition
    case remoteDeletion
    case pathOccupiedByDifferentDocument
    case invalidLocalHierarchy
}

struct SyncV2SnapshotMergeCandidate: Codable, Equatable, Sendable {
    let localProjectID: ProjectID
    let serverProjectID: UUID
    let snapshot: SyncV2RemoteDocumentSnapshot
    let reason: SyncV2SnapshotMergeReason
}

protocol SyncV2SnapshotMergeStoring: Sendable {
    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws
}

protocol SyncV2LocalSnapshotApplying: Sendable {
    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws
    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async
    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async
}

extension SyncV2LocalSnapshotApplying {
    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {}

    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {}
}

enum SyncV2LocalSnapshotApplyError: Error, Equatable, Sendable {
    case pathOccupiedByDifferentDocument
    case invalidHierarchy
    case unsafePath
}

enum SyncV2SnapshotPullOutcome: Equatable, Sendable {
    case applied(documentID: UUID, revision: Int64, wasOpen: Bool)
    case upToDate(documentID: UUID, revision: Int64)
    case mergeRequired(
        documentID: UUID,
        revision: Int64,
        reason: SyncV2SnapshotMergeReason
    )
}

struct SyncV2SnapshotPullReport: Equatable, Sendable {
    let outcomes: [SyncV2SnapshotPullOutcome]
    let appliedSnapshots: [SyncV2RemoteDocumentSnapshot]
}

/// 로컬 자동 저장과 서버 snapshot 적용이 같은 문서의 TXT를 동시에
/// 교체하지 않도록 하는 실행 중 전용 경계다.
actor SyncV2DocumentMutationGate {
    private var lockedDocumentIDs: Set<UUID> = []
    private var waiters: [
        UUID: [CheckedContinuation<Void, Never>]
    ] = [:]

    func withCriticalSection<Value: Sendable>(
        documentID: UUID,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        await acquire(documentID)
        do {
            let value = try await operation()
            release(documentID)
            return value
        } catch {
            release(documentID)
            throw error
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
        var outcomes: [SyncV2SnapshotPullOutcome] = []
        var appliedSnapshots: [SyncV2RemoteDocumentSnapshot] = []
        outcomes.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            try Task.checkCancellation()
            let editing = editingGuards[snapshot.documentID] ?? .closed
            let processed = try await mutationGate.withCriticalSection(
                documentID: snapshot.documentID
            ) { [self] in
                try await process(
                    snapshot,
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editing: editing
                )
            }
            outcomes.append(processed.outcome)
            if let appliedSnapshot = processed.appliedSnapshot {
                appliedSnapshots.append(appliedSnapshot)
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
        editing: SyncV2EditingGuard
    ) async throws -> ProcessedSnapshot {
        try Task.checkCancellation()
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
            } else if state.hasActiveOperation {
                outcome = .mergeRequired(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision,
                    reason: .pendingOperation
                )
            } else {
                outcome = .upToDate(
                    documentID: snapshot.documentID,
                    revision: state.serverRevision
                )
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
            try await localApplier.apply(
                localProjectID: localProjectID,
                snapshot: snapshot
            )
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
        if snapshot.isDeleted {
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

enum SyncV2WorkspaceServerState: Equatable, Sendable {
    case localOnly
    case idle
    case checkingAuthentication
    case connectionChecking
    case reconnecting
    case syncing
    case synced(at: Date)
    case offlineSaved
    case waiting
    case authenticationRequired
    case automaticallyMerged
    case conflictRequired(detail: String)
    case structuralConflict(detail: String)
    case failed(detail: String)
}

enum WorkspaceSyncStatusSeverity: Equatable, Sendable {
    case neutral
    case success
    case warning
    case failure
}

struct WorkspaceSyncStatusPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let detail: String
    let severity: WorkspaceSyncStatusSeverity
    let allowsRetry: Bool
}

enum WorkspaceSyncStatusReducer {
    static func presentation(
        saveState: SaveState,
        handoffState: SyncHandoffState,
        serverState: SyncV2WorkspaceServerState,
        leaseState: EditLeaseDisplayState
    ) -> WorkspaceSyncStatusPresentation {
        let isCloudConnected = serverState != .localOnly
        if case .editing = saveState {
            return value(
                "편집 중",
                isCloudConnected ? "icloud" : "pencil",
                "변경 사항이 아직 로컬 TXT에 저장되지 않았습니다."
            )
        }
        if case .saving = saveState {
            return value(
                "로컬 저장 중",
                isCloudConnected
                    ? "icloud.and.arrow.up"
                    : "arrow.triangle.2.circlepath",
                "변경 사항을 이 iPad의 TXT 파일에 저장하고 있습니다."
            )
        }
        if case let .failed(_, message) = saveState {
            return value(
                "로컬 저장 실패",
                isCloudConnected
                    ? "exclamationmark.icloud"
                    : "exclamationmark.triangle.fill",
                message,
                severity: .failure,
                retry: true
            )
        }
        if case let .failed(_, message) = handoffState {
            return value(
                "동기화 기록 실패",
                "exclamationmark.icloud",
                message,
                severity: .failure,
                retry: true
            )
        }
        if case .heldByOther = leaseState {
            return value(
                "다른 기기 편집 중",
                "lock.fill",
                "다른 기기가 이 문서의 편집 잠금을 보유하고 있습니다. 로컬 TXT는 보존되며 잠금이 풀리면 자동으로 다시 시도합니다.",
                severity: .warning,
                retry: true
            )
        }
        if case .syncing = serverState {
            return value(
                "서버 동기화 중",
                "arrow.triangle.2.circlepath.icloud",
                "서버 snapshot을 확인하고 안전한 변경을 적용하고 있습니다."
            )
        }
        if case .checkingAuthentication = serverState {
            return value(
                "로그인 확인 중",
                "person.crop.circle.badge.clock",
                "저장된 로그인 세션을 복원하고 있습니다."
            )
        }
        if case .connectionChecking = serverState {
            return value(
                "서버 연결 확인 중",
                "network",
                "Realtime 연결과 최신 서버 snapshot을 확인하고 있습니다."
            )
        }
        if case .reconnecting = serverState {
            return value(
                "서버 재연결 중",
                "arrow.triangle.2.circlepath.icloud",
                "연결을 복구한 뒤 누락된 변경을 즉시 다시 확인합니다.",
                severity: .warning
            )
        }
        if case .offlineSaved = serverState {
            return value(
                "오프라인 저장됨",
                "icloud.slash",
                "로컬 TXT에는 저장됐습니다. 연결이 돌아오면 snapshot으로 확인합니다.",
                severity: .warning,
                retry: true
            )
        }
        if case let .synced(at) = serverState {
            let isOlderThanCurrentSave: Bool
            if case .queued = handoffState,
               case let .saved(_, savedAt, _) = saveState {
                isOlderThanCurrentSave = at < savedAt
            } else {
                isOlderThanCurrentSave = false
            }
            if !isOlderThanCurrentSave {
                return value(
                    "서버 동기화됨",
                    "checkmark.icloud",
                    "마지막 확인: \(at.formatted(date: .omitted, time: .shortened))",
                    severity: .success
                )
            }
        }
        if case let .conflictRequired(detail) = serverState {
            return value(
                "충돌 해결 필요",
                "exclamationmark.arrow.triangle.2.circlepath",
                detail,
                severity: .failure,
                retry: true
            )
        }
        if case let .structuralConflict(detail) = serverState {
            return value(
                "제목·경로 확인 필요",
                "exclamationmark.triangle.fill",
                detail,
                severity: .failure,
                retry: true
            )
        }
        if case .queued = handoffState {
            return value(
                "동기화 대기",
                "icloud.and.arrow.up",
                "로컬 저장은 끝났고 서버 전송 순서를 기다리고 있습니다."
            )
        }
        if case .waiting = serverState {
            return value(
                "동기화 대기",
                "clock.arrow.circlepath",
                "편집 또는 조합 중인 문서는 덮어쓰지 않고 다음 snapshot 확인을 기다립니다.",
                severity: .warning,
                retry: true
            )
        }
        if case .authenticationRequired = serverState {
            return value(
                "인증 필요",
                "person.crop.circle.badge.exclamationmark",
                "서버 동기화를 계속하려면 설정에서 다시 로그인하세요.",
                severity: .warning
            )
        }
        if case let .serverSizeLimitExceeded(_, bytes, limit) = handoffState {
            return value(
                "서버 크기 제한 초과",
                "exclamationmark.icloud",
                "\(bytes.formatted())바이트 문서가 서버 제한 \(limit.formatted())바이트를 초과했습니다.",
                severity: .failure
            )
        }
        if case .automaticallyMerged = serverState {
            return value(
                "자동 병합됨",
                "arrow.triangle.merge",
                "서로 겹치지 않는 변경을 자동으로 합쳤습니다.",
                severity: .success
            )
        }
        if case let .failed(detail) = serverState {
            return value(
                "동기화 실패",
                "icloud.slash",
                detail,
                severity: .failure,
                retry: true
            )
        }
        if case .saved = saveState {
            return value(
                isCloudConnected ? "클라우드 전송 준비" : "로컬 저장됨",
                isCloudConnected
                    ? "icloud.and.arrow.up"
                    : "checkmark.circle",
                isCloudConnected
                    ? "로컬 TXT 저장을 마쳤고 서버 전송을 준비하고 있습니다."
                    : "이 iPad의 TXT 파일에 안전하게 저장됐습니다.",
                severity: isCloudConnected ? .neutral : .success
            )
        }
        return value(
            isCloudConnected ? "클라우드 저장 준비" : "로컬 저장 준비",
            isCloudConnected ? "icloud" : "externaldrive",
            isCloudConnected
                ? "문서를 편집하면 로컬 저장 후 서버로 전송합니다."
                : "문서를 편집하면 먼저 이 iPad에 저장합니다."
        )
    }

    private static func value(
        _ label: String,
        _ systemImage: String,
        _ detail: String,
        severity: WorkspaceSyncStatusSeverity = .neutral,
        retry: Bool = false
    ) -> WorkspaceSyncStatusPresentation {
        WorkspaceSyncStatusPresentation(
            label: label,
            systemImage: systemImage,
            detail: detail,
            severity: severity,
            allowsRetry: retry
        )
    }
}

protocol SyncV2RealtimeTriggering: Sendable {
    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws
    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws
    func stop() async
}

actor SyncV2RealtimeConnectGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withSubscription(
        timeout: Duration = .seconds(20),
        timeoutSleep: @escaping @Sendable (Duration) async throws -> Void = {
            duration in
            try await ContinuousClock().sleep(for: duration)
        },
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        await acquire()
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
        let race = SyncV2RealtimeStartRace()
        let operationTask = Task {
            do {
                try await operation()
                await race.resolve(.completed)
            } catch {
                await race.resolve(.failed)
                throw error
            }
        }
        let timeoutTask = Task {
            do {
                try await timeoutSleep(timeout)
                await race.resolve(.timedOut)
            } catch {
                // 구독 완료 또는 상위 stop이 먼저 끝났다.
            }
        }
        let outcome = await race.value()
        operationTask.cancel()
        timeoutTask.cancel()
        release()
        switch outcome {
        case .completed, .failed:
            try await operationTask.value
        case .timedOut:
            throw SyncV2RealtimeTriggerError.subscriptionTimedOut
        }
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

enum SyncV2RealtimeConnectionStatus: Equatable, Sendable {
    case subscribing
    case subscribed
    case closed
    case channelError
    case timedOut
}

enum SyncV2RealtimeTriggerError: Error {
    case globalSubscriptionUnsupported
    case subscriptionTimedOut
}

extension SyncV2RealtimeTriggering {
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        _ = (onChange, onSubscribed)
        throw SyncV2RealtimeTriggerError.globalSubscriptionUnsupported
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await start(
            projectID: projectID,
            onChange: onChange,
            onSubscribed: { onStatus(.subscribed) }
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startAll(
            onChange: onChange,
            onSubscribed: { onStatus(.subscribed) }
        )
    }
}

struct SyncV2RealtimeSubscriptionGate {
    private(set) var hasSubscribed = false

    mutating func receiveSubscribed() -> Bool {
        guard hasSubscribed else {
            hasSubscribed = true
            return false
        }
        return true
    }
}

actor LiveSyncV2RealtimeTrigger: SyncV2RealtimeTriggering {
    private let client: SupabaseClient
    private let subscriptionGate: SyncV2RealtimeConnectGate
    private var channel: RealtimeChannelV2?
    private var changeSubscription: RealtimeSubscription?
    private var statusSubscription: RealtimeSubscription?
    private var channelGeneration: UUID?
    private var hasObservedSubscribing = false
    private var hasSubscribed = false

    init(
        client: SupabaseClient,
        subscriptionGate: SyncV2RealtimeConnectGate =
            SyncV2RealtimeConnectGate()
    ) {
        self.client = client
        self.subscriptionGate = subscriptionGate
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await start(
            projectID: projectID,
            onChange: onChange,
            onStatus: { status in
                if status == .subscribed {
                    onSubscribed()
                }
            }
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await startAll(
            onChange: onChange,
            onStatus: { status in
                if status == .subscribed {
                    onSubscribed()
                }
            }
        )
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startChannel(
            projectID: projectID,
            onChange: onChange,
            onStatus: onStatus
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startChannel(
            projectID: nil,
            onChange: onChange,
            onStatus: onStatus
        )
    }

    private func startChannel(
        projectID: UUID?,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        await stop()
        let generation = UUID()
        channelGeneration = generation
        hasObservedSubscribing = false
        hasSubscribed = false
        let channel = client.channel(
            projectID.map {
                "writerpad-documents-\($0.uuidString.lowercased())"
            } ?? "writerpad-documents-all"
        )
        if let projectID {
            changeSubscription = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "documents",
                filter:
                    "project_id=eq.\(projectID.uuidString.lowercased())"
            ) { _ in
                Task {
                    await self.receivedChange(
                        generation: generation,
                        callback: onChange
                    )
                }
            }
        } else {
            changeSubscription = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "documents"
            ) { _ in
                Task {
                    await self.receivedChange(
                        generation: generation,
                        callback: onChange
                    )
                }
            }
        }
        statusSubscription = channel.onStatusChange {
            [weak self] status in
            Task {
                await self?.receivedStatus(
                    status,
                    generation: generation,
                    callback: onStatus
                )
            }
        }
        self.channel = channel
        do {
            // 같은 SupabaseClient를 쓰는 전체-작품 채널과 현재-작품 채널이
            // 동시에 최초 connect/subscribe에 진입하면 SDK 2.46.0에서 한
            // phx_join이 영구 대기할 수 있다. 공유 gate로 socket 구독을
            // 직렬화하고, 완료된 채널은 즉시 다음 채널에 차례를 넘긴다.
            try await subscriptionGate.withSubscription {
                try await channel.subscribeWithError()
            }
            // subscribeWithError의 정상 반환은 채널 구독이 완료됐다는
            // authoritative 신호다. 일부 장시간 실행·재연결 경로에서는
            // onStatusChange(.subscribed)가 replay되지 않을 수 있으므로,
            // callback 누락 여부와 무관하게 정확히 한 번 확정한다.
            receivedStatus(
                .subscribed,
                generation: generation,
                callback: onStatus
            )
        } catch {
            guard channelGeneration == generation else { throw error }
            let status: SyncV2RealtimeConnectionStatus
            switch error {
            case SyncV2RealtimeTriggerError.subscriptionTimedOut:
                status = .timedOut
            default:
                let detail = error.localizedDescription.lowercased()
                status = detail.contains("timeout")
                    || detail.contains("retry")
                    ? .timedOut
                    : .channelError
            }
            onStatus(status)
            throw error
        }
    }

    func stop() async {
        changeSubscription?.cancel()
        statusSubscription?.cancel()
        changeSubscription = nil
        statusSubscription = nil
        if let channel {
            // Supabase 2.46.0의 removeChannel은 이미 subscribed인 채널만
            // unsubscribe한다. subscribing 중 remove하면 내부 phx_join Task가
            // 고아로 남아 같은 topic의 다음 채널 응답을 가로막을 수 있으므로,
            // 상태와 관계없이 먼저 state machine을 unsubscribed까지 보낸다.
            await channel.unsubscribe()
            await client.removeChannel(channel)
        }
        channel = nil
        channelGeneration = nil
        hasObservedSubscribing = false
        hasSubscribed = false
    }

    private func receivedChange(
        generation: UUID,
        callback: @escaping @Sendable () -> Void
    ) {
        guard channelGeneration == generation else { return }
        callback()
    }

    private func receivedStatus(
        _ status: RealtimeChannelStatus,
        generation: UUID,
        callback: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) {
        guard channelGeneration == generation else { return }
        switch status {
        case .subscribing:
            // actor가 status callback Task를 처리하기 전에 채널이 이미
            // subscribed로 진행했다면 오래된 subscribing으로 회귀하지 않는다.
            guard !hasSubscribed,
                  let currentStatus = channel?.status,
                  Self.sameStatus(status, currentStatus)
            else { return }
            hasObservedSubscribing = true
            callback(.subscribing)
        case .subscribed:
            // subscribed는 callback 시점의 channel.status 비교로 버리지 않는다.
            // subscribeWithError 정상 반환도 같은 경로를 사용하므로 generation당
            // 한 번만 상위 수명주기 모델에 전달된다.
            guard !hasSubscribed else { return }
            hasSubscribed = true
            callback(.subscribed)
        case .unsubscribed:
            // onStatusChange는 등록 직후 초기 unsubscribed를 replay한다.
            // 실제 subscribe가 시작되기 전의 값은 종료 신호가 아니다.
            guard hasObservedSubscribing || hasSubscribed,
                  let currentStatus = channel?.status,
                  Self.sameStatus(status, currentStatus)
            else { return }
            callback(.closed)
        case .unsubscribing:
            break
        }
    }

    private static func sameStatus(
        _ lhs: RealtimeChannelStatus,
        _ rhs: RealtimeChannelStatus
    ) -> Bool {
        switch (lhs, rhs) {
        case (.unsubscribed, .unsubscribed),
             (.subscribing, .subscribing),
             (.subscribed, .subscribed),
             (.unsubscribing, .unsubscribing):
            true
        default:
            false
        }
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
    private let sleep: SyncV2WorkspaceSleep
    private let realtimeTimeoutSleep: SyncV2WorkspaceSleep
    private let pullTimeoutSleep: SyncV2WorkspaceSleep

    private var isStarted = false
    private var activeLocalProjectID: ProjectID?
    private var pullTasks: [ProjectID: Task<Void, Never>] = [:]
    private var pullGenerations: [ProjectID: UInt64] = [:]
    private var pendingProjects = Set<ProjectID>()
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
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
        debounceDelay: Duration = .milliseconds(450),
        periodicDelay: Duration = .seconds(90),
        realtimeSubscriptionTimeout: Duration = .seconds(12),
        pullTimeout: Duration = .seconds(15),
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
        debounceTask?.cancel()
        logTask("periodicTask", action: "cancel", reason: "stop")
        periodicTask?.cancel()
        realtimeTask?.cancel()
        logTask("reconnectTask", action: "cancel", reason: "stop")
        reconnectTask?.cancel()
        pullTasks.values.forEach { $0.cancel() }
        logTask("debounceTask", action: "clear", reason: "stop")
        debounceTask = nil
        logTask("periodicTask", action: "clear", reason: "stop")
        periodicTask = nil
        realtimeTask = nil
        logTask("reconnectTask", action: "clear", reason: "stop")
        reconnectTask = nil
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
        if realtimeTask == nil, reconnectTask == nil {
            startRealtime()
        }
        await pullInactiveProjects()
    }

    private func startRealtime() {
        guard isStarted else { return }
        realtimeTask?.cancel()
        realtimeGeneration &+= 1
        SyncV2Diagnostics.generation(
            scope: "background",
            counter: "realtimeGeneration",
            value: realtimeGeneration,
            reason: "startRealtime"
        )
        let generation = realtimeGeneration
        realtimeTask = Task { [weak self] in
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
                    await race.resolve(.timedOut)
                } catch {
                    // 정상 구독 또는 coordinator 종료가 먼저 끝났다.
                }
            }
            let outcome = await race.value()
            operation.cancel()
            watchdog.cancel()
            await self.realtimeStartFinished(
                outcome,
                generation: generation
            )
        }
    }

    private func realtimeStartFinished(
        _ outcome: SyncV2RealtimeStartOutcome,
        generation: UInt64
    ) async {
        guard isStarted,
              realtimeGeneration == generation
        else { return }
        switch outcome {
        case .completed:
            // 완료된 Task 참조는 foreground 중복 start를 막는 생존 표식이다.
            break
        case .failed:
            realtimeTask = nil
            await receivedRealtimeStatus(
                .channelError,
                generation: generation
            )
        case .timedOut:
            realtimeTask = nil
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
            reconnectTask?.cancel()
            logTask(
                "reconnectTask",
                action: "clear",
                reason: "realtime-subscribed"
            )
            reconnectTask = nil
            // 재구독 직후에는 debounce 없이 누락 구간을 바로 확인한다.
            await pullInactiveProjects()
        case .closed, .channelError, .timedOut:
            scheduleRealtimeReconnect()
        case .subscribing:
            break
        }
    }

    private func scheduleRealtimeReconnect() {
        guard reconnectTask == nil, isStarted else { return }
        let delays: [Duration] = [
            .seconds(1), .seconds(2), .seconds(5),
            .seconds(10), .seconds(30),
        ]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        logTask(
            "reconnectTask",
            action: "create",
            reason: "scheduleRealtimeReconnect"
        )
        reconnectTask = Task { [weak self] in
            await self?.performRealtimeReconnect(after: delay)
        }
    }

    private func performRealtimeReconnect(after delay: Duration) async {
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
        reconnectTask = nil
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
        debounceTask?.cancel()
        let delay = debounceDelay
        let sleep = self.sleep
        logTask(
            "debounceTask",
            action: "create",
            reason: "realtimeChanged"
        )
        debounceTask = Task { [weak self] in
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
        periodicTask?.cancel()
        let delay = periodicDelay
        let sleep = self.sleep
        logTask(
            "periodicTask",
            action: "create",
            reason: "startPeriodicPull"
        )
        periodicTask = Task { [weak self] in
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
                    await race.resolve(.timedOut)
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

typealias SyncV2WorkspaceSleep =
    @Sendable (Duration) async throws -> Void
typealias SyncV2WorkspaceDispatchRetry =
    @Sendable () async -> Void

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

private actor SyncV2RealtimeStartRace {
    private var outcome: SyncV2RealtimeStartOutcome?
    private var waiters: [
        CheckedContinuation<SyncV2RealtimeStartOutcome, Never>
    ] = []

    func resolve(_ outcome: SyncV2RealtimeStartOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        if case .timedOut = outcome {
            SyncV2Diagnostics.raceTimedOut("SyncV2RealtimeStartRace")
        }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func value() async -> SyncV2RealtimeStartOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor SyncV2WorkspacePullRace {
    private var outcome: SyncV2WorkspacePullOutcome?
    private var waiters: [
        CheckedContinuation<SyncV2WorkspacePullOutcome, Never>
    ] = []

    func resolve(_ outcome: SyncV2WorkspacePullOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        if case .timedOut = outcome {
            SyncV2Diagnostics.raceTimedOut("SyncV2WorkspacePullRace")
        }
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func value() async -> SyncV2WorkspacePullOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
final class SyncV2WorkspaceSyncModel: ObservableObject {
    @Published private(set) var serverState:
        SyncV2WorkspaceServerState = .idle {
            didSet {
                guard oldValue != serverState else { return }
                SyncV2Diagnostics.serverState(
                    localProjectID: localProjectID,
                    from: oldValue,
                    to: serverState
                )
            }
        }

    private let localProjectID: ProjectID
    private let puller: (any SyncV2SnapshotPulling)?
    private let realtime: (any SyncV2RealtimeTriggering)?
    private let authenticationService: any AuthenticationServicing
    private let projectBindingService: any ProjectBindingServicing
    private let requestDispatchRetry: SyncV2WorkspaceDispatchRetry?
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
    private let recoverySleep: SyncV2WorkspaceSleep
    private let networkMonitor: SyncV2NetworkRecoveryMonitor
    private var editingGuards:
        (@MainActor @Sendable () -> [UUID: SyncV2EditingGuard])?
    private var applyOpenSnapshot:
        (@MainActor @Sendable (SyncV2RemoteDocumentSnapshot) -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var realtimeStartTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pullRetryTask: Task<Void, Never>?
    private var authenticationCheckTask: Task<Void, Never>?
    private var authenticationUpdateTask: Task<Void, Never>?
    private var bindingUpdateTask: Task<Void, Never>?
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
        debounceDelay: Duration = .milliseconds(450),
        // Realtime 누락에 대비한 저빈도 안전망이다. 실제 재연결 복구는
        // reachability 이벤트가 즉시 시작하므로 이 주기를 기다리지 않는다.
        periodicDelay: Duration = .seconds(90),
        authenticationTimeout: Duration = .seconds(12),
        authenticationRetryDelay: Duration = .seconds(3),
        realtimeSubscriptionTimeout: Duration = .seconds(12),
        pullTimeout: Duration = .seconds(15),
        retryDelays: [Duration] = [
            .seconds(1), .seconds(2), .seconds(5),
            .seconds(10), .seconds(30),
        ],
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
        self.recoverySleep = recoverySleep
        self.networkMonitor = networkMonitor
        self.sleep = sleep
    }

    func start(
        editingGuards:
            @escaping @MainActor @Sendable
            () -> [UUID: SyncV2EditingGuard],
        applyOpenSnapshot:
            @escaping @MainActor @Sendable
            (SyncV2RemoteDocumentSnapshot) -> Void
    ) async {
        self.editingGuards = editingGuards
        self.applyOpenSnapshot = applyOpenSnapshot
        await updateSceneActivity(true)
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
            debounceTask?.cancel()
            logTask("periodicTask", action: "cancel", reason: "scene-inactive")
            periodicTask?.cancel()
            logTask("pullTask", action: "cancel", reason: "scene-inactive")
            pullTask?.cancel()
            logTask("realtimeStartTask", action: "cancel", reason: "scene-inactive")
            realtimeStartTask?.cancel()
            logTask("reconnectTask", action: "cancel", reason: "scene-inactive")
            reconnectTask?.cancel()
            logTask("pullRetryTask", action: "cancel", reason: "scene-inactive")
            pullRetryTask?.cancel()
            cancelAuthenticationCheck()
            authenticationUpdateTask?.cancel()
            bindingUpdateTask?.cancel()
            logTask("debounceTask", action: "clear", reason: "scene-inactive")
            debounceTask = nil
            logTask("periodicTask", action: "clear", reason: "scene-inactive")
            periodicTask = nil
            logTask("pullTask", action: "clear", reason: "scene-inactive")
            pullTask = nil
            logTask("realtimeStartTask", action: "clear", reason: "scene-inactive")
            realtimeStartTask = nil
            logTask("reconnectTask", action: "clear", reason: "scene-inactive")
            reconnectTask = nil
            logTask("pullRetryTask", action: "clear", reason: "scene-inactive")
            pullRetryTask = nil
            authenticationUpdateTask = nil
            bindingUpdateTask = nil
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
        debounceTask?.cancel()
        logTask("periodicTask", action: "cancel", reason: "stop")
        periodicTask?.cancel()
        logTask("pullTask", action: "cancel", reason: "stop")
        pullTask?.cancel()
        logTask("realtimeStartTask", action: "cancel", reason: "stop")
        realtimeStartTask?.cancel()
        logTask("reconnectTask", action: "cancel", reason: "stop")
        reconnectTask?.cancel()
        logTask("pullRetryTask", action: "cancel", reason: "stop")
        pullRetryTask?.cancel()
        cancelAuthenticationCheck()
        authenticationUpdateTask?.cancel()
        bindingUpdateTask?.cancel()
        logTask("debounceTask", action: "clear", reason: "stop")
        debounceTask = nil
        logTask("periodicTask", action: "clear", reason: "stop")
        periodicTask = nil
        logTask("pullTask", action: "clear", reason: "stop")
        pullTask = nil
        logTask("realtimeStartTask", action: "clear", reason: "stop")
        realtimeStartTask = nil
        logTask("reconnectTask", action: "clear", reason: "stop")
        reconnectTask = nil
        logTask("pullRetryTask", action: "clear", reason: "stop")
        pullRetryTask = nil
        authenticationUpdateTask = nil
        bindingUpdateTask = nil
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
        if authenticationCheckTask == nil {
            scheduleAuthenticationCheck()
        }
        logTask("reconnectTask", action: "cancel", reason: "networkRecovered")
        reconnectTask?.cancel()
        logTask("reconnectTask", action: "clear", reason: "networkRecovered")
        reconnectTask = nil
        if realtime != nil, serverProjectID != nil {
            realtimeHealthy = false
            serverState = .reconnecting
            await realtime?.stop()
            startRealtime(reconnecting: true)
        }
        await pullNow(forceVisibleProgress: true)
    }

    private func activate() async {
        guard GlobalSyncPreference.isEnabled(),
              puller != nil else {
            serverState = .localOnly
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
                serverState = .checkingAuthentication
            }
            scheduleAuthenticationCheck()
            return
        case .unavailable(.networkUnavailable):
            serverState = .offlineSaved
            return
        case .signedOut, .unavailable:
            serverState = .authenticationRequired
            return
        }
        guard let binding = await projectBindingService.currentBinding(
            for: localProjectID
        ), let serverProjectID = binding.serverProjectID else {
            serverState = .localOnly
            return
        }
        guard isActive else { return }
        self.serverProjectID = serverProjectID
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
                serverState = .checkingAuthentication
            }
            scheduleAuthenticationCheck()
        case .localOnly:
            await suspendCloudActivityForAuthentication(.localOnly)
        case .signedOut:
            await suspendCloudActivityForAuthentication(
                .authenticationRequired
            )
        case .unavailable(.networkUnavailable):
            await suspendCloudActivityForAuthentication(.offlineSaved)
        case .unavailable:
            await suspendCloudActivityForAuthentication(
                .authenticationRequired
            )
        }
    }

    private func suspendCloudActivityForAuthentication(
        _ state: SyncV2WorkspaceServerState
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
        debounceTask?.cancel()
        logTask(
            "periodicTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        periodicTask?.cancel()
        logTask(
            "pullTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        pullTask?.cancel()
        logTask(
            "realtimeStartTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        realtimeStartTask?.cancel()
        logTask(
            "reconnectTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        reconnectTask?.cancel()
        logTask(
            "pullRetryTask",
            action: "cancel",
            reason: "authentication-state-change"
        )
        pullRetryTask?.cancel()
        cancelAuthenticationCheck()
        logTask(
            "debounceTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        debounceTask = nil
        logTask(
            "periodicTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        periodicTask = nil
        logTask(
            "pullTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        pullTask = nil
        logTask(
            "realtimeStartTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        realtimeStartTask = nil
        logTask(
            "reconnectTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        reconnectTask = nil
        logTask(
            "pullRetryTask",
            action: "clear",
            reason: "authentication-state-change"
        )
        pullRetryTask = nil
        pullPending = false
        realtimeHealthy = false
        serverState = state
        await realtime?.stop()
    }

    private func scheduleAuthenticationCheck() {
        guard authenticationCheckTask == nil, isActive else { return }
        let clock = ContinuousClock()
        let deadline =
            authenticationCheckDeadline
            ?? clock.now.advanced(by: authenticationTimeout)
        authenticationCheckDeadline = deadline
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            authenticationCheckDeadline = nil
            authenticationCheckHasTimedOut = true
            serverState = .offlineSaved
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
        authenticationCheckTask = Task { [weak self] in
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
                self.authenticationCheckTask = nil
                self.authenticationCheckDeadline = nil
                await self.activate()
            case .unavailable(.networkUnavailable):
                self.authenticationCheckHasTimedOut = true
                self.serverState = .offlineSaved
                self.authenticationCheckTask = nil
                self.authenticationCheckDeadline = nil
                self.scheduleAuthenticationRetry()
            case .restoring:
                // 다른 복원 요청에 밀린 호출은 `.restoring`을 돌려줄 수 있다.
                // 즉시 재귀하면 응답이 계속 restoring일 때 busy loop가 되므로
                // 짧게 양보한 뒤, 이 scene의 최신 요청일 때만 다시 확인한다.
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
                guard self.isActive,
                      self.authenticationCheckGeneration == requestGeneration
                else { return }
                self.authenticationCheckTask = nil
                self.scheduleAuthenticationCheck()
            case .localOnly:
                self.authenticationCheckTask = nil
                self.authenticationCheckDeadline = nil
                self.authenticationCheckHasTimedOut = false
                self.serverState = .localOnly
            case .signedOut, .unavailable:
                self.authenticationCheckTask = nil
                self.authenticationCheckDeadline = nil
                self.authenticationCheckHasTimedOut = false
                self.serverState = .authenticationRequired
            }
        }
    }

    private func scheduleAuthenticationRetry() {
        guard authenticationCheckTask == nil, isActive else { return }
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
        authenticationCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.isActive,
                  self.authenticationCheckGeneration == requestGeneration
            else { return }
            self.authenticationCheckTask = nil
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
        authenticationCheckTask?.cancel()
        authenticationCheckTask = nil
        authenticationCheckDeadline = nil
    }

    private func startBindingObservation() {
        guard bindingUpdateTask == nil else { return }
        let service = projectBindingService
        let localProjectID = self.localProjectID
        bindingUpdateTask = Task { [weak self] in
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
            debounceTask?.cancel()
            logTask("periodicTask", action: "cancel", reason: "bindingRemoved")
            periodicTask?.cancel()
            logTask("pullTask", action: "cancel", reason: "bindingRemoved")
            pullTask?.cancel()
            logTask("realtimeStartTask", action: "cancel", reason: "bindingRemoved")
            realtimeStartTask?.cancel()
            logTask("reconnectTask", action: "cancel", reason: "bindingRemoved")
            reconnectTask?.cancel()
            logTask("pullRetryTask", action: "cancel", reason: "bindingRemoved")
            pullRetryTask?.cancel()
            logTask("debounceTask", action: "clear", reason: "bindingRemoved")
            debounceTask = nil
            logTask("periodicTask", action: "clear", reason: "bindingRemoved")
            periodicTask = nil
            logTask("realtimeStartTask", action: "clear", reason: "bindingRemoved")
            realtimeStartTask = nil
            logTask("reconnectTask", action: "clear", reason: "bindingRemoved")
            reconnectTask = nil
            logTask("pullRetryTask", action: "clear", reason: "bindingRemoved")
            pullRetryTask = nil
            realtimeGeneration &+= 1
            SyncV2Diagnostics.generation(
                scope: "workspace",
                localProjectID: localProjectID,
                counter: "realtimeGeneration",
                value: realtimeGeneration,
                reason: "bindingRemoved"
            )
            await realtime?.stop()
            serverState = .localOnly
            return
        }
        guard self.serverProjectID != serverProjectID else { return }
        self.serverProjectID = nil
        logTask("pullTask", action: "cancel", reason: "bindingChanged")
        pullTask?.cancel()
        logTask("realtimeStartTask", action: "cancel", reason: "bindingChanged")
        realtimeStartTask?.cancel()
        logTask("reconnectTask", action: "cancel", reason: "bindingChanged")
        reconnectTask?.cancel()
        logTask("pullRetryTask", action: "cancel", reason: "bindingChanged")
        pullRetryTask?.cancel()
        logTask("realtimeStartTask", action: "clear", reason: "bindingChanged")
        realtimeStartTask = nil
        logTask("reconnectTask", action: "clear", reason: "bindingChanged")
        reconnectTask = nil
        logTask("pullRetryTask", action: "clear", reason: "bindingChanged")
        pullRetryTask = nil
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
        realtimeStartTask?.cancel()
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
        serverState = reconnecting
            ? .reconnecting
            : .connectionChecking
        logTask(
            "realtimeStartTask",
            action: "create",
            reason: reconnecting
                ? "startRealtime-reconnect"
                : "startRealtime-initial"
        )
        realtimeStartTask = Task { [weak self] in
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
                    await race.resolve(.timedOut)
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
            realtimeStartTask = nil
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
            if !preservesHigherPriorityServerState {
                serverState = realtimeProgressState
            }
        case .subscribed:
            realtimeHealthy = true
            hasRealtimeSubscribed = true
            lastSubscribedAt = ContinuousClock().now
            logTask(
                "reconnectTask",
                action: "cancel",
                reason: "realtime-subscribed"
            )
            reconnectTask?.cancel()
            logTask(
                "reconnectTask",
                action: "clear",
                reason: "realtime-subscribed"
            )
            reconnectTask = nil
            if !preservesHigherPriorityServerState {
                serverState = .connectionChecking
            }
            Task { @MainActor [weak self] in
                // 재구독 직후 이벤트를 기다리지 않고 누락 snapshot을 확인한다.
                await self?.pullNow(forceVisibleProgress: true)
            }
        case .closed, .channelError, .timedOut:
            let now = ContinuousClock().now
            if let lastSubscribedAt,
               lastSubscribedAt.duration(to: now) >= .seconds(30)
            {
                reconnectAttempt = 0
            }
            lastSubscribedAt = nil
            realtimeHealthy = false
            if !preservesHigherPriorityServerState {
                serverState = .reconnecting
            }
            scheduleRealtimeReconnect()
        }
    }

    private var preservesHigherPriorityServerState: Bool {
        switch serverState {
        case .conflictRequired, .structuralConflict, .automaticallyMerged,
             .waiting:
            true
        default:
            false
        }
    }

    private var realtimeProgressState: SyncV2WorkspaceServerState {
        // 최초 연결만 "확인 중"이다. 한 번도 subscribed 되지 못했더라도
        // terminal 상태 뒤 backoff 재시도를 시작했다면 실제 수명주기 상태는
        // "재연결 중"이며, 뒤늦은 subscribing callback이 이를 되돌리면 안 된다.
        hasRealtimeSubscribed || reconnectAttempt > 0
            ? .reconnecting
            : .connectionChecking
    }

    private func scheduleRealtimeReconnect() {
        guard reconnectTask == nil,
              isActive,
              realtime != nil,
              serverProjectID != nil
        else { return }
        let index = min(
            reconnectAttempt,
            max(0, retryDelays.count - 1)
        )
        let delay = retryDelays.isEmpty
            ? Duration.seconds(30)
            : retryDelays[index]
        reconnectAttempt += 1
        let sleep = recoverySleep
        logTask(
            "reconnectTask",
            action: "create",
            reason: "scheduleRealtimeReconnect"
        )
        reconnectTask = Task { [weak self] in
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
            self.reconnectTask = nil
            guard didSleep, self.isActive else { return }
            _ = await self.authenticationService.refreshSession(force: false)
            await self.realtime?.stop()
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
        debounceTask?.cancel()
        let delay = debounceDelay
        let sleep = sleep
        logTask(
            "debounceTask",
            action: "create",
            reason: "scheduleDebouncedPull"
        )
        debounceTask = Task { [weak self] in
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
        periodicTask?.cancel()
        let delay = periodicDelay
        let sleep = sleep
        logTask(
            "periodicTask",
            action: "create",
            reason: "startPeriodicPull"
        )
        periodicTask = Task { [weak self] in
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
        if pullTask != nil {
            pullPending = true
            return
        }
        logTask(
            "pullRetryTask",
            action: "cancel",
            reason: "pullNow-start"
        )
        pullRetryTask?.cancel()
        logTask(
            "pullRetryTask",
            action: "clear",
            reason: "pullNow-start"
        )
        pullRetryTask = nil
        let now = ContinuousClock().now
        let isQuietFollowUp =
            !forceVisibleProgress
            && quietProgressUntil.map { now < $0 } == true
            && {
                if case .synced = serverState { return true }
                return false
            }()
        if !isQuietFollowUp {
            serverState = .syncing
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
        pullTask = Task { [weak self] in
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
                generation: generation
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
                await race.resolve(.timedOut)
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
        generation requestGeneration: UInt64
    ) async {
        guard pullRequestID == requestID else { return }
        logTask(
            "pullTask",
            action: "clear",
            reason: "finishPull"
        )
        pullTask = nil
        guard generation == requestGeneration, isActive else {
            pullPending = false
            if case .syncing = serverState {
                serverState = .idle
            }
            return
        }
        switch outcome {
        case .success(let report):
            pullRetryAttempt = 0
            complete(report)
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
        guard pullRetryTask == nil, isActive else { return }
        let index = min(
            pullRetryAttempt,
            max(0, retryDelays.count - 1)
        )
        let delay = retryDelays.isEmpty
            ? Duration.seconds(30)
            : retryDelays[index]
        pullRetryAttempt += 1
        let sleep = recoverySleep
        logTask(
            "pullRetryTask",
            action: "create",
            reason: "schedulePullRetry"
        )
        pullRetryTask = Task { [weak self] in
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
            self.pullRetryTask = nil
            guard didSleep, self.isActive else { return }
            await self.pullNow()
        }
    }

    private func complete(_ report: SyncV2SnapshotPullReport) {
        report.appliedSnapshots.forEach {
            applyOpenSnapshot?($0)
        }
        let mergeOutcomes = report.outcomes.compactMap {
            if case let .mergeRequired(_, _, reason) = $0 {
                return reason
            }
            return nil
        }
        if mergeOutcomes.contains(.unresolvedConflict) {
            serverState = .conflictRequired(
                detail: "본문 변경이 겹쳐 원본과 병합 후보를 보존했습니다."
            )
        } else if mergeOutcomes.contains(.blockedOperation) {
            serverState = .failed(
                detail: "서버가 저장 작업을 거부했습니다. 로그인 계정과 작품 접근 권한을 확인한 뒤 다시 시도하세요. 로컬 TXT는 보존되어 있습니다."
            )
        } else if mergeOutcomes.contains(
            .pathOccupiedByDifferentDocument
        ) {
            serverState = .structuralConflict(
                detail: "서버 문서의 새 제목과 같은 경로를 다른 로컬 문서가 사용 중입니다. 로컬 TXT는 덮어쓰지 않았습니다."
            )
        } else if mergeOutcomes.contains(.invalidLocalHierarchy) {
            serverState = .structuralConflict(
                detail: "서버 문서의 제목 또는 폴더 위치를 현재 로컬 바인더에 안전하게 적용할 수 없습니다. 로컬 TXT는 덮어쓰지 않았습니다."
            )
        } else if !mergeOutcomes.isEmpty {
            serverState = .waiting
        } else {
            serverState = .synced(at: Date())
        }
        quietProgressUntil = ContinuousClock().now.advanced(
            by: .seconds(3)
        )
    }

    private func complete(_ error: SyncV2ClientError) {
        switch error {
        case .networkUnavailable, .timedOut:
            serverState = .offlineSaved
        case .remote(code: .authRequired, detail: _):
            serverState = .authenticationRequired
        default:
            serverState = .failed(detail: Self.detail(for: error))
        }
    }

    private func completeFailure(_ detail: String) {
        serverState = .failed(detail: detail)
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

actor LocalSyncV2SnapshotMergeStore: SyncV2SnapshotMergeStoring {
    static let prefix = ".writerpad-sync-merge-"
    static let suffix = ".json"

    private let workspaceLocator: any ProjectWorkspaceLocating

    init(workspaceLocator: any ProjectWorkspaceLocating) {
        self.workspaceLocator = workspaceLocator
    }

    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        let root = try await workspaceLocator.workspaceRoot(
            for: candidate.localProjectID
        )
        let url = root.appendingPathComponent(
            Self.prefix
                + candidate.snapshot.documentID.uuidString.lowercased()
                + Self.suffix
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(candidate).write(to: url, options: [.atomic])
    }
}

actor LocalSyncV2SnapshotApplier: SyncV2LocalSnapshotApplying {
    static let markerPrefix = ".writerpad-snapshot-pull-"
    static let markerSuffix = ".json"

    private struct RecoveryMarker: Codable, Sendable {
        let localProjectID: ProjectID
        let snapshot: SyncV2RemoteDocumentSnapshot
        let previousPath: RelativeDocumentPath?
        let previousDocument: DocumentNode?
        let previousContent: Data?
    }

    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let fileManager: FileManager
    private let writer = POSIXAtomicFileWriter()
    private let hasher: any ContentHashing

    init(
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default,
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
        self.hasher = hasher
    }

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws {
        let path = try validatedPath(snapshot.relativePath)
        let documents = try await documentRepository.documents(
            in: localProjectID
        )
        let documentID = DocumentID(rawValue: snapshot.documentID)
        let current = documents.first { $0.id == documentID }
        if documents.contains(where: {
            $0.id != documentID
                && normalized($0.relativePath.rawValue)
                    == normalized(path.rawValue)
        }) {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        let parentPath = (path.rawValue as NSString)
            .deletingLastPathComponent
        let parent: DocumentNode?
        if parentPath.isEmpty || parentPath == "." {
            parent = nil
        } else {
            parent = documents.first {
                $0.kind == .folder
                    && normalized($0.relativePath.rawValue)
                        == normalized(parentPath)
            }
            guard parent != nil else {
                throw SyncV2LocalSnapshotApplyError.invalidHierarchy
            }
        }

        let root = try await workspaceLocator.workspaceRoot(
            for: localProjectID
        )
        let destination = root.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw SyncV2LocalSnapshotApplyError.unsafePath
        }
        let parentURL = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: parentURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw SyncV2LocalSnapshotApplyError.invalidHierarchy
        }

        let markerURL = recoveryMarkerURL(
            documentID: snapshot.documentID,
            root: root
        )
        let existingMarker: RecoveryMarker?
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder().decode(
               RecoveryMarker.self,
               from: data
           ) {
            existingMarker = marker
        } else {
            existingMarker = nil
        }
        let recoveringSameSnapshot =
            existingMarker?.localProjectID == localProjectID
            && existingMarker?.snapshot.documentID
                == snapshot.documentID
            && existingMarker?.snapshot.revision == snapshot.revision
            && normalized(
                existingMarker?.snapshot.relativePath ?? ""
            ) == normalized(snapshot.relativePath)
        if current?.relativePath != path,
           fileManager.fileExists(atPath: destination.path),
           !recoveringSameSnapshot {
            throw SyncV2LocalSnapshotApplyError
                .pathOccupiedByDifferentDocument
        }

        let data = Data(snapshot.content.utf8)
        if !recoveringSameSnapshot {
            let previousContent: Data?
            if let current {
                previousContent = try? Data(
                    contentsOf: root.appendingPathComponent(
                        current.relativePath.rawValue
                    )
                )
            } else {
                previousContent = nil
            }
            let marker = RecoveryMarker(
                localProjectID: localProjectID,
                snapshot: snapshot,
                previousPath: current?.relativePath,
                previousDocument: current,
                previousContent: previousContent
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(
                to: markerURL,
                options: [.atomic]
            )
        }
        let temporary = parentURL.appendingPathComponent(
            LocalDocumentStore.temporaryPrefix
                + snapshot.documentID.uuidString.lowercased()
                + "-pull-\(UUID().uuidString.lowercased())"
                + LocalDocumentStore.temporarySuffix
        )
        try writer.writeTemporaryFile(data: data, at: temporary)
        try writer.replaceItem(at: destination, with: temporary)

        let hash = hasher.sha256(for: data)
        let siblings = documents.filter { $0.parentID == parent?.id }
        let node = DocumentNode(
            id: documentID,
            projectID: localProjectID,
            kind: .text,
            parentID: parent?.id,
            relativePath: path,
            userOrder: current?.userOrder
                ?? ((siblings.map(\.userOrder).max() ?? -1) + 1),
            modifiedAt: snapshot.updatedAt,
            contentHash: hash,
            deletionStatus: .active,
            cursor: current?.cursor ?? .start,
            isExpanded: current?.isExpanded ?? false
        )
        try await documentRepository.save(node)

        if let current, current.relativePath != path {
            let oldURL = root.appendingPathComponent(
                current.relativePath.rawValue
            ).standardizedFileURL
            if oldURL.path.hasPrefix(rootPrefix),
               fileManager.fileExists(atPath: oldURL.path) {
                try fileManager.removeItem(at: oldURL)
            }
        }
    }

    func finish(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        guard let root = try? await workspaceLocator.workspaceRoot(
            for: localProjectID
        ) else { return }
        try? fileManager.removeItem(
            at: recoveryMarkerURL(documentID: documentID, root: root)
        )
    }

    func rollback(
        localProjectID: ProjectID,
        documentID: UUID
    ) async {
        guard
            let root = try? await workspaceLocator.workspaceRoot(
                for: localProjectID
            ),
            let markerData = try? Data(
                contentsOf: recoveryMarkerURL(
                    documentID: documentID,
                    root: root
                )
            ),
            let marker = try? JSONDecoder().decode(
                RecoveryMarker.self,
                from: markerData
            ),
            marker.localProjectID == localProjectID,
            marker.snapshot.documentID == documentID,
            let appliedPath = try? validatedPath(
                marker.snapshot.relativePath
            )
        else { return }

        let appliedURL = root.appendingPathComponent(
            appliedPath.rawValue
        ).standardizedFileURL
        let appliedData = Data(marker.snapshot.content.utf8)
        guard
            let currentData = try? Data(contentsOf: appliedURL),
            currentData == appliedData
        else {
            // 적용 뒤 더 최신 로컬 저장이 있었다면 절대 되돌리지 않는다.
            return
        }

        do {
            if let previousDocument = marker.previousDocument,
               let previousContent = marker.previousContent {
                let previousURL = root.appendingPathComponent(
                    previousDocument.relativePath.rawValue
                ).standardizedFileURL
                let temporary = previousURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        LocalDocumentStore.temporaryPrefix
                            + documentID.uuidString.lowercased()
                            + "-rollback-\(UUID().uuidString.lowercased())"
                            + LocalDocumentStore.temporarySuffix
                    )
                try writer.writeTemporaryFile(
                    data: previousContent,
                    at: temporary
                )
                try writer.replaceItem(
                    at: previousURL,
                    with: temporary
                )
                try await documentRepository.save(previousDocument)
                if previousURL != appliedURL {
                    try? fileManager.removeItem(at: appliedURL)
                }
            } else if marker.previousDocument == nil {
                try? fileManager.removeItem(at: appliedURL)
                try await documentRepository.removeMetadata(
                    id: DocumentID(rawValue: documentID)
                )
            } else {
                return
            }
            try? fileManager.removeItem(
                at: recoveryMarkerURL(
                    documentID: documentID,
                    root: root
                )
            )
        } catch {
            // marker를 남겨 다음 복구가 동일한 보상 작업을 재개하게 한다.
        }
    }

    private func validatedPath(
        _ value: String
    ) throws -> RelativeDocumentPath {
        guard SyncV2Client.isValidServerPath(value),
              value.lowercased().hasSuffix(".txt"),
              !value.hasPrefix("__antigravity__/")
        else {
            throw SyncV2LocalSnapshotApplyError.unsafePath
        }
        return RelativeDocumentPath(rawValue: value)
    }

    private func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func recoveryMarkerURL(
        documentID: UUID,
        root: URL
    ) -> URL {
        root.appendingPathComponent(
            Self.markerPrefix
                + documentID.uuidString.lowercased()
                + Self.markerSuffix
        )
    }
}
