import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ManuscriptExportPreparationError: LocalizedError {
    case compositionActive
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .compositionActive:
            return "한글 조합 입력을 마친 뒤 다시 내보내 주세요."
        case .saveFailed:
            return "최신 원고를 저장하지 못해 내보내기를 중단했습니다. 저장 상태를 확인해 주세요."
        }
    }
}

enum ManuscriptExportPipeline {
    @MainActor
    static func run(
        request: ExportRequest,
        exporter: any Exporting,
        prepare: @MainActor () async throws -> Void
    ) async throws -> ExportReport {
        try await prepare()
        try Task.checkCancellation()
        return try await exporter.export(request)
    }
}

enum ManuscriptExportRangeInput {
    static func resolvedScope(
        startText: String,
        endText: String,
        lastChapterNumber: Int?
    ) -> ManuscriptExportScope? {
        guard let lastChapterNumber, lastChapterNumber > 0 else { return nil }
        let start = startText.isEmpty ? 1 : Int(startText)
        let end = endText.isEmpty ? max(2, lastChapterNumber) : Int(endText)
        guard let start, let end, start > 0, end > start else { return nil }
        return .range(start: start, end: end)
    }

    static func normalizedEnd(_ proposedEnd: Int, start: Int) -> Int {
        max(proposedEnd, start + 1)
    }

    static func appending(_ digit: String, to value: String) -> String {
        guard value.count < 6 else { return value }
        return value == "0" ? digit : value + digit
    }
}

struct ExportContentSectionTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

struct ChapterNumberPad: View {
    let title: String
    @Binding var value: String
    let placeholder: String
    let onDone: () -> Void

    private let rows = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"]
    ]

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(value.isEmpty ? placeholder : value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
            }

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { digit in
                        keypadButton(digit) {
                            append(digit)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                keypadButton("지우기", systemImage: "delete.left") {
                    removeLast()
                }
                keypadButton("0") {
                    append("0")
                }
                keypadButton("완료", tint: .writerPadAccent) {
                    onDone()
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .background {
            HardwareNumberKeyCapture(
                onDigit: append,
                onDelete: removeLast,
                onDone: onDone
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityHidden(true)
        }
    }

    private func keypadButton(
        _ title: String,
        systemImage: String? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 38)
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .background(
                tint ?? Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func append(_ digit: String) {
        value = ManuscriptExportRangeInput.appending(digit, to: value)
    }

    private func removeLast() {
        guard !value.isEmpty else { return }
        value.removeLast()
    }
}

private struct HardwareNumberKeyCapture: UIViewRepresentable {
    let onDigit: (String) -> Void
    let onDelete: () -> Void
    let onDone: () -> Void

    func makeUIView(context: Context) -> HardwareNumberKeyCaptureView {
        let view = HardwareNumberKeyCaptureView()
        updateCallbacks(on: view)
        return view
    }

    func updateUIView(_ view: HardwareNumberKeyCaptureView, context: Context) {
        updateCallbacks(on: view)
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil, !view.isFirstResponder else { return }
            view.becomeFirstResponder()
        }
    }

    static func dismantleUIView(_ view: HardwareNumberKeyCaptureView, coordinator: ()) {
        view.resignFirstResponder()
    }

    private func updateCallbacks(on view: HardwareNumberKeyCaptureView) {
        view.onDigit = onDigit
        view.onDelete = onDelete
        view.onDone = onDone
    }
}

private final class HardwareNumberKeyCaptureView: UIView {
    var onDigit: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onDone: (() -> Void)?
    private let suppressedSoftwareKeyboard = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool { true }
    override var inputView: UIView? { suppressedSoftwareKeyboard }

    override var keyCommands: [UIKeyCommand]? {
        let digits = (0...9).map { digit in
            UIKeyCommand(
                input: String(digit),
                modifierFlags: [],
                action: #selector(handleDigit(_:))
            )
        }
        return digits + [
            UIKeyCommand(
                input: UIKeyCommand.inputDelete,
                modifierFlags: [],
                action: #selector(handleDelete)
            ),
            UIKeyCommand(
                input: "\r",
                modifierFlags: [],
                action: #selector(handleDone)
            )
        ]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleDigit(_ command: UIKeyCommand) {
        guard let digit = command.input else { return }
        onDigit?(digit)
    }

    @objc private func handleDelete() {
        onDelete?()
    }

    @objc private func handleDone() {
        onDone?()
    }
}

struct ManuscriptExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .pdf] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
