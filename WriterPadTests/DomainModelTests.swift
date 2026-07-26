import Foundation
import XCTest
@testable import WriterPad

final class DomainModelTests: XCTestCase {
    private let projectID = ProjectID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    private let documentID = DocumentID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
    private let contentHash = ContentHash(rawValue: String(repeating: "a", count: 64))!
    private let date = Date(timeIntervalSince1970: 1_000)

    func testCoreModelsRoundTripThroughCodable() throws {
        let project = Project(
            id: projectID,
            name: "테스트 작품",
            createdAt: date,
            modifiedAt: date
        )
        let document = makeDocument()
        let backup = BackupSnapshot(
            id: BackupID(rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!),
            projectID: projectID,
            documentID: documentID,
            relativePath: RelativeDocumentPath(rawValue: "백업/자동저장/001화.txt"),
            createdAt: date,
            contentHash: contentHash,
            reason: .automaticSave,
            isPinned: false
        )
        let workspace = EditorWorkspaceState(
            projectID: projectID,
            left: EditorPaneState(documentID: documentID, cursor: .start),
            right: nil,
            activePane: .left
        )

        try assertRoundTrip(project)
        try assertRoundTrip(document)
        try assertRoundTrip(backup)
        try assertRoundTrip(workspace)
        try assertRoundTrip(
            SaveState.saved(generation: 7, savedAt: date, contentHash: contentHash)
        )
    }

    func testRelocationAndTrashMovePreserveStableIdentity() {
        let original = makeDocument()
        let newParentID = DocumentID(
            rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let relocated = original.relocated(
            to: RelativeDocumentPath(rawValue: "메인/원고/2권/026화.txt"),
            parentID: newParentID,
            userOrder: 26,
            at: date.addingTimeInterval(10)
        )
        let trashed = relocated.movedToTrash(
            at: RelativeDocumentPath(rawValue: "메인/휴지통/026화.txt"),
            trashParentID: nil,
            deletedAt: date.addingTimeInterval(20)
        )

        XCTAssertEqual(relocated.id, original.id)
        XCTAssertEqual(relocated.projectID, original.projectID)
        XCTAssertEqual(trashed.id, original.id)
        XCTAssertEqual(trashed.projectID, original.projectID)
        XCTAssertEqual(
            trashed.deletionStatus,
            .trashed(originalPath: relocated.relativePath, deletedAt: date.addingTimeInterval(20))
        )
    }

    func testDocumentMetadataEncodingDoesNotContainManuscriptBody() throws {
        let encoded = try JSONEncoder().encode(makeDocument())
        let json = String(decoding: encoded, as: UTF8.self)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertFalse(json.contains("본문에만 존재하는 문장"))
        XCTAssertNil(object["text"])
        XCTAssertNil(object["content"])
        XCTAssertNil(object["body"])
    }

    func testContentHashRejectsNonSHA256Values() {
        XCTAssertNil(ContentHash(rawValue: "too-short"))
        XCTAssertNil(ContentHash(rawValue: String(repeating: "z", count: 64)))
        XCTAssertEqual(
            ContentHash(rawValue: String(repeating: "A", count: 64))?.rawValue,
            String(repeating: "a", count: 64)
        )
    }

    func testTrashPresentationShowsOnlyTopLevelItemsWhenParentMetadataIsFlattened() {
        let trashID = DocumentID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let deletedAt = date.addingTimeInterval(20)
        let folder = DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: trashID,
            relativePath: RelativeDocumentPath(rawValue: "메인/휴지통/자료"),
            userOrder: 0,
            modifiedAt: deletedAt,
            contentHash: nil,
            deletionStatus: .trashed(
                originalPath: RelativeDocumentPath(rawValue: "메인/메모장/자료"),
                deletedAt: deletedAt
            )
        )
        let flattenedChild = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: trashID,
            relativePath: RelativeDocumentPath(rawValue: "메인/휴지통/자료/메모.txt"),
            userOrder: 0,
            modifiedAt: deletedAt,
            contentHash: contentHash,
            deletionStatus: .trashed(
                originalPath: RelativeDocumentPath(rawValue: "메인/메모장/자료/메모.txt"),
                deletedAt: deletedAt
            )
        )

