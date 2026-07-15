import Foundation

protocol ProjectImporting: Sendable {
    func inspect(_ sourceURL: URL) async throws -> ImportReport
    func importProject(
        from report: ImportReport,
        confirmsWarnings: Bool
    ) async throws -> ProjectImportResult
    func recoverPendingImports() async throws
}

/// 가져온 작품과 전체 문서 색인을 하나의 SwiftData 거래로 등록한다.
protocol ProjectImportMetadataRegistering: Sendable {
    func registerImportedProject(
        _ project: Project,
        documents: [DocumentNode]
    ) async throws
}
