import Foundation
import XCTest
@testable import WriterPad

final class SupabaseAuthServiceTests: XCTestCase {
    func testSuccessfulLoginStoresOnlyReturnedTokensAndMasksEmail() async {
        let serverSession = session(email: "writer@example.com")
        let transport = AuthTransportStub(signInResult: .success(serverSession))
        let store = SessionStoreStub()
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store
        )

        let state = await service.signIn(
            email: "writer@example.com",
            password: "input-only-password"
        )

        XCTAssertEqual(
            state,
            .authenticated(
                AuthenticatedAccount(
                    userID: serverSession.userID,
                    maskedEmail: "w***@example.com"
                )
            )
        )
        let stored = await store.storedTokens()
        let signInCallCount = await transport.signInCallCount()
        XCTAssertEqual(
            stored,
            StoredSessionTokens(
                accessToken: serverSession.accessToken,
                refreshToken: serverSession.refreshToken
            )
        )
        XCTAssertEqual(signInCallCount, 1)
    }

    func testRestoreDoesNotAuthenticateUntilServerReturnsValidatedSession() async {
        let stale = StoredSessionTokens(
            accessToken: "stale-access",
            refreshToken: "stored-refresh"
        )
        let refreshed = session(
            email: "verified@example.com",
            accessToken: "rotated-access",
            refreshToken: "rotated-refresh"
        )
        let store = SessionStoreStub(tokens: stale)
        let transport = AuthTransportStub(
            restoreResult: .success(refreshed)
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store
        )

        let initialState = await service.currentState()
        XCTAssertEqual(initialState, .localOnly)

        let state = await service.restoreSession()
        let storedTokens = await store.storedTokens()
        let receivedTokens = await transport.receivedRestoreTokens()

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(
            storedTokens,
            StoredSessionTokens(
                accessToken: "rotated-access",
                refreshToken: "rotated-refresh"
            )
        )
        XCTAssertEqual(receivedTokens, stale)
    }

    func testAuthenticatedSessionIsNotRestoredTwice() async {
        let store = SessionStoreStub(
            tokens: StoredSessionTokens(
                accessToken: "stored-access",
                refreshToken: "single-use-refresh"
            )
        )
        let transport = AuthTransportStub(
            restoreResult: .success(session(email: "writer@example.com"))
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store
        )

        let first = await service.restoreSession()
        let second = await service.restoreSession()
        let restoreCallCount = await transport.restoreCallCount()

        XCTAssertTrue(first.isAuthenticated)
        XCTAssertEqual(second, first)
        XCTAssertEqual(restoreCallCount, 1)
    }

    func testConcurrentRestoreCallersCoalesceAndReceiveFinalState()
        async {
        let gate = AuthRestoreGate()
        let verified = session(email: "coalesced@example.com")
        let transport = AuthTransportStub(
            restoreResult: .success(verified),
            restoreGate: gate
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: SessionStoreStub(
                tokens: StoredSessionTokens(
                    accessToken: "stored-access",
                    refreshToken: "stored-refresh"
                )
            )
        )

        async let first = service.restoreSession()
        for _ in 0..<100 {
            if await transport.restoreCallCount() == 1 {
                break
            }
            await Task.yield()
        }
        async let second = service.restoreSession()
        await gate.open()
        let states = await [first, second]

        XCTAssertEqual(
            states,
            [
                .authenticated(
                    AuthenticatedAccount(
                        userID: verified.userID,
                        maskedEmail: "c***@example.com"
                    )
                ),
                .authenticated(
                    AuthenticatedAccount(
                        userID: verified.userID,
                        maskedEmail: "c***@example.com"
                    )
                ),
            ]
        )
        let restoreCallCount = await transport.restoreCallCount()
        XCTAssertEqual(restoreCallCount, 1)
    }

    func testNetworkFailureKeepsTokensButNeverShowsAuthenticated() async {
        let tokens = StoredSessionTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        let store = SessionStoreStub(tokens: tokens)
        let transport = AuthTransportStub(
            restoreResult: .failure(.networkUnavailable)
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store
        )

        let state = await service.restoreSession()
        let preservedTokens = await store.storedTokens()

        XCTAssertEqual(state, .unavailable(.networkUnavailable))
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(preservedTokens, tokens)
    }

    func testRestoreTimeoutLeavesRestoringStateAndPreservesTokens()
        async {
        let tokens = StoredSessionTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        let store = SessionStoreStub(tokens: tokens)
        let transport = AuthTransportStub(
            restoreResult: .success(
                session(email: "late@example.com")
            ),
            restoreDelay: .seconds(60)
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store,
            restoreTimeout: .seconds(1),
            sleep: { _ in }
        )

        let state = await service.restoreSession()
        let current = await service.currentState()
        let preservedTokens = await store.storedTokens()

        XCTAssertEqual(state, .unavailable(.networkUnavailable))
        XCTAssertEqual(current, state)
        XCTAssertEqual(preservedTokens, tokens)
    }

    func testRejectedRefreshTokenReasonsAreDistinctAndClearTokens() async {
        let cases: [
            (SupabaseAuthTransportError, AuthenticationSignOutReason)
        ] = [
            (.sessionExpired, .sessionExpired),
            (.refreshTokenRevoked, .refreshTokenRevoked),
            (.refreshTokenReused, .refreshTokenReused),
        ]

        for (transportError, expectedReason) in cases {
            let store = SessionStoreStub(
                tokens: StoredSessionTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            )
            let transport = AuthTransportStub(
                restoreResult: .failure(transportError)
            )
            let service = SupabaseAuthService(
                transport: transport,
                sessionStore: store
            )

            let state = await service.restoreSession()
            let storedTokens = await store.storedTokens()

            XCTAssertEqual(state, .signedOut(expectedReason))
            XCTAssertNil(storedTokens)
        }
    }

    func testKeychainFailureIsDistinct() async {
        let store = SessionStoreStub(loadError: .unexpectedStatus(-1))
        let service = SupabaseAuthService(
            transport: AuthTransportStub(),
            sessionStore: store
        )

        let state = await service.restoreSession()

        XCTAssertEqual(state, .unavailable(.keychainAccess))
        XCTAssertFalse(state.isAuthenticated)
    }

    func testSignOutClearsLocalSessionEvenWhenServerIsOffline() async {
        let store = SessionStoreStub(
            tokens: StoredSessionTokens(
                accessToken: "access",
                refreshToken: "refresh"
            )
        )
        let transport = AuthTransportStub(
            signOutError: .networkUnavailable
        )
        let service = SupabaseAuthService(
            transport: transport,
            sessionStore: store
        )

        let state = await service.signOut()
        let storedTokens = await store.storedTokens()
        let signOutCallCount = await transport.signOutCallCount()

        XCTAssertEqual(state, .signedOut(.userInitiated))
        XCTAssertNil(storedTokens)
        XCTAssertEqual(signOutCallCount, 1)
    }

    func testMissingConfigurationPreservesStoredTokensAndLocalMode() async {
        let tokens = StoredSessionTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        let store = SessionStoreStub(tokens: tokens)
        let service = SupabaseAuthService(
            transport: nil,
            sessionStore: store
        )

        let state = await service.restoreSession()
        let preservedTokens = await store.storedTokens()

        XCTAssertEqual(state, .unavailable(.configurationUnavailable))
        XCTAssertEqual(preservedTokens, tokens)
    }

    @MainActor
    func testUnauthenticatedStateDoesNotBlockLocalManuscriptSave() async throws {
        let environment = try AppEnvironment.testing()
        let authState = await environment.authenticationService.restoreSession()
        let project = try await environment.projectManager.createProject(
            named: "인증 없는 로컬 저장"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(
            loadedDocument
        )

        _ = try await environment.localDocumentStore.save(
            DocumentSaveRequest(
                projectID: project.id,
                documentID: document.id,
                relativePath: document.relativePath,
                text: "로그인 없이 저장되는 원고",
                generation: 1
            )
        )
        let loaded = try await environment.localDocumentStore.loadText(
            for: document
        )

        XCTAssertEqual(authState, .unavailable(.configurationUnavailable))
        XCTAssertEqual(loaded, "로그인 없이 저장되는 원고")
    }

    func testKeychainStoreRoundTripsAndDeletesSession() async throws {
        let store = KeychainSessionStore(
            service: "com.chocos.writerpad.tests.\(UUID().uuidString)",
            account: "isolated-session"
        )
        let tokens = StoredSessionTokens(
            accessToken: "integration-access",
            refreshToken: "integration-refresh"
        )

        try await store.delete()
        let initiallyStored = try await store.load()
        XCTAssertNil(initiallyStored)

        try await store.save(tokens)
        let roundTripped = try await store.load()
        XCTAssertEqual(roundTripped, tokens)

        try await store.delete()
        let deleted = try await store.load()
        XCTAssertNil(deleted)
    }

    private func session(
        email: String?,
        accessToken: String = "new-access",
        refreshToken: String = "new-refresh"
    ) -> ValidatedAuthSession {
        ValidatedAuthSession(
            userID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000091"
            )!,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }
}

