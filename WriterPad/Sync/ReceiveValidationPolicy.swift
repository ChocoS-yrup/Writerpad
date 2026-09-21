import CryptoKit
import Foundation

/// Foreground general-validation authority. Global sendingAllowed stays false.
/// Created only after the screen, account, binding and project gate checks. All
/// writes additionally require a predicted local mutation and all data HTTP uses
/// the append-only stage journal at URLProtocol's final wire boundary.
final class GeneralValidationCapability: @unchecked Sendable {
    @TaskLocal static var current: GeneralValidationCapability?
    let policy: ReceiveValidationPolicy
    let ticket: ReceiveValidationPolicy.Ticket
    let bearer: String
    var rawToken: String { String(bearer.dropFirst(7)) }
    private let checkCurrent: @Sendable () throws -> Void
    private let lock = NSRecursiveLock()
    private var stopped = false
    private var handshakeAttempted = false
    private var handshakeAccepted = false
    private var handshakeBound = false
    private var stage: GeneralValidationPlan.Stage?
    private var used = Set<GeneralValidationPlan.Stage>()
    private var requestHashes = Set<String>()
    private var standing: (@Sendable () throws -> Void)?
    init(policy: ReceiveValidationPolicy, ticket: ReceiveValidationPolicy.Ticket, bearer: String,
         current: @escaping @Sendable () throws -> Void) throws {
        guard policy.enabled, bearer.hasPrefix("Bearer "), bearer.count > 7 else { throw GeneralValidationFailure.denied }
        self.policy = policy; self.ticket = ticket; self.bearer = bearer; checkCurrent = current
        try check()
    }
    var scope: GeneralSyncValidationScope {
        .init(restricted: true, selection: .init(local: GeneralValidationPlan.local, server: GeneralValidationPlan.server,
            documents: [GeneralValidationPlan.document], reviewedRPCs: [], requiresJournal: true))
    }
    func check() throws {
        let checked = try lock.withLock {
            guard !stopped else { throw GeneralValidationFailure.denied }
            return standing
        }
        // Policy authorization also calls this capability. Do not hold our
        // lock while entering the policy lock in the opposite direction.
        try checkCurrent(); try checked?()
        try ReceiveValidationPolicy.$operation.withValue(ticket) { _ = try policy.authorization() }
        try lock.withLock { guard !stopped else { throw GeneralValidationFailure.denied } }
    }
    func isHandshake(_ request: URLRequest) throws -> Bool {
        guard request.url?.path == "/rest/v1/rpc/get_sync_handshake" else { return false }
        try check()
        return try lock.withLock {
            guard stage == nil, !handshakeBound, request.httpMethod == "POST",
                  request.url?.absoluteString == ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/get_sync_handshake",
                  request.value(forHTTPHeaderField: "Authorization") == bearer,
                  let body = request.httpBody,
                  let fields = try JSONSerialization.jsonObject(with: body) as? [String: String],
                  Set(fields.keys) == ["p_project_id", "p_contract_sha256"],
                  fields["p_project_id"].flatMap(UUID.init(uuidString:)) == GeneralValidationPlan.server,
                  fields["p_contract_sha256"] == SyncV2Contract.canonicalSHA256 else { throw GeneralValidationFailure.denied }
            return true
        }
    }
    func authorizeRPC(_ request: URLRequest) throws -> Bool {
        if try isHandshake(request) { return true }
        try check()
        return lock.withLock {
            stage == .sendUpdate && request.value(forHTTPHeaderField: "Authorization") == bearer &&
            requestHashes.contains(GeneralSyncValidationScope.fingerprint(request))
        }
    }
    func reserveHandshake(_ request: URLRequest) throws {
        guard try isHandshake(request) else { return }
        try lock.withLock {
            guard !handshakeAttempted else { throw GeneralValidationFailure.denied }
            handshakeAttempted = true
        }
    }
    func acceptHandshake(_ request: URLRequest, response: URLResponse) throws {
        guard try isHandshake(request) else { return }
        try lock.withLock {
            guard handshakeAttempted, !handshakeAccepted, (response as? HTTPURLResponse)?.statusCode == 200 else { throw GeneralValidationFailure.denied }
            handshakeAccepted = true
        }
    }
    func bindHandshake(_ checked: @escaping @Sendable () throws -> Void) throws {
        try check(); try checked()
        try lock.withLock {
            guard handshakeAccepted, !handshakeBound else { throw GeneralValidationFailure.denied }
            handshakeBound = true; standing = checked
        }
    }
    func begin(_ value: GeneralValidationPlan.Stage) throws {
        try check()
        try lock.withLock {
            guard handshakeBound, stage == nil, used.insert(value).inserted else { throw GeneralValidationFailure.denied }
            stage = value; requestHashes = []
        }
    }
    func register(_ requests: [URLRequest]) throws {
        try check()
        try lock.withLock {
            guard let stage, requestHashes.isEmpty else { throw GeneralValidationFailure.denied }
            for request in requests { _ = try GeneralValidationExecution.Frozen(request: request, stage: stage) }
            requestHashes = Set(requests.map(GeneralSyncValidationScope.fingerprint))
        }
    }
    func requireMutation(sending: Bool? = nil) throws {
        try check(); try GeneralValidationMutation.check()
        try lock.withLock {
            guard let stage, GeneralValidationMutation.current != nil,
                  sending == nil || sending == (stage == .sendUpdate) else { throw GeneralValidationFailure.denied }
        }
    }
    func finishStage() throws { try check(); lock.withLock { stage = nil; requestHashes = [] } }
    func stop() { lock.withLock { stopped = true; stage = nil; requestHashes = [] } }
    func withContext<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self) {
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                try await ReceiveValidationPolicy.$operation.withValue(ticket) {
                    try await ReceiveValidationPolicy.$localProject.withValue(GeneralValidationPlan.local.rawValue) {
                        try await GeneralSyncValidationScope.$override.withValue(scope, operation: work)
                    }
                }
            }
        }
    }
}

