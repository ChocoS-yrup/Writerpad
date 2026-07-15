import Foundation

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
}
