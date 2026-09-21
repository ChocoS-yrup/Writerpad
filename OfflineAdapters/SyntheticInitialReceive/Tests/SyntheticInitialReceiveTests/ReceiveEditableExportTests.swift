import XCTest
@testable import SyntheticInitialReceive

final class ReceiveEditableExportTests: XCTestCase {
    private func snapshot(
        name: String = "본문.txt",
        text: String = "한글\n마지막 LF\n",
        revision: Int = 2,
        second: ReceiveEditableSnapshot.Document? = nil
    ) -> (ReceiveEditableSnapshot, UUID) {
        let id = UUID()
        var documents = [ReceiveEditableSnapshot.Document(
            id: id,
            name: name,
            text: text,
            revision: revision
        )]
        if let second { documents.append(second) }
        return (.init(
            sourceRun: UUID().uuidString.lowercased(),
            folderName: "작품",
            documents: documents
        ), id)
    }

    func testKoreanAndFinalLineFeedAreExactAndVerifiable() throws {
        let (current, id) = snapshot()
        let payload = try ReceiveEditableExport.prepare(
            snapshot: current,
            documentID: id,
            draftText: "한글\n마지막 LF\n"
        )
        XCTAssertEqual(payload.fileName, "본문.txt")
        XCTAssertEqual(payload.bytes, Data("한글\n마지막 LF\n".utf8))
        XCTAssertEqual(payload.sha256, byteHash(payload.bytes))
        XCTAssertNoThrow(try payload.verifyExternal(payload.bytes))
        XCTAssertNoThrow(try payload.verifyCurrent(current))
    }

    func testEmptyDocumentCreatesZeroByteTXT() throws {
        let (current, id) = snapshot(name: "빈문서", text: "", revision: 0)
        let payload = try ReceiveEditableExport.prepare(snapshot: current, documentID: id, draftText: "")
        XCTAssertEqual(payload.fileName, "빈문서.txt")
        XCTAssertTrue(payload.bytes.isEmpty)
        XCTAssertNoThrow(try payload.verifyExternal(Data()))
    }

    func testExistingTXTExtensionIsNotDuplicated() throws {
        let (current, id) = snapshot(name: "본문.TXT")
        let payload = try ReceiveEditableExport.prepare(snapshot: current, documentID: id, draftText: current.documents[0].text)
        XCTAssertEqual(payload.fileName, "본문.TXT")
    }

    func testUnsavedDraftAndUnknownDocumentAreRejected() throws {
        let (current, id) = snapshot()
        XCTAssertThrowsError(try ReceiveEditableExport.prepare(snapshot: current, documentID: id, draftText: "미저장")) {
            XCTAssertEqual($0 as? ReceiveEditableExportError, .unsavedDraft)
        }
        XCTAssertThrowsError(try ReceiveEditableExport.prepare(snapshot: current, documentID: UUID(), draftText: "")) {
            XCTAssertEqual($0 as? ReceiveEditableExportError, .document)
        }
    }

    func testPartialOrChangedExternalResultIsRejected() throws {
        let (current, id) = snapshot()
        let payload = try ReceiveEditableExport.prepare(snapshot: current, documentID: id, draftText: current.documents[0].text)
        for result in [Data(payload.bytes.dropLast()), Data("다른 본문\n".utf8)] {
            XCTAssertThrowsError(try payload.verifyExternal(result)) {
                XCTAssertEqual($0 as? ReceiveEditableExportError, .externalMismatch)
            }
        }
    }

    func testAnyWorkspaceChangeBlocksCompletion() throws {
        let otherID = UUID()
        let other = ReceiveEditableSnapshot.Document(id: otherID, name: "둘째.txt", text: "그대로", revision: 0)
        let (current, id) = snapshot(second: other)
        let payload = try ReceiveEditableExport.prepare(snapshot: current, documentID: id, draftText: current.documents[0].text)

        let changedOther = ReceiveEditableSnapshot(
            sourceRun: current.sourceRun,
            folderName: current.folderName,
            documents: [current.documents[0], .init(id: otherID, name: "둘째.txt", text: "변경", revision: 1)]
        )
        XCTAssertThrowsError(try payload.verifyCurrent(changedOther)) {
            XCTAssertEqual($0 as? ReceiveEditableExportError, .workspaceChanged)
        }

        let changedRevision = ReceiveEditableSnapshot(
            sourceRun: current.sourceRun,
            folderName: current.folderName,
            documents: [.init(id: id, name: "본문.txt", text: current.documents[0].text, revision: 3), other]
        )
        XCTAssertThrowsError(try payload.verifyCurrent(changedRevision))
    }

    func testUnsafeNameAndMalformedSnapshotAreRejected() throws {
        let (unsafe, id) = snapshot(name: "../본문.txt")
        XCTAssertThrowsError(try ReceiveEditableExport.prepare(snapshot: unsafe, documentID: id, draftText: unsafe.documents[0].text))

        let malformed = ReceiveEditableSnapshot(
            sourceRun: "not-a-run",
            folderName: "작품",
            documents: unsafe.documents.map { .init(id: $0.id, name: "본문.txt", text: $0.text, revision: $0.revision) }
        )
        XCTAssertThrowsError(try ReceiveEditableExport.prepare(snapshot: malformed, documentID: id, draftText: malformed.documents[0].text))
    }
}
