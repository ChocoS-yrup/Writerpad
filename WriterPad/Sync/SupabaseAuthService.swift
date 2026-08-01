import Foundation
import Supabase

struct ValidatedAuthSession: Equatable, Sendable {
    let userID: UUID
    let email: String?
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date?

    init(
        userID: UUID,
        email: String?,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date? = nil
    ) {
        self.userID = userID
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

enum SupabaseAuthTransportError: Error, Equatable, Sendable {
    case invalidCredentials
    case sessionExpired
    case refreshTokenRevoked
    case refreshTokenReused
    case networkUnavailable
    case serverRejected
}

protocol SupabaseAuthTransporting: Sendable {
    func signIn(email: String, password: String) async throws
        -> ValidatedAuthSession
    func restore(tokens: StoredSessionTokens) async throws
        -> ValidatedAuthSession
    func refresh(tokens: StoredSessionTokens) async throws
        -> ValidatedAuthSession
    func signOut() async throws
}

extension SupabaseAuthTransporting {
    func refresh(
        tokens: StoredSessionTokens
    ) async throws -> ValidatedAuthSession {
        try await restore(tokens: tokens)
    }
}

actor LiveSupabaseAuthTransport: SupabaseAuthTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func signIn(
        email: String,
        password: String
    ) async throws -> ValidatedAuthSession {
        do {
            return validated(
                try await client.auth.signIn(email: email, password: password)
            )
        } catch {
            throw map(error, isRestore: false)
        }
    }

    func restore(
        tokens: StoredSessionTokens
    ) async throws -> ValidatedAuthSession {
        do {
            // setSession refreshes an expired access token and calls /user for an
            // unexpired token, so a cached user alone can never authenticate.
            return validated(
                try await client.auth.setSession(
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken
                )
            )
        } catch {
            throw map(error, isRestore: true)
        }
    }

    func refresh(
        tokens: StoredSessionTokens
    ) async throws -> ValidatedAuthSession {
        do {
            return validated(
                try await client.auth.refreshSession(
                    refreshToken: tokens.refreshToken
                )
            )
        } catch {
            throw map(error, isRestore: true)
        }
    }

    func signOut() async throws {
        do {
            try await client.auth.signOut()
        } catch {
            throw map(error, isRestore: false)
        }
    }

    private func validated(_ session: Session) -> ValidatedAuthSession {
        ValidatedAuthSession(
            userID: session.user.id,
            email: session.user.email,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }

    private func map(
        _ error: any Error,
        isRestore: Bool
    ) -> SupabaseAuthTransportError {
        if let authError = error as? AuthError {
            switch authError.errorCode {
            case .sessionExpired:
                return .sessionExpired
            case .refreshTokenNotFound:
                return .refreshTokenRevoked
            case .refreshTokenAlreadyUsed:
                return .refreshTokenReused
            case .invalidCredentials:
                return isRestore ? .refreshTokenRevoked : .invalidCredentials
            default:
                return .serverRejected
            }
        }
        if let urlError = error as? URLError,
           urlError.code != .userAuthenticationRequired {
            return .networkUnavailable
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkUnavailable
        }
        return .serverRejected
    }
}

struct AuthenticatedAccount: Equatable, Sendable {
    let userID: UUID
    let maskedEmail: String?
}

enum AuthenticationSignOutReason: Equatable, Sendable {
    case noStoredSession
    case userInitiated
    case sessionExpired
    case refreshTokenRevoked
    case refreshTokenReused
}

enum AuthenticationFailure: Equatable, Sendable {
    case configurationUnavailable
    case invalidCredentials
    case networkUnavailable
    case keychainAccess
    case serverRejected
}

enum AuthenticationState: Equatable, Sendable {
    case localOnly
    case restoring
    case authenticated(AuthenticatedAccount)
    case signedOut(AuthenticationSignOutReason)
    case unavailable(AuthenticationFailure)

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }
}

protocol AuthenticationServicing: Sendable {
    func currentState() async -> AuthenticationState
    func stateUpdates() async -> AsyncStream<AuthenticationState>
    @discardableResult
    func restoreSession() async -> AuthenticationState
    @discardableResult
    func refreshSession(force: Bool) async -> AuthenticationState
    @discardableResult
    func signIn(email: String, password: String) async -> AuthenticationState
    @discardableResult
    func signOut() async -> AuthenticationState
}

extension AuthenticationServicing {
    func stateUpdates() async -> AsyncStream<AuthenticationState> {
        AsyncStream { $0.finish() }
    }

