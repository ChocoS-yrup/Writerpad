import Foundation
import XCTest
@testable import WriterPad

/// 상태 전이 벡터를 실제로 돌리는 하네스다.
///
/// 벡터가 두드리는 대상은 `SyncV2VectorQueue`다. 계약 모듈 위에 얹은 참조
/// 구현과, 실제로 사용자 글을 나르는 `SyncV2Store` 둘 다 이 프로토콜을 채운다.
/// **같은 벡터를 둘에 그대로 먹여** 답이 같은지 본다.
protocol SyncV2VectorQueue: AnyObject {
    func cancelOperation(operationID: UUID, cancelEventID: UUID) async throws -> SyncV2CancelOutcome
    func commitBatch(operationID: UUID) async throws
    func state(of operationID: UUID) async throws -> SyncV2OperationStatus
    func attemptCount(of operationID: UUID) async throws -> Int
    func events(of operationID: UUID) async throws -> [SyncV2OperationEvent]
}

/// 취소 요청의 결과다. 이미 취소된 작업에 다시 요청해도 오류가 아니다.
enum SyncV2CancelOutcome: Equatable {
    case cancelled(eventID: UUID)
    case alreadyCancelled(eventID: UUID?)
}

// MARK: - 참조 구현

/// 계약이 말하는 대로만 움직이는 최소 대기열이다.
///
/// 상태를 칸에 적어 두지 않는다. 언제나 사건 기록에서 계산한다.
final class SyncV2ReferenceQueue: SyncV2VectorQueue {
    private var eventsByOperation: [UUID: [SyncV2OperationEvent]] = [:]
    /// 사건 식별자가 어느 작업의 무슨 사건이었는지다. 같은 식별자로 다시 온
    /// 요청을 멱등하게 처리하려면 필요하다.
    private var eventOwners: [UUID: (operationID: UUID, type: SyncV2OperationEventType)] = [:]
    private var attempts: [UUID: Int] = [:]
    private var baseRevisions: [UUID: Int] = [:]
    private var entityOfOperation: [UUID: UUID] = [:]

    /// 서버 쪽 개체 리비전이다. 벡터가 서버 상태까지 확인하므로 함께 든다.
    private(set) var entityRevisions: [UUID: Int] = [:]

    init(clientState: SyncV2TransitionVector.ClientState, serverState: SyncV2TransitionVector.ServerState) {
        for entity in serverState.entities {
            entityRevisions[entity.entityID] = entity.revision
        }
        for item in clientState.queue {
            entityOfOperation[item.operationID] = item.entityID
            baseRevisions[item.operationID] = item.baseRevision
            attempts[item.operationID] = item.attemptCount
            eventsByOperation[item.operationID] = SyncV2ReferenceQueue.seedEvents(for: item.state)
        }
    }

    /// 벡터가 깔아 둔 상태를 사건 기록으로 되돌린다. 저장소의 되만들기 표와
    /// 같은 규칙을 쓴다.
    private static func seedEvents(for state: SyncV2OperationStatus) -> [SyncV2OperationEvent] {
        SyncV2Store.seedEventTypes(for: state).enumerated().map { index, type in
            SyncV2OperationEvent(sequence: index + 1, type: type)
        }
    }

    func events(of operationID: UUID) async throws -> [SyncV2OperationEvent] {
        eventsByOperation[operationID] ?? []
    }

    func state(of operationID: UUID) async throws -> SyncV2OperationStatus {
        try SyncV2OperationStateDerivation.state(
            from: eventsByOperation[operationID] ?? []
        )
    }

    func attemptCount(of operationID: UUID) async throws -> Int {
        attempts[operationID] ?? 0
    }

    private func append(
        _ type: SyncV2OperationEventType,
        to operationID: UUID,
        eventID: UUID = UUID(),
        errorCode: String? = nil
    ) throws {
        var events = eventsByOperation[operationID] ?? []
        try SyncV2OperationStateDerivation.requireAppendable(to: events)
        events.append(
            SyncV2OperationEvent(
                sequence: events.count + 1,
                type: type,
                errorCode: errorCode
            )
        )
        eventsByOperation[operationID] = events
        eventOwners[eventID] = (operationID, type)
    }

