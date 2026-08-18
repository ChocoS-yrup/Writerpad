import Foundation
import XCTest
@testable import WriterPad

/// 계약 패키지의 상태 전이 벡터를 실제로 돌린다.
///
/// 지금은 벡터 11 하나만 붙인다. 12개를 한꺼번에 붙이면 하네스가 틀린 건지
/// 구현이 틀린 건지 가릴 수 없다.
final class SyncV2TransitionVectorTests: XCTestCase {
    // MARK: - 벡터 읽기

    /// 벡터 12개가 모두 지금의 모델로 읽혀야 한다. 계약이 개정돼 모양이 바뀌면
    /// 여기서 먼저 걸린다.
    func testAllTransitionVectorsDecode() throws {
        let names = try SyncV2TransitionVector.allVectorNames()
        XCTAssertEqual(names.count, 12, "전이 벡터는 12개다: \(names)")

        var legacyProtocolVectors: [String] = []
        for name in names {
            let vector = try SyncV2TransitionVector.load(name)
            XCTAssertEqual(vector.contractVersion, "0.2.0", name)
            XCTAssertFalse(vector.orderedActions.isEmpty, name)
            XCTAssertFalse(vector.expectedQueueStates.isEmpty, name)
            XCTAssertFalse(vector.initialClientStates.isEmpty, name)
            if vector.minimumProtocolVersion < SyncV2Contract.syncProtocolVersion {
                legacyProtocolVectors.append(name)
            }
        }

        // 구형 클라이언트가 주인공인 두 벡터만 protocol 3 아래에서 돈다.
        // 나머지는 계약 경로다.
        XCTAssertEqual(
            legacyProtocolVectors,
            ["03-legacy-first-connect", "10-legacy-structure-write-to-id-based"]
        )
    }

    /// 아이패드가 등장하는 벡터가 어느 것인지 못 박아 둔다. 남은 벡터를 붙일
    /// 때 무엇이 우리 몫인지 여기서 본다.
    func testVectorsInvolvingIPad() throws {
        var withIPad: [String] = []
        for name in try SyncV2TransitionVector.allVectorNames() {
            let vector = try SyncV2TransitionVector.load(name)
            if vector.initialClientStates.contains(where: { $0.platform == "ipad" }) {
                withIPad.append(name)
            }
        }
        XCTAssertEqual(withIPad, [
            "01-empty-folder-create",
            "03-legacy-first-connect",
            "04-rapid-six-renames",
            "05-revision-conflict-rebase",
            "07-restart-queue-recovery",
            "08-rename-delete-conflict",
            "11-cancellation-event-derivation",
        ])
    }

    /// 벡터가 요구하는 능력을 우리가 다 선언하고 있어야 한다. 하나라도 모자라면
    /// 그 벡터는 애초에 우리 이야기가 아니다.
    func testVectorClientCapabilitiesAreDeclared() throws {
        let vector = try SyncV2TransitionVector.load("11-cancellation-event-derivation")
        let client = try XCTUnwrap(vector.initialClientStates.first)

        XCTAssertEqual(client.protocolVersion, SyncV2Contract.syncProtocolVersion)
        XCTAssertTrue(
            Set(client.capabilities).isSubset(of: Set(SyncV2Contract.clientCapabilities)),
            "벡터가 요구하는 능력: \(client.capabilities)"
        )
    }

    // MARK: - TV-011

    private func runVector11() async throws -> SyncV2VectorRunner {
        let vector = try SyncV2TransitionVector.load("11-cancellation-event-derivation")
        let runner = try SyncV2VectorRunner.withReferenceQueue(vector)
        try await runner.run()
        return runner
    }

    /// 벡터가 정한 기계 판정 부분을 전부 통과해야 한다.
    ///
    /// 첫 작업은 취소되고 시도는 0회, 둘째 작업은 완료되고 시도는 1회,
    /// 그리고 완료된 작업에 건 취소는 `OPERATION_TERMINAL`로 거절돼야 한다.
    func testVector11MechanicalExpectations() async throws {
        let runner = try await runVector11()
        await runner.assertMechanicalExpectations()
    }