    func refreshSession(force: Bool) async -> AuthenticationState {
        _ = force
        return await restoreSession()
    }
}

typealias AuthenticationSleep =
    @Sendable (Duration) async throws -> Void
typealias AuthenticationNow = @Sendable () -> Date

actor SupabaseAuthService: AuthenticationServicing {
    private struct ActiveRestore {
        let operationID: UUID
        let task: Task<AuthenticationState, Never>
    }

    private let transport: (any SupabaseAuthTransporting)?
    private let sessionStore: any SessionTokenStoring
    private let restoreTimeout: Duration
    private let refreshMargin: TimeInterval
    private let sleep: AuthenticationSleep
    private let now: AuthenticationNow
    private var stateObservers: [
        UUID: AsyncStream<AuthenticationState>.Continuation
    ] = [:]
    private var state: AuthenticationState = .localOnly {
        didSet {
            guard oldValue != state else { return }
            stateObservers.values.forEach { $0.yield(state) }
        }
    }
    private var activeOperationID: UUID?
    private var activeRestore: ActiveRestore?
    private var activeRefresh: ActiveRestore?
    private var automaticRefreshTask: Task<Void, Never>?
    private var refreshRetryTask: Task<Void, Never>?
    private var sessionExpiresAt: Date?
#if DEBUG
    private var restoreCompletionProbe:
        (@Sendable () async -> Void)?
#endif

    init(
        transport: (any SupabaseAuthTransporting)?,
        sessionStore: any SessionTokenStoring,
        restoreTimeout: Duration = .seconds(12),
        refreshMargin: TimeInterval = 5 * 60,
        now: @escaping AuthenticationNow = Date.init,
        sleep: @escaping AuthenticationSleep = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.sessionStore = sessionStore
        self.restoreTimeout = restoreTimeout
        self.refreshMargin = refreshMargin
        self.now = now
        self.sleep = sleep
    }

    func currentState() -> AuthenticationState {
        state
    }

    func stateUpdates() async -> AsyncStream<AuthenticationState> {
        let observerID = UUID()
        return AsyncStream { continuation in
            stateObservers[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateObserver(observerID) }
            }
        }
    }

    private func removeStateObserver(_ observerID: UUID) {
        stateObservers[observerID] = nil
    }

    @discardableResult
    func restoreSession() async -> AuthenticationState {
        if state.isAuthenticated {
            return await refreshSession(force: false)
        }
        if let activeRestore {
            return await activeRestore.task.value
        }
        // beginOperation은 단일 activeOperationID를 덮어쓰므로 진행 중인
        // refresh와 겹치면 성공한 refresh 결과가 stale로 폐기될 수 있다.
        if let activeRefresh {
            return await activeRefresh.task.value
        }
        guard let transport else {
            state = .unavailable(.configurationUnavailable)
            return state
        }

        let operationID = beginOperation()
        state = .restoring
        let task = Task { [weak self] in
            guard let self else {
                return AuthenticationState.unavailable(
                    .serverRejected
                )
            }
            return await self.performRestore(
                transport: transport,
                operationID: operationID
            )
        }
        activeRestore = ActiveRestore(
            operationID: operationID,
            task: task
        )
        let result = await task.value
#if DEBUG
        let completionProbe = restoreCompletionProbe
        restoreCompletionProbe = nil
        await completionProbe?()
#endif
        if activeRestore?.operationID == operationID {
            activeRestore = nil
        }
        return result
    }

#if DEBUG
    func installRestoreCompletionProbe(
        _ probe: @escaping @Sendable () async -> Void
    ) {
        restoreCompletionProbe = probe
    }
#endif

    @discardableResult
    func refreshSession(force: Bool) async -> AuthenticationState {
        if let activeRefresh {
            return await activeRefresh.task.value
        }
        guard state.isAuthenticated else {
            return await restoreSession()
        }
        // beginOperation은 단일 activeOperationID를 덮어쓰므로 진행 중인
        // restore와 겹치면 성공한 restore 결과가 stale로 폐기될 수 있다.
        if let activeRestore {
            return await activeRestore.task.value
        }
        if !force {
            guard let sessionExpiresAt else { return state }
            if sessionExpiresAt.timeIntervalSince(now()) > refreshMargin {
                return state
            }
        }
        guard let transport else {
            state = .unavailable(.configurationUnavailable)
            return state
        }

        let operationID = beginOperation()
        let task = Task { [weak self] in
            guard let self else {
                return AuthenticationState.unavailable(.serverRejected)
            }
            return await self.performRefresh(
                transport: transport,
                operationID: operationID
            )
        }
        activeRefresh = ActiveRestore(
            operationID: operationID,
            task: task
        )
        let result = await task.value
        if activeRefresh?.operationID == operationID {
            activeRefresh = nil
        }
        return result
    }

