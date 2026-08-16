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
    private var commits = 0
    private var replays = 0

    /// 사람이 트리나 이름을 고치기 전에는 몇 번을 보내도 같은 답이 오는 상태를
    /// 만든다. 배포된 commit_folder는 이 문구들을 errcode P0001로 raise한다.
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
        let current = rows[parameters.folderID]?.revision ?? 0
        guard current == parameters.baseServerRevision else {
            throw SyncV2ClientError.remote(
                code: .revisionConflict,
                detail: nil
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
    private let directory: URL
    private let url: URL
    private let binding: ProjectSyncBinding

    init(server: FakeFolderServer) async throws {
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

    func drain(now seconds: TimeInterval) async {
        let dispatcher = SyncV2Dispatcher(store: store, client: client)
        // 폴더마다 줄이 따로라 한 바퀴로는 사슬이 다 풀리지 않는다.
        for _ in 0 ..< 4 {
            await dispatcher.dispatchReadyOperations(
                now: Date(timeIntervalSince1970: seconds)
            )
        }
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