private actor SessionStoreStub: SessionTokenStoring {
    private var tokens: StoredSessionTokens?
    private let loadError: KeychainSessionStoreError?

    init(
        tokens: StoredSessionTokens? = nil,
        loadError: KeychainSessionStoreError? = nil
    ) {
        self.tokens = tokens
        self.loadError = loadError
    }

    func load() throws -> StoredSessionTokens? {
        if let loadError {
            throw loadError
        }
        return tokens
    }

    func save(_ tokens: StoredSessionTokens) {
        self.tokens = tokens
    }

    func delete() {
        tokens = nil
    }

    func storedTokens() -> StoredSessionTokens? {
        tokens
    }
}

private actor AuthTransportStub: SupabaseAuthTransporting {
    private let signInResult: Result<
        ValidatedAuthSession,
        SupabaseAuthTransportError
    >
    private let restoreResult: Result<
        ValidatedAuthSession,
        SupabaseAuthTransportError
    >
    private let signOutError: SupabaseAuthTransportError?
    private let restoreDelay: Duration?
    private let restoreGate: AuthRestoreGate?
    private var signInCalls = 0
    private var signOutCalls = 0
    private var restoreCalls = 0
    private var restoreTokens: StoredSessionTokens?

    init(
        signInResult: Result<
            ValidatedAuthSession,
            SupabaseAuthTransportError
        > = .failure(.serverRejected),
        restoreResult: Result<
            ValidatedAuthSession,
            SupabaseAuthTransportError
        > = .failure(.serverRejected),
        signOutError: SupabaseAuthTransportError? = nil,
        restoreDelay: Duration? = nil,
        restoreGate: AuthRestoreGate? = nil
    ) {
        self.signInResult = signInResult
        self.restoreResult = restoreResult
        self.signOutError = signOutError
        self.restoreDelay = restoreDelay
        self.restoreGate = restoreGate
    }

    func signIn(
        email: String,
        password: String
    ) throws -> ValidatedAuthSession {
        signInCalls += 1
        return try signInResult.get()
    }

    func restore(
        tokens: StoredSessionTokens
    ) async throws -> ValidatedAuthSession {
        restoreCalls += 1
        restoreTokens = tokens
        await restoreGate?.wait()
        if let restoreDelay {
            try await ContinuousClock().sleep(for: restoreDelay)
        }
        return try restoreResult.get()
    }

    func signOut() throws {
        signOutCalls += 1
        if let signOutError {
            throw signOutError
        }
    }

    func signInCallCount() -> Int {
        signInCalls
    }

    func signOutCallCount() -> Int {
        signOutCalls
    }

    func restoreCallCount() -> Int {
        restoreCalls
    }

    func receivedRestoreTokens() -> StoredSessionTokens? {
        restoreTokens
    }
}

private actor AuthRestoreGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
