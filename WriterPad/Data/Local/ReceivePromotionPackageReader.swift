import CryptoKit
import Darwin
import Foundation

enum ReceivePromotionPackageError: Error, Equatable, LocalizedError, Sendable {
    case invalidPackageType
    case invalidStructure(String)
    case unsafeEntry(String)
    case invalidManifest
    case invalidSeal
    case invalidPayload(String)
    case invalidName(String)
    case sizeLimit

    var errorDescription: String? {
        switch self {
        case .invalidPackageType:
            "수신 편집본 package 형식이 아닙니다."
        case let .invalidStructure(path):
            "package 구성이 계약과 다릅니다: \(path)"
        case let .unsafeEntry(path):
            "링크 또는 안전하지 않은 파일을 포함합니다: \(path)"
        case .invalidManifest:
            "manifest.json이 canonical 계약과 다릅니다."
        case .invalidSeal:
            "seal.json 또는 package 무결성 값이 일치하지 않습니다."
        case let .invalidPayload(path):
            "본문 파일의 크기·SHA-256·UTF-8이 일치하지 않습니다: \(path)"
        case let .invalidName(name):
            "WriterPad에서 사용할 수 없는 이름입니다: \(name)"
        case .sizeLimit:
            "package 크기 또는 문서 수 상한을 넘었습니다."
        }
    }
}

