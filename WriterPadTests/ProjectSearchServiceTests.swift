import Foundation
import XCTest
@testable import WriterPad

final class ProjectSearchServiceTests: XCTestCase {
    func testSearchHitIdentityIncludesDocumentAndMatchRange() {
        let firstDocumentID = DocumentID(rawValue: UUID())
        let secondDocumentID = DocumentID(rawValue: UUID())
        let path = RelativeDocumentPath(rawValue: "메인/원고/1권/001화.txt")
        let hits = [
            DocumentSearchHit(
                documentID: firstDocumentID,
                relativePath: path,
                utf16Location: 0,
                utf16Length: 2,
                preview: "검색",
                previewUTF16Location: 0
            ),
            DocumentSearchHit(
                documentID: secondDocumentID,
                relativePath: path,
                utf16Location: 0,
                utf16Length: 2,
                preview: "검색",
                previewUTF16Location: 0
            ),
            DocumentSearchHit(
                documentID: firstDocumentID,
                relativePath: path,
                utf16Location: 10,
                utf16Length: 2,
                preview: "다른 검색",
                previewUTF16Location: 3
            )
        ]

        XCTAssertEqual(Set(hits.map(\.id)).count, hits.count)
    }

    func testSearchUsesDraftSnapshotAndIncludesAuxiliaryButExcludesTrashAndBackup() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let manuscript = makeDocument(projectID: projectID, path: "원고/001화.txt")
        let auxiliary = makeDocument(projectID: projectID, path: "설정/인물표.txt")
        let trashed = makeDocument(
            projectID: projectID,
            path: "휴지통/삭제.txt",
            deletionStatus: .trashed(
                originalPath: RelativeDocumentPath(rawValue: "원고/삭제.txt"),
                deletedAt: Date()
            )
        )
        let backup = makeDocument(projectID: projectID, path: "백업/사본.txt")
        let repository = SearchDocumentRepository(
            documents: [manuscript, auxiliary, trashed, backup]
        )
        let store = SearchDocumentStore(
            texts: [
                manuscript.id: "디스크에는 없음",
                auxiliary.id: "인물 설정에 별빛이 있다.",
                trashed.id: "별빛",
                backup.id: "별빛"
            ]
        )
        let service = LocalProjectSearchService(
            documentRepository: repository,
            documentStore: store
        )
        let draft = "앞🙂별빛 뒤"

        let report = try await service.search(
            DocumentSearchRequest(
                projectID: projectID,
                query: "별빛",
                textOverrides: [manuscript.id: draft]
            )
        )

        XCTAssertEqual(report.totalDocumentCount, 2)
        XCTAssertEqual(report.searchedDocumentCount, 2)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(Set(report.hits.map(\.documentID)), Set([manuscript.id, auxiliary.id]))

