import Foundation
import CryptoKit

enum IntegratedEditorPlan {
#if DEBUG && WRITERPAD_INTEGRATED_EDITOR
    static let enabled = true
#else
    static let enabled = false
#endif
    static let id = "ipad-integrated-editor-20260913-v1"
    static let local = GeneralValidationPlan.local
    static let server = GeneralValidationPlan.server
    static let parent = UUID(uuidString: "95b8e4d0-1d8d-4af5-b121-0888d0157661")!
    static let protectedDocument = GeneralValidationPlan.document
    static let rootName = "통합검증 20260913"
    static let rootPath = "메인/메모장/" + rootName
    static func contains(_ path: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
}

enum IntegratedEditorError: String, Error, LocalizedError {
    case scope = "INTEGRATED_SCOPE", corrupt = "INTEGRATED_JOURNAL_CORRUPT", locked = "INTEGRATED_LOCKED"
    case budget = "INTEGRATED_REQUEST_LIMIT", expired = "INTEGRATED_TIME_LIMIT", clock = "INTEGRATED_CLOCK_REVERSED"
    case receipt = "INTEGRATED_RECEIPT_REQUIRED", conflict = "INTEGRATED_CONFLICT_PRESERVED"
    case partial = "INTEGRATED_PARTIAL_RECEIVE", dirty = "INTEGRATED_LOCAL_WORK_PENDING", queue = "INTEGRATED_QUEUE"
    case checkpoint = "INTEGRATED_PLANNED_STOP", configuration = "INTEGRATED_CONFIGURATION"
    case diagnostic = "INTEGRATED_DIAGNOSTIC_STOP"
    case automaticPolicy = "INTEGRATED_AUTOMATIC_POLICY_REQUIRED"
    case automaticLimit = "INTEGRATED_EMPTY_CYCLE_LIMIT"
    case automaticCounter = "INTEGRATED_AUTOMATIC_COUNTER_CORRUPT"
    var errorDescription: String? { rawValue }
}

/// Local policy only. This is not wire metadata or an execution approval.
struct IntegratedAutomaticPolicy: Codable, Equatable, Sendable {
    let version: Int
    let maxEmptyCycles: Int
    private enum Key: String, CodingKey, CaseIterable { case version, maxEmptyCycles = "max_empty_cycles" }
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(version: Int = 1, maxEmptyCycles: Int) { self.version = version; self.maxEmptyCycles = maxEmptyCycles }
    init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(Key.allCases.map(\.rawValue)) else { throw IntegratedEditorError.automaticPolicy }
        let c = try decoder.container(keyedBy: Key.self)
        version = try c.decode(Int.self, forKey: .version)
        maxEmptyCycles = try c.decode(Int.self, forKey: .maxEmptyCycles)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(version, forKey: .version); try c.encode(maxEmptyCycles, forKey: .maxEmptyCycles)
    }
    func validate() throws {
        guard version == 1, maxEmptyCycles >= 0 else { throw IntegratedEditorError.automaticPolicy }
    }
}

/// Proposed execution limits are inert until supplied explicitly to the integrated candidate.
/// Expiry is absolute wall time; suspending/restarting the app never extends it.
struct IntegratedExecution: Codable, Equatable, Sendable {
    let id: UUID
    let accountID: UUID
    let expiresAt: Date
    let maximumRequests: Int
    let maximumWrites: Int
    let maximumAuthentication: Int
    let pollingSeconds: Int
    let automatic: Bool
    var checkpoint: String? = nil
    var automatic_policy: IntegratedAutomaticPolicy? = nil
    func validate(now: Date) throws {
        try automatic_policy?.validate()
        guard maximumRequests > 0, maximumRequests <= 1000, maximumWrites > 0,
              maximumWrites <= maximumRequests, maximumAuthentication > 0,
              maximumAuthentication <= maximumRequests, (5...300).contains(pollingSeconds),
              expiresAt > now, expiresAt.timeIntervalSince(now) <= 86_400,
              checkpoint == nil || ["all", "beforeHTTP", "afterCommitResponse", "afterStoredResponse", "afterOriginalApply"].contains(checkpoint!) else {
            throw IntegratedEditorError.configuration
        }
    }
}

