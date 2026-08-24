import Foundation
import Supabase

/// 서버가 이 작품에 대해 무엇을 지원하는지 한 번에 묻는 경로다.
///
/// 클라이언트는 allowlist 유무나 행의 부재를 추측하지 않는다. 추측하면 언젠가
/// 반쯤 적용된 구조가 남고, 그건 되돌릴 방법이 없다. 여기서 얻은 답은 기록될
/// 뿐이며 계약 경로를 열지 않는다. 여는 것은 별개의 로컬 행위다.
///
/// 답을 메모리에만 둔다. 디스크에 남기면 앱을 다시 켠 뒤에도 살아남는데, 그때
/// 서버는 이미 다른 말을 하고 있을 수 있다. 재시작은 곧 모름으로 돌아가는 것이
/// 맞다.

// MARK: - 요청

struct SyncV2HandshakeParameters: Encodable, Equatable, Sendable {
    let projectID: UUID
    let contractSHA256: String

    enum CodingKeys: String, CodingKey {
        case projectID = "p_project_id"
        case contractSHA256 = "p_contract_sha256"
    }
}

// MARK: - 응답

/// `get_sync_handshake`가 실제로 보내는 열 개 필드를 그대로 받는다.
///
/// 서버가 보내는 것을 로컬 상수로 대신 채우지 않는다. 그렇게 하면 저장된 값이
/// "서버가 말한 것"처럼 읽히지만 실제로는 우리가 우리에게 한 말이라, 사고가
/// 났을 때 누구 말이 틀렸는지 가릴 수 없게 된다.
struct SyncV2HandshakeResponse: Decodable, Equatable, Sendable {
    let supported: Bool
    let projectID: UUID
    let projectSyncMode: SyncV2ProjectSyncMode
    let migrationEpoch: Int
    let contractVersion: String?
    let canonicalContractSHA256: String?
    let serverContractSHA256: String?
    let serverProtocolVersion: Int?
    let supportedProtocolVersions: [Int]
    let serverCapabilities: [String]

    enum CodingKeys: String, CodingKey {
        case supported
        case projectID = "project_id"
        case projectSyncMode = "project_sync_mode"
        case migrationEpoch = "migration_epoch"
        case contractVersion = "contract_version"
        case canonicalContractSHA256 = "canonical_contract_sha256"
        case serverContractSHA256 = "server_contract_sha256"
        case serverProtocolVersion = "server_protocol_version"
        case supportedProtocolVersions = "supported_protocol_versions"
        case serverCapabilities = "server_capabilities"
    }
}

// MARK: - 오류

enum SyncV2HandshakeTransportError: Error, Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case networkUnavailable
    case timedOut
    case invalidResponse
    case serverRejected
}

enum SyncV2HandshakeError: Error, Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case networkUnavailable
    case timedOut
    case invalidResponse
    /// 서버가 이 작품에 대해 계약 경로를 아직 열어 주지 않았다.
    case contractUnavailable
    case incompatible(SyncV2ContractError)
    case serverRejected
    /// 누구로서 물었는지 확정할 수 없다. 빈 값을 신원으로 인정하면 계정이 바뀌어도
    /// 같다고 판정되므로, 모름은 "같음"이 아니라 "다름"으로 취급한다.
    case identityUnknown
    /// 기다리는 사이에 상황이 바뀌어, 도착한 답이 이미 지난 상황의 것이 됐다.
    case superseded

    /// 이미 들고 있던 답을 버려야 하는 오류인지다.
    ///
    /// 여기 해당하는 답이 오면 서버 쪽 사정이 우리가 읽은 시점을 앞질렀다는
    /// 뜻이라, 들고 있던 것은 더 이상 서버를 설명하지 않는다.
    var invalidatesStandingReading: Bool {
        switch self {
        case .authenticationRequired, .forbidden, .contractUnavailable,
             .incompatible, .identityUnknown:
            return true
        case .networkUnavailable, .timedOut, .invalidResponse, .serverRejected,
             .superseded:
            return false
        }
    }
}

// MARK: - 전송

protocol SyncV2HandshakeTransporting: Sendable {
    func fetchHandshake(
        parameters: SyncV2HandshakeParameters
    ) async throws -> SyncV2HandshakeResponse
}

