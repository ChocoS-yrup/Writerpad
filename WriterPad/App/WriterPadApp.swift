import SwiftUI
import SwiftData
import Observation

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

@Observable
final class WriterPadCommandActions {
    private(set) var canToggleEditorPane = false
    @ObservationIgnored
    private var performAction: (WriterPadEditorCommand) -> Void = { _ in }

    func update(
        perform: @escaping (WriterPadEditorCommand) -> Void,
        canToggleEditorPane: Bool
    ) {
        performAction = perform
        self.canToggleEditorPane = canToggleEditorPane
    }

    func perform(_ command: WriterPadEditorCommand) {
        performAction(command)
    }
}

enum WriterPadCloudStartup {
    static func start(
        syncEnabled: Bool,
        authenticationService: any AuthenticationServicing,
        deviceIdentityService: any DeviceIdentityProviding,
        syncDispatcher: SyncV2Dispatcher?,
        backgroundSyncCoordinator: SyncV2BackgroundSyncCoordinator?
    ) async {
        async let identity: Void = deviceIdentityService.prepareIdentity()
        guard syncEnabled else {
            await identity
            return
        }

        // 인증 네트워크 요청이 지연돼도 기존 queue 복구와 새 operation
        // 감시는 즉시 시작한다.
        await syncDispatcher?.start()
        async let authentication = authenticationService.restoreSession()
        let (state, _) = await (authentication, identity)
        guard state.isAuthenticated else { return }
        await syncDispatcher?.loginSucceeded()
        await backgroundSyncCoordinator?.start()
    }
}

struct WriterPadCommands: Commands {
    @FocusedValue(WriterPadCommandActions.self) private var actions

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
    @Environment(\.scenePhase) private var scenePhase
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
                .task {
                    await startCloudServices()
                }
                .task {
                    await observeAuthenticationChanges()
                }
                .onChange(of: scenePhase) { _, phase in
                    Task {
                        if phase == .active {
                            await resumeCloudServices()
                        } else {
                            await environment.backgroundSyncCoordinator?
                                .stop()
                        }
                    }
                }
        }
        .modelContainer(environment.modelContainer)
        .commands { WriterPadCommands() }
    }

    private func startCloudServices() async {
        await WriterPadCloudStartup.start(
            syncEnabled: GlobalSyncPreference.isEnabled(),
            authenticationService: environment.authenticationService,
            deviceIdentityService: environment.deviceIdentityService,
            syncDispatcher: environment.syncDispatcher,
            backgroundSyncCoordinator:
                environment.backgroundSyncCoordinator
        )
    }

    private func resumeCloudServices() async {
        guard GlobalSyncPreference.isEnabled() else { return }
        // 시작 task가 scene 전환으로 취소됐더라도 idempotent start로 복구한다.
        await environment.syncDispatcher?.start()
        await environment.syncDispatcher?.appEnteredForeground()
        let state = await environment.authenticationService.restoreSession()
        guard state.isAuthenticated else { return }
        await environment.syncDispatcher?.loginSucceeded()
        await environment.backgroundSyncCoordinator?.start()
        await environment.backgroundSyncCoordinator?.appEnteredForeground()
    }

    private func observeAuthenticationChanges() async {
        let updates = await environment.authenticationService.stateUpdates()
        for await state in updates {
            guard !Task.isCancelled else { return }
            await applyAuthenticationState(state)
        }
    }

    private func applyAuthenticationState(
        _ state: AuthenticationState
    ) async {
        switch state {
        case .authenticated:
            guard GlobalSyncPreference.isEnabled() else { return }
            await environment.syncDispatcher?.start()
            await environment.syncDispatcher?.loginSucceeded()
            await environment.backgroundSyncCoordinator?.start()
        case .signedOut, .localOnly:
            await environment.syncDispatcher?.stop()
            await environment.backgroundSyncCoordinator?.stop()
            await environment.editLeaseManager?.releaseAll()
        case .unavailable:
            // 인증되지 않은 동안 원격 pull/realtime/lease는 열지 않는다.
            // Dispatcher는 보존된 로컬 queue의 복구 상태를 유지할 수 있다.
            await environment.backgroundSyncCoordinator?.stop()
            await environment.editLeaseManager?.releaseAll()
        case .restoring:
            // 시작 시 로컬 queue 복구를 막지 않고 서버 검증 결과를 기다린다.
            break
        }
    }
}
