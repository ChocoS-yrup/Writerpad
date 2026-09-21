import Foundation
import SwiftData
import XCTest
@testable import WriterPad

/// 정상 상태 pull이 문서마다 작품 전체 목록을 읽지 않는지, 그리고 전체 목록이
/// 실제로 필요한 경로의 판정은 그대로인지 함께 고정한다.
final class SyncV2LocalSnapshotApplyLookupTests: XCTestCase {
    // MARK: - 정상 상태 저장소 호출 횟수

    func testSteadyStatePullDoesNotReadWholeProjectPerDocument()
        async throws {
        let documentCount = 40
        let workspace = try await Workspace.make(
            documentCount: documentCount
        )
        addTeardownBlock { workspace.remove() }

        await workspace.repositorySpy.resetCounts()
        let report = try await workspace.makePullService().pull(
            localProjectID: workspace.projectID,
            serverProjectID: workspace.serverProjectID
        )

        let counts = await workspace.repositorySpy.counts()
        XCTAssertEqual(
            counts.documentsInProject,
            0,
            "정상 상태에서는 작품 전체 목록을 읽지 않아야 한다."
        )
        XCTAssertEqual(
            counts.documentByID,
            documentCount * 2,
            "문서마다 단건 조회 두 번(동일성 확인, 복구 필요 확인)이다."
        )
        XCTAssertEqual(
            report.outcomes.count,
            documentCount
        )
        XCTAssertTrue(
            report.outcomes.allSatisfy {
                if case .upToDate = $0 { return true }
                return false
            },
            "변경이 없으므로 전부 upToDate여야 한다."
        )
        XCTAssertTrue(report.appliedSnapshots.isEmpty)
    }

    // MARK: - 전체 목록이 필요한 경로

    func testEquivalentIdentityStillFoundWhenRemoteUUIDIsAbsent()
        async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        let local = workspace.documentIDs[0]
        let remoteID = UUID()
        let snapshot = workspace.snapshot(
            documentID: remoteID,
            path: workspace.relativePath(at: 0),
            content: Workspace.body
        )

        await workspace.repositorySpy.resetCounts()
        let found = await workspace.applier.equivalentLocalDocumentID(
            localProjectID: workspace.projectID,
            snapshot: snapshot
        )

