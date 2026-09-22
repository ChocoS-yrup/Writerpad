import CryptoKit
import Foundation

/// Opt-in diagnostic candidate only. A stop is durable and consumed once per plan/point.
/// No transport, timers, settings writes, process termination or automatic recovery here.
enum NormalEditorRecoveryInjection {
    static let plan = "normal-editor-recovery-20260913-v1"
    enum Point: String, Codable, Sendable { case beforeHTTP, afterCommitResponse, afterStoredResponse, afterOriginalApply }
    struct Run: Codable, Equatable, Sendable {
        let id: UUID
        let baselineRevision: Int64
        let baselineHash: String
    }
    struct Configuration: Codable, Equatable, Sendable {
        let point: Point
        let contentHash: String
        var run: Run? = nil
    }
#if DEBUG
    @TaskLocal static var testConfiguration: Configuration?
#endif
    static func parse(_ environment: [String: String]) throws -> Configuration? {
        let keys = ["WRITERPAD_RECOVERY_PLAN", "WRITERPAD_RECOVERY_POINT", "WRITERPAD_RECOVERY_CONTENT_SHA256",
                    "WRITERPAD_RECOVERY_RUN_ID", "WRITERPAD_RECOVERY_BASE_REVISION", "WRITERPAD_RECOVERY_BASE_SHA256"]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        guard environment[keys[0]] == plan, let raw = environment[keys[1]], let point = Point(rawValue: raw),
              let hash = environment[keys[2]], hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw NormalEditorError.recoveryConfiguration
        }
        var configuration = Configuration(point: point, contentHash: hash)
        if keys.dropFirst(3).contains(where: { environment[$0] != nil }) {
            guard let rawID = environment[keys[3]], let id = UUID(uuidString: rawID),
                  rawID == id.uuidString.lowercased(), let rawRevision = environment[keys[4]],
                  let revision = Int64(rawRevision), revision >= 6, revision < Int64.max, String(revision) == rawRevision,
                  let baseHash = environment[keys[5]], validHash(baseHash) else {
                throw NormalEditorError.recoveryConfiguration
            }
            configuration.run = .init(id: id, baselineRevision: revision, baselineHash: baseHash)
        }
        return configuration
    }
    static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func configuration() throws -> Configuration? {
#if DEBUG
        if let testConfiguration { return testConfiguration }
#endif
#if DEBUG && WRITERPAD_NORMAL_EDITOR && WRITERPAD_NORMAL_EDITOR_RECOVERY
        return try parse(ProcessInfo.processInfo.environment)
#else
        return nil
#endif
    }
    static func hit(_ point: Point, journal: NormalEditorJournal) throws {
        guard let configuration = try effectiveConfiguration(journal), configuration.point == point else { return }
        let key = checkpointKey(configuration)
        if configuration.run != nil {
            guard let active = journal.state().recoveryRuns?.last, !active.completed,
                  active.configuration == configuration else { throw NormalEditorError.recoveryConfiguration }
            try checkAction(journal, receiving: point == .afterOriginalApply)
        }
        // Keep reopens and already-consumed boundaries completely read-only.
        guard journal.state().recoveryCheckpoints?.contains(key) != true else { return }
        try journal.update("recoveryCheckpoint:" + point.rawValue) { state in
            let content: String
            if point == .afterOriginalApply {
                guard let receive = state.receive, receive.phase == "originalApplyStarted" else {
                    throw NormalEditorError.recoveryConfiguration
                }
                try NormalEditorPlan.validate(receive.remote)
                content = receive.remote.content
            } else {
                guard let index = state.head else { throw NormalEditorError.recoveryConfiguration }
                let save = state.saves[index]
                let expected: NormalEditorJournal.Phase = point == .beforeHTTP ? .frozen
                    : point == .afterCommitResponse ? .httpStarted : .responseStored
                guard save.phase == expected, let json = save.request,
                      try json.sha256Hex() == save.requestHash else { throw NormalEditorError.recoveryConfiguration }
                try NormalEditorPlan.validate(SyncV2ContractRequest(storedJSON: json), source: save.source)
                content = try NormalEditorPlan.content(save.source)
            }
            guard NormalEditorPlan.hash(content) == configuration.contentHash else { throw NormalEditorError.recoveryConfiguration }
            state.recoveryCheckpoints = (state.recoveryCheckpoints ?? []) + [key]
        }
        throw NormalEditorError.recoveryCheckpoint
    }

    static func checkpointKey(_ configuration: Configuration) -> String {
        plan + ":" + (configuration.run.map { $0.id.uuidString.lowercased() + ":" } ?? "") + configuration.point.rawValue
    }
    // Home-screen relaunch does not inherit launch environment. Resume the same durable run,
    // never a fresh journal/queue namespace that could hide an uncertain request.
    static func effectiveConfiguration(_ journal: NormalEditorJournal) throws -> Configuration? {
        let supplied = try configuration()
        if let active = journal.state().recoveryRuns?.last, !active.completed {
            guard supplied == nil || supplied == active.configuration else { throw NormalEditorError.recoveryConfiguration }
            return active.configuration
        }
        return supplied
    }
    static func preflight(journal: NormalEditorJournal, baseline: SyncV2RemoteDocumentSnapshot,
                          localText: String, dirty: Bool, composing: Bool, draftFailed: Bool) throws {
        guard let configuration = try effectiveConfiguration(journal), let run = configuration.run else { return }
        try NormalEditorPlan.validate(baseline)
        guard run.baselineRevision >= 6, run.baselineRevision < Int64.max, validHash(run.baselineHash), validHash(configuration.contentHash),
              !dirty, !composing, !draftFailed else { throw NormalEditorError.recoveryConfiguration }
        let state = journal.state(), runs = state.recoveryRuns ?? []
        guard state.conflicts.isEmpty, state.error == nil, let recordedBase = state.baseline,
              recordedBase.revision == run.baselineRevision,
              NormalEditorPlan.hash(recordedBase.content) == run.baselineHash else { throw NormalEditorError.baseline }
        let existing = runs.last.flatMap { $0.configuration == configuration && !$0.completed ? $0 : nil }
        if existing == nil {
            guard !runs.contains(where: { $0.configuration.run?.id == run.id }),
                  state.receive == nil else { throw NormalEditorError.recoveryConfiguration }
        }
        let baselineMatches = baseline.revision == run.baselineRevision && NormalEditorPlan.hash(baseline.content) == run.baselineHash
        let batchID: UUID?
        if configuration.point == .afterOriginalApply {
            guard state.head == nil else { throw NormalEditorError.dirty }
            batchID = nil
            if let receive = state.receive {
                guard existing != nil else { throw NormalEditorError.recoveryConfiguration }
                try validateIncoming(receive.remote, configuration: configuration)
                guard receive.baseline.revision == run.baselineRevision,
                      NormalEditorPlan.hash(receive.baseline.content) == run.baselineHash,
                      baselineMatches || (baseline.revision == receive.remote.revision && Data(baseline.content.utf8) == Data(receive.remote.content.utf8)),
                      Data(localText.utf8) == Data(receive.baseline.content.utf8) || Data(localText.utf8) == Data(receive.remote.content.utf8) else { throw NormalEditorError.baseline }
            } else {
                guard baselineMatches, Data(localText.utf8) == Data(baseline.content.utf8) else { throw NormalEditorError.baseline }
            }
        } else {
            guard state.receive == nil, let head = state.head,
                  state.saves.filter({ $0.phase != .completed && $0.phase != .superseded }).count == 1 else { throw NormalEditorError.queue }
            let save = state.saves[head], text = try NormalEditorPlan.content(save.source)
            guard !text.isEmpty, !text.contains("\r"), NormalEditorPlan.hash(text) == configuration.contentHash,
                  Data(localText.utf8) == Data(text.utf8) else { throw NormalEditorError.recoveryConfiguration }
            batchID = save.source.batchID
            if let existing {
                guard existing.batchID == batchID else { throw NormalEditorError.recoveryConfiguration }
            } else {
                // Never attach a new run ID to an already materialized/uncertain request.
                guard save.phase == .queued, save.request == nil, save.attempts.isEmpty else { throw NormalEditorError.recoveryConfiguration }
            }
            guard baselineMatches || (existing != nil && save.phase == .responseStored && baseline.revision == run.baselineRevision + 1 && Data(baseline.content.utf8) == Data(text.utf8)) else { throw NormalEditorError.baseline }
        }
        if let draft = try journal.draft() {
            let allowed = configuration.point == .afterOriginalApply
                ? [run.baselineHash, state.receive.map { NormalEditorPlan.hash($0.remote.content) }].compactMap { $0 }
                : [configuration.contentHash]
            guard allowed.contains(draft.hash) else { throw NormalEditorError.dirty }
        }
        if existing == nil {
            try journal.update("recoveryRunPrepared") { $0.recoveryRuns = runs + [.init(configuration: configuration, batchID: batchID)] }
        }
    }
    static func checkAction(_ journal: NormalEditorJournal, receiving: Bool) throws {
        guard let configuration = try effectiveConfiguration(journal), configuration.run != nil else { return }
        guard let active = journal.state().recoveryRuns?.last, !active.completed,
              active.configuration == configuration,
              receiving == (configuration.point == .afterOriginalApply) else { throw NormalEditorError.recoveryConfiguration }
        if !receiving {
            guard let head = journal.state().head, journal.state().saves[head].source.batchID == active.batchID else { throw NormalEditorError.recoveryConfiguration }
        }
    }
    static func validateIncoming(_ remote: SyncV2RemoteDocumentSnapshot, configuration: Configuration) throws {
        guard let run = configuration.run else { return }
        try NormalEditorPlan.validate(remote)
        guard configuration.point == .afterOriginalApply, remote.revision > run.baselineRevision,
              NormalEditorPlan.hash(remote.content) == configuration.contentHash else { throw NormalEditorError.recoveryConfiguration }
    }
    static func completeRun(_ state: inout NormalEditorJournal.State) {
        guard let index = state.recoveryRuns?.indices.last, state.recoveryRuns?[index].completed == false else { return }
        state.recoveryRuns?[index].completed = true
    }
}

