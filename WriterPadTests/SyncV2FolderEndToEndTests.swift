import Foundation
import XCTest
@testable import WriterPad

/// 요구사항 8에서 여러 구간을 관통하는 항목들이다. 대기열·전송·재시도·원격
/// 반영이 함께 맞물려야만 통과하므로, 한 구간만 고쳐서는 통과할 수 없다.
final class SyncV2FolderEndToEndTests: XCTestCase {
    /// 이 전환이 고치려는 증상 그 자체다. 보내는 기기에서 이름을 바꾸면 받는
    /// 기기에 옛 이름과 새 이름의 폴더가 함께 남으면 안 된다.
    func testRenamedEmptyFolderLeavesExactlyOneFolderOnTheOtherDevice()
        async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let rootID = UUID()
        let folderID = UUID()

        // 보내는 기기: 폴더를 만들고 서버에 올린다.
        try await sender.enqueue(
            operationID: UUID(),
            folderID: rootID,
            parentFolderID: nil,
            name: "메인"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: rootID,
            name: "가 나 다"
        )
        await sender.drain(now: 10)

        // 보내는 기기: 같은 folder_id로 이름만 바꾼다.
        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: rootID,
            name: "가 나 다 바"
        )
        await sender.drain(now: 20)

        // 받는 기기: 옛 이름으로 폴더를 갖고 있다가 서버 목록을 반영한다.
        let receiver = try FolderReceiverFixture(
            documents: [
                receiverFolder(id: rootID, path: "메인", parent: nil),
                receiverFolder(
                    id: folderID,
                    path: "메인/가 나 다",
                    parent: rootID
                ),
            ]
        )
        try receiver.makeDirectory("메인/가 나 다")

        _ = await receiver.applier.applyRemoteFolders(
            localProjectID: receiver.projectID,
            remote: await server.folderList(),
            blockedFolderIDs: []
        )

        let stored = try await receiver.repository.documents(
            in: receiver.projectID
        )
        let folders = stored.filter { $0.kind == .folder }
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(
            folders.first { $0.id == DocumentID(rawValue: folderID) }?
                .relativePath.rawValue,
            "메인/가 나 다 바"
        )
        XCTAssertTrue(receiver.exists("메인/가 나 다 바"))
        XCTAssertFalse(receiver.exists("메인/가 나 다"))
        await sender.close()
    }

    /// 끊긴 채로 앱을 껐다 켜도 같은 작업이어야 한다. 새 operation_id를 만들면
    /// 서버가 다른 작업으로 보고 폴더를 한 번 더 만든다.
    func testOfflineRenameKeepsItsOperationIDAcrossRestart() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let renameID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)

        await sender.setOffline(true)
        try await sender.enqueue(
            operationID: renameID,
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다 바"
        )
        await sender.drain(now: 20)
        let offlineCalls = await sender.client.folderOperationIDs()

        // 앱을 껐다 켠다. 대기 중인 작업이 사라지면 안 된다.
        try await sender.restart()
        await sender.setOffline(false)
        await sender.drain(now: 10_000)

        let calls = await sender.client.folderOperationIDs()
        let liveCount = await server.liveFolderCount()
        let storedName = await server.name(of: folderID)
        XCTAssertEqual(offlineCalls.last, renameID)
        XCTAssertEqual(calls.filter { $0 == renameID }.count, 2)
        XCTAssertEqual(liveCount, 1)
        XCTAssertEqual(storedName, "가 나 다 바")
        await sender.close()
    }

    /// 응답이 오는 길에 끊기면 같은 요청을 다시 보내게 된다. 서버는 같은
    /// operation_id를 다시 반영하지 않고 이미 한 결과를 그대로 돌려준다.
    func testRepeatedRPCNeverCreatesTheFolderTwice() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let operationID = UUID()

        // 서버는 반영했는데 응답이 오지 못한 상황을 만든다.
        await sender.client.dropResponse(for: operationID)
        try await sender.enqueue(
            operationID: operationID,
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)
        await sender.drain(now: 10_000)

        let commits = await server.commitCallCount()
        let replays = await server.replayCount()
        let liveCount = await server.liveFolderCount()
        let revision = await server.revision(of: folderID)
        XCTAssertEqual(commits, 2)
        XCTAssertEqual(replays, 1)
        // 두 번 닿았어도 폴더는 하나여야 한다.
        XCTAssertEqual(liveCount, 1)
        XCTAssertEqual(revision, 1)
        await sender.close()
    }

    /// 이 셋은 시간이 지나서 저절로 풀리는 상태가 아니다. 부모가 없거나, 이름을
    /// 다른 identity가 차지했거나, 트리가 고리를 이룬 것이라 사람이 고쳐야 한다.
    /// 재시도 큐에 남으면 상한 5분마다 영원히 같은 거절을 다시 받는다.
    private static let stableFolderRejectionMessages = [
        "PARENT_FOLDER_NOT_FOUND",
        "FOLDER_NAME_CONFLICT",
        "FOLDER_CYCLE",
    ]

    func testStableFolderRejectionsNeverReturnToTheRetryQueue() async throws {
        for message in Self.stableFolderRejectionMessages {
            let server = FakeFolderServer()
            let sender = try await FolderDeviceFixture(server: server)
            let folderID = UUID()
            let operationID = UUID()
            await server.rejectCommits(for: folderID, message: message)

            try await sender.enqueue(
                operationID: operationID,
                folderID: folderID,
                parentFolderID: nil,
                name: "가 나 다"
            )
            // 시각을 크게 벌린다. 재시도로 분류됐다면 대기가 끝나 다시 잡힌다.
            await sender.drain(now: 10)
            await sender.drain(now: 10_000)
            await sender.drain(now: 1_000_000)

            let status = try await sender.store.operationStatus(
                operationID: operationID
            )
            let attempts = try await sender.store.operationAttempts(
                operationID: operationID
            )
            let calls = await sender.client.folderOperationIDs()
            XCTAssertEqual(status, "conflict", message)
            XCTAssertEqual(attempts, 1, message)
            XCTAssertEqual(
                calls.filter { $0 == operationID }.count,
                1,
                message
            )
            await sender.close()
        }
    }

    /// 폴더 줄은 claim 순서대로 하나씩 비운다. 맨 앞이 영구히 거절당해도 그
    /// 뒤가 함께 서면 안 된다.
    func testOtherFolderWorkKeepsFlowingPastAStableRejection() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let stalledID = UUID()
        let parentID = UUID()
        let childID = UUID()
        await server.rejectCommits(
            for: stalledID,
            message: "FOLDER_NAME_CONFLICT"
        )

        let stalledOperationID = UUID()
        try await sender.enqueue(
            operationID: stalledOperationID,
            folderID: stalledID,
            parentFolderID: nil,
            name: "가"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: parentID,
            parentFolderID: nil,
            name: "나"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: childID,
            parentFolderID: parentID,
            name: "다"
        )
        await sender.drain(now: 10)

        let stalledName = await server.name(of: stalledID)
        let parentName = await server.name(of: parentID)
        let childName = await server.name(of: childID)
        let liveCount = await server.liveFolderCount()
        let stalledStatus = try await sender.store.operationStatus(
            operationID: stalledOperationID
        )
        // 막힌 작업은 재시도 대기가 아니라 세워 둔 상태여야 한다. 재시도
        // 대기로 남으면 다음 배수에서 같은 거절을 다시 받는다.
        XCTAssertEqual(stalledStatus, "conflict")
        XCTAssertNil(stalledName)
        XCTAssertEqual(parentName, "나")
        XCTAssertEqual(childName, "다")
        XCTAssertEqual(liveCount, 2)
        await sender.close()
    }

    /// 세워 둔 작업은 다시 claim되지 않으므로 한 상태에 진단 한 줄만 남는다.
    /// 사용자가 같은 조작을 다시 해도 새 요청이 서버로 나가지 않는다.
    func testRepeatedStableRejectionLeavesASingleStalledState() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let firstAttemptID = UUID()
        let secondAttemptID = UUID()
        await server.rejectCommits(
            for: folderID,
            message: "FOLDER_NAME_CONFLICT"
        )

        try await sender.enqueue(
            operationID: firstAttemptID,
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)
        // 사용자가 같은 조작을 한 번 더 한다.
        try await sender.enqueue(
            operationID: secondAttemptID,
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10_000)
        await sender.drain(now: 1_000_000)

        let first = try await sender.store.operationStatus(
            operationID: firstAttemptID
        )
        let second = try await sender.store.operationStatus(
            operationID: secondAttemptID
        )
        let commits = await server.commitCallCount()
        XCTAssertEqual(first, "conflict")
        XCTAssertEqual(commits, 1)
        // 뒤따르는 작업은 앞의 굳은 작업 뒤에서 기다린다. 이 잠금을 푸는 것은
        // 이번 범위가 아니라 별도 작업이다. 여기서는 세워 둔 상태가 여전히
        // 하나뿐이라는 것만 못 박는다.
        XCTAssertEqual(second, "pending")
        await sender.close()
    }

    // MARK: - 굳은 폴더가 무엇을 잠그는지 재는 시험들
    //
    // 에러 코드 분류로 자동 재시도는 멈췄지만, claim 조건은 'completed'와
    // 'cancelled'만 끝난 것으로 본다. conflict는 retry_wait와 똑같이 "아직
    // 안 끝난 앞 작업"이다. 그래서 분류가 잠금까지 풀어 주지는 않는다는 것을
    // 여기서 재현해 못 박는다.

    /// 사용자가 굳은 폴더를 다시 조작해도 스스로 풀 수 없다. 이름을 바꾸든
    /// 지우든 새 작업은 앞의 굳은 행 뒤에서 claim되지 않는다.
    func testUserCannotClearAStalledFolderByOperatingOnItAgain()
        async throws {
        for followUpIsDeleted in [false, true] {
            let server = FakeFolderServer()
            let sender = try await FolderDeviceFixture(server: server)
            let folderID = UUID()
            let stalledID = UUID()
            let followUpID = UUID()
            await server.rejectCommits(
                for: folderID,
                message: "FOLDER_NAME_CONFLICT"
            )

            try await sender.enqueue(
                operationID: stalledID,
                folderID: folderID,
                parentFolderID: nil,
                name: "가 나 다"
            )
            await sender.drain(now: 10)

            // 사용자가 같은 폴더를 다시 조작한다.
            try await sender.enqueue(
                operationID: followUpID,
                folderID: folderID,
                parentFolderID: nil,
                name: followUpIsDeleted ? "가 나 다" : "라 마 바",
                isDeleted: followUpIsDeleted
            )
            await sender.drain(now: 10_000)
            await sender.drain(now: 1_000_000)

            let stalled = try await sender.store.operationStatus(
                operationID: stalledID
            )
            let followUp = try await sender.store.operationStatus(
                operationID: followUpID
            )
            let commits = await server.commitCallCount()
            let label = followUpIsDeleted ? "삭제" : "이름 변경"
            XCTAssertEqual(stalled, "conflict", label)
            XCTAssertEqual(followUp, "pending", label)
            XCTAssertEqual(commits, 1, "\(label): 새 요청이 나가지 않는다")
            await sender.close()
        }
    }

    /// 앱을 껐다 켜도 풀리지 않는다. 저장소를 열 때 되살리는 목록에 폴더가
    /// 받는 코드가 하나도 없다.
    func testRestartDoesNotClearAStalledFolder() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let stalledID = UUID()
        await server.rejectCommits(
            for: folderID,
            message: "FOLDER_NAME_CONFLICT"
        )

        try await sender.enqueue(
            operationID: stalledID,
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)
        try await sender.restart()
        await sender.drain(now: 1_000_000)

        let stalled = try await sender.store.operationStatus(
            operationID: stalledID
        )
        let commits = await server.commitCallCount()
        XCTAssertEqual(stalled, "conflict")
        XCTAssertEqual(commits, 1)
        await sender.close()
    }

    /// 굳은 자식이 있으면 부모 폴더의 삭제가 claim되지 않는다. 서버는 live
    /// 자식이 남은 폴더의 삭제를 거절하므로 대기 자체는 옳지만, 자식이 영영
    /// 끝나지 않으면 부모도 영영 나가지 못한다.
    func testStalledChildBlocksItsAncestorDeletion() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let parentID = UUID()
        let childID = UUID()
        let parentDeleteID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: parentID,
            parentFolderID: nil,
            name: "부모"
        )
        await sender.drain(now: 10)
        // 자식은 처음부터 거절당해 굳는다.
        await server.rejectCommits(
            for: childID,
            message: "FOLDER_NAME_CONFLICT"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: childID,
            parentFolderID: parentID,
            name: "자식"
        )
        await sender.drain(now: 20)
        // 사용자가 부모를 지운다.
        try await sender.enqueue(
            operationID: parentDeleteID,
            folderID: parentID,
            parentFolderID: nil,
            name: "부모",
            isDeleted: true
        )
        await sender.drain(now: 1_000_000)

        let parentDelete = try await sender.store.operationStatus(
            operationID: parentDeleteID
        )
        let parentIsDeleted = await server.isDeleted(parentID)
        XCTAssertEqual(parentDelete, "pending")
        XCTAssertEqual(parentIsDeleted, false)
        await sender.close()
    }

    /// 나가는 작업이 굳으면 들어오는 변경까지 함께 언다. 굳은 행이
    /// `foldersWithPendingOperations`에 그대로 들어가고, 그 집합이 pull에서
    /// `blockedFolderIDs`로 쓰이기 때문이다.
    func testStalledFolderAlsoFreezesIncomingChangesForThatFolder()
        async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        await server.rejectCommits(
            for: folderID,
            message: "FOLDER_NAME_CONFLICT"
        )

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)

        let blocked = try await sender.store.foldersWithPendingOperations(
            localProjectID: sender.localProjectID
        )
        XCTAssertTrue(
            blocked.contains(folderID),
            "굳은 폴더가 미전송 작업 집합에 그대로 남는다"
        )

        // 다른 기기가 같은 폴더의 이름을 바꿔 보낸 상황을 받는 쪽에서 반영한다.
        let receiver = try FolderReceiverFixture(
            documents: [
                receiverFolder(id: folderID, path: "가 나 다", parent: nil),
            ]
        )
        try receiver.makeDirectory("가 나 다")
        let report = await receiver.applier.applyRemoteFolders(
            localProjectID: receiver.projectID,
            remote: [
                SyncV2RemoteFolder(
                    folderID: folderID,
                    parentFolderID: nil,
                    name: "라 마 바",
                    revision: 2,
                    isDeleted: false,
                    updatedAt: Date(timeIntervalSince1970: 200)
                ),
            ],
            blockedFolderIDs: blocked.map(DocumentID.init(rawValue:))
                .reduce(into: Set<DocumentID>()) { $0.insert($1) }
        )

        XCTAssertTrue(report.movedFolderIDs.isEmpty)
        XCTAssertEqual(report.rejectedNames.count, 1)
        XCTAssertEqual(
            report.rejectedNames.first?.reason,
            "pendingLocalOperation"
        )
        XCTAssertTrue(receiver.exists("가 나 다"))
        XCTAssertFalse(receiver.exists("라 마 바"))
        await sender.close()
    }

    /// 두 기기가 같은 폴더의 이름을 앞뒤로 바꾸면 늦은 쪽은 REVISION_CONFLICT를
    /// 받는다. 폴더에는 합칠 본문이 없으므로 기준선만 서버 값으로 옮겨 그대로
    /// 다시 보낸다. 늦게 커밋하는 쪽이 이기고, 진 쪽은 pull로 따라간다.
    /// 되감기에는 상한이 있어야 한다.
    ///
    /// 폴더는 늦게 커밋하는 쪽이 이기므로, 두 기기가 모두 이름 변경을 들고
    /// 있으면 서로 되감기를 주고받는다. 지연만 있고 횟수 상한이 없으면 멈출
    /// 근거가 사용자가 이름을 그만 바꾸는 것뿐인데 그것은 장치가 아니다.
    ///
    /// 실기기 검증(검증06)에서 8회를 손으로 채우는 것은 비현실적이라
    /// 상한 동작은 여기서만 확인된다.
    func testEndlessRevisionConflictStopsAtTheRebaseCeiling() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let renameID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)

        // 다른 기기가 멈추지 않는다. 되감아도 서버가 또 앞서 있다.
        await server.keepAdvancing(folderID: folderID)
        try await sender.enqueue(
            operationID: renameID,
            folderID: folderID,
            parentFolderID: nil,
            name: "이 기기 이름"
        )

        var status: String?
        var finalRebaseCount = 0
        for round in 1 ... 8 {
            await sender.drain(now: TimeInterval(20 + round * 10))
            let lineage = try await sender.store.queuedOperations()
                .filter { $0.automaticRebaseCount > 0 }
                .max { $0.automaticRebaseCount < $1.automaticRebaseCount }
            status = lineage?.status.rawValue
            finalRebaseCount = lineage?.automaticRebaseCount ?? 0
            if status == "conflict" { break }
        }

        let stalled = await sender.stalledFolderChanges()
        await sender.close()

        // 영원히 되감지 않고 세운다.
        XCTAssertEqual(status, "conflict")
        XCTAssertEqual(finalRebaseCount, 8)
        // 세웠으면 화면이 말할 수 있어야 한다. 조용히 굳으면 사용자는 모른다.
        XCTAssertTrue(
            stalled.contains {
                $0.name == "이 기기 이름" && $0.errorCode == "AUTO_REBASE_LIMIT"
            },
            "상한에 닿은 폴더는 화면이 말할 수 있어야 한다: \(stalled)"
        )
    }

    func testConcurrentRenameFromTwoDevicesLetsTheLaterOneWin() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        let renameID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)

        // 다른 기기가 먼저 이름을 바꾼다. 이 기기는 아직 모른다.
        await server.applyOtherDeviceRename(
            folderID: folderID,
            name: "다른 기기 이름"
        )
        try await sender.enqueue(
            operationID: renameID,
            folderID: folderID,
            parentFolderID: nil,
            name: "이 기기 이름"
        )
        await sender.drain(now: 20)

        let originalStatus = try await sender.store.operationStatus(
            operationID: renameID
        )
        let operations = try await sender.store.queuedOperations()
        let successor = try XCTUnwrap(
            operations.first { $0.supersedesOperationID == renameID }
        )
        let storedName = await server.name(of: folderID)
        let revision = await server.revision(of: folderID)
        XCTAssertEqual(originalStatus, "cancelled")
        XCTAssertEqual(successor.status, .completed)
        XCTAssertEqual(successor.automaticRebaseCount, 1)
        XCTAssertEqual(storedName, "이 기기 이름")
        XCTAssertEqual(revision, 3)
        await sender.close()
    }

    /// 기준선을 다시 잡아 지나간 폴더는 잠기지 않는다. 이후 작업도, 조상 폴더의
    /// 삭제도 그대로 흐른다.
    func testRebasedFolderLocksNeitherItsOwnWorkNorItsAncestorDeletion()
        async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let parentID = UUID()
        let childID = UUID()
        let childDeleteID = UUID()
        let parentDeleteID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: parentID,
            parentFolderID: nil,
            name: "부모"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: childID,
            parentFolderID: parentID,
            name: "자식"
        )
        await sender.drain(now: 10)

        // 다른 기기가 자식 이름을 먼저 바꾼다.
        await server.applyOtherDeviceRename(
            folderID: childID,
            name: "다른 기기 자식"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: childID,
            parentFolderID: parentID,
            name: "이 기기 자식"
        )
        await sender.drain(now: 20)

        // 그 뒤 사용자가 자식과 부모를 차례로 지운다.
        try await sender.enqueue(
            operationID: childDeleteID,
            folderID: childID,
            parentFolderID: parentID,
            name: "이 기기 자식",
            isDeleted: true
        )
        try await sender.enqueue(
            operationID: parentDeleteID,
            folderID: parentID,
            parentFolderID: nil,
            name: "부모",
            isDeleted: true
        )
        await sender.drain(now: 30)

        let childDelete = try await sender.store.operationStatus(
            operationID: childDeleteID
        )
        let parentDelete = try await sender.store.operationStatus(
            operationID: parentDeleteID
        )
        let childDeleted = await server.isDeleted(childID)
        let parentDeleted = await server.isDeleted(parentID)
        XCTAssertEqual(childDelete, "completed")
        XCTAssertEqual(parentDelete, "completed")
        XCTAssertEqual(childDeleted, true)
        XCTAssertEqual(parentDeleted, true)
        await sender.close()
    }

    /// 나가는 작업이 지나갔으므로 들어오는 변경도 얼지 않는다.
    func testRebasedFolderNoLongerFreezesIncomingChanges() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)
        await server.applyOtherDeviceRename(
            folderID: folderID,
            name: "다른 기기 이름"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "이 기기 이름"
        )
        await sender.drain(now: 20)

        let blocked = try await sender.store.foldersWithPendingOperations(
            localProjectID: sender.localProjectID
        )
        XCTAssertFalse(
            blocked.contains(folderID),
            "지나간 폴더는 미전송 작업 집합에 남지 않는다"
        )

        let receiver = try FolderReceiverFixture(
            documents: [
                receiverFolder(id: folderID, path: "가 나 다", parent: nil),
            ]
        )
        try receiver.makeDirectory("가 나 다")
        let report = await receiver.applier.applyRemoteFolders(
            localProjectID: receiver.projectID,
            remote: await server.folderList(),
            blockedFolderIDs: blocked.map(DocumentID.init(rawValue:))
                .reduce(into: Set<DocumentID>()) { $0.insert($1) }
        )

        XCTAssertEqual(report.rejectedNames.count, 0)
        XCTAssertEqual(report.movedFolderIDs.count, 1)
        XCTAssertTrue(receiver.exists("이 기기 이름"))
        await sender.close()
    }

    /// 기준선을 다시 잡는 것이 폴더 줄의 순서 보장을 건드리면 안 된다. 부모를
    /// 다시 잡느라 한 바퀴 더 도는 동안에도 자식이 부모를 앞지르지 않는다.
    func testRebaseKeepsParentBeforeChildOrdering() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let parentID = UUID()
        let childID = UUID()
        let parentRenameID = UUID()
        let childCreateID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: parentID,
            parentFolderID: nil,
            name: "부모"
        )
        await sender.drain(now: 10)
        // 다른 기기가 부모 이름을 먼저 바꾼다.
        await server.applyOtherDeviceRename(
            folderID: parentID,
            name: "다른 기기 부모"
        )

        // 부모 이름 변경과 그 아래 자식 생성을 같은 줄에 넣는다.
        try await sender.enqueue(
            operationID: parentRenameID,
            folderID: parentID,
            parentFolderID: nil,
            name: "이 기기 부모"
        )
        try await sender.enqueue(
            operationID: childCreateID,
            folderID: childID,
            parentFolderID: parentID,
            name: "자식"
        )
        await sender.drain(now: 20)

        let calls = await sender.client.folderOperationIDs()
        guard let renameIndex = calls.lastIndex(of: parentRenameID),
              let childIndex = calls.lastIndex(of: childCreateID)
        else {
            return XCTFail("두 작업 모두 서버에 닿아야 한다: \(calls)")
        }
        let parentName = await server.name(of: parentID)
        let childName = await server.name(of: childID)
        XCTAssertLessThan(
            renameIndex,
            childIndex,
            "자식이 부모를 앞지르면 안 된다: \(calls)"
        )
        XCTAssertEqual(parentName, "이 기기 부모")
        XCTAssertEqual(childName, "자식")
        await sender.close()
    }

    /// 화면이 읽어 갈 목록에 굳은 폴더가 실제로 담기는지 본다. 대기열과 화면
    /// 사이가 끊겨 있으면 문구를 아무리 고쳐도 드러나지 않는다.
    func testStalledFolderChangeIsReadableForTheScreen() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()
        await server.rejectCommits(
            for: folderID,
            message: "FOLDER_NAME_CONFLICT"
        )

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "설정집"
        )
        await sender.drain(now: 10)
        let stalled = try await sender.store.stalledFolderChanges(
            localProjectID: sender.localProjectID
        )
        XCTAssertEqual(stalled.count, 1)
        XCTAssertEqual(stalled.first?.name, "설정집")
        XCTAssertEqual(stalled.first?.errorCode, "FOLDER_NAME_CONFLICT")

        // 화면은 dispatcher를 거쳐 읽는다. 그 경로도 같은 답이어야 한다.
        let throughDispatcher = await sender.stalledFolderChanges()
        XCTAssertEqual(throughDispatcher, stalled)
        await sender.close()
    }

    /// 기준선을 다시 잡아 지나간 폴더는 화면에 올릴 것이 없다.
    func testRebasedFolderLeavesNothingForTheScreenToReport() async throws {
        let server = FakeFolderServer()
        let sender = try await FolderDeviceFixture(server: server)
        let folderID = UUID()

        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "가 나 다"
        )
        await sender.drain(now: 10)
        await server.applyOtherDeviceRename(
            folderID: folderID,
            name: "다른 기기 이름"
        )
        try await sender.enqueue(
            operationID: UUID(),
            folderID: folderID,
            parentFolderID: nil,
            name: "이 기기 이름"
        )
        await sender.drain(now: 20)

        let stalled = try await sender.store.stalledFolderChanges(
            localProjectID: sender.localProjectID
        )
        XCTAssertTrue(stalled.isEmpty)
        await sender.close()
    }

    private func receiverFolder(
        id: UUID,
        path: String,
        parent: UUID?
    ) -> DocumentNode {
        DocumentNode(
            id: DocumentID(rawValue: id),
            projectID: receiverProjectID,
            kind: .folder,
            parentID: parent.map(DocumentID.init(rawValue:)),
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }

    private let receiverProjectID = ProjectID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!
    )

    private final class FolderReceiverFixture {
        let projectID = ProjectID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-0000000000e1"
            )!
        )
        let root: URL
        let repository: EndToEndRepositoryStub
        let applier: SyncV2RemoteFolderApplier

        init(documents: [DocumentNode]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "WriterPad-folder-e2e-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            repository = EndToEndRepositoryStub(documents: documents)
            applier = SyncV2RemoteFolderApplier(
                documentRepository: repository,
                workspaceLocator: EndToEndWorkspaceLocator(root: root)
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func makeDirectory(_ path: String) throws {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path),
                withIntermediateDirectories: true
            )
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path
            )
        }
    }
}

