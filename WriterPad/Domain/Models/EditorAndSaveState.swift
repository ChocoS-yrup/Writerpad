import Foundation

enum EditorPane: String, Codable, Equatable, Sendable {
    case left
    case right
}

/// 좌우 편집기 한 칸의 현재 문서와 커서를 나타낸다.
struct EditorPaneState: Codable, Equatable, Sendable {
    let documentID: DocumentID?
    let cursor: TextCursorState
}

/// 작품별 좌우 편집기 복원에 필요한 최소 화면 상태다.
struct EditorWorkspaceState: Codable, Equatable, Sendable {
    let projectID: ProjectID
    let left: EditorPaneState
    let right: EditorPaneState?
    let activePane: EditorPane
}

/// 로컬 TXT 저장 흐름의 사용자 표시 상태다.
enum SaveState: Codable, Equatable, Sendable {
    case idle
    case editing(generation: UInt64)
    case saving(generation: UInt64)
    case saved(generation: UInt64, savedAt: Date, contentHash: ContentHash)
    case failed(generation: UInt64, message: String)

    var generation: UInt64? {
        switch self {
        case .idle:
            nil
        case let .editing(generation), let .saving(generation),
             let .saved(generation, _, _), let .failed(generation, _):
            generation
        }
    }
}
