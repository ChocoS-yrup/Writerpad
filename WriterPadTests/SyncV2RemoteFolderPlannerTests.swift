import Foundation
import XCTest
@testable import WriterPad

/// 요구사항 5의 항목을 하나씩 고정한다. 이 판단이 틀리면 받는 기기에 폴더가
/// 둘 남거나 사용자의 자료가 사라진다.
final class SyncV2RemoteFolderPlannerTests: XCTestCase {
    private let projectID = ProjectID(rawValue: UUID())
    private let rootID = DocumentID(rawValue: UUID())

    /// 이 전환이 고치려는 증상 그 자체다. 빈 폴더의 이름이 바뀌면 지우고 새로
    /// 만드는 것이 아니라 있던 폴더가 옮겨져야 한다.
    func testRenamedEmptyFolderMovesInsteadOfBeingRecreated() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(
                    id: folderID,
                    parent: rootID,
                    name: "가 나 다 바"
                ),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/가 나 다", parent: rootID),
            ]
        )

        XCTAssertEqual(
            plan.actions,
            [
                .move(
                    folderID: folderID,
                    from: RelativeDocumentPath(rawValue: "메인/가 나 다"),
                    to: RelativeDocumentPath(rawValue: "메인/가 나 다 바")
                )
            ]
        )
    }

    func testFolderMissingFromTheServerIsLeftAlone() {
        let localOnlyID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [remoteFolder(id: rootID, parent: nil, name: "메인")],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: localOnlyID, path: "메인/새 폴더", parent: rootID),
            ]
        )

        // 서버에 없다는 것과 지워졌다는 것은 다르다. 아직 못 올린 폴더를
        // 지우면 사용자가 만든 것이 사라진다.
        XCTAssertTrue(plan.isEmpty)
    }

    func testOnlyTombstoneCausesDeletion() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(
                    id: folderID,
                    parent: rootID,
                    name: "지운 폴더",
                    isDeleted: true
                ),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/지운 폴더", parent: rootID),
            ]
        )

        XCTAssertEqual(
            plan.actions,
            [
                .delete(
                    folderID: folderID,
                    path: RelativeDocumentPath(rawValue: "메인/지운 폴더")
                )
            ]
        )
    }

    func testOccupiedDestinationIsPreservedAsAConflict() {
        let movingID = DocumentID(rawValue: UUID())
        let sittingID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: movingID, parent: rootID, name: "나중"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: movingID, path: "메인/처음", parent: rootID),
                folder(id: sittingID, path: "메인/나중", parent: rootID),
            ]
        )

        // 덮어쓰거나 합치면 이미 있던 폴더의 내용이 사라진다.
        XCTAssertEqual(
            plan.actions,
            [
                .conflict(
                    folderID: movingID,
                    path: RelativeDocumentPath(rawValue: "메인/나중"),
                    reason: .destinationOccupied
                )
            ]
        )
    }

    func testFolderWithUnsentLocalWorkIsNotOverwritten() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "서버 이름"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/내 이름", parent: rootID),
            ],
            blockedFolderIDs: [folderID]
        )

        XCTAssertEqual(
            plan.actions,
            [
                .conflict(
                    folderID: folderID,
                    path: RelativeDocumentPath(rawValue: "메인/내 이름"),
                    reason: .pendingLocalOperation
                )
            ]
        )
    }

    func testTwoFoldersWantingTheSamePlaceBothStandStill() {
        let firstID = DocumentID(rawValue: UUID())
        let secondID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: firstID, parent: rootID, name: "같은 이름"),
                remoteFolder(id: secondID, parent: rootID, name: "같은 이름"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: firstID, path: "메인/하나", parent: rootID),
                folder(id: secondID, path: "메인/둘", parent: rootID),
            ]
        )

        // 먼저 처리한 쪽이 이기게 두면 나머지 하나가 조용히 사라진다.
        XCTAssertEqual(plan.actions.count, 2)
        XCTAssertTrue(
            plan.actions.allSatisfy {
                if case .conflict(_, _, .destinationOccupied) = $0 {
                    return true
                }
                return false
            }
        )
    }

    /// 서로 자리를 맞바꾸는 두 폴더가 서로를 막으면 안 된다. 비켜나는 자리는
    /// 목적지로 쓸 수 있어야 한다.
    func testFolderCanMoveIntoAPlaceAnotherFolderIsLeaving() {
        let movingID = DocumentID(rawValue: UUID())
        let leavingID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: movingID, parent: rootID, name: "나"),
                remoteFolder(id: leavingID, parent: rootID, name: "다"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: movingID, path: "메인/가", parent: rootID),
                folder(id: leavingID, path: "메인/나", parent: rootID),
            ]
        )

        XCTAssertEqual(plan.actions.count, 2)
        XCTAssertTrue(
            plan.actions.allSatisfy {
                if case .move = $0 { return true }
                return false
            }
        )
    }

    func testParentMovesBeforeItsChild() {
        let parentID = DocumentID(rawValue: UUID())
        let childID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: parentID, parent: rootID, name: "새 부모"),
                remoteFolder(id: childID, parent: parentID, name: "새 자식"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: parentID, path: "메인/옛 부모", parent: rootID),
                folder(
                    id: childID,
                    path: "메인/옛 부모/옛 자식",
                    parent: parentID
                ),
            ]
        )

        // 부모를 옮기면 자식은 따라온다. 순서가 뒤집히면 자식이 옛 자리를 찾다
        // 실패한다.
        guard case let .move(firstID, _, _) = plan.actions.first else {
            return XCTFail("Expected a move first, got \(plan.actions).")
        }
        XCTAssertEqual(firstID, parentID)
        XCTAssertEqual(plan.actions.count, 2)
    }

    func testCycleFromTheServerIsRefusedInsteadOfApplied() {
        let firstID = DocumentID(rawValue: UUID())
        let secondID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: firstID, parent: secondID, name: "가"),
                remoteFolder(id: secondID, parent: firstID, name: "나"),
            ],
            documents: [
                folder(id: firstID, path: "메인/가", parent: nil),
                folder(id: secondID, path: "메인/나", parent: nil),
            ]
        )

        XCTAssertEqual(plan.actions.count, 2)
        XCTAssertTrue(
            plan.actions.allSatisfy {
                if case .conflict(_, _, .parentCycle) = $0 { return true }
                return false
            }
        )
    }

    func testFolderNewToThisDeviceIsCreated() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "새 폴더"),
            ],
            documents: [folder(id: rootID, path: "메인", parent: nil)]
        )

        XCTAssertEqual(
            plan.actions,
            [
                .create(
                    folderID: folderID,
                    parentID: rootID,
                    path: RelativeDocumentPath(rawValue: "메인/새 폴더")
                )
            ]
        )
    }

    /// 아직 이관되지 않은 상위 폴더가 있어도 그 아래는 반영할 수 있어야 한다.
    func testParentKnownOnlyLocallyStillYieldsAPath() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: folderID, parent: rootID, name: "새 이름"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/옛 이름", parent: rootID),
            ]
        )

        XCTAssertEqual(
            plan.actions,
            [
                .move(
                    folderID: folderID,
                    from: RelativeDocumentPath(rawValue: "메인/옛 이름"),
                    to: RelativeDocumentPath(rawValue: "메인/새 이름")
                )
            ]
        )
    }

    func testUnchangedFolderProducesNoAction() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "그대로"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(id: folderID, path: "메인/그대로", parent: rootID),
            ]
        )

        XCTAssertTrue(plan.isEmpty)
    }

    /// macOS 파일 이름은 자모가 분해된 형태로 들어올 수 있다. 정규화하지 않으면
    /// 바뀐 것이 없는데도 매번 옮기려 든다.
    func testDecomposedLocalNameIsNotSeenAsAChange() {
        let folderID = DocumentID(rawValue: UUID())
        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: [
                remoteFolder(id: rootID, parent: nil, name: "메인"),
                remoteFolder(id: folderID, parent: rootID, name: "가나다"),
            ],
            documents: [
                folder(id: rootID, path: "메인", parent: nil),
                folder(
                    id: folderID,
                    path: "메인/가나다"
                        .decomposedStringWithCanonicalMapping,
                    parent: rootID
                ),
            ]
        )

        XCTAssertTrue(plan.isEmpty)
    }

    private func remoteFolder(
        id: DocumentID,
        parent: DocumentID?,
        name: String,
        isDeleted: Bool = false,
        revision: Int64 = 1
    ) -> SyncV2RemoteFolder {
        SyncV2RemoteFolder(
            folderID: id.rawValue,
            parentFolderID: parent?.rawValue,
            name: name,
            revision: revision,
            isDeleted: isDeleted,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func folder(
        id: DocumentID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        DocumentNode(
            id: id,
            projectID: projectID,
            kind: .folder,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }
}
