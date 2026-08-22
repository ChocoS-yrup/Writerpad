import CryptoKit
import Foundation

/// 동결된 sync-contract 0.2.0의 와이어 계약이다.
///
/// Windows가 `sync_contract.py`로 먼저 구현한 것과 같은 규칙을 담는다. 두
/// 클라이언트가 같은 작품을 쓰므로, 한쪽이 조금이라도 다르게 계산하면 서버가
/// 요청을 거부하거나 더 나쁘게는 서로 다른 것을 같다고 착각한다. 그래서 이
/// 파일은 "읽기 좋은 Swift"보다 "Windows와 한 글자도 다르지 않은 결과"를
/// 우선한다.
///
/// 여기 있는 것은 계산뿐이다. 저장소도 네트워크도 건드리지 않아 벡터로 그대로
/// 검증할 수 있다.
enum SyncV2Contract {
    /// 빌드에 박아 두는 계약 고정값이다. `sync-contract/contract-lock.json`과
    /// 일치해야 하며, 어긋난 채로 배포되면 서버가 다이제스트 불일치로 모든
    /// 쓰기를 거부한다.
    static let version = "0.2.0"

    /// 계약을 확정한 커밋이다. lock 파일에는 담을 수 없어(커밋이 자기 SHA를
    /// 품을 수 없다) 단계 인수인계 문서에 기록된 값을 여기 옮겨 둔다.
    static let gitCommit = "fcd99b7098b9a04bd93c585d89b16588aa482530"

    /// 계약 본문을 마지막으로 바꾼 커밋이다.
    static let contentCommit = "7bcb5d25c5376b02469666df7318b90b456ffee6"

    /// RFC 8785로 정규화한 `protocol.json`의 바이트 수와 SHA-256이다.
    static let canonicalByteCount = 23_256
    static let canonicalSHA256 =
        "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"

    /// protocol 3 이상이어야 구조 쓰기가 허용된다.
    static let syncProtocolVersion = 3

    static let storageNameAlgorithm = "storage-name-v1"
    static let storageNameUnicodeVersion = "15.0.0"

    /// 서버가 어느 빌드에서 온 요청인지 알 수 있게 하는 값이다. 사고가 났을 때
    /// 어느 버전이 범인인지 가리는 유일한 단서다.
    static let clientBuildID = "writerpad-ipad-stage8-contract-0.2.0"

    /// 우리가 지킬 수 있다고 선언하는 능력이다. 선언해 놓고 못 지키면 서버가
    /// 우리를 믿고 보낸 요청에서 데이터가 깨진다.
    static let clientCapabilities: [String] = [
        "folders_authoritative",
        "tree_order_ids",
        "tombstones",
        "immutable_batch_contract_metadata",
        "operation_attempt_history",
        "operation_state_events",
        "storage_name_v1",
        "document_commit_v1",
    ]

    /// 서버가 이만큼 갖추지 못했으면 쓰지 않는다. 하나라도 없는 서버에 protocol
    /// 3 요청을 보내면 반쯤 적용된 구조가 남을 수 있다.
    static let requiredServerCapabilities: Set<String> = [
        "atomic_structure_commit",
        "contract_allowlist_validation",
        "project_mode_migration_lock",
        "folder_tombstones",
        "id_tree_validation",
        "legacy_epoch_zero_adapter",
        "storage_name_v1",
        "document_commit_v1",
    ]
}

// MARK: - 오류

/// 계약이 정한 안정된 오류 코드를 나른다.
///
/// 번역된 문구가 아니라 이 코드로 분기한다. 문구는 언제든 바뀌지만 코드는
/// 계약이 보증한다.
struct SyncV2ContractError: Error, Equatable, Sendable {
    let code: String
    let detail: String?

    init(_ code: String, _ detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    static let invalidArgument = SyncV2ContractError("INVALID_ARGUMENT")
    static let storageNameInvalid = SyncV2ContractError("STORAGE_NAME_INVALID")
    static let storageNameReserved = SyncV2ContractError("STORAGE_NAME_RESERVED")
    static let staleMigrationEpoch = SyncV2ContractError("STALE_MIGRATION_EPOCH")
    static let protocolTooOld = SyncV2ContractError("PROTOCOL_TOO_OLD")
    static let contractDigestMismatch = SyncV2ContractError("CONTRACT_DIGEST_MISMATCH")
    static let capabilityMismatch = SyncV2ContractError("CAPABILITY_MISMATCH")
    static let operationTerminal = SyncV2ContractError("OPERATION_TERMINAL")
    static let partialBatchResponse = SyncV2ContractError("PARTIAL_BATCH_RESPONSE")

    static func invalidAtomicResponse(_ detail: String? = nil) -> SyncV2ContractError {
        SyncV2ContractError("INVALID_ATOMIC_RESPONSE", detail)
    }

    static func invalidDocumentResponse(_ detail: String? = nil) -> SyncV2ContractError {
        SyncV2ContractError("INVALID_DOCUMENT_RESPONSE", detail)
    }
}

// MARK: - 정규 JSON

/// 계약이 허용하는 JSON 값이다.
///
/// RFC 8785 전체가 아니라 그 부분집합만 쓴다. 실수는 아예 없고(자릿수 표현이
/// 언어마다 달라 다이제스트가 갈린다), 키는 ASCII 식별자로 제한한다(키 정렬이
/// UTF-16 코드 단위 순서인지 코드포인트 순서인지에 따라 갈리는 문제를 원천
/// 차단한다). 이 제약 덕분에 Python과 Swift가 같은 바이트열을 낸다.
indirect enum SyncV2JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([SyncV2JSON])
    case object([String: SyncV2JSON])
}

