import XCTest
@testable import WriterPad

final class BinderRuleServiceTests: XCTestCase {
    private let service = BinderRuleService()

    func testHierarchyPolicyAllowsOnlyFoldersAtTopLevel() {
        let policy = BinderHierarchyPolicy()
        let projectID = ProjectID(rawValue: UUID())
        let root = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderHierarchyPolicy.topLevelPath,
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let folder = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: root.id,
            relativePath: RelativeDocumentPath(rawValue: "메인/자료"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
        let text = DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: root.id,
            relativePath: RelativeDocumentPath(rawValue: "메인/초안.txt"),
            userOrder: 1,
            modifiedAt: .distantPast,
            contentHash: nil
        )

        XCTAssertNil(policy.placementViolation(for: .folder, in: root))
        XCTAssertEqual(
            policy.placementViolation(for: .text, in: root),
            .documentAtTopLevel
        )
        XCTAssertNil(policy.placementViolation(for: .text, in: folder))
        XCTAssertEqual(policy.invalidTopLevelDocuments(in: [root, folder, text]), [text])
    }

    func testVolumeNameMatrixUsesCanonicalASCIINumbers() {
        let cases: [(String, Int?)] = [
            ("1권", 1), ("10권", 10), ("1000권", 1_000),
            ("0권", nil), ("01권", nil), ("001권", nil),
            ("-1권", nil), ("１권", nil), ("١권", nil),
            ("1卷", nil), ("1권 ", nil)
        ]

        for (name, expected) in cases {
            XCTAssertEqual(
                service.volumeNumber(fromStoredName: name),
                expected,
                "권 이름 경계 실패: \(name)"
            )
        }
    }

    func testChapterNameMatrixDefinesPaddingThousandAndUnicodeBoundaries() {
        let cases: [(String, Int?)] = [
            ("001화.txt", 1), ("010화.txt", 10), ("999화.txt", 999),
            ("1000화.txt", 1_000), ("10000화.txt", 10_000),
            ("000화.txt", nil), ("01화.txt", nil), ("0001화.txt", nil),
            ("１00화.txt", nil), ("١٠٠화.txt", nil), ("001話.txt", nil),
            ("001화.TXT", nil), ("001화 제목.txt", nil)
        ]

        for (name, expected) in cases {
            XCTAssertEqual(
                service.canonicalChapterIdentity(fromStoredName: name)?.number,
                expected,
                "화 이름 경계 실패: \(name)"
            )
        }
    }

    func testChapterRenameNameSeparatesOnlyTheFirstPrefix() {
        let cases: [(String, String, String)] = [
            ("1화 제목", "1화 ", "제목"),
            ("17화 제목", "17화 ", "제목"),
            ("128화 결전 준비", "128화 ", "결전 준비"),
            ("17화", "17화 ", ""),
            ("17화 ", "17화 ", ""),
            ("17화 18화에서 회수할 복선", "17화 ", "18화에서 회수할 복선")
        ]

        for (displayName, prefix, suffix) in cases {
            let result = ChapterRenameName.parse(displayName: displayName)
            XCTAssertEqual(result?.displayPrefix, prefix, "분리 실패: \(displayName)")
            XCTAssertEqual(result?.editableSuffix, suffix, "분리 실패: \(displayName)")
        }
        XCTAssertNil(ChapterRenameName.parse(displayName: "등장인물 설정"))
        XCTAssertNil(ChapterRenameName.parse(displayName: "17화제목"))
    }

    func testCreationMatrixSeparatesManuscriptStructureFromGeneralNames() {
        struct Case {
            let label: String
            let request: BinderCreationRuleRequest
            let expected: BinderRuleDecision
        }
        let cases: [Case] = [
            Case(
                label: "원고 아래 정상 권",
                request: create(parent: "메인/원고", kind: .folder, name: "1권"),
                expected: .allowed
            ),
            Case(
                label: "원고 아래 TXT",
                request: create(parent: "메인/원고", kind: .text, name: "001화.txt"),
                expected: .denied(.manuscriptAcceptsVolumeFoldersOnly)
            ),
            Case(
                label: "앞자리 0 권",
                request: create(parent: "메인/원고", kind: .folder, name: "01권"),
                expected: .denied(.invalidVolumeName)
            ),
            Case(
                label: "권 안 정상 화",
                request: create(parent: "메인/원고/1권", kind: .text, name: "001화.txt"),
                expected: .allowed
            ),
            Case(
                label: "권 안 폴더",
                request: create(parent: "메인/원고/1권", kind: .folder, name: "자료"),
                expected: .denied(.volumeAcceptsChapterTextsOnly)
            ),
            Case(
                label: "권 안 대문자 확장자",
                request: create(parent: "메인/원고/1권", kind: .text, name: "001화.TXT"),
                expected: .denied(.invalidChapterName)
            ),
            Case(
                label: "화 아래 생성",
                request: create(
                    parent: "메인/원고/1권/001화.txt",
                    kind: .text,
                    name: "002화.txt"
                ),
                expected: .denied(.invalidManuscriptDestination)
            ),
            Case(
                label: "일반 영역 대문자 TXT",
                request: create(parent: "메인/메모장", kind: .text, name: "초안.TXT"),
                expected: .allowed
            ),
            Case(
                label: "일반 영역 안전 폴더",
                request: create(parent: "메인/설정집", kind: .folder, name: "마법 체계"),
                expected: .allowed
            )
        ]

        for item in cases {
            XCTAssertEqual(
                service.evaluateCreation(item.request),
                item.expected,
                item.label
            )
        }

        let unsafe = create(parent: "메인/메모장", kind: .text, name: "CON.txt")
        assertDenied(service.evaluateCreation(unsafe), matching: {
            if case .invalidWindowsName = $0 { return true }
            return false
        })
    }

