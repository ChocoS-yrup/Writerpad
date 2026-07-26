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
