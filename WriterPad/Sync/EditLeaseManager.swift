import Foundation
import Network
import Supabase

struct AcquireEditLeaseParameters: Encodable, Equatable, Sendable {
    let documentID: UUID
    let deviceID: UUID
    let ttlSeconds: Int

    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case ttlSeconds = "p_ttl_seconds"
    }
}

struct RenewEditLeaseParameters: Encodable, Equatable, Sendable {
    let documentID: UUID
    let deviceID: UUID
    let leaseToken: UUID
    let ttlSeconds: Int

    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case leaseToken = "p_lease_token"
        case ttlSeconds = "p_ttl_seconds"
    }
}

struct ReleaseEditLeaseParameters: Encodable, Equatable, Sendable {
    let documentID: UUID
    let deviceID: UUID
    let leaseToken: UUID

    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
        case leaseToken = "p_lease_token"
    }
}

struct InspectEditLeaseParameters: Encodable, Equatable, Sendable {
    let documentID: UUID
    let deviceID: UUID

    enum CodingKeys: String, CodingKey {
        case documentID = "p_document_id"
        case deviceID = "p_device_id"
    }
}

enum RemoteEditLeaseState: String, Decodable, Equatable, Sendable {
    case available
    case heldByMe = "held_by_me"
    case heldByOther = "held_by_other"
}

struct EditLeaseMutationResult: Decodable, Equatable, Sendable {
    let documentID: UUID
    let leaseToken: UUID
    let deviceID: UUID
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case leaseToken = "lease_token"
        case deviceID = "device_id"
        case expiresAt = "expires_at"
    }

    init(
        documentID: UUID,
        leaseToken: UUID,
        deviceID: UUID,
        expiresAt: Date
    ) {
        self.documentID = documentID
        self.leaseToken = leaseToken
        self.deviceID = deviceID
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        leaseToken = try values.decode(UUID.self, forKey: .leaseToken)
        deviceID = try values.decode(UUID.self, forKey: .deviceID)
        let timestamp = try values.decode(String.self, forKey: .expiresAt)
        guard let date = EditLeaseTimestamp.decode(timestamp) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt,
                in: values,
                debugDescription: "Invalid lease expires_at timestamp."
            )
        }
        expiresAt = date
    }
}

struct EditLeaseInspectionResult: Decodable, Equatable, Sendable {
    let documentID: UUID
    let state: RemoteEditLeaseState
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case state
        case expiresAt = "expires_at"
    }

    init(
        documentID: UUID,
        state: RemoteEditLeaseState,
        expiresAt: Date?
    ) {
        self.documentID = documentID
        self.state = state
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        state = try values.decode(RemoteEditLeaseState.self, forKey: .state)
        if let timestamp = try values.decodeIfPresent(
            String.self,
            forKey: .expiresAt
        ) {
            guard let date = EditLeaseTimestamp.decode(timestamp) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt,
                    in: values,
                    debugDescription: "Invalid lease expires_at timestamp."
                )
            }
            expiresAt = date
        } else {
            expiresAt = nil
        }
    }
}

private enum EditLeaseTimestamp {
    static func decode(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return seconds.date(from: value)
    }
}

protocol EditLeaseTransporting: Sendable {
    func acquire(
        _ parameters: AcquireEditLeaseParameters
    ) async throws -> EditLeaseMutationResult
    func renew(
        _ parameters: RenewEditLeaseParameters
    ) async throws -> EditLeaseMutationResult
    func release(
        _ parameters: ReleaseEditLeaseParameters
    ) async throws -> Bool
    func inspect(
        _ parameters: InspectEditLeaseParameters
    ) async throws -> EditLeaseInspectionResult
}

actor LiveEditLeaseTransport: EditLeaseTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func acquire(
        _ parameters: AcquireEditLeaseParameters
    ) async throws -> EditLeaseMutationResult {
        try await rpc("acquire_edit_lease", parameters: parameters)
    }

    func renew(
        _ parameters: RenewEditLeaseParameters
    ) async throws -> EditLeaseMutationResult {
        try await rpc("renew_edit_lease", parameters: parameters)
    }

    func release(
        _ parameters: ReleaseEditLeaseParameters
    ) async throws -> Bool {
        try await rpc("release_edit_lease", parameters: parameters)
    }

    func inspect(
        _ parameters: InspectEditLeaseParameters
    ) async throws -> EditLeaseInspectionResult {
        try await rpc("get_edit_lease", parameters: parameters)
    }

    private func rpc<Parameters: Encodable, Result: Decodable>(
        _ name: String,
        parameters: Parameters
    ) async throws -> Result {
        do {
            let response: PostgrestResponse<Result> = try await client
                .rpc(name, params: parameters)
                .execute()
            return response.value
        } catch let error as PostgrestError {
            throw SyncV2CommitTransportError.postgrest(
                message: error.message,
                postgresCode: error.code,
                detail: error.detail
            )
        } catch let error as URLError {
            throw SyncV2CommitTransportError.url(code: error.code)
        } catch is DecodingError {
            throw SyncV2CommitTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw SyncV2CommitTransportError.url(
                    code: URLError.Code(rawValue: nsError.code)
                )
            }
            throw SyncV2CommitTransportError.unknown(
                message: error.localizedDescription
            )
        }
    }
}

