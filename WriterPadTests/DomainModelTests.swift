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
