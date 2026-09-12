import Foundation
import SwiftData
import XCTest
import Supabase
@testable import WriterPad

final class ServerProjectCatalogTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }

    func testSameNameDifferentUUIDsRemainSeparateAcrossPages() async throws {
        let h = try harness()
        await h.transport.setRows([row(1), row(2)])
        let catalog = try await h.service().catalog()
        XCTAssertEqual(catalog.entries.map(\.id), [row(1).id, row(2).id])
        XCTAssertEqual(catalog.entries.map(\.state), [.available, .available])
        let reads = await h.transport.pages
        XCTAssertEqual(reads, 3)
    }

    func testSignedOutCatalogDoesNotReadTransport() async throws {
        let h = try harness()
        _ = await h.auth.signOut()
        await expect(.authenticationRequired) { _ = try await h.service().catalog() }
        let reads = await h.transport.pages
        XCTAssertEqual(reads, 0)
    }

    func testAccountChangeDuringListRejectsResponse() async throws {
        let h = try harness()
        await h.transport.setPageHook { await h.auth.changeAccount() }
        await expect(.staleContext) { _ = try await h.service().catalog() }
    }

    func testConnectionChangeDuringListRejectsResponse() async throws {
        let h = try harness()
        await h.transport.setPageHook { h.transport.connection.change() }
        await expect(.staleContext) { _ = try await h.service().catalog() }
    }

    func testMalformedDuplicateUUIDResponseRejected() async throws {
        let h = try harness()
        await h.transport.setRepeats(true)
        await expect(.invalidResponse) { _ = try await h.service().catalog() }
    }

    func testExistingDifferentLocalIDBindingIsImportedAndPreserved() async throws {
        let h = try harness()
        let old = try await h.manager.createProject(named: "기존 작품")
        let binding = ProjectSyncBinding.connected(localProjectID: old.id, serverProjectID: row(1).id,
            kind: .existingServerProject, projectName: old.name, ownerSubject: h.owner)
        try await h.bindings.save(binding)
        let catalog = try await h.service().catalog()
        XCTAssertEqual(catalog.entries.first?.state, .imported)
        await expect(.bindingConflict) { _ = try await h.service().receive(catalog.entries[0], from: catalog, localName: "새 이름") }
        let after = try await h.bindings.binding(for: old.id)
        XCTAssertEqual(after, binding)
    }

    func testOtherAccountBindingShowsConflict() async throws {
        let h = try harness()
        let old = try await h.manager.createProject(named: "기존 작품")
        try await h.bindings.save(.connected(localProjectID: old.id, serverProjectID: row(1).id,
            kind: .existingServerProject, projectName: old.name, ownerSubject: UUID()))
        let catalog = try await h.service().catalog()
        XCTAssertEqual(catalog.entries.first?.state, .conflict)
    }

    func testJournalUsesServerUUIDWithoutDefaultNodesAndIsHidden() async throws {
        let h = try harness()
        let first = try await h.manager.beginReceiving(row(1), localName: "수신 작품", scope: h.scope)
        let restarted = h.newManager()
        let second = try await restarted.beginReceiving(row(1), localName: "수신 작품", scope: h.scope)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.project.id.rawValue, row(1).id)
        XCTAssertEqual(first.localIdentityPolicy, "server_uuid_for_new_project")
        let nodes = try await h.repo.documents(in: first.project.id)
        let visible = try await restarted.projects()
        XCTAssertTrue(nodes.isEmpty)
        XCTAssertTrue(visible.isEmpty)
        let paths = try h.resolver.standardPaths(forProjectNamed: "수신 작품")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.workspaceRootURL.path), [])
    }

    func testExistingNameCollisionPreservesOldProjectAndAllowsLocalAlias() async throws {
        let h = try harness()
        let old = try await h.manager.createProject(named: row(1).name)
        let oldNodes = try await h.repo.documents(in: old.id)
        let service = h.service()
        let source = try await service.catalog()
        await expect(.bindingConflict) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let imported = try await service.receive(source.entries[0], from: source, localName: "별도 로컬 이름")
        XCTAssertEqual(imported.name, "별도 로컬 이름")
        let after = try await h.repo.documents(in: old.id)
        XCTAssertEqual(after, oldNodes)
        let remote = try await h.transport.project(id: row(1).id)
        XCTAssertEqual(remote?.name, row(1).name)
    }

    func testOtherEndpointJournalCannotBeResumed() async throws {
        let h = try harness()
        _ = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        h.transport.connection.change()
        let source = try await h.service().catalog()
        XCTAssertEqual(source.entries[0].state, .conflict)
    }

    func testCorruptJournalFailsClosedWithoutDeletingFiles() async throws {
        let h = try harness()
        let journal = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        let path = h.resolver.projectsRootURL.appendingPathComponent(".writerpad-server-receive-\(row(1).id.uuidString.lowercased()).json")
        let corrupt = Data("{broken identity".utf8)
        try corrupt.write(to: path)
        await expect(.interrupted) { _ = try await h.service().catalog() }
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
        let stored = try await h.repo.project(id: journal.project.id)
        XCTAssertEqual(stored, journal.project)
    }

    func testChangedOwnershipMarkerRejectsResume() async throws {
        let h = try harness()
        let journal = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        let marker = try h.resolver.standardPaths(forProjectNamed: journal.project.name).projectContainerURL
            .appendingPathComponent(".writerpad-server-receive-owner.json")
        try Data("{}".utf8).write(to: marker)
        do { _ = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: marker), Data("{}".utf8))
    }

    func testWorkspaceSymlinkRejectedAndTargetPreserved() async throws {
        let h = try harness()
        let journal = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        let workspace = try h.resolver.standardPaths(forProjectNamed: journal.project.name).workspaceRootURL
        let target = h.root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("synthetic manuscript".utf8).write(to: target.appendingPathComponent("keep.txt"))
        try FileManager.default.removeItem(at: workspace)
        try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: target)
        await expect(.interrupted) { _ = try await h.manager.beginReceiving(self.row(1), localName: self.row(1).name, scope: h.scope) }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("keep.txt"), encoding: .utf8), "synthetic manuscript")
    }

    func testIncompleteSnapshotStaysHiddenAndRetryUsesSameJournal() async throws {
        let h = try harness()
        await h.puller.setReady(false)
        let service = h.service(), source = try await h.service().catalog()
        await expect(.incompleteSnapshot) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let journals = try await h.manager.receivingJournals()
        let visible = try await h.manager.projects()
        XCTAssertTrue(visible.isEmpty)
        let interrupted = try await service.catalog()
        XCTAssertEqual(interrupted.entries[0].state, .interrupted)
        await h.puller.setReady(true)
        let received = try await service.receive(interrupted.entries[0], from: interrupted, localName: row(1).name)
        XCTAssertEqual(received.id, journals[0].project.id)
        let remaining = try await h.manager.receivingJournals()
        XCTAssertTrue(remaining.isEmpty)
        let now = try await service.catalog()
        XCTAssertEqual(now.entries[0].state, .imported)
        let bindings = try await h.bindings.allBindings()
        XCTAssertEqual(bindings.count, 1)
    }

    func testPendingLocalChangesStopBeforePullAndStayHidden() async throws {
        let h = try harness()
        let service = h.service(queue: { _ in false })
        let source = try await service.catalog()
        await expect(.localChanges) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let calls = await h.puller.calls
        XCTAssertEqual(calls, 0)
        let visible = try await h.manager.projects()
        XCTAssertTrue(visible.isEmpty)
    }

    func testAccountChangeDuringPullNeverPublishes() async throws {
        let h = try harness()
        await h.puller.setHook { await h.auth.changeAccount() }
        let service = h.service(), source = try await h.service().catalog()
        await expect(.staleContext) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let visible = try await h.manager.projects()
        let binding = try await h.bindings.binding(for: ProjectID(rawValue: row(1).id))
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(binding?.kind, .existingServerProject)
    }

    func testLateAuthorizationFailureKeepsConnectedBindingHiddenFromSender() async throws {
        let h = try harness()
        let journal = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        try await h.bindings.save(.connected(localProjectID: journal.project.id, serverProjectID: row(1).id,
            kind: .existingServerProject, projectName: journal.project.name, ownerSubject: h.owner))
        await expect(.staleContext) { _ = try await h.manager.finishReceiving(journal, authorized: { false }) }
        let bindingService = SupabaseProjectBindingService(transport: nil, bindingStore: h.bindings,
            projectRepository: h.repo, authenticationService: h.auth,
            bindingIsVisible: { (try? await h.manager.isReceiving($0)) == false })
        let current = await bindingService.currentBinding(for: journal.project.id)
        let connected = await bindingService.connectedBindings()
        let visible = try await h.manager.projects()
        XCTAssertNil(current)
        XCTAssertTrue(connected.isEmpty)
        XCTAssertTrue(visible.isEmpty)
    }

    func testStorageFailureLeavesJournalAndRetryDoesNotCreateSecondProject() async throws {
        let h = try harness()
        let service = h.service(mark: { _ in throw ProjectBindingStoreError.unavailable })
        let source = try await service.catalog()
        do { _ = try await service.receive(source.entries[0], from: source, localName: row(1).name); XCTFail() } catch {}
        let before = try await h.manager.receivingJournals()
        let retry = h.service(), latest = try await h.service().catalog()
        _ = try await retry.receive(latest.entries[0], from: latest, localName: row(1).name)
        let projects = try await h.repo.projects()
        XCTAssertEqual(projects.map(\.id), before.map { $0.project.id })
    }

    func testConcurrentSelectionCreatesOneJournalAndCancellationCanResume() async throws {
        let h = try harness()
        let gate = CatalogTestGate()
        await h.puller.setHook { await gate.wait() }
        let service = h.service(), source = try await h.service().catalog()
        let task = Task { try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        await gate.started()
        await expect(.alreadyRunning) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        let journals = try await h.manager.receivingJournals()
        XCTAssertEqual(journals.count, 1)
        await h.puller.setHook {}
        let retry = try await service.catalog()
        let result = try await service.receive(retry.entries[0], from: retry, localName: row(1).name)
        XCTAssertEqual(result.id, journals[0].project.id)
    }

    func testStaleCatalogCannotBeginImportAfterAccountSwitch() async throws {
        let h = try harness()
        // Use a single context for the stale selection itself.
        let ownService = h.service(), source = try await h.service().catalog()
        await h.auth.changeAccount()
        await expect(.staleContext) { _ = try await ownService.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let journals = try await h.manager.receivingJournals()
        XCTAssertTrue(journals.isEmpty)
    }

    @MainActor
    func testViewModelInvalidationDiscardsInFlightCatalog() async throws {
        let h = try harness()
        let gate = CatalogTestGate()
        await h.transport.setPageHook { await gate.wait() }
        let model = ServerProjectCatalogModel(service: h.service())
        model.refresh()
        await gate.started()
        model.invalidate()
        await gate.release()
        while model.isWorking { await Task.yield() }
        XCTAssertNil(model.snapshot)
    }

    func testRealSnapshotPreservesFolderDocumentOrderUUIDsAndRevisionsWithZeroQueue() async throws {
        try await exerciseRealSnapshot(receiveGuard: false)
    }
    func testReceiveGuardRealSnapshotPreservesExistingManuscriptAndQueue() async throws {
        try await exerciseRealSnapshot(receiveGuard: true)
    }
    private func exerciseRealSnapshot(receiveGuard: Bool) async throws {
        let h = try harness()
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        guard case let .available(store) = await SyncV2Store.open(at: h.root.appendingPathComponent("isolated.sqlite3")) else {
            return XCTFail("isolated database unavailable")
        }
        let old = try await h.manager.createProject(named: "보존할 기존 작품")
        let oldNodes = try await h.repo.documents(in: old.id)
        let workspace = try h.resolver.standardPaths(forProjectNamed: old.name).workspaceRootURL
        let oldBody = Data("합성 기존 원고와 작업 기록".utf8)
        let oldFile = workspace.appendingPathComponent("보존.txt")
        try oldBody.write(to: oldFile)
        let oldServerID = UUID()
        try await store.save(.connected(localProjectID: old.id, serverProjectID: oldServerID,
            kind: .existingServerProject, projectName: old.name, ownerSubject: h.owner))
        try await catalogEnqueueSyntheticWork(store, localID: old.id, serverID: oldServerID)
        let oldQueue = try await store.uploadQueueSnapshot(localProjectID: old.id)
        let fixture = CatalogSnapshotFixture()
        let locator = RepositoryProjectWorkspaceLocator(projectRepository: h.repo, pathResolver: h.resolver)
        let puller = SyncV2SnapshotPullService(client: fixture, stateStore: store,
            localApplier: LocalSyncV2SnapshotApplier(documentRepository: h.repo, workspaceLocator: locator),
            mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
            folderApplier: SyncV2RemoteFolderApplier(documentRepository: h.repo, workspaceLocator: locator),
            folderDocuments: h.repo)
        let service = ServerProjectCatalogService(transport: h.transport, authentication: h.auth,
            receiver: h.manager, projects: h.repo, bindings: store, puller: puller,
            queueIsEmpty: { try await store.receivingQueueIsEmpty($0) },
            markFolderIdentity: { try await store.markFolderMigrationCompleted(localProjectID: $0) })
        let policy = ReceiveValidationPolicy(enabled: receiveGuard, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner))
        if receiveGuard { h.transport.connection.useStagingFixture() }
        try await ReceiveValidationPolicy.$override.withValue(policy) {
        let permit = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(h.owner, ticket: permit)
        let source = try await service.catalog()
        let result = try await service.receive(source.entries[0], from: source, localName: "로컬 수신 이름")
        XCTAssertEqual(result.id.rawValue, row(1).id)
        let nodes = try await h.repo.documents(in: result.id)
        XCTAssertEqual(Set(nodes.map { $0.id.rawValue }), Set(fixture.folders.map(\.folderID) + [fixture.document.documentID]))
        let document = try XCTUnwrap(nodes.first { $0.id.rawValue == fixture.document.documentID })
        XCTAssertEqual(document.parentID?.rawValue, fixture.document.parentFolderID)
        let receivedRoot = try await locator.workspaceRoot(for: result.id)
        XCTAssertEqual(try String(contentsOf: receivedRoot.appendingPathComponent(document.relativePath.rawValue), encoding: .utf8), fixture.document.content)
        let state = try await store.snapshotState(localProjectID: result.id, serverProjectID: row(1).id, documentID: fixture.document.documentID)
        XCTAssertEqual(state?.serverRevision, 7)
        for remote in fixture.orders {
            let stored = try await store.storedTreeOrder(localProjectID: result.id, parentFolderID: remote.parentFolderID)
            XCTAssertEqual(stored?.children, remote.children)
            XCTAssertEqual(stored?.serverRevision, remote.revision)
        }
        let queue = try await store.receivingQueueIsEmpty(result.id)
        XCTAssertTrue(queue)
        let oldAfter = try await h.repo.documents(in: old.id)
        XCTAssertEqual(oldAfter, oldNodes)
        let oldQueueAfter = try await store.uploadQueueSnapshot(localProjectID: old.id)
        XCTAssertEqual(oldQueueAfter, oldQueue)
        XCTAssertEqual(try Data(contentsOf: oldFile), oldBody)
        let spy = CatalogForbiddenWrites()
        let bindingService = SupabaseProjectBindingService(transport: spy, bindingStore: store,
            projectRepository: h.repo, authenticationService: h.auth, initialSyncRecorder: spy,
            bindingIsVisible: { (try? await h.manager.isReceiving($0)) == false })
        let visibleBinding = await bindingService.currentBinding(for: result.id)
        let connected = await bindingService.connectedBindings()
        XCTAssertEqual(visibleBinding?.kind, .existingServerProject)
        XCTAssertEqual(connected.count, 2)
        let writes = await spy.calls
        XCTAssertEqual(writes, 0)
        let clean = try await store.receivingQueueIsEmpty(result.id)
        XCTAssertTrue(clean)
        }
        await store.close()
    }

    func testLiveCatalogTransportUsesOnlyFilteredGETAndRejectsUnauthorizedResponse() async throws {
        CatalogHTTPLog.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SupabaseClient(supabaseURL: URL(string: "https://catalog.invalid")!, supabaseKey: "synthetic-key",
            options: .init(auth: .init(storage: EphemeralAuthLocalStorage(), autoRefreshToken: false,
                accessToken: { "synthetic-token" }), global: .init(session: session)))
        let transport = LiveServerProjectCatalogTransport(client: client, endpointID: "https://catalog.invalid")
        _ = try await transport.page(after: nil)
        _ = try await transport.page(after: row(1).id)
        _ = try await transport.project(id: row(1).id)
        let requests = CatalogHTTPLog.shared.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/rest/v1/projects")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(.init(name: "select", value: "project_id,name")))
            XCTAssertTrue(query.contains(.init(name: "trashed_at", value: "is.NULL")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        }
        let pageQuery = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(pageQuery.contains(.init(name: "project_id", value: "gt.\(row(1).id.uuidString.lowercased())")))
        XCTAssertTrue(pageQuery.contains(.init(name: "limit", value: "200")))
        CatalogHTTPLog.shared.reject()
        do { _ = try await transport.page(after: nil); XCTFail("401 must fail") } catch {}
        XCTAssertTrue(CatalogHTTPLog.shared.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testCompletedReceiveFromDifferentEndpointShowsConflict() async throws {
        let h = try harness()
        let own = h.service(), source = try await h.service().catalog()
        _ = try await own.receive(source.entries[0], from: source, localName: row(1).name)
        h.transport.connection.change()
        let changed = try await own.catalog()
        XCTAssertEqual(changed.entries[0].state, .conflict)
    }

    func testBindingChangedDuringPullIsNotOverwritten() async throws {
        let h = try harness()
        let replacement = ProjectSyncBinding.connected(localProjectID: ProjectID(rawValue: row(1).id),
            serverProjectID: UUID(), kind: .existingServerProject, projectName: "다른 연결", ownerSubject: UUID())
        await h.puller.setHook { try? await h.bindings.save(replacement) }
        let service = h.service(), source = try await h.service().catalog()
        await expect(.bindingConflict) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let after = try await h.bindings.binding(for: replacement.localProjectID)
        XCTAssertEqual(after, replacement)
        let visible = try await h.manager.projects()
        XCTAssertTrue(visible.isEmpty)
    }

    func testMetadataSaveFailureResumesOriginalJournalAfterRestart() async throws {
        let h = try harness()
        let failing = LocalProjectManager(projectRepository: h.repo, creationMetadataStore: CatalogFailedMetadata(),
            workspaceStateRepository: h.repo, pathResolver: h.resolver, clock: SystemClock())
        do { _ = try await failing.beginReceiving(row(1), localName: row(1).name, scope: h.scope); XCTFail() } catch {}
        let first = try await failing.receivingJournals()
        let projectsBefore = try await h.repo.projects()
        XCTAssertTrue(projectsBefore.isEmpty)
        let restarted = try await h.newManager().beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        XCTAssertEqual(first, [restarted])
        let nodes = try await h.repo.documents(in: restarted.project.id)
        XCTAssertTrue(nodes.isEmpty)
    }

    func testPartialReportBoundariesNeverPublish() async throws {
        let variants: [SyncV2SnapshotPullReport] = [
            .init(contractStructureBaselineReady: true, outcomes: [], appliedSnapshots: [],
                rejectedStructureNames: [.init(name: "불가", parent: "메인", reason: "synthetic", kind: .notApplied)]),
            .init(contractStructureBaselineReady: true, outcomes: [], appliedSnapshots: [], pendingChildTombstoneFolderCount: 1),
            .init(contractStructureBaselineReady: true, outcomes: [], appliedSnapshots: [], deferredLocalApplicationCount: 1)
        ]
        for report in variants {
            let h = try harness()
            await h.puller.setReport(report)
            let service = h.service(), source = try await h.service().catalog()
            await expect(.incompleteSnapshot) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
            let visible = try await h.manager.projects()
            XCTAssertTrue(visible.isEmpty)
        }
    }

    func testNewLocalQueueDuringPullPreventsPublication() async throws {
        let h = try harness()
        let predicate = CatalogQueuePredicate()
        await h.puller.setHook { await predicate.setPending() }
        let service = h.service(queue: { _ in await predicate.isEmpty }), source = try await h.service().catalog()
        await expect(.localChanges) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let visible = try await h.manager.projects()
        XCTAssertTrue(visible.isEmpty)
    }

    func testMissingServerSelectionDoesNotCreateJournal() async throws {
        let h = try harness()
        let own = h.service(), source = try await h.service().catalog()
        await h.transport.setRows([])
        await expect(.invalidResponse) { _ = try await own.receive(source.entries[0], from: source, localName: self.row(1).name) }
        let journals = try await h.manager.receivingJournals()
        XCTAssertTrue(journals.isEmpty)
    }

    func testRealStoreRejectsExistingPendingWorkWithoutDuplicatingQueue() async throws {
        let h = try harness()
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        guard case let .available(store) = await SyncV2Store.open(at: h.root.appendingPathComponent("pending.sqlite3")) else { return XCTFail() }
        let journal = try await h.manager.beginReceiving(row(1), localName: row(1).name, scope: h.scope)
        try await store.save(.connected(localProjectID: journal.project.id, serverProjectID: journal.serverProjectID,
            kind: .existingServerProject, projectName: journal.project.name, ownerSubject: h.owner))
        try await catalogEnqueueSyntheticWork(store, localID: journal.project.id, serverID: journal.serverProjectID)
        let before = try await store.uploadQueueSnapshot(localProjectID: journal.project.id)
        let service = ServerProjectCatalogService(transport: h.transport, authentication: h.auth, receiver: h.manager,
            projects: h.repo, bindings: store, puller: h.puller, queueIsEmpty: { try await store.receivingQueueIsEmpty($0) }, markFolderIdentity: { _ in })
        let source = try await service.catalog()
        for _ in 0..<2 {
            await expect(.localChanges) { _ = try await service.receive(source.entries[0], from: source, localName: self.row(1).name) }
        }
        let after = try await store.uploadQueueSnapshot(localProjectID: journal.project.id)
        let calls = await h.puller.calls
        XCTAssertEqual(before, after)
        XCTAssertEqual(calls, 0)
        await store.close()
    }

    private func row(_ n: Int) -> ServerCatalogProject {
        .init(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!, name: "서버 작품")
    }
    private func expect(_ expected: ServerCatalogError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("expected \(expected)") }
        catch { XCTAssertEqual(error as? ServerCatalogError, expected) }
    }
    private func harness() throws -> CatalogHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-test-\(UUID())")
        roots.append(root)
        return try CatalogHarness(root: root, rows: [row(1)])
    }
}

private struct CatalogHarness {
    let root: URL
    let repo: SwiftDataMetadataRepository
    let resolver: ProjectPathResolver
    let manager: LocalProjectManager
    let owner = UUID()
    let auth: CatalogAuth
    let transport: CatalogTransport
    let bindings = InMemoryProjectBindingStore()
    let puller = CatalogPuller()
    var scope: ServerCatalogScope { .init(accountID: owner, endpoint: transport.endpointID, authenticationEpoch: auth.contractEpoch!.value) }
    init(root: URL, rows: [ServerCatalogProject]) throws {
        self.root = root
        repo = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true))
        resolver = ProjectPathResolver(projectsRootURL: root.appendingPathComponent("Projects"))
        manager = LocalProjectManager(projectRepository: repo, creationMetadataStore: repo, workspaceStateRepository: repo, pathResolver: resolver, clock: SystemClock())
        auth = CatalogAuth(owner: owner)
        transport = CatalogTransport(rows: rows)
    }
    func newManager() -> LocalProjectManager {
        LocalProjectManager(projectRepository: repo, creationMetadataStore: repo, workspaceStateRepository: repo, pathResolver: resolver, clock: SystemClock())
    }
    func service(queue: @escaping @Sendable (ProjectID) async throws -> Bool = { _ in true },
                 mark: @escaping @Sendable (ProjectID) async throws -> Void = { _ in }) -> ServerProjectCatalogService {
        ServerProjectCatalogService(transport: transport, authentication: auth, receiver: manager, projects: repo,
            bindings: bindings, puller: puller, queueIsEmpty: queue, markFolderIdentity: mark)
    }
}