actor LiveSyncV2HandshakeTransport: SyncV2HandshakeTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func fetchHandshake(
        parameters: SyncV2HandshakeParameters
    ) async throws -> SyncV2HandshakeResponse {
        do {
            let response: PostgrestResponse<SyncV2HandshakeResponse> =
                try await client
                    .rpc("get_sync_handshake", params: parameters)
                    .execute()
            return response.value
        } catch let error as PostgrestError {
            switch (error.message, error.code) {
            case ("AUTH_REQUIRED", _), (_, "PGRST301"):
                throw SyncV2HandshakeTransportError.authenticationRequired
            case ("FORBIDDEN", _), (_, "42501"):
                throw SyncV2HandshakeTransportError.forbidden
            default:
                throw SyncV2HandshakeTransportError.serverRejected
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw SyncV2HandshakeTransportError.timedOut
            case .userAuthenticationRequired:
                throw SyncV2HandshakeTransportError.authenticationRequired
            default:
                throw SyncV2HandshakeTransportError.networkUnavailable
            }
        } catch is DecodingError {
            throw SyncV2HandshakeTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                if nsError.code == URLError.timedOut.rawValue {
                    throw SyncV2HandshakeTransportError.timedOut
                }
                throw SyncV2HandshakeTransportError.networkUnavailable
            }
            throw SyncV2HandshakeTransportError.serverRejected
        }
    }
}

// MARK: - 응답 해독

extension SyncV2Contract {
    /// 답 하나가 스스로 어긋나 있지 않은지 본다.
    ///
    /// `requireServerCompatibility`는 다섯 인자만 보는데, 응답에는 그 다섯과
    /// 모순될 수 있는 필드가 더 들어 있다. 전체를 한 번에 들고 있는 곳이 여기뿐이라
    /// 여기서 본다. 모양 문제는 전부 `INVALID_ARGUMENT` 하나로 나가서, 부르는
    /// 쪽이 계약 오류와 해독 오류를 섞어 다루지 않아도 된다.
    static func readHandshakeCompatibility(
        _ response: SyncV2HandshakeResponse
    ) throws -> SyncV2ValidatedHandshake {
        guard response.migrationEpoch >= 0 else {
            throw SyncV2ContractError.invalidArgument
        }
        guard response.supported else {
            throw SyncV2ContractError("CONTRACT_NOT_ALLOWED")
        }
        guard
            let contractVersion = response.contractVersion,
            !contractVersion.isEmpty,
            let canonicalDigest = response.canonicalContractSHA256,
            let serverDigest = response.serverContractSHA256,
            let serverProtocolVersion = response.serverProtocolVersion,
            isSHA256Hex(canonicalDigest),
            isSHA256Hex(serverDigest),
            serverProtocolVersion > 0
        else {
            throw SyncV2ContractError.invalidArgument
        }
        guard
            !response.supportedProtocolVersions.isEmpty,
            response.supportedProtocolVersions.allSatisfy({ $0 > 0 }),
            Set(response.supportedProtocolVersions).count
                == response.supportedProtocolVersions.count,
            !response.serverCapabilities.isEmpty,
            response.serverCapabilities.allSatisfy({ !$0.isEmpty }),
            Set(response.serverCapabilities).count
                == response.serverCapabilities.count
        else {
            throw SyncV2ContractError.invalidArgument
        }
        // 지원한다고 적은 목록에 자기가 쓰겠다는 번호가 없으면 그 답은 자기
        // 자신과 어긋난 것이다. 어느 쪽이 참인지 고르지 않고 거절한다.
        guard response.supportedProtocolVersions.contains(serverProtocolVersion)
        else {
            throw SyncV2ContractError.invalidArgument
        }
        // `server_protocol_version`은 천장일 뿐이라 `>=` 검사만으로는 부족하다.
        // 3을 내리고 4로 답하는 서버는 그 검사를 통과하면서 우리가 할 수 있는 말은
        // 전부 거절한다. 우리가 쓰는 번호가 아직 목록에 남아 있는지를 따로 본다.
        guard response.supportedProtocolVersions.contains(syncProtocolVersion)
        else {
            throw SyncV2ContractError.protocolTooOld
        }
        // 정본 다이제스트와 실제 적용 다이제스트가 다르면 서버가 무엇을 돌리는지
        // 두 갈래로 말한 것이다. 둘 중 하나를 골라 쓰면 고른 쪽이 틀렸을 때 조용히
        // 어긋나므로 여기서 닫는다.
        guard canonicalDigest == serverDigest else {
            throw SyncV2ContractError.invalidArgument
        }

        try requireServerCompatibility(
            projectSyncMode: response.projectSyncMode,
            migrationEpoch: response.migrationEpoch,
            serverProtocolVersion: serverProtocolVersion,
            serverContractSHA256: serverDigest,
            serverCapabilities: response.serverCapabilities
        )

        return SyncV2ValidatedHandshake(
            serverProjectID: response.projectID,
            projectSyncMode: response.projectSyncMode,
            migrationEpoch: response.migrationEpoch,
            contractVersion: contractVersion,
            contractSHA256: serverDigest,
            serverProtocolVersion: serverProtocolVersion,
            supportedProtocolVersions: response.supportedProtocolVersions,
            serverCapabilities: response.serverCapabilities.sorted()
        )
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { character in
            character.isHexDigit && !character.isUppercase
        }
    }
}

