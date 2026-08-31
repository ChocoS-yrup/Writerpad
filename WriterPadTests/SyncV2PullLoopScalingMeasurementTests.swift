import Foundation
import SwiftData
import XCTest
@testable import WriterPad

/// 변경이 하나도 없는 정상 pull 한 번의 비용이 문서 수에 따라 어떻게 자라는지
/// 실제 기기에서 기록한다.
///
/// 서버에 접속하지 않는다. transport는 로컬 stub이고 상태 저장소는 모든 문서를
/// "서버와 같은 revision"으로 답한다. 따라서 이 측정에 남는 시간은 전부
/// 클라이언트 쪽 문서 루프 비용이다.
///
/// 평소 회귀 테스트에서는 실행하지 않는다. Test action에
/// `-WriterPadPullLoopMeasurement` 인자가 있을 때만 동작하며, 시뮬레이터는
/// `-WriterPadAllowSimulatorCalibration`이 추가로 필요하다.
final class SyncV2PullLoopScalingMeasurementTests: XCTestCase {
    /// 곡선을 보려면 최소 세 점이 필요하다. 선형이면 문서당 시간이 일정하고,
    /// O(N²)이면 문서당 시간이 N에 비례해 늘어난다.
    private static let documentCounts = [100, 300, 600, 1_000]

    /// 실측 기준선 fixture의 화당 본문 크기와 맞춘다.
    private static let charactersPerDocument = 6_000

    func testSteadyStatePullLoopScaling() async throws {
        try requireExplicitMeasurementRun()

        var samples: [Sample] = []
        for documentCount in Self.documentCounts {
            samples.append(
                try await measureSteadyStatePull(
                    documentCount: documentCount
                )
            )
        }

        report(samples)
    }

    // MARK: - 한 번의 측정

