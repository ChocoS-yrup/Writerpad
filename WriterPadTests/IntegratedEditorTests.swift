import Foundation
import XCTest
import UIKit
import SwiftUI
@testable import WriterPad

private struct IntegratedTestIdentity: DeviceIdentityProviding {
    let id = DeviceIdentifier(uuid: UUID())
    func currentState() async -> DeviceIdentityState { .ready(id) }
    func currentIdentifier() async throws -> DeviceIdentifier { id }
    func prepareIdentity() async {}
}
private struct IntegratedTestAuth: AuthenticationServicing {
    let user: UUID
    let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    func currentState() async -> AuthenticationState { .authenticated(.init(userID: user, maskedEmail: nil)) }
    func generalValidationBearer() async throws -> String { "Bearer isolated-test-token" }
    func restoreSession() async -> AuthenticationState { await currentState() }
    func refreshSession(force: Bool) async -> AuthenticationState { await currentState() }
    func signIn(email: String, password: String) async -> AuthenticationState { await currentState() }
    func signOut() async -> AuthenticationState { .signedOut(.userInitiated) }
}

private let integratedProtected = "일반 본문 검증 20260912\n이 문서는 일반 동기화 시험용 합성 원고입니다.\n끝.\niPad 일반 검증 20260912\nWindows 일반 검증 20260912\nWindows 일반 편집 검증 20260913\niPad 일반 편집 검증 20260913\nWindows 자동저장 검증 20260913\nWindows 일반 화면 수동 저장 20260913\niPad 일반 화면 저장 20260913\nWindows 일반 화면 자동저장 20260913\n"

