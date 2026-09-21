import Foundation

enum ReceiveEditablePromotionError: Error, Equatable {
    case source
    case unsavedDraft
    case name
    case body
    case structure
    case manifest
    case seal
    case payload
    case workspaceChanged
}

struct ReceiveEditablePromotionReview: Equatable, Sendable {
    struct Document: Equatable, Sendable {
        let sourceDocumentID: UUID
        let sourceName: String
        let sourceBodySHA256: String
        let editableRevision: Int
        let editableBodySHA256: String
        let byteCount: Int
        let payloadPath: String
    }

    let packageID: UUID
    let sourceLocalID: UUID
    let sourceRunID: UUID
    let folderName: String
    let identitySHA256: String
    let workspaceSHA256: String
    let documents: [Document]
    let fingerprint: String
}

/// Paths are relative package paths and are closed by the manifest and seal.
struct ReceiveEditablePromotionPackage: Equatable, Sendable, Identifiable {
    var id: UUID { review.packageID }
    let fileName: String
    let files: [String: Data]
    let review: ReceiveEditablePromotionReview

    func verifyCurrent(_ input: ReceiveEditablePromotionInput) throws {
        let manifest = try ReceiveEditablePromotion.makeManifest(
            input: input,
            packageID: review.packageID
        )
        guard manifest.source.localID == review.sourceLocalID.uuidString.lowercased(),
              manifest.source.runID == review.sourceRunID.uuidString.lowercased(),
              manifest.source.folderName == review.folderName,
              manifest.source.editableIdentitySHA256 == review.identitySHA256,
              manifest.source.editableWorkspaceSHA256 == review.workspaceSHA256,
              ReceiveEditablePromotion.reviewDocuments(manifest.documents) == review.documents else {
            throw ReceiveEditablePromotionError.workspaceChanged
        }
    }

    /// Builds the exact directory package consumed by WriterPad. The closed
    /// manifest inventory means callers cannot add an unreviewed wrapper.
    func fileWrapper() throws -> FileWrapper {
        guard let manifest = files["manifest.json"],
              let seal = files["seal.json"] else {
            throw ReceiveEditablePromotionError.structure
        }
        var payload: [String: FileWrapper] = [:]
        for (path, bytes) in files where path.hasPrefix("payload/") {
            let name = String(path.dropFirst("payload/".count))
            guard !name.isEmpty, !name.contains("/") else {
                throw ReceiveEditablePromotionError.structure
            }
            payload[name] = FileWrapper(regularFileWithContents: bytes)
        }
        guard payload.count == files.count - 2 else {
            throw ReceiveEditablePromotionError.structure
        }
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: manifest),
            "seal.json": FileWrapper(regularFileWithContents: seal),
            "payload": FileWrapper(directoryWithFileWrappers: payload)
        ])
    }
}

enum ReceiveEditablePromotion {
    static let manifestFormat = "writerpad-receive-promotion-v1"
    static let sealFormat = "writerpad-receive-promotion-seal-v1"
    static let producerBundleID = "com.chocos.writerpad.receiveboundary"
    private static let maximumDocumentBytes = 4 * 1024 * 1024
    private static let maximumPayloadBytes = 16 * 1024 * 1024
    private static let maximumDocuments = 4096
    private static let hashLength = 64

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

    private struct InventoryBinding: Codable, Equatable {
        let manifestSHA256: String
        let payloads: [Seal.Payload]

        enum CodingKeys: String, CodingKey {
            case manifestSHA256 = "manifest_sha256"
            case payloads
        }
    }

    static func prepare(
        input: ReceiveEditablePromotionInput,
        draftTexts: [UUID: String],
        packageID: UUID = UUID()
    ) throws -> ReceiveEditablePromotionPackage {
        let expectedIDs = Set(input.editable.documents.map(\.id))
        guard Set(draftTexts.keys) == expectedIDs,
              input.editable.documents.allSatisfy({ draftTexts[$0.id] == $0.text }) else {
            throw ReceiveEditablePromotionError.unsavedDraft
        }

        let manifest = try makeManifest(input: input, packageID: packageID)
        let manifestBytes = try canonical(manifest)
        var files: [String: Data] = ["manifest.json": manifestBytes]
        var payloads: [Seal.Payload] = []

        let editableByID = Dictionary(
            uniqueKeysWithValues: input.editable.documents.map { ($0.id, $0) }
        )
        for document in manifest.documents {
            guard let id = UUID(uuidString: document.sourceDocumentID),
                  let editable = editableByID[id] else {
                throw ReceiveEditablePromotionError.source
            }
            let bytes = Data(editable.text.utf8)
            files[document.payload] = bytes
            payloads.append(.init(
                path: document.payload,
                byteCount: bytes.count,
                sha256: byteHash(bytes)
            ))
        }

        let inventorySHA256 = try inventorySHA256(
            manifestSHA256: byteHash(manifestBytes),
            payloads: payloads
        )
        let seal = Seal(
            format: sealFormat,
            manifestSHA256: byteHash(manifestBytes),
            payloads: payloads,
            inventorySHA256: inventorySHA256
        )
        files["seal.json"] = try canonical(seal)

        let fileName = try packageFileName(folderName: input.editable.folderName)
        let package = try validate(files: files, fileName: fileName)
        try package.verifyCurrent(input)
        return package
    }

