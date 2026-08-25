import Foundation
import UIKit
import XCTest
@testable import WriterPad

final class SyncV2SnapshotPullTests: XCTestCase {
    func testOneShotRaceResolvesOnceAndIntentionallyIgnoresCancellation()
        async {
        let race = SyncV2OneShotRace<Int>()
        let waiter = Task { await race.value() }
        waiter.cancel()

        let acceptedFirst = await race.resolve(1)
        let acceptedSecond = await race.resolve(2)
        let waiterValue = await waiter.value
        let resolvedValue = await race.value()

        XCTAssertTrue(acceptedFirst)
        XCTAssertFalse(acceptedSecond)
        XCTAssertEqual(waiterValue, 1)
        XCTAssertEqual(resolvedValue, 1)
    }

    func testTrashPurgePayloadRequiresExactVersionTypesAndCanonicalIDs()
        throws {
        let first = UUID(
            uuidString: "00000000-0000-0000-0000-000000000111"
        )!
        let generation = UUID(
            uuidString: "00000000-0000-0000-0000-000000000222"
        )!
        let valid = try SyncV2TrashPurgePayload(
            strictContent:
                "{\"empty_generation\":\"\(generation.uuidString.lowercased())\",\"purged_revisions\":{\"\(first.uuidString.lowercased())\":7},\"version\":1}"
        )
        XCTAssertEqual(valid.purgedRevisions[first], 7)
        XCTAssertEqual(
            valid.emptyGeneration,
            generation.uuidString.lowercased()
        )

        let invalidPayloads = [
            "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":2}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":\"1\"}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":1.0}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":true}",
            "{\"empty_generation\":1,\"purged_revisions\":{},\"version\":1}",
            "{\"empty_generation\":\"not-a-uuid\",\"purged_revisions\":{},\"version\":1}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{\"not-a-uuid\":1},\"version\":1}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{\"\(first.uuidString.lowercased())\":\"7\"},\"version\":1}",
            "{\"empty_generation\":\"\",\"purged_revisions\":{\"\(first.uuidString.lowercased())\":7.0},\"version\":1}",
            "{\"empty_generation\":\"\",\"extra\":0,\"purged_revisions\":{},\"version\":1}",
        ]
        for content in invalidPayloads {
            XCTAssertThrowsError(
                try SyncV2TrashPurgePayload(strictContent: content),
                content
            )
        }
    }

    func testConflictTextRenderTrackerSkipsRepeatedLargeSource() {
        let base = String(repeating: "한글🙂긴 원고", count: 1_000)
        var tracker = ConflictTextRenderTracker()

        XCTAssertTrue(tracker.shouldRender(base))
        XCTAssertFalse(tracker.shouldRender(base))
        XCTAssertTrue(tracker.shouldRender(base + "서버 변경"))
    }

    func testAppliedRemoteContentUpdatesBinderStateImmediately() {
        let documentID = UUID()
        let binderDocumentID = DocumentID(rawValue: documentID)
        var overrides = [binderDocumentID: BinderTextContentState.empty]

        applyRemoteBinderContentState(
            makeSnapshot(
                id: documentID,
                content: "윈도우에서 작성한 본문",
                revision: 2
            ),
            to: &overrides
        )

        XCTAssertEqual(overrides[binderDocumentID], .written)

        applyRemoteBinderContentState(
            makeSnapshot(
                id: documentID,
                content: "",
                revision: 3
            ),
            to: &overrides
        )

        XCTAssertEqual(overrides[binderDocumentID], .empty)
    }

    func testDeletedRemoteSnapshotDoesNotChangeBinderStateOverride() {
        let documentID = UUID()
        let binderDocumentID = DocumentID(rawValue: documentID)
        var overrides = [binderDocumentID: BinderTextContentState.written]

        applyRemoteBinderContentState(
            makeSnapshot(
                id: documentID,
                content: "",
                revision: 2,
                isDeleted: true
            ),
            to: &overrides
        )

        XCTAssertEqual(overrides[binderDocumentID], .written)
    }

    func testSnapshotDecodesExactDocumentsColumns() throws {
        let data = Data(
            """
            {
              "document_id":"00000000-0000-0000-0000-000000000111",
              "relative_path":"메인/1권/001화.txt",
              "content":"서버 본문",
              "revision":7,
              "is_deleted":false,
              "deleted_at":null,
              "updated_at":"2026-07-28T01:02:03.123456+00:00"
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(
            SyncV2RemoteDocumentSnapshot.self,
            from: data
        )

        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(snapshot.relativePath, "메인/1권/001화.txt")
        XCTAssertEqual(snapshot.content, "서버 본문")
        XCTAssertFalse(snapshot.isDeleted)
    }

    func testClientRejectsDuplicateDocumentIDsAndSortsValidSnapshot()
        async throws {
        let laterID = UUID(
            uuidString: "ffffffff-0000-0000-0000-000000000001"
        )!
        let earlierID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let valid = SnapshotTransportStub(
            snapshots: [
                makeSnapshot(id: laterID, revision: 2),
                makeSnapshot(id: earlierID, revision: 1),
            ]
        )
        let sorted = try await SyncV2SnapshotClient(
            transport: valid
        ).fetchDocuments(projectID: UUID())
        XCTAssertEqual(
            sorted.map(\.documentID),
            [earlierID, laterID]
        )

        let duplicate = SnapshotTransportStub(
            snapshots: [
                makeSnapshot(id: earlierID, revision: 1),
                makeSnapshot(id: earlierID, revision: 2),
            ]
        )
        do {
            _ = try await SyncV2SnapshotClient(
                transport: duplicate
            ).fetchDocuments(projectID: UUID())
            XCTFail("Duplicate IDs must invalidate the snapshot.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testClientFetchesRevisionConflictSnapshotByDocumentID()
        async throws {
        let targetID = UUID()
        let otherID = UUID()
        let target = makeSnapshot(
            id: targetID,
            content: "자동 rebase 대상",
            revision: 9
        )
        let client = SyncV2SnapshotClient(
            transport: SnapshotTransportStub(
                snapshots: [
                    makeSnapshot(id: otherID, revision: 10),
                    target,
                ]
            )
        )

        let fetched = try await client.fetchDocument(
            projectID: UUID(),
            documentID: targetID
        )

        XCTAssertEqual(fetched, target)
    }

    func testClientUsesTheTransportFolderImplementation() async throws {
        let folder = SyncV2RemoteFolder(
            folderID: UUID(),
            parentFolderID: nil,
            name: "메인",
            revision: 1,
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let client = SyncV2SnapshotClient(
            transport: SnapshotTransportStub(
                snapshots: [],
                folders: [folder]
            )
        )

        let fetched = try await client.fetchFolders(projectID: UUID())

        XCTAssertEqual(fetched, [folder])
    }

    func testPullAppliesOnlyHigherCleanDocumentAndPreservesEveryBlocker()
        async throws {
        let clean = UUID()
        let pending = UUID()
        let blocked = UUID()
        let dirty = UUID()
        let composing = UUID()
        let deleted = UUID()
        let current = UUID()
        let snapshots = [
            makeSnapshot(id: clean, revision: 5),
            makeSnapshot(id: pending, revision: 5),
            makeSnapshot(id: blocked, revision: 5),
            makeSnapshot(id: dirty, revision: 5),
            makeSnapshot(id: composing, revision: 5),
            makeSnapshot(
                id: deleted,
                revision: 5,
                isDeleted: true
            ),
            makeSnapshot(id: current, revision: 5),
        ]
        let states: [UUID: SyncV2SnapshotLocalState] = [
            clean: localState(revision: 4),
            pending: localState(revision: 4, active: true),
            blocked: localState(
                revision: 4,
                active: true,
                blockingErrorCode: "FORBIDDEN"
            ),
            dirty: localState(revision: 4),
            composing: localState(revision: 4),
            deleted: localState(revision: 4),
            current: localState(revision: 5),
        ]
        let stateStore = SnapshotStateStoreStub(states: states)
        let applier = SnapshotApplierSpy()
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(snapshots: snapshots),
            stateStore: stateStore,
            localApplier: applier,
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID(),
            editingGuards: [
                dirty: .init(
                    isOpen: true,
                    isDirty: true,
                    isComposing: false
                ),
                composing: .init(
                    isOpen: true,
                    isDirty: false,
                    isComposing: true
                ),
                deleted: .init(
                    isOpen: true,
                    isDirty: false,
                    isComposing: false
                ),
            ]
        )

        let appliedIDs = await applier.appliedIDs()
        let committedIDs = await stateStore.committedIDs()
        let mergeReasons = await merge.reasons()
        XCTAssertEqual(appliedIDs, [clean])
        XCTAssertEqual(committedIDs, [clean])
        XCTAssertEqual(
            Set(mergeReasons),
            Set([
                .pendingOperation,
                .blockedOperation,
                .dirtyEditor,
                .markedTextComposition,
                .remoteDeletion,
            ])
        )
        XCTAssertTrue(
            report.outcomes.contains(
                .upToDate(documentID: current, revision: 5)
            )
        )
    }

    /// 경로 충돌로 굳은 operation은 `conflict` 상태라 hasActiveOperation에도
    /// 걸린다. 진행 중으로 먼저 판정하면 사용자에게는 끝나지 않는 "동기화 중"이
    /// 되므로, 경로 충돌을 더 앞에서 판정해야 한다. 이 순서가 뒤집히면 원래의
    /// 무한 대기 증상이 그대로 돌아온다.
    func testPathCollisionOutranksPendingOperationSoUserSeesItNeedsResolving()
        async throws {
        let documentID = UUID()
        let stateStore = SnapshotStateStoreStub(
            states: [
                documentID: localState(
                    revision: 4,
                    active: true,
                    pathCollision: true
                ),
            ]
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [makeSnapshot(id: documentID, revision: 4)]
            ),
            stateStore: stateStore,
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID(),
            editingGuards: [:]
        )

        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 4,
                    reason: .pathOccupiedByDifferentDocument
                ),
            ],
            "진행 중으로 묻히면 무한 동기화 대기로 되돌아간다."
        )
    }

    /// 빈 서버 작품을 두 기기가 동시에 채우면 같은 초기 TXT가
    /// 다른 UUID로 두 번 등록될 수 있다. 경로·본문이 같고 편집·백업이
    /// 없는 초기 snapshot만 서버 UUID를 채택해 구조 추돌을 풀어야 한다.
    func testEquivalentInitialDocumentAdoptsServerIdentityWithoutRewritingTXT()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Identity-Adoption-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/1권"),
            withIntermediateDirectories: true
        )
        let relativePath = "메인/1권/001화.txt"
        let fileURL = root.appendingPathComponent(relativePath)
        let originalData = Data()
        try originalData.write(to: fileURL)

        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let volume = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: RelativeDocumentPath(rawValue: "메인/1권"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let localID = DocumentID(rawValue: UUID())
        let local = DocumentNode(
            id: localID,
            projectID: projectID,
            kind: .text,
            parentID: volume.id,
            relativePath: RelativeDocumentPath(rawValue: relativePath),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: SHA256ContentHasher().sha256(for: originalData)
        )
        let repository = SnapshotDocumentRepository(
            documents: [main, volume, local]
        )
        let locator = SnapshotWorkspaceLocator(root: root)
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: locator,
            backupStore: LocalBackupStore(workspaceLocator: locator)
        )
        let remoteID = UUID()
        let snapshot = makeSnapshot(
            id: remoteID,
            path: relativePath,
            content: "",
            revision: 1
        )
        let stateStore = EquivalentIdentityStateStoreStub(
            remoteDocumentID: remoteID,
            path: relativePath
        )
        let mergeStore = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(snapshots: [snapshot]),
            stateStore: stateStore,
            localApplier: applier,
            mergeStore: mergeStore
        )

        let report = try await service.pull(
            localProjectID: projectID,
            serverProjectID: UUID(),
            editingGuards: [:]
        )

        let documents = try await repository.documents(in: projectID)
        XCTAssertFalse(documents.contains { $0.id == localID })
        XCTAssertTrue(documents.contains {
            $0.id.rawValue == remoteID
                && $0.relativePath.rawValue == relativePath
        })
        XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        let mergeReasons = await mergeStore.reasons()
        XCTAssertEqual(mergeReasons, [])
        XCTAssertEqual(
            report.outcomes,
            [.upToDate(documentID: remoteID, revision: 1)]
        )
    }

    /// 경로 충돌이 없으면 기존대로 진행 중으로 보고해야 한다.
    func testActiveOperationWithoutPathCollisionStaysPendingOperation()
        async throws {
        let documentID = UUID()
        let stateStore = SnapshotStateStoreStub(
            states: [
                documentID: localState(revision: 4, active: true),
            ]
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [makeSnapshot(id: documentID, revision: 4)]
            ),
            stateStore: stateStore,
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID(),
            editingGuards: [:]
        )

        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 4,
                    reason: .pendingOperation
                ),
            ]
        )
    }

    func testClosedCleanRemoteTombstoneIsAppliedInsteadOfPreserved()
        async throws {
        let documentID = UUID()
        let stateStore = SnapshotStateStoreStub(
            states: [documentID: localState(revision: 2)]
        )
        let applier = SnapshotApplierSpy()
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: documentID,
                        revision: 3,
                        isDeleted: true
                    ),
                ]
            ),
            stateStore: stateStore,
            localApplier: applier,
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        let appliedIDs = await applier.appliedIDs()
        let committedIDs = await stateStore.committedIDs()
        let mergeReasons = await merge.reasons()
        XCTAssertEqual(appliedIDs, [documentID])
        XCTAssertEqual(committedIDs, [documentID])
        XCTAssertEqual(mergeReasons, [])
        XCTAssertEqual(
            report.outcomes,
            [
                .applied(
                    documentID: documentID,
                    revision: 3,
                    wasOpen: false
                ),
            ]
        )
    }

    func testSameRevisionRepairsOnlyCleanMissingCopyAndSkipsEveryQueueBlocker()
        async throws {
        let clean = UUID()
        let pending = UUID()
        let conflict = UUID()
        let blocked = UUID()
        let dirty = UUID()
        let stale = UUID()
        let snapshots = [clean, pending, conflict, blocked, dirty].map {
            makeSnapshot(id: $0, revision: 5)
        } + [makeSnapshot(id: stale, revision: 4)]
        let stateStore = SnapshotStateStoreStub(
            states: [
                clean: localState(revision: 5),
                pending: localState(revision: 5, active: true),
                conflict: localState(revision: 5, conflict: true),
                blocked: localState(
                    revision: 5,
                    active: true,
                    blockingErrorCode: "CONTENT_TOO_LARGE"
                ),
                dirty: localState(revision: 5),
                stale: localState(revision: 5),
            ]
        )
        let applier = SnapshotRecoveryApplierSpy(
            recoveryIDs: Set([clean, pending, conflict, blocked, dirty, stale])
        )
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(snapshots: snapshots),
            stateStore: stateStore,
            localApplier: applier,
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID(),
            editingGuards: [
                dirty: SyncV2EditingGuard(
                    isOpen: true,
                    isDirty: true,
                    isComposing: false
                ),
            ]
        )

        let appliedIDs = await applier.appliedIDs()
        let committedIDs = await stateStore.committedIDs()
        let mergeReasons = await merge.reasons()
        XCTAssertEqual(appliedIDs, [clean])
        XCTAssertEqual(committedIDs, [])
        XCTAssertEqual(mergeReasons, [.dirtyEditor])
        XCTAssertTrue(
            report.outcomes.contains(
                .applied(
                    documentID: clean,
                    revision: 5,
                    wasOpen: false
                )
            )
        )
        XCTAssertTrue(
            report.outcomes.contains(
                .upToDate(documentID: stale, revision: 5)
            )
        )
        XCTAssertTrue(
            report.outcomes.contains(
                .mergeRequired(
                    documentID: pending,
                    revision: 5,
                    reason: .pendingOperation
                )
            )
        )
        XCTAssertTrue(
            report.outcomes.contains(
                .mergeRequired(
                    documentID: conflict,
                    revision: 5,
                    reason: .unresolvedConflict
                )
            )
        )
        XCTAssertTrue(
            report.outcomes.contains(
                .mergeRequired(
                    documentID: blocked,
                    revision: 5,
                    reason: .blockedOperation
                )
            )
        )
    }

    /// Windows는 빈 폴더 이름을 tree_order에만 쓴다. 서버 folders 행이 아직 옛
    /// 이름인 동안 pull 앞부분에서 로컬 이름을 되돌릴 수 있으므로, 이미 적용한
    /// revision이어도 tree_order를 다시 실행해 새 이름과 folder commit을 복구한다.
    func testSameRevisionTreeOrderIsReappliedAfterStaleFolderProjection()
        async throws {
        let serverProjectID = UUID()
        let treeOrderID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TreeOrderPath
        )
        let snapshot = makeSnapshot(
            id: treeOrderID,
            path: syncV2TreeOrderPath,
            content:
                "{\"tree_order\":{\"메인/메모장\":[\"새폴더D\"]},\"version\":1}",
            revision: 7
        )
        let state = SyncV2SnapshotLocalState(
            serverRevision: 7,
            serverPath: syncV2TreeOrderPath,
            hasActiveOperation: false,
            hasUnresolvedConflict: false,
            blockingErrorCode: nil
        )
        let applier = SnapshotApplierSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(snapshots: [snapshot]),
            stateStore: SnapshotStateStoreStub(
                states: [treeOrderID: state]
            ),
            localApplier: applier,
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverProjectID
        )

        let appliedIDs = await applier.appliedIDs()
        XCTAssertEqual(appliedIDs, [treeOrderID])
        XCTAssertEqual(
            report.outcomes,
            [
                .applied(
                    documentID: treeOrderID,
                    revision: 7,
                    wasOpen: false
                ),
            ]
        )
    }

    func testSameRevisionRecoveryNeverOverwritesDifferentUUIDPath()
        async throws {
        let documentID = UUID()
        let applier = SnapshotRecoveryApplierSpy(
            recoveryIDs: [documentID],
            applyError: .pathOccupiedByDifferentDocument
        )
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [makeSnapshot(id: documentID, revision: 3)]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [documentID: localState(revision: 3)]
            ),
            localApplier: applier,
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        let appliedIDs = await applier.appliedIDs()
        let mergeReasons = await merge.reasons()
        XCTAssertEqual(appliedIDs, [])
        XCTAssertEqual(mergeReasons, [.pathOccupiedByDifferentDocument])
        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 3,
                    reason: .pathOccupiedByDifferentDocument
                ),
            ]
        )
    }

    func testBaselineRaceNeverReportsAppliedAndPreservesMergeCandidate()
        async throws {
        let documentID = UUID()
        let stateStore = SnapshotStateStoreStub(
            states: [documentID: localState(revision: 1)],
            commitResult: false
        )
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(id: documentID, revision: 2),
                ]
            ),
            stateStore: stateStore,
            localApplier: SnapshotApplierSpy(),
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 2,
                    reason: .pendingOperation
                ),
            ]
        )
        let reasons = await merge.reasons()
        XCTAssertEqual(reasons, [.pendingOperation])
    }

    func testLocalSaveWaitsUntilSnapshotBaselineTransactionFinishes()
        async throws {
        let documentID = UUID()
        let mutationGate = SyncV2DocumentMutationGate()
        let sequence = SnapshotMutationSequence()
        let stateStore = BlockingSnapshotStateStore()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(id: documentID, revision: 2),
                ]
            ),
            stateStore: stateStore,
            localApplier: SequencedSnapshotApplier(sequence: sequence),
            mergeStore: SnapshotMergeStoreSpy(),
            mutationGate: mutationGate
        )

        let pullTask = Task {
            try await service.pull(
                localProjectID: ProjectID(rawValue: UUID()),
                serverProjectID: UUID()
            )
        }
        await stateStore.waitUntilSnapshotReadStarts()
        let localSaveTask = Task {
            try await mutationGate.withCriticalSection(
                documentID: documentID
            ) {
                await sequence.append("local-save")
            }
        }
        await stateStore.resumeSnapshotRead()
        _ = try await pullTask.value
        _ = try await localSaveTask.value

        let events = await sequence.events()
        XCTAssertEqual(events, ["remote-snapshot", "local-save"])
    }

    func testFailedSnapshotCASRestoresOriginalLocalTXT() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeURL = root.appendingPathComponent("메인/1권")
        try FileManager.default.createDirectory(
            at: volumeURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(
            rawValue: "메인/1권/001화.txt"
        )
        let folder = DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/1권"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let document = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: folderID,
            relativePath: path,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let fileURL = root.appendingPathComponent(path.rawValue)
        try Data("보존할 iPad 로컬 본문".utf8).write(to: fileURL)
        let repository = SnapshotDocumentRepository(
            documents: [folder, document]
        )
        let stateStore = SnapshotStateStoreStub(
            states: [
                documentID.rawValue: localState(revision: 1),
            ],
            commitResult: false
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: documentID.rawValue,
                        path: path.rawValue,
                        content: "뒤늦게 도착한 서버 본문",
                        revision: 2
                    ),
                ]
            ),
            stateStore: stateStore,
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: UUID()
        )

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let stored = try await repository.document(id: documentID)
        XCTAssertEqual(text, "보존할 iPad 로컬 본문")
        XCTAssertEqual(stored, document)
    }

    func testFailedTombstoneCASRestoresOriginalTXTAndMetadata()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let notesURL = root.appendingPathComponent("메인/자료")
        let trashURL = root.appendingPathComponent("메인/휴지통")
        try FileManager.default.createDirectory(
            at: notesURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let notesID = DocumentID(rawValue: UUID())
        let trashID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(rawValue: "메인/자료/사건.txt")
        let notes = DocumentNode(
            id: notesID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/자료"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let trash = DocumentNode(
            id: trashID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderFixedCategory.trash.relativePath,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let document = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: notesID,
            relativePath: path,
            userOrder: 2,
            modifiedAt: .distantPast,
            contentHash: SHA256ContentHasher().sha256(
                for: Data("CAS 경쟁 전 본문".utf8)
            )
        )
        let originalURL = root.appendingPathComponent(path.rawValue)
        try Data("CAS 경쟁 전 본문".utf8).write(to: originalURL)
        let repository = SnapshotDocumentRepository(
            documents: [notes, trash, document]
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: documentID.rawValue,
                        path: path.rawValue,
                        content: "",
                        revision: 2,
                        isDeleted: true
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [documentID.rawValue: localState(revision: 1)],
                commitResult: false
            ),
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: UUID()
        )

        let stored = try await repository.document(id: documentID)
        XCTAssertEqual(stored, document)
        XCTAssertEqual(
            try String(contentsOf: originalURL, encoding: .utf8),
            "CAS 경쟁 전 본문"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: trashURL.path),
            []
        )
        let trashRecordURL = root.appendingPathComponent(
            ".writerpad-trash-"
                + documentID.rawValue.uuidString.lowercased()
                + ".json"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: trashRecordURL.path)
        )
    }

    func testSameRevisionRestoresMissingLiveAndTombstoneCopies()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-CopyRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/휴지통"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let notesID = DocumentID(rawValue: UUID())
        let trashID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(rawValue: "메인/메모장/복구.txt")
        let notes = DocumentNode(
            id: notesID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/메모장"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let trash = DocumentNode(
            id: trashID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderFixedCategory.trash.relativePath,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let document = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: notesID,
            relativePath: path,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(
            documents: [notes, trash, document]
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let live = makeSnapshot(
            id: documentID.rawValue,
            path: path.rawValue,
            content: "복구할 본문",
            revision: 1
        )
        let requiresLiveRecovery = await applier.requiresCopyRecovery(
            localProjectID: projectID,
            snapshot: live
        )
        XCTAssertTrue(requiresLiveRecovery)
        try await applier.apply(localProjectID: projectID, snapshot: live)
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(path.rawValue),
                encoding: .utf8
            ),
            "복구할 본문"
        )

        let tombstone = makeSnapshot(
            id: documentID.rawValue,
            path: path.rawValue,
            content: "복구할 본문",
            revision: 2,
            isDeleted: true
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: tombstone
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )
        let firstStoredTrash = try await repository.document(id: documentID)
        let firstTrash = try XCTUnwrap(firstStoredTrash)
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(firstTrash.relativePath.rawValue)
        )
        let requiresTombstoneRecovery = await applier.requiresCopyRecovery(
            localProjectID: projectID,
            snapshot: tombstone
        )
        XCTAssertTrue(requiresTombstoneRecovery)

        await repository.failNextSave()
        do {
            try await applier.apply(
                localProjectID: projectID,
                snapshot: tombstone
            )
            XCTFail("복구 metadata 실패가 발생하지 않았습니다.")
        } catch SnapshotTestError.injectedMetadataFailure {}
        let requiresRetry = await applier.requiresCopyRecovery(
            localProjectID: projectID,
            snapshot: tombstone
        )
        XCTAssertTrue(requiresRetry)
        try await applier.apply(localProjectID: projectID, snapshot: tombstone)
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        let repairedDocument = try await repository.document(id: documentID)
        let repaired = try XCTUnwrap(repairedDocument)
        XCTAssertTrue(
            repaired.relativePath.rawValue.contains(
                documentID.rawValue.uuidString.lowercased()
            )
        )
        XCTAssertEqual(repaired.parentID, trashID)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(
                    repaired.relativePath.rawValue
                ),
                encoding: .utf8
            ),
            "복구할 본문"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    ".writerpad-trash-"
                        + documentID.rawValue.uuidString.lowercased()
                        + ".json"
                ).path
            )
        )

        try FileManager.default.removeItem(
            at: root.appendingPathComponent(repaired.relativePath.rawValue)
        )
        let replacementID = DocumentID(rawValue: UUID())
        let replacement = DocumentNode(
            id: replacementID,
            projectID: projectID,
            kind: .text,
            parentID: notesID,
            relativePath: path,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        try await repository.save(replacement)
        try Data("새 UUID 본문".utf8).write(
            to: root.appendingPathComponent(path.rawValue)
        )

        let requiresRelocatedRecovery = await applier.requiresCopyRecovery(
            localProjectID: projectID,
            snapshot: tombstone
        )
        XCTAssertTrue(requiresRelocatedRecovery)
        try await applier.apply(localProjectID: projectID, snapshot: tombstone)
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(path.rawValue),
                encoding: .utf8
            ),
            "새 UUID 본문"
        )
        let relocatedDocument = try await repository.document(id: documentID)
        let relocated = try XCTUnwrap(relocatedDocument)
        XCTAssertTrue(
            relocated.relativePath.rawValue.contains(
                documentID.rawValue.uuidString.lowercased()
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(
                    relocated.relativePath.rawValue
                ),
                encoding: .utf8
            ),
            "복구할 본문"
        )
        let storedReplacement = try await repository.document(
            id: replacementID
        )
        XCTAssertEqual(storedReplacement, replacement)
    }

    func testRemoteTXTMaterializesMissingNonemptyFolderHierarchy()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let notes = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main, notes])
        let documentID = UUID()
        let path = "메인/메모장/Windows 폴더/하위 폴더/새 문서.txt"
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: documentID,
                path: path,
                content: "Windows에서 작성한 본문",
                revision: 1
            )
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID
        )

        let documents = try await repository.documents(in: projectID)
        let firstFolder = try XCTUnwrap(documents.first {
            $0.relativePath.rawValue == "메인/메모장/Windows 폴더"
        })
        let secondFolder = try XCTUnwrap(documents.first {
            $0.relativePath.rawValue
                == "메인/메모장/Windows 폴더/하위 폴더"
        })
        let created = try XCTUnwrap(documents.first {
            $0.id.rawValue == documentID
        })
        XCTAssertEqual(firstFolder.kind, .folder)
        XCTAssertEqual(firstFolder.parentID, notes.id)
        XCTAssertEqual(secondFolder.parentID, firstFolder.id)
        XCTAssertEqual(created.parentID, secondFolder.id)
        XCTAssertEqual(created.relativePath.rawValue, path)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            ),
            "Windows에서 작성한 본문"
        )
    }

    func testTreeOrderAppliesAfterDocumentsAndNeverCreatesHiddenFile()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let notesURL = root.appendingPathComponent("메인/메모장")
        try FileManager.default.createDirectory(
            at: notesURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let notes = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let firstID = DocumentID(rawValue: UUID())
        let secondID = DocumentID(rawValue: UUID())
        let first = DocumentNode(
            id: firstID,
            projectID: projectID,
            kind: .text,
            parentID: notes.id,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/메모장/첫째.txt"
            ),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let second = DocumentNode(
            id: secondID,
            projectID: projectID,
            kind: .text,
            parentID: notes.id,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/메모장/둘째.txt"
            ),
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        try Data("첫째".utf8).write(
            to: notesURL.appendingPathComponent("첫째.txt")
        )
        try Data("둘째".utf8).write(
            to: notesURL.appendingPathComponent("둘째.txt")
        )
        let repository = SnapshotDocumentRepository(
            documents: [main, notes, first, second]
        )
        let treeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TreeOrderPath
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: treeID,
                        path: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인/메모장\":[\"둘째.txt\",\"첫째.txt\"]},\"version\":1}",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: firstID.rawValue,
                        path: first.relativePath.rawValue,
                        content: "첫째",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: secondID.rawValue,
                        path: second.relativePath.rawValue,
                        content: "둘째",
                        revision: 1
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        let updatedFirst = try await repository.document(id: firstID)
        let updatedSecond = try await repository.document(id: secondID)
        XCTAssertEqual(updatedSecond?.userOrder, 0)
        XCTAssertEqual(updatedFirst?.userOrder, 1)
        let appliedIDs = report.appliedSnapshots.map(\.documentID)
        XCTAssertEqual(appliedIDs.last, treeID)
        XCTAssertEqual(
            Set(appliedIDs.dropLast()),
            Set([firstID.rawValue, secondID.rawValue])
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("__antigravity__").path
            )
        )
    }

    func testTrashPurgeRequiresExactHiddenUUIDAndRunsBeforeTombstoneLiveAndTree()
        async throws {
        let serverProjectID = UUID()
        let purgeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TrashPurgePath
        )
        let treeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TreeOrderPath
        )
        let tombstoneID = UUID()
        let liveID = UUID()
        let payload =
            "{\"empty_generation\":\"\",\"purged_revisions\":{},\"version\":1}"
        let applier = SnapshotApplierSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: liveID,
                        path: "메인/메모장/live.txt",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: treeID,
                        path: syncV2TreeOrderPath,
                        content: "{\"tree_order\":{},\"version\":1}",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: tombstoneID,
                        path: "메인/메모장/deleted.txt",
                        content: "",
                        revision: 1,
                        isDeleted: true
                    ),
                    makeSnapshot(
                        id: purgeID,
                        path: syncV2TrashPurgePath,
                        content: payload,
                        revision: 1
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: applier,
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverProjectID
        )

        let appliedIDs = await applier.appliedIDs()
        XCTAssertEqual(appliedIDs, [purgeID, tombstoneID, liveID, treeID])

        let wrongID = UUID()
        let merge = SnapshotMergeStoreSpy()
        let invalidService = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: wrongID,
                        path: syncV2TrashPurgePath,
                        content: payload,
                        revision: 2
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: SnapshotApplierSpy(),
            mergeStore: merge
        )
        let invalidReport = try await invalidService.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverProjectID
        )
        XCTAssertEqual(
            invalidReport.outcomes,
            [
                .mergeRequired(
                    documentID: wrongID,
                    revision: 2,
                    reason: .invalidLocalHierarchy
                ),
            ]
        )
        let reasons = await merge.reasons()
        XCTAssertEqual(reasons, [.invalidLocalHierarchy])
    }

    func testTrashPurgeMergesMaximumDeletesStaleTombstoneAndAllowsHigherRedelete()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TrashPurge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let targetID = UUID()
        let retainedID = UUID()
        let fixture = try makeTrashPurgeFixture(
            root: root,
            projectID: projectID,
            documentID: targetID,
            fileName: "최종직전테스트.txt"
        )
        let previous = SyncV2TrashPurgePayload(
            purgedRevisions: [targetID: 1, retainedID: 9],
            emptyGeneration: ""
        )
        try Data(try previous.canonicalContent().utf8).write(
            to: root.appendingPathComponent(
                LocalSyncV2SnapshotApplier.trashPurgeStateName
            ),
            options: [.atomic]
        )
        let purgeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TrashPurgePath
        )
        let purge = SyncV2TrashPurgePayload(
            purgedRevisions: [targetID: 2, retainedID: 4],
            emptyGeneration: ""
        )
        let mergeURL = root.appendingPathComponent(
            LocalSyncV2SnapshotMergeStore.prefix
                + purgeID.uuidString.lowercased()
                + LocalSyncV2SnapshotMergeStore.suffix
        )
        try Data("기존 invalidLocalHierarchy 표식".utf8).write(to: mergeURL)
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: fixture.repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: targetID,
                        path: fixture.originalPath.rawValue,
                        content: "",
                        revision: 2,
                        isDeleted: true
                    ),
                    makeSnapshot(
                        id: purgeID,
                        path: syncV2TrashPurgePath,
                        content: try purge.canonicalContent(),
                        revision: 2
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [targetID: localState(revision: 1)]
            ),
            localApplier: applier,
            mergeStore: LocalSyncV2SnapshotMergeStore(
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            )
        )

        let report = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        XCTAssertEqual(
            report.appliedSnapshots.map(\.documentID),
            [purgeID, targetID]
        )
        let purgedDocument = try await fixture.repository.document(
            id: DocumentID(rawValue: targetID)
        )
        XCTAssertNil(purgedDocument)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.trashFileURL.path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergeURL.path))
        let mergedState = await applier.trashPurgeState(
            localProjectID: projectID
        )
        XCTAssertEqual(mergedState.purgedRevisions[targetID], 2)
        XCTAssertEqual(mergedState.purgedRevisions[retainedID], 9)

        let restored = DocumentNode(
            id: DocumentID(rawValue: targetID),
            projectID: projectID,
            kind: .text,
            parentID: fixture.notesID,
            relativePath: fixture.originalPath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        try await fixture.repository.save(restored)
        let liveURL = root.appendingPathComponent(
            fixture.originalPath.rawValue
        )
        try Data("더 높은 revision의 재삭제".utf8).write(to: liveURL)
        let redeletionService = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: targetID,
                        path: fixture.originalPath.rawValue,
                        content: "",
                        revision: 3,
                        isDeleted: true
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [targetID: localState(revision: 2)]
            ),
            localApplier: applier,
            mergeStore: SnapshotMergeStoreSpy()
        )

        let redeletion = try await redeletionService.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        XCTAssertEqual(
            redeletion.outcomes,
            [.applied(documentID: targetID, revision: 3, wasOpen: false)]
        )
        let redeletedDocument = try await fixture.repository.document(
            id: DocumentID(rawValue: targetID)
        )
        let trashedAgain = try XCTUnwrap(redeletedDocument)
        guard case .trashed = trashedAgain.deletionStatus else {
            return XCTFail("purge보다 높은 revision은 새 tombstone이어야 합니다.")
        }
    }

    func testTrashPurgeBaselineFailureRollsBackFileMetadataAndState()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TrashPurgeRollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let targetID = UUID()
        let fixture = try makeTrashPurgeFixture(
            root: root,
            projectID: projectID,
            documentID: targetID,
            fileName: "rollback.txt"
        )
        let purgeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TrashPurgePath
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: fixture.repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: targetID,
                        path: fixture.originalPath.rawValue,
                        content: "",
                        revision: 2,
                        isDeleted: true
                    ),
                    makeSnapshot(
                        id: purgeID,
                        path: syncV2TrashPurgePath,
                        content: try SyncV2TrashPurgePayload(
                            purgedRevisions: [targetID: 2],
                            emptyGeneration: ""
                        ).canonicalContent(),
                        revision: 1
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [targetID: localState(revision: 1)],
                commitResult: false
            ),
            localApplier: applier,
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        let restoredDocument = try await fixture.repository.document(
            id: DocumentID(rawValue: targetID)
        )
        XCTAssertNotNil(restoredDocument)
        XCTAssertEqual(
            try String(contentsOf: fixture.trashFileURL, encoding: .utf8),
            "휴지통 본문"
        )
        let restoredState = await applier.trashPurgeState(
            localProjectID: projectID
        )
        XCTAssertEqual(restoredState, .empty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    LocalSyncV2SnapshotApplier.trashPurgeStagePrefix
                        + purgeID.uuidString.lowercased()
                ).path
            )
        )
    }

    func testTrashPurgeRecoveryMarkerRollsBackThenReappliesCommittedBaseline()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TrashPurgeRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let targetID = UUID()
        let fixture = try makeTrashPurgeFixture(
            root: root,
            projectID: projectID,
            documentID: targetID,
            fileName: "recovery.txt"
        )
        let purgeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TrashPurgePath
        )
        let content = try SyncV2TrashPurgePayload(
            purgedRevisions: [targetID: 2],
            emptyGeneration: ""
        ).canonicalContent()
        let firstApplier = LocalSyncV2SnapshotApplier(
            documentRepository: fixture.repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        try await firstApplier.applyTrashPurge(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: purgeID,
                path: syncV2TrashPurgePath,
                content: content,
                revision: 1
            ),
            eligibleDocumentIDs: [targetID]
        )
        let markerURL = root.appendingPathComponent(
            LocalSyncV2SnapshotApplier.markerPrefix
                + purgeID.uuidString.lowercased()
                + LocalSyncV2SnapshotApplier.markerSuffix
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let recoveringApplier = LocalSyncV2SnapshotApplier(
            documentRepository: fixture.repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: targetID,
                        path: fixture.originalPath.rawValue,
                        content: "",
                        revision: 2,
                        isDeleted: true
                    ),
                    makeSnapshot(
                        id: purgeID,
                        path: syncV2TrashPurgePath,
                        content: content,
                        revision: 1
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [
                    purgeID: localState(revision: 1),
                    targetID: localState(revision: 2),
                ]
            ),
            localApplier: recoveringApplier,
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        let recoveredDocument = try await fixture.repository.document(
            id: DocumentID(rawValue: targetID)
        )
        XCTAssertNil(recoveredDocument)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.trashFileURL.path)
        )
    }

    func testTrashEmptyGenerationAppliesOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TrashEmptyGeneration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = ProjectID(rawValue: UUID())
        let firstID = UUID()
        let fixture = try makeTrashPurgeFixture(
            root: root,
            projectID: projectID,
            documentID: firstID,
            fileName: "첫 사건.txt"
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: fixture.repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let generation = UUID().uuidString.lowercased()
        let purgeID = UUID()
        let content = try SyncV2TrashPurgePayload(
            purgedRevisions: [:],
            emptyGeneration: generation
        ).canonicalContent()
        try await applier.applyTrashPurge(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: purgeID,
                path: syncV2TrashPurgePath,
                content: content,
                revision: 1
            ),
            eligibleDocumentIDs: []
        )
        await applier.finish(localProjectID: projectID, documentID: purgeID)
        let firstDocument = try await fixture.repository.document(
            id: DocumentID(rawValue: firstID)
        )
        XCTAssertNil(firstDocument)

        let secondID = DocumentID(rawValue: UUID())
        let secondPath = RelativeDocumentPath(
            rawValue: "메인/휴지통/새 사건.txt"
        )
        try await fixture.repository.save(
            DocumentNode(
                id: secondID,
                projectID: projectID,
                kind: .text,
                parentID: fixture.trashID,
                relativePath: secondPath,
                userOrder: 0,
                modifiedAt: .distantPast,
                contentHash: nil,
                deletionStatus: .trashed(
                    originalPath: RelativeDocumentPath(
                        rawValue: "메인/메모장/새 사건.txt"
                    ),
                    deletedAt: .distantPast
                )
            )
        )
        let secondURL = root.appendingPathComponent(secondPath.rawValue)
        try Data("새 사건".utf8).write(to: secondURL)

        try await applier.applyTrashPurge(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: purgeID,
                path: syncV2TrashPurgePath,
                content: content,
                revision: 2
            ),
            eligibleDocumentIDs: []
        )
        await applier.finish(localProjectID: projectID, documentID: purgeID)

        let secondDocument = try await fixture.repository.document(id: secondID)
        XCTAssertNotNil(secondDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testTreeOrderMaterializesEmptyFolderWithoutHiddenFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"빈 폴더\"],\"메인/빈 폴더\":[\"하위 빈 폴더\"]},\"version\":1}",
                revision: 1
            )
        )

        let documents = try await repository.documents(in: projectID)
        let emptyFolder = try XCTUnwrap(documents.first(where: {
            $0.relativePath.rawValue == "메인/빈 폴더"
        }))
        XCTAssertEqual(emptyFolder.kind, .folder)
        XCTAssertEqual(emptyFolder.parentID, main.id)
        let nestedFolder = try XCTUnwrap(documents.first(where: {
            $0.relativePath.rawValue == "메인/빈 폴더/하위 빈 폴더"
        }))
        XCTAssertEqual(nestedFolder.kind, .folder)
        XCTAssertEqual(nestedFolder.parentID, emptyFolder.id)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "메인/빈 폴더/하위 빈 폴더"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("__antigravity__").path
            )
        )
    }

    func testRemoteDocumentReplacesEmptyTreeOrderTXTPlaceholderFolder()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let path = "메인/001화.txt"
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"001화.txt\"]},\"version\":1}",
                revision: 1
            )
        )
        let initialDocuments = try await repository.documents(in: projectID)
        let placeholder = try XCTUnwrap(initialDocuments.first {
            $0.relativePath.rawValue == path
        })
        XCTAssertEqual(placeholder.kind, .folder)

        let remoteID = UUID()
        await applier.preparePull(
            localProjectID: projectID,
            remoteLiveDocumentPaths: [path]
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: remoteID,
                path: path,
                content: "",
                revision: 1
            )
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: remoteID
        )

        let removedPlaceholder = try await repository.document(
            id: placeholder.id
        )
        XCTAssertNil(removedPlaceholder)
        let storedRemote = try await repository.document(
            id: DocumentID(rawValue: remoteID)
        )
        let document = try XCTUnwrap(storedRemote)
        XCTAssertEqual(document.kind, .text)
        XCTAssertEqual(document.relativePath.rawValue, path)
        var isDirectory: ObjCBool = true
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(path)),
            Data()
        )
    }

    func testRemoteDocumentNeverReplacesNonemptyTreeOrderPlaceholderFolder()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let path = "메인/001화.txt"
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"001화.txt\"]},\"version\":1}",
                revision: 1
            )
        )
        let sentinel = root.appendingPathComponent(path)
            .appendingPathComponent("do-not-delete")
        try Data("preserve".utf8).write(to: sentinel)
        await applier.preparePull(
            localProjectID: projectID,
            remoteLiveDocumentPaths: [path]
        )

        do {
            try await applier.apply(
                localProjectID: projectID,
                snapshot: makeSnapshot(
                    path: path,
                    content: "",
                    revision: 1
                )
            )
            XCTFail("내용이 있는 폴더는 TXT로 바꾸면 안 됩니다.")
        } catch let error as SyncV2LocalSnapshotApplyError {
            XCTAssertEqual(error, .pathOccupiedByDifferentDocument)
        }
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "preserve"
        )
    }

    func testTreeOrderPlaceholderPromotionRollbackRestoresEmptyFolder()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let path = "메인/001화.txt"
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"001화.txt\"]},\"version\":1}",
                revision: 1
            )
        )
        let initialDocuments = try await repository.documents(in: projectID)
        let placeholder = try XCTUnwrap(initialDocuments.first {
            $0.relativePath.rawValue == path
        })
        let remoteID = UUID()
        await applier.preparePull(
            localProjectID: projectID,
            remoteLiveDocumentPaths: [path]
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: remoteID,
                path: path,
                content: "",
                revision: 1
            )
        )

        await applier.rollback(
            localProjectID: projectID,
            documentID: remoteID
        )

        let removedRemote = try await repository.document(
            id: DocumentID(rawValue: remoteID)
        )
        XCTAssertNil(removedRemote)
        let restoredPlaceholder = try await repository.document(
            id: placeholder.id
        )
        XCTAssertEqual(restoredPlaceholder, placeholder)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// 빈 폴더는 tree-order의 child name으로만 전달되므로 Windows의 이름 변경은
    /// "옛 이름 사라짐 + 새 이름 생김"으로 도착한다. 새 이름만 만들고 옛 폴더를
    /// 두면 폴더가 둘로 늘어난다. 지우는 대신 옮겨야 안에 무엇이 있었더라도
    /// 잃지 않는다.
    func testTreeOrderRenamesSyncedEmptyFolderInsteadOfDuplicating()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"새 폴더\"]},\"version\":1}",
                revision: 1
            )
        )
        let created = try await repository.documents(in: projectID)
        let before = try XCTUnwrap(created.first(where: {
            $0.relativePath.rawValue == "메인/새 폴더"
        }))

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"새 폴 더\"]},\"version\":1}",
                revision: 2
            )
        )

        let documents = try await repository.documents(in: projectID)
        let folders = documents.filter {
            $0.kind == .folder && $0.parentID == main.id
        }
        XCTAssertEqual(
            folders.map(\.relativePath.rawValue),
            ["메인/새 폴 더"],
            "이름만 바뀌어야 하고 폴더가 둘로 늘면 안 된다."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/새 폴더").path
            ),
            "옛 이름의 디렉터리는 남지 않아야 한다."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/새 폴 더").path
            )
        )
        XCTAssertEqual(
            before.id,
            folders.first?.id,
            "같은 폴더가 옮겨진 것이므로 식별자는 그대로여야 한다. 새로 계산하면 서버 폴더 기록과 짝이 끊겨 받는 기기에 둘로 보인다."
        )
    }

    /// iPad 경로 정책은 공백이나 마침표로 끝나는 이름을 거부한다. Windows가 그런
    /// 이름을 보내도 그 폴더 하나만 보류되어야 하고 pull 전체가 죽으면 안 된다.
    /// pull은 SyncV2LocalSnapshotApplyError만 보류로 바꾸므로, 다른 오류가 새면
    /// 원고를 포함한 모든 동기화가 멈춘다.
    func testTreeOrderRejectsUnsafeFolderNameAsApplyErrorNotRawPolicyError()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"가 나 다\"]},\"version\":1}",
                revision: 1
            )
        )

        do {
            try await applier.apply(
                localProjectID: projectID,
                snapshot: makeSnapshot(
                    path: syncV2TreeOrderPath,
                    content:
                        "{\"tree_order\":{\"<root>\":[\"가 나 다 라 \"]},\"version\":1}",
                    revision: 2
                )
            )
            XCTFail("공백으로 끝나는 이름은 거부되어야 한다.")
        } catch let error as SyncV2LocalSnapshotApplyError {
            guard case let .unsafeName(rejected) = error else {
                return XCTFail(
                    "어떤 이름이 막혔는지 담은 오류여야 한다: \(error)"
                )
            }
            XCTAssertEqual(rejected.name, "가 나 다 라 ")
            XCTAssertEqual(rejected.parent, "메인")
            XCTAssertTrue(
                rejected.reason.contains("공백이나 마침표"),
                "사유가 사용자에게 그대로 쓰인다: \(rejected.reason)"
            )
        } catch {
            XCTFail(
                """
                pull이 보류로 바꿀 수 있는 오류여야 한다. \
                실제로 나온 오류: \(error)
                """
            )
        }
    }

    /// 이름이 여럿 바뀌면 어느 것이 어느 것인지 짝지을 수 없다. 이때는 지금처럼
    /// 새 이름만 만들고 옛 폴더는 그대로 둔다. 잘못 옮기는 것보다 낫다.
    func testTreeOrderKeepsBothWhenRenamePairingIsAmbiguous() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"가\",\"나\"]},\"version\":1}",
                revision: 1
            )
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                path: syncV2TreeOrderPath,
                content:
                    "{\"tree_order\":{\"<root>\":[\"다\",\"라\"]},\"version\":1}",
                revision: 2
            )
        )

        let documents = try await repository.documents(in: projectID)
        let names = Set(
            documents
                .filter { $0.kind == .folder && $0.parentID == main.id }
                .map(\.relativePath.rawValue)
        )
        XCTAssertEqual(
            names,
            ["메인/가", "메인/나", "메인/다", "메인/라"]
        )
    }

    func testTreeOrderNeverMistakesBlockedRemoteTXTForEmptyFolder()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let notes = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let documentID = UUID()
        let treeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TreeOrderPath
        )
        let repository = SnapshotDocumentRepository(documents: [main, notes])
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: documentID,
                        path: "메인/메모장/대기.txt",
                        content: "편집 중이라 아직 적용하지 않을 본문",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: treeID,
                        path: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"메인/메모장\":[\"대기.txt\"]},\"version\":1}",
                        revision: 1
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID,
            editingGuards: [
                documentID: .init(
                    isOpen: true,
                    isDirty: true,
                    isComposing: false
                ),
            ]
        )

        let documents = try await repository.documents(in: projectID)
        XCTAssertFalse(documents.contains(where: {
            $0.relativePath.rawValue == "메인/메모장/대기.txt"
        }))
        var isDirectory: ObjCBool = false
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "메인/메모장/대기.txt"
                ).path,
                isDirectory: &isDirectory
            )
        )
    }

    func testPullAppliesTombstoneBeforeNewUUIDReusesSamePath()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-PathReuse-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let notesURL = root.appendingPathComponent("메인/메모장")
        let trashURL = root.appendingPathComponent("메인/휴지통")
        try FileManager.default.createDirectory(
            at: notesURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let notes = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let trash = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.trash.relativePath,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let oldID = DocumentID(
            rawValue: UUID(
                uuidString: "ffffffff-0000-0000-0000-000000000001"
            )!
        )
        let newID = DocumentID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )!
        )
        let path = RelativeDocumentPath(rawValue: "메인/메모장/재사용.txt")
        let old = DocumentNode(
            id: oldID,
            projectID: projectID,
            kind: .text,
            parentID: notes.id,
            relativePath: path,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        try Data("이전 UUID".utf8).write(
            to: root.appendingPathComponent(path.rawValue)
        )
        let repository = SnapshotDocumentRepository(
            documents: [main, notes, trash, old]
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: newID.rawValue,
                        path: path.rawValue,
                        content: "새 UUID",
                        revision: 1
                    ),
                    makeSnapshot(
                        id: oldID.rawValue,
                        path: path.rawValue,
                        content: "",
                        revision: 2,
                        isDeleted: true
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: projectID,
            serverProjectID: UUID()
        )

        let oldStored = try await repository.document(id: oldID)
        let newStored = try await repository.document(id: newID)
        guard case .trashed = oldStored?.deletionStatus else {
            return XCTFail("이전 UUID는 먼저 휴지통으로 이동해야 합니다.")
        }
        XCTAssertEqual(newStored?.relativePath, path)
        XCTAssertEqual(newStored?.deletionStatus, .active)
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(path.rawValue),
                encoding: .utf8
            ),
            "새 UUID"
        )
        XCTAssertEqual(
            report.appliedSnapshots.map(\.documentID),
            [oldID.rawValue, newID.rawValue]
        )
    }

    func testFailedTreeOrderCASRestoresPreviousOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TreeOrder-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/메모장"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let notes = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let first = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: notes.id,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/메모장/첫째.txt"
            ),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let second = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: notes.id,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/메모장/둘째.txt"
            ),
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(
            documents: [main, notes, first, second]
        )
        let treeID = syncV2UUIDv5(
            namespace: serverProjectID,
            name: syncV2TreeOrderPath
        )
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(
                        id: treeID,
                        path: syncV2TreeOrderPath,
                        content:
                            "{\"tree_order\":{\"<root>\":[\"메모장\",\"빈 폴더\"],\"메인/메모장\":[\"둘째.txt\",\"첫째.txt\"]},\"version\":1}",
                        revision: 2
                    ),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [treeID: localState(revision: 1)],
                commitResult: false
            ),
            localApplier: LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: SnapshotWorkspaceLocator(root: root)
            ),
            mergeStore: SnapshotMergeStoreSpy()
        )

        _ = try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )

        let restoredFirst = try await repository.document(id: first.id)
        let restoredSecond = try await repository.document(id: second.id)
        XCTAssertEqual(restoredFirst, first)
        XCTAssertEqual(restoredSecond, second)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/빈 폴더").path
            )
        )
        let restoredDocuments = try await repository.documents(in: projectID)
        XCTAssertFalse(
            restoredDocuments.contains(where: {
                $0.relativePath.rawValue == "메인/빈 폴더"
            })
        )
    }

    func testEqualServerRevisionWithPendingLocalOperationIsNotUpToDate()
        async throws {
        let documentID = UUID()
        let merge = SnapshotMergeStoreSpy()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(id: documentID, revision: 7),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [
                    documentID: localState(revision: 7, active: true),
                ]
            ),
            localApplier: SnapshotApplierSpy(),
            mergeStore: merge
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 7,
                    reason: .pendingOperation
                ),
            ]
        )
        let preservedReasons = await merge.reasons()
        XCTAssertEqual(
            preservedReasons,
            [],
            "같은 revision의 기존 서버 본문은 병합 후보로 중복 보존하지 않습니다."
        )
    }

    func testUnresolvedConflictWinsOverPendingOperationAtEqualRevision()
        async throws {
        let documentID = UUID()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [
                    makeSnapshot(id: documentID, revision: 7),
                ]
            ),
            stateStore: SnapshotStateStoreStub(
                states: [
                    documentID: localState(
                        revision: 7,
                        active: true,
                        conflict: true
                    ),
                ]
            ),
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy()
        )

        let report = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        XCTAssertEqual(
            report.outcomes,
            [
                .mergeRequired(
                    documentID: documentID,
                    revision: 7,
                    reason: .unresolvedConflict
                ),
            ]
        )
    }

    func testLocalApplierRenamesWithoutChangingUUIDAndDoesNotQueueSave()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeURL = root.appendingPathComponent("메인/1권")
        try FileManager.default.createDirectory(
            at: volumeURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let folder = DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/1권"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let original = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: folderID,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/1권/001화.txt"
            ),
            userOrder: 2,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let oldURL = root.appendingPathComponent(
            original.relativePath.rawValue
        )
        try Data("로컬".utf8).write(to: oldURL)
        let repository = SnapshotDocumentRepository(
            documents: [folder, original]
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: documentID.rawValue,
                path: "메인/1권/서버 이름.txt",
                content: "서버 본문",
                revision: 3
            )
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        let stored = try await repository.document(id: documentID)
        let updated = try XCTUnwrap(stored)
        XCTAssertEqual(updated.id, documentID)
        XCTAssertEqual(
            updated.relativePath.rawValue,
            "메인/1권/서버 이름.txt"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        let newData = try Data(
            contentsOf: root.appendingPathComponent(
                "메인/1권/서버 이름.txt"
            )
        )
        XCTAssertEqual(String(decoding: newData, as: UTF8.self), "서버 본문")
        let marker = root.appendingPathComponent(
            LocalSyncV2SnapshotApplier.markerPrefix
                + documentID.rawValue.uuidString.lowercased()
                + LocalSyncV2SnapshotApplier.markerSuffix
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLocalApplierNeverOverwritesPathOwnedByDifferentUUID()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeURL = root.appendingPathComponent("메인/1권")
        try FileManager.default.createDirectory(
            at: volumeURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let occupiedID = DocumentID(rawValue: UUID())
        let folder = DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/1권"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let occupied = DocumentNode(
            id: occupiedID,
            projectID: projectID,
            kind: .text,
            parentID: folderID,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/1권/점유.txt"
            ),
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let occupiedURL = root.appendingPathComponent(
            occupied.relativePath.rawValue
        )
        try Data("보존할 본문".utf8).write(to: occupiedURL)
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: SnapshotDocumentRepository(
                documents: [folder, occupied]
            ),
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )

        do {
            try await applier.apply(
                localProjectID: projectID,
                snapshot: makeSnapshot(
                    id: UUID(),
                    path: occupied.relativePath.rawValue,
                    revision: 1
                )
            )
            XCTFail("Occupied paths must be rejected.")
        } catch let error as SyncV2LocalSnapshotApplyError {
            XCTAssertEqual(error, .pathOccupiedByDifferentDocument)
        }
        let preserved = try Data(contentsOf: occupiedURL)
        XCTAssertEqual(
            String(decoding: preserved, as: UTF8.self),
            "보존할 본문"
        )
    }

    func testLocalApplierMovesRemoteTombstoneToNumberedTrashAndRestoresSameUUID()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Tombstone-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let notesURL = root.appendingPathComponent("메인/메모장")
        let trashURL = root.appendingPathComponent("메인/휴지통")
        try FileManager.default.createDirectory(
            at: notesURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: trashURL,
            withIntermediateDirectories: true
        )
        try Data("기존 휴지통 사본".utf8).write(
            to: trashURL.appendingPathComponent("사건.txt")
        )

        let projectID = ProjectID(rawValue: UUID())
        let notesID = DocumentID(rawValue: UUID())
        let trashID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let originalPath = RelativeDocumentPath(
            rawValue: "메인/메모장/사건.txt"
        )
        let notes = DocumentNode(
            id: notesID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderFixedCategory.notes.relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let trash = DocumentNode(
            id: trashID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderFixedCategory.trash.relativePath,
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let document = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: notesID,
            relativePath: originalPath,
            userOrder: 2,
            modifiedAt: .distantPast,
            contentHash: SHA256ContentHasher().sha256(
                for: Data("보존할 로컬 본문".utf8)
            )
        )
        let originalURL = root.appendingPathComponent(originalPath.rawValue)
        try Data("보존할 로컬 본문".utf8).write(to: originalURL)
        let repository = SnapshotDocumentRepository(
            documents: [notes, trash, document]
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let tombstone = makeSnapshot(
            id: documentID.rawValue,
            path: originalPath.rawValue,
            content: "",
            revision: 2,
            isDeleted: true
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: tombstone
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        let numberedTrashURL = trashURL.appendingPathComponent("사건_2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(
            try String(contentsOf: numberedTrashURL, encoding: .utf8),
            "보존할 로컬 본문"
        )
        let trashedDocument = try await repository.document(id: documentID)
        let trashed = try XCTUnwrap(trashedDocument)
        XCTAssertEqual(trashed.id, documentID)
        XCTAssertEqual(
            trashed.relativePath.rawValue,
            "메인/휴지통/사건_2.txt"
        )
        guard case let .trashed(restoredOriginalPath, _) =
                trashed.deletionStatus else {
            return XCTFail("원격 tombstone이 로컬 휴지통 상태여야 합니다.")
        }
        XCTAssertEqual(restoredOriginalPath, originalPath)
        let trashRecordURL = root.appendingPathComponent(
            ".writerpad-trash-"
                + documentID.rawValue.uuidString.lowercased()
                + ".json"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: trashRecordURL.path)
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: documentID.rawValue,
                path: originalPath.rawValue,
                content: "서버에서 복원한 본문",
                revision: 3
            )
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        let restoredDocument = try await repository.document(id: documentID)
        let restored = try XCTUnwrap(restoredDocument)
        XCTAssertEqual(restored.id, documentID)
        XCTAssertEqual(restored.relativePath, originalPath)
        XCTAssertEqual(restored.deletionStatus, .active)
        XCTAssertEqual(
            try String(contentsOf: originalURL, encoding: .utf8),
            "서버에서 복원한 본문"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: numberedTrashURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: trashRecordURL.path)
        )
    }

    func testLocalApplierRecoversRenameAfterMetadataFailure()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Snapshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let volumeURL = root.appendingPathComponent("메인/1권")
        try FileManager.default.createDirectory(
            at: volumeURL,
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let documentID = DocumentID(rawValue: UUID())
        let folder = DocumentNode(
            id: folderID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/1권"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let original = DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: folderID,
            relativePath: RelativeDocumentPath(
                rawValue: "메인/1권/이전.txt"
            ),
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        try Data("이전".utf8).write(
            to: root.appendingPathComponent(original.relativePath.rawValue)
        )
        let repository = SnapshotDocumentRepository(
            documents: [folder, original],
            saveFailuresRemaining: 1
        )
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let snapshot = makeSnapshot(
            id: documentID.rawValue,
            path: "메인/1권/복구.txt",
            content: "복구 본문",
            revision: 9
        )

        do {
            try await applier.apply(
                localProjectID: projectID,
                snapshot: snapshot
            )
            XCTFail("The injected metadata failure must surface.")
        } catch {
            // 복구 marker와 새 TXT가 남아 다음 pull에서 같은 거래를 재개한다.
        }
        try await applier.apply(
            localProjectID: projectID,
            snapshot: snapshot
        )
        await applier.finish(
            localProjectID: projectID,
            documentID: documentID.rawValue
        )

        let stored = try await repository.document(id: documentID)
        XCTAssertEqual(
            stored?.relativePath.rawValue,
            snapshot.relativePath
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    original.relativePath.rawValue
                ).path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(
                    snapshot.relativePath
                ),
                encoding: .utf8
            ),
            snapshot.content
        )
    }

    func testSyncV2StandardTimingPreservesBudgetsAndConstraints() throws {
        let timing = SyncV2Timing.standard

        XCTAssertEqual(timing.authRestoreTimeout, .seconds(12))
        XCTAssertEqual(
            timing.realtimeSubscriptionTimeout,
            .seconds(12)
        )
        XCTAssertEqual(timing.pullTimeout, .seconds(15))
        XCTAssertEqual(
            timing.workspaceAuthenticationTimeout,
            .seconds(12)
        )
        XCTAssertEqual(timing.authenticationRetryDelay, .seconds(3))
        XCTAssertEqual(timing.periodicDelay, .seconds(90))
        XCTAssertEqual(timing.debounceDelay, .milliseconds(450))
        XCTAssertEqual(timing.refreshMargin, 5 * 60)
        XCTAssertEqual(timing.refreshRetryDelay, .seconds(30))
        XCTAssertEqual(
            timing.backoff,
            [
                .seconds(1), .seconds(2), .seconds(5),
                .seconds(10), .seconds(30),
            ]
        )
        XCTAssertEqual(timing.gateHoldTimeout, .seconds(20))
        XCTAssertEqual(
            timing.authenticationRestoringYieldDelay,
            .milliseconds(100)
        )
        XCTAssertEqual(
            timing.stableSubscriptionResetInterval,
            .seconds(30)
        )
        XCTAssertEqual(timing.quietProgressInterval, .seconds(3))

        XCTAssertGreaterThan(
            timing.pullTimeout,
            timing.authRestoreTimeout
        )
        XCTAssertLessThan(
            timing.realtimeSubscriptionTimeout,
            timing.pullTimeout
        )
        XCTAssertLessThan(timing.maximumBackoff, timing.periodicDelay)
        XCTAssertLessThan(
            timing.debounceDelay,
            try XCTUnwrap(timing.backoff.min())
        )
        XCTAssertGreaterThan(
            timing.gateHoldTimeout,
            timing.pullTimeout
        )
        XCTAssertLessThan(
            timing.refreshRetryDelay,
            .seconds(timing.refreshMargin)
        )
        XCTAssertEqual(
            timing.workspaceAuthenticationTimeout,
            timing.authRestoreTimeout
        )
    }

    func testWorkspaceStatusReducerUsesTextIconDetailAndStablePriority() {
        let hash = ContentHash(
            rawValue: String(repeating: "a", count: 64)
        )!
        let saved = SaveState.saved(
            generation: 1,
            savedAt: Date(timeIntervalSince1970: 1),
            contentHash: hash
        )
        let editing = WorkspaceSyncStatusReducer.presentation(
            saveState: .editing(generation: 2),
            handoffState: .failed(generation: 2, message: "record"),
            workspaceState: SyncV2WorkspaceState(
                lastResult: .failed(detail: "server")
            ),
            leaseState: .heldByOther(expiresAt: nil)
        )
        XCTAssertEqual(editing.label, "편집 중")
        XCTAssertFalse(editing.systemImage.isEmpty)
        XCTAssertFalse(editing.detail.isEmpty)

        let cases: [(
            SaveState,
            SyncHandoffState,
            SyncV2WorkspaceState,
            EditLeaseDisplayState,
            String
        )] = [
            (.saving(generation: 1), .idle, .init(), .localOnly, "로컬 저장 중"),
            (saved, .failed(generation: 1, message: "기록"), .init(), .localOnly, "동기화 기록 실패"),
            (saved, .idle, .init(progress: .pulling), .localOnly, "서버 동기화 중"),
            (saved, .idle, .init(progress: .checkingAuthentication), .localOnly, "로그인 확인 중"),
            (saved, .idle, .init(lastResult: .synced(at: .distantPast)), .localOnly, "서버 동기화됨"),
            (saved, .idle, .init(connection: .offline), .localOnly, "오프라인 저장됨"),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .init(progress: .pulling),
                .heldByOther(expiresAt: nil),
                "다른 기기 편집 중"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .init(lastResult: .waiting),
                .heldByOther(expiresAt: nil),
                "다른 기기 편집 중"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .init(lastResult: .synced(at: Date(timeIntervalSince1970: 0))),
                .localOnly,
                "동기화 대기"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .init(lastResult: .synced(at: Date(timeIntervalSince1970: 2))),
                .localOnly,
                "서버 동기화됨"
            ),
            (saved, .queued(generation: 1, operationIDs: [UUID()]), .init(), .localOnly, "동기화 대기"),
            (saved, .idle, .init(lastResult: .authenticationRequired), .localOnly, "인증 필요"),
            (
                saved,
                .serverSizeLimitExceeded(
                    generation: 1,
                    byteCount: 11,
                    limit: 10
                ),
                .init(),
                .localOnly,
                "서버 크기 제한 초과"
            ),
            (saved, .idle, .init(), .heldByOther(expiresAt: nil), "다른 기기 편집 중"),
            (saved, .idle, .init(lastResult: .automaticallyMerged), .localOnly, "자동 병합됨"),
            (saved, .idle, .init(lastResult: .conflictRequired(detail: "충돌")), .localOnly, "충돌 해결 필요"),
            (
                saved,
                .idle,
                .init(lastResult: .structuralConflict(detail: "경로 충돌")),
                .localOnly,
                "제목·경로 확인 필요"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .init(lastResult: .conflictRequired(detail: "보존된 충돌")),
                .localOnly,
                "충돌 해결 필요"
            ),
            (saved, .idle, .init(lastResult: .failed(detail: "실패")), .localOnly, "동기화 실패"),
            (saved, .idle, .init(), .localOnly, "클라우드 전송 준비"),
        ]
        for (save, handoff, server, lease, expected) in cases {
            let presentation = WorkspaceSyncStatusReducer.presentation(
                saveState: save,
                handoffState: handoff,
                workspaceState: server,
                leaseState: lease
            )
            XCTAssertEqual(presentation.label, expected)
            XCTAssertFalse(presentation.systemImage.isEmpty)
            XCTAssertNotNil(
                UIImage(systemName: presentation.systemImage),
                presentation.systemImage
            )
            XCTAssertFalse(presentation.detail.isEmpty)
        }
    }

    func testCloudConnectedSaveLifecycleUsesOnlyCloudIcons() {
        let hash = ContentHash(
            rawValue: String(repeating: "b", count: 64)
        )!
        let savedAt = Date(timeIntervalSince1970: 10)
        let connectedStates: [(
            SaveState,
            SyncHandoffState,
            SyncV2WorkspaceState
        )] = [
            (.editing(generation: 1), .idle, .init()),
            (.saving(generation: 1), .idle, .init()),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .idle,
                .init()
            ),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .queued(generation: 1, operationIDs: [UUID()]),
                .init()
            ),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .idle,
                .init(lastResult: .synced(at: savedAt))
            ),
        ]

        for (saveState, handoffState, serverState) in connectedStates {
            let presentation = WorkspaceSyncStatusReducer.presentation(
                saveState: saveState,
                handoffState: handoffState,
                workspaceState: serverState,
                leaseState: .localOnly
            )
            XCTAssertTrue(
                presentation.systemImage.contains("icloud"),
                "\(presentation.label): \(presentation.systemImage)"
            )
            XCTAssertNotNil(
                UIImage(systemName: presentation.systemImage),
                presentation.systemImage
            )
        }

        let localOnly = WorkspaceSyncStatusReducer.presentation(
            saveState: .saved(
                generation: 1,
                savedAt: savedAt,
                contentHash: hash
            ),
            handoffState: .idle,
            workspaceState: SyncV2WorkspaceState(lastResult: .localOnly),
            leaseState: .localOnly
        )
        XCTAssertEqual(localOnly.label, "로컬 저장됨")
        XCTAssertEqual(localOnly.systemImage, "checkmark.circle")
    }

    func testWorkspaceStatusReducerComposesIndependentAxes() {
        let conflict = SyncV2WorkspaceState.Result.conflictRequired(
            detail: "본문 변경이 겹쳐 원본과 병합 후보를 보존했습니다."
        )
        let cases: [(SyncV2WorkspaceState, String)] = [
            (
                .init(
                    progress: .pulling,
                    connection: .offline,
                    lastResult: conflict
                ),
                "서버 동기화 중"
            ),
            (
                .init(connection: .reconnecting, lastResult: conflict),
                "충돌 해결 필요"
            ),
            (
                .init(connection: .reconnecting, lastResult: .waiting),
                "동기화 대기"
            ),
            (
                .init(
                    connection: .unknown,
                    lastResult: .synced(at: .distantPast)
                ),
                "서버 동기화됨"
            ),
            (
                .init(
                    connection: .reconnecting,
                    lastResult: .synced(at: .distantPast)
                ),
                "서버 재연결 중"
            ),
        ]

        for (workspaceState, expectedLabel) in cases {
            let presentation = WorkspaceSyncStatusReducer.presentation(
                saveState: .idle,
                handoffState: .idle,
                workspaceState: workspaceState,
                leaseState: .localOnly
            )
            XCTAssertEqual(presentation.label, expectedLabel)
        }
    }

    @MainActor
    func testWorkspaceStartsWithActualInactiveSceneWithoutStaleAuthCheck()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "initial inactive scene",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(
            sceneIsActive: false,
            editingGuards: { [:] }
        ) { _ in }
        XCTAssertEqual(model.state, SyncV2WorkspaceState())
        var pullCount = await puller.count()
        XCTAssertEqual(pullCount, 0)

        await model.updateSceneActivity(true)
        for _ in 0..<500 where await puller.count() == 0 {
            await Task.yield()
        }
        pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceSyncModelDebouncesRealtimeAndStopsInBackground()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let puller = WorkspacePullerStub()
        let realtime = WorkspaceRealtimeStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: realtime,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    kind: .existingServerProject,
                    projectName: "project",
                    ownerSubject: UUID()
                )
            ),
            debounceDelay: .milliseconds(30),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        try await Task.sleep(for: .milliseconds(80))
        var pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)

        await model.updateSceneActivity(true)
        try await Task.sleep(for: .milliseconds(80))
        pullCount = await puller.count()
        XCTAssertEqual(
            pullCount,
            1,
            "같은 active 상태 재통지는 snapshot pull을 중복 실행하면 안 됩니다."
        )

        await realtime.emitChange()
        await realtime.emitChange()
        await realtime.emitChange()
        try await Task.sleep(for: .milliseconds(100))
        pullCount = await puller.count()
        XCTAssertEqual(pullCount, 2)

        await realtime.emitSubscribed()
        try await Task.sleep(for: .milliseconds(100))
        pullCount = await puller.count()
        XCTAssertEqual(pullCount, 3)

        await model.updateSceneActivity(false)
        await realtime.emitChange()
        try await Task.sleep(for: .milliseconds(80))
        pullCount = await puller.count()
        let stopCount = await realtime.stopCount()
        XCTAssertEqual(pullCount, 3)
        XCTAssertGreaterThanOrEqual(stopCount, 1)

        await model.updateSceneActivity(true)
        try await Task.sleep(for: .milliseconds(80))
        pullCount = await puller.count()
        XCTAssertEqual(pullCount, 4)
        await model.stop()
    }

    @MainActor
    func testWorkspaceInitialPullShowsSuccessBeforeRealtimeSubscription()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: HangingWorkspaceRealtimeStub(),
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "realtime timeout",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        try await Task.sleep(for: .milliseconds(80))
        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail(
                "Expected synced after successful pull, got \(model.state)"
            )
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceObservesLogoutAndLoginWithoutSceneRoundTrip() async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let account = AuthenticatedAccount(
            userID: UUID(),
            maskedEmail: "u***@example.com"
        )
        let authentication = ObservableWorkspaceAuthenticationStub(
            state: .authenticated(account)
        )
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: authentication,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "auth updates",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 where await authentication.observerCount() < 1 {
            await Task.yield()
        }
        let observerCount = await authentication.observerCount()
        XCTAssertEqual(observerCount, 1)
        guard observerCount == 1 else {
            await model.stop()
            return
        }

        await authentication.setState(.signedOut(.userInitiated))
        for _ in 0..<500 where model.state.lastResult != .authenticationRequired {
            await Task.yield()
        }
        XCTAssertEqual(model.state.lastResult, .authenticationRequired)

        let pullsBeforeLogin = await puller.count()
        await authentication.setState(.authenticated(account))
        for _ in 0..<500 {
            if await puller.count() > pullsBeforeLogin,
               case .synced = model.state.lastResult {
                break
            }
            await Task.yield()
        }

        let pullsAfterLogin = await puller.count()
        XCTAssertGreaterThan(pullsAfterLogin, pullsBeforeLogin)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceRealtimeSubscriptionWatchdogCancelsHungStart()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = HangingWorkspaceRealtimeStub()
        let model = makeLifecycleModel(
            puller: WorkspacePullerStub(),
            realtime: realtime,
            realtimeSubscriptionTimeout: .milliseconds(20),
            realtimeTimeoutSleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            },
            recoverySleep: { _ in
                try await ContinuousClock().sleep(for: .seconds(60))
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await realtime.stopCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let stopCount = await realtime.stopCount()
        XCTAssertGreaterThanOrEqual(stopCount, 1)
        XCTAssertEqual(model.state.connection, .reconnecting)
        await model.stop()
    }

    @MainActor
    func testWorkspaceFailedInitialSubscriptionStaysReconnectingDuringRetry()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = WorkspaceRealtimeStub()
        let model = makeLifecycleModel(
            puller: WorkspacePullerStub(),
            realtime: realtime,
            recoverySleep: { _ in }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await realtime.startCount() == 0 {
            await Task.yield()
        }
        let initialStartCount = await realtime.startCount()
        XCTAssertGreaterThan(initialStartCount, 0)
        await realtime.emitStatus(.channelError)
        for _ in 0..<100
            where await realtime.startCount() <= initialStartCount {
            await Task.yield()
        }
        let retryStartCount = await realtime.startCount()
        XCTAssertGreaterThan(retryStartCount, initialStartCount)

        await realtime.emitStatus(.subscribing)
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(model.state.connection, .reconnecting)
        await model.stop()
    }

    @MainActor
    func testWorkspaceSyncSeparatesBodyAndStructuralConflicts()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let documentID = UUID()
        let cases: [(
            SyncV2SnapshotMergeReason,
            SyncV2WorkspaceState
        )] = [
            (
                .unresolvedConflict,
                SyncV2WorkspaceState(
                    lastResult: .conflictRequired(
                        detail: "본문 변경이 겹쳐 원본과 병합 후보를 보존했습니다."
                    )
                )
            ),
            (
                .blockedOperation,
                SyncV2WorkspaceState(
                    lastResult: .failed(
                        detail: "서버가 저장 작업을 거부했습니다. 로그인 계정과 작품 접근 권한을 확인한 뒤 다시 시도하세요. 로컬 TXT는 보존되어 있습니다."
                    )
                )
            ),
            (
                .pathOccupiedByDifferentDocument,
                SyncV2WorkspaceState(
                    lastResult: .structuralConflict(
                        detail: "서버 문서의 새 제목과 같은 경로를 다른 로컬 문서가 사용 중입니다. 로컬 TXT는 덮어쓰지 않았습니다."
                    )
                )
            ),
            (
                .invalidLocalHierarchy,
                SyncV2WorkspaceState(
                    lastResult: .structuralConflict(
                        detail: "서버의 폴더나 문서 제목 중 iPad에서 쓸 수 없는 이름이 있어 구조를 적용하지 못했습니다. 이름 끝의 공백과 마침표를 지우고 < > : \" / \\ | ? * 문자를 뺀 뒤 다시 동기화해 주세요. 로컬 TXT는 덮어쓰지 않았습니다."
                    )
                )
            ),
        ]

        for (reason, expectedState) in cases {
            let puller = WorkspacePullerStub(
                report: SyncV2SnapshotPullReport(
                    outcomes: [
                        .mergeRequired(
                            documentID: documentID,
                            revision: 2,
                            reason: reason
                        ),
                    ],
                    appliedSnapshots: []
                )
            )
            let model = SyncV2WorkspaceSyncModel(
                localProjectID: localProjectID,
                puller: puller,
                realtime: nil,
                authenticationService: WorkspaceAuthenticationStub(
                    state: .authenticated(
                        AuthenticatedAccount(
                            userID: UUID(),
                            maskedEmail: "u***@example.com"
                        )
                    )
                ),
                projectBindingService: WorkspaceBindingStub(
                    binding: .connected(
                        localProjectID: localProjectID,
                        serverProjectID: serverProjectID,
                        kind: .existingServerProject,
                        projectName: "conflict classification",
                        ownerSubject: UUID()
                    )
                ),
                periodicDelay: .seconds(600)
            )

            await model.start(editingGuards: { [:] }) { _ in }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(model.state, expectedState)
            await model.stop()
        }
    }

    /// 이름을 알아낸 경우에는 그 이름을 화면에 그대로 보여야 한다. 어떤 폴더가
    /// 문제인지 모르면 보내는 기기에서 고칠 수가 없어 상태에서 빠져나올 수 없다.
    @MainActor
    func testStructuralConflictNamesTheRejectedFolderInTheMessage()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let documentID = UUID()
        let puller = WorkspacePullerStub(
            report: SyncV2SnapshotPullReport(
                outcomes: [
                    .mergeRequired(
                        documentID: documentID,
                        revision: 2,
                        reason: .invalidLocalHierarchy
                    ),
                ],
                appliedSnapshots: [],
                rejectedStructureNames: [
                    SyncV2RejectedStructureName(
                        name: "가 나 다 라 ",
                        parent: "메인",
                        reason: "이름은 공백이나 마침표로 끝날 수 없습니다."
                    ),
                ]
            )
        )
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID,
                    kind: .existingServerProject,
                    projectName: "이름 표시",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        try await Task.sleep(for: .milliseconds(50))

        guard case let .structuralConflict(detail) = model.state.lastResult
        else {
            return XCTFail("구조 충돌 상태여야 한다.")
        }
        XCTAssertTrue(
            detail.contains("가 나 다 라 "),
            "막힌 이름이 문구에 그대로 나와야 한다: \(detail)"
        )
        XCTAssertTrue(
            detail.contains("공백이나 마침표로 끝날 수 없습니다"),
            "왜 막혔는지도 함께 나와야 한다: \(detail)"
        )
        await model.stop()
    }

    @MainActor
    func testWorkspaceSyncRetriesDispatcherBeforeInitialAndManualPull()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let puller = WorkspacePullerStub()
        let dispatch = WorkspaceDispatchRetrySpy()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "dispatch before pull",
                    ownerSubject: UUID()
                )
            ),
            requestDispatchRetry: {
                await dispatch.record()
            },
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        try await Task.sleep(for: .milliseconds(50))
        var dispatchCount = await dispatch.count()
        var pullCount = await puller.count()
        XCTAssertEqual(dispatchCount, 1)
        XCTAssertEqual(pullCount, 1)

        await model.retry()
        try await Task.sleep(for: .milliseconds(50))
        dispatchCount = await dispatch.count()
        pullCount = await puller.count()
        XCTAssertEqual(dispatchCount, 2)
        XCTAssertEqual(pullCount, 2)
        await model.stop()
    }

    @MainActor
    func testStoppedWorkspaceRejectsLatePullResult() async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let snapshot = makeSnapshot(id: UUID(), revision: 3)
        let puller = CancellationIgnoringWorkspacePuller(
            report: SyncV2SnapshotPullReport(
                outcomes: [
                    .applied(
                        documentID: snapshot.documentID,
                        revision: snapshot.revision,
                        wasOpen: false
                    ),
                ],
                appliedSnapshots: [snapshot]
            )
        )
        var appliedCount = 0
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: nil
                    )
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "late pull",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in
            appliedCount += 1
        }
        await puller.waitUntilStarted()
        await model.stop()
        await puller.finish()
        for _ in 0..<100 {
            await Task.yield()
        }

        XCTAssertEqual(appliedCount, 0)
    }

    @MainActor
    func testWorkspaceDeliversAllAppliedSnapshotsAsOneBinderRefreshBatch()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let snapshots = [
            makeSnapshot(path: "메인/메모장/하나.txt", revision: 1),
            makeSnapshot(path: "메인/메모장/둘.txt", revision: 1),
            makeSnapshot(path: "메인/메모장/셋.txt", revision: 1),
        ]
        let puller = WorkspacePullerStub(
            report: SyncV2SnapshotPullReport(
                outcomes: snapshots.map {
                    .applied(
                        documentID: $0.documentID,
                        revision: $0.revision,
                        wasOpen: false
                    )
                },
                appliedSnapshots: snapshots
            )
        )
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(userID: UUID(), maskedEmail: nil)
                )
            ),
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "batched binder refresh",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )
        var deliveredBatches: [[UUID]] = []

        await model.start(editingGuards: { [:] }) { batch in
            deliveredBatches.append(batch.map(\.documentID))
        }
        for _ in 0..<500 where deliveredBatches.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(deliveredBatches, [snapshots.map(\.documentID)])
        await model.stop()
    }

    func testRealtimeSubscriptionGateIgnoresInitialSubscription() {
        var gate = SyncV2RealtimeSubscriptionGate()

        XCTAssertFalse(gate.receiveSubscribed())
        XCTAssertTrue(gate.receiveSubscribed())
        XCTAssertTrue(gate.receiveSubscribed())
    }

    func testRealtimeConnectGateSerializesSharedClientSubscriptions()
        async throws {
        let gate = SyncV2RealtimeConnectGate()
        let probe = RealtimeConnectGateProbe()
        let first = Task {
            try await gate.withSubscription {
                await probe.enterAndWait()
                await probe.leave()
            }
        }
        await probe.waitUntilStarted(1)
        let second = Task {
            try await gate.withSubscription {
                await probe.enterAndWait()
                await probe.leave()
            }
        }
        for _ in 0..<20 { await Task.yield() }

        let startedCount = await probe.startedCount()
        XCTAssertEqual(startedCount, 1)
        await probe.releaseOne()
        try await first.value
        await probe.waitUntilStarted(2)
        let maximumWhileWaiting = await probe.maximumConcurrentCount()
        XCTAssertEqual(maximumWhileWaiting, 1)

        await probe.releaseOne()
        try await second.value
        let maximumAfterCompletion = await probe.maximumConcurrentCount()
        XCTAssertEqual(maximumAfterCompletion, 1)
    }

    func testBackgroundRealtimeWatchdogReleasesHungSubscription()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = HangingAllRealtimeStub()
        let coordinator = SyncV2BackgroundSyncCoordinator(
            puller: BackgroundPullerStub(),
            realtime: realtime,
            projectBindingService: BackgroundBindingStub(bindings: []),
            periodicDelay: .seconds(600),
            realtimeSubscriptionTimeout: .milliseconds(20),
            realtimeTimeoutSleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            },
            sleep: { _ in
                try await ContinuousClock().sleep(for: .seconds(60))
            }
        )

        await coordinator.start()
        for _ in 0..<100 where await realtime.stopCount() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let startCount = await realtime.startCount()
        let stopCount = await realtime.stopCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertGreaterThanOrEqual(stopCount, 1)
        await coordinator.stop()
    }

    func testBackgroundSyncKeepsInactiveProjectsLiveAndSkipsOpenProject()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let openProjectID = ProjectID(rawValue: UUID())
        let backgroundProjectID = ProjectID(rawValue: UUID())
        let bindings = BackgroundBindingStub(
            bindings: [
                .connected(
                    localProjectID: openProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "open",
                    ownerSubject: UUID()
                ),
                .connected(
                    localProjectID: backgroundProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "background",
                    ownerSubject: UUID()
                ),
            ]
        )
        let puller = BackgroundPullerStub()
        let realtime = WorkspaceRealtimeStub()
        let coordinator = SyncV2BackgroundSyncCoordinator(
            puller: puller,
            realtime: realtime,
            projectBindingService: bindings,
            debounceDelay: .milliseconds(20),
            periodicDelay: .seconds(600)
        )

        await coordinator.prioritizeProject(openProjectID)
        await coordinator.start()
        try await waitForBackgroundPulls(
            1,
            puller: puller
        )
        var completed = await puller.completedProjectIDs()
        XCTAssertEqual(completed, [backgroundProjectID])

        await realtime.emitChange()
        try await waitForBackgroundPulls(
            2,
            puller: puller
        )
        completed = await puller.completedProjectIDs()
        XCTAssertEqual(
            completed.filter { $0 == backgroundProjectID }.count,
            2
        )
        XCTAssertFalse(completed.contains(openProjectID))

        await coordinator.prioritizeProject(backgroundProjectID)
        try await waitForBackgroundPulls(
            3,
            puller: puller
        )
        completed = await puller.completedProjectIDs()
        await coordinator.stop()
        XCTAssertTrue(completed.contains(openProjectID))
    }

    func testBackgroundForegroundEntryDoesNotRestartInitialSubscription()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = WorkspaceRealtimeStub()
        let coordinator = SyncV2BackgroundSyncCoordinator(
            puller: BackgroundPullerStub(),
            realtime: realtime,
            projectBindingService: BackgroundBindingStub(bindings: []),
            periodicDelay: .seconds(600)
        )

        await coordinator.start()
        for _ in 0..<100 where await realtime.startCount() < 1 {
            await Task.yield()
        }
        await coordinator.appEnteredForeground()
        for _ in 0..<20 { await Task.yield() }

        let startCount = await realtime.startCount()
        let stopCount = await realtime.stopCount()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        await coordinator.stop()
    }

    func testBackgroundProjectPullsAreIndependent() async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let slowProjectID = ProjectID(rawValue: UUID())
        let fastProjectID = ProjectID(rawValue: UUID())
        let bindings = BackgroundBindingStub(
            bindings: [
                .connected(
                    localProjectID: slowProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "slow",
                    ownerSubject: UUID()
                ),
                .connected(
                    localProjectID: fastProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "fast",
                    ownerSubject: UUID()
                ),
            ]
        )
        let puller = BackgroundPullerStub(
            delays: [slowProjectID: 300_000_000]
        )
        let coordinator = SyncV2BackgroundSyncCoordinator(
            puller: puller,
            realtime: WorkspaceRealtimeStub(),
            projectBindingService: bindings,
            periodicDelay: .seconds(600)
        )

        await coordinator.start()
        for _ in 0..<100 {
            if await puller.completedProjectIDs().contains(
                fastProjectID
            ) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        var completed = await puller.completedProjectIDs()
        XCTAssertTrue(completed.contains(fastProjectID))
        XCTAssertFalse(completed.contains(slowProjectID))

        try await waitForBackgroundPulls(2, puller: puller)
        completed = await puller.completedProjectIDs()
        await coordinator.stop()
        XCTAssertEqual(Set(completed), [slowProjectID, fastProjectID])
    }

    private func waitForBackgroundPulls(
        _ count: Int,
        puller: BackgroundPullerStub
    ) async throws {
        for _ in 0..<100 {
            if await puller.completedProjectIDs().count >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("background pull completion timeout")
    }

    @MainActor
    func testWorkspaceSyncWaitsForSessionRestoreWithoutFalseAuthWarning()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let auth = WorkspaceAuthenticationStub(state: .restoring)
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: auth,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "restore race",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        XCTAssertEqual(model.state.progress, .checkingAuthentication)
        var count = await puller.count()
        XCTAssertEqual(count, 0)

        await auth.setState(
            .authenticated(
                AuthenticatedAccount(
                    userID: UUID(),
                    maskedEmail: "u***@example.com"
                )
            )
        )
        for _ in 0..<100 where await puller.count() == 0 {
            await Task.yield()
        }
        count = await puller.count()
        XCTAssertEqual(count, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceAuthenticationWatchdogNeverLeavesCheckingForever()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let timeout = WorkspaceAuthenticationTimeoutGate()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: WorkspacePullerStub(),
            realtime: nil,
            authenticationService:
                WorkspaceAuthenticationStub(state: .restoring),
            projectBindingService: WorkspaceBindingStub(binding: nil),
            periodicDelay: .seconds(600),
            authenticationTimeout: .seconds(12),
            authenticationSleep: { duration in
                try await timeout.sleep(duration)
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        XCTAssertEqual(model.state.progress, .checkingAuthentication)
        await timeout.waitUntilSleeping()
        await timeout.fire()
        for _ in 0..<100 where model.state.connection != .offline {
            await Task.yield()
        }

        XCTAssertEqual(model.state.connection, .offline)
        await model.stop()
    }

    @MainActor
    func testWorkspaceOverallDeadlineStopsImmediateRestoringLoop()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let authentication = AlwaysRestoringAuthenticationStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: ProjectID(rawValue: UUID()),
            puller: WorkspacePullerStub(),
            realtime: nil,
            authenticationService: authentication,
            projectBindingService: WorkspaceBindingStub(binding: nil),
            periodicDelay: .seconds(600),
            authenticationTimeout: .milliseconds(25),
            authenticationRetryDelay: .milliseconds(10)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<50 where model.state.connection != .offline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.state.connection, .offline)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.state.connection, .offline)
        await model.networkRecovered()
        XCTAssertEqual(model.state.connection, .offline)
        let restoreCallCount = await authentication.restoreCallCount()
        XCTAssertGreaterThanOrEqual(restoreCallCount, 2)
        await model.stop()
    }

    @MainActor
    func testWorkspaceRepeatsSupersededRestoringResult()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let authentication =
            SequencedWorkspaceAuthenticationStub(
                responses: [
                    .restoring,
                    .authenticated(
                        AuthenticatedAccount(
                            userID: UUID(),
                            maskedEmail: "u***@example.com"
                        )
                    ),
                ]
            )
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: authentication,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "superseded auth",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await puller.count() == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let restoreCallCount = await authentication.restoreCallCount()
        let pullCount = await puller.count()
        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceRetriesAuthenticationAfterTransientNetworkFailure()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let authentication =
            SequencedWorkspaceAuthenticationStub(
                responses: [
                    .unavailable(.networkUnavailable),
                    .authenticated(
                        AuthenticatedAccount(
                            userID: UUID(),
                            maskedEmail: "u***@example.com"
                        )
                    ),
                ]
            )
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: authentication,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "auth retry",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600),
            authenticationRetryDelay: .milliseconds(10)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await puller.count() == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let restoreCallCount = await authentication.restoreCallCount()
        let pullCount = await puller.count()
        XCTAssertEqual(restoreCallCount, 2)
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceSyncShowsOfflineAndRecoversAfterAuthTimeout()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let auth = WorkspaceAuthenticationStub(
            state: .unavailable(.networkUnavailable)
        )
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: auth,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "auth timeout recovery",
                    ownerSubject: UUID()
                )
            ),
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        XCTAssertEqual(model.state.connection, .offline)

        await auth.setState(
            .authenticated(
                AuthenticatedAccount(
                    userID: UUID(),
                    maskedEmail: "u***@example.com"
                )
            )
        )
        await model.networkRecovered()
        for _ in 0..<100 where await puller.count() == 0 {
            await Task.yield()
        }
        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testWorkspaceSyncDetectsBindingCreatedAfterWorkspaceStarts()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let binding = WorkspaceBindingStub(binding: nil)
        let puller = WorkspacePullerStub()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: nil,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: binding,
            periodicDelay: .seconds(600)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        XCTAssertEqual(model.state.lastResult, .localOnly)
        var pullCount = await puller.count()
        XCTAssertEqual(pullCount, 0)

        await binding.setBinding(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: UUID(),
                kind: .newServerProject,
                projectName: "지연 binding",
                ownerSubject: UUID()
            )
        )
        try await Task.sleep(for: .milliseconds(100))

        pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testSnapshotAuthFailureRefreshesAndRetriesOriginalRequest()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = SequencedWorkspacePuller(
            outcomes: [
                .failure(
                    SyncV2ClientError.remote(
                        code: .authRequired,
                        detail: nil
                    )
                ),
                .success(
                    SyncV2SnapshotPullReport(
                        outcomes: [],
                        appliedSnapshots: []
                    )
                ),
            ]
        )
        let authentication = RefreshCountingAuthenticationStub()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil,
            authentication: authentication
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await puller.count() < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let pullCount = await puller.count()
        let refreshCount = await authentication.refreshCount()
        XCTAssertEqual(pullCount, 2)
        XCTAssertEqual(refreshCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        await model.stop()
    }

    @MainActor
    func testRealtimeTerminalStatesReconnectAndPullImmediately()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = WorkspacePullerStub()
        let realtime = WorkspaceRealtimeStub()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: realtime,
            recoverySleep: { _ in }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        await realtime.emitStatus(.subscribed)
        for _ in 0..<100 where await puller.count() < 2 {
            await Task.yield()
        }

        for terminal in [
            SyncV2RealtimeConnectionStatus.closed,
            .channelError,
            .timedOut,
        ] {
            let oldIndex = max(0, await realtime.startCount() - 1)
            await realtime.emitStatus(terminal)
            for _ in 0..<100
                where await realtime.startCount() <= oldIndex + 1 {
                await Task.yield()
            }
            XCTAssertEqual(model.state.connection, .reconnecting)

            let beforeStale = await puller.count()
            await realtime.emitStatus(.subscribed, at: oldIndex)
            for _ in 0..<10 { await Task.yield() }
            let afterStale = await puller.count()
            XCTAssertEqual(afterStale, beforeStale)

            await realtime.emitStatus(.subscribed)
            for _ in 0..<100 where await puller.count() <= beforeStale {
                await Task.yield()
            }
        }

        let realtimeStartCount = await realtime.startCount()
        XCTAssertGreaterThanOrEqual(realtimeStartCount, 4)
        await model.stop()
    }

    @MainActor
    func testPullWatchdogReleasesHungRequestAndRetrySucceeds()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = FirstPullHangsWorkspacePuller()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil,
            pullTimeout: .milliseconds(20),
            retryDelays: [.milliseconds(1)],
            recoverySleep: { duration in
                try await ContinuousClock().sleep(for: duration)
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await puller.count() < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 2)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced after watchdog retry")
        }
        await model.stop()
    }

    @MainActor
    func testEventsDuringPullCoalesceIntoOneFollowUp() async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = ControlledFirstWorkspacePuller()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil,
            debounceDelay: .milliseconds(5)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        await puller.waitUntilFirstStarted()
        model.realtimeChanged()
        model.realtimeChanged()
        model.realtimeChanged()
        try await Task.sleep(for: .milliseconds(20))
        await puller.finishFirst()
        for _ in 0..<100 where await puller.count() < 2 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(30))

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 2)
        await model.stop()
    }

    @MainActor
    func testPeriodicSafetyPullRecoversMissedRealtimeEvent()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = WorkspacePullerStub()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil,
            periodicDelay: .milliseconds(25)
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<100 where await puller.count() < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let pullCount = await puller.count()
        XCTAssertGreaterThanOrEqual(pullCount, 2)
        await model.stop()
    }

    @MainActor
    func testSyncedStatusBecomesReconnectStatusAfterConnectionCloses()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = WorkspaceRealtimeStub()
        let model = makeLifecycleModel(
            puller: WorkspacePullerStub(),
            realtime: realtime,
            retryDelays: [.seconds(60)]
        )

        await model.start(editingGuards: { [:] }) { _ in }
        await realtime.emitStatus(.subscribed)
        for _ in 0..<100 {
            if case .synced = model.state.lastResult { break }
            await Task.yield()
        }
        await realtime.emitStatus(.closed)

        XCTAssertEqual(model.state.connection, .reconnecting)
        let presentation = WorkspaceSyncStatusReducer.presentation(
            saveState: .idle,
            handoffState: .idle,
            workspaceState: model.state,
            leaseState: .localOnly
        )
        XCTAssertEqual(presentation.label, "서버 재연결 중")
        await model.stop()
    }

    @MainActor
    func testBindingChangeAllowsPullRetryAndRealtimeReconnectToReschedule()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let localProjectID = ProjectID(rawValue: UUID())
        let binding = WorkspaceBindingStub(
            binding: .connected(
                localProjectID: localProjectID,
                serverProjectID: UUID(),
                kind: .existingServerProject,
                projectName: "first binding",
                ownerSubject: UUID()
            )
        )
        let puller = SequencedWorkspacePuller(
            outcomes: [
                .failure(.networkUnavailable),
                .failure(.networkUnavailable),
            ]
        )
        let realtime = WorkspaceRealtimeStub()
        let recoverySleep = ManualWorkspaceSleep()
        let model = SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: realtime,
            authenticationService: WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
            projectBindingService: binding,
            periodicDelay: .seconds(600),
            retryDelays: [.seconds(1)],
            recoverySleep: { duration in
                try await recoverySleep.sleep(duration)
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 {
            let pullCount = await puller.count()
            let realtimeStartCount = await realtime.startCount()
            let sleepCount = await recoverySleep.callCount()
            let isReady = pullCount >= 1
                && realtimeStartCount >= 1
                && sleepCount >= 1
            if isReady { break }
            await Task.yield()
        }
        await realtime.emitStatus(.channelError)
        for _ in 0..<500 where await recoverySleep.callCount() < 2 {
            await Task.yield()
        }

        await binding.setBinding(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: UUID(),
                kind: .existingServerProject,
                projectName: "second binding",
                ownerSubject: UUID()
            )
        )
        for _ in 0..<500 {
            let pullCount = await puller.count()
            let realtimeStartCount = await realtime.startCount()
            let sleepCount = await recoverySleep.callCount()
            let isReady = pullCount >= 2
                && realtimeStartCount >= 2
                && sleepCount >= 3
            if isReady { break }
            await Task.yield()
        }
        await realtime.emitStatus(.channelError)
        for _ in 0..<500 where await recoverySleep.callCount() < 4 {
            await Task.yield()
        }

        let pullCount = await puller.count()
        let realtimeStartCount = await realtime.startCount()
        let recoverySleepCount = await recoverySleep.callCount()
        XCTAssertEqual(pullCount, 2)
        XCTAssertGreaterThanOrEqual(realtimeStartCount, 2)
        XCTAssertGreaterThanOrEqual(recoverySleepCount, 4)
        await model.stop()
    }

    @MainActor
    func testCancelledReconnectDelayReleasesRetrySentinel() async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = WorkspaceRealtimeStub()
        let recoverySleep = ManualWorkspaceSleep()
        let model = makeLifecycleModel(
            puller: WorkspacePullerStub(),
            realtime: realtime,
            retryDelays: [.seconds(1)],
            recoverySleep: { duration in
                try await recoverySleep.sleep(duration)
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 where await realtime.startCount() < 1 {
            await Task.yield()
        }
        await realtime.emitStatus(.channelError)
        for _ in 0..<500 where await recoverySleep.callCount() < 1 {
            await Task.yield()
        }
        await recoverySleep.cancelNext()
        for _ in 0..<500 where await recoverySleep.callCount() < 2 {
            await realtime.emitStatus(.channelError)
            await Task.yield()
        }

        let recoverySleepCount = await recoverySleep.callCount()
        XCTAssertEqual(recoverySleepCount, 2)
        await model.stop()
    }

    @MainActor
    func testImmediateDisconnectsAccumulateRealtimeReconnectBackoff()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = WorkspacePullerStub()
        let realtime = WorkspaceRealtimeStub()
        let recoverySleep = ManualWorkspaceSleep()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: realtime,
            retryDelays: [
                .seconds(1), .seconds(2), .seconds(5),
            ],
            recoverySleep: { duration in
                try await recoverySleep.sleep(duration)
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for attempt in 0..<3 {
            for _ in 0..<500
                where await realtime.startCount() <= attempt {
                await Task.yield()
            }
            let pullCount = await puller.count()
            await realtime.emitStatus(.subscribed)
            for _ in 0..<500 where await puller.count() <= pullCount {
                await Task.yield()
            }
            await realtime.emitStatus(.closed)
            for _ in 0..<500
                where await recoverySleep.callCount() <= attempt {
                await Task.yield()
            }
            await recoverySleep.resumeNext()
        }

        for _ in 0..<500 where await realtime.startCount() < 4 {
            await Task.yield()
        }
        let recordedDurations = await recoverySleep.recordedDurations()
        XCTAssertEqual(
            recordedDurations,
            [.seconds(1), .seconds(2), .seconds(5)]
        )
        await model.stop()
    }

    @MainActor
    func testSuccessfulPullShowsSyncedWhileRealtimeIsUnhealthy() async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = WorkspacePullerStub()
        let realtime = WorkspaceRealtimeStub()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: realtime
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 {
            if case .synced = model.state.lastResult { break }
            await Task.yield()
        }

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.state)")
        }
        XCTAssertEqual(model.state.connection, .unknown)
        let presentation = WorkspaceSyncStatusReducer.presentation(
            saveState: .idle,
            handoffState: .idle,
            workspaceState: model.state,
            leaseState: .localOnly
        )
        XCTAssertEqual(presentation.label, "서버 동기화됨")
        await model.stop()
    }

    @MainActor
    func testRealtimeFailureCannotOverwriteConflictResult() async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let realtime = WorkspaceRealtimeStub()
        let puller = WorkspacePullerStub(
            report: SyncV2SnapshotPullReport(
                outcomes: [
                    .mergeRequired(
                        documentID: UUID(),
                        revision: 2,
                        reason: .unresolvedConflict
                    ),
                ],
                appliedSnapshots: []
            )
        )
        let model = makeLifecycleModel(
            puller: puller,
            realtime: realtime,
            retryDelays: [.seconds(60)]
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 {
            if case .conflictRequired = model.state.lastResult { break }
            await Task.yield()
        }
        await realtime.emitStatus(.closed)

        XCTAssertEqual(model.state.connection, .reconnecting)
        if case .conflictRequired = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected preserved conflict, got \(model.state)")
        }
        let presentation = WorkspaceSyncStatusReducer.presentation(
            saveState: .idle,
            handoffState: .idle,
            workspaceState: model.state,
            leaseState: .localOnly
        )
        XCTAssertEqual(presentation.label, "충돌 해결 필요")
        await model.stop()
    }

    @MainActor
    func testHungAuthenticationRefreshReleasesPullBeforeTimeoutRetry()
        async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = SequencedWorkspacePuller(
            outcomes: [
                .failure(
                    .remote(code: .authRequired, detail: nil)
                ),
                .success(
                    SyncV2SnapshotPullReport(
                        outcomes: [],
                        appliedSnapshots: []
                    )
                ),
            ]
        )
        let authentication = HangingRefreshAuthenticationStub()
        let pullTimeoutSleep = ManualWorkspaceSleep()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil,
            authentication: authentication,
            pullTimeout: .seconds(15),
            pullTimeoutSleep: { duration in
                try await pullTimeoutSleep.sleep(duration)
            },
            recoverySleep: { _ in
                throw CancellationError()
            }
        )

        await model.start(editingGuards: { [:] }) { _ in }
        for _ in 0..<500 {
            let refreshCount = await authentication.refreshCount()
            let timeoutCount = await pullTimeoutSleep.callCount()
            let isReady = refreshCount >= 1 && timeoutCount >= 2
            if isReady { break }
            await Task.yield()
        }
        await pullTimeoutSleep.resumeLast()
        for _ in 0..<500 {
            if case .authenticationRequired = model.state.lastResult { break }
            await Task.yield()
        }

        await model.retry()
        for _ in 0..<500 where await puller.count() < 2 {
            await Task.yield()
        }

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 2)
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected retry to start after refresh timeout")
        }
        await authentication.releaseRefresh()
        await model.stop()
    }

    @MainActor
    func testInvalidatedPullDoesNotLeavePendingFollowUp() async {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let puller = ControlledFirstWorkspacePuller()
        let model = makeLifecycleModel(
            puller: puller,
            realtime: nil
        )

        await model.start(editingGuards: { [:] }) { _ in }
        await puller.waitUntilFirstStarted()
        await model.retry()
        await model.updateSceneActivity(false)
        await puller.finishFirst()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(model.state, SyncV2WorkspaceState())
        await model.updateSceneActivity(true)
        for _ in 0..<500 where await puller.count() < 2 {
            await Task.yield()
        }
        for _ in 0..<100 { await Task.yield() }

        let pullCount = await puller.count()
        XCTAssertEqual(
            pullCount,
            2,
            "무효화된 pull의 pending 요청이 scene 재개 pull 뒤 남으면 안 됩니다."
        )
        if case .synced = model.state.lastResult {
            // expected
        } else {
            XCTFail("Expected resumed generation to settle as synced")
        }
        await model.stop()
    }

    func testRealtimeConnectGateTimesOutHungOperationAndReleasesWaiter()
        async {
        let gate = SyncV2RealtimeConnectGate()
        let operation = SequencedRealtimeGateOperation()
        let timeoutSleep = ManualWorkspaceSleep()
        let first = Task { () -> SyncV2RealtimeTriggerError? in
            do {
                try await gate.withSubscription(
                    timeout: .seconds(20),
                    timeoutSleep: { duration in
                        try await timeoutSleep.sleep(duration)
                    }
                ) {
                    await operation.run()
                }
                return nil
            } catch let error as SyncV2RealtimeTriggerError {
                return error
            } catch {
                return nil
            }
        }
        await operation.waitUntilStarted(1)
        let second = Task { () -> Bool in
            do {
                try await gate.withSubscription(
                    timeout: .seconds(20),
                    timeoutSleep: { duration in
                        try await timeoutSleep.sleep(duration)
                    }
                ) {
                    await operation.run()
                }
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let startCountWhileHeld = await operation.startCount()
        XCTAssertEqual(startCountWhileHeld, 1)
        await timeoutSleep.waitUntilCalled(1)
        await timeoutSleep.resumeNext()
        let emergencyRelease = Task {
            for _ in 0..<50_000 { await Task.yield() }
            return await operation.releaseHungIfSecondDidNotStart()
        }
        await operation.waitUntilStarted(2)
        let startCountAfterTimeout = await operation.startCount()
        XCTAssertEqual(startCountAfterTimeout, 2)
        let requiredEmergencyRelease = await emergencyRelease.value
        XCTAssertFalse(requiredEmergencyRelease)
        let firstError = await first.value
        switch firstError {
        case .subscriptionTimedOut?:
            break
        default:
            XCTFail("Expected subscriptionTimedOut")
        }
        let secondCompleted = await second.value
        XCTAssertTrue(secondCompleted)
        await operation.releaseHungOperation()
    }

    func testDocumentMutationGateTimesOutHungOperationAndReleasesWaiter()
        async {
        let gate = SyncV2DocumentMutationGate()
        let documentID = UUID()
        let operation = SequencedRealtimeGateOperation()
        let timeoutSleep = ManualWorkspaceSleep()
        let first = Task { () -> SyncV2DocumentMutationGateError? in
            do {
                try await gate.withCriticalSection(
                    documentID: documentID,
                    holdTimeout: .seconds(20),
                    timeoutSleep: { duration in
                        try await timeoutSleep.sleep(duration)
                    }
                ) {
                    await operation.run()
                }
                return nil
            } catch let error as SyncV2DocumentMutationGateError {
                return error
            } catch {
                return nil
            }
        }
        await operation.waitUntilStarted(1)
        let second = Task { () -> Bool in
            do {
                try await gate.withCriticalSection(
                    documentID: documentID,
                    holdTimeout: .seconds(20),
                    timeoutSleep: { duration in
                        try await timeoutSleep.sleep(duration)
                    }
                ) {
                    await operation.run()
                }
                return true
            } catch {
                return false
            }
        }
        for _ in 0..<100 { await Task.yield() }
        let startCountWhileHeld = await operation.startCount()
        XCTAssertEqual(startCountWhileHeld, 1)
        await timeoutSleep.waitUntilCalled(1)
        await timeoutSleep.resumeNext()
        let emergencyRelease = Task {
            for _ in 0..<50_000 { await Task.yield() }
            return await operation.releaseHungIfSecondDidNotStart()
        }
        await operation.waitUntilStarted(2)
        let startCountAfterTimeout = await operation.startCount()
        let requiredEmergencyRelease = await emergencyRelease.value
        let firstError = await first.value
        let secondCompleted = await second.value
        XCTAssertEqual(startCountAfterTimeout, 2)
        XCTAssertFalse(requiredEmergencyRelease)
        XCTAssertEqual(firstError, .holdTimedOut)
        XCTAssertTrue(secondCompleted)
        await operation.releaseHungOperation()
    }

    func testLegacyWindowsRootLabelsAreCanonicalizedWithoutDuplicateFolders()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-RootAlias-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/휴지통"),
            withIntermediateDirectories: false
        )
        let projectID = ProjectID(rawValue: UUID())
        let main = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인"),
            userOrder: -1,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let trash = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: main.id,
            relativePath: BinderFixedCategory.trash.relativePath,
            userOrder: BinderFixedCategory.trash.fixedOrder,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let repository = SnapshotDocumentRepository(documents: [main, trash])
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root)
        )
        let treeID = UUID()
        let content = """
        {"tree_order":{"<root>":["📚 원고","👤 캐릭터","📖 설정집","📝 메모장","🗺️ 메인 스토리 틀","🌊 흐름 정리","🔍 복선","📌 장소","🗑️ 휴지통"],"메인/플롯":["빈 장면"]},"version":1}
        """

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeSnapshot(
                id: treeID,
                path: syncV2TreeOrderPath,
                content: content,
                revision: 1
            )
        )
        await applier.finish(localProjectID: projectID, documentID: treeID)

        let canonicalRoots = [
            "원고", "캐릭터", "설정집", "메모장", "스토리 플롯",
            "흐름정리", "복선", "장소", "휴지통",
        ]
        for name in canonicalRoots {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("메인/\(name)").path
                ),
                name
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/스토리 플롯/빈 장면").path
            )
        )
        for name in ["📚 원고", "🗺️ 메인 스토리 틀", "🌊 흐름 정리"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("메인/\(name)").path
                ),
                name
            )
        }
        let documents = try await repository.documents(in: projectID)
        XCTAssertTrue(documents.contains {
            $0.relativePath == BinderFixedCategory.storyPlot.relativePath
        })
        XCTAssertFalse(documents.contains {
            $0.relativePath.rawValue.contains("🗺️")
        })
    }

    @MainActor
    private func makeLifecycleModel(
        puller: any SyncV2SnapshotPulling,
        realtime: (any SyncV2RealtimeTriggering)?,
        authentication: any AuthenticationServicing =
            WorkspaceAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: UUID(),
                        maskedEmail: "u***@example.com"
                    )
                )
            ),
        debounceDelay: Duration = .milliseconds(5),
        periodicDelay: Duration = .seconds(600),
        realtimeSubscriptionTimeout: Duration = .seconds(12),
        pullTimeout: Duration = .seconds(15),
        retryDelays: [Duration] = [.seconds(1), .seconds(2)],
        realtimeTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        pullTimeoutSleep:
            @escaping SyncV2WorkspaceSleep = { duration in
                try await ContinuousClock().sleep(for: duration)
            },
        recoverySleep: @escaping SyncV2WorkspaceSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) -> SyncV2WorkspaceSyncModel {
        let localProjectID = ProjectID(rawValue: UUID())
        return SyncV2WorkspaceSyncModel(
            localProjectID: localProjectID,
            puller: puller,
            realtime: realtime,
            authenticationService: authentication,
            projectBindingService: WorkspaceBindingStub(
                binding: .connected(
                    localProjectID: localProjectID,
                    serverProjectID: UUID(),
                    kind: .existingServerProject,
                    projectName: "lifecycle",
                    ownerSubject: UUID()
                )
            ),
            debounceDelay: debounceDelay,
            periodicDelay: periodicDelay,
            realtimeSubscriptionTimeout: realtimeSubscriptionTimeout,
            pullTimeout: pullTimeout,
            retryDelays: retryDelays,
            realtimeTimeoutSleep: realtimeTimeoutSleep,
            pullTimeoutSleep: pullTimeoutSleep,
            recoverySleep: recoverySleep
        )
    }
}

private func makeSnapshot(
    id: UUID = UUID(),
    path: String = "메인/1권/001화.txt",
    content: String = "서버",
    revision: Int64,
    isDeleted: Bool = false
) -> SyncV2RemoteDocumentSnapshot {
    SyncV2RemoteDocumentSnapshot(
        documentID: id,
        relativePath: path,
        content: content,
        revision: revision,
        isDeleted: isDeleted,
        deletedAt: isDeleted ? Date(timeIntervalSince1970: 10) : nil,
        updatedAt: Date(timeIntervalSince1970: 20)
    )
}

private func localState(
    revision: Int64,
    active: Bool = false,
    conflict: Bool = false,
    blockingErrorCode: String? = nil,
    pathCollision: Bool = false
) -> SyncV2SnapshotLocalState {
    SyncV2SnapshotLocalState(
        serverRevision: revision,
        serverPath: "메인/1권/001화.txt",
        hasActiveOperation: active,
        hasUnresolvedConflict: conflict,
        blockingErrorCode: blockingErrorCode,
        hasPathCollision: pathCollision
    )
}

private struct TrashPurgeFixture {
    let repository: SnapshotDocumentRepository
    let notesID: DocumentID
    let trashID: DocumentID
    let originalPath: RelativeDocumentPath
    let trashFileURL: URL
}

private func makeTrashPurgeFixture(
    root: URL,
    projectID: ProjectID,
    documentID: UUID,
    fileName: String
) throws -> TrashPurgeFixture {
    let notesURL = root.appendingPathComponent("메인/메모장")
    let trashURL = root.appendingPathComponent("메인/휴지통")
    try FileManager.default.createDirectory(
        at: notesURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: trashURL,
        withIntermediateDirectories: true
    )
    let main = DocumentNode(
        id: DocumentID(rawValue: UUID()),
        projectID: projectID,
        kind: .folder,
        parentID: nil,
        relativePath: RelativeDocumentPath(rawValue: "메인"),
        userOrder: -1,
        modifiedAt: .distantPast,
        contentHash: nil
    )
    let notes = DocumentNode(
        id: DocumentID(rawValue: UUID()),
        projectID: projectID,
        kind: .folder,
        parentID: main.id,
        relativePath: BinderFixedCategory.notes.relativePath,
        userOrder: 0,
        modifiedAt: .distantPast,
        contentHash: nil
    )
    let trash = DocumentNode(
        id: DocumentID(rawValue: UUID()),
        projectID: projectID,
        kind: .folder,
        parentID: main.id,
        relativePath: BinderFixedCategory.trash.relativePath,
        userOrder: 1,
        modifiedAt: .distantPast,
        contentHash: nil
    )
    let originalPath = RelativeDocumentPath(
        rawValue: "메인/메모장/" + fileName
    )
    let trashPath = RelativeDocumentPath(
        rawValue: "메인/휴지통/" + fileName
    )
    let document = DocumentNode(
        id: DocumentID(rawValue: documentID),
        projectID: projectID,
        kind: .text,
        parentID: trash.id,
        relativePath: trashPath,
        userOrder: 0,
        modifiedAt: .distantPast,
        contentHash: nil,
        deletionStatus: .trashed(
            originalPath: originalPath,
            deletedAt: .distantPast
        )
    )
    let trashFileURL = root.appendingPathComponent(trashPath.rawValue)
    try Data("휴지통 본문".utf8).write(to: trashFileURL)
    try Data("휴지통 record".utf8).write(
        to: root.appendingPathComponent(
            ".writerpad-trash-"
                + documentID.uuidString.lowercased()
                + ".json"
        )
    )
    return TrashPurgeFixture(
        repository: SnapshotDocumentRepository(
            documents: [main, notes, trash, document]
        ),
        notesID: notes.id,
        trashID: trash.id,
        originalPath: originalPath,
        trashFileURL: trashFileURL
    )
}

private actor SnapshotTransportStub: SyncV2SnapshotTransporting {
    let snapshots: [SyncV2RemoteDocumentSnapshot]
    let folders: [SyncV2RemoteFolder]
    let treeOrders: [SyncV2RemoteTreeOrder]

    init(
        snapshots: [SyncV2RemoteDocumentSnapshot],
        folders: [SyncV2RemoteFolder] = [],
        treeOrders: [SyncV2RemoteTreeOrder] = []
    ) {
        self.snapshots = snapshots
        self.folders = folders
        self.treeOrders = treeOrders
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        snapshots
    }

    func fetchFolders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteFolder] {
        folders
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        treeOrders
    }
}

private actor SnapshotClientStub: SyncV2SnapshotClienting {
    let snapshots: [SyncV2RemoteDocumentSnapshot]
    let folders: [SyncV2RemoteFolder]
    let treeOrders: [SyncV2RemoteTreeOrder]

    init(
        snapshots: [SyncV2RemoteDocumentSnapshot],
        folders: [SyncV2RemoteFolder] = [],
        treeOrders: [SyncV2RemoteTreeOrder] = []
    ) {
        self.snapshots = snapshots
        self.folders = folders
        self.treeOrders = treeOrders
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        snapshots.sorted {
            $0.documentID.uuidString < $1.documentID.uuidString
        }
    }

    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] {
        folders
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        treeOrders
    }
}

private actor SnapshotStateStoreStub: SyncV2SnapshotStateStoring {
    private let states: [UUID: SyncV2SnapshotLocalState]
    private let commitResult: Bool
    private var commits: [UUID] = []

    init(
        states: [UUID: SyncV2SnapshotLocalState],
        commitResult: Bool = true
    ) {
        self.states = states
        self.commitResult = commitResult
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2SnapshotLocalState? {
        states[documentID]
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) async throws -> Bool {
        commits.append(snapshot.documentID)
        return commitResult
    }

    func committedIDs() -> [UUID] { commits }

    /// 이 대역은 계약 순서를 적어 두지 않는다. 다루지 않음을 명시한다.
    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
    ) async throws {
        _ = (localProjectID, serverProjectID, treeOrders)
    }
}

private actor EquivalentIdentityStateStoreStub:
    SyncV2SnapshotStateStoring {
    private let remoteDocumentID: UUID
    private let path: String
    private var adopted = false

    init(remoteDocumentID: UUID, path: String) {
        self.remoteDocumentID = remoteDocumentID
        self.path = path
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) -> SyncV2SnapshotLocalState? {
        _ = (localProjectID, serverProjectID)
        guard adopted, documentID == remoteDocumentID else { return nil }
        return SyncV2SnapshotLocalState(
            serverRevision: 1,
            serverPath: path,
            hasActiveOperation: false,
            hasUnresolvedConflict: false,
            blockingErrorCode: nil
        )
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) -> Bool {
        _ = (localProjectID, serverProjectID, snapshot, expectedRevision)
        return false
    }

    func adoptEquivalentInitialDocument(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        localDocumentID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) -> Bool {
        _ = (localProjectID, serverProjectID, localDocumentID)
        guard snapshot.documentID == remoteDocumentID,
              snapshot.relativePath == path,
              snapshot.revision == 1
        else { return false }
        adopted = true
        return true
    }

    /// 이 대역은 계약 순서를 적어 두지 않는다. 다루지 않음을 명시한다.
    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
    ) async throws {
        _ = (localProjectID, serverProjectID, treeOrders)
    }
}

private actor BlockingSnapshotStateStore:
    SyncV2SnapshotStateStoring {
    private var didStartRead = false
    private var readStartWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<Void, Never>?

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async -> SyncV2SnapshotLocalState? {
        _ = (localProjectID, serverProjectID, documentID)
        didStartRead = true
        let waiters = readStartWaiters
        readStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
        return SyncV2SnapshotLocalState(
            serverRevision: 1,
            serverPath: "메인/1권/001화.txt",
            hasActiveOperation: false,
            hasUnresolvedConflict: false,
            blockingErrorCode: nil
        )
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) -> Bool {
        _ = (
            localProjectID,
            serverProjectID,
            snapshot,
            expectedRevision
        )
        return true
    }

    func waitUntilSnapshotReadStarts() async {
        guard !didStartRead else { return }
        await withCheckedContinuation { continuation in
            readStartWaiters.append(continuation)
        }
    }

    func resumeSnapshotRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    /// 이 대역은 계약 순서를 적어 두지 않는다. 다루지 않음을 명시한다.
    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
    ) async throws {
        _ = (localProjectID, serverProjectID, treeOrders)
    }
}

private actor SnapshotMutationSequence {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func events() -> [String] {
        values
    }
}

private actor SequencedSnapshotApplier:
    SyncV2LocalSnapshotApplying {
    let sequence: SnapshotMutationSequence

    init(sequence: SnapshotMutationSequence) {
        self.sequence = sequence
    }

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async {
        _ = (localProjectID, snapshot)
        await sequence.append("remote-snapshot")
    }
}

private actor SnapshotApplierSpy: SyncV2LocalSnapshotApplying {
    private var identifiers: [UUID] = []

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws {
        identifiers.append(snapshot.documentID)
    }

    func appliedIDs() -> [UUID] { identifiers }
}

private actor SnapshotRecoveryApplierSpy:
    SyncV2LocalSnapshotApplying {
    private let recoveryIDs: Set<UUID>
    private let applyError: SyncV2LocalSnapshotApplyError?
    private var identifiers: [UUID] = []

    init(
        recoveryIDs: Set<UUID>,
        applyError: SyncV2LocalSnapshotApplyError? = nil
    ) {
        self.recoveryIDs = recoveryIDs
        self.applyError = applyError
    }

    func requiresCopyRecovery(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async -> Bool {
        _ = localProjectID
        return recoveryIDs.contains(snapshot.documentID)
    }

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) async throws {
        _ = localProjectID
        if let applyError { throw applyError }
        identifiers.append(snapshot.documentID)
    }

    func appliedIDs() -> [UUID] { identifiers }
}

private actor WorkspaceDispatchRetrySpy {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

private actor SnapshotMergeStoreSpy: SyncV2SnapshotMergeStoring {
    private var candidates: [SyncV2SnapshotMergeCandidate] = []

    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        candidates.append(candidate)
    }

    func reasons() -> [SyncV2SnapshotMergeReason] {
        candidates.map(\.reason)
    }
}

private actor SnapshotDocumentRepository:
    DocumentRepository,
    DocumentIdentityReplacing {
    private var values: [DocumentID: DocumentNode]
    private var saveFailuresRemaining: Int

    init(
        documents: [DocumentNode],
        saveFailuresRemaining: Int = 0
    ) {
        values = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.id, $0) }
        )
        self.saveFailuresRemaining = saveFailuresRemaining
    }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        values.values.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        values[id]
    }

    func save(_ document: DocumentNode) async throws {
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw SnapshotTestError.injectedMetadataFailure
        }
        values[document.id] = document
    }

    func removeMetadata(id: DocumentID) async throws {
        values[id] = nil
    }

    func replaceDocumentIdentity(
        from oldID: DocumentID,
        to newID: DocumentID,
        in projectID: ProjectID
    ) async throws {
        guard values[newID] == nil,
              let old = values[oldID],
              old.projectID == projectID
        else { throw SnapshotTestError.injectedMetadataFailure }
        values[oldID] = nil
        values[newID] = DocumentNode(
            id: newID,
            projectID: old.projectID,
            kind: old.kind,
            parentID: old.parentID,
            relativePath: old.relativePath,
            userOrder: old.userOrder,
            modifiedAt: old.modifiedAt,
            contentHash: old.contentHash,
            deletionStatus: old.deletionStatus,
            cursor: old.cursor,
            isExpanded: old.isExpanded
        )
        let children = values.values.filter { $0.parentID == oldID }
        for child in children {
            values[child.id] = DocumentNode(
                id: child.id,
                projectID: child.projectID,
                kind: child.kind,
                parentID: newID,
                relativePath: child.relativePath,
                userOrder: child.userOrder,
                modifiedAt: child.modifiedAt,
                contentHash: child.contentHash,
                deletionStatus: child.deletionStatus,
                cursor: child.cursor,
                isExpanded: child.isExpanded
            )
        }
    }

    func failNextSave() {
        saveFailuresRemaining += 1
    }
}

private enum SnapshotTestError: Error {
    case injectedMetadataFailure
}

private actor SnapshotWorkspaceLocator: ProjectWorkspaceLocating {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func workspaceRoot(for projectID: ProjectID) async throws -> URL {
        root
    }
}

private actor WorkspacePullerStub: SyncV2SnapshotPulling {
    private var pulls = 0
    private let report: SyncV2SnapshotPullReport

    init(
        report: SyncV2SnapshotPullReport = SyncV2SnapshotPullReport(
            outcomes: [],
            appliedSnapshots: []
        )
    ) {
        self.report = report
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        pulls += 1
        return report
    }

    func count() -> Int { pulls }
}

private enum SequencedWorkspacePullOutcome: Sendable {
    case success(SyncV2SnapshotPullReport)
    case failure(SyncV2ClientError)
}

private actor SequencedWorkspacePuller: SyncV2SnapshotPulling {
    private var outcomes: [SequencedWorkspacePullOutcome]
    private var pulls = 0

    init(outcomes: [SequencedWorkspacePullOutcome]) {
        self.outcomes = outcomes
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        _ = (localProjectID, serverProjectID, editingGuards)
        pulls += 1
        guard !outcomes.isEmpty else {
            return SyncV2SnapshotPullReport(
                outcomes: [],
                appliedSnapshots: []
            )
        }
        switch outcomes.removeFirst() {
        case .success(let report):
            return report
        case .failure(let error):
            throw error
        }
    }

    func count() -> Int { pulls }
}

private actor FirstPullHangsWorkspacePuller: SyncV2SnapshotPulling {
    private var pulls = 0

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        _ = (localProjectID, serverProjectID, editingGuards)
        pulls += 1
        if pulls == 1 {
            try await ContinuousClock().sleep(for: .seconds(60))
        }
        return SyncV2SnapshotPullReport(
            outcomes: [],
            appliedSnapshots: []
        )
    }

    func count() -> Int { pulls }
}

private actor ControlledFirstWorkspacePuller: SyncV2SnapshotPulling {
    private var pulls = 0
    private var firstStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        _ = (localProjectID, serverProjectID, editingGuards)
        pulls += 1
        if pulls == 1 {
            firstStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                finishContinuation = continuation
            }
        }
        return SyncV2SnapshotPullReport(
            outcomes: [],
            appliedSnapshots: []
        )
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finishFirst() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func count() -> Int { pulls }
}

private actor CancellationIgnoringWorkspacePuller:
    SyncV2SnapshotPulling {
    private let report: SyncV2SnapshotPullReport
    private var didStart = false
    private var startWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(report: SyncV2SnapshotPullReport) {
        self.report = report
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async -> SyncV2SnapshotPullReport {
        _ = (localProjectID, serverProjectID, editingGuards)
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        return report
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor WorkspaceRealtimeStub: SyncV2RealtimeTriggering {
    private var change: (@Sendable () -> Void)?
    private var subscribed: (@Sendable () -> Void)?
    private var statuses: [
        @Sendable (SyncV2RealtimeConnectionStatus) -> Void
    ] = []
    private var stops = 0

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        change = onChange
        subscribed = onSubscribed
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        change = onChange
        subscribed = onSubscribed
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        _ = projectID
        change = onChange
        statuses.append(onStatus)
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        change = onChange
        statuses.append(onStatus)
    }

    func stop() async {
        stops += 1
        change = nil
        subscribed = nil
    }

    func emitChange() {
        change?()
    }

    func emitSubscribed() {
        if let status = statuses.last {
            status(.subscribed)
        } else {
            subscribed?()
        }
    }

    func emitStatus(
        _ value: SyncV2RealtimeConnectionStatus,
        at index: Int? = nil
    ) {
        guard !statuses.isEmpty else { return }
        let resolved = index ?? statuses.index(before: statuses.endIndex)
        guard statuses.indices.contains(resolved) else { return }
        statuses[resolved](value)
    }

    func stopCount() -> Int { stops }
    func startCount() -> Int { statuses.count }
}

private actor HangingWorkspaceRealtimeStub:
    SyncV2RealtimeTriggering {
    private var stops = 0

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await ContinuousClock().sleep(for: .seconds(60))
    }

    func stop() async {
        stops += 1
    }

    func stopCount() -> Int { stops }
}

private actor HangingAllRealtimeStub: SyncV2RealtimeTriggering {
    private var starts = 0
    private var stops = 0

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        _ = (projectID, onChange, onSubscribed)
        try await ContinuousClock().sleep(for: .seconds(60))
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        _ = (onChange, onSubscribed)
        starts += 1
        try await ContinuousClock().sleep(for: .seconds(60))
    }

    func stop() async {
        stops += 1
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor RealtimeConnectGateProbe {
    private var active = 0
    private var maximumConcurrent = 0
    private var started = 0
    private var blockers: [CheckedContinuation<Void, Never>] = []
    private var startWaiters:
        [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enterAndWait() async {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        started += 1
        let ready = startWaiters.filter { started >= $0.target }
        startWaiters.removeAll { started >= $0.target }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            blockers.append(continuation)
        }
    }

    func leave() {
        active -= 1
    }

    func releaseOne() {
        guard !blockers.isEmpty else { return }
        blockers.removeFirst().resume()
    }

    func waitUntilStarted(_ target: Int) async {
        guard started < target else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((target, continuation))
        }
    }

    func startedCount() -> Int { started }
    func maximumConcurrentCount() -> Int { maximumConcurrent }
}

private actor ManualWorkspaceSleep {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var durations: [Duration] = []
    private var waiters: [Waiter] = []
    private var callWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                durations.append(duration)
                waiters.append(
                    Waiter(id: id, continuation: continuation)
                )
                let ready = callWaiters.filter {
                    durations.count >= $0.target
                }
                callWaiters.removeAll {
                    durations.count >= $0.target
                }
                ready.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func resumeLast() {
        guard !waiters.isEmpty else { return }
        waiters.removeLast().continuation.resume()
    }

    func cancelNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume(
            throwing: CancellationError()
        )
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }

    func waitUntilCalled(_ target: Int) async {
        guard durations.count < target else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((target, continuation))
        }
    }

    func callCount() -> Int { durations.count }
    func recordedDurations() -> [Duration] { durations }
}

private actor SequencedRealtimeGateOperation {
    private var starts = 0
    private var hungContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [
        (target: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func run() async {
        starts += 1
        let ready = startWaiters.filter { starts >= $0.target }
        startWaiters.removeAll { starts >= $0.target }
        ready.forEach { $0.continuation.resume() }
        guard starts == 1 else { return }
        await withCheckedContinuation { continuation in
            hungContinuation = continuation
        }
    }

    func startCount() -> Int { starts }

    func waitUntilStarted(_ target: Int) async {
        guard starts < target else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((target, continuation))
        }
    }

    func releaseHungOperation() {
        hungContinuation?.resume()
        hungContinuation = nil
    }

    func releaseHungIfSecondDidNotStart() -> Bool {
        guard starts < 2 else { return false }
        releaseHungOperation()
        return true
    }
}

private actor WorkspaceAuthenticationStub: AuthenticationServicing {
    private var state: AuthenticationState
    private var restoreWaiters:
        [CheckedContinuation<AuthenticationState, Never>] = []

    init(state: AuthenticationState) {
        self.state = state
    }

    func currentState() -> AuthenticationState { state }
    func restoreSession() async -> AuthenticationState {
        guard state == .restoring else { return state }
        return await withCheckedContinuation { continuation in
            restoreWaiters.append(continuation)
        }
    }
    // 이 대기 상태 더블은 refresh와 restore를 의도적으로 같은 요청으로 본다.
    func refreshSession(force: Bool) async -> AuthenticationState {
        _ = force
        return await restoreSession()
    }
    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState { state }
    func signOut() -> AuthenticationState {
        state = .signedOut(.userInitiated)
        return state
    }

    func setState(_ state: AuthenticationState) {
        self.state = state
        guard state != .restoring else { return }
        let waiters = restoreWaiters
        restoreWaiters.removeAll()
        waiters.forEach { $0.resume(returning: state) }
    }
}

private actor ObservableWorkspaceAuthenticationStub:
    AuthenticationServicing {
    private var state: AuthenticationState
    private var observers: [
        UUID: AsyncStream<AuthenticationState>.Continuation
    ] = [:]

    init(state: AuthenticationState) {
        self.state = state
    }

    func currentState() -> AuthenticationState { state }
    func restoreSession() -> AuthenticationState { state }
    // 이 관찰 더블은 refresh와 restore를 의도적으로 구분하지 않는다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return state
    }

    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = (email, password)
        return state
    }

    func signOut() -> AuthenticationState {
        state = .signedOut(.userInitiated)
        publish(state)
        return state
    }

    func stateUpdates() -> AsyncStream<AuthenticationState> {
        let observerID = UUID()
        return AsyncStream { continuation in
            observers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(observerID) }
            }
        }
    }

    func setState(_ state: AuthenticationState) {
        self.state = state
        publish(state)
    }

    func observerCount() -> Int { observers.count }

    private func publish(_ state: AuthenticationState) {
        observers.values.forEach { $0.yield(state) }
    }

    private func removeObserver(_ observerID: UUID) {
        observers[observerID] = nil
    }
}

private actor RefreshCountingAuthenticationStub:
    AuthenticationServicing {
    private let authenticated = AuthenticationState.authenticated(
        AuthenticatedAccount(
            userID: UUID(),
            maskedEmail: "u***@example.com"
        )
    )
    private var refreshes = 0

    func currentState() -> AuthenticationState { authenticated }
    func restoreSession() -> AuthenticationState { authenticated }
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        refreshes += 1
        return authenticated
    }
    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = (email, password)
        return authenticated
    }
    func signOut() -> AuthenticationState {
        .signedOut(.userInitiated)
    }
    func refreshCount() -> Int { refreshes }
}

private actor HangingRefreshAuthenticationStub:
    AuthenticationServicing {
    private let authenticated = AuthenticationState.authenticated(
        AuthenticatedAccount(
            userID: UUID(),
            maskedEmail: "u***@example.com"
        )
    )
    private var refreshes = 0
    private var refreshContinuation:
        CheckedContinuation<Void, Never>?

    func currentState() -> AuthenticationState { authenticated }
    func restoreSession() -> AuthenticationState { authenticated }

    func refreshSession(force: Bool) async -> AuthenticationState {
        _ = force
        refreshes += 1
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
        return authenticated
    }

    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = (email, password)
        return authenticated
    }

    func signOut() -> AuthenticationState {
        .signedOut(.userInitiated)
    }

    func refreshCount() -> Int { refreshes }

    func releaseRefresh() {
        refreshContinuation?.resume()
        refreshContinuation = nil
    }
}

private actor SequencedWorkspaceAuthenticationStub:
    AuthenticationServicing {
    private var state: AuthenticationState = .restoring
    private var responses: [AuthenticationState]
    private var restoreCalls = 0

    init(responses: [AuthenticationState]) {
        self.responses = responses
    }

    func currentState() -> AuthenticationState { state }

    func restoreSession() -> AuthenticationState {
        restoreCalls += 1
        guard !responses.isEmpty else { return state }
        state = responses.removeFirst()
        return state
    }

    // 이 순서 더블은 refresh를 restore와 같은 다음 응답 소비로 모델링한다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return restoreSession()
    }

    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = (email, password)
        return state
    }

    func signOut() -> AuthenticationState {
        state = .signedOut(.userInitiated)
        return state
    }

    func restoreCallCount() -> Int { restoreCalls }
}

private actor AlwaysRestoringAuthenticationStub:
    AuthenticationServicing {
    private var restoreCalls = 0

    func currentState() -> AuthenticationState { .restoring }

    func restoreSession() -> AuthenticationState {
        restoreCalls += 1
        return .restoring
    }

    // 이 영구 restoring 더블은 refresh와 restore를 의도적으로 구분하지 않는다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return restoreSession()
    }

    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = (email, password)
        return .restoring
    }

    func signOut() -> AuthenticationState {
        .signedOut(.userInitiated)
    }

    func restoreCallCount() -> Int { restoreCalls }
}

private actor WorkspaceAuthenticationTimeoutGate {
    private var didStart = false
    private var startWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var continuation:
        CheckedContinuation<Void, any Error>?

    func sleep(_ duration: Duration) async throws {
        _ = duration
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSleeping() async {
        guard !didStart else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func fire() {
        continuation?.resume()
        continuation = nil
    }
}

private actor WorkspaceBindingStub: ProjectBindingServicing {
    private var binding: ProjectSyncBinding?
    private var observers: [
        UUID: AsyncStream<ProjectSyncBinding?>.Continuation
    ] = [:]

    init(binding: ProjectSyncBinding?) {
        self.binding = binding
    }

    func setBinding(_ binding: ProjectSyncBinding?) {
        self.binding = binding
        observers.values.forEach { $0.yield(binding) }
    }

    func bindingUpdates(
        for localProjectID: ProjectID
    ) -> AsyncStream<ProjectSyncBinding?> {
        _ = localProjectID
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            observers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeObserver(observerID)
                }
            }
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers[observerID] = nil
    }

    func currentBinding(
        for localProjectID: ProjectID
    ) -> ProjectSyncBinding? {
        binding
    }

    func connectedBindings() -> [ProjectSyncBinding] {
        binding.map { [$0] } ?? []
    }

    func createServerProject(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func refreshServerName(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func disconnect(
        localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }
}

private actor BackgroundBindingStub: ProjectBindingServicing {
    let bindings: [ProjectSyncBinding]

    init(bindings: [ProjectSyncBinding]) {
        self.bindings = bindings
    }

    func connectedBindings() -> [ProjectSyncBinding] {
        bindings
    }

    func createServerProject(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func refreshServerName(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func disconnect(
        localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }
}

private actor BackgroundPullerStub: SyncV2SnapshotPulling {
    private let delays: [ProjectID: UInt64]
    private var completed: [ProjectID] = []

    init(delays: [ProjectID: UInt64] = [:]) {
        self.delays = delays
    }

    func pull(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        editingGuards: [UUID: SyncV2EditingGuard]
    ) async throws -> SyncV2SnapshotPullReport {
        _ = (serverProjectID, editingGuards)
        if let delay = delays[localProjectID] {
            try await Task.sleep(nanoseconds: delay)
        }
        completed.append(localProjectID)
        return SyncV2SnapshotPullReport(
            outcomes: [],
            appliedSnapshots: []
        )
    }

    func completedProjectIDs() -> [ProjectID] {
        completed
    }
}

/// pull이 이관을 원격 폴더 반영보다 먼저 돌리는지 본다. 순서가 뒤집히면 기존
/// 폴더에 공유 UUID가 없는 채로 서버 폴더와 짝을 맞추게 되어, 모든 원격 폴더가
/// "이 기기가 모르는 폴더"로 보이고 옮기는 대신 새로 만들어진다.
final class SyncV2PullFolderWiringTests: XCTestCase {
    func testRemoteFolderApplyWaitsForProjectStructureMutation()
        async throws {
        let localProjectID = ProjectID(rawValue: UUID())
        let gate = SyncV2DocumentMutationGate()
        let blocker = SequencedRealtimeGateOperation()
        let holder = Task {
            try await gate.withCriticalSection(
                documentID: syncV2ProjectStructureMutationID(localProjectID)
            ) {
                await blocker.run()
            }
        }
        await blocker.waitUntilStarted(1)

        let order = FolderWiringOrderRecorder()
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [],
                folders: [
                    SyncV2RemoteFolder(
                        folderID: UUID(),
                        parentFolderID: nil,
                        name: "메인",
                        revision: 1,
                        isDeleted: false,
                        updatedAt: Date(timeIntervalSince1970: 10)
                    )
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy(),
            folderApplier: FolderWiringApplierSpy(order: order),
            mutationGate: gate
        )
        let pull = Task {
            try await service.pull(
                localProjectID: localProjectID,
                serverProjectID: UUID()
            )
        }
        for _ in 0..<100 { await Task.yield() }
        let stepsWhileHeld = await order.steps()
        XCTAssertTrue(stepsWhileHeld.isEmpty)

        await blocker.releaseHungOperation()
        _ = try await holder.value
        _ = try await pull.value
        let completedSteps = await order.steps()
        XCTAssertEqual(completedSteps, ["apply"])
    }

    func testMigrationRunsBeforeRemoteFoldersAreApplied() async throws {
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let order = FolderWiringOrderRecorder()
        let marker = FolderWiringMarkerStub(pendingFolderIDs: [])
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [],
                folders: [
                    SyncV2RemoteFolder(
                        folderID: UUID(),
                        parentFolderID: nil,
                        name: "메인",
                        revision: 1,
                        isDeleted: false,
                        updatedAt: Date(timeIntervalSince1970: 10)
                    )
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy(),
            folderApplier: FolderWiringApplierSpy(order: order),
            folderMigration: SyncV2FolderMigration(
                documentRepository: FolderWiringRepositoryStub(order: order),
                marker: marker,
                changeRecorder: FolderWiringRecorderStub()
            ),
            folderMarker: marker,
            folderDocuments: FolderWiringRepositoryStub(order: order)
        )

        _ = try await service.pull(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID
        )

        let steps = await order.steps()
        XCTAssertEqual(steps.first, "migration")
        XCTAssertEqual(steps.last, "apply")
    }

    func testFolderWithUnsentWorkIsHandedToTheApplierAsBlocked()
        async throws {
        let blockedID = UUID()
        let order = FolderWiringOrderRecorder()
        let applier = FolderWiringApplierSpy(order: order)
        let marker = FolderWiringMarkerStub(pendingFolderIDs: [blockedID])
        let service = SyncV2SnapshotPullService(
            client: SnapshotClientStub(
                snapshots: [],
                folders: [
                    SyncV2RemoteFolder(
                        folderID: blockedID,
                        parentFolderID: nil,
                        name: "메인",
                        revision: 1,
                        isDeleted: false,
                        updatedAt: Date(timeIntervalSince1970: 10)
                    )
                ]
            ),
            stateStore: SnapshotStateStoreStub(states: [:]),
            localApplier: SnapshotApplierSpy(),
            mergeStore: SnapshotMergeStoreSpy(),
            folderApplier: applier,
            folderMarker: marker
        )

        _ = try await service.pull(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: UUID()
        )

        // 미전송 작업이 걸린 폴더를 그냥 넘기면 사용자가 방금 한 일이 원격
        // 값으로 덮인다.
        let blocked = await applier.blockedFolderIDs()
        XCTAssertEqual(blocked, [DocumentID(rawValue: blockedID)])
    }
}

private actor FolderWiringOrderRecorder {
    private var recorded: [String] = []

    func record(_ step: String) {
        recorded.append(step)
    }

    func steps() -> [String] { recorded }
}

private actor FolderWiringApplierSpy: SyncV2RemoteFolderApplying {
    private let order: FolderWiringOrderRecorder
    private var blocked: Set<DocumentID> = []

    init(order: FolderWiringOrderRecorder) {
        self.order = order
    }

    func applyRemoteFolders(
        localProjectID: ProjectID,
        remote: [SyncV2RemoteFolder],
        blockedFolderIDs: Set<DocumentID>
    ) async -> SyncV2RemoteFolderApplyReport {
        await order.record("apply")
        blocked = blockedFolderIDs
        return SyncV2RemoteFolderApplyReport()
    }

    func blockedFolderIDs() -> Set<DocumentID> { blocked }
}

private actor FolderWiringRepositoryStub: DocumentRepository {
    private let order: FolderWiringOrderRecorder

    init(order: FolderWiringOrderRecorder) {
        self.order = order
    }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        await order.record("migration")
        return []
    }

    func document(id: DocumentID) throws -> DocumentNode? { nil }
    func save(_ document: DocumentNode) throws {}
    func removeMetadata(id: DocumentID) throws {}
}

private actor FolderWiringMarkerStub: SyncV2FolderMigrationMarking {
    private let pendingFolderIDs: Set<UUID>
    private var completed = false

    init(pendingFolderIDs: Set<UUID>) {
        self.pendingFolderIDs = pendingFolderIDs
    }

    func isFolderMigrationCompleted(localProjectID: ProjectID) -> Bool {
        completed
    }

    func markFolderMigrationCompleted(localProjectID: ProjectID) {
        completed = true
    }

    func foldersWithPendingOperations(
        localProjectID: ProjectID
    ) -> Set<UUID> {
        pendingFolderIDs
    }
}

private actor FolderWiringRecorderStub: DurableLocalChangeRecording {
    func requirement(
        for projectID: ProjectID
    ) async -> DurableRecordingRequirement {
        .durableQueue
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        .queued(operationIDs: [])
    }
}

/// Windows는 아직 folders 표를 모르고 tree_order만 쓴다. 그쪽에서 온 이름
/// 변경을 아이패드가 폴더 기록에도 올려 주지 않으면, 낡은 서버 행이 다음
/// pull에서 방금 바뀐 이름을 되돌린다.
final class SyncV2TreeOrderFolderBridgeTests: XCTestCase {
    func testTreeOrderRenameKeepsTheFolderIdentifierAndPublishesIt()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Bridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/옛 이름"),
            withIntermediateDirectories: true
        )
        let projectID = ProjectID(rawValue: UUID())
        let mainID = DocumentID(rawValue: UUID())
        // 이관을 마친 폴더다. 식별자가 경로에서 계산한 값과 다르다.
        let migratedID = DocumentID(rawValue: UUID())
        let repository = SnapshotDocumentRepository(
            documents: [
                bridgeFolder(
                    id: mainID,
                    projectID: projectID,
                    path: "메인",
                    parent: nil
                ),
                bridgeFolder(
                    id: migratedID,
                    projectID: projectID,
                    path: "메인/옛 이름",
                    parent: mainID
                ),
            ]
        )
        let publisher = FolderIdentityPublisherSpy()
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root),
            folderIdentityPublisher: publisher
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeBridgeSnapshot(
                content:
                    "{\"tree_order\":{\"<root>\":[\"새 이름\"]},\"version\":1}"
            )
        )

        let documents = try await repository.documents(in: projectID)
        let folders = documents.filter {
            $0.kind == .folder && $0.parentID == mainID
        }
        // 폴더가 하나만 남고, 식별자가 그대로여야 서버 폴더 기록과 짝이 이어진다.
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.id, migratedID)
        XCTAssertEqual(folders.first?.relativePath.rawValue, "메인/새 이름")

        let published = await publisher.published()
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.folderID, migratedID)
        XCTAssertEqual(published.first?.name, "새 이름")
        XCTAssertEqual(published.first?.parentFolderID, mainID)
    }

    func testTreeOrderRenameWithDocumentRemovesOldEmptyShellAndKeepsFolderID()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-Bridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("메인/옛 이름"),
            withIntermediateDirectories: true
        )
        try Data("본문".utf8).write(
            to: root.appendingPathComponent("메인/옛 이름/문서.txt")
        )
        let projectID = ProjectID(rawValue: UUID())
        let mainID = DocumentID(rawValue: UUID())
        let folderID = DocumentID(rawValue: UUID())
        let textID = DocumentID(rawValue: UUID())
        let repository = SnapshotDocumentRepository(
            documents: [
                bridgeFolder(
                    id: mainID,
                    projectID: projectID,
                    path: "메인",
                    parent: nil
                ),
                bridgeFolder(
                    id: folderID,
                    projectID: projectID,
                    path: "메인/옛 이름",
                    parent: mainID
                ),
                DocumentNode(
                    id: textID,
                    projectID: projectID,
                    kind: .text,
                    parentID: folderID,
                    relativePath: RelativeDocumentPath(
                        rawValue: "메인/옛 이름/문서.txt"
                    ),
                    userOrder: 0,
                    modifiedAt: .distantPast,
                    contentHash: nil
                ),
            ]
        )
        let publisher = FolderIdentityPublisherSpy()
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: SnapshotWorkspaceLocator(root: root),
            folderIdentityPublisher: publisher
        )
        await applier.preparePull(
            localProjectID: projectID,
            remoteLiveDocumentPaths: ["메인/새 이름/문서.txt"]
        )
        await applier.prepareRemoteFolders(
            localProjectID: projectID,
            remoteLiveFolderPaths: ["메인", "메인/옛 이름"]
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: SyncV2RemoteDocumentSnapshot(
                documentID: textID.rawValue,
                relativePath: "메인/새 이름/문서.txt",
                content: "본문",
                revision: 2,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/옛 이름").path
            )
        )

        try await applier.apply(
            localProjectID: projectID,
            snapshot: makeBridgeSnapshot(
                content:
                    "{\"tree_order\":{\"<root>\":[\"새 이름\"]},\"version\":1}"
            )
        )

        let documents = try await repository.documents(in: projectID)
        let topLevelFolders = documents.filter {
            $0.kind == .folder && $0.parentID == mainID
        }
        XCTAssertEqual(topLevelFolders.count, 1)
        XCTAssertEqual(topLevelFolders.first?.id, folderID)
        XCTAssertEqual(
            topLevelFolders.first?.relativePath.rawValue,
            "메인/새 이름"
        )
        XCTAssertEqual(
            documents.first { $0.id == textID }?.parentID,
            folderID
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("메인/옛 이름").path
            )
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent(
                    "메인/새 이름/문서.txt"
                ),
                encoding: .utf8
            ),
            "본문"
        )
        let published = await publisher.published()
        XCTAssertEqual(published.last?.folderID, folderID)
        XCTAssertEqual(published.last?.name, "새 이름")
    }

    private func bridgeFolder(
        id: DocumentID,
        projectID: ProjectID,
        path: String,
        parent: DocumentID?
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

    private func makeBridgeSnapshot(
        content: String
    ) -> SyncV2RemoteDocumentSnapshot {
        SyncV2RemoteDocumentSnapshot(
            documentID: UUID(),
            relativePath: syncV2TreeOrderPath,
            content: content,
            revision: 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}

private struct PublishedFolder: Equatable {
    let folderID: DocumentID
    let parentFolderID: DocumentID?
    let name: String
}

private actor FolderIdentityPublisherSpy: SyncV2FolderIdentityPublishing {
    private var recorded: [PublishedFolder] = []

    func publishFolder(
        localProjectID: ProjectID,
        folderID: DocumentID,
        parentFolderID: DocumentID?,
        name: String
    ) async {
        recorded.append(
            PublishedFolder(
                folderID: folderID,
                parentFolderID: parentFolderID,
                name: name
            )
        )
    }

    func published() -> [PublishedFolder] { recorded }
}
