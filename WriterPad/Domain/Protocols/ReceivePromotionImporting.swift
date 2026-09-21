import Foundation

/// Read-only boundary for inspecting a user-selected Receive Boundary package.
protocol ReceivePromotionPackageInspecting: Sendable {
    func inspect(_ packageURL: URL) async throws -> ReceivePromotionReport
}

/// Transaction-only boundary that returns validated bytes after a fresh read.
protocol ReceivePromotionPackageMaterializing: ReceivePromotionPackageInspecting {
    func materialize(
        _ packageURL: URL
    ) async throws -> ReceivePromotionValidatedPackage
}

/// One local metadata store is required so registration and exact rollback use
/// the same project/document database.
protocol ReceivePromotionMetadataStoring:
    ProjectRepository,
    DocumentRepository,
    ProjectImportMetadataRegistering {}

/// Publishes an already durable local project into WriterPad's local catalog.
protocol ReceivePromotionProjectPublishing: Sendable {
    func publishPromotedProject(_ project: Project) async throws -> ManagedProject
}

/// WriterPad-owned transaction boundary. Implementations must re-inspect the
/// package and match its fingerprint before writing any staging or metadata.
protocol ReceivePromotionTransacting: Sendable {
    func promote(
        from report: ReceivePromotionReport,
        projectName: String
    ) async throws -> ReceivePromotionResult

    func recoverPendingPromotions() async throws
}
