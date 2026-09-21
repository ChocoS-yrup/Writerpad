import Foundation
import XCTest
@testable import WriterPad

final class SyncV2FolderMigrationTests: XCTestCase {
    private let serverProjectID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000f0"
    )!

    func testMigrationReplacesFolderIdentifiersAndQueuesThem() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let repository = DocumentRepositoryStub(
            documents: [
                folder(projectID: projectID, path: "메인/메모장", parent: nil),
            ]
        )
        let marker = FolderMigrationMarkerStub()
        let recorder = ChangeRecorderStub()
        let migration = SyncV2FolderMigration(
            documentRepository: repository,
            marker: marker,
            changeRecorder: recorder,
            uuidGenerator: SequentialUUIDGenerator()
        )

        let result = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        guard case .migrated(let folderCount, _) = result else {
            return XCTFail("Expected a migration, got \(result).")
        }
        XCTAssertEqual(folderCount, 1)
        let stored = try await repository.documents(in: projectID)
        XCTAssertEqual(
            stored.map(\.id),
            [
                SyncV2FolderIdentity.derived(
                    serverProjectID: serverProjectID,
                    relativePath: "메인/메모장"
                )
            ]
        )
        let queued = await recorder.batches()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.kind, .structureChange)
        guard case let .folderSnapshot(_, folderID, parentFolderID, name, isDeleted) =
                try XCTUnwrap(queued.first?.mutations.first) else {
            return XCTFail("Expected a folder snapshot mutation.")
        }
        XCTAssertEqual(folderID, stored.first?.id)
        XCTAssertNil(parentFolderID)
        XCTAssertEqual(name, "메모장")
        XCTAssertFalse(isDeleted)
        let completed = try await marker.isFolderMigrationCompleted(
            localProjectID: projectID
        )
        XCTAssertTrue(completed)
    }

    func testSecondRunDoesNothingEvenAfterFoldersAreRenamed() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let repository = DocumentRepositoryStub(
            documents: [
                folder(projectID: projectID, path: "메인/메모장", parent: nil),
            ]
        )
        let marker = FolderMigrationMarkerStub()
        let recorder = ChangeRecorderStub()
        let migration = SyncV2FolderMigration(
            documentRepository: repository,
            marker: marker,
            changeRecorder: recorder,
            uuidGenerator: SequentialUUIDGenerator()
        )
        _ = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        // 이관된 폴더의 이름이 바뀌면 경로와 UUID가 어긋난다. 경로로 다시
        // 계산하면 같은 폴더를 또 이관하게 되므로 표식만 보고 멈춰야 한다.
        let migrated = try await repository.documents(in: projectID)
        await repository.replace(
            migrated.map {
                DocumentNode(
                    id: $0.id,
                    projectID: $0.projectID,
                    kind: $0.kind,
                    parentID: $0.parentID,
                    relativePath: RelativeDocumentPath(
                        rawValue: "메인/새 이름"
                    ),
                    userOrder: $0.userOrder,
                    modifiedAt: $0.modifiedAt,
                    contentHash: $0.contentHash
                )
            }
        )

        let second = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        XCTAssertEqual(second, .alreadyCompleted)
        let stored = try await repository.documents(in: projectID)
        XCTAssertEqual(stored.map(\.id), migrated.map(\.id))
        let queued = await recorder.batches()
        XCTAssertEqual(queued.count, 1)
    }

    func testServerIdentifierWinsOverTheCalculatedOne() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let repository = DocumentRepositoryStub(
            documents: [
                folder(projectID: projectID, path: "메인/메모장", parent: nil),
            ]
        )
        let recorder = ChangeRecorderStub()
        let migration = SyncV2FolderMigration(
            documentRepository: repository,
            marker: FolderMigrationMarkerStub(),
            changeRecorder: recorder,
            uuidGenerator: SequentialUUIDGenerator()
        )
        let serverFolderID = DocumentID(rawValue: UUID())

        _ = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID,
            serverFolderIDsByPath: ["메인/메모장": serverFolderID]
        )

        // 먼저 이관한 기기가 정한 값이 있는데 각자 계산한 값을 고집하면 같은
        // 폴더가 기기마다 다른 식별자를 갖는다.
        let stored = try await repository.documents(in: projectID)
        XCTAssertEqual(stored.map(\.id), [serverFolderID])
        // 서버가 이미 아는 폴더를 다시 만들면 안 된다.
        let queued = await recorder.batches()
        XCTAssertTrue(queued.isEmpty)
    }

    func testChildrenFollowTheNewParentIdentifier() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let parentID = DocumentID(rawValue: UUID())
        let repository = DocumentRepositoryStub(
            documents: [
                folder(
                    projectID: projectID,
                    path: "메인/메모장",
                    parent: nil,
                    id: parentID
                ),
                text(
                    projectID: projectID,
                    path: "메인/메모장/001화.txt",
                    parent: parentID
                ),
            ]
        )
        let migration = SyncV2FolderMigration(
            documentRepository: repository,
            marker: FolderMigrationMarkerStub(),
            changeRecorder: ChangeRecorderStub(),
            uuidGenerator: SequentialUUIDGenerator()
        )

        _ = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        let stored = try await repository.documents(in: projectID)
        let newParent = try XCTUnwrap(stored.first { $0.kind == .folder })
        let child = try XCTUnwrap(stored.first { $0.kind == .text })
        // 문서 식별자는 그대로 두고 부모 연결만 새 값으로 다시 잇는다.
        XCTAssertEqual(child.parentID, newParent.id)
        XCTAssertNotEqual(newParent.id, parentID)
    }

    func testColliderIdentifiersLeaveTheProjectUnmarked() async throws {
        let projectID = ProjectID(rawValue: UUID())
        // 대소문자나 정규화만 다른 두 폴더는 같은 값으로 계산된다. 그대로
        // 이관하면 한쪽이 사라지므로 접고, 표식도 남기지 않아야 한다.
        let repository = DocumentRepositoryStub(
            documents: [
                folder(projectID: projectID, path: "메인/메모장", parent: nil),
                folder(
                    projectID: projectID,
                    path: "메인/메모장".decomposedStringWithCanonicalMapping,
                    parent: nil
                ),
            ]
        )
        let marker = FolderMigrationMarkerStub()
        let migration = SyncV2FolderMigration(
            documentRepository: repository,
            marker: marker,
            changeRecorder: ChangeRecorderStub(),
            uuidGenerator: SequentialUUIDGenerator()
        )

        let result = await migration.migrateIfNeeded(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        guard case .postponed = result else {
            return XCTFail("Expected the migration to be postponed.")
        }
        let completed = try await marker.isFolderMigrationCompleted(
            localProjectID: projectID
        )
        XCTAssertFalse(completed)
    }

    private func folder(
        projectID: ProjectID,
        path: String,
        parent: DocumentID?,
        id: DocumentID = DocumentID(rawValue: UUID())
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: .folder,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }

    private func text(
        projectID: ProjectID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }
}

