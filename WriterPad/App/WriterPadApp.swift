import SwiftUI
import SwiftData

enum WriterPadEditorCommand: String, CaseIterable, Sendable {
    case save
    case undo
    case redo
    case find
    case findInProject
    case closeFind
    case toggleBinder
    case toggleSplit
    case toggleEditorPane
    case previousChapter
    case nextChapter
}

struct WriterPadCommandActions {
    let perform: (WriterPadEditorCommand) -> Void
    let canToggleEditorPane: Bool
}

private struct WriterPadCommandActionsKey: FocusedValueKey {
    typealias Value = WriterPadCommandActions
}

extension FocusedValues {
    var writerPadCommandActions: WriterPadCommandActions? {
        get { self[WriterPadCommandActionsKey.self] }
        set { self[WriterPadCommandActionsKey.self] = newValue }
    }
}

struct WriterPadCommands: Commands {
    @FocusedValue(\.writerPadCommandActions) private var actions

    private func send(_ command: WriterPadEditorCommand) {
        actions?.perform(command)
    }

    var body: some Commands {
        CommandMenu("편집기") {
            Button("저장") { send(.save) }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("실행 취소") { send(.undo) }
            Button("다시 실행") { send(.redo) }
            Button("현재 문서에서 찾기") { send(.find) }
                .keyboardShortcut("f", modifiers: .command)
            Button("작품 전체에서 찾기") { send(.findInProject) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("검색 닫기") { send(.closeFind) }
                .keyboardShortcut(.cancelAction)
            Divider()
            Button("바인더 토글") { send(.toggleBinder) }
                .keyboardShortcut("b", modifiers: .command)
            Button("듀얼 편집기 토글") { send(.toggleSplit) }
                .keyboardShortcut("\\", modifiers: .command)
            Button("편집기 창 전환") { send(.toggleEditorPane) }
                .keyboardShortcut(.tab, modifiers: [])
                .disabled(actions?.canToggleEditorPane != true)
            Divider()
            Button("이전 화") { send(.previousChapter) }
                .keyboardShortcut("[", modifiers: .command)
            Button("다음 화") { send(.nextChapter) }
                .keyboardShortcut("]", modifiers: .command)
        }
    }
}

@main
@MainActor
struct WriterPadApp: App {
    @StateObject private var environment: AppEnvironment

    init() {
        let liveEnvironment: AppEnvironment

        do {
            liveEnvironment = try AppEnvironment.live()
        } catch {
            fatalError("WriterPad 환경을 구성하지 못했습니다: \(error.localizedDescription)")
        }

        _environment = StateObject(wrappedValue: liveEnvironment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .modelContainer(environment.modelContainer)
        .commands { WriterPadCommands() }
    }
}