/// Opt-in at compile time. No defaults, launch argument or contract gate can unlock writes.
final class ReceiveValidationPolicy: @unchecked Sendable {
    struct Configuration: Codable, Equatable, Sendable {
        let version: Int
        let revision: UUID
        let endpoint: String
        let accountID: UUID
        var valid: Bool { version == 1 && endpoint == Self.staging }
        static let staging = "https://mhpnszcorfzrvhyondxr.supabase.co"
    }
    struct Ticket: Equatable, Sendable {
        let process: UUID
        let revision: UUID
        let generation: UUID
        let expires: Date
    }
    enum Denied: Error, LocalizedError {
        case locked
        var errorDescription: String? { "송신은 잠겨 있습니다. 수신 확인을 다시 준비해 주세요." }
    }
    @TaskLocal static var override: ReceiveValidationPolicy?
    @TaskLocal static var operation: Ticket?
    @TaskLocal static var localProject: UUID?
    @TaskLocal static var bodyRun: UUID?
#if DEBUG
    @TaskLocal static var mutationProbe: (@Sendable (String) async -> Void)?
#endif
    static func beforeMutation(_ name: String) async {
#if DEBUG
        await mutationProbe?(name)
#endif
    }
    static var current: ReceiveValidationPolicy { override ?? built }
    static let built: ReceiveValidationPolicy = {
#if DEBUG && (WRITERPAD_RECEIVE_VALIDATION || WRITERPAD_BODY_VALIDATION)
        let url = URL.applicationSupportDirectory.appendingPathComponent("ReceiveValidation/policy.json")
        return ReceiveValidationPolicy(enabled: true, configuration: try? PolicyStore(url: url).load(),
            bodyValidationEnabled: {
#if WRITERPAD_BODY_VALIDATION
                true
#else
                false
#endif
            }())
#else
        return ReceiveValidationPolicy(enabled: false, configuration: nil)
#endif
    }()
    typealias Network = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let network: Network
    let enabled: Bool
    let process = UUID()
    private let configuration: Configuration?
    private let now: @Sendable () -> Date
    // SQL claim validation re-enters synchronously inside mutate; no await occurs under this lock.
    private let lock = NSRecursiveLock()
    private var ticket: Ticket?
    private var verifiedAccount: UUID?
    private var selectedProject: UUID?
    private var receivingLocal: UUID?
    private var denials = 0
    let bodyValidationEnabled: Bool
    private var bodyContext: BodyContext?
    private struct BodyContext {
        let id: UUID
        let device: UUID
        let epochIsCurrent: @Sendable () -> Bool
        var phase: BodyPhase = .receive
        var operationID: UUID?
        var leaseToken: UUID?
        var dispatched = Set<String>()
    }
    enum BodyPhase { case receive, save, send }
    init(enabled: Bool, configuration: Configuration?, now: @escaping @Sendable () -> Date = { Date() },
         network: @escaping Network = ReceiveValidationPolicy.liveNetwork, bodyValidationEnabled: Bool = false) {
        self.bodyValidationEnabled = bodyValidationEnabled
        self.enabled = enabled; self.configuration = configuration?.valid == true ? configuration : nil
        self.now = now; self.network = network
    }
    var sendingAllowed: Bool { !enabled }
    var denialCount: Int { lock.withLock { denials } }
    func requireSending() throws {
        try GeneralValidationMutation.check()
        if let capability = GeneralValidationCapability.current, capability.policy === self {
            try capability.requireMutation(sending: true); return
        }
        if enabled { try lock.withLock { try deny() } }
    }
    private func deny() throws -> Never { denials += 1; throw Denied.locked }
    func invalidate() {
        lock.withLock { ticket = nil; verifiedAccount = nil; selectedProject = nil; receivingLocal = nil; bodyContext = nil }
    }
    /// Called only by an explicit foreground preparation button; never by restore/retry.
    func beginAuthentication(foreground: Bool, endpoint: String) throws -> Ticket? {
        guard enabled else { return nil }
        return try lock.withLock {
            guard bodyContext == nil, foreground, let configuration, configuration.endpoint == endpoint else { try deny() }
            let value = Ticket(process: process, revision: configuration.revision,
                               generation: UUID(), expires: now().addingTimeInterval(300))
            ticket = value; verifiedAccount = nil; selectedProject = nil; receivingLocal = nil
            return value
        }
    }
    private func check(_ expected: Ticket?) throws -> Ticket {
        guard let value = ticket, value.process == process, value.revision == configuration?.revision,
              value.expires > now(), expected == nil || expected == value else { try deny() }
        return value
    }
    func authorization() throws -> Ticket? {
        guard enabled else { return nil }
        return try lock.withLock { try check(Self.operation) }
    }
    func verifyAccount(_ id: UUID, ticket expected: Ticket?) throws {
        try withVerifiedAccount(id, ticket: expected) {}
    }
    func withVerifiedAccount<Value>(_ id: UUID, ticket expected: Ticket?, body: () throws -> Value) throws -> Value {
        guard enabled else { return try body() }
        try Task.checkCancellation()
        return try lock.withLock {
            _ = try check(expected)
            guard configuration?.accountID == id else {
                ticket = nil; verifiedAccount = nil; selectedProject = nil; receivingLocal = nil; try deny()
            }
            verifiedAccount = id
            return try body()
        }
    }
    func requireRead(account: UUID? = nil, endpoint: String? = nil, project: UUID? = nil) throws {
        if let project { try GeneralSyncValidationScope.current.require(server: project) }
        guard enabled else { return }
        try Task.checkCancellation()
        try lock.withLock {
            _ = try check(Self.operation)
            if Self.bodyRun != nil { try checkBodyLocked() }
            if (account != nil && account != configuration?.accountID)
                || (endpoint != nil && endpoint != configuration?.endpoint) {
                ticket = nil; verifiedAccount = nil; selectedProject = nil; receivingLocal = nil
                try deny()
            }
            guard let verifiedAccount, verifiedAccount == configuration?.accountID,
                  account == nil || account == verifiedAccount,
                  endpoint == nil || endpoint == configuration?.endpoint,
                  project == nil || selectedProject == project else { try deny() }
        }
    }
    private func checkReadLocked(project: UUID? = nil) throws {
        _ = try check(Self.operation)
        if Self.bodyRun != nil { try checkBodyLocked() }
        guard verifiedAccount != nil, verifiedAccount == configuration?.accountID,
              project == nil || selectedProject == project else { try deny() }
    }
    func select(_ project: UUID) throws {
        try GeneralSyncValidationScope.current.require(server: project)
        guard enabled else { return }
        try Task.checkCancellation()
        try lock.withLock {
            try checkReadLocked()
            selectedProject = project; receivingLocal = nil
        }
    }
    func authorizeReceiving(_ journal: ServerReceivingJournal) throws {
        guard enabled else { return }
        try Task.checkCancellation()
        try lock.withLock {
            try checkReadLocked(project: journal.serverProjectID)
            guard Self.operation != nil, journal.accountID == verifiedAccount,
                  journal.endpoint == configuration?.endpoint,
                  journal.project.id.rawValue == journal.serverProjectID,
                  journal.version == 1, journal.localIdentityPolicy == "server_uuid_for_new_project" else { try deny() }
            receivingLocal = journal.project.id.rawValue
        }
    }
    /// File appliers have a local identity only. The general runner binds the
    /// different server identity; ordinary receive validation keeps its rule.
    func requireLocalApplication(local: ProjectID) throws {
        let server = GeneralValidationCapability.current?.policy === self
            ? GeneralValidationPlan.server : local.rawValue
        try requireApplication(local: local, server: server)
    }
    func requireApplication(local: ProjectID, server: UUID) throws {
        try GeneralValidationMutation.check()
        try GeneralSyncValidationScope.current.require(local: local, server: server)
        guard enabled else { return }
        if let capability = GeneralValidationCapability.current, capability.policy === self {
            guard local == GeneralValidationPlan.local, server == GeneralValidationPlan.server else { throw Denied.locked }
            try requireRead(project: server); try capability.requireMutation(sending: false); return
        }
        try Task.checkCancellation()
        try lock.withLock {
            try checkReadLocked(project: server)
            guard Self.operation != nil, Self.localProject == server,
                  local.rawValue == server, receivingLocal == local.rawValue else { try deny() }
        }
    }
    /// Synchronous commit only: actor waits/probes happen before this lock.
    /// Cancellation cannot interleave with a filesystem mutation or SQL/SwiftData commit.
    func mutate<Value>(local: ProjectID? = nil, body: () throws -> Value) throws -> Value {
        try GeneralValidationMutation.check()
        if let local { try GeneralSyncValidationScope.current.require(local: local) }
        guard enabled else { return try body() }
        if let capability = GeneralValidationCapability.current, capability.policy === self {
            guard Self.localProject == GeneralValidationPlan.local.rawValue, local == nil || local == GeneralValidationPlan.local else { throw Denied.locked }
            return try lock.withLock {
                try requireRead(project: GeneralValidationPlan.server); try capability.requireMutation(); return try body()
            }
        }
        try Task.checkCancellation()
        return try lock.withLock {
            guard Self.operation != nil, let project = Self.localProject,
                  local == nil || local?.rawValue == project else { try deny() }
            try checkReadLocked(project: project)
            if Self.bodyRun != nil { try checkBodyLocked() }
            return try body()
        }
    }
    /// Shared repositories also serve ordinary local edits and database initialization.
    /// Only a structured receive operation carries this context; it is never refreshed at a writer.
    func mutateIfReceiving<Value>(body: () throws -> Value) throws -> Value {
        try GeneralValidationMutation.check()
        if Self.localProject == nil { return try body() }
        return try mutate(body: body)
    }
    /// Allowlist is semantic: auth POST is permitted, all data RPC writes are denied.
    func authorize(_ request: URLRequest, ticket expected: Ticket? = nil) throws -> Ticket? {
        guard enabled else { return nil }
        try Task.checkCancellation()
        return try lock.withLock {
            let value = try check(expected ?? Self.operation)
            guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.fragment == nil,
                  parts.scheme == "https", parts.port == nil,
                  "https://\(parts.host ?? "")" == configuration?.endpoint else { try deny() }
            if bodyContext != nil { try checkBodyLocked(requireTask: false) }
            let method = request.httpMethod ?? "GET"
            let items = parts.queryItems ?? []
            if url.path == "/auth/v1/token", method == "POST",
               items.count == 1, items[0].name == "grant_type",
               ["password", "refresh_token"].contains(items[0].value ?? "") { return value }
            if url.path == "/auth/v1/user", method == "GET", items.isEmpty { return value }
            if method == "POST", url.path.hasPrefix("/rest/v1/rpc/") {
                if let capability = GeneralValidationCapability.current, capability.policy === self {
                    guard verifiedAccount == configuration?.accountID, verifiedAccount != nil,
                          selectedProject == GeneralValidationPlan.server, try capability.authorizeRPC(request) else { try deny() }
                    return value
                }
                try authorizeBodyRPCLocked(request)
                return value
            }
            guard verifiedAccount == configuration?.accountID, verifiedAccount != nil, method == "GET" else { try deny() }
            if url.path == "/rest/v1/projects" {
                guard items.allSatisfy({ ["select", "trashed_at", "project_id", "order", "limit"].contains($0.name) }),
                      items.filter({ $0.name == "select" }).map(\.value) == ["project_id,name"] else { try deny() }
                if let filter = items.first(where: { $0.name == "project_id" })?.value, filter.hasPrefix("eq.") {
                    guard UUID(uuidString: String(filter.dropFirst(3))) == selectedProject else { try deny() }
                }
                return value
            }
            if ["/rest/v1/documents", "/rest/v1/folders", "/rest/v1/tree_orders"].contains(url.path) {
                let filters = items.filter { $0.name == "project_id" }
                guard let selectedProject, filters.count == 1,
                      filters[0].value?.lowercased() == "eq.\(selectedProject.uuidString.lowercased())",
                      !items.contains(where: { $0.name == "or" || $0.name == "and" }) else { try deny() }
                return value
            }
            try deny()
        }
    }
    func validateResponse(_ data: Data, request: URLRequest, ticket: Ticket?) throws {
        _ = try authorize(request, ticket: ticket)
        if enabled, request.url?.path.hasPrefix("/auth/v1/") == true,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let user = (object["user"] as? [String: Any]) ?? object
            if let rawID = user["id"] as? String, let id = UUID(uuidString: rawID) {
                // Checking an SDK refresh response must not grant account reads by itself.
                guard id == configuration?.accountID else { invalidate(); throw Denied.locked }
            }
        }
    }
    /// No suspension between final permission check and journal publication.
    func publish<Value>(_ journal: ServerReceivingJournal, body: () throws -> Value) throws -> Value {
        guard enabled else { return try body() }
        try Task.checkCancellation()
        return try lock.withLock {
            _ = try check(Self.operation)
            guard verifiedAccount == journal.accountID, configuration?.endpoint == journal.endpoint,
                  selectedProject == journal.serverProjectID, receivingLocal == journal.project.id.rawValue else { try deny() }
            return try body()
        }
    }

    static func liveNetwork(_ request: URLRequest) async throws -> (Data, URLResponse) {
#if WRITERPAD_ISOLATED_TESTS
        throw URLError(.notConnectedToInternet)
#else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(configuration: configuration, delegate: ReceiveValidationNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
#endif
    }


    /// A separate foreground capability. Global writers remain locked throughout.
    func withBodyValidation<Value: Sendable>(binding: ProjectSyncBinding, device: UUID,
        foreground: Bool, epochIsCurrent: @escaping @Sendable () -> Bool,
        body: @Sendable () async throws -> Value) async throws -> Value {
        let ticket = try authorization()
        let id = UUID()
        try lock.withLock {
            guard enabled, bodyValidationEnabled, foreground, bodyContext == nil,
                  binding.localProjectID == BodyValidationPlan.local,
                  binding.serverProjectID == BodyValidationPlan.project,
                  binding.ownerSubject == verifiedAccount, verifiedAccount == configuration?.accountID,
                  verifiedAccount != nil, binding.kind != .localOnly, epochIsCurrent() else { try deny() }
            selectedProject = BodyValidationPlan.project
            receivingLocal = BodyValidationPlan.project
            bodyContext = .init(id: id, device: device, epochIsCurrent: epochIsCurrent)
        }
        defer { lock.withLock { if bodyContext?.id == id { bodyContext = nil; receivingLocal = nil } } }
        return try await Self.$operation.withValue(ticket) {
            try await Self.$localProject.withValue(BodyValidationPlan.project) {
                try await Self.$bodyRun.withValue(id) {
                    try await withTaskCancellationHandler {
                        let result = try await body()
                        try requireBody()
                        return result
                    } onCancel: { self.invalidate() }
                }
            }
        }
    }
    private func checkBodyLocked(requireTask: Bool = true) throws {
        _ = try check(Self.operation)
        guard enabled, bodyValidationEnabled, let context = bodyContext,
              !requireTask || Self.bodyRun == context.id,
              verifiedAccount != nil, verifiedAccount == configuration?.accountID,
              selectedProject == BodyValidationPlan.project,
              receivingLocal == BodyValidationPlan.project, context.epochIsCurrent() else { try deny() }
    }
    func requireBody(local: ProjectID = BodyValidationPlan.local) throws {
        try Task.checkCancellation()
        try lock.withLock {
            try checkBodyLocked()
            guard local == BodyValidationPlan.local else { try deny() }
        }
    }
    func bodyPhase(_ phase: BodyPhase) throws {
        try Task.checkCancellation()
        try lock.withLock {
            try checkBodyLocked()
            // The run can only progress forward; no retry may reopen a phase.
            guard (bodyContext?.phase == .receive && phase == .save)
                || (bodyContext?.phase == .save && phase == .send) else { try deny() }
            bodyContext?.phase = phase
        }
    }
    func requireBodyEnqueue(_ batch: SyncV2EnqueueBatch) throws {
        guard enabled else { return }
        try requireBody(local: batch.localProjectID)
        try lock.withLock {
            guard bodyContext?.phase == .save, batch.mutations.count == 1,
                  case let .document(m) = batch.mutations[0], m.kind == .documentCommit,
                  m.documentID == BodyValidationPlan.document, m.deviceID == bodyContext?.device,
                  m.relativePath == BodyValidationPlan.path, !m.isDeleted,
                  BodyValidationPlan.matches(m.content, BodyValidationPlan.outgoing) else { try deny() }
            guard bodyContext?.operationID == nil || bodyContext?.operationID == m.operationID else { try deny() }
            bodyContext?.operationID = m.operationID
        }
    }
    func requireBodyOperation(_ operation: SyncV2DispatchOperation) throws {
        guard enabled else { return }
        guard let local = operation.localProjectID else { throw Denied.locked }
        try requireBody(local: local)
        try lock.withLock {
            guard bodyContext?.phase == .send,
                  operation.operationID == bodyContext?.operationID,
                  operation.documentID == BodyValidationPlan.document,
                  operation.projectID == BodyValidationPlan.project,
                  operation.deviceID == bodyContext?.device,
                  operation.kind == .documentCommit, operation.baseRevision == 2,
                  BodyValidationPlan.matches(operation.baseContent, BodyValidationPlan.incoming),
                  operation.relativePath == BodyValidationPlan.path,
                  BodyValidationPlan.matches(operation.content, BodyValidationPlan.outgoing), !operation.isDeleted else { try deny() }
        }
    }
    func requireBodyCommit(_ p: SyncV2CommitDocumentParameters) throws {
        guard enabled else { return }
        try requireBody()
        var r = URLRequest(url: URL(string: Configuration.staging + "/rest/v1/rpc/commit_document")!)
        r.httpMethod = "POST"; r.httpBody = try JSONEncoder().encode(p)
        _ = try authorize(r)
    }
    func bodyLease(_ token: UUID) throws {
        try requireBody()
        lock.withLock { bodyContext?.leaseToken = token }
    }
    private func authorizeBodyRPCLocked(_ request: URLRequest) throws {
        // URLProtocol runs outside task-local values; its session is already bound to the ticket.
        try checkBodyLocked(requireTask: false)
        guard request.url?.query == nil, let bytes = request.httpBody,
              let o = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { try deny() }
        func uuid(_ key: String) -> UUID? { (o[key] as? String).flatMap(UUID.init(uuidString:)) }
        switch request.url?.lastPathComponent {
        case "get_sync_handshake":
            guard Set(o.keys) == ["p_project_id", "p_contract_sha256"],
                  uuid("p_project_id") == BodyValidationPlan.project,
                  o["p_contract_sha256"] as? String == SyncV2Contract.canonicalSHA256 else { try deny() }
        case "acquire_edit_lease":
            guard bodyContext?.phase == .send,
                  Set(o.keys) == ["p_document_id", "p_device_id", "p_ttl_seconds"],
                  uuid("p_document_id") == BodyValidationPlan.document,
                  uuid("p_device_id") == bodyContext?.device,
                  o["p_ttl_seconds"] as? Int == 60 else { try deny() }
        case "release_edit_lease":
            guard bodyContext?.phase == .send, bodyContext?.leaseToken != nil,
                  Set(o.keys) == ["p_document_id", "p_device_id", "p_lease_token"],
                  uuid("p_document_id") == BodyValidationPlan.document,
                  uuid("p_device_id") == bodyContext?.device,
                  uuid("p_lease_token") == bodyContext?.leaseToken else { try deny() }
        case "commit_document":
            guard bodyContext?.phase == .send, bodyContext?.operationID != nil, bodyContext?.leaseToken != nil,
                  Set(o.keys) == ["p_document_id", "p_project_id", "p_base_revision", "p_operation_id", "p_device_id", "p_relative_path", "p_content", "p_is_deleted", "p_lease_token"],
                  uuid("p_project_id") == BodyValidationPlan.project,
                  uuid("p_document_id") == BodyValidationPlan.document,
                  uuid("p_device_id") == bodyContext?.device,
                  uuid("p_operation_id") == bodyContext?.operationID,
                  uuid("p_lease_token") == bodyContext?.leaseToken,
                  o["p_base_revision"] as? Int == 2,
                  o["p_relative_path"] as? String == BodyValidationPlan.path,
                  (o["p_content"] as? String).map({ BodyValidationPlan.matches($0, BodyValidationPlan.outgoing) }) == true,
                  o["p_is_deleted"] as? Bool == false else { try deny() }
        default: try deny()
        }
    }
    /// Reserve at the actual HTTP boundary, once per RPC. Checks/response validation do not consume it.
    func reserveBodyRequest(_ request: URLRequest) throws {
        guard enabled else { return }
        try lock.withLock {
            guard bodyContext != nil, request.url?.path.hasPrefix("/rest/v1/rpc/") == true else { return }
            try authorizeBodyRPCLocked(request)
            let rpc = request.url!.lastPathComponent
            guard bodyContext!.dispatched.insert(rpc).inserted else { try deny() }
        }
    }

    struct PolicyStore {
        let url: URL
        func load() throws -> Configuration {
            let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            guard value.valid else { throw Denied.locked }
            return value
        }
        func save(_ value: Configuration) throws {
            guard value.valid else { throw Denied.locked }
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }
}