/// This feature is a separate candidate. Old validation builds never acquire it.
enum NormalEditorPlan {
#if DEBUG && WRITERPAD_NORMAL_EDITOR
    static let enabled = true
#else
    static let enabled = false
#endif
    static let id = "normal-editor-single-document-20260913-v1"
    static let local = GeneralValidationPlan.local
    static let server = GeneralValidationPlan.server
    static let document = GeneralValidationPlan.document
    static let parent = GeneralValidationPlan.parent
    static let path = "메인/원고/일반본문검증 20260912.txt"
    static let initialHash = "82a4dfd0ec8af9e46475d339c6bf779bef995dd70844eb292f8419aec2bdbbaa"
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ node: DocumentNode) throws {
        guard node.id.rawValue == document, node.projectID == local, node.parentID?.rawValue == parent,
              node.relativePath.rawValue == path, node.kind == .text, node.deletionStatus == .active else { throw NormalEditorError.target }
    }
    static func validate(_ snapshot: SyncV2RemoteDocumentSnapshot) throws {
        guard snapshot.documentID == document, snapshot.relativePath == path, snapshot.parentFolderID == parent,
              snapshot.name == GeneralValidationPlan.name, snapshot.structureRevision == 1,
              !snapshot.isDeleted, snapshot.deletedAt == nil, snapshot.revision >= 6 else { throw NormalEditorError.target }
    }
    static func content(_ batch: LocalMutationBatch) throws -> String {
        guard batch.projectID == local, batch.kind == .documentSave, batch.mutations.count == 1,
              case let .documentSnapshot(_, id, path, content, hash, _, deleted) = batch.mutations[0],
              id.rawValue == document, path.rawValue == Self.path, !deleted,
              hash.rawValue == Self.hash(content) else { throw NormalEditorError.target }
        return content
    }
    static func validate(_ request: SyncV2ContractRequest, source: LocalMutationBatch) throws {
        let content = try content(source)
        guard !content.isEmpty, !content.contains("\r"), request.batchID == source.batchID,
              request.json.objectValue?["kind"] == .string("document_commit_request"),
              request.json.objectValue?["project_id"] == .string(server.uuidString.lowercased()),
              request.json.objectValue?["project_sync_mode"] == .string("ID_BASED"),
              request.json.objectValue?["migration_epoch"] == .int(1), request.orderedIntents.count == 1,
              case let .documentSnapshot(operation, _, _, _, _, _, _) = source.mutations[0],
              let intent = request.orderedIntents[0].objectValue, intent["intent_kind"] == .string("update"),
              intent["operation_id"] == .string(operation.uuidString.lowercased()),
              intent["document_id"] == .string(document.uuidString.lowercased()),
              (intent["base_revision"]?.intValue ?? 0) >= 6,
              let payload = intent["payload"]?.objectValue,
              payload["parent_folder_id"] == .string(parent.uuidString.lowercased()),
              payload["name"] == .string(GeneralValidationPlan.name), payload["structure_revision"] == .int(1),
              payload["is_deleted"] == .bool(false), payload["content_byte_count"] == .int(content.utf8.count),
              payload["content_sha256"] == .string(hash(content)),
              payload["content"]?.stringValue.map({ Data($0.utf8) }) == Data(content.utf8) else { throw NormalEditorError.request }
    }
}

