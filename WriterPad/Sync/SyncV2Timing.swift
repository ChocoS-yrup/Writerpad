import Foundation

/// Sync V2 수명주기의 기본 시간 예산을 한곳에서 보여주는 값 타입이다.
/// 각 소비 타입의 initializer는 개별 값을 계속 주입받으므로 테스트에서
/// 필요한 시간만 짧게 바꿀 수 있다.
struct SyncV2Timing: Equatable, Sendable {
    let authRestoreTimeout: Duration
    let realtimeSubscriptionTimeout: Duration
    let initialRealtimeSubscriptionGrace: Duration
    let pullTimeout: Duration
    let workspaceAuthenticationTimeout: Duration
    let authenticationRetryDelay: Duration
    let periodicDelay: Duration
    let debounceDelay: Duration
    let refreshMargin: TimeInterval
    let refreshRetryDelay: Duration
    let backoff: [Duration]
    let gateHoldTimeout: Duration
    let authenticationRestoringYieldDelay: Duration
    let stableSubscriptionResetInterval: Duration
    let quietProgressInterval: Duration

    init(
        authRestoreTimeout: Duration = .seconds(12),
        realtimeSubscriptionTimeout: Duration = .seconds(12),
        initialRealtimeSubscriptionGrace: Duration = .seconds(1),
        pullTimeout: Duration = .seconds(15),
        workspaceAuthenticationTimeout: Duration = .seconds(12),
        authenticationRetryDelay: Duration = .seconds(3),
        periodicDelay: Duration = .seconds(90),
        debounceDelay: Duration = .milliseconds(450),
        refreshMargin: TimeInterval = 5 * 60,
        refreshRetryDelay: Duration = .seconds(30),
        backoff: [Duration] = [
            .seconds(1), .seconds(2), .seconds(5),
            .seconds(10), .seconds(30),
        ],
        gateHoldTimeout: Duration = .seconds(20),
        authenticationRestoringYieldDelay: Duration = .milliseconds(100),
        stableSubscriptionResetInterval: Duration = .seconds(30),
        quietProgressInterval: Duration = .seconds(3)
    ) {
        self.authRestoreTimeout = authRestoreTimeout
        self.realtimeSubscriptionTimeout = realtimeSubscriptionTimeout
        self.initialRealtimeSubscriptionGrace =
            initialRealtimeSubscriptionGrace
        self.pullTimeout = pullTimeout
        self.workspaceAuthenticationTimeout =
            workspaceAuthenticationTimeout
        self.authenticationRetryDelay = authenticationRetryDelay
        self.periodicDelay = periodicDelay
        self.debounceDelay = debounceDelay
        self.refreshMargin = refreshMargin
        self.refreshRetryDelay = refreshRetryDelay
        self.backoff = backoff
        self.gateHoldTimeout = gateHoldTimeout
        self.authenticationRestoringYieldDelay =
            authenticationRestoringYieldDelay
        self.stableSubscriptionResetInterval =
            stableSubscriptionResetInterval
        self.quietProgressInterval = quietProgressInterval
    }

    static let standard = SyncV2Timing()

    var maximumBackoff: Duration {
        backoff.max() ?? .zero
    }
}

// 기본값 사이의 설계 제약:
// - pullTimeout > authRestoreTimeout: 401 뒤 인증 복원/갱신이 snapshot
//   watchdog 예산보다 먼저 끝나 원래 요청을 재시도할 수 있어야 한다.
// - realtimeSubscriptionTimeout < pullTimeout: 연결 성립 여부를 먼저 판정한 뒤
//   더 긴 snapshot 확인 예산을 사용한다.
// - initialRealtimeSubscriptionGrace < realtimeSubscriptionTimeout: 최초
//   snapshot은 Realtime 장애 판정 전에도 유한 시간 안에 시작한다.
// - backoff.max() < periodicDelay: 명시적 재연결 backoff가 90초 안전망보다
//   먼저 실행되어야 한다.
// - debounceDelay < backoff.min(): 이벤트 병합이 첫 재연결보다 먼저 끝나야 한다.
// - gateHoldTimeout > pullTimeout: 공유 Gate가 정상 watchdog보다 먼저 작업을
//   끊으면 안 된다.
// - refreshRetryDelay < refreshMargin: 만료 5분 전 갱신 구간 안에서 30초
//   재시도 기회를 남긴다.
// - workspaceAuthenticationTimeout == authRestoreTimeout: 화면의 로그인 확인과
//   인증 서비스 복원이 같은 12초 상한을 공유해 대기 시간이 겹쳐 늘지 않는다.
