import Foundation
import XCTest
@testable import WriterPad

final class ProjectBackupStoreTests: XCTestCase {
    func testBackupRestoresUUIDFilesBytesHashesAndLogicalTree() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("원본/집필모드", isDirectory: true)
        let draftName = "초안".decomposedStringWithCanonicalMapping
        let volume = source.appendingPathComponent("메인/\(draftName)/1권", isDirectory: true)
        let emptyFolder = source.appendingPathComponent("메인/메모장/빈 폴더", isDirectory: true)
        try fileManager.createDirectory(at: volume, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        let chapterBytes = Data([0xEF, 0xBB, 0xBF])
            + Data("첫 문장🙂\r\n둘째 문장\n".utf8)
        try chapterBytes.write(to: volume.appendingPathComponent("001화.txt"))
        try Data().write(to: volume.appendingPathComponent("002화.txt"))

        let projectID = projectID("3f2a0000-0000-4000-8000-000000000001")
        let mainID = documentID("8c1d0000-0000-4000-8000-000000000001")
        let notesID = documentID("a36c0000-0000-4000-8000-000000000001")
        let draftID = documentID("b47e0000-0000-4000-8000-000000000001")
        let volumeID = documentID("c58f0000-0000-4000-8000-000000000001")
        let chapterID = documentID("d90f0000-0000-4000-8000-000000000001")
        let emptyChapterID = documentID("e01a0000-0000-4000-8000-000000000001")
        let emptyFolderID = documentID("f12b0000-0000-4000-8000-000000000001")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let project = Project(
            id: projectID,
            name: "복원 시험".decomposedStringWithCanonicalMapping,
            createdAt: date,
            modifiedAt: date
        )
        let documents = [
            node(mainID, projectID, .folder, nil, "메인", 0, date),
            node(draftID, projectID, .folder, mainID, "메인/\(draftName)", 0, date),
            node(notesID, projectID, .folder, mainID, "메인/메모장", 1, date),
            node(volumeID, projectID, .folder, draftID, "메인/\(draftName)/1권", 0, date),
            node(chapterID, projectID, .text, volumeID, "메인/\(draftName)/1권/001화.txt", 0, date),
            node(emptyChapterID, projectID, .text, volumeID, "메인/\(draftName)/1권/002화.txt", 1, date),
            node(emptyFolderID, projectID, .folder, notesID, "메인/메모장/빈 폴더", 0, date),
        ]
        let original = try tree(at: source)
        let package = root.appendingPathComponent("독립 백업", isDirectory: true)
        let restored = root.appendingPathComponent("빈 복원 위치", isDirectory: true)
        let store = ProjectBackupStore()

        let backup = try await store.createBackup(
            project: project,
            documents: documents,
            workspaceURL: source,
            packageURL: package
        )
        let restore = try await store.restoreBackup(at: package, to: restored)

        XCTAssertEqual(try tree(at: source), original)
        XCTAssertEqual(restore.manifest, backup.manifest)
        XCTAssertEqual(backup.manifest.formatVersion, 1)
        XCTAssertEqual(
            backup.manifest.project.uuid,
            projectID.rawValue.uuidString.lowercased()
        )
        XCTAssertEqual(backup.manifest.project.title, "복원 시험")
        XCTAssertTrue(
            backup.manifest.nodes.allSatisfy {
                $0.uuid == $0.uuid.lowercased()
                    && $0.parentUUID == $0.parentUUID?.lowercased()
                    && $0.path == $0.path.precomposedStringWithCanonicalMapping
                    && $0.title == $0.title.precomposedStringWithCanonicalMapping
            }
        )

        let chapter = try XCTUnwrap(
            backup.manifest.nodes.first { $0.uuid == chapterID.rawValue.uuidString.lowercased() }
        )
        XCTAssertEqual(chapter.kind, "document")
        XCTAssertEqual(chapter.parentUUID, volumeID.rawValue.uuidString.lowercased())
        XCTAssertEqual(chapter.order, 0)
        XCTAssertEqual(chapter.bytes, chapterBytes.count)
        XCTAssertEqual(
            chapter.sha256,
            SHA256ContentHasher().sha256(for: chapterBytes).rawValue
        )

        let emptyFolderEntry = try XCTUnwrap(
            backup.manifest.nodes.first { $0.uuid == emptyFolderID.rawValue.uuidString.lowercased() }
        )
        XCTAssertEqual(emptyFolderEntry.kind, "folder")
        XCTAssertEqual(emptyFolderEntry.parentUUID, notesID.rawValue.uuidString.lowercased())
        XCTAssertNil(emptyFolderEntry.bytes)
        XCTAssertNil(emptyFolderEntry.sha256)

        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: package.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let encodedNodes = try XCTUnwrap(manifestObject["nodes"] as? [[String: Any]])
        let encodedRoot = try XCTUnwrap(
            encodedNodes.first { $0["uuid"] as? String == mainID.rawValue.uuidString.lowercased() }
        )
        XCTAssertTrue(encodedRoot["parent_uuid"] is NSNull)
        let encodedEmptyFolder = try XCTUnwrap(
            encodedNodes.first { $0["uuid"] as? String == emptyFolderID.rawValue.uuidString.lowercased() }
        )
        XCTAssertNil(encodedEmptyFolder["bytes"])
        XCTAssertNil(encodedEmptyFolder["sha256"])

        let expectedFiles = [
            chapterID.rawValue.uuidString.lowercased(): chapterBytes,
            emptyChapterID.rawValue.uuidString.lowercased(): Data(),
        ]
        XCTAssertEqual(try files(at: package.appendingPathComponent("workspace")), expectedFiles)
        XCTAssertEqual(try files(at: restored), expectedFiles)
    }

    private func projectID(_ value: String) -> ProjectID {
        ProjectID(rawValue: UUID(uuidString: value)!)
    }

    private func documentID(_ value: String) -> DocumentID {
        DocumentID(rawValue: UUID(uuidString: value)!)
    }

    private func node(
        _ id: DocumentID,
        _ projectID: ProjectID,
        _ kind: DocumentKind,
        _ parentID: DocumentID?,
        _ path: String,
        _ order: Int,
        _ date: Date
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: kind,
            parentID: parentID,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: order,
            modifiedAt: date,
            contentHash: nil
        )
    }

    private func files(at root: URL) throws -> [String: Data] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try Dictionary(uniqueKeysWithValues: urls.map {
            ($0.lastPathComponent, try Data(contentsOf: $0))
        })
    }

    private func tree(at root: URL) throws -> [String: Data?] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var result: [String: Data?] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            result[relativePath] = values.isDirectory == true ? nil : try Data(contentsOf: url)
        }
        return result
    }
}
