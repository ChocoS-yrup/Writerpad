import Foundation
import SwiftUI
import UIKit

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
    private let handshakeService: SyncV2HandshakeService?
    private let contractStructureSender: SyncV2ContractStructureSender?
    private let snapshotPuller: (any SyncV2SnapshotPulling)?
    private let defaults: UserDefaults

    init(
        projectManager: any ProjectManaging,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: (any EditLeaseManaging)? = nil,
        handshakeService: SyncV2HandshakeService? = nil,
        contractStructureSender: SyncV2ContractStructureSender? = nil,
        snapshotPuller: (any SyncV2SnapshotPulling)? = nil,
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
        self.handshakeService = handshakeService
        self.contractStructureSender = contractStructureSender
        self.snapshotPuller = snapshotPuller
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
        handshakeService: SyncV2HandshakeService? = nil,
        contractStructureSender: SyncV2ContractStructureSender? = nil,
        snapshotPuller: (any SyncV2SnapshotPulling)? = nil,
        defaults: UserDefaults
    ) {
        self.projectLister = projectLister
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        self.handshakeService = handshakeService
        self.contractStructureSender = contractStructureSender
        self.snapshotPuller = snapshotPuller
        self.defaults = defaults
        isSyncAllEnabled = GlobalSyncPreference.isEnabled(in: defaults)
    }

