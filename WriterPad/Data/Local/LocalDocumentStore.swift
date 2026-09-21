import Foundation

/// 문서 gate 내부 작업은 별도 Task다. 호출자 취소와 실제 TXT 교체 결과를
/// 공유해, 취소/시간 초과를 아직 저장하지 않은 것으로 오인하지 않는다.
private final class ComparedDocumentSaveState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var saved: (DocumentSaveReceipt, String)?
    var replacement: (DocumentSaveReceipt, String)? { lock.withLock { saved } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try lock.withLock { if cancelled { throw CancellationError() } }
    }
    func replace(receipt: DocumentSaveReceipt, marker: String, operation: () throws -> Void) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            saved = (receipt, marker)
        }
    }
}

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
        try await save(request, authorize: {})
    }

    func saveCompared(_ request: DocumentSaveRequest,
        authorize: @escaping @Sendable () throws -> Void) async throws -> DocumentSaveReceipt {
        guard request.expectedCurrentContentHash != nil else { throw LocalDocumentStoreError.comparedContentChanged }
        return try await save(request, authorize: authorize)
    }

    private func save(_ request: DocumentSaveRequest,
        authorize: @escaping @Sendable () throws -> Void) async throws -> DocumentSaveReceipt {
        let compared = request.expectedCurrentContentHash == nil ? nil : ComparedDocumentSaveState()
        if compared != nil { try Task.checkCancellation() }
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
                try await self.performSave(request, compared: compared, authorize: authorize)
            }
        }
        saveTails[request.documentID] = task

        do {
            let receipt = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                if let compared { compared.cancel(); task.cancel() }
            }
            clearTailIfCurrent(documentID: request.documentID, generation: request.generation)
            return receipt
        } catch {
            clearTailIfCurrent(documentID: request.documentID, generation: request.generation)
            if let (receipt, marker) = compared?.replacement {
                if case LocalDocumentStoreError.metadataUpdateFailed = error { throw error }
                throw LocalDocumentStoreError.metadataUpdateFailed(receipt: receipt, markerPath: marker,
                    reason: "선택한 원고는 저장됐지만 후속 기록의 완료 여부를 확인하지 못했습니다.")
            }
            throw error
        }
    }

    private func performSave(_ request: DocumentSaveRequest,
        compared: ComparedDocumentSaveState?,
        authorize: @Sendable () throws -> Void) async throws -> DocumentSaveReceipt {
        try await metadataUpdater.validateBeforeFileSave(request)
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
        // 문서 잠금과 앞선 저장 완료 뒤에 검사한다. 검사부터 원자적 교체까지
        // await가 없으므로 뒤늦은 선택이 다른 로컬 저장을 덮지 않는다.
        if let expected = request.expectedCurrentContentHash {
            try Task.checkCancellation()
            try compared?.check()
            let current = try Data(contentsOf: destinationURL)
            guard hasher.sha256(for: current) == expected else {
                throw LocalDocumentStoreError.comparedContentChanged
            }
        }
        try authorize()
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
            if let compared {
                try compared.replace(receipt: receipt, marker: markerURL.path) {
                    try authorize()
                    try ReceiveValidationPolicy.current.mutateIfReceiving {
                        try writer.replaceItem(at: destinationURL, with: temporaryURL)
                    }
                }
            } else {
                try writer.replaceItem(at: destinationURL, with: temporaryURL)
            }
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
            batchID: GeneralValidationRuntimeValues.current?.batch ?? syncUUIDGenerator.makeUUID(),
            projectID: receipt.projectID,
            localTransactionID: nil,
            kind: batchKind,
            mutations: [
                .documentSnapshot(
                    operationID: GeneralValidationRuntimeValues.current?.operation ?? syncUUIDGenerator.makeUUID(),
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
                try ReceiveValidationPolicy.current.mutateIfReceiving { try fileManager.removeItem(at: url) }
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
        try ReceiveValidationPolicy.current.mutateIfReceiving { try data.write(to: url, options: [.atomic]) }
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
            try ReceiveValidationPolicy.current.mutateIfReceiving {
                try data.write(to: markerURL, options: [.atomic])
            }
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
        if let values = GeneralValidationRuntimeValues.current { return values.date }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
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