actor IntegratedWireStub {
    var snapshot: IntegratedRemoteSnapshot
    let user: UUID
    var receipts: [UUID: SyncV2GeneralCommitReceipt] = [:]
    var writes = 0
    var calls = 0
    var reads = 0
    var receiptReads = 0
    var missingReceipt = false
    var lose = false
    var rejectNext = false
    var receiptFault: String?
    func setReceiptFault(_ fault: String?) { receiptFault = fault }
    init(snapshot: IntegratedRemoteSnapshot, user: UUID) { self.snapshot = snapshot; self.user = user }
    func configure(lost: Bool = false, missing: Bool = false) { lose = lost; missingReceipt = missing }
    func rejectNextCommit() { rejectNext = true }
    func corruptReceipts() {
        for (id, receipt) in receipts {
            var batch = receipt.batch.objectValue!
            batch["writer_user_id"] = .string(UUID().uuidString.lowercased())
            receipts[id] = .init(batch: .object(batch), result: receipt.result)
        }
    }
    func addRemoteDocument(parent: UUID, name: String, content: String) -> UUID {
        let id = UUID()
        snapshot = .init(documents: snapshot.documents + [.init(documentID: id,
            relativePath: IntegratedEditorPlan.rootPath + "/" + name, content: content, revision: 1,
            isDeleted: false, deletedAt: nil, updatedAt: Date(), parentFolderID: parent, name: name, structureRevision: 1)],
            folders: snapshot.folders, orders: snapshot.orders.map {
                guard $0.parentFolderID == parent else { return $0 }
                return .init(treeOrderID: $0.treeOrderID, parentFolderID: parent, children: $0.children + [id], revision: $0.revision + 1, updatedAt: Date())
            })
        return id
    }
    func edit(_ id: UUID, text: String) {
        snapshot = .init(documents: snapshot.documents.map {
            guard $0.documentID == id else { return $0 }
            return .init(documentID: id, relativePath: $0.relativePath, content: text, revision: $0.revision + 1,
                isDeleted: false, deletedAt: nil, updatedAt: Date(), parentFolderID: $0.parentFolderID, name: $0.name, structureRevision: $0.structureRevision)
        }, folders: snapshot.folders, orders: snapshot.orders)
    }
    func exchange(_ request: URLRequest) throws -> (Data, URLResponse) {
        calls += 1
        let path = request.url!.lastPathComponent
        var result: SyncV2JSON
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        func json<T: Encodable>(_ value: T) throws -> SyncV2JSON { try JSONDecoder().decode(SyncV2JSON.self, from: encoder.encode(value)) }
        switch path {
        case "get_sync_handshake":
            result = .object(["supported": .bool(true), "project_id": .string(IntegratedEditorPlan.server.uuidString.lowercased()),
                "project_sync_mode": .string("ID_BASED"), "migration_epoch": .int(1), "contract_version": .string(SyncV2Contract.version),
                "canonical_contract_sha256": .string(SyncV2Contract.canonicalSHA256), "server_contract_sha256": .string(SyncV2Contract.canonicalSHA256),
                "server_protocol_version": .int(SyncV2Contract.syncProtocolVersion), "supported_protocol_versions": .array([.int(SyncV2Contract.syncProtocolVersion)]),
                "server_capabilities": .array(SyncV2Contract.requiredServerCapabilities.sorted().map(SyncV2JSON.string))])
        case "get_project_status": result = .object(["project_id": .string(IntegratedEditorPlan.server.uuidString.lowercased()), "state": .string("active")])
        case "documents": reads += 1; result = try json(snapshot.documents)
        case "folders": reads += 1; result = try json(snapshot.folders)
        case "tree_orders": reads += 1; result = try json(snapshot.orders)
        case "document_commit", "atomic_structure_commit":
            let envelope = try JSONDecoder().decode(SyncV2JSON.self, from: request.httpBody!)
            let contract = try SyncV2ContractRequest(storedJSON: envelope.objectValue!["p_request"]!)
            let pending = SyncV2PendingContractBatch(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: contract)
            if rejectNext {
                rejectNext = false; writes += 1
                edit(UUID(uuidString: contract.orderedIntents[0].objectValue!["document_id"]!.stringValue!)!, text: "요청 직전 서버 수정\n")
                let failure: SyncV2JSON = .object(["kind": .string("document_commit_failure"), "batch_id": .string(contract.batchID.uuidString.lowercased()),
                    "batch_payload_sha256": .string(contract.batchPayloadSHA256), "status": .string("rejected"), "applied": .bool(false), "results": .array([]),
                    "error": .object(["code": .string("REVISION_CONFLICT"), "message": .string("test conflict"), "failed_sequence": .int(1)])])
                return (try encoder.encode(failure), HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
            }
            result = makeGeneralCommitResponseForTesting(pending)
            receipts[contract.batchID] = try makeGeneralCommitReceiptForTesting(pending, accountID: user, response: result)
            var docs = snapshot.documents, folders = snapshot.folders, orders = snapshot.orders
            var changedDocuments: Set<UUID> = []
            for value in contract.orderedIntents {
                let row = value.objectValue!, payload = row["payload"]!.objectValue!
                let id = UUID(uuidString: (row["document_id"] ?? row["entity_id"])!.stringValue!)!
                let revision = Int64(row["base_revision"]!.intValue! + 1)
                let parent = payload["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:))
                let name = payload["name"]?.stringValue ?? ""
                let deleted = payload["is_deleted"] == .bool(true) || row["intent_kind"] == .string("delete")
                switch row["entity_kind"]!.stringValue! {
                case "document":
                    if path == "atomic_structure_commit" || row["intent_kind"] == .string("create") { changedDocuments.insert(id) }
                    let old = docs.first { $0.documentID == id }
                    let next = SyncV2RemoteDocumentSnapshot(documentID: id, relativePath: old?.relativePath ?? "",
                        content: payload["content"]?.stringValue ?? old?.content ?? "", revision: path == "document_commit" ? revision : old?.revision ?? 1,
                        isDeleted: deleted, deletedAt: deleted ? Date() : nil, updatedAt: Date(),
                        parentFolderID: payload.keys.contains("parent_folder_id") ? parent : old?.parentFolderID,
                        name: payload["name"]?.stringValue ?? old?.name, structureRevision: path == "document_commit" ? Int64(payload["structure_revision"]!.intValue!) : revision)
                    docs.removeAll { $0.documentID == id }; docs.append(next)
                case "folder":
                    folders.removeAll { $0.folderID == id }; folders.append(.init(folderID: id, parentFolderID: parent, name: name, revision: revision, isDeleted: deleted, updatedAt: Date()))
                case "tree_order":
                    orders.removeAll { $0.treeOrderID == id }; orders.append(.init(treeOrderID: id, parentFolderID: parent,
                        children: payload["children"]!.arrayValue!.map { UUID(uuidString: $0.stringValue!)! }, revision: revision, updatedAt: Date()))
                default: throw IntegratedEditorError.scope
                }
            }
            func folderPath(_ id: UUID?, seen: Set<UUID> = []) throws -> String {
                guard let id else { return "" }; guard !seen.contains(id), let folder = folders.first(where: { $0.folderID == id }) else { throw IntegratedEditorError.scope }
                let prefix = try folderPath(folder.parentFolderID, seen: seen.union([id])); return prefix.isEmpty ? folder.name : prefix + "/" + folder.name
            }
            docs = try docs.map { doc in
                guard changedDocuments.contains(doc.documentID) else { return doc }
                let prefix = try folderPath(doc.parentFolderID)
                return .init(documentID: doc.documentID, relativePath: prefix + "/" + (doc.name ?? ""), content: doc.content,
                    revision: doc.revision, isDeleted: doc.isDeleted, deletedAt: doc.deletedAt, updatedAt: doc.updatedAt,
                    parentFolderID: doc.parentFolderID, name: doc.name, structureRevision: doc.structureRevision)
            }
            snapshot = .init(documents: docs, folders: folders, orders: orders); writes += 1
            if lose { lose = false; throw URLError(.networkConnectionLost) }
        case "sync_batches", "sync_batch_results":
            receiptReads += 1
            if path == "sync_batch_results", let fault = receiptFault {
                if fault == "transport" { throw URLError(.timedOut) }
                let data = Data((fault == "decode" ? "not-json-secret" : "[]").utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: fault == "http" ? 403 : 200,
                    httpVersion: nil, headerFields: ["Content-Range": fault == "count" ? "*/1" : "*/0", "Authorization": "secret-header"])!)
            }
            let batch = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "batch_id" }!.value!.dropFirst(3)
            let receipt = receipts[UUID(uuidString: String(batch))!]
            result = .array(missingReceipt ? [] : receipt.map { [path == "sync_batches" ? $0.batch : $0.result] } ?? [])
        default: throw IntegratedEditorError.scope
        }
        let count = result.arrayValue?.count ?? 1
        return (try encoder.encode(result), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Range": count == 0 ? "*/0" : "0-\(count - 1)/\(count)"])!)
    }
}

@MainActor
final class IntegratedEditorTests: XCTestCase {
    struct Fixture {
        let root: URL
        let journal: IntegratedEditorJournal
        let backend: IntegratedEditorBackend
        let session: IntegratedEditorSession
        let commands: LocalBinderCommandService
        let repository: SwiftDataMetadataRepository
        let local: IntegratedEditorDocumentStore
        let store: LazySyncV2ProjectBindingStore
        let wire: IntegratedWireStub
        let policy: ReceiveValidationPolicy
        let folder: UUID
        let first: UUID
        let second: UUID
    }
    func fixture(checkpoint: String? = nil, maximum: Int = 500, automaticPolicy: IntegratedAutomaticPolicy? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IntegratedTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), main = UUID(), folder = UUID(), first = UUID(), second = UUID(), trash = UUID()
        let protected = SyncV2RemoteDocumentSnapshot(documentID: IntegratedEditorPlan.protectedDocument,
            relativePath: NormalEditorPlan.path, content: integratedProtected, revision: 9, isDeleted: false, deletedAt: nil,
            updatedAt: Date(), parentFolderID: NormalEditorPlan.parent, name: GeneralValidationPlan.name, structureRevision: 1)
        let documents = [protected] + [(first, "첫째.txt"), (second, "둘째.txt")].map { id, name in
            SyncV2RemoteDocumentSnapshot(documentID: id, relativePath: IntegratedEditorPlan.rootPath + "/" + name,
                content: "초기\n", revision: 1, isDeleted: false, deletedAt: nil, updatedAt: Date(), parentFolderID: folder, name: name, structureRevision: 1)
        }
        let folders: [SyncV2RemoteFolder] = [
            .init(folderID: main, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date()),
            .init(folderID: trash, parentFolderID: main, name: "휴지통", revision: 1, isDeleted: false, updatedAt: Date()),
            .init(folderID: NormalEditorPlan.parent, parentFolderID: main, name: "원고", revision: 1, isDeleted: false, updatedAt: Date()),
            .init(folderID: IntegratedEditorPlan.parent, parentFolderID: main, name: "메모장", revision: 1, isDeleted: false, updatedAt: Date()),
            .init(folderID: folder, parentFolderID: IntegratedEditorPlan.parent, name: IntegratedEditorPlan.rootName, revision: 1, isDeleted: false, updatedAt: Date())]
        let snapshot = IntegratedRemoteSnapshot(documents: documents, folders: folders, orders: [
            .init(treeOrderID: UUID(), parentFolderID: nil, children: [main], revision: 1, updatedAt: Date()),
            .init(treeOrderID: UUID(), parentFolderID: main, children: [NormalEditorPlan.parent, IntegratedEditorPlan.parent, trash], revision: 1, updatedAt: Date()),
            .init(treeOrderID: UUID(), parentFolderID: NormalEditorPlan.parent, children: [IntegratedEditorPlan.protectedDocument], revision: 2, updatedAt: Date()),
            .init(treeOrderID: UUID(), parentFolderID: IntegratedEditorPlan.parent, children: [folder], revision: 3, updatedAt: Date()),
            .init(treeOrderID: UUID(), parentFolderID: folder, children: [first, second], revision: 1, updatedAt: Date())])
        let unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(.init(restricted: false, selection: nil)) {
                guard case let .available(store) = await SyncV2Store.open(at: root.appendingPathComponent("sync.sqlite")) else { throw IntegratedEditorError.corrupt }
                try await store.save(.connected(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, kind: .existingServerProject, projectName: "시험", ownerSubject: user))
                for doc in documents { _ = try await store.applySnapshotBaseline(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, snapshot: doc, expectedRevision: nil) }
                try await store.adoptContractManifestMetadata(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, entries: documents.map(\.manifestEntry))
                try await store.applyFolderSnapshotBaselines(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, folders: folders, excluding: [])
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, treeOrders: snapshot.orders)
                return store
            }
        }
        let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true))
        try await repository.save(Project(id: IntegratedEditorPlan.local, name: "시험", createdAt: Date(), modifiedAt: Date()))
        let folderPaths = [trash: "메인/휴지통", main: "메인", NormalEditorPlan.parent: "메인/원고", IntegratedEditorPlan.parent: "메인/메모장", folder: IntegratedEditorPlan.rootPath]
        for item in folders {
            let path = folderPaths[item.folderID]!
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            try await repository.save(DocumentNode(id: .init(rawValue: item.folderID), projectID: IntegratedEditorPlan.local, kind: .folder,
                parentID: item.parentFolderID.map { .init(rawValue: $0) }, relativePath: .init(rawValue: path),
                userOrder: item.folderID == trash ? 100 : item.folderID == IntegratedEditorPlan.parent ? 3 : 0,
                modifiedAt: Date(), contentHash: nil))
        }
        for (index, doc) in documents.enumerated() {
            try Data(doc.content.utf8).write(to: root.appendingPathComponent(doc.relativePath))
            try await repository.save(DocumentNode(id: .init(rawValue: doc.documentID), projectID: IntegratedEditorPlan.local, kind: .text,
                parentID: doc.parentFolderID.map { .init(rawValue: $0) }, relativePath: .init(rawValue: doc.relativePath), userOrder: index, modifiedAt: Date(),
                contentHash: .init(rawValue: IntegratedEditorPlan.hash(doc.content))))
        }
        let journal = try IntegratedEditorJournal(root: root.appendingPathComponent("journal"))
        try journal.configure(.init(id: UUID(), accountID: user, expiresAt: Date().addingTimeInterval(3600), maximumRequests: maximum,
            maximumWrites: maximum, maximumAuthentication: 4, pollingSeconds: 300, automatic: false, checkpoint: checkpoint, automatic_policy: automaticPolicy))
        try journal.update("testMembers") { $0.members = [folder, first, second] }
        let wakeup = IntegratedEditorWakeup(), gate = SyncV2DocumentMutationGate()
        let recorder = IntegratedEditorRecorder(journal: journal, wakeup: wakeup)
        let locator = FixedWorkspaceLocator(root: root)
        let local = IntegratedEditorDocumentStore(local: LocalDocumentStore(workspaceLocator: locator, metadataUpdater: repository, durableChangeRecorder: recorder, syncMutationGate: gate), journal: journal)
        let commands = LocalBinderCommandService(metadataStore: repository, workspaceStateRepository: repository, workspaceLocator: locator,
            durableChangeRecorder: recorder, syncMutationGate: gate, recoverProjectAliases: false)
        let store = LazySyncV2ProjectBindingStore(databaseURL: root.appendingPathComponent("sync.sqlite"), deviceIdentityProvider: IntegratedTestIdentity())
        let wire = IntegratedWireStub(snapshot: snapshot, user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let backend = IntegratedEditorBackend(store: store, journal: journal, auth: IntegratedTestAuth(user: user),
            configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public"), bindingEpoch: .init(), projectEpoch: .init(), makePuller: { snapshot in
                SyncV2SnapshotPullService(client: snapshot, stateStore: raw,
                    localApplier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: locator),
                    mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
                    folderApplier: SyncV2RemoteFolderApplier(documentRepository: repository, workspaceLocator: locator), folderDocuments: repository, mutationGate: gate)
            })
        let session = IntegratedEditorSession(journal: journal, backend: backend, documents: repository, local: local, workspace: repository, commands: commands, wakeup: wakeup)
        let key = ContractPathGate.storageKey(for: IntegratedEditorPlan.local), prior = UserDefaults.standard.object(forKey: key)
        ContractPathGate.setOpen(true, for: IntegratedEditorPlan.local)
        addTeardownBlock { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        await session.open(); XCTAssertTrue(session.opened, session.message)
        return .init(root: root, journal: journal, backend: backend, session: session, commands: commands, repository: repository, local: local, store: store, wire: wire, policy: policy, folder: folder, first: first, second: second)
    }
    func save(_ f: Fixture, id: UUID, text: String) async throws {
        await f.session.select(.init(rawValue: id))
        let editor = try XCTUnwrap(f.session.editor)
        editor.updateText(text); await f.session.save()
        XCTAssertFalse(editor.hasUnsavedChanges, f.session.message)
    }
    func cycle(_ f: Fixture) async throws {
        try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.prepare(); try await f.backend.synchronize() }
    }
    func testMultiDocumentSavesLostReceiptAndLaterSaveKeepOrder() async throws {
        let f = try await fixture()
        try await save(f, id: f.first, text: "NFD e\u{301} 한글🙂\n")
        try await save(f, id: f.second, text: "둘째 끝 공백  ")
        await f.wire.configure(lost: true)
        do { try await cycle(f); XCTFail("response lost") } catch {}
        XCTAssertEqual(f.journal.state().wires.first?.phase, .httpStarted)
        try await save(f, id: f.first, text: "나중 저장\n\n")
        let used = f.journal.state().usedRequests
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().usedRequests, used)
        await f.wire.configure(missing: true)
        do { try await cycle(f); XCTFail("missing receipt") } catch {}
        var writes = await f.wire.writes; XCTAssertEqual(writes, 1)
        await f.wire.configure(); try await cycle(f)
        writes = await f.wire.writes; XCTAssertEqual(writes, 3)
        XCTAssertNil(f.journal.state().activeWire)
        let queue = try await f.store.generalQueueStatus(localProjectID: IntegratedEditorPlan.local); XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(NormalEditorPlan.path)), Data(integratedProtected.utf8))
        let base = try await f.store.integratedBaseContents(); XCTAssertEqual(base[f.first], "나중 저장\n\n"); XCTAssertEqual(base[f.second], "둘째 끝 공백  ")
    }
    func testFourDurableStopsAndPartialOriginalApplyResume() async throws {
        let f = try await fixture(checkpoint: "all")
        try await save(f, id: f.first, text: "한 번만 송신\n")
        for phase in [IntegratedEditorJournal.Phase.frozen, .httpStarted, .responseStored] {
            do { try await cycle(f); XCTFail("planned stop") } catch { XCTAssertEqual(error as? IntegratedEditorError, .checkpoint) }
            XCTAssertEqual(f.journal.state().wires.first?.phase, phase)
            _ = try IntegratedEditorJournal(root: f.journal.root)
        }
        try await cycle(f)
        await f.wire.edit(f.second, text: "외부 변경 e\u{301}🙂\n")
        do { try await cycle(f); XCTFail("partial apply") } catch { XCTAssertEqual(error as? IntegratedEditorError, .checkpoint) }
        XCTAssertNotNil(f.journal.state().receive)
        let reads = await f.wire.reads
        let path = f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/둘째.txt")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "외부 변경 e\u{301}🙂\n")
        let before = try await f.store.integratedBaseContents(); XCTAssertEqual(before[f.second], "초기\n")
        try await cycle(f)
        let afterReads = await f.wire.reads; XCTAssertEqual(afterReads, reads)
        let after = try await f.store.integratedBaseContents(); XCTAssertEqual(after[f.second], "외부 변경 e\u{301}🙂\n")
        XCTAssertNil(f.journal.state().receive); XCTAssertEqual(f.journal.state().checkpoints.count, 4)
        let writes = await f.wire.writes; XCTAssertEqual(writes, 1)
    }
    func testLocalCreateRenameMoveReorderTrashRestorePreserveIDsAndSources() async throws {
        let f = try await fixture()
        await f.session.create(kind: .folder, name: "자료", parent: .init(rawValue: f.folder))
        let folder = try XCTUnwrap(f.session.folders.first { $0.relativePath.rawValue.hasSuffix("/자료") }, f.session.message)
        await f.session.create(kind: .text, name: "새 문서", parent: folder.id)
        let doc = try XCTUnwrap(f.session.rows.first { $0.relativePath.rawValue.hasSuffix("/새 문서.txt") })
        try await save(f, id: doc.id.rawValue, text: "본문 그대로\n")
        await f.session.rename("바꾼 이름"); await f.session.move(to: .init(rawValue: f.folder)); await f.session.reorder(delta: -1)
        await f.session.trash(); XCTAssertNotEqual(f.session.selected?.deletionStatus, .active, f.session.message)
        await f.session.restore(to: folder.id); XCTAssertEqual(f.session.selected?.deletionStatus, .active, f.session.message)
        let path = try XCTUnwrap(f.session.selected?.relativePath.rawValue)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8), "본문 그대로\n")
        XCTAssertEqual(f.session.selectedID, doc.id)
        XCTAssertGreaterThanOrEqual(f.journal.state().sources.count, 8)
        XCTAssertEqual(f.journal.state().usedRequests, 0)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(NormalEditorPlan.path)), Data(integratedProtected.utf8))
        // The production general queue and transport validator must accept the entire mixed chain.
        try await cycle(f)
        XCTAssertNil(f.journal.state().activeWire)
    }
    func testBudgetAndClockRemainClosedAfterReopenAndConcurrentReservations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try IntegratedEditorJournal(root: root), now = Date()
        let run = IntegratedExecution(id: UUID(), accountID: UUID(), expiresAt: now.addingTimeInterval(30), maximumRequests: 7, maximumWrites: 3, maximumAuthentication: 2, pollingSeconds: 5, automatic: true)
        try journal.configure(run, now: now)
        await withTaskGroup(of: Void.self) { group in for _ in 0..<20 { group.addTask { try? journal.reserve(kind: "data", now: now) } } }
        let reopened = try IntegratedEditorJournal(root: root)
        XCTAssertEqual(reopened.state().usedRequests, 7)
        XCTAssertThrowsError(try reopened.reserve(kind: "auth", now: now))
        XCTAssertThrowsError(try reopened.checkTime(now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try reopened.checkTime(now.addingTimeInterval(31)))
        XCTAssertThrowsError(try reopened.configure(.init(id: UUID(), accountID: run.accountID, expiresAt: run.expiresAt, maximumRequests: 50, maximumWrites: 3, maximumAuthentication: 2, pollingSeconds: 5, automatic: true), now: now))
    }
    func testScopeRejectsProtectedSaveAndOutsideRequest() async throws {
        let f = try await fixture()
        do { _ = try await f.local.save(.init(projectID: IntegratedEditorPlan.local, documentID: .init(rawValue: IntegratedEditorPlan.protectedDocument), relativePath: .init(rawValue: NormalEditorPlan.path), text: "금지", generation: 1)); XCTFail("protected") } catch {}
        let ticket = try XCTUnwrap(f.policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        let authority = IntegratedEditorAuthority(policy: f.policy, ticket: ticket, journal: f.journal, check: {})
        authority.bind("Bearer isolated")
        for path in ["/rest/v1/documents?select=*", "/rest/v1/rpc/arbitrary", "/realtime/v1/websocket"] {
            var request = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + path)!)
            request.setValue("Bearer isolated", forHTTPHeaderField: "Authorization")
            XCTAssertThrowsError(try authority.authorize(request))
        }
        XCTAssertEqual(f.journal.state().usedRequests, 0)
    }
}

