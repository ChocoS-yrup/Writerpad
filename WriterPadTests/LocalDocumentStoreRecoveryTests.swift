import Foundation
import XCTest
@testable import WriterPad

final class LocalDocumentStoreRecoveryTests: XCTestCase {
    func testRestartReconcilesMetadataAfterCommittedFileUpdateFailure() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        try Data("기존".utf8).write(to: workspace.fileURL)
        let updater = RecordingMetadataUpdater(shouldFail: true)
        let store = makeStore(workspace, updater: updater)

        do {
            _ = try await store.save(workspace.request(text: "파일은 저장됨", generation: 1))
            XCTFail("메타데이터 오류가 필요합니다.")
        } catch let error as LocalDocumentStoreError {
            guard case .metadataUpdateFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "파일은 저장됨")
        XCTAssertEqual(try reconciliationMarkers(in: workspace.root).count, 1)

        await updater.setShouldFail(false)
        let restartedStore = makeStore(workspace, updater: updater)
        let report = try await restartedStore.recoverWorkspace(for: workspace.projectID)

        XCTAssertEqual(report.reconciledDocumentIDs, [workspace.documentID])
        XCTAssertTrue(report.retainedMarkers.isEmpty)
        XCTAssertTrue(try reconciliationMarkers(in: workspace.root).isEmpty)
        let updatedReceiptCount = await updater.receipts.count
        XCTAssertEqual(updatedReceiptCount, 1)
    }

    func testRestartRemovesOnlyStaleTemporaryFilesAndNeverPromotesThem() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        try Data("정상 원고".utf8).write(to: workspace.fileURL)
        let now = Date(timeIntervalSince1970: 10_000)
        let oldTemp = workspace.root.appendingPathComponent(".writerpad-save-old.tmp")
        let freshTemp = workspace.root.appendingPathComponent(".writerpad-save-fresh.tmp")
        try Data("오래된 조각".utf8).write(to: oldTemp)
        try Data("새 조각".utf8).write(to: freshTemp)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: oldTemp.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: freshTemp.path
        )
        let store = LocalDocumentStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
            metadataUpdater: RecordingMetadataUpdater(),
            clock: FixedClock(date: now),
            staleTemporaryFileAge: 3_600
        )

        let report = try await store.recoverWorkspace(for: workspace.projectID)
        XCTAssertEqual(report.removedTemporaryFiles, [oldTemp.path])
        XCTAssertEqual(report.retainedTemporaryFiles, [freshTemp.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTemp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTemp.path))
        XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "정상 원고")
    }

    func testMalformedReconciliationMarkerIsRetainedForInspection() async throws {
        let workspace = try LocalDocumentTestWorkspace.create()
        defer { workspace.remove() }
        let marker = workspace.root.appendingPathComponent(".writerpad-reconcile-broken.json")
        try Data("not-json".utf8).write(to: marker)
        let store = makeStore(workspace, updater: RecordingMetadataUpdater())

        let report = try await store.recoverWorkspace(for: workspace.projectID)
        XCTAssertEqual(report.retainedMarkers, [marker.path])
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeStore(
        _ workspace: LocalDocumentTestWorkspace,
        updater: any DocumentFileMetadataUpdating
    ) -> LocalDocumentStore {
        LocalDocumentStore(
            workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
            metadataUpdater: updater
        )
    }

    private func reconciliationMarkers(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) }
    }
}
