import Foundation
import XCTest
@testable import WriterPad

private let normalInitial = "일반 본문 검증 20260912\n이 문서는 일반 동기화 시험용 합성 원고입니다.\n끝.\niPad 일반 검증 20260912\nWindows 일반 검증 20260912\nWindows 일반 편집 검증 20260913\niPad 일반 편집 검증 20260913\nWindows 자동저장 검증 20260913\n"
private func normalSnapshot(_ text: String = normalInitial, revision: Int64 = 6) -> SyncV2RemoteDocumentSnapshot {
    .init(documentID: NormalEditorPlan.document, relativePath: NormalEditorPlan.path, content: text, revision: revision,
          isDeleted: false, deletedAt: nil, updatedAt: Date(timeIntervalSince1970: 100), parentFolderID: NormalEditorPlan.parent,
          name: GeneralValidationPlan.name, structureRevision: 1)
}
private func normalBatch(_ text: String, batch: UUID = UUID(), operation: UUID = UUID()) -> LocalMutationBatch {
    .init(batchID: batch, projectID: NormalEditorPlan.local, localTransactionID: nil,
          mutations: [.documentSnapshot(operationID: operation, documentID: .init(rawValue: NormalEditorPlan.document),
              relativePath: .init(rawValue: NormalEditorPlan.path), content: text,
              contentHash: ContentHash(rawValue: NormalEditorPlan.hash(text))!, localSaveGeneration: 1, isDeleted: false)])
}
private actor NormalTestRepository: DocumentRepository {
    var node = DocumentNode(id: .init(rawValue: NormalEditorPlan.document), projectID: NormalEditorPlan.local, kind: .text,
        parentID: .init(rawValue: NormalEditorPlan.parent), relativePath: .init(rawValue: NormalEditorPlan.path), userOrder: 0,
        modifiedAt: Date(timeIntervalSince1970: 100), contentHash: .init(rawValue: NormalEditorPlan.initialHash))
    var folders: [DocumentNode] = []
    func addFolders(root: UUID) {
        folders = [DocumentNode(id: .init(rawValue: root), projectID: NormalEditorPlan.local, kind: .folder,
            parentID: nil, relativePath: .init(rawValue: "메인"), userOrder: 0, modifiedAt: Date(), contentHash: nil),
            DocumentNode(id: .init(rawValue: NormalEditorPlan.parent), projectID: NormalEditorPlan.local, kind: .folder,
            parentID: .init(rawValue: root), relativePath: .init(rawValue: "메인/원고"), userOrder: 0, modifiedAt: Date(), contentHash: nil)]
    }
    func documents(in projectID: ProjectID) -> [DocumentNode] { projectID == node.projectID ? folders + [node] : [] }
    func document(id: DocumentID) -> DocumentNode? { id == node.id ? node : folders.first { $0.id == id } }
    func save(_ document: DocumentNode) { if document.id == node.id { node = document } else { folders.removeAll { $0.id == document.id }; folders.append(document) } }
    func removeMetadata(id: DocumentID) {}
}
private actor NormalTestBackend: NormalEditorBackend {
    var base = normalSnapshot()
    var server = normalSnapshot()
    let file: URL
    var prepared = false
    var failBeforeHTTP = false
    var loseResponse = false
    var failCompletion = false
    var failApplyAfterText = false
    var missingReceipt = false
    var requests: [SyncV2ContractRequest] = []
    var reads = 0
    var receiptReads = 0
    var finishes = 0
    var prepares = 0
    var beforeBaseline: (@Sendable () async -> Void)?
    let device = UUID()
    init(file: URL) { self.file = file }
    func configure(before: Bool = false, lost: Bool = false, completion: Bool = false, apply: Bool = false, missing: Bool = false) {
        failBeforeHTTP = before; loseResponse = lost; failCompletion = completion; failApplyAfterText = apply; missingReceipt = missing
    }
    func setRemote(_ text: String, revision: Int64) { server = normalSnapshot(text, revision: revision) }
    func onNextBaseline(_ action: @escaping @Sendable () async -> Void) { beforeBaseline = action }
    func localBaseline() async -> SyncV2RemoteDocumentSnapshot {
        let action = beforeBaseline; beforeBaseline = nil
        await action?()
        return base
    }
    func localText() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func prepare() { prepares += 1; prepared = true }
    func invalidate() { prepared = false }
    func remote() throws -> SyncV2RemoteDocumentSnapshot {
        guard prepared else { throw NormalEditorError.locked }; reads += 1; return server
    }
    func freeze(_ source: LocalMutationBatch) throws -> SyncV2ContractRequest {
        guard prepared, case let .documentSnapshot(operation, _, _, text, _, _, _) = source.mutations[0] else { throw NormalEditorError.locked }
        return try SyncV2Contract.buildDocumentCommitRequest(projectID: NormalEditorPlan.server, projectSyncMode: .idBased,
            migrationEpoch: 1, writerDeviceID: device, documentID: NormalEditorPlan.document, intentKind: .update,
            baseRevision: Int(base.revision), parentFolderID: NormalEditorPlan.parent, name: GeneralValidationPlan.name,
            content: text, isDeleted: false, structureRevision: 1, operationID: operation, batchID: source.batchID)
    }
    func transmit(_ request: SyncV2ContractRequest, willStart: @escaping @Sendable () throws -> Void) throws -> SyncV2JSON {
        guard prepared else { throw NormalEditorError.locked }
        if failBeforeHTTP { throw NormalEditorError.locked }
        try willStart(); requests.append(request)
        let payload = request.orderedIntents[0].objectValue!["payload"]!.objectValue!
        server = normalSnapshot(payload["content"]!.stringValue!, revision: base.revision + 1)
        if loseResponse { throw URLError(.networkConnectionLost) }
        return makeGeneralCommitResponseForTesting(.init(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: request))
    }
    func receipt(_ request: SyncV2ContractRequest) throws -> SyncV2JSON? {
        guard prepared else { throw NormalEditorError.locked }; receiptReads += 1
        if missingReceipt { return nil }
        return makeGeneralCommitResponseForTesting(.init(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: request))
    }
    func complete(_ request: SyncV2ContractRequest, response: SyncV2JSON) throws {
        guard prepared else { throw NormalEditorError.locked }
        if failCompletion { throw NormalEditorError.storage }
        base = server; finishes += 1
    }
    func apply(_ receive: NormalEditorJournal.Receive, willApply: @escaping @Sendable () throws -> Void) throws {
        guard prepared else { throw NormalEditorError.locked }
        try willApply()
        try Data(receive.remote.content.utf8).write(to: file, options: .atomic)
        if failApplyAfterText { throw NormalEditorError.partial }
        base = receive.remote
    }
}

