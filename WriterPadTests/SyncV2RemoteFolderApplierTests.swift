import Foundation
import XCTest
@testable import WriterPad

/// 계획이 아니라 실제 디스크와 메타데이터에 무슨 일이 일어나는지 본다.
final class SyncV2RemoteFolderApplierTests: XCTestCase {
    private let projectID = ProjectID(rawValue: UUID())
    private let rootID = DocumentID(rawValue: UUID())

    /// 실기기에서 확인된 증상이다. 빈 폴더는 디스크에 디렉터리만 있고 안이
    /// 비어 있어, 문서 이동으로는 절대 따라오지 않는다.
    func testEmptyFolderIsMovedOnDiskAndInMetadata() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/가 나 다", parent: rootID),
            ]
        )
        try fixture.makeDirectory("메인/가 나 다")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(
                    id: folderID,
                    parent: rootID,
                    name: "가 나 다 바"
                ),
            ],
            blockedFolderIDs: []
        )

        XCTAssertEqual(report.movedFolderIDs, [folderID])
        XCTAssertTrue(fixture.exists("메인/가 나 다 바"))
        XCTAssertFalse(fixture.exists("메인/가 나 다"))
        let stored = try await fixture.repository.documents(in: projectID)
        let moved = try XCTUnwrap(stored.first { $0.id == folderID })
        // 폴더가 하나만 남아야 한다. 지우고 새로 만들면 둘이 된다.
        XCTAssertEqual(moved.relativePath.rawValue, "메인/가 나 다 바")
        XCTAssertEqual(stored.filter { $0.kind == .folder }.count, 2)
    }

    func testMovingAFolderRewritesItsDescendantPaths() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let childID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/옛 이름", parent: rootID),
                text(
                    id: childID,
                    path: "메인/옛 이름/001화.txt",
                    parent: folderID
                ),
            ]
        )
        try fixture.makeDirectory("메인/옛 이름")
        try fixture.write("메인/옛 이름/001화.txt", contents: "본문")

        _ = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "새 이름"),
            ],
            blockedFolderIDs: []
        )

        let stored = try await fixture.repository.documents(in: projectID)
        let child = try XCTUnwrap(stored.first { $0.id == childID })
        // 폴더가 통째로 움직였으므로 그 아래 문서의 경로 캐시도 새 경로여야
        // 한다. 옛 경로가 남으면 그 문서를 다시 열 수 없다.
        XCTAssertEqual(
            child.relativePath.rawValue,
            "메인/새 이름/001화.txt"
        )
        XCTAssertEqual(child.id, childID)
        XCTAssertTrue(fixture.exists("메인/새 이름/001화.txt"))
    }

    func testTombstoneWithLocalContentIsRefusedInsteadOfDeleting()
        async throws {
        let folderID = DocumentID(rawValue: UUID())
        let childID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/지울 폴더", parent: rootID),
                text(
                    id: childID,
                    path: "메인/지울 폴더/미전송.txt",
                    parent: folderID
                ),
            ]
        )
        try fixture.makeDirectory("메인/지울 폴더")
        try fixture.write("메인/지울 폴더/미전송.txt", contents: "아직 못 올림")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(
                    id: folderID,
                    parent: rootID,
                    name: "지울 폴더",
                    isDeleted: true
                ),
            ],
            blockedFolderIDs: []
        )

        // 그 안의 내용은 아직 서버로 못 간 사용자의 자료일 수 있다.
        XCTAssertTrue(report.deletedFolderIDs.isEmpty)
        XCTAssertEqual(report.rejectedNames.count, 1)
        XCTAssertTrue(fixture.exists("메인/지울 폴더/미전송.txt"))
    }

    func testEmptyTombstonedFolderIsRemoved() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/빈 폴더", parent: rootID),
            ]
        )
        try fixture.makeDirectory("메인/빈 폴더")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(
                    id: folderID,
                    parent: rootID,
                    name: "빈 폴더",
                    isDeleted: true
                ),
            ],
            blockedFolderIDs: []
        )

        XCTAssertEqual(report.deletedFolderIDs, [folderID])
        XCTAssertFalse(fixture.exists("메인/빈 폴더"))
        let stored = try await fixture.repository.documents(in: projectID)
        XCTAssertNil(stored.first { $0.id == folderID })
    }

    func testOccupiedDestinationOnDiskIsNotOverwritten() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/처음", parent: rootID),
            ]
        )
        try fixture.makeDirectory("메인/처음")
        // 계획을 세운 뒤에 누군가 그 자리를 차지한 상황이다. 메타데이터에는
        // 없지만 디스크에는 있다.
        try fixture.makeDirectory("메인/나중")
        try fixture.write("메인/나중/남의 원고.txt", contents: "지우면 안 됨")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "나중"),
            ],
            blockedFolderIDs: []
        )

        XCTAssertTrue(report.movedFolderIDs.isEmpty)
        XCTAssertEqual(report.rejectedNames.count, 1)
        XCTAssertTrue(fixture.exists("메인/나중/남의 원고.txt"))
        XCTAssertTrue(fixture.exists("메인/처음"))
    }

    func testFolderNewToThisDeviceIsCreatedOnDisk() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [folder(id: rootID, path: "메인", parent: nil)]
        )
        try fixture.makeDirectory("메인")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "새 폴더"),
            ],
            blockedFolderIDs: []
        )

        XCTAssertEqual(report.createdFolderIDs, [folderID])
        XCTAssertTrue(fixture.exists("메인/새 폴더"))
        let stored = try await fixture.repository.documents(in: projectID)
        let created = try XCTUnwrap(stored.first { $0.id == folderID })
        XCTAssertEqual(created.parentID, rootID)
    }

    func testEmptyRemoteListChangesNothing() async throws {
        let folderID = DocumentID(rawValue: UUID())
        let fixture = try Fixture(
            projectID: projectID,
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/그대로", parent: rootID),
            ]
        )
        try fixture.makeDirectory("메인/그대로")

        let report = await fixture.applier.applyRemoteFolders(
            localProjectID: projectID,
            remote: [],
            blockedFolderIDs: []
        )

        // 폴더 표를 아직 읽지 못하는 서버에서도 퇴보가 없어야 한다.
        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(fixture.exists("메인/그대로"))
    }

    private func remoteFolder(
        id: DocumentID,
        parent: DocumentID?,
        name: String,
        isDeleted: Bool = false
    ) -> SyncV2RemoteFolder {
        SyncV2RemoteFolder(
            folderID: id.rawValue,
            parentFolderID: parent?.rawValue,
            name: name,
            revision: 1,
            isDeleted: isDeleted,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func folder(
        id: DocumentID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        node(id: id, path: path, parent: parent, kind: .folder)
    }

    private func text(
        id: DocumentID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        node(id: id, path: path, parent: parent, kind: .text)
    }

    private func node(
        id: DocumentID,
        path: String,
        parent: DocumentID?,
        kind: DocumentKind
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: kind,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }

    private final class Fixture {
        let root: URL
        let repository: FolderApplierRepositoryStub
        let applier: SyncV2RemoteFolderApplier

        init(projectID: ProjectID, documents: [DocumentNode]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "WriterPad-folder-apply-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            repository = FolderApplierRepositoryStub(documents: documents)
            applier = SyncV2RemoteFolderApplier(
                documentRepository: repository,
                workspaceLocator: FolderApplierWorkspaceLocator(root: root)
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func makeDirectory(_ path: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        func write(_ path: String, contents: String) throws {
            try Data(contents.utf8).write(
                to: root.appendingPathComponent(path)
            )
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path
            )
        }
    }
}

private actor FolderApplierRepositoryStub: DocumentRepository {
    private var storage: [DocumentNode]

    init(documents: [DocumentNode]) {
        storage = documents
    }

    func documents(in projectID: ProjectID) throws -> [DocumentNode] {
        storage.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) throws -> DocumentNode? {
        storage.first { $0.id == id }
    }

    func save(_ document: DocumentNode) throws {
        if let index = storage.firstIndex(where: { $0.id == document.id }) {
            storage[index] = document
        } else {
            storage.append(document)
        }
    }

    func removeMetadata(id: DocumentID) throws {
        storage.removeAll { $0.id == id }
    }
}

private struct FolderApplierWorkspaceLocator: ProjectWorkspaceLocating {
    let root: URL

    func workspaceRoot(for projectID: ProjectID) throws -> URL {
        _ = projectID
        return root
    }
}