private actor CatalogAuth: AuthenticationServicing {
    nonisolated let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    var state: AuthenticationState
    init(owner: UUID) { state = .authenticated(.init(userID: owner, maskedEmail: nil)) }
    func currentState() -> AuthenticationState { state }
    func changeAccount() { contractEpoch?.advance(); state = .authenticated(.init(userID: UUID(), maskedEmail: nil)) }
    func restoreSession() -> AuthenticationState { state }
    func refreshSession(force: Bool) -> AuthenticationState { state }
    func signIn(email: String, password: String) -> AuthenticationState { state }
    func signOut() -> AuthenticationState { contractEpoch?.advance(); state = .signedOut(.userInitiated); return state }
}

private final class CatalogConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "https://catalog.invalid"
    var endpoint: String { lock.withLock { value } }
    func change() { lock.withLock { value = "https://other.invalid" } }
    func useStagingFixture() { lock.withLock { value = ReceiveValidationPolicy.Configuration.staging } }
}
private actor CatalogTransport: ServerProjectCatalogTransporting {
    nonisolated let connection = CatalogConnection()
    nonisolated var endpointID: String { connection.endpoint }
    var rows: [ServerCatalogProject]
    var pages = 0
    var repeats = false
    var hook: @Sendable () async -> Void = {}
    init(rows: [ServerCatalogProject]) { self.rows = rows }
    func setRows(_ value: [ServerCatalogProject]) { rows = value }
    func setRepeats(_ value: Bool) { repeats = value }
    func setPageHook(_ value: @escaping @Sendable () async -> Void) { hook = value }
    func page(after: UUID?) async throws -> [ServerCatalogProject] {
        pages += 1
        await hook()
        if repeats { return rows }
        return Array(rows.filter { after == nil || $0.id.uuidString > after!.uuidString }.prefix(1))
    }
    func project(id: UUID) -> ServerCatalogProject? { rows.first { $0.id == id } }
}
private actor CatalogPuller: SyncV2SnapshotPulling {
    var ready = true
    var report: SyncV2SnapshotPullReport?
    func setReport(_ value: SyncV2SnapshotPullReport) { report = value }
    var calls = 0
    var hook: @Sendable () async -> Void = {}
    func setReady(_ value: Bool) { ready = value }
    func setHook(_ value: @escaping @Sendable () async -> Void) { hook = value }
    func pull(localProjectID: ProjectID, serverProjectID: UUID, editingGuards: [UUID: SyncV2EditingGuard]) async throws -> SyncV2SnapshotPullReport {
        calls += 1
        await hook()
        return report ?? .init(contractStructureBaselineReady: ready, outcomes: [], appliedSnapshots: [])
    }
}
private actor CatalogTestGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var didStart = false
    func wait() async {
        didStart = true
        starts.forEach { $0.resume() }; starts = []
        await withCheckedContinuation { waiting = $0 }
    }
    func started() async {
        if didStart { return }
        await withCheckedContinuation { starts.append($0) }
    }
    func release() { waiting?.resume(); waiting = nil }
}

