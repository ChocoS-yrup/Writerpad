import CoreGraphics
import CoreText
import Foundation

enum ManuscriptExportError: Error, Equatable, LocalizedError, Sendable {
    case projectMissing
    case invalidRange
    case duplicateChapterNumber(Int)
    case noChaptersIncluded
    case destinationDirectoryMissing(String)
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .projectMissing:
            "작품 정보를 찾을 수 없습니다."
        case .invalidRange:
            "시작 화는 종료 화보다 클 수 없으며 1 이상이어야 합니다."
        case let .duplicateChapterNumber(number):
            "원고 저장소가 손상되었습니다. \(number)화가 중복됩니다."
        case .noChaptersIncluded:
            "조건에 맞는 원고가 없어 내보내기 파일을 만들지 않았습니다."
        case let .destinationDirectoryMissing(path):
            "선택한 저장 폴더를 찾을 수 없습니다: \(path)"
        case .pdfCreationFailed:
            "PDF 파일을 완성하지 못했습니다."
        }
    }
}

actor LocalManuscriptExporter: Exporting {
    private let projectRepository: any ProjectRepository
    private let documentRepository: any DocumentRepository
    private let documentStore: any LocalDocumentStoring
    private let pathPolicy: PathPolicy
    private let fileManager: FileManager
    private let uuidGenerator: any UUIDGenerating
    private let writer: POSIXAtomicFileWriter
    private let binderRules = BinderRuleService()

    init(
        projectRepository: any ProjectRepository,
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring,
        pathPolicy: PathPolicy = PathPolicy(),
        fileManager: FileManager = .default,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        faultPlan: AtomicWriteFaultPlan? = nil
    ) {
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.documentStore = documentStore
        self.pathPolicy = pathPolicy
        self.fileManager = fileManager
        self.uuidGenerator = uuidGenerator
        self.writer = POSIXAtomicFileWriter(faultPlan: faultPlan)
    }

    func export(_ request: ExportRequest) async throws -> ExportReport {
        try Task.checkCancellation()
        guard let project = try await projectRepository.project(id: request.projectID) else {
            throw ManuscriptExportError.projectMissing
        }
        let requestedRange: ClosedRange<Int>?
        switch request.scope {
        case .all:
            requestedRange = nil
        case let .range(start, end):
            guard start > 0, end >= start else {
                throw ManuscriptExportError.invalidRange
            }
            requestedRange = start...end
        }

        let documents = try await documentRepository.documents(in: request.projectID)
        var chaptersByNumber: [Int: (document: DocumentNode, prefix: String)] = [:]
        for document in documents {
            try Task.checkCancellation()
            guard let chapter = chapterIdentity(for: document) else { continue }
            if chaptersByNumber[chapter.number] != nil {
                throw ManuscriptExportError.duplicateChapterNumber(chapter.number)
            }
            chaptersByNumber[chapter.number] = (document, chapter.protectedPrefix)
        }

        let candidateNumbers = chaptersByNumber.keys
            .filter { requestedRange?.contains($0) ?? true }
            .sorted()
        let reportRange: ClosedRange<Int>? = requestedRange ?? {
            guard let first = candidateNumbers.first, let last = candidateNumbers.last else {
                return nil
            }
            return first...last
        }()
        let missingNumbers = reportRange.map { range in
            range.filter { chaptersByNumber[$0] == nil }
        } ?? []

        var chunks: [String] = []
        var includedIDs: [DocumentID] = []
        var includedNumbers: [Int] = []
        var emptyExcludedNumbers: [Int] = []
        var firstShortNumber: Int?

        for number in candidateNumbers {
            try Task.checkCancellation()
            guard let chapter = chaptersByNumber[number] else { continue }
            let text = try await documentStore.loadText(for: chapter.document)
            try Task.checkCancellation()

            if request.stopsAtChapterShorterThan300Characters, text.count < 300 {
                firstShortNumber = number
                break
            }
            if request.excludesEmptyChapters, text.isEmpty {
                emptyExcludedNumbers.append(number)
                continue
            }

            if request.includesChapterTitles {
                chunks.append("\(chapter.prefix)\n\n\(text)")
            } else {
                chunks.append(text)
            }
            includedIDs.append(chapter.document.id)
            includedNumbers.append(number)
        }

        guard let firstIncluded = includedNumbers.first,
              let lastIncluded = includedNumbers.last
        else {
            throw ManuscriptExportError.noChaptersIncluded
        }
        try Task.checkCancellation()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: request.destinationDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ManuscriptExportError.destinationDirectoryMissing(
                request.destinationDirectoryURL.path
            )
        }

        let outputName = "\(project.name)(\(firstIncluded)~\(lastIncluded)화).\(request.format.fileExtension)"
        try pathPolicy.validateName(outputName)
        let outputURL = request.destinationDirectoryURL.appendingPathComponent(outputName)
        let temporaryURL = request.destinationDirectoryURL.appendingPathComponent(
            ".writerpad-export-\(uuidGenerator.makeUUID().uuidString.lowercased()).tmp"
        )
        let combinedText = chunks.joined(separator: "\n\n")
        do {
            switch request.format {
            case .plainText:
                try writer.writeTemporaryFile(
                    data: Data(combinedText.utf8),
                    at: temporaryURL
                )
            case .pdf:
                try ManuscriptPDFRenderer().render(
                    combinedText,
                    to: temporaryURL
                )
                try writer.synchronizeFile(at: temporaryURL)
            }
            try Task.checkCancellation()
            try writer.replaceItem(at: outputURL, with: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        return ExportReport(
            outputURL: outputURL,
            requestedScope: request.scope,
            format: request.format,
            exportedDocumentIDs: includedIDs,
            firstIncludedChapterNumber: firstIncluded,
            lastIncludedChapterNumber: lastIncluded,
            missingChapterNumbers: missingNumbers,
            emptyExcludedChapterNumbers: emptyExcludedNumbers,
            firstShortChapterNumber: firstShortNumber
        )
    }

    private func chapterIdentity(for document: DocumentNode) -> ManuscriptChapterIdentity? {
        guard document.kind == .text, case .active = document.deletionStatus else { return nil }
        let components = document.relativePath.rawValue.split(separator: "/").map(String.init)
        guard components.count == 4,
              components[0] == "메인",
              components[1] == "원고",
              binderRules.volumeNumber(fromStoredName: components[2]) != nil
        else { return nil }
        return binderRules.titledChapterIdentity(fromStoredName: components[3])
    }
}

actor ManuscriptExportStaging {
    private let fileManager: FileManager
    private let uuidGenerator: any UUIDGenerating

    init(
        fileManager: FileManager = .default,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator()
    ) {
        self.fileManager = fileManager
        self.uuidGenerator = uuidGenerator
    }

    func createTemporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "WriterPad-Manuscript-Export-\(uuidGenerator.makeUUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func loadOutputData(from url: URL) throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func removeTemporaryDirectory(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}

private struct ManuscriptPDFRenderer {
    private let pageBounds = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let pageMargin: CGFloat = 54

    func render(_ text: String, to outputURL: URL) throws {
        var mediaBox = pageBounds
        guard let context = CGContext(
            outputURL as CFURL,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw ManuscriptExportError.pdfCreationFailed
        }

        do {
            try renderPages(text, in: context)
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }

        guard let document = CGPDFDocument(outputURL as CFURL),
              document.numberOfPages > 0
        else {
            throw ManuscriptExportError.pdfCreationFailed
        }
    }

    private func renderPages(
        _ text: String,
        in context: CGContext
    ) throws {
        let font = CTFontCreateWithName(
            "AppleSDGothicNeo-Regular" as CFString,
            11,
            nil
        )
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let textBounds = pageBounds.insetBy(dx: pageMargin, dy: pageMargin)
        let fullLength = attributedText.length
        var location = 0

        if fullLength == 0 {
            context.beginPDFPage(nil)
            context.endPDFPage()
            return
        }

        while location < fullLength {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            let path = CGMutablePath()
            path.addRect(textBounds)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else {
                context.endPDFPage()
                throw ManuscriptExportError.pdfCreationFailed
            }
            CTFrameDraw(frame, context)
            context.endPDFPage()
            location += visibleRange.length
        }
    }
}