@MainActor
final class NormalEditorTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let journal: NormalEditorJournal
        let model: NormalEditorSession
        let backend: NormalTestBackend
        let local: NormalEditorDocumentStore
        let file: URL
    }
    private func fixture(autosave: Duration = .seconds(3600)) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NormalEditorTests-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let file = workspace.appendingPathComponent(NormalEditorPlan.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(normalInitial.utf8).write(to: file)
        let journal = try NormalEditorJournal(root: root.appendingPathComponent("journal")), repository = NormalTestRepository()
        let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace), metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
        let local = NormalEditorDocumentStore(local: product, journal: journal)
        let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
            workspaceStateRepository: NormalTestWorkspace(), preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: autosave)
        let backend = NormalTestBackend(file: file)
        let model = NormalEditorSession(editor: editor, journal: journal, backend: backend, documents: repository)
        await model.open()
        XCTAssertTrue(model.opened, model.message)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(root: root, journal: journal, model: model, backend: backend, local: local, file: file)
    }
    func testLocalSaveDoesNotRequireLoginAndPreservesUTF8AndFinalLF() async throws {
        let f = try await fixture()
        for text in ["  자유 본문\n끝  ", "NFD: e\u{301} 한글🙂\n", "NFC: é\n\n", ""] {
            f.model.editor.updateText(text); await f.model.save()
            XCTAssertEqual(try Data(contentsOf: f.file), Data(text.utf8))
            XCTAssertEqual(try f.journal.draft()?.hash, NormalEditorPlan.hash(text))
        }
        let writes = await f.backend.requests; XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(f.model.prepared)
    }
    func testCanonicallyEquivalentTextChangeIsNotDiscarded() async throws {
        let f = try await fixture()
        f.model.editor.updateText("é"); await f.model.save()
        f.model.editor.updateText("e\u{301}"); await f.model.save()
        XCTAssertEqual(try Data(contentsOf: f.file), Data("e\u{301}".utf8))
    }
    func testIdleSaveUsesProductionPathWithoutAuthentication() async throws {
        let f = try await fixture(autosave: .milliseconds(20))
        f.model.editor.updateText("유휴 저장\n")
        for _ in 0..<100 where f.journal.state().head == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try Data(contentsOf: f.file), Data("유휴 저장\n".utf8))
        XCTAssertNotNil(f.journal.state().head)
        let requests = await f.backend.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testDraftAndQueueIDsSurviveReopen() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장한 본문"); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        f.model.editor.updateText("저장 전 초안\n")
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().saves.last?.source, source)
        XCTAssertEqual(try reopened.draft()?.text, "저장 전 초안\n")
    }
    func testHTTPNotStartedKeepsSameRequestForFirstTransmission() async throws {
        let f = try await fixture()
        f.model.editor.updateText("송신할 자유 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let frozen = try XCTUnwrap(f.journal.state().saves.first?.requestHash)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .frozen)
        XCTAssertEqual(f.journal.state().saves.first?.attempts.count, 0)
        await f.backend.configure(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.requestHash, frozen)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
        let requests = await f.backend.requests; XCTAssertEqual(requests.count, 1)
    }
    func testLostResponseRequiresReceiptAndNeverResends() async throws {
        let f = try await fixture()
        f.model.editor.updateText("응답 유실 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        let hash = f.journal.state().saves.first?.requestHash
        await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().saves.first?.requestHash, hash)
        let writes = await f.backend.requests, reads = await f.backend.receiptReads
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(reads, 1)
    }
    func testMissingReceiptIsNotPermissionToResend() async throws {
        let f = try await fixture()
        f.model.editor.updateText("원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true, missing: true); await f.model.send()
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 1)
    }
    func testStoredResponseFinishesLocallyWithoutAnotherGETOrPOST() async throws {
        let f = try await fixture()
        f.model.editor.updateText("완료 반영 전 중단"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(completion: true); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .responseStored)
        await f.backend.configure(); await f.model.prepare(); await f.model.recoverResult()
        let reads = await f.backend.receiptReads, writes = await f.backend.requests
        XCTAssertEqual(reads, 0); XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
    }
    func testFollowingEditDoesNotReplaceFrozenOperationOrItsBody() async throws {
        let f = try await fixture()
        f.model.editor.updateText("첫 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true); await f.model.send()
        let first = f.journal.state().saves[0]
        f.model.editor.updateText("후속 원고"); await f.model.save()
        XCTAssertEqual(f.journal.state().saves.count, 2)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, first.requestHash)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(try Data(contentsOf: f.file), Data("후속 원고".utf8))
        XCTAssertEqual(f.journal.state().head, 1)
    }
    func testDirtyOrPendingLocalWorkBlocksReceiveBeforeGET() async throws {
        let f = try await fixture()
        f.model.editor.updateText("미저장"); await f.model.prepare(); await f.model.receive()
        var reads = await f.backend.reads; XCTAssertEqual(reads, 0)
        await f.model.save(); await f.model.prepare(); await f.model.receive()
        reads = await f.backend.reads; XCTAssertEqual(reads, 0)
        XCTAssertEqual(try Data(contentsOf: f.file), Data("미저장".utf8))
    }
    func testRemoteConflictPreservesAllThreeBodiesAcrossNewSave() async throws {
        let f = try await fixture()
        f.model.editor.updateText("로컬 변경"); await f.model.save()
        await f.backend.setRemote("상대 변경", revision: 7)
        await f.model.prepare(); await f.model.send()
        let conflict = try XCTUnwrap(f.journal.state().conflicts.first)
        XCTAssertEqual(conflict.baseline, normalInitial); XCTAssertEqual(conflict.local, "로컬 변경"); XCTAssertEqual(conflict.remote.content, "상대 변경")
        f.model.editor.updateText("후속 편집"); await f.model.save()
        XCTAssertEqual(f.journal.state().conflicts.count, 1)
        XCTAssertEqual(f.journal.state().head, 0)
        XCTAssertEqual(f.journal.state().saves[0].phase, .queued)
        let writes = await f.backend.requests; XCTAssertTrue(writes.isEmpty)
    }
    func testPartialReceiveResumesApplyWithoutRepeatingRemoteFetch() async throws {
        let f = try await fixture()
        await f.backend.setRemote("받은 원고\n", revision: 7)
        await f.backend.configure(apply: true); await f.model.prepare(); await f.model.receive()
        XCTAssertEqual(f.journal.state().receive?.phase, "originalApplyStarted")
        XCTAssertEqual(try Data(contentsOf: f.file), Data("받은 원고\n".utf8))
        await f.backend.configure(); await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive, f.model.message)
        let reads = await f.backend.reads; XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
    }
    func testCompletionSurvivesForegroundLossAndDoesNotReplay() async throws {
        let f = try await fixture()
        f.model.editor.updateText("완료"); await f.model.save(); await f.model.prepare(); await f.model.send()
        let message = f.model.message
        await f.model.setForeground(false)
        XCTAssertEqual(f.model.message, message); XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(try NormalEditorJournal(root: f.journal.root).state().message, message)
        await f.model.setForeground(true); await f.model.prepare(); await f.model.send()
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 1)
    }
    func testEmptyLocalBodyIsPreservedButNeverTransmitted() async throws {
        let f = try await fixture()
        f.model.editor.updateText(""); await f.model.save(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(try Data(contentsOf: f.file).count, 0)
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 0)
        f.model.editor.updateText("다시 작성"); await f.model.save(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.last?.phase, .completed, f.model.message)
    }
    func testCRRejectedWithoutTrimmingOrAlteringOriginal() async throws {
        let f = try await fixture()
        f.model.editor.updateText("CR\r\n본문"); await f.model.save()
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
        XCTAssertEqual(try f.journal.draft()?.text, "CR\r\n본문")
    }
    func testOtherDocumentAndStructureMutationsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        XCTAssertThrowsError(try journal.record(.init(batchID: UUID(), projectID: NormalEditorPlan.local, localTransactionID: nil,
            mutations: [.treeOrder(operationID: UUID(), content: "[]", generation: 1)])))
        let batch = normalBatch("본문")
        try journal.record(batch)
        XCTAssertThrowsError(try journal.record(normalBatch("다른 바이트", batch: batch.batchID)))
        XCTAssertEqual(journal.state().saves.count, 1)
    }
    func testRecordCorruptionStopsInsteadOfResettingCompletedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        try journal.record(normalBatch("본문"))
        let file = root.appendingPathComponent("000000000001.record")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try NormalEditorJournal(root: root))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testGenericReceiptAcceptsNewOperationAndRejectsTampering() throws {
        let request = try SyncV2Contract.buildDocumentCommitRequest(projectID: UUID(), projectSyncMode: .idBased, migrationEpoch: 1,
            writerDeviceID: UUID(), documentID: UUID(), intentKind: .update, baseRevision: 12, parentFolderID: UUID(),
            name: "자유 원고.txt", content: "자유 문장 e\u{301}🙂", isDeleted: false, structureRevision: 1)
        let project = UUID(uuidString: request.json.objectValue!["project_id"]!.stringValue!)!
        let pending = SyncV2PendingContractBatch(localProjectID: .init(rawValue: UUID()), serverProjectID: project, request: request)
        let user = UUID(), response = makeGeneralCommitResponseForTesting(pending)
        let receipt = try makeGeneralCommitReceiptForTesting(pending, accountID: user, response: response)
        XCTAssertEqual(try receipt.validatedResponse(for: pending, accountID: user), response)
        XCTAssertThrowsError(try receipt.validatedResponse(for: pending, accountID: UUID()))
        var batch = receipt.batch.objectValue!; batch["request_sha256"] = .string(String(repeating: "0", count: 64))
        XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: .object(batch), result: receipt.result).validatedResponse(for: pending, accountID: user))
    }
}

