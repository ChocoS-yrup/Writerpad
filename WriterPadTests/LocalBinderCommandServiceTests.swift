import Foundation
import SwiftData
import XCTest
@testable import WriterPad

final class LocalBinderCommandServiceTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    func testCreateFolderAndTextWritesDiskAndMetadata() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)

        let folderResult = try await harness.commands.create(
            kind: .folder,
            named: "자료",
            in: notes.id,
            projectID: harness.project.id
        )
        let textResult = try await harness.commands.create(
            kind: .text,
            named: "첫 메모",
            in: folderResult.affectedDocumentID,
            projectID: harness.project.id
        )

        XCTAssertTrue(fileExists("\(folderResult.relativePath.rawValue)" , harness: harness))
        XCTAssertTrue(fileExists(textResult.relativePath.rawValue, harness: harness))
        XCTAssertEqual(textResult.relativePath.rawValue, "메인/메모장/자료/첫 메모.txt")
        let storedText = try await harness.repository.document(id: textResult.affectedDocumentID)
        XCTAssertEqual(storedText?.parentID, folderResult.affectedDocumentID)
    }

    func testRenamePreservesDocumentIDAndContent() async throws {
        let harness = try await makeHarness()
        try writeText("본문", at: "메인/메모장/초안.txt", harness: harness)
        let notes = try await fixedRoot(.notes, harness: harness)
        let noteChildren = try await harness.binder.children(
            of: notes.id,
            in: harness.project.id
        )
        let before = try XCTUnwrap(noteChildren.first)

        let result = try await harness.commands.rename(
            documentID: before.id,
            to: "완성",
            projectID: harness.project.id
        )
        let storedAfter = try await harness.repository.document(id: before.id)
        let after = try XCTUnwrap(storedAfter)

        XCTAssertEqual(result.affectedDocumentID, before.id)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.relativePath.rawValue, "메인/메모장/완성.txt")
        XCTAssertEqual(try String(contentsOf: fileURL(after.relativePath.rawValue, harness: harness)), "본문")
        XCTAssertFalse(fileExists("메인/메모장/초안.txt", harness: harness))
    }

    func testLargeSubtreeMovePreservesEveryKnownID() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)
        try FileManager.default.createDirectory(
            at: fileURL("메인/메모장/대규모", harness: harness),
            withIntermediateDirectories: true
        )
        for number in 1...200 {
            try writeText("본문 \(number)", at: "메인/메모장/대규모/\(number).txt", harness: harness)
        }
        let folders = try await harness.binder.children(of: notes.id, in: harness.project.id)
        let source = try XCTUnwrap(folders.first)
        _ = try await harness.binder.children(of: source.id, in: harness.project.id)
        let before = try await harness.repository.documents(in: harness.project.id)
            .filter { $0.relativePath.rawValue.hasPrefix("메인/메모장/대규모") }
        let ids = Set(before.map(\.id))

        _ = try await harness.commands.move(
            documentID: source.id,
            to: .folder(settings.id),
            projectID: harness.project.id
        )
        let after = try await harness.repository.documents(in: harness.project.id)
            .filter { ids.contains($0.id) }

        XCTAssertEqual(after.count, 201)
        XCTAssertEqual(Set(after.map(\.id)), ids)
        XCTAssertTrue(after.allSatisfy { $0.relativePath.rawValue.hasPrefix("메인/설정집/대규모") })
        XCTAssertTrue(fileExists("메인/설정집/대규모/200.txt", harness: harness))
    }

    func testDuplicateAndForbiddenNamesDoNotOverwriteAndOfferSafeAlternative() async throws {
        let harness = try await makeHarness()
        try writeText("기존", at: "메인/메모장/메모.txt", harness: harness)
        let notes = try await fixedRoot(.notes, harness: harness)
        _ = try await harness.binder.children(of: notes.id, in: harness.project.id)

        do {
            _ = try await harness.commands.create(
                kind: .text,
                named: "메모",
                in: notes.id,
                projectID: harness.project.id
            )
            XCTFail("중복 이름이 통과했습니다.")
        } catch let error as BinderCommandError {
            guard case let .ruleDenied(_, suggestion) = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
            XCTAssertEqual(suggestion, "메모 2.txt")
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await harness.commands.create(
                kind: .folder,
                named: "CON",
                in: notes.id,
                projectID: harness.project.id
            )
        }
        XCTAssertEqual(try String(contentsOf: fileURL("메인/메모장/메모.txt", harness: harness)), "기존")
    }

    func testInvalidDropsAndSelfDescendantMoveAreRejected() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let parent = try await harness.commands.create(
            kind: .folder,
            named: "부모",
            in: notes.id,
            projectID: harness.project.id
        )
        let child = try await harness.commands.create(
            kind: .folder,
            named: "자식",
            in: parent.affectedDocumentID,
            projectID: harness.project.id
        )

        await assertBinderError(.unresolvedDropTarget) {
            _ = try await harness.commands.move(
                documentID: parent.affectedDocumentID,
                to: .unresolved,
                projectID: harness.project.id
            )
        }
        await assertBinderError(.destinationOutsideProject) {
            _ = try await harness.commands.move(
                documentID: parent.affectedDocumentID,
                to: .outsideProject,
                projectID: harness.project.id
            )
        }
        await assertBinderError(.folderCannotMoveIntoItself) {
            _ = try await harness.commands.move(
                documentID: parent.affectedDocumentID,
                to: .folder(child.affectedDocumentID),
                projectID: harness.project.id
            )
        }
    }

    func testOpenDocumentMoveIsRejected() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)
        let text = try await harness.commands.create(
            kind: .text,
            named: "열린 문서",
            in: notes.id,
            projectID: harness.project.id
        )
        try await harness.repository.saveEditorState(
            EditorWorkspaceState(
                projectID: harness.project.id,
                left: EditorPaneState(documentID: text.affectedDocumentID, cursor: .start),
                right: nil,
                activePane: .left
            )
        )

        do {
            _ = try await harness.commands.move(
                documentID: text.affectedDocumentID,
                to: .folder(settings.id),
                projectID: harness.project.id
            )
            XCTFail("열린 문서가 이동됐습니다.")
        } catch let error as BinderCommandError {
            guard case .openDocument = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    func testPendingFileMoveCommitsMetadataDuringRecovery() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)
        let text = try await harness.commands.create(
            kind: .text,
            named: "복구 대상",
            in: notes.id,
            projectID: harness.project.id
        )

        let recovery = harness.makeCommands(faultPlan: nil)
        let storedCreated = try await harness.repository.document(id: text.affectedDocumentID)
        let created = try XCTUnwrap(storedCreated)

        let failingMove = harness.makeCommands(
            faultPlan: BinderCommandFaultPlan(
                point: .afterFileMutation,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await failingMove.move(
                documentID: created.id,
                to: .folder(settings.id),
                projectID: harness.project.id
            )
            XCTFail("테스트용 중단이 발생하지 않았습니다.")
        } catch let error as BinderCommandError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        XCTAssertTrue(fileExists("메인/설정집/복구 대상.txt", harness: harness))
        let beforeRecovery = try await harness.repository.document(id: created.id)
        XCTAssertEqual(beforeRecovery?.relativePath.rawValue, "메인/메모장/복구 대상.txt")

        try await recovery.recoverPendingTransactions(in: harness.project.id)
        let afterRecovery = try await harness.repository.document(id: created.id)
        XCTAssertEqual(afterRecovery?.relativePath.rawValue, "메인/설정집/복구 대상.txt")
        XCTAssertTrue(try journalFiles(harness: harness).isEmpty)
    }

    func testMoveToTrashPreservesIDAndOriginalPath() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let text = try await harness.commands.create(
            kind: .text,
            named: "지울 문서",
            in: notes.id,
            projectID: harness.project.id
        )

        let result = try await harness.commands.moveToTrash(
            documentID: text.affectedDocumentID,
            projectID: harness.project.id
        )
        let storedTrashed = try await harness.repository.document(id: text.affectedDocumentID)
        let trashed = try XCTUnwrap(storedTrashed)

        XCTAssertEqual(result.affectedDocumentID, text.affectedDocumentID)
        XCTAssertEqual(trashed.relativePath.rawValue, "메인/휴지통/지울 문서.txt")
        guard case let .trashed(originalPath, _) = trashed.deletionStatus else {
            return XCTFail("휴지통 상태가 저장되지 않았습니다.")
        }
        XCTAssertEqual(originalPath.rawValue, "메인/메모장/지울 문서.txt")
    }

    func testGeneralChildrenCanReorderButManuscriptCannot() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let first = try await harness.commands.create(
            kind: .text, named: "하나", in: notes.id, projectID: harness.project.id
        )
        let second = try await harness.commands.create(
            kind: .text, named: "둘", in: notes.id, projectID: harness.project.id
        )

        try await harness.commands.reorder(
            childIDs: [second.affectedDocumentID, first.affectedDocumentID],
            in: notes.id,
            projectID: harness.project.id
        )
        let children = try await harness.binder.children(of: notes.id, in: harness.project.id)
        XCTAssertEqual(children.map(\.id), [second.affectedDocumentID, first.affectedDocumentID])

        let manuscript = try await fixedRoot(.manuscript, harness: harness)
        let volume = try await harness.commands.create(
            kind: .folder, named: "1권", in: manuscript.id, projectID: harness.project.id
        )
        await XCTAssertThrowsErrorAsync {
            try await harness.commands.reorder(
                childIDs: [volume.affectedDocumentID],
                in: manuscript.id,
                projectID: harness.project.id
            )
        }
    }

    private struct Harness {
        let root: URL
        let repository: SwiftDataMetadataRepository
        let resolver: ProjectPathResolver
        let binder: LocalBinderRepository
        let commands: LocalBinderCommandService
        let locator: RepositoryProjectWorkspaceLocator
        let project: ManagedProject
        let workspace: URL
        let clock: FixedClock

        func makeCommands(faultPlan: BinderCommandFaultPlan?) -> LocalBinderCommandService {
            LocalBinderCommandService(
                metadataStore: repository,
                workspaceStateRepository: repository,
                workspaceLocator: locator,
                pathPolicy: resolver.policy,
                clock: clock,
                faultPlan: faultPlan
            )
        }
    }

    private struct FixedClock: AppClock {
        let date = Date(timeIntervalSince1970: 8_000)
        func now() -> Date { date }
    }

    private func makeHarness(
        faultPlan: BinderCommandFaultPlan? = nil
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-BinderCommands-\(UUID().uuidString)")
        roots.append(root)
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let resolver = ProjectPathResolver(projectsRootURL: root.appendingPathComponent("Projects"))
        let clock = FixedClock()
        let manager = LocalProjectManager(
            projectRepository: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: clock
        )
        let project = try await manager.createProject(named: "명령 테스트")
        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: resolver
        )
        let binder = LocalBinderRepository(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            scanner: LocalBinderDirectoryScanner(pathResolver: resolver),
            pathPolicy: resolver.policy,
            clock: clock
        )
        let commands = LocalBinderCommandService(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            pathPolicy: resolver.policy,
            clock: clock,
            faultPlan: faultPlan
        )
        let workspace = try resolver.standardPaths(
            forProjectNamed: project.name
        ).workspaceRootURL
        _ = try await binder.rootNodes(in: project.id)
        return Harness(
            root: root,
            repository: repository,
            resolver: resolver,
            binder: binder,
            commands: commands,
            locator: locator,
            project: project,
            workspace: workspace,
            clock: clock
        )
    }

    private func fixedRoot(
        _ category: BinderFixedCategory,
        harness: Harness
    ) async throws -> BinderNode {
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        return try XCTUnwrap(roots.first { $0.fixedCategory == category })
    }

    private func fileURL(_ path: String, harness: Harness) -> URL {
        harness.workspace.appendingPathComponent(path)
    }

    private func fileExists(_ path: String, harness: Harness) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(path, harness: harness).path)
    }

    private func writeText(_ text: String, at path: String, harness: Harness) throws {
        let url = fileURL(path, harness: harness)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    private func journalFiles(harness: Harness) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: harness.workspace.path)
            .filter { $0.hasPrefix(".writerpad-binder-transaction-") }
    }

    private func assertBinderError(
        _ expected: BinderCommandError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("예상한 오류가 발생하지 않았습니다.")
        } catch let error as BinderCommandError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("예상한 오류가 발생하지 않았습니다.", file: file, line: line)
    } catch {
        // expected
    }
}
