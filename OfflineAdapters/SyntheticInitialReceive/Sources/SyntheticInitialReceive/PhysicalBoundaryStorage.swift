import Foundation
import Darwin

struct PhysicalStorageAccess {
    var check: () throws -> Void = {}
    var created: (URL) throws -> Void = { _ in }
    var verify: (URL) throws -> Void = { _ in }
}

public enum PhysicalStorageError: String, Error {
    case lockRequired, unexpectedData, incompleteCommit, chain, transition, binding, io
}

/// Disposable host storage only. Each part has its own immutable file; nine state records
/// form a hash chain. An atomic head is the commit point. Orphan/pending data is never repaired.
public final class PhysicalBoundaryStorage: LocalBoundaryStorage {
    struct Record: Codable, Equatable {
        let version: Int
        let sequence: Int
        let previousHash: String
        let binding: LocalBoundaryBinding
        let phase: LocalBoundaryPhase
        let parts: [String: DigestEntry]
        let completionDigest: String?
    }
    struct Head: Codable { let version: Int; let sequence: Int; let recordHash: String }
    struct Loaded { let view: LocalStorageView; let record: Record?; let hash: String }

    public let root: URL
    private let workspace: URL
    private let protectedRelativeBinding: Bool
    private let expected: LocalBoundaryBinding
    private let checkpoint: (String) throws -> Void
    private let access: PhysicalStorageAccess
    private let validateWorkspace: () throws -> Void
    private let localLock = NSLock()
    private let ownershipLock = NSLock()
    private var owner: pthread_t?

    // Construction does not create directories, locks or files. Public callers use preparePhysical.
    init(workspace: URL, binding: LocalBoundaryBinding, checkpoint: @escaping (String) throws -> Void = { _ in },
         validateWorkspace: (() throws -> Void)? = nil, access: PhysicalStorageAccess = .init(), protectedContainer: ProtectedBoundaryContainer? = nil) throws {
        let validation = validateWorkspace ?? { _ = try SyntheticAdapter(workspace: workspace) }
        try validation()
        self.validateWorkspace = validation; self.access = access
        self.workspace = workspace
        root = workspace.appendingPathComponent("physical-boundary", isDirectory: true)
        protectedRelativeBinding = protectedContainer != nil
        if let container = protectedContainer {
            try container.validate(workspace)
            guard binding.version == 2, binding.declaredBundle == ProtectedBoundaryContainer.bundleID,
                  binding.root == ProtectedBoundaryContainer.relativeWorkspace + "/physical-boundary" else { throw PhysicalStorageError.binding }
        } else {
            guard binding.root == root.path else { throw PhysicalStorageError.binding }
        }
        expected = binding; self.checkpoint = checkpoint
    }

