import Foundation
import XCTest
@testable import WriterPad

final class ProjectBackupStoreTests: XCTestCase {
    @MainActor
    func testFreshProjectBackupIncludesCreationTimeTrashIdentity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("Projects", isDirectory: true)
        )
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let manager = LocalProjectManager(
            projectRepository: repository,
            creationMetadataStore: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: TestClock(date: Date(timeIntervalSince1970: 1_700_000_000))
        )
        let project = try await manager.createProject(named: "생성 즉시 백업")
        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: resolver
        )
        let coordinator = ProjectBackupCoordinator(
            projectRepository: repository,
            documentRepository: repository,
            workspaceLocator: locator
        )

        let backup = try await coordinator.createBackup(
            for: project.id,
            at: root.appendingPathComponent("독립 백업", isDirectory: true)
        )
        let main = try XCTUnwrap(backup.manifest.nodes.first { $0.path == "메인" })
        let trash = try XCTUnwrap(
            backup.manifest.nodes.first { $0.path == "메인/휴지통" }
        )

        XCTAssertEqual(backup.manifest.nodes.count, 10)
        XCTAssertEqual(trash.kind, "folder")
        XCTAssertEqual(trash.parentUUID, main.uuid)
        XCTAssertEqual(trash.order, BinderFixedCategory.trash.fixedOrder)
    }

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
        XCTAssertEqual(backup.manifest.project.order, 0)
        let encodedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: package.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let encodedProject = try XCTUnwrap(encodedManifest["project"] as? [String: Any])
        XCTAssertEqual(encodedProject["order"] as? Int, 0)
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

    @MainActor
    func testCoordinatorBacksUpProjectFromLocalUUIDRepositories() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }

        let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
        let resolver = ProjectPathResolver(projectsRootURL: projectsRoot)
        let paths = try resolver.createStandardStructure(forProjectNamed: "통합 시험")
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: resolver
        )

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let projectID = projectID("3f2a0000-0000-4000-8000-000000000001")
        let mainID = documentID("8c1d0000-0000-4000-8000-000000000001")
        let draftID = documentID("b47e0000-0000-4000-8000-000000000001")
        let chapterID = documentID("d90f0000-0000-4000-8000-000000000001")
        let project = Project(
            id: projectID,
            name: "통합 시험",
            createdAt: date,
            modifiedAt: date
        )
        try await repository.save(project)
        try await repository.save(node(mainID, projectID, .folder, nil, "메인", 0, date))
        try await repository.save(
            node(draftID, projectID, .folder, mainID, "메인/초안", 0, date)
        )
        try await repository.save(
            node(chapterID, projectID, .text, draftID, "메인/초안/001화.txt", 0, date)
        )

        let draft = paths.workspaceRootURL
            .appendingPathComponent("메인/초안", isDirectory: true)
        try fileManager.createDirectory(at: draft, withIntermediateDirectories: true)
        let originalBytes = Data([0xEF, 0xBB, 0xBF])
            + Data("합성 문장\r\n둘째 줄\n".utf8)
        try originalBytes.write(to: draft.appendingPathComponent("001화.txt"))
        let originalTree = try tree(at: paths.workspaceRootURL)

        let coordinator = ProjectBackupCoordinator(
            projectRepository: repository,
            documentRepository: repository,
            workspaceLocator: locator
        )
        let package = root.appendingPathComponent("독립 백업", isDirectory: true)
        let restored = root.appendingPathComponent("빈 복원 위치", isDirectory: true)

        let backup = try await coordinator.createBackup(for: projectID, at: package)
        let restore = try await coordinator.restoreBackup(at: package, to: restored)

        XCTAssertEqual(try tree(at: paths.workspaceRootURL), originalTree)
        XCTAssertEqual(restore.manifest, backup.manifest)
        XCTAssertEqual(backup.manifest.project.uuid, projectID.rawValue.uuidString.lowercased())
        XCTAssertEqual(
            Set(backup.manifest.nodes.map(\.uuid)),
            Set([mainID, draftID, chapterID].map { $0.rawValue.uuidString.lowercased() })
        )
        XCTAssertEqual(
            try Data(contentsOf: restored.appendingPathComponent(
                chapterID.rawValue.uuidString.lowercased()
            )),
            originalBytes
        )
    }

    func testValidationRejectsUnexpectedPayloadWithoutCreatingDestination() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        let package = root.appendingPathComponent("패키지", isDirectory: true)
        let destination = root.appendingPathComponent("복원 대상", isDirectory: true)
        let manifest = ProjectBackupManifest(
            formatVersion: 1,
            project: .init(
                uuid: UUID().uuidString.lowercased(),
                title: "검증 작품",
                order: 0
            ),
            nodes: [
                .init(
                    uuid: UUID().uuidString.lowercased(),
                    kind: "folder",
                    parentUUID: nil,
                    path: "메인",
                    title: "메인",
                    order: 0,
                    bytes: nil,
                    sha256: nil
                )
            ]
        )
        try writePackage(manifest, payloads: [:], at: package)
        try Data("계약 밖 파일".utf8).write(
            to: package.appendingPathComponent("workspace/extra")
        )

        do {
            _ = try await ProjectBackupStore().restoreBackup(
                at: package,
                to: destination
            )
            XCTFail("manifest에 없는 payload를 허용하면 안 됩니다.")
        } catch let error as ProjectBackupError {
            guard case .unexpectedPackageEntry = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path))
    }

    func testValidationRejectsDuplicateSiblingOrderAndCycle() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: root) }
        let projectUUID = UUID().uuidString.lowercased()
        let firstID = UUID().uuidString.lowercased()
        let secondID = UUID().uuidString.lowercased()
        let duplicateOrder = ProjectBackupManifest(
            formatVersion: 1,
            project: .init(uuid: projectUUID, title: "순서 검증", order: 0),
            nodes: [
                .init(
                    uuid: firstID, kind: "folder", parentUUID: nil,
                    path: "메인", title: "메인", order: 0,
                    bytes: nil, sha256: nil
                ),
                .init(
                    uuid: secondID, kind: "folder", parentUUID: nil,
                    path: "다른 루트", title: "다른 루트", order: 0,
                    bytes: nil, sha256: nil
                ),
            ]
        )
        let duplicatePackage = root.appendingPathComponent("중복 순서")
        try writePackage(duplicateOrder, payloads: [:], at: duplicatePackage)
        do {
            _ = try await ProjectBackupStore().validatedManifest(at: duplicatePackage)
            XCTFail("같은 부모 아래 중복 order를 허용하면 안 됩니다.")
        } catch let error as ProjectBackupError {
            guard case .invalidManifest = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }

        let invalidProjectOrder = ProjectBackupManifest(
            formatVersion: 1,
            project: .init(uuid: projectUUID, title: "작품 순서 검증", order: 1),
            nodes: [
                .init(
                    uuid: firstID, kind: "folder", parentUUID: nil,
                    path: "메인", title: "메인", order: 0,
                    bytes: nil, sha256: nil
                ),
            ]
        )
        let invalidProjectOrderPackage = root.appendingPathComponent("잘못된 작품 순서")
        try writePackage(invalidProjectOrder, payloads: [:], at: invalidProjectOrderPackage)
        do {
            _ = try await ProjectBackupStore().validatedManifest(
                at: invalidProjectOrderPackage
            )
            XCTFail("project.order 0 이외의 값을 허용하면 안 됩니다.")
        } catch let error as ProjectBackupError {
            guard case .invalidManifest = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }

        let cycle = ProjectBackupManifest(
            formatVersion: 1,
            project: .init(uuid: projectUUID, title: "순환 검증", order: 0),
            nodes: [
                .init(
                    uuid: firstID, kind: "folder", parentUUID: secondID,
                    path: "참고/A", title: "A", order: 0,
                    bytes: nil, sha256: nil
                ),
                .init(
                    uuid: secondID, kind: "folder", parentUUID: firstID,
                    path: "참고/B", title: "B", order: 0,
                    bytes: nil, sha256: nil
                ),
            ]
        )
        let cyclePackage = root.appendingPathComponent("순환")
        try writePackage(cycle, payloads: [:], at: cyclePackage)
        do {
            _ = try await ProjectBackupStore().validatedManifest(at: cyclePackage)
            XCTFail("순환 parent_uuid를 허용하면 안 됩니다.")
        } catch let error as ProjectBackupError {
            guard case .invalidManifest = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }
    }

    private func projectID(_ value: String) -> ProjectID {
        ProjectID(rawValue: UUID(uuidString: value)!)
    }

    private struct TestClock: AppClock {
        let date: Date
        func now() -> Date { date }
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

    private func writePackage(
        _ manifest: ProjectBackupManifest,
        payloads: [String: Data],
        at package: URL
    ) throws {
        let workspace = package.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: package.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )
        for (name, data) in payloads {
            try data.write(to: workspace.appendingPathComponent(name), options: [.atomic])
        }
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