private struct CatalogSnapshotFixture: SyncV2SnapshotClienting {
    let folders: [SyncV2RemoteFolder]
    let document: SyncV2RemoteDocumentSnapshot
    let orders: [SyncV2RemoteTreeOrder]
    private let onFetch: @Sendable () -> Void
    init(onFetch: @escaping @Sendable () -> Void = {}) {
        self.onFetch = onFetch
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let paths = ["메인"] + BinderFixedCategory.allCases.map { $0.relativePath.rawValue }
        var nodes: [String: UUID] = [:]
        var built: [SyncV2RemoteFolder] = []
        for path in paths {
            let id = UUID()
            let parent = nodes[path.split(separator: "/").dropLast().joined(separator: "/")]
            nodes[path] = id
            built.append(.init(folderID: id, parentFolderID: parent, name: String(path.split(separator: "/").last!),
                revision: 3, isDeleted: false, updatedAt: date))
        }
        folders = built
        let parent = nodes["메인/원고"]!
        document = .init(documentID: UUID(), relativePath: "메인/원고/합성 문서.txt", content: "서버에서 받은 합성 문서", revision: 7,
            isDeleted: false, deletedAt: nil, updatedAt: date, parentFolderID: parent, name: "합성 문서.txt", structureRevision: 2)
        let documentID = document.documentID
        orders = ([nil] + built.map { Optional($0.folderID) }).map { parentID in
            .init(treeOrderID: UUID(), parentFolderID: parentID,
                children: built.filter { $0.parentFolderID == parentID }.map(\.folderID) + (parentID == parent ? [documentID] : []),
                revision: 4, updatedAt: date)
        }
    }
    func fetchDocuments(projectID: UUID) async throws -> [SyncV2RemoteDocumentSnapshot] { onFetch(); return [document] }
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] { folders }
    func fetchTreeOrders(projectID: UUID) async throws -> [SyncV2RemoteTreeOrder] { orders }
}
private actor CatalogForbiddenWrites: EnsureProjectTransporting, InitialProjectSyncRecording {
    var calls = 0
    func ensureProject(parameters: EnsureProjectParameters) async throws -> EnsuredServerProject {
        calls += 1
        throw EnsureProjectTransportError.serverRejected
    }
    func recordInitialSnapshot(projectID: ProjectID, projectName: String, batchKind: DurableLocalBatchKind) async -> DurableRecordResult {
        calls += 1
        return .notNeeded
    }
}
private final class CatalogHTTPLog: @unchecked Sendable {
    static let shared = CatalogHTTPLog()
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var unauthorized = false
    var requests: [URLRequest] { lock.withLock { captured } }
    func reset() { lock.withLock { captured = []; unauthorized = false } }
    func reject() { lock.withLock { unauthorized = true } }
    func record(_ request: URLRequest) -> Bool { lock.withLock { captured.append(request); return unauthorized } }
}
private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let unauthorized = CatalogHTTPLog.shared.record(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: unauthorized ? 401 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((unauthorized ? "{\"message\":\"synthetic unauthorized\"}" : "[]").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private struct CatalogFailedMetadata: ProjectCreationMetadataStoring {
    func saveProjectCreation(_ project: Project, standardNodes: [DocumentNode]) async throws {
        throw ProjectBindingStoreError.unavailable
    }
}
private actor CatalogQueuePredicate {
    var isEmpty = true
    func setPending() { isEmpty = false }
}

private func catalogEnqueueSyntheticWork(_ store: SyncV2Store, localID: ProjectID, serverID: UUID) async throws {
    let documentID = UUID()
    let baseline = SyncV2RemoteDocumentSnapshot(documentID: documentID, relativePath: "보존.txt", content: "합성 기존 기준선",
        revision: 3, isDeleted: false, deletedAt: nil, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await store.applySnapshotBaseline(localProjectID: localID, serverProjectID: serverID, snapshot: baseline, expectedRevision: nil)
    _ = try await store.enqueue(.init(batchID: UUID(), localProjectID: localID, localTransactionID: UUID(), kind: .documentSave,
        mutations: [.document(.init(operationID: UUID(), documentID: documentID, deviceID: UUID(), localSaveGeneration: 1,
            kind: .documentCommit, localPath: baseline.relativePath, relativePath: baseline.relativePath,
            content: "합성 미완료 로컬 수정", isDeleted: false))]))
}


extension ServerProjectCatalogTests {
    func testReceiveGuardAllowsSelectedImportAndCanceledResponseResumesSameJournal() async throws {
        let h = try harness()
        h.transport.connection.useStagingFixture()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner))
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            do { _ = try await h.service().catalog(); XCTFail() } catch {}
            let beforeCalls = await h.transport.pages
            XCTAssertEqual(beforeCalls, 0)
            let permit = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: permit)
            let source = try await h.service().catalog()
            await h.puller.setHook { policy.invalidate() }
            do { _ = try await h.service().receive(source.entries[0], from: source, localName: "합성 수신"); XCTFail() } catch {}
            let interrupted = try await h.manager.receivingJournals()
            XCTAssertEqual(interrupted.count, 1)
            let hidden = try await h.manager.projects()
            XCTAssertTrue(hidden.isEmpty)
            await h.puller.setHook {}
            let next = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: next)
            let refreshed = try await h.service().catalog()
            let imported = try await h.service().receive(refreshed.entries[0], from: refreshed, localName: "합성 수신")
            XCTAssertEqual(imported.id, interrupted[0].project.id)
            let remaining = try await h.manager.receivingJournals()
            XCTAssertTrue(remaining.isEmpty)
            let calls = await h.puller.calls
            XCTAssertEqual(calls, 2)
        }
    }

    func testReceiveGuardRejectsLateCatalogAndDifferentEndpoint() async throws {
        let h = try harness()
        h.transport.connection.useStagingFixture()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner))
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: ticket)
            await h.transport.setPageHook { policy.invalidate() }
            do { _ = try await h.service().catalog(); XCTFail() } catch {}
            let journals = try await h.manager.receivingJournals()
            XCTAssertTrue(journals.isEmpty)
            let next = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: next)
            h.transport.connection.change()
            do { _ = try await h.service().catalog(); XCTFail() } catch {}
            let pages = await h.transport.pages
            XCTAssertEqual(pages, 1)
        }
    }
}