private actor NormalTestWorkspace: WorkspaceStateRepository {
    func lastProjectID() -> ProjectID? { nil }
    func setLastProjectID(_ projectID: ProjectID?) {}
    func editorState(for projectID: ProjectID) -> EditorWorkspaceState {
        .init(projectID: projectID, left: .init(documentID: nil, cursor: .start), right: nil, activePane: .left)
    }
    func saveEditorState(_ state: EditorWorkspaceState) {}
    func binderWidth(for projectID: ProjectID) -> Double { 280 }
    func setBinderWidth(_ width: Double, for projectID: ProjectID) {}
    func expandedFolderIDs(in projectID: ProjectID) -> Set<DocumentID> { [] }
    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) {}
    func cursor(for documentID: DocumentID) -> TextCursorState { .start }
    func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) {}
}

private struct NormalTestIdentity: DeviceIdentityProviding {
    let id = DeviceIdentifier(uuid: UUID())
    func currentState() async -> DeviceIdentityState { .ready(id) }
    func currentIdentifier() async throws -> DeviceIdentifier { id }
    func prepareIdentity() async {}
}
private struct NormalTestAuth: AuthenticationServicing {
    let user: UUID
    let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    func currentState() async -> AuthenticationState { .authenticated(.init(userID: user, maskedEmail: nil)) }
    func generalValidationBearer() async throws -> String { "Bearer isolated-test-token" }
    func restoreSession() async -> AuthenticationState { await currentState() }
    func refreshSession(force: Bool) async -> AuthenticationState { await currentState() }
    func signIn(email: String, password: String) async -> AuthenticationState { await currentState() }
    func signOut() async -> AuthenticationState { .signedOut(.userInitiated) }
}
private actor NormalWireStub {
    let structure: SyncV2PreparationSnapshot
    let user: UUID
    var writes = 0
    var receiptReads = 0
    var lose = false
    var snapshot = normalSnapshot()
    var storedReceipt: SyncV2GeneralCommitReceipt?
    var metadataReads = 0
    init(structure: SyncV2PreparationSnapshot, user: UUID) { self.structure = structure; self.user = user }
    func loseNextResponse() { lose = true }
    func editRemotely(_ text: String) { snapshot = normalSnapshot(text, revision: snapshot.revision + 1) }
    func exchange(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.lastPathComponent
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let selection = query.first { $0.name == "select" }?.value ?? ""
        if ["folders", "tree_orders", "documents"].contains(path) { metadataReads += 1 }
        let result: SyncV2JSON
        switch path {
        case "get_sync_handshake":
            result = .object(["supported": .bool(true), "project_id": .string(NormalEditorPlan.server.uuidString.lowercased()),
                "project_sync_mode": .string("ID_BASED"), "migration_epoch": .int(1), "contract_version": .string(SyncV2Contract.version),
                "canonical_contract_sha256": .string(SyncV2Contract.canonicalSHA256), "server_contract_sha256": .string(SyncV2Contract.canonicalSHA256),
                "server_protocol_version": .int(SyncV2Contract.syncProtocolVersion), "supported_protocol_versions": .array([.int(SyncV2Contract.syncProtocolVersion)]),
                "server_capabilities": .array(SyncV2Contract.requiredServerCapabilities.sorted().map(SyncV2JSON.string))])
        case "folders": result = .array(structure.folders)
        case "tree_orders": result = .array(structure.treeOrders)
        case "documents":
            if selection.contains("content,") {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                result = .array([try JSONDecoder().decode(SyncV2JSON.self, from: encoder.encode(snapshot))])
            } else {
                result = .array(structure.documents.map { row in
                    var values = row.objectValue!; values["revision"] = .int(Int(snapshot.revision)); return .object(values)
                })
            }
        case "document_commit":
            let envelope = try JSONDecoder().decode(SyncV2JSON.self, from: request.httpBody!)
            let contract = try SyncV2ContractRequest(storedJSON: envelope.objectValue!["p_request"]!)
            let pending = SyncV2PendingContractBatch(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: contract)
            result = makeGeneralCommitResponseForTesting(pending)
            storedReceipt = try makeGeneralCommitReceiptForTesting(pending, accountID: user, response: result)
            snapshot = normalSnapshot(contract.orderedIntents[0].objectValue!["payload"]!.objectValue!["content"]!.stringValue!, revision: snapshot.revision + 1)
            writes += 1
            if lose { lose = false; throw URLError(.networkConnectionLost) }
        case "sync_batches": receiptReads += 1; result = .array(storedReceipt.map { [$0.batch] } ?? [])
        case "sync_batch_results": receiptReads += 1; result = .array(storedReceipt.map { [$0.result] } ?? [])
        default: throw NormalEditorError.request
        }
        let data = try JSONEncoder().encode(result)
        let count = result.arrayValue?.count ?? 1
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Range": count == 0 ? "*/0" : "0-\(count - 1)/\(count)"])!)
    }
}

