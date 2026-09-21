import Foundation
import SQLite3

/// Read in one SQLite transaction, using the same typed rows and full digest as
/// LocalProbe. No tables or columns are removed from the ordinary boundary hash.
struct GeneralValidationMetadataImage: Sendable {
    struct Table: Sendable {
        let columns: [String]
        let schema: [[String]]
        let rows: [[String]]
        func column(_ name: String) throws -> Int {
            guard let index = columns.firstIndex(of: name) else { throw GeneralValidationFailure.denied }
            return index
        }
        func keyed(by name: String) throws -> [String: [String]] {
            let index = try column(name)
            var result: [String: [String]] = [:]
            for row in rows {
                guard row.count == columns.count, result.updateValue(row, forKey: row[index]) == nil else { throw GeneralValidationFailure.denied }
            }
            return result
        }
    }
    let tables: [String: Table]
    let fullHash: String
    static func text(_ value: String, type: Int32) throws -> String {
        let prefix = "\(type):"
        guard value.hasPrefix(prefix), let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let result = String(data: data, encoding: .utf8) else { throw GeneralValidationFailure.denied }
        return result
    }
}

/// A narrow replay envelope, fixed from the unchanged source and isolated result
/// BEFORE the product mutation. All prior history rows remain byte-exact. Only
/// the timestamp of predicted new transactions and the observed two-slot
/// TRANSACTIONSTRING allocator reservation may differ. Unknown layouts fail.
struct GeneralValidationMetadataReplay: Sendable {
    private let before: GeneralValidationMetadataImage
    private let expected: GeneralValidationMetadataImage
    init(before: GeneralValidationMetadataImage, expected: GeneralValidationMetadataImage) throws {
        self.before = before; self.expected = expected
        guard Set(before.tables.keys) == Set(expected.tables.keys),
              let oldTransactions = before.tables["ATRANSACTION"],
              let newTransactions = expected.tables["ATRANSACTION"] else { throw GeneralValidationFailure.denied }
        guard oldTransactions.schema == newTransactions.schema else { throw GeneralValidationFailure.denied }
        _ = try newTransactions.column("ZTIMESTAMP")
        let old = try oldTransactions.keyed(by: "Z_PK"), new = try newTransactions.keyed(by: "Z_PK")
        guard old.allSatisfy({ new[$0.key] == $0.value }) else { throw GeneralValidationFailure.denied }
        for name in ["ACHANGE", "ATRANSACTIONSTRING"] {
            guard let oldTable = before.tables[name], let newTable = expected.tables[name] else { throw GeneralValidationFailure.denied }
            let previous = try oldTable.keyed(by: "Z_PK"), next = try newTable.keyed(by: "Z_PK")
            guard previous.allSatisfy({ next[$0.key] == $0.value }) else { throw GeneralValidationFailure.denied }
        }
        for (name, table) in before.tables {
            guard table.schema == expected.tables[name]?.schema else { throw GeneralValidationFailure.denied }
        }
        // Inspect the allowed allocator delta now, rather than discovering an
        // exception from whatever the live operation subsequently changed.
        _ = try allocatorBounds()
    }
    private func allocatorBounds() throws -> (String, Int, Set<Int64>) {
        guard let oldTable = before.tables["Z_PRIMARYKEY"], let newTable = expected.tables["Z_PRIMARYKEY"] else { throw GeneralValidationFailure.denied }
        let oldRows = try oldTable.keyed(by: "Z_NAME"), newRows = try newTable.keyed(by: "Z_NAME")
        let key = "\(SQLITE_TEXT):" + Data("TRANSACTIONSTRING".utf8).base64EncodedString()
        let index = try oldTable.column("Z_MAX")
        guard var old = oldRows[key], var new = newRows[key],
              let low = Int64(try GeneralValidationMetadataImage.text(old[index], type: SQLITE_INTEGER)),
              let high = Int64(try GeneralValidationMetadataImage.text(new[index], type: SQLITE_INTEGER)),
              low >= 0, high >= low, high == low || high - low == 2 else { throw GeneralValidationFailure.denied }
        old[index] = "allocator"; new[index] = "allocator"
        guard old == new else { throw GeneralValidationFailure.denied }
        return (key, index, Set([low, high]))
    }
    func validate(actual: GeneralValidationMetadataImage, beforeSnapshot: GeneralValidationLocalProbe.Snapshot,
                  expectedSnapshot: GeneralValidationLocalProbe.Snapshot, actualSnapshot: GeneralValidationLocalProbe.Snapshot,
                  interval: ClosedRange<Date>) throws {
        guard beforeSnapshot.metadataHash == before.fullHash, expectedSnapshot.metadataHash == expected.fullHash,
              actualSnapshot.metadataHash == actual.fullHash,
              actualSnapshot.syncHash == expectedSnapshot.syncHash, actualSnapshot.filesHash == expectedSnapshot.filesHash,
              actualSnapshot.stage == expectedSnapshot.stage, actualSnapshot.savedForUpdate == expectedSnapshot.savedForUpdate,
              interval.upperBound.timeIntervalSince(interval.lowerBound) <= 300,
              Set(actual.tables.keys) == Set(expected.tables.keys) else { throw GeneralValidationFailure.denied }
        let (allocatorKey, allocatorIndex, allocatorRange) = try allocatorBounds()
        for (name, predictedTable) in expected.tables {
            guard let actualTable = actual.tables[name], actualTable.schema == predictedTable.schema else { throw GeneralValidationFailure.denied }
            if name == "ATRANSACTION" {
                let previous = try before.tables[name]!.keyed(by: "Z_PK")
                let predicted = try predictedTable.keyed(by: "Z_PK"), received = try actualTable.keyed(by: "Z_PK")
                let timestamp = try predictedTable.column("ZTIMESTAMP")
                guard Set(received.keys) == Set(predicted.keys) else { throw GeneralValidationFailure.denied }
                for (key, var row) in received {
                    if let old = previous[key] {
                        guard row == old else { throw GeneralValidationFailure.denied }
                    } else {
                        guard var planned = predicted[key],
                              let time = Double(try GeneralValidationMetadataImage.text(row[timestamp], type: SQLITE_FLOAT)),
                              time.isFinite, interval.contains(Date(timeIntervalSinceReferenceDate: time)) else { throw GeneralValidationFailure.denied }
                        row[timestamp] = "new-transaction-time"; planned[timestamp] = "new-transaction-time"
                        guard row == planned else { throw GeneralValidationFailure.denied }
                    }
                }
            } else if name == "Z_PRIMARYKEY" {
                var planned = try predictedTable.keyed(by: "Z_NAME"), received = try actualTable.keyed(by: "Z_NAME")
                guard var row = received[allocatorKey], var target = planned[allocatorKey],
                      let count = Int64(try GeneralValidationMetadataImage.text(row[allocatorIndex], type: SQLITE_INTEGER)),
                      allocatorRange.contains(count) else { throw GeneralValidationFailure.denied }
                row[allocatorIndex] = "allocator"; target[allocatorIndex] = "allocator"
                received[allocatorKey] = row; planned[allocatorKey] = target
                guard received == planned else { throw GeneralValidationFailure.denied }
            } else {
                // Includes history changes/string rows, model rows, internal
                // optimistic-lock versions and every unrelated metadata table.
                let encoder = JSONEncoder()
                let planned = try predictedTable.rows.map { try encoder.encode($0).base64EncodedString() }.sorted()
                let received = try actualTable.rows.map { try encoder.encode($0).base64EncodedString() }.sorted()
                guard received == planned else { throw GeneralValidationFailure.denied }
            }
        }
    }
}

