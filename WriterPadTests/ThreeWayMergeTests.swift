import CryptoKit
import XCTest
@testable import WriterPad

final class ThreeWayMergeTests: XCTestCase {
    func testSharedWindowsFixtureMatchesSwiftResults() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, 3)
        XCTAssertEqual(
            Set(fixture.cases.map(\.id)),
            [
                "non_overlapping",
                "adjacent_insertion",
                "line_deletion",
                "final_newline",
                "empty_document",
                "korean_emoji",
                "same_line_conflict",
            ]
        )

        for testCase in fixture.cases {
            let result = ThreeWayMerge.merge(
                base: testCase.base,
                local: testCase.local,
                remote: testCase.remote
            )
            XCTAssertEqual(
                result.content,
                testCase.expectedContent,
                testCase.id
            )
            XCTAssertEqual(
                result.hasConflicts,
                testCase.expectedHasConflicts,
                testCase.id
            )
            XCTAssertEqual(
                result.conflictCount,
                testCase.expectedConflictCount,
                testCase.id
            )
        }
    }

    func testLargeSharedFixtureMatchesWindowsDigest() throws {
        let fixture = try loadFixture()
        let testCase = try XCTUnwrap(
            fixture.generatedCases.first { $0.id == "large_document" }
        )
        let inputs = try testCase.generator.materialize()

        let result = ThreeWayMerge.merge(
            base: inputs.base,
            local: inputs.local,
            remote: inputs.remote
        )

        XCTAssertEqual(
            sha256(result.content),
            testCase.expectedContentSHA256
        )
        XCTAssertEqual(
            result.content.lengthOfBytes(using: .utf8),
            testCase.expectedUTF8ByteCount
        )
        XCTAssertEqual(
            result.hasConflicts,
            testCase.expectedHasConflicts
        )
        XCTAssertEqual(
            result.conflictCount,
            testCase.expectedConflictCount
        )
    }

    func testSameLineConflictNeverSelectsOneSideSilently() throws {
        let result = ThreeWayMerge.merge(
            base: "공통 문장\n",
            local: "내 수정\n",
            remote: "서버 수정\n"
        )

        XCTAssertTrue(result.hasConflicts)
        XCTAssertEqual(result.conflictCount, 1)
        XCTAssertTrue(result.content.contains("내 수정\n"))
        XCTAssertTrue(result.content.contains("공통 문장\n"))
        XCTAssertTrue(result.content.contains("서버 수정\n"))
        XCTAssertTrue(result.content.contains("바꾸기 전 원본"))
        XCTAssertTrue(result.content.contains("로컬 편집본"))
        XCTAssertTrue(result.content.contains("서버 최신본"))
        let differenceSection = try XCTUnwrap(
            result.content.components(
                separatedBy: "로컬과 서버 차이점\n\n"
            ).last
        )
        XCTAssertTrue(differenceSection.contains("로컬 : 내 수정"))
        XCTAssertTrue(differenceSection.contains("서버 : 서버 수정"))
        XCTAssertTrue(
            result.content.hasPrefix(
                "=========\n\n바꾸기 전 원본"
            )
        )
    }

    func testDifferenceSectionOmitsSideWithoutContent() throws {
        let result = ThreeWayMerge.merge(
            base: "기준 문장\n",
            local: "",
            remote: "서버 문장\n"
        )

        XCTAssertTrue(result.hasConflicts)
        let differenceSection = try XCTUnwrap(
            result.content.components(
                separatedBy: "로컬과 서버 차이점\n\n"
            ).last
        )
        XCTAssertFalse(differenceSection.contains("로컬 :"))
        XCTAssertTrue(differenceSection.contains("서버 : 서버"))
    }

    func testDifferenceSectionAggregatesEachSideOnOneLine() throws {
        let result = ThreeWayMerge.merge(
            base: "기준 공통 기준\n",
            local: "야이 공통 씨발아\n",
            remote: "테스트테스트 공통 문재인\n"
        )

        XCTAssertTrue(result.hasConflicts)
        let differenceSection = try XCTUnwrap(
            result.content.components(
                separatedBy: "로컬과 서버 차이점\n\n"
            ).last
        )
        XCTAssertTrue(
            differenceSection.contains("로컬 : 야이 씨발아")
        )
        XCTAssertTrue(
            differenceSection.contains(
                "서버 : 테스트테스트 문재인"
            )
        )
        XCTAssertFalse(differenceSection.contains("차이 1"))
        XCTAssertFalse(differenceSection.contains("(없음)"))
    }

    func testDifferenceSectionKeepsSharedWordsAddedByBothSides() throws {
        let base = "내 아이디어를 훔쳐 간 팀장이 임원들 앞에서 웃고 있었다."
        let result = ThreeWayMerge.merge(
            base: base,
            local: base + "이 씨발놈들아",
            remote: base
                + "예? 저요? 제가 왜 씨발놈이죠 씨발놈아ㅁㄴㅇㅎㅇㅇ"
        )

        XCTAssertTrue(result.hasConflicts)
        let differenceSection = try XCTUnwrap(
            result.content.components(
                separatedBy: "로컬과 서버 차이점\n\n"
            ).last
        )
        XCTAssertTrue(
            differenceSection.contains("로컬 : 이 씨발놈들아")
        )
        XCTAssertTrue(
            differenceSection.contains(
                "서버 : 예? 저요? 제가 왜 씨발놈이죠 씨발놈아ㅁㄴㅇㅎㅇㅇ"
            )
        )
        XCTAssertFalse(differenceSection.contains("로컬 : 이 들"))
    }

    private func loadFixture() throws -> MergeFixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "three_way_merge_cases",
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            MergeFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct MergeFixture: Decodable {
    let version: Int
    let cases: [MergeFixtureCase]
    let generatedCases: [GeneratedMergeFixtureCase]
}

private struct MergeFixtureCase: Decodable {
    let id: String
    let base: String
    let local: String
    let remote: String
    let expectedContent: String
    let expectedHasConflicts: Bool
    let expectedConflictCount: Int
}

private struct GeneratedMergeFixtureCase: Decodable {
    let id: String
    let generator: NumberedLinesGenerator
    let expectedContentSHA256: String
    let expectedUTF8ByteCount: Int
    let expectedHasConflicts: Bool
    let expectedConflictCount: Int
}

private struct NumberedLinesGenerator: Decodable {
    let kind: String
    let lineCount: Int
    let localReplacements: [LineReplacement]
    let remoteReplacements: [LineReplacement]

    func materialize() throws -> (
        base: String,
        local: String,
        remote: String
    ) {
        guard kind == "numberedLines" else {
            throw FixtureError.unsupportedGenerator(kind)
        }
        let baseLines = (0..<lineCount).map {
            String(format: "공통 %05d 😀\n", $0)
        }
        var localLines = baseLines
        var remoteLines = baseLines
        try apply(localReplacements, to: &localLines)
        try apply(remoteReplacements, to: &remoteLines)
        return (
            baseLines.joined(),
            localLines.joined(),
            remoteLines.joined()
        )
    }

    private func apply(
        _ replacements: [LineReplacement],
        to lines: inout [String]
    ) throws {
        for replacement in replacements {
            guard lines.indices.contains(replacement.index) else {
                throw FixtureError.invalidLineIndex(replacement.index)
            }
            lines[replacement.index] = replacement.value
        }
    }
}

private struct LineReplacement: Decodable {
    let index: Int
    let value: String
}

private enum FixtureError: Error {
    case unsupportedGenerator(String)
    case invalidLineIndex(Int)
}
