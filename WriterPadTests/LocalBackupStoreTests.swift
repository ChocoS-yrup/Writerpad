import Foundation
import XCTest
@testable import WriterPad

final class LocalBackupStoreTests: XCTestCase {
    private var workspaces: [LocalDocumentTestWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces = []
    }

    func testAutomaticSnapshotCoalescesConsecutiveDuplicate() async throws {
        let workspace = try makeWorkspace(text: "한글 원고")
        let store = LocalBackupStore(workspaceLocator: FixedWorkspaceLocator(root: workspace.root))
        let first = try await store.createSnapshot(for: workspace.document(), reason: .automaticSave)
        let second = try await store.createSnapshot(for: workspace.document(), reason: .automaticSave)
        XCTAssertEqual(first.id, second.id)
        let snapshots = try await store.snapshots(
            for: workspace.documentID,
            projectID: workspace.projectID
        )
        XCTAssertEqual(snapshots.map(\.id), [first.id])
        let loaded = try await store.text(for: first)
        XCTAssertEqual(loaded, "한글 원고")
    }

    func testImportantBeforeRestoreSnapshotIsNeverCoalesced() async throws {
        let workspace = try makeWorkspace(text: "현재본")
        let store = LocalBackupStore(workspaceLocator: FixedWorkspaceLocator(root: workspace.root))
        let first = try await store.createSnapshot(for: workspace.document(), reason: .beforeRestore)
        let second = try await store.createSnapshot(for: workspace.document(), reason: .beforeRestore)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testPinPersistsAcrossReloadAndDeleteRemovesSnapshotFiles() async throws {
        let workspace = try makeWorkspace(text: "보관할 백업")
        let store = LocalBackupStore(workspaceLocator: FixedWorkspaceLocator(root: workspace.root))
        let snapshot = try await store.createSnapshot(for: workspace.document(), reason: .manual)

        let pinned = try await store.setPinned(true, snapshot: snapshot)
        XCTAssertTrue(pinned.isPinned)
        let reloaded = try await store.snapshots(
            for: workspace.documentID,
            projectID: workspace.projectID
        )
        let reloadedPinned = try XCTUnwrap(reloaded.first)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloadedPinned.id, pinned.id)
        XCTAssertEqual(reloadedPinned.contentHash, pinned.contentHash)
        XCTAssertTrue(reloadedPinned.isPinned)

        try await store.delete(pinned)
        let afterDeletion = try await store.snapshots(
            for: workspace.documentID,
            projectID: workspace.projectID
        )
        XCTAssertTrue(afterDeletion.isEmpty)
        do {
            _ = try await store.text(for: pinned)
            XCTFail("삭제한 백업 본문이 남아 있습니다.")
        } catch let error as BackupStoreError {
            XCTAssertEqual(error, .snapshotNotFound(pinned.id))
        }
    }

    func testSnapshotReusesSavedBytesAndHashWithoutReadingManuscriptOrHashingAgain() async throws {
        let workspace = try makeWorkspace(text: "디스크의 이전 원고")
        let savedData = Data(String(repeating: "저장 직후 최신 원고🙂\n", count: 1_000).utf8)
        let savedHash = SHA256ContentHasher().sha256(for: savedData)
        let wrongHash = ContentHash(rawValue: String(repeating: "0", count: 64))!
        let store: any BackupStoring = LocalBackupStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
            hasher: FixedContentHasher(hash: wrongHash)
        )
        try FileManager.default.removeItem(at: workspace.fileURL)

        let snapshot = try await store.createSnapshot(
            for: workspace.document(),
            reason: .automaticSave,
            savedContent: SavedDocumentContent(
                utf8Data: savedData,
                contentHash: savedHash
            )
        )