        XCTAssertEqual(
            found,
            local.rawValue,
            "UUID가 다르고 경로·본문이 같으면 기존 문서를 후보로 찾아야 한다."
        )
        let counts = await workspace.repositorySpy.counts()
        XCTAssertEqual(
            counts.documentsInProject,
            1,
            "UUID가 없을 때만 경로 후보를 위해 전체 목록을 읽는다."
        )
    }

    func testEquivalentIdentityRejectsDifferentContent() async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        let snapshot = workspace.snapshot(
            documentID: UUID(),
            path: workspace.relativePath(at: 0),
            content: Workspace.body + "다른 본문"
        )

        let found = await workspace.applier.equivalentLocalDocumentID(
            localProjectID: workspace.projectID,
            snapshot: snapshot
        )
        XCTAssertNil(
            found,
            "본문이 다르면 같은 문서로 채택하지 않는다."
        )
    }

    func testEquivalentIdentitySkippedWhenRemoteUUIDExistsLocally()
        async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        let snapshot = workspace.snapshot(
            documentID: workspace.documentIDs[0].rawValue,
            path: workspace.relativePath(at: 0),
            content: Workspace.body
        )

        await workspace.repositorySpy.resetCounts()
        let found = await workspace.applier.equivalentLocalDocumentID(
            localProjectID: workspace.projectID,
            snapshot: snapshot
        )

        XCTAssertNil(found)
        let counts = await workspace.repositorySpy.counts()
        XCTAssertEqual(counts.documentsInProject, 0)
        XCTAssertEqual(counts.documentByID, 1)
    }

    // MARK: - TXT 소실 복구

    func testCopyRecoveryRequiredWhenLocalTextFileIsMissing()
        async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        try FileManager.default.removeItem(at: workspace.fileURL(at: 0))

        let snapshot = workspace.snapshot(
            documentID: workspace.documentIDs[0].rawValue,
            path: workspace.relativePath(at: 0),
            content: Workspace.body
        )
        let requiresRecovery = await workspace.applier.requiresCopyRecovery(
            localProjectID: workspace.projectID,
            snapshot: snapshot
        )
        XCTAssertTrue(
            requiresRecovery,
            "메타데이터는 살아 있는데 TXT가 없으면 복구가 필요하다."
        )
    }

    func testCopyRecoveryNotRequiredWhenLocalTextFileExists()
        async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        let snapshot = workspace.snapshot(
            documentID: workspace.documentIDs[0].rawValue,
            path: workspace.relativePath(at: 0),
            content: Workspace.body
        )
        let requiresRecovery = await workspace.applier.requiresCopyRecovery(
            localProjectID: workspace.projectID,
            snapshot: snapshot
        )
        XCTAssertFalse(requiresRecovery)
    }

    /// 단건 조회는 UUID로 저장소 전체를 찾는다. 작품 경계를 잃으면 다른 작품의
    /// 문서를 이 작품의 복구 대상으로 오인할 수 있다.
    func testCopyRecoveryIgnoresDocumentFromAnotherProject() async throws {
        let workspace = try await Workspace.make(documentCount: 1)
        addTeardownBlock { workspace.remove() }

        let snapshot = workspace.snapshot(
            documentID: workspace.documentIDs[0].rawValue,
            path: workspace.relativePath(at: 0),
            content: Workspace.body
        )
        let requiresRecovery = await workspace.applier.requiresCopyRecovery(
            localProjectID: ProjectID(rawValue: UUID()),
            snapshot: snapshot
        )
        XCTAssertFalse(
            requiresRecovery,
            "다른 작품의 문서는 이 작품의 복구 판정에 들어오면 안 된다."
        )
    }

    // MARK: - fixture

    private struct Workspace {
        static let body = "가나다라마바사"

        let root: URL
        let workspaceRoot: URL
        let projectID: ProjectID
        let serverProjectID: UUID
        let documentIDs: [DocumentID]
        let applier: LocalSyncV2SnapshotApplier
        let repositorySpy: LookupCountingDocumentRepository
        let snapshots: [SyncV2RemoteDocumentSnapshot]
        let states: [UUID: SyncV2SnapshotLocalState]

        static let revision: Int64 = 3

        func relativePath(at index: Int) -> String {
            "메인/원고/1권/" + String(format: "%04d.txt", index + 1)
        }

        func fileURL(at index: Int) -> URL {
            workspaceRoot.appendingPathComponent(relativePath(at: index))
        }

        func snapshot(
            documentID: UUID,
            path: String,
            content: String
        ) -> SyncV2RemoteDocumentSnapshot {
            SyncV2RemoteDocumentSnapshot(
                documentID: documentID,
                relativePath: path,
                content: content,
                revision: Self.revision,
                isDeleted: false,
                deletedAt: nil,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }

        func makePullService() -> SyncV2SnapshotPullService {
            SyncV2SnapshotPullService(
                client: LookupSnapshotClient(snapshots: snapshots),
                stateStore: LookupStateStore(states: states),
                localApplier: applier,
                mergeStore: LookupMergeStore()
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        static func make(documentCount: Int) async throws -> Workspace {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "writerpad-lookup-" + UUID().uuidString.lowercased(),
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
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try await repository.save(
                Project(
                    id: projectID,
                    name: "단건 조회 회귀",
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
            let contentHash = SHA256ContentHasher().sha256(for: data)
            var documentIDs: [DocumentID] = []
            var snapshots: [SyncV2RemoteDocumentSnapshot] = []
            var states: [UUID: SyncV2SnapshotLocalState] = [:]

            for index in 0..<documentCount {
                let documentID = DocumentID(rawValue: UUID())
                let name = String(format: "%04d.txt", index + 1)
                let relativePath = "메인/원고/1권/" + name
                try await repository.save(
                    DocumentNode(
                        id: documentID,
                        projectID: projectID,
                        kind: .text,
                        parentID: parentID,
                        relativePath: RelativeDocumentPath(
                            rawValue: relativePath
                        ),
                        userOrder: index,
                        modifiedAt: now,
                        contentHash: contentHash
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
                        relativePath: relativePath,
                        content: body,
                        revision: revision,
                        isDeleted: false,
                        deletedAt: nil,
                        updatedAt: now
                    )
                )
                states[documentID.rawValue] = SyncV2SnapshotLocalState(
                    serverRevision: revision,
                    serverPath: relativePath,
                    hasActiveOperation: false,
                    hasUnresolvedConflict: false,
                    blockingErrorCode: nil
                )
            }

            let spy = LookupCountingDocumentRepository(base: repository)
            let locator = FixedWorkspaceLocator(root: workspaceRoot)
            let applier = LocalSyncV2SnapshotApplier(
                documentRepository: spy,
                workspaceLocator: locator,
                backupStore: LocalBackupStore(workspaceLocator: locator)
            )

            return Workspace(
                root: root,
                workspaceRoot: workspaceRoot,
                projectID: projectID,
                serverProjectID: UUID(),
                documentIDs: documentIDs,
                applier: applier,
                repositorySpy: spy,
                snapshots: snapshots,
                states: states
            )
        }
    }
}

// MARK: - 대역

private actor LookupCountingDocumentRepository:
    DocumentRepository,
    DocumentIdentityReplacing {
    struct Counts: Sendable {
        var documentsInProject = 0
        var documentByID = 0
    }

    private let base: SwiftDataMetadataRepository
    private var stored = Counts()

    init(base: SwiftDataMetadataRepository) {
        self.base = base
    }

    func counts() -> Counts { stored }

    func resetCounts() { stored = Counts() }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        stored.documentsInProject += 1
        return try await base.documents(in: projectID)
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        stored.documentByID += 1
        return try await base.document(id: id)
    }

    func save(_ document: DocumentNode) async throws {
        try await base.save(document)
    }

    func removeMetadata(id: DocumentID) async throws {
        try await base.removeMetadata(id: id)
    }

    func replaceDocumentIdentity(
        from oldID: DocumentID,
        to newID: DocumentID,
        in projectID: ProjectID
    ) async throws {
        try await base.replaceDocumentIdentity(
            from: oldID,
            to: newID,
            in: projectID
        )
    }
}

private actor LookupSnapshotClient: SyncV2SnapshotClienting {
    private let snapshots: [SyncV2RemoteDocumentSnapshot]

    init(snapshots: [SyncV2RemoteDocumentSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        return snapshots
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        _ = projectID
        return []
    }
}

private actor LookupStateStore: SyncV2SnapshotStateStoring {
    private let states: [UUID: SyncV2SnapshotLocalState]

    init(states: [UUID: SyncV2SnapshotLocalState]) {
        self.states = states
    }

    func snapshotStates(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentIDs: Set<UUID>
    ) async throws -> [UUID: SyncV2SnapshotLocalState]? {
        _ = (localProjectID, serverProjectID)
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
        _ = (localProjectID, serverProjectID, snapshot, expectedRevision)
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

private actor LookupMergeStore: SyncV2SnapshotMergeStoring {
    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        _ = candidate
    }
}