    static func validate(
        files: [String: Data],
        fileName: String
    ) throws -> ReceiveEditablePromotionPackage {
        guard files.count >= 3,
              files.count <= maximumDocuments + 2,
              let manifestBytes = files["manifest.json"],
              let sealBytes = files["seal.json"] else {
            throw ReceiveEditablePromotionError.structure
        }
        guard fileName.lowercased().hasSuffix(".writerpadpromotion") else {
            throw ReceiveEditablePromotionError.name
        }
        do { try validateComponent(fileName) }
        catch { throw ReceiveEditablePromotionError.name }

        let manifest: Manifest
        do { manifest = try decodeExact(Manifest.self, manifestBytes) }
        catch { throw ReceiveEditablePromotionError.manifest }
        let seal: Seal
        do { seal = try decodeExact(Seal.self, sealBytes) }
        catch { throw ReceiveEditablePromotionError.seal }

        try validateManifest(manifest)
        guard seal.format == sealFormat,
              isSHA256(seal.manifestSHA256),
              isSHA256(seal.inventorySHA256),
              seal.manifestSHA256 == byteHash(manifestBytes) else {
            throw ReceiveEditablePromotionError.seal
        }

        let expectedPaths = Set(["manifest.json", "seal.json"] + manifest.documents.map(\.payload))
        guard Set(files.keys) == expectedPaths else {
            throw ReceiveEditablePromotionError.structure
        }

        var payloads: [Seal.Payload] = []
        var total = 0
        for document in manifest.documents {
            guard let bytes = files[document.payload],
                  bytes.count == document.byteCount,
                  bytes.count <= maximumDocumentBytes,
                  byteHash(bytes) == document.editableBodySHA256,
                  String(data: bytes, encoding: .utf8) != nil else {
                throw ReceiveEditablePromotionError.payload
            }
            total += bytes.count
            guard total <= maximumPayloadBytes else {
                throw ReceiveEditablePromotionError.body
            }
            payloads.append(.init(
                path: document.payload,
                byteCount: bytes.count,
                sha256: byteHash(bytes)
            ))
        }

        guard seal.payloads == payloads,
              seal.inventorySHA256 == (try inventorySHA256(
                manifestSHA256: seal.manifestSHA256,
                payloads: payloads
              )) else {
            throw ReceiveEditablePromotionError.seal
        }

        guard let packageID = canonicalUUID(manifest.packageID),
              let localID = canonicalUUID(manifest.source.localID),
              let runID = canonicalUUID(manifest.source.runID) else {
            throw ReceiveEditablePromotionError.manifest
        }
        let review = ReceiveEditablePromotionReview(
            packageID: packageID,
            sourceLocalID: localID,
            sourceRunID: runID,
            folderName: manifest.source.folderName,
            identitySHA256: manifest.source.editableIdentitySHA256,
            workspaceSHA256: manifest.source.editableWorkspaceSHA256,
            documents: reviewDocuments(manifest.documents),
            fingerprint: try packageFingerprint(files)
        )
        return .init(fileName: fileName, files: files, review: review)
    }

