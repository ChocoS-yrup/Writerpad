import SwiftUI
import UIKit
import CoreText

/// UIKit이 문서 본문을 다시 받아야 하는지를 외부 버전과 문서 ID로 판정한다.
struct EditorExternalSnapshot: Equatable, Sendable {
    let documentID: DocumentID
    let version: UInt64
}

enum EditorExternalUpdateDecision: Equatable, Sendable {
    case none
    case applyDocument
    case applyVersion
    case deferForComposition
}

struct EditorExternalUpdateTracker: Sendable {
    private(set) var appliedSnapshot: EditorExternalSnapshot?

    mutating func decision(
        for incoming: EditorExternalSnapshot,
        isComposing: Bool
    ) -> EditorExternalUpdateDecision {
        guard appliedSnapshot != incoming else { return .none }
        guard !isComposing else { return .deferForComposition }

        let decision: EditorExternalUpdateDecision =
            appliedSnapshot?.documentID == incoming.documentID ? .applyVersion : .applyDocument
        appliedSnapshot = incoming
        return decision
    }
}

enum EditorFocusPhase: Equatable, Sendable {
    case idle
    case focused
    case composing
    case backgrounded
    case restoring
}

enum EditorFocusEvent: Equatable, Sendable {
    case focusGained
    case focusLost
    case compositionStarted
    case compositionEnded
    case sceneBecameInactive
    case sceneBecameActive(hasDocument: Bool)
}

enum EditorFocusEffect: Equatable, Sendable {
    case requestFocus
    case completePendingTransition
}

struct EditorFocusStateMachine: Sendable {
    private(set) var phase: EditorFocusPhase = .idle
    private var shouldRestoreFocus = false

    mutating func handle(_ event: EditorFocusEvent) -> [EditorFocusEffect] {
        switch event {
        case .focusGained:
            phase = .focused
            return []
        case .focusLost:
            if phase != .backgrounded {
                phase = .idle
            }
            return []
        case .compositionStarted:
            if phase != .backgrounded {
                phase = .composing
            }
            return []
        case .compositionEnded:
            if phase != .backgrounded {
                phase = .focused
            }
            return [.completePendingTransition]
        case .sceneBecameInactive:
            shouldRestoreFocus = phase == .focused || phase == .composing || phase == .restoring
            phase = .backgrounded
            return []
        case let .sceneBecameActive(hasDocument):
            defer { shouldRestoreFocus = false }
            guard hasDocument, shouldRestoreFocus else {
                phase = .idle
                return []
            }
            phase = .restoring
            return [.requestFocus]
        }
    }
}

struct CompositionSessionTracker: Equatable, Sendable {
    private(set) var anchor: UInt?

    mutating func update(
        markedRange: TextCursorState?,
        selection: TextCursorState
    ) -> TextCursorState? {
        if let markedRange {
            anchor = min(anchor ?? markedRange.location, markedRange.location)
            return nil
        }
        guard let anchor else { return nil }
        self.anchor = nil
        guard selection.selectionLength == 0, selection.location >= anchor else { return nil }
        return TextCursorState(
            location: anchor,
            selectionLength: selection.location - anchor
        )
    }
}

/// WriterPad의 일반 텍스트 편집 표면이다. 저장과 스마트 입력 규칙은 이 타입에 넣지 않는다.
@MainActor
class SmartTextView: UITextView {
    private let placeholderLabel = UILabel()
    private var placeholderTopConstraint: NSLayoutConstraint?
    private var placeholderLeadingConstraint: NSLayoutConstraint?
    private var placeholderTrailingConstraint: NSLayoutConstraint?
    private(set) var appliedAppearance: EditorAppearanceSettings?
    private(set) var fullTextAssignmentCount = 0
    private(set) var temporarySearchHighlightRanges: [NSRange] = []
    private(set) var temporaryCurrentSearchHighlightRange: NSRange?
    private(set) var isPerformingPlainTextPaste = false
    private(set) var fullDocumentLayoutCount = 0
    private(set) var documentEndLayoutPreparationCount = 0
    private(set) var directionalNavigationLayoutPreparationCount = 0
    var isHandlingDirectionalArrowKey = false
    private var requiresDeferredTextLayoutRefresh = true
    private var requiresContentSizeRefresh = true
    private var lastLaidOutTextContainerWidth: CGFloat = -1

    var onEditorCommand: (WriterPadEditorCommand) -> Void = { _ in }

    private var exposesScrollDiagnostics: Bool {
        ProcessInfo.processInfo.arguments.contains("-WriterPadScrollDiagnostics")
    }

    func refreshScrollDiagnostics() {
        guard exposesScrollDiagnostics else { return }
        let inset = adjustedContentInset
        let maximumY = max(
            -inset.top,
            contentSize.height - bounds.height + inset.bottom
        )
        accessibilityLabel = String(
            format: "offset=%.1f max=%.1f content=%.1f bounds=%.1f enabled=%@ pan=%ld",
            contentOffset.y,
            maximumY,
            contentSize.height,
            bounds.height,
            isScrollEnabled ? "true" : "false",
            panGestureRecognizer.state.rawValue
        )
    }

    /// 넓은 행간으로 계산된 네이티브 커서를 본문 폰트 높이로 줄인다.
    /// 실제 글리프 영역을 사용해 폰트 크기·종류가 바뀌어도 세로 위치를 맞춘다.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let nativeRect = super.caretRect(for: position)
        var rect = nativeRect
        guard let textFont = (typingAttributes[.font] as? UIFont) ?? font else {
            return rect
        }

