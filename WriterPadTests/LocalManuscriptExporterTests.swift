import CoreGraphics
import Foundation
import XCTest
@testable import WriterPad

final class LocalManuscriptExporterTests: XCTestCase {
    func testRangeInputUsesGrayDefaultsUntilFirstDigitReplacesThem() {
        XCTAssertEqual(
            ManuscriptExportRangeInput.resolvedScope(
                startText: "",
                endText: "",
                lastChapterNumber: 125
            ),
            .range(start: 1, end: 125)
        )

        let replacedStart = ManuscriptExportRangeInput.appending("7", to: "")
        let replacedEnd = ManuscriptExportRangeInput.appending("9", to: "")
        XCTAssertEqual(replacedStart, "7")
        XCTAssertEqual(replacedEnd, "9")
        XCTAssertEqual(
            ManuscriptExportRangeInput.appending("2", to: replacedStart),
            "72"
        )
        XCTAssertNil(
            ManuscriptExportRangeInput.resolvedScope(
                startText: "7",
                endText: "7",
                lastChapterNumber: 125
            )
        )
        XCTAssertEqual(
            ManuscriptExportRangeInput.normalizedEnd(3, start: 7),
            8
        )
    }

    func testExportsAcrossVolumesByChapterNumberAndOmitsFilenameMemo() async throws {
        let fixture = try ExportFixture(
            chapters: [
                (26, "2권", "026화 다음 권 메모.txt", "스물여섯"),
                (1, "1권", "001화 복선에 대한 메모메모.txt", "첫 내용"),
                (3, "1권", "003화.txt", "셋")
            ]
        )
        defer { fixture.remove() }

        let report = try await fixture.exporter.export(
            fixture.request(
                scope: .all,
                stopsAtShort: false
            )
        )

        XCTAssertEqual(report.firstIncludedChapterNumber, 1)
        XCTAssertEqual(report.lastIncludedChapterNumber, 26)
        XCTAssertEqual(report.missingChapterNumbers, Array(2...25).filter { $0 != 3 })
        XCTAssertEqual(
            try String(contentsOf: report.outputURL, encoding: .utf8),
            "001화\n\n첫 내용\n\n003화\n\n셋\n\n026화\n\n스물여섯"
        )
        XCTAssertFalse(
            try String(contentsOf: report.outputURL, encoding: .utf8).contains("복선에 대한")
        )
        XCTAssertEqual(report.outputURL.lastPathComponent, "테스트 작품(1~26화).txt")
    }

    func testThreeHundredCharacterBoundaryIncludes300AndStopsAt299() async throws {
        let fixture = try ExportFixture(
            chapters: [
                (1, "1권", "001화.txt", String(repeating: "가", count: 300)),
                (2, "1권", "002화.txt", String(repeating: " ", count: 300)),
                (3, "1권", "003화.txt", String(repeating: "나", count: 299)),
                (4, "1권", "004화.txt", String(repeating: "다", count: 301))
            ]
        )
        defer { fixture.remove() }

        let report = try await fixture.exporter.export(
            fixture.request(scope: .all, includesTitles: false)
        )

        XCTAssertEqual(report.firstShortChapterNumber, 3)
        XCTAssertEqual(report.exportedDocumentIDs.count, 2)
        XCTAssertEqual(report.lastIncludedChapterNumber, 2)
        XCTAssertEqual(report.outputURL.lastPathComponent, "테스트 작품(1~2화).txt")

        let overBoundaryReport = try await fixture.exporter.export(
            fixture.request(
                scope: .range(start: 4, end: 4),
                includesTitles: false,
                stopsAtShort: false
            )
        )
        XCTAssertEqual(overBoundaryReport.exportedDocumentIDs.count, 1)
        XCTAssertEqual(
            try String(contentsOf: overBoundaryReport.outputURL, encoding: .utf8).count,
            301
        )
    }

    func testRangeReportsMissingAndEmptyWhileShortStopIsOff() async throws {
        let fixture = try ExportFixture(
            chapters: [
                (50, "2권", "050화.txt", ""),
                (52, "3권", "052화 메모.txt", "🙂한글")
            ]
        )
        defer { fixture.remove() }

        let report = try await fixture.exporter.export(
            fixture.request(
                scope: .range(start: 50, end: 53),
                stopsAtShort: false
            )
        )

        XCTAssertEqual(report.missingChapterNumbers, [51, 53])
        XCTAssertEqual(report.emptyExcludedChapterNumbers, [50])
        XCTAssertEqual(report.firstIncludedChapterNumber, 52)
        XCTAssertEqual(report.lastIncludedChapterNumber, 52)
        XCTAssertEqual(
            try String(contentsOf: report.outputURL, encoding: .utf8),
            "052화\n\n🙂한글"
        )
    }