extension IntegratedEditorTests {
    func testRemoteConflictPreservesBaselineLocalRemoteWithoutWrite() async throws {
        let f = try await fixture()
        try await save(f, id: f.first, text: "로컬 수정\n")
        await f.wire.edit(f.first, text: "동시 원격 수정\n")
        do { try await cycle(f); XCTFail("conflict") } catch { XCTAssertEqual(error as? IntegratedEditorError, .conflict) }
        let conflict = try XCTUnwrap(f.journal.state().conflicts.first)
        XCTAssertEqual(conflict.baseline[f.first], "초기\n")
        XCTAssertEqual(conflict.drafts[f.first]?.text, "로컬 수정\n")
        XCTAssertEqual(conflict.remote.documents.first { $0.documentID == f.first }?.content, "동시 원격 수정\n")
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt"), encoding: .utf8), "로컬 수정\n")
        let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
    }
    func testManualAndAutomaticTriggersShareOneSerialQueueAndBudget() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 5))
        f.session.setConnected(true)
        try await save(f, id: f.first, text: "첫째 자동\n"); try await save(f, id: f.second, text: "둘째 자동\n")
        await ReceiveValidationPolicy.$override.withValue(f.policy) {
            await f.session.toggleAutomatic()
            async let first: Void = f.session.synchronize()
            async let second: Void = f.session.synchronize()
            _ = await (first, second)
            try? await Task.sleep(for: .milliseconds(700))
            if f.session.automatic { await f.session.toggleAutomatic() }
        }
        XCTAssertNil(f.journal.state().activeWire, f.session.message)
        XCTAssertEqual(f.journal.state().wires.count, 2, f.session.message)
        let writes = await f.wire.writes, calls = await f.wire.calls
        XCTAssertEqual(writes, 2); XCTAssertEqual(calls, f.journal.state().usedRequests)
        XCTAssertEqual(calls, 25) // 2 preparation + 2 * (9 metadata reads + 1 write) + 3 receive reads.
        XCTAssertFalse(f.session.automatic)
    }
    func testBudgetExhaustionStopsAutomaticAndCannotRestartManualRequests() async throws {
        let f = try await fixture(maximum: 4, automaticPolicy: .init(maxEmptyCycles: 5))
        try await save(f, id: f.first, text: "한도 보존\n")
        await ReceiveValidationPolicy.$override.withValue(f.policy) {
            await f.session.toggleAutomatic(); await f.session.synchronize()
        }
        XCTAssertTrue(f.journal.state().stopped, f.session.message); XCTAssertFalse(f.session.automatic)
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().usedRequests, 4)
        await ReceiveValidationPolicy.$override.withValue(f.policy) { await f.session.synchronize() }
        let calls = await f.wire.calls, writes = await f.wire.writes
        XCTAssertEqual(calls, 4); XCTAssertEqual(writes, 0)
        XCTAssertEqual(f.journal.state().sources.count, 1)
    }
    func testComposingDraftsRemainWithTheirDocumentAcrossSessionReopen() async throws {
        let f = try await fixture()
        for (id, text) in [(f.first, "조합 e\u{301}🙂  "), (f.second, "둘째 미저장\n\n")] {
            await f.session.select(.init(rawValue: id))
            let model = try XCTUnwrap(f.session.editor)
            _ = model.recordCompositionState(true); model.updateText(text)
        }
        await f.session.setForeground(false)
        let journal = try IntegratedEditorJournal(root: f.journal.root)
        let wakeup = IntegratedEditorWakeup(), locator = FixedWorkspaceLocator(root: f.root)
        let recorder = IntegratedEditorRecorder(journal: journal, wakeup: wakeup)
        let local = IntegratedEditorDocumentStore(local: LocalDocumentStore(workspaceLocator: locator, metadataUpdater: f.repository, durableChangeRecorder: recorder), journal: journal)
        let commands = LocalBinderCommandService(metadataStore: f.repository, workspaceStateRepository: f.repository, workspaceLocator: locator, durableChangeRecorder: recorder, recoverProjectAliases: false)
        let backend = IntegratedEditorBackend(store: f.store, journal: journal, auth: IntegratedTestAuth(user: journal.state().execution!.accountID),
            configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public"), bindingEpoch: .init(), projectEpoch: .init(),
            makePuller: { snapshot in SyncV2SnapshotPullService(client: snapshot, stateStore: f.store,
                localApplier: LocalSyncV2SnapshotApplier(documentRepository: f.repository, workspaceLocator: locator),
                mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator)) })
        let reopened = IntegratedEditorSession(journal: journal, backend: backend, documents: f.repository, local: local, workspace: f.repository, commands: commands, wakeup: wakeup)
        await reopened.open()
        for (id, text) in [(f.first, "조합 e\u{301}🙂  "), (f.second, "둘째 미저장\n\n")] {
            await reopened.select(.init(rawValue: id))
            XCTAssertEqual(Data(reopened.editor!.currentText.utf8), Data(text.utf8))
        }
        XCTAssertEqual(journal.state().usedRequests, 0)
        await reopened.setForeground(false)
    }
    func testPopulatedFolderRenameMoveTrashAndRestoreUseOriginalIDs() async throws {
        let f = try await fixture()
        await f.session.create(kind: .folder, name: "원본 폴더", parent: .init(rawValue: f.folder))
        let folder = try XCTUnwrap(f.session.folders.first { $0.relativePath.rawValue.hasSuffix("/원본 폴더") })
        await f.session.create(kind: .folder, name: "목적지", parent: .init(rawValue: f.folder))
        let destination = try XCTUnwrap(f.session.folders.first { $0.relativePath.rawValue.hasSuffix("/목적지") })
        await f.session.create(kind: .text, name: "자식", parent: folder.id)
        let child = try XCTUnwrap(f.session.rows.first { $0.relativePath.rawValue.hasSuffix("/자식.txt") })
        try await save(f, id: child.id.rawValue, text: "미송신 자식 본문\n")
        await f.session.select(folder.id); await f.session.rename("변경 폴더"); await f.session.move(to: destination.id)
        await f.session.trash(); XCTAssertNotEqual(f.session.selected?.deletionStatus, .active, f.session.message)
        await f.session.restore(to: .init(rawValue: f.folder))
        XCTAssertEqual(f.session.selected?.id, folder.id); XCTAssertEqual(f.session.selected?.deletionStatus, .active, f.session.message)
        try await cycle(f)
        let latest = try XCTUnwrap(f.session.rows.first { $0.id == child.id })
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent(latest.relativePath.rawValue), encoding: .utf8), "미송신 자식 본문\n")
        XCTAssertNil(f.journal.state().activeWire)
    }
}

