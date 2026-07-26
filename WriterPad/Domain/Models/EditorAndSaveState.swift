import Foundation

enum EditorPane: String, Codable, Equatable, Sendable {
    case left
    case right
}

/// 좌우 편집기 한 칸의 현재 문서와 커서를 나타낸다.
struct EditorPaneState: Codable, Equatable, Sendable {
    let documentID: DocumentID?
    let cursor: TextCursorState
}

/// 작품별 좌우 편집기 복원에 필요한 최소 화면 상태다.
struct EditorWorkspaceState: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let left: EditorPaneState
    let right: EditorPaneState?
    let activePane: EditorPane
}

/// 저장된 편집 문서가 휴지통으로 이동됐거나 메타데이터에서 사라진 경우에도
/// 나머지 작업 공간을 복원할 수 있도록 안전한 대체 문서를 결정한다.
enum WorkspaceRestorePolicy {
    static func resolvedState(
        from savedState: EditorWorkspaceState,
        availableDocuments: [DocumentNode]
    ) -> EditorWorkspaceState {
        let activeTextPairs: [(DocumentID, DocumentNode)] = availableDocuments.compactMap {
            document in
                guard document.projectID == savedState.projectID,
                      document.kind == .text,
                      case .active = document.deletionStatus
                else { return nil }
                return (document.id, document)
        }
        let activeTextByID: [DocumentID: DocumentNode] = Dictionary(
            uniqueKeysWithValues: activeTextPairs
        )
        let fallback = availableDocuments
            .compactMap { document -> (document: DocumentNode, chapter: Int)? in
                guard activeTextByID[document.id] != nil,
                      let chapter = manuscriptChapterNumber(for: document)
                else { return nil }
                return (document, chapter)
            }
            .sorted { lhs, rhs in
                if lhs.chapter != rhs.chapter {
                    return lhs.chapter < rhs.chapter
                }
                return lhs.document.relativePath.rawValue.localizedStandardCompare(
                    rhs.document.relativePath.rawValue
                ) == .orderedAscending
            }
            .first?
            .document

        let left = resolvedPane(
            savedState.left,
            activeTextByID: activeTextByID,
            fallback: fallback
        )

        let right: EditorPaneState?
        if let savedRight = savedState.right {
            let resolution = resolvedPane(
                savedRight,
                activeTextByID: activeTextByID,
                fallback: fallback
            )
            // 명시적으로 비어 있던 오른쪽 칸은 유지하되, 유실된 문서를
            // 대체할 원고가 전혀 없을 때만 분할을 닫는다.
            right = savedRight.documentID != nil && resolution.documentID == nil
                ? nil
                : resolution
        } else {
            right = nil
        }

        return EditorWorkspaceState(
            projectID: savedState.projectID,
            left: left,
            right: right,
            activePane: savedState.activePane == .right && right == nil
                ? .left
                : savedState.activePane
        )
    }

    private static func resolvedPane(
        _ savedPane: EditorPaneState,
        activeTextByID: [DocumentID: DocumentNode],
        fallback: DocumentNode?
    ) -> EditorPaneState {
        guard let savedDocumentID = savedPane.documentID else {
            return savedPane
        }
        if activeTextByID[savedDocumentID] != nil {
            return savedPane
        }
        return EditorPaneState(
            documentID: fallback?.id,
            cursor: .start
        )
    }

    private static func manuscriptChapterNumber(for document: DocumentNode) -> Int? {
        let components = document.relativePath.rawValue
            .split(separator: "/")
            .map(String.init)
        guard components.count == 4,
              components[0] == "메인",
              components[1] == "원고"
        else { return nil }

        let rules = BinderRuleService()
        guard rules.volumeNumber(fromStoredName: components[2]) != nil else {
            return nil
        }
        return rules.titledChapterIdentity(fromStoredName: components[3])?.number
    }
}

enum ScreenLayoutOrientation: Equatable, Sendable {
    case portrait
    case landscape
    case unknown
}

enum DualEditorLayoutPolicy {
    static func usesCompactLayout(
        width: Double,
        height: Double,
        screenOrientation: ScreenLayoutOrientation
    ) -> Bool {
        switch screenOrientation {
        case .portrait:
            true
        case .landscape:
            width < 620
        case .unknown:
            width < 620 || height > width
        }
    }
}

