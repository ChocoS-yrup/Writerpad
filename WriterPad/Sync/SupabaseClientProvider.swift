import Foundation
import Supabase

protocol SupabaseClientProviding: AnyObject {
    var configurationState: SupabaseConfigurationState { get }
    var isConfigured: Bool { get }
    func makeAuthTransport() -> (any SupabaseAuthTransporting)?
    func makeProjectBindingTransport() -> (any EnsureProjectTransporting)?
    func makeSyncV2Client() -> SyncV2Client?
    func makeHandshakeTransport() -> (any SyncV2HandshakeTransporting)?
    func makeAtomicStructureTransport() -> (any SyncV2AtomicStructureTransporting)?
    func makeSnapshotClient() -> SyncV2SnapshotClient?
    func makeRealtimeTrigger() -> (any SyncV2RealtimeTriggering)?
    func makeEditLeaseClient() -> EditLeaseClient?
}

extension SupabaseClientProviding {
    func makeHandshakeTransport() -> (any SyncV2HandshakeTransporting)? { nil }
    func makeAtomicStructureTransport() -> (any SyncV2AtomicStructureTransporting)? { nil }
    func makeSnapshotClient() -> SyncV2SnapshotClient? { nil }
    func makeRealtimeTrigger() -> (any SyncV2RealtimeTriggering)? { nil }
}

/// SupabaseClient가 같은 프로세스의 후속 RPC에 로그인 토큰을 붙일 수 있도록
/// 세션을 메모리에만 보관한다. 앱 재실행용 토큰은 KeychainSessionStore가
/// 별도로 관리하므로 이 저장소는 디스크나 Keychain에 기록하지 않는다.
final class EphemeralAuthLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

#if DEBUG
final class SyncV2URLSessionMetricsDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        _ = session
        guard
            let request = task.originalRequest ?? task.currentRequest,
            let rawPullID = request.value(
                forHTTPHeaderField: SyncV2PullDiagnostics.pullIDHeader
            ),
            let pullID = UUID(uuidString: rawPullID),
            let origin = request.value(
                forHTTPHeaderField: SyncV2PullDiagnostics.pullOriginHeader
            ),
            let stage = request.value(
                forHTTPHeaderField: SyncV2PullDiagnostics.pullStageHeader
            ),
            let rawStartedAt = request.value(
                forHTTPHeaderField: SyncV2PullDiagnostics.pullStartHeader
            ),
            let pullStartedAt = UInt64(rawStartedAt)
        else { return }

        let transactions = metrics.transactionMetrics
        let firstFetch = transactions.compactMap(\.fetchStartDate).min()
        let firstResponse = transactions.compactMap(\.responseStartDate).min()
        let lastResponse = transactions.compactMap(\.responseEndDate).max()
        let ttfb = Self.milliseconds(from: firstFetch, to: firstResponse)
        let receive = Self.milliseconds(
            from: firstResponse,
            to: lastResponse
        )
        let networkBytes = transactions.reduce(Int64(0)) {
            $0 + $1.countOfResponseBodyBytesReceived
        }
        let decodedBytes = transactions.reduce(Int64(0)) {
            $0 + $1.countOfResponseBodyBytesAfterDecoding
        }
        SyncV2PullDiagnostics.recordNetworkMetrics(
            pullID: pullID,
            origin: origin,
            stage: stage,
            pullStartedAtNanoseconds: pullStartedAt,
            taskMilliseconds: metrics.taskInterval.duration * 1_000,
            ttfbMilliseconds: ttfb,
            receiveMilliseconds: receive,
            networkBytes: networkBytes,
            decodedBytes: decodedBytes,
            transactionCount: transactions.count
        )
    }

    private static func milliseconds(
        from start: Date?,
        to end: Date?
    ) -> Double {
        guard let start, let end else { return -1 }
        return max(0, end.timeIntervalSince(start) * 1_000)
    }
}
#endif

final class SupabaseClientProvider: SupabaseClientProviding {
    let configurationState: SupabaseConfigurationState
    private let client: SupabaseClient?
    private let realtimeSubscriptionGate =
        SyncV2RealtimeConnectGate()

    var isConfigured: Bool {
        client != nil
    }

    func makeAuthTransport() -> (any SupabaseAuthTransporting)? {
        client.map(LiveSupabaseAuthTransport.init(client:))
    }

    func makeProjectBindingTransport() -> (any EnsureProjectTransporting)? {
        client.map(LiveEnsureProjectTransport.init(client:))
    }

    func makeSyncV2Client() -> SyncV2Client? {
        client.map {
            SyncV2Client(
                transport: LiveSyncV2CommitTransport(client: $0)
            )
        }
    }

    /// 전송만 만든다. `SyncV2HandshakeService`는 답을 메모리에 들고 있어서, 부를
    /// 때마다 새로 만들면 들고 있던 답이 매번 사라진다. 서비스를 하나 만들어 두는
    /// 것은 이것을 쓰는 쪽의 몫이다.
    func makeHandshakeTransport() -> (any SyncV2HandshakeTransporting)? {
        guard case .configured(let configuration) = configurationState else { return nil }
        return client.map { LiveSyncV2HandshakeTransport(client: $0, configuration: configuration) }
    }

    func makeAtomicStructureTransport() ->
        (any SyncV2AtomicStructureTransporting)? {
        guard case .configured(let configuration) = configurationState else { return nil }
        return client.map { LiveSyncV2AtomicStructureTransport(client: $0, configuration: configuration) }
    }

    func makeSnapshotClient() -> SyncV2SnapshotClient? {
        client.map {
            SyncV2SnapshotClient(
                transport: LiveSyncV2SnapshotTransport(client: $0)
            )
        }
    }

    func makeRealtimeTrigger() -> (any SyncV2RealtimeTriggering)? {
        client.map {
            LiveSyncV2RealtimeTrigger(
                client: $0,
                subscriptionGate: realtimeSubscriptionGate
            )
        }
    }

    func makeEditLeaseClient() -> EditLeaseClient? {
        client.map {
            EditLeaseClient(
                transport: LiveEditLeaseTransport(client: $0)
            )
        }
    }

    convenience init(bundle: Bundle = .main) {
        self.init(
            configuration: SupabasePublicConfiguration.load(
                from: bundle.infoDictionary ?? [:]
            )
        )
    }

    init(
        configuration: Result<
            SupabasePublicConfiguration,
            SupabaseConfigurationError
        >
    ) {
        switch configuration {
        case .success(let value):
            configurationState = .configured(value)
#if DEBUG
            let session = URLSession(
                configuration: .default,
                delegate: SyncV2URLSessionMetricsDelegate(),
                delegateQueue: nil
            )
            let globalOptions = SupabaseClientOptions.GlobalOptions(
                session: session
            )
#else
            let globalOptions = SupabaseClientOptions.GlobalOptions()
#endif
            client = SupabaseClient(
                supabaseURL: value.url,
                supabaseKey: value.publishableKey,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: EphemeralAuthLocalStorage(),
                        autoRefreshToken: false,
                        emitLocalSessionAsInitialSession: true
                    ),
                    global: globalOptions
                )
            )
        case .failure(let error):
            configurationState = .unavailable(error)
            client = nil
        }
    }
}
