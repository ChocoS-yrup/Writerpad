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

/// 로컬 저장 성공 뒤 Sync v2 SQLite로 넘기는 불변 handoff다.
/// 서버 전송과는 분리되며, 동일 batch/operation ID로 안전하게 재기록할 수 있다.
struct LocalMutationBatch: Codable, Equatable, Sendable {
    let batchID: UUID
    let projectID: ProjectID
    let localTransactionID: UUID?
    let kind: DurableLocalBatchKind
    let mutations: [DurableLocalMutation]

    init(
        batchID: UUID,
        projectID: ProjectID,
        localTransactionID: UUID?,
        kind: DurableLocalBatchKind = .documentSave,
        mutations: [DurableLocalMutation]
    ) {
        self.batchID = batchID
        self.projectID = projectID
        self.localTransactionID = localTransactionID
        self.kind = kind
        self.mutations = mutations
    }

    private enum CodingKeys: String, CodingKey {
        case batchID
        case projectID
        case localTransactionID
        case kind
        case mutations
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
