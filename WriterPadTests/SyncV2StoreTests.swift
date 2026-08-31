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
        XCTAssertEqual(version, SyncV2Store.currentSchemaVersion)
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

    func testEmptyVersionZeroDatabaseMigratesForwardToLatest() async throws {
        let url = try databaseURL()
        let raw = try RawSQLite(url: url)
        try raw.execute("PRAGMA user_version = 0;")
        raw.close()

        let store = try await openStore(at: url)

        let version = try await store.schemaVersion()
        XCTAssertEqual(version, SyncV2Store.currentSchemaVersion)
        await store.close()
    }

    func testHigherSchemaVersionIsPreservedAndRejected() async throws {
        let url = try databaseURL()
        let raw = try RawSQLite(url: url)
        let tooNew = SyncV2Store.currentSchemaVersion + 1
        try raw.execute("PRAGMA user_version = \(tooNew);")
        raw.close()

        let diagnostic = await unavailableDiagnostic(at: url)

        XCTAssertEqual(diagnostic.reason, .schemaTooNew)
        XCTAssertEqual(diagnostic.schemaVersion, tooNew)
        let check = try RawSQLite(url: url)
        XCTAssertEqual(
            try check.scalarInt("PRAGMA user_version;"),
            tooNew
        )
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

    func testStartupCompletesLegacyInflightEnsureWithSameIDAndAttempts()
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
        XCTAssertEqual(status, "completed")
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
        XCTAssertEqual(first.mutations.count, 5)

        try Data("후속 변경".utf8).write(to: liveURL)
        _ = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "Windows 작품",
            batchKind: .windowsImport
        )

        let recorded = await durable.batches
        XCTAssertEqual(recorded, [first, first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let completedReplay = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "Windows 작품",
            batchKind: .windowsImport
        )
        XCTAssertEqual(completedReplay, .notNeeded)
        let attemptsAfterCompletion = await durable.batches
        XCTAssertEqual(attemptsAfterCompletion, [first, first])
        guard let liveMutation = first.mutations.first(where: {
            if case .documentSnapshot = $0 { return true }
            return false
        }), case let .documentSnapshot(
            _,
            documentID,
            _,
            content,
            _,
            _,
            _
        ) = liveMutation else {
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
        guard let liveMutation = batch.mutations.first(where: {
            if case .documentSnapshot = $0 { return true }
            return false
        }), case let .documentSnapshot(
            _,
            recordedDocumentID,
            recordedPath,
            recordedContent,
            _,
            _,
            _
        ) = liveMutation else {
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

    func testInitialSnapshotTreeOrderUsesNFCAndDeclaresEmptyFolder()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-NFCTreeOrder-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let projectID = ProjectID(rawValue: UUID())
        let rootID = DocumentID(rawValue: UUID())
        let notesID = DocumentID(rawValue: UUID())
        let emptyID = DocumentID(rawValue: UUID())
        let date = Date(timeIntervalSince1970: 1)
        func decomposed(_ path: String) -> RelativeDocumentPath {
            RelativeDocumentPath(
                rawValue: path.decomposedStringWithCanonicalMapping
            )
        }
        let nodes = [
            DocumentNode(
                id: rootID,
                projectID: projectID,
                kind: .folder,
                parentID: nil,
                relativePath: decomposed("메인"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
            DocumentNode(
                id: notesID,
                projectID: projectID,
                kind: .folder,
                parentID: rootID,
                relativePath: decomposed("메인/메모장"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
            DocumentNode(
                id: emptyID,
                projectID: projectID,
                kind: .folder,
                parentID: notesID,
                relativePath: decomposed("메인/메모장/한글 빈폴더"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
        ]
        let durable = ScriptedDurableChangeRecorder(
            results: [.queued(operationIDs: [UUID()])]
        )
        let recorder = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository(nodes),
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )

        guard case .queued = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "NFC 작품",
            batchKind: .projectBinding
        ) else {
            return XCTFail("초기 tree_order가 queue되어야 합니다.")
        }
        let batches = await durable.batches
        let batch = try XCTUnwrap(batches.first)
        guard case let .treeOrder(_, content, _) = batch.mutations.last
        else {
            return XCTFail("초기 tree_order snapshot이 없습니다.")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8))
                as? [String: Any]
        )
        let treeOrder = try XCTUnwrap(
            object["tree_order"] as? [String: [String]]
        )

        XCTAssertEqual(treeOrder["<root>"], ["메모장"])
        XCTAssertEqual(treeOrder["메인/메모장"], ["한글 빈폴더"])
        XCTAssertEqual(treeOrder["메인/메모장/한글 빈폴더"], [])
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
        var liveServerRevisions: [Int64?] = []
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
            liveServerRevisions.append(
                try await store.serverRevision(for: context.documentID)
            )
        }

        XCTAssertEqual(claimedRevisions, [0, 1, 2, 3])
        XCTAssertEqual(claimedDeleted, deleted)
        XCTAssertEqual(liveServerRevisions, [1, nil, 3, nil])
        let serverRevision = try await store.serverRevision(
            for: context.documentID
        )
        XCTAssertNil(serverRevision)
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

    func testTreeOrderCheckpointSurvivesWhileItsFolderIsPending()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let treeDocumentID = syncV2UUIDv5(
            namespace: context.serverProjectID,
            name: syncV2TreeOrderPath
        )
        let folderOperationID = UUID()
        let firstTreeID = UUID()
        let leaseSensitiveDocumentID = UUID()
        let leaseSensitiveOperationID = UUID()
        let secondTreeID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: folderOperationID,
                        name: "팯-빈폴더-팯"
                    ),
                    context.documentMutation(
                        operationID: firstTreeID,
                        documentID: treeDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인\":[\"팯-빈폴더-팯\"]},\"version\":1}",
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
                        operationID: leaseSensitiveOperationID,
                        documentID: leaseSensitiveDocumentID,
                        relativePath: "메인/다른 폴더/임대 중 문서.txt",
                        content: "경로 변경",
                        generation: 1
                    ),
                    context.documentMutation(
                        operationID: secondTreeID,
                        documentID: treeDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인\":[\"팯-빈폴더-팯\",\"다음 항목\"]},\"version\":1}",
                        generation: 2,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let firstTreeStatus = try await store.operationStatus(
            operationID: firstTreeID
        )
        XCTAssertEqual(
            firstTreeStatus,
            SyncV2OperationStatus.pending.rawValue
        )
        let folders = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folder.operationID, folderOperationID)
        try await store.complete(
            folder,
            result: folderCommitResult(for: folder)
        )

        let documents = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertEqual(documents.map(\.operationID), [firstTreeID])
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
        XCTAssertEqual(queued[0].status, .completed)
        XCTAssertEqual(binding?.projectName, "변경된 작품 이름")
        await store.close()
    }

    func testLaunchRecoveryCompletesLegacyEnsureProjectAndReleasesTreeOrder()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let ensureID = UUID()
        let treeID = UUID()
        let treeDocumentID = syncV2UUIDv5(
            namespace: context.serverProjectID,
            name: syncV2TreeOrderPath
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .projectBinding,
                mutations: [
                    .ensureProject(
                        SyncV2EnsureProjectMutation(
                            operationID: ensureID,
                            projectName: "언제까지"
                        )
                    ),
                    context.documentMutation(
                        operationID: treeID,
                        documentID: treeDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{\"<root>\":[]},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        await store.close()

        // 예전 빌드가 남긴 실제 장부 모양을 재현한다.
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations SET status = 'pending'
            WHERE operation_id = '\(ensureID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let recoveredEnsureStatus = try await reopened.operationStatus(
            operationID: ensureID
        )
        let ready = try await reopened.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(recoveredEnsureStatus, "completed")
        XCTAssertEqual(ready.map(\.operationID), [treeID])
        await reopened.close()
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

    /// 경로 충돌로 굳은 operation은 `conflict` 상태라 "완료도 취소도 아님"에
    /// 걸려 진행 중으로 집계된다. 그대로 두면 사용자에게는 끝나지 않는
    /// "동기화 중"으로만 보이므로, 해결이 필요한 상태로 따로 드러나야 한다.
    func testPathConflictSurfacesAsCollisionNotJustPendingWork()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "아이패드에서 쓴 3화"
                    ),
                ]
            )
        )
        let claims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let claimed = try XCTUnwrap(claims.first)

        try await store.markConflict(
            claimed,
            errorCode: "PATH_CONFLICT",
            detail: nil
        )

        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertEqual(state?.hasPathCollision, true)
        XCTAssertNil(
            state?.blockingErrorCode,
            "경로 충돌은 blocked가 아니라 conflict 상태다."
        )
        await store.close()
    }

    /// 다른 이유로 굳은 conflict는 경로 충돌로 보고되면 안 된다.
    func testNonPathConflictDoesNotReportPathCollision() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: UUID()),
                ]
            )
        )
        let claims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let claimed = try XCTUnwrap(claims.first)

        try await store.markConflict(
            claimed,
            errorCode: "OPERATION_ID_REUSED",
            detail: nil
        )

        let state = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        XCTAssertEqual(state?.hasPathCollision, false)
        await store.close()
    }

    /// 오프라인 중 두 기기가 같은 화를 각각 만들면 공통 원본이 없다. 기존
    /// 3-way 형식의 `바꾸기 전 원본`은 빈 칸이 되고 `차이점`은 본문 전체를
    /// 그대로 반복하므로, 두 칸만 남긴 형식을 쓴다.
    func testSideBySideKeepsBothBodiesWithoutBaseOrDifferenceSections() {
        let merged = ThreeWayMerge.sideBySide(
            local: "아이패드에서 쓴 3화",
            remote: "윈도우에서 쓴 3화"
        )

        XCTAssertEqual(
            merged,
            """
            =========

            로컬 편집본

            아이패드에서 쓴 3화

            =========

            서버 최신본

            윈도우에서 쓴 3화

            =========

            """
        )
        XCTAssertFalse(merged.contains("바꾸기 전 원본"))
        XCTAssertFalse(merged.contains("로컬과 서버 차이점"))
    }

    func testSideBySideKeepsBothBodiesWhenOneSideIsEmpty() {
        let merged = ThreeWayMerge.sideBySide(
            local: "",
            remote: "윈도우에서 쓴 3화"
        )

        XCTAssertTrue(merged.contains("로컬 편집본"))
        XCTAssertTrue(merged.contains("윈도우에서 쓴 3화"))
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

    func testUploadQueueSnapshotTracksLegacyPendingInflightAndRetryWait()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: UUID())]
            )
        )
        var snapshot = try await store.uploadQueueSnapshot(
            localProjectID: context.localProjectID
        )
        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertEqual(snapshot.inflightCount, 0)

        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let operation = try XCTUnwrap(claimed.first)
        snapshot = try await store.uploadQueueSnapshot(
            localProjectID: context.localProjectID
        )
        XCTAssertEqual(snapshot.pendingCount, 0)
        XCTAssertEqual(snapshot.inflightCount, 1)

        try await store.deferRetry(
            operation,
            errorCode: "NETWORK_UNAVAILABLE",
            detail: nil,
            nextAttemptAt: Date(timeIntervalSince1970: 100)
        )
        snapshot = try await store.uploadQueueSnapshot(
            localProjectID: context.localProjectID
        )
        XCTAssertEqual(snapshot.inflightCount, 0)
        XCTAssertEqual(snapshot.retryWaitingCount, 1)
        let other = try await store.uploadQueueSnapshot(
            localProjectID: ProjectID(rawValue: UUID())
        )
        XCTAssertEqual(other, .idle)
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

    func testAutomaticRebaseCreatesImmutableSuccessorAndCancelsDependents()
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
        let sourceBatchID = reclaimed.batchID
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
        let original = try XCTUnwrap(
            operations.first { $0.operationID == firstID }
        )
        let cancelled = try XCTUnwrap(
            operations.first { $0.operationID == latestID }
        )
        let advanced = try XCTUnwrap(
            operations.first { $0.operationID == advancedID }
        )
        let successor = try XCTUnwrap(
            operations.first {
                $0.supersedesOperationID == firstID
            }
        )
        let state = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: documentID
        )

        XCTAssertEqual(result, .rebased)
        XCTAssertNotEqual(successor.operationID, firstID)
        XCTAssertNotEqual(successor.batchID, sourceBatchID)
        XCTAssertEqual(successor.supersedesOperationID, firstID)
        XCTAssertEqual(successor.status, .pending)
        XCTAssertEqual(successor.baseRevision, 4)
        XCTAssertEqual(
            successor.content,
            "병합 중 최신 입력\n둘째\n서버 셋째\n"
        )
        XCTAssertEqual(successor.relativePath, remote.relativePath)

        // 원래 의도의 식별값과 payload는 고치지 않는다. 상태와 사건만
        // superseded로 끝나고, 서버 기준선과 병합 결과는 새 의도에만 있다.
        XCTAssertEqual(original.status, .cancelled)
        XCTAssertEqual(original.baseRevision, 3)
        XCTAssertEqual(original.relativePath, baseline.relativePath)
        XCTAssertEqual(original.content, "로컬 1\n둘째\n셋째\n")
        let originalAttempts = try await store.operationAttempts(
            operationID: firstID
        )
        XCTAssertEqual(originalAttempts, 2)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(advanced.status, .cancelled)
        XCTAssertEqual(state?.serverRevision, 4)
        XCTAssertEqual(state?.serverPath, remote.relativePath)

        let successorClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 42)
        )
        XCTAssertEqual(successorClaim.map(\.operationID), [successor.operationID])
        XCTAssertEqual(successorClaim.first?.batchID, successor.batchID)
        XCTAssertEqual(successorClaim.first?.supersedesOperationID, firstID)
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

    func testBatchSnapshotStatesMatchSingleReadsAndOmitUnknownIDs()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let otherDocumentID = UUID()
        let snapshots = [
            SyncV2RemoteDocumentSnapshot(
                documentID: context.documentID,
                relativePath: "메인/원고/1권/001화.txt",
                content: "첫 번째",
                revision: 3,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
            SyncV2RemoteDocumentSnapshot(
                documentID: otherDocumentID,
                relativePath: "메인/원고/1권/002화.txt",
                content: "두 번째",
                revision: 5,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 50)
            ),
        ]
        for snapshot in snapshots {
            let applied = try await store.applySnapshotBaseline(
                localProjectID: context.localProjectID,
                serverProjectID: context.serverProjectID,
                snapshot: snapshot,
                expectedRevision: nil
            )
            XCTAssertTrue(applied)
        }
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: UUID(),
                        relativePath: snapshots[0].relativePath,
                        content: "로컬 수정"
                    ),
                ]
            )
        )

        let unknownID = UUID()
        let optionalBatch = try await store.snapshotStates(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentIDs: [
                context.documentID,
                otherDocumentID,
                unknownID,
            ]
        )
        let batch = try XCTUnwrap(optionalBatch)
        let first = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: context.documentID
        )
        let second = try await store.snapshotState(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            documentID: otherDocumentID
        )

        XCTAssertEqual(batch[context.documentID], first)
        XCTAssertEqual(batch[otherDocumentID], second)
        XCTAssertNil(batch[unknownID])
        XCTAssertEqual(batch.count, 2)
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

    func testEquivalentRevisionZeroInitialDocumentAdoptsServerIdentity()
        async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let localDocumentID = UUID()
        let remoteDocumentID = UUID()
        let path = "메인/1권/001화.txt"
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .newServerProject,
                projectName: "identity race",
                ownerSubject: UUID()
            )
        )
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: nil,
                kind: .projectBinding,
                mutations: [
                    .document(
                        SyncV2DocumentMutation(
                            operationID: UUID(),
                            documentID: localDocumentID,
                            deviceID: UUID(),
                            localSaveGeneration: 0,
                            kind: .documentCommit,
                            localPath: path,
                            relativePath: path,
                            content: "",
                            isDeleted: false
                        )
                    ),
                ]
            )
        )
        let snapshot = SyncV2RemoteDocumentSnapshot(
            documentID: remoteDocumentID,
            relativePath: path,
            content: "",
            revision: 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let initialState = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: localDocumentID
        )
        XCTAssertEqual(initialState?.serverRevision, 0)
        XCTAssertEqual(initialState?.serverPath, path)
        XCTAssertTrue(initialState?.hasActiveOperation == true)
        let queuedBeforeClaim = try await store.queuedOperations(
            documentID: localDocumentID
        )
        XCTAssertEqual(
            queuedBeforeClaim.first?.contentHash,
            SHA256ContentHasher().sha256(for: Data()).rawValue
        )

        let adopted = try await store.adoptEquivalentInitialDocument(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            localDocumentID: localDocumentID,
            snapshot: snapshot
        )

        XCTAssertTrue(adopted)
        let remoteState = try await store.snapshotState(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            documentID: remoteDocumentID
        )
        XCTAssertEqual(remoteState?.serverRevision, 1)
        XCTAssertEqual(remoteState?.serverPath, path)
        XCTAssertFalse(remoteState?.hasActiveOperation == true)
        let localOperations = try await store.queuedOperations(
            documentID: localDocumentID
        )
        XCTAssertEqual(localOperations.map(\.status), [.cancelled])

        let idempotent = try await store.adoptEquivalentInitialDocument(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            localDocumentID: localDocumentID,
            snapshot: snapshot
        )
        XCTAssertTrue(idempotent)
        await store.close()
    }

    func testIdentityAdoptionRejectsEditedInitialDocument() async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let localDocumentID = UUID()
        let path = "메인/1권/001화.txt"
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .newServerProject,
                projectName: "edited identity race",
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
                            documentID: localDocumentID,
                            deviceID: UUID(),
                            localSaveGeneration: 1,
                            kind: .documentCommit,
                            localPath: path,
                            relativePath: path,
                            content: "로컬 편집",
                            isDeleted: false
                        )
                    ),
                ]
            )
        )

        let adopted = try await store.adoptEquivalentInitialDocument(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            localDocumentID: localDocumentID,
            snapshot: SyncV2RemoteDocumentSnapshot(
                documentID: UUID(),
                relativePath: path,
                content: "",
                revision: 1,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 50)
            )
        )

        XCTAssertFalse(adopted)
        let operations = try await store.queuedOperations(
            documentID: localDocumentID
        )
        XCTAssertEqual(operations.map(\.status), [.pending])
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

    func testFolderCommitQueuesFolderLaneWithBaseRevisionZero()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: operationID,
                        name: "가 나 다"
                    )
                ]
            )
        )
        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )

        let claimed = try XCTUnwrap(ready.first)
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(claimed.operationID, operationID)
        XCTAssertEqual(claimed.folderID, context.folderID)
        XCTAssertNil(claimed.parentFolderID)
        XCTAssertEqual(claimed.name, "가 나 다")
        XCTAssertEqual(claimed.baseRevision, 0)
        XCTAssertEqual(claimed.folderSequence, 1)
        XCTAssertFalse(claimed.isDeleted)
        XCTAssertEqual(claimed.attempts, 1)
        await store.close()
    }

    func testRemoteFolderPullAdvancesRenameBaseRevision() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let remote = SyncV2RemoteFolder(
            folderID: context.folderID,
            parentFolderID: nil,
            name: "윈도우 이름",
            revision: 2,
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [remote],
            excluding: []
        )
        let baselineDatabase = try RawSQLite(url: url)
        XCTAssertEqual(
            try baselineDatabase.scalarInt(
                """
                SELECT server_revision FROM sync_folders
                WHERE folder_id =
                    '\(context.folderID.uuidString.lowercased())';
                """
            ),
            2
        )
        baselineDatabase.close()
        let renameID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "아이패드 이름"
                    )
                ]
            )
        )
        let ready = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 30)
        )

        let claimed = try XCTUnwrap(ready.first)
        XCTAssertEqual(claimed.operationID, renameID)
        XCTAssertEqual(claimed.name, "아이패드 이름")
        XCTAssertEqual(claimed.baseRevision, 2)
        await store.close()
    }

    func testRemoteFolderPullDoesNotOverwriteActiveLocalRename()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let renameID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "아이패드 이름"
                    )
                ]
            )
        )

        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "늦게 도착한 서버 이름",
                    revision: 7,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            excluding: []
        )
        let ready = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 30)
        )

        let claimed = try XCTUnwrap(ready.first)
        XCTAssertEqual(claimed.name, "아이패드 이름")
        XCTAssertEqual(claimed.baseRevision, 0)
        await store.close()
    }

    /// 되감기는 상태를 바꾸는 durable 경로다. 사건 열에 남기지 않으면
    /// status 칸과 사건이 말하는 상태가 갈라진다.
    ///
    /// 장치(`operationStateDivergences`)는 있었지만 되감기 뒤를 보는 시험이
    /// 없었다. 교차검증 3라운드에서 지적받아 넣는다.
    func testFolderRebaseLeavesNoStateDivergence() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "서버 revision 2",
                    revision: 2,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            excluding: []
        )
        let renameID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "이 기기 이름"
                    )
                ]
            )
        )
        let claims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 30)
        )
        let claimed = try XCTUnwrap(claims.first)
        let baseline = try await store.operationStateDivergences()
        XCTAssertEqual(baseline, [])

        try await store.rebaseFolderAfterRevisionConflict(
            claimed,
            remote: SyncV2RemoteFolder(
                folderID: context.folderID,
                parentFolderID: nil,
                name: "다른 기기 이름",
                revision: 3,
                isDeleted: false,
                updatedAt: Date(timeIntervalSince1970: 40)
            )
        )

        let divergences = try await store.operationStateDivergences()
        let events = try await store.operationEvents(operationID: renameID)
        let operations = try await store.queuedOperations()
        let successor = try XCTUnwrap(
            operations.first { $0.supersedesOperationID == renameID }
        )
        let successorEvents = try await store.operationEvents(
            operationID: successor.operationID
        )
        await store.close()

        XCTAssertEqual(divergences, [], "되감기 뒤 상태가 사건과 갈라지면 안 된다")
        // 서버가 왜 거절했는지가 이력에 남아야 사후에 셀 수 있다.
        XCTAssertEqual(events.last?.type, .superseded)
        XCTAssertEqual(successorEvents.map(\.type), [.enqueued])
        XCTAssertTrue(
            events.contains { $0.type == .conflictDetected },
            "REVISION_CONFLICT 가 이력에 남아야 한다"
        )
    }

    func testFolderRevisionConflictCreatesImmutableSuccessor()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "서버 revision 2",
                    revision: 2,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ],
            excluding: []
        )
        let renameID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "최종 아이패드 이름"
                    )
                ]
            )
        )
        let firstClaims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 30)
        )
        let first = try XCTUnwrap(firstClaims.first)
        let remote = SyncV2RemoteFolder(
            folderID: context.folderID,
            parentFolderID: nil,
            name: "서버 revision 3",
            revision: 3,
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 40)
        )

        try await store.rebaseFolderAfterRevisionConflict(
            first,
            remote: remote
        )
        let retriedClaims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 50)
        )
        let retried = try XCTUnwrap(retriedClaims.first)

        XCTAssertNotEqual(retried.operationID, renameID)
        XCTAssertNotEqual(retried.batchID, first.batchID)
        XCTAssertEqual(retried.supersedesOperationID, renameID)
        XCTAssertEqual(retried.name, "최종 아이패드 이름")
        XCTAssertEqual(retried.baseRevision, 3)
        XCTAssertEqual(retried.attempts, 1)
        XCTAssertEqual(retried.automaticRebaseCount, 1)
        let originalStatus = try await store.operationStatus(
            operationID: renameID
        )
        let originalEvents = try await store.operationEvents(
            operationID: renameID
        )
        let lineageDivergences = try await store
            .operationLineageDivergences()
        XCTAssertEqual(originalStatus, "cancelled")
        XCTAssertEqual(originalEvents.last?.type, .superseded)
        XCTAssertEqual(lineageDivergences, [])
        await store.close()
    }

    func testLaunchRecoveryRequeuesPersistedFolderRevisionConflict()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "서버 이름",
                    revision: 1,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            excluding: []
        )
        let renameID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "팯-빈폴더-팯"
                    )
                ]
            )
        )
        let claims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let claimed = try XCTUnwrap(claims.first)
        try await store.markConflict(
            claimed,
            errorCode: "REVISION_CONFLICT",
            detail: nil
        )
        await store.close()

        let reopened = try await openStore(at: url)
        let recovered = try await reopened.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(recovered.map(\.operationID), [renameID])
        XCTAssertEqual(recovered.first?.baseRevision, 1)
        await reopened.close()
    }

    func testFolderRenameKeepsFolderIDAndWaitsForUnknownRevision()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let createID = UUID()
        let renameID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: createID,
                        name: "가 나 다"
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "가 나 다 바"
                    )
                ]
            )
        )
        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )

        // 이름 변경은 생성이 받아올 revision을 알기 전에는 나갈 수 없다.
        XCTAssertEqual(ready.map(\.operationID), [createID])
        await store.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(DISTINCT folder_id) FROM sync_operations
                WHERE operation_kind = 'folder_commit';
                """
            ),
            1
        )
        XCTAssertEqual(
            try raw.scalarText(
                """
                SELECT group_concat(document_sequence, ',')
                FROM (
                    SELECT document_sequence FROM sync_operations
                    WHERE operation_kind = 'folder_commit'
                    ORDER BY queue_id
                );
                """
            ),
            "1,2"
        )
        // 앞 작업이 받아올 revision을 아직 모르므로 비어 있어야 한다.
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sync_operations
                WHERE operation_id = '\(renameID.uuidString.lowercased())'
                  AND base_revision IS NULL;
                """
            ),
            1
        )
    }

    func testSameFolderNeverHasTwoOperationsInFlightAtOnce() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let createID = UUID()
        let renameID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: createID,
                        name: "가 나 다"
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameID,
                        name: "가 나 다 바"
                    )
                ]
            )
        )
        await store.close()

        // 뒤 작업의 revision이 이미 채워진 상태를 만든다. 앞 작업이 아직 끝나지
        // 않았는데 둘 다 나가면 서버에 같은 폴더의 두 판이 동시에 도착한다.
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations SET base_revision = 0
            WHERE operation_id = '\(renameID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let ready = try await reopened.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(ready.map(\.operationID), [createID])
        await reopened.close()
    }

    func testPendingFolderOperationSurvivesCloseAndReopen() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: operationID,
                        name: "가 나 다"
                    )
                ]
            )
        )
        await store.close()

        let reopened = try await openStore(at: url)
        let ready = try await reopened.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(ready.map(\.operationID), [operationID])
        XCTAssertEqual(ready.map(\.folderID), [context.folderID])
        await reopened.close()
    }

    func testVersion2DatabaseGainsFolderTableKeepingPendingOperations()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: "아직 못 보낸 저장"
                    )
                ]
            )
        )
        await store.close()

        // 폴더 표가 생기기 전 설치를 흉내 낸다. 미전송 저장이 그대로 있는
        // 상태에서 V3 이후가 더한 것을 모두 걷어내고 버전만 뒤로 돌린다.
        let downgrade = try RawSQLite(url: url)
        try downgrade.execute(
            """
            DROP TABLE conflict_recovery_entities;
            DROP TABLE conflict_recovery_packages;
            DROP TABLE sync_contract_operations;
            DROP TABLE sync_contract_batches;
            DROP TABLE sync_tree_orders;
            DROP TABLE sync_folders;
            DROP TABLE sync_operation_events;
            DROP INDEX sync_operations_supersedes_idx;
            ALTER TABLE sync_operations
                DROP COLUMN automatic_rebase_count;
            ALTER TABLE sync_operations
                DROP COLUMN supersedes_operation_id;
            ALTER TABLE sync_projects
                DROP COLUMN folder_migration_completed_at;
            DELETE FROM schema_migrations WHERE version >= 3;
            PRAGMA user_version = 2;
            """
        )
        downgrade.close()

        let reopened = try await openStore(at: url)

        let version = try await reopened.schemaVersion()
        let queued = try await reopened.queuedOperations(
            documentID: context.documentID
        )
        XCTAssertEqual(version, SyncV2Store.currentSchemaVersion)
        XCTAssertEqual(queued.map(\.operationID), [operationID])
        XCTAssertEqual(queued.map(\.content), ["아직 못 보낸 저장"])
        await reopened.close()

        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'sync_folders';
                """
            ),
            1
        )
    }

    func testCanaryVersion7DatabaseJoinsUnifiedSchemaWithoutLosingContractRows()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let treeOrderID = UUID()
        let batchID = UUID()
        let store = try await connectedStore(at: url, context: context)
        await store.close()

        // fielded canary는 V6/V7 번호를 tree_order와 계약 배치에 썼다. 통합선의
        // 같은 번호가 더한 operation 계보 열과 V8 복구 장부는 없는 모양이다.
        let canary = try RawSQLite(url: url)
        try canary.execute(
            """
            INSERT INTO sync_tree_orders(
                tree_order_id, local_project_id, project_id,
                parent_folder_id, children_json, server_revision,
                server_updated_at, sync_state, last_error_code,
                created_at, updated_at
            ) VALUES (
                '\(treeOrderID.uuidString)',
                '\(context.localProjectID.rawValue.uuidString.lowercased())',
                '\(context.serverProjectID.uuidString.lowercased())',
                NULL, '[]', 4,
                '2026-08-26T00:00:00.000Z', 'synced', NULL,
                '2026-08-26T00:00:00.000Z',
                '2026-08-26T00:00:00.000Z'
            );
            INSERT INTO sync_contract_batches(
                batch_id, local_project_id, project_id, request_json,
                batch_payload_sha256, status, attempts, response_json,
                last_error_code, last_error_detail, created_at, updated_at
            ) VALUES (
                '\(batchID.uuidString)',
                '\(context.localProjectID.rawValue.uuidString.lowercased())',
                '\(context.serverProjectID.uuidString.lowercased())',
                '{"operations":[]}',
                '\(String(repeating: "a", count: 64))',
                'ready', 0, NULL, NULL, NULL,
                '2026-08-26T00:00:00.000Z',
                '2026-08-26T00:00:00.000Z'
            );

            DROP TABLE conflict_recovery_entities;
            DROP TABLE conflict_recovery_packages;
            DROP INDEX sync_operations_supersedes_idx;
            ALTER TABLE sync_operations
                DROP COLUMN automatic_rebase_count;
            ALTER TABLE sync_operations
                DROP COLUMN supersedes_operation_id;

            DELETE FROM schema_migrations WHERE version >= 6;
            INSERT INTO schema_migrations(version, name, checksum, applied_at)
            VALUES
                (6, 'SyncV2StoreSchemaV6', 'fielded-canary-v6',
                 '2026-08-26T00:00:00.000Z'),
                (7, 'SyncV2StoreSchemaV7', 'fielded-canary-v7',
                 '2026-08-26T00:00:00.000Z');
            PRAGMA user_version = 7;
            """
        )
        canary.close()

        let reopened = try await openStore(at: url)
        let integratedVersion = try await reopened.schemaVersion()
        XCTAssertEqual(integratedVersion, SyncV2Store.currentSchemaVersion)
        await reopened.close()

        let integrated = try RawSQLite(url: url)
        XCTAssertEqual(
            try integrated.scalarInt(
                """
                SELECT server_revision FROM sync_tree_orders
                WHERE tree_order_id = '\(treeOrderID.uuidString)';
                """
            ),
            4
        )
        XCTAssertEqual(
            try integrated.scalarText(
                """
                SELECT status FROM sync_contract_batches
                WHERE batch_id = '\(batchID.uuidString)';
                """
            ),
            "ready"
        )
        for column in [
            "supersedes_operation_id",
            "automatic_rebase_count",
        ] {
            XCTAssertEqual(
                try integrated.scalarInt(
                    """
                    SELECT COUNT(*) FROM pragma_table_info('sync_operations')
                    WHERE name = '\(column)';
                    """
                ),
                1
            )
        }
        XCTAssertEqual(
            try integrated.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table'
                  AND name IN (
                    'conflict_recovery_packages',
                    'conflict_recovery_entities'
                  );
                """
            ),
            2
        )
        integrated.close()
    }

    func testFolderNameWithPathSeparatorIsRejected() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)

        do {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.folderMutation(
                            operationID: UUID(),
                            name: "가 나/다"
                        )
                    ]
                )
            )
            XCTFail("A folder name with a separator must fail.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2EnqueueError,
                .invalidMutation
            )
        }
        let operationCount = try await store.operationCount()
        XCTAssertEqual(operationCount, 0)
        await store.close()
    }

    func testFolderMoveIntoOwnDescendantIsRejected() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let childID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "부모"
                    ),
                    context.folderMutation(
                        operationID: UUID(),
                        folderID: childID,
                        parentFolderID: context.folderID,
                        name: "자식"
                    ),
                ]
            )
        )

        do {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.folderMutation(
                            operationID: UUID(),
                            parentFolderID: childID,
                            name: "부모"
                        )
                    ]
                )
            )
            XCTFail("Moving a folder into its own child must fail.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2EnqueueError,
                .invalidMutation
            )
        }
        let operationCount = try await store.operationCount()
        XCTAssertEqual(operationCount, 2)
        await store.close()
    }

    func testFolderLaneAndDocumentLaneAdvanceIndependently()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let folderOperationID = UUID()
        let documentOperationID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: folderOperationID,
                        name: "가 나 다"
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: documentOperationID
                    )
                ]
            )
        )

        // 폴더를 먼저 붙잡아 두어도 문서 줄은 그대로 나가야 한다.
        let folders = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        let documents = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(folders.map(\.operationID), [folderOperationID])
        XCTAssertEqual(
            documents.map(\.operationID),
            [documentOperationID]
        )
        await store.close()
    }

    func testStructureBatchPublishesFolderThenDocumentsThenTreeOrder()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let folderOperationID = UUID()
        let documentOperationID = UUID()
        let treeOrderOperationID = UUID()
        let treeOrderDocumentID = UUID()

        // 실제 폴더 이름 변경 batch와 같은 순서다. 하위 TXT snapshot이 먼저
        // 만들어져도 전송은 폴더 행을 앞세워야 한다.
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.documentMutation(
                        operationID: documentOperationID,
                        relativePath: "메모장/새 이름/문서.txt"
                    ),
                    context.folderMutation(
                        operationID: folderOperationID,
                        name: "새 이름"
                    ),
                    context.documentMutation(
                        operationID: treeOrderOperationID,
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let documentsBeforeFolder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(documentsBeforeFolder.isEmpty)

        let folders = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folders.map(\.operationID), [folderOperationID])
        try await store.complete(
            folder,
            result: folderCommitResult(for: folder)
        )

        let documents = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )
        let document = try XCTUnwrap(documents.first)
        XCTAssertEqual(documents.map(\.operationID), [documentOperationID])
        try await store.complete(
            document,
            result: commitResult(for: document)
        )

        let treeOrder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(treeOrder.map(\.operationID), [treeOrderOperationID])
        await store.close()
    }

    func testRapidVolumeCreationsPublishEveryFolderBeforeAnyChapter()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let firstFolderOperationID = UUID()
        let secondFolderOperationID = UUID()
        let chapterOperationIDs = (0..<4).map { _ in UUID() }
        let chapterDocumentIDs = (0..<4).map { _ in UUID() }
        let treeOrderDocumentID = UUID()
        let firstTreeOrderOperationID = UUID()
        let finalTreeOrderOperationID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .volumeCreation,
                mutations: [
                    context.folderMutation(
                        operationID: firstFolderOperationID,
                        folderID: UUID(),
                        name: "1권"
                    ),
                    context.documentMutation(
                        operationID: chapterOperationIDs[0],
                        documentID: chapterDocumentIDs[0],
                        relativePath: "원고/1권/001화.txt"
                    ),
                    context.documentMutation(
                        operationID: chapterOperationIDs[1],
                        documentID: chapterDocumentIDs[1],
                        relativePath: "원고/1권/002화.txt"
                    ),
                    context.documentMutation(
                        operationID: firstTreeOrderOperationID,
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{\"원고\":[\"1권\"]},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .volumeCreation,
                mutations: [
                    context.folderMutation(
                        operationID: secondFolderOperationID,
                        folderID: UUID(),
                        name: "2권"
                    ),
                    context.documentMutation(
                        operationID: chapterOperationIDs[2],
                        documentID: chapterDocumentIDs[2],
                        relativePath: "원고/2권/026화.txt"
                    ),
                    context.documentMutation(
                        operationID: chapterOperationIDs[3],
                        documentID: chapterDocumentIDs[3],
                        relativePath: "원고/2권/027화.txt"
                    ),
                    context.documentMutation(
                        operationID: finalTreeOrderOperationID,
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{\"원고\":[\"1권\",\"2권\"]},\"version\":1}",
                        generation: 2,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let documentsBeforeFolders = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(documentsBeforeFolders.isEmpty)
        let folders = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(
            folders.map(\.operationID),
            [firstFolderOperationID, secondFolderOperationID]
        )
        for folder in folders {
            try await store.complete(
                folder,
                result: folderCommitResult(for: folder)
            )
        }

        for (index, operationID) in chapterOperationIDs.enumerated() {
            let claims = try await store.claimReadyOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: TimeInterval(20 + index))
            )
            let chapter = try XCTUnwrap(claims.first)
            XCTAssertEqual(claims.map(\.operationID), [operationID])
            try await store.complete(
                chapter,
                result: commitResult(for: chapter)
            )
        }

        let treeOrder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(treeOrder.map(\.operationID), [finalTreeOrderOperationID])
        let firstTreeOrderStatus = try await store.operationStatus(
            operationID: firstTreeOrderOperationID
        )
        XCTAssertEqual(
            firstTreeOrderStatus,
            "cancelled"
        )
        await store.close()
    }

    func testSecondVolumeFolderIsNextAfterInflightChapter()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let firstFolderOperationID = UUID()
        let secondFolderOperationID = UUID()
        let firstChapterOperationID = UUID()
        let secondChapterOperationID = UUID()
        let laterChapterOperationID = UUID()
        let treeOrderDocumentID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .volumeCreation,
                mutations: [
                    context.folderMutation(
                        operationID: firstFolderOperationID,
                        folderID: UUID(),
                        name: "1권"
                    ),
                    context.documentMutation(
                        operationID: firstChapterOperationID,
                        documentID: UUID(),
                        relativePath: "원고/1권/001화.txt"
                    ),
                    context.documentMutation(
                        operationID: secondChapterOperationID,
                        documentID: UUID(),
                        relativePath: "원고/1권/002화.txt"
                    ),
                    context.documentMutation(
                        operationID: UUID(),
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{\"원고\":[\"1권\"]},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        let firstFolderClaims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let firstFolder = try XCTUnwrap(firstFolderClaims.first)
        try await store.complete(
            firstFolder,
            result: folderCommitResult(for: firstFolder)
        )
        let inflight = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )
        let firstChapter = try XCTUnwrap(inflight.first)
        XCTAssertEqual(inflight.map(\.operationID), [firstChapterOperationID])

        _ = try await store.enqueue(
            context.batch(
                kind: .volumeCreation,
                mutations: [
                    context.folderMutation(
                        operationID: secondFolderOperationID,
                        folderID: UUID(),
                        name: "2권"
                    ),
                    context.documentMutation(
                        operationID: laterChapterOperationID,
                        documentID: UUID(),
                        relativePath: "원고/2권/026화.txt"
                    ),
                    context.documentMutation(
                        operationID: UUID(),
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{\"원고\":[\"1권\",\"2권\"]},\"version\":1}",
                        generation: 2,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let noNewDocument = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertTrue(noNewDocument.isEmpty)
        let nextFolders = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        let secondFolder = try XCTUnwrap(nextFolders.first)
        XCTAssertEqual(nextFolders.map(\.operationID), [secondFolderOperationID])
        try await store.complete(
            secondFolder,
            result: folderCommitResult(for: secondFolder)
        )
        let stillOnlyInflight = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 40)
        )
        XCTAssertTrue(stillOnlyInflight.isEmpty)

        try await store.complete(
            firstChapter,
            result: commitResult(for: firstChapter)
        )
        let nextChapter = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 50)
        )
        XCTAssertEqual(
            nextChapter.map(\.operationID),
            [secondChapterOperationID]
        )
        await store.close()
    }

    func testVolumeFolderPriorityAndDependenciesSurviveRestart()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let first = try await connectedStore(at: url, context: context)
        let folderOperationIDs = [UUID(), UUID()]
        let chapterOperationIDs = [UUID(), UUID()]
        let treeOrderDocumentID = UUID()
        let finalTreeOrderOperationID = UUID()

        for index in 0..<2 {
            _ = try await first.enqueue(
                context.batch(
                    kind: .volumeCreation,
                    mutations: [
                        context.folderMutation(
                            operationID: folderOperationIDs[index],
                            folderID: UUID(),
                            name: "\(index + 1)권"
                        ),
                        context.documentMutation(
                            operationID: chapterOperationIDs[index],
                            documentID: UUID(),
                            relativePath: "원고/\(index + 1)권/\(index * 25 + 1)화.txt"
                        ),
                        context.documentMutation(
                            operationID: index == 1
                                ? finalTreeOrderOperationID : UUID(),
                            documentID: treeOrderDocumentID,
                            relativePath: syncV2TreeOrderPath,
                            content: "{\"tree_order\":{\"원고\":[\"\(index + 1)권\"]},\"version\":1}",
                            generation: index + 1,
                            kind: .treeOrder
                        ),
                    ]
                )
            )
        }
        await first.close()

        let reopened = try await openStore(at: url)
        let documentsBeforeFolders = try await reopened.claimReadyOperations(
            localProjectID: context.localProjectID,
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(documentsBeforeFolders.isEmpty)
        let folders = try await reopened.claimReadyFolderOperations(
            localProjectID: context.localProjectID,
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(folders.map(\.operationID), folderOperationIDs)
        for folder in folders {
            try await reopened.complete(
                folder,
                result: folderCommitResult(for: folder)
            )
        }

        let firstChapterClaims = try await reopened.claimReadyOperations(
            localProjectID: context.localProjectID,
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )
        let firstChapter = try XCTUnwrap(firstChapterClaims.first)
        XCTAssertEqual(
            firstChapterClaims.map(\.operationID),
            [chapterOperationIDs[0]]
        )
        try await reopened.complete(
            firstChapter,
            result: commitResult(for: firstChapter)
        )
        await reopened.close()

        let reopenedAgain = try await openStore(at: url)
        let secondChapterClaims = try await reopenedAgain.claimReadyOperations(
            localProjectID: context.localProjectID,
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        let secondChapter = try XCTUnwrap(secondChapterClaims.first)
        XCTAssertEqual(
            secondChapterClaims.map(\.operationID),
            [chapterOperationIDs[1]]
        )
        try await reopenedAgain.complete(
            secondChapter,
            result: commitResult(for: secondChapter)
        )
        let treeOrder = try await reopenedAgain.claimReadyOperations(
            localProjectID: context.localProjectID,
            limit: 10,
            now: Date(timeIntervalSince1970: 40)
        )
        XCTAssertEqual(treeOrder.map(\.operationID), [finalTreeOrderOperationID])
        await reopenedAgain.close()
    }

    func testFolderRebaseSuccessorKeepsOriginalBatchDependenciesBlocked()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "서버 이름",
                    revision: 2,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 10)
                ),
            ],
            excluding: []
        )
        let folderOperationID = UUID()
        let documentOperationID = UUID()
        let treeOrderOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: folderOperationID,
                        name: "아이패드 이름"
                    ),
                    context.documentMutation(
                        operationID: documentOperationID,
                        relativePath: "메모장/아이패드 이름/문서.txt"
                    ),
                    context.documentMutation(
                        operationID: treeOrderOperationID,
                        documentID: UUID(),
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        let originalClaims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 20)
        )
        let original = try XCTUnwrap(originalClaims.first)
        try await store.rebaseFolderAfterRevisionConflict(
            original,
            remote: SyncV2RemoteFolder(
                folderID: context.folderID,
                parentFolderID: nil,
                name: "윈도우 이름",
                revision: 3,
                isDeleted: false,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        )

        let blocked = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 40)
        )
        XCTAssertTrue(blocked.isEmpty)

        let successorClaims = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 40)
        )
        let successor = try XCTUnwrap(successorClaims.first)
        XCTAssertEqual(successor.supersedesOperationID, folderOperationID)
        try await store.complete(
            successor,
            result: folderCommitResult(for: successor)
        )

        let documentClaims = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 50)
        )
        let document = try XCTUnwrap(documentClaims.first)
        XCTAssertEqual(document.operationID, documentOperationID)
        try await store.complete(document, result: commitResult(for: document))
        let treeOrder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 60)
        )
        XCTAssertEqual(treeOrder.map(\.operationID), [treeOrderOperationID])
        let lineageDivergences = try await store
            .operationLineageDivergences()
        XCTAssertEqual(lineageDivergences, [])
        await store.close()
    }

    /// 검증06에서 folder successor가 끝난 뒤 tree_order도 revision 충돌로
    /// successor를 만들었다. 앞선 원본의 successor가 현재 후보 자신인데도
    /// "앞 구조 작업이 끝나야 한다"는 조건에 다시 걸리면, 새 tree_order는
    /// 자기 자신의 완료를 기다리며 영원히 pending에 머문다.
    func testTreeOrderRebaseSuccessorDoesNotWaitForItself()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        try await store.applyFolderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: context.folderID,
                    parentFolderID: nil,
                    name: "서버 이름",
                    revision: 2,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 10)
                ),
            ],
            excluding: []
        )
        let folderOperationID = UUID()
        let treeOrderOperationID = UUID()
        let treeOrderDocumentID = UUID()
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: folderOperationID,
                        name: "아이패드 이름"
                    ),
                    context.documentMutation(
                        operationID: treeOrderOperationID,
                        documentID: treeOrderDocumentID,
                        relativePath: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{},\"version\":1}",
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )

        let originalFolderClaims = try await store
            .claimReadyFolderOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 20)
            )
        let originalFolder = try XCTUnwrap(originalFolderClaims.first)
        try await store.rebaseFolderAfterRevisionConflict(
            originalFolder,
            remote: SyncV2RemoteFolder(
                folderID: context.folderID,
                parentFolderID: nil,
                name: "윈도우 이름",
                revision: 3,
                isDeleted: false,
                updatedAt: Date(timeIntervalSince1970: 30)
            )
        )
        let folderSuccessorClaims = try await store
            .claimReadyFolderOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 40)
            )
        let folderSuccessor = try XCTUnwrap(folderSuccessorClaims.first)
        try await store.complete(
            folderSuccessor,
            result: folderCommitResult(for: folderSuccessor)
        )

        let originalTreeOrderClaims = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 50)
        )
        let originalTreeOrder = try XCTUnwrap(
            originalTreeOrderClaims.first
        )
        let local = try await store.latestLocalSnapshot(
            for: originalTreeOrder
        )
        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: treeOrderDocumentID,
            relativePath: syncV2TreeOrderPath,
            content: "{\"tree_order\":{\"<root>\":[\"윈도우 이름\"]},\"version\":1}",
            revision: originalTreeOrder.baseRevision + 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 55)
        )
        let result = try await store.rebaseAfterRevisionConflict(
            originalTreeOrder,
            remote: remote,
            local: local,
            mergedContent: local.content,
            mergedPath: syncV2TreeOrderPath
        )
        XCTAssertEqual(result, .rebased)

        let treeOrderOperations = try await store.queuedOperations(
            documentID: treeOrderDocumentID
        )
        let successor = try XCTUnwrap(
            treeOrderOperations.first {
                $0.supersedesOperationID == treeOrderOperationID
            }
        )
        XCTAssertNotEqual(successor.operationID, treeOrderOperationID)
        XCTAssertNotEqual(successor.batchID, originalTreeOrder.batchID)
        XCTAssertEqual(successor.status, .pending)

        let ready = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 60)
        )
        XCTAssertEqual(
            ready.map(\.operationID),
            [successor.operationID],
            "tree_order successor는 자기 자신의 완료를 기다리면 안 된다"
        )
        let stateDivergences = try await store.operationStateDivergences()
        let lineageDivergences = try await store
            .operationLineageDivergences()
        XCTAssertEqual(stateDivergences, [])
        XCTAssertEqual(lineageDivergences, [])
        await store.close()
    }

    func testSixRapidFolderRenamesWaitBeforePublishingFinalTreeOrder()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let treeOrderDocumentID = UUID()
        let folderIDs = (0..<6).map { _ in UUID() }
        var folderOperationIDs: [UUID] = []
        var finalTreeOrderOperationID = UUID()

        for index in folderIDs.indices {
            let folderOperationID = UUID()
            let treeOrderOperationID = UUID()
            folderOperationIDs.append(folderOperationID)
            finalTreeOrderOperationID = treeOrderOperationID
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.folderMutation(
                            operationID: folderOperationID,
                            folderID: folderIDs[index],
                            name: "빠른 이름 \(index + 1)_팯"
                        ),
                        context.documentMutation(
                            operationID: treeOrderOperationID,
                            documentID: treeOrderDocumentID,
                            relativePath: syncV2TreeOrderPath,
                            content: "{\"tree_order\":{\"<root>\":[\"\(index + 1)\"]},\"version\":1}",
                            generation: index + 1,
                            kind: .treeOrder
                        ),
                    ]
                )
            )
        }

        let folders = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(folders.map(\.operationID), folderOperationIDs)
        XCTAssertEqual(Set(folders.map(\.folderID)), Set(folderIDs))
        XCTAssertEqual(Set(folders.map(\.name)).count, 6)
        let treeOrderBeforeFolders = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        XCTAssertTrue(treeOrderBeforeFolders.isEmpty)

        for folder in folders.dropLast() {
            try await store.complete(
                folder,
                result: folderCommitResult(for: folder)
            )
        }
        let treeOrderBeforeLastFolder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )
        XCTAssertTrue(treeOrderBeforeLastFolder.isEmpty)

        let lastFolder = try XCTUnwrap(folders.last)
        try await store.complete(
            lastFolder,
            result: folderCommitResult(for: lastFolder)
        )
        let finalTreeOrder = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 30)
        )
        XCTAssertEqual(
            finalTreeOrder.map(\.operationID),
            [finalTreeOrderOperationID]
        )
        await store.close()
    }

    func testParentTombstoneWaitsForItsChildFolder() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let childID = UUID()
        let parentDeleteID = UUID()
        let childDeleteID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "부모"
                    ),
                    context.folderMutation(
                        operationID: UUID(),
                        folderID: childID,
                        parentFolderID: context.folderID,
                        name: "자식"
                    ),
                ]
            )
        )
        // 두 폴더의 생성을 끝내 무덤이 기준선을 갖게 한다. 그러지 않으면
        // 순번이 아니라 아직 비어 있는 base_revision이 무덤을 붙잡는다.
        for step in 0..<2 {
            let created = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: 10 + TimeInterval(step))
            )
            let operation = try XCTUnwrap(created.first)
            try await store.complete(
                operation,
                result: folderCommitResult(for: operation)
            )
        }
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: parentDeleteID,
                        name: "부모",
                        isDeleted: true
                    ),
                    context.folderMutation(
                        operationID: childDeleteID,
                        folderID: childID,
                        parentFolderID: context.folderID,
                        name: "자식",
                        isDeleted: true
                    ),
                ]
            )
        )

        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )

        // 서버는 내용이 있는 폴더의 삭제를 FOLDER_NOT_EMPTY로 거부한다. 자식이
        // 먼저 나가고 부모는 그 뒤에야 나갈 수 있다.
        XCTAssertEqual(ready.map(\.operationID), [childDeleteID])
        await store.close()
    }

    func testFolderTombstoneWaitsForDocumentsInsideIt() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let deleteID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "메모장"
                    )
                ]
            )
        )
        for created in try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        ) {
            try await store.complete(
                created,
                result: folderCommitResult(for: created)
            )
        }
        // 폴더 안 문서가 아직 대기열에 남아 있는 상태를 만든다.
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: UUID(),
                        relativePath: "메모장/001화.txt"
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: deleteID,
                        name: "메모장",
                        isDeleted: true
                    )
                ]
            )
        )

        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )

        // 문서를 먼저 보내지 않으면 서버가 폴더 삭제를 거부한다.
        XCTAssertTrue(ready.isEmpty)
        await store.close()
    }

    func testFolderTombstoneGoesOutOnceNothingIsLeftInside()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let deleteID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "메모장"
                    )
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: deleteID,
                        name: "메모장",
                        isDeleted: true
                    )
                ]
            )
        )
        // 앞선 생성이 끝나 무덤이 기준선을 갖게 한다.
        let first = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 10)
        )
        let created = try XCTUnwrap(first.first)
        try await store.complete(
            created,
            result: folderCommitResult(for: created)
        )

        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 20)
        )

        // 안이 빈 폴더의 무덤은 막을 이유가 없다. 막아 두면 폴더가 영영 서버에
        // 남는다.
        XCTAssertEqual(ready.map(\.operationID), [deleteID])
        await store.close()
    }

    func testProjectWithOnlyFolderWorkIsReportedAsReady() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "가 나 다"
                    )
                ]
            )
        )
        let ready = try await store.readyLocalProjectIDs(
            now: Date(timeIntervalSince1970: 10)
        )

        // 폴더 작업만 있는 작품이 빠지면 디스패처가 그 줄을 아예 열지 않는다.
        XCTAssertEqual(ready, [context.localProjectID])
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

    private func folderCommitResult(
        for operation: SyncV2FolderDispatchOperation
    ) -> SyncV2CommitFolderResult {
        SyncV2CommitFolderResult(
            status: .committed,
            folderID: operation.folderID,
            versionID: UUID(),
            operationID: operation.operationID,
            operationKind: operation.baseRevision == 0 ? .create : .update,
            serverRevision: operation.baseRevision + 1,
            parentFolderID: operation.parentFolderID,
            name: operation.name,
            isDeleted: operation.isDeleted,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }

    // MARK: - 사건 기록과 불변 되감기 (스키마 V5/V6/V7)

    /// 새 저장소에 사건 표가 생겨야 한다.
    func testSchemaV7PreservesLineageAndAddsPersistentRebaseCount()
        async throws {
        let url = try databaseURL()

        let store = try await openStore(at: url)
        let version = try await store.schemaVersion()
        await store.close()

        XCTAssertEqual(version, SyncV2Store.currentSchemaVersion)
        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'sync_operation_events';
                """
            ),
            1
        )
        let v7Checksum = try raw.scalarText(
            "SELECT checksum FROM schema_migrations WHERE version = 7;"
        )
        XCTAssertEqual(v7Checksum.count, 64)
        XCTAssertNotEqual(v7Checksum, "design-fixture-v7")
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM pragma_table_info('sync_operations')
                WHERE name = 'automatic_rebase_count';
                """
            ),
            1
        )
        let checksum = try raw.scalarText(
            "SELECT checksum FROM schema_migrations WHERE version = 5;"
        )
        XCTAssertEqual(checksum.count, 64)
        XCTAssertNotEqual(checksum, "design-fixture-v5")
        let v6Checksum = try raw.scalarText(
            "SELECT checksum FROM schema_migrations WHERE version = 6;"
        )
        XCTAssertEqual(v6Checksum.count, 64)
        XCTAssertNotEqual(v6Checksum, "design-fixture-v6")
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT COUNT(*) FROM pragma_table_info('sync_operations')
                WHERE name = 'supersedes_operation_id';
                """
            ),
            1
        )
        raw.close()
    }

    /// 이미 쌓여 있던 작업에 사건 기록이 채워져야 한다. 그리고 그 기록에서
    /// 다시 계산한 상태가 지금 status와 같아야 한다. 이것이 어긋나면 읽는
    /// 쪽을 옮기는 순간 화면의 숫자가 달라진다.
    func testBackfillSeedsEventsThatDeriveToStoredStatus() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let completedID = UUID()
        let conflictID = UUID()
        let pendingID = UUID()

        let store = try await connectedStore(at: url, context: context)
        for (operationID, documentID) in [
            (completedID, UUID()), (conflictID, UUID()), (pendingID, UUID()),
        ] {
            _ = try await store.enqueue(
                context.batch(
                    mutations: [
                        context.documentMutation(
                            operationID: operationID,
                            documentID: documentID,
                            relativePath: "원고/\(operationID.uuidString).txt"
                        )
                    ]
                )
            )
        }
        await store.close()

        // 사건을 지우고 status만 바꿔 둔다. 되만들기 표가 실제로 도는지
        // 확인하려면 pending 말고 다른 상태가 있어야 한다.
        let raw = try RawSQLite(url: url)
        try raw.execute("DELETE FROM sync_operation_events;")
        try raw.execute(
            """
            UPDATE sync_operations SET status = 'completed'
            WHERE operation_id = '\(completedID.uuidString.lowercased())';
            """
        )
        try raw.execute(
            """
            UPDATE sync_operations
            SET status = 'conflict', last_error_code = 'PATH_CONFLICT'
            WHERE operation_id = '\(conflictID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let completedEvents = try await reopened.operationEvents(
            operationID: completedID
        )
        let conflictEvents = try await reopened.operationEvents(
            operationID: conflictID
        )
        let pendingEvents = try await reopened.operationEvents(
            operationID: pendingID
        )
        let divergences = try await reopened.operationStateDivergences()
        await reopened.close()

        XCTAssertEqual(
            completedEvents.map(\.type),
            [.enqueued, .dispatchStarted, .committed]
        )
        XCTAssertEqual(
            conflictEvents.map(\.type),
            [.enqueued, .dispatchStarted, .conflictDetected]
        )
        XCTAssertEqual(pendingEvents.map(\.type), [.enqueued])

        // 사건 번호는 1부터 빈틈없이 이어져야 계산을 믿을 수 있다.
        XCTAssertEqual(completedEvents.map(\.sequence), [1, 2, 3])

        // 오류는 마지막 사건만 안고 간다. 앞의 사건들은 오류를 낸 적이 없다.
        XCTAssertEqual(conflictEvents.map(\.errorCode), [nil, nil, "PATH_CONFLICT"])

        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: completedEvents),
            .completed
        )
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: conflictEvents),
            .conflict
        )
        XCTAssertEqual(divergences, [], "되만든 직후에는 어긋난 작업이 없어야 한다")
    }

    /// 되만들기는 몇 번을 돌려도 결과가 같아야 한다. 열 때마다 같은 사건이
    /// 한 벌씩 더 쌓이면 기록을 믿을 수 없게 된다.
    func testBackfillIsIdempotentAcrossReopens() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        await store.close()

        for _ in 0..<3 {
            let reopened = try await openStore(at: url)
            try await reopened.backfillOperationEvents()
            await reopened.close()
        }

        let raw = try RawSQLite(url: url)
        let total = try raw.scalarInt(
            """
            SELECT COUNT(*) FROM sync_operation_events
            WHERE operation_id = '\(operationID.uuidString.lowercased())';
            """
        )
        let storedEventID = try raw.scalarText(
            """
            SELECT event_id FROM sync_operation_events
            WHERE operation_id = '\(operationID.uuidString.lowercased())'
              AND event_sequence = 1;
            """
        )
        raw.close()

        XCTAssertEqual(total, 1)
        XCTAssertEqual(
            storedEventID,
            SyncV2Store.legacyEventID(
                operationID: operationID.uuidString.lowercased(),
                eventType: .enqueued
            ),
            "사건 식별자는 작업과 종류에서 계산해야 다시 돌려도 같다"
        )
    }

    /// 되만들기 표의 모든 상태가 자기 자신으로 되돌아와야 한다. 하나라도
    /// 어긋나면 그 상태의 작업들이 옮기는 순간 다른 값이 된다.
    func testSeedEventTypesRoundTripEveryStatus() throws {
        for state in [
            SyncV2OperationStatus.pending, .inflight, .retryWait,
            .blocked, .conflict, .completed, .cancelled,
        ] {
            let events = SyncV2Store.seedEventTypes(for: state)
                .enumerated()
                .map { SyncV2OperationEvent(sequence: $0.offset + 1, type: $0.element) }
            XCTAssertEqual(
                try SyncV2OperationStateDerivation.state(from: events),
                state,
                "\(state)"
            )
        }
    }

    /// status 칸만 고치고 사건을 남기지 않으면 어긋남으로 잡혀야 한다.
    /// 읽는 쪽을 옮기기 전에 이걸로 남은 쓰기 경로를 찾는다.
    func testDivergenceReporterCatchesColumnOnlyChange() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        // 이제는 대기열에 올리는 순간 첫 사건이 함께 남는다.
        let afterEnqueue = try await store.operationStateDivergences()
        let events = try await store.operationEvents(operationID: operationID)
        await store.close()

        // 사건은 그대로 두고 칸만 바꾼다. 지금 남아 있는 쓰기 경로들이 하는 짓이다.
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations SET status = 'completed'
            WHERE operation_id = '\(operationID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let after = try await reopened.operationStateDivergences()
        await reopened.close()

        XCTAssertEqual(events.map(\.type), [.enqueued])
        XCTAssertEqual(afterEnqueue, [], "대기열에 올린 직후에는 어긋남이 없다")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.operationID, operationID.uuidString.lowercased())
        XCTAssertEqual(after.first?.storedStatus, .completed)
        XCTAssertEqual(after.first?.derivedStatus, .pending)
    }

    // MARK: - 아직 사건을 남기지 않는 쓰기 경로

    /// 한 가지 상태 변화를 실제로 태우고, 사건 기록과 status 칸이 어긋나는지
    /// 본다.
    ///
    /// 되만들기를 먼저 돌려 바탕을 깨끗하게 만든 뒤에 변화를 준다. 그래야
    /// 나온 어긋남이 전부 그 변화 때문임이 분명해진다.
    private func divergenceAfterTransition(
        _ transition: (SyncV2Store, SyncV2DispatchOperation) async throws -> Void
    ) async throws -> [SyncV2OperationStateDivergence] {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: UUID())]
            )
        )
        try await store.backfillOperationEvents()
        let baseline = try await store.operationStateDivergences()
        XCTAssertEqual(baseline, [], "바탕이 이미 어긋나 있으면 결과를 믿을 수 없다")

        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let operation = try XCTUnwrap(claimed.first)
        try await transition(store, operation)

        let divergences = try await store.operationStateDivergences()
        await store.close()
        return divergences
    }

    /// 지금 어느 쓰기 경로가 status 칸만 고치고 사건을 남기지 않는지 적어 둔다.
    ///
    /// 여기 나온 것이 곧 옮겨야 할 목록이다. 하나씩 사건을 남기도록 고칠
    /// 때마다 이 목록에서 지운다. 다 지워지면 읽는 쪽을 옮겨도 화면의 숫자가
    /// 달라지지 않는다.
    func testWritePathsThatDoNotYetRecordEvents() async throws {
        // 옮겼다. 대기 → 발송 중.
        let claimOnly = try await divergenceAfterTransition { _, _ in }
        XCTAssertEqual(claimOnly, [])

        // 옮겼다. 발송이 끝나는 네 갈래는 모두 한 함수를 지난다.
        let completed = try await divergenceAfterTransition { store, operation in
            try await store.complete(operation, result: self.commitResult(for: operation))
        }
        XCTAssertEqual(completed, [])

        let retryWait = try await divergenceAfterTransition { store, operation in
            try await store.deferRetry(
                operation,
                errorCode: "NETWORK_UNAVAILABLE",
                detail: nil,
                nextAttemptAt: Date(timeIntervalSince1970: 200)
            )
        }
        XCTAssertEqual(retryWait, [])

        let conflict = try await divergenceAfterTransition { store, operation in
            try await store.markConflict(
                operation,
                errorCode: "REVISION_CONFLICT",
                detail: nil
            )
        }
        XCTAssertEqual(conflict, [])

        let blocked = try await divergenceAfterTransition { store, operation in
            try await store.markBlocked(
                operation,
                errorCode: "AUTH_REQUIRED",
                detail: nil
            )
        }
        XCTAssertEqual(blocked, [])

        // 대기 → 발송 중 → 다시 시도 대기 → 대기. 한 바퀴가 온전히 남는다.
        //
        // 이 왕복은 한때 이 눈의 사각지대였다. 양쪽 다 안 옮겼을 때는 처음
        // 자리로 돌아오면 칸과 계산이 우연히 같아져 아무 일도 없었던 것처럼
        // 보였다. 이제는 지나온 자리가 전부 기록에 남는다.
        //
        // 그래도 어긋남이 없다는 것만으로 "다 옮겼다"고 말할 수는 없다. 아직
        // 아무것도 안 옮긴 짝끼리는 여전히 서로를 가린다. 옮길 목록은 코드에서
        // 직접 세어야 한다.
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        try await store.backfillOperationEvents()
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        try await store.deferRetry(
            try XCTUnwrap(claimed.first),
            errorCode: "NETWORK_UNAVAILABLE",
            detail: nil,
            nextAttemptAt: Date(timeIntervalSince1970: 200)
        )
        try await store.makeRetryWaitOperationsReady(localProjectID: nil)
        let roundTrip = try await store.operationStateDivergences()
        let events = try await store.operationEvents(operationID: operationID)
        await store.close()

        XCTAssertEqual(roundTrip, [])
        XCTAssertEqual(
            events.map(\.type),
            [.enqueued, .dispatchStarted, .retryScheduled, .enqueued]
        )
        // 성공했다고 앞선 실패를 지우지 않는다. 무엇 때문에 다시 시도했는지가
        // 기록에 남아 있어야 한다.
        XCTAssertEqual(
            events.map(\.errorCode),
            [nil, nil, "NETWORK_UNAVAILABLE", nil]
        )
    }

    /// 발송이 끝날 때 남는 사건이 실제로 무엇인지 본다. 어긋나지 않는 것만으로는
    /// 옳은 기록이 남았는지 알 수 없다.
    func testDispatchOutcomeRecordsMatchingEvent() async throws {
        let cases: [(String, (SyncV2Store, SyncV2DispatchOperation) async throws -> Void, SyncV2OperationEventType, String?)] = [
            ("완료", { store, operation in
                try await store.complete(operation, result: self.commitResult(for: operation))
            }, .committed, nil),
            ("다시 시도", { store, operation in
                try await store.deferRetry(
                    operation,
                    errorCode: "NETWORK_UNAVAILABLE",
                    detail: nil,
                    nextAttemptAt: Date(timeIntervalSince1970: 200)
                )
            }, .retryScheduled, "NETWORK_UNAVAILABLE"),
            ("충돌", { store, operation in
                try await store.markConflict(
                    operation,
                    errorCode: "REVISION_CONFLICT",
                    detail: nil
                )
            }, .conflictDetected, "REVISION_CONFLICT"),
            ("막힘", { store, operation in
                try await store.markBlocked(
                    operation,
                    errorCode: "AUTH_REQUIRED",
                    detail: nil
                )
            }, .blocked, "AUTH_REQUIRED"),
        ]

        for (label, transition, expectedType, expectedError) in cases {
            let url = try databaseURL()
            let context = QueueAPIContext()
            let operationID = UUID()
            let store = try await connectedStore(at: url, context: context)
            _ = try await store.enqueue(
                context.batch(
                    mutations: [context.documentMutation(operationID: operationID)]
                )
            )
            try await store.backfillOperationEvents()
            let claimed = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: 100)
            )
            try await transition(store, try XCTUnwrap(claimed.first))
            let events = try await store.operationEvents(operationID: operationID)
            await store.close()

            XCTAssertEqual(events.last?.type, expectedType, label)
            XCTAssertEqual(events.last?.errorCode, expectedError, label)
            // 발송 한 바퀴가 온전히 남는다. 대기에서 시작해 발송을 거쳐 끝난다.
            XCTAssertEqual(
                events.map(\.type),
                [.enqueued, .dispatchStarted, expectedType],
                label
            )
            XCTAssertEqual(events.map(\.sequence), Array(1...events.count), label)
        }
    }

    /// 같은 작업을 다시 보내 받은 멱등 응답은 처음 올린 것과 다른 일이다.
    /// 둘 다 완료로 수렴하지만 기록에는 구분해 남는다.
    func testReplayedCommitRecordsReplayedEvent() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        try await store.backfillOperationEvents()
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let operation = try XCTUnwrap(claimed.first)
        var result = commitResult(for: operation)
        result = SyncV2CommitDocumentResult(
            status: .replayed,
            documentID: result.documentID,
            versionID: result.versionID,
            operationID: result.operationID,
            operationKind: result.operationKind,
            serverRevision: result.serverRevision,
            relativePath: result.relativePath,
            isDeleted: result.isDeleted,
            contentHash: result.contentHash,
            committedAt: result.committedAt
        )

        try await store.complete(operation, result: result)
        let events = try await store.operationEvents(operationID: operationID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(events.last?.type, .replayed)
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: events),
            .completed
        )
        XCTAssertEqual(divergences, [])
    }

    /// 발송 도중 앱이 꺼진 뒤 다시 열면, 되살린 것도 기록에 남아야 한다.
    ///
    /// 계속 발송 중이라고 믿으면 아무도 다시 손대지 않아 영영 대기에 남는다.
    /// 무엇이 되살아났는지 기록에 없으면 나중에 되짚을 수도 없다.
    func testRestartRecoveryRecordsRequeueEvent() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        _ = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        // 여기서 앱이 꺼졌다. 작업은 발송 중인 채로 남는다.
        await store.close()

        let reopened = try await openStore(at: url)
        let events = try await reopened.operationEvents(operationID: operationID)
        let divergences = try await reopened.operationStateDivergences()
        await reopened.close()

        XCTAssertEqual(
            events.map(\.type),
            [.enqueued, .dispatchStarted, .enqueued],
            "집어들었다가 되돌아온 자취가 남아야 한다"
        )
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: events),
            .pending
        )
        XCTAssertEqual(divergences, [])
    }

    /// 막힌 작업을 다시 풀어 줄 때도 기록에 남는다.
    func testForbiddenBlockRecoveryRecordsRequeueEvent() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        try await store.markBlocked(
            try XCTUnwrap(claimed.first),
            errorCode: "FORBIDDEN",
            detail: nil
        )
        try await store.makeRetryWaitOperationsReady(localProjectID: nil)

        let events = try await store.operationEvents(operationID: operationID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(
            events.map(\.type),
            [.enqueued, .dispatchStarted, .blocked, .enqueued]
        )
        XCTAssertEqual(
            events.map(\.errorCode),
            [nil, nil, "FORBIDDEN", nil],
            "풀려났다고 무엇에 막혔었는지를 지우지 않는다"
        )
        XCTAssertEqual(divergences, [])
    }

    /// 여러 경로를 섞어 태워도 기록과 칸이 끝까지 붙어 있어야 한다.
    ///
    /// 지금까지는 경로를 하나씩 따로 태웠다. 실제로는 섞여서 온다.
    func testMixedLifecycleKeepsEventsAndColumnTogether() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let documentID = UUID()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        documentID: documentID
                    )
                ]
            )
        )

        // 세 번 실패하고 네 번째에 성공한다.
        for round in 0..<3 {
            let claimed = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: TimeInterval(100 + round * 10))
            )
            try await store.deferRetry(
                try XCTUnwrap(claimed.first),
                errorCode: "NETWORK_UNAVAILABLE",
                detail: nil,
                nextAttemptAt: Date(timeIntervalSince1970: TimeInterval(105 + round * 10))
            )
            let midway = try await store.operationStateDivergences()
            XCTAssertEqual(midway, [], "\(round + 1)번째 실패 뒤")
            try await store.makeRetryWaitOperationsReady(localProjectID: nil)
        }
        let finalClaim = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 200)
        )
        let operation = try XCTUnwrap(finalClaim.first)
        try await store.complete(operation, result: commitResult(for: operation))

        let events = try await store.operationEvents(operationID: operationID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(divergences, [], "섞어 태워도 끝까지 붙어 있어야 한다")
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: events),
            .completed
        )
        XCTAssertEqual(events.map(\.sequence), Array(1...events.count))

        // 실패한 자취가 성공 뒤에도 남아 있어야 한다.
        XCTAssertEqual(
            events.filter { $0.errorCode == "NETWORK_UNAVAILABLE" }.count,
            3
        )
        XCTAssertEqual(events.last?.type, .committed)
    }

    /// 다시 시도를 되풀이하면 기록이 얼마나 길어지는지 재 둔다.
    ///
    /// 되돌아올 때마다 사건이 둘씩 붙는다. 오래 쓴 장부가 감당 못 할 만큼
    /// 불어나는지 알아 두어야 한다.
    func testEventHistoryGrowthPerRetryCycle() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()
        let cycles = 20

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        for round in 0..<cycles {
            let claimed = try await store.claimReadyOperations(
                limit: 1,
                now: Date(timeIntervalSince1970: TimeInterval(100 + round))
            )
            try await store.deferRetry(
                try XCTUnwrap(claimed.first),
                errorCode: "NETWORK_UNAVAILABLE",
                detail: nil,
                nextAttemptAt: Date(timeIntervalSince1970: TimeInterval(101 + round))
            )
            try await store.makeRetryWaitOperationsReady(localProjectID: nil)
        }
        let events = try await store.operationEvents(operationID: operationID)
        await store.close()

        // 대기 1 + 주기마다 (발송 시작, 다시 시도, 대기) 3개.
        XCTAssertEqual(events.count, 1 + cycles * 3)
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: events),
            .pending
        )
    }

    /// 연쇄 편집의 뒤쪽이 영영 발송되지 않는 자리를 막는다.
    ///
    /// 앞선 저장이 아직 안 끝났는데 또 저장하면, 뒤쪽 작업은 기준 리비전 없이
    /// 큐에 들어간다. 그 값은 앞선 작업이 **완료될 때** 채워진다. 앞선 작업이
    /// 완료 아닌 길로 끝나면 뒤쪽은 값이 빈 채로 남아 발송 대상에서 영영
    /// 빠진다. 큐가 통째로 멈추는데 화면에는 대기 중으로만 보인다.
    ///
    /// 취소하는 그 자리에서 되세워 그런 일이 생기지 않게 한다.
    func testCancelledLeaderDoesNotOrphanFollowingEdit() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let leaderID = UUID()
        let followerID = UUID()
        let followerContent = "첫 문장 그리고 둘째 문장"

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: leaderID,
                        content: "첫 문장",
                        generation: 1
                    )
                ]
            )
        )
        // 앞선 저장이 아직 안 끝났는데 또 저장한다.
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: followerID,
                        content: followerContent,
                        generation: 2
                    )
                ]
            )
        )

        try await store.cancelOperation(
            operationID: leaderID,
            cancelEventID: UUID()
        )

        let claimed = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 100)
        )
        let orphans = try await store.orphanedOperationIDs()
        let events = try await store.operationEvents(operationID: followerID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(
            claimed.map(\.operationID),
            [followerID],
            "앞이 취소돼도 뒤쪽은 발송된다"
        )
        XCTAssertEqual(
            claimed.first?.content,
            followerContent,
            "사용자가 쓴 글은 그대로다"
        )
        XCTAssertEqual(orphans, [])
        XCTAssertTrue(
            events.contains { $0.errorCode == "ADOPTED_AFTER_ORPHANED_CHAIN" },
            "왜 되세워졌는지 기록에 남아야 한다"
        )
        XCTAssertEqual(divergences, [])
    }

    /// 이미 끊긴 채로 남아 있던 장부는 다음에 열 때 되세워야 한다.
    ///
    /// 지금 빌드는 취소하는 자리에서 바로 되세우지만, 예전 빌드가 남긴 장부에는
    /// 이미 끊긴 작업이 들어 있을 수 있다.
    func testLaunchRecoveryAdoptsOrphanLeftByOlderBuild() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: operationID, content: "본문")
                ]
            )
        )
        await store.close()

        // 예전 빌드가 남긴 모양을 흉내 낸다. 기준 리비전이 비어 있어 발송
        // 대상에서 빠져 있다.
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations SET base_revision = NULL
            WHERE operation_id = '\(operationID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let orphans = try await reopened.orphanedOperationIDs()
        let claimed = try await reopened.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 100)
        )
        await reopened.close()

        XCTAssertEqual(orphans, [], "열면서 되세워야 한다")
        XCTAssertEqual(claimed.map(\.operationID), [operationID])
    }

    /// 앞이 끊긴 작업을 지금 리비전 위로 되세우면 다시 발송된다.
    ///
    /// 사용자가 쓴 글은 건드리지 않는다. 무엇을 보낼지는 그대로 두고 어디에
    /// 얹을지만 고친다.
    func testAdoptingOrphanedOperationMakesItDispatchableAgain() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let leaderID = UUID()
        let followerID = UUID()
        let followerContent = "첫 문장 그리고 둘째 문장"

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: leaderID, content: "첫 문장", generation: 1)
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: followerID,
                        content: followerContent,
                        generation: 2
                    )
                ]
            )
        )
        try await store.cancelOperation(
            operationID: leaderID,
            cancelEventID: UUID()
        )

        // 취소가 이미 되세웠으므로 여기서 더 되세울 것은 없다.
        let adopted = try await store.adoptOrphanedOperations()
        let claimed = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 100)
        )
        let remaining = try await store.orphanedOperationIDs()
        let events = try await store.operationEvents(operationID: followerID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(adopted, [], "취소하는 자리에서 이미 되세웠다")
        XCTAssertEqual(claimed.map(\.operationID), [followerID], "다시 발송된다")
        XCTAssertEqual(
            claimed.first?.content,
            followerContent,
            "사용자가 쓴 글은 그대로다"
        )
        XCTAssertEqual(remaining, [], "더 남은 고아가 없다")
        XCTAssertTrue(
            events.contains { $0.errorCode == "ADOPTED_AFTER_ORPHANED_CHAIN" },
            "왜 되살아났는지 기록에 남아야 한다"
        )
        XCTAssertEqual(divergences, [])
    }

    /// 앞선 작업이 정상으로 끝났으면 고아가 아니다. 되세울 것도 없다.
    func testCompletedLeaderDoesNotLeaveOrphan() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let leaderID = UUID()
        let followerID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: leaderID, content: "첫 문장", generation: 1)
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: followerID, content: "둘째 문장", generation: 2)
                ]
            )
        )
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let leader = try XCTUnwrap(claimed.first)
        try await store.complete(leader, result: commitResult(for: leader))

        let orphans = try await store.orphanedOperationIDs()
        let next = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 110)
        )
        await store.close()

        XCTAssertEqual(orphans, [], "정상으로 끝났으면 고아가 없다")
        XCTAssertEqual(next.map(\.operationID), [followerID])
    }

    // MARK: - 빠른 연속 이름 변경 (진단)

    /// 여섯 개를 한 배치로 잇달아 바꿀 때 저장소가 무엇을 하는지 읽는다.
    ///
    /// 미해결 사건과 같은 모양이다. 고치지 않는다. 지금 무슨 일이 일어나는지
    /// 기록으로 남겨, 나중에 보존된 사건에서 원인을 판정할 때 쓸 재료를 만든다.
    ///
    /// - Note: 벡터 04는 `ID_BASED/1`이고 사용자 작품은 `LEGACY/0`이다. 여기서
    ///   무엇이 나오든 그 사건이 재현됐다는 뜻은 아니다.
    func testRapidSixRenamesInOneBatchDiagnostic() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)

        let folderIDs = (0..<5).map { _ in UUID() }
        let operationIDs = (0..<5).map { _ in UUID() }
        let documentOperationID = UUID()
        let documentID = UUID()

        // 여섯 변경이 하나의 배치를 함께 쓴다. 벡터가 그렇게 규정한다.
        var mutations: [SyncV2Mutation] = folderIDs.enumerated().map { index, folderID in
            context.folderMutation(
                operationID: operationIDs[index],
                folderID: folderID,
                name: "R\(index + 1)"
            )
        }
        mutations.append(
            context.documentMutation(
                operationID: documentOperationID,
                documentID: documentID,
                relativePath: "R6.txt",
                content: "여섯째"
            )
        )
        _ = try await store.enqueue(
            context.batch(kind: .structureChange, mutations: mutations)
        )

        // 폴더 줄과 문서 줄을 번갈아 끝까지 흘린다.
        var dispatchedFolders: [UUID] = []
        for round in 0..<10 {
            let folders = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: TimeInterval(100 + round))
            )
            if folders.isEmpty { break }
            for folder in folders {
                dispatchedFolders.append(folder.operationID)
                try await store.complete(folder, result: folderCommitResult(for: folder))
            }
        }
        var dispatchedDocuments: [UUID] = []
        for round in 0..<10 {
            let documents = try await store.claimReadyOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: TimeInterval(200 + round))
            )
            if documents.isEmpty { break }
            for document in documents {
                dispatchedDocuments.append(document.operationID)
                try await store.complete(document, result: commitResult(for: document))
            }
        }

        var states: [String] = []
        for operationID in operationIDs + [documentOperationID] {
            let status = try await store.operationStatus(operationID: operationID) ?? "없음"
            let attempts = try await store.operationAttempts(operationID: operationID) ?? -1
            states.append("\(status)/\(attempts)")
        }
        let orphans = try await store.orphanedOperationIDs()
        let divergences = try await store.operationStateDivergences()
        await store.close()

        // 지금 저장소가 실제로 하는 일을 못 박아 둔다. 이 값이 달라지면
        // 무엇인가 바뀐 것이고, 그때 다시 봐야 한다.
        XCTAssertEqual(
            states,
            Array(repeating: "completed/1", count: 6),
            "여섯 변경의 최종 상태와 시도 횟수"
        )
        XCTAssertEqual(
            dispatchedFolders.count,
            5,
            "폴더 다섯이 모두 발송됐다"
        )
        XCTAssertEqual(
            dispatchedDocuments.count,
            1,
            "문서 하나가 발송됐다. 폴더 줄이 막혀도 문서 줄이 굶지 않는다"
        )
        XCTAssertEqual(orphans, [], "앞이 끊겨 남은 것이 없다")
        XCTAssertEqual(divergences, [], "기록과 칸이 붙어 있다")
    }

    /// 같은 폴더를 잇달아 여섯 번 바꾸면 무엇이 일어나는지 읽는다.
    ///
    /// 서로 다른 폴더 여섯은 독립된 여섯 줄이라 서로를 막지 않는다. 같은
    /// 폴더를 여섯 번 바꾸면 한 줄에 여섯이 늘어서고, 뒤쪽은 앞이 끝나야
    /// 기준을 받는다. 사건의 모양에 더 가깝다.
    ///
    /// 고치지 않는다. 지금 무슨 일이 일어나는지 기록으로 남긴다.
    func testSameFolderRenamedSixTimesDiagnostic() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let folderID = UUID()
        let operationIDs = (0..<6).map { _ in UUID() }

        for (index, operationID) in operationIDs.enumerated() {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.folderMutation(
                            operationID: operationID,
                            folderID: folderID,
                            name: "R\(index + 1)"
                        )
                    ]
                )
            )
        }

        // 앞의 셋만 정상으로 흘리고, 넷째에서 앞선 작업이 완료 아닌 길로
        // 끝나게 한다. 사건에서 마지막 셋이 남았다고 했다.
        var completed: [UUID] = []
        for round in 0..<3 {
            let folders = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: TimeInterval(100 + round))
            )
            guard let folder = folders.first else { break }
            completed.append(folder.operationID)
            try await store.complete(folder, result: folderCommitResult(for: folder))
        }
        let fourth = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 200)
        )
        if let stalled = fourth.first {
            try await store.markConflict(
                stalled,
                errorCode: "PATH_CONFLICT",
                detail: nil
            )
        }

        // 그 뒤로 더 흘려 본다.
        var laterRounds = 0
        for round in 0..<5 {
            let folders = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: TimeInterval(300 + round))
            )
            if folders.isEmpty { break }
            laterRounds += 1
            for folder in folders {
                completed.append(folder.operationID)
                try await store.complete(folder, result: folderCommitResult(for: folder))
            }
        }

        var states: [String] = []
        for operationID in operationIDs {
            states.append(
                try await store.operationStatus(operationID: operationID) ?? "없음"
            )
        }
        let orphans = try await store.orphanedOperationIDs()
        let stuck = try await store.operationsMissingBaseRevision()
        await store.close()

        // 지금 저장소가 실제로 하는 일을 못 박아 둔다.
        XCTAssertEqual(states.prefix(3).map { $0 }, Array(repeating: "completed", count: 3))
        XCTAssertEqual(states[3], "conflict", "넷째가 막혔다")
        XCTAssertEqual(
            Array(states.suffix(2)),
            ["pending", "pending"],
            "마지막 둘은 대기 중으로 남는다"
        )
        XCTAssertEqual(
            laterRounds,
            0,
            "넷째가 막힌 뒤로는 아무것도 발송되지 않는다"
        )
        // 넷째가 충돌로 막혀 있을 뿐 아직 살아 있다. 뒤쪽이 기다리는 것은
        // 줄을 지키는 옳은 동작이지 끊긴 것이 아니다.
        XCTAssertEqual(orphans, [], "앞이 살아 있으면 끊긴 것이 아니다")
        XCTAssertEqual(
            stuck.count,
            2,
            "다만 둘이 기준을 못 받은 채 멈춰 있다: \(stuck)"
        )
    }

    /// 막힌 폴더 작업을 취소하면 뒤쪽도 되세워져야 한다.
    ///
    /// 문서 줄과 폴더 줄이 같아야 한다. 한쪽만 되세우면 폴더를 잇달아 바꾼
    /// 사용자만 큐가 멈춘 채로 남는다.
    func testCancellingBlockedFolderLeaderAdoptsFollowers() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let folderID = UUID()
        let operationIDs = (0..<3).map { _ in UUID() }

        for (index, operationID) in operationIDs.enumerated() {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.folderMutation(
                            operationID: operationID,
                            folderID: folderID,
                            name: "R\(index + 1)"
                        )
                    ]
                )
            )
        }
        // 첫째를 집어들어 막는다.
        let claimed = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        try await store.markConflict(
            try XCTUnwrap(claimed.first),
            errorCode: "PATH_CONFLICT",
            detail: nil
        )
        // 그 첫째를 취소한다. 뒤쪽 둘은 기준을 못 받은 채로 남아 있다.
        try await store.cancelOperation(
            operationID: operationIDs[0],
            cancelEventID: UUID()
        )

        let orphans = try await store.orphanedOperationIDs()
        let stuck = try await store.operationsMissingBaseRevision()
        let ready = try await store.claimReadyFolderOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 300)
        )
        var states: [String] = []
        for operationID in operationIDs {
            states.append(
                try await store.operationStatus(operationID: operationID) ?? "없음"
            )
        }
        await store.close()

        XCTAssertEqual(states[0], "cancelled")
        XCTAssertEqual(orphans, [], "되세운 뒤에는 남은 고아가 없다")
        // 줄의 맨 앞만 되세운다. 셋째는 둘째가 살아 있으니 그 뒤에서 기다리는
        // 것이 옳다. 둘째가 끝나면 그때 기준을 받는다.
        XCTAssertEqual(
            stuck.count,
            1,
            "맨 앞만 풀리고 그다음은 줄을 지킨다: \(stuck)"
        )
        XCTAssertEqual(
            ready.map(\.operationID),
            [operationIDs[1]],
            "앞을 취소하면 뒤쪽이 다시 발송된다"
        )
        // 둘째는 방금 집어들었으니 발송 중이고, 셋째는 그 뒤에서 기다린다.
        XCTAssertEqual(
            Array(states.suffix(2)),
            ["inflight", "pending"],
            "줄을 지켜 하나씩 나간다"
        )
    }

    // MARK: - revision 충돌 되감기 (계약 대조)

    /// 되감기가 원본 작업을 보존하고 새 작업으로 이어지는지 본다.
    ///
    /// 계약은 의도를 불변으로 다룬다. 되감을 때 원본은 그대로 두고 새 작업을
    /// 만들어 원본을 밀어내라고 한다(벡터 05). 원본의 payload가 같은
    /// operation_id 아래에서 바뀌면, 서버가 그 식별자로 기억해 둔 멱등 응답이
    /// 어느 payload의 것인지 알 수 없게 된다. 다시 보냈을 때 서버는 "이미
    /// 처리했다"고 답하는데 그 내용이 지금 보내려던 것과 다를 수 있다.
    ///
    /// 새 operation과 batch는 원본을 `supersedes_operation_id`로 가리키고,
    /// 원본에는 superseded 사건만 덧붙는다. 벡터 05의 로컬 저장소 고정점이다.
    func testRebaseCreatesNewOperationAndSupersedesImmutableOriginal()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let operationID = UUID()
        let originalContent = "내가 쓴 것\n"

        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: operationID,
                        content: originalContent,
                        generation: 1
                    )
                ]
            )
        )
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let operation = try XCTUnwrap(claimed.first)
        let before = try await store.queuedOperations(documentID: context.documentID)
        let beforeHash = try XCTUnwrap(
            before.first { $0.operationID == operationID }?.contentHash
        )

        let remote = SyncV2RemoteDocumentSnapshot(
            documentID: context.documentID,
            relativePath: operation.relativePath,
            content: "서버가 가진 것\n",
            revision: operation.baseRevision + 2,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let local = try await store.latestLocalSnapshot(for: operation)
        let result = try await store.rebaseAfterRevisionConflict(
            operation,
            remote: remote,
            local: local,
            mergedContent: "내가 쓴 것\n서버가 가진 것\n",
            mergedPath: remote.relativePath
        )

        let after = try await store.queuedOperations(documentID: context.documentID)
        let events = try await store.operationEvents(operationID: operationID)
        let lineageDivergences = try await store
            .operationLineageDivergences()
        await store.close()
        let reopened = try await openStore(at: url)
        let persisted = try await reopened.queuedOperations(
            documentID: context.documentID
        )
        await reopened.close()

        XCTAssertEqual(result, .rebased)
        XCTAssertEqual(lineageDivergences, [])

        XCTAssertEqual(after.count, 2)
        let original = try XCTUnwrap(
            after.first { $0.operationID == operationID }
        )
        let rebased = try XCTUnwrap(
            after.first { $0.supersedesOperationID == operationID }
        )
        XCTAssertEqual(original.status, .cancelled)
        XCTAssertEqual(original.content, originalContent)
        XCTAssertEqual(original.contentHash, beforeHash)
        XCTAssertEqual(original.baseRevision.map(Int64.init), operation.baseRevision)

        XCTAssertNotEqual(rebased.operationID, operationID)
        XCTAssertNotEqual(rebased.batchID, operation.batchID)
        XCTAssertEqual(rebased.supersedesOperationID, operationID)
        XCTAssertEqual(rebased.automaticRebaseCount, 1)
        XCTAssertEqual(rebased.status, .pending)
        XCTAssertNotEqual(rebased.contentHash, beforeHash)
        XCTAssertEqual(
            rebased.baseRevision.map(Int64.init),
            remote.revision,
            "새 의도만 서버 기준선에서 시작한다"
        )
        XCTAssertTrue(
            events.contains { $0.type == .superseded },
            "원본은 superseded 사건으로 종결한다"
        )
        XCTAssertEqual(
            persisted.first {
                $0.supersedesOperationID == operationID
            }?.operationID,
            rebased.operationID,
            "재시작 뒤에도 supersedes 연결이 남는다"
        )
    }

    func testLineageDivergenceDetectsRebaseCountWithoutPredecessor()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()
        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(operationID: operationID),
                ]
            )
        )
        await store.close()

        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations
            SET automatic_rebase_count = 1
            WHERE operation_id = '\(operationID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let divergences = try await reopened.operationLineageDivergences()
        await reopened.close()

        XCTAssertEqual(
            divergences,
            [
                SyncV2OperationLineageDivergence(
                    operationID: operationID.uuidString.lowercased(),
                    reason: .rootHasRebaseCount
                ),
            ]
        )
    }

    /// 장부 한 줄이 어긋났다고 저장소가 통째로 안 열리면 안 된다. 사용자는
    /// 그 순간 동기화를 전부 잃는다. 어긋난 줄은 그냥 두고 눈에 띄게만 한다.
    func testDivergentOperationDoesNotBlockStoreOpen() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let operationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                mutations: [context.documentMutation(operationID: operationID)]
            )
        )
        let claimed = try await store.claimReadyOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        try await store.complete(
            try XCTUnwrap(claimed.first),
            result: commitResult(for: try XCTUnwrap(claimed.first))
        )
        await store.close()

        // 사건은 끝났다고 하는데 칸만 되돌려 놓는다. 정상 경로로는 나올 수 없는
        // 모양이지만, 옛 빌드가 남긴 장부나 앞으로 생길 실수가 이럴 수 있다.
        let raw = try RawSQLite(url: url)
        try raw.execute(
            """
            UPDATE sync_operations SET status = 'pending'
            WHERE operation_id = '\(operationID.uuidString.lowercased())';
            """
        )
        raw.close()

        let reopened = try await openStore(at: url)
        let divergences = try await reopened.operationStateDivergences()
        await reopened.close()

        XCTAssertEqual(divergences.count, 1, "어긋난 것이 눈에 보여야 한다")
        XCTAssertEqual(divergences.first?.derivedStatus, .completed)
    }

    /// 밀려난 작업은 취소된 것이 아니라 밀려난 것이다. 무엇에 밀렸는지까지
    /// 기록에 남아야 나중에 왜 사라졌는지 되짚을 수 있다.
    func testSupersededOperationRecordsSupersededEvent() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let firstID = UUID()
        let secondID = UUID()

        let treeDocumentID = UUID()
        let store = try await connectedStore(at: url, context: context)

        func enqueueTreeOrder(_ operationID: UUID, generation: Int, order: String) async throws {
            _ = try await store.enqueue(
                context.batch(
                    kind: .structureChange,
                    mutations: [
                        context.documentMutation(
                            operationID: operationID,
                            documentID: treeDocumentID,
                            relativePath: syncV2TreeOrderPath,
                            content:
                                "{\"tree_order\":{\"메인\":[\(order)]},\"version\":1}",
                            generation: generation,
                            kind: .treeOrder
                        ),
                    ]
                )
            )
        }

        try await enqueueTreeOrder(firstID, generation: 1, order: "\"가.txt\",\"나.txt\"")
        // 뒤에 온 순서가 아직 못 보낸 앞의 순서를 밀어낸다.
        try await enqueueTreeOrder(secondID, generation: 2, order: "\"나.txt\",\"가.txt\"")

        let firstEvents = try await store.operationEvents(operationID: firstID)
        let secondEvents = try await store.operationEvents(operationID: secondID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(firstEvents.last?.type, .superseded)
        XCTAssertEqual(firstEvents.last?.errorCode, "SUPERSEDED_BY_TREE_ORDER")
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: firstEvents),
            .cancelled
        )
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: secondEvents),
            .pending,
            "살아남은 순서는 그대로 대기한다"
        )
        XCTAssertEqual(divergences, [])
    }

    /// 폴더 줄도 문서 줄과 같은 문제를 안고 있다.
    func testFolderWritePathsThatDoNotYetRecordEvents() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let folderOperationID = UUID()

        let store = try await connectedStore(at: url, context: context)
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [context.folderMutation(operationID: folderOperationID)]
            )
        )
        try await store.backfillOperationEvents()
        let baseline = try await store.operationStateDivergences()
        XCTAssertEqual(baseline, [])

        let claimed = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 100)
        )
        let folder = try XCTUnwrap(claimed.first)
        try await store.complete(folder, result: folderCommitResult(for: folder))
        let events = try await store.operationEvents(operationID: folderOperationID)
        let divergences = try await store.operationStateDivergences()
        await store.close()

        XCTAssertEqual(divergences, [])
        XCTAssertEqual(events.last?.type, .committed)
    }

    /// 사건 표는 존재하지 않는 작업을 가리킬 수 없다.
    func testOperationEventRequiresExistingOperation() async throws {
        let url = try databaseURL()
        let store = try await openStore(at: url)
        await store.close()

        let raw = try RawSQLite(url: url)
        XCTAssertThrowsError(
            try raw.execute(
                """
                INSERT INTO sync_operation_events (
                    event_id, operation_id, event_sequence, event_type, recorded_at
                ) VALUES (
                    '\(UUID().uuidString.lowercased())',
                    '\(UUID().uuidString.lowercased())',
                    1, 'enqueued', '2026-08-12T00:00:00.000Z'
                );
                """
            )
        )
        raw.close()
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

    /// 계약 순서를 받은 작품은 레거시 순서 쓰기를 서버로 보내지 않는다.
    ///
    /// 보내면 계약 표가 아는 자식이 빠진 목록이 나가고, 그건 남이 넣은 폴더를
    /// 순서에서 지우는 일이다. 로컬 저장은 이미 끝났으므로 사용자가 방금 바꾼
    /// 순서는 화면에 남는다 — 막는 것은 전송뿐이다.
    func testLegacyTreeOrderWriteIsRefusedOnceContractOrderArrives()
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
        let serverProjectID = UUID()
        try await recorder.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .existingServerProject,
                projectName: "계약 순서 작품",
                ownerSubject: UUID()
            )
        )

        func recordTreeOrder() async -> DurableRecordResult {
            await recorder.record(
                LocalMutationBatch(
                    batchID: UUID(),
                    projectID: localProjectID,
                    localTransactionID: UUID(),
                    kind: .structureChange,
                    mutations: [
                        .treeOrder(
                            operationID: UUID(),
                            content: "{\"tree_order\":{},\"version\":1}",
                            generation: 7
                        )
                    ]
                )
            )
        }

        // 계약 순서를 받기 전에는 막을 이유가 없다.
        guard case .queued = await recordTreeOrder() else {
            return XCTFail("계약 순서 이전에는 레거시 순서가 나가야 한다.")
        }

        try await recorder.applyTreeOrderSnapshotBaselines(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: UUID(),
                    parentFolderID: UUID(),
                    children: [UUID(), UUID()],
                    revision: 3,
                    updatedAt: Date(timeIntervalSince1970: 30)
                )
            ]
        )

        guard case let .localSavedButNotQueued(reason) = await recordTreeOrder()
        else {
            return XCTFail("계약 순서를 받은 뒤에도 레거시 순서가 나갔다.")
        }
        XCTAssertTrue(
            reason.contains("계약 순서"),
            "막힌 이유가 사용자에게 설명되지 않는다: \(reason)"
        )
    }

    func testContractFolderCreatePersistsImmutableAtomicBatchBeforeSend()
        async throws {
        let url = try databaseURL()
        let deviceID = UUID()
        let recorder = LazySyncV2ProjectBindingStore(
            databaseURL: url,
            deviceIdentityProvider: DeviceIdentityService(
                store: InMemoryDeviceIdentityStore(),
                generateUUID: { deviceID }
            )
        )
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let ownerID = UUID()
        let binding = ProjectSyncBinding.connected(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: .existingServerProject,
            projectName: "contract canary",
            ownerSubject: ownerID
        )
        try await recorder.save(binding)
        let parentID = UUID()
        let existingChild = UUID()
        let treeOrderID = UUID()
        try await recorder.applyFolderSnapshotBaselines(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            folders: [
                SyncV2RemoteFolder(
                    folderID: parentID,
                    parentFolderID: nil,
                    name: "메모장",
                    revision: 1,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 10)
                )
            ],
            excluding: []
        )
        try await recorder.applyTreeOrderSnapshotBaselines(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: treeOrderID,
                    parentFolderID: parentID,
                    children: [existingChild],
                    revision: 3,
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            ]
        )
        let batchID = UUID()
        let folderOperationID = UUID()
        let orderOperationID = UUID()
        let folderID = DocumentID(rawValue: UUID())
        let batch = LocalMutationBatch(
            batchID: batchID,
            projectID: localProjectID,
            localTransactionID: UUID(),
            kind: .structureChange,
            mutations: [
                .folderSnapshot(
                    operationID: folderOperationID,
                    folderID: folderID,
                    parentFolderID: DocumentID(rawValue: parentID),
                    name: "계약경로검증4",
                    isDeleted: false
                ),
                .treeOrder(
                    operationID: orderOperationID,
                    content: "{\"tree_order\":{},\"version\":1}",
                    generation: 1
                ),
            ]
        )
        let handshake = SyncV2ValidatedHandshake(
            serverProjectID: serverProjectID,
            projectSyncMode: .legacy,
            migrationEpoch: 0,
            contractVersion: SyncV2Contract.version,
            contractSHA256: SyncV2Contract.canonicalSHA256,
            serverProtocolVersion: SyncV2Contract.syncProtocolVersion,
            supportedProtocolVersions: [SyncV2Contract.syncProtocolVersion],
            serverCapabilities: Array(
                SyncV2Contract.requiredServerCapabilities
            ).sorted()
        )

        let operationIDs = try await recorder.enqueueContractStructure(
            batch,
            binding: binding,
            handshake: handshake
        )

        XCTAssertEqual(operationIDs, [folderOperationID, orderOperationID])
        var uploadQueue = try await recorder.uploadQueueSnapshot(
            localProjectID: localProjectID
        )
        XCTAssertEqual(uploadQueue.pendingCount, 1)
        XCTAssertEqual(uploadQueue.inflightCount, 0)
        let raw = try RawSQLite(url: url)
        XCTAssertEqual(
            try raw.scalarText(
                "SELECT status FROM sync_contract_batches LIMIT 1;"
            ),
            "ready"
        )
        XCTAssertEqual(
            try raw.scalarInt(
                "SELECT COUNT(*) FROM sync_contract_operations;"
            ),
            2
        )
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT base_revision FROM sync_contract_operations
                WHERE entity_kind = 'tree_order';
                """
            ),
            3
        )
        let request = try raw.scalarText(
            "SELECT request_json FROM sync_contract_batches LIMIT 1;"
        )
        XCTAssertTrue(request.contains("atomic_structure_commit_request"))
        XCTAssertTrue(request.contains(folderID.rawValue.uuidString.lowercased()))
        XCTAssertTrue(request.contains(existingChild.uuidString.lowercased()))
        XCTAssertTrue(request.contains("\"status\"") == false)

        let firstClaim = try await recorder.claimNextContractStructure(
            localProjectID: localProjectID
        )
        uploadQueue = try await recorder.uploadQueueSnapshot(
            localProjectID: localProjectID
        )
        XCTAssertEqual(uploadQueue.pendingCount, 0)
        XCTAssertEqual(uploadQueue.inflightCount, 1)
        XCTAssertEqual(firstClaim.request.batchID, batchID)
        try await recorder.recoverInterruptedWork()
        let pending = try await recorder.claimNextContractStructure(
            localProjectID: localProjectID
        )
        XCTAssertEqual(pending.request.batchID, batchID)
        XCTAssertEqual(pending.request.json, firstClaim.request.json)
        let resultRevisions = [1, 4]
        let results = zip(
            pending.request.orderedIntents,
            resultRevisions
        ).map { intent, revision -> SyncV2JSON in
            let fields = intent.objectValue!
            return .object([
                "sequence": fields["sequence"]!,
                "operation_id": fields["operation_id"]!,
                "entity_id": fields["entity_id"]!,
                "result_revision": .int(revision),
            ])
        }
        let response = SyncV2JSON.object([
            "kind": .string("atomic_structure_commit_success"),
            "batch_id": .string(batchID.uuidString.lowercased()),
            "batch_payload_sha256": .string(
                pending.request.batchPayloadSHA256
            ),
            "status": .string("committed"),
            "applied": .bool(true),
            "results": .array(results),
        ])
        XCTAssertEqual(
            try SyncV2Contract.validateAtomicStructureResponse(
                request: pending.request,
                response: response
            ),
            .committed
        )
        try await recorder.completeContractStructure(
            pending,
            response: response
        )
        uploadQueue = try await recorder.uploadQueueSnapshot(
            localProjectID: localProjectID
        )
        XCTAssertEqual(uploadQueue, .idle)
        XCTAssertEqual(
            try raw.scalarText(
                "SELECT status FROM sync_contract_batches LIMIT 1;"
            ),
            "completed"
        )
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT server_revision FROM sync_tree_orders
                WHERE tree_order_id = '\(treeOrderID.uuidString.lowercased())';
                """
            ),
            4
        )
        XCTAssertEqual(
            try raw.scalarInt(
                """
                SELECT server_revision FROM sync_folders
                WHERE folder_id = '\(folderID.rawValue.uuidString.lowercased())';
                """
            ),
            1
        )
    }

    /// 순서 문서만 막고 폴더는 내보내면 서버에 반쯤 적용된 구조가 남는다.
    ///
    /// 폴더 생성·이름변경·삭제는 commit_folder로 따로 나가므로, 순서만 막는
    /// 구현은 이 시험을 통과하지 못한다.
    func testLegacyFolderWritesAreRefusedOnceContractOrderArrives()
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
        let serverProjectID = UUID()
        try await recorder.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .existingServerProject,
                projectName: "계약 순서 작품",
                ownerSubject: UUID()
            )
        )

        func recordFolder(
            folderID: DocumentID,
            name: String,
            isDeleted: Bool
        ) async -> DurableRecordResult {
            await recorder.record(
                LocalMutationBatch(
                    batchID: UUID(),
                    projectID: localProjectID,
                    localTransactionID: UUID(),
                    kind: .structureChange,
                    mutations: [
                        .folderSnapshot(
                            operationID: UUID(),
                            folderID: folderID,
                            parentFolderID: nil,
                            name: name,
                            isDeleted: isDeleted
                        )
                    ]
                )
            )
        }

        try await recorder.applyTreeOrderSnapshotBaselines(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: UUID(),
                    parentFolderID: UUID(),
                    children: [UUID()],
                    revision: 3,
                    updatedAt: Date(timeIntervalSince1970: 30)
                )
            ]
        )

        // 생성·이름변경·삭제 셋 다 나가지 않아야 한다.
        let folderID = DocumentID(rawValue: UUID())
        for (name, isDeleted) in [
            ("새 폴더", false), ("바뀐 이름", false), ("바뀐 이름", true),
        ] {
            guard case .localSavedButNotQueued = await recordFolder(
                folderID: folderID,
                name: name,
                isDeleted: isDeleted
            ) else {
                return XCTFail(
                    "계약 순서를 받은 뒤에도 레거시 폴더 변경이 나갔다: \(name)"
                )
            }
        }

        // 큐에 아무것도 남지 않아야 한다. 하나라도 있으면 서버에 반쯤 적용된
        // 구조가 생긴다.
        let inspection = try await openStore(at: url)
        let queued = try await inspection.queuedOperations(
            documentID: folderID.rawValue
        )
        XCTAssertTrue(
            queued.isEmpty,
            "레거시 폴더 작업이 큐에 남았다: \(queued.count)건"
        )
        await inspection.close()
    }

    /// 계약 이력은 한 번 생기면 되돌아가지 않는다.
    ///
    /// 서버가 빈 응답을 주거나 RLS가 어긋나 아무것도 못 읽는 날, 이력이 지워지면
    /// 방어가 조용히 풀린다. 빈 적용이 이력을 지우지 않는지 못 박는다.
    func testContractTreeOrderHistorySurvivesAnEmptySnapshot() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)

        try await store.applyTreeOrderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: UUID(),
                    parentFolderID: UUID(),
                    children: [UUID()],
                    revision: 2,
                    updatedAt: Date(timeIntervalSince1970: 30)
                )
            ]
        )
        var hasHistory = try await store.hasContractTreeOrderHistory(
            localProjectID: context.localProjectID
        )
        XCTAssertTrue(hasHistory)

        // 빈 응답을 그대로 적용해도 이력은 남아야 한다.
        try await store.applyTreeOrderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            treeOrders: []
        )
        hasHistory = try await store.hasContractTreeOrderHistory(
            localProjectID: context.localProjectID
        )
        XCTAssertTrue(hasHistory, "빈 snapshot 적용으로 계약 이력이 지워졌다")
        await store.close()

        let reopened = try await openStore(at: url)
        let restoredHistory = try await reopened.hasContractTreeOrderHistory(
            localProjectID: context.localProjectID
        )
        XCTAssertTrue(restoredHistory, "재시작 뒤 계약 이력이 사라졌다")
        await reopened.close()
    }

    // MARK: - 계약 tree_order

    /// 서버가 말한 순서와 revision을 그대로 들고 있어야 한다. revision은 우리가
    /// 만들어낼 수 없는 값이고, 그게 없으면 base 0으로 보내 거절당한다.
    func testContractTreeOrderKeepsServerChildrenAndRevision() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let parent = UUID()
        let children = [UUID(), UUID(), UUID()]

        try await store.applyTreeOrderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: UUID(),
                    parentFolderID: parent,
                    children: children,
                    revision: 3,
                    updatedAt: Date(timeIntervalSince1970: 30)
                )
            ]
        )

        let stored = try await store.storedTreeOrder(
            localProjectID: context.localProjectID,
            parentFolderID: parent
        )
        XCTAssertEqual(stored?.children, children)
        XCTAssertEqual(stored?.serverRevision, 3)
        await store.close()

        // 재시작해도 남아 있어야 한다. 순서는 쓰기 직전에 필요한 값이라
        // 세션 안에서만 살아 있으면 다음 실행의 첫 쓰기가 막힌다.
        let reopened = try await openStore(at: url)
        let restored = try await reopened.storedTreeOrder(
            localProjectID: context.localProjectID,
            parentFolderID: parent
        )
        XCTAssertEqual(restored?.children, children)
        XCTAssertEqual(restored?.serverRevision, 3)
        await reopened.close()
    }

    /// 최상위는 parent가 NULL이다. SQLite는 UNIQUE에서 NULL을 서로 다르게 보므로
    /// 두 번 받아도 한 줄이어야 한다.
    func testContractTreeOrderRootStaysASingleRow() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let first = [UUID()]
        let second = [UUID(), UUID()]
        let treeOrderID = UUID()

        for (children, revision) in [(first, Int64(1)), (second, Int64(2))] {
            try await store.applyTreeOrderSnapshotBaselines(
                localProjectID: context.localProjectID,
                serverProjectID: context.serverProjectID,
                treeOrders: [
                    SyncV2RemoteTreeOrder(
                        treeOrderID: treeOrderID,
                        parentFolderID: nil,
                        children: children,
                        revision: revision,
                        updatedAt: Date(timeIntervalSince1970: 30)
                    )
                ]
            )
        }

        let stored = try await store.storedTreeOrder(
            localProjectID: context.localProjectID,
            parentFolderID: nil
        )
        XCTAssertEqual(stored?.children, second)
        XCTAssertEqual(stored?.serverRevision, 2)
        await store.close()
    }

    /// 계약 순서를 받은 적이 없으면 레거시 순서 쓰기를 막을 이유가 없다.
    func testContractTreeOrderHistoryIsFalseUntilServerSpeaks() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)

        var hasHistory = try await store.hasContractTreeOrderHistory(
            localProjectID: context.localProjectID
        )
        XCTAssertFalse(hasHistory)

        try await store.applyTreeOrderSnapshotBaselines(
            localProjectID: context.localProjectID,
            serverProjectID: context.serverProjectID,
            treeOrders: [
                SyncV2RemoteTreeOrder(
                    treeOrderID: UUID(),
                    parentFolderID: UUID(),
                    children: [UUID()],
                    revision: 1,
                    updatedAt: Date(timeIntervalSince1970: 30)
                )
            ]
        )

        hasHistory = try await store.hasContractTreeOrderHistory(
            localProjectID: context.localProjectID
        )
        XCTAssertTrue(hasHistory)
        await store.close()
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

    // MARK: - codex 계보에서 가져온 시험
    // 두 계보가 같은 자리에 서로 다른 시험을 넣어 엉켰다. 한쪽을 고르면
    // 그쪽 시험만 돌아 A 판정 자체가 무의미해지므로 합집합으로 남긴다.

    func testEnqueuedInitialSnapshotWithUnclearedMarkerReplaysSameIDs()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-EnqueuedInitialInterruption-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let mainID = DocumentID(rawValue: UUID())
        let repository = InitialSnapshotDocumentRepository([
            DocumentNode(
                id: mainID,
                projectID: projectID,
                kind: .folder,
                parentID: nil,
                relativePath: .init(rawValue: "메인"),
                userOrder: 0,
                modifiedAt: Date(timeIntervalSince1970: 1),
                contentHash: nil
            ),
        ])
        let durable = ScriptedDurableChangeRecorder(
            results: [
                .queued(operationIDs: []),
                .queued(operationIDs: []),
            ]
        )
        let interrupted = ProjectInitialSyncRecorder(
            documentRepository: repository,
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable,
            fileManager: FailingMarkerRemovalFileManager()
        )

        _ = await interrupted.recordInitialSnapshot(
            projectID: projectID,
            projectName: "enqueue 뒤 중단",
            batchKind: .projectBinding
        )

        let marker = root.appendingPathComponent(
            ProjectInitialSyncRecorder.newProjectMarkerName
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let firstAttempts = await durable.batches
        let first = try XCTUnwrap(firstAttempts.first)

        let restarted = ProjectInitialSyncRecorder(
            documentRepository: repository,
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )
        _ = await restarted.recordInitialSnapshot(
            projectID: projectID,
            projectName: "enqueue 뒤 중단",
            batchKind: .projectBinding
        )

        let attempts = await durable.batches
        XCTAssertEqual(attempts, [first, first])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testInitialSnapshotPreservesLiveIdentitiesAndSkipsTrashedFolders()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-NativeFolderIdentity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let projectID = ProjectID(rawValue: UUID())
        let mainID = DocumentID(rawValue: UUID())
        let standardNames = [
            "원고", "캐릭터", "설정집", "메모장", "스토리 플롯",
            "흐름정리", "복선", "장소", "휴지통",
        ]
        let standardIDs = Dictionary(
            uniqueKeysWithValues: standardNames.map {
                ($0, DocumentID(rawValue: UUID()))
            }
        )
        let date = Date(timeIntervalSince1970: 1)
        var nodes = [
            DocumentNode(
                id: mainID,
                projectID: projectID,
                kind: .folder,
                parentID: nil,
                relativePath: .init(rawValue: "메인"),
                userOrder: 0,
                modifiedAt: date,
                contentHash: nil
            ),
        ]
        for (order, name) in standardNames.enumerated() {
            nodes.append(
                DocumentNode(
                    id: standardIDs[name]!,
                    projectID: projectID,
                    kind: .folder,
                    parentID: mainID,
                    relativePath: .init(rawValue: "메인/\(name)"),
                    userOrder: order,
                    modifiedAt: date,
                    contentHash: nil
                )
            )
        }
        let decomposedName = "가"
        let userFolderID = DocumentID(rawValue: UUID())
        let emptyFolderID = DocumentID(rawValue: UUID())
        let trashedFolderID = DocumentID(rawValue: UUID())
        nodes.append(
            contentsOf: [
                DocumentNode(
                    id: userFolderID,
                    projectID: projectID,
                    kind: .folder,
                    parentID: standardIDs["메모장"],
                    relativePath: .init(
                        rawValue: "메인/메모장/\(decomposedName)"
                    ),
                    userOrder: 0,
                    modifiedAt: date,
                    contentHash: nil
                ),
                DocumentNode(
                    id: emptyFolderID,
                    projectID: projectID,
                    kind: .folder,
                    parentID: standardIDs["설정집"],
                    relativePath: .init(rawValue: "메인/설정집/빈 폴더"),
                    userOrder: 0,
                    modifiedAt: date,
                    contentHash: nil
                ),
                DocumentNode(
                    id: trashedFolderID,
                    projectID: projectID,
                    kind: .folder,
                    parentID: standardIDs["휴지통"],
                    relativePath: .init(rawValue: "메인/휴지통/삭제 폴더"),
                    userOrder: 0,
                    modifiedAt: date,
                    contentHash: nil,
                    deletionStatus: .trashed(
                        originalPath: .init(rawValue: "메인/메모장/삭제 폴더"),
                        deletedAt: date
                    )
                ),
            ]
        )
        let liveID = DocumentID(rawValue: UUID())
        let deletedID = DocumentID(rawValue: UUID())
        let livePath = RelativeDocumentPath(
            rawValue: "메인/메모장/원본.txt"
        )
        let originalBytes = Data("원본\r\n가".utf8)
        try originalBytes.write(to: root.appendingPathComponent(livePath.rawValue))
        nodes.append(
            contentsOf: [
                DocumentNode(
                    id: liveID,
                    projectID: projectID,
                    kind: .text,
                    parentID: standardIDs["메모장"],
                    relativePath: livePath,
                    userOrder: 1,
                    modifiedAt: date,
                    contentHash: nil
                ),
                DocumentNode(
                    id: deletedID,
                    projectID: projectID,
                    kind: .text,
                    parentID: standardIDs["휴지통"],
                    relativePath: .init(rawValue: "메인/휴지통/삭제.txt"),
                    userOrder: 1,
                    modifiedAt: date,
                    contentHash: nil,
                    deletionStatus: .trashed(
                        originalPath: .init(rawValue: "메인/메모장/삭제.txt"),
                        deletedAt: date
                    )
                ),
            ]
        )
        // 저장소 반환 순서가 identity wire order에 영향을 주지 않아야 한다.
        nodes.reverse()
        let durable = ScriptedDurableChangeRecorder(
            results: [.queued(operationIDs: [])]
        )
        let recorder = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository(nodes),
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )

        _ = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "identity",
            batchKind: .projectBinding
        )

        let recordedBatches = await durable.batches
        let batch = try XCTUnwrap(recordedBatches.first)
        var snapshots: [DocumentID: (DocumentID?, String, Bool, Int)] = [:]
        for (index, mutation) in batch.mutations.enumerated() {
            if case let .folderSnapshot(
                _, folderID, parentID, name, isDeleted
            ) = mutation {
                snapshots[folderID] = (parentID, name, isDeleted, index)
            }
        }
        XCTAssertEqual(snapshots.count, 12)
        XCTAssertEqual(
            Set(snapshots.keys),
            Set(nodes.filter {
                $0.kind == .folder && $0.id != trashedFolderID
            }.map(\.id))
        )
        XCTAssertEqual(snapshots[mainID]?.0, nil)
        XCTAssertEqual(snapshots[standardIDs["휴지통"]!]?.0, mainID)
        XCTAssertEqual(snapshots[userFolderID]?.0, standardIDs["메모장"])
        XCTAssertEqual(snapshots[userFolderID]?.1, "가")
        XCTAssertEqual(snapshots[emptyFolderID]?.0, standardIDs["설정집"])
        // base_revision 0의 삭제 폴더는 서버가 INVALID_ARGUMENT로 거절한다.
        // 고정 휴지통은 live로 보내되 그 아래 폴더 operation은 만들지 않는다.
        XCTAssertFalse(snapshots[standardIDs["휴지통"]!]?.2 ?? true)
        XCTAssertNil(snapshots[trashedFolderID])
        XCTAssertNotEqual(
            userFolderID,
            SyncV2FolderIdentity.derived(
                serverProjectID: projectID.rawValue,
                relativePath: "메인/메모장/\(decomposedName)"
            )
        )

        let documentMutations = batch.mutations.compactMap { mutation ->
            (DocumentID, String, ContentHash)? in
            guard case let .documentSnapshot(
                _, id, _, content, hash, _, _
            ) = mutation else { return nil }
            return (id, content, hash)
        }
        XCTAssertEqual(documentMutations.count, 1)
        XCTAssertEqual(documentMutations.first?.0, liveID)
        XCTAssertEqual(Data(documentMutations.first!.1.utf8), originalBytes)
        XCTAssertEqual(
            documentMutations.first?.2,
            SHA256ContentHasher().sha256(for: originalBytes)
        )
        XCTAssertFalse(documentMutations.contains { $0.0 == deletedID })

        guard case let .treeOrder(_, content, _) = batch.mutations.last else {
            return XCTFail("tree_order가 마지막 mutation이어야 합니다.")
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(content.utf8))
                as? [String: Any]
        )
        let tree = try XCTUnwrap(object["tree_order"] as? [String: [String]])
        XCTAssertEqual(tree["<root>"], standardNames)
        XCTAssertEqual(tree["메인/메모장"], ["가", "원본.txt"])
        XCTAssertEqual(tree["메인/설정집"], ["빈 폴더"])
        XCTAssertEqual(Set(tree["<root>"] ?? []).count, 9)
    }

    func testMarkerlessInitialSnapshotStateFailureNeverGuessesNewIDs()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-MarkerlessInitial-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let durable = UnavailableInitialSnapshotStateRecorder()
        let recorder = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository([]),
            workspaceLocator: FixedWorkspaceLocator(root: root),
            durableChangeRecorder: durable
        )

        let result = await recorder.recordInitialSnapshot(
            projectID: projectID,
            projectName: "불일치",
            batchKind: .projectBinding
        )

        XCTAssertEqual(
            result,
            .localSavedButNotQueued(
                reason: "초기 작품 동기화 완료 상태를 확인할 수 없습니다."
            )
        )
        let recordCallCount = await durable.recordCallCount()
        XCTAssertEqual(recordCallCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ProjectInitialSyncRecorder.newProjectMarkerName
                ).path
            )
        )
    }

    func testContractPathRecorderForwardsRecordedInitialSnapshotAndSkipsReplay()
        async throws {
        let database = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: database, context: context)
        _ = try await store.enqueue(
            context.batch(
                kind: .projectBinding,
                mutations: [
                    .ensureProject(
                        SyncV2EnsureProjectMutation(
                            operationID: UUID(),
                            projectName: context.binding.projectName
                        )
                    ),
                ]
            )
        )
        await store.close()

        let defaultsName = "WriterPad-ContractRecorder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: defaultsName)
        }
        let recorder = SyncV2ContractPathRecorder(
            store: LazySyncV2ProjectBindingStore(databaseURL: database),
            handshakeService: nil,
            authenticationService: InitialSnapshotAuthenticationStub(),
            defaults: defaults
        )

        let hasRecorded = try await recorder.hasRecordedInitialSnapshot(
            for: context.localProjectID,
            kind: .projectBinding
        )
        XCTAssertTrue(hasRecorded)

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-ContractRecorder-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }
        let initial = ProjectInitialSyncRecorder(
            documentRepository: InitialSnapshotDocumentRepository([]),
            workspaceLocator: FixedWorkspaceLocator(root: workspace),
            durableChangeRecorder: recorder
        )

        let result = await initial.recordInitialSnapshot(
            projectID: context.localProjectID,
            projectName: context.binding.projectName,
            batchKind: .projectBinding
        )

        XCTAssertEqual(result, .notNeeded)
        let raw = try RawSQLite(url: database)
        XCTAssertEqual(
            try raw.scalarInt(
                "SELECT COUNT(*) FROM sync_batches WHERE batch_kind = 'project_binding';"
            ),
            1
        )
        raw.close()
    }

    func testContractPathRecorderPropagatesInitialSnapshotLookupFailure()
        async throws {
        let database = try databaseURL()
        let raw = try RawSQLite(url: database)
        try raw.execute(
            """
            CREATE TABLE unknown_user_data(value TEXT NOT NULL);
            PRAGMA user_version = 0;
            """
        )
        raw.close()
        let recorder = SyncV2ContractPathRecorder(
            store: LazySyncV2ProjectBindingStore(databaseURL: database),
            handshakeService: nil,
            authenticationService: InitialSnapshotAuthenticationStub()
        )

        do {
            _ = try await recorder.hasRecordedInitialSnapshot(
                for: ProjectID(rawValue: UUID()),
                kind: .projectBinding
            )
            XCTFail("초기 snapshot 조회 실패를 false로 바꾸면 안 됩니다.")
        } catch {
            // fail-closed: 저장소 조회 실패를 호출자에게 그대로 전달한다.
        }
    }

    func testNativeBindingAtomicallyCompletesFolderMigrationButLegacyDoesNot()
        async throws {
        let store = try await openStore(at: databaseURL())
        let owner = UUID()
        let nativeID = ProjectID(rawValue: UUID())
        let windowsID = ProjectID(rawValue: UUID())
        let legacyID = ProjectID(rawValue: UUID())

        try await store.save(
            .connected(
                localProjectID: nativeID,
                serverProjectID: nativeID.rawValue,
                kind: .newServerProject,
                projectName: "native",
                ownerSubject: owner
            )
        )
        try await store.save(
            .connected(
                localProjectID: windowsID,
                serverProjectID: UUID(),
                kind: .windowsImport,
                projectName: "windows",
                ownerSubject: owner
            )
        )
        try await store.save(
            .connected(
                localProjectID: legacyID,
                serverProjectID: UUID(),
                kind: .existingServerProject,
                projectName: "legacy",
                ownerSubject: owner
            )
        )

        let nativeCompleted = try await store.isFolderMigrationCompleted(
            localProjectID: nativeID
        )
        let windowsCompleted = try await store.isFolderMigrationCompleted(
            localProjectID: windowsID
        )
        let legacyCompleted = try await store.isFolderMigrationCompleted(
            localProjectID: legacyID
        )
        XCTAssertTrue(nativeCompleted)
        XCTAssertTrue(windowsCompleted)
        XCTAssertFalse(legacyCompleted)
        await store.close()
    }

    func testThreeLevelFolderTombstonesCommitDeepestFirst() async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let childID = UUID()
        let grandchildID = UUID()
        let parentDeleteID = UUID()
        let childDeleteID = UUID()
        let grandchildDeleteID = UUID()

        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: UUID(),
                        name: "부모"
                    ),
                    context.folderMutation(
                        operationID: UUID(),
                        folderID: childID,
                        parentFolderID: context.folderID,
                        name: "자식"
                    ),
                    context.folderMutation(
                        operationID: UUID(),
                        folderID: grandchildID,
                        parentFolderID: childID,
                        name: "손자"
                    ),
                ]
            )
        )
        // 두 폴더의 생성을 끝내 무덤이 기준선을 갖게 한다. 그러지 않으면
        // 순번이 아니라 아직 비어 있는 base_revision이 무덤을 붙잡는다.
        //
        // 생성에도 부모 게이트가 걸려 한 번에 다 잡히지 않는다. 부모가 끝나야
        // 자식이 준비되므로 더 나올 것이 없을 때까지 돈다.
        while true {
            let created = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: 10)
            )
            if created.isEmpty { break }
            for operation in created {
                try await store.complete(
                    operation,
                    result: folderCommitResult(for: operation)
                )
            }
        }
        _ = try await store.enqueue(
            context.batch(
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: parentDeleteID,
                        name: "부모",
                        isDeleted: true
                    ),
                    context.folderMutation(
                        operationID: childDeleteID,
                        folderID: childID,
                        parentFolderID: context.folderID,
                        name: "자식",
                        isDeleted: true
                    ),
                    context.folderMutation(
                        operationID: grandchildDeleteID,
                        folderID: grandchildID,
                        parentFolderID: childID,
                        name: "손자",
                        isDeleted: true
                    ),
                ]
            )
        )

        var committed: [UUID] = []
        for timestamp in [20.0, 30.0, 40.0] {
            let ready = try await store.claimReadyFolderOperations(
                limit: 10,
                now: Date(timeIntervalSince1970: timestamp)
            )
            let operation = try XCTUnwrap(ready.first)
            XCTAssertEqual(ready.count, 1)
            committed.append(operation.operationID)
            try await store.complete(
                operation,
                result: folderCommitResult(for: operation)
            )
        }

        // A/B/C를 부모 우선으로 enqueue해도 서버에는 C/B/A만 나갈 수 있다.
        // A가 먼저 나가면 live 자식 때문에 FOLDER_NOT_EMPTY가 된다.
        XCTAssertEqual(
            committed,
            [grandchildDeleteID, childDeleteID, parentDeleteID]
        )
        await store.close()
    }

    func testRemoteDeletionRecoveryIsIdempotentAndCancelsOnlyItsBatch()
        async throws {
        let url = try databaseURL()
        let context = QueueAPIContext()
        let store = try await connectedStore(at: url, context: context)
        let batchID = UUID()
        let renameOperationID = UUID()
        let treeOrderOperationID = UUID()
        let unrelatedDocumentID = UUID()
        let unrelatedOperationID = UUID()
        _ = try await store.enqueue(
            context.batch(
                batchID: batchID,
                kind: .structureChange,
                mutations: [
                    context.folderMutation(
                        operationID: renameOperationID,
                        name: "삭제시험-아이패드"
                    ),
                    context.documentMutation(
                        operationID: treeOrderOperationID,
                        documentID: syncV2UUIDv5(
                            namespace: context.serverProjectID,
                            name: syncV2TreeOrderPath
                        ),
                        relativePath: syncV2TreeOrderPath,
                        content: #"{"tree_order":{},"version":1}"#,
                        generation: 1,
                        kind: .treeOrder
                    ),
                ]
            )
        )
        _ = try await store.enqueue(
            context.batch(
                mutations: [
                    context.documentMutation(
                        operationID: unrelatedOperationID,
                        documentID: unrelatedDocumentID,
                        relativePath: "메모장/다른 폴더/정상.txt",
                        content: "계속 동기화할 본문"
                    ),
                ]
            )
        )
        let readyFolders = try await store.claimReadyFolderOperations(
            limit: 1,
            now: Date(timeIntervalSince1970: 10)
        )
        let operation = try XCTUnwrap(readyFolders.first)
        let payloadPath = "fixture.writerpad-recovery"
        let first = try await store.beginRemoteDeletionRecovery(
            operation: operation,
            tombstoneRevision: 2,
            displayName: operation.name,
            payloadRelativePath: payloadPath
        )
        let replay = try await store.beginRemoteDeletionRecovery(
            operation: operation,
            tombstoneRevision: 2,
            displayName: operation.name,
            payloadRelativePath: payloadPath
        )
        XCTAssertEqual(replay.id, first.id)
        XCTAssertEqual(replay.state, .preparing)

        let root = ConflictRecoveryEntity(
            kind: .folder,
            sourceEntityID: operation.folderID,
            restoredEntityID: nil,
            parentSourceEntityID: nil,
            relativePath: operation.name,
            title: operation.name,
            userOrder: 0,
            byteCount: nil,
            sha256: nil,
            restoreStatus: .pending
        )
        try await store.markConflictRecoveryReady(
            packageID: first.id,
            manifestSHA256: String(repeating: "a", count: 64),
            fileCount: 0,
            totalBytes: 0,
            entities: [root]
        )
        try await store.resolveRemoteDeletionSource(packageID: first.id)
        try await store.resolveRemoteDeletionSource(packageID: first.id)

        let packages = try await store.conflictRecoveryPackages(
            localProjectID: context.localProjectID
        )
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.state, .sourceResolved)
        let entities = try await store.conflictRecoveryEntities(packageID: first.id)
        let renameEvents = try await store.operationEvents(
            operationID: renameOperationID
        )
        let treeOrderEvents = try await store.operationEvents(
            operationID: treeOrderOperationID
        )
        let stateDivergences = try await store.operationStateDivergences()
        let lineageDivergences = try await store.operationLineageDivergences()
        let orphanedIDs = try await store.orphanedOperationIDs()
        let unrelated = try await store.queuedOperations(
            documentID: unrelatedDocumentID
        )
        let raw = try RawSQLite(url: url)
        let sourceBatchStatus = try raw.scalarText(
            """
            SELECT status FROM sync_batches
            WHERE batch_id = '\(batchID.uuidString.lowercased())';
            """
        )
        let sourceBatchError = try raw.scalarText(
            """
            SELECT last_error_code FROM sync_batches
            WHERE batch_id = '\(batchID.uuidString.lowercased())';
            """
        )
        raw.close()
        XCTAssertEqual(entities, [root])
        XCTAssertEqual(renameEvents.last?.type, .cancelRequested)
        XCTAssertEqual(treeOrderEvents.last?.type, .cancelRequested)
        XCTAssertEqual(sourceBatchStatus, "completed")
        XCTAssertEqual(sourceBatchError, "REMOTE_DELETION")
        XCTAssertEqual(stateDivergences, [])
        XCTAssertEqual(lineageDivergences, [])
        XCTAssertEqual(orphanedIDs, [])
        XCTAssertEqual(unrelated.map(\.operationID), [unrelatedOperationID])

        let restoredFolderID = UUID()
        let restoreBatchID = UUID()
        try await store.markConflictRecoveryRestoreEnqueued(
            packageID: first.id,
            restoreBatchID: restoreBatchID,
            restoredEntityIDs: [operation.folderID: restoredFolderID]
        )
        try await store.markConflictRecoveryRestoreEnqueued(
            packageID: first.id,
            restoreBatchID: restoreBatchID,
            restoredEntityIDs: [operation.folderID: restoredFolderID]
        )
        var restoredPackages = try await store.conflictRecoveryPackages(
            localProjectID: context.localProjectID
        )
        var restoredEntities = try await store.conflictRecoveryEntities(
            packageID: first.id
        )
        XCTAssertEqual(restoredPackages.first?.state, .restoreEnqueued)
        XCTAssertEqual(restoredPackages.first?.restoreBatchID, restoreBatchID)
        XCTAssertEqual(restoredEntities.first?.restoredEntityID, restoredFolderID)
        XCTAssertEqual(restoredEntities.first?.restoreStatus, .enqueued)

        try await store.markConflictRecoveryRestored(packageID: first.id)
        restoredPackages = try await store.conflictRecoveryPackages(
            localProjectID: context.localProjectID
        )
        restoredEntities = try await store.conflictRecoveryEntities(
            packageID: first.id
        )
        XCTAssertEqual(restoredPackages.first?.state, .restored)
        XCTAssertEqual(restoredEntities.first?.restoreStatus, .committed)
        await store.close()

        // 수정 전 실기기 DB 모양을 재현한다. 앱이 transaction 직후 꺼졌거나
        // 구버전이 남긴 stale batch라도 다음 실행에서 같은 투영으로 치유한다.
        let stale = try RawSQLite(url: url)
        try stale.execute(
            """
            UPDATE sync_batches
            SET status = 'processing',
                last_error_code = 'NETWORK_UNAVAILABLE'
            WHERE batch_id = '\(batchID.uuidString.lowercased())';
            """
        )
        stale.close()

        let reopened = try await openStore(at: url)
        await reopened.close()
        let healed = try RawSQLite(url: url)
        XCTAssertEqual(
            try healed.scalarText(
                """
                SELECT status FROM sync_batches
                WHERE batch_id = '\(batchID.uuidString.lowercased())';
                """
            ),
            "completed"
        )
        XCTAssertEqual(
            try healed.scalarText(
                """
                SELECT last_error_code FROM sync_batches
                WHERE batch_id = '\(batchID.uuidString.lowercased())';
                """
            ),
            "REMOTE_DELETION"
        )
        healed.close()
    }
}

