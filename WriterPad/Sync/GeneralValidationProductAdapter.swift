import Foundation

/// Uses copied product stores and a previously validated handshake. No auth,
/// dispatcher or handshake client is constructed in an offline prediction.
struct GeneralValidationIsolatedStorage: Sendable {
    let store: LazySyncV2ProjectBindingStore
    let adapter: GeneralValidationProductAdapter
    func completeAccepted(_ request: URLRequest, response: SyncV2JSON,
                          authorize: @escaping @Sendable () throws -> Void) async throws {
        try authorize()
        guard let contract = try GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate).contract,
              try SyncV2Contract.validateDocumentCommitResponse(request: contract, response: response) == .committed,
              response.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"] == .int(Int(GeneralValidationPlan.outgoingRevision)) else { throw GeneralValidationFailure.denied }
        try await GeneralValidationMutation.$current.withValue(authorize) {
            try await store.completeContractStructure(.init(localProjectID: GeneralValidationPlan.local,
                serverProjectID: GeneralValidationPlan.server, request: contract), response: response)
        }
        try authorize()
    }
    init(copy: GeneralValidationPlanningCopy, identity: any DeviceIdentityProviding,
         binding: ProjectSyncBinding, handshake: SyncV2ValidatedHandshake,
         preflight: @escaping @Sendable () throws -> Void) throws {
        let coordinator = SyncV2ProjectUploadPullCoordinator()
        let store = LazySyncV2ProjectBindingStore(databaseURL: copy.probe.syncURL, deviceIdentityProvider: identity, uploadPullCoordinator: coordinator)
        let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: copy.probe.metadataURL))
        let locator = FixedGeneralValidationWorkspace(root: copy.probe.workspace)
        let local = LocalDocumentStore(workspaceLocator: locator, metadataUpdater: repository,
            durableChangeRecorder: GeneralValidationPlanningRecorder(store: store, binding: binding, handshake: handshake))
        self.store = store
        adapter = GeneralValidationProductAdapter(store: store, documents: repository, local: local, identity: identity,
            coordinator: coordinator, contractPreflight: { preflight }, makePuller: { snapshot in
                SyncV2SnapshotPullService(client: snapshot, stateStore: store,
                    localApplier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: locator),
                    mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
                    folderApplier: SyncV2RemoteFolderApplier(documentRepository: repository, workspaceLocator: locator), folderDocuments: repository)
            })
    }
}
private struct FixedGeneralValidationWorkspace: ProjectWorkspaceLocating {
    let root: URL
    func workspaceRoot(for projectID: ProjectID) async throws -> URL {
        guard projectID == GeneralValidationPlan.local else { throw GeneralValidationFailure.denied }
        return root
    }
}
private struct GeneralValidationPlanningRecorder: DurableLocalChangeRecording {
    let store: LazySyncV2ProjectBindingStore
    let binding: ProjectSyncBinding
    let handshake: SyncV2ValidatedHandshake
    func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool { false }
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        do {
            return .queued(operationIDs: try await store.enqueueContractStructure(batch, binding: binding, handshake: handshake,
                general: true, authorize: { try GeneralValidationMutation.check() }))
        } catch { return .localSavedButNotQueued(reason: "격리 계획의 저장 기록을 만들지 못했습니다.") }
    }
}