/// The SDK and raw RPC client use this same final boundary. The inner session has
/// no protocol recursion, no cookies/cache, and refuses every redirect.
final class ReceiveValidationURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        struct Context { let policy: ReceiveValidationPolicy; let ticket: ReceiveValidationPolicy.Ticket?; let scope: GeneralSyncValidationScope; let execution: GeneralValidationExecution?; let localMutation: Bool; let capability: GeneralValidationCapability? }
        var contexts: [String: Context] = [:]
    }
    private static let registry = Registry()
    private static let policyHeader = "X-WriterPad-Receive-Policy"
    private var operationTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        // Foundation may convert POST Data into an InputStream before URLProtocol.
        // Materialize a bounded body once, then authorize and forward those exact bytes.
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                guard count > 0, bytes.count + count <= 65_536 else {
                    client?.urlProtocol(self, didFailWithError: ReceiveValidationPolicy.Denied.locked)
                    return
                }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            request.httpBodyStream = nil
            request.httpBody = bytes
        }
        let key = request.value(forHTTPHeaderField: Self.policyHeader) ?? ""
        let context = Self.registry.lock.withLock { Self.registry.contexts[key] }
        request.setValue(nil, forHTTPHeaderField: Self.policyHeader)
        let outgoing = request
        operationTask = Task {
            do {
                let request = outgoing
                guard let context, !context.localMutation, !context.policy.enabled || context.ticket != nil else { throw ReceiveValidationPolicy.Denied.locked }
                try await GeneralValidationCapability.$current.withValue(context.capability) {
                let policy = context.policy, ticket = context.ticket
                try context.scope.authorize(request)
                _ = try policy.authorize(request, ticket: ticket)
                try policy.reserveBodyRequest(request)
                if context.scope.restricted, context.scope.selection?.requiresJournal == true,
                   request.url?.path.hasPrefix("/rest/") == true, context.execution == nil,
                   try context.capability?.isHandshake(request) != true {
                    throw GeneralValidationFailure.denied
                }
                try context.capability?.reserveHandshake(request)
                try context.execution?.begin(request)
                let (data, response) = try await policy.network(request)
                try Task.checkCancellation()
                try context.scope.authorize(request)
                try policy.validateResponse(data, request: request, ticket: ticket)
                guard response.url == request.url else { throw ReceiveValidationPolicy.Denied.locked }
                try context.capability?.acceptHandshake(request, response: response)
                try context.execution?.accept(data, response: response, request: request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                }
            } catch { context?.capability?.stop(); context?.execution?.stop(); client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { operationTask?.cancel() }
    static func session(policy: ReceiveValidationPolicy = .current) -> URLSession {
        return session(policy: policy, ticket: try? policy.authorization())
    }
    static func session(policy: ReceiveValidationPolicy, ticket: ReceiveValidationPolicy.Ticket?) -> URLSession {
        // Each session is permanently bound to its originating grant, including SDK refresh.
        let key = UUID().uuidString
        registry.lock.withLock { registry.contexts[key] = .init(policy: policy, ticket: ticket, scope: GeneralSyncValidationScope.current, execution: GeneralValidationExecution.current, localMutation: GeneralValidationMutation.current != nil, capability: GeneralValidationCapability.current) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReceiveValidationURLProtocol.self]
        configuration.httpAdditionalHeaders = [policyHeader: key]
        return URLSession(configuration: configuration)
    }
}
final class ReceiveValidationNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

#if WRITERPAD_ISOLATED_TESTS
/// Test host fallback: explicitly supplied fake protocols take precedence.
final class ReceiveValidationTestNetworkBlock: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
#endif

/// Proposed immutable synthetic body contract. A different Windows plan requires a new reviewed build.
enum BodyValidationPlan {
    static func matches(_ value: String, _ expected: String) -> Bool { value.utf8.elementsEqual(expected.utf8) }
    static let project = UUID(uuidString: "9a78c51c-7de9-43a8-be54-d25a22d08a28")!
    static let local = ProjectID(rawValue: project)
    static let document = UUID(uuidString: "502cdbe7-814c-42f8-8ed4-81c40cd94902")!
    static let path = "메인/원고/1권/1화.txt"
    static let baseline = "본문 수신 검증 20260911\n이 문서는 동기화 시험용 합성 원고입니다.\n끝.\n"
    static let incoming = baseline + "Windows 양방향 검증 20260911\n"
    static let outgoing = incoming + "iPad 양방향 검증 20260911\n"
}
