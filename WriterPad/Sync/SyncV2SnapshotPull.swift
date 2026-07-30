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
            return
        }
        await withCheckedContinuation { continuation in
            waiters[documentID, default: []].append(continuation)
        }
    }

    private func release(_ documentID: UUID) {
        guard var pending = waiters[documentID], !pending.isEmpty else {
            waiters[documentID] = nil
            lockedDocumentIDs.remove(documentID)
            return
        }
        let next = pending.removeFirst()
        waiters[documentID] = pending.isEmpty ? nil : pending
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
    func stop() async
}

enum SyncV2RealtimeTriggerError: Error {
    case globalSubscriptionUnsupported
}

extension SyncV2RealtimeTriggering {
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        _ = (onChange, onSubscribed)
        throw SyncV2RealtimeTriggerError.globalSubscriptionUnsupported
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
    private var channel: RealtimeChannelV2?
    private var changeSubscription: RealtimeSubscription?
    private var statusSubscription: RealtimeSubscription?
    private var channelGeneration: UUID?
    private var subscriptionGate = SyncV2RealtimeSubscriptionGate()

    init(client: SupabaseClient) {
        self.client = client
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await startChannel(
            projectID: projectID,
            onChange: onChange,
            onSubscribed: onSubscribed
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await startChannel(
            projectID: nil,
            onChange: onChange,
            onSubscribed: onSubscribed
        )
    }

    private func startChannel(
        projectID: UUID?,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        await stop()
        let generation = UUID()
        channelGeneration = generation
        subscriptionGate = SyncV2RealtimeSubscriptionGate()
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
                onChange()
            }
        } else {
            changeSubscription = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "documents"
            ) { _ in
                onChange()
            }
        }
        statusSubscription = channel.onStatusChange {
            [weak self] status in
            if case .subscribed = status {
                Task {
                    await self?.receivedSubscribed(
                        generation: generation,
                        callback: onSubscribed
                    )
                }
            }
        }
        self.channel = channel
        try await channel.subscribeWithError()
    }

    func stop() async {
        changeSubscription?.cancel()
        statusSubscription?.cancel()
        changeSubscription = nil
        statusSubscription = nil
        if let channel {
            await client.removeChannel(channel)
        }
        channel = nil
        channelGeneration = nil
        subscriptionGate = SyncV2RealtimeSubscriptionGate()
    }

    private func receivedSubscribed(
        generation: UUID,
        callback: @escaping @Sendable () -> Void
    ) {
        guard channelGeneration == generation else { return }
        guard subscriptionGate.receiveSubscribed() else {
            // foreground activation already performs an immediate snapshot.
            // The first subscription is therefore not a second trigger.
            return
        }
        callback()
    }
}