        XCTAssertEqual(
            TrashPresentation.topLevelItems(from: [folder, flattenedChild]).map(\.id),
            [folderID]
        )
    }

    func testWorkspaceRestoreReplacesMissingDocumentsWithFirstActiveManuscriptChapter() {
        let missingLeftID = DocumentID(rawValue: UUID())
        let missingRightID = DocumentID(rawValue: UUID())
        let firstChapter = makeTextDocument(
            id: DocumentID(rawValue: UUID()),
            path: "메인/원고/1권/001화 시작.txt",
            order: 1
        )
        let laterChapter = makeTextDocument(
            id: DocumentID(rawValue: UUID()),
            path: "메인/원고/2권/026화.txt",
            order: 26
        )
        let trashedEarlierChapter = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/휴지통/000화.txt"),
            userOrder: 0,
            modifiedAt: date,
            contentHash: nil,
            deletionStatus: .trashed(
                originalPath: RelativeDocumentPath(rawValue: "메인/원고/1권/000화.txt"),
                deletedAt: date
            )
        )
        let saved = EditorWorkspaceState(
            projectID: projectID,
            left: EditorPaneState(
                documentID: missingLeftID,
                cursor: TextCursorState(location: 99, selectionLength: 1)
            ),
            right: EditorPaneState(
                documentID: missingRightID,
                cursor: TextCursorState(location: 45, selectionLength: 0)
            ),
            activePane: .right
        )

        let resolved = WorkspaceRestorePolicy.resolvedState(
            from: saved,
            availableDocuments: [laterChapter, trashedEarlierChapter, firstChapter]
        )

        XCTAssertEqual(resolved.left.documentID, firstChapter.id)
        XCTAssertEqual(resolved.left.cursor, .start)
        XCTAssertEqual(resolved.right?.documentID, firstChapter.id)
        XCTAssertEqual(resolved.right?.cursor, .start)
        XCTAssertEqual(resolved.activePane, .right)
    }

    func testWorkspaceRestoreCollapsesMissingRightPaneWhenNoManuscriptExists() {
        let saved = EditorWorkspaceState(
            projectID: projectID,
            left: EditorPaneState(documentID: nil, cursor: .start),
            right: EditorPaneState(
                documentID: DocumentID(rawValue: UUID()),
                cursor: TextCursorState(location: 10, selectionLength: 0)
            ),
            activePane: .right
        )

        let resolved = WorkspaceRestorePolicy.resolvedState(
            from: saved,
            availableDocuments: []
        )

        XCTAssertNil(resolved.left.documentID)
        XCTAssertNil(resolved.right)
        XCTAssertEqual(resolved.activePane, .left)
    }

    private func makeTextDocument(
        id: DocumentID,
        path: String,
        order: Int
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: .text,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: order,
            modifiedAt: date,
            contentHash: nil
        )
    }

    func testDocumentSearchUsesExactUTF16RangesForKoreanEmojiAndMultilineText() {
        let text = "가🙂나🙂\n한글\n끝"

        XCTAssertEqual(
            DocumentSearchState.findMatches(query: "🙂", in: text),
            [
                TextCursorState(location: 1, selectionLength: 2),
                TextCursorState(location: 4, selectionLength: 2)
            ]
        )
        XCTAssertEqual(
            DocumentSearchState.findMatches(query: "🙂\n한글", in: text),
            [TextCursorState(location: 4, selectionLength: 5)]
        )
        XCTAssertEqual(
            DocumentSearchState.findMatches(query: "가", in: text),
            [TextCursorState(location: 0, selectionLength: 1)]
        )
        XCTAssertEqual(
            DocumentSearchState.findMatches(query: "끝", in: text),
            [TextCursorState(location: 10, selectionLength: 1)]
        )
    }

    func testDocumentSearchIsCaseInsensitiveLiteralNonOverlappingAndWrapsNavigation() {
        var state = DocumentSearchState()
        state.update(query: "aba", in: "AbAba ABA")

        XCTAssertEqual(
            state.matches,
            [
                TextCursorState(location: 0, selectionLength: 3),
                TextCursorState(location: 6, selectionLength: 3)
            ]
        )
        XCTAssertEqual(state.selectedIndex, 0)
        state.selectPrevious()
        XCTAssertEqual(state.selectedIndex, 1)
        state.selectNext()
        XCTAssertEqual(state.selectedIndex, 0)
        state.update(query: "", in: "AbAba ABA")
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertNil(state.selectedIndex)
    }

    func testDocumentSearchHandlesThousandsOfResultsAndRecalculatesAfterEditing() {
        var state = DocumentSearchState()
        let text = String(repeating: "찾기 ", count: 2_000)
        state.update(query: "찾기", in: text)
        XCTAssertEqual(state.matches.count, 2_000)

        state.selectNext()
        XCTAssertEqual(state.currentMatch?.location, 3)
        state.recalculate(in: "X" + text)
        XCTAssertEqual(state.matches.count, 2_000)
        XCTAssertEqual(state.currentMatch?.location, 4)

        state.update(query: "없음", in: text)
        XCTAssertTrue(state.matches.isEmpty)
        XCTAssertNil(state.currentMatch)
    }

    func testDualEditorDocumentSearchStatesRemainIndependent() {
        var left = DocumentSearchState()
        var right = DocumentSearchState()

        left.update(query: "왼쪽", in: "왼쪽 왼쪽")
        right.update(query: "오른쪽", in: "오른쪽")
        left.selectNext()

        XCTAssertEqual(left.query, "왼쪽")
        XCTAssertEqual(left.matches.count, 2)
        XCTAssertEqual(left.selectedIndex, 1)
        XCTAssertEqual(right.query, "오른쪽")
        XCTAssertEqual(right.matches.count, 1)
        XCTAssertEqual(right.selectedIndex, 0)
    }

    private func makeDocument() -> DocumentNode {
        DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권/001화.txt"),
            userOrder: 1,
            modifiedAt: date,
            contentHash: contentHash,
            cursor: TextCursorState(location: 12, selectionLength: 3),
            isExpanded: false
        )
    }

    private func assertRoundTrip<Value>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws where Value: Codable & Equatable {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }
}
