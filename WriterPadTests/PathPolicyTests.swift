import Foundation
import XCTest
@testable import WriterPad

final class PathPolicyTests: XCTestCase {
    private let policy = PathPolicy()

    func testKoreanNamesAndTextExtensionAreAccepted() throws {
        try policy.validateName("흐름 정리")
        XCTAssertEqual(try policy.textFileName(forDisplayName: "001화"), "001화.txt")
        XCTAssertEqual(try policy.textFileName(forDisplayName: "메모.TXT"), "메모.txt")
        XCTAssertEqual(policy.binderDisplayName(forStoredName: "메모.txt"), "메모")
        XCTAssertEqual(policy.binderDisplayName(forStoredName: "자료.md"), "자료.md")
    }

    func testAllWindowsForbiddenCharactersAreRejected() {
        for character in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"] {
            assertRejected("이름\(character)문서")
        }
    }

    func testControlCharactersAndInvalidEndingsAreRejected() {
        assertRejected("줄\n바꿈")
        assertRejected("탭\t문서")
        assertRejected("끝공백 ")
        assertRejected("끝마침표.")
        assertRejected("")
        assertRejected(".")
        assertRejected("..")
    }

    func testReservedWindowsNamesAreRejectedRegardlessOfCaseOrExtension() {
        let fixed = ["CON", "prn.txt", "Aux.TXT", "nul", "CON .txt"]
        let numbered = (1...9).flatMap { ["COM\($0)", "com\($0).txt", "LPT\($0)", "lpt\($0).TXT"] }
        for name in fixed + numbered {
            assertRejected(name)
        }
    }

    func testCaseInsensitiveAndNFCCollisionsAreRejected() throws {
        XCTAssertThrowsError(
            try policy.validateUniqueName("plot.txt", among: ["Plot.txt"])
        )

        let composed = "\u{AC00}.txt"
        let decomposed = "\u{1100}\u{1161}.txt"
        XCTAssertEqual(policy.collisionKey(for: composed), policy.collisionKey(for: decomposed))
        XCTAssertThrowsError(
            try policy.validateUniqueName(decomposed, among: [composed])
        )
    }

    func testConfigurableNameAndRelativePathLimits() {
        let limited = PathPolicy(
            limits: .init(
                maximumNameUTF16Length: 5,
                maximumRelativePathUTF16Length: 12
            )
        )
        XCTAssertThrowsError(try limited.validateName("123456"))
        XCTAssertThrowsError(
            try limited.validateRelativePath(
                RelativeDocumentPath(rawValue: "메인/12345/문서.txt")
            )
        )
    }

    func testAbsoluteAndTraversalPathsAreRejected() {
        for path in [
            "/tmp/escape.txt",
            "~/escape.txt",
            "C:\\escape.txt",
            "../escape.txt",
            "메인/../escape.txt",
            "메인//escape.txt"
        ] {
            XCTAssertThrowsError(
                try policy.validateRelativePath(RelativeDocumentPath(rawValue: path)),
                "허용되면 안 되는 경로: \(path)"
            )
        }
    }

    private func assertRejected(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try policy.validateName(name),
            "허용되면 안 되는 이름: \(name)",
            file: file,
            line: line
        )
    }
}