extension SyncV2JSON {
    /// 계약이 허용하는 키인지 본다. `^[A-Za-z_][A-Za-z0-9_]*$`와 같은 판정을
    /// 정규식 없이 한다. Swift 5 언어 모드에서는 슬래시 정규식 리터럴이 기본
    /// 활성이 아니라 빌드 설정에 기대지 않으려는 것이다.
    static func isContractKey(_ key: String) -> Bool {
        var isFirst = true
        for scalar in key.unicodeScalars {
            let isLetter = ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar)
            let isDigit = ("0"..."9").contains(scalar)
            if isFirst {
                guard isLetter || scalar == "_" else { return false }
                isFirst = false
            } else {
                guard isLetter || isDigit || scalar == "_" else { return false }
            }
        }
        return !isFirst
    }

    /// RFC 8785 부분집합으로 정규화한 문자열이다. 키는 오름차순, 공백은 없다.
    func canonicalJSON() throws -> String {
        var out = ""
        try append(to: &out)
        return out
    }

    /// 정규 JSON의 UTF-8 바이트에 대한 SHA-256이다. 소문자 16진수로 낸다.
    func sha256Hex() throws -> String {
        let digest = SHA256.hash(data: Data(try canonicalJSON().utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func append(to out: inout String) throws {
        switch self {
        case .null:
            out += "null"
        case let .bool(value):
            out += value ? "true" : "false"
        case let .int(value):
            out += String(value)
        case let .string(value):
            SyncV2JSON.appendQuoted(value, to: &out)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                try item.append(to: &out)
            }
            out += "]"
        case let .object(fields):
            out += "{"
            // 키를 ASCII 식별자로 묶어 두었으므로 단순 사전순이 곧 계약 순서다.
            for (index, key) in fields.keys.sorted().enumerated() {
                guard SyncV2JSON.isContractKey(key) else {
                    throw SyncV2ContractError("INVALID_ARGUMENT", "non-contract JSON key")
                }
                if index > 0 { out += "," }
                SyncV2JSON.appendQuoted(key, to: &out)
                out += ":"
                try fields[key]!.append(to: &out)
            }
            out += "}"
        }
    }

    /// 문자열을 JSON 리터럴로 적는다. 비ASCII는 그대로 두고(escape하면 Python
    /// `ensure_ascii=False` 결과와 갈린다) 제어문자만 이스케이프한다.
    private static func appendQuoted(_ value: String, to out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

extension SyncV2JSON {
    /// `JSONSerialization`이 낸 값을 계약 JSON으로 옮긴다. 서버 응답을 검증하기
    /// 전에 거쳐야 하는 관문이다. 실수가 섞여 있으면 여기서 막는다.
    init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if let value = Int(exactly: number) {
                self = .int(value)
            } else {
                throw SyncV2ContractError("INVALID_ARGUMENT", "contract JSON permits integers only")
            }
        case let value as String:
            self = .string(value)
        case let items as [Any]:
            self = .array(try items.map { try SyncV2JSON(jsonObject: $0) })
        case let fields as [String: Any]:
            var mapped: [String: SyncV2JSON] = [:]
            for (key, value) in fields {
                mapped[key] = try SyncV2JSON(jsonObject: value)
            }
            self = .object(mapped)
        default:
            throw SyncV2ContractError("INVALID_ARGUMENT", "unsupported JSON value")
        }
    }

    var objectValue: [String: SyncV2JSON]? {
        if case let .object(fields) = self { return fields }
        return nil
    }

    var arrayValue: [SyncV2JSON]? {
        if case let .array(items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .int(value) = self { return value }
        return nil
    }
}

// MARK: - storage-name 정규화

/// 이름 충돌을 판정하는 정규화다.
///
/// 아이패드는 자모가 분해된 이름을, Windows는 결합된 이름을 만들 수 있다. 두
/// 이름이 같은 자리를 다투는지 알려면 같은 키로 수렴시켜야 한다.
///
/// - Note: **이 구현은 아직 계약이 요구하는 키를 완전히 내지 못한다.**
///   계약은 Unicode 15.0.0의 NFKC와 default case folding을 요구한다. 두 단계 중
///   접기는 `SyncV2UnicodeCasefold`의 동결 표로 옮겨 계약과 맞췄고, NFKC는
///   여전히 Foundation에 맡기고 있어 OS가 싣고 있는 ICU를 따른다
///   (2026-08-13 실측 ICU 78.1 / Unicode 17.0.0).
///
///   이 자리에는 한때 "실제로 갈릴 수 있는 문자는 92개뿐"이라고 적혀 있었다.
///   전 코드포인트를 실제로 훑어 보니 사실이 아니었다. 단독 스칼라만 세도
///   276개가 갈렸고, 그중 181개는 Unicode 14.0.0 베이스라인 **안쪽**이었다.
///   안정성 정책은 판이 올라갈 때 결과가 바뀌지 않는다고 보장할 뿐, 서로 다른
///   구현이 같은 결과를 낸다고 보장하지 않는다. 갈리던 원인의 대부분은 판
///   차이가 아니라 구현 차이 — 접기가 default case folding이 아니었던 것 —
///   이었고, 그 236개가 동결 표로 닫혔다.
///
///   남은 것은 두 가지다. `divergentScalars`의 40개(전부 베이스라인 바깥)와,
///   상위면 스칼라 바로 뒤에 결합문자가 올 때 Foundation의 NFKC가 코드포인트를
///   16비트로 잘라 버리는 결함이다. 둘 다 계약 개정에서 규칙으로 막기로 했고
///   여기서는 아직 손대지 않는다.
///
///   계약 벡터 15개는 접기 교체 전에도 후에도 전부 통과한다. 벡터가 짚지 않는
///   영역에서 갈리기 때문이며, 그래서 벡터 통과는 적합성의 근거가 되지 못한다.
///
///   측정 결과와 스칼라 목록은 저장소 뿌리의 `윈도우세션_회신*.md`와
///   `유니코드측정_*.json`에 있다.
enum SyncV2StorageName {
    private static let reservedBasenames: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul"]
        for index in 1...9 {
            names.insert("com\(index)")
            names.insert("lpt\(index)")
        }
        return names
    }()

    /// 충돌 키를 만든다. 유효하지 않은 이름은 여기서 걸러진다.
    static func normalize(_ value: String) throws -> String {
        for scalar in value.unicodeScalars where scalar == "/"
            || scalar == "\\"
            || scalar.value <= 31
            || scalar.value == 127
        {
            throw SyncV2ContractError.storageNameInvalid
        }

        // NFKC로 폭을 맞추고, 대소문자를 접고, 접은 결과를 다시 NFKC로 맞춘다.
        // 마지막 NFKC가 없으면 접는 과정에서 생긴 분해형이 남아 Windows와
        // 다른 키가 된다.
        //
        // 접기는 Foundation에 맡기지 않고 동결 표를 쓴다.
        // `folding(options: [.caseInsensitive])`는 Unicode default case folding이
        // 아니라서, 전 코드포인트 실측에서 베이스라인 안쪽 181개가 서버와 다른
        // 키를 냈다. 자세한 것은 `SyncV2UnicodeCasefold`에 적어 두었다.
        var normalized = value.precomposedStringWithCompatibilityMapping
        normalized = SyncV2UnicodeCasefold.apply(normalized)
        normalized = normalized.precomposedStringWithCompatibilityMapping

        // 끝의 공백과 마침표는 저장 매체가 조용히 잘라내는 곳이 있어 미리 뗀다.
        while let last = normalized.last, last == " " || last == "." {
            normalized.removeLast()
        }

        if normalized.isEmpty || normalized == "." || normalized == ".." {
            throw SyncV2ContractError.storageNameInvalid
        }

        let basename = normalized
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? normalized
        if reservedBasenames.contains(basename) {
            throw SyncV2ContractError.storageNameReserved
        }
        return normalized
    }

    /// 정규화 결과의 UTF-8을 16진수로 적는다. 벡터 대조에 쓴다.
    static func utf8Hex(_ normalized: String) -> String {
        Array(normalized.utf8).map { String(format: "%02x", $0) }.joined()
    }

    /// 이 구현이 계약(동결된 Unicode 15.0.0)과 아직 다른 키를 내는 스칼라 40개다.
    /// 2026-08-13 전 코드포인트 실측이며 iPadOS 26.5와 macOS 26.5.2가 같은
    /// 값을 냈다.
    ///
    /// 접기를 `SyncV2UnicodeCasefold`로 옮기기 전에는 276개였다. 그중 181개는
    /// 베이스라인(Unicode 14.0.0 할당표) **안쪽**이라 미할당 거부 규칙으로는
    /// 걸러지지 않는 것들이었다 — Cherokee 172개와 Cyrillic U+1C80..U+1C88
    /// 9개. 접기가 동결 표로 바뀌면서 그 181개와, 바깥쪽 95개 중 55개가 함께
    /// 사라졌다. 전부 접기 단계에서 갈리던 것이었기 때문이다.
    ///
    /// 남은 40개는 접기가 아니라 **NFKC 단계**에서 갈린다. Foundation의 NFKC가
    /// 런타임 판(실측 Unicode 17.0.0)을 따르는데, 이 스칼라들은 Unicode 15.0.0
    /// 시점에 미할당이라 계약 쪽에서는 아무 매핑도 받지 못한다. 전부 베이스라인
    /// **바깥**이므로 "베이스라인에 없는 스칼라를 거부한다"는 규칙이 들어오면
    /// 그때 닫힌다.
    ///
    /// - Important: **이 목록은 완전하지 않다.** 스칼라 하나를 단독으로 넣었을
    ///   때 갈리는 것만 담는다. 상위면 스칼라 바로 뒤에 결합문자가 오면
    ///   Foundation의 NFKC가 코드포인트를 16비트로 잘라 버리는데
    ///   (U+10041 U+0301 -> U+00C1), 그 입력은 여기 걸리지 않는다. 여기 없는
    ///   문자만 썼다고 안전하지 않다는 뜻이라, 이 목록은 게이트로 쓸 수 없다.
    ///   그 결함은 배열에 대한 규칙으로 따로 막아야 한다.
    static let divergentScalars: [ClosedRange<UInt32>] = [
        0xA7F1...0xA7F1,
        0x16D68...0x16D6A,
        0x1CCD6...0x1CCF9,
    ]

    /// 이름이 계약과 다르게 정규화되는 문자를 품고 있는지 본다. 쓰기를 막지
    /// 않고 진단에만 쓴다.
    ///
    /// - Important: `divergentScalars`가 완전하지 않으므로 `false`는 안전하다는
    ///   뜻이 아니다. 위 주석을 보라.
    static func containsContractDivergentScalar(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            divergentScalars.contains { $0.contains(scalar.value) }
        }
    }
}

