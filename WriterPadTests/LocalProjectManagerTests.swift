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
        let firstNodes = try await harness.repository.documents(in: first.id)
        let second = try await harness.manager.createProject(named: "나의 작품")
        let secondNodes = try await harness.repository.documents(in: second.id)
        let paths = try harness.resolver.standardPaths(forProjectNamed: "나의 작품")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(firstNodes, secondNodes)
        XCTAssertEqual(firstNodes.count, 10)
        XCTAssertEqual(Set(firstNodes.map(\.id)).count, 10)
        let main = try XCTUnwrap(firstNodes.first {
            $0.relativePath == BinderHierarchyPolicy.topLevelPath
        })
        XCTAssertNil(main.parentID)
        XCTAssertEqual(main.userOrder, 0)
        for category in BinderFixedCategory.allCases {
            let node = try XCTUnwrap(firstNodes.first {
                $0.relativePath == category.relativePath
            })
            XCTAssertEqual(node.parentID, main.id)
            XCTAssertEqual(node.userOrder, category.fixedOrder)
        }
        XCTAssertEqual(
            firstNodes.filter { $0.parentID == main.id }.map(\.userOrder).sorted(),
            BinderFixedCategory.allCases.map(\.fixedOrder).sorted()
        )
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

    func testCreationJournalPreallocatesStandardUUIDsAndRecoveryReusesThem() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterStaging,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await harness.manager.createProject(named: "UUID 선기록")
            XCTFail("staging 직후 테스트 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let projectsBeforeRecovery = try await harness.repository.projects()
        XCTAssertTrue(projectsBeforeRecovery.isEmpty)
        let journalName = try XCTUnwrap(
            rootItems(harness).first { $0.contains("project-transaction") }
        )
        let journalURL = harness.resolver.projectsRootURL.appendingPathComponent(journalName)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        let projectObject = try XCTUnwrap(object["new_project"] as? [String: Any])
        let journalProjectID = try XCTUnwrap(projectObject["project_id"] as? String)
        let nodeObjects = try XCTUnwrap(object["standard_nodes"] as? [[String: Any]])
        let journalNodeIDs = Set(try nodeObjects.map {
            try XCTUnwrap($0["document_id"] as? String)
        })
        XCTAssertEqual(journalNodeIDs.count, 10)

        let restarted = makeManager(from: harness)
        let recoveredProjects = try await restarted.projects()
        let recovered = try XCTUnwrap(recoveredProjects.first)
        let recoveredNodes = try await harness.repository.documents(in: recovered.id)

        XCTAssertEqual(recovered.id.rawValue.uuidString, journalProjectID)
        XCTAssertEqual(
            Set(recoveredNodes.map { $0.id.rawValue.uuidString }),
            journalNodeIDs
        )
        XCTAssertFalse(try rootItems(harness).contains { $0.contains("transaction") })
    }

    func testRecoveryCreatesStagingWithJournalUUIDsWhenInterruptedBeforeDiskCreation() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterCreationJournalWrite,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await harness.manager.createProject(named: "파일 전 중단")
            XCTFail("journal 기록 직후 테스트 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let rootNames = try rootItems(harness)
        XCTAssertFalse(rootNames.contains { $0.hasSuffix(".tmp") })
        let journalName = try XCTUnwrap(
            rootNames.first { $0.contains("project-transaction") }
        )
        let journalURL = harness.resolver.projectsRootURL.appendingPathComponent(journalName)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        let nodeObjects = try XCTUnwrap(object["standard_nodes"] as? [[String: Any]])
        let journalNodeIDs = Set(try nodeObjects.map {
            try XCTUnwrap($0["document_id"] as? String)
        })

        let restarted = makeManager(from: harness)
        let projects = try await restarted.projects()
        let project = try XCTUnwrap(projects.first)
        let recoveredNodes = try await harness.repository.documents(in: project.id)

        XCTAssertEqual(
            Set(recoveredNodes.map { $0.id.rawValue.uuidString }),
            journalNodeIDs
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: try harness.resolver.standardPaths(
                    forProjectNamed: project.name
                ).projectContainerURL.path
            )
        )
        XCTAssertFalse(try rootItems(harness).contains { $0.contains("transaction") })
    }

    func testCreationJournalWithoutStandardUUIDsRequiresManualRecovery() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterStaging,
                leavesTransactionForRecovery: true
            )
        )
        do {
            _ = try await harness.manager.createProject(named: "구형 journal")
            XCTFail("staging 직후 테스트 중단이 발생해야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let journalName = try XCTUnwrap(
            rootItems(harness).first { $0.contains("project-transaction") }
        )
        let journalURL = harness.resolver.projectsRootURL.appendingPathComponent(journalName)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        object.removeValue(forKey: "standard_nodes")
        try JSONSerialization.data(withJSONObject: object).write(
            to: journalURL,
            options: .atomic
        )

        let restarted = makeManager(from: harness)
        do {
            _ = try await restarted.projects()
            XCTFail("UUID가 없는 생성 journal은 자동 완료하면 안 됩니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .recoveryRequired(journalURL.path))
        }
        let storedProjects = try await harness.repository.projects()
        XCTAssertTrue(storedProjects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
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

    func testRestoreProjectBackupRegistersExactIdentityTreeAndRawBytes() async throws {
        let harness = try makeHarness()
        let fixture = try await makeBackupFixture(in: harness)
        let packageBefore = try directoryFingerprint(fixture.packageURL)

        let restored = try await harness.manager.restoreProjectBackup(
            at: fixture.packageURL
        )

        XCTAssertEqual(restored.id, fixture.project.id)
        XCTAssertEqual(restored.name, fixture.project.name)
        let storedNodes = try await harness.repository.documents(in: restored.id)
        XCTAssertEqual(Set(storedNodes.map(\.id)), Set(fixture.nodes.map(\.id)))
        for expected in fixture.nodes {
            let actual = try XCTUnwrap(storedNodes.first { $0.id == expected.id })
            XCTAssertEqual(actual.parentID, expected.parentID)
            XCTAssertEqual(actual.relativePath, expected.relativePath)
            XCTAssertEqual(actual.userOrder, expected.userOrder)
            XCTAssertEqual(actual.kind, expected.kind)
        }
        let restoredTrash = try XCTUnwrap(storedNodes.first {
            $0.relativePath.rawValue == "메인/휴지통/삭제 초안.txt"
        })
        guard case let .trashed(fallbackPath, _) = restoredTrash.deletionStatus else {
            return XCTFail("휴지통 항목은 복원 후에도 휴지통 상태여야 합니다.")
        }
        XCTAssertEqual(fallbackPath, restoredTrash.relativePath)

        let workspace = try harness.resolver.standardPaths(
            forProjectNamed: fixture.project.name
        ).workspaceRootURL
        for (path, expectedBytes) in fixture.documentBytes {
            XCTAssertEqual(
                try Data(contentsOf: workspace.appendingPathComponent(path)),
                expectedBytes
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: workspace.appendingPathComponent("메인/원고/2권").path
            )
        )
        let trashRecordURL = workspace.appendingPathComponent(
            ".writerpad-trash-"
                + restoredTrash.id.rawValue.uuidString.lowercased()
                + ".json"
        )
        let trashDecoder = JSONDecoder()
        trashDecoder.dateDecodingStrategy = .iso8601
        let trashRecord = try trashDecoder.decode(
            TrashRecord.self,
            from: Data(contentsOf: trashRecordURL)
        )
        XCTAssertEqual(trashRecord.documentID, restoredTrash.id)
        XCTAssertEqual(trashRecord.originalPath, restoredTrash.relativePath)
        XCTAssertEqual(try directoryFingerprint(fixture.packageURL), packageBefore)
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-restore") || $0.contains("transaction")
            }
        )
    }

    func testRestoreProjectBackupRejectsDuplicateProjectUUIDWithoutMutation() async throws {
        let harness = try makeHarness()
        let fixture = try await makeBackupFixture(in: harness)
        _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
        let workspace = try harness.resolver.standardPaths(
            forProjectNamed: fixture.project.name
        ).workspaceRootURL
        let before = try directoryFingerprint(workspace)

        do {
            _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
            XCTFail("같은 project UUID를 다시 복원하면 안 됩니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .projectAlreadyExists(fixture.project.id))
        }

        XCTAssertEqual(try directoryFingerprint(workspace), before)
        let storedProjects = try await harness.repository.projects()
        XCTAssertEqual(storedProjects.count, 1)
    }

    func testRestoreProjectBackupRejectsExistingDestinationEvenWhenEmpty() async throws {
        let harness = try makeHarness()
        let fixture = try await makeBackupFixture(in: harness)
        let destination = try harness.resolver.standardPaths(
            forProjectNamed: fixture.project.name
        ).projectContainerURL
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        do {
            _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
            XCTFail("빈 목적지도 덮어쓰면 안 됩니다.")
        } catch let error as PathPolicyError {
            guard case .nameCollision = error else {
                return XCTFail("예상하지 못한 오류: \(error)")
            }
        }

        let storedProjects = try await harness.repository.projects()
        XCTAssertTrue(storedProjects.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testRestoreProjectBackupUsesUUIDParentTreeNotReferencePath() async throws {
        let harness = try makeHarness()
        let fixture = try await makeBackupFixture(in: harness)
        let manifestURL = fixture.packageURL.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        )
        var nodes = try XCTUnwrap(object["nodes"] as? [[String: Any]])
        let index = try XCTUnwrap(nodes.firstIndex {
            $0["path"] as? String == "메인/원고/1권/001화.txt"
        })
        nodes[index]["path"] = "참고용/실제 복원에 쓰지 않는 경로.txt"
        object["nodes"] = nodes
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: manifestURL, options: [.atomic])

        let restored = try await harness.manager.restoreProjectBackup(
            at: fixture.packageURL
        )
        let storedNodes = try await harness.repository.documents(in: restored.id)

        XCTAssertNotNil(storedNodes.first {
            $0.relativePath.rawValue == "메인/원고/1권/001화.txt"
        })
        XCTAssertNil(storedNodes.first {
            $0.relativePath.rawValue == "참고용/실제 복원에 쓰지 않는 경로.txt"
        })
    }

    func testRestartCompletesInterruptedBackupRestoreWithManifestUUIDs() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterRestoreMetadataSave,
                leavesTransactionForRecovery: true
            )
        )
        let fixture = try await makeBackupFixture(in: harness)
        do {
            _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
            XCTFail("복원 메타데이터 저장 뒤 중단돼야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recovered = try await restarted.projects()
        let project = try XCTUnwrap(recovered.first)
        let nodes = try await harness.repository.documents(in: project.id)

        XCTAssertEqual(project.id, fixture.project.id)
        XCTAssertEqual(Set(nodes.map(\.id)), Set(fixture.nodes.map(\.id)))
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-restore") || $0.contains("transaction")
            }
        )
    }

    func testRestartRollsBackRestoreInterruptedBeforePackageCopy() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterRestoreJournalWrite,
                leavesTransactionForRecovery: true
            )
        )
        let fixture = try await makeBackupFixture(in: harness)
        do {
            _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
            XCTFail("복원 journal 기록 뒤 중단돼야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recovered = try await restarted.projects()
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-restore") || $0.contains("transaction")
            }
        )
    }

    func testRestartBuildsRestoreFromStagedPackageWithSameUUIDs() async throws {
        let harness = try makeHarness(
            faultPlan: ProjectManagerFaultPlan(
                point: .afterRestorePackageCopy,
                leavesTransactionForRecovery: true
            )
        )
        let fixture = try await makeBackupFixture(in: harness)
        do {
            _ = try await harness.manager.restoreProjectBackup(at: fixture.packageURL)
            XCTFail("패키지 내부 복사 뒤 중단돼야 합니다.")
        } catch let error as ProjectManagerError {
            XCTAssertEqual(error, .injectedFailure(recoveryPending: true))
        }

        let restarted = makeManager(from: harness)
        let recovered = try await restarted.projects()
        let project = try XCTUnwrap(recovered.first)
        let nodes = try await harness.repository.documents(in: project.id)

        XCTAssertEqual(project.id, fixture.project.id)
        XCTAssertEqual(Set(nodes.map(\.id)), Set(fixture.nodes.map(\.id)))
        XCTAssertFalse(
            try rootItems(harness).contains {
                $0.contains("writerpad-restore") || $0.contains("transaction")
            }
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

    private struct BackupFixture {
        let packageURL: URL
        let project: Project
        let nodes: [DocumentNode]
        let documentBytes: [String: Data]
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
            creationMetadataStore: repository,
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
            creationMetadataStore: harness.repository,
            workspaceStateRepository: harness.repository,
            pathResolver: harness.resolver,
            clock: harness.clock,
            faultPlan: faultPlan
        )
    }

    private func makeBackupFixture(in harness: Harness) async throws -> BackupFixture {
        let fileManager = FileManager.default
        let source = harness.root.appendingPathComponent("BackupSource", isDirectory: true)
        let workspace = source.appendingPathComponent("집필모드", isDirectory: true)
        let mainID = DocumentID(rawValue: UUID())
        let project = Project(
            id: ProjectID(rawValue: UUID()),
            name: "교차 복원 합성 작품",
            createdAt: harness.clock.date,
            modifiedAt: harness.clock.date
        )
        var nodes: [DocumentNode] = [
            DocumentNode(
                id: mainID,
                projectID: project.id,
                kind: .folder,
                parentID: nil,
                relativePath: RelativeDocumentPath(rawValue: "메인"),
                userOrder: 0,
                modifiedAt: harness.clock.date,
                contentHash: nil
            )
        ]
        var categoryIDs: [BinderFixedCategory: DocumentID] = [:]
        for category in BinderFixedCategory.allCases {
            let id = DocumentID(rawValue: UUID())
            categoryIDs[category] = id
            nodes.append(
                DocumentNode(
                    id: id,
                    projectID: project.id,
                    kind: .folder,
                    parentID: mainID,
                    relativePath: category.relativePath,
                    userOrder: category.fixedOrder,
                    modifiedAt: harness.clock.date,
                    contentHash: nil
                )
            )
        }
        let manuscriptID = try XCTUnwrap(categoryIDs[.manuscript])
        let settingsID = try XCTUnwrap(categoryIDs[.settings])
        let volume1ID = DocumentID(rawValue: UUID())
        let volume2ID = DocumentID(rawValue: UUID())
        let chapter1ID = DocumentID(rawValue: UUID())
        let chapter2ID = DocumentID(rawValue: UUID())
        let personID = DocumentID(rawValue: UUID())
        let trashID = try XCTUnwrap(categoryIDs[.trash])
        let trashedDraftID = DocumentID(rawValue: UUID())
        nodes += [
            DocumentNode(
                id: volume1ID, projectID: project.id, kind: .folder,
                parentID: manuscriptID,
                relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권"),
                userOrder: 0, modifiedAt: harness.clock.date, contentHash: nil
            ),
            DocumentNode(
                id: volume2ID, projectID: project.id, kind: .folder,
                parentID: manuscriptID,
                relativePath: RelativeDocumentPath(rawValue: "메인/원고/2권"),
                userOrder: 1, modifiedAt: harness.clock.date, contentHash: nil
            ),
            DocumentNode(
                id: chapter1ID, projectID: project.id, kind: .text,
                parentID: volume1ID,
                relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권/001화.txt"),
                userOrder: 0, modifiedAt: harness.clock.date, contentHash: nil
            ),
            DocumentNode(
                id: chapter2ID, projectID: project.id, kind: .text,
                parentID: volume1ID,
                relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권/002화.txt"),
                userOrder: 1, modifiedAt: harness.clock.date, contentHash: nil
            ),
            DocumentNode(
                id: personID, projectID: project.id, kind: .text,
                parentID: settingsID,
                relativePath: RelativeDocumentPath(rawValue: "메인/설정집/인물.txt"),
                userOrder: 0, modifiedAt: harness.clock.date, contentHash: nil
            ),
            DocumentNode(
                id: trashedDraftID, projectID: project.id, kind: .text,
                parentID: trashID,
                relativePath: RelativeDocumentPath(rawValue: "메인/휴지통/삭제 초안.txt"),
                userOrder: 0, modifiedAt: harness.clock.date, contentHash: nil,
                deletionStatus: .trashed(
                    originalPath: RelativeDocumentPath(rawValue: "메인/메모장/삭제 초안.txt"),
                    deletedAt: harness.clock.date
                )
            ),
        ]
        for node in nodes where node.kind == .folder {
            try fileManager.createDirectory(
                at: workspace.appendingPathComponent(node.relativePath.rawValue),
                withIntermediateDirectories: true
            )
        }
        let chapterBytes = Data([0xEF, 0xBB, 0xBF])
            + Data("합성 첫 문장\r\n합성 둘째 문장\n".utf8)
        let documentBytes = [
            "메인/원고/1권/001화.txt": chapterBytes,
            "메인/원고/1권/002화.txt": Data(),
            "메인/설정집/인물.txt": Data("합성 인물\n".utf8),
            "메인/휴지통/삭제 초안.txt": Data("삭제 전 합성 원고\n".utf8),
        ]
        for (path, data) in documentBytes {
            try data.write(to: workspace.appendingPathComponent(path), options: [.atomic])
        }
        let package = harness.root.appendingPathComponent("InputBackup", isDirectory: true)
        _ = try await ProjectBackupStore().createBackup(
            project: project,
            documents: nodes,
            workspaceURL: workspace,
            packageURL: package
        )
        return BackupFixture(
            packageURL: package,
            project: project,
            nodes: nodes,
            documentBytes: documentBytes
        )
    }

    private func directoryFingerprint(_ root: URL) throws -> [String: Data?] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var result: [String: Data?] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = values.isDirectory == true ? nil : try Data(contentsOf: url)
        }
        return result
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
