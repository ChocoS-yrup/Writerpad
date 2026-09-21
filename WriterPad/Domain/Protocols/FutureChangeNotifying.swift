import Foundation

/// Windows v2 확정 전 표현할 수 있는 최소 연결 상태다.
enum FutureSyncMode: String, Codable, Equatable, Sendable {
    case unconfigured
    case localOnly
    case futureConnection
}

/// 서버 payload나 revision을 확정하지 않는 의미 중심의 로컬 사건이다.
enum LocalChangeEvent: Equatable, Sendable {
    case appLaunched
    case documentSaved(
        projectID: ProjectID,
        documentID: DocumentID,
        contentHash: ContentHash
    )
    /// 서버 계약은 정하지 않고 로컬에서 완료된 일괄 생성의 의미만 전달한다.
    case manuscriptVolumeCreated(
        projectID: ProjectID,
        volumeID: DocumentID,
        chapterIDs: [DocumentID]
    )
    case documentRestored(
        projectID: ProjectID,
        documentID: DocumentID,
        contentHash: ContentHash
    )
    case documentTrashed(projectID: ProjectID, documentID: DocumentID)
    case documentRestoredFromTrash(projectID: ProjectID, documentID: DocumentID)
    case documentPermanentlyDeleted(projectID: ProjectID, documentID: DocumentID)
}

/// 향후 동기화 구현을 로컬 성공 여부와 분리하는 최소 경계다.
protocol FutureChangeNotifying: Sendable {
    var mode: FutureSyncMode { get }
    func record(_ event: LocalChangeEvent) async
}

/// 저널의 날짜 인코딩 정밀도나 화면 상태가 재시도 원본을 바꾸지 않도록
/// 구조 동기화에 필요한 값만 명령 시점에 고정한다.
struct LocalStructureSnapshotNode: Codable, Equatable, Sendable {
    let id: DocumentID
    let projectID: ProjectID
    let kind: DocumentKind
    let parentID: DocumentID?
    let relativePath: RelativeDocumentPath
    let userOrder: Int
    let isIncludedInTree: Bool

    init(_ node: DocumentNode) {
        id = node.id; projectID = node.projectID; kind = node.kind
        parentID = node.parentID; relativePath = node.relativePath; userOrder = node.userOrder
        let path = node.relativePath.rawValue.precomposedStringWithCanonicalMapping
        let trash = BinderFixedCategory.trash.relativePath.rawValue.precomposedStringWithCanonicalMapping
        if case .active = node.deletionStatus {
            isIncludedInTree = path != trash && !path.hasPrefix(trash + "/")
        } else { isIncludedInTree = false }
    }
}

/// 로컬 저장 성공 뒤 Sync v2 SQLite로 넘기는 불변 handoff다.
/// 서버 전송과는 분리되며, 동일 batch/operation ID로 안전하게 재기록할 수 있다.
struct LocalMutationBatch: Codable, Equatable, Sendable {
    let batchID: UUID
    let projectID: ProjectID
    let localTransactionID: UUID?
    let kind: DurableLocalBatchKind
    let mutations: [DurableLocalMutation]
    /// 이름 기반 순서를 UUID 계약으로 바꿀 때 명령 당시의 구조만 사용한다.
    let structureSnapshot: [LocalStructureSnapshotNode]?
    var contractStep: SyncV2GeneralContractStep? = nil
    var originBatchID: UUID? = nil

    init(
        batchID: UUID,
        projectID: ProjectID,
        localTransactionID: UUID?,
        kind: DurableLocalBatchKind = .documentSave,
        mutations: [DurableLocalMutation],
        structureSnapshot: [DocumentNode]? = nil
    ) {
        self.batchID = batchID
        self.projectID = projectID
        self.localTransactionID = localTransactionID
        self.kind = kind
        self.mutations = mutations
        self.structureSnapshot = structureSnapshot?.map(LocalStructureSnapshotNode.init)
    }

    /// 충돌 재선택은 당시 구조를 현재 메타데이터로 다시 만들지 않고 그대로 잇는다.
    init(replacing source: LocalMutationBatch, batchID: UUID, mutations: [DurableLocalMutation]) {
        self.batchID = batchID
        self.projectID = source.projectID
        self.localTransactionID = nil
        self.kind = source.kind
        self.mutations = mutations
        self.structureSnapshot = source.structureSnapshot
        self.contractStep = source.contractStep; self.originBatchID = source.originBatchID
    }

    private enum CodingKeys: String, CodingKey {
        case batchID
        case projectID
        case localTransactionID
        case kind
        case mutations
        case structureSnapshot, contractStep, originBatchID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batchID = try container.decode(UUID.self, forKey: .batchID)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        localTransactionID = try container.decodeIfPresent(
            UUID.self,
            forKey: .localTransactionID
        )
        kind = try container.decodeIfPresent(
            DurableLocalBatchKind.self,
            forKey: .kind
        ) ?? .documentSave
        structureSnapshot = try container.decodeIfPresent([LocalStructureSnapshotNode].self, forKey: .structureSnapshot)
        contractStep = try container.decodeIfPresent(SyncV2GeneralContractStep.self, forKey: .contractStep)
        originBatchID = try container.decodeIfPresent(UUID.self, forKey: .originBatchID)
        mutations = try container.decode(
            [DurableLocalMutation].self,
            forKey: .mutations
        )
    }
}

enum DurableLocalBatchKind: String, Codable, Equatable, Sendable {
    case projectBinding
    case documentSave
    case structureChange
    case volumeCreation
    case trashChange
    case backupRestore
    case windowsImport
}

enum DurableLocalMutation: Codable, Equatable, Sendable {
    case ensureProject(operationID: UUID, name: String)
    case documentSnapshot(
        operationID: UUID,
        documentID: DocumentID,
        relativePath: RelativeDocumentPath,
        content: String,
        contentHash: ContentHash,
        localSaveGeneration: UInt64,
        isDeleted: Bool
    )
    case treeOrder(
        operationID: UUID,
        content: String,
        generation: UInt64
    )
    case trashPurge(
        operationID: UUID,
        content: String,
        generation: UUID
    )
    /// 폴더 자체를 서버에 알린다. 문서와 달리 본문도 경로도 없고, 위치는
    /// parentFolderID 사슬로만 나타낸다. 최상위 폴더는 nil이다.
    case folderSnapshot(
        operationID: UUID,
        folderID: DocumentID,
        parentFolderID: DocumentID?,
        name: String,
        isDeleted: Bool
    )
}

enum DurableRecordResult: Equatable, Sendable {
    case queued(operationIDs: [UUID])
    /// 서버 기준 snapshot과 동일해서 새 operation이 필요하지 않다.
    case notNeeded
    /// 로컬 TXT와 백업은 성공했지만 서버 본문 제한 때문에 전송할 수 없다.
    case serverSizeLimitExceeded(byteCount: Int, limit: Int)
    case localOnly
    case localSavedButNotQueued(reason: String)
}

enum DurableRecordingRequirement: Equatable, Sendable {
    case localOnly
    case durableQueue
}

protocol DurableLocalChangeRecording: Sendable {
    func requirement(for projectID: ProjectID) async -> DurableRecordingRequirement
    func hasRecordedInitialSnapshot(
        for projectID: ProjectID,
        kind: DurableLocalBatchKind
    ) async throws -> Bool
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult
    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) async -> DurableRecordResult?
}

extension DurableLocalChangeRecording {
    func requirement(for projectID: ProjectID) async -> DurableRecordingRequirement {
        .durableQueue
    }

    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) async -> DurableRecordResult? {
        nil
    }
}
