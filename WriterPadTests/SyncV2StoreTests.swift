import Foundation
import SQLite3
import XCTest
@testable import WriterPad

final class SyncV2StoreTests: XCTestCase {
    func testNewDatabaseCreatesFullSchemaAndWAL() async throws {
        let url = try databaseURL()

        let store = try await openStore(at: url)

        let version = try await store.schemaVersion()
        let journalMode = try await store.journalMode()
        XCTAssertEqual(version, 1)
        XCTAssertEqual(journalMode.lowercased(), "wal")
        await store.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table'
                  AND name IN (
                    'sync_projects', 'sync_documents', 'sync_batches',
                    'sync_operations', 'sync_conflicts'
                  );
                """
            ),
            5
        )
        let checksum = try raw.scalarText(
            "SELECT checksum FROM schema_migrations WHERE version = 1;"
        )
        XCTAssertEqual(checksum.count, 64)
        XCTAssertNotEqual(checksum, "design-fixture-v1")
    }

    func testWALAndBindingSurviveCloseAndReopen() async throws {
        let url = try databaseURL()
        let localID = ProjectID(rawValue: UUID())
        let serverID = UUID()
        let ownerID = UUID()
        let expected = ProjectSyncBinding.connected(
            localProjectID: localID,
            serverProjectID: serverID,
            kind: .existingServerProject,
            projectName: "재실행 binding",
            ownerSubject: ownerID
        )
        let first = try await openStore(at: url)
        try await first.save(expected)
        await first.close()

        let reopened = try await openStore(at: url)

        let restored = try await reopened.binding(for: localID)
        let mode = try await reopened.journalMode()
        XCTAssertEqual(restored, expected)
        XCTAssertEqual(mode.lowercased(), "wal")
        await reopened.close()
    }

    func testEmptyVersionZeroDatabaseMigratesForwardToV1() async throws {
        let url = try databaseURL()
        let raw = try RawSQLite(url: url)
        try raw.execute("PRAGMA user_version = 0;")
        raw.close()

        let store = try await openStore(at: url)

        let version = try await store.schemaVersion()
        XCTAssertEqual(version, 1)
        await store.close()
    }

    func testHigherSchemaVersionIsPreservedAndRejected() async throws {
        let url = try databaseURL()
        let raw = try RawSQLite(url: url)
        try raw.execute("PRAGMA user_version = 2;")
        raw.close()

        let diagnostic = await unavailableDiagnostic(at: url)

        XCTAssertEqual(diagnostic.reason, .schemaTooNew)
        XCTAssertEqual(diagnostic.schemaVersion, 2)
        let check = try RawSQLite(url: url)
        XCTAssertEqual(try check.scalarInt("PRAGMA user_version;"), 2)
    }

    func testVersionZeroWithUnknownTableIsPreservedAndRejected()
        async throws {
        let url = try databaseURL()
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            CREATE TABLE unknown_user_data(value TEXT NOT NULL);
            INSERT INTO unknown_user_data(value) VALUES ('preserve me');
            PRAGMA user_version = 0;
            """
        )
        raw.close()

        let diagnostic = await unavailableDiagnostic(at: url)

