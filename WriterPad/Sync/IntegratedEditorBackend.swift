import Foundation

struct IntegratedRemoteSnapshot: Codable, Sendable, SyncV2SnapshotClienting {
    let documents: [SyncV2RemoteDocumentSnapshot]
    let folders: [SyncV2RemoteFolder]
    let orders: [SyncV2RemoteTreeOrder]
    func fetchDocuments(projectID: UUID) async throws -> [SyncV2RemoteDocumentSnapshot] { try check(projectID); return documents }
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] { try check(projectID); return folders }
    func fetchTreeOrders(projectID: UUID) async throws -> [SyncV2RemoteTreeOrder] { try check(projectID); return orders }
    private func check(_ project: UUID) throws { guard project == IntegratedEditorPlan.server else { throw IntegratedEditorError.scope } }
    var metadata: SyncV2PreparationSnapshot {
        func uuid(_ id: UUID?) -> SyncV2JSON { id.map { .string($0.uuidString.lowercased()) } ?? .null }
        let project = uuid(IntegratedEditorPlan.server)
        return .init(folders: folders.map { .object(["project_id": project, "folder_id": uuid($0.folderID),
            "parent_folder_id": uuid($0.parentFolderID), "name": .string($0.name), "revision": .int(Int($0.revision)), "is_deleted": .bool($0.isDeleted)]) },
            documents: documents.map { .object(["project_id": project, "document_id": uuid($0.documentID), "relative_path": .string($0.relativePath),
                "revision": .int(Int($0.revision)), "parent_folder_id": uuid($0.parentFolderID), "name": $0.name.map(SyncV2JSON.string) ?? .null,
                "structure_revision": $0.structureRevision.map { .int(Int($0)) } ?? .null, "is_deleted": .bool($0.isDeleted)]) },
            treeOrders: orders.map { .object(["project_id": project, "tree_order_id": uuid($0.treeOrderID),
                "parent_folder_id": uuid($0.parentFolderID), "children": .array($0.children.map { uuid($0) }), "revision": .int(Int($0.revision))]) })
    }
    /// New remote IDs may enter only through the designated test subtree. Every other baseline row is immutable.
    func validate(baseline: SyncV2PreparationSnapshot, members: Set<UUID>) throws -> Set<UUID> {
        guard documents.count <= 64, folders.count <= 64, orders.count <= 64,
              Set(documents.map(\.documentID)).count == documents.count,
              Set(folders.map(\.folderID)).count == folders.count,
              Set(orders.map(\.treeOrderID)).count == orders.count,
              let protected = documents.first(where: { $0.documentID == IntegratedEditorPlan.protectedDocument }),
              protected.revision == 9, protected.structureRevision == 1, !protected.isDeleted,
              protected.parentFolderID == NormalEditorPlan.parent,
              protected.relativePath == NormalEditorPlan.path,
              IntegratedEditorPlan.hash(protected.content) == "570040e0bd94d5ff31c64799d549775ef74eb14503b7fa374f170ad7297b764f" else { throw IntegratedEditorError.scope }
        var allowed = members
        for folder in folders where folder.parentFolderID == IntegratedEditorPlan.parent && folder.name == IntegratedEditorPlan.rootName {
            allowed.insert(folder.folderID)
        }
        for _ in 0..<folders.count {
            for folder in folders where folder.parentFolderID.map(allowed.contains) == true { allowed.insert(folder.folderID) }
        }
        for doc in documents where doc.parentFolderID.map(allowed.contains) == true {
            guard IntegratedEditorPlan.contains(doc.relativePath) || doc.isDeleted else { throw IntegratedEditorError.scope }
            allowed.insert(doc.documentID)
        }
        guard !allowed.contains(IntegratedEditorPlan.protectedDocument), !allowed.contains(IntegratedEditorPlan.parent) else { throw IntegratedEditorError.scope }
        let existingIDs = Set((baseline.documents + baseline.folders).compactMap {
            ($0.objectValue?["document_id"] ?? $0.objectValue?["folder_id"])?.stringValue.flatMap(UUID.init(uuidString:))
        })
        guard allowed.subtracting(members).isDisjoint(with: existingIDs) else { throw IntegratedEditorError.scope }
        let roots = folders.filter { $0.parentFolderID == IntegratedEditorPlan.parent && $0.name == IntegratedEditorPlan.rootName && !$0.isDeleted }
        guard roots.count <= 1 else { throw IntegratedEditorError.scope }
        for folder in folders where allowed.contains(folder.folderID) && !folder.isDeleted {
            guard folder.parentFolderID.map(allowed.contains) == true ||
                (folder.parentFolderID == IntegratedEditorPlan.parent && folder.name == IntegratedEditorPlan.rootName) else { throw IntegratedEditorError.scope }
        }
        for doc in documents where allowed.contains(doc.documentID) && !doc.isDeleted {
            guard doc.parentFolderID.map(allowed.contains) == true, IntegratedEditorPlan.contains(doc.relativePath) else { throw IntegratedEditorError.scope }
        }
        let remote = metadata
        func unchanged(_ old: [SyncV2JSON], _ new: [SyncV2JSON], id: String) throws {
            func outside(_ rows: [SyncV2JSON]) throws -> [String: SyncV2JSON] {
                var values: [String: SyncV2JSON] = [:]
                for row in rows {
                    guard let key = row.objectValue?[id]?.stringValue, let uuid = UUID(uuidString: key), values[key] == nil else { throw IntegratedEditorError.scope }
                    if !allowed.contains(uuid) { values[key] = row }
                }
                return values
            }
            guard try outside(old) == outside(new) else { throw IntegratedEditorError.scope }
        }
        try unchanged(baseline.documents, remote.documents, id: "document_id")
        try unchanged(baseline.folders, remote.folders, id: "folder_id")
        for row in remote.treeOrders {
            guard let fields = row.objectValue else { throw IntegratedEditorError.scope }
            let parent = fields["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            if parent.map(allowed.contains) == true {
                guard let children = fields["children"]?.arrayValue,
                      children.allSatisfy({ $0.stringValue.flatMap(UUID.init(uuidString:)).map(allowed.contains) == true }) else { throw IntegratedEditorError.scope }
                continue
            }
            guard let old = baseline.treeOrders.first(where: { $0.objectValue?["tree_order_id"] == fields["tree_order_id"] }) else { throw IntegratedEditorError.scope }
            if parent == IntegratedEditorPlan.parent {
                let before = old.objectValue?["children"]?.arrayValue ?? []
                let after = fields["children"]?.arrayValue ?? []
                let retained: (SyncV2JSON) -> Bool = { $0.stringValue.flatMap(UUID.init(uuidString:)).map { !allowed.contains($0) } ?? true }
                guard before.filter(retained) == after.filter(retained) else { throw IntegratedEditorError.scope }
            } else { guard row == old else { throw IntegratedEditorError.scope } }
        }
        let remoteOrderIDs = Set(remote.treeOrders.compactMap { $0.objectValue?["tree_order_id"]?.stringValue })
        guard baseline.treeOrders.allSatisfy({ remoteOrderIDs.contains($0.objectValue?["tree_order_id"]?.stringValue ?? "") }) else { throw IntegratedEditorError.scope }
        return allowed
    }
}