    func testPDFExportCreatesReadableMultiPageDocumentForKoreanAndEmoji() async throws {
        let fixture = try ExportFixture(
            chapters: [
                (
                    1,
                    "1권",
                    "001화.txt",
                    String(repeating: "한글 문장과 이모지🙂가 함께 있습니다.\n", count: 1_200)
                ),
                (2, "1권", "002화 메모.txt", "두 번째 화")
            ]
        )
        defer { fixture.remove() }

        let report = try await fixture.exporter.export(
            fixture.request(
                scope: .all,
                format: .pdf,
                stopsAtShort: false
            )
        )

        XCTAssertEqual(report.format, .pdf)
        XCTAssertEqual(report.outputURL.pathExtension, "pdf")
        XCTAssertEqual(report.outputURL.lastPathComponent, "테스트 작품(1~2화).pdf")
        let data = try Data(contentsOf: report.outputURL)
        XCTAssertTrue(data.starts(with: Data("%PDF-".utf8)))
        let pdf = try XCTUnwrap(CGPDFDocument(report.outputURL as CFURL))
        XCTAssertGreaterThan(pdf.numberOfPages, 1)
    }

    func testPDFExportCreatesBlankPageWhenEmptyChapterIsExplicitlyIncluded() async throws {
        let fixture = try ExportFixture(
            chapters: [(1, "1권", "001화.txt", "")]
        )
        defer { fixture.remove() }

        let report = try await fixture.exporter.export(
            fixture.request(
                scope: .all,
                format: .pdf,
                excludesEmpty: false,
                includesTitles: false,
                stopsAtShort: false
            )
        )

        let pdf = try XCTUnwrap(CGPDFDocument(report.outputURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertEqual(report.exportedDocumentIDs.count, 1)
    }

    func testDuplicateChapterFailsBeforeWriting() async throws {
        let fixture = try ExportFixture(
            chapters: [
                (1, "1권", "001화.txt", "하나"),
                (1, "2권", "001화 메모.txt", "중복")
            ]
        )
        defer { fixture.remove() }

        do {
            _ = try await fixture.exporter.export(
                fixture.request(scope: .all, stopsAtShort: false)
            )
            XCTFail("중복 화수는 추출되면 안 됩니다.")
        } catch {
            XCTAssertEqual(error as? ManuscriptExportError, .duplicateChapterNumber(1))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
    }

    func testReplacementFailurePreservesExistingOutput() async throws {
        let fixture = try ExportFixture(
            chapters: [(1, "1권", "001화.txt", String(repeating: "가", count: 301))],
            faultPlan: AtomicWriteFaultPlan(
                point: .beforeReplacement,
                failure: .generic(code: EIO)
            )
        )
        defer { fixture.remove() }
        let existing = fixture.output.appendingPathComponent("테스트 작품(1~1화).txt")
        try Data("기존 출력".utf8).write(to: existing)

        do {
            _ = try await fixture.exporter.export(
                fixture.request(scope: ManuscriptExportScope.all)
            )
            XCTFail("교체 실패가 전달되어야 합니다.")
        } catch {}

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "기존 출력")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.output.path)
                .contains { $0.hasPrefix(".writerpad-export-") }
        )
    }

    func testPDFReplacementFailurePreservesExistingOutput() async throws {
        let fixture = try ExportFixture(
            chapters: [(1, "1권", "001화.txt", String(repeating: "가", count: 301))],
            faultPlan: AtomicWriteFaultPlan(
                point: .beforeReplacement,
                failure: .generic(code: EIO)
            )
        )
        defer { fixture.remove() }
        let existing = fixture.output.appendingPathComponent("테스트 작품(1~1화).pdf")
        let original = Data("기존 PDF 자리".utf8)
        try original.write(to: existing)

        do {
            _ = try await fixture.exporter.export(
                fixture.request(scope: .all, format: .pdf)
            )
            XCTFail("PDF 교체 실패가 전달되어야 합니다.")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: existing), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.output.path)
                .contains { $0.hasPrefix(".writerpad-export-") }
        )
    }

    func testCancellationDoesNotCreateOutput() async throws {
        let fixture = try ExportFixture(
            chapters: [(1, "1권", "001화.txt", String(repeating: "가", count: 301))],
            loadDelayNanoseconds: 1_000_000_000
        )
        defer { fixture.remove() }

        let task = Task {
            try await fixture.exporter.export(
                fixture.request(scope: ManuscriptExportScope.all)
            )
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소된 추출은 완료되면 안 됩니다.")
        } catch is CancellationError {
        } catch {
            XCTFail("취소 오류가 전달되어야 합니다: \(error)")
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty
        )
    }

    @MainActor
    func testExportPipelineStopsBeforeExporterWhenEditorPreparationFails() async {
        let trace = ExportPipelineTrace()
        let exporter = ExportPipelineProbe(trace: trace)

        do {
            _ = try await ManuscriptExportPipeline.run(
                request: pipelineRequest,
                exporter: exporter
            ) {
                await trace.record("prepare")
                throw ExportPipelineTestError.preparation
            }
            XCTFail("저장 준비 실패 뒤에는 추출기가 호출되면 안 됩니다.")
        } catch {
            XCTAssertEqual(error as? ExportPipelineTestError, .preparation)
        }

        let events = await trace.events()
        XCTAssertEqual(events, ["prepare"])
    }

    @MainActor
    func testExportPipelinePreparesEditorsBeforeCallingExporter() async {
        let trace = ExportPipelineTrace()
        let exporter = ExportPipelineProbe(trace: trace)

        do {
            _ = try await ManuscriptExportPipeline.run(
                request: pipelineRequest,
                exporter: exporter
            ) {
                await trace.record("prepare")
            }
            XCTFail("검사용 추출기 오류가 전달되어야 합니다.")
        } catch {
            XCTAssertEqual(error as? ExportPipelineTestError, .export)
        }

        let events = await trace.events()
        XCTAssertEqual(events, ["prepare", "export"])
    }

    private var pipelineRequest: ExportRequest {
        ExportRequest(
            projectID: ProjectID(rawValue: UUID()),
            scope: .all,
            format: .plainText,
            excludesEmptyChapters: true,
            includesChapterTitles: true,
            stopsAtChapterShorterThan300Characters: true,
            destinationDirectoryURL: FileManager.default.temporaryDirectory
        )
    }
}

