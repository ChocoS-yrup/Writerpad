import Foundation
import SQLite3
import SwiftUI
import UIKit
import XCTest
import Supabase
@testable import WriterPad

final class ReceiveValidationPolicyTests: XCTestCase {
    private let endpoint = ReceiveValidationPolicy.Configuration.staging
    private let account = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private func configuration(version: Int = 1) -> ReceiveValidationPolicy.Configuration {
        .init(version: version, revision: UUID(), endpoint: endpoint, accountID: account)
    }
    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var value = URLRequest(url: URL(string: endpoint + path)!); value.httpMethod = method; return value
    }
    private func ready(_ policy: ReceiveValidationPolicy) throws -> ReceiveValidationPolicy.Ticket? {
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
        try policy.verifyAccount(account, ticket: ticket)
        return ticket
    }
    func testRestartNeverRestoresGrantFromValidOrMissingOrInvalidPolicy() throws {
        for config in [configuration(), nil, configuration(version: 2)] {
            let first = ReceiveValidationPolicy(enabled: true, configuration: config)
            let second = ReceiveValidationPolicy(enabled: true, configuration: config)
            XCTAssertThrowsError(try first.authorization())
            XCTAssertThrowsError(try second.authorization())
            XCTAssertThrowsError(try second.requireSending())
            if config?.valid == true {
                let ticket = try ready(first)
                XCTAssertThrowsError(try second.verifyAccount(account, ticket: ticket))
                XCTAssertThrowsError(try second.authorize(request("/auth/v1/user"), ticket: ticket))
            }
        }
    }
    func testAtomicPolicyStoreInvalidInputAndFailurePreserveOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReceiveValidationPolicy.PolicyStore(url: root.appendingPathComponent("policy.json"))
        XCTAssertThrowsError(try store.load())
        let valid = configuration(); try store.save(valid)
        let before = try Data(contentsOf: store.url)
        XCTAssertThrowsError(try store.save(configuration(version: 99)))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        XCTAssertEqual(try store.load(), valid)
        let failing = ReceiveValidationPolicy.PolicyStore(url: root.appendingPathComponent("missing/policy.json"))
        XCTAssertThrowsError(try failing.save(valid))
        XCTAssertEqual(try Data(contentsOf: store.url), before)
        try Data("corrupt".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.url), Data("corrupt".utf8))
    }
    func testForegroundEndpointAndVerifiedAccountAreRequired() throws {
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration())
        XCTAssertThrowsError(try policy.beginAuthentication(foreground: false, endpoint: endpoint))
        XCTAssertThrowsError(try policy.beginAuthentication(foreground: true, endpoint: "https://other.invalid"))
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
        XCTAssertThrowsError(try policy.requireRead())
        XCTAssertNoThrow(try policy.authorize(request("/auth/v1/token?grant_type=password", method: "POST")))
        XCTAssertThrowsError(try policy.verifyAccount(UUID(), ticket: ticket))
        XCTAssertThrowsError(try policy.authorization())
    }
    func testEveryDataWriterAndUnknownRequestDeniedEvenAfterVerifiedAuthentication() throws {
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration())
        _ = try ready(policy)
        for rpc in ["commit_document", "commit_folder", "ensure_project", "atomic_structure_commit", "document_commit",
                    "acquire_edit_lease", "renew_edit_lease", "release_edit_lease", "unclassified"] {
            XCTAssertThrowsError(try policy.authorize(request("/rest/v1/rpc/" + rpc, method: "POST")), rpc)
        }
        for path in ["/auth/v1/signup", "/auth/v1/logout", "/storage/v1/object/x", "/rest/v1/sync_batches"] {
            XCTAssertThrowsError(try policy.authorize(request(path)))
        }
        var evil = request("/auth/v1/user"); evil.url = URL(string: "https://mhpnszcorfzrvhyondxr.supabase.co.evil.invalid/auth/v1/user")
        XCTAssertThrowsError(try policy.authorize(evil))
        XCTAssertEqual(policy.denialCount, 14)
    }
    func testExpiryCancellationAndPriorGenerationRejectLateResponse() throws {
        let clock = GuardTestClock()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), now: { clock.value })
        let ticket = try ready(policy)
        let auth = request("/auth/v1/user")
        clock.advance(301)
        XCTAssertThrowsError(try policy.validateResponse(Data(), request: auth, ticket: ticket))
        _ = try ready(policy)
        XCTAssertThrowsError(try policy.validateResponse(Data(), request: auth, ticket: ticket))
        policy.invalidate()
        XCTAssertThrowsError(try policy.authorization())
    }
    func testOnlySelectedProjectSelectAndNoApplicationWithoutJournal() throws {
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration())
        _ = try ready(policy)
        let id = UUID(); try policy.select(id)
        XCTAssertNoThrow(try policy.authorize(request("/rest/v1/projects?select=project_id,name&limit=200")))
        XCTAssertNoThrow(try policy.authorize(request("/rest/v1/documents?project_id=eq.\(id)&select=*")))
        XCTAssertThrowsError(try policy.authorize(request("/rest/v1/documents?project_id=eq.\(UUID())&select=*")))
        XCTAssertThrowsError(try policy.authorize(request("/rest/v1/documents?select=*")))
        XCTAssertThrowsError(try policy.requireApplication(local: ProjectID(rawValue: id), server: id))
    }
    func testSDKSessionUsesFinalGuardForAuthRefreshCatalogAndDirectWrites() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
        var session = ReceiveValidationURLProtocol.session(policy: policy)
        defer { session.invalidateAndCancel() }
        var client = SupabaseClient(supabaseURL: URL(string: endpoint)!, supabaseKey: "synthetic-public-key",
            options: .init(auth: .init(storage: EphemeralAuthLocalStorage(), autoRefreshToken: false), global: .init(session: session)))
        do { _ = try await client.auth.refreshSession(refreshToken: "synthetic-refresh"); XCTFail() } catch {}
        var counts = await spy.counts
        XCTAssertEqual(counts, [:])
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
        session.invalidateAndCancel()
        session = ReceiveValidationURLProtocol.session(policy: policy, ticket: ticket)
        client = SupabaseClient(supabaseURL: URL(string: endpoint)!, supabaseKey: "synthetic-public-key",
            options: .init(auth: .init(storage: EphemeralAuthLocalStorage(), autoRefreshToken: false), global: .init(session: session)))
        // Direct URLSession auth response need not be a complete SDK Session to verify final boundary.
        _ = try await session.data(for: request("/auth/v1/token?grant_type=refresh_token", method: "POST"))
        try policy.verifyAccount(account, ticket: ticket)
        _ = try await client.from("projects").select("project_id,name").limit(200).execute()
        do { _ = try await client.rpc("commit_document").execute(); XCTFail() } catch {}
        counts = await spy.counts
        XCTAssertEqual(counts["/auth/v1/token"], 1)
        XCTAssertEqual(counts["/rest/v1/projects"], 1)
        XCTAssertNil(counts["/rest/v1/rpc/commit_document"])
        XCTAssertGreaterThanOrEqual(policy.denialCount, 2)
    }
    func testSDKImplicitExpiredSessionRefreshCannotEscapeWithoutGrant() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
        let storage = EphemeralAuthLocalStorage()
        let payload: [String: Any] = ["access_token": "synthetic-expired", "refresh_token": "synthetic-refresh",
            "expires_in": 3600, "expires_at": 1, "token_type": "bearer",
            "user": ["id": account.uuidString, "aud": "authenticated", "role": "authenticated",
                "app_metadata": [:], "user_metadata": [:], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"]]
        try storage.store(key: "isolated-auth", value: JSONSerialization.data(withJSONObject: payload))
        let session = ReceiveValidationURLProtocol.session(policy: policy)
        let client = SupabaseClient(supabaseURL: URL(string: endpoint)!, supabaseKey: "synthetic-key",
            options: .init(auth: .init(storage: storage, storageKey: "isolated-auth", autoRefreshToken: false), global: .init(session: session)))
        XCTAssertNotNil(client.auth.currentSession, "expired session fixture did not decode")
        do { _ = try await client.from("projects").select("project_id,name").execute(); XCTFail() } catch {}
        let calls = await spy.counts
        XCTAssertTrue(calls.isEmpty)
        XCTAssertGreaterThan(policy.denialCount, 0, "implicit SDK refresh never reached the guarded boundary")
        session.invalidateAndCancel()
    }
    func testRedirectDelegateNeverFollowsEvenSameOrigin() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = request("/auth/v1/user")
        let task = session.dataTask(with: original) // Never resumed.
        let redirect = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let delegate = ReceiveValidationNoRedirect()
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
            newRequest: request("/auth/v1/token?grant_type=password", method: "POST")) { next in XCTAssertNil(next) }
        task.cancel()
    }

    func testFinalHTTPBoundaryRejectsLateAndRedirectedResponse() async throws {
        let gate = GuardHTTPGate()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { request in
            await gate.wait()
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try ready(policy)
        let session = ReceiveValidationURLProtocol.session(policy: policy)
        let req = request("/rest/v1/projects?select=project_id,name")
        let task = Task { try await session.data(for: req) }
        await gate.started(); policy.invalidate(); _ = try ready(policy); await gate.release()
        do { _ = try await task.value; XCTFail("late HTTP response escaped") } catch {}
        let sent = await gate.calls
        XCTAssertEqual(sent, 1)
        session.invalidateAndCancel()
        let redirected = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { request in
            (Data(), HTTPURLResponse(url: URL(string: "https://other.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try ready(redirected)
        let second = ReceiveValidationURLProtocol.session(policy: redirected)
        do { _ = try await second.data(for: req); XCTFail() } catch {}
        second.invalidateAndCancel()
    }
}
private final class GuardTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var time = Date(timeIntervalSince1970: 1000)
    var value: Date { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time.addTimeInterval(seconds) } }
}
private actor GuardHTTPSpy {
    var counts: [String: Int] = [:]
    var responses: [String: Data] = [:]
    func respond(path: String, data: Data) { responses[path] = data }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        XCTAssertNil(request.value(forHTTPHeaderField: "X-WriterPad-Receive-Policy"))
        counts[request.url!.path, default: 0] += 1
        return (responses[request.url!.path] ?? Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private actor GuardHTTPGate {
    var entered = false
    var calls = 0
    var start: [CheckedContinuation<Void, Never>] = []
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { calls += 1; entered = true; start.forEach { $0.resume() }; start = []; await withCheckedContinuation { continuation = $0 } }
    func started() async { if entered { return }; await withCheckedContinuation { start.append($0) } }
    func release() { continuation?.resume(); continuation = nil }
}

extension ReceiveValidationPolicyTests {
    func testGuardedLoginRejectedAccountLeavesLoadingAndPreservesStoredSession() async throws {
        for matches in [false, true] {
            let spy = GuardHTTPSpy()
            let returned = matches ? account : UUID()
            await spy.respond(path: "/auth/v1/token", data: try authPayload(account: returned))
            let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
            let store = GuardSessionStore()
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                let provider = SupabaseClientProvider(configuration: .success(.init(url: URL(string: endpoint)!, publishableKey: "synthetic-key")))
                let service = SupabaseAuthService(transport: provider.makeAuthTransport(), sessionStore: store)
                _ = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
                let state = await service.signIn(email: "fixture@example.invalid", password: "synthetic")
                XCTAssertNotEqual(state, .restoring, "a completed rejected login must leave the loading screen")
                XCTAssertEqual(state.isAuthenticated, matches)
                if !matches {
                    XCTAssertEqual(state, .unavailable(.validationAuthorizationEnded))
                    XCTAssertThrowsError(try policy.authorization())
                }
                XCTAssertFalse(policy.sendingAllowed)
            }
            let calls = await spy.counts, mutations = await store.mutations
            XCTAssertEqual(calls, ["/auth/v1/token": 1])
            XCTAssertEqual(mutations, 0)
        }
    }

    func testGuardedLoginInvalidationAndExpiryLeaveLoadingWithoutPublishingSession() async throws {
        for expires in [false, true] {
            let gate = GuardHTTPGate(), clock = GuardTestClock()
            let payload = try authPayload(account: account)
            let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), now: { clock.value }, network: { request in
                await gate.wait()
                return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let store = GuardSessionStore()
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                let provider = SupabaseClientProvider(configuration: .success(.init(url: URL(string: endpoint)!, publishableKey: "synthetic-key")))
                let service = SupabaseAuthService(transport: provider.makeAuthTransport(), sessionStore: store)
                _ = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
                let login = Task { await service.signIn(email: "fixture@example.invalid", password: "synthetic") }
                await gate.started()
                if expires { clock.advance(301) } else { policy.invalidate() }
                await gate.release()
                let state = await login.value
                XCTAssertEqual(state, .unavailable(.validationAuthorizationEnded))
                XCTAssertFalse(state.isAuthenticated)
                XCTAssertThrowsError(try policy.authorization())
                XCTAssertFalse(policy.sendingAllowed)
            }
            let calls = await gate.calls, mutations = await store.mutations
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(mutations, 0)
        }
    }

    private func authPayload(account: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
            "expires_in": 3600, "expires_at": 4_000_000_000, "token_type": "bearer", "user": ["id": account.uuidString, "aud": "authenticated",
                "role": "authenticated", "email": "fixture@example.invalid", "app_metadata": [:], "user_metadata": [:],
                "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"]])
    }

    func testBoundaryQueuedHTTPRetainsOriginAcrossRegrantWithoutTaskLocal() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
        _ = try ready(policy)
        let oldSession = ReceiveValidationURLProtocol.session(policy: policy)
        let req = request("/rest/v1/projects?select=project_id,name")
        // A's transport and request exist before cancellation; URLProtocol has not loaded it.
        policy.invalidate(); _ = try ready(policy)
        let old = Task.detached { try await oldSession.data(for: req) }
        do { _ = try await old.value; XCTFail("A request borrowed B") } catch {}
        let beforeNew = await spy.counts
        XCTAssertEqual(beforeNew, [:])
        let newSession = ReceiveValidationURLProtocol.session(policy: policy)
        _ = try await Task.detached { try await newSession.data(for: req) }.value
        let afterNew = await spy.counts
        XCTAssertEqual(afterNew["/rest/v1/projects"], 1)
        oldSession.invalidateAndCancel(); newSession.invalidateAndCancel()
    }

    func testBoundaryImplicitSDKRefreshRetainsOriginAcrossRegrant() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
        _ = try ready(policy)
        let storage = EphemeralAuthLocalStorage()
        let payload: [String: Any] = ["access_token": "synthetic-expired", "refresh_token": "synthetic-refresh",
            "expires_in": 3600, "expires_at": 1, "token_type": "bearer",
            "user": ["id": account.uuidString, "aud": "authenticated", "role": "authenticated",
                "app_metadata": [:], "user_metadata": [:], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"]]
        try storage.store(key: "isolated-auth", value: JSONSerialization.data(withJSONObject: payload))
        let session = ReceiveValidationURLProtocol.session(policy: policy)
        // Revoke A before SDK initialization can schedule its implicit expired-session refresh.
        // The session still belongs to A; both SDK startup and the detached query run after B.
        policy.invalidate(); _ = try ready(policy)
        let client = SupabaseClient(supabaseURL: URL(string: endpoint)!, supabaseKey: "synthetic-key",
            options: .init(auth: .init(storage: storage, storageKey: "isolated-auth", autoRefreshToken: false), global: .init(session: session)))
        XCTAssertNotNil(client.auth.currentSession)
        let query = client.from("projects").select("project_id,name")
        do { _ = try await Task.detached { try await query.execute() }.value; XCTFail() } catch {}
        let calls = await spy.counts
        XCTAssertEqual(calls, [:], "implicit refresh must retain A even outside TaskLocal")
        session.invalidateAndCancel()
    }

    func testBoundaryRealMergeResolutionWaitCannotDeleteAfterCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = UUID(), project = ProjectID(rawValue: UUID())
        let marker = root.appendingPathComponent(LocalSyncV2SnapshotMergeStore.prefix + document.uuidString.lowercased() + LocalSyncV2SnapshotMergeStore.suffix)
        let bytes = Data("synthetic completed partial receive".utf8)
        try bytes.write(to: marker)
        let gate = GuardHTTPGate()
        let store = LocalSyncV2SnapshotMergeStore(workspaceLocator: BoundaryWorkspaceLocator(root: root, gate: gate))
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration())
        let ticket = try ready(policy); try policy.select(project.rawValue)
        let operation = Task {
            await ReceiveValidationPolicy.$override.withValue(policy) {
                await ReceiveValidationPolicy.$operation.withValue(ticket) {
                    await ReceiveValidationPolicy.$localProject.withValue(project.rawValue) {
                        await store.resolve(localProjectID: project, documentID: document)
                    }
                }
            }
        }
        await gate.started(); policy.invalidate(); _ = try ready(policy); try policy.select(project.rawValue); await gate.release()
        await operation.value
        XCTAssertEqual(try? Data(contentsOf: marker), bytes, "real actor deleted prior partial receive after cancellation")
    }
}
private actor GuardSessionStore: SessionTokenStoring {
    var mutations = 0
    func load() -> StoredSessionTokens? { .init(accessToken: "preserved-access", refreshToken: "preserved-refresh") }
    func save(_ tokens: StoredSessionTokens) { mutations += 1 }
    func delete() { mutations += 1 }
}
private struct BoundaryWorkspaceLocator: ProjectWorkspaceLocating {
    let root: URL
    let gate: GuardHTTPGate
    func workspaceRoot(for projectID: ProjectID) async throws -> URL { await gate.wait(); return root }
}

