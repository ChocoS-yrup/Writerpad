import CryptoKit
import Darwin
import Foundation

/// Fixed offline agreement with Windows. These values confer no live authority.
enum GeneralValidationPlan {
#if WRITERPAD_EDITOR_VALIDATION
    static let editorEnabled = true
#else
    static let editorEnabled = false
#endif
    static let id = editorEnabled ? "general-editor-20260913-v1" : "general-body-20260912-v1"
    static let incomingRevision: Int64 = editorEnabled ? 4 : 1
    static let outgoingRevision: Int64 = editorEnabled ? 5 : 2
    static let finalRevision: Int64 = editorEnabled ? 6 : 3
    static let local = ProjectID(rawValue: UUID(uuidString: "a9452cd1-4474-40b5-80ca-fbb7871e98e5")!)
    static let server = UUID(uuidString: "d8f50b5f-ae0e-42f8-9296-5d5885a5b304")!
    static let document = UUID(uuidString: "db8a3cc2-8b1a-5539-841c-042de34f5fd6")!
    static let parent = UUID(uuidString: "f4c92790-d675-4970-b1fc-b90f3a929ffb")!
    static let name = "일반본문검증 20260912.txt"
    private static let legacyIncoming = "일반 본문 검증 20260912\n이 문서는 일반 동기화 시험용 합성 원고입니다.\n끝.\n"
    static let initial = legacyIncoming + "iPad 일반 검증 20260912\nWindows 일반 검증 20260912\n"
    static let incoming = editorEnabled ? initial + "Windows 일반 편집 검증 20260913\n" : legacyIncoming
    static let outgoing = incoming + (editorEnabled ? "iPad 일반 편집 검증 20260913\n" : "iPad 일반 검증 20260912\n")
    static let final = outgoing + (editorEnabled ? "Windows 자동저장 검증 20260913\n" : "Windows 일반 검증 20260912\n")
    enum Stage: String, Codable, Sendable {
        case receiveWindows, sendUpdate, receiveFinal
        var predecessor: Self? {
            switch self { case .receiveWindows: nil; case .sendUpdate: .receiveWindows; case .receiveFinal: .sendUpdate }
        }
    }
    static func update(device: UUID, operation: UUID, batch: UUID, build: String) throws -> SyncV2ContractRequest {
        try SyncV2Contract.buildDocumentCommitRequest(projectID: server, projectSyncMode: .idBased,
            migrationEpoch: 1, writerDeviceID: device, documentID: document, intentKind: .update,
            baseRevision: Int(incomingRevision), parentFolderID: parent, name: name, content: outgoing, isDeleted: false,
            structureRevision: 1, operationID: operation, batchID: batch, clientBuildID: build)
    }
}

enum GeneralValidationFailure: Error { case denied, storage, alreadyReserved, priorStageIncomplete }

