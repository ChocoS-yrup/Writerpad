import Foundation
import XCTest
@testable import WriterPad

final class ReceivePromotionPackageReaderTests: XCTestCase {
    private var roots: [URL] = []
    private let reader = ReceivePromotionPackageReader()
    private let hasher = SHA256ContentHasher()

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    @MainActor
    func testSelectionAccessIsHeldUntilReleaseAndBalancedAcrossNewSelection() {
        let first = URL(fileURLWithPath: "/tmp/first.writerpadpromotion")
        let second = URL(fileURLWithPath: "/tmp/second.writerpadpromotion")
        var began: [URL] = []
        var ended: [URL] = []
        let access = ReceivePromotionSelectionAccess(
            begin: { url in began.append(url); return true },
            end: { ended.append($0) }
        )

        access.retain(first)
        XCTAssertEqual(access.retainedURL, first)
        XCTAssertEqual(began, [first])
        XCTAssertTrue(ended.isEmpty)

        access.retain(second)
        XCTAssertEqual(access.retainedURL, second)
        XCTAssertEqual(began, [first, second])
        XCTAssertEqual(ended, [first])

        access.release()
        access.release()
        XCTAssertNil(access.retainedURL)
        XCTAssertEqual(ended, [first, second])
    }

    @MainActor
    func testSelectionAccessDoesNotStopWhenNoGrantWasAcquired() {
        let url = URL(fileURLWithPath: "/tmp/unscoped.writerpadpromotion")
        var stopped = false
        let access = ReceivePromotionSelectionAccess(
            begin: { _ in false },
            end: { _ in stopped = true }
        )

        access.retain(url)
        access.release()

        XCTAssertNil(access.retainedURL)
        XCTAssertFalse(stopped)
    }