    /// 같은 사건 식별자로 다시 취소해도, 새 식별자로 다시 취소해도 취소 사건은
    /// 하나뿐이어야 한다. 벡터의 "one cancellation event exists for the first
    /// operation"을 손으로 옮긴 판정이다.
    func testVector11AppendsExactlyOneCancellationEvent() async throws {
        let runner = try await runVector11()
        let firstOperation = UUID(uuidString: "20000000-0000-4000-8000-000000000081")!

        let cancellations = try await runner.queue.events(of: firstOperation)
            .filter { $0.type == .cancelRequested }
        XCTAssertEqual(cancellations.count, 1)
    }

    /// 취소된 작업의 상태는 저장된 값이 아니라 사건 기록에서 다시 계산해도
    /// 같아야 한다. 벡터의 "state is reproducible from events"다.
    func testVector11StateIsReproducibleFromEvents() async throws {
        let runner = try await runVector11()
        let firstOperation = UUID(uuidString: "20000000-0000-4000-8000-000000000081")!

        let events = try await runner.queue.events(of: firstOperation)
        XCTAssertEqual(
            try SyncV2OperationStateDerivation.state(from: events),
            .cancelled
        )
        XCTAssertEqual(events.map(\.type), [.enqueued, .cancelRequested])
    }

    /// 완료된 작업은 취소 요청을 받아도 완료인 채로 남아야 한다. 여기서 상태가
    /// 흔들리면 이미 서버에 올라간 글이 안 올라간 것처럼 보인다.
    func testVector11CompletedOperationStaysCompleted() async throws {
        let runner = try await runVector11()
        let secondOperation = UUID(uuidString: "20000000-0000-4000-8000-000000000082")!

        let secondState = try await runner.queue.state(of: secondOperation)
        let secondEvents = try await runner.queue.events(of: secondOperation)
        XCTAssertEqual(secondState, .completed)
        XCTAssertFalse(secondEvents.contains { $0.type == .cancelRequested })
    }

    /// 서버 쪽 기대다. 취소된 쪽은 리비전이 그대로고, 커밋된 쪽만 하나 오른다.
    /// 벡터의 entity_assertions 두 문장을 손으로 옮긴 판정이다.
    func testVector11ServerRevisions() async throws {
        let runner = try await runVector11()
        let queue = try XCTUnwrap(runner.queue as? SyncV2ReferenceQueue)

        let firstDocument = UUID(uuidString: "40000000-0000-4000-8000-000000000111")!
        let secondDocument = UUID(uuidString: "40000000-0000-4000-8000-000000000112")!
        XCTAssertEqual(queue.entityRevisions[firstDocument], 1, "취소된 문서는 그대로다")
        XCTAssertEqual(queue.entityRevisions[secondDocument], 2, "커밋된 문서만 오른다")
    }

    /// 작품 모드와 이관 세대는 이 벡터에서 움직이지 않는다. 클라이언트가 임의로
    /// 승격시키지 않는다는 뜻이다.
    func testVector11DoesNotPromoteProject() throws {
        let vector = try SyncV2TransitionVector.load("11-cancellation-event-derivation")
        XCTAssertEqual(vector.initialServerState.projectSyncMode, .legacy)
        XCTAssertEqual(vector.initialServerState.migrationEpoch, 0)
        XCTAssertEqual(vector.expectedServerState.projectSyncMode, .legacy)
        XCTAssertEqual(vector.expectedServerState.migrationEpoch, 0)
    }

    // MARK: - 운영 저장소로 돌리기

