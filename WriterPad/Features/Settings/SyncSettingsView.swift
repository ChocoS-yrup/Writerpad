import Foundation
import SwiftUI

enum GlobalSyncPreference {
    static let storageKey = "writerpad.sync-all-projects-enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(isEnabled, forKey: storageKey)
    }
}

protocol SyncProjectListing: Sendable {
    func projects() async throws -> [ManagedProject]
}

private struct ProjectManagerSyncProjectLister: SyncProjectListing {
    let projectManager: any ProjectManaging

    func projects() async throws -> [ManagedProject] {
        try await projectManager.projects()
    }
}

struct SyncProjectRow: Identifiable, Equatable, Sendable {
    let project: ManagedProject
    let binding: ProjectSyncBinding?

    var id: ProjectID { project.id }

    var isConnected: Bool {
        guard let binding else { return false }
        return binding.kind != .localOnly && binding.serverProjectID != nil
    }

    var statusText: String {
        guard let binding, isConnected else { return "이 iPad에만 저장됨" }
        switch binding.kind {
        case .newServerProject:
            return "새 서버 작품으로 연결됨"
        case .existingServerProject:
            return "기존 서버 작품에 연결됨"
        case .windowsImport:
            return "Windows 작품에 연결됨"
        case .localOnly:
            return "이 iPad에만 저장됨"
        }
    }
}

@MainActor
final class SyncSettingsModel: ObservableObject {
    @Published private(set) var authenticationState: AuthenticationState =
        .localOnly
    @Published private(set) var projectRows: [SyncProjectRow] = []
    @Published private(set) var isSyncAllEnabled: Bool
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var informationMessage: String?

    private let projectLister: any SyncProjectListing
    private let authenticationService: any AuthenticationServicing
    private let projectBindingService: any ProjectBindingServicing
    private let syncDispatcher: SyncV2Dispatcher?
    private let backgroundSyncCoordinator:
        SyncV2BackgroundSyncCoordinator?
    private let editLeaseManager: (any EditLeaseManaging)?
    private let defaults: UserDefaults

    init(
        projectManager: any ProjectManaging,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: (any EditLeaseManaging)? = nil,
        defaults: UserDefaults = .standard
    ) {
        projectLister = ProjectManagerSyncProjectLister(
            projectManager: projectManager
        )
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        self.defaults = defaults
        isSyncAllEnabled = GlobalSyncPreference.isEnabled(in: defaults)
    }

    init(
        projectLister: any SyncProjectListing,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher? = nil,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: (any EditLeaseManaging)? = nil,
        defaults: UserDefaults
    ) {
        self.projectLister = projectLister
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        self.defaults = defaults
        isSyncAllEnabled = GlobalSyncPreference.isEnabled(in: defaults)
    }

    var isAuthenticated: Bool {
        authenticationState.isAuthenticated
    }

    var unconnectedProjectCount: Int {
        projectRows.filter { !$0.isConnected }.count
    }

    func load() async {
        authenticationState = await authenticationService.currentState()
        await reloadProjects()
    }

    func observeAuthenticationChanges() async {
        let updates = await authenticationService.stateUpdates()
        for await updatedState in updates {
            guard !Task.isCancelled else { return }
            authenticationState = updatedState
        }
    }

    func signUp(email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        informationMessage = nil

        let result = await authenticationService.signUp(
            email: email,
            password: password
        )
        authenticationState = await authenticationService.currentState()
        switch result {
        case .authenticated:
            if isSyncAllEnabled {
                await syncDispatcher?.start()
                await backgroundSyncCoordinator?.start()
            }
            await syncDispatcher?.loginSucceeded()
            informationMessage = "계정을 만들고 로그인했습니다."
        case let .confirmationRequired(maskedEmail):
            let recipient = maskedEmail.map { " (\($0))" } ?? ""
            informationMessage = "확인 이메일을 보냈습니다\(recipient). 이메일을 확인한 뒤 로그인하세요."
        case let .failed(failure):
            errorMessage = Self.authenticationMessage(
                .unavailable(failure)
            )
        }
        isWorking = false
    }

