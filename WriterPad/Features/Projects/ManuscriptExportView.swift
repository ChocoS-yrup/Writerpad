import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ManuscriptExportView: View {
    private enum FormatSelection: String, CaseIterable, Identifiable {
        case plainText = "TXT"
        case pdf = "PDF"

        var id: Self { self }

        var format: ManuscriptExportFormat {
            switch self {
            case .plainText: .plainText
            case .pdf: .pdf
            }
        }
    }

    private enum ScopeSelection: String, CaseIterable, Identifiable {
        case all = "전체"
        case range = "범위"

        var id: Self { self }
    }

    private enum ChapterNumberField {
        case start
        case end
    }

    @Environment(\.dismiss) private var dismiss
    let projectID: ProjectID
    let exporter: any Exporting
    let prepareForExport: @MainActor () async throws -> Void
    let loadLastChapterNumber: @MainActor () async throws -> Int
    private let staging = ManuscriptExportStaging()

    @State private var formatSelection = FormatSelection.plainText
    @State private var scopeSelection = ScopeSelection.all
    @State private var startChapter = ""
    @State private var endChapter = ""
    @State private var lastChapterNumber: Int?
    @State private var chapterNumberDraft = ""
    @AppStorage("writerpad.export.excludes-empty-chapters")
    private var excludesEmptyChapters = true
    @AppStorage("writerpad.export.includes-chapter-titles")
    private var includesChapterTitles = true
    @AppStorage("writerpad.export.stops-at-short-chapter")
    private var stopsAtShortChapter = true
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var report: ExportReport?
    @State private var preparedReport: ExportReport?
    @State private var savedURL: URL?
    @State private var preparedDocument: ManuscriptExportDocument?
    @State private var suggestedFileName = "원고.txt"
    @State private var isFileExporterPresented = false
    @State private var preparationTask: Task<Void, Never>?
    @State private var activeChapterNumberField: ChapterNumberField?
    @State private var contentSectionTop: CGFloat = 0

    var body: some View {
        NavigationStack {
            Form {
                formatSection
                scopeSection
                optionSection
                destinationSection
                if let report {
                    completionSection(report)
                }
            }
            .navigationTitle("원고 내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .disabled(isPreparing)
                }
            }
            .overlay {
                if isPreparing {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                        ProgressView("\(formatSelection.rawValue) 파일 만드는 중…")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
        .coordinateSpace(name: "writerpad-manuscript-export")
        .overlay {
            chapterNumberPadOverlay
        }
        .onPreferenceChange(ExportContentSectionTopPreferenceKey.self) { top in
            guard top > 0 else { return }
            contentSectionTop = top
        }
        .interactiveDismissDisabled(isPreparing)
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: preparedDocument,
            contentType: exportContentType,
            defaultFilename: suggestedFileName
        ) { result in
            handleFileExportResult(result)
        }
        .onChange(of: preparedDocument != nil) { _, isReady in
            guard isReady else { return }
            isFileExporterPresented = true
        }
        .alert(
            "원고 내보내기 실패",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "알 수 없는 오류")
        }
        .onDisappear {
            preparationTask?.cancel()
        }
        .task {
            guard lastChapterNumber == nil else { return }
            do {
                lastChapterNumber = max(1, try await loadLastChapterNumber())
            } catch {
                errorMessage = "원고 범위를 불러오지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    private var formatSection: some View {
        Section("파일 형식") {
            Picker("파일 형식", selection: $formatSelection) {
                ForEach(FormatSelection.allCases) { selection in
                    Text(selection.rawValue).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("writerpad.manuscript-export-format")
            .onChange(of: formatSelection) { _, _ in
                report = nil
                savedURL = nil
            }

            Text(
                formatSelection == .plainText
                    ? "UTF-8 일반 텍스트 파일로 저장합니다."
                    : "A4 규격의 읽기용 PDF 파일로 저장합니다."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var scopeSection: some View {
        Section("추출 범위") {
            Picker("범위", selection: $scopeSelection) {
                ForEach(ScopeSelection.allCases) { selection in
                    Text(selection.rawValue).tag(selection)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: scopeSelection) { _, _ in
                activeChapterNumberField = nil
                chapterNumberDraft = ""
                report = nil
                savedURL = nil
            }

            if scopeSelection == .range {
                HStack(spacing: 12) {
                    chapterField(
                        "시작 화",
                        field: .start,
                        displayValue: effectiveStartChapter
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    chapterField(
                        "종료 화",
                        field: .end,
                        displayValue: effectiveEndChapter
                    )
                }
            }
        }
    }

    private var optionSection: some View {
        Section {
            Toggle("화 제목 포함", isOn: $includesChapterTitles)
            Toggle("300자 미만 화에서 중단", isOn: $stopsAtShortChapter)
            Toggle("빈 화 제외", isOn: $excludesEmptyChapters)
                .disabled(stopsAtShortChapter)
            if stopsAtShortChapter {
                Text("빈 화는 300자 미만 중단 조건에 포함됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("공백과 줄바꿈도 글자 수에 포함하며, 기준에 못 미친 화와 이후 화는 추출하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("내용")
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ExportContentSectionTopPreferenceKey.self,
                            value: proxy.frame(
                                in: .named("writerpad-manuscript-export")
                            ).minY
                        )
                    }
                }
        }
    }

    private var destinationSection: some View {
        Section("저장 위치") {
            Button {
                beginPreparingExport()
            } label: {
                Label("내보내고 저장 위치 선택", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(isPreparing || validatedScope == nil)
            .accessibilityIdentifier("writerpad.manuscript-export-save")

            Text("다음 화면에서 파일 앱의 폴더와 파일명을 선택할 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func completionSection(_ report: ExportReport) -> some View {
        Section("완료 보고") {
            reportRow("파일 형식", value: report.format == .plainText ? "TXT" : "PDF")
            reportRow("지정 범위", value: scopeDescription(report.requestedScope))
            reportRow("실제 포함", value: "\(report.exportedDocumentIDs.count)화")
            reportRow("마지막 포함", value: "\(report.lastIncludedChapterNumber)화")
            reportRow("없는 화", value: chapterList(report.missingChapterNumbers))
            reportRow("빈 문서 제외", value: chapterList(report.emptyExcludedChapterNumbers))
            reportRow(
                "300자 미만 중단",
                value: report.firstShortChapterNumber.map { "\($0)화" } ?? "없음"
            )
            reportRow(
                "저장 위치",
                value: savedURL?.path(percentEncoded: false) ?? "저장 위치 선택 중"
            )
        }
    }

    private func chapterField(
        _ title: String,
        field: ChapterNumberField,
        displayValue: String
    ) -> some View {
        Button {
            chapterNumberDraft = ""
            activeChapterNumberField = field
        } label: {
            Text(displayValue)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(displayValue)
    }

    @ViewBuilder
    private var chapterNumberPadOverlay: some View {
        if let activeChapterNumberField {
            GeometryReader { proxy in
                let overlayTop = proxy.frame(
                    in: .named("writerpad-manuscript-export")
                ).minY
                let alignedContentTop = contentSectionTop - overlayTop
                let keypadTop = min(
                    max(alignedContentTop, 16),
                    max(16, proxy.size.height - 260)
                )

                ZStack(alignment: .top) {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            chapterNumberDraft = ""
                            self.activeChapterNumberField = nil
                        }

                    ChapterNumberPad(
                        title: activeChapterNumberField == .start ? "시작 화" : "종료 화",
                        value: $chapterNumberDraft,
                        placeholder: activeChapterNumberField == .start
                            ? effectiveStartChapter
                            : effectiveEndChapter,
                        onDone: {
                            completeChapterNumberEntry(activeChapterNumberField)
                        }
                    )
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
                    .padding(.top, keypadTop)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
            .zIndex(10)
        }
    }

    private func reportRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var validatedScope: ManuscriptExportScope? {
        switch scopeSelection {
        case .all:
            return .all
        case .range:
            return ManuscriptExportRangeInput.resolvedScope(
                startText: startChapter,
                endText: endChapter,
                lastChapterNumber: lastChapterNumber
            )
        }
    }

    private var effectiveStartChapter: String {
        startChapter.isEmpty ? "1" : startChapter
    }

    private var effectiveEndChapter: String {
        if !endChapter.isEmpty {
            return endChapter
        }
        return String(max(2, lastChapterNumber ?? 1))
    }

    private func completeChapterNumberEntry(_ field: ChapterNumberField) {
        defer {
            chapterNumberDraft = ""
            activeChapterNumberField = nil
        }
        guard let entered = Int(chapterNumberDraft), entered > 0 else { return }

        switch field {
        case .start:
            startChapter = String(entered)
            let currentEnd = Int(effectiveEndChapter) ?? entered + 1
            if currentEnd <= entered {
                endChapter = String(entered + 1)
            }
        case .end:
            let currentStart = Int(effectiveStartChapter) ?? 1
            endChapter = String(
                ManuscriptExportRangeInput.normalizedEnd(
                    entered,
                    start: currentStart
                )
            )
        }
    }

    private func beginPreparingExport() {
        guard !isPreparing, let scope = validatedScope else { return }
        errorMessage = nil
        report = nil
        preparedReport = nil
        preparedDocument = nil
        isFileExporterPresented = false
        savedURL = nil
        isPreparing = true
        preparationTask = Task {
            await prepareExport(scope: scope)
        }
    }

    @MainActor
    private func prepareExport(scope: ManuscriptExportScope) async {
        let temporaryDirectory: URL

        do {
            temporaryDirectory = try await staging.createTemporaryDirectory()
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            preparationTask = nil
            return
        }

        do {
            let exportReport = try await ManuscriptExportPipeline.run(
                request: ExportRequest(
                    projectID: projectID,
                    scope: scope,
                    format: formatSelection.format,
                    excludesEmptyChapters: excludesEmptyChapters,
                    includesChapterTitles: includesChapterTitles,
                    stopsAtChapterShorterThan300Characters: stopsAtShortChapter,
                    destinationDirectoryURL: temporaryDirectory
                ),
                exporter: exporter,
                prepare: prepareForExport
            )
            try Task.checkCancellation()
            let outputURL = exportReport.outputURL
            let data = try await staging.loadOutputData(from: outputURL)
            try Task.checkCancellation()

            preparedDocument = ManuscriptExportDocument(data: data)
            suggestedFileName = exportReport.outputURL.deletingPathExtension().lastPathComponent
            preparedReport = exportReport
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            try await staging.removeTemporaryDirectory(at: temporaryDirectory)
        } catch {
            // 앱의 임시 영역은 시스템이 회수한다. 완성된 내보내기 데이터를
            // 버리거나 사용자 저장 화면을 막을 정도의 실패는 아니다.
        }
        isPreparing = false
        preparationTask = nil
    }

    private func handleFileExportResult(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            savedURL = url
            report = preparedReport
        case let .failure(error):
            report = nil
            savedURL = nil
            let cocoaError = error as NSError
            if cocoaError.domain != NSCocoaErrorDomain
                || cocoaError.code != CocoaError.Code.userCancelled.rawValue {
                errorMessage = error.localizedDescription
            }
        }
        preparedDocument = nil
        preparedReport = nil
    }

    private func scopeDescription(_ scope: ManuscriptExportScope) -> String {
        switch scope {
        case .all:
            return "전체 원고"
        case let .range(start, end):
            return "\(start)~\(end)화"
        }
    }

    private func chapterList(_ numbers: [Int]) -> String {
        numbers.isEmpty ? "없음" : numbers.map { "\($0)화" }.joined(separator: ", ")
    }

    private var exportContentType: UTType {
        formatSelection == .plainText ? .plainText : .pdf
    }
}