/// 열지 않은 작품의 서버 변경도 계속 받아오되, 열린 작품은 편집 보호를
/// 가진 `SyncV2WorkspaceSyncModel`에 맡긴다. 작품별 pull Task를 사용하므로
/// 한 작품의 지연이나 오류가 다른 작품을 기다리게 하지 않는다.
actor SyncV2BackgroundSyncCoordinator {
    private let puller: any SyncV2SnapshotPulling
    private let realtime: any SyncV2RealtimeTriggering
    private let projectBindingService: any ProjectBindingServicing
    private let debounceDelay: Duration
    private let periodicDelay: Duration
    private let sleep: SyncV2WorkspaceSleep

    private var isStarted = false
    private var activeLocalProjectID: ProjectID?
    private var pullTasks: [ProjectID: Task<Void, Never>] = [:]
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    init(
        puller: any SyncV2SnapshotPulling,
        realtime: any SyncV2RealtimeTriggering,
        projectBindingService: any ProjectBindingServicing,
        debounceDelay: Duration = .milliseconds(450),
        periodicDelay: Duration = .seconds(90),
        sleep: @escaping SyncV2WorkspaceSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.puller = puller
        self.realtime = realtime
        self.projectBindingService = projectBindingService
        self.debounceDelay = debounceDelay
        self.periodicDelay = periodicDelay
        self.sleep = sleep
    }

    func start() async {
        guard !isStarted, GlobalSyncPreference.isEnabled() else { return }
        isStarted = true
        do {
            try await realtime.startAll(
                onChange: { [weak self] in
                    Task { await self?.realtimeChanged() }
                },
                onSubscribed: { [weak self] in
                    Task { await self?.realtimeChanged() }
                }
            )
        } catch {
            // Realtime 실패 시에도 주기 snapshot pull로 복구한다.
        }
        startPeriodicPull()
        await pullInactiveProjects()
    }

    func stop() async {
        isStarted = false
        debounceTask?.cancel()
        periodicTask?.cancel()
        pullTasks.values.forEach { $0.cancel() }
        debounceTask = nil
        periodicTask = nil
        pullTasks.removeAll()
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
        }
        guard isStarted, previous != localProjectID else { return }
        await pullInactiveProjects()
    }

    func appEnteredForeground() async {
        guard isStarted else { return }
        await pullInactiveProjects()
    }

    private func realtimeChanged() {
        guard isStarted else { return }
        debounceTask?.cancel()
        let delay = debounceDelay
        let sleep = self.sleep
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
        periodicTask?.cancel()
        let delay = periodicDelay
        let sleep = self.sleep
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
            guard
                binding.localProjectID != activeLocalProjectID,
                let serverProjectID = binding.serverProjectID,
                pullTasks[binding.localProjectID] == nil
            else { continue }
            let localProjectID = binding.localProjectID
            let puller = self.puller
            pullTasks[localProjectID] = Task { [weak self] in
                _ = try? await puller.pull(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editingGuards: [:]
                )
                await self?.pullFinished(localProjectID)
            }
        }
    }

    private func pullFinished(_ localProjectID: ProjectID) {
        pullTasks[localProjectID] = nil
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

@MainActor
final class SyncV2WorkspaceSyncModel: ObservableObject {
    @Published private(set) var serverState:
        SyncV2WorkspaceServerState = .idle

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
    private let networkMonitor: SyncV2NetworkRecoveryMonitor
    private var editingGuards:
        (@MainActor @Sendable () -> [UUID: SyncV2EditingGuard])?
    private var applyOpenSnapshot:
        (@MainActor @Sendable (SyncV2RemoteDocumentSnapshot) -> Void)?
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var realtimeStartTask: Task<Void, Never>?
    private var authenticationCheckTask: Task<Void, Never>?
    private var bindingUpdateTask: Task<Void, Never>?
    private var serverProjectID: UUID?
    private var isActive = false
    private var generation: UInt64 = 0
    private var authenticationCheckGeneration: UInt64 = 0
    private var authenticationCheckDeadline: ContinuousClock.Instant?
    private var authenticationCheckHasTimedOut = false
    private var quietProgressUntil: ContinuousClock.Instant?

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
        authenticationSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        networkMonitor: SyncV2NetworkRecoveryMonitor =
            SyncV2NetworkRecoveryMonitor(),
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
        isActive = active
        if active {
            networkMonitor.start { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.networkRecovered()
                }
            }
            startBindingObservation()
            await activate()
        } else {
            debounceTask?.cancel()
            periodicTask?.cancel()
            pullTask?.cancel()
            realtimeStartTask?.cancel()
            cancelAuthenticationCheck()
            bindingUpdateTask?.cancel()
            debounceTask = nil
            periodicTask = nil
            pullTask = nil
            realtimeStartTask = nil
            bindingUpdateTask = nil
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
        isActive = false
        debounceTask?.cancel()
        periodicTask?.cancel()
        pullTask?.cancel()
        realtimeStartTask?.cancel()
        cancelAuthenticationCheck()
        bindingUpdateTask?.cancel()
        debounceTask = nil
        periodicTask = nil
        pullTask = nil
        realtimeStartTask = nil
        bindingUpdateTask = nil
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
        realtimeStartTask?.cancel()
        if let realtime {
            realtimeStartTask = Task { [weak self] in
                do {
                    try await realtime.start(
                        projectID: serverProjectID,
                        onChange: { [weak self] in
                            Task { @MainActor in
                                self?.realtimeChanged()
                            }
                        },
                        onSubscribed: { [weak self] in
                            Task { @MainActor in
                                self?.scheduleDebouncedPull()
                            }
                        }
                    )
                } catch {
                    // Realtime 실패와 무관하게 즉시 및 주기 pull은 유지한다.
                }
            }
        }
        startPeriodicPull()
        await pullNow(forceVisibleProgress: true)
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
            debounceTask?.cancel()
            periodicTask?.cancel()
            pullTask?.cancel()
            realtimeStartTask?.cancel()
            await realtime?.stop()
            serverState = .localOnly
            return
        }
        guard self.serverProjectID != serverProjectID else { return }
        self.serverProjectID = nil
        pullTask?.cancel()
        realtimeStartTask?.cancel()
        await realtime?.stop()
        await activate()
    }

    private func scheduleDebouncedPull() {
        guard isActive else { return }
        debounceTask?.cancel()
        let delay = debounceDelay
        let sleep = sleep
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
        periodicTask?.cancel()
        let delay = periodicDelay
        let sleep = sleep
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
            scheduleDebouncedPull()
            return
        }
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
        pullTask = Task { [weak self] in
            do {
                let report = try await puller.pull(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    editingGuards: guards
                )
                guard !Task.isCancelled,
                      self?.generation == generation,
                      self?.isActive == true
                else { return }
                self?.complete(report)
            } catch let error as SyncV2ClientError {
                guard !Task.isCancelled,
                      self?.generation == generation,
                      self?.isActive == true
                else { return }
                self?.complete(error)
            } catch {
                guard !Task.isCancelled,
                      self?.generation == generation,
                      self?.isActive == true
                else { return }
                self?.completeFailure(error.localizedDescription)
            }
        }
    }

    private func complete(_ report: SyncV2SnapshotPullReport) {
        pullTask = nil
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
        pullTask = nil
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
        pullTask = nil
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
