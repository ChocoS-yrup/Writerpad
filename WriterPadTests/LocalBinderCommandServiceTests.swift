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

    /// Windows 탐색기는 끝 공백을 조용히 잘라내므로 앱이 그대로 두면 두 기기의
    /// 이름이 갈라진다. 실기기에서는 서버에 끝 공백 이름이 박혀 구조 동기화가
    /// 멈추기까지 했다. 디스크와 메타데이터 모두 잘라낸 이름으로 남아야 한다.
    func testTrailingSpaceIsTrimmedBeforeDiskAndMetadata() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)

        let folder = try await harness.commands.create(
            kind: .folder,
            named: "가 나 다 라 ",
            in: notes.id,
            projectID: harness.project.id
        )

        XCTAssertEqual(
            folder.relativePath.rawValue,
            "메인/메모장/가 나 다 라"
        )
        XCTAssertTrue(
            fileExists("메인/메모장/가 나 다 라", harness: harness)
        )
        XCTAssertFalse(
            fileExists("메인/메모장/가 나 다 라 ", harness: harness)
        )

        let renamed = try await harness.commands.rename(
            documentID: folder.affectedDocumentID,
            to: "가 나 다 마  ",
            projectID: harness.project.id
        )

        XCTAssertEqual(
            renamed.relativePath.rawValue,
            "메인/메모장/가 나 다 마"
        )
        XCTAssertEqual(
            renamed.affectedDocumentID,
            folder.affectedDocumentID,
            "이름을 바꿔도 폴더 식별자는 그대로여야 한다."
        )
    }

    /// 지원하지 않는 이름이면 파일 시스템도 메타데이터도 건드리지 않아야 한다.
    func testUnsupportedNameChangesNeitherDiskNorMetadata() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let folder = try await harness.commands.create(
            kind: .folder,
            named: "원래이름",
            in: notes.id,
            projectID: harness.project.id
        )

        for rejected in ["   ", "메모.", "CON", "CLOCK$", "메모?", "메모|"] {
            await XCTAssertThrowsErrorAsync {
                _ = try await harness.commands.rename(
                    documentID: folder.affectedDocumentID,
                    to: rejected,
                    projectID: harness.project.id
                )
            }
        }

        let stored = try await harness.repository.document(
            id: folder.affectedDocumentID
        )
        XCTAssertEqual(stored?.relativePath.rawValue, "메인/메모장/원래이름")
        XCTAssertTrue(fileExists("메인/메모장/원래이름", harness: harness))
    }

    /// 화면에는 사유별 문구 대신 한 문장으로 보여준다. 표시 후 2초 뒤 자동으로
    /// 사라지는 것은 BinderPanel의 기존 처리와 같다.
    func testUnsupportedNameUsesSingleUserFacingMessage() {
        XCTAssertEqual(
            BinderViewModel.unsupportedNameMessage,
            "지원하지 않는 파일명 입니다."
        )
    }

    func testCreateAutomaticallyNumbersDuplicateTextAndFolderNames() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)

        var textPaths: [String] = []
        for _ in 0..<3 {
            let result = try await harness.commands.create(
                kind: .text,
                named: "새 문서",
                in: notes.id,
                projectID: harness.project.id
            )
            textPaths.append(result.relativePath.rawValue)
        }

        var folderPaths: [String] = []
        for _ in 0..<3 {
            let result = try await harness.commands.create(
                kind: .folder,
                named: "새 폴더",
                in: notes.id,
                projectID: harness.project.id
            )
            folderPaths.append(result.relativePath.rawValue)
        }

        XCTAssertEqual(
            textPaths,
            [
                "메인/메모장/새 문서.txt",
                "메인/메모장/새 문서_2.txt",
                "메인/메모장/새 문서_3.txt"
            ]
        )
        XCTAssertEqual(
            folderPaths,
            [
                "메인/메모장/새 폴더",
                "메인/메모장/새 폴더_2",
                "메인/메모장/새 폴더_3"
            ]
        )
        XCTAssertTrue(fileExists(textPaths[1], harness: harness))
        XCTAssertTrue(fileExists(folderPaths[2], harness: harness))
    }

    func testTopLevelCreationAndMoveAcceptFoldersButRejectDocuments() async throws {
        let harness = try await makeHarness()
        let rootID = try await harness.binder.rootContainerID(in: harness.project.id)
        let notes = try await fixedRoot(.notes, harness: harness)

        await assertBinderError(.topLevelRequiresFolder) {
            _ = try await harness.commands.create(
                kind: .text,
                named: "최상위 문서",
                in: rootID,
                projectID: harness.project.id
            )
        }
        let rootFolder = try await harness.commands.create(
            kind: .folder,
            named: "최상위 폴더",
            in: rootID,
            projectID: harness.project.id
        )
        XCTAssertEqual(rootFolder.relativePath.rawValue, "메인/최상위 폴더")

        let text = try await harness.commands.create(
            kind: .text,
            named: "내부 문서",
            in: notes.id,
            projectID: harness.project.id
        )
        await assertBinderError(.topLevelRequiresFolder) {
            _ = try await harness.commands.move(
                documentID: text.affectedDocumentID,
                to: .topLevel,
                projectID: harness.project.id
            )
        }
        let textAfterRejectedMove = try await harness.repository.document(
            id: text.affectedDocumentID
        )
        XCTAssertEqual(textAfterRejectedMove?.relativePath, text.relativePath)

        let nestedFolder = try await harness.commands.create(
            kind: .folder,
            named: "꺼낼 폴더",
            in: notes.id,
            projectID: harness.project.id
        )
        let moved = try await harness.commands.move(
            documentID: nestedFolder.affectedDocumentID,
            to: .topLevel,
            projectID: harness.project.id
        )
        XCTAssertEqual(moved.relativePath.rawValue, "메인/꺼낼 폴더")
        let movedFolder = try await harness.repository.document(
            id: nestedFolder.affectedDocumentID
        )
        XCTAssertEqual(movedFolder?.parentID, rootID)
    }

    func testRestoreWithUnavailableOriginalParentUsesTopLevelOnlyForFolder() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)

        let folderParent = try await harness.commands.create(
            kind: .folder,
            named: "폴더 부모",
            in: notes.id,
            projectID: harness.project.id
        )
        let childFolder = try await harness.commands.create(
            kind: .folder,
            named: "복원 폴더",
            in: folderParent.affectedDocumentID,
            projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: childFolder.affectedDocumentID,
            projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: folderParent.affectedDocumentID,
            projectID: harness.project.id
        )
        let restoredFolder = try await harness.commands.restoreFromTrash(
            documentID: childFolder.affectedDocumentID,
            toFolderID: nil,
            projectID: harness.project.id
        )
        XCTAssertEqual(restoredFolder.relativePath.rawValue, "메인/복원 폴더")

        let textParent = try await harness.commands.create(
            kind: .folder,
            named: "문서 부모",
            in: notes.id,
            projectID: harness.project.id
        )
        let childText = try await harness.commands.create(
            kind: .text,
            named: "복원 문서",
            in: textParent.affectedDocumentID,
            projectID: harness.project.id
        )
        let trashedText = try await harness.commands.moveToTrash(
            documentID: childText.affectedDocumentID,
            projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: textParent.affectedDocumentID,
            projectID: harness.project.id
        )
        await assertBinderError(.documentCannotRestoreToTopLevel) {
            _ = try await harness.commands.restoreFromTrash(
                documentID: childText.affectedDocumentID,
                toFolderID: nil,
                projectID: harness.project.id
            )
        }
        let textAfterRejectedRestore = try await harness.repository.document(
            id: childText.affectedDocumentID
        )
        XCTAssertEqual(textAfterRejectedRestore?.relativePath, trashedText.relativePath)
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

    func testRenameChapterKeepsStoredPrefixAndNormalizesSuffix() async throws {
        let harness = try await makeHarness()
        let manuscript = try await fixedRoot(.manuscript, harness: harness)
        let volume = try await harness.commands.create(
            kind: .folder,
            named: "1권",
            in: manuscript.id,
            projectID: harness.project.id
        )
        let chapter = try await harness.commands.create(
            kind: .text,
            named: "001화",
            in: volume.affectedDocumentID,
            projectID: harness.project.id
        )

        let result = try await harness.commands.renameChapter(
            documentID: chapter.affectedDocumentID,
            titleSuffix: "  18화에서 회수할 복선  ",
            projectID: harness.project.id
        )

        XCTAssertEqual(result.affectedDocumentID, chapter.affectedDocumentID)
        XCTAssertEqual(result.relativePath.rawValue, "메인/원고/1권/001화 18화에서 회수할 복선.txt")
        XCTAssertTrue(fileExists("메인/원고/1권/001화 18화에서 회수할 복선.txt", harness: harness))
        XCTAssertFalse(fileExists("메인/원고/1권/018화에서 회수할 복선.txt", harness: harness))
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

    func testMoveAutomaticallyNumbersDuplicateTextAndFolderNames() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)

        for _ in 0..<2 {
            _ = try await harness.commands.create(
                kind: .text,
                named: "충돌",
                in: settings.id,
                projectID: harness.project.id
            )
            _ = try await harness.commands.create(
                kind: .folder,
                named: "자료",
                in: settings.id,
                projectID: harness.project.id
            )
        }
        let sourceText = try await harness.commands.create(
            kind: .text,
            named: "충돌",
            in: notes.id,
            projectID: harness.project.id
        )
        try writeText("이동한 본문", at: sourceText.relativePath.rawValue, harness: harness)
        let sourceFolder = try await harness.commands.create(
            kind: .folder,
            named: "자료",
            in: notes.id,
            projectID: harness.project.id
        )
        _ = try await harness.commands.create(
            kind: .text,
            named: "하위 문서",
            in: sourceFolder.affectedDocumentID,
            projectID: harness.project.id
        )

        let movedText = try await harness.commands.move(
            documentID: sourceText.affectedDocumentID,
            to: .folder(settings.id),
            projectID: harness.project.id
        )
        let movedFolder = try await harness.commands.move(
            documentID: sourceFolder.affectedDocumentID,
            to: .folder(settings.id),
            projectID: harness.project.id
        )

        XCTAssertEqual(movedText.relativePath.rawValue, "메인/설정집/충돌_3.txt")
        XCTAssertEqual(movedFolder.relativePath.rawValue, "메인/설정집/자료_3")
        XCTAssertEqual(
            try String(contentsOf: fileURL(movedText.relativePath.rawValue, harness: harness)),
            "이동한 본문"
        )
        XCTAssertTrue(fileExists("메인/설정집/자료_3/하위 문서.txt", harness: harness))
        XCTAssertTrue(fileExists("메인/설정집/충돌.txt", harness: harness))
        XCTAssertTrue(fileExists("메인/설정집/충돌_2.txt", harness: harness))
        XCTAssertTrue(fileExists("메인/설정집/자료", harness: harness))
        XCTAssertTrue(fileExists("메인/설정집/자료_2", harness: harness))
    }

    func testDuplicateNamesAreNumberedAndForbiddenNamesRemainRejected() async throws {
        let harness = try await makeHarness()
        try writeText("기존", at: "메인/메모장/메모.txt", harness: harness)
        let notes = try await fixedRoot(.notes, harness: harness)
        _ = try await harness.binder.children(of: notes.id, in: harness.project.id)

        let numbered = try await harness.commands.create(
            kind: .text,
            named: "메모",
            in: notes.id,
            projectID: harness.project.id
        )
        XCTAssertEqual(numbered.relativePath.rawValue, "메인/메모장/메모_2.txt")
        await XCTAssertThrowsErrorAsync {
            _ = try await harness.commands.create(
                kind: .folder,
                named: "CON",
                in: notes.id,
                projectID: harness.project.id
            )
        }
        XCTAssertEqual(try String(contentsOf: fileURL("메인/메모장/메모.txt", harness: harness)), "기존")
        XCTAssertTrue(fileExists("메인/메모장/메모_2.txt", harness: harness))
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

    func testMoveToTrashAutomaticallyNumbersDuplicateFileAndFolderNames() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)
        let characters = try await fixedRoot(.characters, harness: harness)

        let textOne = try await harness.commands.create(
            kind: .text, named: "새 문서", in: notes.id, projectID: harness.project.id
        )
        let textTwo = try await harness.commands.create(
            kind: .text, named: "새 문서", in: settings.id, projectID: harness.project.id
        )
        let textThree = try await harness.commands.create(
            kind: .text, named: "새 문서", in: characters.id, projectID: harness.project.id
        )

        let firstTrash = try await harness.commands.moveToTrash(
            documentID: textOne.affectedDocumentID, projectID: harness.project.id
        )
        let secondTrash = try await harness.commands.moveToTrash(
            documentID: textTwo.affectedDocumentID, projectID: harness.project.id
        )
        let thirdTrash = try await harness.commands.moveToTrash(
            documentID: textThree.affectedDocumentID, projectID: harness.project.id
        )

        XCTAssertEqual(firstTrash.relativePath.rawValue, "메인/휴지통/새 문서.txt")
        XCTAssertEqual(secondTrash.relativePath.rawValue, "메인/휴지통/새 문서_2.txt")
        XCTAssertEqual(thirdTrash.relativePath.rawValue, "메인/휴지통/새 문서_3.txt")
        XCTAssertTrue(fileExists(secondTrash.relativePath.rawValue, harness: harness))
        XCTAssertTrue(fileExists(thirdTrash.relativePath.rawValue, harness: harness))

        let folderOne = try await harness.commands.create(
            kind: .folder, named: "자료", in: notes.id, projectID: harness.project.id
        )
        let folderTwo = try await harness.commands.create(
            kind: .folder, named: "자료", in: settings.id, projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: folderOne.affectedDocumentID, projectID: harness.project.id
        )
        let numberedFolder = try await harness.commands.moveToTrash(
            documentID: folderTwo.affectedDocumentID, projectID: harness.project.id
        )
        XCTAssertEqual(numberedFolder.relativePath.rawValue, "메인/휴지통/자료_2")

        let restored = try await harness.commands.restoreFromTrash(
            documentID: textTwo.affectedDocumentID,
            toFolderID: nil,
            projectID: harness.project.id
        )
        XCTAssertEqual(restored.relativePath.rawValue, "메인/설정집/새 문서.txt")
    }

    func testTrashRestoreReturnsToOriginalLocationAndPreservesID() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .text, named: "복원 문서", in: notes.id, projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID, projectID: harness.project.id
        )
        let restored = try await harness.commands.restoreFromTrash(
            documentID: created.affectedDocumentID,
            toFolderID: nil,
            projectID: harness.project.id
        )
        XCTAssertEqual(restored.affectedDocumentID, created.affectedDocumentID)
        XCTAssertEqual(restored.relativePath.rawValue, "메인/메모장/복원 문서.txt")
        XCTAssertTrue(fileExists(restored.relativePath.rawValue, harness: harness))
        let stored = try await harness.repository.document(id: created.affectedDocumentID)
        XCTAssertEqual(stored?.deletionStatus, .active)
    }

    func testTrashRestoreCanUseChosenDestinationFolder() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let settings = try await fixedRoot(.settings, harness: harness)
        let created = try await harness.commands.create(
            kind: .text, named: "선택 복원", in: notes.id, projectID: harness.project.id
        )
        try writeText("선택 위치로 갈 본문", at: created.relativePath.rawValue, harness: harness)
        _ = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID, projectID: harness.project.id
        )

        let restored = try await harness.commands.restoreFromTrash(
            documentID: created.affectedDocumentID,
            toFolderID: settings.id,
            projectID: harness.project.id
        )

        XCTAssertEqual(restored.affectedDocumentID, created.affectedDocumentID)
        XCTAssertEqual(restored.relativePath.rawValue, "메인/설정집/선택 복원.txt")
        XCTAssertEqual(
            try String(contentsOf: fileURL(restored.relativePath.rawValue, harness: harness), encoding: .utf8),
            "선택 위치로 갈 본문"
        )
    }

    func testTrashRestoreCollisionUsesNumberedNameAndNeverOverwritesExistingFile() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .text, named: "충돌", in: notes.id, projectID: harness.project.id
        )
        try writeText("휴지통 원본", at: created.relativePath.rawValue, harness: harness)
        _ = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID, projectID: harness.project.id
        )
        _ = try await harness.commands.create(
            kind: .text, named: "충돌", in: notes.id, projectID: harness.project.id
        )
        try writeText("새 파일", at: "메인/메모장/충돌.txt", harness: harness)

        let restored = try await harness.commands.restoreFromTrash(
            documentID: created.affectedDocumentID,
            toFolderID: nil,
            projectID: harness.project.id
        )
        XCTAssertEqual(restored.relativePath.rawValue, "메인/메모장/충돌_2.txt")
        XCTAssertEqual(
            try String(contentsOf: fileURL("메인/메모장/충돌.txt", harness: harness), encoding: .utf8),
            "새 파일"
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL("메인/메모장/충돌_2.txt", harness: harness), encoding: .utf8),
            "휴지통 원본"
        )
    }

    func testPermanentDeletionRequiresConfirmationAndRemovesEverything() async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .text, named: "영구 삭제", in: notes.id, projectID: harness.project.id
        )
        let trashed = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID, projectID: harness.project.id
        )
        await assertBinderError(.trashConfirmationRequired) {
            try await harness.commands.permanentlyDelete(
                documentID: created.affectedDocumentID,
                projectID: harness.project.id,
                confirmsPermanentDeletion: false
            )
        }
        try await harness.commands.permanentlyDelete(
            documentID: created.affectedDocumentID,
            projectID: harness.project.id,
            confirmsPermanentDeletion: true
        )
        XCTAssertFalse(fileExists(trashed.relativePath.rawValue, harness: harness))
        let deleted = try await harness.repository.document(id: created.affectedDocumentID)
        XCTAssertNil(deleted)
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
        let chapter = try await harness.commands.create(
            kind: .text, named: "001화", in: volume.affectedDocumentID, projectID: harness.project.id
        )
        await XCTAssertThrowsErrorAsync {
            try await harness.commands.reorder(
                childIDs: [volume.affectedDocumentID],
                in: manuscript.id,
                projectID: harness.project.id
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await harness.commands.moveToTrash(
                documentID: volume.affectedDocumentID,
                projectID: harness.project.id
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await harness.commands.moveToTrash(
                documentID: chapter.affectedDocumentID,
                projectID: harness.project.id
            )
        }
    }

    func testFixedRootBindersCanReorderWhileManuscriptAndTrashStayAtEdges() async throws {
        let harness = try await makeHarness()
        let rootContainerID = try await harness.binder.rootContainerID(in: harness.project.id)
        let before = try await harness.binder.rootNodes(in: harness.project.id)
        let reorderable = before.filter {
            $0.fixedCategory != .manuscript && $0.fixedCategory != .trash
        }
        let reversedIDs = reorderable.reversed().map(\.id)

        try await harness.commands.reorder(
            childIDs: reversedIDs,
            in: rootContainerID,
            projectID: harness.project.id
        )

        let after = try await harness.binder.rootNodes(in: harness.project.id)
        XCTAssertEqual(after.first?.fixedCategory, .manuscript)
        XCTAssertEqual(after.last?.fixedCategory, .trash)
        XCTAssertEqual(
            after.filter { $0.fixedCategory != .manuscript && $0.fixedCategory != .trash }.map(\.id),
            reversedIDs
        )
        XCTAssertTrue(
            after.filter { $0.fixedCategory != .manuscript && $0.fixedCategory != .trash }
                .contains { $0.fixedCategory != nil }
        )
    }

    func testAddNewVolumeCreatesTwentyFiveEmptyChaptersAndReturnsUIIntents() async throws {
        let notifier = RecordingFutureChangeNotifier()
        let harness = try await makeHarness(futureChangeNotifier: notifier)
        let manuscript = try await fixedRoot(.manuscript, harness: harness)

        let result = try await harness.commands.addNewVolume(projectID: harness.project.id)

        XCTAssertEqual(result.volumeNumber, 1)
        XCTAssertEqual(result.volumePath.rawValue, "메인/원고/1권")
        XCTAssertEqual(result.chapterIDs.count, 25)
        XCTAssertEqual(result.firstChapterID, result.chapterIDs.first)
        XCTAssertTrue(result.shouldRefreshBinder)
        XCTAssertEqual(result.manuscriptFolderID, manuscript.id)
        XCTAssertEqual(result.folderToExpandID, result.volumeID)
        XCTAssertEqual(result.documentToOpenID, result.firstChapterID)
        XCTAssertTrue(fileExists("메인/원고/1권/001화.txt", harness: harness))
        XCTAssertTrue(fileExists("메인/원고/1권/025화.txt", harness: harness))

        for number in 1...25 {
            let name = String(format: "%03d화.txt", number)
            let data = try Data(contentsOf: fileURL("메인/원고/1권/\(name)", harness: harness))
            XCTAssertTrue(data.isEmpty, "\(name)은 빈 UTF-8 TXT여야 합니다.")
        }
        let stored = try await harness.repository.documents(in: harness.project.id)
            .filter { $0.relativePath.rawValue.hasPrefix("메인/원고/1권") }
        XCTAssertEqual(stored.count, 26)
        XCTAssertEqual(stored.first(where: { $0.id == result.volumeID })?.parentID, manuscript.id)
        XCTAssertTrue(stored.filter { $0.kind == .text }.allSatisfy { $0.contentHash != nil })
        let events = await notifier.recordedEvents()
        XCTAssertEqual(
            events,
            [.manuscriptVolumeCreated(
                projectID: harness.project.id,
                volumeID: result.volumeID,
                chapterIDs: result.chapterIDs
            )]
        )

        let manuscriptDescriptors = try await harness.commands.commandDescriptors(
            for: manuscript.id,
            in: harness.project.id
        )
        XCTAssertEqual(
            manuscriptDescriptors.first(where: { $0.kind == .addVolume })?.isEnabled,
            true
        )
        XCTAssertEqual(
            manuscriptDescriptors.first(where: { $0.kind == .moveToTrash })?.isEnabled,
            false
        )
        XCTAssertEqual(
            manuscriptDescriptors.first(where: { $0.kind == .reorder })?.isEnabled,
            false
        )
        let notes = try await fixedRoot(.notes, harness: harness)
        let noteDescriptors = try await harness.commands.commandDescriptors(
            for: notes.id,
            in: harness.project.id
        )
        XCTAssertEqual(
            noteDescriptors.first(where: { $0.kind == .addVolume })?.isEnabled,
            false
        )
        XCTAssertEqual(
            noteDescriptors.first(where: { $0.kind == .moveToTrash })?.isEnabled,
            false
        )
        XCTAssertEqual(
            noteDescriptors.first(where: { $0.kind == .reorder })?.isEnabled,
            true
        )
    }

    func testNewVolumeNumberUsesHighestValidVolumeAndIgnoresZeroGapsAndMalformedNames() async throws {
        let scenarios: [([String], Int, Int)] = [
            ([], 1, 1),
            (["0권"], 1, 1),
            (["1권", "2권"], 3, 51),
            (["1권", "3권", "02권", "잘못된 권"], 4, 76)
        ]

        for (names, expectedVolume, expectedStart) in scenarios {
            let harness = try await makeHarness()
            for name in names {
                try FileManager.default.createDirectory(
                    at: fileURL("메인/원고/\(name)", harness: harness),
                    withIntermediateDirectories: false
                )
            }

            let result = try await harness.commands.addNewVolume(projectID: harness.project.id)
            XCTAssertEqual(result.volumeNumber, expectedVolume)
            XCTAssertTrue(
                fileExists(
                    "메인/원고/\(expectedVolume)권/\(chapterName(expectedStart))",
                    harness: harness
                )
            )
            XCTAssertTrue(
                fileExists(
                    "메인/원고/\(expectedVolume)권/\(chapterName(expectedStart + 24))",
                    harness: harness
                )
            )
        }
    }

    func testExistingChapterCollisionPreventsAnyPartOfNewVolume() async throws {
        let harness = try await makeHarness()
        try FileManager.default.createDirectory(
            at: fileURL("메인/원고/1권", harness: harness),
            withIntermediateDirectories: false
        )
        try writeText("기존 원고", at: "메인/원고/1권/026화.txt", harness: harness)

        do {
            _ = try await harness.commands.addNewVolume(projectID: harness.project.id)
            XCTFail("중복 화가 있는 새 권 생성이 통과했습니다.")
        } catch let error as BinderCommandError {
            XCTAssertEqual(error, .chapterAlreadyExists(26))
        }

        XCTAssertFalse(fileExists("메인/원고/2권", harness: harness))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fileURL("메인/원고", harness: harness).path)
                .filter { $0.hasPrefix(".writerpad-new-volume-") },
            []
        )
        let stored = try await harness.repository.documents(in: harness.project.id)
        XCTAssertFalse(stored.contains { $0.relativePath.rawValue.hasPrefix("메인/원고/2권") })
        XCTAssertEqual(
            try String(contentsOf: fileURL("메인/원고/1권/026화.txt", harness: harness)),
            "기존 원고"
        )
    }

    func testExistingTargetVolumeIsNeverOverwritten() async throws {
        let harness = try await makeHarness()
        try writeText("보존할 데이터", at: "메인/원고/1권", harness: harness)

        await XCTAssertThrowsErrorAsync {
            _ = try await harness.commands.addNewVolume(projectID: harness.project.id)
        }

        XCTAssertEqual(
            try String(contentsOf: fileURL("메인/원고/1권", harness: harness)),
            "보존할 데이터"
        )
    }

    func testEveryChapterPreparationFailureRollsBackFilesMetadataAndJournal() async throws {
        for index in 1...25 {
            let harness = try await makeHarness(
                faultPlan: BinderCommandFaultPlan(
                    point: .afterVolumeChapterFile(index),
                    leavesTransactionForRecovery: false
                )
            )
            do {
                _ = try await harness.commands.addNewVolume(projectID: harness.project.id)
                XCTFail("\(index)번째 파일 실패가 발생하지 않았습니다.")
            } catch let error as BinderCommandError {
                XCTAssertEqual(error, .injectedFailure(recoveryPending: false))
            }

            XCTAssertFalse(fileExists("메인/원고/1권", harness: harness))
            let manuscriptItems = try FileManager.default.contentsOfDirectory(
                atPath: fileURL("메인/원고", harness: harness).path
            )
            XCTAssertFalse(manuscriptItems.contains { $0.hasPrefix(".writerpad-new-volume-") })
            XCTAssertTrue(try journalFiles(harness: harness).isEmpty)
            let stored = try await harness.repository.documents(in: harness.project.id)
            XCTAssertFalse(stored.contains { $0.relativePath.rawValue.hasPrefix("메인/원고/1권") })
        }
    }

    func testPromotedVolumeCompletesMetadataDuringRecovery() async throws {
        let harness = try await makeHarness(
            faultPlan: BinderCommandFaultPlan(
                point: .afterFileMutation,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await harness.commands.addNewVolume(projectID: harness.project.id)
            XCTFail("정식 폴더 승격 뒤 테스트 중단이 발생하지 않았습니다.")
        } catch let error as BinderCommandError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        XCTAssertTrue(fileExists("메인/원고/1권/025화.txt", harness: harness))
        var stored = try await harness.repository.documents(in: harness.project.id)
        XCTAssertFalse(stored.contains { $0.relativePath.rawValue.hasPrefix("메인/원고/1권") })

        let recovery = harness.makeCommands(faultPlan: nil)
        try await recovery.recoverPendingTransactions(in: harness.project.id)

        stored = try await harness.repository.documents(in: harness.project.id)
        XCTAssertEqual(
            stored.filter { $0.relativePath.rawValue.hasPrefix("메인/원고/1권") }.count,
            26
        )
        XCTAssertTrue(try journalFiles(harness: harness).isEmpty)
    }

    func testConcurrentSecondVolumeRequestIsRejectedWhileFirstIsFinishing() async throws {
        let notifier = BlockingFutureChangeNotifier()
        let harness = try await makeHarness(futureChangeNotifier: notifier)
        let first = Task {
            try await harness.commands.addNewVolume(projectID: harness.project.id)
        }
        await notifier.waitUntilEntered()

        do {
            _ = try await harness.commands.addNewVolume(projectID: harness.project.id)
            XCTFail("동시 두 번째 요청이 통과했습니다.")
        } catch let error as BinderCommandError {
            XCTAssertEqual(error, .volumeCreationInProgress)
        }

        await notifier.release()
        _ = try await first.value
        XCTAssertTrue(fileExists("메인/원고/1권", harness: harness))
        XCTAssertFalse(fileExists("메인/원고/2권", harness: harness))
    }

    func testChapterNamesAfterOneThousandDoNotUseFixedThreeDigitWidth() async throws {
        let harness = try await makeHarness()
        try FileManager.default.createDirectory(
            at: fileURL("메인/원고/40권", harness: harness),
            withIntermediateDirectories: false
        )

        let result = try await harness.commands.addNewVolume(projectID: harness.project.id)

        XCTAssertEqual(result.volumeNumber, 41)
        XCTAssertTrue(fileExists("메인/원고/41권/1001화.txt", harness: harness))
        XCTAssertTrue(fileExists("메인/원고/41권/1025화.txt", harness: harness))
        XCTAssertFalse(fileExists("메인/원고/41권/001001화.txt", harness: harness))
    }

    func testTextCreationAndVolumeUseAtomicDurableBatches() async throws {
        let recorder = RecordingDurableChangeRecorder()
        let harness = try await makeHarness(durableChangeRecorder: recorder)
        let notes = try await fixedRoot(.notes, harness: harness)

        let created = try await harness.commands.create(
            kind: .text,
            named: "동기화 메모",
            in: notes.id,
            projectID: harness.project.id
        )
        var batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].kind, .structureChange)
        XCTAssertNotNil(batches[0].localTransactionID)
        XCTAssertEqual(batches[0].mutations.count, 2)
        guard case let .documentSnapshot(
            _,
            documentID,
            relativePath,
            content,
            _,
            _,
            isDeleted
        ) = batches[0].mutations[0] else {
            return XCTFail("TXT create snapshot이 없습니다.")
        }
        XCTAssertEqual(documentID, created.affectedDocumentID)
        XCTAssertEqual(relativePath, created.relativePath)
        XCTAssertEqual(content, "")
        XCTAssertFalse(isDeleted)
        guard case .treeOrder = batches[0].mutations[1] else {
            return XCTFail("tree-order가 같은 batch에 없습니다.")
        }

        await recorder.clear()
        try await harness.commands.reorder(
            childIDs: [created.affectedDocumentID],
            in: notes.id,
            projectID: harness.project.id
        )
        batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].kind, .structureChange)
        XCTAssertEqual(batches[0].mutations.count, 1)
        guard case .treeOrder = batches[0].mutations[0] else {
            return XCTFail("재정렬 tree-order가 없습니다.")
        }

        await recorder.clear()
        _ = try await harness.commands.addNewVolume(
            projectID: harness.project.id
        )
        batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].kind, .volumeCreation)
        XCTAssertEqual(
            batches[0].mutations.filter {
                if case .documentSnapshot = $0 { return true }
                return false
            }.count,
            25
        )
        XCTAssertEqual(
            batches[0].mutations.filter {
                if case .treeOrder = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testEmptyFolderCreationQueuesTreeOrderBatch() async throws {
        let recorder = RecordingDurableChangeRecorder()
        let harness = try await makeHarness(durableChangeRecorder: recorder)
        let notes = try await fixedRoot(.notes, harness: harness)

        let created = try await harness.commands.create(
            kind: .folder,
            named: "서버 빈 폴더",
            in: notes.id,
            projectID: harness.project.id
        )

        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].kind, .structureChange)
        XCTAssertNotNil(batches[0].localTransactionID)
        // 폴더 작업과 tree_order가 함께 나간다. tree_order는 Windows 호환을
        // 위해 유지하고, 폴더 작업이 같은 폴더의 정체를 서버에 알린다.
        XCTAssertEqual(batches[0].mutations.count, 2)
        guard case let .folderSnapshot(_, folderID, parentFolderID, name, isDeleted) =
                batches[0].mutations[0] else {
            return XCTFail("빈 폴더의 폴더 작업이 없습니다.")
        }
        XCTAssertEqual(folderID, created.affectedDocumentID)
        XCTAssertEqual(parentFolderID, notes.id)
        XCTAssertEqual(name, "서버 빈 폴더")
        XCTAssertFalse(isDeleted)
        guard case let .treeOrder(_, content, _) = batches[0].mutations[1]
        else {
            return XCTFail("빈 폴더 tree-order가 없습니다.")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8))
                as? [String: Any]
        )
        let treeOrder = try XCTUnwrap(
            object["tree_order"] as? [String: [String]]
        )
        XCTAssertEqual(
            treeOrder[notes.relativePath.rawValue],
            ["서버 빈 폴더"]
        )
        XCTAssertEqual(
            treeOrder[notes.relativePath.rawValue + "/서버 빈 폴더"],
            []
        )
        XCTAssertEqual(
            created.relativePath.rawValue,
            notes.relativePath.rawValue + "/서버 빈 폴더"
        )
    }

    func testTreeOrderNormalizesDecomposedFolderNamesAndIncludesEmptyLists()
        async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        _ = try await harness.commands.create(
            kind: .folder,
            named: "한글 빈폴더",
            in: notes.id,
            projectID: harness.project.id
        )
        let documents = try await harness.repository.documents(
            in: harness.project.id
        )
        let decomposedDocuments = documents.map { document in
            DocumentNode(
                id: document.id,
                projectID: document.projectID,
                kind: document.kind,
                parentID: document.parentID,
                relativePath: RelativeDocumentPath(
                    rawValue: document.relativePath.rawValue
                        .decomposedStringWithCanonicalMapping
                ),
                userOrder: document.userOrder,
                modifiedAt: document.modifiedAt,
                contentHash: document.contentHash,
                deletionStatus: document.deletionStatus,
                cursor: document.cursor,
                isExpanded: document.isExpanded
            )
        }

        let content = try await harness.commands.treeOrderContent(
            documents: decomposedDocuments
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8))
                as? [String: Any]
        )
        let treeOrder = try XCTUnwrap(
            object["tree_order"] as? [String: [String]]
        )

        XCTAssertEqual(treeOrder["메인/메모장"], ["한글 빈폴더"])
        XCTAssertEqual(treeOrder["메인/메모장/한글 빈폴더"], [])
        XCTAssertTrue(treeOrder.keys.allSatisfy {
            $0 == $0.precomposedStringWithCanonicalMapping
        })
        XCTAssertTrue(treeOrder.values.flatMap { $0 }.allSatisfy {
            $0 == $0.precomposedStringWithCanonicalMapping
        })
    }

    func testStructureTrashRestoreAndPurgeCaptureCorrectSnapshots() async throws {
        let recorder = RecordingDurableChangeRecorder()
        let harness = try await makeHarness(durableChangeRecorder: recorder)
        let notes = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .text,
            named: "사건",
            in: notes.id,
            projectID: harness.project.id
        )
        try writeText("본문 snapshot", at: created.relativePath.rawValue, harness: harness)

        await recorder.clear()
        let renamed = try await harness.commands.rename(
            documentID: created.affectedDocumentID,
            to: "이름 변경",
            projectID: harness.project.id
        )
        var recorded = await recorder.recordedBatches()
        var batch = try XCTUnwrap(recorded.last)
        XCTAssertEqual(batch.kind, .structureChange)
        guard case let .documentSnapshot(
            _,
            _,
            renamedPath,
            renamedContent,
            _,
            _,
            renamedDeleted
        ) = batch.mutations[0] else {
            return XCTFail("rename snapshot이 없습니다.")
        }
        XCTAssertEqual(renamedPath, renamed.relativePath)
        XCTAssertEqual(renamedContent, "본문 snapshot")
        XCTAssertFalse(renamedDeleted)

        await recorder.clear()
        _ = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID,
            projectID: harness.project.id
        )
        recorded = await recorder.recordedBatches()
        batch = try XCTUnwrap(recorded.last)
        XCTAssertEqual(batch.kind, .trashChange)
        guard case let .documentSnapshot(
            _,
            _,
            tombstonePath,
            tombstoneContent,
            _,
            _,
            tombstoneDeleted
        ) = batch.mutations[0] else {
            return XCTFail("trash tombstone이 없습니다.")
        }
        XCTAssertEqual(tombstonePath, renamed.relativePath)
        XCTAssertEqual(tombstoneContent, "본문 snapshot")
        XCTAssertFalse(tombstonePath.rawValue.contains("/휴지통/"))
        XCTAssertTrue(tombstoneDeleted)

        await recorder.clear()
        let restored = try await harness.commands.restoreFromTrash(
            documentID: created.affectedDocumentID,
            toFolderID: notes.id,
            projectID: harness.project.id
        )
        recorded = await recorder.recordedBatches()
        batch = try XCTUnwrap(recorded.last)
        guard case let .documentSnapshot(
            _,
            _,
            restorePath,
            restoreContent,
            _,
            _,
            restoreDeleted
        ) = batch.mutations[0] else {
            return XCTFail("restore snapshot이 없습니다.")
        }
        XCTAssertEqual(restorePath, restored.relativePath)
        XCTAssertEqual(restoreContent, "본문 snapshot")
        XCTAssertFalse(restoreDeleted)

        _ = try await harness.commands.moveToTrash(
            documentID: created.affectedDocumentID,
            projectID: harness.project.id
        )
        await recorder.clear()
        try await harness.commands.permanentlyDelete(
            documentID: created.affectedDocumentID,
            projectID: harness.project.id,
            confirmsPermanentDeletion: true
        )
        recorded = await recorder.recordedBatches()
        batch = try XCTUnwrap(recorded.last)
        XCTAssertEqual(batch.mutations.count, 1)
        guard case let .trashPurge(_, content, _) = batch.mutations[0] else {
            return XCTFail("trash-purge snapshot이 없습니다.")
        }
        XCTAssertTrue(
            content.contains(
                created.affectedDocumentID.rawValue.uuidString.lowercased()
            )
        )

        let first = try await harness.commands.create(
            kind: .text,
            named: "전체 삭제 1",
            in: notes.id,
            projectID: harness.project.id
        )
        let second = try await harness.commands.create(
            kind: .text,
            named: "전체 삭제 2",
            in: notes.id,
            projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: first.affectedDocumentID,
            projectID: harness.project.id
        )
        _ = try await harness.commands.moveToTrash(
            documentID: second.affectedDocumentID,
            projectID: harness.project.id
        )
        await recorder.clear()
        let deletion = try await harness.commands.emptyTrash(
            projectID: harness.project.id,
            confirmsPermanentDeletion: true
        )
        XCTAssertEqual(Set(deletion.deletedDocumentIDs), Set([
            first.affectedDocumentID,
            second.affectedDocumentID,
        ]))
        recorded = await recorder.recordedBatches()
        let emptyBatch = try XCTUnwrap(recorded.last)
        guard case let .trashPurge(_, emptyContent, emptyGeneration) =
            emptyBatch.mutations.first else {
            return XCTFail("전체 비우기 trash-purge가 없습니다.")
        }
        XCTAssertTrue(emptyContent.contains(first.affectedDocumentID.rawValue.uuidString.lowercased()))
        XCTAssertTrue(emptyContent.contains(second.affectedDocumentID.rawValue.uuidString.lowercased()))
        XCTAssertTrue(emptyContent.contains(emptyGeneration.uuidString.lowercased()))
    }

    func testFailedDurableHandoffReplaysSameBatchFromBinderJournal() async throws {
        let failing = RecordingDurableChangeRecorder(
            result: .localSavedButNotQueued(reason: "injected")
        )
        let harness = try await makeHarness(durableChangeRecorder: failing)
        let notes = try await fixedRoot(.notes, harness: harness)

        let created = try await harness.commands.create(
            kind: .text,
            named: "복구 대상",
            in: notes.id,
            projectID: harness.project.id
        )

        XCTAssertTrue(fileExists(created.relativePath.rawValue, harness: harness))
        XCTAssertEqual(try journalFiles(harness: harness).count, 1)
        let failedBatches = await failing.recordedBatches()
        let original = try XCTUnwrap(failedBatches.first)

        let succeeding = RecordingDurableChangeRecorder()
        let recovery = harness.makeCommands(
            faultPlan: nil,
            durableChangeRecorder: succeeding
        )
        try await recovery.recoverPendingTransactions(in: harness.project.id)

        let replayed = await succeeding.recordedBatches()
        XCTAssertEqual(replayed, [original])
        XCTAssertTrue(try journalFiles(harness: harness).isEmpty)
    }

    func testBackupRestoreAsCopyKeepsCurrentDocumentAndQueuesNewSibling() async throws {
        let recorder = RecordingDurableChangeRecorder()
        let harness = try await makeHarness(durableChangeRecorder: recorder)
        let notes = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .text,
            named: "아이디어",
            in: notes.id,
            projectID: harness.project.id
        )
        let loadedOriginal = try await harness.repository.document(
            id: created.affectedDocumentID
        )
        let original = try XCTUnwrap(loadedOriginal)
        let documentStore = LocalDocumentStore(
            workspaceLocator: harness.locator,
            metadataUpdater: harness.repository,
            durableChangeRecorder: recorder
        )
        _ = try await documentStore.save(
            .init(
                projectID: original.projectID,
                documentID: original.id,
                relativePath: original.relativePath,
                text: "백업에 보관된 내용🙂\n",
                generation: 1
            )
        )
        let backupStore = LocalBackupStore(workspaceLocator: harness.locator)
        let snapshot = try await backupStore.createSnapshot(
            for: original,
            reason: .manual
        )
        _ = try await documentStore.save(
            .init(
                projectID: original.projectID,
                documentID: original.id,
                relativePath: original.relativePath,
                text: "현재 문서 내용",
                generation: 2
            )
        )
        await recorder.clear()

        let coordinator = DocumentRestoreCoordinator(
            documentStore: documentStore,
            backupStore: backupStore,
            documentRepository: harness.repository,
            binderCommands: harness.commands
        )
        let result = try await coordinator.restoreAsCopy(
            .init(
                document: original,
                snapshot: snapshot,
                saveGeneration: 10
            )
        )

        XCTAssertNotEqual(result.document.id, original.id)
        XCTAssertEqual(result.document.parentID, notes.id)
        XCTAssertEqual(
            result.document.relativePath.rawValue,
            "메인/메모장/아이디어 백업 사본.txt"
        )
        XCTAssertEqual(result.copiedText, "백업에 보관된 내용🙂\n")
        XCTAssertEqual(
            try String(contentsOf: fileURL(original.relativePath.rawValue, harness: harness)),
            "현재 문서 내용"
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL(result.document.relativePath.rawValue, harness: harness)),
            "백업에 보관된 내용🙂\n"
        )
        let batches = await recorder.recordedBatches()
        XCTAssertEqual(batches.map(\.kind), [.structureChange, .documentSave])
    }

    func testManuscriptBackupCopyIsCreatedInNotesWithoutChangingChapter() async throws {
        let harness = try await makeHarness()
        let volume = try await harness.commands.addNewVolume(
            projectID: harness.project.id
        )
        let loadedChapter = try await harness.repository.document(
            id: volume.firstChapterID
        )
        let chapter = try XCTUnwrap(loadedChapter)
        let notes = try await fixedRoot(.notes, harness: harness)
        let documentStore = LocalDocumentStore(
            workspaceLocator: harness.locator,
            metadataUpdater: harness.repository
        )
        _ = try await documentStore.save(
            .init(
                projectID: chapter.projectID,
                documentID: chapter.id,
                relativePath: chapter.relativePath,
                text: "과거 장면",
                generation: 1
            )
        )
        let backupStore = LocalBackupStore(workspaceLocator: harness.locator)
        let snapshot = try await backupStore.createSnapshot(
            for: chapter,
            reason: .manual
        )
        _ = try await documentStore.save(
            .init(
                projectID: chapter.projectID,
                documentID: chapter.id,
                relativePath: chapter.relativePath,
                text: "현재 장면",
                generation: 2
            )
        )
        let coordinator = DocumentRestoreCoordinator(
            documentStore: documentStore,
            backupStore: backupStore,
            documentRepository: harness.repository,
            binderCommands: harness.commands
        )

        let result = try await coordinator.restoreAsCopy(
            .init(
                document: chapter,
                snapshot: snapshot,
                saveGeneration: 10
            )
        )

        XCTAssertEqual(result.document.parentID, notes.id)
        XCTAssertTrue(
            result.document.relativePath.rawValue
                .hasPrefix("메인/메모장/001화 백업 사본")
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL(chapter.relativePath.rawValue, harness: harness)),
            "현재 장면"
        )
        XCTAssertEqual(
            try String(contentsOf: fileURL(result.document.relativePath.rawValue, harness: harness)),
            "과거 장면"
        )
    }

    func testRecoverMigratesLegacyPlotAndPreservesSubtreeIDs() async throws {
        let harness = try await makeHarness()
        let storyPlot = try await fixedRoot(.storyPlot, harness: harness)
        let created = try await harness.commands.create(
            kind: .text,
            named: "구상",
            in: storyPlot.id,
            projectID: harness.project.id
        )
        let documents = try await harness.repository.documents(in: harness.project.id)
        let folder = try XCTUnwrap(documents.first { $0.id == storyPlot.id })
        let text = try XCTUnwrap(documents.first { $0.id == created.affectedDocumentID })
        let legacyFolderPath = RelativeDocumentPath(rawValue: "메인/플롯")
        let legacyTextPath = RelativeDocumentPath(rawValue: "메인/플롯/구상.txt")
        try FileManager.default.moveItem(
            at: fileURL(folder.relativePath.rawValue, harness: harness),
            to: fileURL(legacyFolderPath.rawValue, harness: harness)
        )
        let legacyFolder = copy(folder, path: legacyFolderPath)
        let legacyText = copy(text, path: legacyTextPath)
        try await harness.repository.reconcileBinderMetadata(
            in: harness.project.id,
            upserting: [legacyFolder, legacyText],
            removingSubtrees: []
        )

        try await harness.commands.recoverPendingTransactions(in: harness.project.id)

        XCTAssertTrue(fileExists("메인/스토리 플롯/구상.txt", harness: harness))
        XCTAssertFalse(fileExists("메인/플롯", harness: harness))
        let migrated = try await harness.repository.documents(in: harness.project.id)
        XCTAssertEqual(
            migrated.first { $0.id == folder.id }?.relativePath,
            BinderFixedCategory.storyPlot.relativePath
        )
        XCTAssertEqual(
            migrated.first { $0.id == text.id }?.relativePath.rawValue,
            "메인/스토리 플롯/구상.txt"
        )
    }

    func testRecoverStopsWithoutMergingWhenCanonicalAndLegacyPlotCoexist() async throws {
        let harness = try await makeHarness()
        try FileManager.default.createDirectory(
            at: fileURL("메인/플롯", harness: harness),
            withIntermediateDirectories: false
        )

        await assertBinderError(
            .storyPlotMigrationConflict(["메인/스토리 플롯", "메인/플롯"])
        ) {
            try await harness.commands.recoverPendingTransactions(
                in: harness.project.id
            )
        }

        XCTAssertTrue(fileExists("메인/스토리 플롯", harness: harness))
        XCTAssertTrue(fileExists("메인/플롯", harness: harness))
    }

    func testRecoverRemovesOnlyEmptyDeterministicLegacySyncRootAlias() async throws {
        let harness = try await makeHarness()
        let initialDocuments = try await harness.repository.documents(
            in: harness.project.id
        )
        let main = try XCTUnwrap(
            initialDocuments.first { $0.relativePath.rawValue == "메인" }
        )
        let path = RelativeDocumentPath(rawValue: "메인/📚 원고")
        let identifier = DocumentID(
            rawValue: syncV2UUIDv5(
                namespace: harness.project.id.rawValue,
                name: "writerpad-local-folder/"
                    + path.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            )
        )
        let duplicate = DocumentNode(
            id: identifier,
            projectID: harness.project.id,
            kind: .folder,
            parentID: main.id,
            relativePath: path,
            userOrder: 99,
            modifiedAt: harness.clock.now(),
            contentHash: nil
        )
        try FileManager.default.createDirectory(
            at: fileURL(path.rawValue, harness: harness),
            withIntermediateDirectories: false
        )
        try await harness.repository.reconcileBinderMetadata(
            in: harness.project.id,
            upserting: [duplicate],
            removingSubtrees: []
        )

        try await harness.commands.recoverPendingTransactions(in: harness.project.id)

        XCTAssertFalse(fileExists(path.rawValue, harness: harness))
        let removed = try await harness.repository.document(id: identifier)
        XCTAssertNil(removed)
    }

    func testRecoverPreservesNonemptyLegacySyncRootAliasAndReportsConflict() async throws {
        let harness = try await makeHarness()
        let initialDocuments = try await harness.repository.documents(
            in: harness.project.id
        )
        let main = try XCTUnwrap(
            initialDocuments.first { $0.relativePath.rawValue == "메인" }
        )
        let path = RelativeDocumentPath(rawValue: "메인/📚 원고")
        let identifier = DocumentID(
            rawValue: syncV2UUIDv5(
                namespace: harness.project.id.rawValue,
                name: "writerpad-local-folder/"
                    + path.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            )
        )
        let duplicate = DocumentNode(
            id: identifier,
            projectID: harness.project.id,
            kind: .folder,
            parentID: main.id,
            relativePath: path,
            userOrder: 99,
            modifiedAt: harness.clock.now(),
            contentHash: nil
        )
        let safePath = RelativeDocumentPath(rawValue: "메인/👤 캐릭터")
        let safeID = DocumentID(
            rawValue: syncV2UUIDv5(
                namespace: harness.project.id.rawValue,
                name: "writerpad-local-folder/"
                    + safePath.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            )
        )
        let safeDuplicate = DocumentNode(
            id: safeID,
            projectID: harness.project.id,
            kind: .folder,
            parentID: main.id,
            relativePath: safePath,
            userOrder: 100,
            modifiedAt: harness.clock.now(),
            contentHash: nil
        )
        try writeText("보존", at: "메인/📚 원고/확인.txt", harness: harness)
        try FileManager.default.createDirectory(
            at: fileURL(safePath.rawValue, harness: harness),
            withIntermediateDirectories: false
        )
        try await harness.repository.reconcileBinderMetadata(
            in: harness.project.id,
            upserting: [duplicate, safeDuplicate],
            removingSubtrees: []
        )

        await assertBinderError(.legacySyncFolderConflict([path.rawValue])) {
            try await harness.commands.recoverPendingTransactions(
                in: harness.project.id
            )
        }

        XCTAssertTrue(fileExists("메인/📚 원고/확인.txt", harness: harness))
        XCTAssertTrue(fileExists(safePath.rawValue, harness: harness))
        let preserved = try await harness.repository.document(id: identifier)
        let safePreserved = try await harness.repository.document(id: safeID)
        XCTAssertNotNil(preserved)
        XCTAssertNotNil(safePreserved)
    }

    private func copy(
        _ document: DocumentNode,
        path: RelativeDocumentPath
    ) -> DocumentNode {
        DocumentNode(
            id: document.id,
            projectID: document.projectID,
            kind: document.kind,
            parentID: document.parentID,
            relativePath: path,
            userOrder: document.userOrder,
            modifiedAt: document.modifiedAt,
            contentHash: document.contentHash,
            deletionStatus: document.deletionStatus,
            cursor: document.cursor,
            isExpanded: document.isExpanded
        )
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

        func makeCommands(
            faultPlan: BinderCommandFaultPlan?,
            futureChangeNotifier: any FutureChangeNotifying = NoOpFutureChangeNotifier(),
            durableChangeRecorder: any DurableLocalChangeRecording =
                NoOpDurableLocalChangeRecorder()
        ) -> LocalBinderCommandService {
            LocalBinderCommandService(
                metadataStore: repository,
                workspaceStateRepository: repository,
                workspaceLocator: locator,
                pathPolicy: resolver.policy,
                clock: clock,
                futureChangeNotifier: futureChangeNotifier,
                durableChangeRecorder: durableChangeRecorder,
                faultPlan: faultPlan
            )
        }
    }

    private struct FixedClock: AppClock {
        let date = Date(timeIntervalSince1970: 8_000)
        func now() -> Date { date }
    }

    private func makeHarness(
        faultPlan: BinderCommandFaultPlan? = nil,
        futureChangeNotifier: any FutureChangeNotifying = NoOpFutureChangeNotifier(),
        durableChangeRecorder: any DurableLocalChangeRecording =
            NoOpDurableLocalChangeRecorder()
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
            creationMetadataStore: repository,
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
            futureChangeNotifier: futureChangeNotifier,
            durableChangeRecorder: durableChangeRecorder,
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

    private func chapterName(_ number: Int) -> String {
        (number < 1_000 ? String(format: "%03d", number) : String(number)) + "화.txt"
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

private actor RecordingFutureChangeNotifier: FutureChangeNotifying {
    nonisolated let mode: FutureSyncMode = .localOnly
    private var events: [LocalChangeEvent] = []

    func record(_ event: LocalChangeEvent) async {
        events.append(event)
    }

    func recordedEvents() -> [LocalChangeEvent] {
        events
    }
}

private actor RecordingDurableChangeRecorder: DurableLocalChangeRecording {
    private let result: DurableRecordResult
    private var batches: [LocalMutationBatch] = []

    init(result: DurableRecordResult = .queued(operationIDs: [])) {
        self.result = result
    }

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        .durableQueue
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        batches.append(batch)
        return result
    }

    func recordedBatches() -> [LocalMutationBatch] {
        batches
    }

    func clear() {
        batches = []
    }
}

private actor BlockingFutureChangeNotifier: FutureChangeNotifying {
    nonisolated let mode: FutureSyncMode = .localOnly
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ event: LocalChangeEvent) async {
        guard case .manuscriptVolumeCreated = event else { return }
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
