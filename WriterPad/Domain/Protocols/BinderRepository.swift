import Foundation

protocol BinderRepository: Sendable {
    func rootNodes(in projectID: ProjectID) async throws -> [BinderNode]
    func children(
        of folderID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderNode]
    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) async throws
}

protocol BinderMetadataStoring: Sendable {
    func binderDocuments(in projectID: ProjectID) async throws -> [DocumentNode]
    func binderDocument(id: DocumentID) async throws -> DocumentNode?
    func binderDocument(
        in projectID: ProjectID,
        at relativePath: RelativeDocumentPath
    ) async throws -> DocumentNode?
    func binderChildren(
        in projectID: ProjectID,
        parentID: DocumentID
    ) async throws -> [DocumentNode]
    func reconcileBinderMetadata(
        in projectID: ProjectID,
        upserting documents: [DocumentNode],
        removingSubtrees rootedAt: [DocumentID]
    ) async throws
}

protocol BinderCommanding: Sendable {
    func recoverPendingTransactions(in projectID: ProjectID) async throws
    func commandDescriptors(
        for documentID: DocumentID,
        in projectID: ProjectID
    ) async throws -> [BinderCommandDescriptor]
    func create(
        kind: DocumentKind,
        named displayName: String,
        in parentID: DocumentID,
        projectID: ProjectID
    ) async throws -> BinderCommandResult
    func rename(
        documentID: DocumentID,
        to displayName: String,
        projectID: ProjectID
    ) async throws -> BinderCommandResult
    func move(
        documentID: DocumentID,
        to target: BinderDropTarget,
        projectID: ProjectID
    ) async throws -> BinderCommandResult
    func reorder(
        childIDs: [DocumentID],
        in parentID: DocumentID,
        projectID: ProjectID
    ) async throws
    func moveToTrash(
        documentID: DocumentID,
        projectID: ProjectID
    ) async throws -> BinderCommandResult
}

protocol BinderDirectoryScanning: Sendable {
    func children(
        in workspaceRootURL: URL,
        parentPath: RelativeDocumentPath
    ) async throws -> [BinderDiskEntry]
}