        XCTAssertEqual(diagnostic.reason, .unrecognizedSchema)
        let preserved = try RawSQLite(url: url)
        XCTAssertEqual(
            try preserved.scalarText(
                "SELECT value FROM unknown_user_data LIMIT 1;"
            ),
            "preserve me"
        )
    }

    func testMigrationChecksumMismatchNeverRecreatesDatabase() async throws {
        let url = try databaseURL()
        let created = try await openStore(at: url)
        await created.close()
        let raw = try RawSQLite(url: url)
        try raw.execute(
            "UPDATE schema_migrations SET checksum = 'tampered';"
        )
        raw.close()

        let diagnostic = await unavailableDiagnostic(at: url)

        XCTAssertEqual(diagnostic.reason, .migrationMismatch)
        let preserved = try RawSQLite(url: url)
        XCTAssertEqual(
            try preserved.scalarText(
                "SELECT checksum FROM schema_migrations WHERE version = 1;"
            ),
            "tampered"
        )
    }

    func testFailedMultiRowTransactionRollsBackEveryRow() async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()
        let raw = try RawSQLite(url: url)
        let fixture = QueueFixture()
        try raw.execute(fixture.insertProjectSQL)
        try raw.execute("BEGIN IMMEDIATE;")
        do {
            try raw.execute(fixture.insertBatchSQL(batchID: fixture.batchID))
            let operationSQL = fixture.insertEnsureOperationSQL(
                operationID: fixture.operationID,
                batchID: fixture.batchID,
                status: "pending"
            )
            try raw.execute(operationSQL)
            try raw.execute(operationSQL)
            XCTFail("Duplicate operation ID must fail.")
        } catch {
            try raw.execute("ROLLBACK;")
        }

        XCTAssertEqual(
            try raw.scalarInt("SELECT COUNT(*) FROM sync_batches;"),
            0
        )
        XCTAssertEqual(
            try raw.scalarInt("SELECT COUNT(*) FROM sync_operations;"),
            0
        )
    }

    func testPartiallyCorruptUUIDRowDisablesStoreWithoutDeletingIt()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()
        let invalidUUID = String(repeating: "z", count: 36)
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            INSERT INTO sync_projects(
                local_project_id, server_project_id, binding_kind,
                project_name, owner_subject, created_at, updated_at
            ) VALUES (
                '\(invalidUUID)', NULL, 'local_only',
                '손상 행', NULL, '2026-07-26T00:00:00Z',
                '2026-07-26T00:00:00Z'
            );
            """
        )
        raw.close()

        let diagnostic = await unavailableDiagnostic(at: url)

        XCTAssertEqual(diagnostic.reason, .integrityCheckFailed)
        let preserved = try RawSQLite(url: url)
        XCTAssertEqual(
            try preserved.scalarInt(
                "SELECT COUNT(*) FROM sync_projects;"
            ),
            1
        )
    }

    func testDuplicateDocumentIDIsRejectedAndFirstRowSurvives()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()
        let fixture = QueueFixture()
        let raw = try RawSQLite(url: url)
        try raw.execute(fixture.insertProjectSQL)
        let first = fixture.insertDocumentSQL(
            documentID: fixture.documentID,
            localPath: "원고/1권/001화.txt"
        )
        try raw.execute(first)

        XCTAssertThrowsError(
            try raw.execute(
                fixture.insertDocumentSQL(
                    documentID: fixture.documentID,
                    localPath: "원고/1권/002화.txt"
                )
            )
        )
        XCTAssertEqual(
            try raw.scalarInt("SELECT COUNT(*) FROM sync_documents;"),
            1
        )
    }

    func testDuplicateOperationIDIsRejectedWithoutOverwritingPayload()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()
        let fixture = QueueFixture()
        let secondBatch = UUID()
        let raw = try RawSQLite(url: url)
        try raw.execute(fixture.insertProjectSQL)
        try raw.execute(fixture.insertBatchSQL(batchID: fixture.batchID))
        try raw.execute(fixture.insertBatchSQL(batchID: secondBatch))
        try raw.execute(
            fixture.insertEnsureOperationSQL(
                operationID: fixture.operationID,
                batchID: fixture.batchID,
                status: "pending",
                projectName: "원본 payload"
            )
        )

        XCTAssertThrowsError(
            try raw.execute(
                fixture.insertEnsureOperationSQL(
                    operationID: fixture.operationID,
                    batchID: secondBatch,
                    status: "pending",
                    projectName: "덮어쓰기 payload"
                )
            )
        )
        XCTAssertEqual(
            try raw.scalarText(
                """
                SELECT project_name FROM sync_operations
                WHERE operation_id = '\(fixture.operationID.uuidString.lowercased())';
                """
            ),
            "원본 payload"
        )
    }

    func testOneThousandQueuedOperationsReopenIntact() async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()
        let fixture = QueueFixture()
        let raw = try RawSQLite(url: url)
        var sql = "BEGIN IMMEDIATE;\n\(fixture.insertProjectSQL)\n"
        for _ in 0..<1_000 {
            let batchID = UUID()
            let operationID = UUID()
            sql += fixture.insertBatchSQL(batchID: batchID)
            sql += fixture.insertEnsureOperationSQL(
                operationID: operationID,
                batchID: batchID,
                status: "pending"
            )
        }
        sql += "COMMIT;"
        try raw.execute(sql)
        raw.close()

        let reopened = try await openStore(at: url)

        let count = try await reopened.operationCount()
        XCTAssertEqual(count, 1_000)
        await reopened.close()
    }

    func testStartupReturnsInflightToPendingWithSameIDAndAttempts()
        async throws {
        let url = try databaseURL()
        let created = try await openStore(at: url)
        await created.close()
        let fixture = QueueFixture()
        let raw = try RawSQLite(url: url)
        try raw.execute(fixture.insertProjectSQL)
        try raw.execute(
            fixture.insertBatchSQL(
                batchID: fixture.batchID,
                status: "processing"
            )
        )
        try raw.execute(
            fixture.insertEnsureOperationSQL(
                operationID: fixture.operationID,
                batchID: fixture.batchID,
                status: "inflight",
                attempts: 3
            )
        )
        raw.close()

        let reopened = try await openStore(at: url)

        let status = try await reopened.operationStatus(
            operationID: fixture.operationID
        )
        let attempts = try await reopened.operationAttempts(
            operationID: fixture.operationID
        )
        let count = try await reopened.operationCount()
        XCTAssertEqual(status, "pending")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(count, 1)
        await reopened.close()
    }

    func testLazyBindingAdapterPersistsIntoSyncProjects() async throws {
        let url = try databaseURL()
        let adapter = LazySyncV2ProjectBindingStore(databaseURL: url)
        let binding = ProjectSyncBinding.connected(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID(),
            kind: .newServerProject,
            projectName: "라이브 adapter",
            ownerSubject: UUID()
        )

        let availability = await adapter.availability()
        XCTAssertEqual(availability, .available)
        try await adapter.save(binding)
        let restored = try await adapter.binding(
            for: binding.localProjectID
        )

        XCTAssertEqual(restored, binding)
    }

    func testLazyRecorderMapsSavedSnapshotIntoDurableDocumentQueue()
        async throws {
        let url = try databaseURL()
        let deviceID = UUID()
        let identity = DeviceIdentityService(
            store: InMemoryDeviceIdentityStore(),
            generateUUID: { deviceID }
        )
        let wakeup = SyncV2DispatchWakeup()
        let wakeupCounter = DispatchWakeupCounter()
        await wakeup.install(id: UUID()) {
            Task {
                await wakeupCounter.increment()
            }
        }
        let recorder = LazySyncV2ProjectBindingStore(
            databaseURL: url,
            deviceIdentityProvider: identity,
            dispatchWakeup: wakeup
        )
        let projectID = ProjectID(rawValue: UUID())
        try await recorder.save(
            .connected(
                localProjectID: projectID,
                serverProjectID: UUID(),
                kind: .newServerProject,
                projectName: "10-3 저장 연결",
                ownerSubject: UUID()
            )
        )
        let operationID = UUID()
        let documentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(
            rawValue: "메인/원고/1권/001화.txt"
        )
        let content = "LocalDocumentStore 확정 snapshot🙂"
        let hash = SHA256ContentHasher().sha256(for: Data(content.utf8))
        let batch = LocalMutationBatch(
            batchID: UUID(),
            projectID: projectID,
            localTransactionID: nil,
            mutations: [
                .documentSnapshot(
                    operationID: operationID,
                    documentID: documentID,
                    relativePath: path,
                    content: content,
                    contentHash: hash,
                    localSaveGeneration: 41,
                    isDeleted: false
                )
            ]
        )

        let result = await recorder.record(batch)
        var wakeupCount = await wakeupCounter.value()
        for _ in 0..<50 where wakeupCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
            wakeupCount = await wakeupCounter.value()
        }

        XCTAssertEqual(result, .queued(operationIDs: [operationID]))
        XCTAssertEqual(wakeupCount, 1)
        let inspection = try await openStore(at: url)
        let queued = try await inspection.queuedOperations(
            documentID: documentID.rawValue
        )
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].operationID, operationID)
        XCTAssertEqual(queued[0].documentSequence, 1)
        XCTAssertEqual(queued[0].content, content)
        XCTAssertEqual(queued[0].relativePath, path.rawValue)
        await inspection.close()
    }

    func testLazyRecorderCanonicalizesServerPathAndPreservesNFDLocalPath()
        async throws {
        let url = try databaseURL()
        let recorder = LazySyncV2ProjectBindingStore(
            databaseURL: url,
            deviceIdentityProvider: DeviceIdentityService(
                store: InMemoryDeviceIdentityStore(),
                generateUUID: { UUID() }
            )
        )
        let projectID = ProjectID(rawValue: UUID())
        try await recorder.save(
            .connected(
                localProjectID: projectID,
                serverProjectID: UUID(),
                kind: .newServerProject,
                projectName: "NFC 경로",
                ownerSubject: UUID()
            )
        )
        let expected = "메인/원고/1권/001화.txt"
        let localPath = expected.decomposedStringWithCanonicalMapping
        XCTAssertFalse(localPath.utf8.elementsEqual(expected.utf8))
        let operationID = UUID()
        let documentID = DocumentID(rawValue: UUID())
        let content = "NFD 파일시스템 경로"

        let result = await recorder.record(
            LocalMutationBatch(
                batchID: UUID(),
                projectID: projectID,
                localTransactionID: nil,
                mutations: [
                    .documentSnapshot(
                        operationID: operationID,
                        documentID: documentID,
                        relativePath: RelativeDocumentPath(
                            rawValue: localPath
                        ),
                        content: content,
                        contentHash: SHA256ContentHasher().sha256(
                            for: Data(content.utf8)
                        ),
                        localSaveGeneration: 1,
                        isDeleted: false
                    )
                ]
            )
        )

        XCTAssertEqual(result, .queued(operationIDs: [operationID]))
        let inspection = try await openStore(at: url)
        let queued = try await inspection.queuedOperations(
            documentID: documentID.rawValue
        )
        let operation = try XCTUnwrap(queued.first)
        XCTAssertTrue(operation.localPath.utf8.elementsEqual(localPath.utf8))
        XCTAssertTrue(operation.relativePath.utf8.elementsEqual(expected.utf8))
        await inspection.close()
    }

    func testLazyRecorderReturnsServerSizeLimitWithoutQueueFailure()
        async throws {
        let url = try databaseURL()
        let identity = DeviceIdentityService(
            store: InMemoryDeviceIdentityStore(),
            generateUUID: { UUID() }
        )
        let recorder = LazySyncV2ProjectBindingStore(
            databaseURL: url,
            deviceIdentityProvider: identity
        )
        let projectID = ProjectID(rawValue: UUID())
        try await recorder.save(
            .connected(
                localProjectID: projectID,
                serverProjectID: UUID(),
                kind: .newServerProject,
                projectName: "10-5 크기 제한",
                ownerSubject: UUID()
            )
        )
        let content = String(
            repeating: "a",
            count: SyncV2Store.maximumContentByteCount + 1
        )
        let operationID = UUID()
        let documentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(
            rawValue: "메인/원고/1권/001화.txt"
        )

        let result = await recorder.record(
            LocalMutationBatch(
                batchID: UUID(),
                projectID: projectID,
                localTransactionID: nil,
                mutations: [
                    .documentSnapshot(
                        operationID: operationID,
                        documentID: documentID,
                        relativePath: path,
                        content: content,
                        contentHash: SHA256ContentHasher().sha256(
                            for: Data(content.utf8)
                        ),
                        localSaveGeneration: 1,
                        isDeleted: false
                    )
                ]
            )
        )

        XCTAssertEqual(
            result,
            .serverSizeLimitExceeded(
                byteCount: SyncV2Store.maximumContentByteCount + 1,
                limit: SyncV2Store.maximumContentByteCount
            )
        )
        let restored = await recorder.preservedResult(
            for: projectID,
            documentID: documentID
        )
        XCTAssertEqual(restored, result)
        let inspection = try await openStore(at: url)
        let blockedStatus = try await inspection.operationStatus(
            operationID: operationID
        )
        XCTAssertEqual(
            blockedStatus,
            SyncV2OperationStatus.blocked.rawValue
        )
        await inspection.close()
    }

    func testLazyRecorderMapsHiddenMutationsToWindowsCompatibleUUIDv5()
        async throws {
        let url = try databaseURL()
        let identity = DeviceIdentityService(
            store: InMemoryDeviceIdentityStore(),
            generateUUID: { UUID() }
        )
        let recorder = LazySyncV2ProjectBindingStore(
            databaseURL: url,
            deviceIdentityProvider: identity
        )
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000777"
        )!
        try await recorder.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .windowsImport,
                projectName: "숨김 문서",
                ownerSubject: UUID()
            )
        )
        let treeOperationID = UUID()
        let purgeOperationID = UUID()
        let batch = LocalMutationBatch(
            batchID: UUID(),
            projectID: localProjectID,
            localTransactionID: UUID(),
            kind: .windowsImport,
            mutations: [
                .ensureProject(operationID: UUID(), name: "숨김 문서"),
                .treeOrder(
                    operationID: treeOperationID,
                    content: "{\"tree_order\":{},\"version\":1}",
                    generation: 7
                ),
                .trashPurge(
                    operationID: purgeOperationID,
                    content:
                        "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":1}",
                    generation: UUID()
                ),
            ]
        )

        guard case let .queued(operationIDs) = await recorder.record(batch)
        else {
            return XCTFail("숨김 문서 batch가 queue에 들어가지 않았습니다.")
        }
        XCTAssertEqual(operationIDs.count, 3)

        let inspection = try await openStore(at: url)
        let treeID = UUID(
            uuidString: "40bb5047-37f2-55b6-9aa0-afe78967b752"
        )!
        let purgeID = UUID(
            uuidString: "16203711-4c74-54c3-87ac-204cdeb91c10"
        )!
        let tree = try await inspection.queuedOperations(documentID: treeID)
        let purge = try await inspection.queuedOperations(documentID: purgeID)
        XCTAssertEqual(tree.map(\.operationID), [treeOperationID])
        XCTAssertEqual(tree.map(\.kind), [.treeOrder])
        XCTAssertEqual(
            tree.map(\.relativePath),
            ["__antigravity__/tree-order.json"]
        )
        XCTAssertEqual(purge.map(\.operationID), [purgeOperationID])
        XCTAssertEqual(purge.map(\.kind), [.trashPurge])
        XCTAssertEqual(
            purge.map(\.relativePath),
            ["__antigravity__/trash-purge.json"]
        )
        await inspection.close()
    }

    func testWindowsInitialSnapshotMarkerReplaysImmutableWholeProjectBatch()
        async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WriterPad-WindowsInitial-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/휴지통"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID(rawValue: UUID())
        let rootID = DocumentID(rawValue: UUID())
        let notesID = DocumentID(rawValue: UUID())
        let liveID = DocumentID(rawValue: UUID())
        let trashID = DocumentID(rawValue: UUID())
        let date = Date(timeIntervalSince1970: 1)
        let nodes = [
            DocumentNode(
                id: rootID,
                projectID: projectID,
                kind: .folder,
                parentID: nil,
                relativePath: .init(rawValue: "메인"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
            DocumentNode(
                id: notesID,
                projectID: projectID,
                kind: .folder,
                parentID: rootID,
                relativePath: .init(rawValue: "메인/메모장"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
            DocumentNode(
                id: liveID,
                projectID: projectID,
                kind: .text,
                parentID: notesID,
                relativePath: .init(rawValue: "메인/메모장/가져온 글.txt"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
            DocumentNode(
                id: trashID,
                projectID: projectID,
                kind: .text,
                parentID: nil,
                relativePath: .init(rawValue: "메인/휴지통/제외.txt"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil,
                deletionStatus: .trashed(
                    originalPath: .init(rawValue: "메인/메모장/제외.txt"),
                    deletedAt: date
                )
            ),
        ]
        let liveURL = root.appendingPathComponent("메인/메모장/가져온 글.txt")
        try Data("최초 snapshot".utf8).write(to: liveURL)
        try Data("휴지통".utf8).write(
            to: root.appendingPathComponent("메인/휴지통/제외.txt")
        )
        let durable = ScriptedDurableChangeRecorder(
            results: [
                .localSavedButNotQueued(reason: "injected"),
                .queued(operationIDs: []),
            ]
        )
        let recorder = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository(nodes),
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )

        _ = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "Windows 작품",
            batchKind: .windowsImport
        )
        let marker = root.appendingPathComponent(
            ProjectInitialSyncRecorder.markerName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let firstAttempts = await durable.batches
        let first = try XCTUnwrap(firstAttempts.first)
        XCTAssertEqual(first.kind, .windowsImport)
        XCTAssertEqual(first.mutations.count, 3)

        try Data("후속 변경".utf8).write(to: liveURL)
        _ = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "Windows 작품",
            batchKind: .windowsImport
        )

        let recorded = await durable.batches
        XCTAssertEqual(recorded, [first, first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        guard case let .documentSnapshot(
            _,
            documentID,
            _,
            content,
            _,
            _,
            _
        ) = first.mutations[1] else {
            return XCTFail("가져온 TXT snapshot이 없습니다.")
        }
        XCTAssertEqual(documentID, liveID)
        XCTAssertEqual(content, "최초 snapshot")
    }

    func testNewServerProjectInitialSnapshotBackfillsLiveDocuments()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-NewProjectInitial-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let relativePath = RelativeDocumentPath(
            rawValue: "메인/메모장/연결 전 저장.txt"
        )
        let nodes = [
            DocumentNode(
                id: folderID,
                projectID: projectID,
                kind: .folder,
                parentID: nil,
                relativePath: .init(rawValue: "메인/메모장"),
                userOrder: 0,
                modifiedAt: Date(timeIntervalSince1970: 1),
                contentHash: nil
            ),
            DocumentNode(
                id: documentID,
                projectID: projectID,
                kind: .text,
                parentID: folderID,
                relativePath: relativePath,
                userOrder: 0,
                modifiedAt: Date(timeIntervalSince1970: 1),
                contentHash: nil
            ),
        ]
        try Data("binding 전 로컬 본문".utf8).write(
            to: root.appendingPathComponent(relativePath.rawValue)
        )
        let durable = ScriptedDurableChangeRecorder(
            results: [.queued(operationIDs: [UUID()])]
        )
        let recorder = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository(nodes),
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )

        let result = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "새 서버 작품",
            batchKind: .projectBinding
        )

        guard case .queued = result else {
            return XCTFail("새 작품 초기 snapshot이 queue되어야 합니다.")
        }
        let batches = await durable.batches
        let batch = try XCTUnwrap(batches.first)
        XCTAssertEqual(batch.kind, .projectBinding)
        guard case let .documentSnapshot(
            _,
            recordedDocumentID,
            recordedPath,
            recordedContent,
            _,
            _,
            _
        ) = batch.mutations[1] else {
            return XCTFail("연결 전 로컬 문서 snapshot이 없습니다.")
        }
        XCTAssertEqual(recordedDocumentID, documentID)
        XCTAssertEqual(recordedPath, relativePath)
        XCTAssertEqual(recordedContent, "binding 전 로컬 본문")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ProjectInitialSyncRecorder.newProjectMarkerName
                ).path
            )
        )
    }

    func testSQLiteBindingUniqueIndexRejectsSecondLocalProject()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let serverID = UUID()
        let first = ProjectSyncBinding.connected(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverID,
            kind: .existingServerProject,
            projectName: "첫 binding",
            ownerSubject: UUID()
        )
        let second = ProjectSyncBinding.connected(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverID,
            kind: .existingServerProject,
            projectName: "두 번째 binding",
            ownerSubject: UUID()
        )
        try await store.save(first)

        do {
            try await store.save(second)
            XCTFail("The same server UUID must not bind twice.")
        } catch {
            XCTAssertEqual(
                error as? ProjectBindingStoreError,
                .serverProjectAlreadyBound
            )
        }

        let preserved = try await store.binding(
            forServerProjectID: serverID
        )
        XCTAssertEqual(preserved, first)
        await store.close()
    }

    func testEnqueueAllocatesDocumentSequenceAndImmutablePayload()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        let content = "첫 저장🙂"
        let batch = context.batch(
            mutations: [
                context.documentMutation(
                    operationID: operationID,
                    content: content,
                    generation: 7
                )
            ]
        )

        let receipt = try await store.enqueue(batch)
        let queued = try await store.queuedOperations(
            documentID: context.documentID
        )

        XCTAssertEqual(receipt.operationIDs, [operationID])
        XCTAssertFalse(receipt.replayed)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].operationID, operationID)
        XCTAssertEqual(queued[0].documentSequence, 1)
        XCTAssertEqual(queued[0].kind, .documentCommit)
        XCTAssertEqual(queued[0].status, .pending)
        XCTAssertEqual(queued[0].baseRevision, 0)
        XCTAssertEqual(queued[0].content, content)
        XCTAssertEqual(
            queued[0].contentByteCount,
            content.lengthOfBytes(using: .utf8)
        )
        XCTAssertEqual(queued[0].contentHash.count, 64)
        await store.close()
    }

    func testContentPreflightAllowsTenMiBAndBlocksOneByteOver()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let exactID = UUID()
        let oversizedID = UUID()
        let oversizedDocumentID = UUID()
        let exact = String(
            repeating: "a",
            count: SyncV2Store.maximumContentByteCount
        )
        let oversized = exact + "b"

        let exactReceipt = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: exactID,
                        content: exact
                    )
                ]
            )
        )
        let oversizedReceipt = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: oversizedID,
                        documentID: oversizedDocumentID,
                        relativePath: "원고/1권/002화.txt",
                        content: oversized
                    )
                ]
            )
        )

        let exactStatus = try await store.operationStatus(
            operationID: exactID
        )
        XCTAssertEqual(exactReceipt.blockedOperations, [])
        XCTAssertEqual(
            exactStatus,
            SyncV2OperationStatus.pending.rawValue
        )
        XCTAssertEqual(
            oversizedReceipt.blockedOperations,
            [
                SyncV2BlockedOperation(
                    operationID: oversizedID,
                    contentByteCount:
                        SyncV2Store.maximumContentByteCount + 1,
                    limit: SyncV2Store.maximumContentByteCount
                )
            ]
        )
        let oversizedStatus = try await store.operationStatus(
            operationID: oversizedID
        )
        XCTAssertEqual(
            oversizedStatus,
            SyncV2OperationStatus.blocked.rawValue
        )
        await store.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarText(
                """
                SELECT sync_state FROM sync_documents
                WHERE document_id = '\(
                    oversizedDocumentID.uuidString.lowercased()
                )';
                """
            ),
            "blocked"
        )
        XCTAssertEqual(
            try raw.scalarText(
                """
                SELECT last_error_code FROM sync_documents
                WHERE document_id = '\(
                    oversizedDocumentID.uuidString.lowercased()
                )';
                """
            ),
            SyncV2Store.contentTooLargeErrorCode
        )
    }

    func testServerBaselineNoOpCreatesNoOperationAndRequiresEmptyLane()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let baselineContent = "서버 기준 본문"
        let relativePath = "원고/1권/001화.txt"
        let first = try await connectedStore(at: url, context: context)
        let initialID = UUID()
        _ = try await first.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: initialID,
                        relativePath: relativePath,
                        content: baselineContent
                    )
                ]
            )
        )
        await first.close()

        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations
            SET status = 'completed'
            WHERE operation_id = '\(initialID.uuidString.lowercased())';
            UPDATE sync_documents
            SET server_revision = 7,
                server_path = '\(relativePath)',
                base_content = '\(baselineContent)',
                is_deleted = 0,
                sync_state = 'synced'
            WHERE document_id = '\(
                context.documentID.uuidString.lowercased()
            )';
            """
        )
        raw.close()

        let store = try await openStore(at: url)
        let noOpID = UUID()
        let noOpBatch = context.batch(
            mutations: [
                context.documentMutation(
                    operationID: noOpID,
                    relativePath: relativePath,
                    content: baselineContent,
                    generation: 2
                )
            ]
        )

        let noOp = try await store.enqueue(noOpBatch)
        let replay = try await store.enqueue(noOpBatch)

        XCTAssertEqual(noOp.operationIDs, [])
        XCTAssertEqual(noOp.noOpOperationIDs, [noOpID])
        XCTAssertFalse(noOp.replayed)
        XCTAssertEqual(replay.operationIDs, [])
        XCTAssertEqual(replay.noOpOperationIDs, [noOpID])
        XCTAssertTrue(replay.replayed)
        let countAfterNoOp = try await store.operationCount()
        XCTAssertEqual(countAfterNoOp, 1)

        let pendingID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: pendingID,
                        relativePath: relativePath,
                        content: "전송 대기 중인 변경",
                        generation: 3
                    )
                ]
            )
        )
        let sameAsServerWhilePendingID = UUID()
        let notSkipped = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: sameAsServerWhilePendingID,
                        relativePath: relativePath,
                        content: baselineContent,
                        generation: 4
                    )
                ]
            )
        )

        XCTAssertEqual(notSkipped.operationIDs, [sameAsServerWhilePendingID])
        XCTAssertEqual(notSkipped.noOpOperationIDs, [])
        let finalCount = try await store.operationCount()
        XCTAssertEqual(finalCount, 3)
        await store.close()
    }

    func testNFDServerBaselineQueuesSameUUIDRenameToCanonicalNFC()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let canonicalPath = "원고/1권/001화.txt"
        let nfdServerPath =
            canonicalPath.decomposedStringWithCanonicalMapping
        XCTAssertFalse(
            nfdServerPath.utf8.elementsEqual(canonicalPath.utf8)
        )
        let content = "같은 UUID와 본문"
        let initialID = UUID()
        let first = try await connectedStore(at: url, context: context)
        _ = try await first.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: initialID,
                        relativePath: canonicalPath,
                        content: content
                    )
                ]
            )
        )
        await first.close()

        let raw = try RawSQLite(url: url)
        let escapedNFD = nfdServerPath.replacingOccurrences(
            of: "'",
            with: "''"
        )
        try raw.execute(
            """
            UPDATE sync_operations
            SET status = 'completed'
            WHERE operation_id = '\(initialID.uuidString.lowercased())';
            UPDATE sync_documents
            SET server_revision = 3,
                server_path = '\(escapedNFD)',
                base_content = '\(content)',
                is_deleted = 0,
                sync_state = 'synced'
            WHERE document_id = '\(
                context.documentID.uuidString.lowercased()
            )';
            """
        )
        raw.close()

        let store = try await openStore(at: url)
        let renameID = UUID()
        let receipt = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: renameID,
                        relativePath: canonicalPath,
                        content: content,
                        generation: 2
                    )
                ]
            )
        )

        XCTAssertEqual(receipt.operationIDs, [renameID])
        XCTAssertEqual(receipt.noOpOperationIDs, [])
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let operation = try XCTUnwrap(claimed.first)
        XCTAssertEqual(operation.documentID, context.documentID)
        XCTAssertTrue(
            operation.baseServerPath.utf8.elementsEqual(nfdServerPath.utf8)
        )
        XCTAssertTrue(
            operation.commitParameters.relativePath.utf8
                .elementsEqual(canonicalPath.utf8)
        )
        await store.close()
    }

    func testExactBatchReplayReusesOperationIDsWithoutDuplicateRows()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        let batch = context.batch(
            mutations: [
                context.documentMutation(operationID: operationID)
            ]
        )

        let first = try await store.enqueue(batch)
        let replay = try await store.enqueue(batch)

        XCTAssertFalse(first.replayed)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.operationIDs, [operationID])
        let count = try await store.operationCount()
        XCTAssertEqual(count, 1)
        await store.close()
    }

    func testReusedBatchIDWithDifferentPayloadIsRejected()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        let batchID = UUID()
        let original = context.batch(
            batchID: batchID,
            mutations: [
                context.documentMutation(
                    operationID: operationID,
                    content: "원본"
                )
            ]
        )
        _ = try await store.enqueue(original)
        let changed = context.batch(
            batchID: batchID,
            mutations: [
                context.documentMutation(
                    operationID: operationID,
                    content: "변경 payload"
                )
            ]
        )

        do {
            _ = try await store.enqueue(changed)
            XCTFail("A reused batch ID with another payload must fail.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2EnqueueError,
                .batchIDReused
            )
        }
        let queued = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(queued.map(\.content), ["원본"])
        await store.close()
    }

    func testDistinctIdenticalSavesRemainDistinctAndOrdered()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let firstID = UUID()
        let secondID = UUID()

        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: firstID,
                        content: "같은 본문",
                        generation: 1
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: secondID,
                        content: "같은 본문",
                        generation: 2
                    )
                ]
            )
        )

        let queued = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(
            queued.map(\.operationID),
            [firstID, secondID]
        )
        XCTAssertEqual(
            queued.map(\.documentSequence),
            [1, 2]
        )
        XCTAssertEqual(queued[0].baseRevision, 0)
        XCTAssertNil(queued[1].baseRevision)
        await store.close()
    }

    func testRenameDeleteAndRestoreSnapshotsAreNeverElided()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let identifiers = (0..<4).map { _ in UUID() }
        let paths = [
            "원고/1권/001화.txt",
            "원고/1권/새 이름.txt",
            "원고/1권/새 이름.txt",
            "원고/복원/새 이름.txt",
        ]
        let deleted = [false, false, true, false]
        let contents = ["본문", "본문", "", "복원 본문"]

        for index in identifiers.indices {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.documentMutation(
                            operationID: identifiers[index],
                            relativePath: paths[index],
                            content: contents[index],
                            isDeleted: deleted[index],
                            generation: index + 1
                        )
                    ]
                )
            )
        }

        let queued = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(queued.map(\.operationID), identifiers)
        XCTAssertEqual(
            queued.map(\.documentSequence),
            [1, 2, 3, 4]
        )
        XCTAssertEqual(queued.map(\.relativePath), paths)
        XCTAssertEqual(queued.map(\.isDeleted), deleted)
        XCTAssertEqual(queued.map(\.content), contents)
        await store.close()
    }

    func testCreateDeleteRestoreAndRedeleteKeepOneUUIDAndIncreaseRevision()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationIDs = (0..<4).map { _ in UUID() }
        let deleted = [false, true, false, true]
        let contents = ["최초", "", "복원", ""]

        for index in operationIDs.indices {
            _ = try await store.enqueue(
                context.batch(
                    kind: index == 0 ? .documentSave : .trashChange,
                    mutations: [
                        context.documentMutation(
                            operationID: operationIDs[index],
                            content: contents[index],
                            isDeleted: deleted[index],
                            generation: index + 1
                        ),
                    ]
                )
            )
        }

        var claimedRevisions: [Int64] = []
        var claimedDeleted: [Bool] = []
        for index in operationIDs.indices {
            let claims = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 100 + Double(index))
            )
            let operation = try XCTUnwrap(claims.first)
            XCTAssertEqual(operation.operationID, operationIDs[index])
            XCTAssertEqual(operation.documentID, context.documentID)
            claimedRevisions.append(operation.baseRevision)
            claimedDeleted.append(operation.isDeleted)
            try await store.complete(
                operation,
                result: commitResult(for: operation)
            )
        }

        XCTAssertEqual(claimedRevisions, [0, 1, 2, 3])
        XCTAssertEqual(claimedDeleted, deleted)
        let serverRevision = try await store.serverRevision(
            for: context.documentID
        )
        XCTAssertEqual(serverRevision, 4)
        await store.close()
    }

    func testTombstoneFreesLivePathAndDropsLateDocumentSave()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let reusedPath = "원고/1권/같은 이름.txt"
        let replacementDocumentID = UUID()
        let createID = UUID()
        let deleteID = UUID()
        let replacementID = UUID()
        let lateSaveID = UUID()

        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: createID,
                        relativePath: reusedPath,
                        content: "삭제 전 최신 본문",
                        generation: 1
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .trashChange,
                mutations: [
                    context.documentMutation(
                        operationID: deleteID,
                        relativePath: reusedPath,
                        content: "",
                        isDeleted: true,
                        generation: 2
                    ),
                ]
            )
        )

        let replacementReceipt = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: replacementID,
                        documentID: replacementDocumentID,
                        relativePath: reusedPath,
                        content: "새 UUID 본문",
                        generation: 3
                    ),
                ]
            )
        )
        let lateReceipt = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: lateSaveID,
                        relativePath: reusedPath,
                        content: "늦게 도착한 편집 저장",
                        generation: 1
                    ),
                ]
            )
        )

        XCTAssertEqual(replacementReceipt.operationIDs, [replacementID])
        XCTAssertEqual(lateReceipt.operationIDs, [])
        XCTAssertEqual(lateReceipt.noOpOperationIDs, [lateSaveID])
        let originalOperations = try await store.queuedOperations(
            documentID: context.documentID
        )
        let replacementOperations = try await store.queuedOperations(
            documentID: replacementDocumentID
        )
        XCTAssertEqual(
            originalOperations.map(\.operationID),
            [createID, deleteID]
        )
        XCTAssertEqual(replacementOperations.map(\.operationID), [replacementID])
        await store.close()
    }

    func testRapidTreeOrderCoalescesOnlyUnsentOperation() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let treeDocumentID = syncV2UUIDv5(
            namespace: context.serverProjectID,
            name: syncV2TreeOrderPath
        )
        let firstID = UUID()
        let secondID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.documentMutation(
                        operationID: firstID,
                        documentID: treeDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인/메모장\":[\"첫째.txt\",\"둘째.txt\"]},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.documentMutation(
                        operationID: secondID,
                        documentID: treeDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인/메모장\":[\"둘째.txt\",\"첫째.txt\"]},\"version\":1}",
                        generation: 2,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let operations = try await store.queuedOperations(
            documentID: treeDocumentID
        )
        let firstStatus = try await store.operationStatus(operationID: firstID)
        let secondStatus = try await store.operationStatus(operationID: secondID)
        let claimed = try await store.claimReadyOperations(
            limit: 5,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(operations.map(\.operationID), [firstID, secondID])
        XCTAssertEqual(firstStatus, SyncV2OperationStatus.cancelled.rawValue)
        XCTAssertEqual(secondStatus, SyncV2OperationStatus.pending.rawValue)
        XCTAssertEqual(claimed.map(\.operationID), [secondID])
        XCTAssertEqual(claimed.first?.baseRevision, 0)
        await store.close()
    }

    func testTrashPurgeWaitsForTombstoneAndMaterializesItsCommittedRevision()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let createID = UUID()
        let deleteID = UUID()
        let purgeOperationID = UUID()
        let purgeDocumentID = syncV2UUIDv5(
            namespace: context.serverProjectID,
            name: syncV2TrashPurgePath
        )

        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: createID),
                ]
            )
        )
        let createClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let create = try XCTUnwrap(createClaims.first)
        try await store.complete(create, result: commitResult(for: create))

        _ = try await store.enqueue(
            context.batch(
                kind: .trashChange,
                mutations: [
                    context.documentMutation(
                        operationID: deleteID,
                        content: "",
                        isDeleted: true,
                        generation: 2
                    ),
                ]
            )
        )
        let purgeContent = try SyncV2TrashPurgePayload(
            purgedRevisions: [context.documentID: 0],
            emptyGeneration: ""
        ).canonicalContent()
        _ = try await store.enqueue(
            context.batch(
                kind: .trashChange,
                mutations: [
                    context.documentMutation(
                        operationID: purgeOperationID,
                        documentID: purgeDocumentID,
                        relativePath: syncV2TrashPurgePath,
                        content: purgeContent,
                        generation: nil,
                        kind: .trashPurge
                    ),
                ]
            )
        )

        let beforeDelete = try await store.claimReadyOperations(
            limit: 5,
            now: Date(timeIntervalSince1970: 101)
        )
        XCTAssertEqual(beforeDelete.map(\.operationID), [deleteID])
        let deletion = try XCTUnwrap(beforeDelete.first)
        try await store.complete(
            deletion,
            result: commitResult(for: deletion)
        )

        let afterDelete = try await store.claimReadyOperations(
            limit: 5,
            now: Date(timeIntervalSince1970: 102)
        )
        let purge = try XCTUnwrap(afterDelete.first)
        XCTAssertEqual(purge.operationID, purgeOperationID)
        let materialized = try SyncV2TrashPurgePayload(
            strictContent: purge.content
        )
        XCTAssertEqual(materialized.purgedRevisions[context.documentID], 2)
        await store.close()
    }

    func testIndependentDocumentsEachStartAtSequenceOne()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let secondDocumentID = UUID()
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        let batch = context.batch(
            mutations: [
                context.documentMutation(
                    operationID: firstOperationID
                ),
                context.documentMutation(
                    operationID: secondOperationID,
                    documentID: secondDocumentID,
                    relativePath: "원고/1권/002화.txt"
                ),
            ]
        )

        let receipt = try await store.enqueue(batch)
        let first = try await store.queuedOperations(
            documentID: context.documentID
        )
        let second = try await store.queuedOperations(
            documentID: secondDocumentID
        )

        XCTAssertEqual(
            receipt.operationIDs,
            [firstOperationID, secondOperationID]
        )
        XCTAssertEqual(first.map(\.documentSequence), [1])
        XCTAssertEqual(second.map(\.documentSequence), [1])
        await store.close()
    }

    func testConcurrentEnqueueSerializesOneDocumentLane()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationIDs = (0..<32).map { _ in UUID() }
        let batches = operationIDs.enumerated().map { index, identifier in
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: identifier,
                        content: "동시 저장 \(index)",
                        generation: index
                    )
                ]
            )
        }

        try await withThrowingTaskGroup(
            of: SyncV2EnqueueReceipt.self
        ) { group in
            for batch in batches {
                group.addTask {
                    try await store.enqueue(batch)
                }
            }
            for try await receipt in group {
                XCTAssertEqual(receipt.operationIDs.count, 1)
            }
        }

        let queued = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(queued.count, operationIDs.count)
        XCTAssertEqual(
            queued.compactMap(\.documentSequence),
            Array(1...operationIDs.count)
        )
        XCTAssertEqual(
            Set(queued.map(\.operationID)),
            Set(operationIDs)
        )
        await store.close()
    }

    func testMultiOperationFailureRollsBackBatchDocumentAndSequence()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let reusedOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    .ensureProject(
                        SyncV2EnsureProjectMutation(
                            operationID: reusedOperationID,
                            projectName: "기존 operation"
                        )
                    )
                ]
            )
        )
        let failedBatchID = UUID()
        let failedDocumentID = UUID()
        let failed = context.batch(
            batchID: failedBatchID,
            mutations: [
                context.documentMutation(
                    operationID: UUID(),
                    documentID: failedDocumentID,
                    relativePath: "원고/실패.txt"
                ),
                .ensureProject(
                    SyncV2EnsureProjectMutation(
                        operationID: reusedOperationID,
                        projectName: "충돌 operation"
                    )
                ),
            ]
        )

        do {
            _ = try await store.enqueue(failed)
            XCTFail("The operation ID collision must roll back the batch.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2EnqueueError,
                .operationIDReused
            )
        }
        await store.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sync_batches
                WHERE batch_id = '\(failedBatchID.uuidString.lowercased())';
                """
            ),
            0
        )
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sync_documents
                WHERE document_id = '\(
                    failedDocumentID.uuidString.lowercased()
                )';
                """
            ),
            0
        )
        XCTAssertEqual(
            try raw.scalarInt("SELECT COUNT(*) FROM sync_operations;"),
            1
        )
    }

    func testQueueOrderAndOperationIDsSurviveReopen() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let first = try await connectedStore(at: url, context: context)
        let identifiers = [UUID(), UUID(), UUID()]
        for (index, identifier) in identifiers.enumerated() {
            _ = try await first.enqueue(
                context.batch(
                    mutations: [
                        context.documentMutation(
                            operationID: identifier,
                            content: "저장 \(index)",
                            generation: index
                        )
                    ]
                )
            )
        }
        await first.close()

        let reopened = try await openStore(at: url)
        let queued = try await reopened.queuedOperations(
            documentID: context.documentID
        )

        XCTAssertEqual(queued.map(\.operationID), identifiers)
        XCTAssertEqual(
            queued.map(\.documentSequence),
            [1, 2, 3]
        )
        XCTAssertTrue(queued.allSatisfy { $0.status == .pending })
        await reopened.close()
    }

    func testEnsureProjectUsesNoDocumentLaneAndPreservesOperationID()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        let batch = context.batch(
            kind: .projectBinding,
            mutations: [
                .ensureProject(
                    SyncV2EnsureProjectMutation(
                        operationID: operationID,
                        projectName: "변경된 작품 이름"
                    )
                )
            ]
        )

        let receipt = try await store.enqueue(batch)
        let queued = try await store.queuedOperations()
        let binding = try await store.binding(
            for: context.localProjectID
        )

        XCTAssertEqual(receipt.operationIDs, [operationID])
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued[0].operationID, operationID)
        XCTAssertNil(queued[0].documentID)
        XCTAssertNil(queued[0].documentSequence)
        XCTAssertEqual(queued[0].kind, .ensureProject)
        XCTAssertEqual(binding?.projectName, "변경된 작품 이름")
        await store.close()
    }

    func testDispatcherClaimPreservesDocumentFIFOAndPromotesNextRevision()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let firstID = UUID()
        let secondID = UUID()
        let otherID = UUID()
        let otherDocumentID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: firstID,
                        content: "첫 본문"
                    ),
                    context.documentMutation(
                        operationID: otherID,
                        documentID: otherDocumentID,
                        relativePath: "원고/1권/002화.txt",
                        content: "다른 문서"
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: secondID,
                        content: "둘째 본문",
                        generation: 2
                    ),
                ]
            )
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let firstClaim = try await store.claimReadyOperations(
            limit: 3,
            now: now
        )

        XCTAssertEqual(Set(firstClaim.map(\.operationID)), [firstID, otherID])
        XCTAssertFalse(firstClaim.contains { $0.operationID == secondID })
        let first = try XCTUnwrap(
            firstClaim.first { $0.operationID == firstID }
        )
        try await store.complete(
            first,
            result: commitResult(for: first)
        )

        let secondClaim = try await store.claimReadyOperations(
            limit: 3,
            now: now
        )
        let second = try XCTUnwrap(
            secondClaim.first { $0.operationID == secondID }
        )
        XCTAssertEqual(second.documentSequence, 2)
        XCTAssertEqual(second.baseRevision, 1)
        XCTAssertEqual(second.attempts, 1)
        await store.close()
    }

    func testDocumentNotFoundRecoveryRecreatesMissingServerBaseline()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "메인/원고/1권/001화.txt",
            content: "서버 기준",
            revision: 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        relativePath: "메인/원고/1권/001화.txt",
                        content: "복구할 최신 본문",
                        generation: 2
                    ),
                ]
            )
        )
        let firstClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let claimed = try XCTUnwrap(firstClaim.first)
        XCTAssertEqual(claimed.baseRevision, 1)

        try await store.recoverMissingRemoteDocument(claimed)

        let recreateClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21)
        )
        let recreated = try XCTUnwrap(recreateClaim.first)
        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertEqual(recreated.operationID, operationID)
        XCTAssertEqual(recreated.baseRevision, 0)
        XCTAssertEqual(recreated.baseContent, "")
        XCTAssertEqual(recreated.content, "복구할 최신 본문")
        XCTAssertEqual(
            recreated.relativePath,
            "메인/원고/1권/001화.txt"
        )
        XCTAssertEqual(state?.serverRevision, 0)
        XCTAssertEqual(state?.serverPath, "메인/원고/1권/001화.txt")
        await store.close()
    }

    func testMissingProjectRecoveryRequeuesUntouchedServerDocuments()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let untouchedDocumentID = UUID()
        let untouched = SyncV2RemoteDocumentSnapshot(
            documentID: untouchedDocumentID,
            relativePath: "메인/원고/1권/007화.txt",
            content: "서버 소실 전에 저장된 본문",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: untouched,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)

        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: UUID(),
                        relativePath: "메인/원고/1권/001화.txt",
                        content: "복구를 시작한 문서"
                    ),
                ]
            )
        )
        let triggerClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let trigger = try XCTUnwrap(triggerClaims.first)
        XCTAssertEqual(trigger.baseRevision, 0)

        try await store.recoverMissingRemoteProject(trigger)

        let recoveryClaims = try await store.claimReadyOperations(
            limit: 3,
            now: Date(timeIntervalSince1970: 21)
        )
        let recovery = try XCTUnwrap(recoveryClaims.first)
        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: untouchedDocumentID
        )
        XCTAssertEqual(recovery.documentID, untouchedDocumentID)
        XCTAssertEqual(recovery.baseRevision, 0)
        XCTAssertEqual(recovery.baseContent, "")
        XCTAssertEqual(recovery.content, "서버 소실 전에 저장된 본문")
        XCTAssertEqual(recovery.relativePath, "메인/원고/1권/007화.txt")
        XCTAssertEqual(state?.serverRevision, 0)
        XCTAssertEqual(state?.hasActiveOperation, true)
        await store.close()
    }

    /// Windows는 모든 server path를 NFC로 정규화해 보낸다. macOS 파일 이름은
    /// 한글 자모가 분리된 형태로 들어올 수 있으므로 iPad도 queue 입구에서 같은
    /// 정규화를 해야 서버 경로와 로컬 비교가 어긋나지 않는다. 디스크의 실제
    /// 이름인 local path는 정규화하면 파일을 찾지 못하므로 그대로 둔다.
    func testEnqueueCanonicalizesDecomposedHangulServerPathOnly()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let composed = "원고/1권/001화.txt"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertFalse(
            SyncV2ServerPath.hasExactBytes(decomposed, composed),
            "fixture가 실제로 분해된 형태여야 이 테스트가 의미를 갖는다."
        )
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        relativePath: decomposed
                    ),
                ]
            )
        )

        let claims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let claimed = try XCTUnwrap(claims.first)
        XCTAssertTrue(
            SyncV2ServerPath.hasExactBytes(
                claimed.relativePath,
                composed
            ),
            "서버로 나가는 경로는 NFC여야 한다."
        )
        XCTAssertTrue(
            SyncV2ServerPath.hasExactBytes(
                claimed.localPath,
                "/fixture/\(decomposed)"
            ),
            "로컬 파일 경로는 디스크 이름 그대로여야 한다."
        )
        await store.close()
    }

    /// 구버전에서 DOCUMENT_ALREADY_EXISTS로 굳은 operation은 사용자에게 보이는
    /// 충돌 목록에 없고 재시도 대상도 아니라 영구 정지로 남는다. 시작 시 복구가
    /// 이를 다시 대기열에 세워야 자동 rebase 경로를 탈 수 있다. 서버가 이미 최신
    /// 문서를 갖고 있으므로 DOCUMENT_NOT_FOUND 복구와 달리 기준선을 0으로
    /// 되돌리지 않고 그대로 두어 서버가 알려준 revision으로 맞추게 한다.
    func testLaunchRecoveryRequeuesPersistedDocumentAlreadyExistsConflict()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "",
            revision: 2,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "이미 있는 문서에 얹을 저장",
                        generation: 1
                    ),
                ]
            )
        )
        let claims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let claimed = try XCTUnwrap(claims.first)
        try await store.markConflict(
            claimed,
            errorCode: "DOCUMENT_ALREADY_EXISTS",
            detail: nil
        )
        let blockedClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21)
        )
        XCTAssertTrue(blockedClaims.isEmpty)

        try await store.recoverInterruptedWork()

        let recoveredClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 22)
        )
        let recovered = try XCTUnwrap(recoveredClaims.first)
        XCTAssertEqual(recovered.operationID, operationID)
        XCTAssertEqual(recovered.content, "이미 있는 문서에 얹을 저장")
        XCTAssertEqual(recovered.baseRevision, 2)
        await store.close()
    }

    func testLaunchRecoveryUnblocksPersistedDocumentNotFoundConflict()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "",
            revision: 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let firstID = UUID()
        let secondID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: firstID,
                        content: "첫 저장",
                        generation: 1
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: secondID,
                        content: "더 최신 저장",
                        generation: 2
                    ),
                ]
            )
        )
        let firstClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let first = try XCTUnwrap(firstClaim.first)
        try await store.markConflict(
            first,
            errorCode: "DOCUMENT_NOT_FOUND",
            detail: nil
        )

        try await store.recoverInterruptedWork()

        let recoveredClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21)
        )
        let recovered = try XCTUnwrap(recoveredClaim.first)
        XCTAssertEqual(recovered.operationID, firstID)
        XCTAssertEqual(recovered.baseRevision, 0)
        try await store.markBlocked(
            recovered,
            errorCode: "FORBIDDEN",
            detail: nil
        )

        try await store.recoverInterruptedWork()

        let projectRecoveryClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21.5)
        )
        let projectRecovered = try XCTUnwrap(
            projectRecoveryClaim.first
        )
        XCTAssertEqual(projectRecovered.operationID, firstID)
        XCTAssertEqual(projectRecovered.baseRevision, 0)
        try await store.complete(
            projectRecovered,
            result: commitResult(for: projectRecovered)
        )
        let nextClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 22)
        )
        let next = try XCTUnwrap(nextClaim.first)
        XCTAssertEqual(next.operationID, secondID)
        XCTAssertEqual(next.baseRevision, 1)
        XCTAssertEqual(next.content, "더 최신 저장")
        await store.close()
    }

    func testForbiddenUpdateLaneRecoversOnLaunchAndExplicitRetry()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/006화.txt",
            content: "서버 기준본",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let firstID = UUID()
        let secondID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: firstID,
                        content: "오프라인 첫 저장",
                        generation: 1
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: secondID,
                        content: "오프라인 최신 저장",
                        generation: 2
                    ),
                ]
            )
        )
        let firstClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let first = try XCTUnwrap(firstClaims.first)
        XCTAssertEqual(first.baseRevision, 3)
        try await store.markBlocked(
            first,
            errorCode: "FORBIDDEN",
            detail: nil
        )
        let blockedState = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertEqual(blockedState?.blockingErrorCode, "FORBIDDEN")

        try await store.recoverInterruptedWork()

        let launchClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21)
        )
        let launchRecovered = try XCTUnwrap(launchClaims.first)
        XCTAssertEqual(launchRecovered.operationID, firstID)
        XCTAssertEqual(launchRecovered.baseRevision, 3)
        XCTAssertEqual(launchRecovered.content, "오프라인 첫 저장")
        try await store.markBlocked(
            launchRecovered,
            errorCode: "FORBIDDEN",
            detail: nil
        )

        try await store.makeRetryWaitOperationsReady()

        let retryClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 22)
        )
        let explicitlyRecovered = try XCTUnwrap(retryClaims.first)
        XCTAssertEqual(explicitlyRecovered.operationID, firstID)
        XCTAssertEqual(explicitlyRecovered.baseRevision, 3)
        XCTAssertEqual(explicitlyRecovered.content, "오프라인 첫 저장")
        try await store.complete(
            explicitlyRecovered,
            result: commitResult(for: explicitlyRecovered)
        )
        let nextClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 23)
        )
        let next = try XCTUnwrap(nextClaims.first)
        XCTAssertEqual(next.operationID, secondID)
        XCTAssertEqual(next.baseRevision, 4)
        XCTAssertEqual(next.content, "오프라인 최신 저장")
        await store.close()
    }

    func testLaunchRecoveryRequeuesPersistedLeaseConflictWithoutDataLoss()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "마지막 서버 기준본\n",
            revision: 5,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        let localContent = "잠금 중 저장된 iPad 로컬 본문 📝\n"
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: localContent,
                        generation: 6
                    ),
                ]
            )
        )
        let firstClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let first = try XCTUnwrap(firstClaims.first)
        try await store.markConflict(
            first,
            errorCode: "LEASE_CONFLICT",
            detail: #"{"expires_at":"2030-01-02T03:04:05Z"}"#
        )
        await store.close()

        let reopened = try await openStore(at: url)
        let restoredOperations = try await reopened.queuedOperations(
            documentID: context.documentID
        )
        let restored = try XCTUnwrap(
            restoredOperations.first { $0.operationID == operationID }
        )
        let state = try await reopened.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )

        XCTAssertEqual(restored.status, .pending)
        XCTAssertEqual(restored.baseRevision, Int(baseline.revision))
        XCTAssertEqual(restored.content, localContent)
        XCTAssertEqual(restored.relativePath, baseline.relativePath)
        XCTAssertTrue(state?.hasActiveOperation == true)
        XCTAssertFalse(state?.hasUnresolvedConflict == true)

        let retryClaims = try await reopened.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 21)
        )
        let retry = try XCTUnwrap(retryClaims.first)
        XCTAssertEqual(retry.operationID, operationID)
        XCTAssertEqual(retry.baseRevision, baseline.revision)
        XCTAssertEqual(retry.baseContent, baseline.content)
        XCTAssertEqual(retry.content, localContent)
        await reopened.close()
    }

    func testManualRetryRequeuesAllPersistedLeaseErrorKinds()
        async throws {
        let errorCodes = [
            "LEASE_REQUIRED",
            "LEASE_CONFLICT",
            "LEASE_EXPIRED",
        ]
        for (index, errorCode) in errorCodes.enumerated() {
            let url = try databaseURL()
            let context = QueueAPIContext()
            let store = try await connectedStore(
                at: url,
                context: context
            )
            let baseline = SyncV2RemoteDocumentSnapshot(
                documentID: context.documentID,
                relativePath: "원고/1권/\(index).txt",
                content: "기준 \(index)",
                revision: 1,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 10)
            )
            _ = try await store.applySnapshotBaseline(
                localProjectID: context.localProjectID,
                serverProjectID: context.serverProjectID,
                snapshot: baseline,
                expectedRevision: nil
            )
            let operationID = UUID()
            _ = try await store.enqueue(
                context.batch(
                    mutations: [
                        context.documentMutation(
                            operationID: operationID,
                            relativePath: baseline.relativePath,
                            content: "로컬 \(index)"
                        ),
                    ]
                )
            )
            let claims = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 20)
            )
            let claimed = try XCTUnwrap(claims.first)
            try await store.markConflict(
                claimed,
                errorCode: errorCode,
                detail: nil
            )

            try await store.makeRetryWaitOperationsReady()

            let retryClaims = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 21)
            )
            let retry = try XCTUnwrap(retryClaims.first)
            XCTAssertEqual(retry.operationID, operationID, errorCode)
            XCTAssertEqual(retry.content, "로컬 \(index)", errorCode)
            await store.close()
        }
    }

    func testRetryWaitHonorsDueTimeAndImmediateOpportunity() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: operationID),
                ]
            )
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstClaim = try await store.claimReadyOperations(
            limit: 1,
            now: now
        )
        let first = try XCTUnwrap(firstClaim.first)
        let scheduled = now.addingTimeInterval(120)
        try await store.deferRetry(
            first,
            errorCode: "NETWORK_UNAVAILABLE",
            detail: nil,
            nextAttemptAt: scheduled
        )

        let tooEarly = try await store.claimReadyOperations(
            limit: 1,
            now: now.addingTimeInterval(60)
        )
        let storedRetryDate = try await store.nextRetryDate()
        let nextRetry = try XCTUnwrap(storedRetryDate)
        XCTAssertTrue(tooEarly.isEmpty)
        XCTAssertEqual(
            nextRetry.timeIntervalSince1970,
            scheduled.timeIntervalSince1970,
            accuracy: 0.001
        )

        try await store.makeRetryWaitOperationsReady()
        let retryClaim = try await store.claimReadyOperations(
            limit: 1,
            now: now.addingTimeInterval(60)
        )
        let retried = try XCTUnwrap(retryClaim.first)
        XCTAssertEqual(retried.operationID, operationID)
        XCTAssertEqual(retried.attempts, 2)
        await store.close()
    }

    func testDispatcherClaimIsScopedToOneProjectLane() async throws {
        let url = try databaseURL()
        let firstContext = QueueAPIContext()
        let secondContext = QueueAPIContext()
        let store = try await openStore(at: url)
        try await store.save(firstContext.binding)
        try await store.save(secondContext.binding)
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        _ = try await store.enqueue(
            firstContext.batch(
                mutations: [
                    firstContext.documentMutation(
                        operationID: firstOperationID
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            secondContext.batch(
                mutations: [
                    secondContext.documentMutation(
                        operationID: secondOperationID
                    ),
                ]
            )
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let readyProjectIDs = try await store.readyLocalProjectIDs(
            now: now
        )
        let bindingStore: any ProjectBindingStoring = store
        let bindings = try await bindingStore.allBindings()
        let firstClaim = try await store.claimReadyOperations(
            localProjectID: firstContext.localProjectID,
            limit: 3,
            now: now
        )

        XCTAssertEqual(
            Set(readyProjectIDs),
            [firstContext.localProjectID, secondContext.localProjectID]
        )
        XCTAssertEqual(
            Set(bindings.map(\.localProjectID)),
            [firstContext.localProjectID, secondContext.localProjectID]
        )
        XCTAssertEqual(firstClaim.map(\.operationID), [firstOperationID])
        let remaining = try await store.claimReadyOperations(
            localProjectID: secondContext.localProjectID,
            limit: 3,
            now: now
        )
        XCTAssertEqual(remaining.map(\.operationID), [secondOperationID])
        await store.close()
    }

    func testAutomaticRebaseAtomicallyPromotesLatestGenerationAndCancelsDependents()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let documentID = UUID()
        let deviceID = UUID()
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .existingServerProject,
                projectName: "automatic rebase",
                ownerSubject: UUID()
            )
        )
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: documentID,
            relativePath: "메인/1권/001화.txt",
            content: "공통\n둘째\n셋째\n",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let firstID = UUID()
        let latestID = UUID()
        let advancedID = UUID()
        func mutation(
            operationID: UUID,
            generation: Int,
            content: String
        ) -> SyncV2Mutation {
            .document(
                SyncV2DocumentMutation(
                    operationID: operationID,
                    documentID: documentID,
                    deviceID: deviceID,
                    localSaveGeneration: generation,
                    kind: .documentCommit,
                    localPath: baseline.relativePath,
                    relativePath: baseline.relativePath,
                    content: content,
                    isDeleted: false
                )
            )
        }
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .documentSave,
                mutations: [
                    mutation(
                        operationID: firstID,
                        generation: 5,
                        content: "로컬 1\n둘째\n셋째\n"
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .documentSave,
                mutations: [
                    mutation(
                        operationID: latestID,
                        generation: 8,
                        content: "로컬 최신\n둘째\n셋째\n"
                    ),
                ]
            )
        )
        let claimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let claimed = try XCTUnwrap(claimedOperations.first)
        let staleLocal = try await store.latestLocalSnapshot(for: claimed)
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .documentSave,
                mutations: [
                    mutation(
                        operationID: advancedID,
                        generation: 9,
                        content: "병합 중 최신 입력\n둘째\n셋째\n"
                    ),
                ]
            )
        )
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: documentID,
            relativePath: "메인/1권/서버이름.txt",
            content: "공통\n둘째\n서버 셋째\n",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        let staleResult = try await store.rebaseAfterRevisionConflict(
            claimed,
            remote: remote,
            local: staleLocal,
            mergedContent: "사용하면 안 되는 오래된 병합\n",
            mergedPath: remote.relativePath
        )
        XCTAssertEqual(staleResult, .localGenerationAdvanced)
        let reclaimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 41)
        )
        let reclaimed = try XCTUnwrap(reclaimedOperations.first)
        let latest = try await store.latestLocalSnapshot(for: reclaimed)

        let result: SyncV2AutomaticRebaseStoreResult
        do {
            result = try await store.rebaseAfterRevisionConflict(
                reclaimed,
                remote: remote,
                local: latest,
                mergedContent: "병합 중 최신 입력\n둘째\n서버 셋째\n",
                mergedPath: remote.relativePath
            )
        } catch {
            XCTFail("rebase transaction failed: \(String(reflecting: error))")
            await store.close()
            return
        }
        let operations = try await store.queuedOperations(
            documentID: documentID
        )
        let rebased = try XCTUnwrap(
            operations.first { $0.operationID == firstID }
        )
        let cancelled = try XCTUnwrap(
            operations.first { $0.operationID == latestID }
        )
        let advanced = try XCTUnwrap(
            operations.first { $0.operationID == advancedID }
        )
        let state = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: documentID
        )

        XCTAssertEqual(result, .rebased)
        XCTAssertEqual(rebased.status, .pending)
        XCTAssertEqual(rebased.baseRevision, 4)
        XCTAssertEqual(
            rebased.content,
            "병합 중 최신 입력\n둘째\n서버 셋째\n"
        )
        XCTAssertEqual(rebased.relativePath, remote.relativePath)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(advanced.status, .cancelled)
        XCTAssertEqual(state?.serverRevision, 4)
        XCTAssertEqual(state?.serverPath, remote.relativePath)
        await store.close()
    }

    func testConflictSnapshotPersistsAllSourcesAcrossReopen()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "공통 문장\n",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "내 문장\n",
                        generation: 4
                    ),
                ]
            )
        )
        let claimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let claimed = try XCTUnwrap(claimedOperations.first)
        let local = try await store.latestLocalSnapshot(for: claimed)
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/서버제목.txt",
            content: "서버 문장\n",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let merge = ThreeWayMerge.merge(
            base: claimed.baseContent,
            local: local.content,
            remote: remote.content
        )
        XCTAssertTrue(merge.hasConflicts)

        let result = try await store.preserveConflict(
            claimed,
            remote: remote,
            local: local,
            mergedContent: merge.content,
            conflictCount: merge.conflictCount,
            errorCode: "REVISION_CONFLICT",
            detail: "본문 충돌"
        )
        XCTAssertEqual(result, .preserved)
        await store.close()

        let reopened = try await openStore(at: url)
        let restoredConflict = try await reopened.unresolvedConflict(
            documentID: context.documentID
        )
        let conflict = try XCTUnwrap(restoredConflict)
        let restoredOperations = try await reopened.queuedOperations(
            documentID: context.documentID
        )
        let queued = try XCTUnwrap(
            restoredOperations.first { $0.operationID == operationID }
        )
        let state = try await reopened.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )

        XCTAssertEqual(conflict.operationID, operationID)
        XCTAssertEqual(conflict.documentID, context.documentID)
        XCTAssertEqual(conflict.snapshot.baseContent, baseline.content)
        XCTAssertEqual(conflict.snapshot.localContent, "내 문장\n")
        XCTAssertEqual(conflict.snapshot.remoteContent, "서버 문장\n")
        XCTAssertEqual(conflict.snapshot.mergedContent, merge.content)
        XCTAssertEqual(conflict.snapshot.remoteRevision, 4)
        XCTAssertEqual(
            conflict.snapshot.remotePath,
            "원고/1권/서버제목.txt"
        )
        XCTAssertEqual(
            conflict.snapshot.conflictCount,
            merge.conflictCount
        )
        XCTAssertEqual(queued.status, .conflict)
        XCTAssertTrue(state?.hasUnresolvedConflict == true)
        XCTAssertEqual(state?.serverRevision, 4)
        XCTAssertEqual(state?.serverPath, remote.relativePath)
        await reopened.close()
    }

    func testConflictSnapshotPreservesUnicodeEmptyContentAndNewlinesExactly()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseContent = "기준 한글 🧑‍💻\n\n"
        let localContent = ""
        let remoteContent = "서버 원본 🚀\n마지막 개행 없음"
        let mergedContent = ThreeWayMerge.merge(
            base: baseContent,
            local: localContent,
            remote: remoteContent
        ).content
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/한글 📝/빈 문서.txt",
            content: baseContent,
            revision: 7,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 70)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: localContent,
                        generation: 8
                    ),
                ]
            )
        )
        let claimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 80)
        )
        let claimed = try XCTUnwrap(claimedOperations.first)
        let local = try await store.latestLocalSnapshot(for: claimed)
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/한글 📝/서버 이름.txt",
            content: remoteContent,
            revision: 8,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 90)
        )

        let preservationResult = try await store.preserveConflict(
            claimed,
            remote: remote,
            local: local,
            mergedContent: mergedContent,
            conflictCount: 1,
            errorCode: "REVISION_CONFLICT",
            detail: "특수 문자열 보존"
        )
        XCTAssertEqual(preservationResult, .preserved)
        await store.close()

        let reopened = try await openStore(at: url)
        let restoredConflict = try await reopened.unresolvedConflict(
            documentID: context.documentID
        )
        let conflict = try XCTUnwrap(restoredConflict)

        XCTAssertEqual(conflict.operationID, operationID)
        XCTAssertEqual(conflict.snapshot.baseContent, baseContent)
        XCTAssertEqual(conflict.snapshot.localContent, localContent)
        XCTAssertEqual(conflict.snapshot.remoteContent, remoteContent)
        XCTAssertEqual(conflict.snapshot.mergedContent, mergedContent)
        XCTAssertEqual(conflict.snapshot.remoteRevision, remote.revision)
        XCTAssertEqual(conflict.snapshot.remotePath, remote.relativePath)
        XCTAssertEqual(conflict.snapshot.conflictCount, 1)
        XCTAssertGreaterThan(
            conflict.createdAt,
            Date(timeIntervalSince1970: 0)
        )
        await reopened.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT resolved_at IS NULL AND resolution_kind IS NULL
                FROM sync_conflicts
                WHERE operation_id =
                    '\(operationID.uuidString.lowercased())';
                """
            ),
            1
        )
    }

    func testConflictPreservationFailureRollsBackEveryRelatedChange()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "기준\n",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let baselineApplied = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        XCTAssertTrue(baselineApplied)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "로컬\n",
                        generation: 4
                    ),
                ]
            )
        )
        let claimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let claimed = try XCTUnwrap(claimedOperations.first)
        let local = try await store.latestLocalSnapshot(for: claimed)
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/서버 제목.txt",
            content: "서버\n",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            CREATE TRIGGER inject_conflict_preservation_failure
            BEFORE INSERT ON sync_conflicts
            BEGIN
                SELECT RAISE(ABORT, 'injected conflict preservation failure');
            END;
            """
        )
        raw.close()

        do {
            _ = try await store.preserveConflict(
                claimed,
                remote: remote,
                local: local,
                mergedContent: "저장되면 안 되는 병합 결과",
                conflictCount: 1,
                errorCode: "REVISION_CONFLICT",
                detail: "실패 주입"
            )
            XCTFail("주입된 INSERT 실패가 transaction을 중단해야 합니다.")
        } catch {
            // 기대한 실패다. 아래에서 관련 row 전체가 rollback됐는지 검증한다.
        }

        let operations = try await store.queuedOperations(
            documentID: context.documentID
        )
        let operation = try XCTUnwrap(
            operations.first { $0.operationID == operationID }
        )
        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertEqual(operation.status, .inflight)
        let unresolvedConflict = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        XCTAssertNil(unresolvedConflict)
        XCTAssertEqual(state?.serverRevision, baseline.revision)
        XCTAssertEqual(state?.serverPath, baseline.relativePath)
        XCTAssertFalse(state?.hasUnresolvedConflict == true)
        await store.close()

        let check = try RawSQLite(url: url)
        XCTAssertEqual(
            try check.scalarInt("SELECT COUNT(*) FROM sync_conflicts;"),
            0
        )
        XCTAssertEqual(
            try check.scalarText(
                """
                SELECT sync_state FROM sync_documents
                WHERE document_id =
                    '\(context.documentID.uuidString.lowercased())';
                """
            ),
            "pending"
        )
    }

    func testConflictSnapshotRejectsStaleLocalGeneration()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "공통 문장\n",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        _ = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "이전 로컬\n",
                        generation: 4
                    ),
                ]
            )
        )
        let claimedOperations = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let claimed = try XCTUnwrap(claimedOperations.first)
        let staleLocal = try await store.latestLocalSnapshot(for: claimed)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: UUID(),
                        content: "병합 중 새로 입력한 로컬\n",
                        generation: 5
                    ),
                ]
            )
        )
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: baseline.relativePath,
            content: "서버 문장\n",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        let result = try await store.preserveConflict(
            claimed,
            remote: remote,
            local: staleLocal,
            mergedContent: "오래되어 저장하면 안 되는 병합 결과",
            conflictCount: 1,
            errorCode: "REVISION_CONFLICT",
            detail: "본문 충돌"
        )
        let conflict = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        let operations = try await store.queuedOperations(
            documentID: context.documentID
        )

        XCTAssertEqual(result, .localGenerationAdvanced)
        XCTAssertNil(conflict)
        XCTAssertEqual(
            operations.first { $0.operationID == operationID }?.status,
            .pending
        )
        XCTAssertTrue(operations.allSatisfy { $0.status != .conflict })
        await store.close()
    }

    func testConflictResolutionPersistsHistoryAndRemoteBaseAcrossReopen()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let conflict = try await preserveConflictForResolution(
            in: store,
            context: context
        )
        let resolvedContent = "내 문장과 서버 문장을 직접 정리한 최종본🙂\n"
        let resolutionOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: resolutionOperationID,
                        content: resolvedContent,
                        generation: 5
                    ),
                ]
            )
        )

        try await store.resolveConflict(
            SyncV2ConflictResolutionRequest(
                conflictID: conflict.conflictID,
                documentID: context.documentID,
                resolutionOperationID: resolutionOperationID,
                resolvedContent: resolvedContent,
                kind: .manualMerge
            )
        )
        let unresolvedAfterResolution = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        XCTAssertNil(unresolvedAfterResolution)
        let operations = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == conflict.operationID
            }?.status,
            .cancelled
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == resolutionOperationID
            }?.status,
            .pending
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == resolutionOperationID
            }?.baseRevision,
            Int(conflict.snapshot.remoteRevision)
        )
        await store.close()

        let history = try RawSQLite(url: url)
        XCTAssertEqual(
            try history.scalarText(
                """
                SELECT resolution_kind
                FROM sync_conflicts
                WHERE conflict_id =
                    '\(conflict.conflictID.uuidString.lowercased())';
                """
            ),
            SyncV2ConflictResolutionKind.manualMerge.rawValue
        )
        XCTAssertEqual(
            try history.scalarInt(
                """
                SELECT resolved_at IS NOT NULL
                FROM sync_conflicts
                WHERE conflict_id =
                    '\(conflict.conflictID.uuidString.lowercased())';
                """
            ),
            1
        )
        history.close()

        let reopened = try await openStore(at: url)
        let reopenedConflict = try await reopened.unresolvedConflict(
            documentID: context.documentID
        )
        XCTAssertNil(reopenedConflict)
        let reopenedReady = try await reopened.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let claimed = try XCTUnwrap(reopenedReady.first)
        XCTAssertEqual(claimed.operationID, resolutionOperationID)
        XCTAssertEqual(
            claimed.baseRevision,
            conflict.snapshot.remoteRevision
        )
        XCTAssertEqual(
            claimed.baseContent,
            conflict.snapshot.remoteContent
        )
        XCTAssertEqual(claimed.content, resolvedContent)
        await reopened.close()
    }

    func testConflictResolutionTransactionFailureLeavesConflictOpen()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let conflict = try await preserveConflictForResolution(
            in: store,
            context: context
        )
        let resolutionOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: resolutionOperationID,
                        content: conflict.snapshot.localContent,
                        generation: 5
                    ),
                ]
            )
        )
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            CREATE TRIGGER inject_conflict_resolution_failure
            BEFORE UPDATE OF resolved_at ON sync_conflicts
            WHEN NEW.resolved_at IS NOT NULL
            BEGIN
                SELECT RAISE(ABORT, 'injected conflict resolution failure');
            END;
            """
        )
        raw.close()

        do {
            try await store.resolveConflict(
                SyncV2ConflictResolutionRequest(
                    conflictID: conflict.conflictID,
                    documentID: context.documentID,
                    resolutionOperationID: resolutionOperationID,
                    resolvedContent: conflict.snapshot.localContent,
                    kind: .keepLocal
                )
            )
            XCTFail("주입된 오류가 해결 transaction을 중단해야 합니다.")
        } catch {
            // 기대한 실패다.
        }

        let unresolvedAfterFailure = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        XCTAssertNotNil(unresolvedAfterFailure)
        let operations = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == conflict.operationID
            }?.status,
            .conflict
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == resolutionOperationID
            }?.status,
            .pending
        )
        XCTAssertNil(
            operations.first {
                $0.operationID == resolutionOperationID
            }?.baseRevision
        )
        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertTrue(state?.hasUnresolvedConflict == true)
        await store.close()
    }

    func testConflictResolutionRejectsOperationSupersededByNewerSave()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let conflict = try await preserveConflictForResolution(
            in: store,
            context: context
        )
        let staleOperationID = UUID()
        let latestOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: staleOperationID,
                        content: "오래된 해결 후보",
                        generation: 5
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: latestOperationID,
                        content: "최신 해결 후보",
                        generation: 6
                    ),
                ]
            )
        )

        do {
            try await store.resolveConflict(
                SyncV2ConflictResolutionRequest(
                    conflictID: conflict.conflictID,
                    documentID: context.documentID,
                    resolutionOperationID: staleOperationID,
                    resolvedContent: "오래된 해결 후보",
                    kind: .manualMerge
                )
            )
            XCTFail("최신 저장보다 오래된 해결 operation은 거부해야 합니다.")
        } catch let error as SyncV2ConflictResolutionError {
            XCTAssertEqual(error, .resolutionOperationNotReady)
        }
        let unresolvedAfterStale = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        XCTAssertNotNil(unresolvedAfterStale)
        let operations = try await store.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == staleOperationID
            }?.status,
            .pending
        )
        XCTAssertEqual(
            operations.first {
                $0.operationID == latestOperationID
            }?.status,
            .pending
        )
        await store.close()
    }

    func testSnapshotBaselineUsesRevisionCASAndRejectsOccupiedPath()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .existingServerProject,
                projectName: "snapshot",
                ownerSubject: UUID()
            )
        )
        let first = SyncV2RemoteDocumentSnapshot(
            documentID: UUID(),
            relativePath: "메인/1권/001화.txt",
            content: "서버 1",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        let inserted = try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: first,
            expectedRevision: nil
        )
        let state = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: first.documentID
        )
        XCTAssertTrue(inserted)
        XCTAssertEqual(state?.serverRevision, 3)
        XCTAssertEqual(state?.serverPath, first.relativePath)

        let staleCAS = try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: SyncV2RemoteDocumentSnapshot(
                documentID: first.documentID,
                relativePath: first.relativePath,
                content: "서버 2",
                revision: 4,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 40)
            ),
            expectedRevision: 2
        )
        XCTAssertFalse(staleCAS)

        let occupied = try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: SyncV2RemoteDocumentSnapshot(
                documentID: UUID(),
                relativePath: first.relativePath,
                content: "다른 UUID",
                revision: 1,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 50)
            ),
            expectedRevision: nil
        )
        XCTAssertFalse(occupied)
        await store.close()
    }

    func testSnapshotStateAndCASBlockPendingDocumentOperation()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let documentID = UUID()
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .existingServerProject,
                projectName: "pending",
                ownerSubject: UUID()
            )
        )
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: nil,
                kind: .documentSave,
                mutations: [
                    .document(
                        SyncV2DocumentMutation(
                            operationID: UUID(),
                            documentID: documentID,
                            deviceID: UUID(),
                            localSaveGeneration: 1,
                            kind: .documentCommit,
                            localPath: "메인/1권/001화.txt",
                            relativePath: "메인/1권/001화.txt",
                            content: "로컬 대기",
                            isDeleted: false
                        )
                    ),
                ]
            )
        )

        let state = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: documentID
        )
        XCTAssertTrue(state?.hasActiveOperation == true)
        let applied = try await store.applySnapshotBaseline(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            snapshot: SyncV2RemoteDocumentSnapshot(
                documentID: documentID,
                relativePath: "메인/1권/001화.txt",
                content: "원격",
                revision: 1,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 60)
            ),
            expectedRevision: 0
        )
        XCTAssertFalse(applied)
        await store.close()
    }

    private func commitResult(
        for operation: SyncV2DispatchOperation
    ) -> SyncV2CommitDocumentResult {
        SyncV2CommitDocumentResult(
            status: .committed,
            documentID: operation.documentID,
            versionID: UUID(),
            operationID: operation.operationID,
            operationKind: operation.baseRevision == 0 ? .create : .update,
            serverRevision: operation.baseRevision + 1,
            relativePath: operation.relativePath,
            isDeleted: operation.isDeleted,
            contentHash: SHA256ContentHasher()
                .sha256(for: Data(operation.content.utf8))
                .rawValue,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }

    private func databaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-10-1-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("sync-v2.sqlite3")
    }

    private func openStore(at url: URL) async throws -> SyncV2Store {
        switch await SyncV2Store.open(at: url) {
        case .available(let store):
            return store
        case .unavailable(let diagnostic):
            XCTFail("SyncV2Store open failed: \(diagnostic)")
            throw TestFailure.openFailed
        }
    }

    private func connectedStore(
        at url: URL,
        context: QueueAPIContext
    ) async throws -> SyncV2Store {
        let store = try await openStore(at: url)
        try await store.save(context.binding)
        return store
    }

    private func preserveConflictForResolution(
        in store: SyncV2Store,
        context: QueueAPIContext
    ) async throws -> SyncV2ConflictRecord {
        let baseline = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/001화.txt",
            content: "공통 문장\n",
            revision: 3,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        _ = try await store.applySnapshotBaseline(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            snapshot: baseline,
            expectedRevision: nil
        )
        let conflictOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: conflictOperationID,
                        content: "내 문장\n",
                        generation: 4
                    ),
                ]
            )
        )
        let ready = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let claimed = try XCTUnwrap(ready.first)
        let local = try await store.latestLocalSnapshot(for: claimed)
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: "원고/1권/서버 제목.txt",
            content: "서버 문장\n",
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let merge = ThreeWayMerge.merge(
            base: claimed.baseContent,
            local: local.content,
            remote: remote.content
        )
        _ = try await store.preserveConflict(
            claimed,
            remote: remote,
            local: local,
            mergedContent: merge.content,
            conflictCount: merge.conflictCount,
            errorCode: "REVISION_CONFLICT",
            detail: "본문 충돌"
        )
        let conflict = try await store.unresolvedConflict(
            documentID: context.documentID
        )
        return try XCTUnwrap(conflict)
    }

    private func unavailableDiagnostic(
        at url: URL
    ) async -> SyncV2StoreDiagnostic {
        switch await SyncV2Store.open(at: url) {
        case .available(let store):
            await store.close()
            XCTFail("Store unexpectedly opened.")
            return SyncV2StoreDiagnostic(
                reason: .databaseOpenFailed,
                sqliteCode: nil,
                schemaVersion: nil
            )
        case .unavailable(let diagnostic):
            return diagnostic
        }
    }
}

private enum TestFailure: Error {
    case openFailed
}

private struct QueueAPIContext {
    let localProjectID = ProjectID(rawValue: UUID())
    let serverProjectID = UUID()
    let ownerSubject = UUID()
    let deviceID = UUID()
    let documentID = UUID()

    var binding: ProjectSyncBinding {
        .connected(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: .newServerProject,
            projectName: "10-2 fixture",
            ownerSubject: ownerSubject
        )
    }

    func batch(
        batchID: UUID = UUID(),
        kind: SyncV2BatchKind = .documentSave,
        mutations: [SyncV2Mutation]
    ) -> SyncV2EnqueueBatch {
        SyncV2EnqueueBatch(
            batchID: batchID,
            localProjectID: localProjectID,
            localTransactionID: UUID(),
            kind: kind,
            mutations: mutations
        )
    }

    func documentMutation(
        operationID: UUID,
        documentID: UUID? = nil,
        relativePath: String = "원고/1권/001화.txt",
        content: String = "본문",
        isDeleted: Bool = false,
        generation: Int? = 1,
        kind: SyncV2OperationKind = .documentCommit
    ) -> SyncV2Mutation {
        .document(
            SyncV2DocumentMutation(
                operationID: operationID,
                documentID: documentID ?? self.documentID,
                deviceID: deviceID,
                localSaveGeneration: generation,
                kind: kind,
                localPath: "/fixture/\(relativePath)",
                relativePath: relativePath,
                content: content,
                isDeleted: isDeleted
            )
        )
    }
}

private final class RawSQLite {
    private var database: OpaquePointer?

    init(url: URL) throws {
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, database != nil else {
            throw RawSQLiteError(code: status)
        }
        sqlite3_extended_result_codes(database, 1)
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        close()
    }

    func close() {
        guard let database else { return }
        sqlite3_close_v2(database)
        self.database = nil
    }

    func execute(_ sql: String) throws {
        guard let database else {
            throw RawSQLiteError(code: SQLITE_MISUSE)
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(
            database,
            sql,
            nil,
            nil,
            &errorMessage
        )
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw RawSQLiteError(
                code: sqlite3_extended_errcode(database)
            )
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        Int(try scalarInt64(sql))
    }

    func scalarText(_ sql: String) throws -> String {
        guard let database else {
            throw RawSQLiteError(code: SQLITE_MISUSE)
        }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else {
            throw RawSQLiteError(
                code: sqlite3_extended_errcode(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else {
            throw RawSQLiteError(
                code: sqlite3_extended_errcode(database)
            )
        }
        return String(cString: value)
    }

    private func scalarInt64(_ sql: String) throws -> Int64 {
        guard let database else {
            throw RawSQLiteError(code: SQLITE_MISUSE)
        }
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
            let statement
        else {
            throw RawSQLiteError(
                code: sqlite3_extended_errcode(database)
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RawSQLiteError(
                code: sqlite3_extended_errcode(database)
            )
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private struct RawSQLiteError: Error {
    let code: Int32
}

private actor InitialSnapshotDocumentRepository: DocumentRepository {
    private var nodes: [DocumentNode]

    init(_ nodes: [DocumentNode]) {
        self.nodes = nodes
    }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        nodes.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        nodes.first { $0.id == id }
    }

    func save(_ document: DocumentNode) async throws {
        nodes.removeAll { $0.id == document.id }
        nodes.append(document)
    }

    func removeMetadata(id: DocumentID) async throws {
        nodes.removeAll { $0.id == id }
    }
}

private actor DispatchWakeupCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct QueueFixture {
    let localProjectID = UUID()
    let serverProjectID = UUID()
    let ownerSubject = UUID()
    let documentID = UUID()
    let batchID = UUID()
    let operationID = UUID()

    var insertProjectSQL: String {
        """
        INSERT INTO sync_projects(
            local_project_id, server_project_id, binding_kind,
            project_name, owner_subject, created_at, updated_at
        ) VALUES (
            '\(id(localProjectID))', '\(id(serverProjectID))',
            'new_server_project', 'fixture', '\(id(ownerSubject))',
            '2026-07-26T00:00:00Z', '2026-07-26T00:00:00Z'
        );
        """
    }

    func insertDocumentSQL(
        documentID: UUID,
        localPath: String
    ) -> String {
        """
        INSERT INTO sync_documents(
            document_id, local_project_id, project_id, local_path,
            server_path, created_at, updated_at
        ) VALUES (
            '\(id(documentID))', '\(id(localProjectID))',
            '\(id(serverProjectID))', '\(localPath)', '\(localPath)',
            '2026-07-26T00:00:00Z', '2026-07-26T00:00:00Z'
        );
        """
    }

    func insertBatchSQL(
        batchID: UUID,
        status: String = "ready"
    ) -> String {
        """
        INSERT INTO sync_batches(
            batch_id, local_project_id, batch_kind, mutation_count,
            payload_hash, status, created_at, updated_at
        ) VALUES (
            '\(id(batchID))', '\(id(localProjectID))',
            'project_binding', 1, '\(String(repeating: "a", count: 64))',
            '\(status)', '2026-07-26T00:00:00Z',
            '2026-07-26T00:00:00Z'
        );
        """
    }

    func insertEnsureOperationSQL(
        operationID: UUID,
        batchID: UUID,
        status: String,
        attempts: Int = 0,
        projectName: String = "fixture"
    ) -> String {
        """
        INSERT INTO sync_operations(
            operation_id, batch_id, local_project_id, project_id,
            owner_subject, operation_kind, project_name, status, attempts,
            created_at, updated_at
        ) VALUES (
            '\(id(operationID))', '\(id(batchID))',
            '\(id(localProjectID))', '\(id(serverProjectID))',
            '\(id(ownerSubject))', 'ensure_project', '\(projectName)',
            '\(status)', \(attempts), '2026-07-26T00:00:00Z',
            '2026-07-26T00:00:00Z'
        );
        """
    }

    private func id(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }
}