/// Generated once per foreground action, never compiled or supplied by Windows.
/// The same values are used by the isolated prediction and the actual local
/// mutation; they do not authorize either a save or a network request.
struct GeneralValidationRuntimeValues: Sendable {
    let date: Date
    var editorGeneration: UInt64 { UInt64(date.timeIntervalSince1970 * 1_000_000_000) }
    let batch: UUID
    let operation: UUID
    init(date: Date = Date(), batch: UUID = UUID(), operation: UUID = UUID()) {
        self.date = date; self.batch = batch; self.operation = operation
    }
    @TaskLocal static var current: Self?
}

/// Offline planning input. SQLite's backup API includes committed WAL data;
/// copying only the main DB file would silently lose that state. No migration,
/// checkpoint, credential restoration or network client is performed here.
struct GeneralValidationPlanningCopy: Sendable {
    enum Failure: String, Error { case originalChanged, copyMismatch, baselineRead, copyRead }
    enum CopyPhase: String, Codable, Sendable {
        case sourceValidation, baselineRead, createRoot, createWorkspace
        case databaseProperties, openSource, openDestination, backupInit, backupStep, backupFinish, journalMode, databasePermissions
        case enumerateWorkspace, entryProperties, entryValidation, copyDirectory, copyFile, filePermissions
        case verifySource, readCopy, verifyCopy, verifySourceFinal
    }
    struct CopyDiagnostic: Codable, Sendable {
        let version: Int
        var outcome: String
        var phase: CopyPhase
        var database: String?
        var entry: Int
        var directoriesCopied: Int
        var filesCopied: Int
        var bytesCopied: Int
        var errorFamily: String?
        var errorCode: Int?
        var validationFailure: String?
        var sqliteResult: Int32?
        var syncHashMatches: Bool?
        var metadataHashMatches: Bool?
        var filesHashMatches: Bool?
    }
#if DEBUG && WRITERPAD_ISOLATED_TESTS
    @TaskLocal static var diagnosticProbe: (@Sendable (CopyPhase, URL?) throws -> Void)?
#endif
    /// Only fixed phase names, counts and numeric error codes are persisted.
    /// Never encode NSError descriptions/userInfo, paths, SQL, contents or credentials.
    private final class Diagnostic {
        var root: URL?
        var value = CopyDiagnostic(version: 1, outcome: "incomplete", phase: .sourceValidation,
            entry: 0, directoriesCopied: 0, filesCopied: 0, bytesCopied: 0)
        func enter(_ phase: CopyPhase, database: String? = nil) throws {
            value.phase = phase; value.database = database; value.sqliteResult = nil
#if DEBUG && WRITERPAD_ISOLATED_TESTS
            try GeneralValidationPlanningCopy.diagnosticProbe?(phase, root)
#endif
        }
        func capture(_ error: Error) {
            if let failure = error as? Failure { value.validationFailure = failure.rawValue }
            guard value.errorFamily == nil else { return }
            if let result = value.sqliteResult, result != SQLITE_OK, result != SQLITE_DONE {
                value.errorFamily = "sqlite"; value.errorCode = Int(result); return
            }
            if error is CancellationError { value.errorFamily = "cancelled"; return }
            if error is Failure || error is GeneralValidationFailure { value.errorFamily = "validation"; return }
            let error = error as NSError
            switch error.domain {
            case NSCocoaErrorDomain: value.errorFamily = "cocoa"; value.errorCode = error.code
            case NSPOSIXErrorDomain: value.errorFamily = "posix"; value.errorCode = error.code
            default: value.errorFamily = "other"
            }
        }
        func persist(outcome: String) throws {
            value.outcome = outcome
            guard let root else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            let fd = open(root.appendingPathComponent("copy-diagnostic.json").path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw GeneralValidationFailure.storage }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data); try handle.synchronize()
        }
    }
    let root: URL
    let probe: GeneralValidationLocalProbe
    let baseline: GeneralValidationLocalProbe.Snapshot
    private let original: GeneralValidationLocalProbe

    static func create(from original: GeneralValidationLocalProbe, in parent: URL, savedForUpdate: Bool = false,
                       onDiagnostic: (CopyDiagnostic) -> Void = { _ in }) throws -> Self {
        let diagnostic = Diagnostic()
        do {
            let result = try make(from: original, in: parent, savedForUpdate: savedForUpdate, diagnostic: diagnostic)
            try diagnostic.persist(outcome: "complete")
            onDiagnostic(diagnostic.value)
            return result
        } catch {
            diagnostic.capture(error)
            // A diagnostic write failure never permits a failed copy to proceed.
            try? diagnostic.persist(outcome: "failed")
            onDiagnostic(diagnostic.value)
            throw error
        }
    }
    private static func make(from original: GeneralValidationLocalProbe, in parent: URL,
                             savedForUpdate: Bool, diagnostic: Diagnostic) throws -> Self {
        try diagnostic.enter(.sourceValidation)
        try Task.checkCancellation()
        guard original.fileIdentityRoot == nil else { throw GeneralValidationFailure.denied }
        let manager = FileManager.default
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { throw GeneralValidationFailure.denied }
        let parent = parent.resolvingSymlinksInPath().standardizedFileURL
        let workspace = original.workspace.resolvingSymlinksInPath().standardizedFileURL
        func inside(_ child: URL, _ ancestor: URL) -> Bool {
            child.path == ancestor.path || child.path.hasPrefix(ancestor.path + "/")
        }
        guard !inside(parent, workspace),
              !inside(original.syncURL.resolvingSymlinksInPath(), workspace),
              !inside(original.metadataURL.resolvingSymlinksInPath(), workspace) else { throw GeneralValidationFailure.denied }
        let before: GeneralValidationLocalProbe.Snapshot
        try diagnostic.enter(.baselineRead)
        do { before = try original.capture(savedForUpdate: savedForUpdate) } catch { diagnostic.capture(error); throw Failure.baselineRead }
        let root = parent.appendingPathComponent("planning-" + UUID().uuidString)
        // Never reuse or clear a previous attempt. Failed copies remain evidence.
        try diagnostic.enter(.createRoot)
        try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        diagnostic.root = root
        try diagnostic.enter(.createWorkspace)
        let copyWorkspace = root.appendingPathComponent("workspace")
        try manager.createDirectory(at: copyWorkspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try copyDatabase(original.syncURL, to: root.appendingPathComponent("sync.sqlite3"), role: "sync", diagnostic: diagnostic)
        try copyDatabase(original.metadataURL, to: root.appendingPathComponent("metadata.sqlite3"), role: "metadata", diagnostic: diagnostic)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        try diagnostic.enter(.enumerateWorkspace)
        var failed = false
        guard let files = manager.enumerator(at: workspace, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in diagnostic.value.phase = .enumerateWorkspace; diagnostic.capture(error); failed = true; return false }) else { throw GeneralValidationFailure.denied }
        var count = 0, bytes = 0
        for case let source as URL in files {
            diagnostic.value.entry = count + 1
            try diagnostic.enter(.entryProperties)
            try Task.checkCancellation()
            let values = try source.resourceValues(forKeys: keys)
            count += 1
            try diagnostic.enter(.entryValidation)
            guard count <= 1_024, values.isSymbolicLink != true else { throw GeneralValidationFailure.denied }
            let relative = try GeneralValidationLocalProbe.relativePath(of: source, under: workspace)
            let destination = copyWorkspace.appendingPathComponent(relative)
            if values.isDirectory == true {
                try diagnostic.enter(.copyDirectory)
                try manager.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                diagnostic.value.directoriesCopied += 1
            } else {
                guard values.isRegularFile == true, let size = values.fileSize, size <= 16_777_216 else { throw GeneralValidationFailure.denied }
                bytes += size; guard bytes <= 67_108_864 else { throw GeneralValidationFailure.denied }
                try diagnostic.enter(.copyFile)
                try manager.copyItem(at: source, to: destination)
                diagnostic.value.filesCopied += 1; diagnostic.value.bytesCopied += size
                try diagnostic.enter(.filePermissions)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
        }
        guard !failed else { throw GeneralValidationFailure.denied }
        let probe = GeneralValidationLocalProbe(syncURL: root.appendingPathComponent("sync.sqlite3"),
            metadataURL: root.appendingPathComponent("metadata.sqlite3"), workspace: copyWorkspace, fileIdentityRoot: workspace)
        try diagnostic.enter(.verifySource)
        guard try original.capture(savedForUpdate: savedForUpdate) == before else { throw Failure.originalChanged }
        let copied: GeneralValidationLocalProbe.Snapshot
        try diagnostic.enter(.readCopy)
        do { copied = try probe.capture(savedForUpdate: savedForUpdate) } catch { diagnostic.capture(error); throw Failure.copyRead }
        try diagnostic.enter(.verifyCopy)
        diagnostic.value.syncHashMatches = copied.syncHash == before.syncHash
        diagnostic.value.metadataHashMatches = copied.metadataHash == before.metadataHash
        diagnostic.value.filesHashMatches = copied.filesHash == before.filesHash
        guard copied == before else { throw Failure.copyMismatch }
        try diagnostic.enter(.verifySourceFinal)
        guard try original.capture(savedForUpdate: savedForUpdate) == before else { throw Failure.originalChanged }
        return Self(root: root, probe: probe, baseline: before, original: original)
    }

    private static func copyDatabase(_ source: URL, to destination: URL, role: String, diagnostic: Diagnostic) throws {
        try diagnostic.enter(.databaseProperties, database: role)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GeneralValidationFailure.denied }
        var input: OpaquePointer?, output: OpaquePointer?
        defer { if let input { sqlite3_close_v2(input) }; if let output { sqlite3_close_v2(output) } }
        try diagnostic.enter(.openSource, database: role)
        diagnostic.value.sqliteResult = sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard diagnostic.value.sqliteResult == SQLITE_OK, let input else { throw GeneralValidationFailure.storage }
        try diagnostic.enter(.openDestination, database: role)
        diagnostic.value.sqliteResult = sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard diagnostic.value.sqliteResult == SQLITE_OK, let output else { throw GeneralValidationFailure.storage }
        try diagnostic.enter(.backupInit, database: role)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            diagnostic.value.sqliteResult = sqlite3_extended_errcode(output); throw GeneralValidationFailure.storage
        }
        // Finish even when step fails; never retry a busy or locked source.
        let step = sqlite3_backup_step(backup, -1), finish = sqlite3_backup_finish(backup)
        try diagnostic.enter(.backupStep, database: role); diagnostic.value.sqliteResult = step
        guard step == SQLITE_DONE else { throw GeneralValidationFailure.storage }
        try diagnostic.enter(.backupFinish, database: role); diagnostic.value.sqliteResult = finish
        guard finish == SQLITE_OK else { throw GeneralValidationFailure.storage }
        try diagnostic.enter(.journalMode, database: role)
        diagnostic.value.sqliteResult = sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil)
        guard diagnostic.value.sqliteResult == SQLITE_OK else { throw GeneralValidationFailure.storage }
        try diagnostic.enter(.databasePermissions, database: role)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    func requireOriginalUnchanged() throws {
        try Task.checkCancellation()
        guard try original.capture(savedForUpdate: baseline.savedForUpdate) == baseline else { throw GeneralValidationFailure.denied }
    }

    /// Freeze a single predicted local mutation, including the permitted history
    /// delta, while the real source still exactly matches its pre-mutation state.
    func predictedCheckpoint(savedForUpdate: Bool = false) throws -> GeneralValidationPredictedCheckpoint {
        try requireOriginalUnchanged()
        let previous = try original.metadataImage(), after = try probe.capture(savedForUpdate: savedForUpdate)
        let next = try probe.metadataImage()
        guard previous.fullHash == baseline.metadataHash, next.fullHash == after.metadataHash else { throw GeneralValidationFailure.denied }
        let result = try GeneralValidationPredictedCheckpoint(before: baseline, after: after,
            metadata: GeneralValidationMetadataReplay(before: previous, expected: next))
        try requireOriginalUnchanged()
        return result
    }

    /// Derive a proposal by applying reviewed local steps only to the copy. The
    /// callback must use the supplied copy paths. This is not a live execution
    /// grant or proof of deterministic replay of UUIDs, timestamps and metadata.
    func derive(apply: @Sendable (GeneralValidationLocalProbe, Int) async throws -> Void) async throws -> GeneralValidationCheckpointPlan {
        try requireOriginalUnchanged()
        guard try probe.capture() == baseline, let stage = baseline.stage else { throw GeneralValidationFailure.denied }
        let savedFlags = stage == .sendUpdate ? [true, false] : [false]
        var checkpoints = [baseline]
        for (index, saved) in savedFlags.enumerated() {
            try requireOriginalUnchanged()
            try await GeneralValidationMutation.$current.withValue({ try self.requireOriginalUnchanged() }) {
                try await apply(probe, index)
            }
            try requireOriginalUnchanged()
            checkpoints.append(try probe.capture(savedForUpdate: saved))
        }
        try requireOriginalUnchanged()
        return try GeneralValidationCheckpointPlan(checkpoints: checkpoints)
    }
}

