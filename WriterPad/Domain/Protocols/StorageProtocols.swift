import Foundation

/// 작품 메타데이터 저장 구현이 따라야 하는 경계다.
protocol ProjectRepository: Sendable {
    func projects() async throws -> [Project]
    func project(id: ProjectID) async throws -> Project?
    func save(_ project: Project) async throws
    func remove(id: ProjectID) async throws
}

/// 새 작품과 생성 시점의 고정 바인더 UUID를 한 번의 로컬 메타데이터 저장으로 확정한다.
protocol ProjectCreationMetadataStoring: Sendable {
    func saveProjectCreation(
        _ project: Project,
        standardNodes: [DocumentNode]
    ) async throws
}

/// 바인더 문서 메타데이터 저장 구현이 따라야 하는 경계다.
protocol DocumentRepository: Sendable {
    func documents(in projectID: ProjectID) async throws -> [DocumentNode]
    func document(id: DocumentID) async throws -> DocumentNode?
    func save(_ document: DocumentNode) async throws
    func removeMetadata(id: DocumentID) async throws
}

/// 마지막 작품과 작품별 화면 상태를 복원하는 메타데이터 경계다.
protocol WorkspaceStateRepository: Sendable {
    func lastProjectID() async throws -> ProjectID?
    func setLastProjectID(_ projectID: ProjectID?) async throws
    func editorState(for projectID: ProjectID) async throws -> EditorWorkspaceState
    func saveEditorState(_ state: EditorWorkspaceState) async throws
    func binderWidth(for projectID: ProjectID) async throws -> Double
    func setBinderWidth(_ width: Double, for projectID: ProjectID) async throws
    func expandedFolderIDs(in projectID: ProjectID) async throws -> Set<DocumentID>
    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) async throws
    func cursor(for documentID: DocumentID) async throws -> TextCursorState
    func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) async throws
}

/// UTF-8 TXT 본문의 읽기와 원자적 저장을 담당할 경계다.
protocol LocalDocumentStoring: Sendable {
    func loadText(for document: DocumentNode) async throws -> String
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt
    func retryPendingSyncHandoff(
        for document: DocumentNode
    ) async -> DurableRecordResult
}

extension LocalDocumentStoring {
    func retryPendingSyncHandoff(
        for document: DocumentNode
    ) async -> DurableRecordResult {
        .localOnly
    }
}

/// 작품 ID를 실제 집필모드 루트로 바꾸는 경계다.
protocol ProjectWorkspaceLocating: Sendable {
    func workspaceRoot(for projectID: ProjectID) async throws -> URL
}

/// TXT 교체 후 문서 해시와 수정 시각만 반영하는 경계다.
protocol DocumentFileMetadataUpdating: Sendable {
    /// 파일 교체 직전에 같은 UUID의 문서가 여전히 활성 상태이며 같은 경로를
    /// 가리키는지 확인한다. 휴지통 이동과 경쟁한 늦은 저장을 차단한다.
    func validateBeforeFileSave(_ request: DocumentSaveRequest) async throws
    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws
}

extension DocumentFileMetadataUpdating {
    func validateBeforeFileSave(_ request: DocumentSaveRequest) async throws {
        _ = request
    }
}

/// 백업 생성·조회·복원을 담당할 경계다.
protocol BackupStoring: Sendable {
    func snapshots(
        for documentID: DocumentID,
        projectID: ProjectID
    ) async throws -> [BackupSnapshot]
    func createSnapshot(for document: DocumentNode, reason: BackupReason) async throws -> BackupSnapshot
    func createSnapshot(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent
    ) async throws -> BackupSnapshot
    func createSnapshotAndApplyRetention(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent,
        policy: BackupPolicy
    ) async throws -> BackupMaintenanceResult
    func text(for snapshot: BackupSnapshot) async throws -> String
    func setPinned(_ isPinned: Bool, snapshot: BackupSnapshot) async throws -> BackupSnapshot
    func delete(_ snapshot: BackupSnapshot) async throws
    func applyRetentionPolicy(
        _ policy: BackupPolicy,
        projectID: ProjectID
    ) async throws -> BackupCleanupReport
}

extension BackupStoring {
    /// 저장 결과 재사용을 지원하지 않는 테스트 대역·구현은 기존 파일 기반 경로를 사용한다.
    func createSnapshot(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent
    ) async throws -> BackupSnapshot {
        try await createSnapshot(for: document, reason: reason)
    }

    /// 결합 작업을 지원하지 않는 구현은 기존 두 작업을 순서대로 수행한다.
    func createSnapshotAndApplyRetention(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent,
        policy: BackupPolicy
    ) async throws -> BackupMaintenanceResult {
        let snapshot = try await createSnapshot(
            for: document,
            reason: reason,
            savedContent: savedContent
        )
        let cleanup = try await applyRetentionPolicy(policy, projectID: document.projectID)
        return BackupMaintenanceResult(snapshot: snapshot, cleanup: cleanup)
    }
}

protocol BackupPolicyStoring: Sendable {
    func policy(for projectID: ProjectID) async throws -> BackupPolicy
    func save(_ policy: BackupPolicy, for projectID: ProjectID) async throws
}

/// 프로젝트 전체 TXT 검색 구현이 따라야 하는 경계다.
protocol Searching: Sendable {
    func search(
        _ request: DocumentSearchRequest,
        progress: @escaping @Sendable (DocumentSearchProgress) -> Void
    ) async throws -> ProjectSearchReport
}

extension Searching {
    func search(_ request: DocumentSearchRequest) async throws -> ProjectSearchReport {
        try await search(request, progress: { _ in })
    }
}

/// TXT 추출 구현이 따라야 하는 경계다.
protocol Exporting: Sendable {
    func export(_ request: ExportRequest) async throws -> ExportReport
}