/// Private, redacted failure evidence, independent from the transport journal.
/// Error messages, userInfo, SQL, paths, bodies and credentials are never encoded.
final class GeneralValidationFailureDiagnostic: @unchecked Sendable {
    @TaskLocal static var current: GeneralValidationFailureDiagnostic?
    enum Area: String, Codable { case responses, prediction, original, completion }
    enum Step: String, Codable { case transport, validateResponse, copy, apply, editorSave, metadataSave, snapshotBaseline, checkpoint, finish }
    struct Record: Codable {
        let version: Int
        let attemptID: UUID
        let stage: GeneralValidationPlan.Stage
        let timestamp: Date
        let area: Area
        let step: Step
        let originalApplyStarted: Bool
        let errorFamily: String
        let errorCode: Int?
        var originalBodyMatch: String? = nil
    }
    private let lock = NSLock()
    private var area: Area = .responses
    private var step: Step = .transport
    private var originalBodyMatch: String?
    private var originalApplyStarted = false
    static func mark(_ step: Step) { if let current { current.lock.withLock { current.step = step } } }
    func enter(_ area: Area, _ step: Step) {
        lock.withLock {
            self.area = area; self.step = step
            if area == .original { originalApplyStarted = true }
        }
    }
    func observeOriginal(_ probe: GeneralValidationLocalProbe) {
        let data = try? Data(contentsOf: probe.workspace.appendingPathComponent("메인/원고/" + GeneralValidationPlan.name))
        let match: String
        if let data {
            if data == Data(GeneralValidationPlan.final.utf8) { match = "final" }
            else if data == Data(GeneralValidationPlan.outgoing.utf8) { match = "outgoing" }
            else if data == Data(GeneralValidationPlan.incoming.utf8) { match = "incoming" }
            else if GeneralValidationPlan.editorEnabled && data == Data(GeneralValidationPlan.initial.utf8) { match = "initial" }
            else { match = "other" }
        } else { match = "unreadableOrAbsent" }
        lock.withLock { originalBodyMatch = match }
    }
    func record(error: Error, attemptID: UUID, stage: GeneralValidationPlan.Stage) -> Record {
        let family: String, code: Int?
        switch error {
        case let SyncV2StoreError.sqlite(value): family = "sqlite"; code = Int(value)
        case is SyncV2StoreError: family = "syncStore"; code = nil
        case SyncV2DocumentMutationGateError.holdTimedOut: family = "documentMutationGate.holdTimedOut"; code = nil
        case let value as GeneralValidationEditor.Failure: family = "editor." + value.rawValue; code = nil
        case GeneralValidationFailure.denied: family = "generalValidation.denied"; code = nil
        case GeneralValidationFailure.storage: family = "generalValidation.storage"; code = nil
        case GeneralValidationFailure.alreadyReserved: family = "generalValidation.alreadyReserved"; code = nil
        case GeneralValidationFailure.priorStageIncomplete: family = "generalValidation.priorStageIncomplete"; code = nil
        case let LocalDocumentStoreError.operationFailed(operation, _, value): family = "localSave." + operation.rawValue; code = Int(value)
        case LocalDocumentStoreError.metadataUpdateFailed: family = "localSave.metadataUpdateFailed"; code = nil
        case LocalDocumentStoreError.comparedContentChanged: family = "localSave.comparedContentChanged"; code = nil
        case LocalDocumentStoreError.staleGeneration: family = "localSave.staleGeneration"; code = nil
        case let value as URLError: family = "url"; code = value.code.rawValue
        case is ReceiveValidationPolicy.Denied: family = "receivePolicy"; code = nil
        case is CancellationError: family = "cancellation"; code = nil
        default:
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain { family = "cocoa"; code = ns.code }
            else if ns.domain == NSPOSIXErrorDomain { family = "posix"; code = ns.code }
            else { family = "other"; code = nil }
        }
        return lock.withLock { Record(version: 1, attemptID: attemptID, stage: stage, timestamp: Date(),
            area: area, step: step, originalApplyStarted: originalApplyStarted, errorFamily: family, errorCode: code, originalBodyMatch: originalBodyMatch) }
    }
    func preserve(error: Error, journal: GeneralValidationJournal, root: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record(error: error, attemptID: journal.attemptID, stage: journal.stage))
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw GeneralValidationFailure.storage }
        defer { close(directory) }
        let name = "failure-" + journal.attemptID.uuidString.lowercased() + ".json"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw GeneralValidationFailure.storage }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0, fsync(directory) == 0 else { throw GeneralValidationFailure.storage }
    }
}

