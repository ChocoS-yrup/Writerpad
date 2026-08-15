import Foundation
import XCTest
@testable import WriterPad

final class IndependentProjectBackupStoreTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testCreatesIndependentReadablePackageAndRestoresExactStructure() async throws {
        let fixture = try makeFixture()
        let before = try regularFileContents(under: fixture.workspaceRoot)
        let packageURL = fixture.container.appendingPathComponent("독립백업-v1")
        let store = makeStore(fixture)

        let backup = try await store.createBackup(
            project: fixture.project,
            documents: fixture.documents,
            at: packageURL
        )

        XCTAssertEqual(backup.packageURL, packageURL.standardizedFileURL)
        XCTAssertEqual(backup.manifest.formatVersion, 1)
        XCTAssertEqual(backup.manifest.project, fixture.project)
        XCTAssertEqual(backup.manifest.entries.count, fixture.documents.count)
        XCTAssertEqual(
            try regularFileContents(under: fixture.workspaceRoot),
            before,
            "독립 백업은 원본 workspace를 변경하면 안 됩니다."
        )
        XCTAssertFalse(
            packageURL.path.hasPrefix(fixture.workspaceRoot.path + "/")
        )

        let chapterEntry = try XCTUnwrap(
            backup.manifest.entries.first {
                $0.node.relativePath == fixture.chapterPath
            }
        )
        XCTAssertEqual(chapterEntry.node.id, fixture.chapterID)
        XCTAssertEqual(chapterEntry.node.parentID, fixture.volumeID)
        XCTAssertEqual(chapterEntry.content?.utf8ByteCount, Data(fixture.chapterText.utf8).count)
        XCTAssertEqual(
            chapterEntry.content?.sha256,
            SHA256ContentHasher().sha256(for: Data(fixture.chapterText.utf8))
        )
        XCTAssertEqual(
            try String(
                contentsOf: packageURL.appendingPathComponent(
                    "files/\(fixture.chapterPath.rawValue)"
                ),
                encoding: .utf8
            ),
            fixture.chapterText
        )

        let restoredURL = fixture.container.appendingPathComponent("복구-검증")
        let restore = try await store.restoreVerifiedBackup(
            at: packageURL,
            to: restoredURL
        )