private actor IntegratedNetworkCounter {
    var calls = 0
    func send(_ request: URLRequest) -> (Data, URLResponse) {
        calls += 1
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
extension IntegratedEditorTests {
    func testAuthenticationTransportUsesTheSamePersistentBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try IntegratedEditorJournal(root: root), user = UUID(), counter = IntegratedNetworkCounter()
        try journal.configure(.init(id: UUID(), accountID: user, expiresAt: Date().addingTimeInterval(120), maximumRequests: 10, maximumWrites: 2, maximumAuthentication: 1, pollingSeconds: 5, automatic: false))
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { await counter.send($0) })
        let ticket = try XCTUnwrap(policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        let authority = IntegratedEditorAuthority(policy: policy, ticket: ticket, journal: journal, check: {})
        try await authority.context {
            let session = ReceiveValidationURLProtocol.session(policy: policy, ticket: ticket)
            defer { session.invalidateAndCancel() }
            let url = URL(string: ReceiveValidationPolicy.Configuration.staging + "/auth/v1/user")!
            _ = try await session.data(from: url)
            do { _ = try await session.data(from: url); XCTFail("auth limit") } catch {}
        }
        let count = await counter.calls; XCTAssertEqual(count, 1)
        let reopened = try IntegratedEditorJournal(root: root)
        XCTAssertEqual(reopened.state().usedRequests, 1); XCTAssertEqual(reopened.state().usedAuthentication, 1)
    }
    func testRepeatedForegroundAndManualCyclesRenewAuthorityWithoutDuplicatingWrites() async throws {
        let f = try await fixture()
        try await save(f, id: f.first, text: "복귀 저장\n")
        await ReceiveValidationPolicy.$override.withValue(f.policy) {
            await f.session.synchronize()
            await f.session.setForeground(false)
            await f.session.setForeground(true)
            await f.session.synchronize()
        }
        XCTAssertTrue(f.session.prepared, f.session.message)
        XCTAssertNil(f.journal.state().activeWire)
        let writes = await f.wire.writes, calls = await f.wire.calls
        XCTAssertEqual(writes, 1); XCTAssertEqual(calls, 20)
        XCTAssertEqual(f.journal.state().usedRequests, calls)
        await f.session.setForeground(false)
    }
}
extension IntegratedEditorTests {
    func testRPCConflictPersistsRejectedWireAndThreeVersions() async throws {
        let f = try await fixture(); try await save(f, id: f.first, text: "송신 원문\n")
        await f.wire.rejectNextCommit()
        do { try await cycle(f); XCTFail("RPC conflict") } catch { XCTAssertEqual((error as? SyncV2ContractError)?.code, "REVISION_CONFLICT") }
        XCTAssertEqual(f.journal.state().wires.first?.phase, .conflict)
        XCTAssertNotNil(f.journal.state().wires.first?.response)
        let saved = try XCTUnwrap(f.journal.state().conflicts.first)
        XCTAssertEqual(saved.baseline[f.first], "초기\n"); XCTAssertEqual(saved.drafts[f.first]?.text, "송신 원문\n")
        XCTAssertEqual(saved.remote.documents.first { $0.documentID == f.first }?.content, "요청 직전 서버 수정\n")
        do { try await cycle(f); XCTFail("preserved conflict") } catch {}
        let writes = await f.wire.writes; XCTAssertEqual(writes, 1)
    }
    func testReceiptMismatchNeverFallsBackToAnotherWrite() async throws {
        let f = try await fixture(); try await save(f, id: f.first, text: "원래 요청\n")
        await f.wire.configure(lost: true)
        do { try await cycle(f); XCTFail("lost") } catch {}
        let original = try XCTUnwrap(f.journal.state().wires.first)
        await f.wire.corruptReceipts()
        do { try await cycle(f); XCTFail("mismatch") } catch {}
        let writes = await f.wire.writes; XCTAssertEqual(writes, 1)
        XCTAssertEqual(f.journal.state().wires.first?.hash, original.hash)
        XCTAssertEqual(f.journal.state().wires.first?.phase, .httpStarted)
        let base = try await f.store.integratedBaseContents(); XCTAssertEqual(base[f.first], "초기\n")
    }
    private func diagnosticFixture() async throws -> Fixture {
        let f = try await fixture(checkpoint: "afterStoredResponse")
        try await save(f, id: f.first, text: "첫 원본\n")
        await f.wire.configure(lost: true)
        do { try await cycle(f); XCTFail("lost") } catch {}
        try await save(f, id: f.first, text: "후속 원본\n")
        let wire = try XCTUnwrap(f.journal.state().wires.first)
        let request = try SyncV2ContractRequest(storedJSON: wire.request)
        let run = try XCTUnwrap(f.journal.state().execution)
        let approval = IntegratedExecutionAmendment(executionID: run.id, previousExpiry: run.expiresAt,
            expiresAt: run.expiresAt, journalSHA256: f.journal.headSHA256, approvalSHA256: String(repeating: "a", count: 64),
            batchID: request.batchID, operationID: UUID(uuidString: request.orderedIntents[0].objectValue!["operation_id"]!.stringValue!)!, requestSHA256: wire.hash)
        try f.journal.update("testDiagnosticBound") {
            $0.amendment = approval
            $0.diagnostic = .init(initialRequests: $0.usedRequests, initialAuthentication: $0.usedAuthentication)
        }
        return f
    }
    func testDiagnosticReceiptSuccessStopsBeforeLocalCompletionOrLaterWrite() async throws {
        let f = try await diagnosticFixture()
        let original = f.journal.state(), beforeWrites = await f.wire.writes
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail("checkpoint") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .checkpoint) }
        let state = f.journal.state()
        XCTAssertEqual(state.usedRequests - original.usedRequests, 4)
        XCTAssertEqual(state.usedWrites, original.usedWrites)
        XCTAssertEqual(state.sources.count, 2)
        XCTAssertEqual(state.wires.count, 1)
        XCTAssertEqual(state.wires[0].phase, .responseStored)
        XCTAssertEqual(state.wires[0].request, original.wires[0].request)
        XCTAssertEqual(state.diagnostic?.finished, true)
        let bases = try await f.store.integratedBaseContents(); XCTAssertEqual(bases[f.first], "초기\n")
        let afterWrites = await f.wire.writes; XCTAssertEqual(afterWrites, beforeWrites)
        let head = f.journal.headSHA256
        do { try await f.backend.diagnoseReceipt(); XCTFail("retry") } catch {}
        XCTAssertEqual(f.journal.headSHA256, head)
        XCTAssertThrowsError(try f.journal.reserve(kind: "auth"))
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertThrowsError(try reopened.reserve(kind: "data", path: "sync_batches"))
        XCTAssertThrowsError(try reopened.releaseDiagnostic(journalSHA256: String(repeating: "0", count: 64), approvalSHA256: String(repeating: "b", count: 64)))
        try f.journal.releaseDiagnostic(journalSHA256: head, approvalSHA256: String(repeating: "b", count: 64))
        try await cycle(f)
        let finalWrites = await f.wire.writes; XCTAssertEqual(finalWrites, beforeWrites + 1)
        XCTAssertTrue(f.journal.state().wires.allSatisfy { $0.phase == .completed })
        XCTAssertEqual(f.journal.state().usedWrites, original.usedWrites + 1)
    }
    func testDiagnosticMismatchRecordsFieldAndCannotRetryOrRelease() async throws {
        let f = try await diagnosticFixture()
        await f.wire.corruptReceipts()
        let before = f.journal.state()
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail("mismatch") } catch {}
        XCTAssertEqual(f.journal.state().wires[0].phase, .httpStarted)
        XCTAssertEqual(f.journal.state().usedWrites, before.usedWrites)
        XCTAssertEqual(f.journal.state().usedRequests - before.usedRequests, 4)
        XCTAssertThrowsError(try f.journal.releaseDiagnostic(journalSHA256: f.journal.headSHA256, approvalSHA256: String(repeating: "b", count: 64)))
        let files = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
        let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(text.contains("receiptDiagnostic:validation:batch.writer_user_id"))
        XCTAssertTrue(text.contains("sync_batches:http.200"))
        XCTAssertTrue(text.contains("sync_batch_results:rows.1.total.1"))
        XCTAssertFalse(text.contains("isolated-test-token"))
        XCTAssertFalse(text.contains("Authorization"))
    }
    func testDiagnosticNamesNestedResponseMismatchWithoutAcceptingIt() async throws {
        let f = try await diagnosticFixture()
        let request = try SyncV2ContractRequest(storedJSON: f.journal.state().wires[0].request)
        let pending = SyncV2PendingContractBatch(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: request)
        let response = makeGeneralCommitResponseForTesting(pending)
        XCTAssertNil(IntegratedEditorBackend.documentResponseDifference(request, response: response))
        var fields = response.objectValue!, result = fields["results"]!.arrayValue![0].objectValue!
        result["content_byte_count"] = .int(999)
        fields["results"] = .array([.object(result)])
        let malformed = SyncV2JSON.object(fields)
        XCTAssertEqual(IntegratedEditorBackend.documentResponseDifference(request, response: malformed), "response.results.0.content_byte_count")
        XCTAssertThrowsError(try SyncV2Contract.validateDocumentCommitResponse(request: request, response: malformed))
    }
    func testDiagnosticSeparatesTransportHTTPDecodeAndCountFailures() async throws {
        for (fault, expected) in [("transport", "transport.url.-1001"), ("http", "http.403"), ("decode", "decode.failed"), ("count", "rows.0.total.1")] {
            let f = try await diagnosticFixture(); await f.wire.setReceiptFault(fault)
            let before = f.journal.state()
            do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail(fault) } catch {}
            XCTAssertEqual(f.journal.state().usedRequests - before.usedRequests, 4)
            XCTAssertEqual(f.journal.state().usedWrites, before.usedWrites)
            XCTAssertEqual(f.journal.state().wires[0].phase, .httpStarted)
            let files = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
            let text = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
            XCTAssertTrue(text.contains("receiptDiagnostic:sync_batch_results:" + expected), fault)
            XCTAssertFalse(text.contains("not-json-secret")); XCTAssertFalse(text.contains("secret-header"))
        }
    }
    func testDiagnosticBudgetPersistsPerEndpointAndAuthAcrossReopen() async throws {
        let f = try await diagnosticFixture()
        try f.journal.reserve(kind: "auth")
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertThrowsError(try reopened.reserve(kind: "auth"))
        try reopened.beginDiagnostic()
        XCTAssertThrowsError(try reopened.reserve(kind: "write", path: "rpc/document_commit"))
        XCTAssertThrowsError(try reopened.reserve(kind: "data", path: "documents"))
        for path in ["rpc/get_sync_handshake", "rpc/get_project_status", "sync_batches", "sync_batch_results"] {
            try reopened.reserve(kind: "data", path: path)
            XCTAssertThrowsError(try reopened.reserve(kind: "data", path: path))
        }
        XCTAssertEqual(reopened.state().usedRequests - reopened.state().diagnostic!.initialRequests, 5)
        let twice = try IntegratedEditorJournal(root: reopened.root)
        XCTAssertThrowsError(try twice.beginDiagnostic())
        XCTAssertThrowsError(try twice.reserve(kind: "data", path: "sync_batches"))
    }
    func testExplicitExpiryAmendmentPreservesJournalAndRejectsOtherChanges() async throws {
        let f = try await diagnosticFixture()
        let now = Date(timeIntervalSince1970: 1789272000)
        let old = IntegratedExecution(id: UUID(uuidString: "6a7a9c7d-982a-4fcd-90e6-3b4140504860")!, accountID: f.journal.state().execution!.accountID,
            expiresAt: Date(timeIntervalSince1970: 1789270200), maximumRequests: 520, maximumWrites: 26,
            maximumAuthentication: 16, pollingSeconds: 10, automatic: false, checkpoint: "all")
        try f.journal.update("testOriginalExecution") { $0.execution = old; $0.lastClock = now.addingTimeInterval(-60); $0.amendment = nil; $0.diagnostic = nil }
        let next = IntegratedExecution(id: old.id, accountID: old.accountID, expiresAt: Date(timeIntervalSince1970: 1789279200),
            maximumRequests: 520, maximumWrites: 26, maximumAuthentication: 16, pollingSeconds: 10, automatic: false, checkpoint: "all")
        let wire = f.journal.state().wires[0], request = try SyncV2ContractRequest(storedJSON: wire.request)
        let approval = IntegratedExecutionAmendment(executionID: old.id, previousExpiry: old.expiresAt, expiresAt: next.expiresAt,
            journalSHA256: f.journal.headSHA256, approvalSHA256: String(repeating: "a", count: 64), batchID: request.batchID,
            operationID: UUID(uuidString: request.orderedIntents[0].objectValue!["operation_id"]!.stringValue!)!, requestSHA256: wire.hash)
        let before = f.journal.state()
        let files = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
        let bytes = try files.map { try Data(contentsOf: $0) }
        XCTAssertThrowsError(try f.journal.configure(next, now: now))
        let larger = IntegratedExecution(id: old.id, accountID: old.accountID, expiresAt: next.expiresAt,
            maximumRequests: 521, maximumWrites: 26, maximumAuthentication: 16, pollingSeconds: 10, automatic: false, checkpoint: "all")
        XCTAssertThrowsError(try f.journal.amend(larger, approval: approval, now: now))
        XCTAssertEqual(f.journal.headSHA256, approval.journalSHA256)
        try f.journal.amend(next, approval: approval, now: now)
        let head = f.journal.headSHA256
        try f.journal.amend(next, approval: approval, now: now)
        XCTAssertEqual(f.journal.headSHA256, head)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, bytes)
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        let after = reopened.state()
        XCTAssertEqual(after.usedRequests, before.usedRequests); XCTAssertEqual(after.usedWrites, before.usedWrites)
        XCTAssertEqual(after.usedAuthentication, before.usedAuthentication)
        XCTAssertEqual(after.wires[0].request, before.wires[0].request)
        XCTAssertEqual(after.wires[0].phase, before.wires[0].phase)
        XCTAssertEqual(after.sources.count, before.sources.count)
        XCTAssertEqual(after.checkpoints, before.checkpoints)
        XCTAssertEqual(after.lastClock, before.lastClock)
        XCTAssertThrowsError(try reopened.configure(old, now: now))
        XCTAssertNoThrow(try reopened.configure(next, now: now))
        XCTAssertThrowsError(try reopened.checkTime(next.expiresAt))
        XCTAssertThrowsError(try reopened.reserve(kind: "auth", now: next.expiresAt))
    }
    func testCapturedJournalExtensionOnPrivateCopyPreservesEveryOriginalRecord() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/ipad-integrated-editor-execution-20260913/private/s2-receipt-failure-close-journal")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local captured journal is intentionally outside source control") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("CapturedJournal-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let journal = try IntegratedEditorJournal(root: target), before = journal.state()
        let old = try XCTUnwrap(before.execution), wire = try XCTUnwrap(before.wires.first)
        XCTAssertEqual(before.usedRequests, 33); XCTAssertEqual(before.usedWrites, 1); XCTAssertEqual(before.usedAuthentication, 5)
        XCTAssertEqual(before.sources.count, 2); XCTAssertEqual(wire.phase, .httpStarted)
        XCTAssertEqual(wire.hash, "cedf65759db1576d6566c2762afde9f51f72cc6ee60c7425fcb7927689bcc78d")
        let next = IntegratedExecution(id: old.id, accountID: old.accountID, expiresAt: Date(timeIntervalSince1970: 1789279200),
            maximumRequests: old.maximumRequests, maximumWrites: old.maximumWrites, maximumAuthentication: old.maximumAuthentication,
            pollingSeconds: old.pollingSeconds, automatic: old.automatic, checkpoint: old.checkpoint)
        let request = try SyncV2ContractRequest(storedJSON: wire.request)
        let amendment = IntegratedExecutionAmendment(executionID: old.id, previousExpiry: old.expiresAt, expiresAt: next.expiresAt,
            journalSHA256: journal.headSHA256, approvalSHA256: String(repeating: "a", count: 64), batchID: request.batchID,
            operationID: UUID(uuidString: request.orderedIntents[0].objectValue!["operation_id"]!.stringValue!)!, requestSHA256: wire.hash)
        let now = Date(timeIntervalSince1970: 1789275600)
        try journal.amend(next, approval: amendment, now: now)
        let reopened = try IntegratedEditorJournal(root: target)
        func comparable(_ state: IntegratedEditorJournal.State) throws -> NSDictionary {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
            value.removeValue(forKey: "amendment"); value.removeValue(forKey: "diagnostic")
            // Codable represents UUID dictionaries and Sets as arrays; their iteration order is not state.
            value["checkpoints"] = state.checkpoints.sorted()
            value["members"] = state.members.map { $0.uuidString }.sorted()
            let drafts = value["drafts"] as! [Any]
            var keyedDrafts: [String: Any] = [:]
            for index in stride(from: 0, to: drafts.count, by: 2) { keyedDrafts[drafts[index] as! String] = drafts[index + 1] }
            value["drafts"] = keyedDrafts
            var run = value["execution"] as! [String: Any]; run.removeValue(forKey: "expiresAt"); value["execution"] = run
            return value as NSDictionary
        }
        XCTAssertEqual(try comparable(before), try comparable(reopened.state()))
        let originals = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for file in originals { XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: target.appendingPathComponent(file.lastPathComponent))) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, originals.count + 1)
        XCTAssertThrowsError(try reopened.configure(old, now: now))
        XCTAssertNoThrow(try reopened.configure(next, now: now))
        XCTAssertThrowsError(try reopened.checkTime(next.expiresAt))
    }
    func testReceiptCapabilitiesAcceptOnlyUniqueStringMembershipAndKeepWireHash() async throws {
        let f = try await diagnosticFixture()
        let original = f.journal.state().wires[0], request = try SyncV2ContractRequest(storedJSON: original.request)
        let pending = SyncV2PendingContractBatch(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: request)
        let account = f.journal.state().execution!.accountID, response = makeGeneralCommitResponseForTesting(pending)
        let valid = try makeGeneralCommitReceiptForTesting(pending, accountID: account, response: response)
        let capabilities = valid.batch.objectValue!["client_capabilities"]!.arrayValue!
        let originalCapabilities = original.request.objectValue!["batch"]!.objectValue!["client_capabilities"]!
        XCTAssertNotEqual(.array(capabilities), originalCapabilities)
        XCTAssertEqual(try valid.validatedResponse(for: pending, accountID: account), response)
        var reverse = valid.batch.objectValue!; reverse["client_capabilities"] = .array(Array(capabilities.reversed()))
        XCTAssertEqual(try SyncV2GeneralCommitReceipt(batch: .object(reverse), result: valid.result).validatedResponse(for: pending, accountID: account), response)
        let invalid: [SyncV2JSON?] = [nil, .null, .string("document_commit_v1"), .object([:]), .int(8),
            .array([]), .array(Array(capabilities.dropLast())), .array(capabilities + [.string("unknown_capability")]),
            .array(capabilities + [capabilities[0]]), .array(Array(capabilities.dropLast()) + [.int(1)])]
        for value in invalid {
            var batch = valid.batch.objectValue!; batch["client_capabilities"] = value
            XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: .object(batch), result: valid.result).validatedResponse(for: pending, accountID: account))
        }
        // A malformed original declaration must also fail, even if the receipt repeats it exactly.
        for bad in [SyncV2JSON.null, .string("document_commit_v1"), .array(capabilities + [capabilities[0]]), .array([.int(1)])] {
            var envelope = original.request.objectValue!, originalBatch = envelope["batch"]!.objectValue!
            originalBatch["client_capabilities"] = bad; envelope["batch"] = .object(originalBatch)
            let changedRequest = try SyncV2ContractRequest(storedJSON: .object(envelope))
            let changedPending = SyncV2PendingContractBatch(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: changedRequest)
            var storedBatch = valid.batch.objectValue!; storedBatch["client_capabilities"] = bad
            storedBatch["request_sha256"] = .string(try changedRequest.json.sha256Hex())
            XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: .object(storedBatch), result: valid.result).validatedResponse(for: changedPending, accountID: account))
        }
        for key in ["writer_device_id", "client_build_id", "batch_payload_sha256", "request_sha256", "canonical_contract_sha256"] {
            var batch = valid.batch.objectValue!; batch[key] = .string("changed")
            XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: .object(batch), result: valid.result).validatedResponse(for: pending, accountID: account))
        }
        var result = valid.result.objectValue!; result["response_sha256"] = .string(String(repeating: "0", count: 64))
        XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: valid.batch, result: .object(result)).validatedResponse(for: pending, accountID: account))
        XCTAssertEqual(try request.json.sha256Hex(), original.hash)
        XCTAssertEqual(f.journal.state().wires[0].request, original.request)
    }
    private func recoveryApproval(_ journal: IntegratedEditorJournal) throws -> IntegratedReceiptRecoveryApproval {
        let state = journal.state(), run = try XCTUnwrap(state.execution), amendment = try XCTUnwrap(state.amendment)
        return .init(executionID: run.id, expiresAt: run.expiresAt, journalSHA256: journal.headSHA256,
            approvalSHA256: String(repeating: "b", count: 64), batchID: amendment.batchID, operationID: amendment.operationID,
            requestSHA256: amendment.requestSHA256, expectedRequests: state.usedRequests,
            expectedAuthentication: state.usedAuthentication, expectedWrites: state.usedWrites)
    }
    private func failedDiagnosticFixture() async throws -> Fixture {
        let f = try await diagnosticFixture(); await f.wire.setReceiptFault("transport")
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail("first failure") } catch {}
        await f.wire.setReceiptFault(nil)
        return f
    }
    func testApprovedRecoveryAddsAttemptKeepsFirstDiagnosticAndNeverRepostsFirstWrite() async throws {
        let f = try await failedDiagnosticFixture(), before = f.journal.state()
        let approval = try recoveryApproval(f.journal)
        try f.journal.authorizeReceiptRecovery(approval)
        XCTAssertEqual(f.journal.state().diagnostic, before.diagnostic)
        XCTAssertEqual(f.journal.state().usedRequests, before.usedRequests)
        try f.journal.reserve(kind: "auth")
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        let head = reopened.headSHA256
        try reopened.authorizeReceiptRecovery(approval)
        XCTAssertEqual(reopened.headSHA256, head)
        XCTAssertThrowsError(try reopened.reserve(kind: "auth"))
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail("checkpoint") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .checkpoint) }
        let after = f.journal.state()
        XCTAssertEqual(after.usedRequests - before.usedRequests, 5)
        XCTAssertEqual(after.usedAuthentication - before.usedAuthentication, 1)
        XCTAssertEqual(after.usedWrites, before.usedWrites)
        XCTAssertEqual(after.diagnostic, before.diagnostic)
        XCTAssertEqual(after.receiptRecovery?.finished, true)
        XCTAssertEqual(after.wires[0].phase, .responseStored)
        XCTAssertEqual(after.wires[0].request, before.wires[0].request)
        let writes = await f.wire.writes; XCTAssertEqual(writes, 1)
        XCTAssertEqual(after.sources.count, 2)
        XCTAssertThrowsError(try f.journal.reserve(kind: "data", path: "sync_batches"))
        do { try await f.backend.synchronize(); XCTFail("not released") } catch {}
        try f.journal.releaseDiagnostic(journalSHA256: f.journal.headSHA256, approvalSHA256: String(repeating: "c", count: 64))
        try await cycle(f)
        let finalWrites = await f.wire.writes; XCTAssertEqual(finalWrites, 2)
        XCTAssertEqual(f.journal.state().diagnostic, before.diagnostic)
        XCTAssertTrue(f.journal.state().wires.allSatisfy { $0.phase == .completed })
    }
    func testRecoveryApprovalRejectsWrongScopeCountersAndReuseWithoutChanges() async throws {
        let f = try await diagnosticFixture()
        XCTAssertThrowsError(try f.journal.authorizeReceiptRecovery(recoveryApproval(f.journal)))
        await f.wire.setReceiptFault("http")
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.diagnoseReceipt() }; XCTFail("failure") } catch {}
        let approval = try recoveryApproval(f.journal), head = f.journal.headSHA256
        let data = try JSONEncoder().encode(approval)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let changes: [(String, Any)] = [("executionID", UUID().uuidString), ("expiresAt", Date().addingTimeInterval(7200).timeIntervalSinceReferenceDate),
            ("journalSHA256", String(repeating: "0", count: 64)), ("requestSHA256", String(repeating: "0", count: 64)),
            ("batchID", UUID().uuidString), ("operationID", UUID().uuidString), ("expectedRequests", approval.expectedRequests - 1),
            ("expectedAuthentication", approval.expectedAuthentication - 1), ("expectedWrites", approval.expectedWrites + 1),
            ("approvalSHA256", f.journal.state().amendment!.approvalSHA256)]
        for (key, value) in changes {
            var changed = fields; changed[key] = value
            let invalid = try JSONDecoder().decode(IntegratedReceiptRecoveryApproval.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try f.journal.authorizeReceiptRecovery(invalid), key)
            XCTAssertEqual(f.journal.headSHA256, head)
        }
        try f.journal.authorizeReceiptRecovery(approval)
        try f.journal.beginDiagnostic(); try f.journal.finishDiagnostic()
        let finishedHead = f.journal.headSHA256
        try f.journal.authorizeReceiptRecovery(approval)
        XCTAssertEqual(f.journal.headSHA256, finishedHead)
        XCTAssertThrowsError(try f.journal.beginDiagnostic())
        let secondApproval = try recoveryApproval(f.journal)
        XCTAssertThrowsError(try f.journal.authorizeReceiptRecovery(secondApproval))
    }
    func testCapturedSeventyRecordsAcceptRecoveryOnCopyAndPreserveFirstDiagnostic() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("build/ipad-integrated-receipt-execution-20260913/private/diagnostic-close-journal")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Private execution capture is not a repository fixture") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryCopy-" + UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: target); defer { try? FileManager.default.removeItem(at: target) }
        let journal = try IntegratedEditorJournal(root: target), before = journal.state(), files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 70); XCTAssertEqual(before.usedRequests, 38); XCTAssertEqual(before.usedAuthentication, 6); XCTAssertEqual(before.usedWrites, 1)
        let approval = try recoveryApproval(journal), now = Date(timeIntervalSince1970: 1789277400)
        try journal.authorizeReceiptRecovery(approval, now: now)
        let reopened = try IntegratedEditorJournal(root: target), after = reopened.state()
        XCTAssertEqual(after.diagnostic, before.diagnostic)
        XCTAssertEqual(after.amendment, before.amendment)
        XCTAssertEqual(after.execution, before.execution)
        XCTAssertEqual(after.usedRequests, 38); XCTAssertEqual(after.usedAuthentication, 6); XCTAssertEqual(after.usedWrites, 1)
        XCTAssertEqual(after.receiptRecovery?.initialRequests, 38); XCTAssertEqual(after.receiptRecovery?.initialAuthentication, 6)
        func comparable(_ state: IntegratedEditorJournal.State) throws -> NSDictionary {
            var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
            fields.removeValue(forKey: "receiptRecovery"); fields.removeValue(forKey: "receiptRecoveryApproval")
            fields["checkpoints"] = state.checkpoints.sorted(); fields["members"] = state.members.map { $0.uuidString }.sorted()
            let drafts = fields["drafts"] as! [Any]; var keyed: [String: Any] = [:]
            for index in stride(from: 0, to: drafts.count, by: 2) { keyed[drafts[index] as! String] = drafts[index + 1] }
            fields["drafts"] = keyed; return fields as NSDictionary
        }
        XCTAssertEqual(try comparable(before), try comparable(after))
        XCTAssertEqual(after.wires[0].request, before.wires[0].request); XCTAssertEqual(after.wires[0].phase, .httpStarted)
        XCTAssertEqual(after.checkpoints, before.checkpoints); XCTAssertEqual(after.sources.count, 2)
        for file in files { XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: target.appendingPathComponent(file.lastPathComponent))) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).count, 71)
        XCTAssertThrowsError(try reopened.checkTime(approval.expiresAt))
        // The saved reconstruction is explicitly hash-verified evidence, not labelled as a received raw body.
        let receiptData = try Data(contentsOf: root.appendingPathComponent("build/ipad-integrated-receipt-execution-20260913/private/sync-batches-reconstructed-response.json"))
        XCTAssertEqual(IntegratedEditorPlan.hash(receiptData), "37ac7350709613a52e6eb421f8e24765292a9ac2e798ac4d2b73834eb9774543")
        let batch = try JSONDecoder().decode([SyncV2JSON].self, from: receiptData)[0]
        let request = try SyncV2ContractRequest(storedJSON: before.wires[0].request)
        let pending = SyncV2PendingContractBatch(localProjectID: IntegratedEditorPlan.local, serverProjectID: IntegratedEditorPlan.server, request: request)
        let response = makeGeneralCommitResponseForTesting(pending)
        let syntheticResult = try makeGeneralCommitReceiptForTesting(pending, accountID: before.execution!.accountID, response: response).result
        XCTAssertEqual(try SyncV2GeneralCommitReceipt(batch: batch, result: syntheticResult).validatedResponse(for: pending, accountID: before.execution!.accountID), response)
        XCTAssertEqual(try request.json.sha256Hex(), before.wires[0].hash)
    }
    func testExistingOutsideFolderCannotEnterScopeByRemoteMove() async throws {
        let f = try await fixture(), snapshot = await f.wire.snapshot
        let changed = IntegratedRemoteSnapshot(documents: snapshot.documents, folders: snapshot.folders.map {
            guard $0.name == "휴지통" else { return $0 }
            return .init(folderID: $0.folderID, parentFolderID: f.folder, name: "침범", revision: $0.revision + 1, isDeleted: false, updatedAt: Date())
        }, orders: snapshot.orders)
        XCTAssertThrowsError(try changed.validate(baseline: snapshot.metadata, members: f.journal.state().members))
    }
}
extension IntegratedEditorTests {
    func testNewRemoteDocumentIsAdoptedOnlyInsideTestSubtree() async throws {
        let f = try await fixture()
        let id = await f.wire.addRemoteDocument(parent: f.folder, name: "외부 생성.txt", content: "새 원격 본문 e\u{301}🙂\n")
        try await cycle(f)
        XCTAssertTrue(f.journal.state().members.contains(id))
        let node = try await f.repository.document(id: .init(rawValue: id))
        XCTAssertEqual(node?.parentID?.rawValue, f.folder)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/외부 생성.txt"), encoding: .utf8), "새 원격 본문 e\u{301}🙂\n")
        let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
    }
}

