import Darwin
import Foundation
import SwiftData
import XCTest
@testable import WriterPad

/// 7-6의 통합 fixture를 실제 파일로 만들고 로컬 저장 경계의 기준선을 기록한다.
///
/// 평소 회귀 테스트에서는 실행하지 않는다. Xcode의 Test action에
/// `-WriterPadPerformanceBaseline` 인자를 추가한 Release 빌드에서만 실행한다.
/// 시뮬레이터 교정 실행은 `-WriterPadAllowSimulatorCalibration`도 함께 필요하다.
final class LocalPerformanceBaselineTests: XCTestCase {
    @MainActor
    func testReleaseDeviceBaseline() async throws {
        try requireExplicitPerformanceRun()

        let fixtureStartedAt = ProcessInfo.processInfo.systemUptime
        let fixture = try await LocalPerformanceBaselineFixture.make()
        let fixtureRoot = fixture.root
        addTeardownBlock {
            await LocalPerformanceBaselineFixture.remove(root: fixtureRoot)
        }
        let fixtureGenerationSeconds =
            ProcessInfo.processInfo.systemUptime - fixtureStartedAt

        let rootStartedAt = ProcessInfo.processInfo.systemUptime
        let initialRoots = try await fixture.binder.rootNodes(
            in: fixture.projectID
        )
        let initialRootSeconds =
            ProcessInfo.processInfo.systemUptime - rootStartedAt
        try require(
            initialRoots.count == 9,
            "최상위 바인더는 고정 항목 9개여야 합니다."
        )
        let manuscript = try requireValue(
            initialRoots.first { $0.fixedCategory == .manuscript },
            "원고 최상위 항목을 찾지 못했습니다."
        )

        let topBinderSamples = try await Self.sample(iterations: 10) {
            let roots = try await fixture.binder.rootNodes(
                in: fixture.projectID
            )
            try require(
                roots.count == 9,
                "최상위 바인더 새로고침 결과가 달라졌습니다."
            )
        }

        let manuscriptSamples = try await Self.sample(iterations: 10) {
            let volumes = try await fixture.binder.children(
                of: manuscript.id,
                in: fixture.projectID
            )
            try require(
                volumes.count == 40,
                "원고에는 40권이 있어야 합니다."
            )
        }
        let volumes = try await fixture.binder.children(
            of: manuscript.id,
            in: fixture.projectID
        )
        let firstVolume = try requireValue(
            volumes.first { $0.displayName == "1권" },
            "1권을 찾지 못했습니다."
        )
        let volumeSamples = try await Self.sample(iterations: 10) {
            let chapters = try await fixture.binder.children(
                of: firstVolume.id,
                in: fixture.projectID
            )
            try require(
                chapters.count == 25,
                "권 하나에는 25화가 있어야 합니다."
            )
        }

        let scannerMetrics = await fixture.scanner.metrics()
        try require(
            !scannerMetrics.performedMainThreadIO,
            "바인더 파일 열거가 메인 스레드에서 실행됐습니다."
        )

        let chapterTransition = PerformanceChapterTransitionSampler(
            store: fixture.documentStore,
            documents: Array(fixture.manuscriptDocuments.prefix(2))
        )
        let chapterTransitionSamples = try await Self.sample(iterations: 10) {
            try await chapterTransition.loadNext()
        }

        let atomicSave = PerformanceAtomicSaveSampler(
            store: fixture.documentStore,
            document: fixture.manuscriptDocuments[0],
            body: fixture.manuscriptBody
        )
        let atomicSaveSamples = try await Self.sample(iterations: 10) {
            try await atomicSave.saveNext()
        }

        let searchSamples = try await Self.sample(iterations: 5) {
            let report = try await fixture.searchService.search(
                DocumentSearchRequest(
                    projectID: fixture.projectID,
                    query: LocalPerformanceBaselineFixture.searchNeedle
                )
            )
            try require(
                report.searchedDocumentCount == 1_500
                    && report.hits.count == 1
                    && report.issues.isEmpty,
                "1,500개 실제 TXT 전체 검색 결과가 올바르지 않습니다."
            )
        }

        let backupSamples = try await Self.sample(iterations: 5) {
            let snapshots = try await fixture.backupStore.snapshots(
                for: fixture.manuscriptDocuments[0].id,
                projectID: fixture.projectID
            )
            try require(
                snapshots.count == 5_000,
                "실제 백업 목록은 5,000개여야 합니다."
            )
        }

        let searchMainActorGap = try await maximumMainActorGap {
            _ = try await fixture.searchService.search(
                DocumentSearchRequest(
                    projectID: fixture.projectID,
                    query: "기준선에 없는 검색어"
                )
            )
        }
        let saveMainActorGap = try await maximumMainActorGap {
            try await atomicSave.saveNext()
        }

        var metrics = [
            PerformanceMetricSummary(
                name: "project_entry_initial_root",
                samples: [initialRootSeconds]
            ),
            PerformanceMetricSummary(
                name: "top_binder_refresh",
                samples: topBinderSamples
            ),
            PerformanceMetricSummary(
                name: "manuscript_expand_40_volumes",
                samples: manuscriptSamples
            ),
            PerformanceMetricSummary(
                name: "volume_expand_25_chapters",
                samples: volumeSamples
            ),
            PerformanceMetricSummary(
                name: "chapter_transition_6000_characters",
                samples: chapterTransitionSamples
            ),
            PerformanceMetricSummary(
                name: "atomic_save_6000_characters",
                samples: atomicSaveSamples
            ),
            PerformanceMetricSummary(
                name: "full_search_1500_files",
                samples: searchSamples
            ),
            PerformanceMetricSummary(
                name: "backup_list_5000_snapshots",
                samples: backupSamples
            )
        ]
        metrics.sort { $0.name < $1.name }

        let report = PerformanceBaselineReport(
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            hardwareIdentifier: Self.hardwareIdentifier(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            buildConfiguration: Self.buildConfiguration,
            isSimulator: Self.isSimulator,
            fixture: .init(
                volumeCount: 40,
                manuscriptDocumentCount: 1_000,
                manuscriptCharactersPerDocument: fixture.manuscriptBody.count,
                auxiliaryDocumentCount: 500,
                backupSnapshotCount: 5_000,
                generationSeconds: fixtureGenerationSeconds
            ),
            metrics: metrics,
            currentResidentMemoryBytes: Self.memoryBytes(isPeak: false),
            peakResidentMemoryBytes: Self.memoryBytes(isPeak: true),
            maximumMainActorGapDuringSearchMilliseconds:
                searchMainActorGap * 1_000,
            maximumMainActorGapDuringSaveMilliseconds:
                saveMainActorGap * 1_000,
            binderPerformedMainThreadIO: scannerMetrics.performedMainThreadIO
        )
        let data = try JSONEncoder.performanceBaseline.encode(report)
        let json = try requireValue(
            String(data: data, encoding: .utf8),
            "성능 결과 JSON을 UTF-8로 만들지 못했습니다."
        )
        let attachment = XCTAttachment(string: json)
        attachment.name = "WriterPad-PerformanceBaseline-\(report.hardwareIdentifier).json"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("WRITERPAD_PERFORMANCE_BASELINE_BEGIN")
        print(json)
        print("WRITERPAD_PERFORMANCE_BASELINE_END")
    }

    private func requireExplicitPerformanceRun() throws {
        let process = ProcessInfo.processInfo
        let requested =
            process.arguments.contains("-WriterPadPerformanceBaseline")
            || process.environment["WRITERPAD_RUN_PERFORMANCE_BASELINE"] == "1"
        guard requested else {
            throw XCTSkip(
                "7-6 통합 기준선은 Release 실제 기기에서 명시적으로 실행합니다."
            )
        }

        #if targetEnvironment(simulator)
        let allowsCalibration =
            process.arguments.contains("-WriterPadAllowSimulatorCalibration")
            || process.environment["WRITERPAD_ALLOW_SIMULATOR_CALIBRATION"] == "1"
        guard allowsCalibration else {
            throw XCTSkip(
                "시뮬레이터 수치는 실제 iPad 기준선으로 기록하지 않습니다."
            )
        }
        #elseif targetEnvironment(macCatalyst)
        throw XCTSkip("7-6 기준선은 Mac Catalyst가 아니라 실제 iPad에서 측정합니다.")
        #endif
    }

    private static func sample(
        iterations: Int,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws -> [Double] {
        var values: [Double] = []
        values.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let startedAt = ProcessInfo.processInfo.systemUptime
            try await operation()
            values.append(
                ProcessInfo.processInfo.systemUptime - startedAt
            )
        }
        return values
    }

    @MainActor
    private func maximumMainActorGap(
        during operation: @escaping @Sendable () async throws -> Void
    ) async throws -> Double {
        let heartbeat = Task { @MainActor in
            var maximumGap = 0.0
            var previous = ProcessInfo.processInfo.systemUptime
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous)
                previous = now
            }
            return maximumGap
        }
        async let operationResult: Void = operation()
        let maximumGap = try await heartbeat.value
        try await operationResult
        return maximumGap
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func hardwareIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func memoryBytes(isPeak: Bool) -> UInt64? {
        var information = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(
            isPeak ? information.resident_size_max : information.resident_size
        )
    }
}