extension ReceiveValidationPolicyTests {
    func testBoundaryProviderSharesOnlySameGrantAuthenticationAndReadClients() async throws {
        let spy = GuardHTTPSpy()
        let user: [String: Any] = ["id": account.uuidString, "aud": "authenticated", "role": "authenticated",
            "app_metadata": [:], "user_metadata": [:], "created_at": "2026-01-01T00:00:00Z", "updated_at": "2026-01-01T00:00:00Z"]
        let payload: [String: Any] = ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh",
            "expires_in": 3600, "expires_at": 4_000_000_000, "token_type": "bearer", "user": user]
        await spy.respond(path: "/auth/v1/token", data: try JSONSerialization.data(withJSONObject: payload))
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration(), network: { try await spy.send($0) })
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            let provider = SupabaseClientProvider(configuration: .success(.init(url: URL(string: endpoint)!, publishableKey: "synthetic-key")))
            let auth = try XCTUnwrap(provider.makeAuthTransport())
            let catalog = try XCTUnwrap(provider.makeServerCatalogTransport())
            let a = try policy.beginAuthentication(foreground: true, endpoint: endpoint)
            try await ReceiveValidationPolicy.$operation.withValue(a) {
                let session = try await auth.signIn(email: "fixture@example.invalid", password: "synthetic-password")
                XCTAssertEqual(session.userID, account)
                try policy.verifyAccount(account, ticket: a)
                _ = try await catalog.page(after: nil)
            }
            policy.invalidate()
            let b = try ready(policy)
            do {
                _ = try await ReceiveValidationPolicy.$operation.withValue(a) { try await catalog.page(after: nil) }
                XCTFail("live transport accepted A after B")
            } catch {}
            try await ReceiveValidationPolicy.$operation.withValue(b) {
                _ = try await auth.refresh(tokens: .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh"))
                _ = try await catalog.page(after: nil)
            }
            let calls = await spy.counts
            XCTAssertEqual(calls["/auth/v1/token"], 2)
            XCTAssertEqual(calls["/rest/v1/projects"], 2)
        }
    }
    func testBoundaryMissingOrUnknownHTTPContextFailsClosed() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReceiveValidationURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for value in [nil, "unknown-synthetic-context"] as [String?] {
            var req = request("/auth/v1/user")
            req.setValue(value, forHTTPHeaderField: "X-WriterPad-Receive-Policy")
            do { _ = try await session.data(for: req); XCTFail("unregistered context reached transport") } catch {}
        }
    }
}

final class BodyValidationPolicyTests: XCTestCase {
    let account = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    let device = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    var binding: ProjectSyncBinding { .connected(localProjectID: BodyValidationPlan.local,
        serverProjectID: BodyValidationPlan.project, kind: .existingServerProject,
        projectName: "synthetic", ownerSubject: account) }
    private func policy(clock: GuardTestClock = GuardTestClock(), network: @escaping ReceiveValidationPolicy.Network = { _ in throw URLError(.notConnectedToInternet) }) throws -> ReceiveValidationPolicy {
        let p = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: account), now: { clock.value },
            network: network, bodyValidationEnabled: true)
        let ticket = try p.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try p.verifyAccount(account, ticket: ticket)
        return p
    }
    func batch(operation: UUID = UUID(), project: ProjectID = BodyValidationPlan.local,
               content: String = BodyValidationPlan.outgoing) -> SyncV2EnqueueBatch {
        .init(batchID: UUID(), localProjectID: project, localTransactionID: nil, kind: .documentSave,
            mutations: [.document(.init(operationID: operation, documentID: BodyValidationPlan.document,
                deviceID: device, localSaveGeneration: 1, kind: .documentCommit, localPath: BodyValidationPlan.path,
                relativePath: BodyValidationPlan.path, content: content, isDeleted: false))])
    }
    func request(_ rpc: String, _ body: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/" + rpc)!)
        r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }
    func acquire() throws -> URLRequest { try request("acquire_edit_lease", ["p_document_id": BodyValidationPlan.document.uuidString,
        "p_device_id": device.uuidString, "p_ttl_seconds": 60]) }
    func testScopeNeverUnlocksGlobalStartupRetryRecoveryOrLease() async throws {
        let p = try policy()
        try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
            XCTAssertFalse(p.sendingAllowed)
            XCTAssertThrowsError(try p.requireSending())
            XCTAssertThrowsError(try p.requireBodyEnqueue(self.batch()))
            try p.requireApplication(local: BodyValidationPlan.local, server: BodyValidationPlan.project)
            XCTAssertThrowsError(try p.requireBody(local: ProjectID(rawValue: UUID())))
            XCTAssertThrowsError(try p.authorize(self.acquire()))
        }
        XCTAssertThrowsError(try p.requireBody())
        XCTAssertFalse(p.sendingAllowed)
    }
    func testWrongBindingForegroundAndDuplicateRunFailClosed() async throws {
        let p = try policy()
        do { try await p.withBodyValidation(binding: binding, device: device, foreground: false, epochIsCurrent: { true }) {}; XCTFail() } catch {}
        let wrong = ProjectSyncBinding.connected(localProjectID: BodyValidationPlan.local, serverProjectID: UUID(),
            kind: .existingServerProject, projectName: "synthetic", ownerSubject: account)
        do { try await p.withBodyValidation(binding: wrong, device: device, foreground: true, epochIsCurrent: { true }) {}; XCTFail() } catch {}
        try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
            do { try await p.withBodyValidation(binding: self.binding, device: self.device, foreground: true, epochIsCurrent: { true }) {}; XCTFail() } catch {}
            XCTAssertThrowsError(try p.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
            try p.requireBody()
        }
    }
    func testOnlyExactSingleSyntheticEnqueueAndForwardPhaseAllowed() async throws {
        let p = try policy()
        try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
            try p.bodyPhase(.save)
            XCTAssertThrowsError(try p.requireBodyEnqueue(self.batch(project: ProjectID(rawValue: UUID()))))
            XCTAssertThrowsError(try p.requireBodyEnqueue(self.batch(content: "other")))
            let decomposed = BodyValidationPlan.outgoing.decomposedStringWithCanonicalMapping
            XCTAssertEqual(decomposed, BodyValidationPlan.outgoing, "Swift string equality is canonically equivalent")
            XCTAssertFalse(BodyValidationPlan.matches(decomposed, BodyValidationPlan.outgoing))
            XCTAssertThrowsError(try p.requireBodyEnqueue(self.batch(content: decomposed)))
            let batch = self.batch(); try p.requireBodyEnqueue(batch)
            try p.requireBodyEnqueue(batch) // durable replay of the same operation only
            XCTAssertThrowsError(try p.requireBodyEnqueue(self.batch()))
            try p.bodyPhase(.send)
            XCTAssertThrowsError(try p.bodyPhase(.save))
            XCTAssertThrowsError(try p.requireBodyEnqueue(batch))
        }
    }
    func testHTTPAllowlistAndOneAttemptBudgetUseRealGuardedSession() async throws {
        let spy = GuardHTTPSpy()
        let p = try policy(network: { try await spy.send($0) })
        try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
            try p.bodyPhase(.save); try p.requireBodyEnqueue(self.batch()); try p.bodyPhase(.send)
            let session = ReceiveValidationURLProtocol.session(policy: p)
            defer { session.invalidateAndCancel() }
            let request = try self.acquire()
            _ = try await session.data(for: request)
            do { _ = try await session.data(for: request); XCTFail("duplicate HTTP sent") } catch {}
            for rpc in ["ensure_project", "commit_folder", "atomic_structure_commit", "document_commit", "renew_edit_lease", "get_edit_lease"] {
                XCTAssertThrowsError(try p.authorize(self.request(rpc, [:])))
            }
            XCTAssertThrowsError(try p.authorize(self.request("acquire_edit_lease", ["p_document_id": UUID().uuidString,
                "p_device_id": self.device.uuidString, "p_ttl_seconds": 60])))
        }
        let calls = await spy.counts
        XCTAssertEqual(calls, ["/rest/v1/rpc/acquire_edit_lease": 1])
    }
    func testCommitPayloadPinsEveryFieldAndRejectsMissingLease() async throws {
        let p = try policy(), operation = UUID(), lease = UUID()
        try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
            try p.bodyPhase(.save); try p.requireBodyEnqueue(self.batch(operation: operation)); try p.bodyPhase(.send)
            let params = SyncV2CommitDocumentParameters(documentID: BodyValidationPlan.document, projectID: BodyValidationPlan.project,
                baseServerRevision: 2, operationID: operation, deviceID: self.device, relativePath: BodyValidationPlan.path,
                content: BodyValidationPlan.outgoing, isDeleted: false, leaseToken: lease)
            XCTAssertThrowsError(try p.requireBodyCommit(params))
            try p.bodyLease(lease); try p.requireBodyCommit(params)
            var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as! [String: Any]
            for key in Array(o.keys) {
                let original = o[key]; o[key] = "unexpected"
                XCTAssertThrowsError(try p.authorize(self.request("commit_document", o)), key)
                o[key] = original
            }
            o["p_content"] = BodyValidationPlan.outgoing.decomposedStringWithCanonicalMapping
            XCTAssertThrowsError(try p.authorize(self.request("commit_document", o)))
            o["p_content"] = BodyValidationPlan.outgoing
            o["extra"] = true
            XCTAssertThrowsError(try p.authorize(self.request("commit_document", o)))
        }
    }
    func testExpiryAndEpochChangesPreventMutationAfterAwait() async throws {
        let clock = GuardTestClock(), epoch = SyncV2ContractEpoch()
        let p = try policy(clock: clock)
        do {
            try await p.withBodyValidation(binding: binding, device: device, foreground: true,
                epochIsCurrent: { epoch.value == 0 }) {
                epoch.advance()
                XCTAssertThrowsError(try p.mutate(local: BodyValidationPlan.local) { XCTFail("late mutation") })
            }
            XCTFail()
        } catch {}
        let second = try policy(clock: clock)
        do {
            try await second.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
                clock.advance(301)
                XCTAssertThrowsError(try second.requireBody())
            }
            XCTFail()
        } catch {}
    }
    func testBackgroundCancellationRejectsLateHTTPAndNoSecondRequest() async throws {
        let gate = GuardHTTPGate()
        let p = try policy(network: { req in
            await gate.wait()
            return (Data("{}".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let task = Task {
            try await p.withBodyValidation(binding: binding, device: device, foreground: true, epochIsCurrent: { true }) {
                try p.bodyPhase(.save); try p.requireBodyEnqueue(self.batch()); try p.bodyPhase(.send)
                let session = ReceiveValidationURLProtocol.session(policy: p)
                defer { session.invalidateAndCancel() }
                _ = try await session.data(for: self.acquire())
                try p.mutate { XCTFail("late response applied") }
            }
        }
        for _ in 0..<200 {
            if await gate.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        p.invalidate(); task.cancel(); await gate.release()
        do { try await task.value; XCTFail() } catch {}
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try p.requireBody())
    }
}

final class GeneralSyncValidationScopeTests: XCTestCase {
    private let local = ProjectID(rawValue: UUID()), server = UUID(), document = UUID()
    private func scope(rpcs: Set<String> = []) -> GeneralSyncValidationScope {
        .init(restricted: true, selection: .init(local: local, server: server, documents: [document], reviewedRPCs: rpcs))
    }
    private func request(_ suffix: String) -> URLRequest {
        URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + suffix)!)
    }
    func testUnequalLocalAndServerIDsAreCheckedAsPairAndMissingScopeDeniesAll() throws {
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil)
        try GeneralSyncValidationScope.$override.withValue(scope()) {
            try policy.requireApplication(local: local, server: server)
            XCTAssertThrowsError(try policy.requireApplication(local: ProjectID(rawValue: server), server: server))
            XCTAssertThrowsError(try policy.requireApplication(local: local, server: UUID()))
            XCTAssertThrowsError(try policy.requireRead(project: UUID()))
            XCTAssertThrowsError(try policy.select(UUID()))
            XCTAssertTrue(GeneralSyncValidationScope.current.dispatcherScope.contains(local))
            XCTAssertFalse(GeneralSyncValidationScope.current.dispatcherScope.contains(ProjectID(rawValue: UUID())))
        }
        let missing = GeneralSyncValidationScope(restricted: true, selection: nil)
        XCTAssertThrowsError(try missing.require(local: local))
        XCTAssertThrowsError(try missing.require(document: document))
        XCTAssertFalse(missing.dispatcherScope.contains(local))
    }
    func testSelectedScopeCannotUnlockExistingReceivePolicyOrRealtime() throws {
        try scope().require(local: local, server: server)
        XCTAssertThrowsError(try scope().requireRealtime())
        try GeneralSyncValidationScope.$override.withValue(scope()) {
            let policy = ReceiveValidationPolicy(enabled: true, configuration: nil)
            XCTAssertFalse(policy.sendingAllowed)
            XCTAssertThrowsError(try policy.requireSending())
            XCTAssertThrowsError(try policy.requireApplication(local: local, server: server))
        }
    }
    func testHTTPRequiresExactProjectFilterAndRejectsCatalogRelationsAndUnknownTables() throws {
        let filter = "&project_id=eq." + server.uuidString.lowercased()
        try scope().authorize(request("/rest/v1/documents?select=document_id,content" + filter))
        for suffix in ["/rest/v1/documents?select=document_id", "/rest/v1/projects?select=project_id,name",
                       "/rest/v1/documents?select=document_id,projects(*)" + filter,
                       "/rest/v1/documents?select=document_id" + filter + filter,
                       "/rest/v1/documents?select=document_id" + filter + "&or=(project_id.not.is.null)",
                       "/rest/v1/documents?select=document_id&project_id=eq." + UUID().uuidString.lowercased(),
                       "/rest/v1/sync_batch_results?select=batch_id" + filter] {
            XCTAssertThrowsError(try scope().authorize(request(suffix)), suffix)
        }
        var foreign = request("/auth/v1/user"); foreign.url = URL(string: "https://other.invalid/auth/v1/user")!
        XCTAssertThrowsError(try scope().authorize(foreign))
    }
    func testRPCApprovalMatchesExactBytesIncludingNestedProjectAndDocument() throws {
        var rpc = request("/rest/v1/rpc/document_commit"); rpc.httpMethod = "POST"
        rpc.httpBody = try JSONSerialization.data(withJSONObject: ["p_request": ["project_id": server.uuidString, "document_id": document.uuidString]])
        XCTAssertThrowsError(try scope().authorize(rpc))
        let reviewed = scope(rpcs: [GeneralSyncValidationScope.fingerprint(rpc)])
        try reviewed.authorize(rpc)
        var changed = rpc
        changed.httpBody = try JSONSerialization.data(withJSONObject: ["p_request": ["project_id": UUID().uuidString, "document_id": document.uuidString]])
        XCTAssertThrowsError(try reviewed.authorize(changed))
        changed = rpc; changed.url = request("/rest/v1/rpc/atomic_structure_commit").url
        XCTAssertThrowsError(try reviewed.authorize(changed))
        changed = rpc; changed.httpBody?.append(32)
        XCTAssertThrowsError(try reviewed.authorize(changed))
    }
    func testSessionCapturesScopeAndRejectsUnreviewedRPCBeforeNetwork() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let session = GeneralSyncValidationScope.$override.withValue(scope()) {
            ReceiveValidationURLProtocol.session(policy: policy)
        }
        defer { session.invalidateAndCancel() }
        let selected = request("/rest/v1/documents?select=document_id&project_id=eq." + server.uuidString.lowercased())
        _ = try await session.data(for: selected)
        for bad in [request("/rest/v1/documents?select=document_id"), request("/rest/v1/projects?select=project_id,name")] {
            do { _ = try await session.data(for: bad); XCTFail("Scope escaped its originating task") } catch {}
        }
        var rpc = request("/rest/v1/rpc/acquire_edit_lease"); rpc.httpMethod = "POST"
        rpc.httpBody = Data("{\"p_document_id\":\"\(document)\"}".utf8)
        do { _ = try await session.data(for: rpc); XCTFail("unreviewed lease reached network") } catch {}
        let counts = await spy.counts
        XCTAssertEqual(counts, ["/rest/v1/documents": 1])
    }
    func testScopedHTTPStillRejectsResponseAfterAuthenticationInvalidation() async throws {
        let gate = GuardHTTPGate(), account = UUID()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: account), network: { req in
            await gate.wait()
            return (Data("[]".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(account, ticket: ticket); try policy.select(server)
        let session = GeneralSyncValidationScope.$override.withValue(scope()) { ReceiveValidationURLProtocol.session(policy: policy) }
        defer { session.invalidateAndCancel() }
        let req = request("/rest/v1/documents?select=document_id&project_id=eq." + server.uuidString.lowercased())
        let work = Task { try await session.data(for: req) }
        await gate.started(); policy.invalidate(); await gate.release()
        do { _ = try await work.value; XCTFail("late result escaped revoked account grant") } catch {}
        let calls = await gate.calls; XCTAssertEqual(calls, 1)
    }
    func testLeaseClientRejectsAllFourOperationsForUnknownDocumentBeforeTransport() async throws {
        let transport = GeneralScopeLeaseSpy(), device = UUID()
        let client = EditLeaseClient(transport: transport)
        try await GeneralSyncValidationScope.$override.withValue(scope()) {
            let other = UUID()
            do { _ = try await client.acquire(documentID: other, deviceID: device, ttlSeconds: 60); XCTFail() } catch {}
            do { _ = try await client.renew(documentID: other, deviceID: device, leaseToken: UUID(), ttlSeconds: 60); XCTFail() } catch {}
            do { _ = try await client.release(documentID: other, deviceID: device, leaseToken: UUID()); XCTFail() } catch {}
            do { _ = try await client.inspect(documentID: other, deviceID: device); XCTFail() } catch {}
            let before = await transport.calls; XCTAssertEqual(before, 0)
            _ = try await client.acquire(documentID: document, deviceID: device, ttlSeconds: 60)
            let after = await transport.calls; XCTAssertEqual(after, 1)
        }
    }
}
private actor GeneralScopeLeaseSpy: EditLeaseTransporting {
    var calls = 0
    func acquire(_ p: AcquireEditLeaseParameters) -> EditLeaseMutationResult {
        calls += 1; return .init(documentID: p.documentID, leaseToken: UUID(), deviceID: p.deviceID, expiresAt: Date().addingTimeInterval(60))
    }
    func renew(_ p: RenewEditLeaseParameters) -> EditLeaseMutationResult {
        calls += 1; return .init(documentID: p.documentID, leaseToken: p.leaseToken, deviceID: p.deviceID, expiresAt: Date().addingTimeInterval(60))
    }
    func release(_ p: ReleaseEditLeaseParameters) -> Bool { calls += 1; return true }
    func inspect(_ p: InspectEditLeaseParameters) -> EditLeaseInspectionResult { calls += 1; return .init(documentID: p.documentID, state: .available, expiresAt: nil) }
}

extension GeneralSyncValidationScopeTests {
    func testProviderSDKAndRawContractHTTPBothUseFinalRestriction() async throws {
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let configuration = SupabasePublicConfiguration(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "synthetic-key")
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            try await GeneralSyncValidationScope.$override.withValue(scope()) {
                let provider = SupabaseClientProvider(configuration: .success(configuration))
                let snapshot = try XCTUnwrap(provider.makeSnapshotClient())
                let selected = try await snapshot.fetchDocuments(projectID: server)
                XCTAssertTrue(selected.isEmpty)
                do { _ = try await snapshot.fetchDocuments(projectID: UUID()); XCTFail("SDK sent another project") } catch {}
                let http = SyncV2ContractHTTPClient(configuration: configuration, accessToken: { "synthetic-token" })
                do { _ = try await http.call(rpc: "document_commit", body: Data("{}".utf8)); XCTFail("raw HTTP sent unreviewed bytes") } catch {}
            }
        }
        let counts = await spy.counts
        XCTAssertEqual(counts, ["/rest/v1/documents": 1])
    }
}