// MARK: - 작품 동기화 모드

/// 작품이 어느 규약으로 쓰이고 있는지다. 승격은 한 방향이고 클라이언트가
/// 임의로 올리지 않는다.
enum SyncV2ProjectSyncMode: String, Codable, Equatable, Sendable {
    case legacy = "LEGACY"
    case migrating = "MIGRATING"
    case idBased = "ID_BASED"
}

extension SyncV2Contract {
    /// 모드와 이관 세대의 짝이 성립하는지 본다. `LEGACY`는 세대가 0이어야 하고
    /// 나머지는 1 이상이어야 한다. 어긋난 조합은 낡은 이관 정보를 들고 있다는
    /// 뜻이라 그대로 쓰면 남의 세대에 덮어쓴다.
    static func isValidModeEpoch(
        _ mode: SyncV2ProjectSyncMode,
        _ migrationEpoch: Int
    ) -> Bool {
        switch mode {
        case .legacy: return migrationEpoch == 0
        case .migrating, .idBased: return migrationEpoch >= 1
        }
    }

    /// 쓰기 전에 서버가 우리와 같은 계약을 말하는지 확인한다.
    ///
    /// 하나라도 어긋나면 쓰지 않는다. 추측해서 진행하면 반쯤 적용된 구조가
    /// 남고, 그건 되돌릴 방법이 없다.
    static func requireServerCompatibility(
        projectSyncMode: SyncV2ProjectSyncMode,
        migrationEpoch: Int,
        serverProtocolVersion: Int,
        serverContractSHA256: String,
        serverCapabilities: some Sequence<String>
    ) throws {
        guard isValidModeEpoch(projectSyncMode, migrationEpoch) else {
            throw SyncV2ContractError.staleMigrationEpoch
        }
        guard serverProtocolVersion >= syncProtocolVersion else {
            throw SyncV2ContractError.protocolTooOld
        }
        guard serverContractSHA256 == canonicalSHA256 else {
            throw SyncV2ContractError.contractDigestMismatch
        }
        guard requiredServerCapabilities.isSubset(of: Set(serverCapabilities)) else {
            throw SyncV2ContractError.capabilityMismatch
        }
    }
}

