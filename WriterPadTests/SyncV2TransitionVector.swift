import Foundation
@testable import WriterPad

/// `sync-contract/test_vectors/`의 상태 전이 벡터를 읽는 모델이다.
///
/// 아이패드와 Windows가 **같은 벡터로 같은 결과**를 내야 한다. 그래서 벡터를
/// 복사해 두지 않고 계약 패키지의 원본을 그대로 읽는다. 사본을 두면 계약이
/// 개정될 때 조용히 낡는다.
///
/// 벡터의 기대값은 두 종류다. `state`·`attempt_count`·`error_code`처럼 기계가
/// 그대로 대조할 수 있는 것과, `assertions`처럼 사람이 읽는 문장이다. 이
/// 하네스는 앞의 것만 자동으로 판정하고 뒤의 것은 그대로 실어 나른다. 문장을
/// 자동으로 해석하는 척하지 않는다.
struct SyncV2TransitionVector: Decodable {
    let vectorID: String
    let title: String
    let contractVersion: String
    let minimumProtocolVersion: Int
    let tags: [String]
    let initialServerState: ServerState
    let initialClientStates: [ClientState]
    let orderedActions: [Action]
    let faultInjections: [Fault]
    let expectedServerState: ServerExpectation
    let expectedClientStates: [ClientExpectation]
    let expectedQueueStates: [QueueExpectation]
    let invariants: [Invariant]

    enum CodingKeys: String, CodingKey {
        case vectorID = "vector_id"
        case title
        case contractVersion = "contract_version"
        case minimumProtocolVersion = "minimum_protocol_version"
        case tags
        case initialServerState = "initial_server_state"
        case initialClientStates = "initial_client_states"
        case orderedActions = "ordered_actions"
        case faultInjections = "fault_injections"
        case expectedServerState = "expected_server_state"
        case expectedClientStates = "expected_client_states"
        case expectedQueueStates = "expected_queue_states"
        case invariants
    }

    struct ServerState: Decodable {
        let projectID: UUID
        let projectSyncMode: SyncV2ProjectSyncMode
        let migrationEpoch: Int
        let entities: [Entity]
        let treeOrder: [String: [String]]

        enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case projectSyncMode = "project_sync_mode"
            case migrationEpoch = "migration_epoch"
            case entities
            case treeOrder = "tree_order"
        }
    }

    struct Entity: Decodable {
        let entityID: UUID
        let entityKind: String
        let revision: Int
        let isDeleted: Bool
        let parentFolderID: UUID?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case entityID = "entity_id"
            case entityKind = "entity_kind"
            case revision
            case isDeleted = "is_deleted"
            case parentFolderID = "parent_folder_id"
            case name
        }
    }

    struct ClientState: Decodable {
        let clientID: String
        let platform: String
        let protocolVersion: Int
        let capabilities: [String]
        let queue: [QueueItem]

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case platform
            case protocolVersion = "protocol_version"
            case capabilities
            case queue
        }
    }

    /// 벡터가 미리 깔아 두는 대기열 항목이다. `provenance_kind`가
    /// `LEGACY_EPOCH_0`이면 batch가 없고 `CONTRACT_BATCH`면 반드시 있다.
    struct QueueItem: Decodable {
        let operationID: UUID
        let batchID: UUID?
        let provenanceKind: String
        let entityID: UUID
        let intentKind: String
        let baseRevision: Int
        let payloadSHA256: String
        let state: SyncV2OperationStatus
        let attemptCount: Int

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case batchID = "batch_id"
            case provenanceKind = "provenance_kind"
            case entityID = "entity_id"
            case intentKind = "intent_kind"
            case baseRevision = "base_revision"
            case payloadSHA256 = "payload_sha256"
            case state
            case attemptCount = "attempt_count"
        }
    }

    struct Action: Decodable {
        let actionID: String
        let actor: String
        let kind: Kind
        let input: [String: VectorValue]
        /// 사람이 읽는 문장이다. 자동 판정하지 않고 실패 메시지에만 싣는다.
        let expectedOutcome: String

        enum CodingKeys: String, CodingKey {
            case actionID = "action_id"
            case actor
            case kind
            case input
            case expectedOutcome = "expected_outcome"
        }

        enum Kind: String, Decodable {
            case createFolder = "create_folder"
            case createDocument = "create_document"
            case renameFolder = "rename_folder"
            case renameDocument = "rename_document"
            case deleteFolder = "delete_folder"
            case deleteDocument = "delete_document"
            case connectLegacyClient = "connect_legacy_client"
            case commitBatch = "commit_batch"
            case retryOperation = "retry_operation"
            case restartClient = "restart_client"
            case pullSnapshot = "pull_snapshot"
            case rebaseOperation = "rebase_operation"
            case beginMigration = "begin_migration"
            case completeMigration = "complete_migration"
            case legacyStructureWrite = "legacy_structure_write"
            case cancelOperation = "cancel_operation"
            case atomicStructureCommit = "atomic_structure_commit"
        }
    }

    struct Fault: Decodable {
        let afterActionID: String
        let type: String
        let parameters: [String: VectorValue]

        enum CodingKeys: String, CodingKey {
            case afterActionID = "after_action_id"
            case type
            case parameters
        }
    }

    struct ServerExpectation: Decodable {
        let projectSyncMode: SyncV2ProjectSyncMode
        let migrationEpoch: Int
        let entityAssertions: [String]
        let treeOrderAssertions: [String]

        enum CodingKeys: String, CodingKey {
            case projectSyncMode = "project_sync_mode"
            case migrationEpoch = "migration_epoch"
            case entityAssertions = "entity_assertions"
            case treeOrderAssertions = "tree_order_assertions"
        }
    }

    struct ClientExpectation: Decodable {
        let clientID: String
        let assertions: [String]

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case assertions
        }
    }

    /// 대기열 기대값이다.
    ///
    /// - Note: `errorCode`는 저장된 칸이 아니라 **그 작업을 마지막으로 건드린
    ///   동작이 낸 오류**다. 벡터 11에서 이미 완료된 작업에 `OPERATION_TERMINAL`이
    ///   붙어 있는데, 계약상 끝난 작업에는 사건을 덧붙일 수 없으므로 사건 기록에
    ///   그 코드가 남을 자리가 없다. Windows도 `cancel_operation`이 던진 예외의
    ///   코드로 확인한다(`test_cancellation_is_idempotent_and_terminal_safe`).
    struct QueueExpectation: Decodable {
        let operationID: UUID
        let state: SyncV2OperationStatus
        let attemptCount: Int
        let errorCode: String?
        let supersedesOperationID: UUID?
        let assertions: [String]

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case state
            case attemptCount = "attempt_count"
            case errorCode = "error_code"
            case supersedesOperationID = "supersedes_operation_id"
            case assertions
        }
    }

    struct Invariant: Decodable {
        let id: String
        let assert: String
    }
}