#if DEBUG
    /// 서버가 이 작품에 대해 무엇을 지원하는지 한 번 묻고 그 답을 보여 준다.
    ///
    /// 읽기 전용이다. 답이 무엇이든 계약 경로를 열지 않으며, 관문은 이 화면에서
    /// 건드리지 않는다. 개발 빌드에서 서버와 처음 대화해 보기 위한 자리다.
    @Published private(set) var handshakeReport: String?

    /// 연결하지 않은 서버 작품에도 물을 수 있게 한다.
    ///
    /// 작품을 연결하면 `ensure_project`가 서버에 쓴다. 핸드셰이크만 확인하려는
    /// 자리에서 그 쓰기를 유발하지 않으려고 서버 작품 id를 직접 받는다. 로컬
    /// 작품 id는 캐시 키에만 쓰이고 요청에는 실리지 않는다.
    /// 서버 구조를 내려받아 로컬에 반영만 한다. 서버로 나가는 것은 없다.
    ///
    /// 전체 동기화 토글은 dispatcher 를 함께 시작해서 나가는 쪽도 연다. 대조만
    /// 하려는 자리에서 그걸 켜면, 이름은 같고 id 가 다른 로컬 폴더가 서버로
    /// 나가 중복이 되거나 FOLDER_NAME_CONFLICT 로 막힌다. 그래서 pull 만 부른다.
    @Published private(set) var pullReport: String?

    /// 작품별 계약 경로 관문이다. 로컬 스위치이고 서버에 나가는 것이 없다.
    ///
    /// 켜도 그 자체로는 아무것도 쓰지 않는다. 서 있는 핸드셰이크와 함께여야
    /// 계약 경로가 쓰이고, 그 둘 중 어느 것도 서버가 움직일 수 없다.
    @Published private(set) var openContractPathProjectIDs: Set<ProjectID> = []

    func isGateOpen(for row: SyncProjectRow) -> Bool {
        openContractPathProjectIDs.contains(row.project.id)
    }

    func setGateOpen(_ isOpen: Bool, for row: SyncProjectRow) {
        if isOpen {
            ContractPathGate.setOpen(true, for: row.project.id, in: defaults)
            openContractPathProjectIDs.insert(row.project.id)
        } else {
            ContractPathGate.close(for: row.project.id, in: defaults)
            openContractPathProjectIDs.remove(row.project.id)
            // 관문을 닫으면 들고 있던 답도 버린다. 닫힌 뒤에도 답이 서 있으면
            // 다시 열었을 때 낡은 답으로 곧장 쓰기 시작한다.
            Task { await handshakeService?.gateClosed() }
        }
        gateReport = "\(row.project.name) 관문: \(isOpen ? "열림" : "닫힘")"
    }

    @Published private(set) var gateReport: String?
    @Published private(set) var contractSendReport: String?

    func sendOneContractBatch(for row: SyncProjectRow) async {
        guard let contractStructureSender else {
            contractSendReport = "계약 구조 전송을 사용할 수 없습니다."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await contractStructureSender.sendNext(
                localProjectID: row.project.id
            )
            contractSendReport = """
            batch_id: \(report.batchID.uuidString.lowercased())
            status: \(report.status.rawValue)
            operations: \(report.operationCount)
            """
        } catch {
            contractSendReport = "실패: \(error)"
        }
    }

    func runPullOnly(for row: SyncProjectRow) async {
        guard let snapshotPuller else {
            pullReport = "snapshot 전송이 없습니다. Supabase 설정을 확인하세요."
            return
        }
        guard let serverProjectID = row.binding?.serverProjectID else {
            pullReport = "이 작품은 서버에 연결되어 있지 않습니다."
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await snapshotPuller.pull(
                localProjectID: row.project.id,
                serverProjectID: serverProjectID,
                editingGuards: [:]
            )
            var lines = [
                "적용된 스냅샷: \(report.appliedSnapshots.count)",
                "결과: \(report.outcomes.count)",
            ]
            if report.rejectedStructureNames.isEmpty {
                lines.append("거부된 구조 이름: 없음")
            } else {
                lines.append("거부된 구조 이름 \(report.rejectedStructureNames.count):")
                for rejected in report.rejectedStructureNames.prefix(5) {
                    lines.append("  \(rejected.parent)/\(rejected.name) — \(rejected.reason)")
                }
            }
            pullReport = lines.joined(separator: "\n")
            await reloadProjects()
        } catch {
            pullReport = "실패: \(error)"
        }
    }

    func runHandshake(serverProjectIDText: String) async {
        guard let serverProjectID = UUID(uuidString: serverProjectIDText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            handshakeReport = "서버 작품 id가 UUID 형식이 아닙니다."
            return
        }
        await runHandshake(
            localProjectID: ProjectID(rawValue: serverProjectID),
            serverProjectID: serverProjectID
        )
    }

    func runHandshake(for row: SyncProjectRow) async {
        guard handshakeService != nil else {
            handshakeReport = "핸드셰이크 전송이 없습니다. Supabase 설정을 확인하세요."
            return
        }
        guard let serverProjectID = row.binding?.serverProjectID else {
            handshakeReport = "이 작품은 서버에 연결되어 있지 않습니다."
            return
        }
        await runHandshake(
            localProjectID: row.project.id,
            serverProjectID: serverProjectID
        )
    }

    private func runHandshake(
        localProjectID: ProjectID,
        serverProjectID: UUID
    ) async {
        guard let handshakeService else {
            handshakeReport = "핸드셰이크 전송이 없습니다. Supabase 설정을 확인하세요."
            return
        }
        guard let context = SyncV2HandshakeContext.make(
            authenticationState: authenticationState,
            localProjectID: localProjectID,
            serverProjectID: serverProjectID
        ) else {
            handshakeReport = "로그인 상태가 아니라 누구로서 묻는지 확정할 수 없습니다."
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let handshake = try await handshakeService.refresh(context: context)
            let gateIsOpen = ContractPathGate.isOpen(
                for: localProjectID,
                in: defaults
            )
            let usesContractPath = await handshakeService.usesContractStructure(
                context: context,
                gateIsOpen: gateIsOpen
            )
            handshakeReport = """
            supported: 예
            mode: \(handshake.projectSyncMode.rawValue) / epoch \(handshake.migrationEpoch)
            contract: \(handshake.contractVersion)
            protocol: \(handshake.serverProtocolVersion)
            supported_protocol_versions: \(handshake.supportedProtocolVersions)
            digest: \(handshake.contractSHA256.prefix(12))…
            capabilities: \(handshake.serverCapabilities.count)개
            관문: \(gateIsOpen ? "열림" : "닫힘")
            계약 경로: \(usesContractPath ? "사용" : "미사용")
            """
        } catch {
            handshakeReport = "실패: \(error)"
        }
    }
#endif

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
#if DEBUG
            // UserDefaults만 읽으면 토글 자체는 관찰할 상태가 없어 탭 직후 예전
            // 값으로 돌아간다. 로드할 때 저장값을 화면 상태로 한 번 끌어올린다.
            openContractPathProjectIDs = Set(
                rows.lazy
                    .filter {
                        ContractPathGate.isOpen(
                            for: $0.project.id,
                            in: self.defaults
                        )
                    }
                    .map(\.project.id)
            )
#endif
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

private enum AuthenticationField: Hashable {
    case email
    case password
    case passwordConfirmation
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

private struct AuthenticationTextField: UIViewRepresentable {
    let field: AuthenticationField
    let placeholder: String
    @Binding var text: String
    @Binding var focusedField: AuthenticationField?
    let isSecure: Bool
    let keyboardType: UIKeyboardType
    let textContentType: UITextContentType?
    let accessibilityIdentifier: String
    let isPreviousEnabled: Bool
    let isNextEnabled: Bool
    let onMove: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        configure(textField, coordinator: context.coordinator)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        configure(textField, coordinator: context.coordinator)

