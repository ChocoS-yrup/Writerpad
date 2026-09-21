import Darwin
import Foundation
import XCTest
import SwiftData
@testable import WriterPad

final class ReceivePromotionTransactionTests: XCTestCase {
    private var roots: [URL] = []
    private let fileManager = FileManager.default
    private let hasher = SHA256ContentHasher()

    override func tearDownWithError() throws {
        for root in roots { try? fileManager.removeItem(at: root) }
        roots = []
    }

    func testSuccessPreservesPayloadAndSecondRunWritesNothing() async throws {
        let harness = makeHarness()
        let first = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "격리검증 편집본"
        )

        XCTAssertFalse(first.wasAlreadyCompleted)
        let projectURL = harness.root.appendingPathComponent("격리검증 편집본")
        XCTAssertEqual(
            try Data(contentsOf: projectURL.appendingPathComponent(
                "집필모드/메인/메모장/저장경계.txt"
            )),
            Data("한글\n마지막 LF\n".utf8)
        )
        let before = try snapshot(harness.root)
        let uuidCount = harness.uuids.count

        let second = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "격리검증 편집본"
        )

        XCTAssertTrue(second.wasAlreadyCompleted)
        XCTAssertEqual(second.transactionID, first.transactionID)
        XCTAssertEqual(harness.uuids.count, uuidCount)
        XCTAssertEqual(try snapshot(harness.root), before)
    }

    func testCompletedReceiptAllowsNormalEditsExpansionAndProjectRename() async throws {
        let harness = makeHarness()
        let first = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "승격 직후 이름"
        )
        let oldURL = harness.root.appendingPathComponent("승격 직후 이름")
        let renamed = first.project.project.renamed(
            to: "사용자가 바꾼 이름",
            at: Date(timeIntervalSince1970: 1_800_000_100)
        )
        try fileManager.moveItem(
            at: oldURL,
            to: harness.root.appendingPathComponent(renamed.name)
        )
        try await harness.metadata.save(renamed)

        for node in try await harness.metadata.documents(in: renamed.id) {
            let changed = DocumentNode(
                id: node.id,
                projectID: node.projectID,
                kind: node.kind,
                parentID: node.parentID,
                relativePath: node.relativePath,
                userOrder: node.userOrder,
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_100),
                contentHash: node.kind == .text
                    ? hasher.sha256(for: Data("사용자 편집".utf8))
                    : nil,
                deletionStatus: node.deletionStatus,
                cursor: node.kind == .text
                    ? TextCursorState(location: 3, selectionLength: 0)
                    : node.cursor,
                isExpanded: node.kind == .folder ? true : node.isExpanded
            )
            try await harness.metadata.save(changed)
        }
        try Data("사용자 편집".utf8).write(
            to: harness.root.appendingPathComponent(
                "사용자가 바꾼 이름/집필모드/메인/메모장/저장경계.txt"
            )
        )
        let beforeReplay = try snapshot(harness.root)
        let uuidCount = harness.uuids.count

        let replay = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "사용하지 않을 새 이름"
        )

        XCTAssertTrue(replay.wasAlreadyCompleted)
        XCTAssertEqual(replay.transactionID, first.transactionID)
        XCTAssertEqual(replay.project.id, first.project.id)
        XCTAssertEqual(replay.project.name, renamed.name)
        XCTAssertEqual(harness.uuids.count, uuidCount)
        XCTAssertEqual(try snapshot(harness.root), beforeReplay)
    }

    func testCompletedReceiptStillFailsClosedWhenMappedDocumentIsMissing() async throws {
        let harness = makeHarness()
        _ = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "문서 누락 차단"
        )
        let promotedDocuments = try await harness.metadata.documents(
            in: (try await harness.metadata.projects()).first!.id
        )
        let mappedDocument = promotedDocuments.first { $0.kind == .text }!
        try await harness.metadata.removeMetadata(id: mappedDocument.id)

        await Self.assertError(.completedPromotionUnavailable) {
            _ = try await harness.transaction.promote(
                from: harness.package.report,
                projectName: "새 작품을 만들면 안 됨"
            )
        }
    }

    func testDanglingReceiptEntriesBlockReplayWithoutWriting() async throws {
        for replaceFolder in [false, true] {
            let harness = makeHarness()
            _ = try await harness.transaction.promote(
                from: harness.package.report, projectName: "완료된 작품"
            )
            let before = try snapshot(harness.root)
            let uuidCount = harness.uuids.count
            let folder = harness.root.appendingPathComponent(".writerpad-promotion-receipts")
            let receipt = folder.appendingPathComponent(harness.package.report.sourceKey.rawValue + ".json")
            let entry = replaceFolder ? folder : receipt
            let retained = harness.root.deletingLastPathComponent().appendingPathComponent("retained")
            let missing = harness.root.deletingLastPathComponent().appendingPathComponent("missing")
            try fileManager.moveItem(at: entry, to: retained)
            try fileManager.createSymbolicLink(at: entry, withDestinationURL: missing)

            await Self.assertError(.recoveryRequired(receipt.path)) {
                _ = try await harness.transaction.promote(
                    from: harness.package.report, projectName: "중복 작품 금지"
                )
            }
            XCTAssertEqual(harness.uuids.count, uuidCount)
            XCTAssertEqual(try? fileManager.destinationOfSymbolicLink(atPath: entry.path), missing.path)
            let projects = try await harness.metadata.projects()
            XCTAssertEqual(projects.count, 1)
            // Restore the test fixture only after checking the link was preserved.
            try fileManager.removeItem(at: entry)
            try fileManager.moveItem(at: retained, to: entry)
            XCTAssertEqual(try snapshot(harness.root), before)
        }
    }

    func testFIFOReceiptIsRejectedWithoutWaitingForAWriter() async throws {
        let harness = makeHarness()
        _ = try await harness.transaction.promote(
            from: harness.package.report, projectName: "특수 파일 차단"
        )
        let receipt = harness.root.appendingPathComponent(
            ".writerpad-promotion-receipts/" + harness.package.report.sourceKey.rawValue + ".json"
        )
        try fileManager.removeItem(at: receipt)
        XCTAssertEqual(mkfifo(receipt.path, 0o600), 0)
        let uuidCount = harness.uuids.count
        await Self.assertError(.recoveryRequired(receipt.path)) {
            _ = try await harness.transaction.promote(
                from: harness.package.report, projectName: "중복 작품 금지"
            )
        }
        XCTAssertEqual(harness.uuids.count, uuidCount)
    }

    func testActualCatalogHidesInterruptedPromotionUntilRecoveryCompletes() async throws {
        for point in [ReceivePromotionFaultPoint.afterMetadataRegistration, .afterPromotion, .afterReceiptWrite] {
            let harness = makeHarness()
            let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
            let repository = SwiftDataMetadataRepository(modelContainer: container)
            let manager = LocalProjectManager(
                projectRepository: repository, creationMetadataStore: repository,
                workspaceStateRepository: repository, pathResolver: harness.resolver, clock: harness.clock
            )
            let existing = try await manager.createProject(named: "기존 작품")
            let transaction = ReceivePromotionTransaction(
                packageReader: harness.materializer, metadataStore: repository, projectPublisher: manager,
                pathResolver: harness.resolver, clock: harness.clock,
                faultPlan: .init(point: point, leavesTransactionForRecovery: true)
            )
            await Self.assertError(.injectedFailure(recoveryPending: true)) {
                _ = try await transaction.promote(from: harness.package.report, projectName: "미완료 승격")
            }
            let stored = try await repository.projects()
            let pending = try XCTUnwrap(stored.first { $0.id != existing.id })
            let visible = try await manager.projects()
            XCTAssertEqual(visible.map(\.id), [existing.id])
            do {
                try await manager.selectProject(id: pending.id)
                XCTFail("Pending promotion must not be selectable")
            } catch let error as ProjectManagerError {
                XCTAssertEqual(error, .missingProject(pending.id))
            }
            do {
                _ = try await manager.renameProject(id: pending.id, to: "아직 변경 금지")
                XCTFail("Pending promotion must not be renamed")
            } catch let error as ProjectManagerError {
                XCTAssertEqual(error, .missingProject(pending.id))
            }
            let recovery = ReceivePromotionTransaction(
                packageReader: harness.materializer, metadataStore: repository, projectPublisher: manager,
                pathResolver: harness.resolver, clock: harness.clock
            )
            try await recovery.recoverPendingPromotions()
            let completed = try await recovery.promote(from: harness.package.report, projectName: "미완료 승격")
            let final = try await manager.projects()
            XCTAssertEqual(Set(final.map(\.id)), Set([existing.id, completed.project.id]))
            XCTAssertEqual(final.count, 2)
            let before = try snapshot(harness.root)
            let replay = try await recovery.promote(from: harness.package.report, projectName: "미완료 승격")
            XCTAssertTrue(replay.wasAlreadyCompleted)
            XCTAssertEqual(try snapshot(harness.root), before)
        }
    }

    func testCatalogSnapshotCannotResurfaceRolledBackPromotion() async throws {
        let harness = makeHarness()
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let gate = ReceivePromotionPausingProjectRepository(repository)
        let manager = LocalProjectManager(
            projectRepository: gate, creationMetadataStore: repository,
            workspaceStateRepository: repository, pathResolver: harness.resolver, clock: harness.clock
        )
        let transaction = ReceivePromotionTransaction(
            packageReader: harness.materializer, metadataStore: repository, projectPublisher: manager,
            pathResolver: harness.resolver, clock: harness.clock,
            faultPlan: .init(point: .afterMetadataRegistration, leavesTransactionForRecovery: true)
        )
        await Self.assertError(.injectedFailure(recoveryPending: true)) {
            _ = try await transaction.promote(from: harness.package.report, projectName: "롤백할 작품")
        }
        await gate.pauseNextProjects()
        let listing = Task { try await manager.projects() }
        await gate.waitForPause()
        try await transaction.recoverPendingPromotions()
        await gate.resume()
        let visible = try await listing.value
        XCTAssertTrue(visible.isEmpty)
        let stored = try await repository.projects()
        XCTAssertTrue(stored.isEmpty)
    }

    func testMalformedPromotionMarkerBlocksCatalogWithoutWriting() async throws {
        let harness = makeHarness()
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let manager = LocalProjectManager(
            projectRepository: repository, creationMetadataStore: repository,
            workspaceStateRepository: repository, pathResolver: harness.resolver, clock: harness.clock
        )
        _ = try await manager.createProject(named: "정상 작품")
        let marker = harness.root.appendingPathComponent(".writerpad-promotion-transaction-" + UUID().uuidString.lowercased() + ".json")
        try Data("{}\n".utf8).write(to: marker)
        let before = try snapshot(harness.root)
        do {
            _ = try await manager.projects()
            XCTFail("Malformed promotion marker must block catalog reconciliation")
        } catch let error as ReceivePromotionTransactionError {
            guard case .recoveryRequired = error else { throw error }
        }
        XCTAssertEqual(try snapshot(harness.root), before)
    }

    func testReorderDoesNotOverwriteConcurrentPromotionCatalogEntry() async throws {
        let harness = makeHarness()
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let gate = ReceivePromotionPausingProjectRepository(repository)
        let manager = LocalProjectManager(
            projectRepository: gate, creationMetadataStore: repository,
            workspaceStateRepository: repository, pathResolver: harness.resolver, clock: harness.clock
        )
        let existing = try await manager.createProject(named: "기존 작품")
        await gate.pauseNextProjects()
        let reorder = Task { try await manager.reorderProjects([existing.id]) }
        await gate.waitForPause()
        let publisher = ReceivePromotionPausingPublisher(manager)
        let transaction = ReceivePromotionTransaction(
            packageReader: harness.materializer, metadataStore: repository, projectPublisher: publisher,
            pathResolver: harness.resolver, clock: harness.clock
        )
        let promotion = Task { try await transaction.promote(from: harness.package.report, projectName: "동시 승격") }
        await publisher.waitForPause()
        let catalog = harness.root.appendingPathComponent(".writerpad-project-catalog.json")
        let reserved = try Data(contentsOf: catalog)
        await gate.resume()
        _ = try await reorder.value
        XCTAssertEqual(try Data(contentsOf: catalog), reserved)
        await publisher.resume()
        let completed = try await promotion.value
        let visible = try await manager.projects()
        XCTAssertEqual(visible.map(\.id), [existing.id, completed.project.id])
    }

    func testConcurrentCatalogReadDoesNotExposePublishedButUncommittedProject() async throws {
        let harness = makeHarness()
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let manager = LocalProjectManager(
            projectRepository: repository, creationMetadataStore: repository,
            workspaceStateRepository: repository, pathResolver: harness.resolver, clock: harness.clock
        )
        let publisher = ReceivePromotionPausingPublisher(manager)
        let transaction = ReceivePromotionTransaction(
            packageReader: harness.materializer, metadataStore: repository, projectPublisher: publisher,
            pathResolver: harness.resolver, clock: harness.clock
        )
        let work = Task { try await transaction.promote(from: harness.package.report, projectName: "공개 직전") }
        await publisher.waitForPause()
        let before = try snapshot(harness.root)
        let visible = try await manager.projects()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(try snapshot(harness.root), before)
        await publisher.resume()
        let result = try await work.value
        let completed = try await manager.projects()
        XCTAssertEqual(completed.map(\.id), [result.project.id])
    }

    @MainActor
    func testSwiftDataOrphansPreserveRollbackEvidence() async throws {
        let harness = makeHarness()
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let transaction = ReceivePromotionTransaction(
            packageReader: harness.materializer, metadataStore: repository,
            projectPublisher: ReceivePromotionRepositoryPublisher(repository),
            pathResolver: harness.resolver, clock: harness.clock,
            faultPlan: .init(point: .afterStaging, leavesTransactionForRecovery: true)
        )
        await Self.assertError(.injectedFailure(recoveryPending: true)) {
            _ = try await transaction.promote(from: harness.package.report, projectName: "고아 기록 보존")
        }
        let marker = harness.root.appendingPathComponent(try XCTUnwrap(markerNames(harness.root).first))
        struct MarkerProject: Decodable { let project: Project }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(MarkerProject.self, from: Data(contentsOf: marker)).project
        let context = ModelContext(container)
        context.insert(DocumentRecord(
            id: UUID(), projectID: project.id.rawValue, kindRawValue: DocumentKind.text.rawValue,
            parentID: nil, relativePath: "고아.txt", userOrder: 0, modifiedAt: harness.clock.now(),
            contentHash: nil, isDeleted: false, originalPath: nil, deletedAt: nil,
            cursorLocation: 0, selectionLength: 0, isExpanded: false
        ))
        try context.save()
        let before = try snapshot(harness.root)
        do {
            try await transaction.recoverPendingPromotions()
            XCTFail("Orphan documents must block rollback")
        } catch let error as ReceivePromotionTransactionError {
            guard case let .recoveryRequired(path) = error else { throw error }
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath(), marker.resolvingSymlinksInPath())
        }
        XCTAssertEqual(try snapshot(harness.root), before)
        let retained = try await repository.hasDocumentsForPromotionRecovery(in: project.id)
        XCTAssertTrue(retained)
    }

    func testSwiftDataImportRejectsExistingDocumentIdentity() async throws {
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let original = Project(id: .init(rawValue: UUID()), name: "기존 작품", createdAt: date, modifiedAt: date)
        let incoming = Project(id: .init(rawValue: UUID()), name: "새 작품", createdAt: date, modifiedAt: date)
        let id = DocumentID(rawValue: UUID())
        func document(in project: Project, name: String) -> DocumentNode {
            DocumentNode(id: id, projectID: project.id, kind: .text, parentID: nil,
                         relativePath: .init(rawValue: name), userOrder: 0,
                         modifiedAt: date, contentHash: nil)
        }
        let originalDocument = document(in: original, name: "보존.txt")
        try await repository.registerImportedProject(original, documents: [originalDocument])
        do {
            try await repository.registerImportedProject(incoming, documents: [document(in: incoming, name: "덮어쓰기.txt")])
            XCTFail("Existing document identity must not be upserted into another project")
        } catch let error as MetadataRepositoryError {
            guard case .corruptedRecord(entity: "DocumentRecord", identifier: _, reason: _) = error else { throw error }
        }
        let preserved = try await repository.document(id: id)
        let projects = try await repository.projects()
        XCTAssertEqual(preserved, originalDocument)
        XCTAssertEqual(projects, [original])
    }

    func testSwiftDataRollbackBeforeRegistrationCanRetry() async throws {
        for point in [ReceivePromotionFaultPoint.afterMarkerWrite, .afterStaging] {
            let harness = makeHarness()
            let store = harness.root.deletingLastPathComponent().appendingPathComponent("metadata.sqlite")
            try fileManager.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Each phase uses a fresh ModelContainer against the same on-disk store.
            do {
                let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: store)
                let repository = SwiftDataMetadataRepository(modelContainer: container)
                let transaction = ReceivePromotionTransaction(
                    packageReader: harness.materializer, metadataStore: repository,
                    projectPublisher: ReceivePromotionRepositoryPublisher(repository),
                    pathResolver: harness.resolver, clock: harness.clock,
                    faultPlan: .init(point: point, leavesTransactionForRecovery: true)
                )
                await Self.assertError(.injectedFailure(recoveryPending: true)) {
                    _ = try await transaction.promote(from: harness.package.report, projectName: "등록 전 복구")
                }
            }
            let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: store)
            let repository = SwiftDataMetadataRepository(modelContainer: container)
            let recovery = ReceivePromotionTransaction(
                packageReader: harness.materializer, metadataStore: repository,
                projectPublisher: ReceivePromotionRepositoryPublisher(repository),
                pathResolver: harness.resolver, clock: harness.clock
            )
            try await recovery.recoverPendingPromotions()
            XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: harness.root.path), [])
            let projects = try await repository.projects()
            XCTAssertTrue(projects.isEmpty)
            let result = try await recovery.promote(from: harness.package.report, projectName: "등록 전 복구")
            XCTAssertFalse(result.wasAlreadyCompleted)
        }
    }

    func testSwiftDataRecoveryAfterRegistrationAndPublication() async throws {
        for point in [ReceivePromotionFaultPoint.afterMetadataRegistration, .afterPromotion, .afterReceiptWrite] {
            let harness = makeHarness(timestamp: 1_800_000_000.253024)
            let store = harness.root.deletingLastPathComponent().appendingPathComponent("metadata.sqlite")
            try fileManager.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: store)
                let repository = SwiftDataMetadataRepository(modelContainer: container)
                let transaction = ReceivePromotionTransaction(
                    packageReader: harness.materializer, metadataStore: repository,
                    projectPublisher: ReceivePromotionRepositoryPublisher(repository),
                    pathResolver: harness.resolver, clock: harness.clock,
                    faultPlan: .init(point: point, leavesTransactionForRecovery: true)
                )
                await Self.assertError(.injectedFailure(recoveryPending: true)) {
                    _ = try await transaction.promote(from: harness.package.report, projectName: "영속화 복구")
                }
            }
            let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: store)
            let repository = SwiftDataMetadataRepository(modelContainer: container)
            let recovery = ReceivePromotionTransaction(
                packageReader: harness.materializer, metadataStore: repository,
                projectPublisher: ReceivePromotionRepositoryPublisher(repository),
                pathResolver: harness.resolver, clock: harness.clock
            )
            try await recovery.recoverPendingPromotions()
            let result = try await recovery.promote(from: harness.package.report, projectName: "영속화 복구")
            XCTAssertEqual(result.wasAlreadyCompleted, point != .afterMetadataRegistration)
            let projects = try await repository.projects()
            XCTAssertEqual(projects.count, 1)
            let nodes = try await repository.documents(in: result.project.id)
            XCTAssertEqual(nodes.filter { $0.kind == .text }.count, 2)
            let before = try snapshot(harness.root)
            let replay = try await recovery.promote(from: harness.package.report, projectName: "영속화 복구")
            XCTAssertTrue(replay.wasAlreadyCompleted)
            XCTAssertEqual(try snapshot(harness.root), before)
        }
    }

    func testChangedPackageFailsBeforeFirstWrite() async throws {
        let harness = makeHarness()
        let inspected = harness.package.report
        await harness.materializer.set(makePackage(fingerprint: "c"))

        await Self.assertError(.sourceChangedAfterInspection) {
            _ = try await harness.transaction.promote(
                from: inspected,
                projectName: "변경 차단"
            )
        }
        XCTAssertFalse(fileManager.fileExists(atPath: harness.root.path))
    }

    func testExistingProjectNameFailsBeforeFirstWrite() async throws {
        let harness = makeHarness()
        let existing = Project(
            id: ProjectID(rawValue: UUID()),
            name: "이미 있는 작품",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await harness.metadata.save(existing)

        await Self.assertError(.duplicateProject(existing.name)) {
            _ = try await harness.transaction.promote(
                from: harness.package.report,
                projectName: existing.name
            )
        }

        XCTAssertFalse(fileManager.fileExists(atPath: harness.root.path))
        let projects = try await harness.metadata.projects()
        XCTAssertEqual(projects, [existing])
    }

    func testStagingAndMetadataFailuresRollbackOnlyNewTransaction() async throws {
        for point in [ReceivePromotionFaultPoint.afterStaging, .afterMetadataRegistration] {
            let harness = makeHarness(fault: .init(
                point: point,
                leavesTransactionForRecovery: false
            ))
            await Self.assertError(.injectedFailure(recoveryPending: false)) {
                _ = try await harness.transaction.promote(
                    from: harness.package.report,
                    projectName: "롤백 작품"
                )
            }
            let projects = try await harness.metadata.projects()
            XCTAssertTrue(projects.isEmpty)
            XCTAssertEqual(
                fileManager.fileExists(atPath: harness.root.path)
                    ? try fileManager.contentsOfDirectory(atPath: harness.root.path) : [],
                []
            )
        }
    }

    func testPostMoveRecoveryCompletesReceiptAndBlocksDuplicate() async throws {
        let harness = makeHarness(fault: .init(
            point: .afterPromotion,
            leavesTransactionForRecovery: true
        ))
        await Self.assertError(.injectedFailure(recoveryPending: true)) {
            _ = try await harness.transaction.promote(
                from: harness.package.report,
                projectName: "복구 작품"
            )
        }
        let recovery = makeRecovery(harness)

        try await recovery.recoverPendingPromotions()
        let result = try await recovery.promote(
            from: harness.package.report,
            projectName: "복구 작품"
        )

        XCTAssertTrue(result.wasAlreadyCompleted)
        XCTAssertTrue(try markerNames(harness.root).isEmpty)
    }

    func testFractionalClockRecoversEveryDurablePhase() async throws {
        for point in [ReceivePromotionFaultPoint.afterMetadataRegistration,
                      .afterPromotion, .afterReceiptWrite] {
            let harness = makeHarness(
                fault: .init(point: point, leavesTransactionForRecovery: true),
                timestamp: 1_800_000_000.253024
            )
            await Self.assertError(.injectedFailure(recoveryPending: true)) {
                _ = try await harness.transaction.promote(
                    from: harness.package.report, projectName: "소수점 시각 복구"
                )
            }
            let recovery = makeRecovery(harness)
            try await recovery.recoverPendingPromotions()
            XCTAssertTrue(try markerNames(harness.root).isEmpty)
            let result = try await recovery.promote(
                from: harness.package.report, projectName: "소수점 시각 복구"
            )
            XCTAssertEqual(result.wasAlreadyCompleted, point != .afterMetadataRegistration)
            let before = try snapshot(harness.root)
            _ = try await recovery.promote(
                from: harness.package.report, projectName: "소수점 시각 복구"
            )
            XCTAssertEqual(try snapshot(harness.root), before)
        }
    }

    func testRollbackMetadataMismatchPreservesStagingAndMarker() async throws {
        let harness = makeHarness(fault: .init(
            point: .afterMetadataRegistration, leavesTransactionForRecovery: true
        ))
        await Self.assertError(.injectedFailure(recoveryPending: true)) {
            _ = try await harness.transaction.promote(
                from: harness.package.report, projectName: "복구 자료 보존"
            )
        }
        let project = try await harness.metadata.projects().first!
        let changed = project.renamed(to: "다른 메타데이터", at: harness.clock.now())
        try await harness.metadata.save(changed)
        let before = try snapshot(harness.root)
        XCTAssertTrue(before.keys.contains { $0.hasSuffix("저장경계.txt") })
        do {
            try await makeRecovery(harness).recoverPendingPromotions()
            XCTFail("Metadata mismatch must block rollback")
        } catch let error as ReceivePromotionTransactionError {
            guard case .recoveryRequired = error else { throw error }
        }
        XCTAssertEqual(try snapshot(harness.root), before)
        let retained = try await harness.metadata.project(id: project.id)
        XCTAssertEqual(retained, changed)
    }

    func testConcurrentRecoveryCannotDeleteActiveStaging() async throws {
        let harness = makeHarness()
        await harness.metadata.pauseNextRegistration()
        let promotion = Task {
            try await harness.transaction.promote(
                from: harness.package.report, projectName: "진행 중 거래"
            )
        }
        await harness.metadata.waitForRegistrationPause()
        let before = try snapshot(harness.root)
        do {
            try await harness.transaction.recoverPendingPromotions()
            XCTFail("Recovery must reject an active transaction")
        } catch {
            XCTAssertEqual(error as? ReceivePromotionTransactionError, .operationInProgress)
        }
        XCTAssertEqual(try snapshot(harness.root), before)
        do {
            _ = try await harness.transaction.promote(
                from: harness.package.report, projectName: "동시 요청"
            )
            XCTFail("Concurrent promotion must be rejected")
        } catch {
            XCTAssertEqual(error as? ReceivePromotionTransactionError, .operationInProgress)
        }
        XCTAssertEqual(try snapshot(harness.root), before)
        await harness.metadata.resumeRegistration()
        let result = try await promotion.value
        XCTAssertFalse(result.wasAlreadyCompleted)
        let projects = try await harness.metadata.projects()
        XCTAssertEqual(projects.count, 1)
        try await harness.transaction.recoverPendingPromotions()
        let replay = try await harness.transaction.promote(
            from: harness.package.report, projectName: "진행 중 거래"
        )
        XCTAssertTrue(replay.wasAlreadyCompleted)
    }

    func testCorruptPostMoveStateFailsClosedAndPreservesEvidence() async throws {
        let harness = makeHarness(fault: .init(
            point: .afterPromotion,
            leavesTransactionForRecovery: true
        ))
        await Self.assertError(.injectedFailure(recoveryPending: true)) {
            _ = try await harness.transaction.promote(
                from: harness.package.report,
                projectName: "손상 작품"
            )
        }
        try Data("손상".utf8).write(
            to: harness.root.appendingPathComponent(
                "손상 작품/집필모드/메인/메모장/저장경계.txt"
            )
        )

        do {
            try await makeRecovery(harness).recoverPendingPromotions()
            XCTFail("손상된 완료 후보를 수용했습니다.")
        } catch ReceivePromotionTransactionError.recoveryRequired(_) {
            XCTAssertFalse(try markerNames(harness.root).isEmpty)
            XCTAssertTrue(fileManager.fileExists(
                atPath: harness.root.appendingPathComponent("손상 작품").path
            ))
        } catch {
            XCTFail("예상하지 않은 오류: \(error)")
        }
    }

    func testSameSourceDifferentFingerprintIsBlocked() async throws {
        let harness = makeHarness()
        _ = try await harness.transaction.promote(
            from: harness.package.report,
            projectName: "중복 작품"
        )
        let changed = makePackage(
            packageID: UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!,
            localID: harness.package.report.sourceLocalID,
            runID: harness.package.report.sourceRunID,
            fingerprint: "d"
        )
        await harness.materializer.set(changed)

        await Self.assertError(.sourceAlreadyPromoted) {
            _ = try await harness.transaction.promote(
                from: changed.report,
                projectName: "다른 이름"
            )
        }
    }

    func testSharedProducerFixturePromotesThroughRealReader() async throws {
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "promotion-bridge-test-" + UUID().uuidString
        )
        roots.append(parent)
        let resolver = ProjectPathResolver(
            projectsRootURL: parent.appendingPathComponent("Documents")
        )
        let metadata = ReceivePromotionMemoryMetadata()
        let publisher = ReceivePromotionMemoryPublisher(metadata)
        let reader = ReceivePromotionPackageReader()
        let transaction = ReceivePromotionTransaction(
            packageReader: reader,
            metadataStore: metadata,
            projectPublisher: publisher,
            pathResolver: resolver,
            clock: ReceivePromotionFixedClock(
                value: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        let fixture = sharedBridgeFixture()
        let report = try await reader.inspect(fixture)

        let result = try await transaction.promote(
            from: report,
            projectName: "공유 fixture 편집본"
        )

        XCTAssertFalse(result.wasAlreadyCompleted)
        XCTAssertEqual(result.documentMappings.count, 2)
        XCTAssertEqual(
            try Data(contentsOf: resolver.projectsRootURL.appendingPathComponent(
                "공유 fixture 편집본/집필모드/메인/메모장/저장경계.txt"
            )),
            Data("한글\n마지막 LF\n".utf8)
        )
    }
}

private extension ReceivePromotionTransactionTests {
    struct Harness {
        let root: URL
        let resolver: ProjectPathResolver
        let package: ReceivePromotionValidatedPackage
        let materializer: ReceivePromotionMutableMaterializer
        let metadata: ReceivePromotionMemoryMetadata
        let publisher: ReceivePromotionMemoryPublisher
        let uuids: ReceivePromotionSequenceUUIDGenerator
        let clock: ReceivePromotionFixedClock
        let transaction: ReceivePromotionTransaction
    }

    func makeHarness(
        fault: ReceivePromotionFaultPlan? = nil,
        timestamp: TimeInterval = 1_800_000_000
    ) -> Harness {
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "promotion-transaction-test-" + UUID().uuidString
        )
        roots.append(parent)
        let root = parent.appendingPathComponent("Documents")
        let resolver = ProjectPathResolver(projectsRootURL: root)
        let package = makePackage()
        let materializer = ReceivePromotionMutableMaterializer(package)
        let metadata = ReceivePromotionMemoryMetadata()
        let publisher = ReceivePromotionMemoryPublisher(metadata)
        let uuids = ReceivePromotionSequenceUUIDGenerator()
        let clock = ReceivePromotionFixedClock(
            value: Date(timeIntervalSince1970: timestamp)
        )
        return Harness(
            root: root,
            resolver: resolver,
            package: package,
            materializer: materializer,
            metadata: metadata,
            publisher: publisher,
            uuids: uuids,
            clock: clock,
            transaction: ReceivePromotionTransaction(
                packageReader: materializer,
                metadataStore: metadata,
                projectPublisher: publisher,
                pathResolver: resolver,
                clock: clock,
                uuidGenerator: uuids,
                faultPlan: fault
            )
        )
    }

    func makeRecovery(_ harness: Harness) -> ReceivePromotionTransaction {
        ReceivePromotionTransaction(
            packageReader: harness.materializer,
            metadataStore: harness.metadata,
            projectPublisher: harness.publisher,
            pathResolver: harness.resolver,
            clock: harness.clock,
            uuidGenerator: harness.uuids
        )
    }

    func makePackage(
        packageID: UUID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
        localID: UUID = UUID(uuidString: "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")!,
        runID: UUID = UUID(uuidString: "cccccccc-1111-4222-8333-dddddddddddd")!,
        fingerprint: Character = "b"
    ) -> ReceivePromotionValidatedPackage {
        let bodies = [Data(), Data("한글\n마지막 LF\n".utf8)]
        let ids = [
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        ]
        let names = ["빈문서.txt", "저장경계.txt"]
        let reviews = ids.indices.map { index in
            ReceivePromotionDocumentReview(
                sourceDocumentID: ids[index],
                sourceName: names[index],
                sourceBodyHash: ContentHash(
                    rawValue: String(repeating: index == 0 ? "1" : "2", count: 64)
                )!,
                editableRevision: index,
                editableBodyHash: hasher.sha256(for: bodies[index]),
                byteCount: bodies[index].count,
                payloadPath: RelativeDocumentPath(
                    rawValue: String(format: "payload/%04d.txt", index + 1)
                )
            )
        }
        let report = ReceivePromotionReport(
            sourceSelectionURL: URL(fileURLWithPath: "/unused/source.writerpadpromotion"),
            packageID: packageID,
            producerBundleID: "com.chocos.writerpad.receiveboundary",
            sourceLocalID: localID,
            sourceRunID: runID,
            sourceFolderName: "격리검증",
            editableIdentityHash: ContentHash(rawValue: String(repeating: "a", count: 64))!,
            editableWorkspaceHash: ContentHash(rawValue: String(repeating: "9", count: 64))!,
            sourceKey: hasher.sha256(for: Data("stable-source".utf8)),
            packageFingerprint: ContentHash(
                rawValue: String(repeating: String(fingerprint), count: 64)
            )!,
            suggestedProjectName: "격리검증 편집본",
            documents: reviews
        )
        return ReceivePromotionValidatedPackage(
            report: report,
            documents: reviews.indices.map { .init(review: reviews[$0], data: bodies[$0]) }
        )
    }

    static func assertError(
        _ expected: ReceivePromotionTransactionError,
        operation: @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ReceivePromotionTransactionError, expected)
        }
    }

    func snapshot(_ root: URL) throws -> [String: Data] {
        guard fileManager.fileExists(atPath: root.path) else { return [:] }
        var result: [String: Data] = [:]
        for subpath in try fileManager.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(subpath)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[subpath.precomposedStringWithCanonicalMapping] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func markerNames(_ root: URL) throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(atPath: root.path).filter {
            $0.hasPrefix(".writerpad-promotion-transaction-")
        }
    }

    func sharedBridgeFixture() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "TestFixtures/ReceivePromotionBridge.writerpadpromotion",
                isDirectory: true
            )
    }
}