/// Append-only stage files. Opening a stage never truncates, repairs, or deletes it.
/// The owner supplies one stable private root; it must not choose a fresh root on retry.
final class GeneralValidationJournal: @unchecked Sendable {
    static let reviewedRecoveryArgument = "-writerpad-reviewed-first-receive-sha256"
    static let reviewedRecoveryIDArgument = "-writerpad-reviewed-first-receive-id"
    static func reviewedRecoveryID(arguments: [String]) -> UUID? {
        let indices = arguments.indices.filter { arguments[$0] == reviewedRecoveryIDArgument }
        guard indices.count == 1, let index = indices.first, arguments.indices.contains(index + 1),
              let id = UUID(uuidString: arguments[index + 1]),
              arguments[index + 1] == id.uuidString.lowercased() else { return nil }
        return id
    }
    static func reviewedRecoveryHash(arguments: [String]) -> String? {
        if arguments.contains(reviewedRecoveryIDArgument), reviewedRecoveryID(arguments: arguments) == nil { return nil }
        let indices = arguments.indices.filter { arguments[$0] == reviewedRecoveryArgument }
        guard indices.count == 1, let index = indices.first, arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return value
    }
    /// Operator-reviewed, explicit recovery of one exact failed GET-only stage.
    /// Preserve its original bytes by an exclusive atomic rename in the same
    /// private root. This does not authorize transport or change later stages.
    static func archiveReviewedFirstReceive(root: URL, expectedSHA256: String, recoveryID: UUID? = nil,
                                           validateLocal: () throws -> Void) throws {
        guard !GeneralValidationPlan.editorEnabled, reviewedRecoveryHash(arguments: [reviewedRecoveryArgument, expectedSHA256]) != nil else { throw GeneralValidationFailure.denied }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw GeneralValidationFailure.storage }
        defer { close(directory) }
        for stage in [GeneralValidationPlan.Stage.sendUpdate, .receiveFinal] {
            var info = stat()
            guard fstatat(directory, url(root: root, stage: stage).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0,
                  errno == ENOENT else { throw GeneralValidationFailure.denied }
        }
        let name = url(root: root, stage: .receiveWindows).lastPathComponent
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw GeneralValidationFailure.storage }
        defer { close(fd) }
        var sourceInfo = stat()
        guard fstat(fd, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG,
              sourceInfo.st_size > 0, sourceInfo.st_size <= 65_536 else { throw GeneralValidationFailure.denied }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65_537) ?? Data()
        guard data.count == Int(sourceInfo.st_size), data.last == 10,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA256 else { throw GeneralValidationFailure.denied }
        let rows = try data.split(separator: 10).map { try JSONDecoder().decode(Row.self, from: Data($0)) }
        guard rows.count == 8, rows.allSatisfy({ $0.plan == GeneralValidationPlan.id && $0.stage == .receiveWindows }),
              rows.allSatisfy({ $0.attemptID == rows.first?.attemptID && $0.startedAt == rows.first?.startedAt }),
              rows.first?.event == .reserved, rows.first?.sequence == 0,
              rows.last?.event == .stopped, rows.last?.sequence == 3 else { throw GeneralValidationFailure.denied }
        for index in 0..<3 {
            let attempt = rows[1 + index * 2], response = rows[2 + index * 2]
            guard attempt.event == .attempt, response.event == .responseAccepted,
                  attempt.sequence == index + 1, response.sequence == index + 1,
                  let hash = attempt.requestSHA256, hash.count == 64,
                  hash.allSatisfy({ "0123456789abcdef".contains($0) }), response.requestSHA256 == hash else { throw GeneralValidationFailure.denied }
        }
        try validateLocal()
        var currentInfo = stat()
        guard fstatat(directory, name, &currentInfo, AT_SYMLINK_NOFOLLOW) == 0,
              currentInfo.st_dev == sourceInfo.st_dev, currentInfo.st_ino == sourceInfo.st_ino,
              currentInfo.st_size == sourceInfo.st_size else { throw GeneralValidationFailure.denied }
        guard lseek(fd, 0, SEEK_SET) == 0,
              try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 65_537) == data else { throw GeneralValidationFailure.denied }
        // One operator-reviewed ID can be consumed only once, even when a
        // subsequent stop has different bytes. Legacy hash archives stay intact.
        let archive = "reviewed-stop-" + (recoveryID?.uuidString.lowercased() ?? expectedSHA256) + ".jsonl"
        guard renameatx_np(directory, name, directory, archive, UInt32(RENAME_EXCL)) == 0 else { throw GeneralValidationFailure.storage }
        guard fsync(directory) == 0 else { throw GeneralValidationFailure.storage }
    }
    enum Event: String, Codable { case reserved, attempt, responseAccepted, completed, stopped }
    struct Row: Codable {
        let plan: String
        let stage: GeneralValidationPlan.Stage
        let event: Event
        let sequence: Int
        let requestSHA256: String?
        let attemptID: UUID?
        let startedAt: Date?
        init(plan: String, stage: GeneralValidationPlan.Stage, event: Event, sequence: Int,
             requestSHA256: String?, attemptID: UUID? = nil, startedAt: Date? = nil) {
            self.plan = plan; self.stage = stage; self.event = event; self.sequence = sequence
            self.requestSHA256 = requestSHA256; self.attemptID = attemptID; self.startedAt = startedAt
        }
    }
    let attemptID = UUID()
    private let startedAt = Date()
    let stage: GeneralValidationPlan.Stage
    let url: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var failed = false
    private var executionAttached = false
    private var terminal = false
    private let beforeAppend: @Sendable (Event) throws -> Void
    static func url(root: URL, stage: GeneralValidationPlan.Stage) -> URL {
        root.appendingPathComponent(GeneralValidationPlan.id + "-" + stage.rawValue + ".jsonl")
    }
    init(root: URL, stage: GeneralValidationPlan.Stage,
         beforeAppend: @escaping @Sendable (Event) throws -> Void = { _ in }) throws {
        self.stage = stage; self.beforeAppend = beforeAppend
        url = Self.url(root: root, stage: stage)
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw GeneralValidationFailure.storage }
        defer { close(directory) }
        if let prior = stage.predecessor {
            let priorURL = Self.url(root: root, stage: prior)
            let previous = openat(directory, priorURL.lastPathComponent, O_RDONLY | O_NOFOLLOW)
            guard previous >= 0 else { throw GeneralValidationFailure.priorStageIncomplete }
            let handle = FileHandle(fileDescriptor: previous, closeOnDealloc: true)
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536, data.last == 10 else { throw GeneralValidationFailure.priorStageIncomplete }
            let rows = try data.split(separator: 10).map { try JSONDecoder().decode(Row.self, from: Data($0)) }
            let count = prior == .sendUpdate ? 1 : 3
            guard rows.count == 2 + count * 2,
                  rows.allSatisfy({ $0.plan == GeneralValidationPlan.id && $0.stage == prior }),
                  rows.allSatisfy({ $0.attemptID == rows.first?.attemptID && $0.startedAt == rows.first?.startedAt }),
                  rows.first?.event == .reserved, rows.first?.sequence == 0,
                  rows.last?.event == .completed, rows.last?.sequence == count
            else { throw GeneralValidationFailure.priorStageIncomplete }
            for index in 0..<count {
                let attempt = rows[1 + index * 2], response = rows[2 + index * 2]
                guard attempt.event == .attempt, response.event == .responseAccepted,
                      attempt.sequence == index + 1, response.sequence == index + 1,
                      let hash = attempt.requestSHA256, hash.count == 64,
                      hash.allSatisfy({ "0123456789abcdef".contains($0) }), response.requestSHA256 == hash
                else { throw GeneralValidationFailure.priorStageIncomplete }
            }
        }
        let fd = openat(directory, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw errno == EEXIST ? GeneralValidationFailure.alreadyReserved : .storage }
        descriptor = fd
        do {
            try append(.reserved, sequence: 0)
            guard fsync(directory) == 0 else { throw GeneralValidationFailure.storage }
        } catch {
            // A partial reservation remains a stop marker. Never remove it on error.
            throw error
        }
    }
    deinit { close(descriptor) }
    /// A reservation may precede a local save, whose actual queue IDs are not
    /// available yet. It can be attached to only one transport execution.
    func attach(stage: GeneralValidationPlan.Stage) throws {
        try lock.withLock {
            guard !failed, !terminal, !executionAttached, self.stage == stage else { throw GeneralValidationFailure.denied }
            executionAttached = true
        }
    }
    func append(_ event: Event, sequence: Int, requestSHA256: String? = nil) throws {
        try lock.withLock {
            guard !failed, !terminal else { throw GeneralValidationFailure.storage }
            do {
                try beforeAppend(event)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                var data = try encoder.encode(Row(plan: GeneralValidationPlan.id, stage: stage,
                    event: event, sequence: sequence, requestSHA256: requestSHA256, attemptID: attemptID, startedAt: startedAt))
                data.append(10)
                try data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { throw GeneralValidationFailure.storage }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw GeneralValidationFailure.storage }
                        offset += written
                    }
                }
                guard fsync(descriptor) == 0 else { throw GeneralValidationFailure.storage }
                if event == .stopped || event == .completed { terminal = true }
            } catch { failed = true; throw error }
        }
    }
}