protocol EditLeaseClienting: Sendable {
    func acquire(
        documentID: UUID,
        deviceID: UUID,
        ttlSeconds: Int
    ) async throws -> EditLeaseMutationResult
    func renew(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID,
        ttlSeconds: Int
    ) async throws -> EditLeaseMutationResult
    func release(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID
    ) async throws -> Bool
    func inspect(
        documentID: UUID,
        deviceID: UUID
    ) async throws -> EditLeaseInspectionResult
}

actor EditLeaseClient: EditLeaseClienting {
    private let transport: any EditLeaseTransporting

    init(transport: any EditLeaseTransporting) {
        self.transport = transport
    }

    func acquire(
        documentID: UUID,
        deviceID: UUID,
        ttlSeconds: Int
    ) async throws -> EditLeaseMutationResult {
        guard Self.valid(ttlSeconds) else {
            throw SyncV2ClientError.remote(
                code: .invalidArgument,
                detail: nil
            )
        }
        return try await mutation(
            documentID: documentID,
            deviceID: deviceID
        ) {
            try await transport.acquire(
                AcquireEditLeaseParameters(
                    documentID: documentID,
                    deviceID: deviceID,
                    ttlSeconds: ttlSeconds
                )
            )
        }
    }

    func renew(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID,
        ttlSeconds: Int
    ) async throws -> EditLeaseMutationResult {
        guard Self.valid(ttlSeconds) else {
            throw SyncV2ClientError.remote(
                code: .invalidArgument,
                detail: nil
            )
        }
        let result = try await mutation(
            documentID: documentID,
            deviceID: deviceID
        ) {
            try await transport.renew(
                RenewEditLeaseParameters(
                    documentID: documentID,
                    deviceID: deviceID,
                    leaseToken: leaseToken,
                    ttlSeconds: ttlSeconds
                )
            )
        }
        guard result.leaseToken == leaseToken else {
            throw SyncV2ClientError.invalidResponse
        }
        return result
    }

    func release(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID
    ) async throws -> Bool {
        do {
            return try await transport.release(
                ReleaseEditLeaseParameters(
                    documentID: documentID,
                    deviceID: deviceID,
                    leaseToken: leaseToken
                )
            )
        } catch let error as SyncV2CommitTransportError {
            throw SyncV2Client.classify(error)
        } catch let error as SyncV2ClientError {
            throw error
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    func inspect(
        documentID: UUID,
        deviceID: UUID
    ) async throws -> EditLeaseInspectionResult {
        do {
            let result = try await transport.inspect(
                InspectEditLeaseParameters(
                    documentID: documentID,
                    deviceID: deviceID
                )
            )
            guard result.documentID == documentID else {
                throw SyncV2ClientError.invalidResponse
            }
            return result
        } catch let error as SyncV2CommitTransportError {
            throw SyncV2Client.classify(error)
        } catch let error as SyncV2ClientError {
            throw error
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    private func mutation(
        documentID: UUID,
        deviceID: UUID,
        operation: () async throws -> EditLeaseMutationResult
    ) async throws -> EditLeaseMutationResult {
        do {
            let result = try await operation()
            guard
                result.documentID == documentID,
                result.deviceID == deviceID
            else {
                throw SyncV2ClientError.invalidResponse
            }
            return result
        } catch let error as SyncV2CommitTransportError {
            throw SyncV2Client.classify(error)
        } catch let error as SyncV2ClientError {
            throw error
        } catch {
            throw SyncV2ClientError.serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: nil,
                    message: error.localizedDescription,
                    detail: nil
                )
            )
        }
    }

    private static func valid(_ ttlSeconds: Int) -> Bool {
        (30 ... 120).contains(ttlSeconds)
    }
}

protocol SyncV2DocumentRevisionProviding: Sendable {
    func serverRevision(for documentID: UUID) async throws -> Int64?
}

enum EditLeaseDisplayState: Equatable, Sendable {
    case localOnly
    case acquiring
    case held(expiresAt: Date)
    case heldByOther(expiresAt: Date?)
    case offlineEditing
    case authenticationRequired
    case unavailable
}

protocol EditLeaseManaging: Sendable {
    func stateUpdates(
        documentID: UUID
    ) async -> AsyncStream<EditLeaseDisplayState>
    func beginEditing(documentID: UUID) async -> EditLeaseDisplayState
    func refreshEditing(documentID: UUID) async -> EditLeaseDisplayState
    func ensureLeaseForActiveLiveDocument(
        documentID: UUID,
        serverRevision: Int64
    ) async
    func documentBecameTombstone(documentID: UUID) async
    func offlineDisplayState(documentID: UUID) async
        -> EditLeaseDisplayState
    func endEditing(documentID: UUID) async
    func leaseTokenForCommit(
        documentID: UUID,
        deviceID: UUID,
        baseRevision: Int64
    ) async throws -> UUID?
    func commitSucceeded(
        documentID: UUID,
        deviceID: UUID,
        isDeleted: Bool
    ) async
    func commitFailed(
        documentID: UUID,
        deviceID: UUID,
        error: SyncV2ClientError
    ) async
    func releaseAll() async
}

extension EditLeaseManaging {
    func ensureLeaseForActiveLiveDocument(
        documentID: UUID,
        serverRevision: Int64
    ) async {
        _ = (documentID, serverRevision)
    }

    func documentBecameTombstone(documentID: UUID) async {
        _ = documentID
    }
}

typealias EditLeaseSleep = @Sendable (Duration) async throws -> Void

protocol EditLeaseConnectivityMonitoring: AnyObject, Sendable {
    func start(
        handler: @escaping @Sendable (_ isConnected: Bool) -> Void
    )
    func cancel()
}

final class EditLeaseConnectivityMonitor:
    EditLeaseConnectivityMonitoring,
    @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(
        label: "com.chocos.writerpad.edit-lease-network"
    )
    private let lock = NSLock()
    private var isStarted = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
    }

    func start(
        handler: @escaping @Sendable (_ isConnected: Bool) -> Void
    ) {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        lock.unlock()
        monitor.pathUpdateHandler = { path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        lock.unlock()
        monitor.cancel()
    }
}

actor EditLeaseManager: EditLeaseManaging {
    static let leaseTTLSeconds = 90
    static let heartbeatInterval: Duration = .seconds(45)
    static let transientRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(5),
    ]

    private struct LeaseKey: Hashable, Sendable {
        let documentID: UUID
        let deviceID: UUID
    }

    private struct Entry {
        var token: UUID?
        var expiresAt: Date?
        var activeReferences: Int
        var requiresLease: Bool
        var state: EditLeaseDisplayState
        var serverRevision: Int64?
        var lifecycleSequence: UInt64
        var retryAttempt: Int
    }

    private let client: any EditLeaseClienting
    private let revisionProvider: any SyncV2DocumentRevisionProviding
    private let deviceIdentityProvider: any DeviceIdentityProviding
    private let now: @Sendable () -> Date
    private let sleep: EditLeaseSleep
    private let isEnabled: @Sendable () -> Bool
    private let authenticationState:
        (@Sendable () async -> AuthenticationState)?
    private var entries: [LeaseKey: Entry] = [:]
    private var heartbeatTasks: [LeaseKey: Task<Void, Never>] = [:]
    private struct Acquisition {
        let id: UUID
        let task: Task<EditLeaseMutationResult, any Error>
    }
    private var acquisitionTasks: [LeaseKey: Acquisition] = [:]
    private var retryTasks: [LeaseKey: Task<Void, Never>] = [:]
    private var stateObservers: [
        UUID: [UUID: AsyncStream<EditLeaseDisplayState>.Continuation]
    ] = [:]

    init(
        client: any EditLeaseClienting,
        revisionProvider: any SyncV2DocumentRevisionProviding,
        deviceIdentityProvider: any DeviceIdentityProviding,
        now: @escaping @Sendable () -> Date = Date.init,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        authenticationState:
            (@Sendable () async -> AuthenticationState)? = nil,
        sleep: @escaping EditLeaseSleep = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.client = client
        self.revisionProvider = revisionProvider
        self.deviceIdentityProvider = deviceIdentityProvider
        self.now = now
        self.isEnabled = isEnabled
        self.authenticationState = authenticationState
        self.sleep = sleep
    }

    func stateUpdates(
        documentID: UUID
    ) -> AsyncStream<EditLeaseDisplayState> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            stateObservers[documentID, default: [:]][observerID] =
                continuation
            if let state = entries.first(where: {
                $0.key.documentID == documentID
            })?.value.state {
                continuation.yield(state)
            }
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeStateObserver(
                        documentID: documentID,
                        observerID: observerID
                    )
                }
            }
        }
    }

    func beginEditing(
        documentID: UUID
    ) async -> EditLeaseDisplayState {
        guard isEnabled() else { return .localOnly }
        let deviceID: UUID
        do {
            let identifier = try await deviceIdentityProvider
                .currentIdentifier()
            deviceID = identifier.uuid
        } catch {
            return .unavailable
        }
        let key = LeaseKey(documentID: documentID, deviceID: deviceID)
        var entry = entries[key] ?? Entry(
            token: nil,
            expiresAt: nil,
            activeReferences: 0,
            requiresLease: false,
            state: .localOnly,
            serverRevision: nil,
            lifecycleSequence: 0,
            retryAttempt: 0
        )
        entry.activeReferences += 1
        entries[key] = entry

        let revision: Int64?
        do {
            revision = try await revisionProvider.serverRevision(
                for: documentID
            )
        } catch {
            entries[key]?.state = .unavailable
            publish(.unavailable, documentID: documentID)
            return .unavailable
        }
        guard let revision, revision > 0 else {
            entries[key]?.requiresLease = false
            entries[key]?.serverRevision = nil
            entries[key]?.state = .localOnly
            return .localOnly
        }
        entries[key]?.requiresLease = true
        entries[key]?.serverRevision = revision
        let lifecycleSequence = entries[key]?.lifecycleSequence
        if let authenticationDisplayState =
            await authenticationDisplayState() {
            entries[key]?.state = authenticationDisplayState
            publish(authenticationDisplayState, documentID: documentID)
            return authenticationDisplayState
        }
        do {
            _ = try await validToken(for: key)
            return entries[key]?.state ?? .unavailable
        } catch let error as SyncV2ClientError {
            guard entries[key]?.lifecycleSequence == lifecycleSequence,
                  entries[key]?.requiresLease == true
            else { return entries[key]?.state ?? .localOnly }
            let state = Self.displayState(for: error)
            entries[key]?.state = state
            publish(state, documentID: documentID)
            scheduleRecoveryAfterAcquireFailure(error, for: key)
            return state
        } catch {
            guard entries[key]?.lifecycleSequence == lifecycleSequence,
                  entries[key]?.requiresLease == true
            else { return entries[key]?.state ?? .localOnly }
            entries[key]?.state = .unavailable
            publish(.unavailable, documentID: documentID)
            return .unavailable
        }
    }

    func refreshEditing(
        documentID: UUID
    ) async -> EditLeaseDisplayState {
        guard isEnabled() else { return .localOnly }
        let identifier: DeviceIdentifier
        do {
            identifier = try await deviceIdentityProvider
                .currentIdentifier()
        } catch {
            return .unavailable
        }
        let key = LeaseKey(
            documentID: documentID,
            deviceID: identifier.uuid
        )
        guard var entry = entries[key], entry.activeReferences > 0 else {
            return .localOnly
        }
        guard entry.requiresLease else { return .localOnly }
        if let authenticationDisplayState =
            await authenticationDisplayState() {
            entry.state = authenticationDisplayState
            entries[key] = entry
            return authenticationDisplayState
        }
        if entry.token != nil {
            await heartbeat(key)
            return entries[key]?.state ?? .unavailable
        }
        do {
            _ = try await validToken(for: key)
            return entries[key]?.state ?? .unavailable
        } catch let error as SyncV2ClientError {
            let state = Self.displayState(for: error)
            entry.state = state
            entries[key] = entry
            return state
        } catch {
            entry.state = .unavailable
            entries[key] = entry
            return .unavailable
        }
    }

    func ensureLeaseForActiveLiveDocument(
        documentID: UUID,
        serverRevision: Int64
    ) async {
        guard isEnabled(), serverRevision > 0 else { return }
        let identifier: DeviceIdentifier
        do {
            identifier = try await deviceIdentityProvider.currentIdentifier()
        } catch {
            return
        }
        let key = LeaseKey(
            documentID: documentID,
            deviceID: identifier.uuid
        )
        guard var entry = entries[key], entry.activeReferences > 0 else {
            return
        }
        if entry.requiresLease,
           entry.serverRevision == serverRevision,
           entry.token != nil || acquisitionTasks[key] != nil {
            return
        }
        if !entry.requiresLease || entry.serverRevision != serverRevision {
            entry.lifecycleSequence &+= 1
        }
        entry.requiresLease = true
        entry.serverRevision = serverRevision
        entry.state = .acquiring
        entry.retryAttempt = 0
        entries[key] = entry
        let lifecycleSequence = entry.lifecycleSequence
        publish(.acquiring, documentID: documentID)
        do {
            _ = try await validToken(for: key)
        } catch let error as SyncV2ClientError {
            guard entries[key]?.requiresLease == true,
                  entries[key]?.lifecycleSequence == lifecycleSequence,
                  entries[key]?.serverRevision == serverRevision
            else { return }
            let state = Self.displayState(for: error)
            entries[key]?.state = state
            publish(state, documentID: documentID)
            scheduleRecoveryAfterAcquireFailure(error, for: key)
        } catch {
            guard entries[key]?.requiresLease == true,
                  entries[key]?.lifecycleSequence == lifecycleSequence,
                  entries[key]?.serverRevision == serverRevision
            else { return }
            entries[key]?.state = .unavailable
            publish(.unavailable, documentID: documentID)
        }
    }

    func documentBecameTombstone(documentID: UUID) async {
        for key in entries.keys where key.documentID == documentID {
            guard var entry = entries[key] else { continue }
            cancelTasks(for: key)
            entry.lifecycleSequence &+= 1
            entry.token = nil
            entry.expiresAt = nil
            entry.requiresLease = false
            entry.serverRevision = nil
            entry.state = .localOnly
            entry.retryAttempt = 0
            entries[key] = entry
        }
        publish(.localOnly, documentID: documentID)
    }

    func offlineDisplayState(
        documentID: UUID
    ) -> EditLeaseDisplayState {
        let state: EditLeaseDisplayState =
            isEnabled() ? .offlineEditing : .localOnly
        for key in entries.keys where key.documentID == documentID {
            entries[key]?.state = state
        }
        publish(state, documentID: documentID)
        return state
    }

    func endEditing(documentID: UUID) async {
        guard
            let key = entries.keys.first(where: {
                $0.documentID == documentID
                    && (entries[$0]?.activeReferences ?? 0) > 0
            }),
            var entry = entries[key]
        else {
            return
        }
        entry.activeReferences -= 1
        entries[key] = entry
        guard entry.activeReferences == 0 else { return }
        await releaseAndRemove(key)
    }

    func leaseTokenForCommit(
        documentID: UUID,
        deviceID: UUID,
        baseRevision: Int64
    ) async throws -> UUID? {
        guard baseRevision > 0 else { return nil }
        let key = LeaseKey(documentID: documentID, deviceID: deviceID)
        if entries[key] == nil {
            entries[key] = Entry(
                token: nil,
                expiresAt: nil,
                activeReferences: 0,
                requiresLease: true,
                state: .acquiring,
                serverRevision: baseRevision,
                lifecycleSequence: 0,
                retryAttempt: 0
            )
        }
        return try await validToken(for: key)
    }

    func commitSucceeded(
        documentID: UUID,
        deviceID: UUID,
        isDeleted: Bool
    ) async {
        let key = LeaseKey(documentID: documentID, deviceID: deviceID)
        guard var entry = entries[key] else { return }
        if isDeleted {
            cancelTasks(for: key)
            entries[key] = nil
            publish(.localOnly, documentID: documentID)
            return
        }
        guard entry.activeReferences > 0 else {
            await releaseAndRemove(key)
            return
        }
        if entry.token == nil {
            entry.requiresLease = true
            entry.state = .acquiring
            entries[key] = entry
            publish(.acquiring, documentID: documentID)
            do {
                _ = try await validToken(for: key)
            } catch let error as SyncV2ClientError {
                let state = Self.displayState(for: error)
                entries[key]?.state = state
                publish(state, documentID: documentID)
            } catch {
                entries[key]?.state = .unavailable
                publish(.unavailable, documentID: documentID)
            }
            return
        }
        entry.expiresAt = now().addingTimeInterval(
            TimeInterval(Self.leaseTTLSeconds)
        )
        if let expiresAt = entry.expiresAt {
            entry.state = .held(expiresAt: expiresAt)
        }
        entries[key] = entry
        publish(entry.state, documentID: documentID)
        scheduleHeartbeat(for: key)
    }

    func commitFailed(
        documentID: UUID,
        deviceID: UUID,
        error: SyncV2ClientError
    ) async {
        let key = LeaseKey(documentID: documentID, deviceID: deviceID)
        if case let .remote(code: .leaseConflict, detail: detail) = error,
           var entry = entries[key],
           entry.activeReferences > 0 {
            // 다른 기기가 잠금을 가진 동안에도 이 편집기의 참조와 관찰을
            // 유지한다. 재시도 때 `.acquiring`으로 되돌아가면 화면이
            // "확인 중"과 잠금 충돌 사이에서 계속 깜빡인다.
            cancelTasks(for: key)
            let state = EditLeaseDisplayState.heldByOther(
                expiresAt: Self.expirationDate(from: detail)
            )
            let shouldPublish = entry.state != state
            entry.token = nil
            entry.expiresAt = nil
            entry.state = state
            entries[key] = entry
            if shouldPublish {
                publish(state, documentID: documentID)
            }
            let expiration = Self.expirationDate(from: detail)
            let seconds = max(
                1,
                expiration?.timeIntervalSince(now()) ?? 2
            )
            scheduleReacquire(for: key, after: .seconds(seconds))
            return
        }
        let shouldRelease: Bool
        switch error {
        case let .remote(code, _):
            shouldRelease = [
                .revisionConflict,
                .operationIDReused,
                .leaseConflict,
                .leaseExpired,
                .pathConflict,
            ].contains(code)
        case .invalidResponse, .serverRejected, .networkUnavailable,
             .timedOut:
            shouldRelease = false
        }
        if case .remote(code: .documentNotFound, detail: _) = error,
           var entry = entries[key] {
            cancelTasks(for: key)
            entry.lifecycleSequence &+= 1
            entry.token = nil
            entry.expiresAt = nil
            entry.requiresLease = false
            entry.serverRevision = nil
            entry.retryAttempt = 0
            entry.state = .unavailable
            entries[key] = entry
            publish(.unavailable, documentID: documentID)
        } else if shouldRelease {
            await releaseAndRemove(key)
        } else if var entry = entries[key] {
            entry.state = Self.displayState(for: error)
            entries[key] = entry
            publish(entry.state, documentID: documentID)
        }
    }

    func releaseAll() async {
        let keys = Array(entries.keys)
        for key in keys {
            await releaseAndRemove(key)
        }
    }

    func state(
        documentID: UUID,
        deviceID: UUID
    ) -> EditLeaseDisplayState? {
        entries[
            LeaseKey(documentID: documentID, deviceID: deviceID)
        ]?.state
    }

    private func validToken(for key: LeaseKey) async throws -> UUID {
        if let entry = entries[key],
           let token = entry.token,
           let expiresAt = entry.expiresAt,
           expiresAt.timeIntervalSince(now()) > 10 {
            return token
        }
        let keepsVisibleConflict: Bool
        if case .heldByOther = entries[key]?.state {
            keepsVisibleConflict = true
        } else {
            keepsVisibleConflict = false
        }
        if !keepsVisibleConflict {
            entries[key]?.state = .acquiring
            publish(.acquiring, documentID: key.documentID)
        }
        let lifecycleSequence = entries[key]?.lifecycleSequence
        let result = try await acquire(for: key)
        guard let current = entries[key],
              current.lifecycleSequence == lifecycleSequence,
              current.requiresLease
        else {
            _ = try? await client.release(
                documentID: key.documentID,
                deviceID: key.deviceID,
                leaseToken: result.leaseToken
            )
            throw CancellationError()
        }
        entries[key]?.token = result.leaseToken
        entries[key]?.expiresAt = result.expiresAt
        entries[key]?.state = .held(expiresAt: result.expiresAt)
        entries[key]?.retryAttempt = 0
        publish(
            .held(expiresAt: result.expiresAt),
            documentID: key.documentID
        )
        if (entries[key]?.activeReferences ?? 0) > 0 {
            scheduleHeartbeat(for: key)
        }
        return result.leaseToken
    }

    private func acquire(
        for key: LeaseKey
    ) async throws -> EditLeaseMutationResult {
        if let acquisition = acquisitionTasks[key] {
            return try await acquisition.task.value
        }
        let client = self.client
        let id = UUID()
        let task = Task {
            try await client.acquire(
                documentID: key.documentID,
                deviceID: key.deviceID,
                ttlSeconds: Self.leaseTTLSeconds
            )
        }
        acquisitionTasks[key] = Acquisition(id: id, task: task)
        do {
            let result = try await task.value
            if acquisitionTasks[key]?.id == id {
                acquisitionTasks[key] = nil
            }
            return result
        } catch {
            if acquisitionTasks[key]?.id == id {
                acquisitionTasks[key] = nil
            }
            throw error
        }
    }

    private func scheduleHeartbeat(for key: LeaseKey) {
        heartbeatTasks[key]?.cancel()
        guard
            (entries[key]?.activeReferences ?? 0) > 0,
            entries[key]?.token != nil
        else {
            return
        }
        let sleep = self.sleep
        heartbeatTasks[key] = Task { [weak self] in
            do {
                try await sleep(Self.heartbeatInterval)
            } catch {
                return
            }
            await self?.heartbeat(key)
        }
    }

    private func heartbeat(_ key: LeaseKey) async {
        guard
            let entry = entries[key],
            entry.activeReferences > 0,
            let token = entry.token
        else {
            return
        }
        let lifecycleSequence = entry.lifecycleSequence
        do {
            let result = try await client.renew(
                documentID: key.documentID,
                deviceID: key.deviceID,
                leaseToken: token,
                ttlSeconds: Self.leaseTTLSeconds
            )
            guard var current = entries[key],
                  current.lifecycleSequence == lifecycleSequence,
                  current.requiresLease,
                  current.token == token
            else { return }
            current.token = result.leaseToken
            current.expiresAt = result.expiresAt
            current.state = .held(expiresAt: result.expiresAt)
            current.retryAttempt = 0
            entries[key] = current
            publish(current.state, documentID: key.documentID)
            scheduleHeartbeat(for: key)
        } catch let error as SyncV2ClientError {
            guard entries[key]?.lifecycleSequence == lifecycleSequence else {
                return
            }
            handleHeartbeatFailure(error, for: key)
        } catch {
            guard entries[key]?.lifecycleSequence == lifecycleSequence else {
                return
            }
            entries[key]?.state = .unavailable
            publish(.unavailable, documentID: key.documentID)
            scheduleTransientReacquire(for: key)
        }
    }

    private func handleHeartbeatFailure(
        _ error: SyncV2ClientError,
        for key: LeaseKey
    ) {
        guard var entry = entries[key], entry.activeReferences > 0 else {
            return
        }
        entry.state = Self.displayState(for: error)
        entry.token = nil
        entry.expiresAt = nil
        entries[key] = entry
        publish(entry.state, documentID: key.documentID)
        switch error {
        case .remote(code: .leaseExpired, detail: _):
            scheduleReacquire(for: key, after: .zero)
        case let .remote(code: .leaseConflict, detail: detail):
            let expiration = Self.expirationDate(from: detail)
            let seconds = max(
                1,
                expiration?.timeIntervalSince(now()) ?? 2
            )
            scheduleReacquire(for: key, after: .seconds(seconds))
        case .networkUnavailable, .timedOut:
            scheduleTransientReacquire(for: key)
        case .remote(code: .documentNotFound, detail: _):
            entry.lifecycleSequence &+= 1
            entry.requiresLease = false
            entry.serverRevision = nil
            entry.retryAttempt = 0
            entries[key] = entry
        default:
            break
        }
    }

    private func scheduleRecoveryAfterAcquireFailure(
        _ error: SyncV2ClientError,
        for key: LeaseKey
    ) {
        switch error {
        case .remote(code: .leaseExpired, detail: _):
            scheduleReacquire(for: key, after: .zero)
        case let .remote(code: .leaseConflict, detail: detail):
            let expiration = Self.expirationDate(from: detail)
            let seconds = max(
                1,
                expiration?.timeIntervalSince(now()) ?? 2
            )
            scheduleReacquire(for: key, after: .seconds(seconds))
        case .networkUnavailable, .timedOut:
            scheduleTransientReacquire(for: key)
        default:
            break
        }
    }

    private func scheduleTransientReacquire(for key: LeaseKey) {
        guard var entry = entries[key],
              entry.requiresLease,
              entry.activeReferences > 0,
              entry.retryAttempt < Self.transientRetryDelays.count
        else { return }
        let delay = Self.transientRetryDelays[entry.retryAttempt]
        entry.retryAttempt += 1
        entries[key] = entry
        scheduleReacquire(for: key, after: delay)
    }

    private func scheduleReacquire(
        for key: LeaseKey,
        after delay: Duration
    ) {
        retryTasks[key]?.cancel()
        guard let entry = entries[key],
              entry.requiresLease,
              entry.activeReferences > 0
        else { return }
        let lifecycleSequence = entry.lifecycleSequence
        let sleep = self.sleep
        retryTasks[key] = Task { [weak self] in
            do {
                if delay > .zero {
                    try await sleep(delay)
                } else {
                    await Task.yield()
                }
                try Task.checkCancellation()
            } catch {
                return
            }
            await self?.performScheduledReacquire(
                key,
                lifecycleSequence: lifecycleSequence
            )
        }
    }

    private func performScheduledReacquire(
        _ key: LeaseKey,
        lifecycleSequence: UInt64
    ) async {
        retryTasks[key] = nil
        guard let entry = entries[key],
              entry.lifecycleSequence == lifecycleSequence,
              entry.requiresLease,
              entry.activeReferences > 0,
              entry.token == nil
        else { return }
        do {
            _ = try await validToken(for: key)
        } catch let error as SyncV2ClientError {
            guard entries[key]?.lifecycleSequence == lifecycleSequence else {
                return
            }
            entries[key]?.state = Self.displayState(for: error)
            if let state = entries[key]?.state {
                publish(state, documentID: key.documentID)
            }
            switch error {
            case let .remote(code: .leaseConflict, detail: detail):
                let expiration = Self.expirationDate(from: detail)
                let seconds = max(
                    1,
                    expiration?.timeIntervalSince(now()) ?? 2
                )
                scheduleReacquire(for: key, after: .seconds(seconds))
            case .networkUnavailable, .timedOut:
                scheduleTransientReacquire(for: key)
            case .remote(code: .documentNotFound, detail: _):
                await documentBecameTombstone(
                    documentID: key.documentID
                )
            default:
                break
            }
        } catch {
            entries[key]?.state = .unavailable
            publish(.unavailable, documentID: key.documentID)
            scheduleTransientReacquire(for: key)
        }
    }

    private func releaseAndRemove(_ key: LeaseKey) async {
        let entry = entries.removeValue(forKey: key)
        cancelTasks(for: key)
        publish(.localOnly, documentID: key.documentID)
        guard let token = entry?.token else { return }
        let client = self.client
        Task {
            _ = try? await client.release(
                documentID: key.documentID,
                deviceID: key.deviceID,
                leaseToken: token
            )
        }
    }

    private func cancelTasks(for key: LeaseKey) {
        heartbeatTasks.removeValue(forKey: key)?.cancel()
        acquisitionTasks.removeValue(forKey: key)?.task.cancel()
        retryTasks.removeValue(forKey: key)?.cancel()
    }

    private func publish(
        _ state: EditLeaseDisplayState,
        documentID: UUID
    ) {
        stateObservers[documentID]?.values.forEach {
            $0.yield(state)
        }
    }

    private func removeStateObserver(
        documentID: UUID,
        observerID: UUID
    ) {
        stateObservers[documentID]?[observerID] = nil
        if stateObservers[documentID]?.isEmpty == true {
            stateObservers[documentID] = nil
        }
    }

    private static func displayState(
        for error: SyncV2ClientError
    ) -> EditLeaseDisplayState {
        switch error {
        case .networkUnavailable, .timedOut:
            return .offlineEditing
        case let .remote(code, detail):
            switch code {
            case .authRequired:
                return .authenticationRequired
            case .leaseConflict:
                return .heldByOther(
                    expiresAt: expirationDate(from: detail)
                )
            case .leaseExpired:
                return .offlineEditing
            case .documentNotFound:
                return .unavailable
            case .forbidden, .invalidArgument,
                 .documentAlreadyExists, .revisionConflict,
                 .operationIDReused, .leaseRequired, .pathConflict,
                 .folderNotFound, .folderAlreadyExists, .folderNotEmpty,
                 .parentFolderNotFound, .folderNameConflict, .folderCycle:
                // 편집 점유는 문서에만 있다. 폴더 코드는 여기로 오지 않는다.
                return .unavailable
            }
        case .invalidResponse, .serverRejected:
            return .unavailable
        }
    }

    private func authenticationDisplayState() async
        -> EditLeaseDisplayState? {
        guard let authenticationState else { return nil }
        switch await authenticationState() {
        case .authenticated:
            return nil
        case .localOnly, .restoring:
            // 앱 시작 시 세션 복원과 편집기 복원이 경합해도 인증 없는
            // RPC를 시작하지 않는다. 이후 첫 commit이 같은 활성 entry의
            // 임대를 획득한다.
            return .localOnly
        case .signedOut:
            return .authenticationRequired
        case .unavailable(.networkUnavailable):
            return .offlineEditing
        case .unavailable:
            return .unavailable
        }
    }

    private static func expirationDate(from detail: String?) -> Date? {
        guard
            let detail,
            let data = detail.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let value = object["expires_at"] as? String
        else {
            return nil
        }
        return EditLeaseTimestamp.decode(value)
    }
}