private struct ReceivePromotionFixedClock: AppClock {
    let value: Date
    func now() -> Date { value }
}

private final class ReceivePromotionSequenceUUIDGenerator: UUIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 1

    func makeUUID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let suffix = String(format: "%012llx", next)
        next += 1
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return next - 1
    }
}

private actor ReceivePromotionMutableMaterializer: ReceivePromotionPackageMaterializing {
    private var package: ReceivePromotionValidatedPackage

    init(_ package: ReceivePromotionValidatedPackage) { self.package = package }
    func set(_ value: ReceivePromotionValidatedPackage) { package = value }
    func inspect(_ packageURL: URL) async throws -> ReceivePromotionReport { package.report }
    func materialize(_ packageURL: URL) async throws -> ReceivePromotionValidatedPackage { package }
}

private actor ReceivePromotionMemoryMetadata: ReceivePromotionMetadataStoring {
    private var projectValues: [ProjectID: Project] = [:]
    private var documentValues: [ProjectID: [DocumentNode]] = [:]
    private var shouldPauseRegistration = false
    private var registrationContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiter: CheckedContinuation<Void, Never>?

    func pauseNextRegistration() { shouldPauseRegistration = true }
    func waitForRegistrationPause() async {
        if registrationContinuation != nil { return }
        await withCheckedContinuation { pauseWaiter = $0 }
    }
    func resumeRegistration() {
        registrationContinuation?.resume()
        registrationContinuation = nil
    }

    func projects() async throws -> [Project] { Array(projectValues.values) }
    func project(id: ProjectID) async throws -> Project? { projectValues[id] }
    func save(_ project: Project) async throws { projectValues[project.id] = project }
    func remove(id: ProjectID) async throws {
        projectValues.removeValue(forKey: id)
        documentValues.removeValue(forKey: id)
    }
    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        guard projectValues[projectID] != nil else {
            throw MetadataRepositoryError.missingProject(projectID)
        }
        return documentValues[projectID] ?? []
    }
    func hasDocumentsForPromotionRecovery(in projectID: ProjectID) async throws -> Bool {
        !(documentValues[projectID] ?? []).isEmpty
    }
    func document(id: DocumentID) async throws -> DocumentNode? {
        documentValues.values.flatMap { $0 }.first { $0.id == id }
    }
    func save(_ document: DocumentNode) async throws {
        var values = documentValues[document.projectID] ?? []
        values.removeAll { $0.id == document.id }
        values.append(document)
        documentValues[document.projectID] = values
    }
    func removeMetadata(id: DocumentID) async throws {
        for key in documentValues.keys {
            documentValues[key]?.removeAll { $0.id == id }
        }
    }
    func registerImportedProject(
        _ project: Project,
        documents: [DocumentNode]
    ) async throws {
        if shouldPauseRegistration {
            shouldPauseRegistration = false
            await withCheckedContinuation {
                registrationContinuation = $0
                pauseWaiter?.resume()
                pauseWaiter = nil
            }
        }
        projectValues[project.id] = project
        documentValues[project.id] = documents
    }
}

