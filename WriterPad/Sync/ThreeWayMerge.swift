import Foundation

struct ThreeWayMergeResult: Equatable, Sendable {
    let content: String
    let hasConflicts: Bool
    let conflictCount: Int
}

enum ThreeWayMerge {
    /// 오프라인 중 두 기기가 같은 경로에 각각 새 문서를 만들면 공통 원본이
    /// 없다. 이때 `바꾸기 전 원본`은 빈 칸이 되고 `차이점`은 양쪽 본문 전체를
    /// 그대로 반복하므로, 두 칸만 남겨 한 문서에 나란히 보존한다. 어느 쪽을
    /// 남길지는 작가가 편집기에서 직접 정리한다.
    static func sideBySide(
        local: String,
        remote: String
    ) -> String {
        var output = "=========\n\n"
        output += "로컬 편집본\n\n"
        output += ensureTrailingNewline(local)
        output += "\n=========\n\n"
        output += "서버 최신본\n\n"
        output += ensureTrailingNewline(remote)
        output += "\n=========\n"
        return output
    }

    private static func ensureTrailingNewline(_ value: String) -> String {
        guard !value.isEmpty else { return "\n" }
        return value.hasSuffix("\n") ? value : value + "\n"
    }

    static func merge(
        base: String,
        local: String,
        remote: String
    ) -> ThreeWayMergeResult {
        if local == remote {
            return result(content: local)
        }
        if local == base {
            return result(content: remote)
        }
        if remote == base {
            return result(content: local)
        }

        let baseLines = lineTokens(base)
        let localLines = lineTokens(local)
        let remoteLines = lineTokens(remote)
        let changes =
            changes(from: baseLines, to: localLines, side: .local)
            + changes(from: baseLines, to: remoteLines, side: .remote)

        var output: [String] = []
        var cursor = 0
        var conflictCount = 0

        for cluster in clusters(changes) {
            let start = cluster.map(\.start).min() ?? cursor
            let end = cluster.map(\.end).max() ?? start
            output.append(contentsOf: baseLines[cursor..<start])

            let localChanges = cluster.filter { $0.side == .local }
            let remoteChanges = cluster.filter { $0.side == .remote }
            if !localChanges.isEmpty, !remoteChanges.isEmpty {
                let localSegment = applySegment(
                    baseLines,
                    start: start,
                    end: end,
                    changes: localChanges
                )
                let remoteSegment = applySegment(
                    baseLines,
                    start: start,
                    end: end,
                    changes: remoteChanges
                )
                if localSegment == remoteSegment {
                    output.append(contentsOf: localSegment)
                } else {
                    conflictCount += 1
                    output.append("=========\n\n")
                    output.append("바꾸기 전 원본\n\n")
                    output.append(
                        ensureNewline(Array(baseLines[start..<end]))
                    )
                    output.append("\n=========\n\n")
                    output.append("로컬 편집본\n\n")
                    output.append(ensureNewline(localSegment))
                    output.append("\n=========\n\n")
                    output.append("서버 최신본\n\n")
                    output.append(ensureNewline(remoteSegment))
                    output.append("\n=========\n\n")
                    output.append("로컬과 서버 차이점\n\n")
                    output.append(
                        ensureNewline(
                            differenceSummary(
                                base: Array(
                                    baseLines[start..<end]
                                ),
                                local: localSegment,
                                remote: remoteSegment
                            )
                        )
                    )
                    output.append("\n=========\n")
                }
            } else {
                output.append(
                    contentsOf: applySegment(
                        baseLines,
                        start: start,
                        end: end,
                        changes: localChanges.isEmpty
                            ? remoteChanges
                            : localChanges
                    )
                )
            }
            cursor = end
        }

        output.append(contentsOf: baseLines[cursor...])
        return ThreeWayMergeResult(
            content: output.joined(),
            hasConflicts: conflictCount > 0,
            conflictCount: conflictCount
        )
    }

    private enum Side: String, Comparable {
        case local
        case remote

        static func < (lhs: Side, rhs: Side) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Change: Equatable {
        let start: Int
        let end: Int
        let replacement: [String]
        let side: Side
    }

    private struct Match {
        let baseStart: Int
        let changedStart: Int
        let count: Int
    }

    private enum OpcodeTag {
        case replace
        case delete
        case insert
        case equal
    }

    private struct Opcode {
        let tag: OpcodeTag
        let baseStart: Int
        let baseEnd: Int
        let changedStart: Int
        let changedEnd: Int
    }

    private static func result(content: String) -> ThreeWayMergeResult {
        ThreeWayMergeResult(
            content: content,
            hasConflicts: false,
            conflictCount: 0
        )
    }