    func testCreationRejectsGlobalChapterNumberAndNormalizedNameDuplicates() {
        let duplicateChapter = BinderCreationRuleRequest(
            parentPath: path("메인/원고/2권"),
            kind: .text,
            storedName: "001화.txt",
            existingManuscriptChapterPaths: [
                path("메인/원고/1권/001화 첫 만남.txt")
            ]
        )
        XCTAssertEqual(
            service.evaluateCreation(duplicateChapter),
            .denied(.duplicateChapterNumber(1))
        )

        let composed = "가.txt"
        let decomposed = "\u{1100}\u{1161}.txt"
        let normalizedDuplicate = BinderCreationRuleRequest(
            parentPath: path("메인/메모장"),
            kind: .text,
            storedName: decomposed,
            existingSiblingNames: [composed]
        )
        XCTAssertEqual(
            service.evaluateCreation(normalizedDuplicate),
            .denied(.duplicateNormalizedName(composed))
        )
    }

    func testRenameMatrixLocksVolumeAndChapterPrefixButAllowsChapterTitle() {
        let volumeCases: [(String, BinderRuleDecision)] = [
            ("1권", .allowed),
            ("2권", .denied(.volumeNameLocked))
        ]
        for (name, expected) in volumeCases {
            XCTAssertEqual(
                service.evaluateRename(
                    BinderRenameRuleRequest(
                        sourcePath: path("메인/원고/1권"),
                        kind: .folder,
                        proposedStoredName: name,
                        existingSiblingNames: ["1권", "2권"]
                    )
                ),
                expected
            )
        }
        XCTAssertEqual(
            service.evaluateRename(
                BinderRenameRuleRequest(
                    sourcePath: path("메인/원고"),
                    kind: .folder,
                    proposedStoredName: "다른 원고"
                )
            ),
            .denied(.manuscriptRootLocked)
        )

        let chapterCases: [(String, BinderRuleDecision)] = [
            ("001화.txt", .allowed),
            ("001화 첫 만남.txt", .allowed),
            ("002화 첫 만남.txt", .denied(.chapterPrefixLocked("001화"))),
            ("01화.txt", .denied(.invalidChapterName)),
            ("001화.TXT", .denied(.invalidChapterName))
        ]
        for (name, expected) in chapterCases {
            XCTAssertEqual(
                service.evaluateRename(
                    BinderRenameRuleRequest(
                        sourcePath: path("메인/원고/1권/001화.txt"),
                        kind: .text,
                        proposedStoredName: name,
                        existingSiblingNames: ["001화.txt"]
                    )
                ),
                expected,
                "화 이름 변경 경계 실패: \(name)"
            )
        }

        XCTAssertEqual(
            service.evaluateRename(
                BinderRenameRuleRequest(
                    sourcePath: path("메인/메모장/초안.txt"),
                    kind: .text,
                    proposedStoredName: "자유로운 제목.TXT",
                    existingSiblingNames: ["초안.txt"]
                )
            ),
            .allowed
        )
    }