// Synthetic local policy and save-boundary tests. No device capture or real transport.
extension IntegratedEditorTests {
    func testAutomaticPolicyStrictKeysAndOldRunIsNotBackfilled() async throws {
        for json in [#"{"version":2,"max_empty_cycles":1}"#, #"{"version":1,"max_empty_cycles":-1}"#,
                     #"{"version":true,"max_empty_cycles":1}"#, #"{"version":1,"max_empty_cycles":true}"#,
                     #"{"version":1,"max_empty_cycles":1.5}"#, #"{"version":1,"max_empty_cycles":1,"extra":0}"#,
                     #"{"version":1,"maxEmptyCycles":1}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(IntegratedAutomaticPolicy.self, from: Data(json.utf8)), json)
        }
        let policy = try JSONDecoder().decode(IntegratedAutomaticPolicy.self, from: Data(#"{"version":1,"max_empty_cycles":0}"#.utf8))
        XCTAssertEqual(policy.maxEmptyCycles, 0)
        let f = try await fixture(), head = f.journal.headSHA256, run = f.journal.state().execution!
        XCTAssertThrowsError(try f.journal.setAutomatic(true))
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        try reopened.configure(run)
        XCTAssertNil(reopened.state().empty_cycles_used); XCTAssertNil(reopened.state().automatic_stop)
        XCTAssertEqual(reopened.headSHA256, head)
        var changed = run; changed.automatic_policy = .init(maxEmptyCycles: 1)
        XCTAssertThrowsError(try reopened.configure(changed))
        XCTAssertEqual(reopened.headSHA256, head)
    }
    func testLastEmptyCycleAppliesRemoteAndRestartBlocksAllAutomaticButManualKeepsCount() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 1))
        try f.journal.setAutomatic(true)
        await f.wire.edit(f.first, text: "마지막 허용 수신\n")
        try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1); XCTAssertFalse(f.journal.state().automatic)
        XCTAssertNil(f.journal.state().receive)
        let base = try await f.store.integratedBaseContents(); XCTAssertEqual(base[f.first], "마지막 허용 수신\n")
        let calls = await f.wire.calls
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.automaticBlockReason(), .automaticLimit)
        XCTAssertThrowsError(try reopened.setAutomatic(true))
        try await save(f, id: f.first, text: "한도 이후 로컬 원본\n")
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("automatic denied") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .automaticLimit) }
        let blockedCalls = await f.wire.calls; XCTAssertEqual(blockedCalls, calls)
        try await cycle(f)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
        XCTAssertEqual(f.journal.state().automatic_stop, IntegratedEditorError.automaticLimit.rawValue)
    }
    func testAutomaticFailureRetainsReservationBeforeFirstHTTPAndAfterReopen() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try f.journal.setAutomatic(true)
        let journal = f.journal
        let failed = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: f.journal.state().execution!.accountID), network: { _ in
            XCTAssertEqual(journal.state().empty_cycles_used, 1)
            throw URLError(.timedOut)
        })
        do { try await ReceiveValidationPolicy.$override.withValue(failed) { try await f.backend.runCycle(automatic: true) }; XCTFail("failure") } catch {}
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().empty_cycles_used, 1); XCTAssertEqual(reopened.state().usedRequests, 1)
        // Also model interruption after the durable reservation but before the first HTTP.
        try reopened.reserveAutomaticCycle(hasPendingBatch: false)
        let interrupted = try IntegratedEditorJournal(root: reopened.root)
        XCTAssertEqual(interrupted.state().empty_cycles_used, 2); XCTAssertEqual(interrupted.state().usedRequests, 1)
        XCTAssertThrowsError(try interrupted.setAutomatic(true))
    }
    func testZeroMissingAndCorruptCounterBlockBeforeTransportWithoutReset() async throws {
        for mode in ["zero", "missing", "negative", "excess", "stop"] {
            let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: mode == "zero" ? 0 : 2))
            try f.journal.update("syntheticCounterFault") {
                $0.automatic = true
                if mode == "missing" { $0.empty_cycles_used = nil }
                if mode == "negative" { $0.empty_cycles_used = -1 }
                if mode == "excess" { $0.empty_cycles_used = 3 }
                if mode == "stop" { $0.automatic_stop = "unknown" }
            }
            let head = f.journal.headSHA256
            do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail(mode) } catch {}
            let calls = await f.wire.calls; XCTAssertEqual(calls, 0, mode)
            XCTAssertEqual(f.journal.headSHA256, head, mode)
            XCTAssertNotNil(try IntegratedEditorJournal(root: f.journal.root).automaticBlockReason())
        }
    }
    func testOfflineInactiveAndPreexistingConflictDoNotConsumeEmptyCycle() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try f.journal.setAutomatic(true)
        await f.session.synchronize(automatic: true) // Connectivity starts unknown/offline.
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        await f.session.setForeground(false); f.session.setConnected(true)
        await f.session.synchronize(automatic: true)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        let remote = await f.wire.snapshot
        try f.journal.update("syntheticConflict") { $0.conflicts.append(.init(baseline: [:], sources: [], drafts: [:], remote: remote)) }
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("conflict") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .conflict) }
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        let calls = await f.wire.calls; XCTAssertEqual(calls, 0)
    }
    func testSendingAndReceiptRecoveryCyclesDoNotConsumeEmptyBudget() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try await save(f, id: f.first, text: "첫 원본\n")
        try f.journal.setAutomatic(true); await f.wire.configure(lost: true)
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("lost") } catch {}
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        XCTAssertEqual(f.journal.state().wires.first?.phase, .httpStarted)
        try await save(f, id: f.first, text: "둘째 원본\n")
        try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        XCTAssertEqual(f.journal.state().sources.count, 2)
        XCTAssertTrue(f.journal.state().wires.allSatisfy { $0.phase == .completed })
        let writes = await f.wire.writes; XCTAssertEqual(writes, 2)
    }
    func testAutomaticReservationIsAtomicAndCumulativeAcrossReopen() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 3))
        try f.journal.setAutomatic(true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { try? f.journal.reserveAutomaticCycle(hasPendingBatch: false) } }
        }
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().empty_cycles_used, 3); XCTAssertFalse(reopened.state().automatic)
        XCTAssertEqual(reopened.state().usedRequests, 0)
        XCTAssertThrowsError(try reopened.reserveAutomaticCycle(hasPendingBatch: true))
        var changed = reopened.state().execution!; changed.automatic_policy = .init(maxEmptyCycles: 4)
        XCTAssertThrowsError(try reopened.configure(changed))
        XCTAssertEqual(reopened.state().empty_cycles_used, 3)
    }
    func testSaveBoundariesKeepPasteEnterAndSameContentShortcutSeparateWithoutBodyInDiagnostic() async throws {
        let f = try await fixture()
        await f.session.select(.init(rawValue: f.first))
        let editor = try XCTUnwrap(f.session.editor)
        let pasted = "붙여넣기 e\u{301}🙂"
        editor.updateText(pasted, source: .paste)
        // Drive the real autosave entry deterministically; timer scheduling is separately exercised below.
        let firstSaved = await editor.saveNow(boundary: .autosaveTimer); XCTAssertTrue(firstSaved)
        let first = try XCTUnwrap(f.journal.state().latestSaveDiagnostic)
        XCTAssertEqual(first.boundary, .autosaveTimer); XCTAssertEqual(first.inputSource, .paste)
        XCTAssertEqual(first.after, EditorBodyDiagnostic(pasted)); XCTAssertEqual(first.stage, "saved")
        editor.updateText(pasted + "\n", source: .enter); await f.session.save()
        let second = try XCTUnwrap(f.journal.state().latestSaveDiagnostic)
        XCTAssertEqual(second.boundary, .saveButton); XCTAssertEqual(second.inputSource, .enter)
        XCTAssertEqual(second.before, first.after); XCTAssertEqual(second.after.utf8Bytes, first.after.utf8Bytes + 1)
        XCTAssertTrue(second.after.endsLF); XCTAssertEqual(second.changed, true)
        await f.session.save(boundary: .saveShortcut)
        let unchanged = try XCTUnwrap(f.journal.state().latestSaveDiagnostic)
        XCTAssertEqual(unchanged.boundary, .saveShortcut); XCTAssertEqual(unchanged.stage, "unchanged"); XCTAssertEqual(unchanged.changed, false)
        XCTAssertEqual(f.journal.state().sources.count, 2)
        let bytes = try JSONEncoder().encode(unchanged)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(pasted))
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().sources.count, 2)
        XCTAssertEqual(reopened.state().latestSaveDiagnostic?.after, second.after)
        let path = IntegratedEditorPlan.rootPath + "/첫째.txt"
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(path)), Data((pasted + "\n").utf8))
    }
    func testActualAutosaveTimerAndTransitionRecordDistinctBoundaries() async throws {
        let f = try await fixture()
        await f.session.select(.init(rawValue: f.first))
        let editor = try XCTUnwrap(f.session.editor)
        editor.updateAutosaveDelay(.milliseconds(5)); editor.updateText("타이머 저장", source: .key)
        for _ in 0..<100 where editor.hasUnsavedChanges { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.boundary, .autosaveTimer)
        editor.updateAutosaveDelay(.seconds(300)); editor.updateText("전환 저장\n", source: .other)
        await f.session.select(.init(rawValue: f.second))
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.boundary, .documentTransition)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.after, EditorBodyDiagnostic("전환 저장\n"))
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.stage, "draftRetained")
        XCTAssertEqual(f.journal.state().sources.count, 1) // Selection never adds a new save.
        XCTAssertTrue(editor.hasUnsavedChanges)
        let saved = await editor.saveNow(boundary: .autosaveTimer); XCTAssertTrue(saved)
        XCTAssertEqual(f.journal.state().sources.count, 2)
    }
    func testCompositionDeferralAndRemoteOriginAreNotAttributedToUserKey() async throws {
        let f = try await fixture()
        await f.session.select(.init(rawValue: f.first)); let editor = try XCTUnwrap(f.session.editor)
        _ = editor.recordCompositionState(true); editor.updateText("조합 중", source: .ime)
        let deferred = await editor.saveNow(boundary: .saveButton); XCTAssertTrue(deferred)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.stage, "deferredComposition")
        XCTAssertEqual(f.journal.state().sources.count, 0)
        let generation = try XCTUnwrap(editor.recordCompositionState(false))
        _ = await editor.finishCompositionStateUpdate(false, generation: generation)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.inputSource, .ime)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.boundary, .saveButton)
        try await cycle(f)
        await f.wire.edit(f.first, text: "원격 본문\n")
        await ReceiveValidationPolicy.$override.withValue(f.policy) { await f.session.synchronize() }
        await f.session.select(.init(rawValue: f.first)); await f.session.save()
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.inputSource, .remoteSnapshot)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.stage, "unchanged")
    }
}

