import Foundation
import XCTest
@testable import WriterPad

final class ProjectPathResolverTests: XCTestCase {
    func testCreatesOnlyTheFixedWindowsCompatibleStructure() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            let paths = try resolver.createStandardStructure(forProjectNamed: "한글 작품")

            for directory in paths.requiredDirectories {
                var isDirectory: ObjCBool = false
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: directory.path,
                        isDirectory: &isDirectory
                    )
                )
                XCTAssertTrue(isDirectory.boolValue)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.settingsFileURL.path))
            XCTAssertEqual(paths.trashURL.path, paths.mainURL.appendingPathComponent("휴지통").path)
            XCTAssertEqual(
                paths.storyPlotURL.path,
                paths.mainURL.appendingPathComponent("스토리 플롯").path
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: paths.workspaceRootURL.appendingPathComponent("휴지통").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: paths.mainURL.appendingPathComponent("플롯").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: paths.mainURL.appendingPathComponent("메인 스토리 틀").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: paths.backupsURL.appendingPathComponent("전환직전").path
                )
            )
        }
    }

    func testCreationIsIdempotentAndPreservesExistingSettings() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            let first = try resolver.createStandardStructure(forProjectNamed: "멱등성")
            let customSettings = Data(
                "{\"keep\":true,\"project_name\":\"멱등성\"}\n".utf8
            )
            try customSettings.write(to: first.settingsFileURL, options: .atomic)

            let second = try resolver.createStandardStructure(forProjectNamed: "멱등성")
            XCTAssertEqual(first, second)
            XCTAssertEqual(try Data(contentsOf: second.settingsFileURL), customSettings)
        }
    }

    func testProjectNameCollisionUsesCaseAndNFCNormalization() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            _ = try resolver.createStandardStructure(forProjectNamed: "Novel")
            XCTAssertThrowsError(
                try resolver.createStandardStructure(forProjectNamed: "novel")
            )
        }

        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            _ = try resolver.createStandardStructure(forProjectNamed: "\u{AC00}")
            XCTAssertThrowsError(
                try resolver.createStandardStructure(forProjectNamed: "\u{1100}\u{1161}")
            )
        }
    }

    /// Windows 탐색기는 이름 끝 공백을 조용히 잘라낸다. 앱이 그대로 두면 두
    /// 기기의 이름이 갈라지고, 실기기에서는 서버에 끝 공백 이름이 박혀 구조
    /// 동기화가 멈추기까지 했다. 저장 전에 잘라내야 한다.
    func testSanitizedNameTrimsTrailingSpacesAndNormalizesToNFC() throws {
        let policy = PathPolicy()

        XCTAssertEqual(try policy.sanitizedName("가 나 다 라 "), "가 나 다 라")
        XCTAssertEqual(try policy.sanitizedName("메모   "), "메모")

        let decomposed = "가나다".decomposedStringWithCanonicalMapping
        let sanitized = try policy.sanitizedName(decomposed)
        XCTAssertTrue(
            sanitized.utf8.elementsEqual("가나다".utf8),
            "NFC로 맞춰야 Windows가 보내는 이름과 바이트가 같아진다."
        )
    }

    func testSanitizedNameRejectsUnsupportedNames() throws {
        let policy = PathPolicy()

        XCTAssertThrowsError(try policy.sanitizedName("   ")) { error in
            XCTAssertEqual(error as? PathPolicyError, .emptyName)
        }
        XCTAssertThrowsError(try policy.sanitizedName("메모.")) { error in
            XCTAssertEqual(
                error as? PathPolicyError,
                .trailingSpaceOrPeriod
            )
        }
        for name in ["CON", "PRN", "AUX", "NUL", "CLOCK$", "COM1", "LPT9"] {
            XCTAssertThrowsError(
                try policy.sanitizedName(name),
                "Windows 예약 이름 \(name)은 거부해야 한다."
            )
        }
        for character in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"] {
            XCTAssertThrowsError(
                try policy.sanitizedName("메모\(character)"),
                "금지 문자 \(character)는 거부해야 한다."
            )
        }
    }

    /// 확장자 앞에 공백이 남으면 `이름 .txt`가 되어 Windows와 갈라진다.
    func testTextFileNameTrimsBeforeAppendingExtension() throws {
        let policy = PathPolicy()

        XCTAssertEqual(
            try policy.textFileName(forDisplayName: "첫 화 "),
            "첫 화.txt"
        )
        XCTAssertEqual(
            try policy.textFileName(forDisplayName: "첫 화 .txt"),
            "첫 화.txt"
        )
        XCTAssertThrowsError(
            try policy.textFileName(forDisplayName: "   ")
        )
    }

    func testStandardizedPathCannotEscapeWorkspaceRoot() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            let paths = try resolver.createStandardStructure(forProjectNamed: "보안")

            for rawPath in ["../escape.txt", "/tmp/escape.txt", "메인/../../escape.txt"] {
                XCTAssertThrowsError(
                    try resolver.validatedURL(
                        for: RelativeDocumentPath(rawValue: rawPath),
                        in: paths.workspaceRootURL
                    )
                )
            }
        }
    }

    func testSymlinkCannotRedirectAPathOutsideWorkspace() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            let paths = try resolver.createStandardStructure(forProjectNamed: "링크 보안")
            let outside = root.deletingLastPathComponent()
                .appendingPathComponent("Outside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }

            let link = paths.workspaceRootURL.appendingPathComponent("외부연결")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

            XCTAssertThrowsError(
                try resolver.validatedURL(
                    for: RelativeDocumentPath(rawValue: "외부연결/escape.txt"),
                    in: paths.workspaceRootURL
                )
            )
        }
    }

    func testContainedExternalURLRoundTripsToRelativePath() throws {
        try withTemporaryDirectory { root in
            let resolver = ProjectPathResolver(projectsRootURL: root)
            let paths = try resolver.createStandardStructure(forProjectNamed: "왕복")
            let expected = RelativeDocumentPath(rawValue: "메인/원고/1권/001화.txt")
            let url = try resolver.validatedURL(
                for: expected,
                in: paths.workspaceRootURL
            )

            XCTAssertEqual(
                try resolver.validatedRelativePath(
                    for: url,
                    in: paths.workspaceRootURL
                ),
                expected
            )
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPadPaths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