private enum TestFailure: Error {
    case openFailed
}

private actor InitialSnapshotAuthenticationStub: AuthenticationServicing {
    func currentState() -> AuthenticationState { .localOnly }
    func restoreSession() -> AuthenticationState { .localOnly }
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return .localOnly
    }
    func signIn(email: String, password: String) -> AuthenticationState {
        _ = email
        _ = password
        return .localOnly
    }
    func signOut() -> AuthenticationState { .signedOut(.userInitiated) }
}

private struct QueueAPIContext {
    let localProjectID = ProjectID(rawValue: UUID())
    let serverProjectID = UUID()
    let ownerSubject = UUID()
    let deviceID = UUID()
    let documentID = UUID()
    let folderID = UUID()

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

    func folderMutation(
        operationID: UUID,
        folderID: UUID? = nil,
        parentFolderID: UUID? = nil,
        name: String = "가 나 다",
        isDeleted: Bool = false
    ) -> SyncV2Mutation {
        .folder(
            SyncV2FolderMutation(
                operationID: operationID,
                folderID: folderID ?? self.folderID,
                parentFolderID: parentFolderID,
                deviceID: deviceID,
                name: name,
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

private final class FailingMarkerRemovalFileManager: FileManager,
    @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        _ = URL
        throw CocoaError(.fileWriteUnknown)
    }
}

private actor UnavailableInitialSnapshotStateRecorder:
    DurableLocalChangeRecording {
    private struct InjectedError: Error {}
    private var calls = 0

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
        throw InjectedError()
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        _ = batch
        calls += 1
        return .queued(operationIDs: [])
    }

    func recordCallCount() -> Int { calls }
}