final class GeneralValidationJournalTests: XCTestCase {
    private let bearer = "Bearer synthetic-journal-token"
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("general-journal-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func reads() -> [URLRequest] {
        ["documents", "folders", "tree_orders"].map {
            var req = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/" + $0 + "?select=project_id&project_id=eq." + GeneralValidationPlan.server.uuidString.lowercased())!)
            req.httpMethod = "GET"; req.setValue(bearer, forHTTPHeaderField: "Authorization"); return req
        }
    }
    private func response(_ req: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    private func execution(_ root: URL, stage: GeneralValidationPlan.Stage = .receiveWindows,
                           requests: [URLRequest]? = nil, current: @escaping @Sendable () throws -> Void = {},
                           local: @escaping @Sendable () throws -> Void = {},
                           append: @escaping @Sendable (GeneralValidationJournal.Event) throws -> Void = { _ in }) throws -> GeneralValidationExecution {
        try .init(root: root, stage: stage, requests: requests ?? reads(), bearer: bearer,
                  checkCurrent: current, checkLocal: local, beforeAppend: append)
    }
    private func rows(_ root: URL, stage: GeneralValidationPlan.Stage = .receiveWindows) throws -> [GeneralValidationJournal.Row] {
        try Data(contentsOf: GeneralValidationJournal.url(root: root, stage: stage)).split(separator: 10)
            .map { try JSONDecoder().decode(GeneralValidationJournal.Row.self, from: Data($0)) }
    }
    private func receiveCompleted(_ root: URL) throws {
        let run = try execution(root)
        for req in reads() { try run.begin(req); try run.accept(Data("[]".utf8), response: response(req), request: req) }
        try run.completeAfterLocalValidation {}
    }
    private func update() throws -> (URLRequest, SyncV2ContractRequest) {
        let contract = try GeneralValidationPlan.update(device: UUID(), operation: UUID(), batch: UUID(), build: "synthetic-ipad-build")
        var req = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/rpc/document_commit")!)
        req.httpMethod = "POST"; req.setValue(bearer, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(SyncV2AtomicStructureParameters(request: contract.json))
        return (req, contract)
    }
    private func receipt(_ contract: SyncV2ContractRequest, revision: Int = 2, status: String = "committed") throws -> Data {
        let intent = contract.orderedIntents[0].objectValue!, payload = intent["payload"]!.objectValue!
        return try JSONEncoder().encode(SyncV2JSON.object([
            "kind": .string("document_commit_success"), "batch_id": .string(contract.batchID.uuidString.lowercased()),
            "batch_payload_sha256": .string(contract.batchPayloadSHA256), "status": .string(status), "applied": .bool(true),
            "results": .array([.object(["sequence": .int(1), "operation_id": intent["operation_id"]!,
                "document_id": intent["document_id"]!, "result_revision": .int(revision),
                "structure_revision": .int(1), "parent_folder_id": payload["parent_folder_id"]!,
                "name": payload["name"]!, "content_sha256": payload["content_sha256"]!,
                "content_byte_count": payload["content_byte_count"]!, "is_deleted": .bool(false)])])]))
    }
    func testPlanBodiesMatchWindowsAndActualQueueIDsAreRetained() throws {
        XCTAssertEqual(Data(GeneralValidationPlan.incoming.utf8).count, 100)
        XCTAssertEqual(Data(GeneralValidationPlan.outgoing.utf8).count, 128)
        XCTAssertEqual(Data(GeneralValidationPlan.final.utf8).count, 159)
        XCTAssertEqual(SHA256ContentHasher().sha256(for: Data(GeneralValidationPlan.outgoing.utf8)).rawValue, "e2e2247ad6b98784bd4fdeaf45401b5a7805f58659f98abcd508f489f252eb15")
        let (req, contract) = try update()
        let frozen = try GeneralValidationExecution.Frozen(request: req, stage: .sendUpdate)
        XCTAssertEqual(frozen.contract?.batchID, contract.batchID)
        XCTAssertEqual(frozen.contract?.json, contract.json)
    }
    func testResponseAcceptedIsNotLocalCompletionAndCannotStartSend() throws {
        let root = try root(), run = try execution(root)
        for req in reads() { try run.begin(req); try run.accept(Data("[]".utf8), response: response(req), request: req) }
        XCTAssertEqual(try rows(root).last?.event, .responseAccepted)
        let (req, _) = try update()
        XCTAssertThrowsError(try execution(root, stage: .sendUpdate, requests: [req]))
        try run.completeAfterLocalValidation {}
        XCTAssertEqual(try rows(root).last?.event, .completed)
        _ = try execution(root, stage: .sendUpdate, requests: [req])
    }
    func testLocalValidationFailureAndRestartKeepPermanentStopMarker() throws {
        let root = try root(), run = try execution(root)
        for req in reads() { try run.begin(req); try run.accept(Data("[]".utf8), response: response(req), request: req) }
        XCTAssertThrowsError(try run.completeAfterLocalValidation { throw GeneralValidationFailure.denied })
        let before = try Data(contentsOf: GeneralValidationJournal.url(root: root, stage: .receiveWindows))
        XCTAssertEqual(try rows(root).last?.event, .stopped)
        XCTAssertThrowsError(try execution(root))
        XCTAssertEqual(try Data(contentsOf: GeneralValidationJournal.url(root: root, stage: .receiveWindows)), before)
    }
    func testOneUseRequestCannotRepeatOrSkipAndJournalHasNoSecretsOrBody() throws {
        let root = try root(), run = try execution(root), req = reads()[0]
        try run.begin(req); try run.accept(Data("[]".utf8), response: response(req), request: req)
        XCTAssertThrowsError(try run.begin(req))
        let journal = try rows(root)
        XCTAssertEqual(journal.filter { $0.event == .attempt }.count, 1)
        XCTAssertEqual(journal.last?.event, .stopped)
        let text = try String(contentsOf: GeneralValidationJournal.url(root: root, stage: .receiveWindows), encoding: .utf8)
        XCTAssertFalse(text.contains(bearer)); XCTAssertFalse(text.contains("Authorization"))
        XCTAssertFalse(text.contains(GeneralValidationPlan.incoming)); XCTAssertFalse(text.contains(GeneralValidationPlan.server.uuidString.lowercased()))
        let second = try execution(try self.root())
        XCTAssertThrowsError(try second.begin(reads()[1]))
    }
    func testDurableAttemptAndCompletedSendDoNotPermitReplayAfterNewObject() throws {
        let root = try root(); try receiveCompleted(root)
        let (req, contract) = try update(), run = try execution(root, stage: .sendUpdate, requests: [req])
        try run.begin(req)
        XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .attempt)
        try run.accept(receipt(contract), response: response(req), request: req)
        try run.completeAfterLocalValidation {}
        XCTAssertThrowsError(try execution(root, stage: .sendUpdate, requests: [req]))
        _ = try execution(root, stage: .receiveFinal)
    }
    func testIncorrectRevisionPartialHTTPOrReplyNeverCompletesStage() throws {
        for revision in [1, 3] {
            let root = try root(); try receiveCompleted(root)
            let (req, contract) = try update(), run = try execution(root, stage: .sendUpdate, requests: [req])
            try run.begin(req)
            XCTAssertThrowsError(try run.accept(receipt(contract, revision: revision), response: response(req), request: req))
            XCTAssertThrowsError(try run.completeAfterLocalValidation {})
            XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .stopped)
        }
        let root = try root(), run = try execution(root), req = reads()[0]
        try run.begin(req)
        XCTAssertThrowsError(try run.accept(Data("[]".utf8), response: response(req, status: 206), request: req))
    }
    func testChangedRequestHeadersOrBytesStopBeforeAttempt() throws {
        for header in ["Authorization", "Range", "Range-Unit", "Accept-Profile", "Content-Profile", "Prefer"] {
            let root = try root(), run = try execution(root)
            var changed = reads()[0]; changed.setValue("changed", forHTTPHeaderField: header)
            XCTAssertThrowsError(try run.begin(changed))
            XCTAssertFalse(try rows(root).contains { $0.event == .attempt })
        }
        let root = try root(); try receiveCompleted(root)
        let (req, _) = try update(), run = try execution(root, stage: .sendUpdate, requests: [req])
        var changed = req; changed.httpBody?.append(32)
        XCTAssertThrowsError(try run.begin(changed))
    }
    func testCurrentLocalAndExpiryChecksCannotBeRevived() throws {
        let flag = GeneralJournalFlag(), clock = GeneralJournalClock(), root = try root()
        let run = try GeneralValidationExecution(root: root, stage: .receiveWindows, requests: reads(), bearer: bearer,
            now: { clock.time }, checkCurrent: { try flag.check() }, checkLocal: {})
        clock.advance(301)
        XCTAssertThrowsError(try run.begin(reads()[0]))
        XCTAssertFalse(try rows(root).contains { $0.event == .attempt })
        let other = try execution(try self.root(), local: { try flag.check() })
        flag.invalidate(); XCTAssertThrowsError(try other.begin(reads()[0]))
    }
    func testRecordFailureOrRevocationDuringRecordNeverReachesHTTP() async throws {
        for failWrite in [false, true] {
            let root = try root(), flag = GeneralJournalFlag(), spy = GuardHTTPSpy()
            let run = try execution(root, current: { try flag.check() }, append: { event in
                if event == .attempt {
                    if failWrite { throw GeneralValidationFailure.storage }
                    flag.invalidate()
                }
            })
            let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
            let session = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: policy) }
            do { _ = try await session.data(for: reads()[0]); XCTFail() } catch {}
            session.invalidateAndCancel()
            let counts = await spy.counts; XCTAssertTrue(counts.isEmpty)
            XCTAssertThrowsError(try execution(root))
        }
    }
    func testActualHTTPPersistsBeforeTransportAndUnknownResponseCannotRetry() async throws {
        let root = try root(), req = reads()[0]
        let run = try execution(root)
        let marker = GeneralValidationJournal.url(root: root, stage: .receiveWindows)
        let spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { request in
            let rows = try Data(contentsOf: marker).split(separator: 10).map { try JSONDecoder().decode(GeneralValidationJournal.Row.self, from: Data($0)) }
            XCTAssertEqual(rows.last?.event, .attempt)
            _ = try await spy.send(request)
            throw URLError(.networkConnectionLost)
        })
        let session = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: policy) }
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 { do { _ = try await session.data(for: req); XCTFail() } catch {} }
        let counts = await spy.counts; XCTAssertEqual(counts["/rest/v1/documents"], 1)
        XCTAssertEqual(try rows(root).last?.event, .stopped)
        XCTAssertThrowsError(try execution(root))
    }
    func testHTTPRejectsLateResponseAfterForegroundRevocation() async throws {
        let root = try root(), flag = GeneralJournalFlag(), gate = GuardHTTPGate(), run = try execution(root, current: { try flag.check() })
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { req in
            await gate.wait(); return (Data("[]".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let session = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: policy) }
        let req = reads()[0], task = Task { try await session.data(for: req) }
        await gate.started(); flag.invalidate(); await gate.release()
        do { _ = try await task.value; XCTFail() } catch {}
        session.invalidateAndCancel()
        XCTAssertEqual(try rows(root).last?.event, .stopped)
        XCTAssertFalse(try rows(root).contains { $0.event == .responseAccepted })
    }
    func testCompiledReviewScopeRequiresJournalAndDoesNotBypassReceiveLock() async throws {
        let spy = GuardHTTPSpy(), policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let scope = GeneralSyncValidationScope(restricted: true, selection: .init(local: GeneralValidationPlan.local, server: GeneralValidationPlan.server, documents: [], reviewedRPCs: [], requiresJournal: true))
        let session = GeneralSyncValidationScope.$override.withValue(scope) { ReceiveValidationURLProtocol.session(policy: policy) }
        do { _ = try await session.data(for: reads()[0]); XCTFail() } catch {}
        session.invalidateAndCancel()
        let counts = await spy.counts; XCTAssertTrue(counts.isEmpty)
        let locked = ReceiveValidationPolicy(enabled: true, configuration: nil), run = try execution(try root())
        let guarded = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: locked) }
        do { _ = try await guarded.data(for: reads()[0]); XCTFail() } catch {}
        guarded.invalidateAndCancel()
    }
}
private final class GeneralJournalFlag: @unchecked Sendable {
    private let lock = NSLock(); private var valid = true
    func check() throws { try lock.withLock { if !valid { throw GeneralValidationFailure.denied } } }
    func invalidate() { lock.withLock { valid = false } }
}
private final class GeneralJournalClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 1000
    var time: TimeInterval { lock.withLock { value } }
    func advance(_ amount: TimeInterval) { lock.withLock { value += amount } }
}