private actor ReceivePromotionMemoryPublisher: ReceivePromotionProjectPublishing {
    private let metadata: ReceivePromotionMemoryMetadata

    init(_ metadata: ReceivePromotionMemoryMetadata) { self.metadata = metadata }

    func publishPromotedProject(_ project: Project) async throws -> ManagedProject {
        guard try await metadata.project(id: project.id) == project else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        return ManagedProject(project: project, userOrder: 0, lifecycleState: .active)
    }
}

private struct ReceivePromotionRepositoryPublisher: ReceivePromotionProjectPublishing {
    let repository: any ReceivePromotionMetadataStoring
    init(_ repository: any ReceivePromotionMetadataStoring) { self.repository = repository }
    func publishPromotedProject(_ project: Project) async throws -> ManagedProject {
        guard try await repository.project(id: project.id) == project else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        return ManagedProject(project: project, userOrder: 0, lifecycleState: .active)
    }
}

private actor ReceivePromotionPausingPublisher: ReceivePromotionProjectPublishing {
    let manager: LocalProjectManager
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ manager: LocalProjectManager) { self.manager = manager }
    func publishPromotedProject(_ project: Project) async throws -> ManagedProject {
        let result = try await manager.publishPromotedProject(project)
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
        return result
    }
    func waitForPause() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ReceivePromotionPausingProjectRepository: ProjectRepository {
    let repository: SwiftDataMetadataRepository
    private var pauseNext = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ repository: SwiftDataMetadataRepository) { self.repository = repository }
    func pauseNextProjects() { pauseNext = true }
    func projects() async throws -> [Project] {
        let values = try await repository.projects()
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation {
                continuation = $0
                waiter?.resume()
                waiter = nil
            }
        }
        return values
    }
    func project(id: ProjectID) async throws -> Project? { try await repository.project(id: id) }
    func save(_ project: Project) async throws { try await repository.save(project) }
    func remove(id: ProjectID) async throws { try await repository.remove(id: id) }
    func waitForPause() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
