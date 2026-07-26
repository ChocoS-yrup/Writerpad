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
        faultPlan: AtomicWriteFaultPlan? = nil
    ) -> LocalDocumentStore {
        LocalDocumentStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
            metadataUpdater: updater,
            uuidGenerator: FixedUUIDGenerator(
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            faultPlan: faultPlan
        )
    }
}
