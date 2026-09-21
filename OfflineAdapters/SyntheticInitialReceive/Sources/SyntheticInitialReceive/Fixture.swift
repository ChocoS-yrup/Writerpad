import Foundation
import CryptoKit

public enum ReceiveError: String, Error {
    case schema, identity, body, structure, path, existingData, corrupt, incomplete, busy, io
}

func require(_ condition: @autoclosure () throws -> Bool, _ error: ReceiveError) throws {
    if try !condition() { throw error }
}

public func byteHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// This is a new internal format, not Windows' canonical journal encoding.
public func canonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(10)
    return data
}

func decodeExact<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
    let result: T
    do { result = try JSONDecoder().decode(type, from: data) }
    catch { throw ReceiveError.schema }
    // Unknown/duplicate keys and alternate numeric representations cannot be silently dropped.
    try require(try canonical(result) == data, .schema)
    return result
}

public struct FixtureManifest: Codable, Equatable {
    public struct Node: Codable, Equatable {
        public var id: String
        public var kind: String
        public var parent: String?
        public var name: String
        public var path: String
        public var revision: Int
    }
    public struct Order: Codable, Equatable {
        public var parent: String
        public var children: [String]
        public var revision: Int
    }
    public struct Body: Codable, Equatable {
        public var node: String
        public var file: String
        public var bytes: Int
        public var sha256: String
    }
    public var version: Int
    public var kind: String
    public var fixtureID: String
    public var localIdentity: String
    public var sourceIdentity: String
    public var root: String
    public var expectedNodes: [String]
    public var expectedDocuments: [String]
    public var expectedOrders: [String]
    public var nodes: [Node]
    public var orders: [Order]
    public var bodies: [Body]
}

public struct SyntheticInput {
    public let manifest: FixtureManifest
    public let digest: String
    let sourceFiles: [String: Data]
    let outputs: [String: Data]

    public init(files: [String: Data]) throws {
        try require(files.count <= 70 && files.values.allSatisfy { $0.count <= 4 * 1024 * 1024 }, .schema)
        try require(files.values.reduce(0) { $0 + $1.count } <= 16 * 1024 * 1024, .schema)
        guard let original = files["manifest.json"] else { throw ReceiveError.schema }
        let m = try decodeExact(FixtureManifest.self, original)
        try require(m.version == 1 && m.kind == "synthetic-initial-receive-v1", .schema)
        func id(_ value: String, _ prefix: String) -> Bool {
            value.hasPrefix(prefix) && UUID(uuidString: String(value.dropFirst(prefix.count)))?.uuidString.lowercased() == String(value.dropFirst(prefix.count))
        }
        try require(id(m.fixtureID, "fixture-") && id(m.localIdentity, "local-") && id(m.sourceIdentity, "source-"), .identity)
        try require(!m.nodes.isEmpty && m.nodes.count <= 64, .structure)
        try require(Set(m.nodes.map(\.id)).count == m.nodes.count, .structure)
        let nodes = Dictionary(uniqueKeysWithValues: m.nodes.map { ($0.id, $0) })
        try require(m.nodes.allSatisfy { id($0.id, "node-") && $0.revision > 0 && ["folder", "document"].contains($0.kind) }, .structure)
        func exact(_ list: [String], _ expected: Set<String>) -> Bool {
            Set(list).count == list.count && Set(list) == expected
        }
        let folders = Set(m.nodes.filter { $0.kind == "folder" }.map(\.id))
        let documents = Set(m.nodes.filter { $0.kind == "document" }.map(\.id))
        try require(exact(m.expectedNodes, Set(nodes.keys)) && exact(m.expectedDocuments, documents) && exact(m.expectedOrders, folders), .structure)
        try require(nodes[m.root]?.kind == "folder" && nodes[m.root]?.parent == nil, .structure)
        var collisionKeys = Set<String>()
        for node in m.nodes {
            try validateComponent(node.name)
            var parts = [node.name], visited: Set<String> = [node.id], current = node
            while let parent = current.parent {
                guard let next = nodes[parent], next.kind == "folder", visited.insert(parent).inserted else { throw ReceiveError.structure }
                parts.insert(next.name, at: 0)
                current = next
            }
            try require(current.id == m.root, .structure)
            try require(parts.joined(separator: "/") == node.path, .path)
            let key = node.path.precomposedStringWithCanonicalMapping.lowercased()
            try require(collisionKeys.insert(key).inserted, .path)
        }
        try require(exact(m.orders.map(\.parent), folders), .structure)
        for order in m.orders {
            try require(order.revision > 0 && exact(order.children, Set(m.nodes.filter { $0.parent == order.parent }.map(\.id))), .structure)
        }
        try require(exact(m.bodies.map(\.node), documents), .body)
        try require(Set(m.bodies.map(\.file)).count == m.bodies.count, .body)
        try require(Set(files.keys) == Set(["manifest.json"] + m.bodies.map(\.file)), .body)
        var output: [String: Data] = [:]
        for body in m.bodies {
            try require(body.file == "bodies/\(body.node).txt", .path)
            guard let data = files[body.file], let node = nodes[body.node] else { throw ReceiveError.body }
            try require(body.bytes == data.count && body.sha256 == byteHash(data) && String(data: data, encoding: .utf8) != nil, .body)
            output["tree/" + node.path] = data
        }
        self.manifest = m
        self.sourceFiles = files
        // Hash list includes the original manifest bytes. Sorted array avoids dictionary order dependence.
        let entries = files.keys.sorted().map { DigestEntry(path: $0, bytes: files[$0]!.count, sha256: byteHash(files[$0]!)) }
        self.digest = byteHash(try canonical(entries))
        output["metadata.json"] = try canonical(m.nodes)
        output["orders.json"] = try canonical(m.orders)
        output["synthetic-base.json"] = try canonical(SyntheticBase(kind: "synthetic-only", inputDigest: digest, manifest: m))
        self.outputs = output
    }

    public static func load(directory: URL) throws -> Self {
        let entries = try SafeFiles.inventory(directory)
        try require(entries.files.count <= 70, .schema)
        var files: [String: Data] = [:]
        for path in entries.files { files[path] = try SafeFiles.read(directory.appendingPathComponent(path), limit: 4 * 1024 * 1024) }
        let input = try Self(files: files)
        try require(entries.directories == SafeFiles.parents(of: Set(files.keys)), .path)
        return input
    }
}

struct DigestEntry: Codable, Equatable { let path: String; let bytes: Int; let sha256: String }
struct SyntheticBase: Codable { let kind: String; let inputDigest: String; let manifest: FixtureManifest }

func validateComponent(_ value: String) throws {
    try require(!value.isEmpty && value.utf8.count <= 120 && value != "." && value != "..", .path)
    try require(!value.contains("/") && !value.contains("\\") && !value.contains(":"), .path)
    try require(!value.lowercased().hasSuffix(".pending"), .path)
    try require(value.last != "." && value.last != " " && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, .path)
}