    private func performRefresh(
        transport: any SupabaseAuthTransporting,
        operationID: UUID
    ) async -> AuthenticationState {
        let storedTokens: StoredSessionTokens
        do {
            guard let tokens = try await sessionStore.load() else {
                guard isCurrent(operationID) else { return state }
                state = .signedOut(.noStoredSession)
                return state
            }
            storedTokens = tokens
        } catch {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(.keychainAccess)
            return state
        }

        let outcome = AuthenticationRestoreOutcome()
        let transportTask = Task {
            do {
                let session = try await transport.refresh(tokens: storedTokens)
                await outcome.resolve(.success(session))
            } catch let error as SupabaseAuthTransportError {
                await outcome.resolve(.failure(error))
            } catch {
                await outcome.resolve(.failure(.serverRejected))
            }
        }
        let timeoutTask = Task {
            do {
                try await sleep(restoreTimeout)
                await outcome.resolve(.failure(.networkUnavailable))
            } catch {
                // 갱신 또는 다른 인증 작업이 먼저 끝났다.
            }
        }
        let result = await outcome.value()
        transportTask.cancel()
        timeoutTask.cancel()

        guard isCurrent(operationID) else { return state }
        switch result {
        case .success(let session):
            return await accept(session, operationID: operationID)
        case .failure(.networkUnavailable):
            state = .unavailable(.networkUnavailable)
            scheduleRefreshRetry()
            return state
        case .failure(let error):
            return await handleRestoreFailure(
                error,
                operationID: operationID
            )
        }
    }

    private func performRestore(
        transport: any SupabaseAuthTransporting,
        operationID: UUID
    ) async -> AuthenticationState {
        let storedTokens: StoredSessionTokens
        do {
            guard let tokens = try await sessionStore.load() else {
                guard isCurrent(operationID) else { return state }
                state = .signedOut(.noStoredSession)
                return state
            }
            guard isCurrent(operationID) else { return state }
            storedTokens = tokens
        } catch {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(.keychainAccess)
            return state
        }

        let outcome = AuthenticationRestoreOutcome()
        let transportTask = Task {
            do {
                let session = try await transport.restore(
                    tokens: storedTokens
                )
                await outcome.resolve(.success(session))
            } catch let error as SupabaseAuthTransportError {
                await outcome.resolve(.failure(error))
            } catch {
                await outcome.resolve(.failure(.serverRejected))
            }
        }
        let timeout = restoreTimeout
        let sleep = self.sleep
        let timeoutTask = Task {
            do {
                try await sleep(timeout)
                await outcome.resolve(.failure(.networkUnavailable))
            } catch {
                // 정상 완료 또는 다른 인증 작업이 먼저 끝나 취소된 경로다.
            }
        }
        let result = await outcome.value()
        transportTask.cancel()
        timeoutTask.cancel()

        switch result {
        case .success(let session):
            guard isCurrent(operationID) else { return state }
            return await accept(session, operationID: operationID)
        case .failure(let error):
            guard isCurrent(operationID) else { return state }
            return await handleRestoreFailure(
                error,
                operationID: operationID
            )
        }
    }

    @discardableResult
    func signIn(
        email: String,
        password: String
    ) async -> AuthenticationState {
        cancelActiveAuthenticationTasks()
        guard let transport else {
            state = .unavailable(.configurationUnavailable)
            return state
        }
        guard
            !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !password.isEmpty
        else {
            state = .unavailable(.invalidCredentials)
            return state
        }

        let operationID = beginOperation()
        do {
            let session = try await transport.signIn(
                email: email,
                password: password
            )
            guard isCurrent(operationID) else { return state }
            return await accept(session, operationID: operationID)
        } catch let error as SupabaseAuthTransportError {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(failure(for: error))
            return state
        } catch {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(.serverRejected)
            return state
        }
    }

    @discardableResult
    func signOut() async -> AuthenticationState {
        cancelActiveAuthenticationTasks()
        let operationID = beginOperation()
        state = .signedOut(.userInitiated)
        do {
            try await sessionStore.delete()
            guard isCurrent(operationID) else { return state }
            state = .signedOut(.userInitiated)
            sessionExpiresAt = nil
        } catch {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(.keychainAccess)
        }
        if let transport {
            try? await transport.signOut()
        }
        return state
    }

