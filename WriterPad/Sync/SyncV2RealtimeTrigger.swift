import Foundation
import Supabase

protocol SyncV2RealtimeTriggering: Sendable {
    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws
    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws
    func stop() async
}

enum SyncV2RealtimeConnectionStatus: Equatable, Sendable {
    case subscribing
    case subscribed
    case closed
    case channelError
    case timedOut
}

enum SyncV2RealtimeTriggerError: Error, Sendable {
    case globalSubscriptionUnsupported
    case subscriptionTimedOut
}

extension SyncV2RealtimeTriggering {
    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        _ = (onChange, onSubscribed)
        throw SyncV2RealtimeTriggerError.globalSubscriptionUnsupported
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await start(
            projectID: projectID,
            onChange: onChange,
            onSubscribed: { onStatus(.subscribed) }
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startAll(
            onChange: onChange,
            onSubscribed: { onStatus(.subscribed) }
        )
    }
}

struct SyncV2RealtimeSubscriptionGate {
    private(set) var hasSubscribed = false

    mutating func receiveSubscribed() -> Bool {
        guard hasSubscribed else {
            hasSubscribed = true
            return false
        }
        return true
    }
}

actor LiveSyncV2RealtimeTrigger: SyncV2RealtimeTriggering {
    private let client: SupabaseClient
    private let subscriptionGate: SyncV2RealtimeConnectGate
    private var channel: RealtimeChannelV2?
    private var changeSubscription: RealtimeSubscription?
    private var statusSubscription: RealtimeSubscription?
    private var channelGeneration: UUID?
    private var hasObservedSubscribing = false
    private var hasSubscribed = false

    init(
        client: SupabaseClient,
        subscriptionGate: SyncV2RealtimeConnectGate =
            SyncV2RealtimeConnectGate()
    ) {
        self.client = client
        self.subscriptionGate = subscriptionGate
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await start(
            projectID: projectID,
            onChange: onChange,
            onStatus: { status in
                if status == .subscribed {
                    onSubscribed()
                }
            }
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onSubscribed: @escaping @Sendable () -> Void
    ) async throws {
        try await startAll(
            onChange: onChange,
            onStatus: { status in
                if status == .subscribed {
                    onSubscribed()
                }
            }
        )
    }

    func start(
        projectID: UUID,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startChannel(
            projectID: projectID,
            onChange: onChange,
            onStatus: onStatus
        )
    }

    func startAll(
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        try await startChannel(
            projectID: nil,
            onChange: onChange,
            onStatus: onStatus
        )
    }

    private func startChannel(
        projectID: UUID?,
        onChange: @escaping @Sendable () -> Void,
        onStatus: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) async throws {
        await stop()
        let generation = UUID()
        channelGeneration = generation
        hasObservedSubscribing = false
        hasSubscribed = false
        let channel = client.channel(
            projectID.map {
                "writerpad-documents-\($0.uuidString.lowercased())"
            } ?? "writerpad-documents-all"
        )
        if let projectID {
            changeSubscription = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "documents",
                filter:
                    "project_id=eq.\(projectID.uuidString.lowercased())"
            ) { _ in
                Task {
                    await self.receivedChange(
                        generation: generation,
                        callback: onChange
                    )
                }
            }
        } else {
            changeSubscription = channel.onPostgresChange(
                AnyAction.self,
                schema: "public",
                table: "documents"
            ) { _ in
                Task {
                    await self.receivedChange(
                        generation: generation,
                        callback: onChange
                    )
                }
            }
        }
        statusSubscription = channel.onStatusChange {
            [weak self] status in
            Task {
                await self?.receivedStatus(
                    status,
                    generation: generation,
                    callback: onStatus
                )
            }
        }
        self.channel = channel
        do {
            // 같은 SupabaseClient를 쓰는 전체-작품 채널과 현재-작품 채널이
            // 동시에 최초 connect/subscribe에 진입하면 SDK 2.46.0에서 한
            // phx_join이 영구 대기할 수 있다. 공유 gate로 socket 구독을
            // 직렬화하고, 완료된 채널은 즉시 다음 채널에 차례를 넘긴다.
            try await subscriptionGate.withSubscription {
                try await channel.subscribeWithError()
            }
            // subscribeWithError의 정상 반환은 채널 구독이 완료됐다는
            // authoritative 신호다. 일부 장시간 실행·재연결 경로에서는
            // onStatusChange(.subscribed)가 replay되지 않을 수 있으므로,
            // callback 누락 여부와 무관하게 정확히 한 번 확정한다.
            receivedStatus(
                .subscribed,
                generation: generation,
                callback: onStatus
            )
        } catch {
            guard channelGeneration == generation else { throw error }
            let status: SyncV2RealtimeConnectionStatus
            switch error {
            case SyncV2RealtimeTriggerError.subscriptionTimedOut:
                status = .timedOut
            default:
                let detail = error.localizedDescription.lowercased()
                status = detail.contains("timeout")
                    || detail.contains("retry")
                    ? .timedOut
                    : .channelError
            }
            onStatus(status)
            throw error
        }
    }

    func stop() async {
        changeSubscription?.cancel()
        statusSubscription?.cancel()
        changeSubscription = nil
        statusSubscription = nil
        if let channel {
            // Supabase 2.46.0의 removeChannel은 이미 subscribed인 채널만
            // unsubscribe한다. subscribing 중 remove하면 내부 phx_join Task가
            // 고아로 남아 같은 topic의 다음 채널 응답을 가로막을 수 있으므로,
            // 상태와 관계없이 먼저 state machine을 unsubscribed까지 보낸다.
            await channel.unsubscribe()
            await client.removeChannel(channel)
        }
        channel = nil
        channelGeneration = nil
        hasObservedSubscribing = false
        hasSubscribed = false
    }

    private func receivedChange(
        generation: UUID,
        callback: @escaping @Sendable () -> Void
    ) {
        guard channelGeneration == generation else { return }
        callback()
    }

    private func receivedStatus(
        _ status: RealtimeChannelStatus,
        generation: UUID,
        callback: @escaping @Sendable
            (SyncV2RealtimeConnectionStatus) -> Void
    ) {
        guard channelGeneration == generation else { return }
        switch status {
        case .subscribing:
            // actor가 status callback Task를 처리하기 전에 채널이 이미
            // subscribed로 진행했다면 오래된 subscribing으로 회귀하지 않는다.
            guard !hasSubscribed,
                  let currentStatus = channel?.status,
                  Self.sameStatus(status, currentStatus)
            else { return }
            hasObservedSubscribing = true
            callback(.subscribing)
        case .subscribed:
            // subscribed는 callback 시점의 channel.status 비교로 버리지 않는다.
            // subscribeWithError 정상 반환도 같은 경로를 사용하므로 generation당
            // 한 번만 상위 수명주기 모델에 전달된다.
            guard !hasSubscribed else { return }
            hasSubscribed = true
            callback(.subscribed)
        case .unsubscribed:
            // onStatusChange는 등록 직후 초기 unsubscribed를 replay한다.
            // 실제 subscribe가 시작되기 전의 값은 종료 신호가 아니다.
            guard hasObservedSubscribing || hasSubscribed,
                  let currentStatus = channel?.status,
                  Self.sameStatus(status, currentStatus)
            else { return }
            callback(.closed)
        case .unsubscribing:
            break
        }
    }

    private static func sameStatus(
        _ lhs: RealtimeChannelStatus,
        _ rhs: RealtimeChannelStatus
    ) -> Bool {
        switch (lhs, rhs) {
        case (.unsubscribed, .unsubscribed),
             (.subscribing, .subscribing),
             (.subscribed, .subscribed),
             (.unsubscribing, .unsubscribing):
            true
        default:
            false
        }
    }
}
