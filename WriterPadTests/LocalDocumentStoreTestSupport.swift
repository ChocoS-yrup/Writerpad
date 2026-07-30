import Foundation
@testable import WriterPad

struct FixedWorkspaceLocator: ProjectWorkspaceLocating {
    let root: URL

    func workspaceRoot(for projectID: ProjectID) async throws -> URL {
        root
    }
}

actor RecordingMetadataUpdater: DocumentFileMetadataUpdating {
    private(set) var receipts: [DocumentSaveReceipt] = []
    private var shouldFail = false

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws {
        if shouldFail { throw TestMetadataError.forced }
        receipts.append(receipt)
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }
}

actor BlockingMetadataUpdater: DocumentFileMetadataUpdating {
    private var shouldBlockFirst = true
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var receipts: [DocumentSaveReceipt] = []

    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws {
        if shouldBlockFirst {
            shouldBlockFirst = false
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        receipts.append(receipt)
    }

    func hasEnteredFirstUpdate() -> Bool { entered }

    func releaseFirstUpdate() {
        continuation?.resume()
        continuation = nil
    }
}

actor ScriptedDurableChangeRecorder: DurableLocalChangeRecording {
    private var results: [DurableRecordResult]
    private let restoredResult: DurableRecordResult?
    private let metadataUpdater: RecordingMetadataUpdater?
    private(set) var batches: [LocalMutationBatch] = []
    private(set) var metadataReceiptCounts: [Int] = []

    init(
        results: [DurableRecordResult],
        restoredResult: DurableRecordResult? = nil,
        metadataUpdater: RecordingMetadataUpdater? = nil
    ) {
        self.results = results
        self.restoredResult = restoredResult
        self.metadataUpdater = metadataUpdater
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        batches.append(batch)
        if let metadataUpdater {
            metadataReceiptCounts.append(await metadataUpdater.receipts.count)
        }
        guard !results.isEmpty else {
            return .localSavedButNotQueued(reason: "script exhausted")
        }
        return results.removeFirst()
    }

    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) async -> DurableRecordResult? {
        _ = projectID
        _ = documentID
        return restoredResult
    }
}

struct FixedClock: AppClock {
    let date: Date
    func now() -> Date { date }
}

struct FixedUUIDGenerator: UUIDGenerating {
    let uuid: UUID
    func makeUUID() -> UUID { uuid }
}

enum TestMetadataError: Error {
    case forced
}

struct LocalDocumentTestWorkspace {
    let root: URL
    let projectID: ProjectID
    let documentID: DocumentID
    let relativePath: RelativeDocumentPath
    let fileURL: URL

    static func create() throws -> LocalDocumentTestWorkspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPadDocumentStore-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("메인/원고/1권", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return LocalDocumentTestWorkspace(
            root: root,
            projectID: ProjectID(rawValue: UUID()),
            documentID: DocumentID(rawValue: UUID()),
            relativePath: RelativeDocumentPath(rawValue: "메인/원고/1권/1화.txt"),
            fileURL: parent.appendingPathComponent("1화.txt")
        )
    }

    func request(
        text: String,
        generation: UInt64,
        cursor: TextCursorState? = nil
    ) -> DocumentSaveRequest {
        DocumentSaveRequest(
            projectID: projectID,
            documentID: documentID,
            relativePath: relativePath,
            text: text,
            generation: generation,
            cursor: cursor
        )
    }

    func document() -> DocumentNode {
        DocumentNode(
            id: documentID,
            projectID: projectID,
            kind: .text,
            parentID: nil,
            relativePath: relativePath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
