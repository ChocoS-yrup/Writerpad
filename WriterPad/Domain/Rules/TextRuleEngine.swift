import Foundation

struct TextRuleSettings: Equatable, Sendable {
    var smartPairsEnabled: Bool
    var ellipsisConversionEnabled: Bool
    var specialQuotationShortcutsEnabled: Bool
    var sceneBreakEnabled: Bool

    var hasEnabledRule: Bool {
        smartPairsEnabled
            || ellipsisConversionEnabled
            || specialQuotationShortcutsEnabled
            || sceneBreakEnabled
    }

    static let enabled = TextRuleSettings(
        smartPairsEnabled: true,
        ellipsisConversionEnabled: true,
        specialQuotationShortcutsEnabled: true,
        sceneBreakEnabled: true
    )
    static let disabled = TextRuleSettings(
        smartPairsEnabled: false,
        ellipsisConversionEnabled: false,
        specialQuotationShortcutsEnabled: false,
        sceneBreakEnabled: false
    )
}

struct TextEditOperation: Equatable, Sendable {
    let range: TextCursorState
    let replacement: String
}

struct TextRuleRequest: Equatable, Sendable {
    let text: String
    let textUTF16Location: UInt
    let selection: TextCursorState
    let changeRange: TextCursorState
    let replacementText: String
    let settings: TextRuleSettings
    let isComposing: Bool
    let isPaste: Bool

    init(
        text: String,
        textUTF16Location: UInt = 0,
        selection: TextCursorState,
        changeRange: TextCursorState,
        replacementText: String,
        settings: TextRuleSettings,
        isComposing: Bool,
        isPaste: Bool
    ) {
        self.text = text
        self.textUTF16Location = textUTF16Location
        self.selection = selection
        self.changeRange = changeRange
        self.replacementText = replacementText
        self.settings = settings
        self.isComposing = isComposing
        self.isPaste = isPaste
    }
}

struct TextRuleCompositionRequest: Equatable, Sendable {
    let text: String
    let textUTF16Location: UInt
    let selection: TextCursorState
    let confirmedRange: TextCursorState
    let settings: TextRuleSettings

    init(
        text: String,
        textUTF16Location: UInt = 0,
        selection: TextCursorState,
        confirmedRange: TextCursorState,
        settings: TextRuleSettings
    ) {
        self.text = text
        self.textUTF16Location = textUTF16Location
        self.selection = selection
        self.confirmedRange = confirmedRange
        self.settings = settings
    }
}

struct TextRuleResult: Equatable, Sendable {
    let handled: Bool
    let edit: TextEditOperation?
    let selection: TextCursorState

    static func unhandled(selection: TextCursorState) -> TextRuleResult {
        TextRuleResult(handled: false, edit: nil, selection: selection)
    }
}

/// UIKit과 독립적으로 한 번의 키 입력을 하나의 최소 편집 연산으로 변환한다.
enum TextRuleEngine {
    static let sceneBreak = "\n\n * * *\n\n"

    private static let pairs: [Character: Character] = [
        "'": "'",
        "\"": "\"",
        "[": "]",
        "(": ")",
        "{": "}",
        "「": "」",
        "『": "』"
    ]

    private static let closers = Set(pairs.values)

    static func evaluate(_ request: TextRuleRequest) -> TextRuleResult {
        let unhandled = TextRuleResult.unhandled(selection: request.selection)
        guard request.settings.hasEnabledRule, !request.isComposing, !request.isPaste else {
            return unhandled
        }
        guard let selectionRange = validatedRange(
                  request.selection,
                  in: request.text,
                  textUTF16Location: request.textUTF16Location
              ),
              let changeRange = validatedRange(
                  request.changeRange,
                  in: request.text,
                  textUTF16Location: request.textUTF16Location
              )
        else {
            return unhandled
        }

        if let shortcut = directShortcutInsertion(
            request,
            selectionRange: selectionRange
        ) {
            return shortcut
        }

        if request.settings.sceneBreakEnabled {
            if let deletion = sceneBreakDeletion(
                request,
                selectionRange: selectionRange,
                changeRange: changeRange
            ) {
                return deletion
            }

            if let insertion = sceneBreakInsertion(request) {
                return insertion
            }
        }

        if request.settings.smartPairsEnabled {
            if let deletion = emptyPairDeletion(
                request,
                selectionRange: selectionRange,
                changeRange: changeRange
            ) {
                return deletion
            }

            if let skip = matchingCloserSkip(request, selectionRange: selectionRange) {
                return skip
            }

            if let newline = newlineAfterCloser(request, selectionRange: selectionRange) {
                return newline
            }

            if let pair = pairInsertion(
                request,
                selectionRange: selectionRange,
                changeRange: changeRange
            ) {
                return pair
            }
        }

        return unhandled
    }