        if textField.text != text {
            textField.text = text
        }

        if focusedField == field {
            if !textField.isFirstResponder {
                textField.becomeFirstResponder()
            }
        } else if textField.isFirstResponder {
            textField.resignFirstResponder()
        }
    }

    private func configure(
        _ textField: UITextField,
        coordinator: Coordinator
    ) {
        textField.placeholder = placeholder
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = .tintColor
        textField.keyboardType = keyboardType
        textField.textContentType = textContentType
        if textField.isSecureTextEntry != isSecure {
            textField.isSecureTextEntry = isSecure
        }
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = isNextEnabled ? .next : .done
        textField.accessibilityIdentifier = accessibilityIdentifier
        textField.accessibilityLabel = placeholder

        guard coordinator.previousEnabled != isPreviousEnabled
                || coordinator.nextEnabled != isNextEnabled
                || coordinator.previousButton == nil
                || coordinator.nextButton == nil else {
            return
        }

        coordinator.previousEnabled = isPreviousEnabled
        coordinator.nextEnabled = isNextEnabled
        let previousButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.up"),
            style: .plain,
            target: coordinator,
            action: #selector(Coordinator.moveToPreviousField)
        )
        previousButton.accessibilityLabel = "이전 입력란"
        previousButton.accessibilityIdentifier =
            "writerpad.auth-previous-field"
        previousButton.isEnabled = isPreviousEnabled

        let nextButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
            style: .plain,
            target: coordinator,
            action: #selector(Coordinator.moveToNextField)
        )
        nextButton.accessibilityLabel = "다음 입력란"
        nextButton.accessibilityIdentifier = "writerpad.auth-next-field"
        nextButton.isEnabled = isNextEnabled

        coordinator.previousButton = previousButton
        coordinator.nextButton = nextButton
        textField.inputAssistantItem.trailingBarButtonGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [previousButton, nextButton],
                representativeItem: nil
            )
        ]
        if textField.isFirstResponder {
            textField.reloadInputViews()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AuthenticationTextField
        var previousEnabled: Bool?
        var nextEnabled: Bool?
        var previousButton: UIBarButtonItem?
        var nextButton: UIBarButtonItem?

        init(parent: AuthenticationTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focusedField = parent.field
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.focusedField == parent.field {
                parent.focusedField = nil
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if parent.isNextEnabled {
                parent.onMove(1)
            } else {
                textField.resignFirstResponder()
            }
            return false
        }

        @objc func moveToPreviousField() {
            parent.onMove(-1)
        }

        @objc func moveToNextField() {
            parent.onMove(1)
        }
    }
}

struct SyncSettingsView: View {
    @StateObject private var model: SyncSettingsModel
    @State private var authenticationMode: AuthenticationFormMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var focusedAuthenticationField: AuthenticationField?
    @State private var isConfirmingEnableAll = false
    @State private var connectionRequest: ExistingConnectionRequest?
    @State private var disconnectTarget: SyncProjectRow?
#if DEBUG
    @State private var handshakeProjectIDText = ""
#endif

    init(
        projectManager: any ProjectManaging,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: (any EditLeaseManaging)? = nil,
        handshakeService: SyncV2HandshakeService? = nil,
        contractStructureSender: SyncV2ContractStructureSender? = nil,
        snapshotPuller: (any SyncV2SnapshotPulling)? = nil,
    ) {
        _model = StateObject(
            wrappedValue: SyncSettingsModel(
                projectManager: projectManager,
                authenticationService: authenticationService,
                projectBindingService: projectBindingService,
                syncDispatcher: syncDispatcher,
                backgroundSyncCoordinator: backgroundSyncCoordinator,
                editLeaseManager: editLeaseManager,
                handshakeService: handshakeService,
                contractStructureSender: contractStructureSender,
                snapshotPuller: snapshotPuller
            )
        )
    }

