import Foundation
import SwiftData
import XCTest
@testable import WriterPad

final class LocalProjectManagerTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    func testCreateBuildsCompleteStructureAndDuplicateRequestIsIdempotent() async throws {
        let harness = try makeHarness()

        let first = try await harness.manager.createProject(named: "나의 작품")
        let second = try await harness.manager.createProject(named: "나의 작품")
        let paths = try harness.resolver.standardPaths(forProjectNamed: "나의 작품")

        XCTAssertEqual(first.id, second.id)
        let storedProjects = try await harness.repository.projects()
        XCTAssertEqual(storedProjects.count, 1)
        for directory in paths.requiredDirectories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
        XCTAssertEqual(
            try harness.resolver.storedProjectName(forProjectNamed: "나의 작품"),
            "나의 작품"
        )
        XCTAssertFalse(try rootItems(harness).contains { $0.hasSuffix(".tmp") })
        XCTAssertFalse(try rootItems(harness).contains { $0.contains("transaction") })
    }

    func testNormalizedNameCollisionDoesNotOverwriteExistingProject() async throws {
        let harness = try makeHarness()
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        _ = try await harness.manager.createProject(named: composed)

        do {
            _ = try await harness.manager.createProject(named: decomposed)
            XCTFail("Unicode 정규화 충돌을 허용하면 안 됩니다.")
        } catch let error as PathPolicyError {
            guard case .nameCollision = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }

        let storedProjects = try await harness.repository.projects()
        XCTAssertEqual(storedProjects.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try harness.resolver.standardPaths(
                    forProjectNamed: composed
                ).projectContainerURL.path
            )
        )
    }

    func testCreateFailureRollsBackMetadataAndFolders() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterMetadataSave,
                leavesTransactionForRecovery: false
            )
        )

        do {
            _ = try await harness.manager.createProject(named: "실패 작품")
            XCTFail("주입된 실패가 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: false))
        }

        let storedProjects = try await harness.repository.projects()
        XCTAssertTrue(storedProjects.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try harness.resolver.standardPaths(
                    forProjectNamed: "실패 작품"
                ).projectContainerURL.path
            )
        )
        XCTAssertFalse(try rootItems(harness).contains { $0.contains("transaction") })
    }

    func testNewManagerCompletesInterruptedCreation() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterMetadataSave,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await harness.manager.createProject(named: "복구 작품")
            XCTFail("테스트 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recovered = try await restarted.projects()

        XCTAssertEqual(recovered.map(\.name), ["복구 작품"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try harness.resolver.standardPaths(
                    forProjectNamed: "복구 작품"
                ).projectContainerURL.path
            )
        )
        XCTAssertFalse(try rootItems(harness).contains { $0.contains("transaction") })
    }

    func testRenameUpdatesFolderSettingsAndMetadata() async throws {
        let harness = try makeHarness()
        let created = try await harness.manager.createProject(named: "변경 전")

        let renamed = try await harness.manager.renameProject(
            id: created.id,
            to: "변경 후"
        )

        XCTAssertEqual(renamed.name, "변경 후")
        let stored = try await harness.repository.project(id: created.id)
        XCTAssertEqual(stored?.name, "변경 후")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try harness.resolver.standardPaths(
                    forProjectNamed: "변경 전"
                ).projectContainerURL.path
            )
        )
        XCTAssertEqual(
            try harness.resolver.storedProjectName(forProjectNamed: "변경 후"),
            "변경 후"
        )
    }

    func testRenameFailureRollsBackFolderSettingsAndMetadata() async throws {
        let base = try makeHarness()
        let created = try await base.manager.createProject(named: "원래 이름")
        let failing = makeManager(
            from: base,
            faultPlan: ProjectManagerFaultPlan(
                point: .afterFileMove,
                leavesTransactionForRecovery: false
            )
        )

        do {
            _ = try await failing.renameProject(id: created.id, to: "실패 이름")
            XCTFail("주입된 실패가 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: false))
        }

        let stored = try await base.repository.project(id: created.id)
        XCTAssertEqual(stored?.name, "원래 이름")
        XCTAssertEqual(
            try base.resolver.storedProjectName(forProjectNamed: "원래 이름"),
            "원래 이름"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try base.resolver.standardPaths(
                    forProjectNamed: "실패 이름"
                ).projectContainerURL.path
            )
        )
    }

    func testNewManagerCompletesInterruptedRename() async throws {
        let base = try makeHarness()
        let created = try await base.manager.createProject(named: "중단 전")
        let interrupted = makeManager(
            from: base,
            faultPlan: ProjectManagerFaultPlan(
                point: .afterFileMove,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await interrupted.renameProject(id: created.id, to: "중단 후")
            XCTFail("테스트 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: base)
        let recovered = try await restarted.projects()

        XCTAssertEqual(recovered.map(\.name), ["중단 후"])
        XCTAssertEqual(
            try base.resolver.storedProjectName(forProjectNamed: "중단 후"),
            "중단 후"
        )
        XCTAssertFalse(try rootItems(base).contains { $0.contains("transaction") })
    }

    func testCustomOrderAndLastProjectSurviveManagerRestart() async throws {
        let harness = try makeHarness()
        let first = try await harness.manager.createProject(named: "첫 작품")
        let second = try await harness.manager.createProject(named: "둘째 작품")
        _ = try await harness.manager.reorderProjects([second.id, first.id])
        try await harness.manager.selectProject(id: first.id)

        let restarted = makeManager(from: harness)
        let projects = try await restarted.projects()
        let restored = try await restarted.restoreLastProject()

        XCTAssertEqual(projects.map(\.id), [second.id, first.id])
        XCTAssertEqual(restored?.id, first.id)
    }

    func testDeletionRequiresConfirmationAndKeepsFolderForTrashStage() async throws {
        let harness = try makeHarness()
        let created = try await harness.manager.createProject(named: "삭제 확인")
        let folder = try harness.resolver.standardPaths(
            forProjectNamed: created.name
        ).projectContainerURL

        let confirmation = try await harness.manager.prepareDeletion(id: created.id)
        let beforeConfirmation = try await harness.manager.projects()
        XCTAssertFalse(beforeConfirmation[0].isDeletionRequested)

        try await harness.manager.confirmDeletion(confirmation)
        let pending = try await harness.manager.projects()[0]

        XCTAssertTrue(pending.isDeletionRequested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let restored = try await harness.manager.restoreLastProject()
        XCTAssertNil(restored)

        try await harness.manager.cancelDeletion(id: created.id)
        let afterCancellation = try await harness.manager.projects()
        XCTAssertFalse(afterCancellation[0].isDeletionRequested)
    }

    func testDeletedListPreservesProjectUntilPermanentDeletion() async throws {
        let harness = try makeHarness()
        let first = try await harness.manager.createProject(named: "삭제할 작품")
        let second = try await harness.manager.createProject(named: "남길 작품")
        try await harness.manager.selectProject(id: first.id)
        let firstFolder = try harness.resolver.standardPaths(
            forProjectNamed: first.name
        ).projectContainerURL

        do {
            _ = try await harness.manager.preparePermanentDeletion(id: first.id)
            XCTFail("삭제 목록으로 옮기기 전에는 영구 삭제 확인을 만들 수 없어야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .projectNotInDeletedList(first.id))
        }

        let pending = try await harness.manager.prepareDeletion(id: first.id)
        try await harness.manager.confirmDeletion(pending)
        let deletedListConfirmation = try await harness.manager.prepareMoveToDeletedList(
            id: first.id
        )
        let replacement = try await harness.manager.moveToDeletedList(
            deletedListConfirmation
        )
        let listed = try await harness.manager.projects().first { $0.id == first.id }
        let preservedMetadata = try await harness.repository.project(id: first.id)
        let replacementID = try await harness.manager.restoreLastProject()?.id

        XCTAssertEqual(replacement?.id, second.id)
        XCTAssertTrue(listed?.isInDeletedList == true)
        XCTAssertNotNil(preservedMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFolder.path))
        XCTAssertEqual(replacementID, second.id)

        let confirmation = try await harness.manager.preparePermanentDeletion(id: first.id)
        _ = try await harness.manager.permanentlyDelete(confirmation)
        let deletedMetadata = try await harness.repository.project(id: first.id)
        let remainingIDs = try await harness.manager.projects().map(\.id)
        let restoredID = try await harness.manager.restoreLastProject()?.id

        XCTAssertNil(deletedMetadata)
        XCTAssertEqual(remainingIDs, [second.id])
        XCTAssertEqual(restoredID, second.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFolder.path))
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-delete") || $0.contains("transaction")
            }
        )
    }

    func testRestartCompletesPermanentDeletionInterruptedAfterQuarantine() async throws {
        let harness = try makeHarness()
        let doomed = try await harness.manager.createProject(named: "중단 삭제")
        let survivor = try await harness.manager.createProject(named: "생존 작품")
        let pending = try await harness.manager.prepareDeletion(id: doomed.id)
        try await harness.manager.confirmDeletion(pending)
        let deletedListConfirmation = try await harness.manager.prepareMoveToDeletedList(
            id: doomed.id
        )
        _ = try await harness.manager.moveToDeletedList(deletedListConfirmation)
        let confirmation = try await harness.manager.preparePermanentDeletion(id: doomed.id)
        let interrupted = makeManager(
            from: harness,
            faultPlan: ProjectManagerFaultPlan(
                point: .afterProjectQuarantine,
                leavesTransactionForRecovery: true
            )
        )

        do {
            _ = try await interrupted.permanentlyDelete(confirmation)
            XCTFail("격리 직후 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recoveredIDs = try await restarted.projects().map(\.id)
        let restoredID = try await restarted.restoreLastProject()?.id
        let deletedMetadata = try await harness.repository.project(id: doomed.id)
        XCTAssertEqual(recoveredIDs, [survivor.id])
        XCTAssertEqual(restoredID, survivor.id)
        XCTAssertNil(deletedMetadata)
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-delete") || $0.contains("transaction")
            }
        )
    }

    func testRestartCompletesPermanentDeletionInterruptedAfterMetadataRemoval() async throws {
        let harness = try makeHarness()
        let doomed = try await harness.manager.createProject(named: "메타 제거 중단")
        let pending = try await harness.manager.prepareDeletion(id: doomed.id)
        try await harness.manager.confirmDeletion(pending)
        let deletedListConfirmation = try await harness.manager.prepareMoveToDeletedList(
            id: doomed.id
        )
        _ = try await harness.manager.moveToDeletedList(deletedListConfirmation)
        let confirmation = try await harness.manager.preparePermanentDeletion(id: doomed.id)
        let interrupted = makeManager(
            from: harness,
            faultPlan: ProjectManagerFaultPlan(
                point: .afterProjectMetadataRemoval,
                leavesTransactionForRecovery: true
            )
        )

        do {
            _ = try await interrupted.permanentlyDelete(confirmation)
            XCTFail("메타데이터 제거 직후 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recoveredProjects = try await restarted.projects()
        let restoredProject = try await restarted.restoreLastProject()
        XCTAssertTrue(recoveredProjects.isEmpty)
        XCTAssertNil(restoredProject)
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-delete") || $0.contains("transaction")
            }
        )
    }

    func testDeletedListProjectCanBeRestoredWithoutChangingFilesOrMetadata() async throws {
        let harness = try makeHarness()
        let created = try await harness.manager.createProject(named: "복원할 작품")
        let folder = try harness.resolver.standardPaths(
            forProjectNamed: created.name
        ).projectContainerURL
        let pending = try await harness.manager.prepareDeletion(id: created.id)
        try await harness.manager.confirmDeletion(pending)
        let deletedListConfirmation = try await harness.manager.prepareMoveToDeletedList(
            id: created.id
        )
        _ = try await harness.manager.moveToDeletedList(deletedListConfirmation)

        try await harness.manager.restoreFromDeletedList(id: created.id)
        let restored = try await harness.manager.projects().first { $0.id == created.id }
        let metadata = try await harness.repository.project(id: created.id)

        XCTAssertTrue(restored?.isActive == true)
        XCTAssertNotNil(metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        try await harness.manager.selectProject(id: created.id)
        let restoredLastID = try await harness.manager.restoreLastProject()?.id
        XCTAssertEqual(restoredLastID, created.id)
    }

    func testReorderIgnoresDeletedListAndRestoredProjectMovesToEnd() async throws {
        let harness = try makeHarness()
        let first = try await harness.manager.createProject(named: "첫 작품")
        let second = try await harness.manager.createProject(named: "둘째 작품")
        let third = try await harness.manager.createProject(named: "셋째 작품")
        let pending = try await harness.manager.prepareDeletion(id: second.id)
        try await harness.manager.confirmDeletion(pending)
        let deletedListConfirmation = try await harness.manager.prepareMoveToDeletedList(
            id: second.id
        )
        _ = try await harness.manager.moveToDeletedList(deletedListConfirmation)

        let reordered = try await harness.manager.reorderProjects([third.id, first.id])
        XCTAssertEqual(
            reordered.filter { !$0.isInDeletedList }.map(\.id),
            [third.id, first.id]
        )

        try await harness.manager.restoreFromDeletedList(id: second.id)
        let restoredOrder = try await harness.manager.projects()
            .filter { !$0.isInDeletedList }
            .map(\.id)
        XCTAssertEqual(restoredOrder, [third.id, first.id, second.id])
    }

    func testExportDescriptorPointsAtWholeProjectWithoutCreatingArchive() async throws {
        let harness = try makeHarness()
        let created = try await harness.manager.createProject(named: "내보낼 작품")

        let descriptor = try await harness.manager.exportDescriptor(id: created.id)

        XCTAssertEqual(descriptor.projectID, created.id)
        XCTAssertEqual(descriptor.suggestedArchiveName, "내보낼 작품.zip")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: descriptor.projectContainerURL.path)
        )
    }

    private struct Harness {
        let root: URL
        let container: ModelContainer
        let repository: SwiftDataMetadataRepository
        let resolver: ProjectPathResolver
        let clock: FixedClock
        let manager: LocalProjectManager
    }

    private struct FixedClock: AppClock {
        let date: Date
        func now() -> Date { date }
    }

    private func makeHarness(
        faultPlan: ProjectManagerFaultPlan? = nil
    ) throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-ProjectManagerTests-\(UUID().uuidString)")
        roots.append(root)
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("Projects")
        )
        let clock = FixedClock(date: Date(timeIntervalSince1970: 1_234_567))
        let manager = LocalProjectManager(
            projectRepository: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: clock,
            faultPlan: faultPlan
        )
        return Harness(
            root: root,
            container: container,
            repository: repository,
            resolver: resolver,
            clock: clock,
            manager: manager
        )
    }

    private func makeManager(
        from harness: Harness,
        faultPlan: ProjectManagerFaultPlan? = nil
    ) -> LocalProjectManager {
        LocalProjectManager(
            projectRepository: harness.repository,
            workspaceStateRepository: harness.repository,
            pathResolver: harness.resolver,
            clock: harness.clock,
            faultPlan: faultPlan
        )
    }

    private func rootItems(_ harness: Harness) throws -> [String] {
        guard FileManager.default.fileExists(
            atPath: harness.resolver.projectsRootURL.path
        ) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            atPath: harness.resolver.projectsRootURL.path
        )
    }
}
