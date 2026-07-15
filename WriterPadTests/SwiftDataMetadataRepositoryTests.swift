import Foundation
import SwiftData
import XCTest
@testable import WriterPad

final class SwiftDataMetadataRepositoryTests: XCTestCase {
    private let projectID = ProjectID(
        rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    )
    private let otherProjectID = ProjectID(
        rawValue: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    )
    private let folderID = DocumentID(
        rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    )
    private let firstDocumentID = DocumentID(
        rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
    )
    private let secondDocumentID = DocumentID(
        rawValue: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!
    )
    private let date = Date(timeIntervalSince1970: 3_000)

    @MainActor
    func testFirstLaunchHasSafeDefaults() async throws {
        let repository = try makeInMemoryRepository()

        let initialProjects = try await repository.projects()
        let initialLastProjectID = try await repository.lastProjectID()
        XCTAssertEqual(initialProjects, [])
        XCTAssertNil(initialLastProjectID)

        try await repository.save(makeProject())
        let defaultBinderWidth = try await repository.binderWidth(for: projectID)
        let defaultEditorState = try await repository.editorState(for: projectID)
        XCTAssertEqual(
            defaultBinderWidth,
            SwiftDataMetadataRepository.defaultBinderWidth
        )
        XCTAssertEqual(
            defaultEditorState,
            EditorWorkspaceState(
                projectID: projectID,
                left: EditorPaneState(documentID: nil, cursor: .start),
                right: nil,
                activePane: .left
            )
        )
    }

    @MainActor
    func testMetadataRestoresAfterContainerReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPadMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("WriterPad.store")