/// Reads a user-selected package without changing it or any WriterPad state.
actor ReceivePromotionPackageReader: ReceivePromotionPackageMaterializing {
    private static let manifestFormat = "writerpad-receive-promotion-v1"
    private static let sealFormat = "writerpad-receive-promotion-seal-v1"
    private static let producerBundleID = "com.chocos.writerpad.receiveboundary"
    private static let maximumDocuments = 4_096
    private static let maximumDocumentBytes = 4 * 1_024 * 1_024
    private static let maximumPayloadBytes = 16 * 1_024 * 1_024
    private static let maximumManifestBytes = 2 * 1_024 * 1_024
    private static let maximumSealBytes = 2 * 1_024 * 1_024

    private let fileManager: FileManager
    private let pathPolicy: PathPolicy
    private let hasher: any ContentHashing

    init(
        fileManager: FileManager = .default,
        pathPolicy: PathPolicy = PathPolicy(),
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.fileManager = fileManager
        self.pathPolicy = pathPolicy
        self.hasher = hasher
    }

    func inspect(_ packageURL: URL) async throws -> ReceivePromotionReport {
        try await materialize(packageURL).report
    }

    func materialize(
        _ packageURL: URL
    ) async throws -> ReceivePromotionValidatedPackage {
        let didStart = packageURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { packageURL.stopAccessingSecurityScopedResource() }
        }
        return try materializeOpened(packageURL.standardizedFileURL)
    }

    private func materializeOpened(
        _ root: URL
    ) throws -> ReceivePromotionValidatedPackage {
        guard root.pathExtension.lowercased() == "writerpadpromotion" else {
            throw ReceivePromotionPackageError.invalidPackageType
        }
        try requireDirectory(root, relativePath: "")

        let rootChildren = try childNames(root)
        guard rootChildren == Set(["manifest.json", "seal.json", "payload"]) else {
            throw ReceivePromotionPackageError.invalidStructure("")
        }
        let payloadRoot = root.appendingPathComponent("payload", isDirectory: true)
        try requireDirectory(payloadRoot, relativePath: "payload")
        let payloadNames = try childNames(payloadRoot)
        guard !payloadNames.isEmpty,
              payloadNames.count <= Self.maximumDocuments else {
            throw ReceivePromotionPackageError.sizeLimit
        }

        let manifestBytes = try readRegularFile(
            root.appendingPathComponent("manifest.json"),
            relativePath: "manifest.json",
            limit: Self.maximumManifestBytes
        )
        let sealBytes = try readRegularFile(
            root.appendingPathComponent("seal.json"),
            relativePath: "seal.json",
            limit: Self.maximumSealBytes
        )

        let manifest: Manifest
        do { manifest = try decodeCanonical(Manifest.self, manifestBytes) }
        catch { throw ReceivePromotionPackageError.invalidManifest }
        let seal: Seal
        do { seal = try decodeCanonical(Seal.self, sealBytes) }
        catch { throw ReceivePromotionPackageError.invalidSeal }

        try validateManifest(manifest)
        let manifestHash = hasher.sha256(for: manifestBytes)
        guard seal.format == Self.sealFormat,
              exactHash(seal.manifestSHA256) == manifestHash,
              exactHash(seal.inventorySHA256) != nil,
              seal.payloads.count == manifest.documents.count else {
            throw ReceivePromotionPackageError.invalidSeal
        }

        let expectedNames = Set(manifest.documents.map {
            String($0.payload.dropFirst("payload/".count))
        })
        guard payloadNames == expectedNames else {
            throw ReceivePromotionPackageError.invalidStructure("payload")
        }

        var totalBytes = 0
        var payloadBindings: [Seal.Payload] = []
        var reviews: [ReceivePromotionDocumentReview] = []
        var materializedDocuments: [ReceivePromotionPayloadDocument] = []
        var fingerprintEntries = [
            DigestEntry(
                path: "manifest.json",
                bytes: manifestBytes.count,
                sha256: manifestHash.rawValue
            )
        ]

        for document in manifest.documents {
            let name = String(document.payload.dropFirst("payload/".count))
            let data = try readRegularFile(
                payloadRoot.appendingPathComponent(name),
                relativePath: document.payload,
                limit: Self.maximumDocumentBytes
            )
            let hash = hasher.sha256(for: data)
            guard data.count == document.byteCount,
                  exactHash(document.editableBodySHA256) == hash,
                  String(data: data, encoding: .utf8) != nil else {
                throw ReceivePromotionPackageError.invalidPayload(document.payload)
            }
            totalBytes += data.count
            guard totalBytes <= Self.maximumPayloadBytes else {
                throw ReceivePromotionPackageError.sizeLimit
            }
            let binding = Seal.Payload(
                path: document.payload,
                byteCount: data.count,
                sha256: hash.rawValue
            )
            payloadBindings.append(binding)
            fingerprintEntries.append(.init(
                path: document.payload,
                bytes: data.count,
                sha256: hash.rawValue
            ))
            let review = ReceivePromotionDocumentReview(
                sourceDocumentID: canonicalUUID(document.sourceDocumentID)!,
                sourceName: document.sourceName,
                sourceBodyHash: exactHash(document.sourceBodySHA256)!,
                editableRevision: document.editableRevision,
                editableBodyHash: hash,
                byteCount: data.count,
                payloadPath: RelativeDocumentPath(rawValue: document.payload)
            )
            reviews.append(review)
            materializedDocuments.append(.init(review: review, data: data))
        }

        let inventory = InventoryBinding(
            manifestSHA256: manifestHash.rawValue,
            payloads: payloadBindings
        )
        guard seal.payloads == payloadBindings,
              exactHash(seal.inventorySHA256) == hasher.sha256(for: try canonical(inventory)) else {
            throw ReceivePromotionPackageError.invalidSeal
        }

        let sealHash = hasher.sha256(for: sealBytes)
        fingerprintEntries.append(.init(
            path: "seal.json",
            bytes: sealBytes.count,
            sha256: sealHash.rawValue
        ))
        fingerprintEntries.sort { $0.path < $1.path }
        let fingerprint = hasher.sha256(for: try canonical(fingerprintEntries))
        let sourceKey = hasher.sha256(for: try canonical(SourceKeyBinding(
            producerBundleID: manifest.producerBundleID,
            sourceLocalID: manifest.source.localID,
            sourceRunID: manifest.source.runID
        )))

        let suggestedProjectName = manifest.source.folderName + " 편집본"
        do { try pathPolicy.validateName(suggestedProjectName) }
        catch { throw ReceivePromotionPackageError.invalidName(suggestedProjectName) }

        let report = ReceivePromotionReport(
            sourceSelectionURL: root,
            packageID: canonicalUUID(manifest.packageID)!,
            producerBundleID: manifest.producerBundleID,
            sourceLocalID: canonicalUUID(manifest.source.localID)!,
            sourceRunID: canonicalUUID(manifest.source.runID)!,
            sourceFolderName: manifest.source.folderName,
            editableIdentityHash: exactHash(manifest.source.editableIdentitySHA256)!,
            editableWorkspaceHash: exactHash(manifest.source.editableWorkspaceSHA256)!,
            sourceKey: sourceKey,
            packageFingerprint: fingerprint,
            suggestedProjectName: suggestedProjectName,
            documents: reviews
        )
        return ReceivePromotionValidatedPackage(
            report: report,
            documents: materializedDocuments
        )
    }

    private func validateManifest(_ manifest: Manifest) throws {
        guard manifest.format == Self.manifestFormat,
              manifest.producerBundleID == Self.producerBundleID,
              canonicalUUID(manifest.packageID) != nil,
              canonicalUUID(manifest.source.localID) != nil,
              canonicalUUID(manifest.source.runID) != nil,
              exactHash(manifest.source.editableIdentitySHA256) != nil,
              exactHash(manifest.source.editableWorkspaceSHA256) != nil,
              !manifest.documents.isEmpty,
              manifest.documents.count <= Self.maximumDocuments else {
            throw ReceivePromotionPackageError.invalidManifest
        }
        do { try pathPolicy.validateName(manifest.source.folderName) }
        catch { throw ReceivePromotionPackageError.invalidName(manifest.source.folderName) }

        var ids = Set<String>()
        var nameKeys = Set<String>()
        for (index, document) in manifest.documents.enumerated() {
            guard canonicalUUID(document.sourceDocumentID) != nil,
                  ids.insert(document.sourceDocumentID).inserted,
                  exactHash(document.sourceBodySHA256) != nil,
                  exactHash(document.editableBodySHA256) != nil,
                  document.editableRevision >= 0,
                  document.byteCount >= 0,
                  document.byteCount <= Self.maximumDocumentBytes,
                  document.payload == String(format: "payload/%04d.txt", index + 1) else {
                throw ReceivePromotionPackageError.invalidManifest
            }
            do { try pathPolicy.validateName(document.sourceName) }
            catch { throw ReceivePromotionPackageError.invalidName(document.sourceName) }
            let collisionKey = pathPolicy.collisionKey(for: document.sourceName)
            guard nameKeys.insert(collisionKey).inserted else {
                throw ReceivePromotionPackageError.invalidName(document.sourceName)
            }
            if index > 0,
               manifest.documents[index - 1].sourceDocumentID >= document.sourceDocumentID {
                throw ReceivePromotionPackageError.invalidManifest
            }
        }
    }

    private func childNames(_ directory: URL) throws -> Set<String> {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw ReceivePromotionPackageError.invalidStructure(
                directory.lastPathComponent
            )
        }
        let names = children.map(\.lastPathComponent)
        guard Set(names).count == names.count else {
            throw ReceivePromotionPackageError.invalidStructure(
                directory.lastPathComponent
            )
        }
        return Set(names)
    }

    private func requireDirectory(_ url: URL, relativePath: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ReceivePromotionPackageError.invalidStructure(relativePath)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw ReceivePromotionPackageError.unsafeEntry(relativePath)
        }
    }

    private func readRegularFile(
        _ url: URL,
        relativePath: String,
        limit: Int
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ReceivePromotionPackageError.unsafeEntry(relativePath)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1 else {
            throw ReceivePromotionPackageError.unsafeEntry(relativePath)
        }
        guard before.st_size >= 0, before.st_size <= off_t(limit) else {
            throw ReceivePromotionPackageError.sizeLimit
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count >= 0 else {
                throw ReceivePromotionPackageError.unsafeEntry(relativePath)
            }
            if count == 0 { break }
            guard data.count + count <= limit else {
                throw ReceivePromotionPackageError.sizeLimit
            }
            data.append(contentsOf: buffer[0..<count])
        }

        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw ReceivePromotionPackageError.unsafeEntry(relativePath)
        }
        return data
    }

    private func exactHash(_ raw: String) -> ContentHash? {
        guard let value = ContentHash(rawValue: raw), value.rawValue == raw else {
            return nil
        }
        return value
    }

    private func canonicalUUID(_ raw: String) -> UUID? {
        guard let value = UUID(uuidString: raw),
              value.uuidString.lowercased() == raw else { return nil }
        return value
    }

    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private func decodeCanonical<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoded = try JSONDecoder().decode(type, from: data)
        guard try canonical(decoded) == data else {
            throw ReceivePromotionPackageError.invalidManifest
        }
        return decoded
    }
}

