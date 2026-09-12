import CryptoKit
import Foundation
import SQLite3
import Supabase
import SwiftData
import XCTest
@testable import WriterPad

final class BodyValidationServiceTests: XCTestCase {
    func testReceiveThenComparedSaveAndSendPreservesOtherQueuesAndOldMarker() async throws {
        let f = try await BodyFixture.make()
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), BodyValidationPlan.incoming)
            try await f.service.run(send: true, foreground: true)
            XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), BodyValidationPlan.outgoing)
            let state = try await f.store.snapshotState(localProjectID: BodyValidationPlan.local,
                serverProjectID: BodyValidationPlan.project, documentID: BodyValidationPlan.document)
            XCTAssertEqual(state?.serverRevision, 3)
            XCTAssertEqual(state?.serverPath, BodyValidationPlan.path)
            XCTAssertEqual(state?.hasActiveOperation, false)
            // Completed history prevents a second operation after a double click or retry.
            do { try await f.service.run(send: true, foreground: true); XCTFail() } catch {}
            do { try await f.service.run(send: false, foreground: true); XCTFail() } catch {}
            XCTAssertFalse(f.policy.sendingAllowed)
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, ["acquire_edit_lease", "commit_document", "release_edit_lease"])
        XCTAssertEqual(try f.otherRows(), before)
        XCTAssertEqual(try Data(contentsOf: f.marker), f.markerBytes)
        XCTAssertEqual(try Data(contentsOf: f.otherBody), Data("다른 작품 합성 원고 · 보존\n".utf8))
        let otherMetadata = try await f.repository.documents(in: f.otherProject)
        XCTAssertEqual(otherMetadata, [f.otherNode])
        XCTAssertEqual(try f.targetStatus(), "completed")
    }
    func testFailedComparedSaveNeverClaimsOrSendsAndPreservesOtherQueues() async throws {
        let f = try await BodyFixture.make(failMetadata: true)
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            do { try await f.service.run(send: true, foreground: true); XCTFail() } catch {}
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(try f.targetStatus(), "")
        XCTAssertEqual(try f.otherRows(), before)
        XCTAssertEqual(try Data(contentsOf: f.marker), f.markerBytes)
        // TXT was saved but metadata failed: keep the real local save recovery marker.
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), BodyValidationPlan.outgoing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.workspace.path)
            .contains(where: { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) }))
    }
    func testLostCommitResponseRetainsSameInflightOperationAndStopsAutomaticRetry() async throws {
        let f = try await BodyFixture.make(loseCommit: true)
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            do { try await f.service.run(send: true, foreground: true); XCTFail() } catch {}
            do { try await f.service.run(send: true, foreground: true); XCTFail() } catch {}
            do { _ = try await f.store.claimBodyValidation(); XCTFail() } catch {}
            do { try await f.store.recoverInterruptedWork(); XCTFail() } catch {}
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, ["acquire_edit_lease", "commit_document"])
        XCTAssertEqual(try f.targetStatus(), "inflight")
        XCTAssertEqual(try f.otherRows(), before)
        XCTAssertEqual(try Data(contentsOf: f.marker), f.markerBytes)
    }
    func testIDBasedModeAndUnexpectedRemoteRevisionStopBeforeLocalMutation() async throws {
        for mode in [SyncV2ProjectSyncMode.idBased, .legacy] {
            let f = try await BodyFixture.make(mode: mode, remoteRevision: mode == .legacy ? 4 : 2)
            addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
            let before = try f.otherRows()
            try await ReceiveValidationPolicy.$override.withValue(f.policy) {
                do { try await f.service.run(send: false, foreground: true); XCTFail() } catch {}
            }
            let calls = await f.network.calls
            XCTAssertEqual(calls, [])
            XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), BodyValidationPlan.baseline)
            XCTAssertEqual(try f.targetStatus(), "")
            XCTAssertEqual(try f.otherRows(), before)
        }
    }
    func testBackgroundDuringCommitRejectsLateResponseAndDuplicateRun() async throws {
        let f = try await BodyFixture.make(pauseCommit: true)
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            let task = Task { try await f.service.run(send: true, foreground: true) }
            for _ in 0..<200 {
                if await f.network.calls.contains("commit_document") { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            do { try await f.service.run(send: true, foreground: true); XCTFail("duplicate run") } catch {}
            f.policy.invalidate(); task.cancel(); await f.network.release()
            do { try await task.value; XCTFail("late response completed") } catch {}
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, ["acquire_edit_lease", "commit_document"])
        XCTAssertEqual(try f.targetStatus(), "inflight")
        XCTAssertEqual(try f.otherRows(), before)
        XCTAssertEqual(try Data(contentsOf: f.marker), f.markerBytes)
    }
    func testDatabaseCompletionFailureRollsBackJournalAfterServerResponse() async throws {
        let f = try await BodyFixture.make()
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            try bodySQL(f.database, "CREATE TRIGGER synthetic_fail_completion BEFORE UPDATE ON sync_documents WHEN NEW.server_revision=3 BEGIN SELECT RAISE(ABORT, 'synthetic save failure'); END")
            do { try await f.service.run(send: true, foreground: true); XCTFail() } catch {}
            let state = try await f.store.snapshotState(localProjectID: BodyValidationPlan.local,
                serverProjectID: BodyValidationPlan.project, documentID: BodyValidationPlan.document)
            XCTAssertEqual(state?.serverRevision, 2)
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, ["acquire_edit_lease", "commit_document"])
        XCTAssertEqual(try f.targetStatus(), "inflight")
        XCTAssertEqual(try f.otherRows(), before)
    }
    func testLiveSDKCommitAndLeaseUseSameGrantAndFinalHTTPBoundary() async throws {
        let f = try await BodyFixture.make(useSDK: true)
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
            try await f.service.run(send: true, foreground: true)
        }
        let calls = await f.network.calls
        XCTAssertEqual(calls, ["acquire_edit_lease", "commit_document", "release_edit_lease"])
        XCTAssertEqual(try f.targetStatus(), "completed")
    }
    func testNonTargetEnqueueAndGlobalRecoveryAreDeniedEvenInsideScope() async throws {
        let f = try await BodyFixture.make()
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        let before = try f.otherRows()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.policy.withBodyValidation(binding: f.binding, device: f.device, foreground: true,
                epochIsCurrent: { true }) {
                try f.policy.bodyPhase(.save)
                let bad = LocalMutationBatch(batchID: UUID(), projectID: f.otherProject, localTransactionID: nil,
                    kind: .documentSave, mutations: [.documentSnapshot(operationID: UUID(), documentID: DocumentID(rawValue: UUID()),
                        relativePath: .init(rawValue: "메인/원고/other.txt"), content: "synthetic", contentHash: SHA256ContentHasher().sha256(for: Data("synthetic".utf8)), localSaveGeneration: 1, isDeleted: false)])
                let recorded = await f.store.record(bad)
                if case .queued = recorded { XCTFail() }
                do { try await f.store.recoverInterruptedWork(); XCTFail() } catch {}
                do { _ = try await f.store.claimReadyOperations(localProjectID: f.otherProject, limit: 3, now: Date()); XCTFail() } catch {}
            }
        }
        XCTAssertEqual(try f.otherRows(), before)
    }
    func testSnapshotRejectsChangedOrMissingFoldersBeforeAnyApplication() async throws {
        try await assertSnapshotRejected([.folderName, .folderParent, .folderRevision, .folderDeleted, .folderMissing, .folderExtra, .folderDuplicate])
    }
    func testSnapshotRejectsChangedControlBeforeAnyApplication() async throws {
        try await assertSnapshotRejected([.controlContent, .controlRevision, .controlMissing, .controlUUID, .controlPath, .controlNullable, .controlDeleted])
    }
    func testSnapshotRejectsUnexpectedDocumentsAndBodyFieldsBeforeAnyApplication() async throws {
        try await assertSnapshotRejected([.extraDocument, .duplicateDocument, .bodyContent, .bodyRevision, .bodyPath, .bodyNullable, .bodyDeleted])
    }
    func testSnapshotRejectsTreeOrdersAndReadFailuresBeforeAnyApplication() async throws {
        try await assertSnapshotRejected([.treeOrder, .documentsFailure, .foldersFailure, .ordersFailure])
    }
    func testSnapshotRejectsChangeAfterPreliminaryBodyCheck() async throws {
        try await assertSnapshotRejected([.changedBetweenPrecheckAndCapture])
    }
    func testValidatedSnapshotIsReusedWithoutLiveHydrationOrSecondFetch() async throws {
        let f = try await BodyFixture.make(fault: .changedAfterCapture)
        addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.service.run(send: false, foreground: true)
        }
        let reads = await f.snapshot.fullDocumentReads, hydration = await f.snapshot.liveHydrationReads
        XCTAssertEqual(reads, 1); XCTAssertEqual(hydration, 0)
        XCTAssertEqual(try Data(contentsOf: f.body), Data(BodyValidationPlan.incoming.utf8))
        let control = try await f.store.snapshotState(localProjectID: BodyValidationPlan.local,
            serverProjectID: BodyValidationPlan.project, documentID: BodyValidationSnapshot.control)
        XCTAssertEqual(control?.serverRevision, 1)
        let calls = await f.network.calls; XCTAssertEqual(calls, [])
    }
    private func assertSnapshotRejected(_ faults: [BodySnapshot.Fault]) async throws {
        for fault in faults {
            let f = try await BodyFixture.make(fault: fault)
            addTeardownBlock { [root = f.root] in try? FileManager.default.removeItem(at: root) }
            let rows = try f.allSyncRows(), files = try f.workspaceBytes()
            let metadata = try await f.repository.documents(in: BodyValidationPlan.local)
            let otherMetadata = try await f.repository.documents(in: f.otherProject)
            try await ReceiveValidationPolicy.$override.withValue(f.policy) {
                do { try await f.service.run(send: false, foreground: true); XCTFail("accepted \(fault)") } catch {}
            }
            let calls = await f.network.calls
            XCTAssertEqual(calls, [], fault.rawValue)
            XCTAssertEqual(try f.allSyncRows(), rows, fault.rawValue)
            XCTAssertEqual(try f.workspaceBytes(), files, fault.rawValue)
            let after = try await f.repository.documents(in: BodyValidationPlan.local)
            let otherAfter = try await f.repository.documents(in: f.otherProject)
            XCTAssertEqual(after, metadata, fault.rawValue); XCTAssertEqual(otherAfter, otherMetadata, fault.rawValue)
            XCTAssertEqual(try Data(contentsOf: f.otherBody), Data("다른 작품 합성 원고 · 보존\n".utf8))
        }
    }

}