/// Explicit launch approval; never inferred from a changed execution JSON.
struct IntegratedExecutionAmendment: Codable, Equatable, Sendable {
    let executionID: UUID
    let previousExpiry: Date
    let expiresAt: Date
    let journalSHA256: String
    let approvalSHA256: String
    let batchID: UUID
    let operationID: UUID
    let requestSHA256: String
}

struct IntegratedReceiptDiagnostic: Codable, Equatable, Sendable {
    let initialRequests: Int
    let initialAuthentication: Int
    var reservedPaths: [String] = []
    var attempted = false
    var finished = false
    var releasedBy: String?
}

struct IntegratedReceiptRecoveryApproval: Codable, Equatable, Sendable {
    let executionID: UUID
    let expiresAt: Date
    let journalSHA256: String
    let approvalSHA256: String
    let batchID: UUID
    let operationID: UUID
    let requestSHA256: String
    let expectedRequests: Int
    let expectedAuthentication: Int
    let expectedWrites: Int
}

final class IntegratedEditorJournal: @unchecked Sendable {
    struct Draft: Codable, Sendable { let text: String; let cursor: TextCursorState; let hash: String; var inputSource: EditorInputSource? = nil }
    struct Source: Codable, Sendable { let batch: LocalMutationBatch; var enqueued = false }
    enum Phase: String, Codable, Sendable { case frozen, httpStarted, responseStored, completed, conflict }
    struct Wire: Codable, Sendable {
        let request: SyncV2JSON
        let hash: String
        var phase: Phase = .frozen
        var response: SyncV2JSON?
    }
    struct Conflict: Codable, Sendable {
        let baseline: [UUID: String]
        let sources: [LocalMutationBatch]
        let drafts: [UUID: Draft]
        let remote: IntegratedRemoteSnapshot
    }
    struct State: Codable, Sendable {
        var sources: [Source] = []
        var wires: [Wire] = []
        var drafts: [UUID: Draft] = [:]
        var members: Set<UUID> = []
        var receive: IntegratedRemoteSnapshot?
        var conflicts: [Conflict] = []
        var execution: IntegratedExecution?
        // Optional so journals written by 202609130843 decode without migration.
        var amendment: IntegratedExecutionAmendment?
        var diagnostic: IntegratedReceiptDiagnostic?
        var receiptRecoveryApproval: IntegratedReceiptRecoveryApproval?
        var receiptRecovery: IntegratedReceiptDiagnostic?
        // Absent in old runs; never backfilled or reset when reopening.
        var empty_cycles_used: Int?
        var automatic_stop: String?
        var latestSaveDiagnostic: EditorBoundaryDiagnostic?
        var usedRequests = 0
        var usedWrites = 0
        var usedAuthentication = 0
        var lastClock: Date?
        var stopped = false
        var automatic = false
        var checkpoints: Set<String> = []
        var message = "로컬 집필 준비. 통신은 승인된 실행 설정이 필요합니다."
        var activeWire: Int? { wires.firstIndex { $0.phase != .completed } }
        var diagnosticKey: WritableKeyPath<State, IntegratedReceiptDiagnostic?> { receiptRecovery == nil ? \.diagnostic : \.receiptRecovery }
        var activeDiagnostic: IntegratedReceiptDiagnostic? { self[keyPath: diagnosticKey] }
    }
    private struct Row: Codable { let plan: String; let sequence: Int; let previous: String; let event: String; let state: State }
    let root: URL
    private let lock = NSRecursiveLock()
    private var value = State()
    private var sequence = 0
    private var previous = ""
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter({ $0.pathExtension == "record" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw IntegratedEditorError.corrupt }
            let data = try Data(contentsOf: file), row = try JSONDecoder().decode(Row.self, from: data)
            guard row.plan == IntegratedEditorPlan.id, row.sequence == sequence + 1, row.previous == previous,
                  file.lastPathComponent == String(format: "%012d.record", row.sequence) else { throw IntegratedEditorError.corrupt }
            value = row.state; sequence = row.sequence; previous = IntegratedEditorPlan.hash(data)
        }
        for wire in value.wires { guard try wire.request.sha256Hex() == wire.hash else { throw IntegratedEditorError.corrupt } }
        for draft in value.drafts.values { guard IntegratedEditorPlan.hash(draft.text) == draft.hash else { throw IntegratedEditorError.corrupt } }
    }
    func state() -> State { lock.withLock { value } }
    var headSHA256: String { lock.withLock { previous } }
    var diagnosticRestricted: Bool { state().activeDiagnostic.map { $0.releasedBy == nil } ?? false }
    func authorizeReceiptRecovery(_ approval: IntegratedReceiptRecoveryApproval, now: Date = Date()) throws {
        try lock.withLock {
            try checkTime(now)
            if let existing = value.receiptRecoveryApproval {
                guard existing == approval, value.receiptRecovery != nil else { throw IntegratedEditorError.configuration }
                return // Reconnecting the same approval never resets its attempt or reservations.
            }
            guard let run = value.execution, let amendment = value.amendment,
                  run.id == approval.executionID, run.expiresAt == approval.expiresAt,
                  previous == approval.journalSHA256, Self.isDigest(approval.approvalSHA256),
                  approval.approvalSHA256 != amendment.approvalSHA256,
                  approval.batchID == amendment.batchID, approval.operationID == amendment.operationID,
                  approval.requestSHA256 == amendment.requestSHA256,
                  let first = value.diagnostic, first.attempted, first.finished, first.releasedBy == nil,
                  value.receiptRecovery == nil, !value.automatic, value.receive == nil, value.conflicts.isEmpty,
                  value.usedRequests == approval.expectedRequests, value.usedAuthentication == approval.expectedAuthentication,
                  value.usedWrites == approval.expectedWrites,
                  value.usedRequests <= run.maximumRequests - 5, value.usedAuthentication < run.maximumAuthentication,
                  let index = value.activeWire, value.wires[index].phase == .httpStarted,
                  value.wires[index].response == nil, value.wires[index].hash == approval.requestSHA256 else { throw IntegratedEditorError.configuration }
            let request = try SyncV2ContractRequest(storedJSON: value.wires[index].request)
            guard request.batchID == approval.batchID, request.orderedIntents.count == 1,
                  request.orderedIntents[0].objectValue?["operation_id"] == .string(approval.operationID.uuidString.lowercased()) else { throw IntegratedEditorError.configuration }
            try update("receiptRecoveryApproved") {
                $0.receiptRecoveryApproval = approval
                $0.receiptRecovery = .init(initialRequests: $0.usedRequests, initialAuthentication: $0.usedAuthentication)
            }
        }
    }
    func amend(_ execution: IntegratedExecution, approval: IntegratedExecutionAmendment, now: Date = Date()) throws {
        try lock.withLock {
            if let existing = value.amendment {
                guard existing == approval, value.execution == execution else { throw IntegratedEditorError.configuration }
                try checkTime(now); return
            }
            guard let old = value.execution, old.id == approval.executionID,
                  approval.executionID == UUID(uuidString: "6a7a9c7d-982a-4fcd-90e6-3b4140504860"),
                  old.expiresAt == approval.previousExpiry,
                  approval.previousExpiry == Date(timeIntervalSince1970: 1789270200),
                  approval.expiresAt == Date(timeIntervalSince1970: 1789279200),
                  execution.expiresAt == approval.expiresAt,
                  approval.journalSHA256 == previous, Self.isDigest(approval.approvalSHA256),
                  !value.stopped, !value.automatic, value.receive == nil, value.conflicts.isEmpty,
                  value.lastClock.map({ now >= $0 }) ?? true,
                  let index = value.activeWire, value.wires[index].phase == .httpStarted,
                  value.wires[index].hash == approval.requestSHA256 else { throw IntegratedEditorError.configuration }
            let request = try SyncV2ContractRequest(storedJSON: value.wires[index].request)
            guard request.batchID == approval.batchID, request.orderedIntents.count == 1,
                  request.orderedIntents[0].objectValue?["operation_id"] == .string(approval.operationID.uuidString.lowercased()) else { throw IntegratedEditorError.configuration }
            let expected = IntegratedExecution(id: old.id, accountID: old.accountID, expiresAt: approval.expiresAt,
                maximumRequests: old.maximumRequests, maximumWrites: old.maximumWrites,
                maximumAuthentication: old.maximumAuthentication, pollingSeconds: old.pollingSeconds,
                automatic: old.automatic, checkpoint: old.checkpoint, automatic_policy: old.automatic_policy)
            guard execution == expected else { throw IntegratedEditorError.configuration }
            try execution.validate(now: now)
            try update("executionExtendedWithReceiptDiagnostic") {
                $0.execution = execution; $0.amendment = approval
                $0.diagnostic = .init(initialRequests: $0.usedRequests, initialAuthentication: $0.usedAuthentication)
            }
        }
    }
    private static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func beginDiagnostic() throws {
        try checkTime()
        try update(state().receiptRecovery == nil ? "receiptDiagnosticStarted" : "receiptRecoveryStarted") {
            guard let d = $0.activeDiagnostic, d.releasedBy == nil, !d.attempted, !d.finished else { throw IntegratedEditorError.diagnostic }
            let key = $0.diagnosticKey; $0[keyPath: key]?.attempted = true
        }
    }
    func finishDiagnostic() throws {
        try update(state().receiptRecovery == nil ? "receiptDiagnosticFinished" : "receiptRecoveryFinished") {
            let key = $0.diagnosticKey; $0[keyPath: key]?.finished = true; $0.automatic = false
        }
    }
    /// Separate, explicit approval after reviewing the diagnostic. No counters/checkpoints are reset.
    func releaseDiagnostic(journalSHA256: String, approvalSHA256: String) throws {
        try lock.withLock {
            try checkTime()
            guard previous == journalSHA256, Self.isDigest(approvalSHA256),
                  let d = value.activeDiagnostic, d.finished, d.releasedBy == nil,
                  let index = value.activeWire, value.wires[index].phase == .responseStored,
                  let run = value.execution,
                  value.checkpoints.contains(run.id.uuidString + ":afterStoredResponse") else { throw IntegratedEditorError.configuration }
            try update("receiptDiagnosticResumeApproved") { let key = $0.diagnosticKey; $0[keyPath: key]?.releasedBy = approvalSHA256 }
        }
    }
    func diagnosticEvent(_ stage: String, detail: String) throws {
        guard diagnosticRestricted else { return }
        // Callers supply enum-like field names/numbers only, never localized error text or HTTP headers.
        try update((state().receiptRecovery == nil ? "receiptDiagnostic:" : "receiptRecovery:") + stage + ":" + detail) { _ in }
    }
    func update(_ event: String, _ change: (inout State) throws -> Void) throws {
        try lock.withLock {
            var next = value; try change(&next)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(Row(plan: IntegratedEditorPlan.id, sequence: sequence + 1, previous: previous, event: event, state: next))
            let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw IntegratedEditorError.corrupt }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
            let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directory >= 0 else { throw IntegratedEditorError.corrupt }; defer { close(directory) }
            let name = String(format: "%012d.record", sequence + 1)
            guard renameatx_np(directory, temporary.lastPathComponent, directory, name, UInt32(RENAME_EXCL)) == 0,
                  fsync(directory) == 0 else { throw IntegratedEditorError.corrupt }
            value = next; sequence += 1; previous = IntegratedEditorPlan.hash(bytes)
        }
    }
    func configure(_ execution: IntegratedExecution, now: Date = Date()) throws {
        try execution.validate(now: now)
        if let existing = state().execution {
            guard existing == execution else { throw IntegratedEditorError.configuration }
            try checkTime(now); return
        }
        try update("executionBound") {
            $0.execution = execution; $0.lastClock = now
            if let policy = execution.automatic_policy {
                $0.empty_cycles_used = 0
                if policy.maxEmptyCycles == 0 { $0.automatic_stop = IntegratedEditorError.automaticLimit.rawValue }
            }
            $0.automatic = execution.automatic && execution.automatic_policy != nil && $0.automatic_stop == nil
        }
    }
    func automaticBlockReason() -> IntegratedEditorError? {
        lock.withLock {
            guard let policy = value.execution?.automatic_policy else { return .automaticPolicy }
            guard policy.version == 1, policy.maxEmptyCycles >= 0 else { return .automaticPolicy }
            guard let used = value.empty_cycles_used, used >= 0, used <= policy.maxEmptyCycles,
                  value.automatic_stop == nil || value.automatic_stop == IntegratedEditorError.automaticLimit.rawValue,
                  value.automatic_stop == nil || used == policy.maxEmptyCycles else { return .automaticCounter }
            if value.automatic_stop != nil || used == policy.maxEmptyCycles { return .automaticLimit }
            return nil
        }
    }
    func setAutomatic(_ enabled: Bool) throws {
        try lock.withLock {
            try checkTime()
            if enabled, let reason = automaticBlockReason() { throw reason }
            try update("automaticChanged") { $0.automatic = enabled }
        }
    }
    /// Called once with dispatch ownership, after local eligibility checks, before any auth/HTTP.
    /// Persisting the Nth reservation also stops *future* automatic cycles. This cycle may finish.
    func reserveAutomaticCycle(hasPendingBatch: Bool, now: Date = Date()) throws {
        try lock.withLock {
            try checkTime(now)
            if let reason = automaticBlockReason() { throw reason }
            guard value.automatic, !diagnosticRestricted else { throw IntegratedEditorError.locked }
            guard value.conflicts.isEmpty, !value.wires.contains(where: { $0.phase == .conflict }) else { throw IntegratedEditorError.conflict }
            guard let run = value.execution, value.usedRequests < run.maximumRequests else { throw IntegratedEditorError.budget }
            guard !hasPendingBatch else { return }
            try update("emptyAutomaticCycleReserved") {
                $0.empty_cycles_used! += 1; $0.lastClock = now
                if $0.empty_cycles_used == run.automatic_policy!.maxEmptyCycles {
                    $0.automatic_stop = IntegratedEditorError.automaticLimit.rawValue
                    $0.automatic = false
                }
            }
        }
    }
    func recordSaveDiagnostic(_ diagnostic: EditorBoundaryDiagnostic) throws {
        guard state().members.contains(diagnostic.documentID.rawValue) else { throw IntegratedEditorError.scope }
        try update("editorBoundary:" + diagnostic.boundary.rawValue) { $0.latestSaveDiagnostic = diagnostic }
    }
    func checkTime(_ now: Date = Date()) throws {
        let state = state()
        guard let execution = state.execution, !state.stopped else { throw IntegratedEditorError.locked }
        guard state.lastClock.map({ now >= $0 }) ?? true else { throw IntegratedEditorError.clock }
        guard now < execution.expiresAt else { throw IntegratedEditorError.expired }
    }
    func reserve(kind: String, path: String? = nil, now: Date = Date()) throws {
        try update("requestReserved:" + kind) { state in
            guard let execution = state.execution, !state.stopped else { throw IntegratedEditorError.locked }
            guard state.lastClock.map({ now >= $0 }) ?? true else { throw IntegratedEditorError.clock }
            guard now < execution.expiresAt else { throw IntegratedEditorError.expired }
            guard state.usedRequests < execution.maximumRequests,
                  kind != "write" || state.usedWrites < execution.maximumWrites,
                  kind != "auth" || state.usedAuthentication < execution.maximumAuthentication else { throw IntegratedEditorError.budget }
            if let d = state.activeDiagnostic, d.releasedBy == nil {
                guard !d.finished, state.usedRequests - d.initialRequests < 5, kind != "write" else { throw IntegratedEditorError.diagnostic }
                if kind == "auth" {
                    guard state.usedAuthentication - d.initialAuthentication < 1 else { throw IntegratedEditorError.diagnostic }
                } else {
                    guard d.attempted, let path, ["rpc/get_sync_handshake", "rpc/get_project_status", "sync_batches", "sync_batch_results"].contains(path),
                          !d.reservedPaths.contains(path) else { throw IntegratedEditorError.diagnostic }
                    let key = state.diagnosticKey; state[keyPath: key]?.reservedPaths.append(path)
                }
            }
            state.usedRequests += 1; if kind == "write" { state.usedWrites += 1 }
            if kind == "auth" { state.usedAuthentication += 1 }; state.lastClock = now
        }
    }
    func checkpoint(_ point: String) throws {
        guard let run = state().execution, (run.checkpoint == point || run.checkpoint == "all") else { return }
        let key = run.id.uuidString + ":" + point
        guard !state().checkpoints.contains(key) else { return }
        try update("checkpoint:" + point) { $0.checkpoints.insert(key) }
        throw IntegratedEditorError.checkpoint
    }
    func draft(id: UUID, text: String, cursor: TextCursorState) throws {
        guard state().members.contains(id), id != IntegratedEditorPlan.protectedDocument else { throw IntegratedEditorError.scope }
        try update("draftSaved") { $0.drafts[id] = .init(text: text, cursor: cursor, hash: IntegratedEditorPlan.hash(text)) }
    }
    func record(_ batch: LocalMutationBatch) throws {
        guard batch.projectID == IntegratedEditorPlan.local, batch.contractStep == nil,
              [.documentSave, .structureChange, .trashChange, .volumeCreation].contains(batch.kind) else { throw IntegratedEditorError.scope }
        var members = state().members
        if let snapshot = batch.structureSnapshot {
            members.formUnion(snapshot.filter { IntegratedEditorPlan.contains($0.relativePath.rawValue) }.map { $0.id.rawValue })
        }
        for mutation in batch.mutations {
            switch mutation {
            case let .documentSnapshot(_, id, path, text, hash, _, _):
                guard id.rawValue != IntegratedEditorPlan.protectedDocument,
                      members.contains(id.rawValue) || IntegratedEditorPlan.contains(path.rawValue),
                      !text.contains("\r"), IntegratedEditorPlan.hash(text) == hash.rawValue else { throw IntegratedEditorError.scope }
                members.insert(id.rawValue)
            case let .folderSnapshot(_, id, parent, name, _):
                guard members.contains(id.rawValue) || parent.map({ members.contains($0.rawValue) }) == true
                    || (parent?.rawValue == IntegratedEditorPlan.parent && name == IntegratedEditorPlan.rootName) else { throw IntegratedEditorError.scope }
                members.insert(id.rawValue)
            case .treeOrder: break // Complete UUID-order intents are validated again against server baseline before transport.
            default: throw IntegratedEditorError.scope
            }
        }
        try update("sourceQueued") { state in
            guard state.receive == nil else { throw IntegratedEditorError.partial }
            if let old = state.sources.first(where: { $0.batch.batchID == batch.batchID }) {
                guard old.batch == batch else { throw IntegratedEditorError.corrupt }; return
            }
            state.members = members; state.sources.append(.init(batch: batch))
        }
    }
}

final class IntegratedEditorWakeup: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    func install(_ callback: @escaping @Sendable () -> Void) { lock.withLock { self.callback = callback } }
    func notify() { lock.withLock { callback }?() }
}
struct IntegratedEditorRecorder: DurableLocalChangeRecording {
    let journal: IntegratedEditorJournal
    let wakeup: IntegratedEditorWakeup
    func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool { false }
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        do {
            try journal.record(batch); wakeup.notify()
            return .queued(operationIDs: batch.mutations.map {
                switch $0 { case let .documentSnapshot(id, _, _, _, _, _, _), let .folderSnapshot(id, _, _, _, _),
                    let .treeOrder(id, _, _), let .trashPurge(id, _, _), let .ensureProject(id, _): return id }
            })
        } catch { return .localSavedButNotQueued(reason: error.localizedDescription) }
    }
}