    /// 취소를 요청한다.
    ///
    /// 같은 사건 식별자로 다시 오면 사건을 늘리지 않고 이미 취소됐다고
    /// 답한다. 완료된 작업은 `OPERATION_TERMINAL`로 거절한다. 이미 취소된
    /// 작업은 오류가 아니다.
    func cancelOperation(
        operationID: UUID,
        cancelEventID: UUID
    ) async throws -> SyncV2CancelOutcome {
        guard eventsByOperation[operationID] != nil else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "모르는 작업이다")
        }
        if let owner = eventOwners[cancelEventID] {
            guard owner.operationID == operationID, owner.type == .cancelRequested else {
                throw SyncV2ContractError("EVENT_ID_REUSED")
            }
            return .alreadyCancelled(eventID: cancelEventID)
        }
        let current = try await state(of: operationID)
        if current == .completed {
            throw SyncV2ContractError.operationTerminal
        }
        if current == .cancelled {
            return .alreadyCancelled(eventID: nil)
        }
        try append(.cancelRequested, to: operationID, eventID: cancelEventID)
        return .cancelled(eventID: cancelEventID)
    }

    /// 배치를 보내 커밋한다. 한 번의 시도로 친다.
    func commitBatch(operationID: UUID) async throws {
        try append(.dispatchStarted, to: operationID)
        attempts[operationID] = (attempts[operationID] ?? 0) + 1
        try append(.committed, to: operationID)
        if let entityID = entityOfOperation[operationID] {
            entityRevisions[entityID] = (baseRevisions[operationID] ?? 0) + 1
        }
    }
}

// MARK: - 운영 저장소 어댑터

/// 벡터를 운영 저장소로 돌린다.
///
/// 참조 구현은 계약을 옳게 옮겼는지 확인해 주지만, 실제로 사용자 글을 나르는
/// 것은 `SyncV2Store`다. 같은 벡터를 저장소에도 그대로 먹여 봐야 한다.
///
/// 벡터가 부르는 작업 식별자와 저장소가 실제로 만든 것을 잇는 표를 받는다.
/// 벡터의 대기열은 표에 직접 밀어 넣지 않고 저장소의 정식 경로로 만들어야,
/// 시험이 저장소가 하는 일을 실제로 확인한다.
final class SyncV2StoreVectorQueue: SyncV2VectorQueue {
    private let store: SyncV2Store
    private let operationIDs: [UUID: UUID]
    private let commit: (SyncV2Store, UUID) async throws -> Void

    init(
        store: SyncV2Store,
        operationIDs: [UUID: UUID],
        commit: @escaping (SyncV2Store, UUID) async throws -> Void
    ) {
        self.store = store
        self.operationIDs = operationIDs
        self.commit = commit
    }

    private func resolved(_ vectorOperationID: UUID) throws -> UUID {
        guard let real = operationIDs[vectorOperationID] else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "벡터 작업을 잇지 못했다")
        }
        return real
    }

    func cancelOperation(
        operationID: UUID,
        cancelEventID: UUID
    ) async throws -> SyncV2CancelOutcome {
        let outcome = try await store.cancelOperation(
            operationID: try resolved(operationID),
            cancelEventID: cancelEventID
        )
        switch outcome {
        case let .cancelled(eventID):
            return .cancelled(eventID: eventID)
        case let .alreadyCancelled(eventID):
            return .alreadyCancelled(eventID: eventID)
        }
    }

    func commitBatch(operationID: UUID) async throws {
        try await commit(store, try resolved(operationID))
    }

    func state(of operationID: UUID) async throws -> SyncV2OperationStatus {
        let raw = try await store.operationStatus(
            operationID: try resolved(operationID)
        )
        guard let raw, let state = SyncV2OperationStatus(rawValue: raw) else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "상태를 읽지 못했다")
        }
        return state
    }

    func attemptCount(of operationID: UUID) async throws -> Int {
        try await store.operationAttempts(
            operationID: try resolved(operationID)
        ) ?? 0
    }

    func events(of operationID: UUID) async throws -> [SyncV2OperationEvent] {
        try await store.operationEvents(
            operationID: try resolved(operationID)
        )
    }
}

// MARK: - 실행기

/// 벡터를 읽어 동작을 차례대로 돌리고 기대값과 대조한다.
final class SyncV2VectorRunner {
    let vector: SyncV2TransitionVector
    let queue: SyncV2VectorQueue

    /// 각 작업을 마지막으로 건드린 동작이 낸 오류다.
    ///
    /// 벡터의 `expected_queue_states[].error_code`가 가리키는 것이 이 값이다.
    /// 저장된 칸이 아니다. 완료된 작업에 취소를 걸면 `OPERATION_TERMINAL`이
    /// 나지만 계약상 사건은 붙지 않으므로 기록에는 남을 자리가 없다.
    private(set) var lastActionErrorCode: [UUID: String] = [:]

    /// 자동으로 판정하지 않고 넘기는 문장들이다. 실패했을 때 사람이 볼 수
    /// 있도록 모아 둔다.
    private(set) var proseAssertions: [String] = []

    init(vector: SyncV2TransitionVector, queue: SyncV2VectorQueue) {
        self.vector = vector
        self.queue = queue
    }

    /// 참조 구현으로 벡터를 돌릴 준비를 한다.
    static func withReferenceQueue(_ vector: SyncV2TransitionVector) throws -> SyncV2VectorRunner {
        let client = try primaryClient(of: vector)
        return SyncV2VectorRunner(
            vector: vector,
            queue: SyncV2ReferenceQueue(
                clientState: client,
                serverState: vector.initialServerState
            )
        )
    }