    func signIn(email: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        informationMessage = nil
        authenticationState = await authenticationService.signIn(
            email: email,
            password: password
        )
        if authenticationState.isAuthenticated {
            if isSyncAllEnabled {
                await syncDispatcher?.start()
                await backgroundSyncCoordinator?.start()
            }
            await syncDispatcher?.loginSucceeded()
            informationMessage = "서버 계정에 로그인했습니다."
        } else {
            errorMessage = Self.authenticationMessage(authenticationState)
        }
        isWorking = false
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        informationMessage = nil
        authenticationState = await authenticationService.signOut()
        await syncDispatcher?.stop()
        await backgroundSyncCoordinator?.stop()
        await editLeaseManager?.releaseAll()
        informationMessage = isSyncAllEnabled
            ? "로그아웃했습니다. 작품 연결은 유지되고 동기화만 멈췄습니다."
            : "로그아웃했습니다."
        isWorking = false
    }

    func requireLogin() {
        errorMessage = "모든 작품 동기화를 켜려면 먼저 서버 계정에 로그인하세요."
    }

    func enableSyncForAllProjects() async {
        guard !isWorking else { return }
        guard authenticationState.isAuthenticated else {
            requireLogin()
            return
        }

        isWorking = true
        errorMessage = nil
        informationMessage = nil
        isSyncAllEnabled = true
        GlobalSyncPreference.setEnabled(true, in: defaults)
        await syncDispatcher?.start()
        await backgroundSyncCoordinator?.start()

        var failedProjects: [(String, ProjectBindingFailure)] = []
        for row in projectRows where !row.isConnected {
            let result = await projectBindingService.createServerProject(
                for: row.project.id
            )
            if case let .failed(failure) = result {
                failedProjects.append((row.project.name, failure))
            }
        }

        await reloadProjects()
        await syncDispatcher?.userRequestedRetry()
        await backgroundSyncCoordinator?.appEnteredForeground()
        if failedProjects.isEmpty {
            informationMessage = projectRows.isEmpty
                ? "전체 작품 동기화를 켰습니다. 새 작품부터 자동으로 연결됩니다."
                : "전체 작품 동기화를 켰습니다."
        } else {
            let names = failedProjects.map(\.0).joined(separator: ", ")
            errorMessage = "전체 동기화는 켰지만 다음 작품을 연결하지 못했습니다: \(names). "
                + Self.bindingMessage(failedProjects[0].1)
        }
        isWorking = false
    }

    func disableSyncForAllProjects() async {
        guard !isWorking else { return }
        isSyncAllEnabled = false
        GlobalSyncPreference.setEnabled(false, in: defaults)
        await syncDispatcher?.stop()
        await backgroundSyncCoordinator?.stop()
        await editLeaseManager?.releaseAll()
        informationMessage = "자동 동기화를 멈췄습니다. 작품별 서버 연결은 유지됩니다."
    }

    func connectAsNewServerProject(_ projectID: ProjectID) async {
        await performBinding {
            await projectBindingService.createServerProject(for: projectID)
        }
    }

