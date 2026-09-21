import XCTest
@testable import SyntheticInitialReceive

final class ReceiveEditablePromotionPackageTests: XCTestCase {
    private var homes: [URL] = []

    override func tearDownWithError() throws {
        for home in homes { try FileManager.default.removeItem(at: home) }
    }

    private func home() throws -> URL {
        let value = URL(fileURLWithPath: try SafeFiles.temporaryPath())
            .appendingPathComponent(
                "editable-promotion-" + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: value,
            withIntermediateDirectories: false
        )
        homes.append(value)
        return value
    }

    private func input() throws -> (
        ReceiveEditablePromotionInput,
        [UUID: String],
        UUID,
        UUID
    ) {
        let root = try home()
        let local = UUID()
        let empty = UUID()
        let body = UUID()
        let original = "격리 저장 경계 기준"
        let source = ReceiveStoredSnapshot(
            runID: UUID().uuidString.lowercased(),
            folderName: "작품명 자동수신저장 격리검증 20260913",
            documents: [
                .init(id: empty, name: "빈문서.txt", text: "", byteCount: 0),
                .init(
                    id: body,
                    name: "저장경계.txt",
                    text: original,
                    byteCount: Data(original.utf8).count
                )
            ]
        )
        _ = try ReceiveEditableCopy.create(
            home: root,
            local: local,
            snapshot: source,
            check: {}
        )
        _ = try ReceiveEditableCopy.save(
            home: root,
            local: local,
            snapshot: source,
            documentID: body,
            expectedRevision: 0,
            text: "한글\n마지막 LF\n",
            check: {}
        )
        let verified = try ReceiveEditableCopy.promotionInput(
            home: root,
            local: local,
            snapshot: source,
            check: {}
        )
        let drafts = Dictionary(
            uniqueKeysWithValues: verified.editable.documents.map { ($0.id, $0.text) }
        )
        return (verified, drafts, empty, body)
    }

    func testCreatesCanonicalPackageWithExactEmptyKoreanAndFinalLFBytes() throws {
        let (input, drafts, empty, body) = try input()
        let editableRoot = homes.last!
            .appendingPathComponent("Library/Application Support/ReceiveEditable-v1")
            .appendingPathComponent(input.localID.uuidString.lowercased())
            .appendingPathComponent(input.source.runID)
        let identityURL = editableRoot.appendingPathComponent("identity.json")
        let workspaceURL = editableRoot.appendingPathComponent("workspace.json")
        let identityBefore = try SafeFiles.read(identityURL)
        let workspaceBefore = try SafeFiles.read(workspaceURL)
        let packageID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let package = try ReceiveEditablePromotion.prepare(
            input: input,
            draftTexts: drafts,
            packageID: packageID
        )

        XCTAssertTrue(package.fileName.hasSuffix(".writerpadpromotion"))
        XCTAssertEqual(package.review.packageID, packageID)
        XCTAssertEqual(package.review.sourceLocalID, input.localID)
        XCTAssertEqual(package.review.documents.count, 2)
        XCTAssertEqual(Set(package.files.keys), [
            "manifest.json", "seal.json", "payload/0001.txt", "payload/0002.txt"
        ])

        let byID = Dictionary(
            uniqueKeysWithValues: package.review.documents.map { ($0.sourceDocumentID, $0) }
        )
        XCTAssertEqual(package.files[byID[empty]!.payloadPath], Data())
        XCTAssertEqual(
            package.files[byID[body]!.payloadPath],
            Data("한글\n마지막 LF\n".utf8)
        )
        XCTAssertNoThrow(try ReceiveEditablePromotion.validate(
            files: package.files,
            fileName: package.fileName
        ))
        XCTAssertNoThrow(try package.verifyCurrent(input))
        XCTAssertEqual(try SafeFiles.read(identityURL), identityBefore)
        XCTAssertEqual(try SafeFiles.read(workspaceURL), workspaceBefore)
    }

