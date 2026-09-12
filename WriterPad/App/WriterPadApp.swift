import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers

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
        guard ReceiveValidationPolicy.current.sendingAllowed else { return }
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

@MainActor
final class WriterPadStartupModel: ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    @Published private(set) var failed = false
    private let makeEnvironment: @MainActor () throws -> AppEnvironment

    init(makeEnvironment: @escaping @MainActor () throws -> AppEnvironment = AppEnvironment.startupDefault) {
        self.makeEnvironment = makeEnvironment
        retry()
    }

    func retry() {
        guard environment == nil else { return }
        do {
            environment = try makeEnvironment()
            failed = false
        } catch {
            // 저장소 오류에 경로나 개인정보가 섞일 수 있다. 원인을 숨긴 채
            // 새 DB로 대체하지 않고 기존 저장소를 그대로 다시 열 수 있게 둔다.
            failed = true
        }
    }
}

@main
@MainActor
struct WriterPadApp: App {
    @StateObject private var startup = WriterPadStartupModel()

    var body: some Scene {
        WindowGroup {
            if let environment = startup.environment {
                WriterPadRunningView(environment: environment)
            } else {
                WriterPadStartupRecoveryView(startup: startup)
            }
        }
        .commands { WriterPadCommands() }
    }
}

@MainActor
private struct WriterPadStartupRecoveryView: View {
    @ObservedObject var startup: WriterPadStartupModel
    @State private var selectsBackup = false
    @State private var isCheckingBackup = false
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("저장소를 열지 못했습니다") {
                    Text("앱을 지우거나 저장소를 초기화하지 마세요. 원고 파일과 기존 백업을 자동으로 삭제하거나 빈 저장소로 바꾸지 않았습니다.")
                    Text("이 화면에서는 로그인과 동기화를 시작하지 않습니다.")
                    Button("다시 열기") { startup.retry() }
                        .disabled(isCheckingBackup)
                        .accessibilityIdentifier("writerpad.startup-retry")
                }
                Section("원고 먼저 보관하기") {
                    Text("파일 앱 → 나의 iPad → ChocoS(또는 ChocoS Debug)에서 작품 폴더를 iCloud Drive나 외장 저장소로 복사하세요. 각 작품의 집필모드 폴더에 TXT 원고와 기존 백업이 있습니다.")
                    Text("파일 앱에 자료가 보이지 않아도 데이터가 없다고 판단하지 마세요. 이전 버전의 내부 저장소에 남아 있을 수 있으므로 앱을 보존하세요.")
                }
                Section("기존 백업 확인") {
                    Text("원고·구조 백업 폴더를 선택하면 내용을 변경하지 않고 복원 가능한 형식인지 검사합니다. 저장소가 다시 열리면 작품 목록에서 백업을 복원할 수 있습니다.")
                    Button("백업 폴더 검사…") { selectsBackup = true }
                        .disabled(isCheckingBackup)
                        .accessibilityIdentifier("writerpad.startup-check-backup")
                    if isCheckingBackup { ProgressView("백업 확인 중…") }
                    if let backupMessage { Text(backupMessage) }
                }
            }
            .navigationTitle("자료 보존 및 복구")
        }
        .fileImporter(isPresented: $selectsBackup, allowedContentTypes: [.folder]) { result in
            let url: URL
            switch result {
            case let .success(selected): url = selected
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError {
                    backupMessage = "백업 폴더를 열지 못했습니다. 파일 접근 권한을 확인하세요."
                }
                return
            }
            Task {
                isCheckingBackup = true
                backupMessage = nil
                defer { isCheckingBackup = false }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let manifest = try await ProjectBackupStore().validatedManifest(at: url)
                    backupMessage = "백업 형식과 본문 검증을 통과했습니다. 문서 \(manifest.nodes.filter { $0.kind == "document" }.count)개가 있습니다. 실제 복원은 저장소를 다시 연 뒤 진행하세요."
                } catch {
                    backupMessage = "백업을 확인하지 못했습니다. 선택한 폴더와 파일 접근 권한을 확인하세요. 원본 백업은 변경하지 않았습니다."
                }
            }
        }
    }
}

@MainActor
private struct WriterPadRunningView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var environment: AppEnvironment

    var body: some View {
        RootView()
            .environmentObject(environment)
            .modelContainer(environment.modelContainer)
            .task { await startCloudServices() }
            .task { await observeAuthenticationChanges() }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    if phase == .active {
                        await resumeCloudServices()
                    } else {
                        ReceiveValidationPolicy.current.invalidate()
                        await environment.backgroundSyncCoordinator?.stop()
                    }
                }
            }
    }

    private func startCloudServices() async {
#if !WRITERPAD_ISOLATED_TESTS
        await WriterPadCloudStartup.start(
            syncEnabled: GlobalSyncPreference.isEnabled(),
            authenticationService: environment.authenticationService,
            deviceIdentityService: environment.deviceIdentityService,
            syncDispatcher: environment.syncDispatcher,
            backgroundSyncCoordinator:
                environment.backgroundSyncCoordinator
        )
#endif
    }

    private func resumeCloudServices() async {
        guard ReceiveValidationPolicy.current.sendingAllowed else { return }
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
            ReceiveValidationPolicy.current.invalidate()
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