    func testValidPackagePreservesEmptyKoreanAndFinalLineFeedMetadata() async throws {
        let fixture = try makePackage()

        let report = try await reader.inspect(fixture.packageURL)

        XCTAssertEqual(report.packageID, fixture.packageID)
        XCTAssertEqual(report.sourceLocalID, fixture.localID)
        XCTAssertEqual(report.sourceRunID, fixture.runID)
        XCTAssertEqual(report.suggestedProjectName, "작품명 자동수신저장 격리검증 20260913 편집본")
        XCTAssertEqual(report.documents.count, 2)
        XCTAssertEqual(report.totalBytes, Data("한글\n마지막 LF\n".utf8).count)
        XCTAssertEqual(report.documents[0].byteCount, 0)
        XCTAssertEqual(report.documents[1].editableRevision, 1)
        XCTAssertEqual(
            report.documents[1].editableBodyHash,
            hasher.sha256(for: Data("한글\n마지막 LF\n".utf8))
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.packageURL.appendingPathComponent("payload/0001.txt")),
            Data()
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.packageURL.appendingPathComponent("payload/0002.txt")),
            Data("한글\n마지막 LF\n".utf8)
        )
    }

    func testSourceKeyIsStableButPackageFingerprintChanges() async throws {
        let first = try makePackage(
            packageID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let second = try makePackage(
            packageID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            localID: first.localID,
            runID: first.runID
        )

        let firstReport = try await reader.inspect(first.packageURL)
        let secondReport = try await reader.inspect(second.packageURL)

        XCTAssertEqual(firstReport.sourceKey, secondReport.sourceKey)
        XCTAssertNotEqual(firstReport.packageID, secondReport.packageID)
        XCTAssertNotEqual(firstReport.packageFingerprint, secondReport.packageFingerprint)
    }

    func testUnknownOrMissingEntriesFailClosed() async throws {
        let unknown = try makePackage()
        try Data().write(to: unknown.packageURL.appendingPathComponent("extra.bin"))
        await assertError(.invalidStructure("")) {
            _ = try await self.reader.inspect(unknown.packageURL)
        }

        let missing = try makePackage()
        try FileManager.default.removeItem(
            at: missing.packageURL.appendingPathComponent("payload/0002.txt")
        )
        await assertError(.invalidStructure("payload")) {
            _ = try await self.reader.inspect(missing.packageURL)
        }
    }

    func testPayloadMutationAndNonCanonicalManifestAreRejected() async throws {
        let changed = try makePackage()
        try Data("변경".utf8).write(
            to: changed.packageURL.appendingPathComponent("payload/0002.txt")
        )
        await assertError(.invalidPayload("payload/0002.txt")) {
            _ = try await self.reader.inspect(changed.packageURL)
        }

        let nonCanonical = try makePackage()
        let manifestURL = nonCanonical.packageURL.appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifestURL)
        bytes.append(0x20)
        try bytes.write(to: manifestURL)
        await assertError(.invalidManifest) {
            _ = try await self.reader.inspect(nonCanonical.packageURL)
        }
    }

    func testSymbolicLinkAndHardLinkPayloadsAreRejected() async throws {
        let symbolic = try makePackage()
        let symbolicPayload = symbolic.packageURL.appendingPathComponent("payload/0002.txt")
        let symbolicTarget = symbolic.packageURL.deletingLastPathComponent()
            .appendingPathComponent("outside.txt")
        try Data("한글\n마지막 LF\n".utf8).write(to: symbolicTarget)
        try FileManager.default.removeItem(at: symbolicPayload)
        try FileManager.default.createSymbolicLink(
            at: symbolicPayload,
            withDestinationURL: symbolicTarget
        )
        await assertError(.unsafeEntry("payload/0002.txt")) {
            _ = try await self.reader.inspect(symbolic.packageURL)
        }

        let hard = try makePackage()
        let hardPayload = hard.packageURL.appendingPathComponent("payload/0002.txt")
        let hardAlias = hard.packageURL.deletingLastPathComponent()
            .appendingPathComponent("hard-alias.txt")
        try FileManager.default.linkItem(at: hardPayload, to: hardAlias)
        await assertError(.unsafeEntry("payload/0002.txt")) {
            _ = try await self.reader.inspect(hard.packageURL)
        }
    }

    func testUnicodeAndCaseFoldedNameCollisionsAreRejected() async throws {
        let unicode = try makePackage(names: ["É.txt", "E\u{301}.txt"])
        await assertError(.invalidName("E\u{301}.txt")) {
            _ = try await self.reader.inspect(unicode.packageURL)
        }

        let caseFolded = try makePackage(names: ["Draft.txt", "draft.TXT"])
        await assertError(.invalidName("draft.TXT")) {
            _ = try await self.reader.inspect(caseFolded.packageURL)
        }
    }

    func testWrongExtensionAndInvalidWriterPadNameAreRejected() async throws {
        let wrongExtension = try makePackage(extensionName: "txt")
        await assertError(.invalidPackageType) {
            _ = try await self.reader.inspect(wrongExtension.packageURL)
        }

        let invalidName = try makePackage(names: ["../탈출.txt", "정상.txt"])
        await assertError(.invalidName("../탈출.txt")) {
            _ = try await self.reader.inspect(invalidName.packageURL)
        }
    }

    func testReadsExactSharedProducerBridgeFixture() async throws {
        let report = try await reader.inspect(sharedBridgeFixture())
        XCTAssertEqual(
            report.packageID,
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
        XCTAssertEqual(report.documents.map(\.sourceName), ["빈문서.txt", "저장경계.txt"])
        XCTAssertEqual(report.documents.map(\.editableRevision), [0, 1])
        XCTAssertEqual(report.totalBytes, Data("한글\n마지막 LF\n".utf8).count)
    }

    private func sharedBridgeFixture() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "TestFixtures/ReceivePromotionBridge.writerpadpromotion",
                isDirectory: true
            )
    }

    private func assertError(
        _ expected: ReceivePromotionPackageError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ReceivePromotionPackageError, expected)
        }
    }

    private func makePackage(
        packageID: UUID = UUID(),
        localID: UUID = UUID(),
        runID: UUID = UUID(),
        names: [String] = ["빈문서.txt", "저장경계.txt"],
        extensionName: String = "writerpadpromotion"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "writerpad-promotion-test-" + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        roots.append(root)
        let package = root.appendingPathComponent(
            "수신 편집본." + extensionName,
            isDirectory: true
        )
        let payloadRoot = package.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(
            at: payloadRoot,
            withIntermediateDirectories: true
        )

        let ids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ]
        let sourceBodies = [Data(), Data("격리 저장 경계 기준".utf8)]
        let editableBodies = [Data(), Data("한글\n마지막 LF\n".utf8)]
        let documents = zip(ids.indices, ids).map { index, id in
            Manifest.Document(
                sourceDocumentID: id.uuidString.lowercased(),
                sourceName: names[index],
                sourceBodySHA256: hasher.sha256(for: sourceBodies[index]).rawValue,
                editableRevision: index,
                editableBodySHA256: hasher.sha256(for: editableBodies[index]).rawValue,
                byteCount: editableBodies[index].count,
                payload: String(format: "payload/%04d.txt", index + 1)
            )
        }
        let manifest = Manifest(
            format: "writerpad-receive-promotion-v1",
            packageID: packageID.uuidString.lowercased(),
            producerBundleID: "com.chocos.writerpad.receiveboundary",
            source: .init(
                localID: localID.uuidString.lowercased(),
                runID: runID.uuidString.lowercased(),
                folderName: "작품명 자동수신저장 격리검증 20260913",
                editableIdentitySHA256: String(repeating: "a", count: 64),
                editableWorkspaceSHA256: String(repeating: "b", count: 64)
            ),
            documents: documents
        )
        let manifestBytes = try canonical(manifest)
        try manifestBytes.write(to: package.appendingPathComponent("manifest.json"))

        var bindings: [Seal.Payload] = []
        for (index, data) in editableBodies.enumerated() {
            let path = String(format: "payload/%04d.txt", index + 1)
            try data.write(to: package.appendingPathComponent(path))
            bindings.append(.init(
                path: path,
                byteCount: data.count,
                sha256: hasher.sha256(for: data).rawValue
            ))
        }
        let manifestHash = hasher.sha256(for: manifestBytes).rawValue
        let inventoryHash = hasher.sha256(for: try canonical(InventoryBinding(
            manifestSHA256: manifestHash,
            payloads: bindings
        ))).rawValue
        let seal = Seal(
            format: "writerpad-receive-promotion-seal-v1",
            manifestSHA256: manifestHash,
            payloads: bindings,
            inventorySHA256: inventoryHash
        )
        try canonical(seal).write(to: package.appendingPathComponent("seal.json"))
        return .init(packageURL: package, packageID: packageID, localID: localID, runID: runID)
    }

    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

private extension ReceivePromotionPackageReaderTests {
    struct Fixture {
        let packageURL: URL
        let packageID: UUID
        let localID: UUID
        let runID: UUID
    }

    struct Manifest: Codable {
        struct Source: Codable {
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

        struct Document: Codable {
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

    struct Seal: Codable {
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

    struct InventoryBinding: Codable {
        let manifestSHA256: String
        let payloads: [Seal.Payload]

        enum CodingKeys: String, CodingKey {
            case manifestSHA256 = "manifest_sha256"
            case payloads
        }
    }
}