    /// Python `str.splitlines()` 뒤 각 줄에 `\n`을 붙이는 Windows 계약을
    /// 재현한다. 따라서 실제 병합 경로에서는 비어 있지 않은 결과가 LF로
    /// 정규화되지만, 위의 동일본 단축 경로는 입력 문자열을 그대로 보존한다.
    private static func lineTokens(_ value: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousWasCarriageReturn = false

        for scalar in value.unicodeScalars {
            if previousWasCarriageReturn, scalar.value == 0x0A {
                previousWasCarriageReturn = false
                continue
            }
            previousWasCarriageReturn = false

            if isLineBoundary(scalar.value) {
                lines.append(String(current) + "\n")
                current.removeAll(keepingCapacity: true)
                previousWasCarriageReturn = scalar.value == 0x0D
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty {
            lines.append(String(current) + "\n")
        }
        return lines
    }

    private static func isLineBoundary(_ value: UInt32) -> Bool {
        switch value {
        case 0x0A, 0x0B, 0x0C, 0x0D,
             0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
            true
        default:
            false
        }
    }

    private static func changes(
        from base: [String],
        to changed: [String],
        side: Side
    ) -> [Change] {
        opcodes(base: base, changed: changed).compactMap { opcode in
            guard opcode.tag != .equal else { return nil }
            return Change(
                start: opcode.baseStart,
                end: opcode.baseEnd,
                replacement: Array(
                    changed[opcode.changedStart..<opcode.changedEnd]
                ),
                side: side
            )
        }
    }

    /// `difflib.SequenceMatcher(autojunk=False)`의 관찰 가능한 line opcode
    /// 선택 규칙을 이식한다. 동률에서는 base와 changed의 더 이른 match가
    /// 선택되므로 Windows와 동일한 충돌 구간을 만든다.
    private static func opcodes<Element: Hashable>(
        base: [Element],
        changed: [Element]
    ) -> [Opcode] {
        let matches = matchingBlocks(base: base, changed: changed)
        var result: [Opcode] = []
        var baseIndex = 0
        var changedIndex = 0

        for match in matches {
            let tag: OpcodeTag?
            if baseIndex < match.baseStart,
               changedIndex < match.changedStart {
                tag = .replace
            } else if baseIndex < match.baseStart {
                tag = .delete
            } else if changedIndex < match.changedStart {
                tag = .insert
            } else {
                tag = nil
            }
            if let tag {
                result.append(
                    Opcode(
                        tag: tag,
                        baseStart: baseIndex,
                        baseEnd: match.baseStart,
                        changedStart: changedIndex,
                        changedEnd: match.changedStart
                    )
                )
            }
            if match.count > 0 {
                result.append(
                    Opcode(
                        tag: .equal,
                        baseStart: match.baseStart,
                        baseEnd: match.baseStart + match.count,
                        changedStart: match.changedStart,
                        changedEnd: match.changedStart + match.count
                    )
                )
            }
            baseIndex = match.baseStart + match.count
            changedIndex = match.changedStart + match.count
        }
        return result
    }

    private static func matchingBlocks<Element: Hashable>(
        base: [Element],
        changed: [Element]
    ) -> [Match] {
        typealias Region = (
            baseLow: Int,
            baseHigh: Int,
            changedLow: Int,
            changedHigh: Int
        )
        var changedIndices: [Element: [Int]] = [:]
        for (index, line) in changed.enumerated() {
            changedIndices[line, default: []].append(index)
        }

        var queue: [Region] = [(0, base.count, 0, changed.count)]
        var matches: [Match] = []
        while let region = queue.popLast() {
            let match = longestMatch(
                base: base,
                changed: changed,
                changedIndices: changedIndices,
                region: region
            )
            guard match.count > 0 else { continue }
            matches.append(match)
            if region.baseLow < match.baseStart,
               region.changedLow < match.changedStart {
                queue.append(
                    (
                        region.baseLow,
                        match.baseStart,
                        region.changedLow,
                        match.changedStart
                    )
                )
            }
            let baseAfter = match.baseStart + match.count
            let changedAfter = match.changedStart + match.count
            if baseAfter < region.baseHigh,
               changedAfter < region.changedHigh {
                queue.append(
                    (
                        baseAfter,
                        region.baseHigh,
                        changedAfter,
                        region.changedHigh
                    )
                )
            }
        }

        matches.sort {
            if $0.baseStart != $1.baseStart {
                return $0.baseStart < $1.baseStart
            }
            return $0.changedStart < $1.changedStart
        }
        var collapsed: [Match] = []
        for match in matches {
            if let last = collapsed.last,
               last.baseStart + last.count == match.baseStart,
               last.changedStart + last.count == match.changedStart {
                collapsed[collapsed.count - 1] = Match(
                    baseStart: last.baseStart,
                    changedStart: last.changedStart,
                    count: last.count + match.count
                )
            } else {
                collapsed.append(match)
            }
        }
        collapsed.append(
            Match(
                baseStart: base.count,
                changedStart: changed.count,
                count: 0
            )
        )
        return collapsed
    }

    private static func longestMatch<Element: Hashable>(
        base: [Element],
        changed: [Element],
        changedIndices: [Element: [Int]],
        region: (
            baseLow: Int,
            baseHigh: Int,
            changedLow: Int,
            changedHigh: Int
        )
    ) -> Match {
        var bestBase = region.baseLow
        var bestChanged = region.changedLow
        var bestCount = 0
        var previousLengths: [Int: Int] = [:]

        for baseIndex in region.baseLow..<region.baseHigh {
            var currentLengths: [Int: Int] = [:]
            for changedIndex in changedIndices[base[baseIndex]] ?? [] {
                if changedIndex < region.changedLow { continue }
                if changedIndex >= region.changedHigh { break }
                let count = (previousLengths[changedIndex - 1] ?? 0) + 1
                currentLengths[changedIndex] = count
                if count > bestCount {
                    bestBase = baseIndex - count + 1
                    bestChanged = changedIndex - count + 1
                    bestCount = count
                }
            }
            previousLengths = currentLengths
        }

        while bestBase > region.baseLow,
              bestChanged > region.changedLow,
              base[bestBase - 1] == changed[bestChanged - 1] {
            bestBase -= 1
            bestChanged -= 1
            bestCount += 1
        }
        while bestBase + bestCount < region.baseHigh,
              bestChanged + bestCount < region.changedHigh,
              base[bestBase + bestCount] == changed[bestChanged + bestCount] {
            bestCount += 1
        }
        return Match(
            baseStart: bestBase,
            changedStart: bestChanged,
            count: bestCount
        )
    }

    private static func differenceSummary(
        base: [String],
        local: [String],
        remote: [String]
    ) -> [String] {
        let baseScalars = base.joined().unicodeScalars.map(\.value)
        let localScalars = local.joined().unicodeScalars.map(\.value)
        let remoteScalars = remote.joined().unicodeScalars.map(\.value)
        let localDifferences = changedDifferences(
            base: baseScalars,
            changed: localScalars
        )
        let remoteDifferences = changedDifferences(
            base: baseScalars,
            changed: remoteScalars
        )

        var output: [String] = []
        if !localDifferences.isEmpty {
            output.append(
                "로컬 : \(localDifferences.joined(separator: " "))\n"
            )
        }
        if !remoteDifferences.isEmpty {
            output.append(
                "서버 : \(remoteDifferences.joined(separator: " "))\n"
            )
        }
        return output
    }

    private static func changedDifferences(
        base: [UInt32],
        changed: [UInt32]
    ) -> [String] {
        var differences: [String] = []
        for opcode in opcodes(base: base, changed: changed) {
            guard opcode.tag != .equal else { continue }
            let value = scalarString(
                changed[opcode.changedStart..<opcode.changedEnd]
            )
            if let visible = visibleDifference(value) {
                differences.append(visible)
            }
        }
        return differences
    }

    private static func scalarString(
        _ values: ArraySlice<UInt32>
    ) -> String {
        var scalars = String.UnicodeScalarView()
        for value in values {
            if let scalar = UnicodeScalar(value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    private static func visibleDifference(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let visible = value
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\n", with: " ↵ ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return visible.isEmpty ? nil : visible
    }

    private static func clusters(_ changes: [Change]) -> [[Change]] {
        var remaining = changes
        var result: [[Change]] = []

        while !remaining.isEmpty {
            var cluster = [remaining.removeFirst()]
            var expanded = true
            while expanded {
                expanded = false
                var index = 0
                while index < remaining.count {
                    let candidate = remaining[index]
                    if cluster.contains(where: {
                        overlaps(candidate, $0)
                    }) {
                        cluster.append(candidate)
                        remaining.remove(at: index)
                        expanded = true
                    } else {
                        index += 1
                    }
                }
            }
            result.append(cluster.sorted(by: changeOrder))
        }
        return result.sorted {
            let lhsStart = $0.map(\.start).min() ?? 0
            let rhsStart = $1.map(\.start).min() ?? 0
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            let lhsEnd = $0.map(\.end).min() ?? 0
            let rhsEnd = $1.map(\.end).min() ?? 0
            return lhsEnd < rhsEnd
        }
    }

    private static func overlaps(_ first: Change, _ second: Change) -> Bool {
        if first.start == first.end, second.start == second.end {
            return first.start == second.start
        }
        if first.start == first.end {
            return second.start < first.start && first.start < second.end
        }
        if second.start == second.end {
            return first.start < second.start && second.start < first.end
        }
        return max(first.start, second.start) < min(first.end, second.end)
    }

    private static func changeOrder(_ lhs: Change, _ rhs: Change) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.side < rhs.side
    }

    private static func applySegment(
        _ base: [String],
        start: Int,
        end: Int,
        changes: [Change]
    ) -> [String] {
        var cursor = start
        var output: [String] = []
        for change in changes.sorted(by: changeOrder) {
            output.append(contentsOf: base[cursor..<change.start])
            output.append(contentsOf: change.replacement)
            cursor = change.end
        }
        output.append(contentsOf: base[cursor..<end])
        return output
    }

    private static func ensureNewline(_ lines: [String]) -> String {
        var value = lines.joined()
        if !value.isEmpty, !value.hasSuffix("\n") {
            value.append("\n")
        }
        return value
    }
}
