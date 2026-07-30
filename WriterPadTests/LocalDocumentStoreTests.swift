import Foundation
import XCTest
@testable import WriterPad

final class LocalDocumentStoreTests: XCTestCase {
    func testUTF8RoundTripsEmptyKoreanEmojiAndLargeText() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let updater = RecordingMetadataUpdater()
        let store = makeStore(workspace, updater: updater)
        let samples = [
            "",
            "한글 원고\n둘째 줄",
            "글쓰기 😊📝 가족 이모지 👩‍💻",
            String(repeating: "대용량 원고 📖\n", count: 100_000)
        ]

        for (index, sample) in samples.enumerated() {
            let receipt = try await store.save(
                workspace.request(text: sample, generation: UInt64(index + 1))
            )
            let loadedText = try await store.loadText(for: workspace.document())
            XCTAssertEqual(loadedText, sample)
            XCTAssertEqual(
                receipt.contentHash,
                SHA256ContentHasher().sha256(for: Data(sample.utf8))
            )
        }
        let receipts = await updater.receipts
        XCTAssertEqual(receipts.count, samples.count)
    }

    func testSHA256MatchesKnownValue() {
        XCTAssertEqual(
            SHA256ContentHasher().sha256(for: Data("abc".utf8)).rawValue,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSaveReceiptCarriesReusableContentWithoutPersistingItInMarkerEncoding() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let text = String(repeating: "저장 결과 재사용🙂\n", count: 1_000)
        let expectedData = Data(text.utf8)
        let cursor = TextCursorState(location: 41, selectionLength: 3)
        let store = makeStore(workspace, updater: RecordingMetadataUpdater())

        let receipt = try await store.save(
            workspace.request(text: text, generation: 1, cursor: cursor)
        )

        XCTAssertEqual(receipt.savedContent?.utf8Data, expectedData)
        XCTAssertEqual(receipt.savedContent?.contentHash, receipt.contentHash)
        XCTAssertEqual(receipt.cursor, cursor)
        let encoded = try JSONEncoder().encode(receipt)
        XCTAssertNil(String(data: encoded, encoding: .utf8)?.range(of: "savedContent"))
        let decoded = try JSONDecoder().decode(DocumentSaveReceipt.self, from: encoded)
        XCTAssertNil(decoded.savedContent)
        XCTAssertEqual(decoded.cursor, cursor)
        XCTAssertEqual(decoded.contentHash, receipt.contentHash)
    }

    func testInvalidUTF8IsRejectedWithoutLossyDecoding() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        try Data([0xC3, 0x28]).write(to: workspace.fileURL)
        let store = makeStore(workspace, updater: RecordingMetadataUpdater())

        do {
            _ = try await store.loadText(for: workspace.document())
            XCTFail("UTF-8 오류가 필요합니다.")
        } catch let error as LocalDocumentStoreError {
            guard case .invalidUTF8 = error else { return XCTFail("\(error)") }
        }
    }

    func testSameDocumentSavesStayOrderedAcrossMetadataAwait() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let updater = BlockingMetadataUpdater()
        let store = makeStore(workspace, updater: updater)

        let first = Task { try await store.save(workspace.request(text: "첫 번째", generation: 1)) }
        while !(await updater.hasEnteredFirstUpdate()) { await Task.yield() }
        let second = Task { try await store.save(workspace.request(text: "두 번째", generation: 2)) }
        await Task.yield()
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "첫 번째")

        await updater.releaseFirstUpdate()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "두 번째")
        let generations = await updater.receipts.map(\.generation)
        XCTAssertEqual(generations, [1, 2])
    }

    func testSuccessfulSaveHandsImmutableSnapshotToQueueAfterMetadata()
        async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let updater = RecordingMetadataUpdater()
        let operationID = UUID()
        let recorder = ScriptedDurableChangeRecorder(
            results: [.queued(operationIDs: [operationID])],
            metadataUpdater: updater
        )
        let store = makeStore(
            workspace,
            updater: updater,
            durableChangeRecorder: recorder
        )
        let text = "확정 snapshot 한글🙂"

        let receipt = try await store.save(
            workspace.request(text: text, generation: 17)
        )

        XCTAssertEqual(
            receipt.durableRecordResult,
            .queued(operationIDs: [operationID])
        )
        let metadataReceiptCounts = await recorder.metadataReceiptCounts
        let recordedBatches = await recorder.batches
        XCTAssertEqual(metadataReceiptCounts, [1])
        let batch = try XCTUnwrap(recordedBatches.first)
        XCTAssertEqual(batch.projectID, workspace.projectID)
        XCTAssertEqual(batch.mutations.count, 1)
        guard case let .documentSnapshot(
            _,
            documentID,
            relativePath,
            content,
            contentHash,
            generation,
            isDeleted
        ) = batch.mutations[0] else {
            return XCTFail("문서 snapshot이어야 합니다.")
        }
        XCTAssertEqual(documentID, workspace.documentID)
        XCTAssertEqual(relativePath, workspace.relativePath)
        XCTAssertEqual(content, text)
        XCTAssertEqual(contentHash, receipt.contentHash)
        XCTAssertEqual(generation, 17)
        XCTAssertFalse(isDeleted)
    }

    func testQueueFailureKeepsLocalSaveAndRetriesSameImmutableBatch()
        async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let operationID = UUID()
        let recorder = ScriptedDurableChangeRecorder(
            results: [
                .localSavedButNotQueued(reason: "injected queue failure"),
                .queued(operationIDs: [operationID])
            ]
        )
        let store = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: recorder
        )

        let receipt = try await store.save(
            workspace.request(text: "로컬은 성공", generation: 1)
        )

        XCTAssertEqual(
            receipt.durableRecordResult,
            .localSavedButNotQueued(reason: "injected queue failure")
        )
        XCTAssertEqual(
            try String(contentsOf: workspace.fileURL, encoding: .utf8),
            "로컬은 성공"
        )

        let retry = await store.retryPendingSyncHandoff(
            for: workspace.document()
        )
        XCTAssertEqual(retry, .queued(operationIDs: [operationID]))
        let attempts = await recorder.batches
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts[0], attempts[1])
    }

    func testOversizedServerSnapshotStillCompletesLocalSave()
        async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let limit = 10 * 1_024 * 1_024
        let text = String(repeating: "a", count: limit + 1)
        let recorder = ScriptedDurableChangeRecorder(
            results: [
                .serverSizeLimitExceeded(
                    byteCount: limit + 1,
                    limit: limit
                )
            ]
        )
        let store = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: recorder
        )

        let receipt = try await store.save(
            workspace.request(text: text, generation: 1)
        )

        XCTAssertEqual(
            receipt.durableRecordResult,
            .serverSizeLimitExceeded(
                byteCount: limit + 1,
                limit: limit
            )
        )
        XCTAssertEqual(try Data(contentsOf: workspace.fileURL).count, limit + 1)
        let restored = try await store.loadText(for: workspace.document())
        XCTAssertEqual(restored, text)

        let reopened = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: ScriptedDurableChangeRecorder(
                results: [],
                restoredResult: .serverSizeLimitExceeded(
                    byteCount: limit + 1,
                    limit: limit
                )
            )
        )
        let restoredState = await reopened.retryPendingSyncHandoff(
            for: workspace.document()
        )
        XCTAssertEqual(
            restoredState,
            .serverSizeLimitExceeded(
                byteCount: limit + 1,
                limit: limit
            )
        )
    }

    func testNextSaveFlushesEarlierFailureBeforeNewSnapshot()
        async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        let recorder = ScriptedDurableChangeRecorder(
            results: [
                .localSavedButNotQueued(reason: "first attempt failed"),
                .queued(operationIDs: [firstOperationID]),
                .queued(operationIDs: [secondOperationID])
            ]
        )
        let store = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: recorder
        )
        _ = try await store.save(
            workspace.request(text: "첫 snapshot", generation: 1)
        )

        let second = try await store.save(
            workspace.request(text: "둘째 snapshot", generation: 2)
        )

        XCTAssertEqual(
            second.durableRecordResult,
            .queued(operationIDs: [firstOperationID, secondOperationID])
        )
        let attempts = await recorder.batches
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertNotEqual(attempts[1].batchID, attempts[2].batchID)
        XCTAssertEqual(snapshotContent(in: attempts[1]), "첫 snapshot")
        XCTAssertEqual(snapshotContent(in: attempts[2]), "둘째 snapshot")
    }

    func testQueueFailureSurvivesStoreRecreationWithSameImmutableBatch()
        async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let failingRecorder = ScriptedDurableChangeRecorder(
            results: [.localSavedButNotQueued(reason: "injected")]
        )
        let firstStore = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: failingRecorder
        )
        _ = try await firstStore.save(
            workspace.request(text: "재실행 뒤에도 보존", generation: 9)
        )
        let failedAttempts = await failingRecorder.batches
        let firstAttempt = try XCTUnwrap(failedAttempts.first)
        let operationID = UUID()
        let succeedingRecorder = ScriptedDurableChangeRecorder(
            results: [.queued(operationIDs: [operationID])]
        )
        let recreatedStore = makeStore(
            workspace,
            updater: RecordingMetadataUpdater(),
            durableChangeRecorder: succeedingRecorder
        )

        let result = await recreatedStore.retryPendingSyncHandoff(
            for: workspace.document()
        )

        XCTAssertEqual(result, .queued(operationIDs: [operationID]))
        let successfulAttempts = await succeedingRecorder.batches
        let replay = try XCTUnwrap(successfulAttempts.first)
        XCTAssertEqual(replay, firstAttempt)
        XCTAssertEqual(snapshotContent(in: replay), "재실행 뒤에도 보존")
    }

    func testStaleGenerationCannotOverwriteLatestText() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let store = makeStore(workspace, updater: RecordingMetadataUpdater())
        _ = try await store.save(workspace.request(text: "최신", generation: 2))

        do {
            _ = try await store.save(workspace.request(text: "오래된 값", generation: 1))
            XCTFail("오래된 generation을 거부해야 합니다.")
        } catch let error as LocalDocumentStoreError {
            guard case .staleGeneration = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "최신")
    }

    func testEveryPreReplacementFailurePreservesExistingManuscript() async throws {
        let points: [AtomicWriteFaultPoint] = [
            .beforeTemporaryFileCreation,
            .duringWrite,
            .duringFlush,
            .beforeReconciliationJournal,
            .beforeReplacement
        ]

        for point in points {
            let workspace = try LocalDocumentTestWorkspace.create()
            try Data("기존 정상 원고".utf8).write(to: workspace.fileURL)
            defer { workspace.remove() }
            let store = makeStore(
                workspace,
                updater: RecordingMetadataUpdater(),
                faultPlan: .init(point: point, failure: .generic(code: EIO))
            )

            do {
                _ = try await store.save(workspace.request(text: "새 원고", generation: 1))
                XCTFail("\(point)에서 실패해야 합니다.")
            } catch {
                XCTAssertEqual(
                    try String(contentsOf: workspace.fileURL, encoding: .utf8),
                    "기존 정상 원고"
                )
                let names = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
                XCTAssertFalse(names.contains { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) })
            }
        }
    }

    func testPermissionAndDiskFullFailuresAreMeaningful() async throws {
        for failure in [InjectedWriteFailure.accessDenied, .storageFull] {
            let workspace = try LocalDocumentTestWorkspace.create()
            defer { workspace.remove() }
            let store = makeStore(
                workspace,
                updater: RecordingMetadataUpdater(),
                faultPlan: .init(point: .duringWrite, failure: failure)
            )
            do {
                _ = try await store.save(workspace.request(text: "저장", generation: 1))
                XCTFail("주입한 실패가 필요합니다.")
            } catch let error as LocalDocumentStoreError {
                switch (failure, error) {
                case (.accessDenied, .accessDenied), (.storageFull, .storageFull): break
                default: XCTFail("\(failure): \(error)")
                }
            }
        }
    }

    private func makeStore(
        _ workspace: LocalDocumentTestWorkspace,
        updater: any DocumentFileMetadataUpdating,
        durableChangeRecorder: any DurableLocalChangeRecording =
            NoOpDurableLocalChangeRecorder(),
        faultPlan: AtomicWriteFaultPlan? = nil
    ) -> LocalDocumentStore {
        LocalDocumentStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
            metadataUpdater: updater,
            durableChangeRecorder: durableChangeRecorder,
            uuidGenerator: FixedUUIDGenerator(
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            faultPlan: faultPlan
        )
    }

    private func snapshotContent(in batch: LocalMutationBatch) -> String? {
        guard case let .documentSnapshot(
            _, _, _, content, _, _, _
        ) = batch.mutations.first else {
            return nil
        }
        return content
    }
}