extension GeneralValidationJournalTests {
    func testSymlinkRootAndIncompletePriorFileCannotCreateNewStage() throws {
        let root = try root(), linkParent = try self.root(), link = linkParent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try execution(link))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let prior = GeneralValidationJournal.url(root: root, stage: .receiveWindows)
        try Data("incomplete reservation".utf8).write(to: prior)
        let (req, _) = try update()
        XCTAssertThrowsError(try execution(root, stage: .sendUpdate, requests: [req]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: GeneralValidationJournal.url(root: root, stage: .sendUpdate).path))
    }
    func testActualContractHTTPCommitsOnceAndJournalRequiresLocalCompletion() async throws {
        let root = try root(); try receiveCompleted(root)
        let (req, contract) = try update(), result = try receipt(contract)
        let run = try execution(root, stage: .sendUpdate, requests: [req]), spy = GuardHTTPSpy()
        await spy.respond(path: "/rest/v1/rpc/document_commit", data: result)
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let scope = GeneralSyncValidationScope(restricted: true, selection: .init(local: GeneralValidationPlan.local,
            server: GeneralValidationPlan.server, documents: [], reviewedRPCs: [GeneralSyncValidationScope.fingerprint(req)], requiresJournal: true))
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                try await GeneralValidationExecution.$current.withValue(run) {
                    let http = SyncV2ContractHTTPClient(configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "synthetic-key"), accessToken: { "synthetic-journal-token" })
                    let data = try await http.call(rpc: "document_commit", body: req.httpBody!)
                    XCTAssertEqual(data, result)
                }
            }
        }
        XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .responseAccepted)
        try run.completeAfterLocalValidation {}
        XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .completed)
        let counts = await spy.counts; XCTAssertEqual(counts, ["/rest/v1/rpc/document_commit": 1])
        XCTAssertThrowsError(try execution(root, stage: .sendUpdate, requests: [req]))
    }
}

extension GeneralValidationJournalTests {
    func testPreviouslyCachedSDKClientCannotDropNewJournalContext() async throws {
        let root = try root(), account = UUID(), spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(), endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: account), network: { try await spy.send($0) })
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(account, ticket: ticket); try policy.select(GeneralValidationPlan.server)
        let configuration = SupabasePublicConfiguration(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "synthetic-key")
        let pool = ReceiveValidationSDKClients(configuration: configuration, policy: policy)
        _ = try pool.client(ticket: ticket) // Login may have populated the old cache before a stage exists.
        let run = try GeneralValidationExecution(root: root, stage: .receiveWindows, requests: reads(), bearer: "Bearer synthetic-key", checkCurrent: {}, checkLocal: {})
        try await GeneralValidationExecution.$current.withValue(run) {
            let client = try pool.client(ticket: ticket)
            _ = try await client.from("documents").select("project_id").eq("project_id", value: GeneralValidationPlan.server.uuidString.lowercased()).execute()
        }
        XCTAssertEqual(try rows(root).last?.event, .responseAccepted)
        XCTAssertEqual(try rows(root).filter { $0.event == .attempt }.count, 1)
        let counts = await spy.counts; XCTAssertEqual(counts["/rest/v1/documents"], 1)
        run.stop()
    }
}

@MainActor
final class GeneralValidationScreenTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let probe: GeneralValidationLocalProbe
        let journal: URL
        let account: UUID
        let auth: ScreenAuthStub
        let bindingEpoch: SyncV2ContractEpoch
        let projectEpoch: SyncV2ContractEpoch
        let model: GeneralValidationScreenModel
    }
    private func sql(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw GeneralValidationFailure.denied }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw GeneralValidationFailure.denied }
    }
    private func fixture(queueEmpty: Bool = true, bindingMatches: Bool = true,
                         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("screen-fixture-\(UUID())")
        let workspace = root.appendingPathComponent("workspace"), sync = root.appendingPathComponent("sync.sqlite3"), metadata = root.appendingPathComponent("metadata.sqlite3")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let local = GeneralValidationPlan.local.rawValue.uuidString.lowercased(), server = GeneralValidationPlan.server.uuidString.lowercased()
        try sql(sync, """
            CREATE TABLE sync_documents(document_id TEXT,local_project_id TEXT,project_id TEXT,server_revision INTEGER,base_hash TEXT,parent_folder_id TEXT,name TEXT,structure_revision INTEGER,is_deleted INTEGER,server_path TEXT);
            INSERT INTO sync_documents VALUES('6cbe47cd-67e5-5e27-8dbf-f3ae59255d52','\(local)','\(server)',1,'e290f19f8c47350c5b9b6e7314aadea1477508174b770860040148280517e1f6',NULL,NULL,NULL,0,'__antigravity__/tree-order.json');
            CREATE TABLE sync_folders(folder_id TEXT,local_project_id TEXT,project_id TEXT,name TEXT,server_revision INTEGER,is_deleted INTEGER);
            CREATE TABLE sync_tree_orders(tree_order_id TEXT,local_project_id TEXT,project_id TEXT,parent_folder_id TEXT,server_revision INTEGER,children_json TEXT);
            INSERT INTO sync_tree_orders VALUES('31eb06be-9cc9-55db-9a05-5882172474ce','\(local)','\(server)','\(GeneralValidationPlan.parent.uuidString.lowercased())',1,'[]');
            CREATE TABLE protected_queue(id TEXT,status TEXT);
            INSERT INTO protected_queue VALUES('unrelated-operation','pending');
            """)
        for n in 0..<11 {
            let folder = n == 0 ? GeneralValidationPlan.parent.uuidString.lowercased() : "folder-\(n)"
            let name = n == 0 ? "원고" : "합성 폴더 \(n)"
            try sql(sync, "INSERT INTO sync_folders VALUES('\(folder)','\(local)','\(server)','\(name)',1,0); INSERT INTO sync_tree_orders VALUES('other-order-\(n)','\(local)','\(server)',NULL,1,'[]');")
        }
        try sql(metadata, "CREATE TABLE metadata(id TEXT,value TEXT); INSERT INTO metadata VALUES('synthetic','preserved');")
        let account = UUID(), auth = ScreenAuthStub(account: account), bindingEpoch = SyncV2ContractEpoch(), projectEpoch = SyncV2ContractEpoch()
        let binding = ProjectSyncBinding.connected(localProjectID: GeneralValidationPlan.local,
            serverProjectID: bindingMatches ? GeneralValidationPlan.server : UUID(), kind: .existingServerProject, projectName: "합성 시험", ownerSubject: account)
        let probe = GeneralValidationLocalProbe(syncURL: sync, metadataURL: metadata, workspace: workspace), journal = root.appendingPathComponent("journal")
        let model = GeneralValidationScreenModel(auth: auth, bindingEpoch: bindingEpoch, projectEpoch: projectEpoch,
            journalRoot: journal, binding: { binding }, queueIsEmpty: { queueEmpty }, probe: { probe }, now: clock)
        model.setForeground(true)
        return Fixture(root: root, probe: probe, journal: journal, account: account, auth: auth, bindingEpoch: bindingEpoch, projectEpoch: projectEpoch, model: model)
    }
    private func requests() -> [URLRequest] {
        ["documents","folders","tree_orders"].map {
            var req = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/" + $0 + "?select=project_id&project_id=eq." + GeneralValidationPlan.server.uuidString.lowercased())!)
            req.httpMethod = "GET"; req.setValue("Bearer synthetic", forHTTPHeaderField: "Authorization"); return req
        }
    }
    func testScreenPreparationUsesExistingLoginAndReadsWithoutCreatingJournal() async throws {
        let f = try fixture(), before = try f.probe.capture()
        await f.model.prepare()
        XCTAssertTrue(f.model.ready); XCTAssertEqual(f.model.stage, .receiveWindows)
        XCTAssertEqual(try f.probe.capture(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        let calls = await f.auth.networkCalls; XCTAssertEqual(calls, 0)
        f.model.invalidate()
    }
    func testDedicatedLoginCallsOnlyAuthenticationAndClearsPassword() async throws {
        let f = try fixture(), before = try f.probe.capture()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: f.account))
        f.model.email = "fixture@example.test"; f.model.password = "synthetic-only"
        await ReceiveValidationPolicy.$override.withValue(policy) { await f.model.signIn() }
        let calls = await f.auth.networkCalls
        XCTAssertEqual(calls, 1); XCTAssertEqual(f.model.password, "")
        XCTAssertTrue(f.model.message.hasPrefix("서버 계정에 로그인했습니다."))
        XCTAssertFalse(f.model.ready); XCTAssertFalse(policy.sendingAllowed)
        XCTAssertEqual(try f.probe.capture(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
    }
    func testDedicatedLoginRejectsWrongAccountAndInactiveScreen() async throws {
        let f = try fixture()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: UUID()))
        f.model.email = "fixture@example.test"; f.model.password = "synthetic-only"
        await ReceiveValidationPolicy.$override.withValue(policy) { await f.model.signIn() }
        XCTAssertFalse(f.model.message.hasPrefix("서버 계정에 로그인했습니다."))
        XCTAssertThrowsError(try policy.authorization())
        f.model.setForeground(false); f.model.password = "synthetic-only"
        await f.model.signIn()
        let calls = await f.auth.networkCalls; XCTAssertEqual(calls, 1)
    }
    func testWrongBindingQueueOrMissingLoginCannotPrepare() async throws {
        for f in [try fixture(bindingMatches: false), try fixture(queueEmpty: false)] {
            await f.model.prepare(); XCTAssertFalse(f.model.ready)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        }
        let signedOut = try fixture(); await signedOut.auth.signOut(); await signedOut.model.prepare()
        XCTAssertFalse(signedOut.model.ready)
    }
    func testScreenExitAuthenticationBindingProjectAndExpiryInvalidatePreparedContext() async throws {
        for change in 0..<5 {
            let clock = GeneralJournalClock(), f = try fixture(clock: { clock.time })
            await f.model.prepare(); XCTAssertTrue(f.model.ready)
            switch change {
            case 0: f.model.setForeground(false)
            case 1: f.auth.contractEpoch?.advance()
            case 2: f.bindingEpoch.advance()
            case 3: f.projectEpoch.advance()
            default: clock.advance(301)
            }
            XCTAssertThrowsError(try f.model.makeExecution(requests: requests(), bearer: "Bearer synthetic"))
            XCTAssertFalse(f.model.ready)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        }
    }
    func testRealFileMetadataOtherQueueAndEmptyFolderChangesStopBeforeJournal() async throws {
        for change in 0..<4 {
            let f = try fixture(); await f.model.prepare(); XCTAssertTrue(f.model.ready)
            switch change {
            case 0: try Data("changed".utf8).write(to: f.probe.workspace.appendingPathComponent("unexpected.txt"))
            case 1: try sql(f.probe.metadataURL, "UPDATE metadata SET value='changed'")
            case 2: try sql(f.probe.syncURL, "UPDATE protected_queue SET status='inflight'")
            default: try FileManager.default.createDirectory(at: f.probe.workspace.appendingPathComponent("new-empty-folder"), withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try f.model.makeExecution(requests: requests(), bearer: "Bearer synthetic"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.journal.path))
        }
    }
    func testUnexpectedPathOrPartialOrderCannotBePresentedAsReady() async throws {
        let f = try fixture()
        try sql(f.probe.syncURL, "UPDATE sync_tree_orders SET server_revision=2 WHERE tree_order_id='31eb06be-9cc9-55db-9a05-5882172474ce'")
        await f.model.prepare(); XCTAssertFalse(f.model.ready)
        let collision = try fixture(), parent = collision.probe.workspace.appendingPathComponent("메인/원고")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("collision".utf8).write(to: parent.appendingPathComponent(GeneralValidationPlan.name))
        await collision.model.prepare(); XCTAssertFalse(collision.model.ready)
    }
    func testModelPassesActualStateChecksToHTTPJournalAndStopsOnExit() async throws {
        let f = try fixture(); await f.model.prepare()
        let reqs = requests(), run = try f.model.makeExecution(requests: reqs, bearer: "Bearer synthetic")
        let spy = GuardHTTPSpy(), policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let session = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: policy) }
        _ = try await session.data(for: reqs[0])
        f.model.setForeground(false)
        do { _ = try await session.data(for: reqs[1]); XCTFail() } catch {}
        session.invalidateAndCancel()
        let counts = await spy.counts; XCTAssertEqual(counts, ["/rest/v1/documents":1])
        let rows = try Data(contentsOf: GeneralValidationJournal.url(root: f.journal, stage: .receiveWindows)).split(separator:10).map { try JSONDecoder().decode(GeneralValidationJournal.Row.self, from: Data($0)) }
        XCTAssertEqual(rows.last?.event, .stopped)
    }
    func testRealMetadataChangeDuringResponsePreventsAcceptance() async throws {
        let f = try fixture(); await f.model.prepare()
        let reqs = requests(), run = try f.model.makeExecution(requests: reqs, bearer: "Bearer synthetic"), gate = GuardHTTPGate()
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { request in
            await gate.wait(); return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
        })
        let session = GeneralValidationExecution.$current.withValue(run) { ReceiveValidationURLProtocol.session(policy: policy) }
        let req = reqs[0], work = Task { try await session.data(for:req) }
        await gate.started(); try sql(f.probe.metadataURL, "UPDATE metadata SET value='late change'"); await gate.release()
        do { _ = try await work.value; XCTFail() } catch {}
        session.invalidateAndCancel(); f.model.invalidate()
    }
    func testClosedScreenRendersPreparedStatus() async throws {
        let f = try fixture(); await f.model.prepare(); XCTAssertTrue(f.model.ready)
        let view = Form { GeneralValidationSection(model:f.model) }.environment(\.scenePhase, .active)
        let host = UIHostingController(rootView:view)
        let window = UIWindow(frame:CGRect(x:0,y:0,width:768,height:900)); window.rootViewController = host; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds; host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(300))
        let image = UIGraphicsImageRenderer(size:host.view.bounds.size).image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name="general-validation-prepared-screen"; attachment.lifetime = .keepAlways; add(attachment)
        f.model.invalidate()
    }
}
private actor ScreenAuthStub: AuthenticationServicing {
    func generalValidationBearer() -> String { "Bearer synthetic-runtime" }
    nonisolated let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    var networkCalls = 0
    var state: AuthenticationState
    init(account: UUID) { state = .authenticated(.init(userID:account,maskedEmail:"fixture@…")) }
    func currentState() -> AuthenticationState { state }
    func restoreSession() -> AuthenticationState { networkCalls += 1; return state }
    func refreshSession(force:Bool) -> AuthenticationState { networkCalls += 1; return state }
    func signIn(email:String,password:String) -> AuthenticationState { networkCalls += 1; return state }
    func signOut() -> AuthenticationState { state = .signedOut(.userInitiated); contractEpoch?.advance(); return state }
}