// MARK: - 요청

/// 계약이 정한 개체 종류다.
enum SyncV2EntityKind: String, Equatable, Sendable {
    case project, folder, document
    case treeOrder = "tree_order"
    case trashPurge = "trash_purge"
}

/// 계약이 정한 의도 종류다.
enum SyncV2IntentKind: String, Equatable, Sendable {
    case ensure, create, update, rename, move, delete, restore, reorder, migrate
}

/// 문서 커밋이 쓸 수 있는 의도만 따로 좁힌 것이다.
enum SyncV2DocumentIntentKind: String, Equatable, Sendable {
    case create, update, delete, restore
}

/// 구조 배치에 담을 하나의 의도다. 순서가 곧 계약이라 배열에 넣은 차례대로
/// `sequence`를 받는다.
struct SyncV2StructureIntent: Equatable, Sendable {
    let entityKind: SyncV2EntityKind
    let entityID: UUID
    let intentKind: SyncV2IntentKind
    let baseRevision: Int
    let payload: SyncV2JSON
    let operationID: UUID
    let supersedesOperationID: UUID?

    init(
        entityKind: SyncV2EntityKind,
        entityID: UUID,
        intentKind: SyncV2IntentKind,
        baseRevision: Int = 0,
        payload: SyncV2JSON,
        operationID: UUID = UUID(),
        supersedesOperationID: UUID? = nil
    ) {
        self.entityKind = entityKind
        self.entityID = entityID
        self.intentKind = intentKind
        self.baseRevision = baseRevision
        self.payload = payload
        self.operationID = operationID
        self.supersedesOperationID = supersedesOperationID
    }
}

