import Foundation

/// UTF-8 TXT를 읽고, 문서별 저장 순서를 보장하며, 원자적으로 교체한다.
actor LocalDocumentStore: LocalDocumentStoring {
    static let temporaryPrefix = ".writerpad-save-"
    static let temporarySuffix = ".tmp"
    static let reconciliationPrefix = ".writerpad-reconcile-"
    static let reconciliationSuffix = ".json"

    let workspaceLocator: any ProjectWorkspaceLocating
    let metadataUpdater: any DocumentFileMetadataUpdating
    let fileManager: FileManager
    let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    let hasher: any ContentHashing
    private let writer: POSIXAtomicFileWriter
    let staleTemporaryFileAge: TimeInterval
    private var latestSubmittedGeneration: [DocumentID: UInt64] = [:]
    private var saveTails: [DocumentID: Task<DocumentSaveReceipt, Error>] = [:]

    init(
        workspaceLocator: any ProjectWorkspaceLocating,
        metadataUpdater: any DocumentFileMetadataUpdating,
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        faultPlan: AtomicWriteFaultPlan? = nil,
        staleTemporaryFileAge: TimeInterval = 60 * 60
    ) {
        self.workspaceLocator = workspaceLocator
        self.metadataUpdater = metadataUpdater
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.writer = POSIXAtomicFileWriter(faultPlan: faultPlan)
        self.staleTemporaryFileAge = staleTemporaryFileAge
    }

    func loadText(for document: DocumentNode) async throws -> String {
        guard document.kind == .text else {
            throw LocalDocumentStoreError.textFileRequired(document.relativePath.rawValue)
        }
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: document.projectID)
        let fileURL = try validatedTextURL(document.relativePath, workspaceRoot: workspaceRoot)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw mapReadError(error, url: fileURL)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw LocalDocumentStoreError.invalidUTF8(fileURL.path)
        }
        return text
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        if let latest = latestSubmittedGeneration[request.documentID],
           request.generation <= latest {
            throw LocalDocumentStoreError.staleGeneration(
                documentID: request.documentID,
                requested: request.generation,
                latest: latest
            )
        }

        latestSubmittedGeneration[request.documentID] = request.generation
        let previous = saveTails[request.documentID]
        let task = Task { [weak self] in
            if let previous { _ = try? await previous.value }
            guard let self else { throw CancellationError() }
            return try await self.performSave(request)
        }
        saveTails[request.documentID] = task

        do {
            let receipt = try await task.value
            clearTailIfCurrent(documentID: request.documentID, generation: request.generation)
            return receipt
        } catch {
            clearTailIfCurrent(documentID: request.documentID, generation: request.generation)
            throw error
        }
    }

    private func performSave(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: request.projectID)
        let destinationURL = try validatedTextURL(
            request.relativePath,
            workspaceRoot: workspaceRoot
        )
        let parentURL = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LocalDocumentStoreError.parentDirectoryMissing(parentURL.path)
        }

        let data = Data(request.text.utf8)
        let temporaryURL = parentURL.appendingPathComponent(
            Self.temporaryPrefix
                + request.documentID.rawValue.uuidString.lowercased()
                + "-\(request.generation)-"
                + uuidGenerator.makeUUID().uuidString.lowercased()
                + Self.temporarySuffix
        )
        let markerURL = reconciliationURL(for: request.documentID, workspaceRoot: workspaceRoot)

        var didReplaceManuscript = false
        do {
            try writer.writeTemporaryFile(data: data, at: temporaryURL)
            let modifiedAt = temporaryModificationDate(temporaryURL)
            let receipt = DocumentSaveReceipt(
                projectID: request.projectID,
                documentID: request.documentID,
                relativePath: request.relativePath,
                contentHash: hasher.sha256(for: data),
                modifiedAt: modifiedAt,
                generation: request.generation
            )
            try writeReconciliationMarker(receipt, to: markerURL)
            try writer.replaceItem(at: destinationURL, with: temporaryURL)
            didReplaceManuscript = true

            do {
                try await metadataUpdater.updateAfterFileSave(receipt)
                try? fileManager.removeItem(at: markerURL)
                return receipt
            } catch {
                throw LocalDocumentStoreError.metadataUpdateFailed(
                    receipt: receipt,
                    markerPath: markerURL.path,
                    reason: String(describing: error)
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            // 원고 교체 전 실패에서는 복구 표식을 남기지 않는다.
            if !didReplaceManuscript {
                try? fileManager.removeItem(at: markerURL)
            }
            throw error
        }
    }

    func validatedTextURL(
        _ relativePath: RelativeDocumentPath,
        workspaceRoot: URL
    ) throws -> URL {
        guard relativePath.rawValue.lowercased().hasSuffix(".txt") else {
            throw LocalDocumentStoreError.textFileRequired(relativePath.rawValue)
        }
        let resolver = ProjectPathResolver(
            projectsRootURL: workspaceRoot.deletingLastPathComponent(),
            fileManager: fileManager
        )
        return try resolver.validatedURL(for: relativePath, in: workspaceRoot)
    }

    private func reconciliationURL(for id: DocumentID, workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(
            Self.reconciliationPrefix
                + id.rawValue.uuidString.lowercased()
                + Self.reconciliationSuffix
        )
    }

    private func writeReconciliationMarker(
        _ receipt: DocumentSaveReceipt,
        to markerURL: URL
    ) throws {
        try writer.injectedJournalFailure(at: markerURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(receipt)
        do {
            try data.write(to: markerURL, options: [.atomic])
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileWriteNoPermissionError {
                throw LocalDocumentStoreError.accessDenied(
                    operation: .reconciliation,
                    path: markerURL.path
                )
            }
            if nsError.domain == NSPOSIXErrorDomain,
               [Int(ENOSPC), Int(EDQUOT)].contains(nsError.code) {
                throw LocalDocumentStoreError.storageFull(path: markerURL.path)
            }
            throw LocalDocumentStoreError.operationFailed(
                operation: .reconciliation,
                path: markerURL.path,
                code: Int32(nsError.code)
            )
        }
    }

    private func temporaryModificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? clock.now()
    }

    private func mapReadError(_ error: Error, url: URL) -> LocalDocumentStoreError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError {
            return .fileNotFound(url.path)
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return .accessDenied(operation: .read, path: url.path)
        }
        return .operationFailed(operation: .read, path: url.path, code: Int32(nsError.code))
    }

    private func clearTailIfCurrent(documentID: DocumentID, generation: UInt64) {
        if latestSubmittedGeneration[documentID] == generation {
            saveTails[documentID] = nil
        }
    }
}