enum NormalEditorError: String, Error, LocalizedError {
    case target = "NORMAL_TARGET_MISMATCH", storage = "NORMAL_STORAGE", corrupt = "NORMAL_RECORD_CORRUPT"
    case locked = "NORMAL_AUTHORITY_EXPIRED", busy = "NORMAL_BUSY", baseline = "NORMAL_BASELINE_MISMATCH"
    case dirty = "NORMAL_UNSAVED_OR_PENDING", empty = "NORMAL_EMPTY_UPLOAD", request = "NORMAL_REQUEST_MISMATCH"
    case unknown = "NORMAL_RECEIPT_REQUIRED", conflict = "NORMAL_CONFLICT_PRESERVED", queue = "NORMAL_QUEUE_FAILED"
    case partial = "NORMAL_RECEIVE_INCOMPLETE", noChange = "NORMAL_NO_PENDING_CHANGE"
    case recoveryCheckpoint = "NORMAL_RECOVERY_CHECKPOINT", recoveryConfiguration = "NORMAL_RECOVERY_CONFIGURATION"
    var errorDescription: String? { rawValue }
}

/// Draft replaces only its private file; accepted operations and transitions are append-only.
/// A new instance verifies the complete hash chain before using the latest state.
final class NormalEditorJournal: @unchecked Sendable {
    struct RecoveryRun: Codable, Sendable {
        let configuration: NormalEditorRecoveryInjection.Configuration
        let batchID: UUID?
        var completed = false
    }
    struct Draft: Codable, Sendable {
        let text: String
        let cursor: TextCursorState
        let hash: String
    }
    enum Phase: String, Codable, Sendable { case queued, freezing, frozen, httpStarted, responseStored, completed, superseded }
    struct Save: Codable, Sendable {
        let source: LocalMutationBatch
        var request: SyncV2JSON?
        var requestHash: String?
        var phase: Phase = .queued
        var response: SyncV2JSON?
        var attempts: [UUID] = []
        var error: String?
    }
    struct Receive: Codable, Sendable {
        let id: UUID
        let baseline: SyncV2RemoteDocumentSnapshot
        let remote: SyncV2RemoteDocumentSnapshot
        var phase: String = "responseStored"
        var observedOriginalHash: String?
    }
    struct Conflict: Codable, Sendable {
        let baseline: String
        let local: String
        let remote: SyncV2RemoteDocumentSnapshot
    }
    struct State: Codable, Sendable {
        var baseline: SyncV2RemoteDocumentSnapshot?
        var saves: [Save] = []
        var receive: Receive?
        var conflicts: [Conflict] = []
        var error: String?
        var lastFailure: String?
        var lastHTTPStatus: Int?
        var lastRequestHash: String?
        // Optional for compatibility with the installed candidate's existing journal.
        var recoveryCheckpoints: [String]?
        var recoveryRuns: [RecoveryRun]?
        var message = "통신 잠김. 로컬 편집·저장은 로그인 없이 가능합니다."
        var head: Int? { saves.firstIndex { $0.phase != .completed && $0.phase != .superseded } }
    }
    private struct Row: Codable {
        let plan: String
        let sequence: Int
        let previous: String
        let event: String
        let timestamp: Date
        let state: State
    }
    let root: URL
    private let lock = NSRecursiveLock()
    private var value = State()
    private var sequence = 0
    private var previous = ""
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.pathExtension == "record" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw NormalEditorError.corrupt }
            let bytes = try Data(contentsOf: file), row = try JSONDecoder().decode(Row.self, from: bytes)
            guard row.plan == NormalEditorPlan.id, row.sequence == sequence + 1, row.previous == previous,
                  file.lastPathComponent == String(format: "%012d.record", row.sequence) else { throw NormalEditorError.corrupt }
            value = row.state; sequence = row.sequence; previous = NormalEditorPlan.hash(bytes)
        }
        for save in value.saves {
            _ = try NormalEditorPlan.content(save.source)
            if let request = save.request {
                guard try request.sha256Hex() == save.requestHash else { throw NormalEditorError.corrupt }
                try NormalEditorPlan.validate(SyncV2ContractRequest(storedJSON: request), source: save.source)
            }
        }
    }
    func state() -> State { lock.withLock { value } }
    func update(_ event: String, _ change: (inout State) throws -> Void) throws {
        try lock.withLock {
            var next = value; try change(&next)
            let row = Row(plan: NormalEditorPlan.id, sequence: sequence + 1, previous: previous, event: event, timestamp: Date(), state: next)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(row)
            let destination = root.appendingPathComponent(String(format: "%012d.record", sequence + 1))
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw NormalEditorError.corrupt }
            try publish(bytes, to: destination)
            value = next; sequence += 1; previous = NormalEditorPlan.hash(bytes)
        }
    }
    private func publish(_ bytes: Data, to destination: URL) throws {
        // A crash may leave an unpublished .tmp, never a truncated visible record.
        let temporary = root.appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw NormalEditorError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: bytes); try handle.synchronize(); try handle.close()
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw NormalEditorError.storage }; defer { close(directory) }
        guard renameatx_np(directory, temporary.lastPathComponent, directory, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0,
              fsync(directory) == 0 else { throw NormalEditorError.storage }
    }
    private func sync(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw NormalEditorError.storage }; defer { close(directory) }
        guard fsync(directory) == 0 else { throw NormalEditorError.storage }
    }
    func saveDraft(text: String, cursor: TextCursorState) throws {
        try lock.withLock {
            let file = root.appendingPathComponent("draft.json")
            try JSONEncoder().encode(Draft(text: text, cursor: cursor, hash: NormalEditorPlan.hash(text))).write(to: file, options: .atomic)
            try sync(file)
        }
    }
    func draft() throws -> Draft? {
        try lock.withLock {
            let file = root.appendingPathComponent("draft.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: file))
            guard draft.hash == NormalEditorPlan.hash(draft.text) else { throw NormalEditorError.corrupt }
            return draft
        }
    }
    func record(_ batch: LocalMutationBatch) throws {
        _ = try NormalEditorPlan.content(batch)
        try update("localSaveQueued") { state in
            if let same = state.saves.first(where: { $0.source.batchID == batch.batchID }) {
                guard same.source == batch else { throw NormalEditorError.request }; return
            }
            if state.conflicts.isEmpty, state.error == nil {
                for index in state.saves.indices where state.saves[index].phase == .queued { state.saves[index].phase = .superseded }
            }
            state.saves.append(Save(source: batch))
            // A save does not clear a conflict, interrupted receive, or previous failure.
        }
    }
}

