import Foundation
import XCTest
@testable import WriterPad

/// 계약 0.2.0을 Windows와 똑같이 계산하는지 확인한다.
///
/// 기대값은 짐작한 것이 아니라 Windows의 `sync_contract.py`를 실제로 돌려
/// 받아 적은 것이다. 두 클라이언트가 같은 작품을 쓰므로, 한쪽이 다른 바이트를
/// 내면 서버 다이제스트 검사에서 막히거나 더 나쁘게는 서로 다른 것을 같다고
/// 착각한다.
final class SyncV2ContractTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let deviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let documentID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let folderID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let operationID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let batchID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

    // MARK: - 고정값

    /// pin 값이 흐트러지면 서버가 모든 쓰기를 거부한다. 실수로 바꾸는 일을
    /// 막으려고 못 박아 둔다.
    func testContractPinMatchesLockFile() {
        XCTAssertEqual(SyncV2Contract.version, "0.2.0")
        XCTAssertEqual(
            SyncV2Contract.canonicalSHA256,
            "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"
        )
        XCTAssertEqual(SyncV2Contract.canonicalByteCount, 23_256)
        XCTAssertEqual(
            SyncV2Contract.gitCommit,
            "fcd99b7098b9a04bd93c585d89b16588aa482530"
        )
        XCTAssertEqual(SyncV2Contract.syncProtocolVersion, 3)
    }

    /// 선언하는 능력이 하나라도 빠지거나 늘면 서버가 배치를 거부한다.
    func testCapabilitySetsMatchContract() {
        XCTAssertEqual(SyncV2Contract.clientCapabilities, [
            "folders_authoritative",
            "tree_order_ids",
            "tombstones",
            "immutable_batch_contract_metadata",
            "operation_attempt_history",
            "operation_state_events",
            "storage_name_v1",
            "document_commit_v1",
        ])
        XCTAssertEqual(SyncV2Contract.requiredServerCapabilities, [
            "atomic_structure_commit",
            "contract_allowlist_validation",
            "project_mode_migration_lock",
            "folder_tombstones",
            "id_tree_validation",
            "legacy_epoch_zero_adapter",
            "storage_name_v1",
            "document_commit_v1",
        ])
    }

    // MARK: - 정규 JSON

    /// Python `json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=False)`와
    /// 같은 바이트를 내야 한다. 기대 다이제스트는 Windows에서 뽑았다.
    func testCanonicalJSONMatchesWindows() throws {
        let cases: [(SyncV2JSON, String, String)] = [
            (
                .object(["a": .string("따옴표\"역슬래시\\줄바꿈\n탭\t")]),
                #"{"a":"따옴표\"역슬래시\\줄바꿈\n탭\t"}"#,
                "64e3b9c23f5e9a2a4b2d3fc592c6660660a20eb7bc8d349e475322a3bcfcf311"
            ),
            (
                .object(["z": .int(1), "a": .int(2), "_m": .int(3)]),
                #"{"_m":3,"a":2,"z":1}"#,
                "b0e7dc7427539a499fb5954996635d926fbd0c3b85a30eec196be0d107cf247e"
            ),
            (
                .object(["k": .array([.int(1), .int(-2), .int(0)])]),
                #"{"k":[1,-2,0]}"#,
                "fc3c541f8f9af6dd77eb2254bcbbb49f4b7d9e23e15e58c2886aa3cdc12731c8"
            ),
            (
                .object(["n": .null, "t": .bool(true), "f": .bool(false)]),
                #"{"f":false,"n":null,"t":true}"#,
                "22e00dc2f7b01420f940fbdbfbdf34fa0667cc6500186495023ba37722cbd05e"
            ),
        ]
        for (value, expectedJSON, expectedDigest) in cases {
            XCTAssertEqual(try value.canonicalJSON(), expectedJSON)
            XCTAssertEqual(try value.sha256Hex(), expectedDigest)
        }
    }

    /// 한글은 그대로 실어야 한다. escape하면 Windows와 다른 바이트가 된다.
    func testCanonicalJSONKeepsNonASCIILiteral() throws {
        XCTAssertEqual(
            try SyncV2JSON.object(["name": .string("첫 눈")]).canonicalJSON(),
            #"{"name":"첫 눈"}"#
        )
    }

    /// 계약이 허용하지 않는 키는 다이제스트를 만들기 전에 막는다. 정렬 순서가
    /// 구현마다 갈릴 여지를 남기지 않으려는 제약이다.
    func testCanonicalJSONRejectsNonContractKey() {
        for key in ["가나", "with-dash", "9lead", "", "with space"] {
            XCTAssertThrowsError(
                try SyncV2JSON.object([key: .int(1)]).canonicalJSON()
            ) { error in
                XCTAssertEqual((error as? SyncV2ContractError)?.code, "INVALID_ARGUMENT")
            }
        }
    }

    /// 실수는 자릿수 표현이 언어마다 달라 다이제스트를 갈라놓는다. 응답에
    /// 섞여 들어와도 거부한다.
    func testJSONFromServerRejectsFractionalNumber() {
        XCTAssertThrowsError(try SyncV2JSON(jsonObject: ["a": 1.5])) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "INVALID_ARGUMENT")
        }
    }

    /// 서버가 보낸 참·거짓을 숫자로 오해하면 `applied` 검사가 무의미해진다.
    func testJSONFromServerKeepsBooleanDistinctFromInteger() throws {
        XCTAssertEqual(try SyncV2JSON(jsonObject: true), .bool(true))
        XCTAssertEqual(try SyncV2JSON(jsonObject: 1), .int(1))
        XCTAssertNotEqual(try SyncV2JSON(jsonObject: true), .int(1))
    }

    // MARK: - storage-name 벡터

    /// `sync-contract/conformance_vectors/storage-name-v1.json`의 벡터 15개다.
    private struct StorageNameVector {
        let id: String
        let input: String
        let normalized: String?
        let utf8Hex: String?
        let errorCode: String?
    }

    private let storageNameVectors: [StorageNameVector] = [
        .init(id: "SN-001", input: "R\u{00E9}sum\u{00E9}", normalized: "r\u{00E9}sum\u{00E9}", utf8Hex: "72c3a973756dc3a9", errorCode: nil),
        .init(id: "SN-002", input: "Re\u{0301}sume\u{0301}", normalized: "r\u{00E9}sum\u{00E9}", utf8Hex: "72c3a973756dc3a9", errorCode: nil),
        .init(id: "SN-003", input: "FILE.TXT", normalized: "file.txt", utf8Hex: "66696c652e747874", errorCode: nil),
        .init(id: "SN-004", input: "File. ", normalized: "file", utf8Hex: "66696c65", errorCode: nil),
        .init(id: "SN-005", input: "\u{D3F4}\u{B354}", normalized: "\u{D3F4}\u{B354}", utf8Hex: "ed8fb4eb8d94", errorCode: nil),
        .init(id: "SN-006", input: "\u{0130}", normalized: "i\u{0307}", utf8Hex: "69cc87", errorCode: nil),
        .init(id: "SN-007", input: "Stra\u{00DF}e", normalized: "strasse", utf8Hex: "73747261737365", errorCode: nil),
        .init(id: "SN-008", input: " leading", normalized: " leading", utf8Hex: "206c656164696e67", errorCode: nil),
        .init(id: "SN-009", input: "A\u{00A0}B", normalized: "a b", utf8Hex: "612062", errorCode: nil),
        .init(id: "SN-010", input: "\u{FF21}\u{FF22}\u{FF23}", normalized: "abc", utf8Hex: "616263", errorCode: nil),
        .init(id: "SN-011", input: "CON.txt", normalized: nil, utf8Hex: nil, errorCode: "STORAGE_NAME_RESERVED"),
        .init(id: "SN-012", input: "folder/name", normalized: nil, utf8Hex: nil, errorCode: "STORAGE_NAME_INVALID"),
        .init(id: "SN-013", input: "folder\\name", normalized: nil, utf8Hex: nil, errorCode: "STORAGE_NAME_INVALID"),
        .init(id: "SN-014", input: ". ", normalized: nil, utf8Hex: nil, errorCode: "STORAGE_NAME_INVALID"),
        .init(id: "SN-015", input: "", normalized: nil, utf8Hex: nil, errorCode: "STORAGE_NAME_INVALID"),
    ]

    /// 계약 벡터 15개를 전부 통과해야 한다.
    func testStorageNameConformanceVectors() {
        for vector in storageNameVectors {
            if let expected = vector.normalized {
                do {
                    let actual = try SyncV2StorageName.normalize(vector.input)
                    XCTAssertEqual(actual, expected, vector.id)
                    XCTAssertEqual(
                        SyncV2StorageName.utf8Hex(actual),
                        vector.utf8Hex,
                        vector.id
                    )
                } catch {
                    XCTFail("\(vector.id): 통과해야 하는데 \(error)")
                }
            } else {
                XCTAssertThrowsError(
                    try SyncV2StorageName.normalize(vector.input),
                    vector.id
                ) { error in
                    XCTAssertEqual(
                        (error as? SyncV2ContractError)?.code,
                        vector.errorCode,
                        vector.id
                    )
                }
            }
        }
    }

    /// 아이패드의 분해형 입력과 Windows의 결합형 입력이 같은 키로 수렴해야
    /// 한다. 아니면 같은 폴더를 서로 다른 것으로 보고 둘로 만든다.
    func testStorageNameConvergesAcrossNormalizationForms() throws {
        let decomposed = "\u{110B}\u{1167}\u{11AB}\u{1112}\u{1161}\u{11B7}"
        let composed = "\u{C5F0}\u{D568}"
        // Swift의 `==`는 정규 동치를 같다고 보므로 스칼라로 비교해야 두 입력이
        // 실제로 다른 바이트열임을 확인할 수 있다.
        XCTAssertNotEqual(
            Array(decomposed.unicodeScalars),
            Array(composed.unicodeScalars)
        )
        XCTAssertEqual(
            try SyncV2StorageName.normalize(decomposed),
            try SyncV2StorageName.normalize(composed)
        )
    }

    /// 제어문자와 DEL도 막아야 한다.
    func testStorageNameRejectsControlCharacters() {
        for scalar in [UnicodeScalar(0)!, UnicodeScalar(31)!, UnicodeScalar(127)!] {
            XCTAssertThrowsError(try SyncV2StorageName.normalize("a\(scalar)b")) { error in
                XCTAssertEqual((error as? SyncV2ContractError)?.code, "STORAGE_NAME_INVALID")
            }
        }
    }

    /// Windows 예약 이름은 확장자가 붙어도 막힌다.
    func testStorageNameRejectsReservedBasenames() {
        for name in ["con", "PRN", "aux.txt", "nul", "com1", "LPT9.md"] {
            XCTAssertThrowsError(try SyncV2StorageName.normalize(name), name) { error in
                XCTAssertEqual((error as? SyncV2ContractError)?.code, "STORAGE_NAME_RESERVED", name)
            }
        }
    }

    /// 동결 표가 서버·Windows와 같은 표인지 본다.
    ///
    /// 세 구현이 같은 키를 내려면 같은 표를 봐야 한다. 정규형 SHA-256 하나로
    /// 확인한다. 이 값이 흔들리면 표가 어딘가에서 손상된 것이므로 개수만 맞춰
    /// 넘어가지 마라.
    func testFrozenCasefoldTableIsIntact() {
        XCTAssertEqual(SyncV2UnicodeCasefold.unicodeVersion, "15.0.0")
        XCTAssertEqual(SyncV2UnicodeCasefold.mappingCount, 1_530)
        XCTAssertEqual(SyncV2UnicodeCasefold.table.count, SyncV2UnicodeCasefold.mappingCount)
        XCTAssertEqual(
            SyncV2UnicodeCasefold.tableSHA256,
            "eac289d0d721c58867acb07af38d9a8e8ee374d328b33d93251ae6348e258439"
        )

        // 여러 스칼라로 접히는 항목도 제대로 풀렸는지 본다.
        XCTAssertEqual(SyncV2UnicodeCasefold.table[0x00DF], "ss")
        XCTAssertEqual(SyncV2UnicodeCasefold.table[0x0130], "i\u{0307}")
    }

    /// 접기를 동결 표로 옮긴 것이 베이스라인 안쪽 발산을 닫았는지 본다.
    ///
    /// 실측에서 베이스라인(Unicode 14.0.0 할당표) 안쪽 181개가 서버와 다른 키를
    /// 냈다. 전부 접기 단계에서 갈리던 것이라 여기서 사라져야 한다. 이 시험이
    /// 깨지면 접기가 다시 Foundation으로 돌아갔다는 뜻이다.
    func testFrozenCasefoldClosesInsideBaselineDivergence() throws {
        // Cherokee — 계약은 대문자 쪽으로 접는다. Foundation은 U+AB70을 냈다.
        XCTAssertEqual(try SyncV2StorageName.normalize("\u{13A0}"), "\u{13A0}")
        XCTAssertEqual(try SyncV2StorageName.normalize("\u{AB70}"), "\u{13A0}")
        XCTAssertEqual(try SyncV2StorageName.normalize("\u{13F8}"), "\u{13F0}")

        // Cyrillic — 계약은 U+1C80을 U+0432(в)로 접는다. Foundation은 접지 않아
        // 충돌을 놓쳤다. 이제 같은 키로 수렴해야 한다.
        XCTAssertEqual(
            try SyncV2StorageName.normalize("\u{1C80}"),
            try SyncV2StorageName.normalize("\u{0432}")
        )
        XCTAssertEqual(try SyncV2StorageName.normalize("\u{1C88}"), "\u{A64B}")

        for scalar in ["\u{13A0}", "\u{AB70}", "\u{13F8}", "\u{1C80}", "\u{1C88}"] {
            XCTAssertFalse(
                SyncV2StorageName.containsContractDivergentScalar(scalar),
                scalar
            )
        }
    }

    /// 남은 발산 목록이 실측한 구성 그대로인지 본다.
    ///
    /// 예전에는 이 자리에서 개수가 92인지만 셌다. 그 92는 스캔 결과가 아니라
    /// 손으로 적어 넣은 값이었고, 2026-08-13 전 코드포인트 실측으로 틀렸음이
    /// 드러났다(실제 276). 접기를 동결 표로 옮겨 236개가 닫히고 40개가 남았다.
    ///
    /// 이 시험이 깨지면 목록을 실측으로 다시 뽑고 저장소 뿌리의 측정 자료도
    /// 함께 갱신하라. 기대값만 숫자로 맞춰 넣지 마라.
    func testDivergentScalarsMatchMeasurement() {
        let total = SyncV2StorageName.divergentScalars.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 40)

        // 남은 것은 전부 NFKC 단계의 판 차이다. 베이스라인 바깥이라 미할당 거부
        // 규칙이 들어오면 닫힌다.
        XCTAssertTrue(SyncV2StorageName.containsContractDivergentScalar("\u{1CCD6}"))
        XCTAssertTrue(SyncV2StorageName.containsContractDivergentScalar("\u{16D68}"))

        // 접기로 닫힌 것은 더 이상 걸리지 않는다.
        XCTAssertFalse(SyncV2StorageName.containsContractDivergentScalar("\u{10D50}"))
        // 흔한 이름은 애초에 걸리지 않는다.
        XCTAssertFalse(SyncV2StorageName.containsContractDivergentScalar("첫 눈"))
        XCTAssertFalse(SyncV2StorageName.containsContractDivergentScalar("Résumé"))
    }

    // 계약 storage-name-v1 위반. 현재 동작을 기록만 한다.
    // Foundation NFKC를 동결 표 구현으로 갈아치우면 이 시험을 고치지 말고
    // 삭제하라. 계약을 지키는 쪽의 시험은 벡터 하네스가 맡는다.
    //
    /// 발산 목록이 게이트로 쓸 수 없다는 것을 못 박는다.
    ///
    /// 상위면 스칼라 뒤에 결합문자가 오면 Foundation의 NFKC가 코드포인트를
    /// 16비트로 잘라낸다. U+10041("𐁁")이 U+0041("A")로 읽혀 뒤따르는 U+0301과
    /// 결합해 버린다. 계약대로라면 두 스칼라가 그대로 남아야 한다.
    ///
    /// 그 입력은 `divergentScalars`의 어느 범위에도 걸리지 않는다. 목록을
    /// 통과했다고 안전하지 않다는 뜻이며, 이것이 목록을 진단용으로만 두는
    /// 이유다.
    func testSupplementaryPlaneNFKCTruncates_CONTRACT_VIOLATION_PINNED() throws {
        let name = "\u{10041}\u{0301}"
        XCTAssertFalse(SyncV2StorageName.containsContractDivergentScalar(name))

        let normalized = try SyncV2StorageName.normalize(name)
        XCTAssertEqual(normalized, "\u{00E1}")
        XCTAssertEqual(SyncV2StorageName.utf8Hex(normalized), "c3a1")
        // 서로 다른 두 이름이 같은 충돌 키로 수렴한다.
        XCTAssertEqual(normalized, try SyncV2StorageName.normalize("\u{00C1}"))
    }

    // MARK: - 서버 호환성

    private func requireCompatibility(
        mode: SyncV2ProjectSyncMode = .idBased,
        epoch: Int = 7,
        protocolVersion: Int = 3,
        digest: String = SyncV2Contract.canonicalSHA256,
        capabilities: Set<String> = SyncV2Contract.requiredServerCapabilities
    ) throws {
        try SyncV2Contract.requireServerCompatibility(
            projectSyncMode: mode,
            migrationEpoch: epoch,
            serverProtocolVersion: protocolVersion,
            serverContractSHA256: digest,
            serverCapabilities: capabilities
        )
    }

    func testServerCompatibilityAcceptsMatchingServer() {
        XCTAssertNoThrow(try requireCompatibility())
        XCTAssertNoThrow(try requireCompatibility(mode: .legacy, epoch: 0))
        // 서버가 우리보다 앞서 있는 것은 괜찮다.
        XCTAssertNoThrow(try requireCompatibility(protocolVersion: 4))
        XCTAssertNoThrow(
            try requireCompatibility(
                capabilities: SyncV2Contract.requiredServerCapabilities.union(["future_thing"])
            )
        )
    }

    /// 모드와 세대가 어긋나면 낡은 이관 정보를 들고 있다는 뜻이라 쓰지 않는다.
    func testServerCompatibilityRejectsStaleEpoch() {
        let bad: [(SyncV2ProjectSyncMode, Int)] = [
            (.legacy, 1), (.legacy, -1), (.migrating, 0), (.idBased, 0),
        ]
        for (mode, epoch) in bad {
            XCTAssertThrowsError(try requireCompatibility(mode: mode, epoch: epoch)) { error in
                XCTAssertEqual((error as? SyncV2ContractError)?.code, "STALE_MIGRATION_EPOCH")
            }
        }
    }

    func testServerCompatibilityFailsClosed() {
        XCTAssertThrowsError(try requireCompatibility(protocolVersion: 2)) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "PROTOCOL_TOO_OLD")
        }
        XCTAssertThrowsError(try requireCompatibility(digest: String(repeating: "0", count: 64))) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "CONTRACT_DIGEST_MISMATCH")
        }
        XCTAssertThrowsError(
            try requireCompatibility(
                capabilities: SyncV2Contract.requiredServerCapabilities.subtracting(["id_tree_validation"])
            )
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "CAPABILITY_MISMATCH")
        }
    }

    // MARK: - 문서 커밋 요청

    private func buildDocumentRequest(
        intentKind: SyncV2DocumentIntentKind = .update,
        baseRevision: Int = 4,
        isDeleted: Bool = false,
        structureRevision: Int = 2,
        name: String = "1장. 첫 눈",
        content: String = "눈이 내렸다.\n"
    ) throws -> SyncV2ContractRequest {
        try SyncV2Contract.buildDocumentCommitRequest(
            projectID: projectID,
            projectSyncMode: .idBased,
            migrationEpoch: 7,
            writerDeviceID: deviceID,
            documentID: documentID,
            intentKind: intentKind,
            baseRevision: baseRevision,
            parentFolderID: folderID,
            name: name,
            content: content,
            isDeleted: isDeleted,
            structureRevision: structureRevision,
            operationID: operationID,
            batchID: batchID
        )
    }

    /// Windows가 같은 입력으로 만든 다이제스트와 한 글자도 다르면 안 된다.
    func testDocumentCommitRequestMatchesWindowsDigests() throws {
        let request = try buildDocumentRequest()

        XCTAssertEqual(
            request.batchPayloadSHA256,
            "0be12774bf601eef2471c31e391cee73bed14bc7093a068ae625437b9bbe3853"
        )
        let intent = request.orderedIntents[0].objectValue!
        XCTAssertEqual(
            intent["payload_sha256"],
            .string("2b04d743201f13bed4d82755f403de4750cd17829ab983dc2c5cae56b52a2b05")
        )
        XCTAssertEqual(
            try request.json.sha256Hex(),
            "8c3551fdee5ba1bfa70af85597367e6252ce7d6b68728678e51ca8bcc4f29750"
        )
    }

    /// batch에 8개 필드가 빠짐없이 실려야 한다. 지금 아이패드가 하나도 보내지
    /// 않던 바로 그 값들이다.
    func testDocumentCommitCarriesImmutableBatchMetadata() throws {
        let request = try buildDocumentRequest()
        let batch = request.json.objectValue!["batch"]!.objectValue!

        XCTAssertEqual(Set(batch.keys), [
            "batch_id", "writer_device_id", "client_build_id", "sync_protocol_version",
            "contract_version", "canonical_contract_sha256", "client_capabilities",
            "batch_payload_sha256",
        ])
        XCTAssertEqual(batch["sync_protocol_version"], .int(3))
        XCTAssertEqual(batch["contract_version"], .string("0.2.0"))
        XCTAssertEqual(
            batch["canonical_contract_sha256"],
            .string(SyncV2Contract.canonicalSHA256)
        )
        XCTAssertEqual(
            batch["writer_device_id"],
            .string("22222222-2222-2222-2222-222222222222")
        )
        XCTAssertEqual(
            batch["client_capabilities"],
            .array(SyncV2Contract.clientCapabilities.map { .string($0) })
        )
    }

    /// 문서 의도는 `entity_id`가 아니라 `document_id`를 쓴다. 구조 의도와 키가
    /// 다르다.
    func testDocumentIntentUsesDocumentIDKey() throws {
        let intent = try buildDocumentRequest().orderedIntents[0].objectValue!
        XCTAssertEqual(intent["document_id"], .string("33333333-3333-3333-3333-333333333333"))
        XCTAssertNil(intent["entity_id"])
        XCTAssertEqual(intent["entity_kind"], .string("document"))
    }

    /// 본문 다이제스트와 바이트 수는 우리가 계산해 실어 보낸다.
    func testDocumentPayloadCarriesContentDigest() throws {
        let request = try buildDocumentRequest(content: "가나다")
        let payload = request.orderedIntents[0].objectValue!["payload"]!.objectValue!
        XCTAssertEqual(payload["content_byte_count"], .int(9))
        XCTAssertEqual(
            payload["content_sha256"]?.stringValue?.count,
            64
        )
    }

    /// 계약이 금지한 조합은 보내기 전에 막는다. 서버까지 갔다 오면 그만큼
    /// 사용자가 기다린다.
    func testDocumentCommitRejectsForbiddenCombinations() {
        // 새로 만드는데 기준 리비전이 0이 아니다.
        XCTAssertThrowsError(try buildDocumentRequest(intentKind: .create, baseRevision: 1))
        // 이미 있는 문서인데 기준 리비전이 0이다.
        XCTAssertThrowsError(try buildDocumentRequest(intentKind: .update, baseRevision: 0))
        // 지운다는데 지워짐 표시가 없다.
        XCTAssertThrowsError(try buildDocumentRequest(intentKind: .delete, isDeleted: false))
        // 지우지 않는데 지워짐 표시가 있다.
        XCTAssertThrowsError(try buildDocumentRequest(intentKind: .update, isDeleted: true))
        // 구조 리비전은 1 이상이다.
        XCTAssertThrowsError(try buildDocumentRequest(structureRevision: 0))
        // 이름이 규칙을 어겼다.
        XCTAssertThrowsError(try buildDocumentRequest(name: "장/1"))
    }

    func testDocumentCommitAcceptsCreateAndDelete() {
        XCTAssertNoThrow(try buildDocumentRequest(intentKind: .create, baseRevision: 0))
        XCTAssertNoThrow(try buildDocumentRequest(intentKind: .delete, baseRevision: 3, isDeleted: true))
    }

    // MARK: - 구조 원자 커밋 요청

    private func renameIntents() -> [SyncV2StructureIntent] {
        [("가", "나"), ("나", "다"), ("다", "라")].enumerated().map { index, pair in
            SyncV2StructureIntent(
                entityKind: .folder,
                entityID: UUID(uuidString: "7777777\(index)-7777-7777-7777-777777777777")!,
                intentKind: .rename,
                baseRevision: index + 1,
                payload: .object([
                    "name": .string(pair.1),
                    "previous_name": .string(pair.0),
                    "parent_folder_id": .null,
                ]),
                operationID: UUID(uuidString: "8888888\(index)-8888-8888-8888-888888888888")!
            )
        }
    }

    private func buildAtomicRequest() throws -> SyncV2ContractRequest {
        try SyncV2Contract.buildAtomicStructureRequest(
            projectID: projectID,
            projectSyncMode: .idBased,
            migrationEpoch: 7,
            writerDeviceID: deviceID,
            orderedIntents: renameIntents(),
            batchID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
    }

    /// 연속된 이름 변경 셋을 하나의 배치로 묶었을 때 Windows와 같은 값이
    /// 나와야 한다. 미해결 사건과 같은 모양의 입력이다.
    func testAtomicStructureRequestMatchesWindowsDigests() throws {
        let request = try buildAtomicRequest()

        XCTAssertEqual(
            request.batchPayloadSHA256,
            "11ebf33730d62f91c2ed05684326e06f9757642816889157d83b7c8347ce79b2"
        )
        XCTAssertEqual(
            try request.json.sha256Hex(),
            "c062a52662bac79171390f16484ea2783d6e63e1bf87846fe9706b3379842099"
        )
        let expected = [
            "a8e4ed6736e1b939f9045621c2a48b89bb1dc962fddd756684ebb2fa5a3c095f",
            "f97930b6469a9a3522a8ff8200dbb0536dae45a16a6fa079c4ebc80c0030210b",
            "4ff50ad2105e5b76ae140666532b11db5cc245b5926ec667ade4df832fc576ac",
        ]
        for (index, intent) in request.orderedIntents.enumerated() {
            XCTAssertEqual(intent.objectValue!["payload_sha256"], .string(expected[index]))
        }
    }

    /// 순서가 곧 계약이다. `sequence`는 1부터 연속이어야 한다.
    func testAtomicStructureAssignsContiguousSequence() throws {
        let request = try buildAtomicRequest()
        XCTAssertEqual(request.orderedIntents.count, 3)
        for (index, intent) in request.orderedIntents.enumerated() {
            let fields = intent.objectValue!
            XCTAssertEqual(fields["sequence"], .int(index + 1))
            XCTAssertEqual(
                fields["batch_id"],
                .string("99999999-9999-9999-9999-999999999999")
            )
            XCTAssertEqual(fields["entity_kind"], .string("folder"))
            XCTAssertEqual(fields["intent_kind"], .string("rename"))
        }
    }

    /// 배치에 담긴 이름도 보내기 전에 걸러야 한다.
    func testAtomicStructureRejectsInvalidNameInPayload() {
        let bad = SyncV2StructureIntent(
            entityKind: .folder,
            entityID: folderID,
            intentKind: .rename,
            payload: .object(["name": .string("메모/장")])
        )
        XCTAssertThrowsError(
            try SyncV2Contract.buildAtomicStructureRequest(
                projectID: projectID,
                projectSyncMode: .idBased,
                migrationEpoch: 7,
                writerDeviceID: deviceID,
                orderedIntents: [bad]
            )
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "STORAGE_NAME_INVALID")
        }
    }

    func testAtomicStructureRejectsEmptyBatch() {
        XCTAssertThrowsError(
            try SyncV2Contract.buildAtomicStructureRequest(
                projectID: projectID,
                projectSyncMode: .idBased,
                migrationEpoch: 7,
                writerDeviceID: deviceID,
                orderedIntents: []
            )
        )
    }

    /// 클라이언트가 모드를 임의로 올리지 못하게 조합부터 막는다.
    func testRequestBuildersRejectInvalidModeEpoch() {
        XCTAssertThrowsError(
            try SyncV2Contract.buildAtomicStructureRequest(
                projectID: projectID,
                projectSyncMode: .idBased,
                migrationEpoch: 0,
                writerDeviceID: deviceID,
                orderedIntents: renameIntents()
            )
        )
    }

    // MARK: - 응답 검증

    private func successResponse(
        for request: SyncV2ContractRequest,
        status: String = "committed",
        revision: Int = 9
    ) -> SyncV2JSON {
        let intent = request.orderedIntents[0].objectValue!
        let payload = intent["payload"]!.objectValue!
        return .object([
            "kind": .string("document_commit_success"),
            "batch_id": .string(SyncV2Contract.canonicalUUID(request.batchID)),
            "batch_payload_sha256": .string(request.batchPayloadSHA256),
            "status": .string(status),
            "applied": .bool(true),
            "results": .array([.object([
                "sequence": .int(1),
                "operation_id": intent["operation_id"]!,
                "document_id": intent["document_id"]!,
                "result_revision": .int(revision),
                "structure_revision": payload["structure_revision"]!,
                "parent_folder_id": payload["parent_folder_id"]!,
                "name": payload["name"]!,
                "content_sha256": payload["content_sha256"]!,
                "content_byte_count": payload["content_byte_count"]!,
                "is_deleted": payload["is_deleted"]!,
            ])]),
        ])
    }

    func testDocumentResponseAcceptsCommitted() throws {
        let request = try buildDocumentRequest()
        XCTAssertEqual(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: successResponse(for: request)
            ),
            .committed
        )
    }

    /// 같은 operation을 다시 보냈을 때 오는 멱등 응답이다. 정상 성공으로
    /// 수렴시켜야 큐가 막히지 않는다.
    func testDocumentResponseTreatsReplayedAsSuccess() throws {
        let request = try buildDocumentRequest()
        XCTAssertEqual(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: successResponse(for: request, status: "replayed")
            ),
            .replayed
        )
    }

    /// 리비전이 없거나 0이면 성공으로 처리하지 않는다. 그걸 믿으면 다음 편집이
    /// 잘못된 기준 위에 쌓인다.
    func testDocumentResponseRejectsMissingRevision() throws {
        let request = try buildDocumentRequest()
        XCTAssertThrowsError(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: successResponse(for: request, revision: 0)
            )
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "PARTIAL_BATCH_RESPONSE")
        }
    }

    /// 남의 배치 응답을 우리 것으로 착각하면 안 된다.
    func testDocumentResponseRejectsForeignBatch() throws {
        let request = try buildDocumentRequest()
        guard case var .object(fields) = successResponse(for: request) else {
            return XCTFail("응답이 객체가 아니다")
        }
        fields["batch_id"] = .string("00000000-0000-0000-0000-000000000000")
        XCTAssertThrowsError(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: .object(fields)
            )
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "INVALID_DOCUMENT_RESPONSE")
        }
    }

    /// 서버가 우리가 보낸 이름과 다른 것을 돌려주면 로컬에 반영하기 전에 안다.
    func testDocumentResponseRejectsAlteredPayloadEcho() throws {
        let request = try buildDocumentRequest()
        guard case var .object(fields) = successResponse(for: request),
              case let .array(results) = fields["results"]!,
              case var .object(result) = results[0]
        else {
            return XCTFail("응답 모양이 예상과 다르다")
        }
        result["name"] = .string("서버가 바꾼 이름")
        fields["results"] = .array([.object(result)])
        XCTAssertThrowsError(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: .object(fields)
            )
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "PARTIAL_BATCH_RESPONSE")
        }
    }

    /// 키가 하나라도 더 붙거나 빠지면 우리가 모르는 규약이다.
    func testDocumentResponseRejectsUnexpectedKey() throws {
        let request = try buildDocumentRequest()
        guard case var .object(fields) = successResponse(for: request) else {
            return XCTFail("응답이 객체가 아니다")
        }
        fields["extra"] = .int(1)
        XCTAssertThrowsError(
            try SyncV2Contract.validateDocumentCommitResponse(
                request: request,
                response: .object(fields)
            )
        )
    }

    /// 실패 응답은 계약 오류 코드를 그대로 올린다. 번역 문구가 아니라 코드로
    /// 분기해야 하기 때문이다.
    func testDocumentFailureSurfacesContractErrorCode() throws {
        let request = try buildDocumentRequest()
        let response = SyncV2JSON.object([
            "kind": .string("document_commit_failure"),
            "batch_id": .string(SyncV2Contract.canonicalUUID(request.batchID)),
            "batch_payload_sha256": .string(request.batchPayloadSHA256),
            "status": .string("rejected"),
            "applied": .bool(false),
            "results": .array([]),
            "error": .object([
                "code": .string("REVISION_CONFLICT"),
                "message": .string("base revision is behind"),
                "failed_sequence": .int(1),
            ]),
        ])
        XCTAssertThrowsError(
            try SyncV2Contract.validateDocumentCommitResponse(request: request, response: response)
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "REVISION_CONFLICT")
        }
    }

    /// 부분 적용은 존재해선 안 된다. 셋을 보냈는데 둘만 돌아오면 거부한다.
    func testAtomicResponseRejectsPartialResults() throws {
        let request = try buildAtomicRequest()
        let intent = request.orderedIntents[0].objectValue!
        let response = SyncV2JSON.object([
            "kind": .string("atomic_structure_commit_success"),
            "batch_id": .string(SyncV2Contract.canonicalUUID(request.batchID)),
            "batch_payload_sha256": .string(request.batchPayloadSHA256),
            "status": .string("committed"),
            "applied": .bool(true),
            "results": .array([.object([
                "sequence": .int(1),
                "operation_id": intent["operation_id"]!,
                "entity_id": intent["entity_id"]!,
                "result_revision": .int(2),
            ])]),
        ])
        XCTAssertThrowsError(
            try SyncV2Contract.validateAtomicStructureResponse(request: request, response: response)
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "PARTIAL_BATCH_RESPONSE")
        }
    }

    func testAtomicResponseAcceptsFullBatch() throws {
        let request = try buildAtomicRequest()
        let results = request.orderedIntents.enumerated().map { index, intent -> SyncV2JSON in
            let fields = intent.objectValue!
            return .object([
                "sequence": .int(index + 1),
                "operation_id": fields["operation_id"]!,
                "entity_id": fields["entity_id"]!,
                "result_revision": .int(index + 2),
            ])
        }
        let response = SyncV2JSON.object([
            "kind": .string("atomic_structure_commit_success"),
            "batch_id": .string(SyncV2Contract.canonicalUUID(request.batchID)),
            "batch_payload_sha256": .string(request.batchPayloadSHA256),
            "status": .string("committed"),
            "applied": .bool(true),
            "results": .array(results),
        ])
        XCTAssertEqual(
            try SyncV2Contract.validateAtomicStructureResponse(request: request, response: response),
            .committed
        )
    }

    /// 배치 다이제스트가 다르면 우리가 만든 요청의 응답이 아니다.
    func testAtomicResponseRejectsDigestMismatch() throws {
        let request = try buildAtomicRequest()
        let response = SyncV2JSON.object([
            "kind": .string("atomic_structure_commit_success"),
            "batch_id": .string(SyncV2Contract.canonicalUUID(request.batchID)),
            "batch_payload_sha256": .string(String(repeating: "0", count: 64)),
            "status": .string("committed"),
            "applied": .bool(true),
            "results": .array([]),
        ])
        XCTAssertThrowsError(
            try SyncV2Contract.validateAtomicStructureResponse(request: request, response: response)
        ) { error in
            XCTAssertEqual((error as? SyncV2ContractError)?.code, "INVALID_ATOMIC_RESPONSE")
        }
    }

    // MARK: - 이벤트에서 파생하는 상태

    func testStateDerivationFollowsLastEvent() throws {
        let cases: [(SyncV2OperationEventType, SyncV2OperationStatus)] = [
            (.enqueued, .pending),
            (.dispatchStarted, .inflight),
            (.retryScheduled, .retryWait),
            (.blocked, .blocked),
            (.conflictDetected, .conflict),
            (.committed, .completed),
            (.replayed, .completed),
            (.cancelRequested, .cancelled),
            (.superseded, .cancelled),
        ]
        for (type, expected) in cases {
            let events = [
                SyncV2OperationEvent(sequence: 1, type: .enqueued),
                SyncV2OperationEvent(sequence: 2, type: type),
            ]
            XCTAssertEqual(try SyncV2OperationStateDerivation.state(from: events), expected)
        }
    }

    /// 기록이 없으면 상태를 지어내지 않는다.
    func testStateDerivationRequiresEventHistory() {
        XCTAssertThrowsError(try SyncV2OperationStateDerivation.state(from: []))
    }

    /// 중간이 비면 우리가 못 본 사건이 있다는 뜻이라 계산을 믿을 수 없다.
    func testStateDerivationRejectsGapInSequence() {
        let events = [
            SyncV2OperationEvent(sequence: 1, type: .enqueued),
            SyncV2OperationEvent(sequence: 3, type: .committed),
        ]
        XCTAssertThrowsError(try SyncV2OperationStateDerivation.state(from: events))
    }

    /// 끝난 작업에 사건을 더 붙이면 완료된 작업이 되살아나 다시 발송된다.
    func testTerminalOperationRejectsFurtherEvents() {
        for terminal in [SyncV2OperationEventType.committed, .replayed, .cancelRequested, .superseded] {
            let events = [
                SyncV2OperationEvent(sequence: 1, type: .enqueued),
                SyncV2OperationEvent(sequence: 2, type: terminal),
            ]
            XCTAssertThrowsError(
                try SyncV2OperationStateDerivation.requireAppendable(to: events)
            ) { error in
                XCTAssertEqual((error as? SyncV2ContractError)?.code, "OPERATION_TERMINAL")
            }
        }
    }

    func testActiveOperationAcceptsFurtherEvents() {
        let events = [
            SyncV2OperationEvent(sequence: 1, type: .enqueued),
            SyncV2OperationEvent(sequence: 2, type: .retryScheduled, errorCode: "PATH_CONFLICT"),
        ]
        XCTAssertNoThrow(try SyncV2OperationStateDerivation.requireAppendable(to: events))
    }

    /// Windows가 밟은 지뢰다. 성공 사건에는 오류 코드가 없으므로 기록 전체에서
    /// 마지막 오류를 그냥 집으면, 성공한 뒤에도 옛 오류가 영원히 표시된다.
    func testCompletedOperationReportsNoStaleError() {
        let events = [
            SyncV2OperationEvent(sequence: 1, type: .enqueued),
            SyncV2OperationEvent(sequence: 2, type: .retryScheduled, errorCode: "AUTH_REQUIRED"),
            SyncV2OperationEvent(sequence: 3, type: .dispatchStarted),
            SyncV2OperationEvent(sequence: 4, type: .committed),
        ]
        XCTAssertNil(SyncV2OperationStateDerivation.latestErrorCode(from: events))
    }

    /// 아직 살아 있는 작업의 오류는 그대로 보여 준다.
    func testActiveOperationReportsLatestError() {
        let events = [
            SyncV2OperationEvent(sequence: 1, type: .enqueued),
            SyncV2OperationEvent(sequence: 2, type: .retryScheduled, errorCode: "AUTH_REQUIRED"),
            SyncV2OperationEvent(sequence: 3, type: .retryScheduled, errorCode: "PATH_CONFLICT"),
        ]
        XCTAssertEqual(
            SyncV2OperationStateDerivation.latestErrorCode(from: events),
            "PATH_CONFLICT"
        )
    }
}