    var body: some View {
        Form {
            accountSection
            if model.isAuthenticated {
                globalSyncSection
                projectConnectionsSection
#if DEBUG
                handshakeDiagnosticsSection
#endif
            } else {
                protectedCloudSection
            }
        }
        .navigationTitle("서버 동기화")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: authenticationMode) { _, mode in
            if mode == .signIn,
               focusedAuthenticationField == .passwordConfirmation {
                focusedAuthenticationField = .password
            }
        }
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

#if DEBUG
    /// 개발 빌드에서만 보이는 진단 자리다. 서버에 읽기만 하고 아무것도 쓰지 않는다.
    private var handshakeDiagnosticsSection: some View {
        Section("계약 핸드셰이크 (개발용)") {
            TextField("서버 작품 id (UUID)", text: $handshakeProjectIDText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(.footnote.monospaced())
            Button("이 id로 확인") {
                Task {
                    await model.runHandshake(
                        serverProjectIDText: handshakeProjectIDText
                    )
                }
            }
            .disabled(model.isWorking || handshakeProjectIDText.isEmpty)
            ForEach(model.projectRows.filter(\.isConnected)) { row in
                Toggle(
                    "\(row.project.name) 관문",
                    isOn: Binding(
                        get: { model.isGateOpen(for: row) },
                        set: { newValue in
                            model.setGateOpen(newValue, for: row)
                        }
                    )
                )
                Button("\(row.project.name) — pull만 실행") {
                    Task { await model.runPullOnly(for: row) }
                }
                .disabled(model.isWorking)
                Button("\(row.project.name) 확인") {
                    Task { await model.runHandshake(for: row) }
                }
                .disabled(model.isWorking)
                Button("\(row.project.name) — 대기 계약 배치 1건 전송") {
                    Task { await model.sendOneContractBatch(for: row) }
                }
                .disabled(model.isWorking || !model.isGateOpen(for: row))
            }
            if let report = model.gateReport {
                Text(report)
                    .font(.footnote.monospaced())
            }
            if let report = model.pullReport {
                Text(report)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            if let report = model.handshakeReport {
                Text(report)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            if let report = model.contractSendReport {
                Text(report)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Text("핸드셰크와 관문은 자체로는 읽기만 합니다. ‘대기 계약 배치 1건 전송’만 서버 구조를 쓸 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
#endif

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
                AuthenticationTextField(
                    field: .email,
                    placeholder: "이메일",
                    text: $email,
                    focusedField: $focusedAuthenticationField,
                    isSecure: false,
                    keyboardType: .emailAddress,
                    textContentType: .username,
                    accessibilityIdentifier: "writerpad.sync-email",
                    isPreviousEnabled: previousAuthenticationField != nil,
                    isNextEnabled: nextAuthenticationField != nil,
                    onMove: { moveAuthenticationFocus(by: $0) }
                )
                .frame(maxWidth: .infinity, minHeight: 36)
                AuthenticationTextField(
                    field: .password,
                    placeholder: "비밀번호",
                    text: $password,
                    focusedField: $focusedAuthenticationField,
                    isSecure: true,
                    keyboardType: .default,
                    textContentType: authenticationMode == .signUp
                        ? .newPassword
                        : .password,
                    accessibilityIdentifier: "writerpad.sync-password",
                    isPreviousEnabled: previousAuthenticationField != nil,
                    isNextEnabled: nextAuthenticationField != nil,
                    onMove: { moveAuthenticationFocus(by: $0) }
                )
                .frame(maxWidth: .infinity, minHeight: 36)
                if authenticationMode == .signUp {
                    AuthenticationTextField(
                        field: .passwordConfirmation,
                        placeholder: "비밀번호 확인",
                        text: $passwordConfirmation,
                        focusedField: $focusedAuthenticationField,
                        isSecure: true,
                        keyboardType: .default,
                        textContentType: .newPassword,
                        accessibilityIdentifier:
                            "writerpad.sync-password-confirmation",
                        isPreviousEnabled: previousAuthenticationField != nil,
                        isNextEnabled: nextAuthenticationField != nil,
                        onMove: { moveAuthenticationFocus(by: $0) }
                    )
                    .frame(maxWidth: .infinity, minHeight: 36)
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

    private var authenticationFields: [AuthenticationField] {
        if authenticationMode == .signUp {
            return [.email, .password, .passwordConfirmation]
        }
        return [.email, .password]
    }

    private var previousAuthenticationField: AuthenticationField? {
        adjacentAuthenticationField(offset: -1)
    }

    private var nextAuthenticationField: AuthenticationField? {
        adjacentAuthenticationField(offset: 1)
    }

    private func adjacentAuthenticationField(
        offset: Int
    ) -> AuthenticationField? {
        guard let focusedAuthenticationField,
              let currentIndex = authenticationFields.firstIndex(
                  of: focusedAuthenticationField
              ) else {
            return nil
        }
        let targetIndex = currentIndex + offset
        guard authenticationFields.indices.contains(targetIndex) else {
            return nil
        }
        return authenticationFields[targetIndex]
    }

    private func moveAuthenticationFocus(by offset: Int) {
        focusedAuthenticationField = adjacentAuthenticationField(
            offset: offset
        )
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