        let manuscriptHit = try XCTUnwrap(
            report.hits.first { $0.documentID == manuscript.id }
        )
        XCTAssertEqual(manuscriptHit.utf16Location, 3)
        XCTAssertEqual(manuscriptHit.utf16Length, 2)
        let preview = manuscriptHit.preview as NSString
        XCTAssertEqual(
            preview.substring(
                with: NSRange(
                    location: Int(manuscriptHit.previewUTF16Location),
                    length: Int(manuscriptHit.utf16Length)
                )
            ),
            "별빛"
        )
    }

    func testReadFailureIsReportedWithoutDiscardingOtherResults() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let readable = makeDocument(projectID: projectID, path: "원고/읽힘.txt")
        let broken = makeDocument(projectID: projectID, path: "원고/깨짐.txt")
        let repository = SearchDocumentRepository(documents: [readable, broken])
        let store = SearchDocumentStore(
            texts: [readable.id: "검색어"],
            failingDocumentIDs: [broken.id]
        )
        let service = LocalProjectSearchService(
            documentRepository: repository,
            documentStore: store
        )

        let report = try await service.search(
            DocumentSearchRequest(projectID: projectID, query: "검색어")
        )

        XCTAssertEqual(report.hits.map(\.documentID), [readable.id])
        XCTAssertEqual(report.searchedDocumentCount, 1)
        XCTAssertEqual(report.issues.count, 1)
        XCTAssertEqual(report.issues.first?.documentID, broken.id)
    }

    func testSearchRetriesWithRefreshedMetadataAfterMove() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let old = makeDocument(projectID: projectID, path: "원고/이전.txt")
        let moved = makeDocument(id: old.id, projectID: projectID, path: "원고/이동.txt")
        let repository = SearchDocumentRepository(
            documents: [old],
            refreshedDocuments: [old.id: moved]
        )
        let store = SearchDocumentStore(
            texts: [moved.id: "이동 중에도 찾기"],
            requiredPaths: [moved.id: moved.relativePath]
        )
        let service = LocalProjectSearchService(
            documentRepository: repository,
            documentStore: store
        )

        let report = try await service.search(
            DocumentSearchRequest(projectID: projectID, query: "찾기")
        )

        XCTAssertEqual(report.hits.count, 1)
        XCTAssertEqual(report.hits.first?.relativePath, moved.relativePath)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testCancellationStopsLongRunningSearch() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let documents = (0..<50).map {
            makeDocument(projectID: projectID, path: "원고/\($0).txt")
        }
        let store = SearchDocumentStore(
            texts: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, "본문") }),
            loadDelayNanoseconds: 20_000_000
        )
        let service = LocalProjectSearchService(
            documentRepository: SearchDocumentRepository(documents: documents),
            documentStore: store
        )
        let task = Task {
            try await service.search(
                DocumentSearchRequest(projectID: projectID, query: "없음")
            )
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소 오류가 필요합니다.")
        } catch is CancellationError {
            let loadCount = await store.loadCount
            XCTAssertLessThan(loadCount, documents.count)
        }
    }

    func testDirectSearchHandlesOneThousandEpisodesAndFiveHundredAuxiliaryDocuments() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let episodes = (0..<1_000).map {
            makeDocument(projectID: projectID, path: "원고/\($0).txt")
        }
        let auxiliary = (0..<500).map {
            makeDocument(projectID: projectID, path: "설정/\($0).txt")
        }
        let documents = episodes + auxiliary
        let approximatelySixThousandCharacters = String(repeating: "가나다라마바사 ", count: 750)
        let store = SearchDocumentStore(
            texts: Dictionary(
                uniqueKeysWithValues: documents.map {
                    ($0.id, approximatelySixThousandCharacters)
                }
            )
        )
        let progress = SearchProgressRecorder()
        let service = LocalProjectSearchService(
            documentRepository: SearchDocumentRepository(documents: documents),
            documentStore: store
        )
        let startedAt = Date()

        let report = try await service.search(
            DocumentSearchRequest(projectID: projectID, query: "존재하지 않는 검색어"),
            progress: { progress.record($0) }
        )

        XCTAssertEqual(report.totalDocumentCount, 1_500)
        XCTAssertEqual(report.searchedDocumentCount, 1_500)
        XCTAssertTrue(report.hits.isEmpty)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(
            progress.latest,
            DocumentSearchProgress(
                completedDocumentCount: 1_500,
                totalDocumentCount: 1_500,
                hitCount: 0
            )
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            5,
            "직접 파일 검색의 초기 기준선이 5초를 넘으면 인덱스 도입을 재검토해야 합니다."
        )
    }

    func testRealUTF8FilesMeetInitialFifteenHundredDocumentBaseline() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "WriterPadProjectSearch-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let manuscriptDirectory = root.appendingPathComponent(
            "메인/원고/1권",
            isDirectory: true
        )
        let auxiliaryDirectory = root.appendingPathComponent(
            "메인/설정집/자료",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: manuscriptDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: auxiliaryDirectory,
            withIntermediateDirectories: true
        )

        let projectID = ProjectID(rawValue: UUID())
        let body = String(repeating: "가나다라마바사 ", count: 750)
        var documents: [DocumentNode] = []
        for index in 0..<1_500 {
            let isEpisode = index < 1_000
            let relativePath = isEpisode
                ? "메인/원고/1권/\(index)화.txt"
                : "메인/설정집/자료/\(index - 1_000).txt"
            let text = index == 1_499 ? body + "끝검색" : body
            let url = root.appendingPathComponent(relativePath)
            try Data(text.utf8).write(to: url)
            documents.append(
                makeDocument(projectID: projectID, path: relativePath)
            )
        }

        let localStore = LocalDocumentStore(
            workspaceLocator: FixedWorkspaceLocator(root: root),
            metadataUpdater: RecordingMetadataUpdater()
        )
        let service = LocalProjectSearchService(
            documentRepository: SearchDocumentRepository(documents: documents),
            documentStore: localStore
        )
        let startedAt = Date()

        let report = try await service.search(
            DocumentSearchRequest(projectID: projectID, query: "끝검색")
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(report.searchedDocumentCount, 1_500)
        XCTAssertEqual(report.hits.count, 1)
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertLessThan(
            elapsed,
            5,
            "실제 UTF-8 TXT 직접 검색이 5초를 넘으면 인덱스 도입을 재검토해야 합니다."
        )
    }

    @MainActor
    func testSearchWorkDoesNotBlockMainActor() async throws {
        let projectID = ProjectID(rawValue: UUID())
        let documents = (0..<20).map {
            makeDocument(projectID: projectID, path: "원고/\($0).txt")
        }
        let service = LocalProjectSearchService(
            documentRepository: SearchDocumentRepository(documents: documents),
            documentStore: SearchDocumentStore(
                texts: Dictionary(uniqueKeysWithValues: documents.map { ($0.id, "본문") }),
                loadDelayNanoseconds: 20_000_000
            )
        )
        let heartbeat = expectation(description: "main actor heartbeat")
        let searchTask = Task {
            try await service.search(
                DocumentSearchRequest(projectID: projectID, query: "없음")
            )
        }

        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.2)
        searchTask.cancel()
        _ = try? await searchTask.value
    }
}