extension IntegratedEditorTests {
    func testSaveFailureKeepsOriginalDraftAndReportsBoundaryWithoutCreatingSource() async throws {
        let f = try await fixture()
        await f.session.select(.init(rawValue: f.first)); let editor = try XCTUnwrap(f.session.editor)
        editor.updateText("실패 보존\n", source: .paste)
        let remote = await f.wire.snapshot
        try f.journal.update("syntheticPartialReceive") { $0.receive = remote }
        let saved = await editor.saveNow(boundary: .saveShortcut); XCTAssertFalse(saved)
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.stage, "failed")
        XCTAssertEqual(f.journal.state().latestSaveDiagnostic?.boundary, .saveShortcut)
        XCTAssertEqual(f.journal.state().drafts[f.first]?.text, "실패 보존\n")
        XCTAssertTrue(f.journal.state().sources.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")), Data("초기\n".utf8))
    }
    func testPartialApplyOnLastCycleKeepsReservationAndBlocksAutomaticRestart() async throws {
        let f = try await fixture(checkpoint: "afterOriginalApply", automaticPolicy: .init(maxEmptyCycles: 1))
        await f.wire.edit(f.first, text: "부분 수신\n"); try f.journal.setAutomatic(true)
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("checkpoint") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .checkpoint) }
        XCTAssertNotNil(f.journal.state().receive)
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().empty_cycles_used, 1); XCTAssertThrowsError(try reopened.setAutomatic(true))
        let calls = await f.wire.calls
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("stopped") } catch {}
        let after = await f.wire.calls; XCTAssertEqual(after, calls)
        try await cycle(f)
        XCTAssertNil(f.journal.state().receive); XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
    }
    func testNativeInputReportsObservedKeyEnterIMEAndUnclassifiedChange() async throws {
        let id = DocumentID(rawValue: UUID())
        var sources: [EditorInputSource] = []
        let bridge = iPadTextEditor(text: .constant(""), documentID: id, externalVersion: 0,
            selection: .constant(.start), focusRequest: 0, textRuleSettings: .disabled,
            onInputSource: { _, source in sources.append(source) })
        let coordinator = bridge.makeCoordinator(), view = BoundaryTrackingTextView()
        view.delegate = coordinator; view.textStorage.delegate = coordinator
        coordinator.applyExternalState(to: view)
        view.insertText("x"); view.insertText("\n")
        view.setMarkedText("가", selectedRange: NSRange(location: 1, length: 0)); view.unmarkText()
        XCTAssertTrue(sources.contains(.key), String(describing: sources))
        XCTAssertTrue(sources.contains(.enter), String(describing: sources))
        XCTAssertTrue(sources.contains(.ime), String(describing: sources))
        XCTAssertNil(view.boundaryInputSource)
        view.text = "외부에서 바뀐 합성 본문"; coordinator.textViewDidChange(view)
        XCTAssertEqual(sources.last, .other)
        var saveCommands = 0; view.onEditorCommand = { if $0 == .save { saveCommands += 1 } }
        let command = try XCTUnwrap(view.keyCommands?.first { $0.input == "s" && $0.modifierFlags == .command })
        _ = view.perform(command.action, with: command)
        XCTAssertEqual(saveCommands, 1)
    }
}