    /// 같은 벡터를 실제로 사용자 글을 나르는 저장소에 그대로 먹인다.
    ///
    /// 참조 구현이 통과하는 것과 저장소가 통과하는 것은 다른 이야기다. 이것이
    /// 통과해야 계약대로 움직인다고 말할 수 있다.
    func testVector11AgainstProductionStore() async throws {
        let vector = try SyncV2TransitionVector.load("11-cancellation-event-derivation")
        let client = try SyncV2VectorRunner.primaryClient(of: vector)
        XCTAssertEqual(client.queue.count, 2)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-TV011-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-v2.sqlite3")

        guard case let .available(store) = await SyncV2Store.open(at: url) else {
            return XCTFail("저장소를 열지 못했다")
        }
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let ownerSubject = UUID()
        let deviceID = UUID()
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .newServerProject,
                projectName: "TV-011",
                ownerSubject: ownerSubject
            )
        )

        // 벡터가 부르는 이름과 저장소가 실제로 만든 작업을 잇는다. 벡터의
        // 대기열을 표에 직접 밀어 넣지 않고 정식 경로로 만들어야, 이 시험이
        // 저장소가 실제로 하는 일을 확인한다.
        var mapping: [UUID: UUID] = [:]
        for (index, item) in client.queue.enumerated() {
            let realOperationID = UUID()
            mapping[item.operationID] = realOperationID
            _ = try await store.enqueue(
                SyncV2EnqueueBatch(
                    batchID: UUID(),
                    localProjectID: localProjectID,
                    localTransactionID: UUID(),
                    kind: .documentSave,
                    mutations: [
                        .document(
                            SyncV2DocumentMutation(
                                operationID: realOperationID,
                                documentID: item.entityID,
                                deviceID: deviceID,
                                localSaveGeneration: 1,
                                kind: .documentCommit,
                                localPath: "/fixture/원고/\(index).txt",
                                relativePath: "원고/\(index).txt",
                                content: "본문 \(index)",
                                isDeleted: false
                            )
                        )
                    ]
                )
            )
        }

        let queue = SyncV2StoreVectorQueue(
            store: store,
            url: url,
            operationIDs: mapping,
            dispatch: Self.storeDispatch
        )

        let runner = SyncV2VectorRunner(vector: vector, queue: queue)
        try await runner.run()
        let mismatches = await runner.mechanicalMismatches()

        let firstEvents = try await queue.events(
            of: UUID(uuidString: "20000000-0000-4000-8000-000000000081")!
        )
        let divergences = try await queue.currentStore.operationStateDivergences()
        await queue.close()

        XCTAssertEqual(
            mismatches,
            [],
            "저장소가 벡터와 어긋났다:\n" + mismatches.joined(separator: "\n")
        )
        // 같은 식별자로도, 새 식별자로도 다시 취소했지만 사건은 하나뿐이어야 한다.
        XCTAssertEqual(
            firstEvents.filter { $0.type == .cancelRequested }.count,
            1
        )
        XCTAssertEqual(divergences, [], "기록과 칸이 끝까지 붙어 있어야 한다")
    }

    // MARK: - TV-007 재시작 복구

    /// 보내는 도중 앱이 꺼졌다가 다시 열렸을 때, 같은 작업이 신원을 지킨 채
    /// 다시 발송되는지 본다.
    ///
    /// 끊긴 시도도 실제로 있었던 일이므로 시도 횟수에서 빼지 않는다. 벡터가
    /// 기대하는 최종 시도 횟수가 2인 이유다.
    func testVector07AgainstProductionStore() async throws {
        let vector = try SyncV2TransitionVector.load("07-restart-queue-recovery")
        let (queue, mapping) = try await makeStoreQueue(for: vector, name: "TV007")
        let vectorOperationID = try XCTUnwrap(mapping.keys.first)

        let runner = SyncV2VectorRunner(vector: vector, queue: queue)
        try await runner.run()
        let mismatches = await runner.mechanicalMismatches()
        let events = try await queue.events(of: vectorOperationID)
        let divergences = try await queue.currentStore.operationStateDivergences()
        await queue.close()

        XCTAssertEqual(
            mismatches,
            [],
            "저장소가 벡터와 어긋났다:\n" + mismatches.joined(separator: "\n")
        )
        // 집어들었다가 꺼졌고, 다시 열며 대기로 돌아왔고, 다시 보내 끝났다.
        XCTAssertEqual(
            events.map(\.type),
            [.enqueued, .dispatchStarted, .enqueued, .dispatchStarted, .committed]
        )
        XCTAssertEqual(divergences, [])
    }

    /// 재시작해도 작업의 신원은 그대로여야 한다. 새 신원을 만들면 서버가 같은
    /// 편집을 두 번 받는다.
    func testVector07PreservesOperationIdentityAcrossRestart() async throws {
        let vector = try SyncV2TransitionVector.load("07-restart-queue-recovery")
        let (queue, mapping) = try await makeStoreQueue(for: vector, name: "TV007-identity")
        let vectorOperationID = try XCTUnwrap(mapping.keys.first)
        let realOperationID = try XCTUnwrap(mapping[vectorOperationID])

        let runner = SyncV2VectorRunner(vector: vector, queue: queue)
        try await runner.run()
        let store = queue.currentStore
        let status = try await store.operationStatus(operationID: realOperationID)
        let attempts = try await store.operationAttempts(operationID: realOperationID)
        await queue.close()

        XCTAssertEqual(status, "completed")
        XCTAssertEqual(attempts, 2, "끊긴 시도도 있었던 일이다")
    }

    // MARK: - 저장소 고정물

    /// 벡터의 대기열을 저장소의 정식 경로로 만들고 어댑터를 돌려준다.
    private func makeStoreQueue(
        for vector: SyncV2TransitionVector,
        name: String
    ) async throws -> (SyncV2StoreVectorQueue, [UUID: UUID]) {
        let client = try SyncV2VectorRunner.primaryClient(of: vector)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync-v2.sqlite3")

        guard case let .available(store) = await SyncV2Store.open(at: url) else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "저장소를 열지 못했다")
        }
        let localProjectID = ProjectID(rawValue: UUID())
        let deviceID = UUID()
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: UUID(),
                kind: .newServerProject,
                projectName: name,
                ownerSubject: UUID()
            )
        )

        var mapping: [UUID: UUID] = [:]
        for (index, item) in client.queue.enumerated() {
            let realOperationID = UUID()
            mapping[item.operationID] = realOperationID
            _ = try await store.enqueue(
                SyncV2EnqueueBatch(
                    batchID: UUID(),
                    localProjectID: localProjectID,
                    localTransactionID: UUID(),
                    kind: .documentSave,
                    mutations: [
                        .document(
                            SyncV2DocumentMutation(
                                operationID: realOperationID,
                                documentID: item.entityID,
                                deviceID: deviceID,
                                localSaveGeneration: 1,
                                kind: .documentCommit,
                                localPath: "/fixture/원고/\(index).txt",
                                relativePath: "원고/\(index).txt",
                                content: "본문 \(index)",
                                isDeleted: false
                            )
                        )
                    ]
                )
            )
        }
        let queue = SyncV2StoreVectorQueue(
            store: store,
            url: url,
            operationIDs: mapping,
            dispatch: Self.storeDispatch
        )
        return (queue, mapping)
    }

    /// 저장소로 발송을 흉내 낸다.
    ///
    /// `complete`가 거짓이면 집어들기만 하고 끝내지 않는다. 보내는 도중에
    /// 앱이 꺼진 상태를 만들 때 쓴다.
    private static func storeDispatch(
        _ store: SyncV2Store,
        _ operationID: UUID,
        _ complete: Bool
    ) async throws {
        let claimed = try await store.claimReadyOperations(
            limit: 10,
            now: Date(timeIntervalSince1970: 100)
        )
        guard let operation = claimed.first(where: { $0.operationID == operationID }) else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "집어들지 못했다")
        }
        guard complete else { return }
        try await store.complete(
            operation,
            result: SyncV2CommitDocumentResult(
                status: .committed,
                documentID: operation.documentID,
                versionID: UUID(),
                operationID: operation.operationID,
                operationKind: operation.baseRevision == 0 ? .create : .update,
                serverRevision: operation.baseRevision + 1,
                relativePath: operation.relativePath,
                isDeleted: operation.isDeleted,
                contentHash: SHA256ContentHasher()
                    .sha256(for: Data(operation.content.utf8))
                    .rawValue,
                committedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    // MARK: - 하네스가 실제로 무언가를 잡는가

    /// 상태를 사건이 아니라 칸에 적어 두고, 끝난 작업에도 사건을 덧붙이는
    /// 구현이다. Windows가 실제로 냈던 버그를 그대로 흉내 낸다.
    private final class BrokenQueue: SyncV2VectorQueue {
        private var statuses: [UUID: SyncV2OperationStatus] = [:]
        private var eventLog: [UUID: [SyncV2OperationEvent]] = [:]
        private var attempts: [UUID: Int] = [:]

        init(clientState: SyncV2TransitionVector.ClientState) {
            for item in clientState.queue {
                statuses[item.operationID] = item.state
                eventLog[item.operationID] = [
                    SyncV2OperationEvent(sequence: 1, type: .enqueued)
                ]
                attempts[item.operationID] = item.attemptCount
            }
        }

        func cancelOperation(operationID: UUID, cancelEventID: UUID) async throws -> SyncV2CancelOutcome {
            // 끝난 작업인지 보지 않고, 올 때마다 사건을 덧붙인다.
            var events = eventLog[operationID] ?? []
            events.append(
                SyncV2OperationEvent(sequence: events.count + 1, type: .cancelRequested)
            )
            eventLog[operationID] = events
            statuses[operationID] = .cancelled
            return .cancelled(eventID: cancelEventID)
        }

        func commitBatch(operationID: UUID) async throws {
            attempts[operationID] = (attempts[operationID] ?? 0) + 1
            // 상태 칸을 갱신하지 않는다. 완료됐는데 pending으로 남는다.
        }

        func beginDispatch(operationID: UUID) async throws {
            attempts[operationID] = (attempts[operationID] ?? 0) + 1
        }

        // 껐다 켜도 아무것도 되살리지 않는다. 보내던 작업이 그대로 멈춰 있는다.
        func restart() async throws {}

        func retry(operationID: UUID) async throws {
            try await commitBatch(operationID: operationID)
        }

        func state(of operationID: UUID) async throws -> SyncV2OperationStatus {
            statuses[operationID] ?? .pending
        }

        func attemptCount(of operationID: UUID) async throws -> Int { attempts[operationID] ?? 0 }
        func events(of operationID: UUID) async throws -> [SyncV2OperationEvent] { eventLog[operationID] ?? [] }
    }

    /// 틀린 구현을 넣으면 하네스가 어긋남을 집어내야 한다. 이 시험이 없으면
    /// 벡터가 통과했다는 말이 아무것도 보증하지 않는다.
    func testHarnessCatchesBrokenImplementation() async throws {
        let vector = try SyncV2TransitionVector.load("11-cancellation-event-derivation")
        let client = try XCTUnwrap(vector.initialClientStates.first)
        let runner = SyncV2VectorRunner(vector: vector, queue: BrokenQueue(clientState: client))
        try await runner.run()

        let mismatches = await runner.mechanicalMismatches()
        XCTAssertFalse(mismatches.isEmpty, "틀린 구현인데 하네스가 아무것도 잡지 못했다")

        // 완료돼야 할 작업이 pending으로 남는 것과, 종료 상태 보호가 없어
        // OPERATION_TERMINAL이 나지 않는 것을 둘 다 잡아야 한다.
        XCTAssertTrue(
            mismatches.contains { $0.contains("상태") },
            "상태 어긋남을 잡지 못했다: \(mismatches)"
        )
        XCTAssertTrue(
            mismatches.contains { $0.contains("마지막 오류") },
            "종료 상태 보호가 없는 것을 잡지 못했다: \(mismatches)"
        )
    }

    /// 참조 구현으로는 어긋남이 하나도 없어야 한다.
    func testReferenceQueueHasNoMismatch() async throws {
        let mismatches = await (try await runVector11()).mechanicalMismatches()
        XCTAssertEqual(mismatches, [])
    }
}