    func testManifestKeepsSourceHashesButDoesNotReuseThemAsPackageIdentity() throws {
        let (input, drafts, _, body) = try input()
        let package = try ReceiveEditablePromotion.prepare(
            input: input,
            draftTexts: drafts,
            packageID: UUID()
        )
        let document = package.review.documents.first { $0.sourceDocumentID == body }!
        let source = input.source.documents.first { $0.id == body }!
        let editable = input.editable.documents.first { $0.id == body }!
        XCTAssertEqual(document.sourceBodySHA256, byteHash(Data(source.text.utf8)))
        XCTAssertEqual(document.editableBodySHA256, byteHash(Data(editable.text.utf8)))
        XCTAssertNotEqual(package.review.packageID, body)
    }

    func testUnsavedOrIncompleteDraftSetIsRejected() throws {
        let (input, drafts, empty, body) = try input()
        var changed = drafts
        changed[body] = "미저장 변경"
        XCTAssertThrowsError(try ReceiveEditablePromotion.prepare(
            input: input,
            draftTexts: changed
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .unsavedDraft)
        }

        var missing = drafts
        missing.removeValue(forKey: empty)
        XCTAssertThrowsError(try ReceiveEditablePromotion.prepare(
            input: input,
            draftTexts: missing
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .unsavedDraft)
        }
    }