    static func makeManifest(
        input: ReceiveEditablePromotionInput,
        packageID: UUID
    ) throws -> Manifest {
        guard input.source.runID == input.editable.sourceRun,
              input.source.folderName == input.editable.folderName,
              canonicalUUID(input.source.runID) != nil,
              isSHA256(input.identitySHA256),
              isSHA256(input.workspaceSHA256),
              !input.editable.documents.isEmpty,
              input.editable.documents.count <= maximumDocuments else {
            throw ReceiveEditablePromotionError.source
        }
        do { try validateComponent(input.editable.folderName) }
        catch { throw ReceiveEditablePromotionError.name }

        var sourceByID: [UUID: ReceiveStoredSnapshot.Document] = [:]
        for document in input.source.documents {
            guard sourceByID.updateValue(document, forKey: document.id) == nil else {
                throw ReceiveEditablePromotionError.source
            }
        }
        let editableIDs = input.editable.documents.map(\.id)
        guard Set(editableIDs).count == editableIDs.count,
              Set(sourceByID.keys) == Set(editableIDs) else {
            throw ReceiveEditablePromotionError.source
        }

        var collisionKeys = Set<String>()
        var documents: [Manifest.Document] = []
        var total = 0
        for editable in input.editable.documents.sorted(by: {
            $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased()
        }) {
            guard let source = sourceByID[editable.id],
                  source.name == editable.name,
                  source.byteCount == Data(source.text.utf8).count,
                  editable.revision >= 0 else {
                throw ReceiveEditablePromotionError.source
            }
            do { try validateComponent(editable.name) }
            catch { throw ReceiveEditablePromotionError.name }
            let collisionKey = editable.name.precomposedStringWithCanonicalMapping.lowercased()
            guard collisionKeys.insert(collisionKey).inserted else {
                throw ReceiveEditablePromotionError.name
            }

            let sourceBytes = Data(source.text.utf8)
            let editableBytes = Data(editable.text.utf8)
            guard sourceBytes.count <= maximumDocumentBytes,
                  editableBytes.count <= maximumDocumentBytes,
                  String(data: sourceBytes, encoding: .utf8) != nil,
                  String(data: editableBytes, encoding: .utf8) != nil else {
                throw ReceiveEditablePromotionError.body
            }
            total += editableBytes.count
            guard total <= maximumPayloadBytes else {
                throw ReceiveEditablePromotionError.body
            }
            let index = documents.count + 1
            documents.append(.init(
                sourceDocumentID: editable.id.uuidString.lowercased(),
                sourceName: editable.name,
                sourceBodySHA256: byteHash(sourceBytes),
                editableRevision: editable.revision,
                editableBodySHA256: byteHash(editableBytes),
                byteCount: editableBytes.count,
                payload: String(format: "payload/%04d.txt", index)
            ))
        }

        return Manifest(
            format: manifestFormat,
            packageID: packageID.uuidString.lowercased(),
            producerBundleID: producerBundleID,
            source: .init(
                localID: input.localID.uuidString.lowercased(),
                runID: input.source.runID,
                folderName: input.source.folderName,
                editableIdentitySHA256: input.identitySHA256,
                editableWorkspaceSHA256: input.workspaceSHA256
            ),
            documents: documents
        )
    }

    static func reviewDocuments(
        _ documents: [Manifest.Document]
    ) -> [ReceiveEditablePromotionReview.Document] {
        documents.compactMap { document in
            guard let id = UUID(uuidString: document.sourceDocumentID) else { return nil }
            return .init(
                sourceDocumentID: id,
                sourceName: document.sourceName,
                sourceBodySHA256: document.sourceBodySHA256,
                editableRevision: document.editableRevision,
                editableBodySHA256: document.editableBodySHA256,
                byteCount: document.byteCount,
                payloadPath: document.payload
            )
        }
    }

    private static func validateManifest(_ manifest: Manifest) throws {
        guard manifest.format == manifestFormat,
              manifest.producerBundleID == producerBundleID,
              canonicalUUID(manifest.packageID) != nil,
              canonicalUUID(manifest.source.localID) != nil,
              canonicalUUID(manifest.source.runID) != nil,
              isSHA256(manifest.source.editableIdentitySHA256),
              isSHA256(manifest.source.editableWorkspaceSHA256),
              !manifest.documents.isEmpty,
              manifest.documents.count <= maximumDocuments else {
            throw ReceiveEditablePromotionError.manifest
        }
        do { try validateComponent(manifest.source.folderName) }
        catch { throw ReceiveEditablePromotionError.name }

        var ids = Set<String>()
        var names = Set<String>()
        for (offset, document) in manifest.documents.enumerated() {
            guard canonicalUUID(document.sourceDocumentID) != nil,
                  ids.insert(document.sourceDocumentID).inserted,
                  isSHA256(document.sourceBodySHA256),
                  isSHA256(document.editableBodySHA256),
                  document.editableRevision >= 0,
                  document.byteCount >= 0,
                  document.byteCount <= maximumDocumentBytes,
                  document.payload == String(format: "payload/%04d.txt", offset + 1) else {
                throw ReceiveEditablePromotionError.manifest
            }
            do { try validateComponent(document.sourceName) }
            catch { throw ReceiveEditablePromotionError.name }
            let nameKey = document.sourceName.precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(nameKey).inserted else {
                throw ReceiveEditablePromotionError.name
            }
            if offset > 0 {
                guard manifest.documents[offset - 1].sourceDocumentID < document.sourceDocumentID else {
                    throw ReceiveEditablePromotionError.manifest
                }
            }
        }
    }

    private static func packageFileName(folderName: String) throws -> String {
        let name = folderName + "-WriterPad승격.writerpadpromotion"
        do { try validateComponent(name) }
        catch { throw ReceiveEditablePromotionError.name }
        return name
    }

    private static func inventorySHA256(
        manifestSHA256: String,
        payloads: [Seal.Payload]
    ) throws -> String {
        byteHash(try canonical(InventoryBinding(
            manifestSHA256: manifestSHA256,
            payloads: payloads
        )))
    }

    private static func packageFingerprint(_ files: [String: Data]) throws -> String {
        let entries = files.keys.sorted().map {
            DigestEntry(path: $0, bytes: files[$0]!.count, sha256: byteHash(files[$0]!))
        }
        return byteHash(try canonical(entries))
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value else { return nil }
        return id
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == hashLength && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}