/// commit_folder의 성질만 흉내 낸다. 같은 operation_id는 다시 반영하지 않고
/// 이미 낸 결과를 돌려주며, 기준선이 어긋나면 거절한다.
private actor FakeFolderServer {
    private struct Row {
        var parentFolderID: UUID?
        var name: String
        var revision: Int64
        var isDeleted: Bool
    }

    private var rows: [UUID: Row] = [:]
    private var applied: [UUID: SyncV2CommitFolderResult] = [:]
    private var stableRejections: [UUID: String] = [:]
    /// 거절할 때마다 revision을 한 칸 더 올린다. 다른 기기가 이름을 계속
    /// 바꾸고 있는 상황이다 — 되감아도 또 뒤처진다.
    private var keepsAdvancing: Set<UUID> = []
    private var commits = 0
    private var replays = 0

    /// 사람이 트리나 이름을 고치기 전에는 몇 번을 보내도 같은 답이 오는 상태를
    /// 만든다. 배포된 commit_folder는 이 문구들을 errcode P0001로 raise한다.
    func keepAdvancing(folderID: UUID) { keepsAdvancing.insert(folderID) }

    func rejectCommits(for folderID: UUID, message: String) {
        stableRejections[folderID] = message
    }

    func commitFolder(
        _ parameters: SyncV2CommitFolderParameters
    ) throws -> SyncV2CommitFolderResult {
        commits += 1
        if let previous = applied[parameters.operationID] {
            replays += 1
            return SyncV2CommitFolderResult(
                status: .replayed,
                folderID: previous.folderID,
                versionID: previous.versionID,
                operationID: previous.operationID,
                operationKind: previous.operationKind,
                serverRevision: previous.serverRevision,
                parentFolderID: previous.parentFolderID,
                name: previous.name,
                isDeleted: previous.isDeleted,
                committedAt: previous.committedAt
            )
        }
        // 서버는 트리를 건드리기 전에 raise한다. 실패한 요청은 아무것도
        // 바꾸지 않으므로 다음 요청도 같은 답을 받는다.
        if let message = stableRejections[parameters.folderID] {
            throw SyncV2Client.classify(
                .postgrest(
                    message: message,
                    postgresCode: "P0001",
                    detail: nil
                )
            )
        }
        // 되감기는 서버를 다시 읽어 따라잡는다. 그 사이에 또 바뀌어야
        // 영원히 뒤처진다. 그래서 읽은 뒤가 아니라 매 커밋 직전에 올린다.
        // 읽기와 쓰기를 한 식에 겹치면 배타적 접근 위반으로 죽는다.
        if keepsAdvancing.contains(parameters.folderID),
           let advanced = rows[parameters.folderID]?.revision {
            rows[parameters.folderID]?.revision = advanced + 1
        }
        let current = rows[parameters.folderID]?.revision ?? 0
        guard current == parameters.baseServerRevision else {
            // 배포된 commit_folder는 거절하면서 현재 revision과 서버가 들고
            // 있는 이름·부모를 detail에 함께 싣는다. 그 형태 그대로 흉내낸다.
            let row = rows[parameters.folderID]
            let detail: [String: Any] = [
                "current_revision": current,
                "parent_folder_id":
                    row?.parentFolderID?.uuidString.lowercased() as Any,
                "name": row?.name as Any,
                "is_deleted": row?.isDeleted ?? false,
            ]
            let encoded = try JSONSerialization.data(
                withJSONObject: detail.compactMapValues { $0 }
            )
            throw SyncV2Client.classify(
                .postgrest(
                    message: "REVISION_CONFLICT",
                    postgresCode: "P0001",
                    detail: String(decoding: encoded, as: UTF8.self)
                )
            )
        }
        let revision = parameters.baseServerRevision + 1
        rows[parameters.folderID] = Row(
            parentFolderID: parameters.parentFolderID,
            name: parameters.name,
            revision: revision,
            isDeleted: parameters.isDeleted
        )
        let result = SyncV2CommitFolderResult(
            status: .committed,
            folderID: parameters.folderID,
            versionID: UUID(),
            operationID: parameters.operationID,
            operationKind: parameters.baseServerRevision == 0
                ? .create
                : .update,
            serverRevision: revision,
            parentFolderID: parameters.parentFolderID,
            name: parameters.name,
            isDeleted: parameters.isDeleted,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
        applied[parameters.operationID] = result
        return result
    }

    func folderList() -> [SyncV2RemoteFolder] {
        rows.map { folderID, row in
            SyncV2RemoteFolder(
                folderID: folderID,
                parentFolderID: row.parentFolderID,
                name: row.name,
                revision: row.revision,
                isDeleted: row.isDeleted,
                updatedAt: Date(timeIntervalSince1970: 200)
            )
        }
    }

    func liveFolderCount() -> Int {
        rows.values.filter { !$0.isDeleted }.count
    }

    func name(of folderID: UUID) -> String? { rows[folderID]?.name }
    func isDeleted(_ folderID: UUID) -> Bool? { rows[folderID]?.isDeleted }

    /// 다른 기기가 같은 폴더를 먼저 바꾼 상황이다. revision이 올라가므로 이
    /// 기기가 들고 있던 기준선은 낡은 값이 된다.
    func applyOtherDeviceRename(folderID: UUID, name: String) {
        guard var row = rows[folderID] else { return }
        row.name = name
        row.revision += 1
        rows[folderID] = row
    }
    func revision(of folderID: UUID) -> Int64? { rows[folderID]?.revision }
    func commitCallCount() -> Int { commits }
    func replayCount() -> Int { replays }
}

private actor EndToEndFolderClient: SyncV2CommitClienting {
    private let server: FakeFolderServer
    private var isOffline = false
    private var droppedResponseOperationIDs: Set<UUID> = []
    private var seen: [UUID] = []

    init(server: FakeFolderServer) {
        self.server = server
    }

    func setOffline(_ value: Bool) { isOffline = value }

    /// 서버는 반영했는데 응답이 오지 못한 상황이다. 한 번만 삼킨다.
    func dropResponse(for operationID: UUID) {
        droppedResponseOperationIDs.insert(operationID)
    }

    func folderOperationIDs() -> [UUID] { seen }

    func commitDocument(
        _ parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult {
        throw SyncV2ClientError.remote(
            code: .invalidArgument,
            detail: "This fixture only serves folders."
        )
    }

    func commitFolder(
        _ parameters: SyncV2CommitFolderParameters
    ) async throws -> SyncV2CommitFolderResult {
        seen.append(parameters.operationID)
        guard !isOffline else {
            throw SyncV2ClientError.networkUnavailable
        }
        let result = try await server.commitFolder(parameters)
        if droppedResponseOperationIDs.contains(parameters.operationID) {
            droppedResponseOperationIDs.remove(parameters.operationID)
            throw SyncV2ClientError.networkUnavailable
        }
        return result
    }
}

private final class FolderDeviceFixture {
    let localProjectID = ProjectID(rawValue: UUID())
    let serverProjectID = UUID()
    let ownerSubject = UUID()
    let deviceID = UUID()
    let client: EndToEndFolderClient
    private(set) var store: SyncV2Store
    private let server: FakeFolderServer
    private let directory: URL
    private let url: URL
    private let binding: ProjectSyncBinding

    init(server: FakeFolderServer) async throws {
        self.server = server
        client = EndToEndFolderClient(server: server)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-folder-device-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("sync-v2.sqlite3")
        switch await SyncV2Store.open(at: url) {
        case .available(let opened):
            store = opened
        case .unavailable(let diagnostic):
            throw EndToEndFixtureError.openFailed(diagnostic)
        }
        binding = .connected(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: .newServerProject,
            projectName: "폴더 관통 fixture",
            ownerSubject: ownerSubject
        )
        try await store.save(binding)
    }

    func enqueue(
        operationID: UUID,
        folderID: UUID,
        parentFolderID: UUID?,
        name: String,
        isDeleted: Bool = false
    ) async throws {
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .structureChange,
                mutations: [
                    .folder(
                        SyncV2FolderMutation(
                            operationID: operationID,
                            folderID: folderID,
                            parentFolderID: parentFolderID,
                            deviceID: deviceID,
                            name: name,
                            isDeleted: isDeleted
                        )
                    )
                ]
            )
        )
    }

    /// 제품은 `AppEnvironment`에서 이것을 넘긴다. 넘기지 않으면 폴더
    /// revision 충돌이 되감기 없이 그대로 굳으므로 시험도 같이 넘긴다.
    private func makeRebaser() -> SyncV2AutomaticRebaser {
        SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: EndToEndFolderSnapshotClient(server: server)
        )
    }

    func drain(now seconds: TimeInterval) async {
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            automaticRebaser: makeRebaser()
        )
        // 폴더마다 줄이 따로라 한 바퀴로는 사슬이 다 풀리지 않는다.
        for _ in 0 ..< 4 {
            await dispatcher.dispatchReadyOperations(
                now: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    /// 화면이 실제로 쓰는 경로다. dispatcher가 들고 있는 저장소를 거친다.
    func stalledFolderChanges() async -> [SyncV2StalledFolderChange] {
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            automaticRebaser: makeRebaser()
        )
        return await dispatcher.stalledFolderChanges(
            localProjectID: localProjectID
        )
    }

    func setOffline(_ value: Bool) async {
        await client.setOffline(value)
    }

    func restart() async throws {
        await store.close()
        switch await SyncV2Store.open(at: url) {
        case .available(let reopened):
            store = reopened
        case .unavailable(let diagnostic):
            throw EndToEndFixtureError.openFailed(diagnostic)
        }
    }

    func close() async {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum EndToEndFixtureError: Error {
    case openFailed(SyncV2StoreDiagnostic)
}

private actor EndToEndRepositoryStub: DocumentRepository {
    private var storage: [DocumentNode]

    init(documents: [DocumentNode]) {
        storage = documents
    }

    func documents(in projectID: ProjectID) throws -> [DocumentNode] {
        storage.filter { $0.projectID == projectID }
    }

    func document(id: DocumentID) throws -> DocumentNode? {
        storage.first { $0.id == id }
    }

    func save(_ document: DocumentNode) throws {
        if let index = storage.firstIndex(where: { $0.id == document.id }) {
            storage[index] = document
        } else {
            storage.append(document)
        }
    }

    func removeMetadata(id: DocumentID) throws {
        storage.removeAll { $0.id == id }
    }
}

private struct EndToEndWorkspaceLocator: ProjectWorkspaceLocating {
    let root: URL

    func workspaceRoot(for projectID: ProjectID) throws -> URL {
        _ = projectID
        return root
    }
}

/// 되감기가 서버의 현재 폴더를 다시 읽을 수 있게 하는 어댑터다.
/// 이 fixture는 폴더만 다루므로 문서 목록은 비운다.
private struct EndToEndFolderSnapshotClient: SyncV2SnapshotClienting {
    let server: FakeFolderServer

    func fetchDocuments(
        projectID: UUID
    ) async throws -> [SyncV2RemoteDocumentSnapshot] { [] }

    func fetchFolders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteFolder] {
        await server.folderList()
    }
}