/// Task-local authority never changes global preferences or the existing contract gate.
final class IntegratedEditorAuthority: @unchecked Sendable {
    @TaskLocal static var current: IntegratedEditorAuthority?
    @TaskLocal static var sending: Bool?
    let policy: ReceiveValidationPolicy
    let ticket: ReceiveValidationPolicy.Ticket
    let journal: IntegratedEditorJournal
    private let currentCheck: @Sendable () throws -> Void
    private let lock = NSLock()
    private var stopped = false
    private var bearer: String?
    private var authEpoch: (SyncV2ContractEpoch, UInt64)?
    init(policy: ReceiveValidationPolicy, ticket: ReceiveValidationPolicy.Ticket, journal: IntegratedEditorJournal,
         check: @escaping @Sendable () throws -> Void) {
        self.policy = policy; self.ticket = ticket; self.journal = journal; currentCheck = check
    }
    func bind(_ bearer: String, epoch: SyncV2ContractEpoch? = nil) {
        lock.withLock { self.bearer = bearer; self.authEpoch = epoch.map { ($0, $0.value) } }
    }
    func stop() { lock.withLock { stopped = true } }
    func includesOrderParent(_ parent: UUID?) -> Bool {
        parent == IntegratedEditorPlan.parent || parent.map(journal.state().members.contains) == true
    }
    func check() throws {
        try Task.checkCancellation(); try currentCheck(); try journal.checkTime()
        guard !lock.withLock({ stopped }) else { throw IntegratedEditorError.locked }
        if let epoch = lock.withLock({ authEpoch }) {
            guard epoch.0.isAvailable, epoch.0.value == epoch.1 else { throw IntegratedEditorError.locked }
        }
        try ReceiveValidationPolicy.$operation.withValue(ticket) { _ = try policy.authorization() }
    }
    func requireMutation(sending expected: Bool? = nil) throws {
        try check()
        guard lock.withLock({ bearer != nil }), let sending = Self.sending,
              expected == nil || expected == sending else { throw IntegratedEditorError.locked }
    }
    func authorize(_ request: URLRequest) throws {
        try check()
        guard let parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              parts.scheme == "https", parts.host == "mhpnszcorfzrvhyondxr.supabase.co",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
              request.httpBodyStream == nil else { throw IntegratedEditorError.scope }
        let method = request.httpMethod ?? "GET", items = parts.queryItems ?? []
        if journal.diagnosticRestricted {
            guard ["/auth/v1/token", "/auth/v1/user", "/rest/v1/rpc/get_sync_handshake", "/rest/v1/rpc/get_project_status",
                   "/rest/v1/sync_batches", "/rest/v1/sync_batch_results"].contains(parts.path) else { throw IntegratedEditorError.diagnostic }
        }
        guard Set(items.map(\.name)).count == items.count else { throw IntegratedEditorError.scope }
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        if parts.path == "/auth/v1/token", method == "POST", query.count == 1,
           ["password", "refresh_token"].contains(query["grant_type"] ?? "") { return }
        if parts.path == "/auth/v1/user", method == "GET", query.isEmpty { return }
        guard let bearer = lock.withLock({ bearer }), request.value(forHTTPHeaderField: "Authorization") == bearer else { throw IntegratedEditorError.locked }
        let server = IntegratedEditorPlan.server.uuidString.lowercased()
        if method == "POST", items.isEmpty, let body = request.httpBody {
            let fields = try JSONDecoder().decode(SyncV2JSON.self, from: body).objectValue ?? [:]
            if parts.path == "/rest/v1/rpc/get_sync_handshake" {
                guard Set(fields.keys) == ["p_project_id", "p_contract_sha256"], fields["p_project_id"]?.stringValue?.lowercased() == server,
                      fields["p_contract_sha256"] == .string(SyncV2Contract.canonicalSHA256) else { throw IntegratedEditorError.scope }; return
            }
            if parts.path == "/rest/v1/rpc/get_project_status" {
                guard fields == ["p_project_id": .string(server)] else { throw IntegratedEditorError.scope }; return
            }
            guard ["/rest/v1/rpc/document_commit", "/rest/v1/rpc/atomic_structure_commit"].contains(parts.path),
                  Set(fields.keys) == ["p_request"], let json = fields["p_request"],
                  let index = journal.state().activeWire else { throw IntegratedEditorError.scope }
            let wire = journal.state().wires[index]
            guard wire.phase == .frozen, json == wire.request, try json.sha256Hex() == wire.hash else { throw IntegratedEditorError.receipt }
            let expected = json.objectValue?["kind"] == .string("document_commit_request") ? "document_commit" : "atomic_structure_commit"
            guard parts.path == "/rest/v1/rpc/" + expected else { throw IntegratedEditorError.scope }; return
        }
        guard method == "GET", request.httpBody == nil, request.value(forHTTPHeaderField: "Prefer") == "count=exact",
              query["limit"] == "65", let table = request.url?.lastPathComponent,
              parts.path == "/rest/v1/" + table else { throw IntegratedEditorError.scope }
        if let columns = GeneralValidationRemoteSnapshot.columns[table] {
            guard query == ["select": columns, "project_id": "eq." + server, "limit": "65"] else { throw IntegratedEditorError.scope }; return
        }
        guard let index = journal.state().activeWire, journal.state().wires[index].phase == .httpStarted,
              let batch = journal.state().wires[index].request.objectValue?["batch"]?.objectValue?["batch_id"]?.stringValue else { throw IntegratedEditorError.receipt }
        let columns = table == "sync_batches" ? IntegratedEditorBackend.batchColumns : IntegratedEditorBackend.resultColumns
        var expected = ["select": columns, "limit": "65", "batch_id": "eq." + batch]
        if table == "sync_batches" { expected["project_id"] = "eq." + server }
        guard ["sync_batches", "sync_batch_results"].contains(table), query == expected else { throw IntegratedEditorError.scope }
    }
    func context<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self) {
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                try await ReceiveValidationPolicy.$operation.withValue(ticket, operation: operation)
            }
        }
    }
    func mutate<T: Sendable>(sending: Bool, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await context {
            try await Self.$sending.withValue(sending) {
                try self.requireMutation(sending: sending)
                return try await ReceiveValidationPolicy.$localProject.withValue(IntegratedEditorPlan.local.rawValue) {
                    try await GeneralValidationMutation.$current.withValue({ try self.requireMutation(sending: sending) }, operation: operation)
                }
            }
        }
    }
}