extension NormalEditorTests {
    private func stableJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    func testPreparedRunCancellationRecoversAfterDurableResaveWithoutRewritingHistory() async throws {
        let f = try await fixture(), first = "준비된 본문", second = "다시 저장한 본문"
        let config = runConfiguration(first)
        f.model.editor.updateText(first); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared)
        let bound = try XCTUnwrap(f.journal.state().recoveryRuns?.last?.batchID)
        f.model.editor.updateText(second); await f.model.save()
        await f.model.prepare()
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .superseded)
        // Restoring the same bytes is also a distinct durable save; never silently rebind it.
        f.model.editor.updateText(first); await f.model.save()
        await f.model.prepare()
        XCTAssertFalse(f.model.prepared)
        let saves = try stableJSON(f.journal.state().saves)
        let files = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "record" }
        let bytes = try files.map { try Data(contentsOf: $0) }
        let draft = try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json"))
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, false)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.batchID, bound)
        XCTAssertEqual(try stableJSON(f.journal.state().saves), saves)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json")), draft)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(first.utf8))
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.effectiveConfiguration(reopened))
        // No launch environment, a runless config, or a reused UUID must not bypass diagnostics.
        await f.model.prepare(); XCTAssertFalse(f.model.prepared)
        for invalid in [config, .init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(first))] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(invalid) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        let next = runConfiguration(first)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(next) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 2)
        XCTAssertNotEqual(f.journal.state().recoveryRuns?.last?.batchID, bound)
        // New run is durable too: no launch environment is needed to resume it.
        await f.model.send(); await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.first?.cancelled, true)
        let requests = await f.backend.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.batchID, f.journal.state().saves.last?.source.batchID)
    }
    func testPreparedRunCancellationAfterAutosaveDoesNotSendOrAcquireAuthority() async throws {
        let f = try await fixture(autosave: .milliseconds(20))
        f.model.editor.updateText("첫 저장"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("첫 저장")) { await f.model.prepare() }
        f.model.editor.updateText("자동 저장")
        for _ in 0..<100 where f.journal.state().saves.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.journal.state().saves.count, 2)
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertFalse(f.model.prepared)
        let prepares = await f.backend.prepares, requests = await f.backend.requests, reads = await f.backend.reads
        let backendPrepared = await f.backend.prepared
        XCTAssertEqual(prepares, 1); XCTAssertTrue(requests.isEmpty); XCTAssertEqual(reads, 0); XCTAssertFalse(backendPrepared)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("자동 저장")) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared, f.model.message)
    }
    func testCancellationRejectsAllMaterializedSendPhasesWithoutChangingJournal() async throws {
        for phase: NormalEditorJournal.Phase in [.freezing, .frozen, .httpStarted, .responseStored] {
            let f = try await fixture(), text = "취소 금지"
            f.model.editor.updateText(text); await f.model.save()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
            let request = try await f.backend.freeze(f.journal.state().saves[0].source)
            try f.journal.update("testMaterializedPhase") { state in
                state.saves[0].phase = phase
                if phase != .freezing {
                    state.saves[0].request = request.json; state.saves[0].requestHash = try request.json.sha256Hex()
                }
                if phase == .httpStarted || phase == .responseStored { state.saves[0].attempts = [UUID()] }
                if phase == .responseStored { state.saves[0].response = .object([:]) }
            }
            let before = try stableJSON(f.journal.state())
            let files = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
            XCTAssertFalse(NormalEditorRecoveryInjection.canCancelPreparedRun(f.journal.state()))
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
            XCTAssertEqual(try stableJSON(f.journal.state()), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), files)
            await f.model.cancelPreparedRecoveryRun()
            XCTAssertFalse(f.model.prepared)
            XCTAssertTrue(f.journal.state().recoveryRuns?.last?.isActive == true)
            XCTAssertEqual(f.journal.state().saves[0].phase, phase)
        }
    }
    func testCancellationRechecksRequestMarkersAndCheckpointEvenOnQueuedSource() async throws {
        let f = try await fixture(), text = "요청 표식"
        f.model.editor.updateText(text); await f.model.save()
        let config = runConfiguration(text)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) { await f.model.prepare() }
        let state = f.journal.state()
        for marker in 0..<5 {
            var unsafe = state
            switch marker {
            case 0: unsafe.saves[0].request = .object([:])
            case 1: unsafe.saves[0].requestHash = "recorded"
            case 2: unsafe.saves[0].response = .object([:])
            case 3: unsafe.saves[0].attempts = [UUID()]
            default: unsafe.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey(config)]
            }
            XCTAssertFalse(NormalEditorRecoveryInjection.canCancelPreparedRun(unsafe))
        }
    }
    func testReceivePreparationCanCancelButStoredOrPartialReceiveCannot() async throws {
        for phase in [nil, "responseStored", "originalApplyStarted"] as [String?] {
            let f = try await fixture()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("수신 본문", point: .afterOriginalApply)) {
                await f.model.prepare()
            }
            if let phase {
                try f.journal.update("testReceiveStarted") {
                    $0.receive = .init(id: UUID(), baseline: normalSnapshot(), remote: normalSnapshot("수신 본문", revision: 7), phase: phase)
                }
                let before = try stableJSON(f.journal.state())
                XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
                XCTAssertEqual(try stableJSON(f.journal.state()), before)
            } else {
                await f.model.cancelPreparedRecoveryRun()
                XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
            }
            let reads = await f.backend.reads, requests = await f.backend.requests
            XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
        }
    }
    func testCancellationIsExplicitAndCannotRunInBackgroundOrCompleteCancelledRun() async throws {
        let f = try await fixture(), text = "명시 취소"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let model = f.model
        await f.backend.onNextBaseline { await model.cancelPreparedRecoveryRun() }
        await model.prepare()
        XCTAssertTrue(model.prepared); XCTAssertNil(f.journal.state().recoveryRuns?.last?.cancelled)
        await f.model.setForeground(false)
        let before = try stableJSON(f.journal.state())
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertEqual(try stableJSON(f.journal.state()), before)
        await f.model.setForeground(true); await f.model.cancelPreparedRecoveryRun()
        var cancelled = f.journal.state()
        NormalEditorRecoveryInjection.completeRun(&cancelled)
        XCTAssertEqual(cancelled.recoveryRuns?.last?.completed, false)
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
    }
    func testPreparedRunCanBeCancelledAfterSessionReconstruction() async throws {
        let f = try await fixture()
        f.model.editor.updateText("이전 저장"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("이전 저장")) { await f.model.prepare() }
        f.model.editor.updateText("새 저장"); await f.model.save()
        await f.model.setForeground(false)
        let journal = try NormalEditorJournal(root: f.journal.root), repository = NormalTestRepository()
        let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: f.root.appendingPathComponent("workspace")),
            metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
        let local = NormalEditorDocumentStore(local: product, journal: journal)
        let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
            workspaceStateRepository: NormalTestWorkspace(), preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) },
            autosaveDelay: .seconds(3600))
        let model = NormalEditorSession(editor: editor, journal: journal, backend: f.backend, documents: repository)
        await model.open(); await model.prepare()
        XCTAssertTrue(model.opened); XCTAssertFalse(model.prepared)
        await model.cancelPreparedRecoveryRun()
        XCTAssertEqual(journal.state().recoveryRuns?.last?.cancelled, true)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("새 저장")) { await model.prepare() }
        XCTAssertTrue(model.prepared, model.message)
        XCTAssertEqual(journal.state().recoveryRuns?.count, 2)
    }
    func testCancellationPreservesUnsavedDraftAndRequiresCleanNewRun() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장 본문"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("저장 본문")) { await f.model.prepare() }
        f.model.editor.updateText("미저장 초안 e\u{301}🙂\n")
        let draft = try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json"))
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertTrue(f.model.editor.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json")), draft)
        XCTAssertEqual(try Data(contentsOf: f.file), Data("저장 본문".utf8))
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("저장 본문")) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 1)
    }
    func testRecoveryRunWithoutCancellationFieldStillDecodesAsActive() throws {
        let legacy = NormalEditorJournal.RecoveryRun(configuration: runConfiguration("이전 실행"), batchID: UUID())
        let bytes = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("cancelled"))
        let decoded = try JSONDecoder().decode(NormalEditorJournal.RecoveryRun.self, from: bytes)
        XCTAssertTrue(decoded.isActive); XCTAssertNil(decoded.cancelled)
    }
    private func runConfiguration(_ text: String, point: NormalEditorRecoveryInjection.Point = .afterStoredResponse,
                                  id: UUID = UUID(), revision: Int64 = 6, baseline: String = normalInitial) -> NormalEditorRecoveryInjection.Configuration {
        .init(point: point, contentHash: NormalEditorPlan.hash(text),
              run: .init(id: id, baselineRevision: revision, baselineHash: NormalEditorPlan.hash(baseline)))
    }
    func testRunConfigurationRequiresCompleteCanonicalIdentityAndBaseline() throws {
        let valid = ["WRITERPAD_RECOVERY_PLAN": NormalEditorRecoveryInjection.plan,
                     "WRITERPAD_RECOVERY_POINT": "afterStoredResponse",
                     "WRITERPAD_RECOVERY_CONTENT_SHA256": NormalEditorPlan.initialHash,
                     "WRITERPAD_RECOVERY_RUN_ID": UUID().uuidString.lowercased(),
                     "WRITERPAD_RECOVERY_BASE_REVISION": "6",
                     "WRITERPAD_RECOVERY_BASE_SHA256": NormalEditorPlan.initialHash]
        XCTAssertNotNil(try NormalEditorRecoveryInjection.parse(valid)?.run)
        for key in valid.keys {
            var invalid = valid; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid), key)
        }
        for (key, value) in [("WRITERPAD_RECOVERY_RUN_ID", "../escape"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", "06"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", "5"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", String(Int64.max)),
                             ("WRITERPAD_RECOVERY_BASE_SHA256", "invalid")] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid))
        }
    }
    func testRunPreparationDoesNotAcquireAuthorityAfterSceneDeactivationDuringLocalRead() async throws {
        let f = try await fixture(), text = "비활성 전환 준비"
        f.model.editor.updateText(text); await f.model.save()
        let model = f.model
        await f.backend.onNextBaseline { await model.setForeground(false) }
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await model.prepare() }
        let prepares = await f.backend.prepares
        XCTAssertEqual(prepares, 0); XCTAssertFalse(model.prepared)
        XCTAssertEqual(f.journal.state().saves.last?.phase, .queued)
    }
    func testRunRechecksDraftAfterPreparationBeforeRemoteRead() async throws {
        let f = try await fixture(), text = "준비한 저장"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared)
        f.model.editor.updateText("준비 이후의 미저장 변경")
        await f.model.send()
        let reads = await f.backend.reads, requests = await f.backend.requests
        XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(f.model.prepared)
    }
    func testRunAllowsAcknowledgedBaselineBeforeFinalJournalCompletion() async throws {
        let f = try await fixture(), text = "완료 기록 직전"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare(); await f.model.send() }
        let save = f.journal.state().saves[0]
        let request = try SyncV2ContractRequest(storedJSON: XCTUnwrap(save.request))
        await f.backend.prepare()
        try await f.backend.complete(request, response: XCTUnwrap(save.response))
        // Durable store advanced, append-only journal still has the old baseline/responseStored.
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves[0].phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
        let requests = await f.backend.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testRunPreflightRejectsWrongBaselineAndDirtyInputBeforeAuthority() async throws {
        let f = try await fixture(), text = "준비 검사🙂\n"
        f.model.editor.updateText(text); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        for configuration in [runConfiguration(text, revision: 7), runConfiguration(text, baseline: "wrong"), runConfiguration("wrong body")] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(configuration) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        f.model.editor.updateText("미저장 초안")
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let prepares = await f.backend.prepares
        XCTAssertEqual(prepares, 0); XCTAssertNil(f.journal.state().recoveryRuns)
        XCTAssertEqual(f.journal.state().saves.last?.source, source)
    }
    func testRunRejectsWrongTargetAndCompositionWithoutWritingJournal() async throws {
        let f = try await fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
        let wrong = SyncV2RemoteDocumentSnapshot(documentID: UUID(), relativePath: NormalEditorPlan.path,
            content: normalInitial, revision: 6, isDeleted: false, deletedAt: nil, updatedAt: Date(),
            parentFolderID: NormalEditorPlan.parent, name: GeneralValidationPlan.name, structureRevision: 1)
        try NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("수신", point: .afterOriginalApply)) {
            for (base, composing, failed) in [(wrong, false, false), (normalSnapshot(), true, false), (normalSnapshot(), false, true)] {
                XCTAssertThrowsError(try NormalEditorRecoveryInjection.preflight(journal: f.journal,
                    baseline: base, localText: normalInitial, dirty: false, composing: composing, draftFailed: failed))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), before)
    }
    func testRunCannotReplaceUncertainRequestAndReopensWithoutLaunchEnvironment() async throws {
        let f = try await fixture(), text = "불변 요청 e\u{301}\n", config = runConfiguration("불변 요청 e\u{301}\n")
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) {
            await f.model.prepare(); await f.model.send()
        }
        XCTAssertEqual(f.journal.state().saves[0].phase, .responseStored)
        let source = f.journal.state().saves[0]
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(try NormalEditorRecoveryInjection.effectiveConfiguration(reopened), config)
        for replacement in [runConfiguration(text), .init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(replacement) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        XCTAssertEqual(f.journal.state().saves[0].source, source.source)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, source.requestHash)
        XCTAssertEqual(f.journal.state().saves[0].attempts, source.attempts)
        // No launch configuration: the persisted run still selects the same checkpoint/operation.
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves[0].phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true)
        let writes = await f.backend.requests, reads = await f.backend.receiptReads
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(reads, 0)
    }
    func testDistinctRunsConsumeSamePointOnceEachWithoutRewritingOldRecords() async throws {
        let f = try await fixture(), first = "첫 실행\n", second = "다음 실행\n"
        let config1 = runConfiguration(first)
        f.model.editor.updateText(first); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config1) { await f.model.prepare(); await f.model.send() }
        await f.model.prepare(); await f.model.recoverResult()
        let oldRecords = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "record" }
        let bytes = try oldRecords.map { try Data(contentsOf: $0) }
        f.model.editor.updateText(second); await f.model.save()
        let config2 = runConfiguration(second, revision: 7, baseline: first)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config2) { await f.model.prepare(); await f.model.send() }
        XCTAssertEqual(f.journal.state().saves.last?.phase, .responseStored, f.model.message)
        XCTAssertEqual(Set(f.journal.state().recoveryCheckpoints ?? []),
            Set([NormalEditorRecoveryInjection.checkpointKey(config1), NormalEditorRecoveryInjection.checkpointKey(config2)]))
        XCTAssertEqual(try oldRecords.map { try Data(contentsOf: $0) }, bytes)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 2)
        XCTAssertTrue(f.journal.state().recoveryRuns?.allSatisfy(\.completed) == true)
        let writes = await f.backend.requests
        XCTAssertEqual(writes.count, 2)
        XCTAssertNotEqual(writes[0].batchID, writes[1].batchID)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config1) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared)
    }
    func testNewRunCannotAdoptLegacyFrozenRequest() async throws {
        let f = try await fixture(), text = "기존 동결 요청"
        f.model.editor.updateText(text); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let request = f.journal.state().saves[0].request
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared); XCTAssertNil(f.journal.state().recoveryRuns)
        XCTAssertEqual(f.journal.state().saves[0].request, request)
    }
    func testReceiveRunRejectsQueuedSaveBeforeAuthorityWithoutCompletingIt() async throws {
        let f = try await fixture()
        f.model.editor.updateText("잘못 저장한 본문"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("받을 본문", point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        let prepares = await f.backend.prepares, requests = await f.backend.requests
        XCTAssertEqual(prepares, 0); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(f.journal.state().saves.last?.phase, .queued)
        XCTAssertNil(f.journal.state().receive); XCTAssertNil(f.journal.state().recoveryRuns)
    }
    func testReceiveRunRejectsUnexpectedRemoteBeforeOriginalApply() async throws {
        let f = try await fixture(), text = "승인된 수신 본문"
        await f.backend.setRemote("다른 본문", revision: 7)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
        XCTAssertNil(f.journal.state().receive)
        XCTAssertFalse(f.model.prepared)
        await f.backend.setRemote(text, revision: 6)
        await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
    }
    func testReceiveRunResumesPartialOriginalUsingStoredRemoteWithoutSend() async throws {
        let f = try await fixture(), text = "수신 중단 복구🙂\n"
        await f.backend.setRemote(text, revision: 7)
        await f.backend.configure(apply: true)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        let receive = try XCTUnwrap(f.journal.state().receive)
        XCTAssertEqual(receive.phase, "originalApplyStarted")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(text.utf8))
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().receive?.id, receive.id)
        await f.backend.configure()
        await f.model.prepare(); await f.model.recoverResult() // Wrong direction cannot send/complete.
        XCTAssertNotNil(f.journal.state().receive)
        await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive, f.model.message)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
        XCTAssertEqual(try f.journal.draft()?.text, text)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true)
        let requests = await f.backend.requests, reads = await f.backend.reads
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(reads, 1)
    }
    func testRealContractQueueAndReceiptRecoveryUseSameOperation() async throws {
        let f = try await fixture()
        let url = f.root.appendingPathComponent("sync.sqlite")
        let user = UUID(), identity = NormalTestIdentity(), mainFolder = UUID()
        let unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let scope = GeneralSyncValidationScope(restricted: false, selection: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                guard case let .available(store) = await SyncV2Store.open(at: url) else { throw NormalEditorError.storage }
                try await store.save(ProjectSyncBinding.connected(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    kind: .existingServerProject, projectName: "합성", ownerSubject: user))
                _ = try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    snapshot: normalSnapshot(), expectedRevision: nil)
                try await store.adoptContractManifestMetadata(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    entries: [normalSnapshot().manifestEntry])
                let root = mainFolder
                try await store.applyFolderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    folders: [.init(folderID: root, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date()),
                              .init(folderID: NormalEditorPlan.parent, parentFolderID: root, name: "원고", revision: 1, isDeleted: false, updatedAt: Date())], excluding: [])
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    treeOrders: [.init(treeOrderID: UUID(uuidString: "31eb06be-9cc9-55db-9a05-5882172474ce")!, parentFolderID: NormalEditorPlan.parent,
                        children: [NormalEditorPlan.document], revision: 2, updatedAt: Date())])
                return store
            }
        }
        let wire = NormalWireStub(structure: try await raw.normalEditorStructure(), user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let key = ContractPathGate.storageKey(for: NormalEditorPlan.local)
        let prior = UserDefaults.standard.object(forKey: key)
        ContractPathGate.setOpen(true, for: NormalEditorPlan.local)
        defer { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let lazy = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity)
        let repository = NormalTestRepository()
        await repository.addFolders(root: mainFolder)
        let backend = LiveNormalEditorBackend(store: lazy, documents: repository, local: f.local,
            applier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: f.file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())),
            mutationGate: SyncV2DocumentMutationGate(), auth: NormalTestAuth(user: user),
            configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public-key"),
            journal: f.journal, bindingEpoch: SyncV2ContractEpoch(), projectEpoch: SyncV2ContractEpoch())
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            try await backend.prepare()
            let remote = try await backend.remote(); XCTAssertEqual(remote.revision, 6)
            f.model.editor.updateText("새 자유 원고 e\u{301}🙂\n"); await f.model.save()
            let source = try XCTUnwrap(f.journal.state().saves.last?.source)
            let request = try await backend.freeze(source)
            try NormalEditorPlan.validate(request, source: source)
            try f.journal.update("testFreeze") {
                $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen
            }
            await wire.loseNextResponse()
            do { _ = try await backend.transmit(request, willStart: {
                try f.journal.update("testHTTPStarted") { $0.saves[0].phase = .httpStarted }
            }); XCTFail("lost response") } catch {}
            await backend.invalidate(); try await backend.prepare()
            let recovered = try await backend.receipt(request)
            let response = try XCTUnwrap(recovered)
            try await backend.complete(request, response: response)
            try await backend.complete(request, response: response) // idempotent late local completion
            let base = try await backend.localBaseline()
            XCTAssertEqual(base.revision, 7); XCTAssertEqual(Data(base.content.utf8), Data("새 자유 원고 e\u{301}🙂\n".utf8))
            let queue = try await lazy.generalQueueStatus(localProjectID: NormalEditorPlan.local)
            XCTAssertEqual(queue.pendingCount, 0)
            let stored = try await lazy.normalEditorPending(batchID: request.batchID)
            XCTAssertEqual(stored?.request, request)
            let writes = await wire.writes, reads = await wire.receiptReads
            XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2)
            try f.journal.update("testComplete") { $0.saves[0].phase = .completed; $0.baseline = base }
            await wire.editRemotely("실제 수신 반영 원고 e\u{301}🙂")
            let next = try await backend.remote()
            let receive = NormalEditorJournal.Receive(id: UUID(), baseline: base, remote: next)
            try f.journal.update("testReceive") { $0.receive = receive }
            try await backend.apply(receive, willApply: {})
            let applied = try await backend.localBaseline()
            XCTAssertEqual(applied.revision, 8)
            XCTAssertEqual(try Data(contentsOf: f.file), Data(next.content.utf8))
            try await backend.apply(receive, willApply: { XCTFail("completed receive must not apply twice") })
        }
    }
    func testAuthorityIsLocalToActionAndExpiryCannotOpenGlobalSending() async throws {
        let user = UUID(), epoch = SyncV2ContractEpoch()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user))
        let ticket = try XCTUnwrap(policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        try policy.verifyAccount(user, ticket: ticket); try policy.select(NormalEditorPlan.server)
        let initial = epoch.value
        let authority = NormalEditorAuthority(policy: policy, ticket: ticket, bearer: "Bearer test") {
            guard epoch.value == initial else { throw NormalEditorError.locked }
        }
        try authority.bind()
        XCTAssertFalse(policy.sendingAllowed)
        XCTAssertThrowsError(try policy.requireSending())
        try await authority.mutate(sending: true) { try policy.requireSending() }
        XCTAssertThrowsError(try policy.requireSending())
        epoch.advance()
        do { try await authority.mutate(sending: true) { try policy.requireSending() }; XCTFail("expired") } catch {}
        XCTAssertFalse(policy.sendingAllowed)
    }
}