extension GeneralValidationScreenTests {
    private func historyFixture() throws -> (Fixture, GeneralValidationMetadataReplay, GeneralValidationLocalProbe.Snapshot, GeneralValidationLocalProbe.Snapshot, Date) {
        let f = try fixture(), now = Date()
        try sql(f.probe.metadataURL, """
            CREATE TABLE ATRANSACTION(Z_PK INTEGER PRIMARY KEY,ZTIMESTAMP REAL,ZAUTHOR TEXT);
            INSERT INTO ATRANSACTION VALUES(1,1.0,'original');
            CREATE TABLE ACHANGE(Z_PK INTEGER PRIMARY KEY,ZPAYLOAD TEXT);
            INSERT INTO ACHANGE VALUES(1,'original');
            CREATE TABLE ATRANSACTIONSTRING(Z_PK INTEGER PRIMARY KEY,ZSTRING TEXT);
            INSERT INTO ATRANSACTIONSTRING VALUES(1,'original');
            CREATE TABLE Z_PRIMARYKEY(Z_ENT INTEGER,Z_NAME TEXT,Z_SUPER INTEGER,Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES(3,'DocumentRecord',0,12),(16003,'TRANSACTIONSTRING',0,2);
            """)
        let before = try f.probe.capture(), original = try f.probe.metadataImage()
        try sql(f.probe.metadataURL, """
            INSERT INTO ATRANSACTION VALUES(2,\(now.timeIntervalSinceReferenceDate),'planned');
            INSERT INTO ACHANGE VALUES(2,'predicted document change');
            UPDATE Z_PRIMARYKEY SET Z_MAX=4 WHERE Z_NAME='TRANSACTIONSTRING';
            """)
        let expected = try f.probe.capture(), replay = try GeneralValidationMetadataReplay(before: original, expected: f.probe.metadataImage())
        return (f, replay, before, expected, now)
    }
    func testHistoryReplayAllowsOnlyNewTransactionTimeAndPredictedAllocatorReservation() throws {
        let (f, replay, before, expected, now) = try historyFixture()
        try sql(f.probe.metadataURL, "UPDATE ATRANSACTION SET ZTIMESTAMP=\(now.timeIntervalSinceReferenceDate + 0.5) WHERE Z_PK=2; UPDATE Z_PRIMARYKEY SET Z_MAX=2 WHERE Z_NAME='TRANSACTIONSTRING';")
        let actual = try f.probe.capture()
        XCTAssertNotEqual(actual.metadataHash, expected.metadataHash)
        try replay.validate(actual: f.probe.metadataImage(), beforeSnapshot: before, expectedSnapshot: expected,
            actualSnapshot: actual, interval: now...now.addingTimeInterval(1))
        // Ordinary wire/start guards still detect these same history-only edits.
        XCTAssertNotEqual(try f.probe.capture(), expected)
    }
    func testHistoryReplayRejectsPriorHistoryProductSchemaAndUnexpectedNewHistoryChanges() throws {
        let alterations = [
            "UPDATE ATRANSACTION SET ZTIMESTAMP=2 WHERE Z_PK=1",
            "UPDATE ATRANSACTION SET ZTIMESTAMP=1 WHERE Z_PK=2",
            "UPDATE ATRANSACTION SET ZAUTHOR='other' WHERE Z_PK=2",
            "DELETE FROM ATRANSACTION WHERE Z_PK=1",
            "INSERT INTO ATRANSACTION VALUES(3,1,'extra')",
            "UPDATE ACHANGE SET ZPAYLOAD='changed' WHERE Z_PK=1",
            "UPDATE ACHANGE SET ZPAYLOAD='changed' WHERE Z_PK=2",
            "UPDATE ATRANSACTIONSTRING SET ZSTRING='changed' WHERE Z_PK=1",
            "UPDATE Z_PRIMARYKEY SET Z_MAX=13 WHERE Z_NAME='DocumentRecord'",
            "UPDATE Z_PRIMARYKEY SET Z_MAX=3 WHERE Z_NAME='TRANSACTIONSTRING'",
            "UPDATE Z_PRIMARYKEY SET Z_MAX=6 WHERE Z_NAME='TRANSACTIONSTRING'",
            "UPDATE metadata SET value='changed'",
            "ALTER TABLE ATRANSACTION ADD COLUMN unexpected TEXT",
            "ALTER TABLE metadata RENAME TO previous_metadata; CREATE TABLE metadata(id INTEGER,value TEXT); INSERT INTO metadata SELECT * FROM previous_metadata; DROP TABLE previous_metadata",
            "CREATE TABLE unexpected(id INTEGER)"
        ]
        for alteration in alterations {
            let (f, replay, before, expected, now) = try historyFixture()
            try sql(f.probe.metadataURL, alteration)
            XCTAssertThrowsError(try replay.validate(actual: f.probe.metadataImage(), beforeSnapshot: before,
                expectedSnapshot: expected, actualSnapshot: f.probe.capture(), interval: now...now.addingTimeInterval(1)), alteration)
        }
    }
    func testHistoryReplayRejectsPlannerChangingPreviouslyPreservedHistory() throws {
        let (f, _, _, _, _) = try historyFixture()
        let before = try f.probe.metadataImage()
        for table in ["ATRANSACTION", "ACHANGE", "ATRANSACTIONSTRING"] {
            try sql(f.probe.metadataURL, "DELETE FROM \(table) WHERE Z_PK=1")
            XCTAssertThrowsError(try GeneralValidationMetadataReplay(before: before, expected: f.probe.metadataImage()))
        }
    }
    func testHistoryReplayRejectsMismatchedSnapshotAndExcessiveTimeWindow() throws {
        let (f, replay, before, expected, now) = try historyFixture()
        let actual = try f.probe.capture(), image = try f.probe.metadataImage()
        let wrong = GeneralValidationLocalProbe.Snapshot(syncHash: "unexpected", metadataHash: actual.metadataHash,
            filesHash: actual.filesHash, stage: actual.stage)
        XCTAssertThrowsError(try replay.validate(actual: image, beforeSnapshot: before, expectedSnapshot: expected,
            actualSnapshot: wrong, interval: now...now.addingTimeInterval(1)))
        XCTAssertThrowsError(try replay.validate(actual: image, beforeSnapshot: before, expectedSnapshot: expected,
            actualSnapshot: actual, interval: now...now.addingTimeInterval(301)))
    }
    func testHistoryReplaySealsFullHashAndRejectsLaterHistoryOnlyChange() async throws {
        let (f, _, _, _, now) = try historyFixture()
        let before = try f.probe.capture(), old = try f.probe.metadataImage()
        try sql(f.probe.metadataURL, "INSERT INTO ATRANSACTION VALUES(3,\(now.timeIntervalSinceReferenceDate),'new')")
        let expected = try f.probe.capture(), replay = try GeneralValidationMetadataReplay(before: old, expected: f.probe.metadataImage())
        try sql(f.probe.metadataURL, "DELETE FROM ATRANSACTION WHERE Z_PK=3")
        let transition = try GeneralValidationLocalTransition(expected: [before, expected], capture: { _ in try f.probe.capture() },
            current: {}, metadataReplays: [1: replay], metadataImage: { try f.probe.metadataImage() })
        try await transition.advance { _ in
            try await self.sql(f.probe.metadataURL, "INSERT INTO ATRANSACTION VALUES(3,\(Date().timeIntervalSinceReferenceDate),'new')")
        }
        try transition.requireFinished()
        try sql(f.probe.metadataURL, "UPDATE ATRANSACTION SET ZTIMESTAMP=ZTIMESTAMP+0.01 WHERE Z_PK=3")
        XCTAssertThrowsError(try transition.check())
    }
    func testExistingStageRecordCannotBeRepreparedOrReplaced() async throws {
        let f = try fixture(); await f.model.prepare(); XCTAssertTrue(f.model.ready)
        _ = try f.model.makeExecution(requests: requests(), bearer:"Bearer synthetic")
        f.model.invalidate()
        let path = GeneralValidationJournal.url(root:f.journal,stage:.receiveWindows), before = try Data(contentsOf:path)
        await f.model.prepare()
        XCTAssertFalse(f.model.ready); XCTAssertTrue(f.model.message.contains("실행 기록"))
        XCTAssertEqual(try Data(contentsOf:path),before)
    }
    func testCurrentConfiguredAccountGrantIsUsedWithoutRestoringSession() async throws {
        let f = try fixture()
        let policy = ReceiveValidationPolicy(enabled:true, configuration:.init(version:1,revision:UUID(),endpoint:ReceiveValidationPolicy.Configuration.staging,accountID:f.account))
        _ = try policy.beginAuthentication(foreground:true,endpoint:ReceiveValidationPolicy.Configuration.staging)
        await ReceiveValidationPolicy.$override.withValue(policy) { await f.model.prepare() }
        XCTAssertTrue(f.model.ready)
        policy.invalidate()
        XCTAssertThrowsError(try f.model.makeExecution(requests: requests(),bearer:"Bearer synthetic"))
        let calls = await f.auth.networkCalls; XCTAssertEqual(calls,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.journal.path))
    }
}

extension GeneralValidationScreenTests {
    func testExactBodyRevisionsSelectNextStageAndRejectWrongParent() async throws {
        for (revision,content,expected) in [(1,GeneralValidationPlan.incoming,GeneralValidationPlan.Stage.sendUpdate as GeneralValidationPlan.Stage?), (2,GeneralValidationPlan.outgoing,.receiveFinal), (3,GeneralValidationPlan.final,nil)] {
            let f = try fixture(), local = GeneralValidationPlan.local.rawValue.uuidString.lowercased(), server = GeneralValidationPlan.server.uuidString.lowercased(), doc = GeneralValidationPlan.document.uuidString.lowercased()
            let hash = SHA256ContentHasher().sha256(for:Data(content.utf8)).rawValue
            try sql(f.probe.syncURL, "INSERT INTO sync_documents VALUES('\(doc)','\(local)','\(server)',\(revision),'\(hash)','\(GeneralValidationPlan.parent.uuidString.lowercased())','\(GeneralValidationPlan.name)',1,0,'메인/원고/\(GeneralValidationPlan.name)'); UPDATE sync_tree_orders SET server_revision=2,children_json='[\"\(doc)\"]' WHERE tree_order_id='31eb06be-9cc9-55db-9a05-5882172474ce';")
            let parent = f.probe.workspace.appendingPathComponent("메인/원고")
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
            try Data(content.utf8).write(to:parent.appendingPathComponent(GeneralValidationPlan.name))
            await f.model.prepare(); XCTAssertTrue(f.model.ready); XCTAssertEqual(f.model.stage,expected)
            try sql(f.probe.syncURL,"UPDATE sync_folders SET name='wrong parent' WHERE folder_id='\(GeneralValidationPlan.parent.uuidString.lowercased())'")
            await f.model.prepare(); XCTAssertFalse(f.model.ready)
        }
    }
}

private final class GeneralStageState: @unchecked Sendable {
    typealias Snapshot = GeneralValidationLocalProbe.Snapshot
    let states: [Snapshot]
    private let lock = NSLock()
    private var index = 0
    private var corrupt = false
    private var effects = 0
    init(send: Bool = false, final: Bool = false) {
        let stages: [GeneralValidationPlan.Stage?] = send ? [.sendUpdate, .sendUpdate, .receiveFinal] : (final ? [.receiveFinal, nil] : [.receiveWindows, .sendUpdate])
        states = stages.enumerated().map { index, stage in
            Snapshot(syncHash: "sync-\(index)", metadataHash: "metadata-\(index)", filesHash: "files-\(index)", stage: stage, savedForUpdate: send && index == 1)
        }
    }
    func capture(_ unused: Int) -> Snapshot {
        lock.withLock {
            let value = states[index]
            return Snapshot(syncHash: corrupt ? "unexpected-other-queue" : value.syncHash, metadataHash: value.metadataHash,
                filesHash: value.filesHash, stage: value.stage, savedForUpdate: value.savedForUpdate)
        }
    }
    func advance() { lock.withLock { index += 1; effects += 1 } }
    func damage() { lock.withLock { corrupt = true } }
    var count: Int { lock.withLock { effects } }
    func transition(current: @escaping @Sendable () throws -> Void = {}) throws -> GeneralValidationLocalTransition {
        try .init(expected: states, capture: { self.capture($0) }, current: current)
    }
}