extension ServerProjectCatalogTests {
    func testReceiveGuardCancellationAfterManifestBeforeRealApplicationKeepsJournalHidden() async throws {
        let h = try harness()
        let old = try await h.manager.createProject(named: "보존 작품")
        let before = try await h.repo.documents(in: old.id)
        h.transport.connection.useStagingFixture()
        guard case let .available(store) = await SyncV2Store.open(at: h.root.appendingPathComponent("cancel.sqlite3")) else { return XCTFail() }
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner))
        let fixture = CatalogSnapshotFixture(onFetch: { policy.invalidate() })
        let locator = RepositoryProjectWorkspaceLocator(projectRepository: h.repo, pathResolver: h.resolver)
        let puller = SyncV2SnapshotPullService(client: fixture, stateStore: store,
            localApplier: LocalSyncV2SnapshotApplier(documentRepository: h.repo, workspaceLocator: locator),
            mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
            folderApplier: SyncV2RemoteFolderApplier(documentRepository: h.repo, workspaceLocator: locator), folderDocuments: h.repo)
        let service = ServerProjectCatalogService(transport: h.transport, authentication: h.auth, receiver: h.manager,
            projects: h.repo, bindings: store, puller: puller, queueIsEmpty: { try await store.receivingQueueIsEmpty($0) }, markFolderIdentity: { _ in })
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: ticket)
            let source = try await service.catalog()
            do { _ = try await service.receive(source.entries[0], from: source, localName: "중단 수신"); XCTFail() } catch {}
            let journals = try await h.manager.receivingJournals()
            XCTAssertEqual(journals.count, 1)
            let nodes = try await h.repo.documents(in: journals[0].project.id)
            XCTAssertTrue(nodes.isEmpty, "canceled manifest reached the real folder/document applier")
            let visible = try await h.manager.projects()
            XCTAssertEqual(visible.map(\.id), [old.id])
            let after = try await h.repo.documents(in: old.id)
            XCTAssertEqual(after, before)
        }
        await store.close()
    }
}