    public func withExclusiveAccess(_ operation: () throws -> Void) throws {
        guard localLock.try() else { throw ReceiveError.busy }
        defer { localLock.unlock() }
        try access.check(); try validateWorkspace()
        try SafeFiles.checked(workspace); try SafeFiles.checked(root)
        // Recheck the old namespace under the physical lock as well as before construction.
        guard try SafeFiles.attributes(workspace.appendingPathComponent("store")) == nil else { throw LocalBoundaryError.protectedData }
        let lockURL = workspace.appendingPathComponent("physical-boundary.lock")
        try SafeFiles.checked(lockURL)
        let existed = try SafeFiles.attributes(lockURL) != nil
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageDiagnostics.posix(PhysicalStorageError.io, .openLock, errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw StorageDiagnostics.posix(ReceiveError.path, .fstat, errno) }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size == 0 else { throw ReceiveError.path }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StorageDiagnostics.posix(ReceiveError.busy, .flock, errno) }
        defer { flock(fd, LOCK_UN) }
        if !existed { try access.created(lockURL) }
        try access.verify(lockURL); try access.check()
        guard let current = try SafeFiles.attributes(lockURL), current.st_ino == info.st_ino,
              current.st_dev == info.st_dev else { throw ReceiveError.path }
        ownershipLock.lock(); owner = pthread_self(); ownershipLock.unlock()
        defer { ownershipLock.lock(); owner = nil; ownershipLock.unlock() }
        try checkpoint("locked")
        try operation()
        try access.check()
    }

    private func requireLock() throws {
        ownershipLock.lock()
        defer { ownershipLock.unlock() }
        guard let owner = owner, pthread_equal(owner, pthread_self()) != 0 else { throw PhysicalStorageError.lockRequired }
        try access.check()
    }
    private func recordName(_ sequence: Int) -> String { String(format: "record-%02d.json", sequence) }
    private func partName(_ part: LocalStoragePart) -> String { "part-" + part.rawValue + ".bin" }
    private func syncDirectory(_ directory: URL) throws {
        try SafeFiles.checked(directory)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDiagnostics.posix(PhysicalStorageError.io, .openDirectory, errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw StorageDiagnostics.posix(PhysicalStorageError.io, .fsync, errno) }
    }

    private func acceptedBinding(_ stored: LocalBoundaryBinding, complete: Bool) -> Bool {
        if stored == expected { return true }
        guard protectedRelativeBinding, complete, stored.version == 1 else { return false }
        let suffix = "/physical-boundary"
        guard stored.root.hasSuffix(suffix) else { return false }
        let workspacePath = String(stored.root.dropLast(suffix.count))
        guard ProtectedBoundaryContainer.validLegacyWorkspace(workspacePath) else { return false }
        let normalized = LocalBoundaryBinding(version:2, declaredBundle:stored.declaredBundle, root:expected.root,
            localIdentity:stored.localIdentity, sourceIdentity:stored.sourceIdentity, fixtureID:stored.fixtureID,
            inputDigest:stored.inputDigest, resultDigest:stored.resultDigest)
        return normalized == expected
    }

    private func load() throws -> Loaded {
        try requireLock()
        guard try SafeFiles.attributes(workspace.appendingPathComponent("store")) == nil else { throw LocalBoundaryError.protectedData }
        guard try SafeFiles.attributes(root) != nil else {
            return Loaded(view: LocalStorageView(hasUnsentDraft: false, hasUnexpectedData: false), record: nil, hash: "")
        }
        let inventory = try SafeFiles.inventory(root)
        try access.verify(root)
        for name in inventory.files { try access.check(); try access.verify(root.appendingPathComponent(name)) }
        guard inventory.directories.isEmpty, inventory.files.contains("head.json") else { throw PhysicalStorageError.incompleteCommit }
        let head = try decodeExact(Head.self, SafeFiles.read(root.appendingPathComponent("head.json"), limit: 1024))
        guard head.version == 1, (1...9).contains(head.sequence) else { throw PhysicalStorageError.chain }
        var previous: Record?, previousHash = ""
        var permitted: Set<String> = ["head.json"]
        for sequence in 1...head.sequence {
            let name = recordName(sequence); permitted.insert(name)
            let raw = try SafeFiles.read(root.appendingPathComponent(name), limit: 65536)
            let record = try decodeExact(Record.self, raw)
            guard record.version == 1, record.sequence == sequence, record.previousHash == previousHash,
                  acceptedBinding(record.binding, complete: head.sequence == 9),
                  previous == nil || previous?.binding == record.binding else { throw PhysicalStorageError.chain }
            let count = min(max(sequence - 2, 0), 5)
            let expectedParts = Set(LocalStoragePart.allCases.prefix(count).map(\.rawValue))
            guard Set(record.parts.keys) == expectedParts,
                  record.phase == (sequence == 1 ? .bound : (sequence == 9 ? .syntheticReady : .applying)),
                  record.completionDigest == (sequence >= 8 ? expected.resultDigest : nil) else { throw PhysicalStorageError.transition }
            for (part, entry) in record.parts {
                guard let kind = LocalStoragePart(rawValue: part), entry.path == partName(kind),
                      entry.bytes >= 0, entry.bytes <= 20 * 1024 * 1024,
                      previous?.parts[part] == nil || previous?.parts[part] == entry else { throw PhysicalStorageError.transition }
                permitted.insert(entry.path)
            }
            previous = record; previousHash = byteHash(raw)
        }
        guard head.recordHash == previousHash, inventory.files == permitted, let last = previous else { throw PhysicalStorageError.unexpectedData }
        var data: [LocalStoragePart: Data] = [:]
        for (name, entry) in last.parts {
            try access.check()
            let raw = try SafeFiles.read(root.appendingPathComponent(entry.path))
            guard raw.count == entry.bytes, byteHash(raw) == entry.sha256 else { throw LocalBoundaryError.content }
            data[LocalStoragePart(rawValue: name)!] = raw
        }
        // Only the in-memory view is normalized, after original-byte chain and payload checks.
        // A legacy chain is accepted only when complete, so no new record can extend it.
        let view = LocalStorageView(binding: expected, phase: last.phase, parts: data,
            completionDigest: last.completionDigest, hasUnsentDraft: false, hasUnexpectedData: false)
        try access.check()
        return Loaded(view: view, record: last, hash: previousHash)
    }

    public func read() throws -> LocalStorageView { try load().view }

    private func writeFile(_ data: Data, name: String, replacingHead: Bool = false) throws {
        try requireLock()
        let destination = root.appendingPathComponent(name)
        try SafeFiles.checked(destination)
        let existing = try SafeFiles.attributes(destination)
        guard replacingHead || existing == nil else { throw PhysicalStorageError.unexpectedData }
        try checkpoint("before:" + name)
        try SafeFiles.write(data, to: destination, prepareFile: { url in
            try self.access.check(); try self.access.created(url); try self.access.verify(url); try self.access.check()
        }) { stage in
            try self.access.check(); try self.checkpoint(stage); try self.access.check()
        }
        // SafeFiles synchronizes file and parent before this checkpoint.
        try access.check(); try access.verify(destination)
        guard try SafeFiles.read(destination) == data else { throw LocalBoundaryError.writeNotObserved }
        try checkpoint("written:" + name)
    }

    private func commit(_ record: Record, from old: Loaded) throws {
        guard record.sequence == (old.record?.sequence ?? 0) + 1, record.sequence <= 9 else { throw PhysicalStorageError.transition }
        let raw = try canonical(record)
        try writeFile(raw, name: recordName(record.sequence))
        try writeFile(try canonical(Head(version: 1, sequence: record.sequence, recordHash: byteHash(raw))),
                      name: "head.json", replacingHead: old.record != nil)
        // Only the published head plus full chain/part readback makes a commit observable.
        guard try load().record == record else { throw LocalBoundaryError.writeNotObserved }
        try checkpoint("committed:" + String(record.sequence))
    }

    public func bind(_ binding: LocalBoundaryBinding) throws {
        let old = try load()
        guard binding == expected, old.record == nil else { throw PhysicalStorageError.binding }
        // An already existing empty/partial root never reaches here through load().
        guard mkdir(root.path, 0o700) == 0 else { throw StorageDiagnostics.posix(PhysicalStorageError.io, .mkdir, errno) }
        try access.created(root); try access.verify(root); try access.check()
        try syncDirectory(workspace)
        try checkpoint("created-root")
        try commit(Record(version: 1, sequence: 1, previousHash: "", binding: expected,
            phase: .bound, parts: [:], completionDigest: nil), from: old)
    }

    public func setPhase(_ phase: LocalBoundaryPhase) throws {
        let old = try load()
        guard let previous = old.record,
              (phase == .applying && previous.sequence == 1) || (phase == .syntheticReady && previous.sequence == 8) else { throw PhysicalStorageError.transition }
        try commit(Record(version: 1, sequence: previous.sequence + 1, previousHash: old.hash, binding: expected,
            phase: phase, parts: previous.parts, completionDigest: previous.completionDigest), from: old)
    }

    public func write(_ data: Data, part: LocalStoragePart) throws {
        let old = try load()
        guard let previous = old.record, (2...6).contains(previous.sequence),
              LocalStoragePart.allCases[previous.sequence - 2] == part, data.count <= 20 * 1024 * 1024 else { throw PhysicalStorageError.transition }
        let name = partName(part)
        try writeFile(data, name: name)
        var parts = previous.parts
        parts[part.rawValue] = DigestEntry(path: name, bytes: data.count, sha256: byteHash(data))
        try commit(Record(version: 1, sequence: previous.sequence + 1, previousHash: old.hash, binding: expected,
            phase: .applying, parts: parts, completionDigest: nil), from: old)
    }

    public func setCompletion(_ digest: String) throws {
        let old = try load()
        guard let previous = old.record, previous.sequence == 7, digest == expected.resultDigest else { throw PhysicalStorageError.transition }
        try commit(Record(version: 1, sequence: 8, previousHash: old.hash, binding: expected,
            phase: .applying, parts: previous.parts, completionDigest: digest), from: old)
    }
}