/// 서버 답에서 계약이 쓰는 것만 추린 값이다. 여기까지 온 것은 모양과 호환성을
/// 모두 통과했다는 뜻이지, 계약 경로를 써도 된다는 뜻은 아니다.
struct SyncV2ValidatedHandshake: Equatable, Sendable {
    let serverProjectID: UUID
    let projectSyncMode: SyncV2ProjectSyncMode
    let migrationEpoch: Int
    let contractVersion: String
    let contractSHA256: String
    let serverProtocolVersion: Int
    /// 서버가 지금 받아 주는 protocol 번호 전부다. `serverProtocolVersion`은
    /// 천장일 뿐이라, 우리가 쓰는 번호가 이 안에 남아 있는지가 실제 판정이다.
    let supportedProtocolVersions: [Int]
    let serverCapabilities: [String]
}

// MARK: - 문맥과 읽은 값

/// 이 답이 어느 상황에 대한 답인지다. 넷 중 하나라도 움직이면 답은 그 상황을
/// 더 이상 설명하지 않는다.
struct SyncV2HandshakeContext: Equatable, Sendable {
    let localProjectID: ProjectID
    let serverProjectID: UUID
    /// 로그인한 계정이다. 라이브러리 내부 속성이나 직접 해독한 토큰이 아니라
    /// 인증 교환이 돌려준 세션의 user id를 쓴다.
    let accountID: UUID
    let clientContractSHA256: String

    init(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        accountID: UUID,
        clientContractSHA256: String = SyncV2Contract.canonicalSHA256
    ) {
        self.localProjectID = localProjectID
        self.serverProjectID = serverProjectID
        self.accountID = accountID
        self.clientContractSHA256 = clientContractSHA256
    }

    /// 인증된 상태에서만 문맥이 성립한다.
    ///
    /// `nil`을 돌려주는 것이 요점이다. 신원을 모를 때 빈 값을 대신 넣으면 두 번의
    /// 모름이 서로 같다고 판정되어, 계정이 바뀌어도 앞 계정의 답이 살아남는다.
    static func make(
        authenticationState: AuthenticationState,
        localProjectID: ProjectID,
        serverProjectID: UUID
    ) -> SyncV2HandshakeContext? {
        guard case let .authenticated(account) = authenticationState else {
            return nil
        }
        return SyncV2HandshakeContext(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: account.userID
        )
    }
}

/// 특정 문맥에서 특정 시점에 읽은 답이다.
struct SyncV2HandshakeReading: Equatable, Sendable {
    let context: SyncV2HandshakeContext
    let handshake: SyncV2ValidatedHandshake
    /// 이 답을 읽을 당시의 세대다. 무효화가 일어나면 세대가 올라가고, 세대가
    /// 다른 답은 아무리 내용이 맞아도 쓰이지 않는다.
    let generation: UInt64
    let observedAt: Date
}

// MARK: - 서비스