private actor DocumentRepositoryStub: DocumentRepository {
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

    func replace(_ documents: [DocumentNode]) {
        storage = documents
    }
}

private actor FolderMigrationMarkerStub: SyncV2FolderMigrationMarking {
    private var completed: Set<ProjectID> = []

    func isFolderMigrationCompleted(localProjectID: ProjectID) -> Bool {
        completed.contains(localProjectID)
    }

    func markFolderMigrationCompleted(localProjectID: ProjectID) {
        completed.insert(localProjectID)
    }

    func foldersWithPendingOperations(
        localProjectID: ProjectID
    ) -> Set<UUID> {
        _ = localProjectID
        return []
    }
}

private actor ChangeRecorderStub: DurableLocalChangeRecording {
    private var recorded: [LocalMutationBatch] = []

    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        _ = projectID
        return .durableQueue
    }

    func hasRecordedInitialSnapshot(
        for projectID: ProjectID,
        kind: DurableLocalBatchKind
    ) async throws -> Bool {
        _ = projectID
        _ = kind
        return false
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        recorded.append(batch)
        return .queued(
            operationIDs: batch.mutations.map(\.operationIDForTest)
        )
    }

    func batches() -> [LocalMutationBatch] {
        recorded
    }
}

private struct SequentialUUIDGenerator: UUIDGenerating {
    func makeUUID() -> UUID { UUID() }
}

private extension DurableLocalMutation {
    var operationIDForTest: UUID {
        switch self {
        case let .ensureProject(operationID, _):
            operationID
        case let .documentSnapshot(operationID, _, _, _, _, _, _):
            operationID
        case let .treeOrder(operationID, _, _):
            operationID
        case let .trashPurge(operationID, _, _):
            operationID
        case let .folderSnapshot(operationID, _, _, _, _):
            operationID
        }
    }
}