    /// 벡터가 겨냥하는 클라이언트다. 아이패드가 있으면 아이패드를 본다.
    static func primaryClient(
        of vector: SyncV2TransitionVector
    ) throws -> SyncV2TransitionVector.ClientState {
        guard let client = vector.initialClientStates.first(where: { $0.platform == "ipad" })
            ?? vector.initialClientStates.first
        else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "벡터에 클라이언트가 없다")
        }
        return client
    }

    /// 아직 다루지 못하는 동작이다. 조용히 넘기지 않고 이름을 들고 올라간다.
    struct UnsupportedAction: Error, CustomStringConvertible {
        let actionID: String
        let kind: SyncV2TransitionVector.Action.Kind
        var description: String {
            "\(actionID): 아직 하네스가 다루지 못하는 동작이다 — \(kind.rawValue)"
        }
    }

    /// 동작을 차례대로 돌린다.
    func run() async throws {
        for action in vector.orderedActions {
            proseAssertions.append("\(action.actionID) \(action.expectedOutcome)")
            do {
                try await perform(action)
            } catch let error as SyncV2ContractError {
                // 계약 오류는 벡터가 기대하는 결과일 수 있다. 어느 작업에서
                // 났는지 기록해 두고 계속 간다.
                if let operationID = action.input["operation_id"]?.uuidValue {
                    lastActionErrorCode[operationID] = error.code
                }
            }
        }
        for expectation in vector.expectedQueueStates {
            proseAssertions.append(contentsOf: expectation.assertions.map {
                "queue \(expectation.operationID): \($0)"
            })
        }
        proseAssertions.append(contentsOf: vector.expectedServerState.entityAssertions)
        proseAssertions.append(contentsOf: vector.invariants.map { "\($0.id) \($0.assert)" })
    }

    private func perform(_ action: SyncV2TransitionVector.Action) async throws {
        switch action.kind {
        case .cancelOperation:
            guard let operationID = action.input["operation_id"]?.uuidValue,
                  let eventID = action.input["cancel_event_id"]?.uuidValue
            else {
                throw SyncV2ContractError("INVALID_ARGUMENT", "\(action.actionID): 취소 입력이 모자라다")
            }
            _ = try await queue.cancelOperation(
                operationID: operationID,
                cancelEventID: eventID
            )

        case .commitBatch:
            guard let operationID = action.input["operation_id"]?.uuidValue else {
                throw SyncV2ContractError("INVALID_ARGUMENT", "\(action.actionID): 커밋 입력이 모자라다")
            }
            try await queue.commitBatch(operationID: operationID)

        default:
            throw UnsupportedAction(actionID: action.actionID, kind: action.kind)
        }
    }

    /// 기계가 대조할 수 있는 기대값만 맞춰 보고 어긋난 것을 돌려준다.
    /// 문장은 판정하지 않는다.
    ///
    /// 판정을 `XCTAssert`로 바로 하지 않고 목록으로 내는 이유는, 하네스가
    /// 실제로 무언가를 잡는지 확인하는 시험에서 "틀린 구현을 넣으면 어긋남이
    /// 나온다"를 그대로 확인할 수 있어야 하기 때문이다.
    func mechanicalMismatches() async -> [String] {
        var mismatches: [String] = []
        for expectation in vector.expectedQueueStates {
            let label = "\(vector.vectorID) \(expectation.operationID)"
            do {
                let actual = try await queue.state(of: expectation.operationID)
                if actual != expectation.state {
                    mismatches.append("\(label): 상태 \(actual) ≠ 기대 \(expectation.state)")
                }
            } catch {
                mismatches.append("\(label): 상태를 계산하지 못했다 — \(error)")
            }
            do {
                let attempts = try await queue.attemptCount(of: expectation.operationID)
                if attempts != expectation.attemptCount {
                    mismatches.append("\(label): 시도 \(attempts) ≠ 기대 \(expectation.attemptCount)")
                }
            } catch {
                mismatches.append("\(label): 시도 횟수를 읽지 못했다 — \(error)")
            }
            if let expectedCode = expectation.errorCode {
                let actual = lastActionErrorCode[expectation.operationID]
                if actual != expectedCode {
                    mismatches.append(
                        "\(label): 마지막 오류 \(actual ?? "없음") ≠ 기대 \(expectedCode)"
                    )
                }
            }
        }
        return mismatches
    }

    /// 어긋난 것이 없어야 한다.
    func assertMechanicalExpectations(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let mismatches = await mechanicalMismatches()
        XCTAssertEqual(
            mismatches,
            [],
            "\(vector.vectorID) 기대값이 어긋났다:\n" + mismatches.joined(separator: "\n"),
            file: file,
            line: line
        )
    }
}
