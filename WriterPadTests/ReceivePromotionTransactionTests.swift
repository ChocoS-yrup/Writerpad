import Foundation
import XCTest
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

        await assertError(.completedPromotionUnavailable) {
            _ = try await harness.transaction.promote(
                from: harness.package.report,
                projectName: "새 작품을 만들면 안 됨"
            )
        }
    }

    func testChangedPackageFailsBeforeFirstWrite() async throws {
        let harness = makeHarness()
        let inspected = harness.package.report
        await harness.materializer.set(makePackage(fingerprint: "c"))

        await assertError(.sourceChangedAfterInspection) {
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

        await assertError(.duplicateProject(existing.name)) {
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
            await assertError(.injectedFailure(recoveryPending: false)) {
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
        await assertError(.injectedFailure(recoveryPending: true)) {
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

    func testCorruptPostMoveStateFailsClosedAndPreservesEvidence() async throws {
        let harness = makeHarness(fault: .init(
            point: .afterPromotion,
            leavesTransactionForRecovery: true
        ))
        await assertError(.injectedFailure(recoveryPending: true)) {
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

        await assertError(.sourceAlreadyPromoted) {
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

    func makeHarness(fault: ReceivePromotionFaultPlan? = nil) -> Harness {
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
            value: Date(timeIntervalSince1970: 1_800_000_000)
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

    func assertError(
        _ expected: ReceivePromotionTransactionError,
        operation: () async throws -> Void
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

    func projects() async throws -> [Project] { Array(projectValues.values) }
    func project(id: ProjectID) async throws -> Project? { projectValues[id] }
    func save(_ project: Project) async throws { projectValues[project.id] = project }
    func remove(id: ProjectID) async throws {
        projectValues.removeValue(forKey: id)
        documentValues.removeValue(forKey: id)
    }
    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        documentValues[projectID] ?? []
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