/// 서버로 보낼 요청이다. 응답을 검증하려면 보낸 요청이 필요해 함께 들고 있는다.
struct SyncV2ContractRequest: Equatable, Sendable {
    let json: SyncV2JSON
    let batchID: UUID
    let batchPayloadSHA256: String
    let orderedIntents: [SyncV2JSON]
}

extension SyncV2Contract {
    /// UUID를 계약이 쓰는 소문자 표기로 적는다. Swift 기본 표기는 대문자라
    /// 그대로 쓰면 다이제스트가 갈린다.
    static func canonicalUUID(_ value: UUID) -> String {
        value.uuidString.lowercased()
    }

    /// batch 하나에 실리는 불변 계약 메타데이터 8개 필드다. 만든 뒤에는 절대
    /// 바꾸지 않으며, 재시도는 같은 batch_id로 다시 보낸다.
    private static func batchMetadata(
        batchID: UUID,
        writerDeviceID: UUID,
        clientBuildID: String,
        batchPayloadSHA256: String
    ) -> SyncV2JSON {
        .object([
            "batch_id": .string(canonicalUUID(batchID)),
            "writer_device_id": .string(canonicalUUID(writerDeviceID)),
            "client_build_id": .string(clientBuildID),
            "sync_protocol_version": .int(syncProtocolVersion),
            "contract_version": .string(version),
            "canonical_contract_sha256": .string(canonicalSHA256),
            "client_capabilities": .array(clientCapabilities.map { .string($0) }),
            "batch_payload_sha256": .string(batchPayloadSHA256),
        ])
    }

    /// 연속된 구조 변경을 하나의 원자 커밋으로 묶는다.
    ///
    /// 빠른 연속 이름 변경이 이 길로 간다. 부분 적용이 없으므로 여섯 번 바꾼
    /// 것이 셋만 반영되는 일이 생기지 않는다.
    static func buildAtomicStructureRequest(
        projectID: UUID,
        projectSyncMode: SyncV2ProjectSyncMode,
        migrationEpoch: Int,
        writerDeviceID: UUID,
        orderedIntents: [SyncV2StructureIntent],
        batchID: UUID = UUID(),
        clientBuildID: String = SyncV2Contract.clientBuildID
    ) throws -> SyncV2ContractRequest {
        guard isValidModeEpoch(projectSyncMode, migrationEpoch) else {
            throw SyncV2ContractError.invalidArgument
        }
        guard !orderedIntents.isEmpty else {
            throw SyncV2ContractError.invalidArgument
        }

        var intents: [SyncV2JSON] = []
        for (index, source) in orderedIntents.enumerated() {
            guard source.baseRevision >= 0 else {
                throw SyncV2ContractError.invalidArgument
            }
            guard let payloadFields = source.payload.objectValue else {
                throw SyncV2ContractError.invalidArgument
            }
            // 이름이 실려 있으면 보내기 전에 규칙 위반을 걸러 낸다. 값 자체는
            // 원본을 그대로 보낸다. 정규화 결과는 충돌 판정에만 쓰인다.
            if let name = payloadFields["name"]?.stringValue {
                _ = try SyncV2StorageName.normalize(name)
            }

            var intent: [String: SyncV2JSON] = [
                "sequence": .int(index + 1),
                "operation_id": .string(canonicalUUID(source.operationID)),
                "batch_id": .string(canonicalUUID(batchID)),
                "entity_kind": .string(source.entityKind.rawValue),
                "entity_id": .string(canonicalUUID(source.entityID)),
                "intent_kind": .string(source.intentKind.rawValue),
                "base_revision": .int(source.baseRevision),
                "payload_sha256": .string(try source.payload.sha256Hex()),
                "payload": source.payload,
            ]
            if let supersedes = source.supersedesOperationID {
                intent["supersedes_operation_id"] = .string(canonicalUUID(supersedes))
            }
            intents.append(.object(intent))
        }

        let batchPayloadSHA256 = try SyncV2JSON.array(intents).sha256Hex()
        let json = SyncV2JSON.object([
            "kind": .string("atomic_structure_commit_request"),
            "project_id": .string(canonicalUUID(projectID)),
            "project_sync_mode": .string(projectSyncMode.rawValue),
            "migration_epoch": .int(migrationEpoch),
            "batch": batchMetadata(
                batchID: batchID,
                writerDeviceID: writerDeviceID,
                clientBuildID: clientBuildID,
                batchPayloadSHA256: batchPayloadSHA256
            ),
            "ordered_intents": .array(intents),
        ])
        return SyncV2ContractRequest(
            json: json,
            batchID: batchID,
            batchPayloadSHA256: batchPayloadSHA256,
            orderedIntents: intents
        )
    }

