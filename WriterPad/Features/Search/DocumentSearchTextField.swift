import SwiftUI
import UIKit

@MainActor
final class DocumentSearchUITextView: UITextView {
    var onHardwareReturn: () -> Void = {}
    var onHardwareEscape: () -> Void = {}
    private let placeholderLabel = UILabel()

    var placeholder: String? {
        didSet {
            placeholderLabel.text = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        placeholderLabel.font = UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        placeholderLabel.frame = CGRect(
            x: inset.left + textContainer.lineFragmentPadding,
            y: inset.top,
            width: max(0, bounds.width - inset.left - inset.right),
            height: 24
        )
    }

    override var keyCommands: [UIKeyCommand]? {
        let escapeCommand = UIKeyCommand(
            input: UIKeyCommand.inputEscape,
            modifierFlags: [],
            action: #selector(handleHardwareEscape)
        )
        escapeCommand.discoverabilityTitle = "검색 닫기"
        escapeCommand.wantsPriorityOverSystemBehavior = true
        let inheritedCommands = (super.keyCommands ?? []).filter { command in
            command.input != UIKeyCommand.inputEscape
                || !command.modifierFlags.intersection(
                    [.command, .shift, .control, .alternate]
                ).isEmpty
        }
        return inheritedCommands + [escapeCommand]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let escapePresses = presses.filter { press in
            press.key?.keyCode == .keyboardEscape
                || press.key?.charactersIgnoringModifiers == UIKeyCommand.inputEscape
        }
        if !escapePresses.isEmpty {
            onHardwareEscape()
            let remainingPresses = presses.subtracting(escapePresses)
            if !remainingPresses.isEmpty {
                super.pressesBegan(remainingPresses, with: event)
            }
            return
        }
        let returnPresses = presses.filter { press in
            guard let characters = press.key?.charactersIgnoringModifiers else { return false }
            return characters == "\r" || characters == "\n"
        }
        if !returnPresses.isEmpty {
            onHardwareReturn()
            let remainingPresses = presses.subtracting(returnPresses)
            if !remainingPresses.isEmpty {
                super.pressesBegan(remainingPresses, with: event)
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func insertText(_ text: String) {
        // 일부 입력 경로는 pressesBegan 없이 UIKeyInput 문자로 전달된다.
        // 기본 삽입을 막아 first responder를 유지한다.
        if text == "\n" || text == "\r" {
            onHardwareReturn()
            return
        }
        if text == "\u{1B}" {
            onHardwareEscape()
            return
        }
        super.insertText(text)
        updatePlaceholderVisibility()
    }

    @objc func handleHardwareEscape() {
        if isFirstResponder {
            resignFirstResponder()
        }
        onHardwareEscape()
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }
}

struct DocumentSearchTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder = "현재 문서에서 찾기"
    var accessibilityIdentifier = "writerpad.document-search-field"
    var minimumHeight: CGFloat = 32
    var maximumHeight: CGFloat = 88
    var verticalTextInset: CGFloat = 5
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> DocumentSearchUITextView {
        let textView = DocumentSearchUITextView()
        textView.delegate = context.coordinator
        textView.onHardwareReturn = onSubmit
        textView.onHardwareEscape = onCancel
        textView.placeholder = placeholder
        textView.backgroundColor = .clear
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(
            top: verticalTextInset,
            left: 0,
            bottom: verticalTextInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byCharWrapping
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.returnKeyType = .search
        textView.enablesReturnKeyAutomatically = false
        textView.accessibilityIdentifier = accessibilityIdentifier
        return textView
    }

    func updateUIView(_ textView: DocumentSearchUITextView, context: Context) {
        context.coordinator.parent = self
        textView.onHardwareReturn = onSubmit
        textView.onHardwareEscape = onCancel
        textView.placeholder = placeholder
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.textContainerInset = UIEdgeInsets(
            top: verticalTextInset,
            left: 0,
            bottom: verticalTextInset,
            right: 0
        )
        if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
            textView.updatePlaceholderVisibility()
        }
        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        } else if !isFocused, textView.isFirstResponder {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak textView, weak coordinator] in
                guard let textView,
                      let coordinator,
                      !coordinator.parent.isFocused,
                      textView.isFirstResponder
                else { return }
                textView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(
        _ textView: DocumentSearchUITextView,
        coordinator: Coordinator
    ) {
        textView.onHardwareReturn = {}
        textView.onHardwareEscape = {}
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        textView.delegate = nil
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: DocumentSearchUITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(
            width: width,
            height: min(max(fittingSize.height, minimumHeight), maximumHeight)
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: DocumentSearchTextField

        init(parent: DocumentSearchTextField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? DocumentSearchUITextView)?.updatePlaceholderVisibility()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !parent.isFocused else { return }
            DispatchQueue.main.async { self.parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard parent.isFocused else { return }
            DispatchQueue.main.async { self.parent.isFocused = false }
        }
    }
}