        let glyphTopInset = max(0, textFont.ascender - textFont.capHeight)
        let glyphHeight = max(2, textFont.capHeight - textFont.descender)
        let targetHeight = glyphHeight * 1.12
        let expansion = targetHeight - glyphHeight
        let verticalOffset = max(0, glyphTopInset - expansion / 2)
        let availableHeight = max(2, rect.height - verticalOffset)
        rect.origin.y += min(verticalOffset, max(0, rect.height - 2))
        rect.size.height = min(targetHeight, availableHeight)
        let upwardExpansion = min(
            rect.height * 0.15,
            max(0, rect.minY - nativeRect.minY)
        )
        rect.origin.y -= upwardExpansion
        rect.size.height += upwardExpansion
        return rect
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            keyCommand(
                input: "s",
                modifierFlags: .command,
                title: "저장"
            ),
            keyCommand(
                input: "f",
                modifierFlags: .command,
                title: "현재 문서에서 찾기"
            ),
            keyCommand(
                input: "f",
                modifierFlags: [.command, .shift],
                title: "작품 전체에서 찾기"
            ),
            keyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                title: "검색 닫기"
            ),
            keyCommand(
                input: "b",
                modifierFlags: .command,
                title: "바인더 토글"
            ),
            keyCommand(
                input: "\\",
                modifierFlags: .command,
                title: "듀얼 편집기 토글"
            ),
            keyCommand(
                input: "\t",
                modifierFlags: [],
                title: "편집기 창 전환",
                wantsPriorityOverSystemBehavior: true
            ),
            keyCommand(
                input: "[",
                modifierFlags: .command,
                title: "이전 화"
            ),
            keyCommand(
                input: "]",
                modifierFlags: .command,
                title: "다음 화"
            )
        ]
    }

    private func keyCommand(
        input: String,
        modifierFlags: UIKeyModifierFlags,
        title: String,
        wantsPriorityOverSystemBehavior: Bool = false
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            input: input,
            modifierFlags: modifierFlags,
            action: #selector(handleWriterPadKeyCommand(_:))
        )
        command.discoverabilityTitle = title
        command.wantsPriorityOverSystemBehavior = wantsPriorityOverSystemBehavior
        return command
    }

    var placeholderText: String = "" {
        didSet {
            placeholderLabel.text = placeholderText
            refreshPlaceholderVisibility()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        refreshScrollDiagnostics()

        let currentWidth = textContainer.size.width
        let widthChanged = abs(currentWidth - lastLaidOutTextContainerWidth) > 0.5
        let shouldInvalidateLayout = requiresDeferredTextLayoutRefresh || widthChanged
        guard shouldInvalidateLayout || requiresContentSizeRefresh else { return }

        requiresDeferredTextLayoutRefresh = false
        requiresContentSizeRefresh = false
        lastLaidOutTextContainerWidth = currentWidth
        guard shouldInvalidateLayout else {
            // 직접 입력은 UIKit이 변경 범위와 가시 영역의 레이아웃을 이미 갱신한다.
            // 여기서 textContainer 전체를 강제 완료하면 원고 길이에 비례해 입력이 느려진다.
            refreshScrollDiagnostics()
            return
        }

        let documentRange = NSRange(location: 0, length: textStorage.length)
        if documentRange.length > 0 {
            layoutManager.invalidateLayout(
                forCharacterRange: documentRange,
                actualCharacterRange: nil
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        fullDocumentLayoutCount += 1
        refreshContentSizeFromTextLayout()
        isScrollEnabled = true
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = true
        setNeedsDisplay()
        refreshScrollDiagnostics()
        // 위에서 확정한 TextKit 높이를 다음 UIKit 레이아웃 패스에서
        // UIScrollView.contentSize에 반영한다.
        setNeedsLayout()
    }

    /// 문서 전체 교체 뒤 UIKit이 간헐적으로 `contentSize.height`를 0으로 되돌리는
    /// 경우가 있다. TextKit이 계산한 실제 글리프 높이를 스크롤 범위의 기준으로 삼아
    /// 자동 줄바꿈 원고도 화 전환 뒤 계속 스크롤할 수 있게 한다.
    private func refreshContentSizeFromTextLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let usedRect = layoutManager.usedRect(for: textContainer)
        let laidOutHeight = ceil(
            usedRect.maxY + textContainerInset.top + textContainerInset.bottom
        )
        let requiredHeight = max(bounds.height, laidOutHeight)
        guard abs(contentSize.height - requiredHeight) > 0.5
                || abs(contentSize.width - bounds.width) > 0.5
        else { return }
        contentSize = CGSize(width: bounds.width, height: requiredHeight)
    }

    func requestDeferredTextLayoutRefresh() {
        requiresDeferredTextLayoutRefresh = true
        requiresContentSizeRefresh = true
        setNeedsLayout()
    }

    /// 직접 입력으로 줄 수가 바뀌면 전체 스크롤 범위만 갱신한다.
    /// 현재 보이는 위치는 `layoutSubviews`에서 보존해 UIKit의 커서 스크롤과 경쟁하지 않는다.
    func requestContentSizeRefresh() {
        requiresContentSizeRefresh = true
        setNeedsLayout()
    }

    /// 비연속 레이아웃 상태에서도 저장된 커서가 있는 먼 구간을 직접 준비한다.
    /// 해당 글리프의 끝까지 스크롤 범위를 확장해 임시 contentSize의 최댓값에 걸리지 않게 한다.
    func prepareViewportLayout(around selection: NSRange) {
        guard textStorage.length > 0 else { return }
        let location = min(max(0, selection.location), textStorage.length - 1)
        let characterRange = NSRange(location: location, length: 1)
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        let laidOutMaxY = max(
            glyphRect.maxY,
            layoutManager.extraLineFragmentUsedRect.maxY
        )
        let requiredHeight = ceil(
            laidOutMaxY + textContainerInset.top + textContainerInset.bottom
        )
        if requiredHeight > contentSize.height {
            contentSize.height = requiredHeight
        }
    }

    /// 비연속 레이아웃 경계에서 물리 방향키가 다음 화면 단위로 건너뛰지
    /// 않도록 현재 커서 앞뒤의 제한된 구간만 미리 준비한다.
    func prepareDirectionalNavigationLayout() {
        guard textStorage.length > 0 else { return }
        let location = min(max(0, selectedRange.location), textStorage.length)
        let radius = 4_096
        let lowerBound = max(0, location - radius)
        let upperBound = min(textStorage.length, location + radius)
        var range = NSRange(
            location: lowerBound,
            length: upperBound - lowerBound
        )
        if range.length > 0 {
            range = (textStorage.string as NSString)
                .rangeOfComposedCharacterSequences(for: range)
            layoutManager.ensureLayout(forCharacterRange: range)
            directionalNavigationLayoutPreparationCount += 1
        }
    }

    /// 비연속 레이아웃이 빠른 스크롤로 건너뛴 구간을 뒤늦게 계산하며 전체 높이를
    /// 늘리지 않도록, 입력이 멈춘 뒤 스크롤 범위를 한 번만 완전히 확정한다.
    func prepareDocumentEndLayout() {
        guard textStorage.length > 0 else { return }
        let preservedOffset = contentOffset
        documentEndLayoutPreparationCount += 1
        UIView.performWithoutAnimation {
            layoutManager.ensureLayout(
                forCharacterRange: NSRange(
                    location: 0,
                    length: textStorage.length
                )
            )
            refreshContentSizeFromTextLayout()

            let inset = adjustedContentInset
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                contentSize.height - bounds.height + inset.bottom
            )
            let restoredY = min(max(preservedOffset.y, minimumY), maximumY)
            if abs(contentOffset.y - restoredY) > 0.5 {
                setContentOffset(
                    CGPoint(x: preservedOffset.x, y: restoredY),
                    animated: false
                )
            }
        }
    }

    func applyExternalText(
        _ newText: String,
        selection: TextCursorState,
        clearsUndoHistory: Bool
    ) {
        if text != newText {
            text = newText
            fullTextAssignmentCount += 1
            // UITextView의 전체 문자열 교체는 기존 표시 속성을 잃을 수 있다.
            // 같은 설정값이어도 새 문서에는 다시 적용되도록 캐시만 무효화한다.
            appliedAppearance = nil
        }
        requestDeferredTextLayoutRefresh()
        selectedRange = Self.clampedRange(
            selection,
            utf16Length: textStorage.length
        )
        if clearsUndoHistory {
            undoManager?.removeAllActions()
        }
        refreshVisualAppearance()
        refreshPlaceholderVisibility()
    }

    /// 같은 문서를 표시하는 다른 패널의 한 번의 편집만 TextKit 저장소에 반영한다.
    /// 버전이 연속되지 않거나 범위가 맞지 않으면 호출자가 전체 본문 동기화로 복구한다.
    @discardableResult
    func applyExternalTextMutation(
        _ mutation: SharedEditorTextChange.Mutation,
        expectedUTF16Length: Int?,
        selection: TextCursorState
    ) -> Bool {
        let range = NSRange(
            location: Int(clamping: mutation.range.location),
            length: Int(clamping: mutation.range.selectionLength)
        )
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= textStorage.length
        else { return false }

        let attributedReplacement = NSAttributedString(
            string: mutation.replacementText,
            attributes: typingAttributes
        )
        textStorage.replaceCharacters(in: range, with: attributedReplacement)
        if let expectedUTF16Length,
           textStorage.length != expectedUTF16Length {
            return false
        }
        requestDeferredTextLayoutRefresh()
        selectedRange = Self.clampedRange(
            selection,
            utf16Length: textStorage.length
        )
        refreshVisualAppearance()
        refreshPlaceholderVisibility()
        return true
    }

    func setTemporarySearchHighlights(_ ranges: [NSRange], current: NSRange? = nil) {
        let wholeDocument = NSRange(location: 0, length: textStorage.length)
        let manager = undoManager
        let shouldRestoreUndoRegistration = manager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            manager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                manager?.enableUndoRegistration()
            }
        }
        textStorage.removeAttribute(.backgroundColor, range: wholeDocument)
        temporarySearchHighlightRanges = ranges.filter {
            $0.location >= 0 && $0.length > 0 && NSMaxRange($0) <= textStorage.length
        }
        temporaryCurrentSearchHighlightRange = current.flatMap { range in
            guard range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= textStorage.length
            else { return nil }
            return range
        }
        for range in temporarySearchHighlightRanges {
            textStorage.addAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.32),
                range: range
            )
        }
        if let temporaryCurrentSearchHighlightRange {
            textStorage.addAttribute(
                .backgroundColor,
                value: UIColor.systemOrange.withAlphaComponent(0.58),
                range: temporaryCurrentSearchHighlightRange
            )
        }
    }

    func performUndo() {
        undoManager?.undo()
    }

    func performRedo() {
        undoManager?.redo()
    }

    @objc private func handleWriterPadKeyCommand(_ command: UIKeyCommand) {
        let modifiers = command.modifierFlags.intersection(
            [.command, .shift, .control, .alternate]
        )
        let editorCommand: WriterPadEditorCommand?
        if command.input == "s", modifiers == .command {
            editorCommand = .save
        } else if command.input == "f", modifiers == .command {
            editorCommand = .find
        } else if command.input == "f", modifiers == [.command, .shift] {
            editorCommand = .findInProject
        } else if command.input == UIKeyCommand.inputEscape, modifiers.isEmpty {
            editorCommand = .closeFind
        } else if command.input == "b", modifiers == .command {
            editorCommand = .toggleBinder
        } else if command.input == "\\", modifiers == .command {
            editorCommand = .toggleSplit
        } else if command.input == "\t", modifiers.isEmpty {
            editorCommand = .toggleEditorPane
        } else if command.input == "[", modifiers == .command {
            editorCommand = .previousChapter
        } else if command.input == "]", modifiers == .command {
            editorCommand = .nextChapter
        } else {
            editorCommand = nil
        }
        if let editorCommand {
            onEditorCommand(editorCommand)
        }
    }

    func applyTextRuleResult(_ result: TextRuleResult) {
        guard result.handled else { return }
        if let edit = result.edit {
            replaceTextRegisteringUndo(
                range: NSRange(
                    location: Int(edit.range.location),
                    length: Int(edit.range.selectionLength)
                ),
                replacement: edit.replacement,
                selection: NSRange(
                    location: Int(result.selection.location),
                    length: Int(result.selection.selectionLength)
                )
            )
        } else {
            selectedRange = NSRange(
                location: Int(result.selection.location),
                length: Int(result.selection.selectionLength)
            )
            delegate?.textViewDidChangeSelection?(self)
        }
    }

    override func paste(_ sender: Any?) {
        guard let plainText = UIPasteboard.general.string else {
            super.paste(sender)
            return
        }
        isPerformingPlainTextPaste = true
        defer { isPerformingPlainTextPaste = false }
        insertText(plainText)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handlesDirectionalArrow = presses.contains { press in
            guard let keyCode = press.key?.keyCode else { return false }
            return keyCode == .keyboardUpArrow
                || keyCode == .keyboardDownArrow
                || keyCode == .keyboardLeftArrow
                || keyCode == .keyboardRightArrow
        }
        guard handlesDirectionalArrow else {
            super.pressesBegan(presses, with: event)
            return
        }

        isHandlingDirectionalArrowKey = true
        prepareDirectionalNavigationLayout()
        super.pressesBegan(presses, with: event)
        // 키 처리 중 UIKit이 선택 변경 콜백을 늦추는 경우에도 한 번은 확실히
        // 타자기 화면 위치를 새 커서에 맞춘다.
        delegate?.textViewDidChangeSelection?(self)
        isHandlingDirectionalArrowKey = false
    }

    func refreshPlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
        setNeedsLayout()
    }

    /// 본문 색상은 현재 시스템 외관에만 맞춘다.
    /// 색상 속성 변경 중에는 Undo 등록을 끄므로 원고 문자열과 Undo 이력에 남지 않는다.
    func refreshVisualAppearance() {
        textColor = .label
        tintColor = .systemBlue
        placeholderLabel.textColor = .placeholderText

        var attributes = typingAttributes
        attributes[.foregroundColor] = UIColor.label
        typingAttributes = attributes

        let documentRange = NSRange(location: 0, length: textStorage.length)
        guard documentRange.length > 0 else { return }
        let manager = undoManager
        let shouldRestoreUndoRegistration = manager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            manager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                manager?.enableUndoRegistration()
            }
        }
        textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: documentRange)
    }

    /// 글꼴과 문단 모양은 표시 속성으로만 적용하며 TXT 문자열에는 포함하지 않는다.
    func applyAppearance(_ appearance: EditorAppearanceSettings) {
        guard appearance != appliedAppearance else { return }
        appliedAppearance = appearance

        let baseFont: UIFont
        switch appearance.fontFamily {
        case .system:
            baseFont = .systemFont(ofSize: appearance.fontSize)
        case .serif:
            let descriptor = UIFont.systemFont(ofSize: appearance.fontSize)
                .fontDescriptor
                .withDesign(.serif)
            baseFont = descriptor.map { UIFont(descriptor: $0, size: appearance.fontSize) }
                ?? .systemFont(ofSize: appearance.fontSize)
        case .monospaced:
            baseFont = .monospacedSystemFont(ofSize: appearance.fontSize, weight: .regular)
        case .malgunGothic, .malgunGothicSemilight, .malgunGothicBold:
            baseFont = BundledEditorFonts.font(
                postScriptName: appearance.fontFamily.bundledPostScriptName ?? "",
                size: appearance.fontSize
            ) ?? .systemFont(ofSize: appearance.fontSize)
        }
        let styledFont: UIFont
        if appearance.isBold {
            styledFont = baseFont.fontDescriptor
                .withSymbolicTraits(baseFont.fontDescriptor.symbolicTraits.union(.traitBold))
                .map { UIFont(descriptor: $0, size: baseFont.pointSize) }
                ?? baseFont
        } else {
            styledFont = baseFont
        }
        let editorFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: styledFont)
        let paragraphStyle = NSMutableParagraphStyle()
        // lineHeightMultiple은 첫 줄 위에도 leading을 배분해 선택 핸들과 글자가
        // 어긋나 보인다. 동일한 줄 간격을 줄 아래 여백으로 적용한다.
        paragraphStyle.lineHeightMultiple = 1
        paragraphStyle.lineSpacing = editorFont.lineHeight * CGFloat(0.6 + appearance.lineSpacing / 100)
        paragraphStyle.lineBreakMode = .byWordWrapping

        font = editorFont
        placeholderLabel.font = editorFont
        textContainerInset = UIEdgeInsets(
            top: appearance.verticalInset,
            left: appearance.horizontalInset,
            bottom: appearance.verticalInset,
            right: appearance.horizontalInset
        )
        // 안내문도 본문과 동일한 textContainerInset을 단일 기준으로 사용한다.
        placeholderTopConstraint?.constant = appearance.verticalInset
        placeholderLeadingConstraint?.constant = appearance.horizontalInset
        placeholderTrailingConstraint?.constant = -appearance.horizontalInset

        var attributes = typingAttributes
        attributes[.font] = editorFont
        attributes[.paragraphStyle] = paragraphStyle
        attributes[.foregroundColor] = UIColor.label
        attributes[.kern] = -0.5
        typingAttributes = attributes

        let documentRange = NSRange(location: 0, length: textStorage.length)
        defer {
            if documentRange.length > 0 {
                layoutManager.invalidateLayout(
                    forCharacterRange: documentRange,
                    actualCharacterRange: nil
                )
            }
            requestDeferredTextLayoutRefresh()
            setNeedsDisplay()
        }
        guard documentRange.length > 0 else { return }
        let manager = undoManager
        let shouldRestoreUndoRegistration = manager?.isUndoRegistrationEnabled == true
        if shouldRestoreUndoRegistration {
            manager?.disableUndoRegistration()
        }
        defer {
            if shouldRestoreUndoRegistration {
                manager?.enableUndoRegistration()
            }
        }
        textStorage.addAttributes(
            [
                .font: editorFont,
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.label,
                .kern: -0.5
            ],
            range: documentRange
        )
    }

    func replaceTextRegisteringUndo(
        range: NSRange,
        replacement: String,
        selection: NSRange
    ) {
        guard range.location >= 0,
              range.length >= 0,
              NSMaxRange(range) <= textStorage.length,
              let swiftRange = Range(range, in: text)
        else {
            return
        }

        let removedText = String(text[swiftRange])
        let previousSelection = selectedRange
        let inverseRange = NSRange(location: range.location, length: replacement.utf16.count)
        undoManager?.registerUndo(withTarget: self) { target in
            target.replaceTextRegisteringUndo(
                range: inverseRange,
                replacement: removedText,
                selection: previousSelection
            )
        }
        undoManager?.setActionName("스마트 입력")

        // 빈 문서에는 새 문자열이 상속할 기존 글자 속성이 없다.
        // 스마트 쌍도 일반 입력과 동일한 typingAttributes로 삽입해야
        // 첫 글자부터 선택한 편집기 폰트와 문단 모양을 유지한다.
        let attributedReplacement = NSAttributedString(
            string: replacement,
            attributes: typingAttributes
        )
        textStorage.replaceCharacters(in: range, with: attributedReplacement)
        selectedRange = selection
        refreshVisualAppearance()
        refreshPlaceholderVisibility()
        delegate?.textViewDidChange?(self)
        delegate?.textViewDidChangeSelection?(self)
    }

    private func configure() {
        backgroundColor = .clear
        // 긴 원고의 아직 레이아웃되지 않은 먼 구간으로 이동할 때 앞부분 전체를
        // 먼저 계산하지 않고, 현재 필요한 구간을 독립적으로 레이아웃한다.
        layoutManager.allowsNonContiguousLayout = true
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textColor = .label
        tintColor = .systemBlue
        isScrollEnabled = true
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        // iPadOS의 오른쪽 가장자리 Slide Over 제스처와 스크롤 표시기 드래그가
        // 경쟁하지 않도록 표시기만 본문 여백 안쪽으로 이동한다.
        verticalScrollIndicatorInsets.right = 20
        allowsEditingTextAttributes = false
        textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 24, right: 16)
        textContainer.lineFragmentPadding = 0
        accessibilityLabel = "원고 편집기"

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        placeholderTopConstraint = placeholderLabel.topAnchor.constraint(
            equalTo: topAnchor,
            constant: 18
        )
        placeholderLeadingConstraint = placeholderLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: 16
        )
        placeholderTrailingConstraint = placeholderLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor,
            constant: -16
        )
        NSLayoutConstraint.activate(
            [
                placeholderTopConstraint,
                placeholderLeadingConstraint,
                placeholderTrailingConstraint
            ].compactMap { $0 }
        )
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SmartTextView, _) in
            view.refreshVisualAppearance()
        }
        refreshVisualAppearance()
        refreshPlaceholderVisibility()
    }

    private static func clampedRange(
        _ cursor: TextCursorState,
        utf16Length: Int
    ) -> NSRange {
        let safeUTF16Length = UInt(max(0, utf16Length))
        let location = min(cursor.location, safeUTF16Length)
        let selectionLength = min(cursor.selectionLength, safeUTF16Length - location)
        return NSRange(location: Int(location), length: Int(selectionLength))
    }
}