private enum ExportPipelineTestError: Error, Equatable {
    case preparation
    case export
}

private actor ExportPipelineTrace {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor ExportPipelineProbe: Exporting {
    let trace: ExportPipelineTrace

    init(trace: ExportPipelineTrace) {
        self.trace = trace
    }

    func export(_ request: ExportRequest) async throws -> ExportReport {
        await trace.record("export")
        throw ExportPipelineTestError.export
    }
}

private struct ExportFixture {
    let root: URL
    let output: URL
    let projectID: ProjectID
    let exporter: LocalManuscriptExporter

    init(
        chapters: [(number: Int, volume: String, fileName: String, text: String)],
        faultPlan: AtomicWriteFaultPlan? = nil,
        loadDelayNanoseconds: UInt64 = 0
    ) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPadExport-\(UUID().uuidString)", isDirectory: true)
        let fixtureOutput = fixtureRoot.appendingPathComponent("출력", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureOutput,
            withIntermediateDirectories: true
        )
        let fixtureProjectID = ProjectID(rawValue: UUID())
        let documents = chapters.map { chapter in
            DocumentNode(
                id: DocumentID(rawValue: UUID()),
                projectID: fixtureProjectID,
                kind: .text,
                parentID: nil,
                relativePath: RelativeDocumentPath(
                    rawValue: "메인/원고/\(chapter.volume)/\(chapter.fileName)"
                ),
                userOrder: chapter.number,
                modifiedAt: .distantPast,
                contentHash: nil
            )
        }
        let texts = Dictionary(
            uniqueKeysWithValues: zip(documents, chapters).map { ($0.id, $1.text) }
        )
        root = fixtureRoot
        output = fixtureOutput
        projectID = fixtureProjectID
        exporter = LocalManuscriptExporter(
            projectRepository: ExportProjectRepository(
                project: Project(
                    id: fixtureProjectID,
                    name: "테스트 작품",
                    createdAt: .distantPast,
                    modifiedAt: .distantPast
                )
            ),
            documentRepository: ExportDocumentRepository(documents: documents),
            documentStore: ExportDocumentStore(
                texts: texts,
                loadDelayNanoseconds: loadDelayNanoseconds
            ),
            faultPlan: faultPlan
        )
    }

    func request(
        scope: ManuscriptExportScope,
        format: ManuscriptExportFormat = .plainText,
        excludesEmpty: Bool = true,
        includesTitles: Bool = true,
        stopsAtShort: Bool = true
    ) -> ExportRequest {
        ExportRequest(
            projectID: projectID,
            scope: scope,
            format: format,
            excludesEmptyChapters: excludesEmpty,
            includesChapterTitles: includesTitles,
            stopsAtChapterShorterThan300Characters: stopsAtShort,
            destinationDirectoryURL: output
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ExportProjectRepository: ProjectRepository {
    let storedProject: Project
    init(project: Project) { storedProject = project }
    func projects() async throws -> [Project] { [storedProject] }
    func project(id: ProjectID) async throws -> Project? {
        storedProject.id == id ? storedProject : nil
    }
    func save(_ project: Project) async throws {}
    func remove(id: ProjectID) async throws {}
}

private actor ExportDocumentRepository: DocumentRepository {
    let storedDocuments: [DocumentNode]
    init(documents: [DocumentNode]) { storedDocuments = documents }
    func documents(in projectID: ProjectID) async throws -> [DocumentNode] {
        storedDocuments.filter { $0.projectID == projectID }
    }
    func document(id: DocumentID) async throws -> DocumentNode? {
        storedDocuments.first { $0.id == id }
    }
    func save(_ document: DocumentNode) async throws {}
    func removeMetadata(id: DocumentID) async throws {}
}

private actor ExportDocumentStore: LocalDocumentStoring {
    let texts: [DocumentID: String]
    let loadDelayNanoseconds: UInt64
    init(texts: [DocumentID: String], loadDelayNanoseconds: UInt64 = 0) {
        self.texts = texts
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }
    func loadText(for document: DocumentNode) async throws -> String {
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        return try XCTUnwrap(texts[document.id])
    }
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        throw CancellationError()
    }
}