struct NormalEditorRecorder: DurableLocalChangeRecording {
    let journal: NormalEditorJournal
    func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool { false }
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        do {
            try journal.record(batch)
            guard case let .documentSnapshot(id, _, _, _, _, _, _) = batch.mutations[0] else { throw NormalEditorError.target }
            return .queued(operationIDs: [id])
        } catch { return .localSavedButNotQueued(reason: NormalEditorError.queue.rawValue) }
    }
}

/// The normal production save path remains responsible for TXT, metadata, generation and handoff.
actor NormalEditorDocumentStore: LocalDocumentStoring {
    let local: any LocalDocumentStoring
    let journal: NormalEditorJournal
    init(local: any LocalDocumentStoring, journal: NormalEditorJournal) { self.local = local; self.journal = journal }
    func loadText(for document: DocumentNode) async throws -> String {
        try NormalEditorPlan.validate(document); return try await local.loadText(for: document)
    }
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        guard request.projectID == NormalEditorPlan.local, request.documentID.rawValue == NormalEditorPlan.document,
              request.relativePath.rawValue == NormalEditorPlan.path, request.durableBatchKind == .documentSave,
              journal.state().receive == nil else { throw NormalEditorError.partial }
        // CR is rejected, never silently normalized. Empty local drafts may be saved but not sent.
        guard !request.text.contains("\r") else { throw NormalEditorError.request }
        do {
            let receipt = try await local.save(request)
            guard case .queued = receipt.durableRecordResult else { throw NormalEditorError.queue }
            return receipt
        } catch {
            try journal.update("localSaveFailed") { $0.error = (error as? NormalEditorError)?.rawValue ?? "NORMAL_LOCAL_SAVE_FAILED" }
            throw error
        }
    }
}