extension GeneralValidationJournalTests {
    private func stageBaseline() throws -> GeneralValidationRemoteBaseline {
        let date = Date(timeIntervalSince1970: 0), root = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        var folders: [SyncV2RemoteFolder] = [
            .init(folderID: root, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: date),
            .init(folderID: GeneralValidationPlan.parent, parentFolderID: root, name: "원고", revision: 1, isDeleted: false, updatedAt: date)
        ]
        for i in 1...9 {
            folders.append(.init(folderID: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", i))!, parentFolderID: root, name: "합성 폴더 \(i)", revision: 1, isDeleted: false, updatedAt: date))
        }
        let orders = ([nil] + folders.map { Optional($0.folderID) }).enumerated().map { index, parent in
            SyncV2RemoteTreeOrder(treeOrderID: parent == GeneralValidationPlan.parent ? GeneralValidationRemoteBaseline.orderID : UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index))!, parentFolderID: parent, children: folders.filter { $0.parentFolderID == parent }.map(\.folderID), revision: 1, updatedAt: date)
        }
        return GeneralValidationRemoteBaseline(control: .init(documentID: GeneralValidationRemoteBaseline.controlID,
            relativePath: syncV2TreeOrderPath, content: generalStageControlFixture, revision: 1, isDeleted: false, deletedAt: nil, updatedAt: date), folders: folders, orders: orders)
    }
    private func stagePayloads(final: Bool = false) throws -> [Data] {
        let b = try stageBaseline(), date = Date(timeIntervalSince1970: 10)
        let doc = SyncV2RemoteDocumentSnapshot(documentID: GeneralValidationPlan.document,
            relativePath: "메인/원고/" + GeneralValidationPlan.name, content: final ? GeneralValidationPlan.final : GeneralValidationPlan.incoming,
            revision: final ? 3 : 1, isDeleted: false, deletedAt: nil, updatedAt: date,
            parentFolderID: GeneralValidationPlan.parent, name: GeneralValidationPlan.name, structureRevision: 1)
        let orders = b.orders.map { order in order.treeOrderID == GeneralValidationRemoteBaseline.orderID
            ? SyncV2RemoteTreeOrder(treeOrderID: order.treeOrderID, parentFolderID: order.parentFolderID, children: [GeneralValidationPlan.document], revision: 2, updatedAt: date) : order }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try [encoder.encode([b.control, doc]), encoder.encode(b.folders), encoder.encode(orders)]
    }
    private func stageReads() -> [URLRequest] {
        reads().map { old in
            var request = old
            var parts = URLComponents(url: old.url!, resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "select", value: GeneralValidationRemoteSnapshot.columns[old.url!.lastPathComponent]),
                                .init(name: "project_id", value: "eq." + GeneralValidationPlan.server.uuidString.lowercased())]
            request.url = parts.url; return request
        }
    }
    private func exchange(payloads: [Data]) -> GeneralValidationStageService.Exchange {
        { request in
            let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { request in
                let index = ["documents", "folders", "tree_orders"].firstIndex(of: request.url!.lastPathComponent) ?? 0
                return (payloads[index], HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let session = ReceiveValidationURLProtocol.session(policy: policy)
            defer { session.invalidateAndCancel() }
            return try await session.data(for: request)
        }
    }
    func testStageReceiveUsesAcceptedSnapshotAndCompletesOnlyAfterLocalTransition() async throws {
        let root = try root(), state = GeneralStageState(), transition = try state.transition()
        let service = GeneralValidationStageService(root: root, exchange: exchange(payloads: try stagePayloads()), current: {})
        try await service.receive(stage: .receiveWindows, requests: stageReads(), bearer: bearer,
            baseline: stageBaseline(), transition: transition) { snapshot, authorize in
                try authorize()
                let docs = try await snapshot.fetchDocuments(projectID: GeneralValidationPlan.server)
                XCTAssertEqual(docs.count, 2)
                let hydrated = try await snapshot.fetchDocumentContents(projectID: GeneralValidationPlan.server, documentIDs: [GeneralValidationPlan.document])
                XCTAssertEqual(hydrated.first?.content, GeneralValidationPlan.incoming)
                state.advance()
                return .init(contractStructureBaselineReady: true, outcomes: [], appliedSnapshots: docs)
            }
        XCTAssertEqual(state.count, 1); XCTAssertEqual(try rows(root).last?.event, .completed)
        XCTAssertEqual(try rows(root).filter { $0.event == .attempt }.count, 3)
        do {
            try await service.receive(stage: .receiveWindows, requests: stageReads(), bearer: bearer,
                baseline: stageBaseline(), transition: transition) { _, _ in XCTFail(); throw GeneralValidationFailure.denied }
            XCTFail()
        } catch {}
    }
    func testStageSendReservesBeforeSaveAndPreservesActualQueueIDs() async throws {
        let root = try root(); try receiveCompleted(root)
        let state = GeneralStageState(send: true), transition = try state.transition(), (request, contract) = try update()
        let marker = GeneralValidationJournal.url(root: root, stage: .sendUpdate)
        let service = GeneralValidationStageService(root: root, exchange: exchange(payloads: [try receipt(contract)]), current: {})
        try await service.send(bearer: bearer, transition: transition) { authorize in
            try authorize()
            let text = try String(contentsOf: marker, encoding: .utf8)
            XCTAssertTrue(text.contains("reserved")); XCTAssertFalse(text.contains("attempt"))
            state.advance(); return request
        } finish: { json, authorize in
            try authorize(); XCTAssertEqual(json.objectValue?["batch_id"], .string(contract.batchID.uuidString.lowercased()))
            state.advance()
        }
        XCTAssertEqual(state.count, 2); XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .completed)
        XCTAssertEqual(try rows(root, stage: .sendUpdate).filter { $0.event == .attempt }.count, 1)
        let finalState = GeneralStageState(final: true)
        let finalService = GeneralValidationStageService(root: root, exchange: exchange(payloads: try stagePayloads(final: true)), current: {})
        try await finalService.receive(stage: .receiveFinal, requests: stageReads(), bearer: bearer,
            baseline: stageBaseline(), transition: finalState.transition()) { snapshot, authorize in
                try authorize(); let docs = try await snapshot.fetchDocuments(projectID: GeneralValidationPlan.server)
                XCTAssertEqual(docs.first { $0.documentID == GeneralValidationPlan.document }?.revision, 3)
                finalState.advance(); return .init(contractStructureBaselineReady: true, outcomes: [], appliedSnapshots: docs)
            }
        XCTAssertEqual(try rows(root, stage: .receiveFinal).last?.event, .completed)
    }
    func testStageSnapshotRejectsPartialDuplicateUnrelatedAndWrongBodyBeforeApply() async throws {
        for mode in 0..<6 {
            var data = try stagePayloads()
            let index = mode == 0 ? 0 : (mode == 1 || mode == 2 ? 1 : (mode == 3 ? 0 : 2))
            var rows = try JSONSerialization.jsonObject(with: data[index]) as! [[String: Any]]
            switch mode {
            case 0: rows.removeLast()
            case 1: rows[1] = rows[0]
            case 2: rows[1]["name"] = "unrelated folder changed"
            case 3: rows[1]["content"] = GeneralValidationPlan.outgoing
            case 4: rows[0]["children"] = []
            default: rows.firstIndex { $0["tree_order_id"] as? String == GeneralValidationRemoteBaseline.orderID.uuidString } .map { rows[$0]["revision"] = 1 }
            }
            data[index] = try JSONSerialization.data(withJSONObject: rows)
            let root = try root(), state = GeneralStageState()
            let service = GeneralValidationStageService(root: root, exchange: exchange(payloads: data), current: {})
            do {
                try await service.receive(stage: .receiveWindows, requests: stageReads(), bearer: bearer,
                    baseline: stageBaseline(), transition: state.transition()) { _, _ in XCTFail(); throw GeneralValidationFailure.denied }
                XCTFail("mode \(mode)")
            } catch {}
            XCTAssertEqual(state.count, 0); XCTAssertEqual(try self.rows(root).last?.event, .stopped)
        }
    }
    func testStageTransportCannotSkipBoundaryOrSwapAcceptedPayload() async throws {
        let payloads = try stagePayloads(), normal = exchange(payloads: payloads)
        for skip in [true, false] {
            let root = try root(), state = GeneralStageState()
            let service = GeneralValidationStageService(root: root, exchange: { req in
                if !skip { _ = try await normal(req) }
                return (skip ? payloads[0] : Data("[]".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, current: {})
            do {
                try await service.receive(stage: .receiveWindows, requests: stageReads(), bearer: bearer,
                    baseline: stageBaseline(), transition: state.transition()) { _, _ in XCTFail(); throw GeneralValidationFailure.denied }
                XCTFail()
            } catch {}
            XCTAssertEqual(try rows(root).last?.event, .stopped)
        }
    }
    func testStageFailedSaveLeavesReservationAndNewServiceCannotRepeatSave() async throws {
        let root = try root(); try receiveCompleted(root)
        let (request, _) = try update(), state = GeneralStageState(send: true)
        for _ in 0..<2 {
            let service = GeneralValidationStageService(root: root, exchange: { _ in XCTFail(); throw GeneralValidationFailure.denied }, current: {})
            do {
                try await service.send(bearer: bearer, transition: state.transition()) { authorize in
                    try authorize(); state.damage(); throw GeneralValidationFailure.storage
                } finish: { _, _ in XCTFail() }
                XCTFail()
            } catch {}
        }
        XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .stopped)
        XCTAssertFalse(try rows(root, stage: .sendUpdate).contains { $0.event == .attempt })
        let reservation = try GeneralValidationJournal(root: self.root(), stage: .receiveWindows)
        try reservation.append(.stopped, sequence: 0)
        XCTAssertThrowsError(try reservation.attach(stage: .receiveWindows))
        _ = request
    }
    func testStageUnexpectedPostApplyMutationOrIncompleteReportCannotComplete() async throws {
        for corrupt in [true, false] {
            let root = try root(), state = GeneralStageState()
            let service = GeneralValidationStageService(root: root, exchange: exchange(payloads: try stagePayloads()), current: {})
            do {
                try await service.receive(stage: .receiveWindows, requests: stageReads(), bearer: bearer,
                    baseline: stageBaseline(), transition: state.transition()) { _, authorize in
                        try authorize(); state.advance(); if corrupt { state.damage() }
                        return .init(contractStructureBaselineReady: corrupt, outcomes: [], appliedSnapshots: [])
                    }
                XCTFail()
            } catch {}
            XCTAssertEqual(try rows(root).last?.event, .stopped)
        }
    }
    func testStageMutationBlocksWireAndRevocationCannotAdoptPostWriteState() async throws {
        let state = GeneralStageState(), flag = GeneralJournalFlag(), transition = try state.transition(current: { try flag.check() })
        do {
            try await transition.advance { authorize in
                try authorize(); XCTAssertThrowsError(try transition.check())
                state.advance(); flag.invalidate(); XCTAssertThrowsError(try authorize())
            }
            XCTFail()
        } catch {}
        XCTAssertThrowsError(try transition.requireFinished())
    }
    func testStageRejectedCommitResponseNeverCallsLocalCompletion() async throws {
        for revision in [1, 3] {
            let root = try root(); try receiveCompleted(root)
            let state = GeneralStageState(send: true), (request, contract) = try update()
            let service = GeneralValidationStageService(root: root, exchange: exchange(payloads: [try receipt(contract, revision: revision)]), current: {})
            do {
                try await service.send(bearer: bearer, transition: state.transition()) { authorize in
                    try authorize(); state.advance(); return request
                } finish: { _, _ in XCTFail() }
                XCTFail()
            } catch {}
            XCTAssertEqual(state.count, 1); XCTAssertEqual(try rows(root, stage: .sendUpdate).last?.event, .stopped)
        }
    }
}

private let generalStageControlFixture = "{\"folder_paths\":[\"메인/메모장\",\"메인/복선\",\"메인/설정집\",\"메인/스토리 플롯\",\"메인/연결확인\",\"메인/원고\",\"메인/장소\",\"메인/캐릭터\",\"메인/흐름정리\"],\"tree_order\":{\"<root>\":[\"원고\",\"캐릭터\",\"설정집\",\"메모장\",\"스토리 플롯\",\"흐름정리\",\"복선\",\"장소\",\"연결확인\",\"휴지통\"],\"메인/메모장\":[],\"메인/복선\":[],\"메인/설정집\":[],\"메인/스토리 플롯\":[],\"메인/연결확인\":[],\"메인/원고\":[],\"메인/장소\":[],\"메인/캐릭터\":[],\"메인/흐름정리\":[]},\"version\":1}"

extension GeneralValidationScreenTests {
    private func installStageBody(_ f: Fixture, revision: Int, content: String) throws {
        try installStageBody(f.probe, revision: revision, content: content)
    }
    private func installStageBody(_ probe: GeneralValidationLocalProbe, revision: Int, content: String) throws {
        let local = GeneralValidationPlan.local.rawValue.uuidString.lowercased(), server = GeneralValidationPlan.server.uuidString.lowercased(), doc = GeneralValidationPlan.document.uuidString.lowercased()
        let hash = SHA256ContentHasher().sha256(for: Data((revision == 1 ? GeneralValidationPlan.incoming : content).utf8)).rawValue
        try sql(probe.syncURL, "DELETE FROM sync_documents WHERE document_id='\(doc)'; INSERT INTO sync_documents VALUES('\(doc)','\(local)','\(server)',\(revision),'\(hash)','\(GeneralValidationPlan.parent.uuidString.lowercased())','\(GeneralValidationPlan.name)',1,0,'메인/원고/\(GeneralValidationPlan.name)'); UPDATE sync_tree_orders SET server_revision=2,children_json='[\"\(doc)\"]' WHERE tree_order_id='31eb06be-9cc9-55db-9a05-5882172474ce';")
        let parent = probe.workspace.appendingPathComponent("메인/원고")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: parent.appendingPathComponent(GeneralValidationPlan.name))
    }
    func testStageFactoryUsesRealSQLiteCheckpointsAndStopsOnScreenExit() async throws {
        let f = try fixture()
        try installStageBody(f, revision: 1, content: GeneralValidationPlan.incoming)
        let before = try f.probe.capture()
        // Freeze expected states on synthetic data, then restore the exact starting
        // logical state. Production must supply a separately reviewed mutation plan.
        try installStageBody(f, revision: 1, content: GeneralValidationPlan.outgoing)
        XCTAssertThrowsError(try f.probe.capture())
        let saved = try f.probe.capture(savedForUpdate: true)
        try installStageBody(f, revision: 2, content: GeneralValidationPlan.outgoing)
        let completed = try f.probe.capture()
        try installStageBody(f, revision: 1, content: GeneralValidationPlan.incoming)
        XCTAssertEqual(try f.probe.capture(), before)
        await f.model.prepare(); XCTAssertTrue(f.model.ready)
        let (_, transition) = try f.model.makeStageService(expected: [before, saved, completed], exchange: { _ in XCTFail(); throw GeneralValidationFailure.denied })
        XCTAssertThrowsError(try f.model.makeExecution(requests: requests(), bearer: "Bearer synthetic"))
        // makeExecution rejection invalidates the whole preparation.
        XCTAssertThrowsError(try transition.check())
        await f.model.prepare()
        let (_, second) = try f.model.makeStageService(expected: [before, saved, completed], exchange: { _ in XCTFail(); throw GeneralValidationFailure.denied })
        f.model.setForeground(false)
        XCTAssertThrowsError(try second.check())
    }
    func testCheckpointPlanRejectsRecapturedOrMisorderedProductStates() throws {
        let state = GeneralStageState(send: true)
        let valid = try GeneralValidationCheckpointPlan(checkpoints: state.states)
        XCTAssertEqual(valid.initial, state.states[0])
        XCTAssertEqual(valid.stage, .sendUpdate)
        XCTAssertNoThrow(try valid.requireStart(state.states[0]))
        XCTAssertThrowsError(try valid.requireStart(state.states[1]))

        var duplicate = state.states
        duplicate[1] = duplicate[0]
        XCTAssertThrowsError(try GeneralValidationCheckpointPlan(checkpoints: duplicate))

        var reordered = state.states
        reordered[2] = GeneralValidationLocalProbe.Snapshot(syncHash: "sync-final", metadataHash: "metadata-final",
            filesHash: "files-final", stage: .receiveWindows, savedForUpdate: false)
        XCTAssertThrowsError(try GeneralValidationCheckpointPlan(checkpoints: reordered))
        XCTAssertThrowsError(try GeneralValidationCheckpointPlan(checkpoints: Array(state.states.dropLast())))
        let sameHashes = state.states.map {
            GeneralValidationLocalProbe.Snapshot(syncHash: "same", metadataHash: "same", filesHash: "same",
                stage: $0.stage, savedForUpdate: $0.savedForUpdate)
        }
        XCTAssertThrowsError(try GeneralValidationCheckpointPlan(checkpoints: sameHashes))
    }
    func testPlanningCopyDerivesSendProposalWithoutChangingOriginal() async throws {
        let f = try fixture()
        try installStageBody(f, revision: 1, content: GeneralValidationPlan.incoming)
        let original = try f.probe.capture()
        let copy = try GeneralValidationPlanningCopy.create(from: f.probe, in: f.root)
        XCTAssertEqual(try copy.probe.capture(), original)
        XCTAssertNotEqual(copy.probe.workspace, f.probe.workspace)
        let proposal = try await copy.derive { probe, step in
            try self.installStageBody(probe, revision: step == 0 ? 1 : 2, content: GeneralValidationPlan.outgoing)
        }
        XCTAssertEqual(proposal.checkpoints.map(\.stage), [.sendUpdate, .sendUpdate, .receiveFinal])
        XCTAssertEqual(proposal.checkpoints.map(\.savedForUpdate), [false, true, false])
        XCTAssertEqual(try f.probe.capture(), original)
        XCTAssertEqual(try generalProductRows(copy.probe.syncURL, "SELECT status FROM protected_queue"), ["pending"])
        do { _ = try await copy.derive { _, _ in XCTFail("Used copy must not be replayed") }; XCTFail() } catch {}
    }
    func testPlanningCopyIncludesCommittedWALWithoutCheckpointingOriginal() throws {
        let f = try fixture()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.probe.metadataURL.path, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO metadata VALUES('wal-only','committed');", nil, nil, nil), SQLITE_OK)
        let wal = URL(fileURLWithPath: f.probe.metadataURL.path + "-wal")
        let mainBytes = try Data(contentsOf: f.probe.metadataURL), walBytes = try Data(contentsOf: wal)
        XCTAssertFalse(walBytes.isEmpty)
        do { _ = try f.probe.capture() } catch { XCTFail("Original WAL baseline capture failed: \(error)"); return }
        let copy = try GeneralValidationPlanningCopy.create(from: f.probe, in: f.root)
        XCTAssertEqual(try generalProductRows(copy.probe.metadataURL, "SELECT value FROM metadata WHERE id='wal-only'"), ["committed"])
        XCTAssertEqual(try Data(contentsOf: f.probe.metadataURL), mainBytes)
        XCTAssertEqual(try Data(contentsOf: wal), walBytes)
        XCTAssertEqual(try copy.probe.capture(), try f.probe.capture())
    }
    func testPlanningCopyRejectsOriginalDriftBeforeAnyStep() async throws {
        let f = try fixture(), copy = try GeneralValidationPlanningCopy.create(from: f.probe, in: f.root)
        try sql(f.probe.syncURL, "UPDATE protected_queue SET status='changed'")
        do { _ = try await copy.derive { _, _ in XCTFail("Changed original must stop planning") }; XCTFail() } catch {}
        XCTAssertThrowsError(try copy.requireOriginalUnchanged())
        XCTAssertEqual(try generalProductRows(copy.probe.syncURL, "SELECT status FROM protected_queue"), ["pending"])
    }
    func testPlanningCopyRejectsWorkspaceDestinationAndSymbolicLinks() throws {
        let f = try fixture()
        XCTAssertThrowsError(try GeneralValidationPlanningCopy.create(from: f.probe, in: f.probe.workspace))
        try FileManager.default.createSymbolicLink(at: f.probe.workspace.appendingPathComponent("linked.sqlite3"), withDestinationURL: f.probe.metadataURL)
        XCTAssertThrowsError(try GeneralValidationPlanningCopy.create(from: f.probe, in: f.root))
    }
    func testInvalidCheckpointPlanInvalidatesPreparationWithoutReservingStage() async throws {
        let f = try fixture()
        await f.model.prepare()
        XCTAssertTrue(f.model.ready)
        let before = try f.probe.capture()
        XCTAssertThrowsError(try f.model.makeStageService(expected: [before, before], exchange: { _ in
            XCTFail("Invalid plan must not reach transport"); throw GeneralValidationFailure.denied
        }))
        XCTAssertFalse(f.model.ready)
        XCTAssertThrowsError(try f.model.validatePrepared())
        XCTAssertFalse(FileManager.default.fileExists(atPath: GeneralValidationJournal.url(root: f.journal, stage: .receiveWindows).path))
    }
    func testExactLocalTransitionAcceptsSavedBodyAndRejectsOtherQueueMutation() async throws {
        for corrupt in [false, true] {
            let f = try fixture()
            try installStageBody(f, revision: 1, content: GeneralValidationPlan.incoming)
            let before = try f.probe.capture()
            try installStageBody(f, revision: 1, content: GeneralValidationPlan.outgoing)
            let saved = try f.probe.capture(savedForUpdate: true)
            try installStageBody(f, revision: 2, content: GeneralValidationPlan.outgoing)
            let completed = try f.probe.capture()
            try installStageBody(f, revision: 1, content: GeneralValidationPlan.incoming)
            let expected = [before, saved, completed]
            let transition = try GeneralValidationLocalTransition(expected: expected, capture: { index in
                try f.probe.capture(savedForUpdate: expected[index].savedForUpdate)
            }, current: {})
            try transition.require(stage: .sendUpdate)
            let parent = f.probe.workspace.appendingPathComponent("메인/원고/" + GeneralValidationPlan.name)
            do {
                try await transition.advance { authorize in
                    try authorize(); try Data(GeneralValidationPlan.outgoing.utf8).write(to: parent)
                    if corrupt {
                        var db: OpaquePointer?
                        guard sqlite3_open(f.probe.syncURL.path, &db) == SQLITE_OK, let db else { throw GeneralValidationFailure.storage }
                        defer { sqlite3_close(db) }
                        guard sqlite3_exec(db, "UPDATE protected_queue SET status='changed'", nil, nil, nil) == SQLITE_OK else { throw GeneralValidationFailure.storage }
                    }
                }
                XCTAssertFalse(corrupt)
                try transition.check()
            } catch { XCTAssertTrue(corrupt) }
        }
    }
}

private final class GeneralMutationAuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (@Sendable () throws -> Void)?
    func store(_ value: @escaping @Sendable () throws -> Void) { lock.withLock { self.value = value } }
    func check() throws { let authorize = lock.withLock { value }; try XCTUnwrap(authorize)() }
}
extension GeneralValidationJournalTests {
    func testStageOldSaveAuthorizationCannotReviveDuringCompletion() async throws {
        let state = GeneralStageState(send: true), transition = try state.transition(), box = GeneralMutationAuthorizationBox()
        try await transition.advance { authorize in
            try authorize(); box.store(authorize); state.advance()
        }
        XCTAssertThrowsError(try box.check())
        try await transition.advance { authorize in
            try authorize(); XCTAssertThrowsError(try box.check()); state.advance()
        }
        try transition.requireFinished(); XCTAssertThrowsError(try box.check())
    }
}