/// Captured at session creation and enforced inside the final URLProtocol boundary.
/// This is an additional guard: ReceiveValidationPolicy still controls authentication
/// and transmission. No default network, stored credentials, or UI grant is created.
final class GeneralValidationExecution: @unchecked Sendable {
    @TaskLocal static var current: GeneralValidationExecution?
    struct Frozen: Sendable {
        let request: URLRequest
        let contract: SyncV2ContractRequest?
        var hash: String { GeneralSyncValidationScope.fingerprint(request) }
        init(request: URLRequest, stage: GeneralValidationPlan.Stage) throws {
            self.request = request
            guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.percentEncodedPath == url.path else { throw GeneralValidationFailure.denied }
            let body = request.httpBody ?? Data()
            if stage == .sendUpdate {
                guard url.absoluteString == ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/document_commit",
                      request.httpMethod == "POST", request.httpBodyStream == nil,
                      body.count < 65_536 else { throw GeneralValidationFailure.denied }
                let wrapper = try JSONDecoder().decode(SyncV2JSON.self, from: body).objectValue
                guard let wrapper, Set(wrapper.keys) == ["p_request"], let json = wrapper["p_request"],
                      let batch = json.objectValue?["batch"]?.objectValue,
                      let intent = json.objectValue?["ordered_intents"]?.arrayValue?.first?.objectValue,
                      let device = batch["writer_device_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let batchID = batch["batch_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let operation = intent["operation_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      let build = batch["client_build_id"]?.stringValue, !build.isEmpty
                else { throw GeneralValidationFailure.denied }
                let expected = try GeneralValidationPlan.update(device: device, operation: operation, batch: batchID, build: build)
                guard json == expected.json else { throw GeneralValidationFailure.denied }
                contract = expected
            } else {
                let scope = GeneralSyncValidationScope(restricted: true, selection: .init(local: GeneralValidationPlan.local,
                    server: GeneralValidationPlan.server, documents: [], reviewedRPCs: []))
                try scope.authorize(request)
                guard request.httpMethod == "GET", ["documents", "folders", "tree_orders"].contains(url.lastPathComponent),
                      (parts.queryItems ?? []).allSatisfy({ ["select", "project_id"].contains($0.name) })
                else { throw GeneralValidationFailure.denied }
                contract = nil
            }
            try Self.checkHeaders(request)
        }
        static func checkHeaders(_ request: URLRequest) throws {
            guard request.value(forHTTPHeaderField: "Range") == nil,
                  request.value(forHTTPHeaderField: "Range-Unit") == nil,
                  request.value(forHTTPHeaderField: "Prefer") == nil || request.value(forHTTPHeaderField: "Prefer") == "count=exact",
                  ["Accept-Profile", "Content-Profile"].allSatisfy({ request.value(forHTTPHeaderField: $0) == nil || request.value(forHTTPHeaderField: $0) == "public" })
            else { throw GeneralValidationFailure.denied }
        }
    }
    private let requests: [Frozen]
    private let journal: GeneralValidationJournal
    private let checkCurrent: @Sendable () throws -> Void
    private let checkLocal: @Sendable () throws -> Void
    private let now: @Sendable () -> TimeInterval
    private let deadline: TimeInterval
    private let bearerHash: Data
    private let lock = NSRecursiveLock()
    private var index = 0
    private var inFlight = false
    private var stopped = false
    private var completed = false
    private var acceptedPayloadHashes: [Data] = []
    init(root: URL, stage: GeneralValidationPlan.Stage, requests: [URLRequest], bearer: String,
         lifetime: TimeInterval = 300, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         checkCurrent: @escaping @Sendable () throws -> Void,
         checkLocal: @escaping @Sendable () throws -> Void,
         beforeAppend: @escaping @Sendable (GeneralValidationJournal.Event) throws -> Void = { _ in },
         reservation: GeneralValidationJournal? = nil) throws {
        guard !bearer.isEmpty, lifetime > 0, lifetime <= 300,
              stage == .sendUpdate ? requests.count == 1 : requests.count == 3 else { throw GeneralValidationFailure.denied }
        self.requests = try requests.map { try Frozen(request: $0, stage: stage) }
        if stage != .sendUpdate {
            guard Set(requests.compactMap { $0.url?.lastPathComponent }) == ["documents", "folders", "tree_orders"] else { throw GeneralValidationFailure.denied }
        }
        self.checkCurrent = checkCurrent; self.checkLocal = checkLocal; self.now = now
        deadline = now() + lifetime; bearerHash = Data(SHA256.hash(data: Data(bearer.utf8)))
        try checkCurrent(); try checkLocal()
        if let reservation {
            guard reservation.url == GeneralValidationJournal.url(root: root, stage: stage) else { throw GeneralValidationFailure.denied }
            journal = reservation
        } else { journal = try GeneralValidationJournal(root: root, stage: stage, beforeAppend: beforeAppend) }
        try journal.attach(stage: stage)
    }
    private func check(_ request: URLRequest? = nil) throws {
        try Task.checkCancellation()
        guard !stopped, !completed, now() < deadline else { throw GeneralValidationFailure.denied }
        try checkCurrent(); try checkLocal()
        if let request {
            try Frozen.checkHeaders(request)
            guard Data(SHA256.hash(data: Data((request.value(forHTTPHeaderField: "Authorization") ?? "").utf8))) == bearerHash else { throw GeneralValidationFailure.denied }
        }
    }
    func begin(_ request: URLRequest) throws {
        try lock.withLock {
            do {
                try check(request)
                guard !inFlight, index < requests.count,
                      GeneralSyncValidationScope.fingerprint(request) == requests[index].hash else { throw GeneralValidationFailure.denied }
                try journal.append(.attempt, sequence: index + 1, requestSHA256: requests[index].hash)
                try check(request) // Revocation or local change during persistence must stop before wire.
                inFlight = true
            } catch { stop(); throw error }
        }
    }
    func accept(_ data: Data, response: URLResponse, request: URLRequest) throws {
        try lock.withLock {
            do {
                try check(request)
                guard inFlight, index < requests.count, requests[index].hash == GeneralSyncValidationScope.fingerprint(request),
                      response.url == request.url, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count <= 16_777_216 else { throw GeneralValidationFailure.denied }
                if let contract = requests[index].contract {
                    let json = try JSONDecoder().decode(SyncV2JSON.self, from: data)
                    guard try SyncV2Contract.validateDocumentCommitResponse(request: contract, response: json) == .committed,
                          json.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"] == .int(Int(GeneralValidationPlan.outgoingRevision))
                    else { throw GeneralValidationFailure.denied }
                }
                try journal.append(.responseAccepted, sequence: index + 1, requestSHA256: requests[index].hash)
                acceptedPayloadHashes.append(Data(SHA256.hash(data: data)))
                index += 1; inFlight = false
            } catch { stop(); throw error }
        }
    }
    /// Caller must verify complete remote snapshots and the durable local apply/queue
    /// result before invoking this. Merely receiving the HTTP response cannot finish a stage.
    func completeAfterLocalValidation(_ validate: () throws -> Void) throws {
        try lock.withLock {
            do {
                try check()
                guard !inFlight, index == requests.count else { throw GeneralValidationFailure.denied }
                try validate(); try check()
                try journal.append(.completed, sequence: index)
                completed = true
            } catch { stop(); throw error }
        }
    }
    /// Call before any local mutation: a transport closure returning data without
    /// passing the final URLProtocol boundary must never authorize an apply.
    func requireResponsesAccepted() throws {
        try lock.withLock {
            do {
                try check()
                guard !inFlight, index == requests.count else { throw GeneralValidationFailure.denied }
            } catch { stop(); throw error }
        }
    }
    func requireAcceptedPayloads(_ payloads: [Data]) throws {
        try lock.withLock {
            do {
                try requireResponsesAccepted()
                guard payloads.map({ Data(SHA256.hash(data: $0)) }) == acceptedPayloadHashes else { throw GeneralValidationFailure.denied }
            } catch { stop(); throw error }
        }
    }
    func stop() {
        lock.withLock {
            guard !stopped, !completed else { return }
            stopped = true
            try? journal.append(.stopped, sequence: index)
        }
    }
}