/// 답을 읽고, 그 답이 아직 같은 상황을 설명하는 동안에만 들고 있는다.
///
/// 저장소를 쓰지 않는다. `SyncV2Store`에 남기면 앱을 껐다 켠 뒤에도 답이 살아
/// 있는데, 그 사이 서버 쪽 allowlist나 작품 모드가 바뀌었을 수 있다. 재시작 뒤에는
/// 다시 묻는 것이 맞다.
actor SyncV2HandshakeService {
    private let transport: any SyncV2HandshakeTransporting
    private let now: @Sendable () -> Date

    private var reading: SyncV2HandshakeReading?
    /// 무효화가 일어날 때마다 오른다. 올리는 것만으로 들고 있던 답 전부가 한
    /// 번에 죽으므로, 무효화를 반쪽만 구현하는 실수가 성립하지 않는다.
    private var generation: UInt64 = 0
    private var inFlight: Task<SyncV2ValidatedHandshake, Error>?

    init(
        transport: any SyncV2HandshakeTransporting,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    // MARK: 읽기

    /// 서버에 묻고, 통과한 답만 이 문맥에 묶어 들고 있는다.
    ///
    /// 묻기 전에 먼저 버린다. 조회·해독·검증 중 어디서 실패하든 계약 경로에 쓸 수
    /// 있는 값이 남지 않게 하려는 것이다.
    func refresh(
        context: SyncV2HandshakeContext?
    ) async throws -> SyncV2ValidatedHandshake {
        guard let context else {
            forget(reason: "identityUnknown")
            throw SyncV2HandshakeError.identityUnknown
        }
        guard context.clientContractSHA256 == SyncV2Contract.canonicalSHA256 else {
            forget(reason: "clientDigestMismatch")
            throw SyncV2HandshakeError.incompatible(.contractDigestMismatch)
        }

        // 이미 날아간 요청이 있으면 그 결과를 함께 기다린다. 화면 여러 곳이 동시에
        // 물어도 서버에는 한 번만 간다. 먼저 온 요청이 이미 버리고 출발했으므로
        // 여기서 다시 버리지 않는다 — 다시 버리면 세대가 올라 그 요청의 답이 죽는다.
        if let inFlight {
            return try await inFlight.value
        }

        forget(reason: "refresh")

        let generation = self.generation
        let task = Task<SyncV2ValidatedHandshake, Error> { [transport] in
            let response: SyncV2HandshakeResponse
            do {
                response = try await transport.fetchHandshake(
                    parameters: SyncV2HandshakeParameters(
                        projectID: context.serverProjectID,
                        contractSHA256: SyncV2Contract.canonicalSHA256
                    )
                )
            } catch let error as SyncV2HandshakeTransportError {
                throw Self.classify(error)
            } catch {
                throw SyncV2HandshakeError.serverRejected
            }

            // 우리가 물은 작품에 대한 답인지 먼저 본다. 다른 작품에 대한 답을
            // 받아 두면 남의 상태로 우리 작품을 판단하게 된다.
            guard response.projectID == context.serverProjectID else {
                throw SyncV2HandshakeError.invalidResponse
            }
            guard response.supported else {
                throw SyncV2HandshakeError.contractUnavailable
            }
            do {
                return try SyncV2Contract.readHandshakeCompatibility(response)
            } catch let error as SyncV2ContractError {
                throw error == .invalidArgument
                    ? SyncV2HandshakeError.invalidResponse
                    : SyncV2HandshakeError.incompatible(error)
            }
        }
        inFlight = task

        defer { inFlight = nil }
        do {
            let handshake = try await task.value
            // 기다리는 사이에 무효화가 일어났다면 이 답은 이미 지난 상황에 대한
            // 것이다. 늦게 도착한 답이 새 상황을 덮어쓰지 못하게 버린다.
            guard generation == self.generation else {
                throw SyncV2HandshakeError.superseded
            }
            reading = SyncV2HandshakeReading(
                context: context,
                handshake: handshake,
                generation: generation,
                observedAt: now()
            )
            return handshake
        } catch let error as SyncV2HandshakeError {
            if error.invalidatesStandingReading {
                forget(reason: "invalidatingError")
            }
            throw error
        }
    }

    /// 지금 이 문맥을 설명하는 답이 서 있는 동안에만 돌려준다.
    func standingHandshake(
        for context: SyncV2HandshakeContext?
    ) -> SyncV2ValidatedHandshake? {
        guard let context, let reading else { return nil }
        guard reading.generation == generation else { return nil }
        guard reading.context == context else { return nil }
        guard reading.context.clientContractSHA256
            == SyncV2Contract.canonicalSHA256 else { return nil }
        return reading.handshake
    }

    func isFresh(for context: SyncV2HandshakeContext?) -> Bool {
        standingHandshake(for: context) != nil
    }

    // MARK: 무효화

    /// 들고 있던 답을 버린다. 세대를 올리므로 진행 중인 조회의 결과도 함께 죽는다.
    func forget(reason: String) {
        reading = nil
        generation &+= 1
        SyncV2Diagnostics.generation(
            scope: "handshake",
            counter: "generation",
            value: generation,
            reason: reason
        )
    }

    /// 다른 작품으로 옮겼다.
    func projectChanged() { forget(reason: "projectChanged") }

    /// 로그아웃했거나 세션이 끝났다.
    func authenticationChanged() { forget(reason: "authenticationChanged") }

    /// 관문을 닫았다.
    func gateClosed() { forget(reason: "gateClosed") }

    /// 서버가 우리가 읽은 시점을 앞지른 답을 보냈다.
    func forgetIfStale(_ error: SyncV2HandshakeError) {
        guard error.invalidatesStandingReading else { return }
        forget(reason: "staleServerAnswer")
    }

    private static func classify(
        _ error: SyncV2HandshakeTransportError
    ) -> SyncV2HandshakeError {
        switch error {
        case .authenticationRequired: return .authenticationRequired
        case .forbidden: return .forbidden
        case .networkUnavailable: return .networkUnavailable
        case .timedOut: return .timedOut
        case .invalidResponse: return .invalidResponse
        case .serverRejected: return .serverRejected
        }
    }
}

// MARK: - 관문

/// 작품별로 계약 경로를 쓸지 정하는 로컬 스위치다.
///
/// 기본은 닫힘이고, 서버는 이것을 열 수 없다. allowlist를 켜도 이 스위치가 닫혀
/// 있으면 아무것도 움직이지 않는다. 핸드셰이크가 성공했다는 것과 계약 경로를
/// 쓴다는 것은 별개이며, 그 둘을 잇는 유일한 지점이 여기다.
enum ContractPathGate {
    static let storageKeyPrefix = "writerpad.contract-path-enabled."

    static func storageKey(for localProjectID: ProjectID) -> String {
        storageKeyPrefix + localProjectID.rawValue.uuidString
    }

    /// 값이 없으면 닫힘이다. 켠 적 없는 작품이 열려 있는 일은 없다.
    static func isOpen(
        for localProjectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: storageKey(for: localProjectID))
    }

    static func setOpen(
        _ isOpen: Bool,
        for localProjectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(isOpen, forKey: storageKey(for: localProjectID))
    }

    static func close(
        for localProjectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: storageKey(for: localProjectID))
    }
}

