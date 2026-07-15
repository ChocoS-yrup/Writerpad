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

protocol BinderDirectoryScanning: Sendable {
    func children(
        in workspaceRootURL: URL,
        parentPath: RelativeDocumentPath
    ) async throws -> [BinderDiskEntry]
}