extension NormalEditorTests {
    func testSelfHashedArbitraryRPCAndUnscopedReceiptAreDenied() async throws {
        let f = try await fixture(), user = UUID()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user))
        let ticket = try XCTUnwrap(policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        try policy.verifyAccount(user, ticket: ticket); try policy.select(NormalEditorPlan.server)
        let authority = NormalEditorAuthority(policy: policy, ticket: ticket, bearer: "Bearer test", journal: f.journal, check: {})
        try authority.bind()
        for path in ["rpc/document_commit", "rpc/atomic_structure_commit", "sync_batch_results?select=*&batch_id=eq.fake&limit=2"] {
            var request = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/" + path)!)
            request.httpMethod = path.hasPrefix("rpc/") ? "POST" : "GET"
            request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
            request.setValue("count=exact", forHTTPHeaderField: "Prefer")
            let frozen = request
            try await authority.context {
                try NormalEditorAuthority.$wireHash.withValue(GeneralSyncValidationScope.fingerprint(frozen)) {
                    XCTAssertThrowsError(try policy.authorize(frozen, ticket: ticket))
                }
            }
        }
    }
    func testFreezingMarkerProtectsOperationBeforeRequestPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root), first = normalBatch("고정 중 원고")
        try journal.record(first)
        try journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        let reopened = try NormalEditorJournal(root: root)
        try reopened.record(normalBatch("후속 편집"))
        XCTAssertEqual(reopened.state().head, 0)
        XCTAssertEqual(reopened.state().saves[0].source, first)
        XCTAssertEqual(reopened.state().saves[0].phase, .freezing)
    }
}

