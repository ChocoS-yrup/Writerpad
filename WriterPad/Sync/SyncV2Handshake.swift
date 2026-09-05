import Foundation
import Supabase

/// actor 사이의 await 없이 전송 시작 시점까지 수명 변화를 검사한다.
final class SyncV2ContractEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0
    private var transitions = 0
    var value: UInt64 { lock.withLock { counter } }
    var isAvailable: Bool { lock.withLock { transitions == 0 } }
    func advance() { lock.withLock { counter &+= 1 } }
    func beginTransition() { lock.withLock { transitions += 1; counter &+= 1 } }
    func endTransition() { lock.withLock { transitions -= 1; counter &+= 1 } }
}

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
    case contractRejected(String)
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

    var isRetryable: Bool {
        self == .networkUnavailable || self == .timedOut
    }

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

/// 계약 RPC는 HTTP 상태를 보존한다. SDK의 PostgREST 오류 변환은 JSON 오류의
/// 429/5xx 상태를 버릴 수 있어 재시도 분류에 사용하지 않는다.
struct SyncV2ContractHTTPClient: Sendable {
    let configuration: SupabasePublicConfiguration
    let accessToken: @Sendable () -> String?
    var session: URLSession = .shared

    func call(rpc: String, body: Data, authorize: @Sendable () throws -> Void = {}) async throws -> Data {
        guard let token = accessToken() else { throw SyncV2HandshakeTransportError.authenticationRequired }
        var request = URLRequest(url: configuration.url.appendingPathComponent("rest/v1/rpc/\(rpc)"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        // 토큰과 요청을 준비한 뒤, 네트워크 호출 직전에 동기적으로 검사한다.
        try authorize()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncV2HandshakeTransportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError(data: data, response: http) }
        return data
    }
}

actor LiveSyncV2HandshakeTransport: SyncV2HandshakeTransporting {
    private let http: SyncV2ContractHTTPClient

    init(client: SupabaseClient, configuration: SupabasePublicConfiguration) {
        http = SyncV2ContractHTTPClient(configuration: configuration, accessToken: { client.auth.currentSession?.accessToken })
    }

    func fetchHandshake(
        parameters: SyncV2HandshakeParameters
    ) async throws -> SyncV2HandshakeResponse {
        do {
            let data = try await http.call(rpc: "get_sync_handshake", body: JSONEncoder().encode(parameters))
            return try JSONDecoder().decode(SyncV2HandshakeResponse.self, from: data)
        } catch {
            throw Self.classify(error)
        }
    }

    static func classify(_ error: Error, depth: Int = 0) -> SyncV2HandshakeTransportError {
        if let known = error as? SyncV2HandshakeTransportError { return known }
        if let remote = error as? PostgrestError {
            switch remote.message {
            case "AUTH_REQUIRED", "AUTH_EXPIRED": return .authenticationRequired
            case "FORBIDDEN": return .forbidden
            case "CONTRACT_NOT_ALLOWED", "CONTRACT_DIGEST_MISMATCH",
                 "PROTOCOL_TOO_OLD", "CAPABILITY_MISMATCH", "STALE_MIGRATION_EPOCH":
                return .contractRejected(remote.message)
            default:
                if remote.code == "PGRST301" { return .authenticationRequired }
                if remote.code == "42501" { return .forbidden }
                return .serverRejected
            }
        }
        if let http = error as? HTTPError {
            // 명시적인 거절은 오래된 underlying timeout보다 우선한다.
            if http.response.statusCode == 401 { return .authenticationRequired }
            if http.response.statusCode == 403 { return .forbidden }
            if let remote = try? JSONDecoder().decode(PostgrestError.self, from: http.data) {
                let specific = classify(remote)
                if specific != .serverRejected { return specific }
            }
            if http.response.statusCode == 429 || http.response.statusCode >= 500 {
                return .networkUnavailable
            }
            return .serverRejected
        }
        if error is DecodingError { return .invalidResponse }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == URLError.timedOut.rawValue { return .timedOut }
            if ns.code == URLError.userAuthenticationRequired.rawValue { return .authenticationRequired }
            if ns.code == URLError.cancelled.rawValue { return .serverRejected }
            return .networkUnavailable
        }
        if depth < 4, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return classify(underlying, depth: depth + 1)
        }
        return .serverRejected
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
        guard contractVersion == version else {
            throw SyncV2ContractError.contractDigestMismatch
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
    let authenticationEpoch: UInt64
    let bindingEpoch: UInt64

    init(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        accountID: UUID,
        clientContractSHA256: String = SyncV2Contract.canonicalSHA256,
        authenticationEpoch: UInt64 = 0,
        bindingEpoch: UInt64 = 0
    ) {
        self.localProjectID = localProjectID
        self.serverProjectID = serverProjectID
        self.accountID = accountID
        self.clientContractSHA256 = clientContractSHA256
        self.authenticationEpoch = authenticationEpoch
        self.bindingEpoch = bindingEpoch
    }

    /// 인증된 상태에서만 문맥이 성립한다.
    ///
    /// `nil`을 돌려주는 것이 요점이다. 신원을 모를 때 빈 값을 대신 넣으면 두 번의
    /// 모름이 서로 같다고 판정되어, 계정이 바뀌어도 앞 계정의 답이 살아남는다.
    static func make(
        authenticationState: AuthenticationState,
        localProjectID: ProjectID,
        serverProjectID: UUID,
        authenticationEpoch: UInt64 = 0,
        bindingEpoch: UInt64 = 0
    ) -> SyncV2HandshakeContext? {
        guard case let .authenticated(account) = authenticationState else {
            return nil
        }
        return SyncV2HandshakeContext(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: account.userID,
            authenticationEpoch: authenticationEpoch,
            bindingEpoch: bindingEpoch
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
    private typealias Outcome = Result<SyncV2ValidatedHandshake, SyncV2HandshakeError>
    private struct Flight {
        let id: UUID
        let context: SyncV2HandshakeContext
        let generation: UInt64
        let race: SyncV2OneShotRace<Outcome>
    }
    private let transport: any SyncV2HandshakeTransporting
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let timeout: Duration
    nonisolated let authorizationEpoch = SyncV2ContractEpoch()
    private var reading: SyncV2HandshakeReading?
    private var inFlight: Flight?
    private var generation: UInt64 { authorizationEpoch.value }
    private var automaticTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var bindingTask: Task<Void, Never>?
    private var lifecycleGeneration: UInt64 = 0
    private var selectedProjectID: ProjectID?
    private var selectionID = UUID()
    private var authenticationService: (any AuthenticationServicing)?
    private var bindingService: (any ProjectBindingServicing)?
    private var sceneActive = true
    nonisolated let activityEpoch = SyncV2ContractEpoch()
    private var retryAttempt = 0
    private var retryAt: Date?
    private var terminalContext: SyncV2HandshakeContext?
    private let networkMonitor = SyncV2NetworkRecoveryMonitor()

    init(
        transport: any SyncV2HandshakeTransporting,
        now: @escaping @Sendable () -> Date = Date.init,
        timeout: Duration = .seconds(12),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.now = now
        self.timeout = timeout
        self.sleep = sleep
    }

    func refresh(context: SyncV2HandshakeContext?) async throws -> SyncV2ValidatedHandshake {
        guard !Task.isCancelled else { throw SyncV2HandshakeError.superseded }
        guard let context else {
            forget(reason: "identityUnknown")
            throw SyncV2HandshakeError.identityUnknown
        }
        guard context.clientContractSHA256 == SyncV2Contract.canonicalSHA256 else {
            forget(reason: "clientDigestMismatch")
            throw SyncV2HandshakeError.incompatible(.contractDigestMismatch)
        }
        let flight: Flight
        if let existing = inFlight {
            // 다른 문맥은 같은 요청에 합류할 수 없다. 실제 호출 슬롯은 끝날 때까지
            // 유지하므로 취소를 무시하는 SDK에도 중복 네트워크 요청을 만들지 않는다.
            guard existing.context == context, existing.generation == generation else {
                throw SyncV2HandshakeError.superseded
            }
            flight = existing
        } else {
            forget(reason: "refresh")
            let created = Flight(id: UUID(), context: context, generation: generation,
                                 race: SyncV2OneShotRace<Outcome>())
            inFlight = created
            flight = created
            let transport = self.transport
            let sleep = self.sleep
            let timeout = self.timeout
            let watchdog = Task {
                do {
                    try await sleep(timeout)
                    await created.race.resolve(.failure(.timedOut))
                } catch { }
            }
            Task { [weak self] in
                let outcome: Outcome
                do {
                    let response = try await transport.fetchHandshake(parameters:
                        SyncV2HandshakeParameters(projectID: context.serverProjectID,
                                                  contractSHA256: context.clientContractSHA256))
                    guard response.projectID == context.serverProjectID else {
                        throw SyncV2HandshakeError.invalidResponse
                    }
                    guard response.supported else { throw SyncV2HandshakeError.contractUnavailable }
                    outcome = .success(try SyncV2Contract.readHandshakeCompatibility(response))
                } catch let error as SyncV2HandshakeError {
                    outcome = .failure(error)
                } catch let error as SyncV2ContractError {
                    outcome = .failure(error == .invalidArgument ? .invalidResponse : .incompatible(error))
                } catch {
                    outcome = .failure(Self.classify(LiveSyncV2HandshakeTransport.classify(error)))
                }
                watchdog.cancel()
                await self?.finishFlight(created.id)
                await created.race.resolve(outcome)
            }
        }
        let outcome = await flight.race.value()
        // 성공·실패·unsupported와 합류한 호출자 전부에 동일하게 적용한다.
        guard flight.generation == generation, !Task.isCancelled else { throw SyncV2HandshakeError.superseded }
        switch outcome {
        case .success(let handshake):
            retryAttempt = 0; retryAt = nil; terminalContext = nil
            reading = SyncV2HandshakeReading(context: context, handshake: handshake,
                                             generation: generation, observedAt: now())
            return handshake
        case .failure(let error):
            reading = nil
            throw error
        }
    }

    func refreshForGate(context: SyncV2HandshakeContext) async throws -> SyncV2ValidatedHandshake {
        // 이미 진행 중인 오래된 조회에 합류하여 스위치를 켜지 않는다.
        forget(reason: "explicitGateOpen")
        return try await refresh(context: context)
    }

    private func finishFlight(_ id: UUID) {
        if inFlight?.id == id { inFlight = nil }
    }

    func standingHandshake(for context: SyncV2HandshakeContext?) -> SyncV2ValidatedHandshake? {
        guard let context, let reading, reading.generation == generation,
              reading.context == context,
              context.clientContractSHA256 == SyncV2Contract.canonicalSHA256
        else { return nil }
        return reading.handshake
    }
    func isFresh(for context: SyncV2HandshakeContext?) -> Bool {
        standingHandshake(for: context) != nil
    }
    func forget(reason: String) {
        reading = nil
        authorizationEpoch.advance()
        SyncV2Diagnostics.generation(scope: "handshake", counter: "generation",
                                     value: generation, reason: reason)
    }
    func projectChanged() { invalidateLifecycle(reason: "projectChanged") }
    func authenticationChanged() { invalidateLifecycle(reason: "authenticationChanged") }
    func gateClosed() { invalidateLifecycle(reason: "gateClosed") }
    func forgetIfStale(_ error: SyncV2HandshakeError, expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != generation { return }
        guard error.invalidatesStandingReading else { return }
        invalidateLifecycle(reason: "staleServerAnswer")
    }

    static func retryDelay(attempt: Int) -> Duration {
        .seconds([2, 4, 8, 16, 32, 60][min(max(attempt, 0), 5)])
    }

    /// UI는 사건만 전달하고 네트워크 완료를 기다리지 않는다.
    func observeProject(
        _ projectID: ProjectID?,
        authentication: any AuthenticationServicing,
        bindings: any ProjectBindingServicing
    ) async {
        let first = authenticationService == nil ||
            authenticationService?.contractEpoch !== authentication.contractEpoch ||
            bindingService?.contractEpoch !== bindings.contractEpoch
        authenticationService = authentication
        bindingService = bindings
        if first {
            authenticationTask?.cancel()
            let updates = await authentication.stateUpdates()
            authenticationTask = Task { [weak self] in
                for await _ in updates {
                    guard !Task.isCancelled else { return }
                    await self?.authenticationChanged()
                }
            }
            networkMonitor.start { [weak self] in
                Task { await self?.networkRecovered() }
            }
        }
        guard first || selectedProjectID != projectID else { return }
        selectedProjectID = projectID
        selectionID = UUID()
        bindingTask?.cancel()
        projectChanged()
        guard let projectID else { return }
        let selection = selectionID
        let updates = await bindings.bindingUpdates(for: projectID)
        guard selection == selectionID, selectedProjectID == projectID else { return }
        bindingTask = Task { [weak self] in
            for await _ in updates {
                guard !Task.isCancelled else { return }
                await self?.bindingChanged(for: projectID, selection: selection)
            }
        }
    }

    private func bindingChanged(for projectID: ProjectID, selection: UUID) {
        guard selectedProjectID == projectID, selectionID == selection else { return }
        projectChanged()
    }

    func updateSceneActivity(_ active: Bool) {
        guard active != sceneActive else { return }
        sceneActive = active
        activityEpoch.advance()
        lifecycleGeneration &+= 1
        // 복귀만으로 캐시 TTL을 새로 만들지 않는다. 송신 권한과 읽기 캐시는 분리한다.
        automaticTask?.cancel(); automaticTask = nil
        if active { scheduleAutomatic() }
    }

    func networkRecovered() { scheduleAutomatic() }

    func canStartContractWrite() -> Bool { sceneActive }

    func stopObserving() {
        authenticationTask?.cancel(); authenticationTask = nil
        bindingTask?.cancel(); bindingTask = nil
        networkMonitor.cancel()
        authenticationService = nil
        bindingService = nil
        selectedProjectID = nil
        invalidateLifecycle(reason: "stop")
    }

    private func invalidateLifecycle(reason: String) {
        forget(reason: reason)
        lifecycleGeneration &+= 1
        retryAttempt = 0
        retryAt = nil
        terminalContext = nil
        automaticTask?.cancel()
        automaticTask = nil
        scheduleAutomatic()
    }

    private func scheduleAutomatic() {
        guard automaticTask == nil, sceneActive, selectedProjectID != nil,
              authenticationService != nil, bindingService != nil else { return }
        let revision = lifecycleGeneration
        automaticTask = Task { [weak self] in
            await self?.runAutomatic(revision: revision)
        }
    }

    private func runAutomatic(revision: UInt64) async {
        defer { if revision == lifecycleGeneration { automaticTask = nil } }
        while !Task.isCancelled, revision == lifecycleGeneration, sceneActive,
              let projectID = selectedProjectID,
              let auth = authenticationService, let bindings = bindingService {
            do {
                if let retryAt, retryAt > now() {
                    try await sleep(.seconds(retryAt.timeIntervalSince(now())))
                }
                try Task.checkCancellation()
                let authEpoch = auth.contractEpoch?.value ?? 0
                let bindingEpoch = bindings.contractEpoch?.value ?? 0
                let state = await auth.currentState()
                let binding = await bindings.currentBinding(for: projectID)
                guard revision == lifecycleGeneration, !Task.isCancelled else { return }
                guard bindings.contractEpoch?.isAvailable ?? true else { return }
                guard let serverID = binding?.serverProjectID,
                      let context = SyncV2HandshakeContext.make(authenticationState: state,
                          localProjectID: projectID, serverProjectID: serverID,
                          authenticationEpoch: authEpoch, bindingEpoch: bindingEpoch)
                else { return }
                guard authEpoch == (auth.contractEpoch?.value ?? 0),
                      bindingEpoch == (bindings.contractEpoch?.value ?? 0) else { continue }
                if standingHandshake(for: context) != nil || terminalContext == context { return }
                // 옛 실제 요청이 종료될 때까지 슬롯을 유지한다. 재시도 기한도 유지한다.
                if inFlight != nil {
                    try await sleep(.seconds(2))
                    continue
                }
                do {
                    _ = try await refresh(context: context)
                    guard revision == lifecycleGeneration else { return }
                    retryAttempt = 0; retryAt = nil
                    return
                } catch let error as SyncV2HandshakeError {
                    guard revision == lifecycleGeneration, !Task.isCancelled else { return }
                    if error == .superseded { continue }
                    guard error.isRetryable else { terminalContext = context; return }
                    let delay = Self.retryDelay(attempt: retryAttempt)
                    retryAttempt = min(retryAttempt + 1, 5)
                    retryAt = now().addingTimeInterval(Double(delay.components.seconds))
                }
            } catch { return }
        }
    }

    private static func classify(_ error: SyncV2HandshakeTransportError) -> SyncV2HandshakeError {
        switch error {
        case .authenticationRequired: return .authenticationRequired
        case .forbidden: return .forbidden
        case .networkUnavailable: return .networkUnavailable
        case .timedOut: return .timedOut
        case .invalidResponse: return .invalidResponse
        case .serverRejected: return .serverRejected
        case .contractRejected(let code):
            return code == "CONTRACT_NOT_ALLOWED" ? .contractUnavailable : .incompatible(SyncV2ContractError(code))
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
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var revisions: [String: UInt64] = [:]
    }
    private static let state = State()
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
        state.lock.withLock {
            state.revisions[revisionKey(localProjectID, defaults), default: 0] &+= 1
            defaults.set(isOpen, forKey: storageKey(for: localProjectID))
        }
    }

    static func close(
        for localProjectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) {
        state.lock.withLock {
            state.revisions[revisionKey(localProjectID, defaults), default: 0] &+= 1
            defaults.removeObject(forKey: storageKey(for: localProjectID))
        }
    }

    private static func revisionKey(_ id: ProjectID, _ defaults: UserDefaults) -> String {
        "\(ObjectIdentifier(defaults))-\(id.rawValue)"
    }

    static func revision(for id: ProjectID, in defaults: UserDefaults = .standard) -> UInt64 {
        state.lock.withLock { state.revisions[revisionKey(id, defaults), default: 0] }
    }

    static func openAfterValidation(
        for id: ProjectID, in defaults: UserDefaults, revision: UInt64,
        validate: () -> Bool
    ) -> Bool {
        state.lock.withLock {
            let key = revisionKey(id, defaults)
            guard state.revisions[key, default: 0] == revision, validate() else { return false }
            state.revisions[key, default: 0] &+= 1
            defaults.set(true, forKey: storageKey(for: id))
            return true
        }
    }

    /// 관문 변경과 송신 시작 예약 사이에 await를 두지 않는다.
    /// 예약 뒤의 닫힘은 이미 시작한 요청의 서버 취소를 뜻하지 않는다.
    static func reserveStart(
        for id: ProjectID, in defaults: UserDefaults,
        revision: UInt64, validate: () -> Bool
    ) throws {
        try state.lock.withLock {
            guard state.revisions[revisionKey(id, defaults), default: 0] == revision,
                  isOpen(for: id, in: defaults), validate()
            else { throw SyncV2ContractStructureError.gateClosed }
        }
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