/// A single side effect, predicted before it runs. Send completion is predicted
/// separately from the actual accepted receipt; no fabricated server timestamps.
struct GeneralValidationPredictedCheckpoint: Sendable {
    let before: GeneralValidationLocalProbe.Snapshot
    let after: GeneralValidationLocalProbe.Snapshot
    let metadata: GeneralValidationMetadataReplay
    init(before: GeneralValidationLocalProbe.Snapshot, after: GeneralValidationLocalProbe.Snapshot,
         metadata: GeneralValidationMetadataReplay) throws {
        let allowed: Bool
        switch (before.stage, before.savedForUpdate, after.stage, after.savedForUpdate) {
        case (.receiveWindows, false, .sendUpdate, false), (.sendUpdate, false, .sendUpdate, true),
             (.sendUpdate, true, .receiveFinal, false), (.receiveFinal, false, nil, false): allowed = true
        default: allowed = false
        }
        guard allowed, before != after else { throw GeneralValidationFailure.denied }
        self.before = before; self.after = after; self.metadata = metadata
    }
    func makeTransition(probe: GeneralValidationLocalProbe,
                        current: @escaping @Sendable () throws -> Void) throws -> GeneralValidationLocalTransition {
        try GeneralValidationLocalTransition(expected: [before, after], capture: { index in
            try probe.capture(savedForUpdate: index == 0 ? before.savedForUpdate : after.savedForUpdate)
        }, current: current, metadataReplays: [1: metadata], metadataImage: { try probe.metadataImage() })
    }
}

