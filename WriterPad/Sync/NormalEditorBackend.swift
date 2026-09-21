import Foundation

/// Short-lived explicit authority; it never alters saved gates or the global send lock.
final class NormalEditorAuthority: @unchecked Sendable {
    @TaskLocal static var current: NormalEditorAuthority?
    @TaskLocal static var mutation: Bool? // true: contract queue, false: single-document receive
    @TaskLocal static var wireHash: String?
    let policy: ReceiveValidationPolicy
    let ticket: ReceiveValidationPolicy.Ticket
    let bearer: String
    let journal: NormalEditorJournal?
    private let currentCheck: @Sendable () throws -> Void
    private let lock = NSLock()
    private var stopped = false
    private var bound = false
    init(policy: ReceiveValidationPolicy, ticket: ReceiveValidationPolicy.Ticket, bearer: String, journal: NormalEditorJournal? = nil,
         check: @escaping @Sendable () throws -> Void) {
        self.policy = policy; self.ticket = ticket; self.bearer = bearer; self.journal = journal; self.currentCheck = check
    }
    func check() throws {
        try Task.checkCancellation(); try currentCheck()
        guard lock.withLock({ !stopped }) else { throw NormalEditorError.locked }
        try ReceiveValidationPolicy.$operation.withValue(ticket) { _ = try policy.authorization() }
    }
    func bind() throws { try check(); lock.withLock { bound = true } }
    func stop() { lock.withLock { stopped = true } }
    func requireMutation(sending: Bool? = nil) throws {
        try check()
        guard lock.withLock({ bound }), let active = Self.mutation,
              sending == nil || sending == active else { throw NormalEditorError.locked }
    }
    func authorize(_ request: URLRequest) throws {
        try check()
        guard Self.wireHash == GeneralSyncValidationScope.fingerprint(request),
              request.value(forHTTPHeaderField: "Authorization") == bearer,
              let parts = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              parts.scheme == "https", parts.host == "mhpnszcorfzrvhyondxr.supabase.co",
              parts.port == nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
              request.httpBodyStream == nil, request.value(forHTTPHeaderField: "Range") == nil,
              request.value(forHTTPHeaderField: "Range-Unit") == nil else { throw NormalEditorError.request }
        let method = request.httpMethod ?? "GET", items = parts.queryItems ?? []
        if method == "POST", parts.path == "/rest/v1/rpc/get_sync_handshake", items.isEmpty {
            guard !lock.withLock({ bound }), let data = request.httpBody,
                  let fields = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  Set(fields.keys) == ["p_project_id", "p_contract_sha256"],
                  fields["p_project_id"]?.lowercased() == NormalEditorPlan.server.uuidString.lowercased(),
                  fields["p_contract_sha256"] == SyncV2Contract.canonicalSHA256 else { throw NormalEditorError.request }
            return
        }
        guard lock.withLock({ bound }), let journal else { throw NormalEditorError.request }
        let state = journal.state()
        if method == "POST", parts.path == "/rest/v1/rpc/document_commit", items.isEmpty {
            guard let index = state.head, state.saves[index].phase == .frozen,
                  let data = request.httpBody,
                  let fields = try JSONDecoder().decode(SyncV2JSON.self, from: data).objectValue,
                  Set(fields.keys) == ["p_request"], let json = fields["p_request"],
                  try json.sha256Hex() == state.saves[index].requestHash else { throw NormalEditorError.request }
            try NormalEditorPlan.validate(SyncV2ContractRequest(storedJSON: json), source: state.saves[index].source)
            return
        }
        guard method == "GET", request.httpBody == nil, request.value(forHTTPHeaderField: "Prefer") == "count=exact",
              Set(items.map(\.name)).count == items.count else { throw NormalEditorError.request }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let table = request.url!.lastPathComponent
        let columns = [
            "folders": "folder_id,project_id,parent_folder_id,name,revision,is_deleted",
            "tree_orders": "tree_order_id,project_id,parent_folder_id,children,revision",
            "documents": "document_id,project_id,relative_path,revision,parent_folder_id,name,structure_revision,is_deleted",
            "documentBody": "document_id,relative_path,content,revision,parent_folder_id,name,structure_revision,is_deleted,deleted_at,updated_at",
            "sync_batches": "batch_id,project_id,writer_user_id,writer_device_id,client_build_id,sync_protocol_version,contract_version,canonical_contract_sha256,client_capabilities,batch_payload_sha256,project_sync_mode,migration_epoch,request_sha256",
            "sync_batch_results": "batch_id,applied,response,response_sha256"
        ]
        guard parts.path == "/rest/v1/" + table else { throw NormalEditorError.request }
        if ["sync_batches", "sync_batch_results"].contains(table) {
            guard let index = state.head, [.httpStarted, .responseStored].contains(state.saves[index].phase),
                  let json = state.saves[index].request,
                  fields["batch_id"] == "eq." + (try SyncV2ContractRequest(storedJSON: json)).batchID.uuidString.lowercased(),
                  fields["select"] == columns[table], fields["limit"] == "2",
                  Set(fields.keys) == (table == "sync_batches" ? ["select", "limit", "batch_id", "project_id"] : ["select", "limit", "batch_id"]) else { throw NormalEditorError.request }
            if table == "sync_batch_results" { return }
        } else {
            let body = table == "documents" && fields["document_id"] != nil
            guard ["folders", "tree_orders", "documents"].contains(table),
                  fields["select"] == columns[body ? "documentBody" : table],
                  fields["limit"] == (body ? "2" : "1000"),
                  Set(fields.keys) == (body ? ["select", "limit", "project_id", "document_id"] : ["select", "limit", "project_id"]) else { throw NormalEditorError.request }
            if body, fields["document_id"] != "eq." + NormalEditorPlan.document.uuidString.lowercased() { throw NormalEditorError.target }
        }
        guard fields["project_id"] == "eq." + NormalEditorPlan.server.uuidString.lowercased() else { throw NormalEditorError.target }
    }
    func context<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self) {
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                try await ReceiveValidationPolicy.$operation.withValue(ticket) {
                    try await operation()
                }
            }
        }
    }
    func mutate<T: Sendable>(sending: Bool, _ operation: @Sendable () async throws -> T) async throws -> T {
        try await context {
            try await Self.$mutation.withValue(sending) {
                try self.requireMutation(sending: sending)
                return try await ReceiveValidationPolicy.$localProject.withValue(NormalEditorPlan.local.rawValue) {
                    try await GeneralValidationMutation.$current.withValue({ try self.requireMutation(sending: sending) }) {
                        try await operation()
                    }
                }
            }
        }
    }
}