    /// 문서 본문 하나를 커밋한다. 구조 배치와 달리 의도는 항상 하나다.
    static func buildDocumentCommitRequest(
        projectID: UUID,
        projectSyncMode: SyncV2ProjectSyncMode,
        migrationEpoch: Int,
        writerDeviceID: UUID,
        documentID: UUID,
        intentKind: SyncV2DocumentIntentKind,
        baseRevision: Int,
        parentFolderID: UUID?,
        name: String,
        content: String,
        isDeleted: Bool,
        structureRevision: Int,
        operationID: UUID = UUID(),
        batchID: UUID = UUID(),
        supersedesOperationID: UUID? = nil,
        clientBuildID: String = SyncV2Contract.clientBuildID
    ) throws -> SyncV2ContractRequest {
        guard isValidModeEpoch(projectSyncMode, migrationEpoch) else {
            throw SyncV2ContractError.invalidArgument
        }
        let body = Data(content.utf8)
        guard body.count <= 10_485_760 else {
            throw SyncV2ContractError.invalidArgument
        }
        guard baseRevision >= 0, structureRevision >= 1 else {
            throw SyncV2ContractError.invalidArgument
        }
        // 새로 만드는 문서는 기준 리비전이 0이어야 하고, 이미 있는 문서는 1
        // 이상이어야 한다. 지운다는 의도와 지워짐 표시도 반드시 같이 간다.
        if (intentKind == .create && baseRevision != 0)
            || (intentKind != .create && baseRevision < 1)
            || ((intentKind == .delete) != isDeleted)
        {
            throw SyncV2ContractError.invalidArgument
        }
        _ = try SyncV2StorageName.normalize(name)

        let contentDigest = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        let payload = SyncV2JSON.object([
            "parent_folder_id": parentFolderID.map { .string(canonicalUUID($0)) } ?? .null,
            "name": .string(name),
            "content": .string(content),
            "content_sha256": .string(contentDigest),
            "content_byte_count": .int(body.count),
            "is_deleted": .bool(isDeleted),
            "structure_revision": .int(structureRevision),
        ])

        var intent: [String: SyncV2JSON] = [
            "sequence": .int(1),
            "operation_id": .string(canonicalUUID(operationID)),
            "batch_id": .string(canonicalUUID(batchID)),
            "entity_kind": .string(SyncV2EntityKind.document.rawValue),
            "document_id": .string(canonicalUUID(documentID)),
            "intent_kind": .string(intentKind.rawValue),
            "base_revision": .int(baseRevision),
            "payload_sha256": .string(try payload.sha256Hex()),
            "payload": payload,
        ]
        if let supersedes = supersedesOperationID {
            intent["supersedes_operation_id"] = .string(canonicalUUID(supersedes))
        }

        let intents: [SyncV2JSON] = [.object(intent)]
        let batchPayloadSHA256 = try SyncV2JSON.array(intents).sha256Hex()
        let json = SyncV2JSON.object([
            "kind": .string("document_commit_request"),
            "project_id": .string(canonicalUUID(projectID)),
            "project_sync_mode": .string(projectSyncMode.rawValue),
            "migration_epoch": .int(migrationEpoch),
            "batch": batchMetadata(
                batchID: batchID,
                writerDeviceID: writerDeviceID,
                clientBuildID: clientBuildID,
                batchPayloadSHA256: batchPayloadSHA256
            ),
            "ordered_intents": .array(intents),
        ])
        return SyncV2ContractRequest(
            json: json,
            batchID: batchID,
            batchPayloadSHA256: batchPayloadSHA256,
            orderedIntents: intents
        )
    }
}

// MARK: - 응답 검증

// 커밋 결과(`committed` / `replayed`)는 `SyncV2Client`가 이미 정의한
// `SyncV2CommitStatus`를 그대로 쓴다. `replayed`는 같은 operation을 다시
// 보냈을 때 오는 멱등 응답이라 정상 성공으로 수렴시킨다.