extension NormalEditorTests {
    func testUnpublishedTornRecordDoesNotHideDurableDraftOrQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        let batch = normalBatch("저장 본문")
        try journal.record(batch); try journal.saveDraft(text: "최신 초안", cursor: .start)
        let interrupted = root.appendingPathComponent(UUID().uuidString + ".tmp")
        try Data("incomplete unpublished bytes".utf8).write(to: interrupted)
        let reopened = try NormalEditorJournal(root: root)
        XCTAssertEqual(reopened.state().saves.first?.source, batch)
        XCTAssertEqual(try reopened.draft()?.text, "최신 초안")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
    }
}


extension NormalEditorTests {
    func testRecoveryDiagnosticBoundariesSurviveSessionReconstruction() async throws {
        let f = try await fixture()
        let url = f.root.appendingPathComponent("sync.sqlite")
        let user = UUID(), identity = NormalTestIdentity(), mainFolder = UUID()
        let unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let scope = GeneralSyncValidationScope(restricted: false, selection: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                guard case let .available(store) = await SyncV2Store.open(at: url) else { throw NormalEditorError.storage }
                try await store.save(ProjectSyncBinding.connected(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    kind: .existingServerProject, projectName: "합성", ownerSubject: user))
                _ = try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    snapshot: normalSnapshot(), expectedRevision: nil)
                try await store.adoptContractManifestMetadata(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    entries: [normalSnapshot().manifestEntry])
                let root = mainFolder
                try await store.applyFolderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    folders: [.init(folderID: root, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date()),
                              .init(folderID: NormalEditorPlan.parent, parentFolderID: root, name: "원고", revision: 1, isDeleted: false, updatedAt: Date())], excluding: [])
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    treeOrders: [.init(treeOrderID: UUID(uuidString: "31eb06be-9cc9-55db-9a05-5882172474ce")!, parentFolderID: NormalEditorPlan.parent,
                        children: [NormalEditorPlan.document], revision: 2, updatedAt: Date())])
                return store
            }
        }
        let wire = NormalWireStub(structure: try await raw.normalEditorStructure(), user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let key = ContractPathGate.storageKey(for: NormalEditorPlan.local)
        let prior = UserDefaults.standard.object(forKey: key)
        ContractPathGate.setOpen(true, for: NormalEditorPlan.local)
        defer { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let lazy = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity)
        let repository = NormalTestRepository()
        await repository.addFolders(root: mainFolder)

        func reopen() async throws -> NormalEditorSession {
            let journal = try NormalEditorJournal(root: f.journal.root)
            let workspace = f.root.appendingPathComponent("workspace")
            let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace),
                metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
            let local = NormalEditorDocumentStore(local: product, journal: journal)
            let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
                workspaceStateRepository: NormalTestWorkspace(),
                preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: .seconds(3600))
            let backend = LiveNormalEditorBackend(
                store: LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity),
                documents: repository, local: local,
                applier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: workspace)),
                mutationGate: SyncV2DocumentMutationGate(), auth: NormalTestAuth(user: user),
                configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public-key"),
                journal: journal, bindingEpoch: SyncV2ContractEpoch(), projectEpoch: SyncV2ContractEpoch())
            let model = NormalEditorSession(editor: editor, journal: journal, backend: backend, documents: repository)
            await model.open()
            XCTAssertTrue(model.opened, model.message)
            XCTAssertFalse(model.prepared)
            return model
        }
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            var model = try await reopen()
            let text = "복구 경계 원고 e\u{301}🙂\n", nextText = "부분 수신 원고 e\u{301}🙂\n"
            model.editor.updateText(text); await model.save()
            let source = try XCTUnwrap(model.journal.state().saves.last?.source)
            await model.setForeground(false)
            model = try await reopen()
            XCTAssertEqual(model.editor.currentText, text)
            XCTAssertEqual(model.journal.state().saves.last?.source, source)
            await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .beforeHTTP, contentHash: NormalEditorPlan.hash(text))) {
                await model.send()
            }
            let frozen = try XCTUnwrap(model.journal.state().saves.last?.requestHash)
            XCTAssertEqual(model.journal.state().saves.last?.phase, .frozen, model.message)
            XCTAssertEqual(model.journal.state().saves.last?.attempts.count, 0)
            var writes = await wire.writes; XCTAssertEqual(writes, 0)
            model = try await reopen(); await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterCommitResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.send()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .httpStarted, model.message)
            XCTAssertNil(model.journal.state().saves.last?.response)
            XCTAssertEqual(model.journal.state().saves.last?.attempts.count, 1)
            XCTAssertEqual(model.journal.state().saves.last?.requestHash, frozen)
            writes = await wire.writes; XCTAssertEqual(writes, 1)
            model = try await reopen(); await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.recoverResult()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .responseStored, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 6)
            var reads = await wire.receiptReads; XCTAssertEqual(reads, 2)
            model = try await reopen(); await model.prepare()
            // Same arm is consumed durably; restarting cannot inject it again.
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.recoverResult()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .completed, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 7)
            XCTAssertEqual(model.journal.state().saves.last?.source, source)
            reads = await wire.receiptReads; XCTAssertEqual(reads, 2)
            let completion = model.journal.state().message
            await model.setForeground(false)
            model = try await reopen()
            XCTAssertEqual(model.message, completion)
            await model.prepare()
            XCTAssertEqual(model.journal.state().saves.last?.phase, .completed)
            await wire.editRemotely(nextText)
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterOriginalApply, contentHash: NormalEditorPlan.hash(nextText))) {
                await model.receive()
            }
            XCTAssertEqual(model.journal.state().receive?.phase, "originalApplyStarted", model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 7)
            XCTAssertEqual(try Data(contentsOf: f.file), Data(nextText.utf8))
            let beforeResumeReads = await wire.metadataReads
            model = try await reopen(); await model.prepare()
            await model.receive()
            let afterResumeReads = await wire.metadataReads
            XCTAssertEqual(afterResumeReads, beforeResumeReads)
            XCTAssertNil(model.journal.state().receive, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 8)
            XCTAssertEqual(model.journal.state().recoveryCheckpoints?.count, 4)
            XCTAssertEqual(try model.journal.draft()?.text, nextText)
            XCTAssertEqual(model.editor.currentText, nextText)
            writes = await wire.writes; reads = await wire.receiptReads
            XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2)
            let queue = try await lazy.generalQueueStatus(localProjectID: NormalEditorPlan.local)
            XCTAssertEqual(queue.pendingCount, 0)
            // Exercise every run-scoped boundary with the real backend/SQLite and a wire stub.
            // Each run gets a new synthetic save only after the previous one completes.
            for point: NormalEditorRecoveryInjection.Point in [.beforeHTTP, .afterCommitResponse, .afterStoredResponse] {
                let base = try XCTUnwrap(model.journal.state().baseline)
                let content = "실행 격리 \(point.rawValue) e\u{301}🙂\n"
                let configuration = runConfiguration(content, point: point, revision: base.revision, baseline: base.content)
                model.editor.updateText(content); await model.save()
                let beforeWrites = await wire.writes, beforeReceipts = await wire.receiptReads
                await NormalEditorRecoveryInjection.$testConfiguration.withValue(configuration) {
                    await model.prepare(); await model.send()
                }
                let interrupted = try XCTUnwrap(model.journal.state().saves.last)
                XCTAssertEqual(interrupted.phase, point == .beforeHTTP ? .frozen : point == .afterCommitResponse ? .httpStarted : .responseStored, model.message)
                XCTAssertTrue(model.journal.state().recoveryCheckpoints?.contains(NormalEditorRecoveryInjection.checkpointKey(configuration)) == true)
                model = try await reopen(); await model.prepare()
                if point == .beforeHTTP { await model.send() } else { await model.recoverResult() }
                XCTAssertEqual(model.journal.state().saves.last?.phase, .completed, model.message)
                XCTAssertEqual(model.journal.state().saves.last?.source, interrupted.source)
                XCTAssertEqual(model.journal.state().saves.last?.requestHash, interrupted.requestHash)
                XCTAssertEqual(model.journal.state().recoveryRuns?.last?.completed, true)
                let afterWrites = await wire.writes, afterReceipts = await wire.receiptReads
                XCTAssertEqual(afterWrites - beforeWrites, 1)
                XCTAssertEqual(afterReceipts - beforeReceipts, point == .afterCommitResponse ? 2 : 0)
            }
            let runBase = try XCTUnwrap(model.journal.state().baseline), incoming = "실행별 수신 복구\n"
            await wire.editRemotely(incoming)
            let receiveConfiguration = runConfiguration(incoming, point: .afterOriginalApply,
                revision: runBase.revision, baseline: runBase.content)
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(receiveConfiguration) {
                await model.prepare(); await model.receive()
            }
            let receiveID = try XCTUnwrap(model.journal.state().receive?.id)
            XCTAssertTrue(model.journal.state().recoveryCheckpoints?.contains(NormalEditorRecoveryInjection.checkpointKey(receiveConfiguration)) == true)
            let runReads = await wire.metadataReads, runWrites = await wire.writes
            model = try await reopen()
            XCTAssertEqual(model.journal.state().receive?.id, receiveID)
            await model.prepare(); await model.receive()
            XCTAssertNil(model.journal.state().receive, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, runBase.revision + 1)
            XCTAssertEqual(try model.journal.draft()?.text, incoming)
            XCTAssertEqual(model.journal.state().recoveryRuns?.count, 4)
            XCTAssertTrue(model.journal.state().recoveryRuns?.allSatisfy(\.completed) == true)
            XCTAssertEqual(model.journal.state().recoveryCheckpoints?.count, 8) // Four legacy + four run-scoped keys.
            let finalReads = await wire.metadataReads, finalWrites = await wire.writes
            XCTAssertEqual(finalReads, runReads); XCTAssertEqual(finalWrites, runWrites)
        }
    }
    func testRecoveryDiagnosticConfigurationFailsClosed() throws {
        XCTAssertNil(try NormalEditorRecoveryInjection.parse([:]))
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(["WRITERPAD_RECOVERY_POINT": "beforeHTTP"]))
        let valid = ["WRITERPAD_RECOVERY_PLAN": NormalEditorRecoveryInjection.plan,
                     "WRITERPAD_RECOVERY_POINT": "beforeHTTP",
                     "WRITERPAD_RECOVERY_CONTENT_SHA256": String(repeating: "a", count: 64)]
        XCTAssertEqual(try NormalEditorRecoveryInjection.parse(valid)?.point, .beforeHTTP)
        for (key, value) in [("WRITERPAD_RECOVERY_PLAN", "old-plan"), ("WRITERPAD_RECOVERY_POINT", "arbitrary"),
                             ("WRITERPAD_RECOVERY_CONTENT_SHA256", "not-a-hash")] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid))
        }
    }
    func testRecoveryDiagnosticMismatchDoesNotConsumeOrAlterRequest() async throws {
        let f = try await fixture()
        f.model.editor.updateText("보존 원고\n"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let source = f.journal.state().saves[0]
        try NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .beforeHTTP, contentHash: String(repeating: "0", count: 64))) {
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.hit(.beforeHTTP, journal: f.journal)) { error in
                XCTAssertEqual(error as? NormalEditorError, .recoveryConfiguration)
            }
        }
        XCTAssertNil(f.journal.state().recoveryCheckpoints)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, source.requestHash)
        XCTAssertEqual(f.journal.state().saves[0].source, source.source)
        XCTAssertEqual(f.journal.state().saves[0].phase, .frozen)
    }
}