enum DualEditorSelectionRoute: Equatable, Sendable {
    case openIn(EditorPane)
    case activate(EditorPane)
}

/// 바인더 선택은 항상 활성 편집기로 보낸다.
/// 분리 모드에서는 같은 문서를 양쪽에 열어 서로 다른 위치를 볼 수 있다.
enum DualEditorRouter {
    static func route(
        selectedDocumentID: DocumentID,
        isSplitEnabled: Bool,
        activePane: EditorPane,
        leftDocumentID: DocumentID?,
        rightDocumentID: DocumentID?
    ) -> DualEditorSelectionRoute {
        .openIn(activePane)
    }
}

/// 한 패널의 본문 변경을 반대 패널에 반영할 때 UTF-16 커서 위치를 보정한다.
/// 변경 구간보다 뒤에 있는 커서는 증감 길이만큼 이동하고, 변경 구간 안의 커서는
/// 새 구간의 끝으로 모은다.
enum SharedEditorTextChange {
    struct Mutation: Equatable, Sendable {
        let range: TextCursorState
        let replacementText: String
    }

    struct VersionedMutation: Equatable, Sendable {
        let baseVersion: UInt64
        let version: UInt64
        let mutation: Mutation
    }

    static func adjustedCursor(
        _ cursor: TextCursorState,
        applying mutation: Mutation
    ) -> TextCursorState {
        let editStart = Int(clamping: mutation.range.location)
        let oldEditEnd = editStart + Int(clamping: mutation.range.selectionLength)
        let newEditEnd = editStart + mutation.replacementText.utf16.count
        let start = transformedOffset(
            Int(clamping: cursor.location),
            editStart: editStart,
            oldEditEnd: oldEditEnd,
            newEditEnd: newEditEnd
        )
        let oldSelectionEnd = cursor.location.addingReportingOverflow(cursor.selectionLength)
        let boundedSelectionEnd = oldSelectionEnd.overflow ? UInt.max : oldSelectionEnd.partialValue
        let end = transformedOffset(
            Int(clamping: boundedSelectionEnd),
            editStart: editStart,
            oldEditEnd: oldEditEnd,
            newEditEnd: newEditEnd
        )
        let boundedStart = max(0, start)
        let boundedEnd = max(boundedStart, end)
        return TextCursorState(
            location: UInt(boundedStart),
            selectionLength: UInt(boundedEnd - boundedStart)
        )
    }

    static func adjustedCursor(
        _ cursor: TextCursorState,
        from oldText: String,
        to newText: String
    ) -> TextCursorState {
        guard oldText != newText else { return cursor }
        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        let sharedLimit = min(oldUnits.count, newUnits.count)

        var prefix = 0
        while prefix < sharedLimit, oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldUnits.count - prefix,
              suffix < newUnits.count - prefix,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }

        let oldEditEnd = oldUnits.count - suffix
        let newEditEnd = newUnits.count - suffix
        let start = transformedOffset(
            Int(clamping: cursor.location),
            editStart: prefix,
            oldEditEnd: oldEditEnd,
            newEditEnd: newEditEnd
        )
        let oldSelectionEnd = cursor.location.addingReportingOverflow(cursor.selectionLength)
        let boundedSelectionEnd = oldSelectionEnd.overflow ? UInt.max : oldSelectionEnd.partialValue
        let end = transformedOffset(
            Int(clamping: boundedSelectionEnd),
            editStart: prefix,
            oldEditEnd: oldEditEnd,
            newEditEnd: newEditEnd
        )
        let boundedStart = min(start, newUnits.count)
        let boundedEnd = min(max(end, boundedStart), newUnits.count)
        return TextCursorState(
            location: UInt(boundedStart),
            selectionLength: UInt(boundedEnd - boundedStart)
        )
    }

    private static func transformedOffset(
        _ offset: Int,
        editStart: Int,
        oldEditEnd: Int,
        newEditEnd: Int
    ) -> Int {
        if offset <= editStart { return offset }
        if offset < oldEditEnd { return newEditEnd }
        return offset + (newEditEnd - oldEditEnd)
    }
}

/// 현재 문서 검색의 일시적인 표시 상태다. 범위는 UITextView와 같은 UTF-16 좌표계이며
/// 빈 검색어는 결과가 없고, 리터럴·대소문자 무시·비중첩 방식으로 찾는다.
struct DocumentSearchState: Equatable, Sendable {
    private(set) var query = ""
    private(set) var matches: [TextCursorState] = []
    private(set) var selectedIndex: Int?