extension SyncV2Contract {
    /// 계약 오류 코드 모양인지 본다. `^[A-Z][A-Z0-9_]+$`와 같은 판정이다.
    static func isErrorCode(_ code: String) -> Bool {
        let scalars = Array(code.unicodeScalars)
        guard scalars.count >= 2, ("A"..."Z").contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    /// 응답이 우리가 보낸 배치의 것인지, 그리고 온전한지 확인한다.
    ///
    /// 리비전이 없는 응답을 성공으로 처리하지 않는다. 그걸 성공이라 믿으면
    /// 다음 편집이 잘못된 기준 위에 쌓인다.
    @discardableResult
    static func validateAtomicStructureResponse(
        request: SyncV2ContractRequest,
        response: SyncV2JSON
    ) throws -> SyncV2CommitStatus {
        guard let fields = response.objectValue else {
            throw SyncV2ContractError.invalidAtomicResponse()
        }
        guard fields["batch_id"]?.stringValue == canonicalUUID(request.batchID) else {
            throw SyncV2ContractError.invalidAtomicResponse("batch_id mismatch")
        }
        guard fields["batch_payload_sha256"]?.stringValue == request.batchPayloadSHA256 else {
            throw SyncV2ContractError.invalidAtomicResponse("batch digest mismatch")
        }

        switch fields["kind"]?.stringValue {
        case "atomic_structure_commit_success":
            guard Set(fields.keys) == [
                "kind", "batch_id", "batch_payload_sha256", "status", "applied", "results",
            ] else {
                throw SyncV2ContractError.invalidAtomicResponse()
            }
            guard let status = fields["status"]?.stringValue.flatMap(SyncV2CommitStatus.init),
                  fields["applied"] == .bool(true)
            else {
                throw SyncV2ContractError.invalidAtomicResponse()
            }
            guard let results = fields["results"]?.arrayValue,
                  results.count == request.orderedIntents.count
            else {
                throw SyncV2ContractError.partialBatchResponse
            }
            for (intent, result) in zip(request.orderedIntents, results) {
                guard let result = result.objectValue,
                      Set(result.keys) == ["sequence", "operation_id", "entity_id", "result_revision"]
                else {
                    throw SyncV2ContractError.invalidAtomicResponse()
                }
                let intentFields = intent.objectValue ?? [:]
                guard result["sequence"] == intentFields["sequence"],
                      result["operation_id"] == intentFields["operation_id"],
                      result["entity_id"] == intentFields["entity_id"],
                      let revision = result["result_revision"]?.intValue,
                      revision >= 1
                else {
                    throw SyncV2ContractError.partialBatchResponse
                }
            }
            return status

        case "atomic_structure_commit_failure":
            try validateFailureEnvelope(
                fields: fields,
                intentCount: request.orderedIntents.count,
                makeError: SyncV2ContractError.invalidAtomicResponse
            )
            throw failureError(from: fields)

        default:
            throw SyncV2ContractError.invalidAtomicResponse()
        }
    }

    /// 문서 응답은 되돌아온 값이 우리가 보낸 payload와 완전히 같은지까지 본다.
    /// 서버가 이름이나 부모를 조용히 바꿔 놓았다면 로컬에 반영하기 전에 안다.
    @discardableResult
    static func validateDocumentCommitResponse(
        request: SyncV2ContractRequest,
        response: SyncV2JSON
    ) throws -> SyncV2CommitStatus {
        guard let fields = response.objectValue,
              request.orderedIntents.count == 1,
              fields["batch_id"]?.stringValue == canonicalUUID(request.batchID),
              fields["batch_payload_sha256"]?.stringValue == request.batchPayloadSHA256
        else {
            throw SyncV2ContractError.invalidDocumentResponse()
        }

        switch fields["kind"]?.stringValue {
        case "document_commit_success":
            guard Set(fields.keys) == [
                "kind", "batch_id", "batch_payload_sha256", "status", "applied", "results",
            ] else {
                throw SyncV2ContractError.invalidDocumentResponse()
            }
            guard let status = fields["status"]?.stringValue.flatMap(SyncV2CommitStatus.init),
                  fields["applied"] == .bool(true)
            else {
                throw SyncV2ContractError.invalidDocumentResponse()
            }
            guard let results = fields["results"]?.arrayValue, results.count == 1 else {
                throw SyncV2ContractError.partialBatchResponse
            }
            guard let result = results[0].objectValue,
                  Set(result.keys) == [
                      "sequence", "operation_id", "document_id", "result_revision",
                      "structure_revision", "parent_folder_id", "name", "content_sha256",
                      "content_byte_count", "is_deleted",
                  ]
            else {
                throw SyncV2ContractError.invalidDocumentResponse()
            }
            let intentFields = request.orderedIntents[0].objectValue ?? [:]
            let payload = intentFields["payload"]?.objectValue ?? [:]
            guard result["sequence"] == .int(1),
                  result["operation_id"] == intentFields["operation_id"],
                  result["document_id"] == intentFields["document_id"],
                  let revision = result["result_revision"]?.intValue,
                  revision >= 1,
                  result["structure_revision"] == payload["structure_revision"],
                  result["parent_folder_id"] == payload["parent_folder_id"],
                  result["name"] == payload["name"],
                  result["content_sha256"] == payload["content_sha256"],
                  result["content_byte_count"] == payload["content_byte_count"],
                  result["is_deleted"] == payload["is_deleted"]
            else {
                throw SyncV2ContractError.partialBatchResponse
            }
            return status

        case "document_commit_failure":
            try validateFailureEnvelope(
                fields: fields,
                intentCount: 1,
                makeError: SyncV2ContractError.invalidDocumentResponse
            )
            throw failureError(from: fields)

        default:
            throw SyncV2ContractError.invalidDocumentResponse()
        }
    }

    /// 실패 응답도 모양이 정해져 있다. 모양이 틀린 실패는 실패로도 믿지 않는다.
    private static func validateFailureEnvelope(
        fields: [String: SyncV2JSON],
        intentCount: Int,
        makeError: (String?) -> SyncV2ContractError
    ) throws {
        guard Set(fields.keys) == [
            "kind", "batch_id", "batch_payload_sha256", "status", "applied", "error", "results",
        ],
            fields["status"] == .string("rejected"),
            fields["applied"] == .bool(false),
            fields["results"] == .array([]),
            let error = fields["error"]?.objectValue,
            Set(error.keys) == ["code", "message", "failed_sequence"],
            let code = error["code"]?.stringValue,
            isErrorCode(code),
            let message = error["message"]?.stringValue,
            !message.isEmpty
        else {
            throw makeError(nil)
        }
        switch error["failed_sequence"] {
        case .null, .none:
            break
        case let .int(sequence) where (1...intentCount).contains(sequence):
            break
        default:
            throw makeError(nil)
        }
    }

    /// 실패 응답이 실어 보낸 계약 오류 코드를 그대로 올린다.
    private static func failureError(from fields: [String: SyncV2JSON]) -> SyncV2ContractError {
        let error = fields["error"]?.objectValue ?? [:]
        return SyncV2ContractError(
            error["code"]?.stringValue ?? "INVALID_ARGUMENT",
            error["message"]?.stringValue
        )
    }
}

// MARK: - 이벤트에서 파생하는 작업 상태

/// 작업에 일어난 일이다. 덧붙이기만 하고 지우지 않는다.
enum SyncV2OperationEventType: String, Equatable, Sendable {
    case enqueued
    case dispatchStarted = "dispatch_started"
    case retryScheduled = "retry_scheduled"
    case blocked
    case conflictDetected = "conflict_detected"
    case committed
    case replayed
    case cancelRequested = "cancel_requested"
    case superseded

