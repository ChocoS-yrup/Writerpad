import Darwin
import Foundation

/// 같은 폴더의 고유한 임시 파일을 디스크에 반영한 뒤 rename으로 교체한다.
struct POSIXAtomicFileWriter: Sendable {
    let faultPlan: AtomicWriteFaultPlan?

    init(faultPlan: AtomicWriteFaultPlan? = nil) {
        self.faultPlan = faultPlan
    }

    func writeTemporaryFile(data: Data, at temporaryURL: URL) throws {
        try inject(.beforeTemporaryFileCreation, operation: .createTemporaryFile, url: temporaryURL)
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw mappedError(operation: .createTemporaryFile, url: temporaryURL, code: errno)
        }

        var shouldRemove = true
        var shouldClose = true
        defer {
            if shouldClose { close(descriptor) }
            if shouldRemove { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try inject(.duringWrite, operation: .write, url: temporaryURL)
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw mappedError(operation: .write, url: temporaryURL, code: errno)
                }
                guard count > 0 else {
                    throw LocalDocumentStoreError.operationFailed(
                        operation: .write,
                        path: temporaryURL.path,
                        code: EIO
                    )
                }
                offset += count
            }
        }

        try inject(.duringFlush, operation: .flush, url: temporaryURL)
        guard fsync(descriptor) == 0 else {
            throw mappedError(operation: .flush, url: temporaryURL, code: errno)
        }
        let closeResult = close(descriptor)
        shouldClose = false
        guard closeResult == 0 else {
            throw mappedError(operation: .flush, url: temporaryURL, code: errno)
        }
        shouldRemove = false
    }

    func replaceItem(at destinationURL: URL, with temporaryURL: URL) throws {
        try inject(.beforeReplacement, operation: .replace, url: destinationURL)
        guard rename(temporaryURL.path, destinationURL.path) == 0 else {
            throw mappedError(operation: .replace, url: destinationURL, code: errno)
        }
        flushDirectory(destinationURL.deletingLastPathComponent())
    }

    func injectedJournalFailure(at url: URL) throws {
        try inject(.beforeReconciliationJournal, operation: .reconciliation, url: url)
    }

    private func inject(
        _ point: AtomicWriteFaultPoint,
        operation: LocalDocumentOperation,
        url: URL
    ) throws {
        guard let faultPlan, faultPlan.point == point else { return }
        switch faultPlan.failure {
        case .accessDenied:
            throw LocalDocumentStoreError.accessDenied(operation: operation, path: url.path)
        case .storageFull:
            throw LocalDocumentStoreError.storageFull(path: url.path)
        case let .generic(code):
            throw LocalDocumentStoreError.operationFailed(
                operation: operation,
                path: url.path,
                code: code
            )
        }
    }

    private func mappedError(
        operation: LocalDocumentOperation,
        url: URL,
        code: Int32
    ) -> LocalDocumentStoreError {
        switch code {
        case EACCES, EPERM:
            .accessDenied(operation: operation, path: url.path)
        case ENOSPC, EDQUOT:
            .storageFull(path: url.path)
        default:
            .operationFailed(operation: operation, path: url.path, code: code)
        }
    }

    private func flushDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
    }
}