private struct GeneralProductIdentity: DeviceIdentityProviding {
    let id: DeviceIdentifier
    func currentState() async -> DeviceIdentityState { .ready(id) }
    func currentIdentifier() async throws -> DeviceIdentifier { id }
    func prepareIdentity() async {}
}
/// Only handshake/identity are synthetic; enqueue, materialize, claim and complete
/// below execute the ordinary SQLite product code.
private struct GeneralProductRecorder: DurableLocalChangeRecording {
    let store: LazySyncV2ProjectBindingStore
    let binding: ProjectSyncBinding
    let handshake: SyncV2ValidatedHandshake
    func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool { false }
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        do { return .queued(operationIDs: try await store.enqueueContractStructure(batch, binding: binding, handshake: handshake, general: true, authorize: { try GeneralValidationMutation.check() })) }
        catch { return .localSavedButNotQueued(reason: "synthetic fixture enqueue failure") }
    }
}
private struct GeneralProductFixture: Sendable {
    let root: URL
    let workspace: URL
    let database: URL
    let store: LazySyncV2ProjectBindingStore
    let repository: SwiftDataMetadataRepository
    let local: LocalDocumentStore
    let identity: GeneralProductIdentity
    let coordinator: SyncV2ProjectUploadPullCoordinator
    let other: ProjectID
    func adapter(preflight: @escaping @Sendable () async throws -> (@Sendable () throws -> Void) = { {} }) -> GeneralValidationProductAdapter {
        GeneralValidationProductAdapter(store: store, documents: repository, local: local, identity: identity,
            coordinator: coordinator, contractPreflight: preflight, makePuller: { snapshot in
                SyncV2SnapshotPullService(client: snapshot, stateStore: store,
                    localApplier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: workspace)),
                    mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: FixedWorkspaceLocator(root: workspace)),
                    folderApplier: SyncV2RemoteFolderApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: workspace)),
                    folderDocuments: repository)
            })
    }
    var body: URL { workspace.appendingPathComponent("메인/원고/" + GeneralValidationPlan.name) }
    func otherRows() throws -> [String] {
        try ["sync_projects", "sync_documents", "sync_batches", "sync_operations"].flatMap { table in
            try generalProductRows(database, "SELECT * FROM \(table) WHERE local_project_id='\(other.rawValue.uuidString.lowercased())' ORDER BY 1").map { table + $0 }
        } + generalProductRows(database, "SELECT * FROM sync_operation_events WHERE operation_id IN (SELECT operation_id FROM sync_operations WHERE local_project_id='\(other.rawValue.uuidString.lowercased())') ORDER BY 1")
    }
}
private func generalProductRows(_ url: URL, _ query: String) throws -> [String] {
    var db: OpaquePointer?, statement: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw GeneralValidationFailure.storage }
    defer { sqlite3_finalize(statement); sqlite3_close(db) }
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw GeneralValidationFailure.storage }
    var rows: [String] = []
    while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return rows }
        guard code == SQLITE_ROW else { throw GeneralValidationFailure.storage }
        rows.append((0..<sqlite3_column_count(statement)).map { i in
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "<NULL>"
        }.joined(separator: "\u{001f}"))
    }
}
extension GeneralValidationJournalTests {
    private func productFixture(failMetadata: Bool = false, diskMetadata: Bool = false) async throws -> GeneralProductFixture {
        let root = try root(), workspace = root.appendingPathComponent("workspace"), database = root.appendingPathComponent("product.sqlite3")
        let baseline = try stageBaseline(), now = Date(timeIntervalSince1970: 0)
        let coordinator = SyncV2ProjectUploadPullCoordinator(), identity = GeneralProductIdentity(id: .init(uuid: UUID()))
        let store = LazySyncV2ProjectBindingStore(databaseURL: database, deviceIdentityProvider: identity, uploadPullCoordinator: coordinator)
        let binding = ProjectSyncBinding.connected(localProjectID: GeneralValidationPlan.local, serverProjectID: GeneralValidationPlan.server,
            kind: .existingServerProject, projectName: "합성 검증", ownerSubject: UUID())
        try await store.save(binding)
        let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: !diskMetadata, storeURL: diskMetadata ? root.appendingPathComponent("metadata.sqlite3") : nil))
        try await repository.save(Project(id: GeneralValidationPlan.local, name: "합성 검증", createdAt: now, modifiedAt: now))
        // Explicit iterative paths avoid assuming the server's array order.
        var paths: [UUID: String] = [:]
        for _ in 0..<11 {
            for folder in baseline.folders where paths[folder.folderID] == nil {
                if let parent = folder.parentFolderID, let prefix = paths[parent] { paths[folder.folderID] = prefix + "/" + folder.name }
                else if folder.parentFolderID == nil { paths[folder.folderID] = folder.name }
            }
        }
        for folder in baseline.folders.sorted(by: { paths[$0.folderID]!.count < paths[$1.folderID]!.count }) {
            let relative = paths[folder.folderID]!
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent(relative), withIntermediateDirectories: true)
            try await repository.save(DocumentNode(id: .init(rawValue: folder.folderID), projectID: GeneralValidationPlan.local, kind: .folder,
                parentID: folder.parentFolderID.map(DocumentID.init(rawValue:)), relativePath: .init(rawValue: relative), userOrder: 0, modifiedAt: now, contentHash: nil))
        }
        try await store.applyFolderSnapshotBaselines(localProjectID: GeneralValidationPlan.local, serverProjectID: GeneralValidationPlan.server, folders: baseline.folders, excluding: [])
        try await store.applyTreeOrderSnapshotBaselines(localProjectID: GeneralValidationPlan.local, serverProjectID: GeneralValidationPlan.server, treeOrders: baseline.orders)
        _ = try await store.applySnapshotBaseline(localProjectID: GeneralValidationPlan.local, serverProjectID: GeneralValidationPlan.server, snapshot: baseline.control, expectedRevision: nil)
        let other = ProjectID(rawValue: UUID())
        try await store.save(.connected(localProjectID: other, serverProjectID: UUID(), kind: .existingServerProject, projectName: "other", ownerSubject: binding.ownerSubject!))
        for i in 0..<2 {
            let content = "other \(i)"
            let batch = LocalMutationBatch(batchID: UUID(), projectID: other, localTransactionID: nil, kind: .documentSave,
                mutations: [.documentSnapshot(operationID: UUID(), documentID: .init(rawValue: UUID()), relativePath: .init(rawValue: "other\(i).txt"),
                    content: content, contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 1, isDeleted: false)])
            guard case .queued = await store.record(batch) else { throw GeneralValidationFailure.storage }
        }
        let handshake = SyncV2ValidatedHandshake(serverProjectID: GeneralValidationPlan.server, projectSyncMode: .idBased, migrationEpoch: 1,
            contractVersion: SyncV2Contract.version, contractSHA256: SyncV2Contract.canonicalSHA256,
            serverProtocolVersion: SyncV2Contract.syncProtocolVersion, supportedProtocolVersions: [SyncV2Contract.syncProtocolVersion], serverCapabilities: Array(SyncV2Contract.requiredServerCapabilities))
        let local = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace),
            metadataUpdater: failMetadata ? RecordingMetadataUpdater(shouldFail: true) : repository,
            durableChangeRecorder: GeneralProductRecorder(store: store, binding: binding, handshake: handshake))
        return .init(root: root, workspace: workspace, database: database, store: store, repository: repository, local: local,
            identity: identity, coordinator: coordinator, other: other)
    }
    private func receiveProduct(_ f: GeneralProductFixture, final: Bool = false) async throws {
        let snapshot = try GeneralValidationRemoteSnapshot(stage: final ? .receiveFinal : .receiveWindows,
            data: stagePayloads(final: final), baseline: stageBaseline())
        _ = try await f.adapter().apply(snapshot, authorize: {})
    }
    func testPlanningCopyDerivesReceiveUsingProductSQLiteAndDiskSwiftData() async throws {
        let f = try await productFixture(diskMetadata: true)
        let original = GeneralValidationLocalProbe(syncURL: f.database, metadataURL: f.root.appendingPathComponent("metadata.sqlite3"), workspace: f.workspace)
        let before: GeneralValidationLocalProbe.Snapshot
        do { before = try original.capture() } catch { XCTFail("Original product baseline capture failed: \(error)"); return }
        let otherBefore = try f.otherRows()
        let copy = try GeneralValidationPlanningCopy.create(from: original, in: f.root)
        let snapshot = try GeneralValidationRemoteSnapshot(stage: .receiveWindows, data: stagePayloads(), baseline: stageBaseline())
        let proposal = try await copy.derive { probe, _ in
            let coordinator = SyncV2ProjectUploadPullCoordinator()
            let store = LazySyncV2ProjectBindingStore(databaseURL: probe.syncURL, deviceIdentityProvider: f.identity, uploadPullCoordinator: coordinator)
            let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: false, storeURL: probe.metadataURL))
            let local = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: probe.workspace), metadataUpdater: repository)
            let isolated = GeneralProductFixture(root: copy.root, workspace: probe.workspace, database: probe.syncURL,
                store: store, repository: repository, local: local, identity: f.identity, coordinator: coordinator, other: f.other)
            _ = try await isolated.adapter().apply(snapshot, authorize: { try copy.requireOriginalUnchanged() })
            XCTAssertEqual(try isolated.otherRows(), otherBefore)
        }
        XCTAssertEqual(proposal.checkpoints.map(\.stage), [.receiveWindows, .sendUpdate])
        XCTAssertEqual(try original.capture(), before)
        XCTAssertEqual(try f.otherRows(), otherBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.body.path))
        XCTAssertEqual(try String(contentsOf: copy.probe.workspace.appendingPathComponent("메인/원고/" + GeneralValidationPlan.name), encoding: .utf8), GeneralValidationPlan.incoming)
    }
    func testRuntimePredictionMatchesActualProductReceiveSaveAndCompletion() async throws {
        for _ in 0..<2 {
            let f = try await productFixture(diskMetadata: true), otherBefore = try f.otherRows()
            let probe = GeneralValidationLocalProbe(syncURL: f.database, metadataURL: f.root.appendingPathComponent("metadata.sqlite3"), workspace: f.workspace)
            let bindingValue = try await f.store.binding(for: GeneralValidationPlan.local)
            let binding = try XCTUnwrap(bindingValue)
            let handshake = SyncV2ValidatedHandshake(serverProjectID: GeneralValidationPlan.server, projectSyncMode: .idBased, migrationEpoch: 1,
                contractVersion: SyncV2Contract.version, contractSHA256: SyncV2Contract.canonicalSHA256, serverProtocolVersion: SyncV2Contract.syncProtocolVersion,
                supportedProtocolVersions: [SyncV2Contract.syncProtocolVersion], serverCapabilities: Array(SyncV2Contract.requiredServerCapabilities))
            let values = GeneralValidationRuntimeValues()
            try await GeneralValidationRuntimeValues.$current.withValue(values) {
                let copy = try GeneralValidationPlanningCopy.create(from: probe, in: f.root)
                let predicted = try GeneralValidationIsolatedStorage(copy: copy, identity: f.identity, binding: binding, handshake: handshake, preflight: {})
                let snapshot = try GeneralValidationRemoteSnapshot(stage: .receiveWindows, data: stagePayloads(), baseline: stageBaseline())
                _ = try await predicted.adapter.apply(snapshot, authorize: { try copy.requireOriginalUnchanged() })
                let receivePlan = try copy.predictedCheckpoint()
                let receive = try receivePlan.makeTransition(probe: probe, current: {})
                _ = try await receive.advance { authorize in try await f.adapter().apply(snapshot, authorize: authorize) }
                try receive.requireFinished()
                XCTAssertEqual(try probe.capture().stage, .sendUpdate)
                XCTAssertEqual(try f.otherRows(), otherBefore)

                let sendCopy = try GeneralValidationPlanningCopy.create(from: probe, in: f.root)
                let sendPrediction = try GeneralValidationIsolatedStorage(copy: sendCopy, identity: f.identity, binding: binding, handshake: handshake, preflight: {})
                let plannedRequest = try await sendPrediction.adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: { try sendCopy.requireOriginalUnchanged() })
                let savePlan = try sendCopy.predictedCheckpoint(savedForUpdate: true)
                let save = try savePlan.makeTransition(probe: probe, current: {})
                let actual = f.adapter()
                let actualRequest = try await save.advance { authorize in
                    try await actual.saveAndCaptureRequest(bearer: self.bearer, publishableKey: "synthetic", authorize: authorize)
                }
                try save.requireFinished()
                XCTAssertEqual(GeneralSyncValidationScope.fingerprint(actualRequest), GeneralSyncValidationScope.fingerprint(plannedRequest))
                let contract = try XCTUnwrap(GeneralValidationExecution.Frozen(request: actualRequest, stage: .sendUpdate).contract)
                XCTAssertEqual(contract.batchID, values.batch)
                XCTAssertEqual(contract.orderedIntents.first?.objectValue?["operation_id"], .string(values.operation.uuidString.lowercased()))
                XCTAssertEqual(try f.otherRows(), otherBefore)

                let response = try JSONDecoder().decode(SyncV2JSON.self, from: receipt(contract))
                // Clone the actual saved state and predict completion using the
                // accepted receipt, including its original server timestamps.
                let completeCopy = try GeneralValidationPlanningCopy.create(from: probe, in: f.root, savedForUpdate: true)
                let completionPrediction = try GeneralValidationIsolatedStorage(copy: completeCopy, identity: f.identity, binding: binding, handshake: handshake, preflight: {})
                let pendingCheckpoint = try completeCopy.probe.capture(savedForUpdate: true)
                let wrongReceipt = try JSONDecoder().decode(SyncV2JSON.self, from: receipt(contract, revision: 3))
                do {
                    try await completionPrediction.completeAccepted(actualRequest, response: wrongReceipt, authorize: {})
                    XCTFail("Unexpected revision must fail before changing the planning copy")
                } catch {}
                XCTAssertEqual(try completeCopy.probe.capture(savedForUpdate: true), pendingCheckpoint)
                try await completionPrediction.completeAccepted(actualRequest, response: response, authorize: { try completeCopy.requireOriginalUnchanged() })
                let completion = try completeCopy.predictedCheckpoint().makeTransition(probe: probe, current: {})
                try await completion.advance { authorize in try await actual.finish(response, authorize: authorize) }
                try completion.requireFinished()
                await actual.end(); await sendPrediction.adapter.end()
                XCTAssertEqual(try probe.capture().stage, .receiveFinal)
                XCTAssertEqual(try f.otherRows(), otherBefore)

                let finalCopy = try GeneralValidationPlanningCopy.create(from: probe, in: f.root)
                let finalPrediction = try GeneralValidationIsolatedStorage(copy: finalCopy, identity: f.identity, binding: binding, handshake: handshake, preflight: {})
                let finalSnapshot = try GeneralValidationRemoteSnapshot(stage: .receiveFinal, data: stagePayloads(final: true), baseline: stageBaseline())
                _ = try await finalPrediction.adapter.apply(finalSnapshot, authorize: { try finalCopy.requireOriginalUnchanged() })
                let finalTransition = try finalCopy.predictedCheckpoint().makeTransition(probe: probe, current: {})
                _ = try await finalTransition.advance { authorize in try await f.adapter().apply(finalSnapshot, authorize: authorize) }
                try finalTransition.requireFinished()
                XCTAssertEqual(try Data(contentsOf: f.body), Data(GeneralValidationPlan.final.utf8))
                XCTAssertEqual(GeneralValidationPlan.final.split(separator: "\n").count, 5)
                XCTAssertEqual(try f.otherRows(), otherBefore)
            }
        }
    }
    func testProductStorageReceiveSaveQueueCompleteAndFinalReceivePreserveOtherRows() async throws {
        let f = try await productFixture(), before = try f.otherRows()
        try await receiveProduct(f)
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), GeneralValidationPlan.incoming)
        let adapter = f.adapter()
        let req = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic-public-key", authorize: {})
        let contract = try XCTUnwrap(GeneralValidationExecution.Frozen(request: req, stage: .sendUpdate).contract)
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_batches"), ["processing"])
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), GeneralValidationPlan.outgoing)
        let response = try JSONDecoder().decode(SyncV2JSON.self, from: receipt(contract))
        try await adapter.finish(response, authorize: {}); await adapter.end()
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_batches"), ["completed"])
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_local_batches"), ["completed"])
        try await receiveProduct(f, final: true)
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), GeneralValidationPlan.final)
        let state = try await f.store.snapshotState(localProjectID: GeneralValidationPlan.local, serverProjectID: GeneralValidationPlan.server, documentID: GeneralValidationPlan.document)
        XCTAssertEqual(state?.serverRevision, 3); XCTAssertEqual(state?.hasActiveOperation, false)
        XCTAssertEqual(try f.otherRows(), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.workspace.path).contains { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) || $0.hasPrefix(LocalDocumentStore.syncHandoffPrefix) })
    }
    func testProductStorageLockedPolicyRejectsBeforeTXTOrQueueChange() async throws {
        let f = try await productFixture(); try await receiveProduct(f)
        let before = try Data(contentsOf: f.body), other = try f.otherRows()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: nil)
        do {
            try await ReceiveValidationPolicy.$override.withValue(policy) {
                _ = try await f.adapter().saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {})
            }; XCTFail()
        } catch {}
        XCTAssertEqual(try Data(contentsOf: f.body), before); XCTAssertEqual(try f.otherRows(), other)
        XCTAssertEqual(try generalProductRows(f.database, "SELECT COUNT(*) FROM sync_contract_local_batches"), ["0"])
    }
    func testProductStorageMetadataFailureLeavesRecoveryMarkerWithoutClaim() async throws {
        let f = try await productFixture(failMetadata: true); try await receiveProduct(f)
        let before = try f.otherRows(), adapter = f.adapter()
        do { _ = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {}); XCTFail() } catch {}
        await adapter.end()
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), GeneralValidationPlan.outgoing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.workspace.path).contains { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) })
        XCTAssertEqual(try generalProductRows(f.database, "SELECT COUNT(*) FROM sync_contract_batches"), ["0"])
        XCTAssertEqual(try f.otherRows(), before)
    }
    func testProductStorageCancelledCompletionPreservesProcessingAndCannotRetrySave() async throws {
        let f = try await productFixture(); try await receiveProduct(f)
        let adapter = f.adapter(), before = try f.otherRows()
        let request = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {})
        let contract = try XCTUnwrap(GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate).contract)
        let response = try JSONDecoder().decode(SyncV2JSON.self, from: receipt(contract))
        do { try await adapter.finish(response, authorize: { throw CancellationError() }); XCTFail() } catch {}
        await adapter.end()
        do { _ = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {}); XCTFail() } catch {}
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_batches"), ["processing"])
        XCTAssertEqual(try f.otherRows(), before)
    }
    func testProductStorageMutationContextDeniesHTTPBeforeMockNetwork() async throws {
        let req = reads()[0], spy = GuardHTTPSpy()
        let policy = ReceiveValidationPolicy(enabled: false, configuration: nil, network: { try await spy.send($0) })
        let session = GeneralValidationMutation.$current.withValue({}) { ReceiveValidationURLProtocol.session(policy: policy) }
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(for: req); XCTFail() } catch {}
        let counts = await spy.counts; XCTAssertTrue(counts.isEmpty)
    }
}