extension SyncV2HandshakeService {
    /// 이 작품의 구조 쓰기를 계약 경로로 보낼지다.
    ///
    /// 세 조건이 모두 맞아야 참이고, 그중 서버가 움직일 수 있는 것은 하나도 없다.
    /// 관문은 로컬이고, 답은 이 실행 안에서만 살아 있으며, 문맥은 지금 열린 작품과
    /// 로그인한 계정으로 만든다.
    func usesContractStructure(
        context: SyncV2HandshakeContext?,
        gateIsOpen: Bool
    ) -> Bool {
        guard gateIsOpen else { return false }
        guard let handshake = standingHandshake(for: context) else { return false }
        // 들고 있는 서버 상태를 쓸 때마다 다시 검사한다. 지금 이 설계에서는 답이
        // 메모리에 있고 잡은 뒤로 바뀌지 않아 여기서 걸릴 일이 없지만, 언젠가 답을
        // 어딘가에 남기게 되면 그때부터 이 검사가 유일한 방어가 된다.
        do {
            try SyncV2Contract.requireServerCompatibility(
                projectSyncMode: handshake.projectSyncMode,
                migrationEpoch: handshake.migrationEpoch,
                serverProtocolVersion: handshake.serverProtocolVersion,
                serverContractSHA256: handshake.contractSHA256,
                serverCapabilities: handshake.serverCapabilities
            )
        } catch {
            return false
        }
        return true
    }
}