actor IntegratedEditorBackend {
    static let batchColumns = "batch_id,project_id,writer_user_id,writer_device_id,client_build_id,sync_protocol_version,contract_version,canonical_contract_sha256,client_capabilities,batch_payload_sha256,project_sync_mode,migration_epoch,request_sha256"
    static let resultColumns = "batch_id,applied,response,response_sha256"
    let store: LazySyncV2ProjectBindingStore
    let journal: IntegratedEditorJournal
    let auth: any AuthenticationServicing
    let configuration: SupabasePublicConfiguration
    let bindingEpoch: SyncV2ContractEpoch
    let projectEpoch: SyncV2ContractEpoch
    let lifecycle = SyncV2ContractEpoch()
    let makePuller: @Sendable (IntegratedRemoteSnapshot) -> any SyncV2SnapshotPulling
    private var authority: IntegratedEditorAuthority?
    private var handshake: SyncV2ValidatedHandshake?
    private var binding: ProjectSyncBinding?
    private var dispatching = false
    init(store: LazySyncV2ProjectBindingStore, journal: IntegratedEditorJournal, auth: any AuthenticationServicing,
         configuration: SupabasePublicConfiguration, bindingEpoch: SyncV2ContractEpoch, projectEpoch: SyncV2ContractEpoch,
         makePuller: @escaping @Sendable (IntegratedRemoteSnapshot) -> any SyncV2SnapshotPulling) {
        self.store = store; self.journal = journal; self.auth = auth; self.configuration = configuration
        self.bindingEpoch = bindingEpoch; self.projectEpoch = projectEpoch; self.makePuller = makePuller
    }
    func invalidate() { authority?.stop(); authority = nil; handshake = nil; lifecycle.advance() }
    private func grant() throws -> IntegratedEditorAuthority {
        guard let authority else { throw IntegratedEditorError.locked }; try authority.check(); return authority
    }
    private func begin() throws -> IntegratedEditorAuthority {
        invalidate(); try journal.checkTime()
        guard configuration.url.absoluteString == ReceiveValidationPolicy.Configuration.staging,
              ContractPathGate.isOpen(for: IntegratedEditorPlan.local) else { throw IntegratedEditorError.locked }
        let bv = bindingEpoch.value, pv = projectEpoch.value, lv = lifecycle.value
        let bindingEpoch = bindingEpoch, projectEpoch = projectEpoch, lifecycle = lifecycle
        let gate = ContractPathGate.revision(for: IntegratedEditorPlan.local), policy = ReceiveValidationPolicy.current
        guard let ticket = try policy.beginAuthentication(foreground: true, endpoint: configuration.url.absoluteString) else { throw IntegratedEditorError.locked }
        let authority = IntegratedEditorAuthority(policy: policy, ticket: ticket, journal: journal) {
            guard bindingEpoch.isAvailable, bindingEpoch.value == bv, projectEpoch.isAvailable, projectEpoch.value == pv,
                  lifecycle.value == lv, ContractPathGate.isOpen(for: IntegratedEditorPlan.local),
                  ContractPathGate.revision(for: IntegratedEditorPlan.local) == gate else { throw IntegratedEditorError.locked }
        }
        self.authority = authority; return authority
    }
    func signIn(email: String, password: String) async throws {
        let authority = try begin(), auth = auth
        let state = try await authority.context { await auth.signIn(email: email, password: password) }
        guard case let .authenticated(account) = state, account.userID == journal.state().execution?.accountID else { throw IntegratedEditorError.locked }
        try authority.policy.verifyAccount(account.userID, ticket: authority.ticket)
    }
    func prepare(automatic: Bool = false) async throws {
        let authority = try begin(), auth = auth
        if automatic {
            // Local queue inspection, no remote emptiness probe and no receipt SELECT.
            if let reason = journal.automaticBlockReason() { throw reason }
            let pendingState = journal.state()
            guard pendingState.conflicts.isEmpty,
                  !pendingState.wires.contains(where: { $0.phase == .conflict }) else { throw IntegratedEditorError.conflict }
            let queue = try await store.generalQueueStatus(localProjectID: IntegratedEditorPlan.local)
            try authority.check()
            guard queue.attentionCount == 0 else { throw IntegratedEditorError.queue }
            let state = journal.state()
            try journal.reserveAutomaticCycle(hasPendingBatch: state.activeWire != nil
                || state.sources.contains { !$0.enqueued } || queue.pendingCount > 0)
        }
        var state = await auth.currentState()
        if !state.isAuthenticated { state = try await authority.context { await auth.restoreSession() } }
        guard case let .authenticated(user) = state, user.userID == journal.state().execution?.accountID,
              let binding = try await store.binding(for: IntegratedEditorPlan.local), binding.serverProjectID == IntegratedEditorPlan.server,
              binding.ownerSubject == user.userID, binding.kind == .existingServerProject else { throw IntegratedEditorError.locked }
        try await authority.context {
            try authority.policy.verifyAccount(user.userID, ticket: authority.ticket)
            try authority.policy.select(IntegratedEditorPlan.server)
        }
        let bearer = try await authority.context { try await auth.generalValidationBearer() }; authority.bind(bearer, epoch: auth.contractEpoch)
        self.binding = binding
        let data = try JSONEncoder().encode(SyncV2HandshakeParameters(projectID: IntegratedEditorPlan.server, contractSHA256: SyncV2Contract.canonicalSHA256))
        let response = try await exchange(path: "rpc/get_sync_handshake", body: data)
        let handshake = try SyncV2Contract.readHandshakeCompatibility(JSONDecoder().decode(SyncV2HandshakeResponse.self, from: response))
        guard handshake.serverProjectID == IntegratedEditorPlan.server, handshake.projectSyncMode == .idBased, handshake.migrationEpoch == 1 else { throw IntegratedEditorError.scope }
        let status = try await exchange(path: "rpc/get_project_status", body: JSONEncoder().encode(["p_project_id": IntegratedEditorPlan.server.uuidString.lowercased()]))
        guard try SyncV2ContractProjectStatus.decode(status, expectedProjectID: IntegratedEditorPlan.server) == .active else { throw IntegratedEditorError.locked }
        self.handshake = handshake
    }
    private func exchange(path: String, query: [URLQueryItem] = [], body: Data? = nil,
                          willStart: @escaping @Sendable () throws -> Void = {}) async throws -> Data {
        let authority = try grant()
        var url = URLComponents(url: configuration.url.appendingPathComponent("rest/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.timeoutInterval = 15
        let auth = auth
        request.setValue(try await authority.context { try await auth.generalValidationBearer() }, forHTTPHeaderField: "Authorization")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if body == nil { request.setValue("count=exact", forHTTPHeaderField: "Prefer") }
        let frozen = request, journal = journal
        return try await authority.context {
            try authority.authorize(frozen)
            let write = ["rpc/document_commit", "rpc/atomic_structure_commit"].contains(path)
            if write { try journal.checkpoint("beforeHTTP") }
            try journal.reserve(kind: write ? "write" : "data", path: path)
            try willStart()
            let data: Data, response: URLResponse
            do { (data, response) = try await authority.policy.network(frozen) }
            catch {
                try journal.diagnosticEvent(path, detail: Self.diagnosticError(error))
                throw error
            }
            if let http = response as? HTTPURLResponse {
                try journal.diagnosticEvent(path, detail: "http.\(http.statusCode).bytes.\(data.count).sha256.\(IntegratedEditorPlan.hash(data))")
            }
            try authority.check()
            guard let http = response as? HTTPURLResponse, http.url == frozen.url, data.count <= 16_777_216 else { throw IntegratedEditorError.scope }
            if http.statusCode != 200 {
                if write {
                    let result = try? JSONDecoder().decode(SyncV2JSON.self, from: data)
                    if ["document_commit_failure", "atomic_structure_commit_failure"].contains(result?.objectValue?["kind"]?.stringValue ?? "") { return data }
                    throw SyncV2ContractError("HTTP_" + String(http.statusCode))
                }
                throw IntegratedEditorError.receipt
            }
            if body == nil {
                let rows: [SyncV2JSON]
                do { rows = try JSONDecoder().decode([SyncV2JSON].self, from: data) }
                catch { try journal.diagnosticEvent(path, detail: "decode.failed"); throw error }
                let count = http.value(forHTTPHeaderField: "Content-Range").flatMap { Int($0.split(separator: "/").last ?? "") }
                try journal.diagnosticEvent(path, detail: "rows.\(rows.count).total.\(count.map(String.init) ?? "missing")")
                guard let count, count == rows.count, count < 65 else { throw IntegratedEditorError.scope }
            }
            return data
        }
    }
    private func rows(_ table: String, columns: String, filters: [URLQueryItem]) async throws -> Data {
        try await exchange(path: table, query: [.init(name: "select", value: columns), .init(name: "limit", value: "65")] + filters)
    }
    func remote() async throws -> IntegratedRemoteSnapshot {
        let filters = [URLQueryItem(name: "project_id", value: "eq." + IntegratedEditorPlan.server.uuidString.lowercased())]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self), formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }; formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw IntegratedEditorError.scope }; return date
        }
        let documents = try await decoder.decode([SyncV2RemoteDocumentSnapshot].self, from: rows("documents", columns: GeneralValidationRemoteSnapshot.columns["documents"]!, filters: filters))
        let folders = try await decoder.decode([SyncV2RemoteFolder].self, from: rows("folders", columns: GeneralValidationRemoteSnapshot.columns["folders"]!, filters: filters))
        let orders = try await decoder.decode([SyncV2RemoteTreeOrder].self, from: rows("tree_orders", columns: GeneralValidationRemoteSnapshot.columns["tree_orders"]!, filters: filters))
        return .init(documents: documents, folders: folders, orders: orders)
    }
    private func receipt(_ request: SyncV2ContractRequest) async throws -> SyncV2JSON {
        let batch = request.batchID.uuidString.lowercased()
        let first = try await rows("sync_batches", columns: Self.batchColumns, filters: [
            .init(name: "project_id", value: "eq." + IntegratedEditorPlan.server.uuidString.lowercased()), .init(name: "batch_id", value: "eq." + batch)])
        let batches = try JSONDecoder().decode([SyncV2JSON].self, from: first)
        guard batches.count == 1 else { throw IntegratedEditorError.receipt }
        let second = try await rows("sync_batch_results", columns: Self.resultColumns, filters: [.init(name: "batch_id", value: "eq." + batch)])
        let results = try JSONDecoder().decode([SyncV2JSON].self, from: second)
        guard results.count == 1, let account = journal.state().execution?.accountID else { throw IntegratedEditorError.receipt }
        if journal.diagnosticRestricted,
           let field = Self.documentResponseDifference(request, response: results[0].objectValue?["response"]) {
            try journal.diagnosticEvent("validation", detail: field)
        }
        return try SyncV2GeneralCommitReceipt(batch: batches[0], result: results[0]).validatedResponse(
            for: .init(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: request), accountID: account,
            mismatch: { try self.journal.diagnosticEvent("validation", detail: $0) })
    }
    /// Field names only. This explains rejection; the existing contract validator remains authoritative.
    static func documentResponseDifference(_ request: SyncV2ContractRequest, response: SyncV2JSON?) -> String? {
        guard request.json.objectValue?["kind"] == .string("document_commit_request") else { return nil }
        guard let fields = response?.objectValue else { return "response.object" }
        for (key, expected) in [("kind", SyncV2JSON.string("document_commit_success")), ("batch_id", .string(request.batchID.uuidString.lowercased())),
                                ("batch_payload_sha256", .string(request.batchPayloadSHA256)), ("applied", .bool(true))] {
            if fields[key] != expected { return "response." + key }
        }
        guard Set(fields.keys) == ["kind", "batch_id", "batch_payload_sha256", "status", "applied", "results"] else { return "response.keys" }
        guard fields["status"]?.stringValue.flatMap(SyncV2CommitStatus.init) != nil else { return "response.status" }
        guard let rows = fields["results"]?.arrayValue, rows.count == 1, request.orderedIntents.count == 1 else { return "response.results.count" }
        guard let row = rows[0].objectValue else { return "response.results.0.object" }
        guard Set(row.keys) == ["sequence", "operation_id", "document_id", "result_revision", "structure_revision", "parent_folder_id", "name", "content_sha256", "content_byte_count", "is_deleted"] else { return "response.results.0.keys" }
        let intent = request.orderedIntents[0].objectValue ?? [:], payload = intent["payload"]?.objectValue ?? [:]
        if row["sequence"] != .int(1) { return "response.results.0.sequence" }
        for key in ["operation_id", "document_id"] where row[key] != intent[key] { return "response.results.0." + key }
        if let base = intent["base_revision"]?.intValue, row["result_revision"]?.intValue != base + 1 { return "response.results.0.result_revision" }
        for key in ["structure_revision", "parent_folder_id", "name", "content_sha256", "content_byte_count", "is_deleted"] where row[key] != payload[key] {
            return "response.results.0." + key
        }
        return nil
    }
    private static func diagnosticError(_ error: Error) -> String {
        if let error = error as? URLError { return "transport.url.\(error.code.rawValue)" }
        if error is DecodingError { return "decode.failed" }
        if let error = error as? IntegratedEditorError { return error.rawValue }
        if let error = error as? SyncV2ContractStructureError { return "structure." + String(describing: error) }
        if let error = error as? SyncV2ContractError {
            let code = error.code
            if code.count <= 80 && code.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) { return "contract." + code }
        }
        return "unclassified"
    }
    /// A single persisted diagnostic attempt: no enqueue, write, snapshot, or local baseline application.
    func diagnoseReceipt() async throws {
        try journal.beginDiagnostic()
        do {
            try await prepare()
            guard let index = journal.state().activeWire,
                  let approval = journal.state().amendment,
                  journal.state().wires[index].phase == .httpStarted,
                  journal.state().wires[index].hash == approval.requestSHA256 else { throw IntegratedEditorError.receipt }
            let request = try SyncV2ContractRequest(storedJSON: journal.state().wires[index].request)
            guard request.batchID == approval.batchID else { throw IntegratedEditorError.receipt }
            let response = try await receipt(request)
            try validateResponse(request, response: response)
            try journal.diagnosticEvent("validation", detail: "passed")
            try journal.update("responseStored") { $0.wires[index].response = response; $0.wires[index].phase = .responseStored }
            try journal.checkpoint("afterStoredResponse")
            throw IntegratedEditorError.diagnostic
        } catch {
            try journal.diagnosticEvent("outcome", detail: Self.diagnosticError(error))
            try journal.finishDiagnostic()
            invalidate()
            throw error
        }
    }
    private func validate(_ request: SyncV2ContractRequest, baseline: SyncV2PreparationSnapshot) throws {
        let state = journal.state(), members = state.members
        guard request.json.objectValue?["project_id"] == .string(IntegratedEditorPlan.server.uuidString.lowercased()),
              request.json.objectValue?["project_sync_mode"] == .string("ID_BASED"), request.json.objectValue?["migration_epoch"] == .int(1) else { throw IntegratedEditorError.scope }
        for value in request.orderedIntents {
            guard let intent = value.objectValue, let payload = intent["payload"]?.objectValue,
                  let id = (intent["document_id"] ?? intent["entity_id"])?.stringValue.flatMap(UUID.init(uuidString:)) else { throw IntegratedEditorError.scope }
            if intent["entity_kind"] == .string("tree_order") {
                guard let parent = payload["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                      members.contains(parent) || parent == IntegratedEditorPlan.parent,
                      let children = payload["children"]?.arrayValue else { throw IntegratedEditorError.scope }
                let old = baseline.treeOrders.first { $0.objectValue?["parent_folder_id"] == payload["parent_folder_id"] }?.objectValue?["children"]?.arrayValue ?? []
                let outside: (SyncV2JSON) -> Bool = { $0.stringValue.flatMap(UUID.init(uuidString:)).map { !members.contains($0) } ?? true }
                guard old.filter(outside) == children.filter(outside) else { throw IntegratedEditorError.scope }
            } else {
                guard members.contains(id), id != IntegratedEditorPlan.protectedDocument else { throw IntegratedEditorError.scope }
                if let parent = payload["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                    guard members.contains(parent) || (parent == IntegratedEditorPlan.parent && payload["name"] == .string(IntegratedEditorPlan.rootName)) else { throw IntegratedEditorError.scope }
                }
            }
        }
    }
    /// Shared dispatch ownership includes preparation so a busy trigger never consumes a cycle.
    func runCycle(automatic: Bool = false) async throws {
        guard !dispatching else { throw IntegratedEditorError.locked }
        dispatching = true; defer { dispatching = false }
        try await prepare(automatic: automatic)
        try await synchronize()
    }
    /// One serialized cycle. The existing store expands composite sources and keeps dependent RPC order.
    func synchronize() async throws {
        guard !journal.diagnosticRestricted else { throw IntegratedEditorError.diagnostic }
        let authority = try grant(), store = store, journal = journal
        guard let handshake, let binding, journal.state().conflicts.isEmpty else { throw IntegratedEditorError.conflict }
        if journal.state().receive != nil { try await applyReceived(); return }
        try await authority.mutate(sending: true) {
            let page = try await store.generalRecoveryPage(localProjectID: IntegratedEditorPlan.local, after: nil)
            guard page.nextCursor == nil else { throw IntegratedEditorError.queue }
            let originals = Set(journal.state().sources.map { $0.batch.batchID })
            for row in page.rows {
                let detail = try await store.generalRecoveryDetail(localProjectID: IntegratedEditorPlan.local, batchID: row.batchID)
                guard originals.contains(row.batchID) || detail.source.originBatchID.map(originals.contains) == true else { throw IntegratedEditorError.queue }
            }
            for (index, source) in journal.state().sources.enumerated() where !source.enqueued {
                _ = try await store.enqueueContractStructure(source.batch, binding: binding, handshake: handshake, general: true,
                    authorize: { try authority.requireMutation(sending: true) })
                try journal.update("sourceEnqueued") { $0.sources[index].enqueued = true }
            }
        }
        while true {
            try authority.check()
            if journal.state().activeWire == nil {
                let claimedHead = try await store.integratedClaimedHead()
                let ready = try await store.hasReadyGeneralContract(localProjectID: IntegratedEditorPlan.local)
                guard claimedHead != nil || ready else { break }
                let baseline = try await store.integratedBaseline()
                let first = try await remote(), second = try await remote()
                _ = try second.validate(baseline: baseline, members: journal.state().members)
                guard try first.metadata.fingerprint() == second.metadata.fingerprint(),
                      try baseline.fingerprint() == second.metadata.fingerprint() else {
                    try await preserveConflict(second); throw IntegratedEditorError.conflict
                }
                let pending: SyncV2PendingContractBatch
                if let claimed = claimedHead {
                    // This runtime cannot start HTTP before the immutable journal wire is published.
                    pending = claimed
                } else {
                    do { pending = try await authority.mutate(sending: true) { try await store.claimNextGeneralContract(localProjectID: IntegratedEditorPlan.local) } }
                    catch SyncV2ContractStructureError.noReadyBatch { break }
                }
                try validate(pending.request, baseline: baseline)
                try journal.update("requestFrozen") { $0.wires.append(.init(request: pending.request.json, hash: try pending.request.json.sha256Hex())) }
            }
            guard let index = journal.state().activeWire else { throw IntegratedEditorError.queue }
            let wire = journal.state().wires[index], request = try SyncV2ContractRequest(storedJSON: wire.request)
            if wire.phase == .conflict { throw IntegratedEditorError.conflict }
            var response = wire.response
            if wire.phase == .httpStarted { response = try await receipt(request) }
            if wire.phase == .frozen {
                let baseline = try await store.integratedBaseline()
                let remote = try await remote()
                _ = try remote.validate(baseline: baseline, members: journal.state().members)
                guard try baseline.fingerprint() == remote.metadata.fingerprint() else {
                    try await preserveConflict(remote); throw IntegratedEditorError.conflict
                }
                try validate(request, baseline: baseline)
                let rpc = request.json.objectValue?["kind"] == .string("document_commit_request") ? "document_commit" : "atomic_structure_commit"
                let data = try await exchange(path: "rpc/" + rpc, body: JSONEncoder().encode(SyncV2AtomicStructureParameters(request: request.json))) {
                    try journal.update("httpStarted") { $0.wires[index].phase = .httpStarted }
                }
                response = try JSONDecoder().decode(SyncV2JSON.self, from: data)
                do { try validateResponse(request, response: response!) }
                catch {
                    let code = (error as? SyncV2ContractError)?.code ?? ""
                    if ["REVISION_CONFLICT", "STRUCTURE_REVISION_CONFLICT"].contains(code) {
                        let rejected = response
                        try journal.update("serverConflict") { $0.wires[index].response = rejected; $0.wires[index].phase = .conflict }
                        try await preserveConflict(self.remote())
                    }
                    throw error
                }
                try journal.checkpoint("afterCommitResponse")
            }
            guard let response else { throw IntegratedEditorError.receipt }
            try validateResponse(request, response: response)
            if journal.state().wires[index].phase != .responseStored {
                try journal.update("responseStored") { $0.wires[index].response = response; $0.wires[index].phase = .responseStored }
            }
            try journal.checkpoint("afterStoredResponse")
            try await authority.mutate(sending: true) { try await store.completeIntegratedRequest(request, response: response) }
            try journal.update("sendCompleted") { $0.wires[index].phase = .completed; $0.message = "저장된 변경 송신 완료" }
        }
        let queue = try await store.generalQueueStatus(localProjectID: IntegratedEditorPlan.local)
        guard queue.pendingCount == 0, queue.attentionCount == 0, queue.retryCount == 0 else { throw IntegratedEditorError.queue }
        let snapshot = try await remote(), baseline = try await store.integratedBaseline()
        let members = try snapshot.validate(baseline: baseline, members: journal.state().members)
        try journal.update("receiveStored") { $0.receive = snapshot; $0.members = members }
        try await applyReceived()
    }
    private func validateResponse(_ request: SyncV2ContractRequest, response: SyncV2JSON) throws {
        if request.json.objectValue?["kind"] == .string("document_commit_request") { _ = try SyncV2Contract.validateDocumentCommitResponse(request: request, response: response) }
        else { _ = try SyncV2Contract.validateAtomicStructureResponse(request: request, response: response) }
        guard let results = response.objectValue?["results"]?.arrayValue, results.count == request.orderedIntents.count else { throw IntegratedEditorError.receipt }
        for (intent, result) in zip(request.orderedIntents, results) {
            guard let base = intent.objectValue?["base_revision"]?.intValue,
                  result.objectValue?["result_revision"]?.intValue == base + 1 else { throw IntegratedEditorError.receipt }
        }
    }
    private func preserveConflict(_ remote: IntegratedRemoteSnapshot) async throws {
        let baseline = try await store.integratedBaseContents()
        try journal.update("conflictPreserved") { state in
            state.conflicts.append(.init(baseline: baseline, sources: state.sources.map(\.batch), drafts: state.drafts, remote: remote))
        }
    }
    private func applyReceived() async throws {
        let authority = try grant(), journal = journal, makePuller = makePuller
        guard let snapshot = journal.state().receive else { return }
        try await authority.mutate(sending: false) {
            let report = try await makePuller(snapshot).pull(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, editingGuards: [:])
            guard !report.hasDeferredLocalApplication, report.rejectedStructureNames.isEmpty,
                  report.pendingChildTombstoneFolderCount == 0,
                  !report.outcomes.contains(where: { if case .mergeRequired = $0 { true } else { false } }) else { throw IntegratedEditorError.partial }
            try journal.update("receiveCompleted") { state in
                for doc in snapshot.documents where state.members.contains(doc.documentID) && !doc.isDeleted {
                    state.drafts[doc.documentID] = .init(text: doc.content, cursor: .start, hash: IntegratedEditorPlan.hash(doc.content), inputSource: .remoteSnapshot)
                }
                state.receive = nil; state.message = "송수신 완료 · 본문과 구조를 반영했습니다."
            }
        }
    }
}
