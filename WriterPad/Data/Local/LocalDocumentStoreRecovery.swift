import Foundation

struct LocalDocumentRecoveryIssue: Equatable, Sendable {
    let path: String
    let reason: String
}

struct LocalDocumentRecoveryReport: Equatable, Sendable {
    var removedTemporaryFiles: [String] = []
    var retainedTemporaryFiles: [String] = []
    var reconciledDocumentIDs: [DocumentID] = []
    var retainedMarkers: [String] = []
    var issues: [LocalDocumentRecoveryIssue] = []
}

extension LocalDocumentStore {
    /// 재실행 시 오래된 임시 파일을 정리하고, 저장된 TXT와 메타데이터를 다시 맞춘다.
    func recoverWorkspace(for projectID: ProjectID) async throws -> LocalDocumentRecoveryReport {
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: projectID)
        var report = LocalDocumentRecoveryReport()
        var markerURLs: [URL] = []
        for url in workspaceEntries(at: workspaceRoot) {
            let name = url.lastPathComponent
            if name.hasPrefix(Self.temporaryPrefix), name.hasSuffix(Self.temporarySuffix) {
                cleanTemporaryFile(url, report: &report)
            } else if name.hasPrefix(Self.reconciliationPrefix),
                      name.hasSuffix(Self.reconciliationSuffix) {
                markerURLs.append(url)
            }
        }

        for markerURL in markerURLs {
            await reconcile(markerURL, projectID: projectID, workspaceRoot: workspaceRoot, report: &report)
        }
        return report
    }

    private func workspaceEntries(at root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return []
        }
        var urls: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            urls.append(url)
        }
        return urls
    }

    private func cleanTemporaryFile(
        _ url: URL,
        report: inout LocalDocumentRecoveryReport
    ) {
        let modificationDate = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
        guard clock.now().timeIntervalSince(modificationDate) >= staleTemporaryFileAge else {
            report.retainedTemporaryFiles.append(url.path)
            return
        }
        do {
            try fileManager.removeItem(at: url)
            report.removedTemporaryFiles.append(url.path)
        } catch {
            report.issues.append(.init(path: url.path, reason: error.localizedDescription))
        }
    }

    private func reconcile(
        _ markerURL: URL,
        projectID: ProjectID,
        workspaceRoot: URL,
        report: inout LocalDocumentRecoveryReport
    ) async {
        do {
            let data = try Data(contentsOf: markerURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let receipt = try decoder.decode(DocumentSaveReceipt.self, from: data)
            guard receipt.projectID == projectID else {
                throw RecoveryValidationError.wrongProject
            }
            let targetURL = try validatedTextURL(
                receipt.relativePath,
                workspaceRoot: workspaceRoot
            )
            let targetData = try Data(contentsOf: targetURL)
            guard hasher.sha256(for: targetData) == receipt.contentHash else {
                throw RecoveryValidationError.hashMismatch
            }
            try await metadataUpdater.updateAfterFileSave(receipt)
            try fileManager.removeItem(at: markerURL)
            report.reconciledDocumentIDs.append(receipt.documentID)
        } catch {
            report.retainedMarkers.append(markerURL.path)
            report.issues.append(.init(path: markerURL.path, reason: String(describing: error)))
        }
    }
}

private enum RecoveryValidationError: Error {
    case wrongProject
    case hashMismatch
}