    /// 이 일이 일어난 뒤의 상태다.
    var state: SyncV2OperationStatus {
        switch self {
        case .enqueued: return .pending
        case .dispatchStarted: return .inflight
        case .retryScheduled: return .retryWait
        case .blocked: return .blocked
        case .conflictDetected: return .conflict
        case .committed, .replayed: return .completed
        case .cancelRequested, .superseded: return .cancelled
        }
    }
}

/// 취소 요청의 결과다. 이미 취소된 작업에 다시 요청해도 오류가 아니다.
enum SyncV2OperationCancelOutcome: Equatable, Sendable {
    case cancelled(eventID: UUID)
    /// 같은 요청이 다시 왔다. 사건 식별자가 같으면 그 값을, 이미 다른 요청으로
    /// 취소돼 있었으면 nil을 준다.
    case alreadyCancelled(eventID: UUID?)
}

/// 사건에서 계산한 상태와 저장된 status 칸이 어긋난 작업이다.
///
/// 읽는 쪽을 사건 계산으로 옮기기 전에 이 목록이 비어 있어야 한다.
struct SyncV2OperationStateDivergence: Equatable, Sendable {
    let operationID: String
    /// status 칸에 적힌 값이다. 알 수 없는 문자열이면 nil이다.
    let storedStatus: SyncV2OperationStatus?
    /// 사건 기록에서 계산한 값이다. 기록이 없거나 중간이 비면 nil이다.
    let derivedStatus: SyncV2OperationStatus?
}

/// 기록된 사건 하나다.
struct SyncV2OperationEvent: Equatable, Sendable {
    let sequence: Int
    let type: SyncV2OperationEventType
    let errorCode: String?

    init(sequence: Int, type: SyncV2OperationEventType, errorCode: String? = nil) {
        self.sequence = sequence
        self.type = type
        self.errorCode = errorCode
    }
}

/// 상태를 따로 저장하지 않고 사건 기록에서 계산한다.
///
/// Windows는 상태 칸을 직접 고쳐 쓰다가, 끝난 작업이 `pending`으로 남아 대기
/// 건수가 영원히 줄지 않는 버그를 냈다. 사건에서 계산하면 그런 어긋남이 생길
/// 자리가 없다.
enum SyncV2OperationStateDerivation {
    /// 사건 기록에서 현재 상태를 계산한다.
    static func state(from events: [SyncV2OperationEvent]) throws -> SyncV2OperationStatus {
        guard let last = events.last else {
            throw SyncV2ContractError("INVALID_ARGUMENT", "operation has no append-only event history")
        }
        for (index, event) in events.enumerated() where event.sequence != index + 1 {
            throw SyncV2ContractError("INVALID_ARGUMENT", "operation event sequence is not contiguous")
        }
        return last.type.state
    }

    /// 끝난 상태다. 여기 닿으면 더 붙이지 않는다.
    static let terminalStates: Set<SyncV2OperationStatus> = [.completed, .cancelled]

    /// 사건을 하나 더 붙일 수 있는지 본다. 이미 끝난 작업에 덧붙이면 완료된
    /// 작업이 되살아나 다시 발송된다.
    static func requireAppendable(to events: [SyncV2OperationEvent]) throws {
        guard let last = events.last else { return }
        if terminalStates.contains(last.type.state) {
            throw SyncV2ContractError.operationTerminal
        }
    }

    /// 가장 최근 오류다.
    ///
    /// 성공 사건에는 오류 코드가 없으므로, 기록 전체에서 마지막 오류를 그냥
    /// 집으면 성공한 뒤에도 옛 오류가 영원히 이긴다. 그래서 이미 끝난 작업은
    /// 오류가 없는 것으로 본다.
    static func latestErrorCode(from events: [SyncV2OperationEvent]) -> String? {
        guard let last = events.last, !terminalStates.contains(last.type.state) else {
            return nil
        }
        return events.reversed().first { $0.errorCode?.isEmpty == false }?.errorCode
    }
}