/// Ordinary product storage operations for the internal runner. Construction does
/// not open a file, authenticate, claim a queue or create a network client.
actor GeneralValidationProductAdapter {
    typealias PullerFactory = @Sendable (GeneralValidationRemoteSnapshot) -> any SyncV2SnapshotPulling
    private let store: LazySyncV2ProjectBindingStore
    private let documents: any DocumentRepository
    private let local: any LocalDocumentStoring
    private let identity: any DeviceIdentityProviding
    private let coordinator: SyncV2ProjectUploadPullCoordinator
    private let makePuller: PullerFactory
    private let contractPreflight: @Sendable () async throws -> (@Sendable () throws -> Void)
    private let receivePreflight: @Sendable () async throws -> (@Sendable () throws -> Void)
    private var pending: SyncV2PendingContractBatch?
    private var saveStarted = false
    private var receiveStarted = false
    private var finished = false
    private var uploadPermit: SyncV2ProjectUploadPullCoordinator.UploadPermit?
    private var standingAuthorization: (@Sendable () throws -> Void)?
    init(store: LazySyncV2ProjectBindingStore, documents: any DocumentRepository,
         local: any LocalDocumentStoring, identity: any DeviceIdentityProviding,
         coordinator: SyncV2ProjectUploadPullCoordinator,
         contractPreflight: @escaping @Sendable () async throws -> (@Sendable () throws -> Void),
         receivePreflight: (@Sendable () async throws -> (@Sendable () throws -> Void))? = nil,
         makePuller: @escaping PullerFactory) {
        self.store = store; self.documents = documents; self.local = local; self.identity = identity
        self.coordinator = coordinator; self.makePuller = makePuller
        self.contractPreflight = contractPreflight
        self.receivePreflight = receivePreflight ?? contractPreflight
    }
    private func idle() async throws {
        let queue = try await store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)
        let general = try await store.generalQueueStatus(localProjectID: GeneralValidationPlan.local)
        guard queue == .idle, general.pendingCount == 0, general.attentionCount == 0, general.retryCount == 0 else { throw GeneralValidationFailure.denied }
    }
    private func node() async throws -> DocumentNode {
        guard let node = try await documents.document(id: DocumentID(rawValue: GeneralValidationPlan.document)),
              node.projectID == GeneralValidationPlan.local, node.kind == .text, node.deletionStatus == .active,
              node.parentID?.rawValue == GeneralValidationPlan.parent,
              node.relativePath.rawValue == "메인/원고/" + GeneralValidationPlan.name else { throw GeneralValidationFailure.denied }
        return node
    }
    private func requireBody(revision: Int64, content: String) async throws {
        let node = try await node()
        guard node.contentHash == SHA256ContentHasher().sha256(for: Data(content.utf8)),
              Data(try await local.loadText(for: node).utf8) == Data(content.utf8),
              let state = try await store.snapshotState(localProjectID: GeneralValidationPlan.local,
                serverProjectID: GeneralValidationPlan.server, documentID: GeneralValidationPlan.document),
              state.serverRevision == revision, !state.hasActiveOperation, !state.hasUnresolvedConflict, !state.hasPathCollision,
              state.serverPath == node.relativePath.rawValue else { throw GeneralValidationFailure.denied }
    }
    func makeEditor() async throws -> GeneralValidationEditor {
        guard GeneralValidationPlan.editorEnabled else { throw GeneralValidationFailure.denied }
        try await idle()
        try await requireBody(revision: GeneralValidationPlan.incomingRevision, content: GeneralValidationPlan.incoming)
        let editor = await GeneralValidationEditor(documents: documents, local: local)
        try await editor.open(node())
        return editor
    }
    func saveAndCaptureRequest(bearer: String, publishableKey: String,
                               editor: GeneralValidationEditor? = nil, draft: GeneralValidationEditor.Draft? = nil,
                               authorize: @escaping @Sendable () throws -> Void) async throws -> URLRequest {
        // A review build must fail before changing TXT, not only when claiming.
        try authorize(); try ReceiveValidationPolicy.current.requireSending()
        guard !saveStarted, !receiveStarted, !bearer.isEmpty, !publishableKey.isEmpty else { throw GeneralValidationFailure.denied }
        saveStarted = true
        let standing = try await contractPreflight()
        standingAuthorization = standing
        let checked: @Sendable () throws -> Void = { try authorize(); try standing() }
        return try await GeneralValidationMutation.$current.withValue(checked) {
            try await idle(); try await requireBody(revision: GeneralValidationPlan.incomingRevision, content: GeneralValidationPlan.incoming)
            let node = try await node(), device = try await identity.currentIdentifier().uuid
            guard let binding = try await store.binding(for: GeneralValidationPlan.local),
                  binding.serverProjectID == GeneralValidationPlan.server, binding.kind == .existingServerProject else { throw GeneralValidationFailure.denied }
            try checked()
            let generation: UInt64
            let receipt: DocumentSaveReceipt
            if GeneralValidationPlan.editorEnabled {
                guard let editor, let draft, let values = GeneralValidationRuntimeValues.current else { throw GeneralValidationFailure.denied }
                generation = values.editorGeneration
                GeneralValidationFailureDiagnostic.mark(.editorSave)
                receipt = try await editor.save(draft, authorize: checked)
            } else {
                generation = UInt64((GeneralValidationRuntimeValues.current?.date ?? Date()).timeIntervalSince1970 * 1_000_000)
                receipt = try await local.saveCompared(.init(projectID: node.projectID, documentID: node.id,
                    relativePath: node.relativePath, text: GeneralValidationPlan.outgoing, generation: generation,
                    expectedCurrentContentHash: SHA256ContentHasher().sha256(for: Data(GeneralValidationPlan.incoming.utf8))), authorize: checked)
            }
            try checked()
            guard case let .queued(ids) = receipt.durableRecordResult, ids.count == 1,
                  receipt.projectID == node.projectID, receipt.documentID == node.id, receipt.relativePath == node.relativePath,
                  receipt.generation == generation,
                  receipt.savedContent?.utf8Data == Data(GeneralValidationPlan.outgoing.utf8),
                  receipt.contentHash == SHA256ContentHasher().sha256(for: Data(GeneralValidationPlan.outgoing.utf8)),
                  Data(try await local.loadText(for: node).utf8) == Data(GeneralValidationPlan.outgoing.utf8) else { throw GeneralValidationFailure.denied }
            let queue = try await store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)
            guard let permit = await coordinator.beginUploadDrain(localProjectID: GeneralValidationPlan.local, queue: queue) else { throw GeneralValidationFailure.denied }
            uploadPermit = permit
            let claimed = try await store.claimNextGeneralContract(localProjectID: GeneralValidationPlan.local)
            pending = claimed
            try checked()
            guard claimed.localProjectID == GeneralValidationPlan.local, claimed.serverProjectID == GeneralValidationPlan.server,
                  let intent = claimed.request.orderedIntents.first?.objectValue,
                  intent["operation_id"] == .string(ids[0].uuidString.lowercased()),
                  claimed.request.json == (try GeneralValidationPlan.update(device: device, operation: ids[0],
                    batch: claimed.request.batchID, build: claimed.request.json.objectValue?["batch"]?.objectValue?["client_build_id"]?.stringValue ?? "")).json else { throw GeneralValidationFailure.denied }
            var request = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/document_commit")!)
            request.httpMethod = "POST"
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(SyncV2AtomicStructureParameters(request: claimed.request.json))
            _ = try GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate)
            return request
        }
    }
    /// Release only the in-memory coordinator permit. Persisted queue/journal
    /// state is untouched, including when the server response was lost.
    func end() async {
        guard let permit = uploadPermit else { return }
        uploadPermit = nil
        await coordinator.finishUploadDrain(permit,
            queue: (try? await store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)) ?? .init(retryWaitingCount: 1))
    }
    func finish(_ response: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws {
        guard saveStarted, !finished, let pending, let standing = standingAuthorization else { throw GeneralValidationFailure.denied }
        // Failure is terminal for this adapter; no second completion attempt.
        finished = true
        try authorize(); try ReceiveValidationPolicy.current.requireSending()
        let checked: @Sendable () throws -> Void = { try authorize(); try standing() }
        try await GeneralValidationMutation.$current.withValue(checked) {
            try checked()
            guard try SyncV2Contract.validateDocumentCommitResponse(request: pending.request, response: response) == .committed,
                  response.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"] == .int(Int(GeneralValidationPlan.outgoingRevision)) else { throw GeneralValidationFailure.denied }
            try await store.completeContractStructure(pending, response: response)
            try checked(); try await requireBody(revision: GeneralValidationPlan.outgoingRevision, content: GeneralValidationPlan.outgoing)
            try await idle(); try checked()
        }
    }
    func apply(_ snapshot: GeneralValidationRemoteSnapshot,
               authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2SnapshotPullReport {
        try authorize(); try ReceiveValidationPolicy.current.requireApplication(local: GeneralValidationPlan.local, server: GeneralValidationPlan.server)
        guard !receiveStarted, !saveStarted else { throw GeneralValidationFailure.denied }
        receiveStarted = true
        let standing = try await receivePreflight()
        let checked: @Sendable () throws -> Void = { try authorize(); try standing() }
        return try await GeneralValidationMutation.$current.withValue(checked) {
            try await idle(); try checked()
            let queue = try await store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)
            guard let permit = await coordinator.observeServerChange(localProjectID: GeneralValidationPlan.local,
                queue: queue, bootstrapAllowed: false) else { throw GeneralValidationFailure.denied }
            do {
                let report = try await makePuller(snapshot).pull(localProjectID: GeneralValidationPlan.local,
                    serverProjectID: GeneralValidationPlan.server, editingGuards: [:])
                try checked()
                let docs = try await snapshot.fetchDocuments(projectID: GeneralValidationPlan.server)
                guard let target = docs.first(where: { $0.documentID == GeneralValidationPlan.document }),
                      report.contractStructureBaselineReady, !report.hasDeferredLocalApplication,
                      report.rejectedStructureNames.isEmpty, report.pendingChildTombstoneFolderCount == 0,
                      !report.outcomes.contains(where: { if case .mergeRequired = $0 { true } else { false } }) else { throw GeneralValidationFailure.denied }
                try await requireBody(revision: target.revision, content: target.content); try await idle(); try checked()
                _ = await coordinator.finishPull(permit, succeeded: true, queue: .idle)
                return report
            } catch {
                _ = await coordinator.finishPull(permit, succeeded: false,
                    queue: (try? await store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)) ?? .init(retryWaitingCount: 1))
                throw error
            }
        }
    }
}