    var currentMatch: TextCursorState? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    mutating func update(query: String, in text: String) {
        self.query = query
        recalculate(in: text)
    }

    mutating func recalculate(in text: String) {
        let previousLocation = currentMatch?.location
        matches = Self.findMatches(query: query, in: text)
        guard !matches.isEmpty else {
            selectedIndex = nil
            return
        }
        if let previousLocation,
           let exactIndex = matches.firstIndex(where: { $0.location == previousLocation }) {
            selectedIndex = exactIndex
        } else if let previousLocation,
                  let followingIndex = matches.firstIndex(where: { $0.location >= previousLocation }) {
            selectedIndex = followingIndex
        } else {
            selectedIndex = 0
        }
    }

    mutating func selectNext() {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? -1) + 1) % matches.count
    }

    mutating func selectPrevious() {
        guard !matches.isEmpty else { return }
        selectedIndex = ((selectedIndex ?? 0) - 1 + matches.count) % matches.count
    }

    mutating func clear() {
        query = ""
        matches = []
        selectedIndex = nil
    }

    static func findMatches(query: String, in text: String) -> [TextCursorState] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        let queryLength = (query as NSString).length
        guard queryLength > 0, source.length >= queryLength else { return [] }

        var results: [TextCursorState] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while searchRange.length >= queryLength {
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .literal],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            results.append(
                TextCursorState(
                    location: UInt(match.location),
                    selectionLength: UInt(match.length)
                )
            )
            let nextLocation = NSMaxRange(match)
            searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
        }
        return results
    }
}

enum EditorFontFamily: String, Codable, CaseIterable, Equatable, Sendable {
    case system
    case serif
    case monospaced
    case malgunGothic
    case malgunGothicSemilight
    case malgunGothicBold

    var displayName: String {
        switch self {
        case .system: "시스템 고딕"
        case .serif: "명조 계열"
        case .monospaced: "고정폭"
        case .malgunGothic: "맑은 고딕"
        case .malgunGothicSemilight: "맑은 고딕 세미라이트"
        case .malgunGothicBold: "맑은 고딕 볼드"
        }
    }

    var bundledPostScriptName: String? {
        switch self {
        case .system, .serif, .monospaced:
            nil
        case .malgunGothic:
            "MalgunGothic"
        case .malgunGothicSemilight:
            "MalgunGothic-Semilight"
        case .malgunGothicBold:
            "MalgunGothicBold"
        }
    }
}

/// TXT에 기록하지 않고 편집 화면에만 적용하는 전역 표시 설정이다.
struct EditorAppearanceSettings: Codable, Equatable, Sendable {
    static let `default` = EditorAppearanceSettings(
        fontFamily: .system,
        fontSize: 17,
        lineSpacing: 6,
        horizontalInset: 64,
        verticalInset: 30,
        isBold: false,
        typewriterScrolling: false
    )

    let fontFamily: EditorFontFamily
    let fontSize: Double
    let lineSpacing: Double
    let horizontalInset: Double
    let verticalInset: Double
    let isBold: Bool
    let typewriterScrolling: Bool

    init(
        fontFamily: EditorFontFamily,
        fontSize: Double,
        lineSpacing: Double,
        horizontalInset: Double,
        verticalInset: Double,
        isBold: Bool = false,
        typewriterScrolling: Bool
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize.clamped(to: 14...32, fallback: 17)
        // 표시 배율은 1.6 + lineSpacing / 100이다. -60을 허용하면
        // 기존 저장값·표시를 유지한 채 최소 1.0배 행간까지 조절할 수 있다.
        self.lineSpacing = lineSpacing.clamped(to: -60...20, fallback: 6)
        self.horizontalInset = horizontalInset.clamped(to: 24...120, fallback: 64)
        self.verticalInset = verticalInset.clamped(to: 16...80, fallback: 30)
        self.isBold = isBold
        self.typewriterScrolling = typewriterScrolling
    }
}

/// 공백과 줄바꿈을 포함한 Swift 확장 자소 클러스터를 한 글자로 센다.
struct ManuscriptStatistics: Equatable, Sendable {
    static let empty = ManuscriptStatistics(characterCount: 0)