private struct PerformanceMetricSummary: Codable, Sendable {
    let name: String
    let sampleCount: Int
    let medianMilliseconds: Double
    let p95Milliseconds: Double
    let minimumMilliseconds: Double
    let maximumMilliseconds: Double

    init(name: String, samples: [Double]) {
        let sorted = samples.sorted()
        self.name = name
        sampleCount = sorted.count
        medianMilliseconds = Self.percentile(0.5, in: sorted) * 1_000
        p95Milliseconds = Self.percentile(0.95, in: sorted) * 1_000
        minimumMilliseconds = (sorted.first ?? 0) * 1_000
        maximumMilliseconds = (sorted.last ?? 0) * 1_000
    }

    private static func percentile(_ percentile: Double, in values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = max(
            0,
            min(values.count - 1, Int(ceil(percentile * Double(values.count))) - 1)
        )
        return values[index]
    }
}

private struct PerformanceBaselineReport: Codable, Sendable {
    struct Fixture: Codable, Sendable {
        let volumeCount: Int
        let manuscriptDocumentCount: Int
        let manuscriptCharactersPerDocument: Int
        let auxiliaryDocumentCount: Int
        let backupSnapshotCount: Int
        let generationSeconds: Double
    }

    let capturedAt: String
    let hardwareIdentifier: String
    let operatingSystem: String
    let buildConfiguration: String
    let isSimulator: Bool
    let fixture: Fixture
    let metrics: [PerformanceMetricSummary]
    let currentResidentMemoryBytes: UInt64?
    let peakResidentMemoryBytes: UInt64?
    let maximumMainActorGapDuringSearchMilliseconds: Double
    let maximumMainActorGapDuringSaveMilliseconds: Double
    let binderPerformedMainThreadIO: Bool
}