    private static func directShortcutInsertion(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.selection.selectionLength == 0,
              request.changeRange == request.selection
        else {
            return nil
        }

        // 일부 외장 키보드/입력 계층은 세 번의 마침표를 한 번에 전달한다.
        // 이 경우에도 원고에는 ASCII 마침표 세 개가 아닌 U+22EF 하나만 남긴다.
        if request.settings.ellipsisConversionEnabled,
           request.replacementText == "..." {
            return TextRuleResult(
                handled: true,
                edit: TextEditOperation(range: request.changeRange, replacement: "⋯"),
                selection: TextCursorState(
                    location: request.selection.location + 1,
                    selectionLength: 0
                )
            )
        }

        if request.settings.ellipsisConversionEnabled,
           request.replacementText == ".",
           let previous = textBeforeSelection(
               utf16Length: 2,
               request: request,
               selectionRange: selectionRange
           ),
           previous.text == ".." {
            return TextRuleResult(
                handled: true,
                edit: TextEditOperation(range: previous.range, replacement: "⋯"),
                selection: TextCursorState(
                    location: previous.range.location + 1,
                    selectionLength: 0
                )
            )
        }

        let quotationRules = [(trigger: "ㄴ", replacement: "「」"), (trigger: "ㄱ", replacement: "『』")]
        guard request.settings.specialQuotationShortcutsEnabled,
              let rule = quotationRules.first(where: { $0.trigger == request.replacementText }),
              let previous = textBeforeSelection(
                  utf16Length: 1,
                  request: request,
                  selectionRange: selectionRange
              ),
              previous.text == rule.trigger
        else {
            return nil
        }

        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(range: previous.range, replacement: rule.replacement),
            selection: TextCursorState(
                location: previous.range.location + 1,
                selectionLength: 0
            )
        )
    }

    private static func textBeforeSelection(
        utf16Length: UInt,
        request: TextRuleRequest,
        selectionRange: Range<String.Index>
    ) -> (range: TextCursorState, text: String)? {
        guard request.selection.location >= utf16Length else { return nil }
        let cursor = TextCursorState(
            location: request.selection.location - utf16Length,
            selectionLength: utf16Length
        )
        guard let range = validatedRange(
                  cursor,
                  in: request.text,
                  textUTF16Location: request.textUTF16Location
              ),
              range.upperBound == selectionRange.lowerBound
        else {
            return nil
        }
        return (cursor, String(request.text[range]))
    }

    static func evaluateCompositionCompletion(
        _ request: TextRuleCompositionRequest
    ) -> TextRuleResult {
        let unhandled = TextRuleResult.unhandled(selection: request.selection)
        guard request.settings.specialQuotationShortcutsEnabled,
              request.selection.selectionLength == 0,
              let confirmedRange = validatedRange(
                  request.confirmedRange,
                  in: request.text,
                  textUTF16Location: request.textUTF16Location
              ),
              request.selection.location
                == request.confirmedRange.location + request.confirmedRange.selectionLength
        else {
            return unhandled
        }

        let confirmedText = String(request.text[confirmedRange])
        let rules = [(trigger: "ㄴㄴ", replacement: "「」"), (trigger: "ㄱㄱ", replacement: "『』")]
        guard let rule = rules.first(where: { confirmedText.hasSuffix($0.trigger) }) else {
            return unhandled
        }

        let triggerLength = UInt(rule.trigger.utf16.count)
        let replacementLocation = request.selection.location - triggerLength
        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(
                range: TextCursorState(
                    location: replacementLocation,
                    selectionLength: triggerLength
                ),
                replacement: rule.replacement
            ),
            selection: TextCursorState(location: replacementLocation + 1, selectionLength: 0)
        )
    }

    private static func sceneBreakInsertion(
        _ request: TextRuleRequest
    ) -> TextRuleResult? {
        guard request.replacementText == "*",
              request.selection.selectionLength == 0,
              request.changeRange == request.selection
        else {
            return nil
        }

        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(range: request.changeRange, replacement: sceneBreak),
            selection: TextCursorState(
                location: request.selection.location + UInt(sceneBreak.utf16.count),
                selectionLength: 0
            )
        )
    }

    private static func sceneBreakDeletion(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>,
        changeRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.replacementText.isEmpty,
              request.selection.selectionLength == 0,
              request.changeRange.selectionLength == 1
        else {
            return nil
        }

        let sceneLength = UInt(sceneBreak.utf16.count)
        let sceneRange: TextCursorState
        if changeRange.upperBound == selectionRange.lowerBound,
           request.selection.location >= sceneLength {
            sceneRange = TextCursorState(
                location: request.selection.location - sceneLength,
                selectionLength: sceneLength
            )
        } else if changeRange.lowerBound == selectionRange.lowerBound {
            sceneRange = TextCursorState(
                location: request.selection.location,
                selectionLength: sceneLength
            )
        } else {
            return nil
        }

        guard let swiftSceneRange = validatedRange(
                  sceneRange,
                  in: request.text,
                  textUTF16Location: request.textUTF16Location
              ),
              String(request.text[swiftSceneRange]) == sceneBreak
        else {
            return nil
        }

        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(range: sceneRange, replacement: ""),
            selection: TextCursorState(location: sceneRange.location, selectionLength: 0)
        )
    }

    private static func emptyPairDeletion(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>,
        changeRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.replacementText.isEmpty,
              request.selection.selectionLength == 0,
              request.changeRange.selectionLength > 0,
              changeRange.upperBound == selectionRange.lowerBound
        else {
            return nil
        }

        let removed = String(request.text[changeRange])
        guard removed.count == 1,
              let opener = removed.first,
              let closer = pairs[opener],
              character(at: selectionRange.lowerBound, in: request.text) == closer
        else {
            return nil
        }

        let combinedLength = request.changeRange.selectionLength + UInt(String(closer).utf16.count)
        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(
                range: TextCursorState(
                    location: request.changeRange.location,
                    selectionLength: combinedLength
                ),
                replacement: ""
            ),
            selection: TextCursorState(location: request.changeRange.location, selectionLength: 0)
        )
    }

    private static func matchingCloserSkip(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.selection.selectionLength == 0,
              request.changeRange == request.selection,
              request.replacementText.count == 1,
              let closer = request.replacementText.first,
              closers.contains(closer),
              character(at: selectionRange.lowerBound, in: request.text) == closer
        else {
            return nil
        }

        return TextRuleResult(
            handled: true,
            edit: nil,
            selection: TextCursorState(
                location: request.selection.location + UInt(request.replacementText.utf16.count),
                selectionLength: 0
            )
        )
    }

    private static func newlineAfterCloser(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.replacementText == "\n",
              request.selection.selectionLength == 0,
              request.changeRange == request.selection,
              let closer = character(at: selectionRange.lowerBound, in: request.text),
              closers.contains(closer)
        else {
            return nil
        }

        let insertionLocation = request.selection.location + UInt(String(closer).utf16.count)
        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(
                range: TextCursorState(location: insertionLocation, selectionLength: 0),
                replacement: "\n"
            ),
            selection: TextCursorState(location: insertionLocation + 1, selectionLength: 0)
        )
    }

    private static func pairInsertion(
        _ request: TextRuleRequest,
        selectionRange: Range<String.Index>,
        changeRange: Range<String.Index>
    ) -> TextRuleResult? {
        guard request.replacementText.count == 1,
              let opener = request.replacementText.first,
              let closer = pairs[opener],
              request.changeRange == request.selection,
              selectionRange == changeRange
        else {
            return nil
        }

        let selectedText = String(request.text[selectionRange])
        let openerText = String(opener)
        let replacement = openerText + selectedText + String(closer)
        let innerLocation = request.selection.location + UInt(openerText.utf16.count)
        return TextRuleResult(
            handled: true,
            edit: TextEditOperation(range: request.changeRange, replacement: replacement),
            selection: TextCursorState(
                location: innerLocation,
                selectionLength: request.selection.selectionLength
            )
        )
    }

    private static func validatedRange(
        _ cursor: TextCursorState,
        in text: String,
        textUTF16Location: UInt
    ) -> Range<String.Index>? {
        guard cursor.location >= textUTF16Location,
              cursor.selectionLength <= UInt(Int.max)
        else {
            return nil
        }
        let localLocation = cursor.location - textUTF16Location
        guard localLocation <= UInt(Int.max) else { return nil }
        let range = NSRange(
            location: Int(localLocation),
            length: Int(cursor.selectionLength)
        )
        let utf16Text = text as NSString
        guard range.location <= utf16Text.length,
              range.length <= utf16Text.length - range.location,
              isCharacterBoundary(range.location, in: utf16Text),
              isCharacterBoundary(NSMaxRange(range), in: utf16Text),
              let swiftRange = Range(range, in: text)
        else {
            return nil
        }
        return swiftRange
    }

    private static func isCharacterBoundary(
        _ utf16Offset: Int,
        in text: NSString
    ) -> Bool {
        if utf16Offset == 0 || utf16Offset == text.length { return true }
        guard utf16Offset > 0, utf16Offset < text.length else { return false }
        return text.rangeOfComposedCharacterSequence(at: utf16Offset).location == utf16Offset
    }

    private static func character(
        at index: String.Index,
        in text: String
    ) -> Character? {
        guard index < text.endIndex else { return nil }
        return text[index]
    }
}