extension ServerProjectCatalogTests {
    func testBoundaryRealBaselineActorWaitPreservesPartialReceiveAndResumes() async throws {
        try await exerciseBoundary("baseline")
    }
    func testBoundaryRealMetadataActorWaitPreservesPartialReceiveAndResumes() async throws {
        try await exerciseBoundary("metadata.save")
    }
    func testBoundaryRealCreationActorWaitPreservesJournalAndResumes() async throws {
        try await exerciseBoundary("metadata.saveProjectCreation")
    }
    func testBoundaryRealApplyThenFinishWaitPreservesPartialReceiveAndResumes() async throws {
        try await exerciseBoundary("applier.finish")
    }
    func testBoundaryRealReceiverPublicationExpiryPreservesPartialReceiveAndResumes() async throws {
        try await exerciseBoundary("receiver.publish", expire: true)
    }

    private func exerciseBoundary(_ checkpoint: String, expire: Bool = false) async throws {
        let h = try harness()
        let old = try await h.manager.createProject(named: "합성 보호 작품")
        let oldNodes = try await h.repo.documents(in: old.id)
        let oldFile = try h.resolver.standardPaths(forProjectNamed: old.name).workspaceRootURL.appendingPathComponent("보존.txt")
        try Data("기존 합성 원고".utf8).write(to: oldFile)
        h.transport.connection.useStagingFixture()
        guard case let .available(store) = await SyncV2Store.open(at: h.root.appendingPathComponent("boundary.sqlite3")) else { return XCTFail() }
        let oldServer = UUID()
        try await store.save(.connected(localProjectID: old.id, serverProjectID: oldServer, kind: .existingServerProject,
            projectName: old.name, ownerSubject: h.owner))
        try await catalogEnqueueSyntheticWork(store, localID: old.id, serverID: oldServer)
        let oldQueue = try await store.uploadQueueSnapshot(localProjectID: old.id)
        let fixture = CatalogSnapshotFixture()
        let locator = RepositoryProjectWorkspaceLocator(projectRepository: h.repo, pathResolver: h.resolver)
        let applier = LocalSyncV2SnapshotApplier(documentRepository: h.repo, workspaceLocator: locator)
        let puller = SyncV2SnapshotPullService(client: fixture, stateStore: store, localApplier: applier,
            mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: locator),
            folderApplier: SyncV2RemoteFolderApplier(documentRepository: h.repo, workspaceLocator: locator), folderDocuments: h.repo)
        let service = ServerProjectCatalogService(transport: h.transport, authentication: h.auth, receiver: h.manager,
            projects: h.repo, bindings: store, puller: puller, queueIsEmpty: { try await store.receivingQueueIsEmpty($0) },
            markFolderIdentity: { try await store.markFolderMigrationCompleted(localProjectID: $0) })
        let clock = CatalogBoundaryClock()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner), now: { clock.value })
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            let grant = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
            try policy.verifyAccount(h.owner, ticket: grant)
            let source = try await service.catalog()
            let gate = CatalogTestGate(), once = CatalogBoundaryOnce()
            let task = Task {
                try await ReceiveValidationPolicy.$mutationProbe.withValue({ name in
                    if name == checkpoint, once.take() { await gate.wait() }
                }) {
                    try await service.receive(source.entries[0], from: source, localName: "합성 중단 수신")
                }
            }
            await gate.started()
            let journals = try await h.manager.receivingJournals()
            let journal = try XCTUnwrap(journals.first)
            let beforeNodes = try? await h.repo.documents(in: journal.project.id)
            let beforeProjects = try await h.repo.projects()
            let beforeDisk = try catalogBoundaryFiles(h.root)
            let beforeState = try await store.snapshotState(localProjectID: journal.project.id,
                serverProjectID: journal.serverProjectID, documentID: fixture.document.documentID)
            if expire { clock.advance(301) } else { policy.invalidate() }
            // Cancellation case restores the exact same selected project under B.
            // Expiry case has no regrant until the old operation has stopped.
            if !expire {
                let next = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
                try policy.verifyAccount(h.owner, ticket: next)
                try ReceiveValidationPolicy.$operation.withValue(next) {
                    try policy.select(journal.serverProjectID)
                    try policy.authorizeReceiving(journal)
                }
            }
            await gate.release()
            do { _ = try await task.value; XCTFail("canceled receive published at \(checkpoint)") } catch {}
            XCTAssertEqual(try catalogBoundaryFiles(h.root), beforeDisk, "post-cancel file/DB writes at \(checkpoint)")
            let afterNodes = try? await h.repo.documents(in: journal.project.id)
            let afterProjects = try await h.repo.projects()
            let afterJournals = try await h.manager.receivingJournals()
            let afterState = try await store.snapshotState(localProjectID: journal.project.id,
                serverProjectID: journal.serverProjectID, documentID: fixture.document.documentID)
            XCTAssertEqual(afterNodes, beforeNodes)
            XCTAssertEqual(afterProjects, beforeProjects)
            XCTAssertEqual(afterJournals, journals)
            XCTAssertEqual(afterState, beforeState)
            let oldAfter = try await h.repo.documents(in: old.id)
            let queueAfter = try await store.uploadQueueSnapshot(localProjectID: old.id)
            XCTAssertEqual(oldAfter, oldNodes); XCTAssertEqual(queueAfter, oldQueue)
            // Reuse the persisted journal/identity and legitimate partial receive, never rollback.
            if expire {
                let next = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
                try policy.verifyAccount(h.owner, ticket: next)
            }
            let refreshed = try await service.catalog()
            let result = try await service.receive(refreshed.entries[0], from: refreshed, localName: journal.project.name)
            XCTAssertEqual(result.id, journal.project.id)
            let remaining = try await h.manager.receivingJournals()
            XCTAssertTrue(remaining.isEmpty)
            let final = try await h.repo.documents(in: result.id)
            XCTAssertEqual(Set(final.map { $0.id.rawValue }), Set(fixture.folders.map(\.folderID) + [fixture.document.documentID]))
            let finalState = try await store.snapshotState(localProjectID: result.id,
                serverProjectID: journal.serverProjectID, documentID: fixture.document.documentID)
            XCTAssertEqual(finalState?.serverRevision, 7)
            let queue = try await store.receivingQueueIsEmpty(result.id)
            XCTAssertTrue(queue)
        }
        await store.close()
    }
}
private final class CatalogBoundaryOnce: @unchecked Sendable {
    private let lock = NSLock(); private var used = false
    func take() -> Bool { lock.withLock { if used { return false }; used = true; return true } }
}
private final class CatalogBoundaryClock: @unchecked Sendable {
    private let lock = NSLock(); private var time = Date(timeIntervalSince1970: 1000)
    var value: Date { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time.addTimeInterval(seconds) } }
}
private func catalogBoundaryFiles(_ root: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let url as URL in entries {
        // SQLite shared-memory read marks are not persisted application content.
        if !url.lastPathComponent.hasSuffix("-shm"), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
    }
    return files
}