private enum BundledEditorFonts {
    private static let resources = ["malgun", "malgunbd", "malgunsl"]

    static func font(postScriptName: String, size: CGFloat) -> UIFont? {
        registerIfNeeded()
        return UIFont(name: postScriptName, size: size)
    }

    private static func registerIfNeeded() {
        _ = registrationAttempted
    }

    private static let registrationAttempted: Void = {
        for resource in resources {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf") else {
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
}

/// SwiftUI 상태와 단일 UITextView 인스턴스를 연결하는 TextKit 편집기다.
struct iPadTextEditor: UIViewRepresentable {
    @Binding var text: String
    let documentID: DocumentID
    let externalVersion: UInt64
    var externalTextMutation: SharedEditorTextChange.VersionedMutation? = nil
    var externalUTF16Length: Int? = nil
    @Binding var selection: TextCursorState
    let focusRequest: UInt64
    var compositionCommitRequest: UInt64 = 0
    var undoRequest: UInt64 = 0
    var redoRequest: UInt64 = 0
    var isActive: Bool = true
    var isReadOnly: Bool = false
    var appearance: EditorAppearanceSettings = .default
    var placeholder: String = "빈 문서입니다. 바로 입력을 시작하세요."
    var searchHighlightRanges: [NSRange] = []
    var currentSearchHighlightRange: NSRange?
    var searchNavigationRequest: UInt64 = 0
    var selectionNavigationRequest: UInt64 = 0
    var textRuleSettings: TextRuleSettings = .enabled
    /// 정상 입력은 전체 문자열 없이 mutation만 전달한다. TextKit이 단일 변경 범위를
    /// 제공하지 못한 예외 경로에서만 첫 번째 인자에 전체 복구 스냅샷이 들어온다.
    /// 변경이 실제로 발생한 UITextView의 문서 ID를 함께 전달한다. SwiftUI 모델이
    /// 먼저 다음 문서로 전환된 뒤 이전 UITextView의 지연 callback이 도착하더라도,
    /// 호출자가 이전 원고를 새 문서에 적용하지 않도록 문서 경계를 보존한다.
    var onTextChange:
        (DocumentID, String?, SharedEditorTextChange.Mutation?) -> Void =
            { _, _, _ in }
    var onEditorCommand: (WriterPadEditorCommand) -> Void = { _ in }
    var onCompositionStateChange: (DocumentID, Bool) -> Void = { _, _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SmartTextView {
        let textView = SmartTextView()
        textView.delegate = context.coordinator
        textView.textStorage.delegate = context.coordinator
        textView.onEditorCommand = self.onEditorCommand
        textView.accessibilityIdentifier = "writerpad.native-editor-text-view"
        context.coordinator.applyExternalState(to: textView)
        return textView
    }

    func updateUIView(_ textView: SmartTextView, context: Context) {
        context.coordinator.parent = self
        textView.onEditorCommand = onEditorCommand
        context.coordinator.applyExternalState(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, @preconcurrency NSTextStorageDelegate {
        static let maximumSynchronousTypewriterUTF16Length = 500_000

        private struct TextRuleContext {
            let text: String
            let utf16Location: UInt
        }

        var parent: iPadTextEditor
        private var tracker = EditorExternalUpdateTracker()
        private var lastFocusRequest: UInt64 = 0
        private var lastCompositionCommitRequest: UInt64 = 0
        private var lastUndoRequest: UInt64 = 0
        private var lastRedoRequest: UInt64 = 0
        private var lastSearchNavigationRequest: UInt64 = 0
        private var lastSelectionNavigationRequest: UInt64 = 0
        private var lastReportedCompositionState = false
        private var isApplyingExternalState = false
        private var compositionTracker = CompositionSessionTracker()
        private var isForcingShortcutCommit = false
        private static let maximumCompositionCommitAttempts = 4
        private static let compositionCommitReloadInterval = 8
        private var responderResignationGeneration: UInt64 = 0
        private var typewriterPaddingGeneration: UInt64 = 0
        private var viewportRestorationGeneration: UInt64 = 0
        private var documentEndLayoutGeneration: UInt64 = 0
        private var isUserScrolling = false
        private var didApplyBottomScrollAssist = false
        private var contentOffsetBeforeTextChange: CGPoint?
        private var pendingTextMutation: SharedEditorTextChange.Mutation?
        private var processedTextMutations: [SharedEditorTextChange.Mutation] = []
        private var lastKnownUTF16Length = 0
        private var lastTypewriterCaretMidY: CGFloat?
        private(set) var lastTextRuleContextUTF16Length = 0
        private(set) var typewriterSynchronousLayoutCount = 0

        init(parent: iPadTextEditor) {
            self.parent = parent
        }

        func applyExternalState(to textView: SmartTextView) {
            textView.textStorage.delegate = self
            textView.placeholderText = parent.placeholder
            textView.isEditable = !parent.isReadOnly
            textView.isSelectable = !parent.isReadOnly
            textView.isScrollEnabled = true
            textView.accessibilityValue = parent.isReadOnly
                ? "읽기 전용"
                : nil
            let incoming = EditorExternalSnapshot(
                documentID: parent.documentID,
                version: parent.externalVersion
            )
            let previousSnapshot = tracker.appliedSnapshot
            let decision = tracker.decision(
                for: incoming,
                isComposing: Self.hasActiveMarkedText(in: textView)
            )

            switch decision {
            case .none:
                applySelectionIfNeeded(to: textView)
            case .deferForComposition:
                handleCompositionState(in: textView)
            case .applyDocument, .applyVersion:
                if decision == .applyDocument {
                    lastTypewriterCaretMidY = nil
                    // 본문 전체 교체가 UIKit의 초기 오프셋을 노출하기 전에 가린다.
                    // 저장된 커서의 레이아웃과 최종 오프셋이 확정되면 다시 표시한다.
                    textView.alpha = 0
                }
                isApplyingExternalState = true
                let appliedIncrementally: Bool
                if decision == .applyVersion,
                   let previousSnapshot,
                   let externalMutation = parent.externalTextMutation,
                   externalMutation.baseVersion == previousSnapshot.version,
                   externalMutation.version == incoming.version {
                    appliedIncrementally = textView.applyExternalTextMutation(
                        externalMutation.mutation,
                        expectedUTF16Length: parent.externalUTF16Length
                            ?? parent.text.utf16.count,
                        selection: parent.selection
                    )
                } else {
                    appliedIncrementally = false
                }
                if !appliedIncrementally {
                    textView.applyExternalText(
                        parent.text,
                        selection: parent.selection,
                        clearsUndoHistory: decision == .applyDocument
                    )
                }
                if decision == .applyDocument {
                    // 새 문서의 글꼴·행간을 먼저 적용해야 저장된 커서의 세로 좌표가 정확하다.
                    textView.applyAppearance(parent.appearance)
                    updateTypewriterScrollPadding(for: textView)
                    scheduleSelectionViewportRestoration(
                        for: parent.documentID,
                        in: textView
                    )
                }
                scheduleDocumentEndLayoutPreparation(for: textView)
                isApplyingExternalState = false
            }

            lastKnownUTF16Length = textView.textStorage.length

            textView.applyAppearance(parent.appearance)
            if !parent.appearance.typewriterScrolling {
                lastTypewriterCaretMidY = nil
            }
            textView.setTemporarySearchHighlights(
                parent.searchHighlightRanges,
                current: parent.currentSearchHighlightRange
            )
            if parent.searchNavigationRequest != lastSearchNavigationRequest {
                lastSearchNavigationRequest = parent.searchNavigationRequest
                if let range = parent.currentSearchHighlightRange,
                   range.location >= 0,
                   range.length > 0,
                   NSMaxRange(range) <= textView.textStorage.length {
                    textView.prepareViewportLayout(around: range)
                    textView.scrollRangeToVisible(range)
                }
            }
            if parent.selectionNavigationRequest != lastSelectionNavigationRequest {
                lastSelectionNavigationRequest = parent.selectionNavigationRequest
                let length = textView.textStorage.length
                let location = min(Int(parent.selection.location), length)
                let selectionLength = min(
                    Int(parent.selection.selectionLength),
                    length - location
                )
                let range = NSRange(location: location, length: selectionLength)
                textView.prepareViewportLayout(around: range)
                textView.scrollRangeToVisible(range)
            }
            scheduleTypewriterPaddingUpdate(for: textView)
            commitCompositionIfRequested(in: textView)
            if parent.isReadOnly {
                requestResponderResignationIfNeeded(for: textView)
                return
            }
            if !parent.isActive {
                requestResponderResignationIfNeeded(for: textView)
                return
            }
            cancelPendingResponderResignation()
            applyEditCommandsIfNeeded(to: textView)
            requestFocusIfNeeded(for: textView)
        }

        private func applyEditCommandsIfNeeded(to textView: SmartTextView) {
            guard !Self.hasActiveMarkedText(in: textView) else { return }
            if parent.undoRequest != lastUndoRequest {
                lastUndoRequest = parent.undoRequest
                textView.performUndo()
            }
            if parent.redoRequest != lastRedoRequest {
                lastRedoRequest = parent.redoRequest
                textView.performRedo()
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalState else { return }
            guard let sourceDocumentID = tracker.appliedSnapshot?.documentID
            else { return }
            let resultingLength = textView.textStorage.length
            let processed = processedTextMutations
            processedTextMutations.removeAll(keepingCapacity: true)
            let proposedMutation: SharedEditorTextChange.Mutation?
            if processed.count == 1 {
                proposedMutation = processed[0]
            } else if processed.isEmpty {
                proposedMutation = pendingTextMutation
            } else {
                proposedMutation = nil
            }
            pendingTextMutation = nil
            let mutation = proposedMutation.flatMap {
                Self.validatedMutation(
                    $0,
                    previousUTF16Length: lastKnownUTF16Length,
                    resultingUTF16Length: resultingLength
                )
            }
            lastKnownUTF16Length = resultingLength
            if let mutation {
                parent.onTextChange(sourceDocumentID, nil, mutation)
            } else {
                // 드문 다중 편집·예상 밖 IME 콜백에서만 전체 스냅샷으로 복구한다.
                let snapshot = textView.textStorage.string
                parent.onTextChange(sourceDocumentID, snapshot, nil)
            }
            if let smartTextView = textView as? SmartTextView {
                smartTextView.refreshPlaceholderVisibility()
                smartTextView.requestContentSizeRefresh()
            }
            handleCompositionState(in: textView)
            if let smartTextView = textView as? SmartTextView {
                normalizeTrailingEllipsisIfNeeded(in: smartTextView)
            }
            let previousContentOffset = contentOffsetBeforeTextChange
            contentOffsetBeforeTextChange = nil
            stabilizeTypewriterScrollAfterTextChange(
                in: textView,
                previousContentOffset: previousContentOffset
            )
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard !isApplyingExternalState,
                  editedMask.contains(.editedCharacters)
            else { return }
            let oldLength = editedRange.length - delta
            guard oldLength >= 0,
                  editedRange.location <= textStorage.length,
                  editedRange.length <= textStorage.length - editedRange.location
            else {
                processedTextMutations.removeAll(keepingCapacity: true)
                return
            }
            processedTextMutations.append(
                SharedEditorTextChange.Mutation(
                    range: TextCursorState(
                        location: UInt(editedRange.location),
                        selectionLength: UInt(oldLength)
                    ),
                    replacementText: (textStorage.string as NSString)
                        .substring(with: editedRange)
                )
            )
        }

        private static func validatedMutation(
            _ mutation: SharedEditorTextChange.Mutation,
            previousUTF16Length: Int,
            resultingUTF16Length: Int
        ) -> SharedEditorTextChange.Mutation? {
            guard mutation.range.location <= UInt(Int.max),
                  mutation.range.selectionLength <= UInt(Int.max)
            else { return nil }
            let location = Int(mutation.range.location)
            let removedLength = Int(mutation.range.selectionLength)
            guard location <= previousUTF16Length,
                  removedLength <= previousUTF16Length - location,
                  previousUTF16Length - removedLength
                    + mutation.replacementText.utf16.count == resultingUTF16Length
            else { return nil }
            return mutation
        }

        /// 일부 키보드는 세 번째 마침표를 `shouldChangeTextIn` 경로가 아닌
        /// 일반 변경으로 전달한다. 커서 바로 앞의 직접 입력 `...`만 보정한다.
        private func normalizeTrailingEllipsisIfNeeded(in textView: SmartTextView) {
            guard parent.textRuleSettings.ellipsisConversionEnabled,
                  !textView.isPerformingPlainTextPaste,
                  !Self.hasActiveMarkedText(in: textView),
                  textView.selectedRange.length == 0,
                  textView.selectedRange.location >= 3
            else { return }

            let range = NSRange(
                location: textView.selectedRange.location - 3,
                length: 3
            )
            guard textView.textStorage.mutableString.substring(with: range) == "..." else {
                return
            }
            textView.replaceTextRegisteringUndo(
                range: range,
                replacement: "⋯",
                selection: NSRange(location: range.location + 1, length: 0)
            )
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if parent.appearance.typewriterScrolling,
               parent.isActive,
               !isUserScrolling {
                contentOffsetBeforeTextChange = textView.contentOffset
            } else {
                contentOffsetBeforeTextChange = nil
            }
            pendingTextMutation = SharedEditorTextChange.Mutation(
                range: Self.cursor(from: range),
                replacementText: replacement
            )
            guard let smartTextView = textView as? SmartTextView else { return true }
            let isComposing = Self.hasActiveMarkedText(in: textView)
            let isPaste = smartTextView.isPerformingPlainTextPaste
            guard parent.textRuleSettings.hasEnabledRule, !isComposing, !isPaste else {
                return true
            }
            guard let context = Self.textRuleContext(
                in: textView,
                covering: [textView.selectedRange, range]
            ) else {
                return true
            }
            lastTextRuleContextUTF16Length = context.text.utf16.count
            let result = TextRuleEngine.evaluate(
                TextRuleRequest(
                    text: context.text,
                    textUTF16Location: context.utf16Location,
                    selection: Self.cursor(from: textView.selectedRange),
                    changeRange: Self.cursor(from: range),
                    replacementText: replacement,
                    settings: parent.textRuleSettings,
                    isComposing: isComposing,
                    isPaste: isPaste
                )
            )
            guard result.handled else { return true }
            pendingTextMutation = result.edit.map {
                SharedEditorTextChange.Mutation(
                    range: $0.range,
                    replacementText: $0.replacement
                )
            }
            smartTextView.applyTextRuleResult(result)
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalState else { return }
            let range = textView.selectedRange
            let updated = TextCursorState(
                location: UInt(max(0, range.location)),
                selectionLength: UInt(max(0, range.length))
            )
            if parent.selection != updated {
                parent.selection = updated
            }
            handleCompositionState(in: textView)
            stabilizeDirectionalArrowNavigationIfNeeded(in: textView)
        }

        private func stabilizeDirectionalArrowNavigationIfNeeded(in textView: UITextView) {
            guard let smartTextView = textView as? SmartTextView,
                  smartTextView.isHandlingDirectionalArrowKey,
                  parent.appearance.typewriterScrolling,
                  parent.isActive,
                  !isUserScrolling,
                  !Self.hasActiveMarkedText(in: textView),
                  textView.selectedRange.length == 0,
                  let selection = textView.selectedTextRange
            else { return }

            smartTextView.prepareViewportLayout(around: textView.selectedRange)
            textView.layoutIfNeeded()
            let caretMidY = textView.caretRect(for: selection.end).midY
            lastTypewriterCaretMidY = caretMidY
            applyTypewriterScrollIfNeeded(
                to: textView,
                caretMidY: caretMidY,
                animated: false
            )
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
            handleCompositionState(in: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            handleCompositionState(in: textView)
            parent.onFocusChange(false)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? SmartTextView)?.refreshScrollDiagnostics()
            guard isUserScrolling,
                  !didApplyBottomScrollAssist
            else { return }

            let inset = scrollView.adjustedContentInset
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + inset.bottom
            )
            let scrollableDistance = maximumY - minimumY
            guard scrollableDistance > 1 else { return }

            let progress = (scrollView.contentOffset.y - minimumY)
                / scrollableDistance
            // 90% 지점의 부동소수점 반올림 오차만 허용한다.
            guard progress >= 0.899 else { return }

            didApplyBottomScrollAssist = true
            (scrollView as? SmartTextView)?.prepareDocumentEndLayout()
            let finalizedMaximumY = max(
                minimumY,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + inset.bottom
            )
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: finalizedMaximumY),
                animated: false
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            documentEndLayoutGeneration &+= 1
            (scrollView as? SmartTextView)?.prepareDocumentEndLayout()
            isUserScrolling = true
            didApplyBottomScrollAssist = false
            lastTypewriterCaretMidY = nil
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate {
                isUserScrolling = false
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserScrolling = false
        }

        private func scheduleDocumentEndLayoutPreparation(
            for textView: SmartTextView
        ) {
            documentEndLayoutGeneration &+= 1
            let generation = documentEndLayoutGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                [weak self, weak textView] in
                guard let self,
                      let textView,
                      generation == self.documentEndLayoutGeneration,
                      !self.isUserScrolling
                else { return }
                let preservedOffset = textView.contentOffset
                textView.prepareDocumentEndLayout()
                // contentSize 확정 뒤 UIKit이 다음 레이아웃 패스에서 선택 위치를
                // 자동 스크롤할 수 있다. 그 패스까지 처리한 후 기존 화면을 복원한다.
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          let textView,
                          generation == self.documentEndLayoutGeneration,
                          !self.isUserScrolling
                    else { return }
                    textView.layoutIfNeeded()
                    self.restoreContentOffsetImmediately(
                        preservedOffset,
                        in: textView
                    )
                }
            }
        }

        /// 새 문서는 화면에 그려지기 전에 저장된 커서를 기준으로 표시 위치를 확정한다.
        /// 별도 스크롤 캐시를 사용하면 커서와 화면이 어긋날 수 있으므로 항상 커서를 따른다.
        private func scheduleSelectionViewportRestoration(
            for documentID: DocumentID,
            in textView: SmartTextView
        ) {
            viewportRestorationGeneration &+= 1
            let generation = viewportRestorationGeneration
            // UITextView가 포커스 직후 예약하는 자체 선택 스크롤이 끝날 때까지
            // 이전 위치를 노출하지 않는다. 최종 커서 위치에서 한 번에 표시한다.
            textView.setNeedsLayout()
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.layoutIfNeeded()
                textView.prepareViewportLayout(around: textView.selectedRange)

                // 위 블록 뒤에 예약된 becomeFirstResponder/선택 스크롤까지 처리된 다음
                // 최종 오프셋을 다시 확정한다.
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self,
                          let textView,
                          generation == self.viewportRestorationGeneration
                    else { return }
                    guard self.tracker.appliedSnapshot?.documentID == documentID,
                          let selectedRange = textView.selectedTextRange
                    else {
                        textView.alpha = 1
                        return
                    }

                    textView.layoutIfNeeded()
                    textView.prepareViewportLayout(around: textView.selectedRange)
                    let caret = textView.caretRect(for: selectedRange.end)
                    let targetY = TypewriterScrollPosition.targetY(
                        caretMidY: caret.midY,
                        viewportHeight: textView.bounds.height,
                        contentHeight: textView.contentSize.height,
                        topInset: textView.adjustedContentInset.top,
                        bottomInset: textView.adjustedContentInset.bottom
                    )
                    UIView.performWithoutAnimation {
                        textView.layer.removeAllAnimations()
                        textView.setContentOffset(
                            CGPoint(x: textView.contentOffset.x, y: targetY),
                            animated: false
                        )
                        textView.alpha = 1
                        textView.layoutIfNeeded()
                    }
                    self.lastTypewriterCaretMidY = caret.midY
                    textView.refreshScrollDiagnostics()
                }
            }
        }

        private func applySelectionIfNeeded(to textView: UITextView) {
            let length = UInt(textView.textStorage.length)
            let location = min(parent.selection.location, length)
            let selectionLength = min(parent.selection.selectionLength, length - location)
            let target = NSRange(location: Int(location), length: Int(selectionLength))
            if textView.selectedRange != target {
                isApplyingExternalState = true
                textView.selectedRange = target
                isApplyingExternalState = false
            }
        }

        private func scheduleTypewriterPaddingUpdate(for textView: UITextView) {
            typewriterPaddingGeneration &+= 1
            let generation = typewriterPaddingGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView,
                      generation == self.typewriterPaddingGeneration,
                      !self.isUserScrolling
                else { return }
                self.updateTypewriterScrollPadding(for: textView)
            }
        }

        /// iPadOS 26의 한글 입력은 키보드 종류에 따라 marked text가 매 자모마다
        /// 잠시 해제될 수 있다. IME 상태 대신 실제 커서 줄을 기준으로 삼아,
        /// 같은 줄의 자모 입력은 화면을 고정하고 줄바꿈 때만 한 번 이동한다.
        private func stabilizeTypewriterScrollAfterTextChange(
            in textView: UITextView,
            previousContentOffset: CGPoint?
        ) {
            guard parent.appearance.typewriterScrolling,
                  parent.isActive,
                  !isUserScrolling
            else { return }
            guard textView.textStorage.length <= Self.maximumSynchronousTypewriterUTF16Length else {
                // 거대한 원고, 특히 줄바꿈 없는 단일 문단에서는 caretRect 계산이
                // 문단 전체 레이아웃을 강제할 수 있다. UIKit의 기본 커서 가시성에
                // 맡겨 입력을 우선하고 동기 타자기 스크롤은 생략한다.
                lastTypewriterCaretMidY = nil
                return
            }

            UIView.performWithoutAnimation {
                updateTypewriterScrollPadding(for: textView)
                typewriterSynchronousLayoutCount += 1
                textView.layoutIfNeeded()
                guard let selection = textView.selectedTextRange else { return }
                let caretMidY = textView.caretRect(for: selection.end).midY
                let sameVisualLine = lastTypewriterCaretMidY.map {
                    abs(caretMidY - $0) < typewriterLineChangeThreshold(for: textView)
                } ?? false
                if sameVisualLine {
                    if let previousContentOffset {
                        restoreContentOffsetImmediately(
                            previousContentOffset,
                            in: textView
                        )
                    }
                    return
                }
                lastTypewriterCaretMidY = caretMidY
                applyTypewriterScrollIfNeeded(
                    to: textView,
                    caretMidY: caretMidY,
                    animated: false
                )
            }
        }

        private func typewriterLineChangeThreshold(for textView: UITextView) -> CGFloat {
            max(4, (textView.font?.lineHeight ?? 20) * 0.6)
        }

        private func restoreContentOffsetImmediately(
            _ offset: CGPoint,
            in textView: UITextView
        ) {
            let inset = textView.adjustedContentInset
            let minimumY = -inset.top
            let maximumY = max(
                minimumY,
                textView.contentSize.height - textView.bounds.height + inset.bottom
            )
            let restoredY = min(max(offset.y, minimumY), maximumY)
            guard abs(textView.contentOffset.y - restoredY) > 0.5 else { return }
            textView.setContentOffset(
                CGPoint(x: offset.x, y: restoredY),
                animated: false
            )
        }

        /// 마지막 줄도 화면 중앙까지 올릴 수 있도록 표시 전용 하단 여유를 확보한다.
        private func updateTypewriterScrollPadding(for textView: UITextView) {
            let desiredBottomInset = parent.appearance.typewriterScrolling
                ? max(0, textView.bounds.height / 2 - textView.textContainerInset.bottom)
                : 0
            guard abs(textView.contentInset.bottom - desiredBottomInset) > 0.5 else { return }
            var inset = textView.contentInset
            inset.bottom = desiredBottomInset
            textView.contentInset = inset
        }

        private func applyTypewriterScrollIfNeeded(
            to textView: UITextView,
            caretMidY: CGFloat,
            animated: Bool
        ) {
            guard parent.appearance.typewriterScrolling,
                  !isUserScrolling,
                  textView.bounds.height > 0
            else {
                return
            }
            let targetY = TypewriterScrollPosition.targetY(
                caretMidY: caretMidY,
                viewportHeight: textView.bounds.height,
                contentHeight: textView.contentSize.height,
                topInset: textView.adjustedContentInset.top,
                bottomInset: textView.adjustedContentInset.bottom
            )
            guard abs(textView.contentOffset.y - targetY) > 0.5 else { return }
            textView.setContentOffset(
                CGPoint(x: textView.contentOffset.x, y: targetY),
                animated: animated && !UIAccessibility.isReduceMotionEnabled
            )
        }

        private func requestFocusIfNeeded(for textView: UITextView) {
            guard parent.focusRequest > lastFocusRequest else { return }
            lastFocusRequest = parent.focusRequest
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView,
                      self.parent.isActive
                else { return }
                _ = textView.becomeFirstResponder()
            }
        }