    func testMoveMatrixProtectsManuscriptBoundaryAndStructure() {
        struct Case {
            let label: String
            let request: BinderMoveRuleRequest
            let expected: BinderRuleDecision
        }
        let sourceChapter = path("메인/원고/1권/001화.txt")
        let cases: [Case] = [
            Case(
                label: "원고 밖으로 이동",
                request: move(source: sourceChapter, kind: .text, destination: "메인/메모장"),
                expected: .denied(.manuscriptCannotLeave)
            ),
            Case(
                label: "외부 문서를 원고로 이동",
                request: move(
                    source: path("메인/메모장/001화.txt"),
                    kind: .text,
                    destination: "메인/원고/1권"
                ),
                expected: .denied(.externalItemCannotEnterManuscript)
            ),
            Case(
                label: "화를 다른 권으로 이동",
                request: BinderMoveRuleRequest(
                    sourcePath: sourceChapter,
                    kind: .text,
                    destinationFolderPath: path("메인/원고/2권"),
                    existingManuscriptChapterPaths: [sourceChapter]
                ),
                expected: .allowed
            ),
            Case(
                label: "화를 원고 루트로 이동",
                request: move(source: sourceChapter, kind: .text, destination: "메인/원고"),
                expected: .denied(.invalidManuscriptDestination)
            ),
            Case(
                label: "권을 권 안으로 이동",
                request: move(
                    source: path("메인/원고/1권"),
                    kind: .folder,
                    destination: "메인/원고/2권"
                ),
                expected: .denied(.invalidManuscriptDestination)
            ),
            Case(
                label: "일반 영역 이동",
                request: move(
                    source: path("메인/메모장/초안.txt"),
                    kind: .text,
                    destination: "메인/설정집"
                ),
                expected: .allowed
            )
        ]

        for item in cases {
            XCTAssertEqual(service.evaluateMove(item.request), item.expected, item.label)
        }

        let duplicateAtDestination = BinderMoveRuleRequest(
            sourcePath: sourceChapter,
            kind: .text,
            destinationFolderPath: path("메인/원고/2권"),
            existingManuscriptChapterPaths: [
                sourceChapter,
                path("메인/원고/2권/001화 복사본.txt")
            ]
        )
        XCTAssertEqual(
            service.evaluateMove(duplicateAtDestination),
            .denied(.duplicateChapterNumber(1))
        )
    }

    func testDropHasIndependentEntryPointAndReturnsUserReason() {
        let request = move(
            source: path("메인/캐릭터/주인공.txt"),
            kind: .text,
            destination: "메인/원고/1권"
        )
        let decision = service.evaluateDrop(request)

        XCTAssertEqual(decision, .denied(.externalItemCannotEnterManuscript))
        XCTAssertFalse(decision.userReason?.isEmpty ?? true)
    }

    func testReorderLocksManuscriptRootAndInternalNaturalOrder() {
        XCTAssertEqual(
            service.evaluateReorder(itemPath: path("메인/원고"), proposedIndex: 0),
            .allowed
        )
        XCTAssertEqual(
            service.evaluateReorder(itemPath: path("메인/원고"), proposedIndex: 2),
            .denied(.manuscriptRootLocked)
        )
        XCTAssertEqual(
            service.evaluateReorder(itemPath: path("메인/원고/1권"), proposedIndex: 3),
            .denied(.manuscriptUsesNaturalOrder)
        )
        XCTAssertEqual(
            service.evaluateReorder(itemPath: path("메인/메모장"), proposedIndex: 4),
            .allowed
        )
    }

    func testManuscriptNaturalSortUsesNumbersInsteadOfStoredUserOrder() {
        let volumes = ["10권", "2권", "1권"].sorted(by: service.manuscriptItemPrecedes)
        let chapters = ["1000화.txt", "010화.txt", "002화 제목.txt", "001화.txt"]
            .sorted(by: service.manuscriptItemPrecedes)

        XCTAssertEqual(volumes, ["1권", "2권", "10권"])
        XCTAssertEqual(
            chapters,
            ["001화.txt", "002화 제목.txt", "010화.txt", "1000화.txt"]
        )
        XCTAssertTrue(service.usesManuscriptNaturalOrder(in: path("메인/원고")))
        XCTAssertTrue(service.usesManuscriptNaturalOrder(in: path("메인/원고/1권")))
        XCTAssertFalse(service.usesManuscriptNaturalOrder(in: path("메인/메모장")))
    }

    private func create(
        parent: String,
        kind: DocumentKind,
        name: String
    ) -> BinderCreationRuleRequest {
        BinderCreationRuleRequest(
            parentPath: path(parent),
            kind: kind,
            storedName: name
        )
    }

    private func move(
        source: RelativeDocumentPath,
        kind: DocumentKind,
        destination: String
    ) -> BinderMoveRuleRequest {
        BinderMoveRuleRequest(
            sourcePath: source,
            kind: kind,
            destinationFolderPath: path(destination)
        )
    }

    private func path(_ rawValue: String) -> RelativeDocumentPath {
        RelativeDocumentPath(rawValue: rawValue)
    }

    private func assertDenied(
        _ decision: BinderRuleDecision,
        matching predicate: (BinderRuleViolation) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .denied(violation) = decision else {
            XCTFail("거부 결과가 필요합니다.", file: file, line: line)
            return
        }
        XCTAssertTrue(predicate(violation), file: file, line: line)
        XCTAssertFalse(violation.userMessage.isEmpty, file: file, line: line)
    }
}