    private func accept(
        _ session: ValidatedAuthSession,
        operationID: UUID
    ) async -> AuthenticationState {
        do {
            try await sessionStore.save(
                StoredSessionTokens(
                    accessToken: session.accessToken,
                    refreshToken: session.refreshToken,
                    expiresAt: session.expiresAt
                )
            )
        } catch {
            guard isCurrent(operationID) else { return state }
            if let transport {
                try? await transport.signOut()
            }
            state = .unavailable(.keychainAccess)
            return state
        }
        guard isCurrent(operationID) else { return state }

        state = .authenticated(
            AuthenticatedAccount(
                userID: session.userID,
                maskedEmail: Self.masked(session.email)
            )
        )
        sessionExpiresAt = session.expiresAt
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
        scheduleAutomaticRefresh()
        return state
    }

    private func handleRestoreFailure(
        _ error: SupabaseAuthTransportError,
        operationID: UUID
    ) async -> AuthenticationState {
        let reason: AuthenticationSignOutReason?
        switch error {
        case .sessionExpired:
            reason = .sessionExpired
        case .refreshTokenRevoked:
            reason = .refreshTokenRevoked
        case .refreshTokenReused:
            reason = .refreshTokenReused
        case .networkUnavailable:
            state = .unavailable(.networkUnavailable)
            return state
        case .invalidCredentials, .serverRejected:
            reason = nil
        }

        guard let reason else {
            state = .unavailable(.serverRejected)
            return state
        }
        do {
            try await sessionStore.delete()
            guard isCurrent(operationID) else { return state }
            state = .signedOut(reason)
            sessionExpiresAt = nil
            automaticRefreshTask?.cancel()
            automaticRefreshTask = nil
            refreshRetryTask?.cancel()
            refreshRetryTask = nil
        } catch {
            guard isCurrent(operationID) else { return state }
            state = .unavailable(.keychainAccess)
        }
        return state
    }

    private func failure(
        for error: SupabaseAuthTransportError
    ) -> AuthenticationFailure {
        switch error {
        case .invalidCredentials:
            .invalidCredentials
        case .networkUnavailable:
            .networkUnavailable
        case .sessionExpired, .refreshTokenRevoked, .refreshTokenReused,
             .serverRejected:
            .serverRejected
        }
    }

    private static func masked(_ email: String?) -> String? {
        guard
            let email,
            let separator = email.firstIndex(of: "@"),
            separator != email.startIndex
        else {
            return nil
        }
        let first = email[email.startIndex]
        let domain = email[email.index(after: separator)...]
        return "\(first)***@\(domain)"
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        return operationID
    }

    private func scheduleAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        guard let sessionExpiresAt else { return }
        let delay = max(
            0,
            sessionExpiresAt.timeIntervalSince(now()) - refreshMargin
        )
        let sleep = self.sleep
        automaticRefreshTask = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                try Task.checkCancellation()
            } catch {
                return
            }
            _ = await self?.refreshSession(force: true)
        }
    }

    private func scheduleRefreshRetry() {
        guard refreshRetryTask == nil else { return }
        let sleep = self.sleep
        refreshRetryTask = Task { [weak self] in
            do {
                try await sleep(.seconds(30))
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            await self.clearRefreshRetryTask()
            _ = await self.restoreSession()
        }
    }

    private func clearRefreshRetryTask() {
        refreshRetryTask = nil
    }

    private func cancelActiveAuthenticationTasks() {
        activeRestore?.task.cancel()
        activeRestore = nil
        activeRefresh?.task.cancel()
        activeRefresh = nil
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
        refreshRetryTask?.cancel()
        refreshRetryTask = nil
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        let isCurrent = activeOperationID == operationID
        if !isCurrent {
            SyncV2Diagnostics.supersededAuthOperation(
                operationID: operationID,
                activeOperationID: activeOperationID
            )
        }
        return isCurrent
    }
}

private actor AuthenticationRestoreOutcome {
    private var result:
        Result<ValidatedAuthSession, SupabaseAuthTransportError>?
    private var continuations: [
        CheckedContinuation<
            Result<ValidatedAuthSession, SupabaseAuthTransportError>,
            Never
        >
    ] = []

    func resolve(
        _ result:
            Result<ValidatedAuthSession, SupabaseAuthTransportError>
    ) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    func value() async
        -> Result<ValidatedAuthSession, SupabaseAuthTransportError> {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