        /// 바인더 선택은 UITextView의 포커스를 빼앗지 않으므로 marked text가 저절로
        /// 끝나지 않는다. 최신 조합을 UIKit 경로로 확정한 뒤 모델의 대기 전환을 깨운다.
        private func commitCompositionIfRequested(in textView: UITextView) {
            guard parent.compositionCommitRequest > lastCompositionCommitRequest else { return }
            lastCompositionCommitRequest = parent.compositionCommitRequest
            let request = lastCompositionCommitRequest
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView,
                      request == self.lastCompositionCommitRequest
                else { return }
                self.attemptCompositionCommit(
                    request: request,
                    attempt: 1,
                    in: textView
                )
            }
        }

        /// 실기기 한글 입력기는 빠른 연속 입력 직후 첫 `unmarkText()`를 간헐적으로
        /// 반영하지 않는다. 조합이 실제로 끝났는지 확인하며 짧게 재시도하고, 그래도
        /// 남으면 responder를 내려 UIKit 자체의 안전한 조합 확정 경로를 사용한다.
        private func attemptCompositionCommit(
            request: UInt64,
            attempt: Int,
            in textView: UITextView
        ) {
            guard request == lastCompositionCommitRequest else { return }
            if Self.hasActiveMarkedText(in: textView) {
                textView.unmarkText()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                [weak self, weak textView] in
                guard let self,
                      let textView,
                      request == self.lastCompositionCommitRequest
                else { return }
                self.handleCompositionState(in: textView)
                guard Self.hasActiveMarkedText(in: textView) else {
                    // UIKit의 완료 콜백과 SwiftUI Task 실행 순서가 뒤집히면 브리지는
                    // 이미 false를 보고했다고 기억하지만 모델만 true로 남을 수 있다.
                    // 명시적 전환 요청에는 현재 UIKit 상태를 반드시 다시 확인시킨다.
                    self.reportCompositionState(false, force: true)
                    return
                }
                guard attempt < Self.maximumCompositionCommitAttempts else {
                    self.forceCompositionCommit(
                        request: request,
                        attempt: 1,
                        in: textView
                    )
                    return
                }
                self.attemptCompositionCommit(
                    request: request,
                    attempt: attempt + 1,
                    in: textView
                )
            }
        }

        private func forceCompositionCommit(
            request: UInt64,
            attempt: Int,
            in textView: UITextView
        ) {
            guard request == lastCompositionCommitRequest else { return }
            if textView.isFirstResponder {
                _ = textView.resignFirstResponder()
            }
            textView.unmarkText()
            // 드물게 입력기가 계속 marked range를 유지하더라도 메인 스레드를
            // 빠른 타이머로 영구 점유하지 않도록, 초기 복구 뒤에는 저빈도로 확인한다.
            let retryDelayMilliseconds = attempt < 40 ? 25 : 250
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(retryDelayMilliseconds)
            ) { [weak self, weak textView] in
                guard let self,
                      let textView,
                      request == self.lastCompositionCommitRequest
                else { return }
                self.handleCompositionState(in: textView)
                guard Self.hasActiveMarkedText(in: textView) else {
                    self.reportCompositionState(false, force: true)
                    return
                }
                if attempt.isMultiple(
                    of: Self.compositionCommitReloadInterval
                ) {
                    textView.reloadInputViews()
                }
                self.forceCompositionCommit(
                    request: request,
                    attempt: attempt + 1,
                    in: textView
                )
            }
        }

        /// `updateUIView` 도중 responder를 동기 변경하면 UIKit 포커스 콜백이 SwiftUI 갱신에
        /// 재진입할 수 있다. 다음 메인 루프로 미루고, 그사이 패널이 다시 활성화되면 취소한다.
        private func requestResponderResignationIfNeeded(for textView: UITextView) {
            guard textView.isFirstResponder else { return }
            responderResignationGeneration &+= 1
            let generation = responderResignationGeneration
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      let textView,
                      generation == self.responderResignationGeneration,
                      !self.parent.isActive,
                      !Self.hasActiveMarkedText(in: textView),
                      textView.isFirstResponder
                else { return }
                textView.resignFirstResponder()
            }
        }

        private func cancelPendingResponderResignation() {
            responderResignationGeneration &+= 1
        }

        private func handleCompositionState(in textView: UITextView) {
            let selection = Self.cursor(from: textView.selectedRange)
            let markedRange = Self.markedCursor(in: textView)
            let confirmedRange = compositionTracker.update(
                markedRange: markedRange,
                selection: selection
            )

            if markedRange != nil,
               !isForcingShortcutCommit,
               let anchor = compositionTracker.anchor,
               selection.selectionLength == 0,
               selection.location >= anchor,
               let smartTextView = textView as? SmartTextView {
                let activeRange = TextCursorState(
                    location: anchor,
                    selectionLength: selection.location - anchor
                )
                guard let activeNSRange = Self.range(from: activeRange),
                      let context = Self.textRuleContext(
                          in: textView,
                          covering: [textView.selectedRange, activeNSRange]
                      )
                else {
                    reportCompositionState(true)
                    return
                }
                let candidate = TextRuleEngine.evaluateCompositionCompletion(
                    TextRuleCompositionRequest(
                        text: context.text,
                        textUTF16Location: context.utf16Location,
                        selection: selection,
                        confirmedRange: activeRange,
                        settings: parent.textRuleSettings
                    )
                )
                if candidate.handled {
                    isForcingShortcutCommit = true
                    textView.unmarkText()
                    isForcingShortcutCommit = false
                    if let completedRange = compositionTracker.update(
                        markedRange: nil,
                        selection: Self.cursor(from: textView.selectedRange)
                    ) {
                        applyCompositionCompletion(
                            completedRange,
                            in: smartTextView
                        )
                    }
                    reportCompositionState(false)
                    return
                }
            }

            if let confirmedRange,
               let smartTextView = textView as? SmartTextView {
                applyCompositionCompletion(confirmedRange, in: smartTextView)
            }
            reportCompositionState(markedRange != nil)
        }

        private func applyCompositionCompletion(
            _ confirmedRange: TextCursorState,
            in textView: SmartTextView
        ) {
            guard let confirmedNSRange = Self.range(from: confirmedRange),
                  let context = Self.textRuleContext(
                      in: textView,
                      covering: [textView.selectedRange, confirmedNSRange]
                  )
            else { return }
            let result = TextRuleEngine.evaluateCompositionCompletion(
                TextRuleCompositionRequest(
                    text: context.text,
                    textUTF16Location: context.utf16Location,
                    selection: Self.cursor(from: textView.selectedRange),
                    confirmedRange: confirmedRange,
                    settings: parent.textRuleSettings
                )
            )
            if result.handled {
                textView.applyTextRuleResult(result)
            }
        }

        private func reportCompositionState(
            _ isComposing: Bool,
            force: Bool = false
        ) {
            guard force || isComposing != lastReportedCompositionState else { return }
            lastReportedCompositionState = isComposing
            let sourceDocumentID =
                tracker.appliedSnapshot?.documentID
                ?? parent.documentID
            parent.onCompositionStateChange(
                sourceDocumentID,
                isComposing
            )
        }

        private static func cursor(from range: NSRange) -> TextCursorState {
            TextCursorState(
                location: UInt(max(0, range.location)),
                selectionLength: UInt(max(0, range.length))
            )
        }

        private static func range(from cursor: TextCursorState) -> NSRange? {
            guard cursor.location <= UInt(Int.max),
                  cursor.selectionLength <= UInt(Int.max)
            else { return nil }
            let end = cursor.location.addingReportingOverflow(cursor.selectionLength)
            guard !end.overflow, end.partialValue <= UInt(Int.max) else { return nil }
            return NSRange(
                location: Int(cursor.location),
                length: Int(cursor.selectionLength)
            )
        }

        /// 스마트 입력 규칙에 필요한 선택 영역과 앞뒤 문맥만 복사한다.
        /// NSTextStorage의 UTF-16 저장소를 직접 사용해 긴 원고 전체를 Swift String으로
        /// 브리지하지 않으며, 잘린 문맥의 양 끝은 조합문자 경계까지 확장한다.
        private static func textRuleContext(
            in textView: UITextView,
            covering ranges: [NSRange]
        ) -> TextRuleContext? {
            guard !ranges.isEmpty else { return nil }
            let storage = textView.textStorage.mutableString
            for range in ranges {
                guard range.location <= storage.length,
                      range.length <= storage.length - range.location
                else { return nil }
            }

            let coveredLowerBound = ranges.map(\.location).min() ?? 0
            let coveredUpperBound = ranges.map(NSMaxRange).max() ?? coveredLowerBound
            let padding = max(3, TextRuleEngine.sceneBreak.utf16.count)
            let lowerBound = max(0, coveredLowerBound - min(coveredLowerBound, padding))
            let upperBound = min(storage.length, coveredUpperBound + padding)
            var contextRange = NSRange(
                location: lowerBound,
                length: upperBound - lowerBound
            )
            if contextRange.length > 0 {
                contextRange = storage.rangeOfComposedCharacterSequences(for: contextRange)
            }
            return TextRuleContext(
                text: storage.substring(with: contextRange),
                utf16Location: UInt(contextRange.location)
            )
        }

        private static func markedCursor(in textView: UITextView) -> TextCursorState? {
            guard let markedTextRange = textView.markedTextRange else { return nil }
            let location = textView.offset(
                from: textView.beginningOfDocument,
                to: markedTextRange.start
            )
            let length = textView.offset(from: markedTextRange.start, to: markedTextRange.end)
            // iPad 한글 입력기는 포커스 직후나 빈 문서에서 실제 조합 글자 없이
            // 길이 0의 marked range만 남길 수 있다. 이를 조합 중으로 취급하면
            // 문서 전환이 영구 대기하고 `unmarkText()` 재시도가 끝나지 않는다.
            guard location >= 0, length > 0 else { return nil }
            return TextCursorState(
                location: UInt(location),
                selectionLength: UInt(length)
            )
        }

        private static func hasActiveMarkedText(in textView: UITextView) -> Bool {
            markedCursor(in: textView) != nil
        }
    }
}

/// 기존 1단계 연결 이름과의 소스 호환을 유지한다.
typealias UIKitTextViewBridge = iPadTextEditor
