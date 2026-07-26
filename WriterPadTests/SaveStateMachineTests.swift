import Foundation
import XCTest
@testable import WriterPad

final class SaveStateMachineTests: XCTestCase {
    private let contentHash = ContentHash(rawValue: String(repeating: "b", count: 64))!
    private let date = Date(timeIntervalSince1970: 2_000)

    func testEditingSavingAndSavedTransition() {
        let editing = SaveStateMachine.reduce(.idle, event: .edited(generation: 1))
        let saving = SaveStateMachine.reduce(editing, event: .saveStarted(generation: 1))
        let saved = SaveStateMachine.reduce(
            saving,
            event: .saveSucceeded(generation: 1, savedAt: date, contentHash: contentHash)
        )

        XCTAssertEqual(editing, .editing(generation: 1))
        XCTAssertEqual(saving, .saving(generation: 1))
        XCTAssertEqual(
            saved,
            .saved(generation: 1, savedAt: date, contentHash: contentHash)
        )
    }

    func testOlderSaveCompletionCannotOverwriteNewerEditingState() {
        let current = SaveState.editing(generation: 2)
        let result = SaveStateMachine.reduce(
            current,
            event: .saveSucceeded(generation: 1, savedAt: date, contentHash: contentHash)
        )

        XCTAssertEqual(result, current)
    }

    func testLocalBadgeTransitionsAndRetryPresentation() {
        let editing = SaveStateMachine.reduce(.idle, event: .edited(generation: 1))
        let saving = SaveStateMachine.reduce(editing, event: .saveStarted(generation: 1))
        let saved = SaveStateMachine.reduce(
            saving,
            event: .saveSucceeded(generation: 1, savedAt: date, contentHash: contentHash)
        )
        let editedAgain = SaveStateMachine.reduce(saved, event: .edited(generation: 2))
        let failed = SaveStateMachine.reduce(
            .saving(generation: 3),
            event: .saveFailed(generation: 3, message: "disk full")
        )

        XCTAssertEqual(SaveStateMachine.presentation(for: editing).label, "편집 중")
        XCTAssertEqual(SaveStateMachine.presentation(for: saving).label, "로컬 저장 중")
        XCTAssertEqual(SaveStateMachine.presentation(for: saved).label, "로컬 저장됨")
        XCTAssertEqual(SaveStateMachine.presentation(for: editedAgain).label, "편집 중")
        XCTAssertTrue(SaveStateMachine.presentation(for: failed).allowsRetry)
        XCTAssertEqual(
            SaveStateMachine.presentation(for: failed).systemImage,
            "exclamationmark.triangle"
        )
    }

    func testNoOpSyncBoundaryStaysLocalOnly() async {
        let notifier = NoOpFutureChangeNotifier()
        XCTAssertEqual(notifier.mode, .localOnly)
        await notifier.record(.appLaunched)
    }
}