/// Extra mutation guard, never a grant. It is inherited by the product store's
/// structured tasks and checked again at the SQLite/metadata/file boundary.
enum GeneralValidationMutation {
    @TaskLocal static var current: (@Sendable () throws -> Void)?
    static func check() throws { try current?() }
}

/// Immutable expected states supplied before execution. This validates their
/// sequence, not their provenance or how the future hashes were calculated.
/// Production still needs a separate expected-state builder.
struct GeneralValidationCheckpointPlan: Sendable, Equatable {
    typealias Snapshot = GeneralValidationLocalProbe.Snapshot
    let checkpoints: [Snapshot]

    init(checkpoints: [Snapshot]) throws {
        guard checkpoints.count == 2 || checkpoints.count == 3 else {
            throw GeneralValidationFailure.denied
        }
        let stages = checkpoints.map(\.stage)
        let saved = checkpoints.map(\.savedForUpdate)
        let valid: Bool
        switch stages {
        case [.receiveWindows, .sendUpdate]:
            valid = saved == [false, false]
        case [.sendUpdate, .sendUpdate, .receiveFinal]:
            valid = saved == [false, true, false]
        case [.receiveFinal, nil]:
            valid = saved == [false, false]
        default:
            valid = false
        }
        guard valid else { throw GeneralValidationFailure.denied }
        for pair in zip(checkpoints, checkpoints.dropFirst()) {
            guard pair.0.syncHash != pair.1.syncHash ||
                  pair.0.metadataHash != pair.1.metadataHash ||
                  pair.0.filesHash != pair.1.filesHash else { throw GeneralValidationFailure.denied }
        }
        self.checkpoints = checkpoints
    }

    var initial: Snapshot { checkpoints[0] }
    var stage: GeneralValidationPlan.Stage {
        guard let stage = checkpoints[0].stage else { preconditionFailure("invalid checkpoint plan") }
        return stage
    }

    func requireStart(_ snapshot: Snapshot) throws {
        guard snapshot == initial else { throw GeneralValidationFailure.denied }
    }
}

/// A reviewed set of exact checkpoints, frozen before any side effect. Never
/// recapture a changed database and silently adopt it as the new baseline.
final class GeneralValidationLocalTransition: @unchecked Sendable {
    typealias Snapshot = GeneralValidationLocalProbe.Snapshot
    private let expected: [Snapshot]
    private let capture: @Sendable (Int) throws -> Snapshot
    private let current: @Sendable () throws -> Void
    private let metadataReplays: [Int: GeneralValidationMetadataReplay]
    private let metadataImage: (@Sendable () throws -> GeneralValidationMetadataImage)?
    private var sealed: Snapshot
    private let lock = NSRecursiveLock()
    private var index = 0
    private var mutating = false
    private var stopped = false
    private var mutationGeneration: UInt64 = 0
    init(expected: [Snapshot], capture: @escaping @Sendable (Int) throws -> Snapshot,
         current: @escaping @Sendable () throws -> Void,
         metadataReplays: [Int: GeneralValidationMetadataReplay] = [:],
         metadataImage: (@Sendable () throws -> GeneralValidationMetadataImage)? = nil) throws {
        guard expected.count == 2 || expected.count == 3 else { throw GeneralValidationFailure.denied }
        self.expected = expected; self.capture = capture; self.current = current
        guard metadataReplays.keys.allSatisfy({ $0 > 0 && $0 < expected.count }),
              metadataReplays.isEmpty || metadataImage != nil else { throw GeneralValidationFailure.denied }
        self.metadataReplays = metadataReplays; self.metadataImage = metadataImage; self.sealed = expected[0]
        try check()
    }
    func require(stage: GeneralValidationPlan.Stage) throws {
        try lock.withLock {
            try check()
            let stages: [GeneralValidationPlan.Stage?]
            switch stage {
            case .receiveWindows: stages = [.receiveWindows, .sendUpdate]
            case .sendUpdate: stages = [.sendUpdate, .sendUpdate, .receiveFinal]
            case .receiveFinal: stages = [.receiveFinal, nil]
            }
            guard index == 0, expected.map(\.stage) == stages,
                  expected.map(\.savedForUpdate) == (stage == .sendUpdate ? [false, true, false] : [false, false]) else { throw GeneralValidationFailure.denied }
        }
    }
    func check() throws {
        try lock.withLock {
            try Task.checkCancellation(); try current()
            guard !stopped, !mutating, try capture(index) == sealed else { throw GeneralValidationFailure.denied }
        }
    }
    private func authorizeMutation(generation: UInt64) throws {
        try lock.withLock {
            try Task.checkCancellation(); try current()
            guard mutating, !stopped, generation == mutationGeneration else { throw GeneralValidationFailure.denied }
        }
    }
    func advance<T: Sendable>(_ operation: @Sendable (@escaping @Sendable () throws -> Void) async throws -> T) async throws -> T {
        do {
            let startedAt = Date()
            let generation = try lock.withLock {
                try check()
                guard index + 1 < expected.count else { throw GeneralValidationFailure.denied }
                mutating = true; mutationGeneration += 1
                return mutationGeneration
            }
            let authorization: @Sendable () throws -> Void = { try self.authorizeMutation(generation: generation) }
            let result = try await GeneralValidationMutation.$current.withValue(authorization) {
                try await operation(authorization)
            }
            try lock.withLock {
                try authorizeMutation(generation: generation)
                let actual = try capture(index + 1)
                if let replay = metadataReplays[index + 1], let metadataImage {
                    let endedAt = Date()
                    guard endedAt >= startedAt else { throw GeneralValidationFailure.denied }
                    try replay.validate(actual: metadataImage(), beforeSnapshot: sealed,
                        expectedSnapshot: expected[index + 1], actualSnapshot: actual, interval: startedAt...endedAt)
                } else {
                    guard actual == expected[index + 1] else { throw GeneralValidationFailure.denied }
                }
                // Seal only after the predeclared envelope validates every row.
                // Later wire checks again use the entire unmodified full hash.
                sealed = actual
                index += 1; mutating = false
                try check()
            }
            return result
        } catch { stop(); throw error }
    }
    func requireFinished() throws {
        try lock.withLock {
            try check()
            guard index == expected.count - 1 else { throw GeneralValidationFailure.denied }
        }
    }
    func stop() { lock.withLock { stopped = true } }
}

