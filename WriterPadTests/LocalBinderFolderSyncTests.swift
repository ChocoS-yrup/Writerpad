import Foundation
import XCTest
@testable import WriterPad

/// 실제 바인더 명령을 실행했을 때 폴더 작업이 대기열에 들어가는지 본다.
///
/// 대기열에 직접 넣는 테스트만으로는 부족하다. 이 연결이 빠져 있으면 사용자가
/// 폴더 이름을 바꿔도 tree_order만 나가고 서버 폴더 행은 옛 이름으로 남아,
/// 다음 pull에서 방금 바꾼 이름이 되돌려진다.
final class LocalBinderFolderSyncTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }

    func testCreatingAFolderQueuesItWithANewIdentifier() async throws {
        let harness = try await makeHarness()
        let parent = try await fixedRoot(.notes, harness: harness)

        let result = try await harness.commands.create(
            kind: .folder,
            named: "가 나 다",
            in: parent.id,
            projectID: harness.project.id
        )

        let created = result.affectedDocumentID
        let folders = await harness.recorder.folderMutations()
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.folderID, created)
        XCTAssertEqual(folders.first?.parentFolderID, parent.id)
        XCTAssertEqual(folders.first?.name, "가 나 다")
        XCTAssertEqual(folders.first?.isDeleted, false)
    }

    func testRenamingAFolderKeepsItsIdentifier() async throws {
        let harness = try await makeHarness()
        let parent = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .folder,
            named: "가 나 다",
            in: parent.id,
            projectID: harness.project.id
        ).affectedDocumentID
        await harness.recorder.reset()

        _ = try await harness.commands.rename(
            documentID: created,
            to: "가 나 다 바",
            projectID: harness.project.id
        )

        let folders = await harness.recorder.folderMutations()
        XCTAssertEqual(folders.count, 1)
        // 새 UUID를 만들면 받는 기기에 폴더가 둘 남는다.
        XCTAssertEqual(folders.first?.folderID, created)
        XCTAssertEqual(folders.first?.name, "가 나 다 바")
        XCTAssertEqual(folders.first?.parentFolderID, parent.id)
        XCTAssertEqual(folders.first?.isDeleted, false)
    }

    func testMovingAFolderKeepsItsIdentifierAndChangesTheParent()
        async throws {
        let harness = try await makeHarness()
        let notes = try await fixedRoot(.notes, harness: harness)
        let destination = try await harness.commands.create(
            kind: .folder,
            named: "받는 폴더",
            in: notes.id,
            projectID: harness.project.id
        ).affectedDocumentID
        let moving = try await harness.commands.create(
            kind: .folder,
            named: "옮길 폴더",
            in: notes.id,
            projectID: harness.project.id
        ).affectedDocumentID
        await harness.recorder.reset()

        _ = try await harness.commands.move(
            documentID: moving,
            to: .folder(destination),
            projectID: harness.project.id
        )

        let folders = await harness.recorder.folderMutations()
        let moved = try XCTUnwrap(
            folders.first { $0.folderID == moving }
        )
        XCTAssertEqual(moved.parentFolderID, destination)
        XCTAssertEqual(moved.name, "옮길 폴더")
        XCTAssertEqual(moved.isDeleted, false)
    }

    func testTrashingAFolderQueuesATombstoneForTheSameIdentifier()
        async throws {
        let harness = try await makeHarness()
        let parent = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .folder,
            named: "지울 폴더",
            in: parent.id,
            projectID: harness.project.id
        ).affectedDocumentID
        await harness.recorder.reset()

        _ = try await harness.commands.moveToTrash(
            documentID: created,
            projectID: harness.project.id
        )

        let folders = await harness.recorder.folderMutations()
        let tombstone = try XCTUnwrap(
            folders.first { $0.folderID == created }
        )
        XCTAssertTrue(tombstone.isDeleted)
    }

    func testRestoringAFolderQueuesItAliveAgainWithTheSameIdentifier()
        async throws {
        let harness = try await makeHarness()
        let parent = try await fixedRoot(.notes, harness: harness)
        let created = try await harness.commands.create(
            kind: .folder,
            named: "되살릴 폴더",
            in: parent.id,
            projectID: harness.project.id
        ).affectedDocumentID
        _ = try await harness.commands.moveToTrash(
            documentID: created,
            projectID: harness.project.id
        )
        await harness.recorder.reset()

        _ = try await harness.commands.restoreFromTrash(
            documentID: created,
            toFolderID: parent.id,
            projectID: harness.project.id
        )

        let folders = await harness.recorder.folderMutations()
        let restored = try XCTUnwrap(
            folders.first { $0.folderID == created }
        )
        // 복원은 지우고 새로 만드는 것이 아니라 같은 폴더를 되살리는 것이다.
        XCTAssertFalse(restored.isDeleted)
        XCTAssertEqual(restored.parentFolderID, parent.id)
    }

    /// 같은 batch가 저널에 적혀 재시도에 그대로 다시 쓰이므로 operation_id가
    /// 유지된다. 새로 만들면 서버가 다른 작업으로 보고 폴더를 한 번 더 만든다.
    func testRetriedHandoffKeepsTheSameFolderOperationID() async throws {
        let harness = try await makeHarness(firstRecordFails: true)
        let parent = try await fixedRoot(.notes, harness: harness)

        _ = try await harness.commands.create(
            kind: .folder,
            named: "가 나 다",
            in: parent.id,
            projectID: harness.project.id
        )
        // 첫 전달이 실패했으므로 다음 명령이 저널을 복구하며 다시 보낸다.
        _ = try await harness.commands.create(
            kind: .folder,
            named: "다른 폴더",
            in: parent.id,
            projectID: harness.project.id
        )

        let folders = await harness.recorder.folderMutations()
        let firstFolder = folders.filter { $0.name == "가 나 다" }
        XCTAssertEqual(firstFolder.count, 2)
        XCTAssertEqual(
            firstFolder.first?.operationID,
            firstFolder.last?.operationID
        )
    }

    private struct Harness {
        let root: URL
        let repository: SwiftDataMetadataRepository
        let resolver: ProjectPathResolver
        let binder: LocalBinderRepository
        let commands: LocalBinderCommandService
        let project: ManagedProject
        let recorder: FolderMutationRecorder
    }

    private struct FixedClock: AppClock {
        let date = Date(timeIntervalSince1970: 8_000)
        func now() -> Date { date }
    }

    private func makeHarness(
        firstRecordFails: Bool = false
    ) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-FolderSync-\(UUID().uuidString)"
            )
        roots.append(root)
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: true
        )
        let repository = SwiftDataMetadataRepository(
            modelContainer: container
        )
        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("Projects")
        )
        let clock = FixedClock()
        let manager = LocalProjectManager(
            projectRepository: repository,
            creationMetadataStore: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: clock
        )
        let project = try await manager.createProject(named: "폴더 동기화 테스트")
        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: resolver
        )
        let binder = LocalBinderRepository(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            scanner: LocalBinderDirectoryScanner(pathResolver: resolver),
            pathPolicy: resolver.policy,
            clock: clock
        )
        let recorder = FolderMutationRecorder(
            firstRecordFails: firstRecordFails
        )
        let commands = LocalBinderCommandService(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            pathPolicy: resolver.policy,
            clock: clock,
            durableChangeRecorder: recorder
        )
        _ = try await binder.rootNodes(in: project.id)
        return Harness(
            root: root,
            repository: repository,
            resolver: resolver,
            binder: binder,
            commands: commands,
            project: project,
            recorder: recorder
        )
    }

    private func fixedRoot(
        _ category: BinderFixedCategory,
        harness: Harness
    ) async throws -> BinderNode {
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        return try XCTUnwrap(roots.first { $0.fixedCategory == category })
    }
}

