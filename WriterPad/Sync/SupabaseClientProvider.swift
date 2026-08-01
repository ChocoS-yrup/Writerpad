import Foundation
import Supabase

protocol SupabaseClientProviding: AnyObject {
    var configurationState: SupabaseConfigurationState { get }
    var isConfigured: Bool { get }
    func makeAuthTransport() -> (any SupabaseAuthTransporting)?
    func makeProjectBindingTransport() -> (any EnsureProjectTransporting)?
    func makeSyncV2Client() -> SyncV2Client?
    func makeSnapshotClient() -> SyncV2SnapshotClient?
    func makeRealtimeTrigger() -> (any SyncV2RealtimeTriggering)?
    func makeEditLeaseClient() -> EditLeaseClient?
}

extension SupabaseClientProviding {
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
            client = SupabaseClient(
                supabaseURL: value.url,
                supabaseKey: value.publishableKey,
                options: SupabaseClientOptions(
                    auth: .init(
                        storage: EphemeralAuthLocalStorage(),
                        autoRefreshToken: false,
                        emitLocalSessionAsInitialSession: true
                    )
                )
            )
        case .failure(let error):
            configurationState = .unavailable(error)
            client = nil
        }
    }
}