    private func measureSteadyStatePull(
        documentCount: Int
    ) async throws -> Sample {
        let fixture = try await Fixture.make(
            documentCount: documentCount,
            charactersPerDocument: Self.charactersPerDocument
        )
        let root = fixture.root
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        await fixture.repositorySpy.resetCounts()

        let recorder = SyncV2PullDiagnosticRecorder()
        let context = SyncV2PullDiagnosticContext(
            origin: "pull-loop-scaling",
            recorder: recorder
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        let report = try await SyncV2PullDiagnostics.withContext(context) {
            try await fixture.service.pull(
                localProjectID: fixture.projectID,
                serverProjectID: fixture.serverProjectID
            )
        }
        let wallMilliseconds =
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

        // 측정하려던 경로를 실제로 지났는지 확인한다. 하나라도 적용이나
        // 병합으로 빠졌다면 "변경 없는 pull"이 아니므로 수치를 못 믿는다.
        let upToDateCount = report.outcomes.filter {
            if case .upToDate = $0 { return true }
            return false
        }.count
        XCTAssertEqual(
            upToDateCount,
            documentCount,
            "문서 \(documentCount)개가 모두 upToDate여야 정상 pull 측정이다."
        )
        XCTAssertTrue(
            report.appliedSnapshots.isEmpty,
            "변경 없는 pull에서 적용된 문서가 있으면 안 된다."
        )

        let counts = await fixture.repositorySpy.counts()
        let events = recorder.events()

        return Sample(
            documentCount: documentCount,
            wallMilliseconds: wallMilliseconds,
            identityLookupMilliseconds: Self.value(
                in: events,
                stage: "document-loop-breakdown",
                phase: "identity-lookup"
            ),
            processAfterStateLookupMilliseconds: Self.value(
                in: events,
                stage: "document-loop-breakdown",
                phase: "process-after-state-lookup"
            ),
            stateStoreLookupMilliseconds: Self.value(
                in: events,
                stage: "document-loop-breakdown",
                phase: "state-store-lookup"
            ),
            mutationGateWaitMilliseconds: Self.value(
                in: events,
                stage: "document-loop-breakdown",
                phase: "mutation-gate-wait"
            ),
            documentLoopMilliseconds: Self.duration(
                in: events,
                stage: "document-local-compare-apply",
                phase: "finished"
            ),
            identityAuditMilliseconds: Self.duration(
                in: events,
                stage: "identity-audit",
                phase: "finished"
            ),
            serviceMilliseconds: Self.duration(
                in: events,
                stage: "snapshot-service",
                phase: "finished"
            ),
            documentsInProjectCalls: counts.documentsInProject,
            documentByIDCalls: counts.documentByID,
            hasDiagnostics: !events.isEmpty
        )
    }

    // MARK: - 보고

    private func report(_ samples: [Sample]) {
        var lines: [String] = []
        lines.append(
            "| 문서 수 | 전체 pull | 문서 루프 | identity-lookup"
                + " | process-after-state-lookup | documents(in:) 호출"
                + " | document(id:) 호출 | 문서당 |"
        )
        lines.append(
            "|---:|---:|---:|---:|---:|---:|---:|---:|"
        )
        for sample in samples {
            lines.append(
                "| \(sample.documentCount)"
                    + " | \(Self.milliseconds(sample.wallMilliseconds))"
                    + " | \(Self.milliseconds(sample.documentLoopMilliseconds))"
                    + " | \(Self.milliseconds(sample.identityLookupMilliseconds))"
                    + " | \(Self.milliseconds(sample.processAfterStateLookupMilliseconds))"
                    + " | \(sample.documentsInProjectCalls)"
                    + " | \(sample.documentByIDCalls)"
                    + " | \(Self.milliseconds(sample.millisecondsPerDocument)) |"
            )
        }

        if let first = samples.first, let last = samples.last,
           first.documentCount != last.documentCount,
           first.millisecondsPerDocument > 0 {
            let sizeRatio =
                Double(last.documentCount) / Double(first.documentCount)
            let perDocumentRatio =
                last.millisecondsPerDocument / first.millisecondsPerDocument
            lines.append("")
            lines.append(
                "문서 수 \(Self.ratio(sizeRatio))배일 때 문서당 시간"
                    + " \(Self.ratio(perDocumentRatio))배."
                    + " 선형이면 1배에 가깝고, O(N²)이면 문서 수 배율에 가깝다."
            )
        }

        if samples.contains(where: { !$0.hasDiagnostics }) {
            lines.append("")
            lines.append(
                "주의: SyncV2PullDiagnostics 이벤트가 비었다."
                    + " Debug 구성으로 실행해야 단계별 수치가 남는다."
            )
        }

        let table = lines.joined(separator: "\n")
        print("WRITERPAD_PULL_LOOP_SCALING_BEGIN")
        print(table)
        if let json = Self.json(for: samples) {
            print(json)
            let attachment = XCTAttachment(string: json)
            attachment.name = "WriterPad-PullLoopScaling.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        print("WRITERPAD_PULL_LOOP_SCALING_END")

        let tableAttachment = XCTAttachment(string: table)
        tableAttachment.name = "WriterPad-PullLoopScaling.md"
        tableAttachment.lifetime = .keepAlways
        add(tableAttachment)
    }

    private static func json(for samples: [Sample]) -> String? {
        let payload: [String: Any] = [
            "measurement": "sync-v2-steady-state-pull-loop",
            "charactersPerDocument": charactersPerDocument,
            "samples": samples.map { $0.dictionary },
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func value(
        in events: [SyncV2PullDiagnosticEvent],
        stage: String,
        phase: String
    ) -> Double {
        events.first { $0.stage == stage && $0.phase == phase }?
            .valueMilliseconds ?? 0
    }

    private static func duration(
        in events: [SyncV2PullDiagnosticEvent],
        stage: String,
        phase: String
    ) -> Double {
        events.first { $0.stage == stage && $0.phase == phase }?
            .durationMilliseconds ?? 0
    }

    private static func milliseconds(_ value: Double) -> String {
        String(format: "%.2fms", value)
    }

    private static func ratio(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func requireExplicitMeasurementRun() throws {
        let process = ProcessInfo.processInfo
        let requested =
            process.arguments.contains("-WriterPadPullLoopMeasurement")
            || process.environment["WRITERPAD_RUN_PULL_LOOP_MEASUREMENT"]
                == "1"
        guard requested else {
            throw XCTSkip(
                "pull 루프 확장성 측정은 실제 기기에서 명시적으로 실행한다."
            )
        }

        #if targetEnvironment(simulator)
        let allowsCalibration =
            process.arguments.contains("-WriterPadAllowSimulatorCalibration")
            || process.environment["WRITERPAD_ALLOW_SIMULATOR_CALIBRATION"]
                == "1"
        guard allowsCalibration else {
            throw XCTSkip(
                "시뮬레이터 수치는 실제 iPad 측정값으로 기록하지 않는다."
            )
        }
        #endif
    }

    // MARK: - 표본

    private struct Sample: Sendable {
        let documentCount: Int
        let wallMilliseconds: Double
        let identityLookupMilliseconds: Double
        let processAfterStateLookupMilliseconds: Double
        let stateStoreLookupMilliseconds: Double
        let mutationGateWaitMilliseconds: Double
        let documentLoopMilliseconds: Double
        let identityAuditMilliseconds: Double
        let serviceMilliseconds: Double
        let documentsInProjectCalls: Int
        let documentByIDCalls: Int
        let hasDiagnostics: Bool

        var millisecondsPerDocument: Double {
            documentCount == 0
                ? 0
                : wallMilliseconds / Double(documentCount)
        }

        var dictionary: [String: Any] {
            [
                "documentCount": documentCount,
                "wallMilliseconds": wallMilliseconds,
                "millisecondsPerDocument": millisecondsPerDocument,
                "identityLookupMilliseconds": identityLookupMilliseconds,
                "processAfterStateLookupMilliseconds":
                    processAfterStateLookupMilliseconds,
                "stateStoreLookupMilliseconds": stateStoreLookupMilliseconds,
                "mutationGateWaitMilliseconds": mutationGateWaitMilliseconds,
                "documentLoopMilliseconds": documentLoopMilliseconds,
                "identityAuditMilliseconds": identityAuditMilliseconds,
                "serviceMilliseconds": serviceMilliseconds,
                "documentsInProjectCalls": documentsInProjectCalls,
                "documentByIDCalls": documentByIDCalls,
                "hasDiagnostics": hasDiagnostics,
            ]
        }
    }

    // MARK: - fixture

    private struct Fixture {
        let root: URL
        let projectID: ProjectID
        let serverProjectID: UUID
        let service: SyncV2SnapshotPullService
        let repositorySpy: CountingDocumentRepository

        static func make(
            documentCount: Int,
            charactersPerDocument: Int
        ) async throws -> Fixture {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "writerpad-pull-scaling-"
                        + UUID().uuidString.lowercased(),
                    isDirectory: true
                )
            let workspaceRoot = root
                .appendingPathComponent("작품", isDirectory: true)
            let volumeRoot = workspaceRoot
                .appendingPathComponent("메인", isDirectory: true)
                .appendingPathComponent("원고", isDirectory: true)
                .appendingPathComponent("1권", isDirectory: true)
            try fileManager.createDirectory(
                at: volumeRoot,
                withIntermediateDirectories: true
            )

            // 실제 앱과 같은 디스크 저장소를 쓴다. 메모리 전용 컨테이너는
            // SwiftData 조회 비용을 실제보다 낮게 보이게 한다.
            let container = try WriterPadMetadataStore.makeContainer(
                isStoredInMemoryOnly: false,
                storeURL: root.appendingPathComponent("metadata.store")
            )
            let repository = SwiftDataMetadataRepository(
                modelContainer: container
            )

            let projectID = ProjectID(rawValue: UUID())
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try await repository.save(
                Project(
                    id: projectID,
                    name: "pull 루프 측정",
                    createdAt: now,
                    modifiedAt: now
                )
            )

            var parentID: DocumentID?
            for path in ["메인", "메인/원고", "메인/원고/1권"] {
                let folderID = DocumentID(rawValue: UUID())
                try await repository.save(
                    DocumentNode(
                        id: folderID,
                        projectID: projectID,
                        kind: .folder,
                        parentID: parentID,
                        relativePath: RelativeDocumentPath(rawValue: path),
                        userOrder: 0,
                        modifiedAt: now,
                        contentHash: nil
                    )
                )
                parentID = folderID
            }

            let hasher = SHA256ContentHasher()
            let body = String(
                repeating: "가",
                count: charactersPerDocument
            )
            let data = Data(body.utf8)
            let contentHash = hasher.sha256(for: data)

            var snapshots: [SyncV2RemoteDocumentSnapshot] = []
            var states: [UUID: SyncV2SnapshotLocalState] = [:]
            snapshots.reserveCapacity(documentCount)
            states.reserveCapacity(documentCount)

            for index in 0..<documentCount {
                let documentID = DocumentID(rawValue: UUID())
                let name = String(format: "%04d.txt", index + 1)
                let relativePath = "메인/원고/1권/" + name
                try await repository.save(
                    DocumentNode(
                        id: documentID,
                        projectID: projectID,
                        kind: .text,
                        parentID: parentID,
                        relativePath: RelativeDocumentPath(
                            rawValue: relativePath
                        ),
                        userOrder: index,
                        modifiedAt: now,
                        contentHash: contentHash
                    )
                )
                try data.write(
                    to: volumeRoot.appendingPathComponent(name),
                    options: [.atomic]
                )
                snapshots.append(
                    SyncV2RemoteDocumentSnapshot(
                        documentID: documentID.rawValue,
                        relativePath: relativePath,
                        content: body,
                        revision: 7,
                        isDeleted: false,
                        deletedAt: nil,
                        updatedAt: now
                    )
                )
                states[documentID.rawValue] = SyncV2SnapshotLocalState(
                    serverRevision: 7,
                    serverPath: relativePath,
                    hasActiveOperation: false,
                    hasUnresolvedConflict: false,
                    blockingErrorCode: nil
                )
            }

            let spy = CountingDocumentRepository(base: repository)
            let locator = FixedWorkspaceLocator(root: workspaceRoot)
            let applier = LocalSyncV2SnapshotApplier(
                documentRepository: spy,
                workspaceLocator: locator,
                backupStore: LocalBackupStore(workspaceLocator: locator)
            )
            let service = SyncV2SnapshotPullService(
                client: FixedSnapshotClient(snapshots: snapshots),
                stateStore: UpToDateSnapshotStateStore(states: states),
                localApplier: applier,
                mergeStore: NoOpSnapshotMergeStore()
            )

            return Fixture(
                root: root,
                projectID: projectID,
                serverProjectID: UUID(),
                service: service,
                repositorySpy: spy
            )
        }
    }
}

// MARK: - 측정용 대역

/// 실제 저장소로 그대로 넘기면서 호출 횟수만 센다. A-2 적용 뒤 이 숫자가
/// 문서 수에 비례해 늘지 않는지 확인하는 데 쓴다.
private actor CountingDocumentRepository:
    DocumentRepository,
    DocumentIdentityReplacing {
    struct Counts: Sendable {
        var documentsInProject = 0
        var documentByID = 0
    }

    private let base: SwiftDataMetadataRepository
    private var stored = Counts()

    init(base: SwiftDataMetadataRepository) {
        self.base = base
    }

    func counts() -> Counts { stored }

    func resetCounts() { stored = Counts() }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        stored.documentsInProject += 1
        return try await base.documents(in: projectID)
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        stored.documentByID += 1
        return try await base.document(id: id)
    }

    func save(_ document: DocumentNode) async throws {
        try await base.save(document)
    }

    func removeMetadata(id: DocumentID) async throws {
        try await base.removeMetadata(id: id)
    }

    func replaceDocumentIdentity(
        from oldID: DocumentID,
        to newID: DocumentID,
        in projectID: ProjectID
    ) async throws {
        try await base.replaceDocumentIdentity(
            from: oldID,
            to: newID,
            in: projectID
        )
    }
}

private actor FixedSnapshotClient: SyncV2SnapshotClienting {
    private let snapshots: [SyncV2RemoteDocumentSnapshot]

    init(snapshots: [SyncV2RemoteDocumentSnapshot]) {
        self.snapshots = snapshots
    }

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        return snapshots
    }

    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        _ = projectID
        return []
    }
}

/// 모든 문서가 서버와 같은 revision이라고 답한다. 변경 없는 pull의
/// 클라이언트 비용만 남기기 위한 대역이다.
private actor UpToDateSnapshotStateStore: SyncV2SnapshotStateStoring {
    private let states: [UUID: SyncV2SnapshotLocalState]

    init(states: [UUID: SyncV2SnapshotLocalState]) {
        self.states = states
    }

    func snapshotStates(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentIDs: Set<UUID>
    ) async throws -> [UUID: SyncV2SnapshotLocalState]? {
        _ = (localProjectID, serverProjectID)
        return states.filter { documentIDs.contains($0.key) }
    }

    func snapshotState(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        documentID: UUID
    ) async throws -> SyncV2SnapshotLocalState? {
        _ = (localProjectID, serverProjectID)
        return states[documentID]
    }

    func applySnapshotBaseline(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        snapshot: SyncV2RemoteDocumentSnapshot,
        expectedRevision: Int64?
    ) async throws -> Bool {
        _ = (localProjectID, serverProjectID, snapshot, expectedRevision)
        return true
    }

    func applyTreeOrderSnapshotBaselines(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        treeOrders: [SyncV2RemoteTreeOrder]
    ) async throws {
        _ = (localProjectID, serverProjectID, treeOrders)
    }
}

private actor NoOpSnapshotMergeStore: SyncV2SnapshotMergeStoring {
    func preserve(_ candidate: SyncV2SnapshotMergeCandidate) async throws {
        _ = candidate
    }
}