extension GeneralValidationJournalTests {
    func testProductStorageMissingContractPreflightRejectsBeforeSave() async throws {
        let f = try await productFixture(); try await receiveProduct(f)
        let before = try Data(contentsOf: f.body)
        let adapter = f.adapter(preflight: { throw GeneralValidationFailure.denied })
        do { _ = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {}); XCTFail() } catch {}
        XCTAssertEqual(try Data(contentsOf: f.body), before)
        XCTAssertEqual(try generalProductRows(f.database, "SELECT COUNT(*) FROM sync_contract_local_batches"), ["0"])
    }
    func testProductStorageRevokedStandingContractCannotCompleteSavedRequest() async throws {
        let f = try await productFixture(); try await receiveProduct(f)
        let flag = GeneralJournalFlag(), adapter = f.adapter(preflight: { { try flag.check() } })
        let request = try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: {})
        let contract = try XCTUnwrap(GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate).contract)
        let response = try JSONDecoder().decode(SyncV2JSON.self, from: receipt(contract))
        flag.invalidate()
        do { try await adapter.finish(response, authorize: {}); XCTFail() } catch {}
        await adapter.end()
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_batches"), ["processing"])
    }
    func testProductStorageRevocationInsideMetadataWaitStopsCommitAndQueue() async throws {
        let f = try await productFixture(); try await receiveProduct(f)
        let node = try await f.repository.document(id: .init(rawValue: GeneralValidationPlan.document))
        let flag = GeneralJournalFlag(), adapter = f.adapter()
        do {
            _ = try await ReceiveValidationPolicy.$mutationProbe.withValue({ name in
                if name == "metadata.updateAfterFileSave" { flag.invalidate() }
            }) { try await adapter.saveAndCaptureRequest(bearer: bearer, publishableKey: "synthetic", authorize: { try flag.check() }) }
            XCTFail()
        } catch {}
        await adapter.end()
        let after = try await f.repository.document(id: .init(rawValue: GeneralValidationPlan.document))
        XCTAssertEqual(after, node)
        XCTAssertEqual(try String(contentsOf: f.body, encoding: .utf8), GeneralValidationPlan.outgoing)
        XCTAssertEqual(try generalProductRows(f.database, "SELECT COUNT(*) FROM sync_contract_local_batches"), ["0"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.workspace.path).contains { $0.hasPrefix(LocalDocumentStore.reconciliationPrefix) })
    }
}

private actor GeneralRuntimeWire {
    var payloads: [Data]
    var paths: [String] = []
    var failCommit = false
    var revoke: (@Sendable () -> Void)?
    init(payloads: [Data]) { self.payloads = payloads }
    func setPayloads(_ data: [Data]) { payloads = data }
    func setFailure() { failCommit = true }
    func setRevocation(_ callback: @escaping @Sendable () -> Void) { revoke = callback }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.lastPathComponent; paths.append(path)
        let data: Data
        if path == "get_sync_handshake" {
            data = try JSONSerialization.data(withJSONObject: [
                "supported": true, "project_id": GeneralValidationPlan.server.uuidString.lowercased(),
                "project_sync_mode": "ID_BASED", "migration_epoch": 1, "contract_version": SyncV2Contract.version,
                "canonical_contract_sha256": SyncV2Contract.canonicalSHA256, "server_contract_sha256": SyncV2Contract.canonicalSHA256,
                "server_protocol_version": SyncV2Contract.syncProtocolVersion,
                "supported_protocol_versions": [SyncV2Contract.syncProtocolVersion], "server_capabilities": Array(SyncV2Contract.requiredServerCapabilities)
            ])
        } else if path == "document_commit" {
            if failCommit { throw URLError(.networkConnectionLost) }
            let contract = try GeneralValidationExecution.Frozen(request: request, stage: .sendUpdate).contract!
            let intent = contract.orderedIntents[0].objectValue!, payload = intent["payload"]!.objectValue!
            data = try JSONEncoder().encode(SyncV2JSON.object([
                "kind": .string("document_commit_success"), "batch_id": .string(contract.batchID.uuidString.lowercased()),
                "batch_payload_sha256": .string(contract.batchPayloadSHA256), "status": .string("committed"), "applied": .bool(true),
                "results": .array([.object(["sequence": .int(1), "operation_id": intent["operation_id"]!,
                    "document_id": intent["document_id"]!, "result_revision": .int(2), "structure_revision": .int(1),
                    "parent_folder_id": payload["parent_folder_id"]!, "name": payload["name"]!,
                    "content_sha256": payload["content_sha256"]!, "content_byte_count": payload["content_byte_count"]!, "is_deleted": .bool(false)])])]))
        } else {
            guard let index = ["documents", "folders", "tree_orders"].firstIndex(of: path) else { throw GeneralValidationFailure.denied }
            data = payloads[index]; revoke?()
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
extension GeneralValidationJournalTests {
    @MainActor
    private func runtimeFixture(gateOpen: Bool = true) async throws -> (GeneralProductFixture, GeneralValidationScreenModel, ReceiveValidationPolicy, GeneralRuntimeWire, GeneralJournalFlag, URL) {
        let f = try await productFixture(diskMetadata: true)
        let bindingValue = try await f.store.binding(for: GeneralValidationPlan.local), binding = try XCTUnwrap(bindingValue)
        let account = try XCTUnwrap(binding.ownerSubject)
        let auth = ScreenAuthStub(account: account), wire = GeneralRuntimeWire(payloads: try stagePayloads())
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: account), network: { try await wire.send($0) })
        let ticket = try policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging)
        try policy.verifyAccount(account, ticket: ticket)
        let configuration = SupabasePublicConfiguration(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "synthetic-public")
        let transport = ReceiveValidationPolicy.$override.withValue(policy) {
            SupabaseClientProvider(configuration: .success(configuration)).makeHandshakeTransport()!
        }
        let handshake = SyncV2HandshakeService(transport: transport), flag = GeneralJournalFlag()
        if !gateOpen { flag.invalidate() }
        let bindingEpoch = SyncV2ContractEpoch(), projectEpoch = SyncV2ContractEpoch()
        let probe = GeneralValidationLocalProbe(syncURL: f.database, metadataURL: f.root.appendingPathComponent("metadata.sqlite3"), workspace: f.workspace)
        let journal = f.root.appendingPathComponent("runtime-journal"), baseline = try stageBaseline()
        let model = GeneralValidationScreenModel(auth: auth, bindingEpoch: bindingEpoch, projectEpoch: projectEpoch, journalRoot: journal,
            binding: { binding }, queueIsEmpty: {
                let legacy = try await f.store.uploadQueueSnapshot(localProjectID: GeneralValidationPlan.local)
                let general = try await f.store.generalQueueStatus(localProjectID: GeneralValidationPlan.local)
                return legacy == .idle && general.pendingCount == 0 && general.attentionCount == 0 && general.retryCount == 0
            }, probe: { probe })
        let defaults = UserDefaults(suiteName: "general-runtime-" + UUID().uuidString)!
        ContractPathGate.setOpen(gateOpen, for: GeneralValidationPlan.local, in: defaults)
        let authority = f.coordinator.contractStructureAuthority
        let context: @Sendable () async throws -> SyncV2HandshakeContext = {
            SyncV2HandshakeContext.make(authenticationState: await auth.currentState(), localProjectID: GeneralValidationPlan.local,
                serverProjectID: GeneralValidationPlan.server, authenticationEpoch: auth.contractEpoch!.value, bindingEpoch: bindingEpoch.value)!
        }
        let recorder = SyncV2ContractPathRecorder(store: f.store, handshakeService: handshake, authenticationService: auth,
            defaults: defaults, bindingEpoch: bindingEpoch, structureAuthority: authority, localProjectEpoch: projectEpoch,
            isLocalProjectActive: { $0 == GeneralValidationPlan.local })
        let local = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: f.workspace), metadataUpdater: f.repository,
            durableChangeRecorder: recorder)
        model.runtime = GeneralValidationRuntime(auth: auth, handshake: handshake, identity: f.identity, configuration: configuration,
            binding: { binding }, context: context,
            gate: { try flag.check(); return { try flag.check() } }, adapter: {
                GeneralValidationProductAdapter(store: f.store, documents: f.repository, local: local, identity: f.identity,
                    coordinator: f.coordinator, contractPreflight: {
                        guard authority.proof(try await context(), requiresActiveServer: false) != nil else { throw GeneralValidationFailure.denied }
                        return { try flag.check() }
                    }, receivePreflight: { { try flag.check() } }, makePuller: { snapshot in
                        SyncV2SnapshotPullService(client: snapshot, stateStore: f.store,
                            localApplier: LocalSyncV2SnapshotApplier(documentRepository: f.repository, workspaceLocator: FixedWorkspaceLocator(root: f.workspace)),
                            mergeStore: LocalSyncV2SnapshotMergeStore(workspaceLocator: FixedWorkspaceLocator(root: f.workspace)),
                            folderApplier: SyncV2RemoteFolderApplier(documentRepository: f.repository, workspaceLocator: FixedWorkspaceLocator(root: f.workspace)),
                            folderDocuments: f.repository, contractStructureAuthority: authority, contractContext: { _, _ in try? await context() })
                    })
            }, baseline: { baseline })
        model.setForeground(true)
        return (f, model, policy, wire, flag, journal)
    }
    @MainActor
    func testRuntimeScreenHandshakeReceiveSingleCommitAndFinalComparisonWithLockedGlobalPolicy() async throws {
        let (f, model, policy, wire, _, journal) = try await runtimeFixture()
        let other = try f.otherRows()
        await ReceiveValidationPolicy.$override.withValue(policy) { await model.prepareExecution() }
        XCTAssertTrue(model.executionReady, model.message); XCTAssertFalse(policy.sendingAllowed)
        await model.execute(.sendUpdate) // Out-of-order button calls are inert.
        await model.execute(.receiveWindows)
        XCTAssertEqual(model.stage, .sendUpdate, model.message)
        await model.execute(.sendUpdate)
        XCTAssertEqual(model.stage, .receiveFinal, model.message)
        await model.execute(.sendUpdate) // Double submit cannot send twice.
        await wire.setPayloads(try stagePayloads(final: true))
        await model.execute(.receiveFinal)
        XCTAssertNil(model.stage, model.message); XCTAssertFalse(model.executionReady)
        XCTAssertTrue(model.message.contains("159바이트 · 5줄"), model.message)
        let paths = await wire.paths
        XCTAssertEqual(paths, ["get_sync_handshake", "documents", "folders", "tree_orders", "document_commit", "documents", "folders", "tree_orders"])
        XCTAssertEqual(try Data(contentsOf: f.body), Data(GeneralValidationPlan.final.utf8))
        XCTAssertEqual(try f.otherRows(), other); XCTAssertFalse(policy.sendingAllowed)
        for stage in [GeneralValidationPlan.Stage.receiveWindows, .sendUpdate, .receiveFinal] {
            let rows = try Data(contentsOf: GeneralValidationJournal.url(root: journal, stage: stage)).split(separator: 10)
                .map { try JSONDecoder().decode(GeneralValidationJournal.Row.self, from: Data($0)) }
            XCTAssertEqual(rows.last?.event, .completed)
            XCTAssertEqual(rows.filter { $0.event == .attempt }.count, stage == .sendUpdate ? 1 : 3)
        }
    }
    @MainActor
    func testRuntimeClosedGateMakesNoHandshakeAndDoesNotCreateJournal() async throws {
        let (_, model, policy, wire, _, journal) = try await runtimeFixture(gateOpen: false)
        await ReceiveValidationPolicy.$override.withValue(policy) { await model.prepareExecution() }
        XCTAssertFalse(model.executionReady)
        let paths = await wire.paths; XCTAssertTrue(paths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }
    @MainActor
    func testRuntimeGateRevokedDuringReadRejectsLatePayloadAndStops() async throws {
        let (f, model, policy, wire, flag, _) = try await runtimeFixture()
        await ReceiveValidationPolicy.$override.withValue(policy) { await model.prepareExecution() }
        XCTAssertTrue(model.executionReady, model.message)
        await wire.setRevocation { flag.invalidate() }
        await model.execute(.receiveWindows)
        XCTAssertFalse(model.executionReady); XCTAssertFalse(FileManager.default.fileExists(atPath: f.body.path))
        await model.execute(.receiveWindows)
        let paths = await wire.paths; XCTAssertEqual(paths, ["get_sync_handshake", "documents"])
    }
    @MainActor
    func testRuntimeLostCommitResponsePreservesProcessingAndCannotRetry() async throws {
        let (f, model, policy, wire, _, _) = try await runtimeFixture()
        await ReceiveValidationPolicy.$override.withValue(policy) { await model.prepareExecution() }
        await model.execute(.receiveWindows)
        XCTAssertEqual(model.stage, .sendUpdate, model.message)
        await wire.setFailure(); await model.execute(.sendUpdate)
        XCTAssertFalse(model.executionReady)
        XCTAssertEqual(try Data(contentsOf: f.body), Data(GeneralValidationPlan.outgoing.utf8))
        XCTAssertEqual(try generalProductRows(f.database, "SELECT status FROM sync_contract_batches"), ["processing"])
        await model.execute(.sendUpdate)
        await ReceiveValidationPolicy.$override.withValue(policy) { await model.prepareExecution() }
        XCTAssertFalse(model.executionReady)
        let paths = await wire.paths; XCTAssertEqual(paths.filter { $0 == "document_commit" }.count, 1)
    }
    func testPreservedBaselineIsValidWithoutNewServerRead() throws {
        let baseline = try GeneralValidationRemoteBaseline.preserved()
        try baseline.validate(); XCTAssertEqual(baseline.control.content.utf8.count, 557)
        XCTAssertEqual(baseline.folders.count, 11); XCTAssertEqual(baseline.orders.count, 12)
    }
}


extension GeneralValidationJournalTests {
    func testPreservedBaselineAllowsOnlyMillisecondRoundingAndNoOtherFieldChange() throws {
        let baseline = try GeneralValidationRemoteBaseline.preserved(), original = baseline.folders[0]
        func shifted(_ seconds: Double, name: String? = nil) -> SyncV2RemoteFolder {
            .init(folderID: original.folderID, parentFolderID: original.parentFolderID, name: name ?? original.name,
                revision: original.revision, isDeleted: original.isDeleted, updatedAt: original.updatedAt.addingTimeInterval(seconds))
        }
        XCTAssertTrue(try baseline.matches(original, shifted(0.0004)))
        XCTAssertFalse(try baseline.matches(original, shifted(0.002)))
        XCTAssertFalse(try baseline.matches(original, shifted(0, name: "changed")))
        var exact = baseline; exact.timestampTolerance = 0
        XCTAssertFalse(try exact.matches(original, shifted(0.0004)))
        var tooWide = baseline; tooWide.timestampTolerance = 1
        XCTAssertThrowsError(try tooWide.validate())
    }
}


extension ReceiveValidationPolicyTests {
    func testLocalApplicationAliasDoesNotGrantUnscopedDifferentServerAccess() throws {
        let policy = ReceiveValidationPolicy(enabled: true, configuration: configuration())
        let ticket = try ready(policy)
        try policy.select(GeneralValidationPlan.server)
        try ReceiveValidationPolicy.$operation.withValue(ticket) {
            try ReceiveValidationPolicy.$localProject.withValue(GeneralValidationPlan.local.rawValue) {
                try GeneralValidationMutation.$current.withValue({}) {
                    XCTAssertThrowsError(try policy.requireLocalApplication(local: GeneralValidationPlan.local))
                    XCTAssertThrowsError(try policy.requireApplication(local: GeneralValidationPlan.local, server: GeneralValidationPlan.server))
                    XCTAssertThrowsError(try policy.requireSending())
                }
            }
        }
    }
}
