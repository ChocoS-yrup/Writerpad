import Foundation
import Darwin

public struct SyntheticReceipt: Encodable, Equatable {
    public let synthetic_applied: Bool
    public let input_digest: String
    public let baseline_ready = false
    public let baseline_applied = false
    public let execution_allowed = false
    public let app_binding_created = false
}

public struct SyntheticSnapshot {
    public let receipt: SyntheticReceipt
    public let files: [String: Data]
}

enum Phase: String, Codable { case bound, staged, validated, applying, syntheticApplied }
struct Binding: Codable, Equatable {
    let kind: String
    let root: String
    let localIdentity: String
    let sourceIdentity: String
    let fixtureID: String
    let inputDigest: String
    let resultDigest: String
}
struct Journal: Codable, Equatable { let binding: Binding; var phase: Phase }

/// Only the host's disposable SyntheticInitialReceive-<UUID>/store namespace is supported.
/// No app storage, transport, authentication, editor, job or real baseline API is linked.
public final class SyntheticAdapter {
    public let root: URL
    private let workspace: URL
    private let checkpoint: (String) throws -> Void

    public init(workspace: URL, checkpoint: @escaping (String) throws -> Void = { _ in }) throws {
        try SafeFiles.checked(workspace)
        let allowed = [try SafeFiles.temporaryPath(), "/private/tmp"]
        try require(allowed.contains(workspace.deletingLastPathComponent().path), .path)
        let prefix = "SyntheticInitialReceive-"
        try require(workspace.lastPathComponent.hasPrefix(prefix) && UUID(uuidString: String(workspace.lastPathComponent.dropFirst(prefix.count))) != nil, .path)
        guard let info = try SafeFiles.attributes(workspace), info.st_mode & S_IFMT == S_IFDIR else { throw ReceiveError.path }
        self.workspace = workspace
        self.root = workspace.appendingPathComponent("store", isDirectory: true)
        self.checkpoint = checkpoint
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try SafeFiles.checked(workspace)
        try SafeFiles.checked(root)
        let url = workspace.appendingPathComponent("store.lock")
        try SafeFiles.checked(url)
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReceiveError.io }
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_size == 0, .path)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ReceiveError.busy }
        defer { flock(fd, LOCK_UN) }
        try checkpoint("locked")
        return try action()
    }

    private func binding(_ input: SyntheticInput) throws -> Binding {
        let entries = input.outputs.keys.sorted().map { DigestEntry(path: $0, bytes: input.outputs[$0]!.count, sha256: byteHash(input.outputs[$0]!)) }
        return Binding(kind: "synthetic-store-v1", root: root.path,
                       localIdentity: input.manifest.localIdentity, sourceIdentity: input.manifest.sourceIdentity,
                       fixtureID: input.manifest.fixtureID, inputDigest: input.digest, resultDigest: byteHash(try canonical(entries)))
    }

    private func stageFiles(_ input: SyntheticInput) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: input.sourceFiles.map { ("staging/" + $0.key, $0.value) })
    }
    private func resultFiles(_ input: SyntheticInput) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: input.outputs.map { ("result/" + $0.key, $0.value) })
    }
    private func outputDirectories(_ input: SyntheticInput) -> Set<String> {
        Set(input.manifest.nodes.filter { $0.kind == "folder" }.map { "result/tree/" + $0.path })
    }

    private func load(_ expected: Binding) throws -> Journal {
        guard try SafeFiles.attributes(root.appendingPathComponent("owner.json")) != nil,
              try SafeFiles.attributes(root.appendingPathComponent("journal.json")) != nil else { throw ReceiveError.corrupt }
        let owner = try decodeExact(Binding.self, SafeFiles.read(root.appendingPathComponent("owner.json")))
        let journal = try decodeExact(Journal.self, SafeFiles.read(root.appendingPathComponent("journal.json")))
        try require(owner == expected && journal.binding == expected, .identity)
        return journal
    }

    private func audit(_ input: SyntheticInput, _ journal: Journal) throws {
        let stage = stageFiles(input), outputs = resultFiles(input)
        var permitted = stage
        permitted["owner.json"] = try canonical(journal.binding)
        permitted["journal.json"] = try canonical(journal)
        var dirs = SafeFiles.parents(of: Set(permitted.keys))
        if [.applying, .syntheticApplied].contains(journal.phase) {
            permitted.merge(outputs) { a, _ in a }
            permitted["complete.json"] = try canonical(journal.binding)
            dirs.formUnion(SafeFiles.parents(of: Set(permitted.keys)))
            dirs.formUnion(outputDirectories(input))
        }
        let actual = try SafeFiles.inventory(root)
        try require(actual.files.isSubset(of: Set(permitted.keys)) && actual.directories.isSubset(of: dirs), .existingData)
        for path in actual.files {
            try require(try SafeFiles.read(root.appendingPathComponent(path)) == permitted[path], .corrupt)
        }
        if journal.phase != .bound {
            try require(Set(stage.keys).isSubset(of: actual.files), .incomplete)
        }
        if actual.files.contains("complete.json") || journal.phase == .syntheticApplied {
            try require(Set(outputs.keys).union(["complete.json"]).isSubset(of: actual.files), .incomplete)
            try require(outputDirectories(input).isSubset(of: actual.directories), .incomplete)
        }
    }

    private func putNew(_ path: String, _ data: Data) throws {
        let url = root.appendingPathComponent(path)
        if try SafeFiles.attributes(url) != nil {
            try require(try SafeFiles.read(url) == data, .corrupt)
        } else {
            try SafeFiles.write(data, to: url, checkpoint: checkpoint)
            try checkpoint("written:" + path)
        }
    }
    private func transition(_ phase: Phase, _ journal: inout Journal) throws {
        journal.phase = phase
        try SafeFiles.write(try canonical(journal), to: root.appendingPathComponent("journal.json"), checkpoint: checkpoint)
        try checkpoint("phase:" + phase.rawValue)
    }

    @discardableResult
    public func apply(_ input: SyntheticInput) throws -> SyntheticReceipt {
        try locked {
            let expected = try binding(input)
            if try SafeFiles.attributes(root) == nil { try SafeFiles.mkdir(root) }
            let inventory = try SafeFiles.inventory(root)
            if inventory.files.isEmpty && inventory.directories.isEmpty {
                try putNew("owner.json", canonical(expected))
                try putNew("journal.json", canonical(Journal(binding: expected, phase: .bound)))
            }
            var journal = try load(expected)
            try audit(input, journal)
            if journal.phase == .bound {
                for path in stageFiles(input).keys.sorted() { try putNew(path, stageFiles(input)[path]!) }
                try transition(.staged, &journal)
            }
            try audit(input, journal)
            if journal.phase == .staged { try transition(.validated, &journal) }
            if journal.phase == .validated { try transition(.applying, &journal) }
            if journal.phase == .applying {
                for path in outputDirectories(input).sorted() { try SafeFiles.mkdir(root.appendingPathComponent(path)) }
                let outputs = resultFiles(input)
                for path in outputs.keys.sorted() { try putNew(path, outputs[path]!) }
                try audit(input, journal)
                try putNew("complete.json", canonical(expected))
                try transition(.syntheticApplied, &journal)
            }
            try audit(input, journal)
            return SyntheticReceipt(synthetic_applied: true, input_digest: input.digest)
        }
    }

    public func snapshot(for input: SyntheticInput) throws -> SyntheticSnapshot {
        try locked {
            let journal = try load(binding(input))
            try audit(input, journal)
            try require(journal.phase == .syntheticApplied, .incomplete)
            var files: [String: Data] = [:]
            for path in input.outputs.keys { files[path] = try SafeFiles.read(root.appendingPathComponent("result/" + path)) }
            return SyntheticSnapshot(receipt: SyntheticReceipt(synthetic_applied: true, input_digest: input.digest), files: files)
        }
    }
}
