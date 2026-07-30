import Foundation

/// UTF-8 TXT를 읽고, 문서별 저장 순서를 보장하며, 원자적으로 교체한다.
actor LocalDocumentStore: LocalDocumentStoring {
    static let temporaryPrefix = ".writerpad-save-"
    static let temporarySuffix = ".tmp"
    static let reconciliationPrefix = ".writerpad-reconcile-"
    static let reconciliationSuffix = ".json"
    static let syncHandoffPrefix = ".writerpad-sync-handoff-"
    static let syncHandoffSuffix = ".json"

    let workspaceLocator: any ProjectWorkspaceLocating
    let metadataUpdater: any DocumentFileMetadataUpdating
    private let durableChangeRecorder: any DurableLocalChangeRecording
    let fileManager: FileManager
    let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let syncUUIDGenerator: any UUIDGenerating
    let hasher: any ContentHashing
    private let writer: POSIXAtomicFileWriter
    private let syncMutationGate: SyncV2DocumentMutationGate
    let staleTemporaryFileAge: TimeInterval
    private var latestSubmittedGeneration: [DocumentID: UInt64] = [:]
    private var saveTails: [DocumentID: Task<DocumentSaveReceipt, Error>] = [:]
    private var pendingSyncHandoffs: [DocumentID: [LocalMutationBatch]] = [:]
    private var loadedSyncHandoffDocuments: Set<DocumentID> = []

    init(
        workspaceLocator: any ProjectWorkspaceLocating,
        metadataUpdater: any DocumentFileMetadataUpdating,
        durableChangeRecorder: any DurableLocalChangeRecording =
            NoOpDurableLocalChangeRecorder(),
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        syncUUIDGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        faultPlan: AtomicWriteFaultPlan? = nil,
        staleTemporaryFileAge: TimeInterval = 60 * 60,
        syncMutationGate: SyncV2DocumentMutationGate =
            SyncV2DocumentMutationGate()
    ) {
        self.workspaceLocator = workspaceLocator
        self.metadataUpdater = metadataUpdater
        self.durableChangeRecorder = durableChangeRecorder
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.syncUUIDGenerator = syncUUIDGenerator
        self.hasher = hasher
        self.writer = POSIXAtomicFileWriter(faultPlan: faultPlan)
        self.staleTemporaryFileAge = staleTemporaryFileAge
        self.syncMutationGate = syncMutationGate
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
            return try await self.syncMutationGate.withCriticalSection(
                documentID: request.documentID.rawValue
            ) {
                try await self.performSave(request)
            }
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
            let contentHash = hasher.sha256(for: data)
            let receipt = DocumentSaveReceipt(
                projectID: request.projectID,
                documentID: request.documentID,
                relativePath: request.relativePath,
                contentHash: contentHash,
                modifiedAt: modifiedAt,
                generation: request.generation,
                cursor: request.cursor,
                savedContent: SavedDocumentContent(
                    utf8Data: data,
                    contentHash: contentHash
                )
            )
            try writeReconciliationMarker(receipt, to: markerURL)
            try writer.replaceItem(at: destinationURL, with: temporaryURL)
            didReplaceManuscript = true

            do {
                try await metadataUpdater.updateAfterFileSave(receipt)
                let recordResult = await recordSavedDocument(
                    receipt,
                    batchKind: request.durableBatchKind,
                    workspaceRoot: workspaceRoot,
                    reconciliationURL: markerURL
                )
                return receipt.recording(recordResult)
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

    func retryPendingSyncHandoff(
        for document: DocumentNode
    ) async -> DurableRecordResult {
        let requirement = await durableChangeRecorder.requirement(
            for: document.projectID
        )
        guard requirement == .durableQueue else {
            return .localOnly
        }
        do {
            let workspaceRoot = try await workspaceLocator.workspaceRoot(
                for: document.projectID
            )
            try loadPendingSyncHandoffsIfNeeded(
                for: document.id,
                workspaceRoot: workspaceRoot
            )
            guard pendingSyncHandoffs[document.id]?.isEmpty == false else {
                return await durableChangeRecorder.preservedResult(
                    for: document.projectID,
                    documentID: document.id
                ) ?? .localOnly
            }
            return await flushPendingSyncHandoffs(
                for: document.id,
                workspaceRoot: workspaceRoot
            )
        } catch {
            return .localSavedButNotQueued(
                reason: "동기화 재시도 기록을 불러올 수 없습니다."
            )
        }
    }

    private func recordSavedDocument(
        _ receipt: DocumentSaveReceipt,
        batchKind: DurableLocalBatchKind,
        workspaceRoot: URL,
        reconciliationURL: URL
    ) async -> DurableRecordResult {
        let requirement = await durableChangeRecorder.requirement(
            for: receipt.projectID
        )
        guard requirement == .durableQueue else {
            try? fileManager.removeItem(at: reconciliationURL)
            return .localOnly
        }
        guard let content = receipt.savedContent else {
            return .localSavedButNotQueued(reason: "저장 snapshot을 복구할 수 없습니다.")
        }
        let batch = LocalMutationBatch(
            batchID: syncUUIDGenerator.makeUUID(),
            projectID: receipt.projectID,
            localTransactionID: nil,
            kind: batchKind,
            mutations: [
                .documentSnapshot(
                    operationID: syncUUIDGenerator.makeUUID(),
                    documentID: receipt.documentID,
                    relativePath: receipt.relativePath,
                    content: String(decoding: content.utf8Data, as: UTF8.self),
                    contentHash: content.contentHash,
                    localSaveGeneration: receipt.generation,
                    isDeleted: false
                )
            ]
        )
        do {
            try loadPendingSyncHandoffsIfNeeded(
                for: receipt.documentID,
                workspaceRoot: workspaceRoot
            )
            pendingSyncHandoffs[receipt.documentID, default: []].append(batch)
            try persistPendingSyncHandoffs(
                for: receipt.documentID,
                workspaceRoot: workspaceRoot
            )
            try? fileManager.removeItem(at: reconciliationURL)
        } catch {
            return .localSavedButNotQueued(
                reason: "동기화 재시도 기록을 저장할 수 없습니다."
            )
        }
        return await flushPendingSyncHandoffs(
            for: receipt.documentID,
            workspaceRoot: workspaceRoot
        )
    }

    private func flushPendingSyncHandoffs(
        for documentID: DocumentID,
        workspaceRoot: URL
    ) async -> DurableRecordResult {
        var queuedOperationIDs: [UUID] = []
        var didSkipNoOp = false
        var sizeLimitFailure: (byteCount: Int, limit: Int)?

        while let batch = pendingSyncHandoffs[documentID]?.first {
            let result = await durableChangeRecorder.record(batch)
            switch result {
            case .queued(let operationIDs):
                queuedOperationIDs.append(contentsOf: operationIDs)
                pendingSyncHandoffs[documentID]?.removeFirst()
                // 삭제 실패로 marker가 남아도 같은 batch ID 재생은 멱등이다.
                try? persistPendingSyncHandoffs(
                    for: documentID,
                    workspaceRoot: workspaceRoot
                )
            case .notNeeded:
                didSkipNoOp = true
                pendingSyncHandoffs[documentID]?.removeFirst()
                try? persistPendingSyncHandoffs(
                    for: documentID,
                    workspaceRoot: workspaceRoot
                )
            case let .serverSizeLimitExceeded(byteCount, limit):
                sizeLimitFailure = (byteCount, limit)
                pendingSyncHandoffs[documentID]?.removeFirst()
                try? persistPendingSyncHandoffs(
                    for: documentID,
                    workspaceRoot: workspaceRoot
                )
            case .localOnly:
                return .localSavedButNotQueued(
                    reason: "동기화 연결 상태가 변경되어 기록을 보류했습니다."
                )
            case .localSavedButNotQueued:
                return result
            }
        }
        pendingSyncHandoffs[documentID] = nil

        if let sizeLimitFailure {
            return .serverSizeLimitExceeded(
                byteCount: sizeLimitFailure.byteCount,
                limit: sizeLimitFailure.limit
            )
        }
        if !queuedOperationIDs.isEmpty {
            return .queued(operationIDs: queuedOperationIDs)
        }
        if didSkipNoOp {
            return .notNeeded
        }
        return .localOnly
    }

    private struct SyncHandoffEnvelope: Codable {
        let version: Int
        let documentID: DocumentID
        let batches: [LocalMutationBatch]
    }

    private func loadPendingSyncHandoffsIfNeeded(
        for documentID: DocumentID,
        workspaceRoot: URL
    ) throws {
        guard !loadedSyncHandoffDocuments.contains(documentID) else { return }
        let url = syncHandoffURL(for: documentID, workspaceRoot: workspaceRoot)
        guard fileManager.fileExists(atPath: url.path) else {
            pendingSyncHandoffs[documentID] = []
            loadedSyncHandoffDocuments.insert(documentID)
            return
        }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(SyncHandoffEnvelope.self, from: data)
        guard envelope.version == 1, envelope.documentID == documentID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pendingSyncHandoffs[documentID] = envelope.batches
        loadedSyncHandoffDocuments.insert(documentID)
    }

    private func persistPendingSyncHandoffs(
        for documentID: DocumentID,
        workspaceRoot: URL
    ) throws {
        let url = syncHandoffURL(for: documentID, workspaceRoot: workspaceRoot)
        let batches = pendingSyncHandoffs[documentID] ?? []
        guard !batches.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            return
        }
        let envelope = SyncHandoffEnvelope(
            version: 1,
            documentID: documentID,
            batches: batches
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: url, options: [.atomic])
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

    private func syncHandoffURL(for id: DocumentID, workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent(
            Self.syncHandoffPrefix
                + id.rawValue.uuidString.lowercased()
                + Self.syncHandoffSuffix
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
