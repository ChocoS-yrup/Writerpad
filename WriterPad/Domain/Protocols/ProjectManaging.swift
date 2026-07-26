import Foundation

protocol ProjectManaging: Sendable {
    func projects() async throws -> [ManagedProject]
    func createProject(named name: String) async throws -> ManagedProject
    func restoreLastProject() async throws -> ManagedProject?
    func selectProject(id: ProjectID) async throws
    func renameProject(id: ProjectID, to newName: String) async throws -> ManagedProject
    func reorderProjects(_ orderedIDs: [ProjectID]) async throws -> [ManagedProject]
    func prepareDeletion(id: ProjectID) async throws -> ProjectDeletionConfirmation
    func confirmDeletion(_ confirmation: ProjectDeletionConfirmation) async throws
    func cancelDeletion(id: ProjectID) async throws
    func prepareMoveToDeletedList(
        id: ProjectID
    ) async throws -> ProjectDeletedListConfirmation
    @discardableResult
    func moveToDeletedList(
        _ confirmation: ProjectDeletedListConfirmation
    ) async throws -> ManagedProject?
    func restoreFromDeletedList(id: ProjectID) async throws
    func preparePermanentDeletion(
        id: ProjectID
    ) async throws -> ProjectPermanentDeletionConfirmation
    @discardableResult
    func permanentlyDelete(
        _ confirmation: ProjectPermanentDeletionConfirmation
    ) async throws -> ManagedProject?
    func exportDescriptor(id: ProjectID) async throws -> ProjectExportDescriptor
    func recoverPendingTransactions() async throws
}