/// 벡터의 `input`·`parameters`처럼 모양이 정해지지 않은 값이다.
///
/// 동작마다 입력이 달라서(어떤 것은 `tree_order`처럼 중첩된 표를 싣는다) 미리
/// 모양을 못 박을 수 없다. 그렇다고 통째로 삼키면 계약이 개정돼 새 모양이
/// 들어와도 모르고 지나가므로, 받을 수 있는 값을 열거하고 그 밖은 거부한다.
indirect enum VectorValue: Decodable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case null
    case array([VectorValue])
    case object([String: VectorValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([VectorValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: VectorValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "벡터 입력에 예상하지 못한 값이 있다"
            )
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }

    var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }

    var arrayValue: [VectorValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var objectValue: [String: VectorValue]? {
        if case let .object(value) = self { return value }
        return nil
    }
}

// MARK: - 불러오기

extension SyncV2TransitionVector {
    enum LoadError: Error, CustomStringConvertible {
        case missingPackage(URL)
        case missingVector(String, URL)

        var description: String {
            switch self {
            case let .missingPackage(url):
                return """
                계약 패키지를 찾지 못했다: \(url.path)
                벡터는 저장소의 sync-contract/test_vectors/를 그대로 읽는다. \
                시뮬레이터가 아닌 실기기에서는 이 경로에 닿을 수 없다.
                """
            case let .missingVector(name, url):
                return "벡터 \(name)이(가) 없다: \(url.path)"
            }
        }
    }

    /// 저장소의 계약 패키지 위치다. 테스트 소스 경로에서 거슬러 올라간다.
    static var packageURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WriterPadTests
            .deletingLastPathComponent()   // 저장소 뿌리
            .appendingPathComponent("sync-contract")
    }

    /// 이름으로 벡터 하나를 읽는다. `11-cancellation-event-derivation`처럼
    /// 확장자 없는 파일명을 준다.
    static func load(_ name: String) throws -> SyncV2TransitionVector {
        let directory = packageURL.appendingPathComponent("test_vectors")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw LoadError.missingPackage(packageURL)
        }
        let url = directory.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.missingVector(name, url)
        }
        return try JSONDecoder().decode(
            SyncV2TransitionVector.self,
            from: Data(contentsOf: url)
        )
    }

    /// 계약 패키지에 들어 있는 벡터 파일 이름 전부다.
    static func allVectorNames() throws -> [String] {
        let directory = packageURL.appendingPathComponent("test_vectors")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw LoadError.missingPackage(packageURL)
        }
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }
}