private actor IntegratedCycleLatch {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseFirst() async {
        guard !entered else { return }; entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func didEnter() -> Bool { entered }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private struct IntegratedReservationCheckingAuth: AuthenticationServicing {
    let journal: IntegratedEditorJournal
    let succeeds: Bool
    let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    func currentState() async -> AuthenticationState { .signedOut(.userInitiated) }
    func generalValidationBearer() async throws -> String {
        XCTAssertEqual(journal.state().empty_cycles_used, 1)
        return "Bearer isolated-test-token"
    }
    func restoreSession() async -> AuthenticationState {
        XCTAssertEqual(journal.state().empty_cycles_used, 1)
        XCTAssertNotNil(IntegratedEditorAuthority.current)
        do { try journal.reserve(kind: "auth") } catch { XCTFail("synthetic auth reservation") }
        return succeeds ? .authenticated(.init(userID: journal.state().execution!.accountID, maskedEmail: nil)) : .signedOut(.userInitiated)
    }
    func refreshSession(force: Bool) async -> AuthenticationState { await restoreSession() }
    func signIn(email: String, password: String) async -> AuthenticationState { await restoreSession() }
    func signOut() async -> AuthenticationState { .signedOut(.userInitiated) }
}
extension IntegratedEditorTests {
    func testFirstAuthenticationEntryAlreadyHasDurableEmptyReservationIncludingFailure() async throws {
        for succeeds in [true, false] {
            let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
            let backend = await IntegratedEditorBackend(store: f.store, journal: f.journal,
                auth: IntegratedReservationCheckingAuth(journal: f.journal, succeeds: succeeds), configuration: f.backend.configuration,
                bindingEpoch: .init(), projectEpoch: .init(), makePuller: f.backend.makePuller)
            try f.journal.setAutomatic(true)
            do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await backend.runCycle(automatic: true) }; XCTAssertTrue(succeeds) }
            catch { XCTAssertFalse(succeeds) }
            let reopened = try IntegratedEditorJournal(root: f.journal.root)
            XCTAssertEqual(reopened.state().empty_cycles_used, 1); XCTAssertEqual(reopened.state().usedAuthentication, 1)
            let calls = await f.wire.calls; XCTAssertEqual(calls, succeeds ? 5 : 0)
        }
    }
    func testBusyAndDeniedAuthorizationDoNotReserveAnExtraAutomaticCycle() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try f.journal.setAutomatic(true)
        let denied = ReceiveValidationPolicy(enabled: true, configuration: nil)
        do { try await ReceiveValidationPolicy.$override.withValue(denied) { try await f.backend.runCycle(automatic: true) }; XCTFail("permission") } catch {}
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        let latch = IntegratedCycleLatch(), wire = f.wire
        let policy = ReceiveValidationPolicy(enabled: true,
            configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: f.journal.state().execution!.accountID),
            network: { request in await latch.pauseFirst(); return try await wire.exchange(request) })
        let first = Task { try await ReceiveValidationPolicy.$override.withValue(policy) { try await f.backend.runCycle(automatic: true) } }
        for _ in 0..<200 {
            if await latch.didEnter() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let entered = await latch.didEnter(); XCTAssertTrue(entered)
        do { try await ReceiveValidationPolicy.$override.withValue(policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("busy") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .locked) }
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
        await latch.release(); try await first.value
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
        let calls = await wire.calls; XCTAssertEqual(calls, 5)
    }
}