extension GeneralValidationStageService {
    func send(bearer: String, publishableKey: String, transition: GeneralValidationLocalTransition,
              adapter: GeneralValidationProductAdapter) async throws {
        do {
            try await send(bearer: bearer, transition: transition) { authorize in
                try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: publishableKey, authorize: authorize)
            } finish: { response, authorize in try await adapter.finish(response, authorize: authorize) }
            await adapter.end()
        } catch { await adapter.end(); throw error }
    }
    func receive(stage: GeneralValidationPlan.Stage, requests: [URLRequest], bearer: String,
                 baseline: GeneralValidationRemoteBaseline, transition: GeneralValidationLocalTransition,
                 adapter: GeneralValidationProductAdapter) async throws {
        try await receive(stage: stage, requests: requests, bearer: bearer, baseline: baseline, transition: transition) { snapshot, authorize in
            try await adapter.apply(snapshot, authorize: authorize)
        }
    }
}

/// Foreground composition only. Uses existing stores; construction is inert.
actor GeneralValidationRuntime {
    struct Prepared: Sendable {
        let capability: GeneralValidationCapability
        let handshake: SyncV2ValidatedHandshake
        let binding: ProjectSyncBinding
        let baseline: GeneralValidationRemoteBaseline
    }
    private let auth: any AuthenticationServicing
    private let handshakeService: SyncV2HandshakeService
    private let identity: any DeviceIdentityProviding
    private let configuration: SupabasePublicConfiguration
    private let binding: @Sendable () async throws -> ProjectSyncBinding?
    private let context: @Sendable () async throws -> SyncV2HandshakeContext
    private let gate: @Sendable () throws -> (@Sendable () throws -> Void)
    private let adapter: @Sendable () -> GeneralValidationProductAdapter
    private let baseline: @Sendable () throws -> GeneralValidationRemoteBaseline
    private var busy = false
    init(auth: any AuthenticationServicing, handshake: SyncV2HandshakeService,
         identity: any DeviceIdentityProviding, configuration: SupabasePublicConfiguration,
         binding: @escaping @Sendable () async throws -> ProjectSyncBinding?,
         context: @escaping @Sendable () async throws -> SyncV2HandshakeContext,
         gate: @escaping @Sendable () throws -> (@Sendable () throws -> Void),
         adapter: @escaping @Sendable () -> GeneralValidationProductAdapter,
         baseline: @escaping @Sendable () throws -> GeneralValidationRemoteBaseline = { try .preserved() }) {
        self.auth = auth; handshakeService = handshake; self.identity = identity; self.configuration = configuration
        self.binding = binding; self.context = context; self.gate = gate; self.adapter = adapter; self.baseline = baseline
    }
    func prepare(probe: GeneralValidationLocalProbe, snapshot: GeneralValidationLocalProbe.Snapshot,
                 current: @escaping @Sendable () throws -> Void) async throws -> Prepared {
        guard !busy else { throw GeneralValidationFailure.denied }; busy = true
        defer { busy = false }
        try current()
        let gateCheck = try gate(), policy = ReceiveValidationPolicy.current
        guard configuration.url.absoluteString == ReceiveValidationPolicy.Configuration.staging,
              let ticket = try policy.authorization(), let binding = try await binding(),
              binding.localProjectID == GeneralValidationPlan.local, binding.serverProjectID == GeneralValidationPlan.server,
              binding.kind == .existingServerProject,
              case let .authenticated(account) = await auth.currentState(), account.userID == binding.ownerSubject else { throw GeneralValidationFailure.denied }
        let bearer = try await auth.generalValidationBearer(), context = try await context()
        let baseline = try baseline(); try baseline.validate()
        let capability = try GeneralValidationCapability(policy: policy, ticket: ticket, bearer: bearer,
            current: { try current(); try gateCheck() })
        do {
            let handshake = try await capability.withContext {
                try policy.select(GeneralValidationPlan.server)
                return try await self.handshakeService.refresh(context: context)
            }
            guard handshake.projectSyncMode == .idBased, handshake.migrationEpoch == 1,
                  handshake.contractSHA256 == SyncV2Contract.canonicalSHA256,
                  try probe.capture() == snapshot else { throw GeneralValidationFailure.denied }
            let epoch = handshakeService.authorizationEpoch, version = epoch.value
            try capability.bindHandshake {
                guard epoch.isAvailable, epoch.value == version else { throw GeneralValidationFailure.denied }
            }
            return .init(capability: capability, handshake: handshake, binding: binding, baseline: baseline)
        } catch { capability.stop(); throw error }
    }
    func makeEditor() async throws -> GeneralValidationEditor { try await adapter().makeEditor() }
    private func readRequests(bearer: String) -> [URLRequest] {
        ["documents", "folders", "tree_orders"].map { name in
            var url = URLComponents(url: configuration.url.appendingPathComponent("rest/v1/" + name), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "select", value: GeneralValidationRemoteSnapshot.columns[name]!),
                             .init(name: "project_id", value: "eq." + GeneralValidationPlan.server.uuidString.lowercased())]
            var request = URLRequest(url: url.url!); request.httpMethod = "GET"; request.timeoutInterval = 15
            request.setValue(bearer, forHTTPHeaderField: "Authorization"); request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
            return request
        }
    }
    private func exchange(_ request: URLRequest, execution: GeneralValidationExecution) async throws -> (Data, URLResponse) {
        try await GeneralValidationExecution.$current.withValue(execution) {
            let session = ReceiveValidationURLProtocol.session()
            defer { session.invalidateAndCancel() }
            return try await session.data(for: request)
        }
    }
    func run(stage: GeneralValidationPlan.Stage, prepared: Prepared, probe: GeneralValidationLocalProbe,
             before: GeneralValidationLocalProbe.Snapshot, journalRoot: URL, editor: GeneralValidationEditor? = nil) async throws -> GeneralValidationLocalProbe.Snapshot {
        guard !busy, before.stage == stage else { throw GeneralValidationFailure.denied }; busy = true
        defer { busy = false }
        let draft: GeneralValidationEditor.Draft?
        if GeneralValidationPlan.editorEnabled && stage == .sendUpdate {
            guard let editor else { throw GeneralValidationEditor.Failure.wrongDraft }
            draft = try await editor.draft()
        } else { draft = nil }
        let capability = prepared.capability
        let diagnostic = GeneralValidationFailureDiagnostic()
        return try await GeneralValidationFailureDiagnostic.$current.withValue(diagnostic) {
            try await capability.withContext {
                try await GeneralValidationRuntimeValues.$current.withValue(GeneralValidationRuntimeValues()) {
                    try capability.begin(stage)
                    let cursor = GeneralValidationRuntimeCursor(check: {
                        try capability.check()
                        guard try probe.capture() == before else { throw GeneralValidationFailure.denied }
                    })
                    try cursor.check()
                    try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let reservation = try GeneralValidationJournal(root: journalRoot, stage: stage)
                    var execution: GeneralValidationExecution?
                    let actual = self.adapter()
                    do {
                        let planningRoot = journalRoot.appendingPathComponent("planning")
                        try FileManager.default.createDirectory(at: planningRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        if stage != .sendUpdate {
                            let requests = await self.readRequests(bearer: capability.bearer)
                            try GeneralValidationRemoteSnapshot.validateRequests(requests); try capability.register(requests)
                            let run = try GeneralValidationExecution(root: journalRoot, stage: stage, requests: requests, bearer: capability.bearer,
                                checkCurrent: { try capability.check() }, checkLocal: { try cursor.check() }, reservation: reservation)
                            execution = run
                            var data: [Data] = []
                            for request in requests { data.append(try await self.exchange(request, execution: run).0) }
                            try run.requireAcceptedPayloads(data)
                            diagnostic.enter(.responses, .validateResponse)
                            let snapshot = try GeneralValidationRemoteSnapshot(stage: stage, data: data, baseline: prepared.baseline)
                            diagnostic.enter(.prediction, .copy)
                            let copy = try GeneralValidationPlanningCopy.create(from: probe, in: planningRoot)
                            let predicted = try GeneralValidationIsolatedStorage(copy: copy, identity: self.identity,
                                binding: prepared.binding, handshake: prepared.handshake, preflight: { try capability.check() })
                            // The cursor already compares the complete original probe
                            // to the sealed starting snapshot on every authorization.
                            diagnostic.enter(.prediction, .apply)
                            _ = try await GeneralValidationMutation.$current.withValue({ try cursor.check() }) {
                                try await predicted.adapter.apply(snapshot, authorize: { try cursor.check() })
                            }
                            diagnostic.enter(.prediction, .checkpoint)
                            let transition = try copy.predictedCheckpoint().makeTransition(probe: probe, current: { try capability.check() })
                            try cursor.check()
                            diagnostic.enter(.original, .apply)
                            _ = try await transition.advance { authorize in try await actual.apply(snapshot, authorize: authorize) }
                            try cursor.finish(transition)
                        } else {
                            diagnostic.enter(.prediction, .copy)
                            // The journal was reserved before planning or saving.
                            let copy = try GeneralValidationPlanningCopy.create(from: probe, in: planningRoot)
                            let predicted = try GeneralValidationIsolatedStorage(copy: copy, identity: self.identity,
                                binding: prepared.binding, handshake: prepared.handshake, preflight: { try capability.check() })
                            diagnostic.enter(.prediction, .apply)
                            let predictedEditor: GeneralValidationEditor?
                            if let draft {
                                let value = try await predicted.adapter.makeEditor()
                                await value.usePrediction(draft)
                                predictedEditor = value
                            } else { predictedEditor = nil }
                            let request = try await GeneralValidationMutation.$current.withValue({ try cursor.check() }) {
                                try await predicted.adapter.saveAndCaptureRequest(bearer: capability.bearer, publishableKey: self.configuration.publishableKey,
                                    editor: predictedEditor, draft: draft, authorize: { try cursor.check() })
                            }
                            diagnostic.enter(.prediction, .checkpoint)
                            let save = try copy.predictedCheckpoint(savedForUpdate: true).makeTransition(probe: probe, current: { try capability.check() })
                            try cursor.check()
                            diagnostic.enter(.original, .apply)
                            let actualRequest = try await save.advance { authorize in
                                try await actual.saveAndCaptureRequest(bearer: capability.bearer, publishableKey: self.configuration.publishableKey, editor: editor, draft: draft, authorize: authorize)
                            }
                            await predicted.adapter.end()
                            try cursor.finish(save)
                            guard GeneralSyncValidationScope.fingerprint(actualRequest) == GeneralSyncValidationScope.fingerprint(request) else { throw GeneralValidationFailure.denied }
                            try capability.register([actualRequest])
                            let run = try GeneralValidationExecution(root: journalRoot, stage: stage, requests: [actualRequest], bearer: capability.bearer,
                                checkCurrent: { try capability.check() }, checkLocal: { try cursor.check() }, reservation: reservation)
                            execution = run
                            diagnostic.enter(.responses, .transport)
                            let response = try await self.exchange(actualRequest, execution: run)
                            try run.requireAcceptedPayloads([response.0])
                            let json = try JSONDecoder().decode(SyncV2JSON.self, from: response.0)
                            diagnostic.enter(.prediction, .copy)
                            let completionCopy = try GeneralValidationPlanningCopy.create(from: probe, in: planningRoot, savedForUpdate: true)
                            let completionPrediction = try GeneralValidationIsolatedStorage(copy: completionCopy, identity: self.identity,
                                binding: prepared.binding, handshake: prepared.handshake, preflight: { try capability.check() })
                            diagnostic.enter(.prediction, .apply)
                            try await completionPrediction.completeAccepted(actualRequest, response: json,
                                authorize: { try cursor.check() })
                            diagnostic.enter(.prediction, .checkpoint)
                            let completion = try completionCopy.predictedCheckpoint().makeTransition(probe: probe, current: { try capability.check() })
                            try cursor.check()
                            diagnostic.enter(.original, .finish)
                            try await completion.advance { authorize in try await actual.finish(json, authorize: authorize) }
                            try cursor.finish(completion)
                        }
                        diagnostic.enter(.completion, .finish)
                        guard let execution else { throw GeneralValidationFailure.denied }
                        try execution.completeAfterLocalValidation { try cursor.check() }
                        try cursor.check(); let result = try probe.capture(); try cursor.check()
                        await actual.end(); try capability.finishStage()
                        return result
                    } catch {
                        capability.stop()
                        execution?.stop(); try? reservation.append(.stopped, sequence: 0)
                        diagnostic.observeOriginal(probe)
                        try? diagnostic.preserve(error: error, journal: reservation, root: journalRoot)
                        await actual.end(); throw error
                    }
                }
            }
        }
    }
}

private final class GeneralValidationRuntimeCursor: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var checked: @Sendable () throws -> Void
    init(check: @escaping @Sendable () throws -> Void) { checked = check }
    func check() throws { try lock.withLock { try checked() } }
    func finish(_ transition: GeneralValidationLocalTransition) throws {
        try transition.requireFinished()
        lock.withLock { checked = { try transition.requireFinished() } }
        try check()
    }
}