/// Full reviewed baseline, supplied from preserved evidence, never inferred from
/// the incoming response. Preserved millisecond dates allow only their rounding loss.
struct GeneralValidationRemoteBaseline: Sendable {
    let control: SyncV2RemoteDocumentSnapshot
    let folders: [SyncV2RemoteFolder]
    let orders: [SyncV2RemoteTreeOrder]
    var timestampTolerance: TimeInterval = 0
    /// Preserved iPad baseline, before the agreed Windows create. Local storage
    /// retained server dates to milliseconds; allow only that rounding loss.
    static func preserved() throws -> Self {
        struct Archive: Decodable {
            let control: SyncV2RemoteDocumentSnapshot
            let folders: [SyncV2RemoteFolder]
            let orders: [SyncV2RemoteTreeOrder]
        }
        let data = Data(base64Encoded: "eyJjb250cm9sIjp7ImNvbnRlbnQiOiJ7XCJmb2xkZXJfcGF0aHNcIjpbXCLrqZTsnbgv66mU66qo7J6lXCIsXCLrqZTsnbgv67O17ISgXCIsXCLrqZTsnbgv7ISk7KCV7KeRXCIsXCLrqZTsnbgv7Iqk7Yag66asIO2UjOuhr1wiLFwi66mU7J24L+yXsOqysO2ZleyduFwiLFwi66mU7J24L+ybkOqzoFwiLFwi66mU7J24L+yepeyGjFwiLFwi66mU7J24L+y6kOumre2EsFwiLFwi66mU7J24L+2dkOumhOygleumrFwiXSxcInRyZWVfb3JkZXJcIjp7XCI8cm9vdD5cIjpbXCLsm5Dqs6BcIixcIuy6kOumre2EsFwiLFwi7ISk7KCV7KeRXCIsXCLrqZTrqqjsnqVcIixcIuyKpO2GoOumrCDtlIzroa9cIixcIu2dkOumhOygleumrFwiLFwi67O17ISgXCIsXCLsnqXshoxcIixcIuyXsOqysO2ZleyduFwiLFwi7Zy07KeA7Ya1XCJdLFwi66mU7J24L+uplOuqqOyepVwiOltdLFwi66mU7J24L+uzteyEoFwiOltdLFwi66mU7J24L+yEpOygleynkVwiOltdLFwi66mU7J24L+yKpO2GoOumrCDtlIzroa9cIjpbXSxcIuuplOyduC/sl7DqsrDtmZXsnbhcIjpbXSxcIuuplOyduC/sm5Dqs6BcIjpbXSxcIuuplOyduC/snqXshoxcIjpbXSxcIuuplOyduC/supDrpq3thLBcIjpbXSxcIuuplOyduC/tnZDrpoTsoJXrpqxcIjpbXX0sXCJ2ZXJzaW9uXCI6MX0iLCJkZWxldGVkX2F0IjpudWxsLCJkb2N1bWVudF9pZCI6IjZjYmU0N2NkLTY3ZTUtNWUyNy04ZGJmLWYzYWU1OTI1NWQ1MiIsImlzX2RlbGV0ZWQiOmZhbHNlLCJuYW1lIjpudWxsLCJwYXJlbnRfZm9sZGVyX2lkIjpudWxsLCJyZWxhdGl2ZV9wYXRoIjoiX19hbnRpZ3Jhdml0eV9fL3RyZWUtb3JkZXIuanNvbiIsInJldmlzaW9uIjoxLCJzdHJ1Y3R1cmVfcmV2aXNpb24iOm51bGwsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA3OjIwOjI0LjcwMloifSwiZm9sZGVycyI6W3siZm9sZGVyX2lkIjoiMTMxODY3ODQtMmU1Ny00ZTI5LWIyOGEtMTc4MzAxNjc5ODI0IiwiaXNfZGVsZXRlZCI6ZmFsc2UsIm5hbWUiOiLtnLTsp4DthrUiLCJwYXJlbnRfZm9sZGVyX2lkIjoiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIiwicmV2aXNpb24iOjEsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA3OjIwOjI0LjM2NVoifSx7ImZvbGRlcl9pZCI6IjRhNzFhYzdmLTQzYmItNDhlNS1hMGE5LTQ0NTA4YmQ0NjNkMCIsImlzX2RlbGV0ZWQiOmZhbHNlLCJuYW1lIjoi7Iqk7Yag66asIO2UjOuhryIsInBhcmVudF9mb2xkZXJfaWQiOiJlODdhMGU0NC05YThkLTRiMTgtYjk3NC1iNDBmNGFiMWVhYWQiLCJyZXZpc2lvbiI6MSwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDc6MjA6MjMuNTExWiJ9LHsiZm9sZGVyX2lkIjoiNWEwYTFkODgtM2E5Ni00NjdiLTk3MTEtMGJjZTliNjliZTNjIiwiaXNfZGVsZXRlZCI6ZmFsc2UsIm5hbWUiOiLsupDrpq3thLAiLCJwYXJlbnRfZm9sZGVyX2lkIjoiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIiwicmV2aXNpb24iOjEsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA3OjIwOjI0LjI1M1oifSx7ImZvbGRlcl9pZCI6IjY3MzI5NmZjLTJiMmEtNDU4OS1hOTIwLTk4ZmIxZjczNzBmMSIsImlzX2RlbGV0ZWQiOmZhbHNlLCJuYW1lIjoi7Z2Q66aE7KCV66asIiwicGFyZW50X2ZvbGRlcl9pZCI6ImU4N2EwZTQ0LTlhOGQtNGIxOC1iOTc0LWI0MGY0YWIxZWFhZCIsInJldmlzaW9uIjoxLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwNzoyMDoyNC40ODJaIn0seyJmb2xkZXJfaWQiOiI4ZjA2NmQ4MC0wMzczLTQwMGQtODhlNC1iODA5ZTY4ZTc0NjAiLCJpc19kZWxldGVkIjpmYWxzZSwibmFtZSI6IuuzteyEoCIsInBhcmVudF9mb2xkZXJfaWQiOiJlODdhMGU0NC05YThkLTRiMTgtYjk3NC1iNDBmNGFiMWVhYWQiLCJyZXZpc2lvbiI6MSwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDc6MjA6MjMuMTQxWiJ9LHsiZm9sZGVyX2lkIjoiOTViOGU0ZDAtMWQ4ZC00YWY1LWIxMjEtMDg4OGQwMTU3NjYxIiwiaXNfZGVsZXRlZCI6ZmFsc2UsIm5hbWUiOiLrqZTrqqjsnqUiLCJwYXJlbnRfZm9sZGVyX2lkIjoiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIiwicmV2aXNpb24iOjEsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA3OjIwOjIyLjg2OFoifSx7ImZvbGRlcl9pZCI6ImEyZDlmNzYwLTFhNDItNGVhZC1hMmQwLTUxODcwYjA2MmZkOSIsImlzX2RlbGV0ZWQiOmZhbHNlLCJuYW1lIjoi7Jew6rKw7ZmV7J24IiwicGFyZW50X2ZvbGRlcl9pZCI6ImU4N2EwZTQ0LTlhOGQtNGIxOC1iOTc0LWI0MGY0YWIxZWFhZCIsInJldmlzaW9uIjoxLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwNzoyMDoyMy43NzlaIn0seyJmb2xkZXJfaWQiOiJhNWY2MTk4YS05ZmJlLTQ1MjgtYWM3ZC0xZjBkMzAxNTk5MjIiLCJpc19kZWxldGVkIjpmYWxzZSwibmFtZSI6IuyEpOygleynkSIsInBhcmVudF9mb2xkZXJfaWQiOiJlODdhMGU0NC05YThkLTRiMTgtYjk3NC1iNDBmNGFiMWVhYWQiLCJyZXZpc2lvbiI6MSwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDc6MjA6MjMuMzk4WiJ9LHsiZm9sZGVyX2lkIjoiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIiwiaXNfZGVsZXRlZCI6ZmFsc2UsIm5hbWUiOiLrqZTsnbgiLCJwYXJlbnRfZm9sZGVyX2lkIjpudWxsLCJyZXZpc2lvbiI6MSwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDc6MjA6MjIuNTM4WiJ9LHsiZm9sZGVyX2lkIjoiZWQyMWRlYWQtNzc5MC00Y2NmLWIyNWMtOTQzNTAxZTZmNmUzIiwiaXNfZGVsZXRlZCI6ZmFsc2UsIm5hbWUiOiLsnqXshowiLCJwYXJlbnRfZm9sZGVyX2lkIjoiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIiwicmV2aXNpb24iOjEsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA3OjIwOjI0LjE0MloifSx7ImZvbGRlcl9pZCI6ImY0YzkyNzkwLWQ2NzUtNDk3MC1iMWZjLWI5MGYzYTkyOWZmYiIsImlzX2RlbGV0ZWQiOmZhbHNlLCJuYW1lIjoi7JuQ6rOgIiwicGFyZW50X2ZvbGRlcl9pZCI6ImU4N2EwZTQ0LTlhOGQtNGIxOC1iOTc0LWI0MGY0YWIxZWFhZCIsInJldmlzaW9uIjoxLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwNzoyMDoyNC4wMzJaIn1dLCJvcmRlcnMiOlt7ImNoaWxkcmVuIjpbXSwicGFyZW50X2ZvbGRlcl9pZCI6ImVkMjFkZWFkLTc3OTAtNGNjZi1iMjVjLTk0MzUwMWU2ZjZlMyIsInJldmlzaW9uIjoxLCJ0cmVlX29yZGVyX2lkIjoiMWZhNDViZDYtYThjOS01MzRkLWIyNDgtMGEyZWNkNjdjMGM2IiwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDg6MDA6MDAuNjUyWiJ9LHsiY2hpbGRyZW4iOltdLCJwYXJlbnRfZm9sZGVyX2lkIjoiNGE3MWFjN2YtNDNiYi00OGU1LWEwYTktNDQ1MDhiZDQ2M2QwIiwicmV2aXNpb24iOjEsInRyZWVfb3JkZXJfaWQiOiIyZmM1YzAxNi1hNjYzLTU5YWYtYTAxNC02ZDI2Zjg3NGZkOWIiLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwODowMDowMC42NTJaIn0seyJjaGlsZHJlbiI6W10sInBhcmVudF9mb2xkZXJfaWQiOiJmNGM5Mjc5MC1kNjc1LTQ5NzAtYjFmYy1iOTBmM2E5MjlmZmIiLCJyZXZpc2lvbiI6MSwidHJlZV9vcmRlcl9pZCI6IjMxZWIwNmJlLTljYzktNTVkYi05YTA1LTU4ODIxNzI0NzRjZSIsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA4OjAwOjAwLjY1MloifSx7ImNoaWxkcmVuIjpbXSwicGFyZW50X2ZvbGRlcl9pZCI6IjhmMDY2ZDgwLTAzNzMtNDAwZC04OGU0LWI4MDllNjhlNzQ2MCIsInJldmlzaW9uIjoxLCJ0cmVlX29yZGVyX2lkIjoiM2VkYWMyNTItNmM5Zi01MjVhLWI1MzYtOGRmNTkxZDFiNzhhIiwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDg6MDA6MDAuNjUyWiJ9LHsiY2hpbGRyZW4iOltdLCJwYXJlbnRfZm9sZGVyX2lkIjoiNjczMjk2ZmMtMmIyYS00NTg5LWE5MjAtOThmYjFmNzM3MGYxIiwicmV2aXNpb24iOjEsInRyZWVfb3JkZXJfaWQiOiI0NDlmNmU2NC04ZjdmLTVjZjYtOTU1NC0xMWViYzAzZjU1ZjAiLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwODowMDowMC42NTJaIn0seyJjaGlsZHJlbiI6W10sInBhcmVudF9mb2xkZXJfaWQiOiJhMmQ5Zjc2MC0xYTQyLTRlYWQtYTJkMC01MTg3MGIwNjJmZDkiLCJyZXZpc2lvbiI6MSwidHJlZV9vcmRlcl9pZCI6Ijg5ZjJmN2RiLTRlMzgtNTQ1My1hY2IxLTkwMTc2ODBiOGEyOSIsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA4OjAwOjAwLjY1MloifSx7ImNoaWxkcmVuIjpbXSwicGFyZW50X2ZvbGRlcl9pZCI6Ijk1YjhlNGQwLTFkOGQtNGFmNS1iMTIxLTA4ODhkMDE1NzY2MSIsInJldmlzaW9uIjoxLCJ0cmVlX29yZGVyX2lkIjoiOWNhMzliMzYtYWFkNi01MzQ3LTk3YjktZmYwMGM5MjM0YWVhIiwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDg6MDA6MDAuNjUyWiJ9LHsiY2hpbGRyZW4iOlsiZTg3YTBlNDQtOWE4ZC00YjE4LWI5NzQtYjQwZjRhYjFlYWFkIl0sInBhcmVudF9mb2xkZXJfaWQiOm51bGwsInJldmlzaW9uIjoxLCJ0cmVlX29yZGVyX2lkIjoiYWRkMjA0YWMtZDFlMS01MmU2LWFhMmYtY2UxZTQyZDZmOGNjIiwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDg6MDA6MDAuNjUyWiJ9LHsiY2hpbGRyZW4iOltdLCJwYXJlbnRfZm9sZGVyX2lkIjoiYTVmNjE5OGEtOWZiZS00NTI4LWFjN2QtMWYwZDMwMTU5OTIyIiwicmV2aXNpb24iOjEsInRyZWVfb3JkZXJfaWQiOiJiYmQ5M2JmYS1lZjA4LTVlMTctODQyMi05ZDA4M2MwZmQ1ZjgiLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwODowMDowMC42NTJaIn0seyJjaGlsZHJlbiI6WyJmNGM5Mjc5MC1kNjc1LTQ5NzAtYjFmYy1iOTBmM2E5MjlmZmIiLCI1YTBhMWQ4OC0zYTk2LTQ2N2ItOTcxMS0wYmNlOWI2OWJlM2MiLCJhNWY2MTk4YS05ZmJlLTQ1MjgtYWM3ZC0xZjBkMzAxNTk5MjIiLCI5NWI4ZTRkMC0xZDhkLTRhZjUtYjEyMS0wODg4ZDAxNTc2NjEiLCI0YTcxYWM3Zi00M2JiLTQ4ZTUtYTBhOS00NDUwOGJkNDYzZDAiLCI2NzMyOTZmYy0yYjJhLTQ1ODktYTkyMC05OGZiMWY3MzcwZjEiLCI4ZjA2NmQ4MC0wMzczLTQwMGQtODhlNC1iODA5ZTY4ZTc0NjAiLCJlZDIxZGVhZC03NzkwLTRjY2YtYjI1Yy05NDM1MDFlNmY2ZTMiLCJhMmQ5Zjc2MC0xYTQyLTRlYWQtYTJkMC01MTg3MGIwNjJmZDkiLCIxMzE4Njc4NC0yZTU3LTRlMjktYjI4YS0xNzgzMDE2Nzk4MjQiXSwicGFyZW50X2ZvbGRlcl9pZCI6ImU4N2EwZTQ0LTlhOGQtNGIxOC1iOTc0LWI0MGY0YWIxZWFhZCIsInJldmlzaW9uIjoxLCJ0cmVlX29yZGVyX2lkIjoiYzA2NTVjNWYtOTdmMS01YjRiLWFjMjYtZDRmNjQxODlhMTgwIiwidXBkYXRlZF9hdCI6IjIwMjYtMDktMTBUMDg6MDA6MDAuNjUyWiJ9LHsiY2hpbGRyZW4iOltdLCJwYXJlbnRfZm9sZGVyX2lkIjoiMTMxODY3ODQtMmU1Ny00ZTI5LWIyOGEtMTc4MzAxNjc5ODI0IiwicmV2aXNpb24iOjEsInRyZWVfb3JkZXJfaWQiOiJjZWNiMjAxNi1lNzhhLTU0OGEtOGNhYy03YzU1Yzk4MTI1NzYiLCJ1cGRhdGVkX2F0IjoiMjAyNi0wOS0xMFQwODowMDowMC42NTJaIn0seyJjaGlsZHJlbiI6W10sInBhcmVudF9mb2xkZXJfaWQiOiI1YTBhMWQ4OC0zYTk2LTQ2N2ItOTcxMS0wYmNlOWI2OWJlM2MiLCJyZXZpc2lvbiI6MSwidHJlZV9vcmRlcl9pZCI6ImQ1MDYxMDAwLWY3ZGMtNTE5ZS04MDM3LWNkNTI4ZTAwMmY1ZSIsInVwZGF0ZWRfYXQiOiIyMDI2LTA5LTEwVDA4OjAwOjAwLjY1MloifV19")!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = format.date(from: value) else { throw GeneralValidationFailure.denied }
            return date
        }
        let archive = try decoder.decode(Archive.self, from: data)
        var baseline = Self(control: archive.control, folders: archive.folders, orders: archive.orders)
        baseline.timestampTolerance = 0.001
        try baseline.validate(); return baseline
    }
    func matches(_ lhs: SyncV2RemoteDocumentSnapshot, _ rhs: SyncV2RemoteDocumentSnapshot) throws -> Bool {
        try matchesFields(lhs, rhs, leftDate: lhs.updatedAt, rightDate: rhs.updatedAt)
    }
    func matches(_ lhs: SyncV2RemoteFolder, _ rhs: SyncV2RemoteFolder) throws -> Bool {
        try matchesFields(lhs, rhs, leftDate: lhs.updatedAt, rightDate: rhs.updatedAt)
    }
    func matches(_ lhs: SyncV2RemoteTreeOrder, _ rhs: SyncV2RemoteTreeOrder) throws -> Bool {
        try matchesFields(lhs, rhs, leftDate: lhs.updatedAt, rightDate: rhs.updatedAt)
    }
    private func matchesFields<T: Encodable>(_ lhs: T, _ rhs: T, leftDate: Date, rightDate: Date) throws -> Bool {
        let encoder = JSONEncoder()
        guard abs(leftDate.timeIntervalSince(rightDate)) <= timestampTolerance,
              var left = try JSONSerialization.jsonObject(with: encoder.encode(lhs)) as? [String: Any],
              var right = try JSONSerialization.jsonObject(with: encoder.encode(rhs)) as? [String: Any] else { return false }
        // Snapshot types have custom date encoders; compare the original Date
        // values above, before their ISO8601 encoders can round fractions.
        left.removeValue(forKey: "updated_at"); right.removeValue(forKey: "updated_at")
        return try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: right, options: [.sortedKeys])
    }
    static let controlID = UUID(uuidString: "6cbe47cd-67e5-5e27-8dbf-f3ae59255d52")!
    static let orderID = UUID(uuidString: "31eb06be-9cc9-55db-9a05-5882172474ce")!
    func validate() throws {
        guard timestampTolerance.isFinite, timestampTolerance >= 0, timestampTolerance <= 0.001,
              control.documentID == Self.controlID, control.revision == 1,
              control.relativePath == syncV2TreeOrderPath, control.parentFolderID == nil,
              control.name == nil, control.structureRevision == nil, !control.isDeleted, control.deletedAt == nil,
              control.content.utf8.count == 557,
              SHA256ContentHasher().sha256(for: Data(control.content.utf8)).rawValue == "e290f19f8c47350c5b9b6e7314aadea1477508174b770860040148280517e1f6",
              folders.count == 11, Set(folders.map(\.folderID)).count == 11,
              folders.allSatisfy({ $0.revision == 1 && !$0.isDeleted && !$0.name.isEmpty }),
              orders.count == 12, Set(orders.map(\.treeOrderID)).count == 12,
              Set(orders.map(\.parentFolderID)) == Set([nil] + folders.map { Optional($0.folderID) }),
              orders.allSatisfy({ $0.revision == 1 && Set($0.children).count == $0.children.count }),
              orders.first(where: { $0.treeOrderID == Self.orderID }).map({ $0.parentFolderID == GeneralValidationPlan.parent && $0.children.isEmpty }) == true,
              let parent = folders.first(where: { $0.folderID == GeneralValidationPlan.parent }), parent.name == "원고",
              let root = folders.first(where: { $0.folderID == parent.parentFolderID }), root.parentFolderID == nil, root.name == "메인"
        else { throw GeneralValidationFailure.denied }
        // Exactly the baseline folder children; no orphan, cycle or hidden entity.
        for order in orders {
            guard Set(order.children) == Set(folders.filter { $0.parentFolderID == order.parentFolderID }.map(\.folderID)) else { throw GeneralValidationFailure.denied }
        }
        for folder in folders {
            var cursor: UUID? = folder.folderID, visited = Set<UUID>()
            while let id = cursor {
                guard visited.insert(id).inserted, let next = folders.first(where: { $0.folderID == id }) else { throw GeneralValidationFailure.denied }
                cursor = next.parentFolderID
            }
        }
    }
}

