import Foundation
import Supabase

struct ValidatedAuthSession: Equatable, Sendable {
    let userID: UUID
    let email: String?
    let accessToken: String
    let refreshToken: String
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
    func signOut() async throws
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
            refreshToken: session.refreshToken
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
    @discardableResult
    func restoreSession() async -> AuthenticationState
    @discardableResult
    func signIn(email: String, password: String) async -> AuthenticationState
    @discardableResult
    func signOut() async -> AuthenticationState
}

typealias AuthenticationSleep =
    @Sendable (Duration) async throws -> Void

actor SupabaseAuthService: AuthenticationServicing {
    private struct ActiveRestore {
        let operationID: UUID
        let task: Task<AuthenticationState, Never>
    }

    private let transport: (any SupabaseAuthTransporting)?
    private let sessionStore: any SessionTokenStoring
    private let restoreTimeout: Duration
    private let sleep: AuthenticationSleep
    private var state: AuthenticationState = .localOnly
    private var activeOperationID: UUID?
    private var activeRestore: ActiveRestore?

    init(
        transport: (any SupabaseAuthTransporting)?,
        sessionStore: any SessionTokenStoring,
        restoreTimeout: Duration = .seconds(12),
        sleep: @escaping AuthenticationSleep = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.transport = transport
        self.sessionStore = sessionStore
        self.restoreTimeout = restoreTimeout
        self.sleep = sleep
    }

    func currentState() -> AuthenticationState {
        state
    }

    @discardableResult
    func restoreSession() async -> AuthenticationState {
        if state.isAuthenticated {
            return state
        }
        if let activeRestore {
            return await activeRestore.task.value
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
        if activeRestore?.operationID == operationID {
            activeRestore = nil
        }
        return result
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
        cancelActiveRestore()
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
        cancelActiveRestore()
        let operationID = beginOperation()
        state = .signedOut(.userInitiated)
        do {
            try await sessionStore.delete()
            guard isCurrent(operationID) else { return state }
            state = .signedOut(.userInitiated)
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
                    refreshToken: session.refreshToken
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

    private func cancelActiveRestore() {
        activeRestore?.task.cancel()
        activeRestore = nil
    }

    private func isCurrent(_ operationID: UUID) -> Bool {
        activeOperationID == operationID
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
