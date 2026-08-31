import Foundation
import SwiftData
import XCTest
@testable import WriterPad

/// 본문을 언제 받고 언제 생략하는지 고정한다.
///
/// 생략은 성능 최적화지만 잘못 생략하면 자료를 잃는다. 그래서 "받지 않는다"는
/// 쪽뿐 아니라 "반드시 받아야 한다"는 여섯 경로를 모두 고정한다.
final class SyncV2SnapshotHydrationTests: XCTestCase {
    // MARK: - 생략

    func testUnchangedDocumentsFetchNoContent() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 12)
        addTeardownBlock { workspace.remove() }

        let report = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertTrue(
            requested.isEmpty,
            "변경 없는 pull은 본문을 하나도 받지 않아야 한다."
        )
        XCTAssertEqual(report.outcomes.count, 12)
        XCTAssertTrue(report.outcomes.allSatisfy {
            if case .upToDate = $0 { return true }
            return false
        })
    }

    func testOnlyAdvancedDocumentIsHydrated() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 12)
        addTeardownBlock { workspace.remove() }

        let target = workspace.documentIDs[4].rawValue
        await workspace.client.advanceRevision(
            documentID: target,
            content: "새 본문"
        )

        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertEqual(
            requested,
            [target],
            "세대가 앞선 문서 하나만 본문을 받아야 한다."
        )
    }

    // MARK: - 반드시 받아야 하는 경로

    func testMissingLocalTextFileForcesHydration() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 6)
        addTeardownBlock { workspace.remove() }

        try FileManager.default.removeItem(at: workspace.fileURL(at: 2))
        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertEqual(
            requested,
            [workspace.documentIDs[2].rawValue],
            "TXT가 사라진 문서는 같은 revision이어도 본문이 필요하다."
        )
    }

    func testAbsentLocalUUIDForcesHydration() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 4)
        addTeardownBlock { workspace.remove() }

        // 서버에만 있는 UUID. 같은 경로의 다른 UUID를 채택할지 따지려면
        // 본문 바이트 비교가 필요하다.
        let strangerID = UUID()
        await workspace.client.addDocument(
            documentID: strangerID,
            path: workspace.relativePath(at: 0),
            content: HydrationWorkspace.body,
            revision: 3
        )
        await workspace.setState(
            documentID: strangerID,
            path: workspace.relativePath(at: 0),
            revision: 3
        )

        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertTrue(
            requested.contains(strangerID),
            "로컬에 없는 UUID는 동일성 판정을 위해 본문이 필요하다."
        )
    }

    func testTrashPurgeIsAlwaysHydrated() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 3)
        addTeardownBlock { workspace.remove() }

        let purgeID = syncV2UUIDv5(
            namespace: workspace.serverProjectID,
            name: syncV2TrashPurgePath
        )
        await workspace.client.addDocument(
            documentID: purgeID,
            path: syncV2TrashPurgePath,
            content: "{}",
            revision: 3
        )
        await workspace.setState(
            documentID: purgeID,
            path: syncV2TrashPurgePath,
            revision: 3
        )

        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertTrue(
            requested.contains(purgeID),
            "휴지통 비움은 같은 revision이어도 멱등 병합이 필요하다."
        )
    }

    func testHiddenDocumentContractViolationIsHydrated() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 3)
        addTeardownBlock { workspace.remove() }

        // 계약 UUID가 아닌 tree-order. 원격 본문을 보존 대상으로 남겨야 한다.
        let wrongID = UUID()
        await workspace.client.addDocument(
            documentID: wrongID,
            path: syncV2TreeOrderPath,
            content: "[]",
            revision: 3
        )
        await workspace.setState(
            documentID: wrongID,
            path: syncV2TreeOrderPath,
            revision: 3
        )

        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertTrue(
            requested.contains(wrongID),
            "계약을 어긴 숨은 문서는 본문을 보존해야 한다."
        )
    }

    func testMissingLocalBaselineIsHydrated() async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 5)
        addTeardownBlock { workspace.remove() }

        await workspace.removeState(
            documentID: workspace.documentIDs[1].rawValue
        )
        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertTrue(
            requested.contains(workspace.documentIDs[1].rawValue),
            "로컬 기준선이 없으면 본문을 받아 기존 경로로 가야 한다."
        )
    }

    /// batch 상태 조회가 실패한 pull은 생략 판단의 근거가 없다.
    func testFailedStateBatchHydratesEverything() async throws {
        let workspace = try await HydrationWorkspace.make(
            documentCount: 7,
            batchStateLookupFails: true
        )
        addTeardownBlock { workspace.remove() }

        _ = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertEqual(
            Set(requested),
            Set(workspace.documentIDs.map(\.rawValue)),
            "판정 근거가 없으면 예전처럼 전부 받아야 한다."
        )
    }

    // MARK: - 표와 본문 사이의 서버 변경

    func testRowAdvancedBetweenManifestAndContentUsesNewerSnapshot()
        async throws {
        let workspace = try await HydrationWorkspace.make(documentCount: 4)
        addTeardownBlock { workspace.remove() }

        let target = workspace.documentIDs[1].rawValue
        // 표를 받을 때는 4였고, 본문을 받을 때는 이미 5가 되어 있었다.
        await workspace.client.advanceRevision(
            documentID: target,
            content: "표 시점 본문"
        )
        await workspace.client.advanceRevision(
            documentID: target,
            content: "표를 받은 뒤 서버가 앞섰다"
        )
        await workspace.client.freezeManifestRevision(
            documentID: target,
            revision: 4
        )

        let report = try await workspace.pull()

        let requested = await workspace.client.requestedContentIDs()
        XCTAssertEqual(
            requested,
            [target],
            "표가 앞섰으므로 이 문서만 본문을 받아야 한다."
        )
        let applied = report.appliedSnapshots.first {
            $0.documentID == target
        }
        XCTAssertEqual(
            applied?.revision,
            5,
            "본문 쪽이 더 최신이면 그것을 정본으로 삼아야 한다."
        )
        XCTAssertEqual(applied?.content, "표를 받은 뒤 서버가 앞섰다")
    }

    // MARK: - 검증 계층

    func testMissingRequestedContentIsRejected() async throws {
        let transport = PartialContentTransport(mode: .dropOne)
        let client = SyncV2SnapshotClient(transport: transport)
        do {
            _ = try await client.fetchDocumentContents(
                projectID: UUID(),
                documentIDs: transport.allIDs
            )
            XCTFail("요청한 UUID가 빠지면 실패해야 한다.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testDuplicateContentRowIsRejected() async throws {
        let transport = PartialContentTransport(mode: .duplicate)
        let client = SyncV2SnapshotClient(transport: transport)
        do {
            _ = try await client.fetchDocumentContents(
                projectID: UUID(),
                documentIDs: transport.allIDs
            )
            XCTFail("같은 UUID가 두 번 오면 실패해야 한다.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testUnrequestedContentRowIsRejected() async throws {
        let transport = PartialContentTransport(mode: .stranger)
        let client = SyncV2SnapshotClient(transport: transport)
        do {
            _ = try await client.fetchDocumentContents(
                projectID: UUID(),
                documentIDs: transport.allIDs
            )
            XCTFail("요청하지 않은 문서가 오면 실패해야 한다.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }
}

// MARK: - fixture

private struct HydrationWorkspace {
    static let body = "가나다라마바사아자차"
    static let baseRevision: Int64 = 3

    let root: URL
    let workspaceRoot: URL
    let projectID: ProjectID
    let serverProjectID: UUID
    let documentIDs: [DocumentID]
    let client: HydrationRecordingClient
    let stateStore: MutableSnapshotStateStore
    private let service: SyncV2SnapshotPullService

    func relativePath(at index: Int) -> String {
        "메인/원고/1권/" + String(format: "%04d.txt", index + 1)
    }

    func fileURL(at index: Int) -> URL {
        workspaceRoot.appendingPathComponent(relativePath(at: index))
    }

    func pull() async throws -> SyncV2SnapshotPullReport {
        try await service.pull(
            localProjectID: projectID,
            serverProjectID: serverProjectID
        )
    }

    func setState(
        documentID: UUID,
        path: String,
        revision: Int64
    ) async {
        await stateStore.set(
            documentID: documentID,
            state: SyncV2SnapshotLocalState(
                serverRevision: revision,
                serverPath: path,
                hasActiveOperation: false,
                hasUnresolvedConflict: false,
                blockingErrorCode: nil
            )
        )
    }

    func removeState(documentID: UUID) async {
        await stateStore.remove(documentID: documentID)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func make(
        documentCount: Int,
        batchStateLookupFails: Bool = false
    ) async throws -> HydrationWorkspace {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "writerpad-hydration-" + UUID().uuidString.lowercased(),
                isDirectory: true
            )
        let workspaceRoot = root
            .appendingPathComponent("작품", isDirectory: true)
        let volumeRoot = workspaceRoot
            .appendingPathComponent("메인", isDirectory: true)
            .appendingPathComponent("원고", isDirectory: true)
            .appendingPathComponent("1권", isDirectory: true)
        try fileManager.createDirectory(
            at: volumeRoot,
            withIntermediateDirectories: true
        )

        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: false,
            storeURL: root.appendingPathComponent("metadata.store")
        )
        let repository = SwiftDataMetadataRepository(
            modelContainer: container
        )
        let projectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try await repository.save(
            Project(
                id: projectID,
                name: "본문 채우기",
                createdAt: now,
                modifiedAt: now
            )
        )

        var parentID: DocumentID?
        for path in ["메인", "메인/원고", "메인/원고/1권"] {
            let folderID = DocumentID(rawValue: UUID())
            try await repository.save(
                DocumentNode(
                    id: folderID,
                    projectID: projectID,
                    kind: .folder,
                    parentID: parentID,
                    relativePath: RelativeDocumentPath(rawValue: path),
                    userOrder: 0,
                    modifiedAt: now,
                    contentHash: nil
                )
            )
            parentID = folderID
        }

        let data = Data(body.utf8)
        let hash = SHA256ContentHasher().sha256(for: data)
        var documentIDs: [DocumentID] = []
        var snapshots: [SyncV2RemoteDocumentSnapshot] = []
        var states: [UUID: SyncV2SnapshotLocalState] = [:]

        for index in 0..<documentCount {
            let documentID = DocumentID(rawValue: UUID())
            let name = String(format: "%04d.txt", index + 1)
            let path = "메인/원고/1권/" + name
            try await repository.save(
                DocumentNode(
                    id: documentID,
                    projectID: projectID,
                    kind: .text,
                    parentID: parentID,
                    relativePath: RelativeDocumentPath(rawValue: path),
                    userOrder: index,
                    modifiedAt: now,
                    contentHash: hash
                )
            )
            try data.write(
                to: volumeRoot.appendingPathComponent(name),
                options: [.atomic]
            )
            documentIDs.append(documentID)
            snapshots.append(
                SyncV2RemoteDocumentSnapshot(
                    documentID: documentID.rawValue,
                    relativePath: path,
                    content: body,
                    revision: baseRevision,
                    isDeleted: false,
                    deletedAt: nil,
                    updatedAt: now
                )
            )
            states[documentID.rawValue] = SyncV2SnapshotLocalState(
                serverRevision: baseRevision,
                serverPath: path,
                hasActiveOperation: false,
                hasUnresolvedConflict: false,
                blockingErrorCode: nil
            )
        }

        let locator = FixedWorkspaceLocator(root: workspaceRoot)
        let applier = LocalSyncV2SnapshotApplier(
            documentRepository: repository,
            workspaceLocator: locator,
            backupStore: LocalBackupStore(workspaceLocator: locator)
        )
        let client = HydrationRecordingClient(snapshots: snapshots)
        let stateStore = MutableSnapshotStateStore(
            states: states,
            batchFails: batchStateLookupFails
        )
        let service = SyncV2SnapshotPullService(
            client: client,
            stateStore: stateStore,
            localApplier: applier,
            mergeStore: HydrationMergeStore()
        )

        return HydrationWorkspace(
            root: root,
            workspaceRoot: workspaceRoot,
            projectID: projectID,
            serverProjectID: serverProjectID,
            documentIDs: documentIDs,
            client: client,
            stateStore: stateStore,
            service: service
        )
    }
}

private actor HydrationRecordingClient: SyncV2SnapshotClienting {
    private var snapshots: [UUID: SyncV2RemoteDocumentSnapshot]
    private var frozenManifestRevisions: [UUID: Int64] = [:]
    private var requested: [UUID] = []

    init(snapshots: [SyncV2RemoteDocumentSnapshot]) {
        self.snapshots = Dictionary(
            snapshots.map { ($0.documentID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func requestedContentIDs() -> [UUID] { requested }

    func addDocument(
        documentID: UUID,
        path: String,
        content: String,
        revision: Int64
    ) {
        snapshots[documentID] = SyncV2RemoteDocumentSnapshot(
            documentID: documentID,
            relativePath: path,
            content: content,
            revision: revision,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func advanceRevision(documentID: UUID, content: String) {
        guard let existing = snapshots[documentID] else { return }
        snapshots[documentID] = SyncV2RemoteDocumentSnapshot(
            documentID: existing.documentID,
            relativePath: existing.relativePath,
            content: content,
            revision: existing.revision + 1,
            isDeleted: existing.isDeleted,
            deletedAt: existing.deletedAt,
            updatedAt: existing.updatedAt
        )
    }

    /// 표는 옛 세대로 답하게 만들어 표와 본문 사이의 서버 변경을 흉내 낸다.
    func freezeManifestRevision(documentID: UUID, revision: Int64) {
        frozenManifestRevisions[documentID] = revision
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        return Array(snapshots.values)
    }

    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        _ = projectID
        return snapshots.values.map { snapshot in
            var entry = snapshot.manifestEntry
            if let frozen = frozenManifestRevisions[snapshot.documentID] {
                entry = SyncV2RemoteDocumentManifestEntry(
                    documentID: entry.documentID,
                    relativePath: entry.relativePath,
                    revision: frozen,
                    isDeleted: entry.isDeleted,
                    deletedAt: entry.deletedAt,
                    updatedAt: entry.updatedAt
                )
            }
            return entry
        }
    }

    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        requested.append(contentsOf: documentIDs)
        return documentIDs.compactMap { snapshots[$0] }
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        _ = projectID
        return []
    }
}

private actor MutableSnapshotStateStore: SyncV2SnapshotStateStoring {
    private var states: [UUID: SyncV2SnapshotLocalState]
    private let batchFails: Bool

    init(states: [UUID: SyncV2SnapshotLocalState], batchFails: Bool) {
        self.states = states
        self.batchFails = batchFails
    }

    func set(documentID: UUID, state: SyncV2SnapshotLocalState) {
        states[documentID] = state
    }

    func remove(documentID: UUID) {
        states[documentID] = nil
    }

    func snapshotStates(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentIDs: Set<UUID>
    ) async throws -> [UUID: SyncV2SnapshotLocalState]? {
        _ = (localProjectID, serverProjectID)
        if batchFails { throw SyncV2StoreError.invalidStoredData }
        return states.filter { documentIDs.contains($0.key) }
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2SnapshotLocalState? {
        _ = (localProjectID, serverProjectID)
        return states[documentID]
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) async throws -> Bool {
        _ = (localProjectID, serverProjectID, expectedRevision)
        states[snapshot.documentID] = SyncV2SnapshotLocalState(
            serverRevision: snapshot.revision,
            serverPath: snapshot.relativePath,
            hasActiveOperation: false,
            hasUnresolvedConflict: false,
            blockingErrorCode: nil
        )
        return true
    }

    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
    ) async throws {
        _ = (localProjectID, serverProjectID, treeOrders)
    }
}

private actor HydrationMergeStore: SyncV2SnapshotMergeStoring {
    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        _ = candidate
    }
}

/// 본문 응답이 요청과 어긋나는 경우를 만든다.
private struct PartialContentTransport: SyncV2SnapshotTransporting {
    enum Mode: Sendable { case dropOne, duplicate, stranger }

    let mode: Mode
    let allIDs: [UUID] = [UUID(), UUID(), UUID()]

    private func snapshot(_ id: UUID) -> SyncV2RemoteDocumentSnapshot {
        SyncV2RemoteDocumentSnapshot(
            documentID: id,
            relativePath: "메인/원고/1권/0001.txt",
            content: "본문",
            revision: 1,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        return allIDs.map(snapshot)
    }

    func fetchDocumentManifest(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentManifestEntry] {
        _ = projectID
        return allIDs.map { snapshot($0).manifestEntry }
    }

    func fetchDocumentContents(
        projectID: UUID,
        documentIDs: [UUID]
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = (projectID, documentIDs)
        switch mode {
        case .dropOne:
            return allIDs.dropLast().map(snapshot)
        case .duplicate:
            return (allIDs + [allIDs[0]]).map(snapshot)
        case .stranger:
            return (allIDs.dropLast() + [UUID()]).map(snapshot)
        }
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        _ = projectID
        return []
    }
}
