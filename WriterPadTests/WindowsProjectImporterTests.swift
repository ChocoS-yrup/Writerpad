import Foundation
import SwiftData
import XCTest
@testable import WriterPad

final class WindowsProjectImporterTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    func testNormalProjectImportsWithoutMutatingSourceAndPreservesLegacyFolders() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "정상 작품")
        try writeText("첫 원고", to: fixture.workspace, path: "메인/원고/1권/001화.txt")
        try writeText("사용자 플롯", to: fixture.workspace, path: "메인/플롯/구상.txt")
        try writeText("전환 백업", to: fixture.workspace, path: "백업/전환직전/001화.txt")
        let sourceBefore = try snapshot(of: fixture.container)

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertTrue(report.canImport)
        XCTAssertTrue(report.issues.contains { $0.kind == .legacyPlot })
        XCTAssertTrue(report.issues.contains { $0.kind == .legacyPreMigrationBackup })

        let result = try await harness.importer.importProject(
            from: report,
            confirmsWarnings: true
        )
        let destination = try harness.resolver.standardPaths(
            forProjectNamed: "정상 작품"
        ).workspaceRootURL
        let documents = try await harness.repository.documents(in: result.project.id)
        let sourceAfter = try snapshot(of: fixture.container)

        XCTAssertEqual(sourceAfter, sourceBefore)
        XCTAssertEqual(result.project.name, "정상 작품")
        XCTAssertEqual(result.documentCount, documents.count)
        XCTAssertEqual(Set(documents.map(\.id)).count, documents.count)
        XCTAssertTrue(
            documents.filter { $0.kind == .text }.allSatisfy { $0.contentHash != nil }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("메인/플롯/구상.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("백업/전환직전/001화.txt").path
            )
        )
        XCTAssertEqual(
            Set(result.preservedLegacyPaths.map(\.rawValue)),
            Set(["메인/플롯", "백업/전환직전"])
        )
    }

    func testNonUTF8TextIsFatal() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "인코딩 오류")
        try writeData(
            Data([0xC3, 0x28]),
            to: fixture.workspace,
            path: "메인/원고/1권/001화.txt"
        )

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertFalse(report.canImport)
        XCTAssertTrue(report.fatalIssues.contains { $0.kind == .invalidUTF8 })
    }

    func testDuplicateChapterNumberAcrossVolumesIsFatal() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "중복 화")
        try writeText("1권", to: fixture.workspace, path: "메인/원고/1권/001화.txt")
        try writeText("2권", to: fixture.workspace, path: "메인/원고/2권/001화.txt")

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertFalse(report.canImport)
        XCTAssertTrue(report.fatalIssues.contains { $0.kind == .duplicateChapterNumber })
    }

    func testInvalidVolumeNameIsFatal() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "잘못된 권")
        try writeText("원고", to: fixture.workspace, path: "메인/원고/01권/001화.txt")

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertFalse(report.canImport)
        XCTAssertTrue(report.fatalIssues.contains { $0.kind == .invalidVolumeName })
    }

    func testUnreadableItemIsReportedAsFatal() async throws {
        let harness = try makeHarness(
            faultPlan: ImportFaultPlan(
                point: .unreadableItem(relativePath: "메인/원고/1권/001화.txt")
            )
        )
        let fixture = try makeFixture(in: harness.root, name: "읽기 오류")
        try writeText("원고", to: fixture.workspace, path: "메인/원고/1권/001화.txt")

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertFalse(report.canImport)
        XCTAssertTrue(report.fatalIssues.contains { $0.kind == .unreadableItem })
    }

    func testLargeTreeInspectionCountsEveryChapter() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "대용량 작품")
        for chapter in 1...400 {
            try writeText(
                "\(chapter)화 본문",
                to: fixture.workspace,
                path: String(format: "메인/원고/1권/%03d화.txt", chapter)
            )
        }

        let report = try await harness.importer.inspect(fixture.container)

        XCTAssertTrue(report.canImport)
        XCTAssertEqual(report.textFileCount, 400)
        XCTAssertGreaterThan(report.totalBytes, 0)
    }

    func testMidCopyFailureRollsBackFilesAndMetadataWithoutMutatingSource() async throws {
        let harness = try makeHarness(
            faultPlan: ImportFaultPlan(point: .afterCopiedItem(3))
        )
        let fixture = try makeFixture(in: harness.root, name: "복사 실패")
        try writeText("첫 원고", to: fixture.workspace, path: "메인/원고/1권/001화.txt")
        try writeText("둘째 원고", to: fixture.workspace, path: "메인/원고/1권/002화.txt")
        let sourceBefore = try snapshot(of: fixture.container)
        let report = try await harness.importer.inspect(fixture.container)

        do {
            _ = try await harness.importer.importProject(
                from: report,
                confirmsWarnings: true
            )
            XCTFail("중간 복사 실패가 전파되어야 합니다.")
        } catch {
            XCTAssertEqual(error as? WindowsProjectImporterError, .injectedFailure)
        }

        XCTAssertEqual(try snapshot(of: fixture.container), sourceBefore)
        let projects = try await harness.repository.projects()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.resolver.projectsRootURL
                    .appendingPathComponent("복사 실패").path
            )
        )
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: harness.resolver.projectsRootURL.path
        )
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(".writerpad-import-") })
    }

    func testFailureAfterMetadataRegistrationRollsBackBothStores() async throws {
        let harness = try makeHarness(
            faultPlan: ImportFaultPlan(point: .afterMetadataRegistration)
        )
        let fixture = try makeFixture(in: harness.root, name: "메타데이터 실패")
        try writeText("원고", to: fixture.workspace, path: "메인/원고/1권/001화.txt")
        let report = try await harness.importer.inspect(fixture.container)

        do {
            _ = try await harness.importer.importProject(
                from: report,
                confirmsWarnings: true
            )
            XCTFail("메타데이터 등록 뒤 실패가 전파되어야 합니다.")
        } catch {
            XCTAssertEqual(error as? WindowsProjectImporterError, .injectedFailure)
        }

        let projects = try await harness.repository.projects()
        XCTAssertTrue(projects.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.resolver.projectsRootURL
                    .appendingPathComponent("메타데이터 실패").path
            )
        )
    }

    func testSourceChangeAfterInspectionRequiresARescan() async throws {
        let harness = try makeHarness()
        let fixture = try makeFixture(in: harness.root, name: "검사 후 변경")
        let manuscriptPath = "메인/원고/1권/001화.txt"
        try writeText("검사 당시", to: fixture.workspace, path: manuscriptPath)
        let report = try await harness.importer.inspect(fixture.container)
        try writeText("검사 이후 변경", to: fixture.workspace, path: manuscriptPath)

        do {
            _ = try await harness.importer.importProject(
                from: report,
                confirmsWarnings: true
            )
            XCTFail("검사 후 변경된 원본은 다시 검사해야 합니다.")
        } catch {
            XCTAssertEqual(
                error as? WindowsProjectImporterError,
                .sourceChangedAfterInspection
            )
        }
        let projects = try await harness.repository.projects()
        XCTAssertTrue(projects.isEmpty)
    }

    private struct Harness {
        let root: URL
        let container: ModelContainer
        let repository: SwiftDataMetadataRepository
        let resolver: ProjectPathResolver
        let importer: WindowsProjectImporter
    }

    private struct Fixture {
        let container: URL
        let workspace: URL
    }

    private struct DirectorySnapshot: Equatable {
        let directories: [String]
        let files: [String: Data]
    }

    private struct FixedClock: AppClock {
        let date: Date
        func now() -> Date { date }
    }

    private func makeHarness(
        faultPlan: ImportFaultPlan? = nil
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-ImportTests-\(UUID().uuidString)")
        roots.append(root)
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("ImportedProjects")
        )
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_234_567))
        let manager = LocalProjectManager(
            projectRepository: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: clock
        )
        let importer = WindowsProjectImporter(
            projectRepository: repository,
            documentRepository: repository,
            metadataRegistrar: repository,
            workspaceStateRepository: repository,
            projectManager: manager,
            pathResolver: resolver,
            clock: clock,
            faultPlan: faultPlan
        )
        return Harness(
            root: root,
            container: container,
            repository: repository,
            resolver: resolver,
            importer: importer
        )
    }

    private func makeFixture(in root: URL, name: String) throws -> Fixture {
        let container = root
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let workspace = container.appendingPathComponent("집필모드", isDirectory: true)
        let directories = [
            "메인/원고", "메인/캐릭터", "메인/설정집", "메인/메모장",
            "메인/흐름정리", "메인/복선", "메인/장소", "메인/휴지통",
            "백업/자동저장", "백업/복원전", "백업/충돌"
        ]
        for path in directories {
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let settings = try JSONSerialization.data(
            withJSONObject: ["project_name": name],
            options: [.sortedKeys]
        )
        try writeData(settings, to: workspace, path: "설정.json")
        return Fixture(container: container, workspace: workspace)
    }

    private func writeText(_ text: String, to workspace: URL, path: String) throws {
        try writeData(Data(text.utf8), to: workspace, path: path)
    }

    private func writeData(_ data: Data, to workspace: URL, path: String) throws {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func snapshot(of root: URL) throws -> DirectorySnapshot {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return DirectorySnapshot(directories: [], files: [:])
        }
        var directories: [String] = []
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                directories.append(relative)
            } else if values.isRegularFile == true {
                files[relative] = try Data(contentsOf: url)
            }
        }
        return DirectorySnapshot(directories: directories.sorted(), files: files)
    }
}
