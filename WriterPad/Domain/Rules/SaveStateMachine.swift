import Foundation

typealias AutosaveSleep = @Sendable (Duration) async throws -> Void

/// 입력이 이어지는 동안 예약을 교체하고 마지막 입력 뒤 한 번만 저장 작업을 실행한다.
@MainActor
final class AutosaveDebouncer {
    static let defaultDelay: Duration = .milliseconds(800)

    private var delay: Duration
    private let sleep: AutosaveSleep
    private var pendingTask: Task<Void, Never>?

    init(
        delay: Duration = AutosaveDebouncer.defaultDelay,
        sleep: @escaping AutosaveSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    func schedule(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        pendingTask?.cancel()
        let delay = delay
        let sleep = sleep
        pendingTask = Task {
            do {
                try await sleep(delay)
                try Task.checkCancellation()
                await operation()
            } catch {
                // 새 입력이나 즉시 저장이 기존 예약을 취소한 정상 경로다.
            }
        }
    }

    func updateDelay(_ delay: Duration) {
        self.delay = delay
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}

enum SaveEvent: Equatable, Sendable {
    case edited(generation: UInt64)
    case saveStarted(generation: UInt64)
    case saveSucceeded(generation: UInt64, savedAt: Date, contentHash: ContentHash)
    case saveFailed(generation: UInt64, message: String)

    var generation: UInt64 {
        switch self {
        case let .edited(generation), let .saveStarted(generation),
             let .saveSucceeded(generation, _, _), let .saveFailed(generation, _):
            generation
        }
    }
}

/// 늦게 도착한 과거 저장 결과가 최신 상태를 덮지 않도록 상태를 축약한다.
enum SaveStateMachine {
    static func reduce(_ state: SaveState, event: SaveEvent) -> SaveState {
        if let currentGeneration = state.generation,
           event.generation < currentGeneration {
            return state
        }

        switch event {
        case let .edited(generation):
            return .editing(generation: generation)
        case let .saveStarted(generation):
            return .saving(generation: generation)
        case let .saveSucceeded(generation, savedAt, contentHash):
            return .saved(generation: generation, savedAt: savedAt, contentHash: contentHash)
        case let .saveFailed(generation, message):
            return .failed(generation: generation, message: message)
        }
    }

    /// 배지에 표시할 로컬 저장 의미를 상태 전이와 같은 경계에서 결정한다.
    static func presentation(for state: SaveState) -> LocalSaveStatusPresentation {
        switch state {
        case .idle:
            LocalSaveStatusPresentation(
                label: "로컬 저장 준비",
                systemImage: "externaldrive",
                allowsRetry: false
            )
        case .editing:
            LocalSaveStatusPresentation(
                label: "편집 중",
                systemImage: "pencil",
                allowsRetry: false
            )
        case .saving:
            LocalSaveStatusPresentation(
                label: "로컬 저장 중",
                systemImage: "arrow.triangle.2.circlepath",
                allowsRetry: false
            )
        case .saved:
            LocalSaveStatusPresentation(
                label: "로컬 저장됨",
                systemImage: "checkmark.circle",
                allowsRetry: false
            )
        case .failed:
            LocalSaveStatusPresentation(
                label: "로컬 저장 실패 · 재시도",
                systemImage: "exclamationmark.triangle",
                allowsRetry: true
            )
        }
    }

    static func presentation(
        for state: SaveState,
        syncHandoffState: SyncHandoffState
    ) -> LocalSaveStatusPresentation {
        if case .failed = state {
            return presentation(for: state)
        }
        if case .failed = syncHandoffState {
            return LocalSaveStatusPresentation(
                label: "로컬 저장됨 · 동기화 기록 실패",
                systemImage: "exclamationmark.triangle",
                allowsRetry: true
            )
        }
        if case .saved = state,
           case .serverSizeLimitExceeded = syncHandoffState {
            return LocalSaveStatusPresentation(
                label: "로컬 저장됨 · 서버 크기 제한 초과",
                systemImage: "externaldrive.badge.exclamationmark",
                allowsRetry: false
            )
        }
        if case .saved = state, case .upToDate = syncHandoffState {
            return LocalSaveStatusPresentation(
                label: "로컬 저장됨 · 서버와 동일",
                systemImage: "checkmark.icloud",
                allowsRetry: false
            )
        }
        if case .saved = state, case .queued = syncHandoffState {
            return LocalSaveStatusPresentation(
                label: "로컬 저장됨 · 동기화 대기",
                systemImage: "clock.arrow.circlepath",
                allowsRetry: false
            )
        }
        return presentation(for: state)
    }
}

struct LocalSaveStatusPresentation: Equatable, Sendable {
    let label: String
    let systemImage: String
    let allowsRetry: Bool
}

/// 통계 갱신의 debounce·최대 지연 계산에 쓰는 시각 공급자다. 실제 시계를 쓰면
/// 몇 번 계산될지가 밀리초 단위 흔들림에 좌우되어 테스트가 불안정해진다.
typealias StatisticsNow = @Sendable () -> ContinuousClock.Instant