    func connectExistingServerProject(
        _ projectID: ProjectID,
        serverID: String,
        confirmation: String,
        isWindowsImport: Bool
    ) async {
        guard
            let expectedID = UUID(
                uuidString: serverID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        else {
            errorMessage = "서버 작품 ID가 올바른 UUID 형식이 아닙니다."
            return
        }

        let confirmedID: ConfirmedServerProjectID
        do {
            confirmedID = try ConfirmedServerProjectID(
                expectedServerProjectID: expectedID,
                userEnteredUUID: confirmation
            )
        } catch ProjectBindingConfirmationError.invalidUUID {
            errorMessage = "확인용 서버 작품 ID가 올바른 UUID 형식이 아닙니다."
            return
        } catch ProjectBindingConfirmationError.mismatch {
            errorMessage = "두 서버 작품 ID가 일치하지 않습니다."
            return
        } catch {
            errorMessage = "서버 작품 ID를 확인하지 못했습니다."
            return
        }

        await performBinding {
            if isWindowsImport {
                return await projectBindingService.connectWindowsProject(
                    localProjectID: projectID,
                    confirmation: confirmedID
                )
            }
            return await projectBindingService.connectExistingProject(
                localProjectID: projectID,
                confirmation: confirmedID
            )
        }
    }

    func disconnect(_ projectID: ProjectID) async {
        await performBinding {
            await projectBindingService.disconnect(localProjectID: projectID)
        }
    }

    func refreshServerName(_ projectID: ProjectID) async {
        await performBinding {
            await projectBindingService.refreshServerName(for: projectID)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func clearInformation() {
        informationMessage = nil
    }

    private func reloadProjects() async {
        do {
            let projects = try await projectLister.projects()
                .filter(\.isActive)
            var rows: [SyncProjectRow] = []
            rows.reserveCapacity(projects.count)
            for project in projects {
                let binding = await projectBindingService.currentBinding(
                    for: project.id
                )
                rows.append(
                    SyncProjectRow(project: project, binding: binding)
                )
            }
            projectRows = rows
        } catch {
            errorMessage = "작품 목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func performBinding(
        _ operation: () async -> ProjectBindingResult
    ) async {
        guard !isWorking else { return }
        guard authenticationState.isAuthenticated else {
            requireLogin()
            return
        }
        isWorking = true
        errorMessage = nil
        informationMessage = nil
        let result = await operation()
        switch result {
        case .connected:
            informationMessage = "서버 작품 연결을 저장했습니다."
            await syncDispatcher?.userRequestedRetry()
        case .disconnected:
            informationMessage = "이 iPad의 작품만 연결 해제했습니다. 서버 데이터는 삭제하지 않았습니다."
        case let .failed(failure):
            errorMessage = Self.bindingMessage(failure)
        }
        await reloadProjects()
        await backgroundSyncCoordinator?.appEnteredForeground()
        isWorking = false
    }

    private static func authenticationMessage(
        _ state: AuthenticationState
    ) -> String {
        switch state {
        case .localOnly, .signedOut:
            return "서버 계정에 로그인하지 않았습니다."
        case .restoring:
            return "저장된 서버 로그인을 확인하고 있습니다."
        case .authenticated:
            return ""
        case let .unavailable(failure):
            switch failure {
            case .configurationUnavailable:
                return "서버 주소와 공개 키가 이 빌드에 설정되지 않았습니다."
            case .invalidCredentials:
                return "아이디 또는 비밀번호가 올바르지 않습니다."
            case .weakPassword:
                return "더 안전한 비밀번호를 사용하세요."
            case .accountAlreadyExists:
                return "이미 등록된 이메일입니다. 로그인해 주세요."
            case .signUpDisabled:
                return "현재 새 계정을 만들 수 없습니다."
            case .emailNotConfirmed:
                return "이메일 확인을 완료한 뒤 로그인하세요."
            case .networkUnavailable:
                return "서버에 연결할 수 없습니다. 네트워크를 확인하세요."
            case .keychainAccess:
                return "로그인 정보를 iPad 키체인에 안전하게 저장하지 못했습니다."
            case .serverRejected:
                return "서버가 로그인을 처리하지 못했습니다."
            }
        }
    }

    private static func bindingMessage(
        _ failure: ProjectBindingFailure
    ) -> String {
        switch failure {
        case .configurationUnavailable:
            return "서버 설정이 이 빌드에 없습니다."
        case .authenticationRequired:
            return "서버 계정에 다시 로그인하세요."
        case .bindingStoreUnavailable:
            return "작품 연결 정보를 저장할 수 없습니다."
        case .localStorageUnavailable:
            return "로컬 작품 저장소를 읽을 수 없습니다."
        case .localProjectNotFound:
            return "이 iPad에서 작품을 찾지 못했습니다."
        case .invalidProjectName:
            return "작품 이름을 확인하세요."
        case .confirmationRequired:
            return "서버 작품 ID를 다시 확인하세요."
        case .serverProjectAlreadyBound:
            return "해당 서버 작품은 이미 다른 로컬 작품에 연결되어 있습니다."
        case .serverProjectNotEmpty:
            return """
                해당 서버 작품에 이미 원고가 있습니다. \
                원고가 없는 서버 작품을 선택하거나 \
                새 서버 작품으로 등록해 주세요.
                """
        case .forbidden:
            return "이 계정에는 해당 서버 작품 권한이 없습니다."
        case .networkUnavailable:
            return "서버에 연결할 수 없습니다. 네트워크를 확인하세요."
        case .invalidServerResponse:
            return "서버가 예상과 다른 작품 정보를 반환했습니다."
        case .serverRejected:
            return "서버가 작품 연결을 처리하지 못했습니다."
        case .initialSnapshotNotQueued:
            return "최초 작품 snapshot을 안전하게 기록하지 못했습니다. 앱을 다시 열면 자동으로 재시도합니다."
        case .notBound:
            return "아직 서버에 연결되지 않은 작품입니다."
        }
    }
}

private enum AuthenticationFormMode: String, CaseIterable, Identifiable {
    case signIn
    case signUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .signIn: "로그인"
        case .signUp: "회원 가입"
        }
    }
}

private enum ExistingConnectionKind: String, Identifiable {
    case existing
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .existing: return "기존 서버 작품 연결"
        case .windows: return "Windows 작품 연결"
        }
    }