extension NormalEditorTests {
    func testRecoveryReopenRestoresDraftWithoutReplacingQueuedSource() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장 원고\n"); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        f.model.editor.updateText("아직 저장하지 않은 초안 e\u{301}🙂\n")
        let journal = try NormalEditorJournal(root: f.journal.root)
        let repository = NormalTestRepository()
        let editor = EditorSessionModel(documentRepository: repository, documentStore: f.local,
            workspaceStateRepository: NormalTestWorkspace(),
            preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: .seconds(3600))
        let model = NormalEditorSession(editor: editor, journal: journal, backend: f.backend, documents: repository)
        await model.open()
        XCTAssertTrue(model.opened, model.message); XCTAssertFalse(model.prepared)
        XCTAssertEqual(Data(model.editor.currentText.utf8), Data("아직 저장하지 않은 초안 e\u{301}🙂\n".utf8))
        XCTAssertEqual(try Data(contentsOf: f.file), Data("저장 원고\n".utf8))
        XCTAssertEqual(journal.state().saves.last?.source, source)
        let writes = await f.backend.requests, reads = await f.backend.reads
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(reads, 0)
    }
    func testRecoveryDiagnosticUnarmedBoundariesDoNotWriteJournal() async throws {
        let f = try await fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
        for point: NormalEditorRecoveryInjection.Point in [.beforeHTTP, .afterCommitResponse, .afterStoredResponse, .afterOriginalApply] {
            try NormalEditorRecoveryInjection.hit(point, journal: f.journal)
        }
        XCTAssertNil(f.journal.state().recoveryCheckpoints)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), before)
    }
}
