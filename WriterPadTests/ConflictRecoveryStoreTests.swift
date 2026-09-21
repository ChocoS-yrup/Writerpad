import Foundation
import XCTest
@testable import WriterPad

final class ConflictRecoveryStoreTests: XCTestCase {
    func testStaleTombstoneRevisionDoesNotCreateOrResolveRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        do {
            _ = try await fixture.makeStore().preserveRemoteDeletion(
                operation: fixture.operation,
                tombstoneRevision: fixture.operation.baseRevision
            )
            XCTFail("stale snapshot must be fetched again")
        } catch let error as ConflictRecoveryLedgerError {
            XCTAssertEqual(error, .invalidRemoteDeletion)
        }

        let packageCount = await fixture.ledger.packageCount()
        let resolveCount = await fixture.ledger.resolveCount()
        XCTAssertEqual(packageCount, 0)
        XCTAssertEqual(resolveCount, 0)
    }

    func testPreserveCopiesWholeSubtreeThenResolvesSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()

        let package = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )

        XCTAssertEqual(package.state, .sourceResolved)
        XCTAssertEqual(package.fileCount, 2)
        XCTAssertEqual(package.totalBytes, fixture.firstData.count + fixture.secondData.count)
        let manifest = try await store.validatedManifest(for: package)
        XCTAssertEqual(manifest.entities.count, 4)
        XCTAssertEqual(
            Set(manifest.entities.map(\.sourceEntityID)),
            Set(fixture.documents
                .filter { $0.id != fixture.recoveryContainerID }
                .map { $0.id.rawValue })
        )
        let restoredData = try await store.payloadData(
            package: package,
            sourceDocumentID: fixture.firstDocumentID.rawValue
        )
        XCTAssertEqual(restoredData, fixture.firstData)
        let resolutions = await fixture.ledger.resolveCount()
        XCTAssertEqual(resolutions, 1)
    }

    func testPreserveSameOperationAndRevisionDoesNotDuplicatePackage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()

        let first = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        let second = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )

        XCTAssertEqual(first.id, second.id)
        let begins = await fixture.ledger.beginCount()
        let packages = await fixture.ledger.packageCount()
        let readies = await fixture.ledger.readyCount()
        let resolutions = await fixture.ledger.resolveCount()
        XCTAssertEqual(begins, 2)
        XCTAssertEqual(packages, 1)
        XCTAssertEqual(readies, 1)
        XCTAssertEqual(resolutions, 1)
    }

    func testCorruptedPayloadIsRejectedWithoutChangingLedger() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let package = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        let payloadURL = fixture.packagesRoot
            .appendingPathComponent(package.payloadRelativePath, isDirectory: true)
            .appendingPathComponent(ConflictRecoveryStore.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(fixture.firstDocumentID.rawValue.uuidString.lowercased())
        try Data("손상".utf8).write(to: payloadURL, options: [.atomic])

        do {
            _ = try await store.validatedManifest(for: package)
            XCTFail("corrupted payload must fail")
        } catch {
            guard case ConflictRecoveryStoreError.packageCorrupted = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let packageCount = await fixture.ledger.packageCount()
        XCTAssertEqual(packageCount, 1)
    }

    func testExplicitRestoreUsesNewIDsAndReplaysOneDurableBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let preserved = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )

        let enqueued = try await store.restoreAsNewFolder(
            package: preserved,
            targetParentID: fixture.recoveryContainerID,
            rootDisplayName: "삭제시험-아이패드 (복구됨)"
        )
        let replay = try await store.restoreAsNewFolder(
            package: enqueued,
            targetParentID: fixture.recoveryContainerID,
            rootDisplayName: "삭제시험-아이패드 (복구됨)"
        )

        XCTAssertEqual(enqueued.state, .restoreEnqueued)
        XCTAssertEqual(replay.id, enqueued.id)
        let entities = await fixture.ledger.conflictRecoveryEntities(
            packageID: enqueued.id
        )
        XCTAssertEqual(entities.count, 4)
        XCTAssertTrue(entities.allSatisfy {
            $0.restoredEntityID != nil && $0.restoredEntityID != $0.sourceEntityID
        })
        let batches = await fixture.recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.batchID, enqueued.restoreBatchID)
        XCTAssertEqual(batches.first?.kind, .backupRestore)
        XCTAssertEqual(batches.first?.mutations.count, 5)
        let restoredURL = fixture.workspace.appendingPathComponent(
            "메모장/복구/삭제시험-아이패드 (복구됨)/첫째.txt"
        )
        XCTAssertEqual(try Data(contentsOf: restoredURL), fixture.firstData)
    }

    func testCrashDuringCopyResumesWithoutDuplicatePackage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fault = RecoveryFaultInjector(point: .afterPayloadCopy)
        let crashing = fixture.makeStore(injectFault: { try fault.call($0) })
        do {
            _ = try await crashing.preserveRemoteDeletion(
                operation: fixture.operation,
                tombstoneRevision: 3
            )
            XCTFail("fault must interrupt the first copy")
        } catch RecoveryInjectedFault.stop {
        }

        let resumed = try await fixture.makeStore().preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        XCTAssertEqual(resumed.state, .sourceResolved)
        let count = await fixture.ledger.packageCount()
        XCTAssertEqual(count, 1)
    }

    func testCrashAfterReadyResumesBeforeCancellingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fault = RecoveryFaultInjector(point: .afterReadyBeforeSourceResolution)
        do {
            _ = try await fixture.makeStore(injectFault: { try fault.call($0) })
                .preserveRemoteDeletion(
                    operation: fixture.operation,
                    tombstoneRevision: 3
                )
            XCTFail("fault must interrupt after ready")
        } catch RecoveryInjectedFault.stop {
        }
        let ready = await fixture.ledger.conflictRecoveryPackages(
            localProjectID: fixture.projectID
        ).first
        XCTAssertEqual(ready?.state, .ready)

        let resumed = try await fixture.makeStore().preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        XCTAssertEqual(resumed.state, .sourceResolved)
        let resolutions = await fixture.ledger.resolveCount()
        XCTAssertEqual(resolutions, 1)
    }

    func testCrashAfterRestoreQueueReplaysSameBatchAndIDs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preserved = try await fixture.makeStore().preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        let fault = RecoveryFaultInjector(point: .afterRestoreQueued)
        do {
            _ = try await fixture.makeStore(injectFault: { try fault.call($0) })
                .restoreAsNewFolder(
                    package: preserved,
                    targetParentID: fixture.recoveryContainerID,
                    rootDisplayName: "복구본"
                )
            XCTFail("fault must interrupt after queue")
        } catch RecoveryInjectedFault.stop {
        }
        let resumed = try await fixture.makeStore().restoreAsNewFolder(
            package: preserved,
            targetParentID: fixture.recoveryContainerID,
            rootDisplayName: "복구본"
        )
        XCTAssertEqual(resumed.state, .restoreEnqueued)
        let batches = await fixture.recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.batchID, resumed.restoreBatchID)
    }

    func testRestoreRejectsExistingNameWithoutMergeOrOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let preserved = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        let collision = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: fixture.projectID,
            kind: .folder,
            parentID: fixture.recoveryContainerID,
            relativePath: .init(rawValue: "메모장/복구/이미 있음"),
            userOrder: 0,
            modifiedAt: Date(),
            contentHash: nil
        )
        await fixture.repository.save(collision)
        try FileManager.default.createDirectory(
            at: fixture.workspace.appendingPathComponent("메모장/복구/이미 있음"),
            withIntermediateDirectories: true
        )

        do {
            _ = try await store.restoreAsNewFolder(
                package: preserved,
                targetParentID: fixture.recoveryContainerID,
                rootDisplayName: "이미 있음"
            )
            XCTFail("name collision must not merge")
        } catch let error as ConflictRecoveryStoreError {
            XCTAssertEqual(error, .nameCollision("이미 있음"))
        }
        let batches = await fixture.recorder.recordedBatches()
        XCTAssertEqual(batches, [])
    }

    func testNetworkFailureDuringRestoreKeepsPlanForFiniteRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        let preserved = try await store.preserveRemoteDeletion(
            operation: fixture.operation,
            tombstoneRevision: 3
        )
        await fixture.recorder.failNext("오프라인")
        do {
            _ = try await store.restoreAsNewFolder(
                package: preserved,
                targetParentID: fixture.recoveryContainerID,
                rootDisplayName: "네트워크 복구본"
            )
            XCTFail("the first queue handoff must fail")
        } catch let error as ConflictRecoveryStoreError {
            XCTAssertEqual(error, .queueFailed("오프라인"))
        }
        let stillResolved = await fixture.ledger.conflictRecoveryPackages(
            localProjectID: fixture.projectID
        ).first
        XCTAssertEqual(stillResolved?.state, .sourceResolved)

        let resumed = try await store.restoreAsNewFolder(
            package: preserved,
            targetParentID: fixture.recoveryContainerID,
            rootDisplayName: "네트워크 복구본"
        )
        XCTAssertEqual(resumed.state, .restoreEnqueued)
        let batches = await fixture.recorder.recordedBatches()
        XCTAssertEqual(batches.count, 1)
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let workspace: URL
    let packagesRoot: URL
    let projectID = ProjectID(rawValue: UUID())
    let serverProjectID = UUID()
    let rootFolderID = DocumentID(rawValue: UUID())
    let recoveryContainerID = DocumentID(rawValue: UUID())
    let childFolderID = DocumentID(rawValue: UUID())
    let firstDocumentID = DocumentID(rawValue: UUID())
    let secondDocumentID = DocumentID(rawValue: UUID())
    let firstData = Data("첫 번째 로컬 본문".utf8)
    let secondData = Data("두 번째 로컬 본문".utf8)
    let documents: [DocumentNode]
    let operation: SyncV2FolderDispatchOperation
    let ledger = RecoveryLedgerSpy()
    let recorder = RecoveryRecorderSpy()
    let repository: RecoveryDocumentRepository

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        packagesRoot = root.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("메모장/삭제시험/안쪽", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("메모장/복구", isDirectory: true),
            withIntermediateDirectories: true
        )
        try firstData.write(
            to: workspace.appendingPathComponent("메모장/삭제시험/첫째.txt"),
            options: [.atomic]
        )
        try secondData.write(
            to: workspace.appendingPathComponent("메모장/삭제시험/안쪽/둘째.txt"),
            options: [.atomic]
        )
        let now = Date(timeIntervalSince1970: 1)
        documents = [
            DocumentNode(
                id: recoveryContainerID, projectID: projectID, kind: .folder,
                parentID: nil, relativePath: .init(rawValue: "메모장/복구"),
                userOrder: 1, modifiedAt: now, contentHash: nil
            ),
            DocumentNode(
                id: rootFolderID, projectID: projectID, kind: .folder,
                parentID: nil, relativePath: .init(rawValue: "메모장/삭제시험"),
                userOrder: 0, modifiedAt: now, contentHash: nil
            ),
            DocumentNode(
                id: childFolderID, projectID: projectID, kind: .folder,
                parentID: rootFolderID, relativePath: .init(rawValue: "메모장/삭제시험/안쪽"),
                userOrder: 0, modifiedAt: now, contentHash: nil
            ),
            DocumentNode(
                id: firstDocumentID, projectID: projectID, kind: .text,
                parentID: rootFolderID, relativePath: .init(rawValue: "메모장/삭제시험/첫째.txt"),
                userOrder: 1, modifiedAt: now,
                contentHash: SHA256ContentHasher().sha256(for: firstData)
            ),
            DocumentNode(
                id: secondDocumentID, projectID: projectID, kind: .text,
                parentID: childFolderID, relativePath: .init(rawValue: "메모장/삭제시험/안쪽/둘째.txt"),
                userOrder: 0, modifiedAt: now,
                contentHash: SHA256ContentHasher().sha256(for: secondData)
            ),
        ]
        operation = SyncV2FolderDispatchOperation(
            operationID: UUID(), batchID: UUID(), supersedesOperationID: nil,
            automaticRebaseCount: 0, localProjectID: projectID,
            projectID: serverProjectID, folderID: rootFolderID.rawValue,
            parentFolderID: nil, deviceID: UUID(), folderSequence: 1,
            name: "삭제시험-아이패드", baseRevision: 2,
            isDeleted: false, attempts: 1
        )
        repository = RecoveryDocumentRepository(documents: documents)
    }

    func makeStore(
        injectFault:
            (@Sendable (ConflictRecoveryFaultPoint) throws -> Void)? = nil
    ) -> ConflictRecoveryStore {
        ConflictRecoveryStore(
            ledger: ledger,
            documentRepository: repository,
            workspaceLocator: RecoveryWorkspaceLocator(workspace: workspace),
            packagesRootURL: packagesRoot,
            durableChangeRecorder: recorder,
            injectFault: injectFault
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum RecoveryInjectedFault: Error {
    case stop
}

private final class RecoveryFaultInjector: @unchecked Sendable {
    private let point: ConflictRecoveryFaultPoint
    private let lock = NSLock()
    private var hasFired = false

    init(point: ConflictRecoveryFaultPoint) { self.point = point }

    func call(_ candidate: ConflictRecoveryFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == point, !hasFired else { return }
        hasFired = true
        throw RecoveryInjectedFault.stop
    }
}

private actor RecoveryDocumentRepository: DocumentRepository {
    var documentsValue: [DocumentNode]
    init(documents: [DocumentNode]) { documentsValue = documents }
    func documents(in projectID: ProjectID) -> [DocumentNode] {
        documentsValue.filter { $0.projectID == projectID }
    }
    func document(id: DocumentID) -> DocumentNode? {
        documentsValue.first { $0.id == id }
    }
    func save(_ document: DocumentNode) {
        documentsValue.removeAll { $0.id == document.id }
        documentsValue.append(document)
    }
    func removeMetadata(id: DocumentID) {
        documentsValue.removeAll { $0.id == id }
    }
}

private actor RecoveryRecorderSpy: DurableLocalChangeRecording {
    private var batches: [LocalMutationBatch] = []
    private var nextFailure: String?
    func requirement(for projectID: ProjectID) -> DurableRecordingRequirement {
        _ = projectID
        return .durableQueue
    }
    func hasRecordedInitialSnapshot(
        for projectID: ProjectID,
        kind: DurableLocalBatchKind
    ) -> Bool {
        _ = (projectID, kind)
        return false
    }
    func record(_ batch: LocalMutationBatch) -> DurableRecordResult {
        if let nextFailure {
            self.nextFailure = nil
            return .localSavedButNotQueued(reason: nextFailure)
        }
        if !batches.contains(where: { $0.batchID == batch.batchID }) {
            batches.append(batch)
        }
        return .queued(operationIDs: batch.mutations.map { mutation in
            switch mutation {
            case let .ensureProject(operationID, _),
                 let .documentSnapshot(operationID, _, _, _, _, _, _),
                 let .treeOrder(operationID, _, _),
                 let .trashPurge(operationID, _, _),
                 let .folderSnapshot(operationID, _, _, _, _):
                operationID
            }
        })
    }
    func preservedResult(
        for projectID: ProjectID,
        documentID: DocumentID
    ) -> DurableRecordResult? {
        _ = (projectID, documentID)
        return nil
    }
    func recordedBatches() -> [LocalMutationBatch] { batches }
    func failNext(_ reason: String) { nextFailure = reason }
}

private struct RecoveryWorkspaceLocator: ProjectWorkspaceLocating {
    let workspace: URL
    func workspaceRoot(for projectID: ProjectID) -> URL {
        _ = projectID
        return workspace
    }
}

private actor RecoveryLedgerSpy: ConflictRecoveryLedger {
    private var value: ConflictRecoveryPackage?
    private var entityValues: [ConflictRecoveryEntity] = []
    private var begins = 0
    private var readies = 0
    private var resolutions = 0

    func beginRemoteDeletionRecovery(
        operation: SyncV2FolderDispatchOperation,
        tombstoneRevision: Int64,
        displayName: String,
        payloadRelativePath: String
    ) -> ConflictRecoveryPackage {
        begins += 1
        if let value { return value }
        let now = Date(timeIntervalSince1970: 1)
        let package = ConflictRecoveryPackage(
            id: UUID(), localProjectID: operation.localProjectID,
            serverProjectID: operation.projectID,
            sourceOperationID: operation.operationID,
            sourceFolderID: operation.folderID,
            sourceBaseRevision: operation.baseRevision,
            tombstoneRevision: tombstoneRevision,
            displayName: displayName, state: .preparing,
            payloadRelativePath: payloadRelativePath,
            manifestSHA256: nil, fileCount: 0, totalBytes: 0,
            restoreBatchID: nil, createdAt: now, updatedAt: now,
            restoredAt: nil, payloadDeletedAt: nil
        )
        value = package
        return package
    }

    func markConflictRecoveryReady(
        packageID: UUID,
        manifestSHA256: String,
        fileCount: Int,
        totalBytes: Int,
        entities: [ConflictRecoveryEntity]
    ) throws {
        guard let current = value, current.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        if current.state != .preparing { return }
        readies += 1
        entityValues = entities
        value = replacing(
            current, state: .ready, manifestSHA256: manifestSHA256,
            fileCount: fileCount, totalBytes: totalBytes
        )
    }

    func resolveRemoteDeletionSource(packageID: UUID) throws {
        guard let current = value, current.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        if current.state == .sourceResolved { return }
        guard current.state == .ready else {
            throw ConflictRecoveryLedgerError.invalidState
        }
        resolutions += 1
        value = replacing(current, state: .sourceResolved)
    }

    func markConflictRecoveryRestoreEnqueued(
        packageID: UUID,
        restoreBatchID: UUID,
        restoredEntityIDs: [UUID: UUID]
    ) throws {
        guard let current = value, current.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        entityValues = entityValues.map { entity in
            ConflictRecoveryEntity(
                kind: entity.kind,
                sourceEntityID: entity.sourceEntityID,
                restoredEntityID: restoredEntityIDs[entity.sourceEntityID],
                parentSourceEntityID: entity.parentSourceEntityID,
                relativePath: entity.relativePath,
                title: entity.title,
                userOrder: entity.userOrder,
                byteCount: entity.byteCount,
                sha256: entity.sha256,
                restoreStatus: .enqueued
            )
        }
        value = ConflictRecoveryPackage(
            id: current.id, localProjectID: current.localProjectID,
            serverProjectID: current.serverProjectID,
            sourceOperationID: current.sourceOperationID,
            sourceFolderID: current.sourceFolderID,
            sourceBaseRevision: current.sourceBaseRevision,
            tombstoneRevision: current.tombstoneRevision,
            displayName: current.displayName, state: .restoreEnqueued,
            payloadRelativePath: current.payloadRelativePath,
            manifestSHA256: current.manifestSHA256,
            fileCount: current.fileCount, totalBytes: current.totalBytes,
            restoreBatchID: restoreBatchID,
            createdAt: current.createdAt, updatedAt: Date(),
            restoredAt: nil, payloadDeletedAt: nil
        )
    }

    func markConflictRecoveryRestored(packageID: UUID) throws {
        guard let current = value, current.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        value = replacing(current, state: .restored)
    }

    func discardConflictRecoveryPackage(packageID: UUID) throws {
        guard let current = value, current.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        value = replacing(current, state: .discarded)
    }

    func markConflictRecoveryPayloadDeleted(packageID: UUID) throws {
        guard value?.id == packageID else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
    }

    func conflictRecoveryPackages(
        localProjectID: ProjectID?
    ) -> [ConflictRecoveryPackage] {
        guard let value else { return [] }
        return localProjectID == nil || value.localProjectID == localProjectID
            ? [value] : []
    }

    func conflictRecoveryEntities(
        packageID: UUID
    ) -> [ConflictRecoveryEntity] {
        value?.id == packageID ? entityValues : []
    }

    func beginCount() -> Int { begins }
    func readyCount() -> Int { readies }
    func resolveCount() -> Int { resolutions }
    func packageCount() -> Int { value == nil ? 0 : 1 }

    private func replacing(
        _ package: ConflictRecoveryPackage,
        state: ConflictRecoveryPackageState,
        manifestSHA256: String? = nil,
        fileCount: Int? = nil,
        totalBytes: Int? = nil
    ) -> ConflictRecoveryPackage {
        ConflictRecoveryPackage(
            id: package.id, localProjectID: package.localProjectID,
            serverProjectID: package.serverProjectID,
            sourceOperationID: package.sourceOperationID,
            sourceFolderID: package.sourceFolderID,
            sourceBaseRevision: package.sourceBaseRevision,
            tombstoneRevision: package.tombstoneRevision,
            displayName: package.displayName, state: state,
            payloadRelativePath: package.payloadRelativePath,
            manifestSHA256: manifestSHA256 ?? package.manifestSHA256,
            fileCount: fileCount ?? package.fileCount,
            totalBytes: totalBytes ?? package.totalBytes,
            restoreBatchID: package.restoreBatchID,
            createdAt: package.createdAt, updatedAt: Date(timeIntervalSince1970: 2),
            restoredAt: package.restoredAt,
            payloadDeletedAt: package.payloadDeletedAt
        )
    }
}