private struct BodyFixture {
    let root: URL, workspace: URL, body: URL, marker: URL, database: URL
    let markerBytes: Data
    let policy: ReceiveValidationPolicy
    let store: LazySyncV2ProjectBindingStore
    let service: BodyValidationService
    let network: BodyTestNetwork
    let snapshot: BodySnapshot
    let binding: ProjectSyncBinding
    let device: UUID
    let otherProject: ProjectID
    let otherBody: URL
    let repository: SwiftDataMetadataRepository
    let otherNode: DocumentNode
    static func make(failMetadata: Bool = false, loseCommit: Bool = false, pauseCommit: Bool = false,
                     useSDK: Bool = false, mode: SyncV2ProjectSyncMode = .legacy, remoteRevision: Int64 = 2, fault: BodySnapshot.Fault? = nil) async throws -> BodyFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("body-validation-\(UUID())")
        let workspace = root.appendingPathComponent("workspace"), database = root.appendingPathComponent("sync.sqlite3")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("메인/원고/1권"), withIntermediateDirectories: true)
        let body = workspace.appendingPathComponent(BodyValidationPlan.path)
        try Data(BodyValidationPlan.baseline.utf8).write(to: body)
        let marker = workspace.appendingPathComponent(".writerpad-sync-merge-6df5660a-c1ae-492f-bb1d-26b582508074.json")
        let markerBytes = Data("{\"synthetic\":\"old control UUID marker is opaque to body validation\"}".utf8)
        try markerBytes.write(to: marker)
        let account = UUID(), device = UUID(), other = ProjectID(rawValue: UUID()), now = Date()
        let binding = ProjectSyncBinding.connected(localProjectID: BodyValidationPlan.local, serverProjectID: BodyValidationPlan.project,
            kind: .existingServerProject, projectName: "synthetic", ownerSubject: account)
        let identity = BodyIdentity(id: DeviceIdentifier(uuid: device))
        let coordinator = SyncV2ProjectUploadPullCoordinator()
        let store = LazySyncV2ProjectBindingStore(databaseURL: database, deviceIdentityProvider: identity,
                                                uploadPullCoordinator: coordinator)
        try await store.save(binding)
        try await store.save(.connected(localProjectID: other, serverProjectID: UUID(), kind: .existingServerProject,
                                       projectName: "other synthetic", ownerSubject: account))
        let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: true))
        try await repository.save(Project(id: BodyValidationPlan.local, name: "synthetic", createdAt: now, modifiedAt: now))
        let otherBody = root.appendingPathComponent("other-synthetic.txt")
        let otherBytes = Data("다른 작품 합성 원고 · 보존\n".utf8)
        try otherBytes.write(to: otherBody)
        try await repository.save(Project(id: other, name: "other synthetic", createdAt: now, modifiedAt: now))
        let otherNode = DocumentNode(id: DocumentID(rawValue: UUID()), projectID: other, kind: .text,
            parentID: nil, relativePath: .init(rawValue: "other-synthetic.txt"), userOrder: 3, modifiedAt: now,
            contentHash: SHA256ContentHasher().sha256(for: otherBytes))
        try await repository.save(otherNode)
        let folders = BodyValidationSnapshot.expectedFolders
        func path(_ id: UUID) -> String {
            let folder = folders.first { $0.folderID == id }!
            return folder.parentFolderID.map { path($0) + "/" + folder.name } ?? folder.name
        }
        for folder in folders.sorted(by: { path($0.folderID).split(separator: "/").count < path($1.folderID).split(separator: "/").count }) {
            let relative = path(folder.folderID)
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent(relative), withIntermediateDirectories: true)
            try await repository.save(DocumentNode(id: DocumentID(rawValue: folder.folderID), projectID: BodyValidationPlan.local, kind: .folder,
                parentID: folder.parentFolderID.map(DocumentID.init(rawValue:)), relativePath: .init(rawValue: relative), userOrder: 0,
                modifiedAt: now, contentHash: nil))
        }
        let parent = DocumentID(rawValue: UUID(uuidString: "1de12e60-f998-48b9-aae9-7675b4b42fb9")!)
        try await store.applyFolderSnapshotBaselines(localProjectID: BodyValidationPlan.local,
            serverProjectID: BodyValidationPlan.project, folders: folders, excluding: [])
        _ = try await store.applySnapshotBaseline(localProjectID: BodyValidationPlan.local,
            serverProjectID: BodyValidationPlan.project, snapshot: BodySnapshot.controlRow(), expectedRevision: nil)
        try await repository.save(DocumentNode(id: DocumentID(rawValue: BodyValidationPlan.document), projectID: BodyValidationPlan.local,
            kind: .text, parentID: parent, relativePath: .init(rawValue: BodyValidationPlan.path), userOrder: 0, modifiedAt: now,
            contentHash: SHA256ContentHasher().sha256(for: Data(BodyValidationPlan.baseline.utf8))))
        _ = try await store.applySnapshotBaseline(localProjectID: BodyValidationPlan.local, serverProjectID: BodyValidationPlan.project,
            snapshot: .init(documentID: BodyValidationPlan.document, relativePath: BodyValidationPlan.path,
                content: BodyValidationPlan.baseline, revision: 1, isDeleted: false, deletedAt: nil, updatedAt: now), expectedRevision: nil)
        for i in 0..<7 {
            let batch = LocalMutationBatch(batchID: UUID(), projectID: other, localTransactionID: nil, kind: .documentSave,
                mutations: [.documentSnapshot(operationID: UUID(), documentID: DocumentID(rawValue: UUID()),
                    relativePath: .init(rawValue: "메인/원고/other\(i).txt"), content: "synthetic \(i)",
                    contentHash: SHA256ContentHasher().sha256(for: Data("synthetic \(i)".utf8)), localSaveGeneration: 1, isDeleted: false)])
            let result = await store.record(batch)
            guard case .queued = result else { throw BodyValidationService.Failure.incompleteSave }
        }
        try bodySQL(database, "UPDATE sync_operations SET status='conflict' WHERE queue_id IN (SELECT queue_id FROM sync_operations ORDER BY queue_id LIMIT 3)")
        let network = BodyTestNetwork(loseCommit: loseCommit, pauseCommit: pauseCommit)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: account), network: { try await network.send($0) },
            bodyValidationEnabled: true)
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(account, ticket: ticket)
        let locator = FixedWorkspaceLocator(root: workspace)
        let local = LocalDocumentStore(workspaceLocator: locator,
            metadataUpdater: failMetadata ? RecordingMetadataUpdater(shouldFail: true) : repository,
            durableChangeRecorder: store)
        let snapshot = BodySnapshot(folders: folders, revision: remoteRevision, fault: fault)
        let puller = SyncV2SnapshotPullService(client: snapshot, stateStore: store,
            localApplier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: locator),
            mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
            folderApplier: SyncV2RemoteFolderApplier(documentRepository: repository, workspaceLocator: locator), folderDocuments: repository)
        let transport = BodyTestTransport()
        let config = SupabasePublicConfiguration(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "synthetic-public-key")
        let pool = ReceiveValidationSDKClients(configuration: config, policy: policy)
        let sdk = try pool.client(ticket: ticket)
        let commitClient = useSDK ? SyncV2Client(transport: LiveSyncV2CommitTransport(client: sdk, receiveClients: pool)) : SyncV2Client(transport: transport)
        let leaseClient = useSDK ? EditLeaseClient(transport: LiveEditLeaseTransport(client: sdk, receiveClients: pool)) : EditLeaseClient(transport: transport)
        let service = BodyValidationService(store: store, documents: repository, local: local, puller: puller, snapshot: snapshot,
            commit: commitClient, lease: leaseClient,
            handshake: BodyHandshake(mode: mode), auth: BodyAuth(account: account), identity: identity,
            coordinator: coordinator, bindingEpoch: SyncV2ContractEpoch())
        return .init(root: root, workspace: workspace, body: body, marker: marker, database: database,
            markerBytes: markerBytes, policy: policy, store: store, service: service, network: network,
            snapshot: snapshot, binding: binding, device: device, otherProject: other, otherBody: otherBody, repository: repository, otherNode: otherNode)
    }
    func allSyncRows() throws -> [String] {
        try bodyRows(database, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'sync_%' ORDER BY name")
            .flatMap { table in try bodyRows(database, "SELECT * FROM \(table) ORDER BY rowid").map { table + ":" + $0 } }
    }
    func workspaceBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(workspace.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
    func targetStatus() throws -> String {
        try bodyRows(database, "SELECT status FROM sync_operations WHERE local_project_id='\(BodyValidationPlan.project.uuidString.lowercased())'").joined()
    }
    func otherRows() throws -> [String] {
        let id = otherProject.rawValue.uuidString.lowercased()
        return try ["sync_projects", "sync_documents", "sync_batches", "sync_operations"].flatMap {
            try bodyRows(database, "SELECT * FROM \($0) WHERE local_project_id='\(id)' ORDER BY 1").map { $0 }
        } + bodyRows(database, "SELECT * FROM sync_operation_events WHERE operation_id IN (SELECT operation_id FROM sync_operations WHERE local_project_id='\(id)') ORDER BY 1")
    }
}
private func bodySQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?; guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw BodyValidationService.Failure.unavailable }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BodyValidationService.Failure.unavailable }
}
private func bodyRows(_ url: URL, _ sql: String) throws -> [String] {
    var db: OpaquePointer?, st: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw BodyValidationService.Failure.unavailable }
    defer { sqlite3_finalize(st); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw BodyValidationService.Failure.unavailable }
    var rows: [String] = []
    while sqlite3_step(st) == SQLITE_ROW {
        let columns = (0..<sqlite3_column_count(st)).map { i in sqlite3_column_text(st, i).map { String(cString: $0) } ?? "<NULL>" }
        rows.append(columns.joined(separator: "\u{001f}"))
    }
    return rows
}
private struct BodyIdentity: DeviceIdentityProviding {
    let id: DeviceIdentifier
    func currentState() async -> DeviceIdentityState { .ready(id) }
    func currentIdentifier() async throws -> DeviceIdentifier { id }
    func prepareIdentity() async {}
}
private final class BodyAuth: AuthenticationServicing, @unchecked Sendable {
    let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    let account: UUID
    init(account: UUID) { self.account = account }
    func currentState() async -> AuthenticationState { .authenticated(.init(userID: account, maskedEmail: nil)) }
    func restoreSession() async -> AuthenticationState { await currentState() }
    func refreshSession(force: Bool) async -> AuthenticationState { await currentState() }
    func signIn(email: String, password: String) async -> AuthenticationState { await currentState() }
    func signOut() async -> AuthenticationState { .signedOut(.userInitiated) }
}
private struct BodyHandshake: SyncV2HandshakeTransporting {
    let mode: SyncV2ProjectSyncMode
    func fetchHandshake(parameters: SyncV2HandshakeParameters) async throws -> SyncV2HandshakeResponse {
        .init(supported: true, projectID: parameters.projectID, projectSyncMode: mode, migrationEpoch: 0,
            contractVersion: nil, canonicalContractSHA256: nil, serverContractSHA256: nil, serverProtocolVersion: 3,
            supportedProtocolVersions: [3], serverCapabilities: [])
    }
}
private actor BodySnapshot: SyncV2SnapshotClienting {
    enum Fault: String, CaseIterable {
        case folderName, folderParent, folderRevision, folderDeleted, folderMissing, folderExtra, folderDuplicate
        case controlContent, controlRevision, controlMissing, controlUUID, controlPath, controlNullable, controlDeleted
        case extraDocument, duplicateDocument, bodyContent, bodyRevision, bodyPath, bodyNullable, bodyDeleted
        case treeOrder, documentsFailure, foldersFailure, ordersFailure
        case changedBetweenPrecheckAndCapture, changedAfterCapture
    }
    let folders: [SyncV2RemoteFolder]
    let revision: Int64
    let fault: Fault?
    private(set) var fullDocumentReads = 0
    private(set) var liveHydrationReads = 0
    init(folders: [SyncV2RemoteFolder], revision: Int64, fault: Fault?) {
        self.folders = folders; self.revision = revision; self.fault = fault
    }
    static let controlContent = #"{"tree_order":{"<root>":["메인"],"메인":["원고","캐릭터","설정집","메모장","스토리 플롯","흐름정리","복선","장소","휴지통"],"메인/메모장":[],"메인/복선":[],"메인/설정집":[],"메인/스토리 플롯":[],"메인/원고":["1권"],"메인/원고/1권":["1화.txt"],"메인/장소":[],"메인/캐릭터":[],"메인/흐름정리":[]},"version":1}"#
    static func controlRow() -> SyncV2RemoteDocumentSnapshot {
        .init(documentID: BodyValidationSnapshot.control, relativePath: syncV2TreeOrderPath, content: controlContent,
            revision: 1, isDeleted: false, deletedAt: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func matches(_ faults: [Fault]) -> Bool { fault.map { faults.contains($0) } ?? false }
    func bodyRow() -> SyncV2RemoteDocumentSnapshot {
        .init(documentID: BodyValidationPlan.document, relativePath: BodyValidationPlan.path, content: BodyValidationPlan.incoming,
            revision: revision, isDeleted: false, deletedAt: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }
    func fetchDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2RemoteDocumentSnapshot? { bodyRow() }
    func fetchDocuments(projectID: UUID) async throws -> [SyncV2RemoteDocumentSnapshot] {
        fullDocumentReads += 1
        if fault == .documentsFailure { throw BodyValidationService.Failure.unavailable }
        var rows = [bodyRow(), Self.controlRow()]
        let controlFaults: [Fault] = [.controlContent, .controlRevision, .controlUUID, .controlPath, .controlNullable, .controlDeleted,
            .changedBetweenPrecheckAndCapture]
        let index = fault.map { controlFaults.contains($0) ? 1 : 0 } ?? 0
        let row = rows[index]
        let changedLater = fault == .changedAfterCapture && fullDocumentReads > 1
        rows[index] = .init(documentID: fault == .controlUUID ? UUID() : row.documentID,
            relativePath: matches([.controlPath, .bodyPath]) ? "unexpected.txt" : row.relativePath,
            content: matches([.controlContent, .bodyContent]) || changedLater ? row.content + "changed" : row.content,
            revision: matches([.controlRevision, .bodyRevision, .changedBetweenPrecheckAndCapture]) ? 9 : row.revision,
            isDeleted: matches([.controlDeleted, .bodyDeleted]), deletedAt: nil, updatedAt: row.updatedAt,
            name: matches([.controlNullable, .bodyNullable]) ? "unexpected" : nil)
        if fault == .controlMissing { rows.removeLast() }
        if fault == .duplicateDocument { rows.append(rows[0]) }
        if fault == .extraDocument { rows.append(.init(documentID: UUID(), relativePath: "메인/원고/1권/extra.txt",
            content: "extra", revision: 1, isDeleted: false, deletedAt: nil, updatedAt: Date())) }
        return rows
    }
    func fetchDocumentContents(projectID: UUID, documentIDs: [UUID]) async throws -> [SyncV2RemoteDocumentSnapshot] {
        liveHydrationReads += 1
        // A forbidden re-fetch is observably different from the validated capture.
        return [.init(documentID: BodyValidationPlan.document, relativePath: BodyValidationPlan.path,
            content: "changed after validation", revision: 99, isDeleted: false, deletedAt: nil, updatedAt: Date())]
    }
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] {
        if fault == .foldersFailure { throw BodyValidationService.Failure.unavailable }
        var result = folders
        let f = result[0]
        result[0] = .init(folderID: f.folderID, parentFolderID: fault == .folderParent ? UUID() : f.parentFolderID,
            name: fault == .folderName ? "changed" : f.name, revision: fault == .folderRevision ? 2 : f.revision,
            isDeleted: fault == .folderDeleted, updatedAt: f.updatedAt)
        if fault == .folderMissing { result.removeLast() }
        if fault == .folderDuplicate { result.append(result[0]) }
        if fault == .folderExtra { result.append(.init(folderID: UUID(), parentFolderID: nil, name: "extra",
            revision: 1, isDeleted: false, updatedAt: Date())) }
        return result
    }
    func fetchTreeOrders(projectID: UUID) async throws -> [SyncV2RemoteTreeOrder] {
        if fault == .ordersFailure { throw BodyValidationService.Failure.unavailable }
        return fault == .treeOrder ? [.init(treeOrderID: UUID(), parentFolderID: nil, children: [], revision: 1, updatedAt: Date())] : []
    }
}
private struct BodyTestTransport: SyncV2CommitTransporting, EditLeaseTransporting {
    private func call<P: Encodable, R: Decodable>(_ rpc: String, _ p: P) async throws -> R {
        var request = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/" + rpc)!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(p)
        let session = ReceiveValidationURLProtocol.session()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(R.self, from: data)
    }
    func commitDocument(parameters: SyncV2CommitDocumentParameters) async throws -> SyncV2CommitDocumentResult { try await call("commit_document", parameters) }
    func commitFolder(parameters: SyncV2CommitFolderParameters) async throws -> SyncV2CommitFolderResult { throw BodyValidationService.Failure.unavailable }
    func acquire(_ parameters: AcquireEditLeaseParameters) async throws -> EditLeaseMutationResult { try await call("acquire_edit_lease", parameters) }
    func renew(_ parameters: RenewEditLeaseParameters) async throws -> EditLeaseMutationResult { throw BodyValidationService.Failure.unavailable }
    func release(_ parameters: ReleaseEditLeaseParameters) async throws -> Bool { try await call("release_edit_lease", parameters) }
    func inspect(_ parameters: InspectEditLeaseParameters) async throws -> EditLeaseInspectionResult { throw BodyValidationService.Failure.unavailable }
}
private actor BodyTestNetwork {
    private(set) var calls: [String] = []
    let loseCommit: Bool
    let pauseCommit: Bool
    var pending: CheckedContinuation<Void, Never>?
    let token = UUID()
    init(loseCommit: Bool, pauseCommit: Bool = false) { self.loseCommit = loseCommit; self.pauseCommit = pauseCommit }
    func release() { pending?.resume(); pending = nil }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let rpc = request.url!.lastPathComponent
        calls.append(rpc)
        let p = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let result: Any
        switch rpc {
        case "acquire_edit_lease":
            result = ["document_id": p["p_document_id"]!, "device_id": p["p_device_id"]!,
                "lease_token": token.uuidString, "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))]
        case "release_edit_lease": result = true
        case "commit_document":
            if pauseCommit { await withCheckedContinuation { pending = $0 } }
            if loseCommit { throw URLError(.networkConnectionLost) }
            result = ["status": "committed", "document_id": p["p_document_id"]!, "version_id": UUID().uuidString,
                "operation_id": p["p_operation_id"]!, "operation_kind": "update", "revision": 3,
                "relative_path": BodyValidationPlan.path, "is_deleted": false,
                "content_hash": SHA256ContentHasher().sha256(for: Data(BodyValidationPlan.outgoing.utf8)).rawValue,
                "committed_at": ISO8601DateFormatter().string(from: Date())]
        default: throw BodyValidationService.Failure.unavailable
        }
        return (try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class BodyValidationBuildSelectionTests: XCTestCase {
    func testExplicitBuildSelectionRemainsFailClosedWithoutAccountPolicy() throws {
#if WRITERPAD_BODY_VALIDATION
        XCTAssertTrue(ReceiveValidationPolicy.built.enabled)
        XCTAssertTrue(ReceiveValidationPolicy.built.bodyValidationEnabled)
        XCTAssertFalse(ReceiveValidationPolicy.built.sendingAllowed)
        XCTAssertThrowsError(try ReceiveValidationPolicy.built.authorization())
        XCTAssertThrowsError(try ReceiveValidationPolicy.built.requireSending())
#else
        XCTAssertFalse(ReceiveValidationPolicy.built.bodyValidationEnabled)
#endif
    }
}