private enum SearchTestError: Error {
    case unreadable
    case unexpectedPath
}

private final class SearchProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DocumentSearchProgress?

    var latest: DocumentSearchProgress? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ progress: DocumentSearchProgress) {
        lock.lock()
        value = progress
        lock.unlock()
    }
}

private actor SearchDocumentRepository: DocumentRepository {
    private let listedDocuments: [DocumentNode]
    private let refreshedDocuments: [DocumentID: DocumentNode]

    init(
        documents: [DocumentNode],
        refreshedDocuments: [DocumentID: DocumentNode] = [:]
    ) {
        listedDocuments = documents
        self.refreshedDocuments = refreshedDocuments
    }

    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        listedDocuments.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) async throws -> DocumentNode? {
        refreshedDocuments[id] ?? listedDocuments.first { $0.id == id }
    }

    func save(_ document: DocumentNode) async throws {}
    func removeMetadata(id: DocumentID) async throws {}
}

private actor SearchDocumentStore: LocalDocumentStoring {
    private let texts: [DocumentID: String]
    private let failingDocumentIDs: Set<DocumentID>
    private let requiredPaths: [DocumentID: RelativeDocumentPath]
    private let loadDelayNanoseconds: UInt64
    private(set) var loadCount = 0

    init(
        texts: [DocumentID: String],
        failingDocumentIDs: Set<DocumentID> = [],
        requiredPaths: [DocumentID: RelativeDocumentPath] = [:],
        loadDelayNanoseconds: UInt64 = 0
    ) {
        self.texts = texts
        self.failingDocumentIDs = failingDocumentIDs
        self.requiredPaths = requiredPaths
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }

    func loadText(for document: DocumentNode) async throws -> String {
        loadCount += 1
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        if failingDocumentIDs.contains(document.id) {
            throw SearchTestError.unreadable
        }
        if let requiredPath = requiredPaths[document.id],
           document.relativePath != requiredPath {
            throw SearchTestError.unexpectedPath
        }
        guard let text = texts[document.id] else {
            throw SearchTestError.unreadable
        }
        return text
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        throw SearchTestError.unreadable
    }
}

private func makeDocument(
    id: DocumentID = DocumentID(rawValue: UUID()),
    projectID: ProjectID,
    path: String,
    deletionStatus: DocumentDeletionStatus = .active
) -> DocumentNode {
    DocumentNode(
        id: id,
        projectID: projectID,
        kind: .text,
        parentID: nil,
        relativePath: RelativeDocumentPath(rawValue: path),
        userOrder: 0,
        modifiedAt: Date(),
        contentHash: nil,
        deletionStatus: deletionStatus
    )
}