extension ServerProjectCatalogTests {
    func testBoundaryActualMetadataIdentityReplacementWaitCannotMutateAfterRegrant() async throws {
        let h = try harness()
        let project = try await h.manager.createProject(named: "합성 identity 보존")
        let before = try await h.repo.documents(in: project.id)
        let original = try XCTUnwrap(before.first)
        let target = DocumentID(rawValue: UUID())
        let gate = CatalogTestGate()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: h.owner))
        let permit = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(h.owner, ticket: permit)
        try policy.select(project.id.rawValue)
        let task = Task {
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                try await ReceiveValidationPolicy.$operation.withValue(permit) {
                    try await ReceiveValidationPolicy.$localProject.withValue(project.id.rawValue) {
                        try await ReceiveValidationPolicy.$mutationProbe.withValue({ name in
                            if name == "metadata.replaceDocumentIdentity" { await gate.wait() }
                        }) {
                            try await h.repo.replaceDocumentIdentity(from: original.id, to: target, in: project.id)
                        }
                    }
                }
            }
        }
        await gate.started()
        let disk = try catalogBoundaryFiles(h.root)
        policy.invalidate()
        let next = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(h.owner, ticket: next); try policy.select(project.id.rawValue)
        await gate.release()
        do { try await task.value; XCTFail("stale identity commit") } catch {}
        let after = try await h.repo.documents(in: project.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try catalogBoundaryFiles(h.root), disk)
    }
}