    let characterCount: Int

    init(text: String) {
        characterCount = text.count
    }

    init(characterCount: Int) {
        self.characterCount = characterCount
    }
}

/// 입력 중에는 `UITextView`와 같은 UTF-16 좌표계로 부분 변경만 반영하고,
/// 파일 저장·내보내기처럼 실제로 필요할 때만 Swift `String` 스냅샷을 만든다.
/// 메인 액터에 고정해 TextKit 콜백, SwiftUI 상태, 듀얼 편집기 사이의 순서를 보장한다.
@MainActor
final class ManuscriptTextBuffer {
    private let storage: NSMutableString
    private(set) var statistics: ManuscriptStatistics
    private(set) var snapshotCreationCount = 0
    private(set) var revision: UInt64 = 0

    init(_ text: String = "") {
        storage = NSMutableString(string: text)
        statistics = ManuscriptStatistics(text: text)
    }

    var utf16Length: Int { storage.length }
    var isEmpty: Bool { storage.length == 0 }

    func snapshot() -> String {
        snapshotCreationCount &+= 1
        return storage.copy() as! String
    }

    func selectedCharacterCount(_ selection: TextCursorState) -> Int? {
        guard selection.location <= UInt(Int.max),
              selection.selectionLength <= UInt(Int.max)
        else { return nil }
        let range = NSRange(
            location: Int(selection.location),
            length: Int(selection.selectionLength)
        )
        guard range.location <= storage.length,
              range.length <= storage.length - range.location
        else { return nil }
        return storage.substring(with: range).count
    }

    /// 변경 경계의 인접 확장 자소까지 함께 다시 세어 결합문자·이모지·한글 조합이
    /// 경계를 가로질러도 전체 원고를 순회하지 않고 정확한 글자 수를 유지한다.
    @discardableResult
    func apply(_ mutation: SharedEditorTextChange.Mutation) -> Bool {
        guard mutation.range.location <= UInt(Int.max),
              mutation.range.selectionLength <= UInt(Int.max)
        else { return false }
        let range = NSRange(
            location: Int(mutation.range.location),
            length: Int(mutation.range.selectionLength)
        )
        guard range.location <= storage.length,
              range.length <= storage.length - range.location
        else { return false }

        let oldContextRange = composedContextRange(around: range)
        let oldContextCount = storage.substring(with: oldContextRange).count
        storage.replaceCharacters(in: range, with: mutation.replacementText)
        revision &+= 1

        let replacementLength = mutation.replacementText.utf16.count
        let newContextLength = oldContextRange.length - range.length + replacementLength
        let newContextRange = NSRange(
            location: oldContextRange.location,
            length: newContextLength
        )
        let newContextCount = storage.substring(with: newContextRange).count
        statistics = ManuscriptStatistics(
            characterCount: max(
                0,
                statistics.characterCount - oldContextCount + newContextCount
            )
        )
        return true
    }

    private func composedContextRange(around range: NSRange) -> NSRange {
        guard storage.length > 0 else { return range }
        let lower = max(0, range.location - 1)
        let upper = min(storage.length, NSMaxRange(range) + 1)
        return storage.rangeOfComposedCharacterSequences(
            for: NSRange(location: lower, length: upper - lower)
        )
    }
}

enum TypewriterScrollPosition {
    static func targetY(
        caretMidY: Double,
        viewportHeight: Double,
        contentHeight: Double,
        topInset: Double,
        bottomInset: Double
    ) -> Double {
        let minimum = -max(0, topInset)
        let maximum = max(
            minimum,
            contentHeight - max(0, viewportHeight) + max(0, bottomInset)
        )
        let centered = caretMidY - max(0, viewportHeight) / 2
        return min(max(centered, minimum), maximum)
    }
}

/// 로컬 TXT 저장 흐름의 사용자 표시 상태다.
enum SaveState: Codable, Equatable, Sendable {
    case idle
    case editing(generation: UInt64)
    case saving(generation: UInt64)
    case saved(generation: UInt64, savedAt: Date, contentHash: ContentHash)
    case failed(generation: UInt64, message: String)

    var generation: UInt64? {
        switch self {
        case .idle:
            nil
        case let .editing(generation), let .saving(generation),
             let .saved(generation, _, _), let .failed(generation, _):
            generation
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