        XCTAssertEqual(snapshot.contentHash, savedHash)
        let snapshotURL = workspace.root
            .appendingPathComponent("백업/자동저장", isDirectory: true)
            .appendingPathComponent(
                snapshot.id.rawValue.uuidString.lowercased() + ".txt"
            )
        XCTAssertEqual(try Data(contentsOf: snapshotURL), savedData)
    }

    func testCombinedSnapshotAndRetentionEnumeratesBackupDirectoryOnce() async throws {
        let workspace = try makeWorkspace(text: "첫 백업")
        let store = LocalBackupStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root)
        )
        let firstData = Data("첫 백업".utf8)
        let first = try await store.createSnapshot(
            for: workspace.document(),
            reason: .manual,
            savedContent: SavedDocumentContent(
                utf8Data: firstData,
                contentHash: SHA256ContentHasher().sha256(for: firstData)
            )
        )
        try await ContinuousClock().sleep(for: .milliseconds(5))
        let enumerationsBefore = await store.directoryEnumerationCount
        let secondData = Data("두 번째 백업".utf8)

        let result = try await store.createSnapshotAndApplyRetention(
            for: workspace.document(),
            reason: .automaticSave,
            savedContent: SavedDocumentContent(
                utf8Data: secondData,
                contentHash: SHA256ContentHasher().sha256(for: secondData)
            ),
            policy: BackupPolicy(
                isAutomaticBackupEnabled: true,
                maximumRecentSnapshots: 1,
                retentionDays: 30
            )
        )
        let enumerationsAfter = await store.directoryEnumerationCount

        XCTAssertEqual(enumerationsAfter - enumerationsBefore, 1)
        XCTAssertEqual(result.cleanup.deletedSnapshotIDs, [first.id])
        XCTAssertTrue(result.cleanup.issues.isEmpty)
        XCTAssertNotEqual(result.snapshot.id, first.id)
    }

    func testRestorePreservesCurrentVersionBeforeReplacement() async throws {
        let workspace = try makeWorkspace(text: "과거본")
        let locator = FixedWorkspaceLocator(root: workspace.root)
        let backup = LocalBackupStore(workspaceLocator: locator)
        let old = try await backup.createSnapshot(for: workspace.document(), reason: .manual)
        let documents = LocalDocumentStore(
            workspaceLocator: locator,
            metadataUpdater: RecordingMetadataUpdater()
        )
        let coordinator = DocumentRestoreCoordinator(documentStore: documents, backupStore: backup)

        let result = try await coordinator.restore(
            .init(
                document: workspace.document(),
                snapshot: old,
                currentText: "복원 직전 현재본",
                saveGeneration: 1
            )
        )

        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "과거본")
        XCTAssertEqual(result.restoredText, "과거본")
        XCTAssertEqual(result.receipt.contentHash, old.contentHash)
        let snapshots = try await backup.snapshots(
            for: workspace.documentID,
            projectID: workspace.projectID
        )
        let beforeRestore = try XCTUnwrap(snapshots.first { $0.reason == .beforeRestore })
        let preserved = try await backup.text(for: beforeRestore)
        XCTAssertEqual(preserved, "복원 직전 현재본")
    }

    func testCorruptSnapshotIsRejectedWithoutLosingCurrentText() async throws {
        let workspace = try makeWorkspace(text: "과거본")
        let locator = FixedWorkspaceLocator(root: workspace.root)
        let backup = LocalBackupStore(workspaceLocator: locator)
        let snapshot = try await backup.createSnapshot(for: workspace.document(), reason: .manual)
        try Data("손상".utf8).write(
            to: workspace.root.appendingPathComponent(
                "백업/자동저장/\(snapshot.id.rawValue.uuidString.lowercased()).txt"
            ),
            options: [.atomic]
        )
        let documents = LocalDocumentStore(
            workspaceLocator: locator,
            metadataUpdater: RecordingMetadataUpdater()
        )
        let coordinator = DocumentRestoreCoordinator(documentStore: documents, backupStore: backup)

        do {
            _ = try await coordinator.restore(
                .init(
                    document: workspace.document(), snapshot: snapshot,
                    currentText: "현재본", saveGeneration: 1
                )
            )
            XCTFail("손상 백업이 복원됐습니다.")
        } catch let error as BackupStoreError {
            XCTAssertEqual(error, .hashMismatch(snapshot.id))
        }
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "현재본")
    }

    func testRetentionPolicyHandlesFiveThousandSnapshotsDeterministically() throws {
        let project = ProjectID(rawValue: UUID())
        let document = DocumentID(rawValue: UUID())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let hash = SHA256ContentHasher().sha256(for: Data("x".utf8))
        let snapshots = (0..<5_000).map { index in
            BackupSnapshot(
                id: BackupID(rawValue: UUID()), projectID: project, documentID: document,
                relativePath: .init(rawValue: "메인/원고/1권/1화.txt"),
                createdAt: now.addingTimeInterval(-Double(index) * 600),
                contentHash: hash, reason: .automaticSave, isPinned: index == 4_999
            )
        }
        let first = LocalBackupStore.snapshotsToDelete(snapshots, now: now, policy: .default)
        let second = LocalBackupStore.snapshotsToDelete(
            snapshots.reversed(), now: now, policy: .default
        )
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertFalse(first.contains { $0.isPinned })
        XCTAssertLessThan(first.count, snapshots.count)
    }

    func testRetentionPolicyIgnoresDuplicateSnapshotIDs() {
        let project = ProjectID(rawValue: UUID())
        let document = DocumentID(rawValue: UUID())
        let now = Date(timeIntervalSince1970: 10_000_000)
        let hash = SHA256ContentHasher().sha256(for: Data("x".utf8))
        let uniqueSnapshots = (0..<6).map { index in
            BackupSnapshot(
                id: BackupID(rawValue: UUID()),
                projectID: project,
                documentID: document,
                relativePath: .init(rawValue: "메인/원고/1권/001화.txt"),
                createdAt: now.addingTimeInterval(-Double(index)),
                contentHash: hash,
                reason: .automaticSave,
                isPinned: false
            )
        }
        let duplicatedDirectoryScan = uniqueSnapshots.flatMap { snapshot in
            Array(repeating: snapshot, count: 6)
        }

        let deletion = LocalBackupStore.snapshotsToDelete(
            duplicatedDirectoryScan,
            now: now,
            policy: .default
        )

        XCTAssertTrue(deletion.isEmpty)
    }

    func testPolicyRecoversInvalidValuesAndCorruptFile() async throws {
        let workspace = try makeWorkspace(text: "본문")
        let globalPolicyURL = workspace.root.appendingPathComponent("global-backup-policy.json")
        let store = LocalBackupPolicyStore(
            globalPolicyURL: globalPolicyURL,
            legacyWorkspaceLocator: FixedWorkspaceLocator(root: workspace.root)
        )
        let invalid = BackupPolicy(
            isAutomaticBackupEnabled: false,
            maximumRecentSnapshots: -1,
            retentionDays: 0
        )
        XCTAssertEqual(invalid.maximumRecentSnapshots, BackupPolicy.default.maximumRecentSnapshots)
        XCTAssertEqual(invalid.retentionDays, BackupPolicy.default.retentionDays)
        try Data(
            """
            {"is_automatic_backup_enabled":false,"maximum_recent_snapshots":-9,"retention_days":9000}
            """.utf8
        ).write(to: workspace.root.appendingPathComponent(".writerpad-backup-policy.json"))
        let sanitized = try await store.policy(for: workspace.projectID)
        XCTAssertFalse(sanitized.isAutomaticBackupEnabled)
        XCTAssertEqual(sanitized.maximumRecentSnapshots, 30)
        XCTAssertEqual(sanitized.retentionDays, 30)
        try Data("not-json".utf8).write(to: globalPolicyURL)
        let recovered = try await store.policy(for: workspace.projectID)
        XCTAssertEqual(recovered, .default)
    }

    func testBackupPolicyIsSharedAcrossProjects() async throws {
        let workspace = try makeWorkspace(text: "본문")
        let store = LocalBackupPolicyStore(
            globalPolicyURL: workspace.root.appendingPathComponent("global-backup-policy.json")
        )
        let policy = BackupPolicy(
            isAutomaticBackupEnabled: false,
            maximumRecentSnapshots: 77,
            retentionDays: 365
        )
        try await store.save(policy, for: workspace.projectID)

        let anotherProjectID = ProjectID(rawValue: UUID())
        let sharedPolicy = try await store.policy(for: anotherProjectID)
        XCTAssertEqual(sharedPolicy, policy)
    }

    private func makeWorkspace(text: String) throws -> LocalDocumentTestWorkspace {
        let workspace = try LocalDocumentTestWorkspace.create()
        workspaces.append(workspace)
        try Data(text.utf8).write(to: workspace.fileURL, options: [.atomic])
        return workspace
    }
}

private struct FixedContentHasher: ContentHashing {
    let hash: ContentHash

    func sha256(for data: Data) -> ContentHash { hash }
}