/// Immutable validated data supplied to the ordinary pull service. Subsequent
/// manifest/body hydration reads this value and cannot issue additional GETs.
struct GeneralValidationRemoteSnapshot: SyncV2SnapshotClienting {
    private let documents: [SyncV2RemoteDocumentSnapshot]
    private let folders: [SyncV2RemoteFolder]
    private let orders: [SyncV2RemoteTreeOrder]
    static let columns = [
        "documents": "document_id,parent_folder_id,name,structure_revision,relative_path,content,revision,is_deleted,deleted_at,updated_at",
        "folders": "folder_id,parent_folder_id,name,revision,is_deleted,updated_at",
        "tree_orders": "tree_order_id,parent_folder_id,children,revision,updated_at"
    ]
    static func validateRequests(_ requests: [URLRequest]) throws {
        guard requests.count == 3, requests.compactMap({ $0.url?.lastPathComponent }) == ["documents", "folders", "tree_orders"] else { throw GeneralValidationFailure.denied }
        for request in requests {
            _ = try GeneralValidationExecution.Frozen(request: request, stage: .receiveWindows)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.first(where: { $0.name == "select" })?.value == columns[request.url!.lastPathComponent] else { throw GeneralValidationFailure.denied }
        }
    }
    init(stage: GeneralValidationPlan.Stage, data: [Data], baseline: GeneralValidationRemoteBaseline) throws {
        guard stage != .sendUpdate, data.count == 3 else { throw GeneralValidationFailure.denied }
        try baseline.validate()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw GeneralValidationFailure.denied }
            return date
        }
        documents = try decoder.decode([SyncV2RemoteDocumentSnapshot].self, from: data[0])
        folders = try decoder.decode([SyncV2RemoteFolder].self, from: data[1])
        orders = try decoder.decode([SyncV2RemoteTreeOrder].self, from: data[2])
        guard documents.count == 2, Set(documents.map(\.documentID)) == [GeneralValidationPlan.document, GeneralValidationRemoteBaseline.controlID],
              try documents.first(where: { $0.documentID == GeneralValidationRemoteBaseline.controlID }).map({ try baseline.matches($0, baseline.control) }) == true,
              folders.count == baseline.folders.count, Set(folders.map(\.folderID)).count == folders.count,
              try folders.allSatisfy({ row in try baseline.folders.contains(where: { try baseline.matches(row, $0) }) }),
              orders.count == baseline.orders.count, Set(orders.map(\.treeOrderID)).count == orders.count,
              let target = documents.first(where: { $0.documentID == GeneralValidationPlan.document }),
              !target.isDeleted, target.deletedAt == nil, target.parentFolderID == GeneralValidationPlan.parent,
              target.name == GeneralValidationPlan.name, target.structureRevision == 1,
              target.relativePath == "메인/원고/" + GeneralValidationPlan.name,
              target.revision == (stage == .receiveWindows ? GeneralValidationPlan.incomingRevision : GeneralValidationPlan.finalRevision),
              Data(target.content.utf8) == Data((stage == .receiveWindows ? GeneralValidationPlan.incoming : GeneralValidationPlan.final).utf8)
        else { throw GeneralValidationFailure.denied }
        for order in orders {
            if order.treeOrderID == GeneralValidationRemoteBaseline.orderID {
                guard order.parentFolderID == GeneralValidationPlan.parent, order.revision == 2,
                      order.children == [GeneralValidationPlan.document] else { throw GeneralValidationFailure.denied }
            } else { guard try baseline.orders.contains(where: { try baseline.matches(order, $0) }) else { throw GeneralValidationFailure.denied } }
        }
    }
    private func check(_ project: UUID) throws {
        guard project == GeneralValidationPlan.server else { throw GeneralValidationFailure.denied }
    }
    func fetchDocuments(projectID: UUID) async throws -> [SyncV2RemoteDocumentSnapshot] { try check(projectID); return documents }
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] { try check(projectID); return folders }
    func fetchTreeOrders(projectID: UUID) async throws -> [SyncV2RemoteTreeOrder] { try check(projectID); return orders }
}