    func testPayloadMutationAndPartialPayloadAreRejected() throws {
        let (input, drafts, _, _) = try input()
        let package = try ReceiveEditablePromotion.prepare(input: input, draftTexts: drafts)
        let payloadPath = package.review.documents.first { $0.byteCount > 0 }!.payloadPath

        var changed = package.files
        changed[payloadPath] = Data("바뀐 본문".utf8)
        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: changed,
            fileName: package.fileName
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .payload)
        }

        var missing = package.files
        missing.removeValue(forKey: payloadPath)
        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: missing,
            fileName: package.fileName
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .structure)
        }
    }

    func testUnknownPathAndNonCanonicalManifestAreRejected() throws {
        let (input, drafts, _, _) = try input()
        let package = try ReceiveEditablePromotion.prepare(input: input, draftTexts: drafts)

        var unknown = package.files
        unknown["payload/extra.txt"] = Data()
        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: unknown,
            fileName: package.fileName
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .structure)
        }

        var nonCanonical = package.files
        nonCanonical["manifest.json"] = Data(
            String(decoding: package.files["manifest.json"]!, as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " \n")
                .utf8
        )
        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: nonCanonical,
            fileName: package.fileName
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .manifest)
        }
    }

    func testSealMutationAndWrongExtensionAreRejected() throws {
        let (input, drafts, _, _) = try input()
        let package = try ReceiveEditablePromotion.prepare(input: input, draftTexts: drafts)

        var changed = package.files
        var seal = changed["seal.json"]!
        seal[seal.startIndex] ^= 1
        changed["seal.json"] = seal
        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: changed,
            fileName: package.fileName
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .seal)
        }

        XCTAssertThrowsError(try ReceiveEditablePromotion.validate(
            files: package.files,
            fileName: "작품.txt"
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .name)
        }
    }

    func testNameCollisionAfterUnicodeNormalizationIsRejected() throws {
        let (verified, _, _, _) = try input()
        let first = verified.editable.documents[0]
        let second = verified.editable.documents[1]
        let collision = ReceiveEditablePromotionInput(
            localID: verified.localID,
            source: .init(
                runID: verified.source.runID,
                folderName: verified.source.folderName,
                documents: [
                    .init(id: first.id, name: "É.txt", text: "", byteCount: 0),
                    .init(id: second.id, name: "E\u{301}.txt", text: "", byteCount: 0)
                ]
            ),
            editable: .init(
                sourceRun: verified.editable.sourceRun,
                folderName: verified.editable.folderName,
                documents: [
                    .init(id: first.id, name: "É.txt", text: "", revision: 0),
                    .init(id: second.id, name: "E\u{301}.txt", text: "", revision: 0)
                ]
            ),
            identitySHA256: verified.identitySHA256,
            workspaceSHA256: verified.workspaceSHA256
        )
        let drafts = [first.id: "", second.id: ""]
        XCTAssertThrowsError(try ReceiveEditablePromotion.prepare(
            input: collision,
            draftTexts: drafts
        )) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .name)
        }
    }

    func testCurrentWorkspaceHashChangeBlocksCompletion() throws {
        let (input, drafts, _, body) = try input()
        let package = try ReceiveEditablePromotion.prepare(input: input, draftTexts: drafts)
        var documents = input.editable.documents
        let index = documents.firstIndex { $0.id == body }!
        documents[index] = .init(
            id: body,
            name: documents[index].name,
            text: "후속 저장",
            revision: documents[index].revision + 1
        )
        let changed = ReceiveEditablePromotionInput(
            localID: input.localID,
            source: input.source,
            editable: .init(
                sourceRun: input.editable.sourceRun,
                folderName: input.editable.folderName,
                documents: documents
            ),
            identitySHA256: input.identitySHA256,
            workspaceSHA256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try package.verifyCurrent(changed)) {
            XCTAssertEqual($0 as? ReceiveEditablePromotionError, .workspaceChanged)
        }
    }

    func testFileWrapperContainsOnlyClosedPackageInventory() throws {
        let (input, drafts, _, _) = try input()
        let package = try ReceiveEditablePromotion.prepare(input: input, draftTexts: drafts)
        let wrapper = try package.fileWrapper()
        let root = try XCTUnwrap(wrapper.fileWrappers)
        XCTAssertEqual(Set(root.keys), ["manifest.json", "seal.json", "payload"])
        XCTAssertTrue(root["manifest.json"]?.isRegularFile == true)
        XCTAssertTrue(root["seal.json"]?.isRegularFile == true)
        let payload = try XCTUnwrap(root["payload"]?.fileWrappers)
        XCTAssertEqual(Set(payload.keys), ["0001.txt", "0002.txt"])
        XCTAssertTrue(payload.values.allSatisfy(\.isRegularFile))
    }

    func testProducerBytesMatchSharedWriterPadBridgeFixture() throws {
        let empty = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let body = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let sourceText = "격리 저장 경계 기준"
        let editableText = "한글\n마지막 LF\n"
        let input = ReceiveEditablePromotionInput(
            localID: UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!,
            source: .init(
                runID: "cccccccc-1111-4222-8333-dddddddddddd",
                folderName: "작품명 자동수신저장 격리검증 20260913",
                documents: [
                    .init(id: empty, name: "빈문서.txt", text: "", byteCount: 0),
                    .init(
                        id: body,
                        name: "저장경계.txt",
                        text: sourceText,
                        byteCount: Data(sourceText.utf8).count
                    )
                ]
            ),
            editable: .init(
                sourceRun: "cccccccc-1111-4222-8333-dddddddddddd",
                folderName: "작품명 자동수신저장 격리검증 20260913",
                documents: [
                    .init(id: empty, name: "빈문서.txt", text: "", revision: 0),
                    .init(id: body, name: "저장경계.txt", text: editableText, revision: 1)
                ]
            ),
            identitySHA256: String(repeating: "a", count: 64),
            workspaceSHA256: String(repeating: "b", count: 64)
        )
        let package = try ReceiveEditablePromotion.prepare(
            input: input,
            draftTexts: [empty: "", body: editableText],
            packageID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )
        let fixture = sharedBridgeFixture()
        let fixturePairs: [(String, Data)] = try FileManager.default
            .subpathsOfDirectory(atPath: fixture.path).compactMap { path -> (String, Data)? in
                let url = fixture.appendingPathComponent(path)
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
                else { return nil }
                return (path, try Data(contentsOf: url))
            }
        let fixtureFiles = Dictionary(uniqueKeysWithValues: fixturePairs)
        XCTAssertEqual(package.fileName, "작품명 자동수신저장 격리검증 20260913-WriterPad승격.writerpadpromotion")
        XCTAssertEqual(package.files, fixtureFiles)
    }

    private func sharedBridgeFixture() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent(
            "TestFixtures/ReceivePromotionBridge.writerpadpromotion",
            isDirectory: true
        )
    }
}