private struct LocalPerformanceBaselineFixture {
    static let searchNeedle = "WriterPad7단계성능기준선끝"

    let root: URL
    let modelContainer: ModelContainer
    let projectID: ProjectID
    let manuscriptBody: String
    let manuscriptDocuments: [DocumentNode]
    let scanner: LocalBinderDirectoryScanner
    let binder: LocalBinderRepository
    let documentStore: LocalDocumentStore
    let backupStore: LocalBackupStore
    let searchService: LocalProjectSearchService

    @MainActor
    static func make() async throws -> LocalPerformanceBaselineFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "WriterPad-PerformanceBaseline-\(UUID().uuidString)",
            isDirectory: true
        )
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: true
        )
        let metadata = SwiftDataMetadataRepository(modelContainer: container)
        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("Projects")
        )
        let clock = PerformanceBaselineClock(
            date: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let manager = LocalProjectManager(
            projectRepository: metadata,
            workspaceStateRepository: metadata,
            pathResolver: resolver,
            clock: clock
        )
        let project = try await manager.createProject(named: "7-6 성능 기준선")
        let workspace = try resolver.standardPaths(
            forProjectNamed: project.project.name
        ).workspaceRootURL
        let manuscriptBody = String(
            repeating: "가나다라마바사 ",
            count: 750
        )
        let generated = try generateDocuments(
            in: workspace,
            projectID: project.project.id,
            manuscriptBody: manuscriptBody,
            fileManager: fileManager
        )
        try generateBackups(
            in: workspace,
            projectID: project.project.id,
            document: generated.manuscript[0],
            fileManager: fileManager
        )

        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: metadata,
            pathResolver: resolver
        )
        let scanner = LocalBinderDirectoryScanner(pathResolver: resolver)
        let binder = LocalBinderRepository(
            metadataStore: metadata,
            workspaceStateRepository: metadata,
            workspaceLocator: locator,
            scanner: scanner,
            pathPolicy: resolver.policy,
            clock: clock
        )
        let documentStore = LocalDocumentStore(
            workspaceLocator: locator,
            metadataUpdater: PerformanceMetadataUpdater()
        )
        let backupStore = LocalBackupStore(workspaceLocator: locator)
        let searchRepository = PerformanceDocumentRepository(
            documents: generated.manuscript + generated.auxiliary
        )
        let searchService = LocalProjectSearchService(
            documentRepository: searchRepository,
            documentStore: documentStore
        )
        return LocalPerformanceBaselineFixture(
            root: root,
            modelContainer: container,
            projectID: project.project.id,
            manuscriptBody: manuscriptBody,
            manuscriptDocuments: generated.manuscript,
            scanner: scanner,
            binder: binder,
            documentStore: documentStore,
            backupStore: backupStore,
            searchService: searchService
        )
    }

    static func remove(root: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: root)
        }.value
    }

    private static func generateDocuments(
        in workspace: URL,
        projectID: ProjectID,
        manuscriptBody: String,
        fileManager: FileManager
    ) throws -> (manuscript: [DocumentNode], auxiliary: [DocumentNode]) {
        let bodyData = Data(manuscriptBody.utf8)
        var manuscript: [DocumentNode] = []
        manuscript.reserveCapacity(1_000)
        for volume in 1...40 {
            let directory = workspace.appendingPathComponent(
                "메인/원고/\(volume)권",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let firstChapter = (volume - 1) * 25 + 1
            for chapter in firstChapter..<(firstChapter + 25) {
                let name = chapter < 1_000
                    ? String(format: "%03d화.txt", chapter)
                    : "\(chapter)화.txt"
                let path = RelativeDocumentPath(
                    rawValue: "메인/원고/\(volume)권/\(name)"
                )
                try bodyData.write(
                    to: directory.appendingPathComponent(name)
                )
                manuscript.append(
                    document(
                        projectID: projectID,
                        path: path,
                        order: chapter,
                        uuidGroup: "8000"
                    )
                )
            }
        }

        let auxiliaryDirectory = workspace.appendingPathComponent(
            "메인/설정집/7-6 성능 기준선",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: auxiliaryDirectory,
            withIntermediateDirectories: true
        )
        var auxiliary: [DocumentNode] = []
        auxiliary.reserveCapacity(500)
        for index in 1...500 {
            let name = String(format: "%03d.txt", index)
            let path = RelativeDocumentPath(
                rawValue: "메인/설정집/7-6 성능 기준선/\(name)"
            )
            let text = index == 500
                ? manuscriptBody + searchNeedle
                : manuscriptBody
            try Data(text.utf8).write(
                to: auxiliaryDirectory.appendingPathComponent(name)
            )
            auxiliary.append(
                document(
                    projectID: projectID,
                    path: path,
                    order: index,
                    uuidGroup: "8100"
                )
            )
        }
        return (manuscript, auxiliary)
    }

    private static func generateBackups(
        in workspace: URL,
        projectID: ProjectID,
        document: DocumentNode,
        fileManager: FileManager
    ) throws {
        let directory = workspace.appendingPathComponent(
            "백업/자동저장",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let textData = Data("7-6 성능 기준선 백업".utf8)
        let hash = SHA256ContentHasher().sha256(for: textData)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let baseDate = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0..<5_000 {
            let id = BackupID(rawValue: deterministicUUID(
                group: "9000",
                index: index
            ))
            let snapshot = BackupSnapshot(
                id: id,
                projectID: projectID,
                documentID: document.id,
                relativePath: document.relativePath,
                createdAt: baseDate.addingTimeInterval(-Double(index)),
                contentHash: hash,
                reason: .manual,
                isPinned: index == 4_999
            )
            let baseName = id.rawValue.uuidString.lowercased()
            try textData.write(
                to: directory.appendingPathComponent(baseName + ".txt")
            )
            try encoder.encode(snapshot).write(
                to: directory.appendingPathComponent(baseName + ".json")
            )
        }
    }

    private static func document(
        projectID: ProjectID,
        path: RelativeDocumentPath,
        order: Int,
        uuidGroup: String
    ) -> DocumentNode {
        DocumentNode(
            id: DocumentID(rawValue: deterministicUUID(
                group: uuidGroup,
                index: order
            )),
            projectID: projectID,
            kind: .text,
            parentID: nil,
            relativePath: path,
            userOrder: order,
            modifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            contentHash: nil
        )
    }

    private static func deterministicUUID(group: String, index: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-4000-%@-%012llx",
                group,
                UInt64(index + 1)
            )
        )!
    }
}