/// Internal one-stage runner. No default transport, app entry point, authentication
/// grant, dispatcher start, retries, lease or compensation. Its product adapters
/// must run the ordinary compared-save/claim/apply/complete operations under the
/// supplied mutation authorization and the existing independent receive locks.
actor GeneralValidationStageService {
    typealias Exchange = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let root: URL
    private let exchange: Exchange
    private let current: @Sendable () throws -> Void
    private var used = false
    init(root: URL, exchange: @escaping Exchange, current: @escaping @Sendable () throws -> Void) {
        self.root = root; self.exchange = exchange; self.current = current
    }
    private func reserve(stage: GeneralValidationPlan.Stage, transition: GeneralValidationLocalTransition) throws -> GeneralValidationJournal {
        guard !used else { throw GeneralValidationFailure.denied }
        used = true
        try current(); try transition.require(stage: stage)
        return try GeneralValidationJournal(root: root, stage: stage)
    }
    func receive(stage: GeneralValidationPlan.Stage, requests: [URLRequest], bearer: String,
                 baseline: GeneralValidationRemoteBaseline, transition: GeneralValidationLocalTransition,
                 apply: @Sendable (GeneralValidationRemoteSnapshot, @escaping @Sendable () throws -> Void) async throws -> SyncV2SnapshotPullReport) async throws {
        guard stage != .sendUpdate else { throw GeneralValidationFailure.denied }
        try baseline.validate(); try GeneralValidationRemoteSnapshot.validateRequests(requests)
        let reservation = try reserve(stage: stage, transition: transition)
        var execution: GeneralValidationExecution?
        do {
            let run = try GeneralValidationExecution(root: root, stage: stage, requests: requests, bearer: bearer,
                checkCurrent: current, checkLocal: { try transition.check() }, reservation: reservation)
            execution = run
            var data: [Data] = []
            for request in requests {
                let response = try await GeneralValidationExecution.$current.withValue(run) { try await exchange(request) }
                data.append(response.0)
            }
            try run.requireAcceptedPayloads(data)
            let snapshot = try GeneralValidationRemoteSnapshot(stage: stage, data: data, baseline: baseline)
            let report = try await transition.advance { authorize in try await apply(snapshot, authorize) }
            guard report.contractStructureBaselineReady, !report.hasDeferredLocalApplication,
                  report.rejectedStructureNames.isEmpty, report.pendingChildTombstoneFolderCount == 0,
                  !report.outcomes.contains(where: { if case .mergeRequired = $0 { true } else { false } }) else { throw GeneralValidationFailure.denied }
            try run.completeAfterLocalValidation { try transition.requireFinished() }
        } catch {
            transition.stop()
            if let execution { execution.stop() } else { try? reservation.append(.stopped, sequence: 0) }
            throw error
        }
    }
    func send(bearer: String, transition: GeneralValidationLocalTransition,
              saveAndCaptureRequest: @Sendable (@escaping @Sendable () throws -> Void) async throws -> URLRequest,
              finish: @Sendable (SyncV2JSON, @escaping @Sendable () throws -> Void) async throws -> Void) async throws {
        // Persist before local save. A crash after save but before request capture
        // leaves this reservation, so a new instance cannot save/send again.
        let reservation = try reserve(stage: .sendUpdate, transition: transition)
        var execution: GeneralValidationExecution?
        do {
            let request = try await transition.advance(saveAndCaptureRequest)
            let run = try GeneralValidationExecution(root: root, stage: .sendUpdate, requests: [request], bearer: bearer,
                checkCurrent: current, checkLocal: { try transition.check() }, reservation: reservation)
            execution = run
            let response = try await GeneralValidationExecution.$current.withValue(run) { try await exchange(request) }
            try run.requireAcceptedPayloads([response.0])
            let json = try JSONDecoder().decode(SyncV2JSON.self, from: response.0)
            // Validate the same response again before passing it to local completion.
            guard let contract = try GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate).contract,
                  try SyncV2Contract.validateDocumentCommitResponse(request: contract, response: json) == .committed,
                  json.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"] == .int(Int(GeneralValidationPlan.outgoingRevision)) else { throw GeneralValidationFailure.denied }
            try await transition.advance { authorize in try await finish(json, authorize) }
            try run.completeAfterLocalValidation { try transition.requireFinished() }
        } catch {
            transition.stop()
            if let execution { execution.stop() } else { try? reservation.append(.stopped, sequence: 0) }
            throw error
        }
    }
}