    var isWindowsImport: Bool { self == .windows }
}

private struct ExistingConnectionRequest: Identifiable {
    let project: ManagedProject
    let kind: ExistingConnectionKind

    var id: String {
        "\(project.id.rawValue.uuidString)-\(kind.rawValue)"
    }
}

struct SyncSettingsView: View {
    @StateObject private var model: SyncSettingsModel
    @State private var authenticationMode: AuthenticationFormMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var isConfirmingEnableAll = false
    @State private var connectionRequest: ExistingConnectionRequest?
    @State private var disconnectTarget: SyncProjectRow?

    init(
        projectManager: any ProjectManaging,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: (any EditLeaseManaging)? = nil
    ) {
        _model = StateObject(
            wrappedValue: SyncSettingsModel(
                projectManager: projectManager,
                authenticationService: authenticationService,
                projectBindingService: projectBindingService,
                syncDispatcher: syncDispatcher,
                backgroundSyncCoordinator: backgroundSyncCoordinator,
                editLeaseManager: editLeaseManager
            )
        )
    }

    var body: some View {
        Form {
            accountSection
            if model.isAuthenticated {
                globalSyncSection
                projectConnectionsSection
            } else {
                protectedCloudSection
            }
        }
        .navigationTitle("서버 동기화")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isWorking)
        .overlay {
            if model.isWorking {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .task {
            await model.load()
            await model.observeAuthenticationChanges()
        }
        .confirmationDialog(
            "연결되지 않은 작품 \(model.unconnectedProjectCount)개를 새 서버 작품으로 연결할까요?",
            isPresented: $isConfirmingEnableAll,
            titleVisibility: .visible
        ) {
            Button("연결하고 전체 동기화 켜기") {
                Task { await model.enableSyncForAllProjects() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 서버 또는 Windows에 이미 있는 작품은 취소한 뒤 작품별 ‘기존 서버 연결’을 먼저 사용하세요.")
        }
        .confirmationDialog(
            "‘\(disconnectTarget?.project.name ?? "")’의 서버 연결을 해제할까요?",
            isPresented: Binding(
                get: { disconnectTarget != nil },
                set: { if !$0 { disconnectTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("이 iPad에서 연결 해제", role: .destructive) {
                guard let target = disconnectTarget else { return }
                disconnectTarget = nil
                Task { await model.disconnect(target.project.id) }
            }
            Button("취소", role: .cancel) {
                disconnectTarget = nil
            }
        } message: {
            Text("서버의 작품과 원고는 삭제하지 않습니다.")
        }
        .sheet(item: $connectionRequest) { request in
            ExistingProjectConnectionView(
                projectName: request.project.name,
                kind: request.kind,
                onCancel: { connectionRequest = nil },
                onConnect: { serverID, confirmation in
                    connectionRequest = nil
                    Task {
                        await model.connectExistingServerProject(
                            request.project.id,
                            serverID: serverID,
                            confirmation: confirmation,
                            isWindowsImport: request.kind.isWindowsImport
                        )
                    }
                }
            )
        }
        .alert(
            "동기화 작업을 완료하지 못했습니다",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("확인") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "동기화",
            isPresented: Binding(
                get: { model.informationMessage != nil },
                set: { if !$0 { model.clearInformation() } }
            )
        ) {
            Button("확인") { model.clearInformation() }
        } message: {
            Text(model.informationMessage ?? "")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("서버 계정") {
            switch model.authenticationState {
            case let .authenticated(account):
                LabeledContent("로그인", value: account.maskedEmail ?? "인증됨")
                Button("로그아웃", role: .destructive) {
                    Task { await model.signOut() }
                }
                .accessibilityIdentifier("writerpad.sync-sign-out")
            case .restoring:
                HStack {
                    ProgressView()
                    Text("저장된 로그인을 확인하는 중…")
                }
            case .localOnly, .signedOut, .unavailable:
                Picker("인증 방식", selection: $authenticationMode) {
                    ForEach(AuthenticationFormMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("writerpad.auth-mode")
                TextField("이메일", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("writerpad.sync-email")
                SecureField("비밀번호", text: $password)
                    .textContentType(
                        authenticationMode == .signUp
                            ? .newPassword
                            : .password
                    )
                    .accessibilityIdentifier("writerpad.sync-password")
                if authenticationMode == .signUp {
                    SecureField("비밀번호 확인", text: $passwordConfirmation)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier(
                            "writerpad.sync-password-confirmation"
                        )
                    Text("비밀번호는 6자 이상이어야 합니다. 서버의 보안 정책에 따라 더 강한 비밀번호가 필요할 수 있습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(authenticationMode.title) {
                    let submittedEmail = email
                    let submittedPassword = password
                    password = ""
                    passwordConfirmation = ""
                    Task {
                        if authenticationMode == .signUp {
                            await model.signUp(
                                email: submittedEmail,
                                password: submittedPassword
                            )
                        } else {
                            await model.signIn(
                                email: submittedEmail,
                                password: submittedPassword
                            )
                        }
                    }
                }
                .disabled(!canSubmitAuthentication)
                .accessibilityIdentifier(
                    authenticationMode == .signUp
                        ? "writerpad.sync-sign-up"
                        : "writerpad.sync-sign-in"
                )

                if case let .unavailable(failure) = model.authenticationState {
                    Text(unavailableHint(failure))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text("비밀번호는 로그인·회원 가입 요청에만 사용하며 앱 설정에 저장하지 않습니다. 로그인 토큰은 iPad 키체인에 저장합니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var protectedCloudSection: some View {
        Section("보호된 클라우드 기능") {
            Label("로그인 필요", systemImage: "lock.fill")
                .font(.headline)
            Text("모든 작품 동기화와 작품별 서버 연결은 인증된 계정에서만 열립니다. 로컬 작품 작성과 저장은 계속 사용할 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("writerpad.protected-cloud-route")
    }

    private var canSubmitAuthentication: Bool {
        let hasEmail = !email.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasEmail, !password.isEmpty else { return false }
        if authenticationMode == .signUp {
            return password.count >= 6 && password == passwordConfirmation
        }
        return true
    }

    private var globalSyncSection: some View {
        Section("전체 동기화") {
            Toggle(
                "모든 작품 동기화",
                isOn: Binding(
                    get: { model.isSyncAllEnabled },
                    set: { requestedValue in
                        if requestedValue {
                            guard model.isAuthenticated else {
                                model.requireLogin()
                                return
                            }
                            isConfirmingEnableAll = true
                        } else {
                            Task { await model.disableSyncForAllProjects() }
                        }
                    }
                )
            )
            .accessibilityIdentifier("writerpad.sync-all-projects")

            Text(globalSyncDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var projectConnectionsSection: some View {
        Section("작품별 서버 연결") {
            if model.projectRows.isEmpty {
                Text("연결할 작품이 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.projectRows) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.project.name)
                                    .font(.headline)
                                Text(row.statusText)
                                    .font(.caption)
                                    .foregroundStyle(
                                        row.isConnected ? Color.green : Color.secondary
                                    )
                            }
                            Spacer()
                            Image(
                                systemName: row.isConnected
                                    ? "checkmark.icloud"
                                    : "icloud.slash"
                            )
                            .foregroundStyle(
                                row.isConnected ? Color.green : Color.secondary
                            )
                        }

                        if let serverID = row.binding?.serverProjectID {
                            Text(serverID.uuidString.lowercased())
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if row.isConnected {
                            HStack {
                                Button("서버 이름 갱신") {
                                    Task {
                                        await model.refreshServerName(row.project.id)
                                    }
                                }
                                Button("연결 해제", role: .destructive) {
                                    disconnectTarget = row
                                }
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Menu("서버 작품 연결") {
                                Button("새 서버 작품 만들기") {
                                    Task {
                                        await model.connectAsNewServerProject(
                                            row.project.id
                                        )
                                    }
                                }
                                Button("기존 서버 작품 연결…") {
                                    connectionRequest = ExistingConnectionRequest(
                                        project: row.project,
                                        kind: .existing
                                    )
                                }
                                Button("Windows 작품 연결…") {
                                    connectionRequest = ExistingConnectionRequest(
                                        project: row.project,
                                        kind: .windows
                                    )
                                }
                            }
                            .accessibilityIdentifier(
                                "writerpad.sync-project-\(row.project.id.rawValue.uuidString)"
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Text("작품별 연결 해제는 이 iPad만 로컬 전용으로 전환합니다. 서버 데이터는 삭제하지 않습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var globalSyncDescription: String {
        if model.isSyncAllEnabled, !model.isAuthenticated {
            return "로그아웃되어 동기화가 멈춰 있습니다. 다시 로그인하면 작품 연결을 그대로 사용합니다."
        }
        if model.isSyncAllEnabled {
            return "연결된 모든 작품을 자동 동기화합니다. 작품별 연결 정보는 유지됩니다."
        }
        return "꺼도 작품별 서버 연결은 지우지 않습니다. 다시 켜면 이어서 동기화합니다."
    }

    private func unavailableHint(_ failure: AuthenticationFailure) -> String {
        switch failure {
        case .configurationUnavailable:
            return "이 빌드에는 서버 주소와 공개 키가 설정되지 않았습니다."
        case .invalidCredentials:
            return "아이디 또는 비밀번호를 다시 확인하세요."
        case .weakPassword:
            return "더 안전한 비밀번호를 사용하세요."
        case .accountAlreadyExists:
            return "이미 등록된 이메일입니다. 로그인해 주세요."
        case .signUpDisabled:
            return "현재 새 계정을 만들 수 없습니다."
        case .emailNotConfirmed:
            return "이메일 확인을 완료한 뒤 로그인하세요."
        case .networkUnavailable:
            return "네트워크에 연결되면 다시 시도하세요."
        case .keychainAccess:
            return "iPad 키체인을 사용할 수 없습니다."
        case .serverRejected:
            return "서버 응답을 확인한 뒤 다시 시도하세요."
        }
    }
}

private struct ExistingProjectConnectionView: View {
    let projectName: String
    let kind: ExistingConnectionKind
    let onCancel: () -> Void
    let onConnect: (String, String) -> Void

    @State private var serverID = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(kind.title) {
                    LabeledContent("로컬 작품", value: projectName)
                    TextField("서버 작품 UUID", text: $serverID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("writerpad.server-project-id")
                    TextField("서버 작품 UUID 다시 입력", text: $confirmation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier(
                            "writerpad.server-project-id-confirmation"
                        )
                }

                Section {
                    Text("작품 이름이 아니라 서버의 project_id UUID를 두 번 입력하세요. 잘못된 작품 연결을 막기 위한 확인 단계입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("연결") {
                        onConnect(serverID, confirmation)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(serverID.isEmpty || confirmation.isEmpty)
                }
            }
        }
    }
}
