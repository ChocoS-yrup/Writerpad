import Foundation
import UIKit
import XCTest
@testable import WriterPad

final class SyncV2SnapshotPullTests: XCTestCase {
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
            serverState: .failed(detail: "server"),
            leaseState: .heldByOther(expiresAt: nil)
        )
        XCTAssertEqual(editing.label, "편집 중")
        XCTAssertFalse(editing.systemImage.isEmpty)
        XCTAssertFalse(editing.detail.isEmpty)

        let cases: [(
            SaveState,
            SyncHandoffState,
            SyncV2WorkspaceServerState,
            EditLeaseDisplayState,
            String
        )] = [
            (.saving(generation: 1), .idle, .idle, .localOnly, "로컬 저장 중"),
            (saved, .failed(generation: 1, message: "기록"), .idle, .localOnly, "동기화 기록 실패"),
            (saved, .idle, .syncing, .localOnly, "서버 동기화 중"),
            (saved, .idle, .checkingAuthentication, .localOnly, "로그인 확인 중"),
            (saved, .idle, .synced(at: .distantPast), .localOnly, "서버 동기화됨"),
            (saved, .idle, .offlineSaved, .localOnly, "오프라인 저장됨"),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .syncing,
                .heldByOther(expiresAt: nil),
                "다른 기기 편집 중"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .waiting,
                .heldByOther(expiresAt: nil),
                "다른 기기 편집 중"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .synced(at: Date(timeIntervalSince1970: 0)),
                .localOnly,
                "동기화 대기"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .synced(at: Date(timeIntervalSince1970: 2)),
                .localOnly,
                "서버 동기화됨"
            ),
            (saved, .queued(generation: 1, operationIDs: [UUID()]), .idle, .localOnly, "동기화 대기"),
            (saved, .idle, .authenticationRequired, .localOnly, "인증 필요"),
            (
                saved,
                .serverSizeLimitExceeded(
                    generation: 1,
                    byteCount: 11,
                    limit: 10
                ),
                .idle,
                .localOnly,
                "서버 크기 제한 초과"
            ),
            (saved, .idle, .idle, .heldByOther(expiresAt: nil), "다른 기기 편집 중"),
            (saved, .idle, .automaticallyMerged, .localOnly, "자동 병합됨"),
            (saved, .idle, .conflictRequired(detail: "충돌"), .localOnly, "충돌 해결 필요"),
            (
                saved,
                .idle,
                .structuralConflict(detail: "경로 충돌"),
                .localOnly,
                "제목·경로 확인 필요"
            ),
            (
                saved,
                .queued(generation: 1, operationIDs: [UUID()]),
                .conflictRequired(detail: "보존된 충돌"),
                .localOnly,
                "충돌 해결 필요"
            ),
            (saved, .idle, .failed(detail: "실패"), .localOnly, "동기화 실패"),
            (saved, .idle, .idle, .localOnly, "클라우드 전송 준비"),
        ]
        for (save, handoff, server, lease, expected) in cases {
            let presentation = WorkspaceSyncStatusReducer.presentation(
                saveState: save,
                handoffState: handoff,
                serverState: server,
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
            SyncV2WorkspaceServerState
        )] = [
            (.editing(generation: 1), .idle, .idle),
            (.saving(generation: 1), .idle, .idle),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .idle,
                .idle
            ),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .queued(generation: 1, operationIDs: [UUID()]),
                .idle
            ),
            (
                .saved(
                    generation: 1,
                    savedAt: savedAt,
                    contentHash: hash
                ),
                .idle,
                .synced(at: savedAt)
            ),
        ]

        for (saveState, handoffState, serverState) in connectedStates {
            let presentation = WorkspaceSyncStatusReducer.presentation(
                saveState: saveState,
                handoffState: handoffState,
                serverState: serverState,
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
            serverState: .localOnly,
            leaseState: .localOnly
        )
        XCTAssertEqual(localOnly.label, "로컬 저장됨")
        XCTAssertEqual(localOnly.systemImage, "checkmark.circle")
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail(
                "Expected synced after successful pull, got \(model.serverState)"
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
        for _ in 0..<500 where model.serverState != .authenticationRequired {
            await Task.yield()
        }
        XCTAssertEqual(model.serverState, .authenticationRequired)

        let pullsBeforeLogin = await puller.count()
        await authentication.setState(.authenticated(account))
        for _ in 0..<500 {
            if await puller.count() > pullsBeforeLogin,
               case .synced = model.serverState {
                break
            }
            await Task.yield()
        }

        let pullsAfterLogin = await puller.count()
        XCTAssertGreaterThan(pullsAfterLogin, pullsBeforeLogin)
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        XCTAssertEqual(model.serverState, .reconnecting)
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

        XCTAssertEqual(model.serverState, .reconnecting)
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
            SyncV2WorkspaceServerState
        )] = [
            (
                .unresolvedConflict,
                .conflictRequired(
                    detail: "본문 변경이 겹쳐 원본과 병합 후보를 보존했습니다."
                )
            ),
            (
                .blockedOperation,
                .failed(
                    detail: "서버가 저장 작업을 거부했습니다. 로그인 계정과 작품 접근 권한을 확인한 뒤 다시 시도하세요. 로컬 TXT는 보존되어 있습니다."
                )
            ),
            (
                .pathOccupiedByDifferentDocument,
                .structuralConflict(
                    detail: "서버 문서의 새 제목과 같은 경로를 다른 로컬 문서가 사용 중입니다. 로컬 TXT는 덮어쓰지 않았습니다."
                )
            ),
            (
                .invalidLocalHierarchy,
                .structuralConflict(
                    detail: "서버 문서의 제목 또는 폴더 위치를 현재 로컬 바인더에 안전하게 적용할 수 없습니다. 로컬 TXT는 덮어쓰지 않았습니다."
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
            XCTAssertEqual(model.serverState, expectedState)
            await model.stop()
        }
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
        XCTAssertEqual(model.serverState, .checkingAuthentication)
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        XCTAssertEqual(model.serverState, .checkingAuthentication)
        await timeout.waitUntilSleeping()
        await timeout.fire()
        for _ in 0..<100 where model.serverState != .offlineSaved {
            await Task.yield()
        }

        XCTAssertEqual(model.serverState, .offlineSaved)
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
        for _ in 0..<50 where model.serverState != .offlineSaved {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.serverState, .offlineSaved)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.serverState, .offlineSaved)
        await model.networkRecovered()
        XCTAssertEqual(model.serverState, .offlineSaved)
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        XCTAssertEqual(model.serverState, .offlineSaved)

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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        XCTAssertEqual(model.serverState, .localOnly)
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
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
            XCTAssertEqual(model.serverState, .reconnecting)

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
        if case .synced = model.serverState {
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
            if case .synced = model.serverState { break }
            await Task.yield()
        }
        await realtime.emitStatus(.closed)

        XCTAssertEqual(model.serverState, .reconnecting)
        let presentation = WorkspaceSyncStatusReducer.presentation(
            saveState: .idle,
            handoffState: .idle,
            serverState: model.serverState,
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
            if case .synced = model.serverState { break }
            await Task.yield()
        }

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 1)
        if case .synced = model.serverState {
            // expected
        } else {
            XCTFail("Expected synced, got \(model.serverState)")
        }
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
            if case .authenticationRequired = model.serverState { break }
            await Task.yield()
        }

        await model.retry()
        for _ in 0..<500 where await puller.count() < 2 {
            await Task.yield()
        }

        let pullCount = await puller.count()
        XCTAssertEqual(pullCount, 2)
        if case .synced = model.serverState {
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
        XCTAssertEqual(model.serverState, .idle)
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
        if case .synced = model.serverState {
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
    blockingErrorCode: String? = nil
) -> SyncV2SnapshotLocalState {
    SyncV2SnapshotLocalState(
        serverRevision: revision,
        serverPath: "메인/1권/001화.txt",
        hasActiveOperation: active,
        hasUnresolvedConflict: conflict,
        blockingErrorCode: blockingErrorCode
    )
}

private actor SnapshotTransportStub: SyncV2SnapshotTransporting {
    let snapshots: [SyncV2RemoteDocumentSnapshot]

    init(snapshots: [SyncV2RemoteDocumentSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        snapshots
    }
}

private actor SnapshotClientStub: SyncV2SnapshotClienting {
    let snapshots: [SyncV2RemoteDocumentSnapshot]

    init(snapshots: [SyncV2RemoteDocumentSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        snapshots.sorted {
            $0.documentID.uuidString < $1.documentID.uuidString
        }
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

private actor SnapshotDocumentRepository: DocumentRepository {
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