private struct RecordedFolderMutation: Equatable {
    let operationID: UUID
    let folderID: DocumentID
    let parentFolderID: DocumentID?
    let name: String
    let isDeleted: Bool
}

private actor FolderMutationRecorder: DurableLocalChangeRecording {
    private let firstRecordFails: Bool
    private var recordCount = 0
    private var recorded: [RecordedFolderMutation] = []
    private var treeOrders = 0

    init(firstRecordFails: Bool = false) {
        self.firstRecordFails = firstRecordFails
    }

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        _ = projectID
        return .durableQueue
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        recordCount += 1
        for mutation in batch.mutations {
            switch mutation {
            case let .folderSnapshot(
                operationID,
                folderID,
                parentFolderID,
                name,
                isDeleted
            ):
                recorded.append(
                    RecordedFolderMutation(
                        operationID: operationID,
                        folderID: folderID,
                        parentFolderID: parentFolderID,
                        name: name,
                        isDeleted: isDeleted
                    )
                )
            case .treeOrder:
                treeOrders += 1
            default:
                break
            }
        }
        if firstRecordFails, recordCount == 1 {
            return .localSavedButNotQueued(reason: "fixture")
        }
        return .queued(operationIDs: [])
    }

    func folderMutations() -> [RecordedFolderMutation] { recorded }
    func treeOrderCount() -> Int { treeOrders }

    func reset() {
        recorded = []
        treeOrders = 0
    }
}