private extension ReceivePromotionPackageReader {
    struct Manifest: Codable, Equatable {
        struct Source: Codable, Equatable {
            let localID: String
            let runID: String
            let folderName: String
            let editableIdentitySHA256: String
            let editableWorkspaceSHA256: String

            enum CodingKeys: String, CodingKey {
                case localID = "local_id"
                case runID = "run_id"
                case folderName = "folder_name"
                case editableIdentitySHA256 = "editable_identity_sha256"
                case editableWorkspaceSHA256 = "editable_workspace_sha256"
            }
        }

        struct Document: Codable, Equatable {
            let sourceDocumentID: String
            let sourceName: String
            let sourceBodySHA256: String
            let editableRevision: Int
            let editableBodySHA256: String
            let byteCount: Int
            let payload: String

            enum CodingKeys: String, CodingKey {
                case sourceDocumentID = "source_document_id"
                case sourceName = "source_name"
                case sourceBodySHA256 = "source_body_sha256"
                case editableRevision = "editable_revision"
                case editableBodySHA256 = "editable_body_sha256"
                case byteCount = "byte_count"
                case payload
            }
        }

        let format: String
        let packageID: String
        let producerBundleID: String
        let source: Source
        let documents: [Document]

        enum CodingKeys: String, CodingKey {
            case format
            case packageID = "package_id"
            case producerBundleID = "producer_bundle_id"
            case source
            case documents
        }
    }

    struct Seal: Codable, Equatable {
        struct Payload: Codable, Equatable {
            let path: String
            let byteCount: Int
            let sha256: String

            enum CodingKeys: String, CodingKey {
                case path
                case byteCount = "byte_count"
                case sha256
            }
        }

        let format: String
        let manifestSHA256: String
        let payloads: [Payload]
        let inventorySHA256: String

        enum CodingKeys: String, CodingKey {
            case format
            case manifestSHA256 = "manifest_sha256"
            case payloads
            case inventorySHA256 = "inventory_sha256"
        }
    }

    struct InventoryBinding: Codable, Equatable {
        let manifestSHA256: String
        let payloads: [Seal.Payload]

        enum CodingKeys: String, CodingKey {
            case manifestSHA256 = "manifest_sha256"
            case payloads
        }
    }

    struct SourceKeyBinding: Codable, Equatable {
        let producerBundleID: String
        let sourceLocalID: String
        let sourceRunID: String

        enum CodingKeys: String, CodingKey {
            case producerBundleID = "producer_bundle_id"
            case sourceLocalID = "source_local_id"
            case sourceRunID = "source_run_id"
        }
    }

    struct DigestEntry: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
    }
}