private actor PerformanceDocumentRepository: DocumentRepository {
    private var documentsByID: [DocumentID: DocumentNode]

    init(documents: [DocumentNode]) {
        documentsByID = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.id, $0) }
        )
    }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        documentsByID.values.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        documentsByID[id]
    }

    func save(_ document: DocumentNode) async throws {
        documentsByID[document.id] = document
    }

    func removeMetadata(id: DocumentID) async throws {
        documentsByID.removeValue(forKey: id)
    }
}

private actor PerformanceMetadataUpdater: DocumentFileMetadataUpdating {
    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws {}
}

private actor PerformanceChapterTransitionSampler {
    private let store: LocalDocumentStore
    private let documents: [DocumentNode]
    private var index = 0

    init(store: LocalDocumentStore, documents: [DocumentNode]) {
        self.store = store
        self.documents = documents
    }

    func loadNext() async throws {
        guard !documents.isEmpty else {
            throw PerformanceBaselineError.invalidFixture(
                "화 전환 문서가 없습니다."
            )
        }
        let document = documents[index % documents.count]
        index += 1
        let text = try await store.loadText(for: document)
        try require(
            text.count >= 6_000,
            "화 전환에서 6,000자 원고를 읽지 못했습니다."
        )
    }
}

private actor PerformanceAtomicSaveSampler {
    private let store: LocalDocumentStore
    private let document: DocumentNode
    private let body: String
    private var generation: UInt64 = 0

    init(store: LocalDocumentStore, document: DocumentNode, body: String) {
        self.store = store
        self.document = document
        self.body = body
    }

    func saveNext() async throws {
        generation += 1
        let receipt = try await store.save(
            DocumentSaveRequest(
                projectID: document.projectID,
                documentID: document.id,
                relativePath: document.relativePath,
                text: body + String(generation % 10),
                generation: generation,
                cursor: .start
            )
        )
        try require(
            receipt.generation == generation,
            "원자 저장 세대가 일치하지 않습니다."
        )
    }
}

private struct PerformanceBaselineClock: AppClock {
    let date: Date
    func now() -> Date { date }
}

private enum PerformanceBaselineError: Error {
    case invalidFixture(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw PerformanceBaselineError.invalidFixture(message)
    }
}

private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw PerformanceBaselineError.invalidFixture(message)
    }
    return value
}

private extension JSONEncoder {
    static var performanceBaseline: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