actor LiveNormalEditorBackend: NormalEditorBackend {
    let store: LazySyncV2ProjectBindingStore
    let documents: any DocumentRepository
    let local: any LocalDocumentStoring
    let applier: any SyncV2LocalSnapshotApplying
    let mutationGate: SyncV2DocumentMutationGate
    let auth: any AuthenticationServicing
    let configuration: SupabasePublicConfiguration
    let journal: NormalEditorJournal
    let bindingEpoch: SyncV2ContractEpoch
    let projectEpoch: SyncV2ContractEpoch
    let lifecycle = SyncV2ContractEpoch()
    private var authority: NormalEditorAuthority?
    private var binding: ProjectSyncBinding?
    private var handshake: SyncV2ValidatedHandshake?
    private var account: UUID?
    init(store: LazySyncV2ProjectBindingStore, documents: any DocumentRepository, local: any LocalDocumentStoring,
         applier: any SyncV2LocalSnapshotApplying, mutationGate: SyncV2DocumentMutationGate,
         auth: any AuthenticationServicing, configuration: SupabasePublicConfiguration,
         journal: NormalEditorJournal, bindingEpoch: SyncV2ContractEpoch, projectEpoch: SyncV2ContractEpoch) {
        self.store = store; self.documents = documents; self.local = local; self.applier = applier; self.mutationGate = mutationGate
        self.auth = auth; self.configuration = configuration; self.journal = journal; self.bindingEpoch = bindingEpoch; self.projectEpoch = projectEpoch
    }
    func invalidate() { authority?.stop(); authority = nil; lifecycle.advance() }
    private func grant() throws -> NormalEditorAuthority {
        guard let authority else { throw NormalEditorError.locked }; try authority.check(); return authority
    }
    func localBaseline() async throws -> SyncV2RemoteDocumentSnapshot { try await store.normalEditorBaseline() }
    func localText() async throws -> String {
        guard let node = try await documents.document(id: .init(rawValue: NormalEditorPlan.document)) else { throw NormalEditorError.target }
        try NormalEditorPlan.validate(node); return try await local.loadText(for: node)
    }
    func prepare() async throws {
        invalidate()
        guard configuration.url.absoluteString == ReceiveValidationPolicy.Configuration.staging,
              case let .authenticated(user) = await auth.currentState(),
              let binding = try await store.binding(for: NormalEditorPlan.local), binding.ownerSubject == user.userID,
              binding.serverProjectID == NormalEditorPlan.server, binding.kind == .existingServerProject,
              ContractPathGate.isOpen(for: NormalEditorPlan.local),
              let authEpoch = auth.contractEpoch, authEpoch.isAvailable else { throw NormalEditorError.locked }
        let av = authEpoch.value, bv = bindingEpoch.value, pv = projectEpoch.value, lv = lifecycle.value
        let gateVersion = ContractPathGate.revision(for: NormalEditorPlan.local)
        let bindingEpoch = self.bindingEpoch, projectEpoch = self.projectEpoch, lifecycle = self.lifecycle
        let policy = ReceiveValidationPolicy.current
        guard let ticket = try policy.beginAuthentication(foreground: true, endpoint: configuration.url.absoluteString) else { throw NormalEditorError.locked }
        try policy.verifyAccount(user.userID, ticket: ticket); try policy.select(NormalEditorPlan.server)
        let bearer = try await auth.generalValidationBearer()
        let authority = NormalEditorAuthority(policy: policy, ticket: ticket, bearer: bearer, journal: journal) {
            guard authEpoch.isAvailable, authEpoch.value == av, bindingEpoch.isAvailable, bindingEpoch.value == bv,
                  projectEpoch.isAvailable, projectEpoch.value == pv, lifecycle.value == lv,
                  ContractPathGate.isOpen(for: NormalEditorPlan.local), ContractPathGate.revision(for: NormalEditorPlan.local) == gateVersion else { throw NormalEditorError.locked }
        }
        self.authority = authority; self.account = user.userID; self.binding = binding
        let body = try JSONEncoder().encode(SyncV2HandshakeParameters(projectID: NormalEditorPlan.server, contractSHA256: SyncV2Contract.canonicalSHA256))
        let (data, _) = try await exchange(path: "rpc/get_sync_handshake", body: body)
        let response = try JSONDecoder().decode(SyncV2HandshakeResponse.self, from: data)
        let handshake = try SyncV2Contract.readHandshakeCompatibility(response)
        guard handshake.serverProjectID == NormalEditorPlan.server, handshake.projectSyncMode == .idBased,
              handshake.migrationEpoch == 1 else { throw NormalEditorError.target }
        self.handshake = handshake; try authority.bind()
        // No baseline materialization or repeat of a completed operation in preparation.
        _ = try await localBaseline()
        _ = try await store.normalEditorStructure()
    }
    private func exchange(path: String, query: [URLQueryItem] = [], body: Data? = nil,
                          willStart: @escaping @Sendable () throws -> Void = {}) async throws -> (Data, HTTPURLResponse) {
        let authority = try grant()
        var components = URLComponents(url: configuration.url.appendingPathComponent("rest/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.timeoutInterval = 15
        request.setValue(authority.bearer, forHTTPHeaderField: "Authorization")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if body == nil { request.setValue("count=exact", forHTTPHeaderField: "Prefer") }
        let frozen = request, journal = self.journal
        return try await authority.context {
            try await NormalEditorAuthority.$wireHash.withValue(GeneralSyncValidationScope.fingerprint(frozen)) {
                try GeneralSyncValidationScope.current.authorize(frozen)
                _ = try authority.policy.authorize(frozen, ticket: authority.ticket)
                try authority.check()
                try journal.update("requestBoundary:" + path) { $0.lastRequestHash = GeneralSyncValidationScope.fingerprint(frozen) }
                // The only path to the no-redirect/no-cookie transport. No retry loop.
                if path == "rpc/document_commit" {
                    try NormalEditorRecoveryInjection.hit(.beforeHTTP, journal: journal)
                }
                try willStart()
                let (data, response) = try await authority.policy.network(frozen)
                try authority.check()
                guard let http = response as? HTTPURLResponse, http.url == frozen.url,
                      data.count <= 16_777_216 else { throw NormalEditorError.request }
                try journal.update("httpResponse:" + path) { $0.lastHTTPStatus = http.statusCode }
                if http.statusCode != 200 {
                    if path == "rpc/document_commit", let body = frozen.httpBody,
                       let parameters = try? JSONDecoder().decode(SyncV2JSON.self, from: body),
                       let source = parameters.objectValue?["p_request"],
                       let result = try? JSONDecoder().decode(SyncV2JSON.self, from: data) {
                        let request = try SyncV2ContractRequest(storedJSON: source)
                        _ = try SyncV2Contract.validateDocumentCommitResponse(request: request, response: result)
                    }
                    throw SyncV2ContractError("HTTP_" + String(http.statusCode))
                }
                return (data, http)
            }
        }
    }
    private func rows(_ table: String, columns: String, filters: [URLQueryItem], limit: Int = 1000) async throws -> [SyncV2JSON] {
        let (data, response) = try await exchange(path: table, query: [.init(name: "select", value: columns)] + filters + [.init(name: "limit", value: String(limit))])
        let rows = try JSONDecoder().decode([SyncV2JSON].self, from: data)
        guard let range = response.value(forHTTPHeaderField: "Content-Range"),
              let count = Int(range.split(separator: "/").last ?? ""), count == rows.count, count < limit else { throw NormalEditorError.request }
        return rows
    }
    func remote() async throws -> SyncV2RemoteDocumentSnapshot {
        _ = try grant()
        let filter = [URLQueryItem(name: "project_id", value: "eq." + NormalEditorPlan.server.uuidString.lowercased())]
        let localStructure = try await store.normalEditorStructure()
        let folders = try await rows("folders", columns: "folder_id,project_id,parent_folder_id,name,revision,is_deleted", filters: filter)
        let orders = try await rows("tree_orders", columns: "tree_order_id,project_id,parent_folder_id,children,revision", filters: filter)
        let docs = try await rows("documents", columns: "document_id,project_id,relative_path,revision,parent_folder_id,name,structure_revision,is_deleted", filters: filter)
        let remoteStructure = SyncV2PreparationSnapshot(folders: folders, documents: docs, treeOrders: orders)
        func structure(_ snapshot: SyncV2PreparationSnapshot) -> SyncV2PreparationSnapshot {
            .init(folders: snapshot.folders, documents: snapshot.documents.map { row in
                guard var fields = row.objectValue, fields["document_id"] == .string(NormalEditorPlan.document.uuidString.lowercased()) else { return row }
                fields["revision"] = .int(0); return .object(fields)
            }, treeOrders: snapshot.treeOrders)
        }
        guard try structure(localStructure).fingerprint() == structure(remoteStructure).fingerprint() else { throw NormalEditorError.target }
        let target = try await rows("documents", columns: "document_id,relative_path,content,revision,parent_folder_id,name,structure_revision,is_deleted,deleted_at,updated_at", filters: filter + [.init(name: "document_id", value: "eq." + NormalEditorPlan.document.uuidString.lowercased())], limit: 2)
        guard target.count == 1 else { throw NormalEditorError.target }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { throw NormalEditorError.request }; return date
        }
        let result = try decoder.decode(SyncV2RemoteDocumentSnapshot.self, from: JSONEncoder().encode(target[0]))
        try NormalEditorPlan.validate(result)
        guard let manifest = docs.first(where: { $0.objectValue?["document_id"] == .string(NormalEditorPlan.document.uuidString.lowercased()) }),
              manifest.objectValue?["revision"] == .int(Int(result.revision)) else { throw NormalEditorError.baseline }
        return result
    }
    func freeze(_ source: LocalMutationBatch) async throws -> SyncV2ContractRequest {
        let authority = try grant()
        guard let binding, let handshake else { throw NormalEditorError.locked }
        _ = try NormalEditorPlan.content(source)
        let store = self.store
        return try await authority.mutate(sending: true) {
            let page = try await store.generalRecoveryPage(localProjectID: NormalEditorPlan.local, after: nil)
            guard page.nextCursor == nil, page.rows.allSatisfy({ $0.batchID == source.batchID }) else { throw NormalEditorError.queue }
            let queue = try await store.uploadQueueSnapshot(localProjectID: NormalEditorPlan.local)
            guard queue.conflictCount == 0, queue.blockedCount == 0, queue.retryWaitingCount == 0,
                  queue.pendingCount + queue.inflightCount <= (page.rows.isEmpty ? 0 : 1) else { throw NormalEditorError.queue }
            _ = try await store.enqueueContractStructure(source, binding: binding, handshake: handshake, general: true,
                authorize: { try authority.requireMutation(sending: true) })
            if let existing = try await store.normalEditorPending(batchID: source.batchID) { return existing.request }
            let pending = try await store.claimNextGeneralContract(localProjectID: NormalEditorPlan.local)
            try NormalEditorPlan.validate(pending.request, source: source)
            return pending.request
        }
    }
    func transmit(_ request: SyncV2ContractRequest, willStart: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
        let data = try JSONEncoder().encode(SyncV2AtomicStructureParameters(request: request.json))
        let (response, _) = try await exchange(path: "rpc/document_commit", body: data, willStart: willStart)
        let json = try JSONDecoder().decode(SyncV2JSON.self, from: response)
        _ = try SyncV2Contract.validateDocumentCommitResponse(request: request, response: json)
        try NormalEditorRecoveryInjection.hit(.afterCommitResponse, journal: journal)
        return json
    }
    func receipt(_ request: SyncV2ContractRequest) async throws -> SyncV2JSON? {
        guard let account else { throw NormalEditorError.locked }
        let batchID = request.batchID.uuidString.lowercased()
        let batches = try await rows("sync_batches", columns: "batch_id,project_id,writer_user_id,writer_device_id,client_build_id,sync_protocol_version,contract_version,canonical_contract_sha256,client_capabilities,batch_payload_sha256,project_sync_mode,migration_epoch,request_sha256", filters: [.init(name: "project_id", value: "eq." + NormalEditorPlan.server.uuidString.lowercased()), .init(name: "batch_id", value: "eq." + batchID)], limit: 2)
        guard let batch = batches.first else { return nil }
        let results = try await rows("sync_batch_results", columns: "batch_id,applied,response,response_sha256", filters: [.init(name: "batch_id", value: "eq." + batchID)], limit: 2)
        guard results.count == 1 else { throw NormalEditorError.unknown }
        return try SyncV2GeneralCommitReceipt(batch: batch, result: results[0]).validatedResponse(for: .init(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: request), accountID: account)
    }
    func complete(_ request: SyncV2ContractRequest, response: SyncV2JSON) async throws {
        let authority = try grant(), store = self.store
        let state = journal.state()
        guard let index = state.head, [.httpStarted, .responseStored].contains(state.saves[index].phase),
              try request.json.sha256Hex() == state.saves[index].requestHash,
              response.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"]?.intValue
                == (request.orderedIntents.first?.objectValue?["base_revision"]?.intValue ?? -1) + 1 else { throw NormalEditorError.request }
        try await authority.mutate(sending: true) { try await store.completeNormalEditorRequest(request, response: response, authorize: { try authority.requireMutation(sending: true) }) }
    }
    func apply(_ receive: NormalEditorJournal.Receive, willApply: @escaping @Sendable () throws -> Void) async throws {
        let authority = try grant(), store = self.store, applier = self.applier
        let local = self.local, documents = self.documents, journal = self.journal
        try await authority.mutate(sending: false) {
            try await self.mutationGate.withCriticalSection(documentID: NormalEditorPlan.document) {
                guard try await store.uploadQueueSnapshot(localProjectID: NormalEditorPlan.local) == .idle,
                      let node = try await documents.document(id: .init(rawValue: NormalEditorPlan.document)) else { throw NormalEditorError.dirty }
                try NormalEditorPlan.validate(node)
                let base = try await store.normalEditorBaseline(), text = try await local.loadText(for: node)
                if base.revision == receive.remote.revision, Data(base.content.utf8) == Data(receive.remote.content.utf8), Data(text.utf8) == Data(receive.remote.content.utf8) { return }
                guard base.revision == receive.baseline.revision,
                      Data(base.content.utf8) == Data(receive.baseline.content.utf8),
                      Data(text.utf8) == Data(base.content.utf8) || Data(text.utf8) == Data(receive.remote.content.utf8) else { throw NormalEditorError.partial }
                guard journal.state().head == nil, journal.state().conflicts.isEmpty, journal.state().error == nil else { throw NormalEditorError.dirty }
                if let draft = try journal.draft() {
                    guard draft.hash == NormalEditorPlan.hash(base.content) || draft.hash == NormalEditorPlan.hash(receive.remote.content) else { throw NormalEditorError.dirty }
                }
                try authority.requireMutation(sending: false); try willApply()
                try await applier.apply(localProjectID: NormalEditorPlan.local, snapshot: receive.remote)
                try NormalEditorRecoveryInjection.hit(.afterOriginalApply, journal: journal)
                guard try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    snapshot: receive.remote, expectedRevision: receive.baseline.revision) else { throw NormalEditorError.partial }
            }
        }
    }
}