        XCTAssertEqual(restore.manifest, backup.manifest)
        XCTAssertEqual(restore.restoredWorkspaceURL, restoredURL.standardizedFileURL)
        XCTAssertEqual(
            restore.identityManifestURL.lastPathComponent,
            IndependentProjectBackupStore.restoredIdentityManifestFileName
        )
        XCTAssertEqual(
            try String(
                contentsOf: restoredURL.appendingPathComponent(
                    fixture.chapterPath.rawValue
                ),
                encoding: .utf8
            ),
            fixture.chapterText
        )
        XCTAssertEqual(
            try Data(
                contentsOf: restoredURL.appendingPathComponent(
                    fixture.emptyDocumentPath.rawValue
                )
            ).count,
            0
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: restoredURL.appendingPathComponent(
                    fixture.volumePath.rawValue
                ).path
            )
        )
        XCTAssertEqual(
            try regularFileContents(under: fixture.workspaceRoot),
            before,
            "복구 시연도 원본 workspace를 변경하면 안 됩니다."
        )
    }

    func testRejectsExistingBackupAndRestoreDestinationsWithoutOverwriting() async throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let existingBackup = fixture.container.appendingPathComponent("기존-백업")
        try FileManager.default.createDirectory(at: existingBackup, withIntermediateDirectories: false)
        let sentinel = existingBackup.appendingPathComponent("사용자.txt")
        try Data("보존".utf8).write(to: sentinel)

        do {
            _ = try await store.createBackup(
                project: fixture.project,
                documents: fixture.documents,
                at: existingBackup
            )
            XCTFail("기존 백업 목적지를 덮어썼습니다.")
        } catch let error as IndependentProjectBackupError {
            guard case .destinationAlreadyExists = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "보존")

        let packageURL = fixture.container.appendingPathComponent("새-백업")
        _ = try await store.createBackup(
            project: fixture.project,
            documents: fixture.documents,
            at: packageURL
        )
        let existingRestore = fixture.container.appendingPathComponent("기존-복구")
        try FileManager.default.createDirectory(at: existingRestore, withIntermediateDirectories: false)
        let restoreSentinel = existingRestore.appendingPathComponent("사용자.txt")
        try Data("복구 보존".utf8).write(to: restoreSentinel)

        do {
            _ = try await store.restoreVerifiedBackup(
                at: packageURL,
                to: existingRestore
            )
            XCTFail("기존 복구 목적지를 덮어썼습니다.")
        } catch let error as IndependentProjectBackupError {
            guard case .destinationAlreadyExists = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: restoreSentinel, encoding: .utf8),
            "복구 보존"
        )
    }

    func testRejectsBackupInsideSourceWorkspace() async throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let localBackupParent = fixture.workspaceRoot.appendingPathComponent("백업")
        try FileManager.default.createDirectory(
            at: localBackupParent,
            withIntermediateDirectories: true
        )

        do {
            _ = try await store.createBackup(
                project: fixture.project,
                documents: fixture.documents,
                at: localBackupParent.appendingPathComponent("독립인척하는백업")
            )
            XCTFail("workspace 내부에 독립 백업을 만들었습니다.")
        } catch let error as IndependentProjectBackupError {
            guard case .destinationInsideWorkspace = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    func testCorruptPackageFailsVerificationBeforeRestoreCreation() async throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let packageURL = fixture.container.appendingPathComponent("손상-백업")
        _ = try await store.createBackup(
            project: fixture.project,
            documents: fixture.documents,
            at: packageURL
        )
        try Data("손상된 본문".utf8).write(
            to: packageURL.appendingPathComponent(
                "files/\(fixture.chapterPath.rawValue)"
            ),
            options: [.atomic]
        )
        let restoreURL = fixture.container.appendingPathComponent("생기면-안되는-복구")

        do {
            _ = try await store.restoreVerifiedBackup(
                at: packageURL,
                to: restoreURL
            )
            XCTFail("손상된 백업을 복원했습니다.")
        } catch let error as IndependentProjectBackupError {
            XCTAssertEqual(
                error,
                .contentHashMismatch(fixture.chapterPath.rawValue)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoreURL.path))
    }

    func testMetadataHashMismatchFailsClosedAndRemovesOnlyOwnedPartialDirectory() async throws {
        let fixture = try makeFixture(recordedChapterHash: ContentHash(
            rawValue: String(repeating: "0", count: 64)
        ))
        let store = makeStore(fixture)
        let packageURL = fixture.container.appendingPathComponent("실패-백업")
        let before = try regularFileContents(under: fixture.workspaceRoot)

        do {
            _ = try await store.createBackup(
                project: fixture.project,
                documents: fixture.documents,
                at: packageURL
            )
            XCTFail("메타데이터와 다른 본문 hash를 허용했습니다.")
        } catch let error as IndependentProjectBackupError {
            XCTAssertEqual(
                error,
                .contentHashMismatch(fixture.chapterPath.rawValue)
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        let partials = try FileManager.default.contentsOfDirectory(
            at: fixture.container,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial-") }
        XCTAssertTrue(partials.isEmpty)
        XCTAssertEqual(try regularFileContents(under: fixture.workspaceRoot), before)
    }

    func testRejectsDuplicatePathAndMissingParentBeforeWriting() async throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let duplicate = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: fixture.project.id,
            kind: .text,
            parentID: fixture.volumeID,
            relativePath: fixture.chapterPath,
            userOrder: 99,
            modifiedAt: fixture.now,
            contentHash: nil
        )
        let duplicateURL = fixture.container.appendingPathComponent("중복-백업")
        do {
            _ = try await store.createBackup(
                project: fixture.project,
                documents: fixture.documents + [duplicate],
                at: duplicateURL
            )
            XCTFail("중복 상대 경로를 허용했습니다.")
        } catch let error as IndependentProjectBackupError {
            XCTAssertEqual(error, .duplicateRelativePath(fixture.chapterPath.rawValue))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicateURL.path))

        var missingParentDocuments = fixture.documents
        if let index = missingParentDocuments.firstIndex(where: { $0.id == fixture.chapterID }) {
            let original = missingParentDocuments[index]
            missingParentDocuments[index] = DocumentNode(
                id: original.id,
                projectID: original.projectID,
                kind: original.kind,
                parentID: DocumentID(rawValue: UUID()),
                relativePath: original.relativePath,
                userOrder: original.userOrder,
                modifiedAt: original.modifiedAt,
                contentHash: original.contentHash
            )
        }
        let missingParentURL = fixture.container.appendingPathComponent("부모없음-백업")
        do {
            _ = try await store.createBackup(
                project: fixture.project,
                documents: missingParentDocuments,
                at: missingParentURL
            )
            XCTFail("없는 부모 ID를 허용했습니다.")
        } catch let error as IndependentProjectBackupError {
            guard case .missingParent = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParentURL.path))
    }

    func testUnexpectedFileAndSymbolicLinkAreRejected() async throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let packageURL = fixture.container.appendingPathComponent("검증-백업")
        _ = try await store.createBackup(
            project: fixture.project,
            documents: fixture.documents,
            at: packageURL
        )
        let unexpected = packageURL.appendingPathComponent("메모.txt")
        try Data("manifest에 없음".utf8).write(to: unexpected)
        do {
            _ = try await store.verifyBackup(at: packageURL)
            XCTFail("manifest에 없는 파일을 허용했습니다.")
        } catch let error as IndependentProjectBackupError {
            XCTAssertEqual(error, .unexpectedPackageFile("메모.txt"))
        }
        try FileManager.default.removeItem(at: unexpected)

        let link = packageURL.appendingPathComponent("files/링크.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: packageURL.appendingPathComponent(
                "files/\(fixture.chapterPath.rawValue)"
            )
        )
        do {
            _ = try await store.verifyBackup(at: packageURL)
            XCTFail("symbolic link를 허용했습니다.")
        } catch let error as IndependentProjectBackupError {
            guard case .symbolicLinkNotAllowed = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    func testDefaultThirtyDayRetentionReturnsCandidatesWithoutDeleting() throws {
        let root = try makeTemporaryRoot()
        let now = Date(timeIntervalSince1970: 10_000_000)
        let old = root.appendingPathComponent("old")
        let boundary = root.appendingPathComponent("boundary")
        let recent = root.appendingPathComponent("recent")
        let pinned = root.appendingPathComponent("pinned")
        for url in [old, boundary, recent, pinned] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let items = [
            IndependentProjectBackupInventoryItem(
                packageURL: old,
                createdAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
                isPinned: false
            ),
            IndependentProjectBackupInventoryItem(
                packageURL: boundary,
                createdAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
                isPinned: false
            ),
            IndependentProjectBackupInventoryItem(
                packageURL: recent,
                createdAt: now.addingTimeInterval(-2 * 24 * 60 * 60),
                isPinned: false
            ),
            IndependentProjectBackupInventoryItem(
                packageURL: pinned,
                createdAt: now.addingTimeInterval(-90 * 24 * 60 * 60),
                isPinned: true
            ),
        ]

        let candidates = IndependentProjectBackupRetention.candidates(
            from: items,
            now: now
        )

        XCTAssertEqual(candidates.map(\.packageURL), [old])
        for url in [old, boundary, recent, pinned] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "A1 retention은 후보 계산만 하고 기존 백업을 삭제하면 안 됩니다."
            )
        }
    }

    private func makeStore(_ fixture: Fixture) -> IndependentProjectBackupStore {
        IndependentProjectBackupStore(
            workspaceLocator: FixedWorkspaceLocator(root: fixture.workspaceRoot),
            clock: FixedClock(date: fixture.now),
            uuidGenerator: FixedUUIDGenerator(uuid: fixture.backupID)
        )
    }

    private func makeFixture(
        recordedChapterHash: ContentHash? = nil
    ) throws -> Fixture {
        let container = try makeTemporaryRoot()
        let workspaceRoot = container.appendingPathComponent("원본/집필모드")
        let mainPath = RelativeDocumentPath(rawValue: "메인")
        let manuscriptPath = RelativeDocumentPath(rawValue: "메인/원고")
        let volumePath = RelativeDocumentPath(rawValue: "메인/원고/1권")
        let chapterPath = RelativeDocumentPath(rawValue: "메인/원고/1권/001화.txt")
        let emptyPath = RelativeDocumentPath(rawValue: "메인/원고/1권/002화.txt")
        let notesPath = RelativeDocumentPath(rawValue: "메인/메모장")
        let notePath = RelativeDocumentPath(rawValue: "메인/메모장/등장인물.txt")
        for path in [mainPath, manuscriptPath, volumePath, notesPath] {
            try FileManager.default.createDirectory(
                at: workspaceRoot.appendingPathComponent(path.rawValue),
                withIntermediateDirectories: true
            )
        }
        let chapterText = "첫 문장🙂\n둘째 문장\n"
        let noteText = "주인공: 윤슬\n"
        try Data(chapterText.utf8).write(
            to: workspaceRoot.appendingPathComponent(chapterPath.rawValue)
        )
        try Data().write(
            to: workspaceRoot.appendingPathComponent(emptyPath.rawValue)
        )
        try Data(noteText.utf8).write(
            to: workspaceRoot.appendingPathComponent(notePath.rawValue)
        )

        let projectID = ProjectID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let mainID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!)
        let manuscriptID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)
        let volumeID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!)
        let chapterID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!)
        let emptyID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000005")!)
        let notesID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000006")!)
        let noteID = DocumentID(rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000007")!)
        let now = Date(timeIntervalSince1970: 10_000_000)
        let hasher = SHA256ContentHasher()
        let project = Project(
            id: projectID,
            name: "합성 백업 작품",
            createdAt: now.addingTimeInterval(-10_000),
            modifiedAt: now
        )
        let documents = [
            node(mainID, projectID, .folder, nil, mainPath, 0, now, nil),
            node(manuscriptID, projectID, .folder, mainID, manuscriptPath, 0, now, nil),
            node(volumeID, projectID, .folder, manuscriptID, volumePath, 0, now, nil),
            node(
                chapterID, projectID, .text, volumeID, chapterPath, 0, now,
                recordedChapterHash
                    ?? hasher.sha256(for: Data(chapterText.utf8))
            ),
            node(
                emptyID, projectID, .text, volumeID, emptyPath, 1, now,
                hasher.sha256(for: Data())
            ),
            node(notesID, projectID, .folder, mainID, notesPath, 1, now, nil),
            node(
                noteID, projectID, .text, notesID, notePath, 0, now,
                hasher.sha256(for: Data(noteText.utf8))
            ),
        ]
        return Fixture(
            container: container,
            workspaceRoot: workspaceRoot,
            project: project,
            documents: documents,
            now: now,
            backupID: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            volumeID: volumeID,
            chapterID: chapterID,
            volumePath: volumePath,
            chapterPath: chapterPath,
            emptyDocumentPath: emptyPath,
            chapterText: chapterText
        )
    }

    private func node(
        _ id: DocumentID,
        _ projectID: ProjectID,
        _ kind: DocumentKind,
        _ parentID: DocumentID?,
        _ path: RelativeDocumentPath,
        _ order: Int,
        _ modifiedAt: Date,
        _ hash: ContentHash?
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: kind,
            parentID: parentID,
            relativePath: path,
            userOrder: order,
            modifiedAt: modifiedAt,
            contentHash: hash
        )
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WriterPadIndependentBackupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        temporaryRoots.append(root)
        return root
    }

    private func regularFileContents(under root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let item as URL in enumerator {
            let type = try FileManager.default.attributesOfItem(atPath: item.path)[.type]
                as? FileAttributeType
            guard type == .typeRegular else { continue }
            let relative = String(item.path.dropFirst(root.path.count + 1))
            result[relative] = try Data(contentsOf: item)
        }
        return result
    }
}
private struct Fixture {
    let container: URL
    let workspaceRoot: URL
    let project: Project
    let documents: [DocumentNode]
    let now: Date
    let backupID: UUID
    let volumeID: DocumentID
    let chapterID: DocumentID
    let volumePath: RelativeDocumentPath
    let chapterPath: RelativeDocumentPath
    let emptyDocumentPath: RelativeDocumentPath
    let chapterText: String
}