extension IntegratedEditorTests {
    func testKnownWireConflictBlocksBeforeAuthEvenWhenSnapshotPreservationWasInterrupted() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try await save(f, id: f.first, text: "중단 원본\n")
        await f.wire.configure(lost: true)
        do { try await cycle(f); XCTFail("lost") } catch {}
        try f.journal.update("syntheticInterruptedConflictPreservation") { $0.wires[0].phase = .conflict }
        XCTAssertTrue(f.journal.state().conflicts.isEmpty)
        try f.journal.setAutomatic(true)
        let used = f.journal.state().usedRequests, calls = await f.wire.calls
        do { try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.runCycle(automatic: true) }; XCTFail("known conflict") }
        catch { XCTAssertEqual(error as? IntegratedEditorError, .conflict) }
        XCTAssertEqual(f.journal.state().usedRequests, used); XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        let after = await f.wire.calls; XCTAssertEqual(after, calls)
        XCTAssertEqual(f.journal.state().sources.count, 1)
    }
}

// Joint Windows/iPad draft-state review: UI scheduler and backend are distinct entry points.
// Every request below is served by the synthetic fixture, never a live server.
extension IntegratedEditorTests {
    func testJointCleanSchedulerActuallyStartsAndReservesOneEmptyCycle() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try f.journal.setAutomatic(true)
        await ReceiveValidationPolicy.$override.withValue(f.policy) {
            f.session.setConnected(true)
            for _ in 0..<500 {
                if f.session.prepared || !f.session.automatic { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            f.session.setConnected(false)
        }
        XCTAssertTrue(f.session.prepared, f.session.message)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
        let calls = await f.wire.calls
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(f.journal.state().usedRequests, 5)
        XCTAssertTrue(f.journal.state().sources.isEmpty)
    }

    func testJointSchedulerWaitsOnDirtyOrComposingEditorWithoutReservation() async throws {
        for mode in ["dirty", "composition"] {
            let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
            await f.session.select(.init(rawValue: f.first))
            let editor = try XCTUnwrap(f.session.editor)
            editor.updateAutosaveDelay(.seconds(300))
            if mode == "dirty" { editor.updateText("共同 시험 e\u{301}🙂\n", source: .paste) }
            else { _ = editor.recordCompositionState(true) }
            try f.journal.setAutomatic(true)
            let before = f.journal.state(), head = f.journal.headSHA256
            let unexpectedHTTP = expectation(description: "No scheduled HTTP for " + mode)
            unexpectedHTTP.isInverted = true
            let wire = f.wire
            let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
                endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: before.execution!.accountID), network: { request in
                    unexpectedHTTP.fulfill()
                    return try await wire.exchange(request)
                })
            await ReceiveValidationPolicy.$override.withValue(policy) {
                f.session.setConnected(true)
                // Cross the production scheduler's 400 ms delay. A separate positive-control test
                // proves a clean fixture reaches transport through this same scheduler entry.
                await fulfillment(of: [unexpectedHTTP], timeout: 1.0)
                f.session.setConnected(false)
            }
            XCTAssertEqual(f.journal.headSHA256, head, mode)
            XCTAssertEqual(f.journal.state().empty_cycles_used, 0, mode)
            XCTAssertEqual(f.journal.state().usedRequests, 0, mode)
            XCTAssertTrue(f.journal.state().sources.isEmpty, mode)
            XCTAssertEqual(f.journal.state().drafts[f.first]?.text, before.drafts[f.first]?.text, mode)
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")), Data("초기\n".utf8), mode)
        }
    }

    func testJointSavedUnqueuedSourceExcludesEmptyChargeButAllowsPreparationHTTP() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        try await save(f, id: f.first, text: "저장됐지만 큐 미등록\n")
        let source = try XCTUnwrap(f.journal.state().sources.first)
        XCTAssertFalse(source.enqueued)
        let queueBefore = try await f.store.generalQueueStatus(localProjectID: IntegratedEditorPlan.local)
        XCTAssertEqual(queueBefore.pendingCount, 0)
        try f.journal.setAutomatic(true)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.prepare(automatic: true) }
        let calls = await f.wire.calls, writes = await f.wire.writes
        XCTAssertEqual(calls, 2) // Synthetic handshake and active-project check.
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        XCTAssertEqual(f.journal.state().usedRequests, 2)
        XCTAssertEqual(f.journal.state().sources.count, 1)
        let after = try XCTUnwrap(f.journal.state().sources.first)
        XCTAssertFalse(after.enqueued)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(after), try encoder.encode(source))
    }

    func testJointDirectBackendPreparationDoesNotProvideUISchedulerDraftGuard() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        await f.session.select(.init(rawValue: f.first))
        let editor = try XCTUnwrap(f.session.editor)
        editor.updateAutosaveDelay(.seconds(300))
        editor.updateText("미저장 진입 경계 확인\n", source: .key)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertTrue(f.journal.state().sources.isEmpty)
        try f.journal.setAutomatic(true)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) { try await f.backend.prepare(automatic: true) }
        let calls = await f.wire.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 1)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(f.journal.state().drafts[f.first]?.text, "미저장 진입 경계 확인\n")
        XCTAssertTrue(f.journal.state().sources.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")), Data("초기\n".utf8))
    }
}

extension IntegratedEditorTests {
    /// Fail the actual journal open beneath preserveDraft, using only this fixture's
    /// temporary directory. Restore the healthy journal before any scheduler runs.
    private func failJointDraftWrite(_ f: Fixture, editor: EditorSessionModel, text: String) throws {
        let journal = f.journal.root
        let retained = f.root.appendingPathComponent("retained-journal-" + UUID().uuidString)
        let head = f.journal.headSHA256
        try FileManager.default.moveItem(at: journal, to: retained)
        defer {
            try? FileManager.default.removeItem(at: journal)
            try? FileManager.default.moveItem(at: retained, to: journal)
        }
        try Data("synthetic non-directory write fault".utf8).write(to: journal)
        editor.updateText(text, source: .paste)
        XCTAssertNotNil(editor.draftPersistenceError)
        XCTAssertEqual(Data(editor.currentText.utf8), Data(text.utf8))
        XCTAssertEqual(f.journal.headSHA256, head)
    }

    private func assertJointDraftErrorWaits(_ f: Fixture, editor: EditorSessionModel) async throws {
        XCTAssertNotNil(editor.draftPersistenceError)
        XCTAssertFalse(editor.isComposing)
        // Other guards are open, and the journal is writable again. Failure state
        // must prevent dispatch, not fail a later HTTP reservation or forced save.
        try f.journal.setAutomatic(true)
        XCTAssertTrue(f.session.automatic)
        let head = f.journal.headSHA256
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let beforeState = f.journal.state()
        let before = try encoder.encode(beforeState)
        let text = Data(editor.currentText.utf8)
        let file = f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")
        let bytes = try Data(contentsOf: file)
        let unexpectedHTTP = expectation(description: "J04 must wait before transport")
        unexpectedHTTP.isInverted = true
        let wire = f.wire
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: f.journal.state().execution!.accountID), network: { request in
                unexpectedHTTP.fulfill()
                return try await wire.exchange(request)
            })
        await ReceiveValidationPolicy.$override.withValue(policy) {
            f.session.setConnected(true)
            await fulfillment(of: [unexpectedHTTP], timeout: 1.0)
            f.session.setConnected(false)
        }
        XCTAssertTrue(f.session.automatic)
        XCTAssertFalse(f.session.busy)
        XCTAssertFalse(f.session.prepared)
        XCTAssertEqual(f.journal.headSHA256, head)
        XCTAssertEqual(try encoder.encode(f.journal.state()), before)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(Data(editor.currentText.utf8), text)
        XCTAssertNotNil(editor.draftPersistenceError)
        XCTAssertEqual(f.journal.state().empty_cycles_used, 0)
        XCTAssertEqual(f.journal.state().usedRequests, 0)
        XCTAssertEqual(f.journal.state().usedAuthentication, 0)
        XCTAssertEqual(f.journal.state().usedWrites, 0)
        let calls = await wire.calls
        XCTAssertEqual(calls, 0)
        let reopened = try IntegratedEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.headSHA256, head)
        // Set iteration order may change during decoding. Compare those fields as
        // sets, then compare all remaining data without normalizing manuscript bytes.
        var restored = reopened.state(), expected = beforeState
        XCTAssertEqual(restored.members, expected.members)
        XCTAssertEqual(restored.checkpoints, expected.checkpoints)
        restored.members = []; expected.members = []
        restored.checkpoints = []; expected.checkpoints = []
        XCTAssertEqual(try encoder.encode(restored), try encoder.encode(expected))
    }

    func testJointJ04DirtyDraftWriteFailurePreservesOriginalAndRecoversOnNextInput() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        await f.session.select(.init(rawValue: f.first))
        let editor = try XCTUnwrap(f.session.editor)
        editor.updateAutosaveDelay(.seconds(300))
        let retained = "기록된 초안 e\u{301}🙂\n"
        editor.updateText(retained, source: .key)
        XCTAssertNil(editor.draftPersistenceError)
        try failJointDraftWrite(f, editor: editor, text: "메모리에만 남은 후속 초안  \n")
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(Data(try XCTUnwrap(f.journal.state().drafts[f.first]).text.utf8), Data(retained.utf8))
        XCTAssertTrue(f.journal.state().sources.isEmpty)
        XCTAssertTrue(f.journal.state().wires.isEmpty)
        try await assertJointDraftErrorWaits(f, editor: editor)
        let recovered = "다음 입력 기록 성공 e\u{301}🙂\n\n"
        editor.updateText(recovered, source: .key)
        XCTAssertNil(editor.draftPersistenceError)
        XCTAssertTrue(editor.hasUnsavedChanges) // Persistence recovery itself does not save TXT.
        XCTAssertEqual(Data(try XCTUnwrap(f.journal.state().drafts[f.first]).text.utf8), Data(recovered.utf8))
        XCTAssertTrue(f.journal.state().sources.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")), Data("초기\n".utf8))
        XCTAssertEqual(f.journal.state().usedRequests, 0)
    }

    func testJointJ04CleanAfterOrdinaryAutosaveStillWaitsOnDraftWriteError() async throws {
        let f = try await fixture(automaticPolicy: .init(maxEmptyCycles: 2))
        await f.session.select(.init(rawValue: f.first))
        let editor = try XCTUnwrap(f.session.editor)
        editor.updateAutosaveDelay(.milliseconds(80))
        let text = "실패 뒤 정상 자동 저장 e\u{301}🙂\n"
        try failJointDraftWrite(f, editor: editor, text: text)
        XCTAssertTrue(editor.hasUnsavedChanges)
        // Let the ordinary editor autosave finish while connectivity is false.
        // No manual clean-state override, forced synchronization save or error setter.
        for _ in 0..<300 {
            if !editor.hasUnsavedChanges { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertNotNil(editor.draftPersistenceError)
        XCTAssertNil(editor.boundaryDiagnosticError)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(IntegratedEditorPlan.rootPath + "/첫째.txt")), Data(text.utf8))
        XCTAssertEqual(f.journal.state().sources.count, 1)
        XCTAssertFalse(try XCTUnwrap(f.journal.state().sources.first).enqueued)
        try await assertJointDraftErrorWaits(f, editor: editor)
    }
}
