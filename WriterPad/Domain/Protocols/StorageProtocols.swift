/// 작품 메타데이터 저장 구현이 따라야 하는 경계다.
protocol ProjectRepository: Sendable {
    func projects() async throws -> [Project]
    func project(id: ProjectID) async throws -> Project?
    func save(_ project: Project) async throws
    func remove(id: ProjectID) async throws
}

/// 바인더 문서 메타데이터 저장 구현이 따라야 하는 경계다.
protocol DocumentRepository: Sendable {
    func documents(in projectID: ProjectID) async throws -> [DocumentNode]
    func document(id: DocumentID) async throws -> DocumentNode?
    func save(_ document: DocumentNode) async throws
    func removeMetadata(id: DocumentID) async throws
}

/// UTF-8 TXT 본문의 읽기와 원자적 저장을 담당할 경계다.
protocol LocalDocumentStoring: Sendable {
    func loadText(for document: DocumentNode) async throws -> String
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt
}

/// 백업 생성·조회·복원을 담당할 경계다.
protocol BackupStoring: Sendable {
    func snapshots(for documentID: DocumentID) async throws -> [BackupSnapshot]
    func createSnapshot(for document: DocumentNode, reason: BackupReason) async throws -> BackupSnapshot
    func restore(_ snapshot: BackupSnapshot) async throws -> DocumentSaveReceipt
}

/// 프로젝트 전체 TXT 검색 구현이 따라야 하는 경계다.
protocol Searching: Sendable {
    func search(_ request: DocumentSearchRequest) async throws -> [DocumentSearchHit]
}

/// TXT 추출 구현이 따라야 하는 경계다.
protocol Exporting: Sendable {
    func export(_ request: ExportRequest) async throws -> ExportReport
}