        try await seedPersistentStore(at: storeURL)
        try await verifyPersistentStore(at: storeURL)
    }

    @MainActor
    func testInvalidAndCrossProjectParentsAreRejected() async throws {
        let repository = try makeInMemoryRepository()
        try await repository.save(makeProject())
        try await repository.save(
            Project(
                id: otherProjectID,
                name: "다른 작품",
                createdAt: date,
                modifiedAt: date
            )
        )
        try await repository.save(makeFolder())

        let missingParent = makeDocument(
            id: firstDocumentID,
            projectID: projectID,
            parentID: DocumentID(rawValue: UUID()),
            order: 1,
            path: "메인/원고/1권/001화.txt"
        )
        await assertMetadataError(.missingParent(missingParent.parentID!)) {
            try await repository.save(missingParent)
        }

        let crossProject = makeDocument(
            id: secondDocumentID,
            projectID: otherProjectID,
            parentID: folderID,
            order: 1,
            path: "메인/원고/1권/001화.txt"
        )
        await assertMetadataError(.parentBelongsToAnotherProject(folderID)) {
            try await repository.save(crossProject)
        }
    }

    @MainActor
    func testSavingSameDocumentIDUpdatesInsteadOfDuplicating() async throws {
        let repository = try makeInMemoryRepository()
        try await repository.save(makeProject())
        try await repository.save(makeFolder())
        let original = makeDocument(
            id: firstDocumentID,
            projectID: projectID,
            parentID: folderID,
            order: 1,
            path: "메인/원고/1권/001화.txt"
        )
        try await repository.save(original)
        try await repository.save(
            original.relocated(
                to: RelativeDocumentPath(rawValue: "메인/원고/1권/002화.txt"),
                parentID: folderID,
                userOrder: 2,
                at: date.addingTimeInterval(1)
            )
        )

        let matches = try await repository.documents(in: projectID)
            .filter { $0.id == firstDocumentID }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.relativePath.rawValue, "메인/원고/1권/002화.txt")
    }

    @MainActor
    func testCorruptedRecordIsReportedWithoutTouchingManuscript() async throws {
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        container.mainContext.insert(
            ProjectRecord(
                id: projectID.rawValue,
                name: "손상 테스트",
                createdAt: date,
                modifiedAt: date
            )
        )
        container.mainContext.insert(
            DocumentRecord(
                id: firstDocumentID.rawValue,
                projectID: projectID.rawValue,
                kindRawValue: "unknown-kind",
                parentID: nil,
                relativePath: "메인/원고/1권/001화.txt",
                userOrder: 1,
                modifiedAt: date,
                contentHash: nil,
                isDeleted: false,
                originalPath: nil,
                deletedAt: nil,
                cursorLocation: 0,
                selectionLength: 0,
                isExpanded: false
            )
        )
        try container.mainContext.save()
        let repository = SwiftDataMetadataRepository(modelContainer: container)

        do {
            _ = try await repository.documents(in: projectID)
            XCTFail("손상 메타데이터 오류가 필요합니다.")
        } catch let error as MetadataRepositoryError {
            guard case .corruptedRecord = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    @MainActor
    func testSwiftDataDocumentRecordHasNoBodyField() {
        let record = DocumentRecord(
            id: firstDocumentID.rawValue,
            projectID: projectID.rawValue,
            kindRawValue: DocumentKind.text.rawValue,
            parentID: nil,
            relativePath: "메인/원고/1권/001화.txt",
            userOrder: 1,
            modifiedAt: date,
            contentHash: nil,
            isDeleted: false,
            originalPath: nil,
            deletedAt: nil,
            cursorLocation: 0,
            selectionLength: 0,
            isExpanded: false
        )
        let fieldNames = Set(
            Mirror(reflecting: record).children.compactMap(\.label).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            }
        )

        XCTAssertFalse(fieldNames.contains("text"))
        XCTAssertFalse(fieldNames.contains("body"))
        XCTAssertFalse(fieldNames.contains("content"))
        XCTAssertFalse(fieldNames.contains("manuscript"))
    }

    @MainActor
    private func seedPersistentStore(at storeURL: URL) async throws {
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        try await repository.save(makeProject())
        try await repository.save(makeFolder())
        try await repository.save(
            makeDocument(
                id: secondDocumentID,
                projectID: projectID,
                parentID: folderID,
                order: 2,
                path: "메인/원고/1권/002화.txt"
            )
        )
        try await repository.save(
            makeDocument(
                id: firstDocumentID,
                projectID: projectID,
                parentID: folderID,
                order: 1,
                path: "메인/원고/1권/001화.txt"
            )
        )
        try await repository.setLastProjectID(projectID)
        try await repository.setExpanded(true, for: folderID)
        try await repository.setBinderWidth(412, for: projectID)
        try await repository.saveEditorState(
            EditorWorkspaceState(
                projectID: projectID,
                left: EditorPaneState(
                    documentID: firstDocumentID,
                    cursor: TextCursorState(location: 27, selectionLength: 2)
                ),
                right: EditorPaneState(documentID: secondDocumentID, cursor: .start),
                activePane: .right
            )
        )
    }

    @MainActor
    private func verifyPersistentStore(at storeURL: URL) async throws {
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: storeURL
        )
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let restoredLastProjectID = try await repository.lastProjectID()
        let restoredProject = try await repository.project(id: projectID)
        XCTAssertEqual(restoredLastProjectID, projectID)
        XCTAssertEqual(restoredProject?.id, projectID)

        let documents = try await repository.documents(in: projectID)
        let expandedFolderIDs = try await repository.expandedFolderIDs(in: projectID)
        let binderWidth = try await repository.binderWidth(for: projectID)
        XCTAssertEqual(documents.map(\.userOrder), [0, 1, 2])
        XCTAssertEqual(expandedFolderIDs, Set([folderID]))
        XCTAssertEqual(binderWidth, 412)

        let editor = try await repository.editorState(for: projectID)
        XCTAssertEqual(editor.left.documentID, firstDocumentID)
        XCTAssertEqual(editor.left.cursor, TextCursorState(location: 27, selectionLength: 2))
        XCTAssertEqual(editor.right?.documentID, secondDocumentID)
        XCTAssertEqual(editor.activePane, .right)
    }

    @MainActor
    private func makeInMemoryRepository() throws -> SwiftDataMetadataRepository {
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        return SwiftDataMetadataRepository(modelContainer: container)
    }

    private func makeProject() -> Project {
        Project(id: projectID, name: "재실행 테스트", createdAt: date, modifiedAt: date)
    }

    private func makeFolder() -> DocumentNode {
        DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권"),
            userOrder: 0,
            modifiedAt: date,
            contentHash: nil
        )
    }

    private func makeDocument(
        id: DocumentID,
        projectID: ProjectID,
        parentID: DocumentID?,
        order: Int,
        path: String
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: .text,
            parentID: parentID,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: order,
            modifiedAt: date,
            contentHash: nil
        )
    }

    @MainActor
    private func assertMetadataError(
        _ expected: MetadataRepositoryError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("예상한 메타데이터 오류가 발생하지 않았습니다.")
        } catch let error as MetadataRepositoryError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("예상하지 못한 오류: \(error)")
        }
    }
}
