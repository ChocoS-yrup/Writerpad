import Foundation
import SwiftUI
import UIKit

enum SyncV2HandoffNotifications {
    /// A hint to re-read local handoffs, not proof that the project is synced.
    static let settingsRetryFinished = Notification.Name("writerpad.sync-v2.settings-handoff-retry-finished")

    static func postSettingsRetryFinished(for projectID: ProjectID) {
        NotificationCenter.default.post(name: settingsRetryFinished, object: projectID.rawValue)
    }
}

enum GlobalSyncPreference {
    static let storageKey = "writerpad.sync-all-projects-enabled"
    static let contractEpoch = SyncV2ContractEpoch()

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        ReceiveValidationPolicy.current.sendingAllowed && defaults.bool(forKey: storageKey)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        guard ReceiveValidationPolicy.current.sendingAllowed else { return }
        contractEpoch.advance()
        defaults.set(isEnabled, forKey: storageKey)
    }
}

protocol SyncProjectListing: Sendable {
    var contractEpoch: SyncV2ContractEpoch? { get }
    func projects() async throws -> [ManagedProject]
}

extension SyncProjectListing {
    var contractEpoch: SyncV2ContractEpoch? { nil }
}

struct ProjectManagerSyncProjectLister: SyncProjectListing {
    let projectManager: any ProjectManaging
    var contractEpoch: SyncV2ContractEpoch? { projectManager.syncLifecycleEpoch }

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
    @Published private(set) var generalQueueStatuses: [ProjectID: SyncV2GeneralQueueStatus] = [:]
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
    var generalRecoveryReader: (any SyncV2GeneralRecoveryReading)? { contractStructureSender }
    private let snapshotPuller: (any SyncV2SnapshotPulling)?
    private let defaults: UserDefaults
    private let generalRetryEpoch = SyncV2ContractEpoch()

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
#endif

    /// Product opt-in, independent of the global automatic-sync preference.
    /// Opening validates compatibility; existing sender guards still authorize each write.
    @Published private(set) var openContractPathProjectIDs: Set<ProjectID> = []
    @Published private(set) var openingContractPathProjectIDs: Set<ProjectID> = []
    @Published private(set) var gateReport: String?

    func isGateOpen(for row: SyncProjectRow) -> Bool {
        openContractPathProjectIDs.contains(row.project.id)
    }

    @discardableResult
    func setGateOpen(_ isOpen: Bool, for row: SyncProjectRow, requiresIDBased: Bool = true) -> Task<Void, Never> {
        // 닫힘은 await 전에 반영한다. 열기는 새 조회가 끝난 뒤에만 허용한다.
        if !isOpen {
            ContractPathGate.close(for: row.project.id, in: defaults)
            openContractPathProjectIDs.remove(row.project.id)
            gateReport = "\(row.project.name) 관문: 닫힘"
            return Task { await handshakeService?.gateClosed() }
        }
        guard !isWorking, ReceiveValidationPolicy.current.sendingAllowed,
              openingContractPathProjectIDs.insert(row.id).inserted else { return Task {} }
        let revision = ContractPathGate.revision(for: row.project.id, in: defaults)
        let authEpoch = authenticationService.contractEpoch?.value ?? 0
        let bindingEpoch = projectBindingService.contractEpoch?.value ?? 0
        let localEpoch = projectLister.contractEpoch
        let localRevision = localEpoch?.value
        let activityRevision = handshakeService?.activityEpoch.value
        gateReport = "\(row.project.name) 서버 호환성 확인 중…"
        return Task {
            defer { openingContractPathProjectIDs.remove(row.id) }
            guard let handshakeService else {
                gateReport = "새 핸드셰이크를 확인할 수 없어 관문을 열지 않았습니다."
                return
            }
            let state = await authenticationService.currentState()
            let binding = await projectBindingService.currentBinding(for: row.project.id)
            guard case let .authenticated(account) = state,
                  let binding, binding.localProjectID == row.id, binding == row.binding,
                  binding.kind != .localOnly, binding.ownerSubject == account.userID,
                  localEpoch?.isAvailable == true,
                  (try? await projectLister.projects().contains { $0.id == row.id && $0.isActive }) == true,
                  let serverID = binding.serverProjectID,
                  let context = SyncV2HandshakeContext.make(authenticationState: state,
                      localProjectID: row.project.id, serverProjectID: serverID,
                      authenticationEpoch: authEpoch, bindingEpoch: bindingEpoch)
            else { gateReport = "로그인과 작품 연결을 확인해 주세요."; return }
            do {
                // 캐시가 있어도 명시적 열기는 서버를 새로 확인한다.
                guard await handshakeService.canStartContractWrite(),
                      authEpoch == authenticationService.contractEpoch?.value,
                      bindingEpoch == projectBindingService.contractEpoch?.value,
                      localEpoch?.value == localRevision,
                      ContractPathGate.revision(for: row.id, in: defaults) == revision,
                      !Task.isCancelled else { return }
                let handshake = try await handshakeService.refreshForGate(context: context)
                guard !requiresIDBased || handshake.projectSyncMode == .idBased else {
                    gateReport = "이 작품은 일반 동기화 형식으로 준비되지 않았습니다. 서버 작품을 임의로 이관하지 않았습니다."
                    return
                }
                let handshakeEpoch = handshakeService.authorizationEpoch.value
                guard await handshakeService.isFresh(for: context),
                      await handshakeService.canStartContractWrite(), !Task.isCancelled else { return }
                let opened = ContractPathGate.openAfterValidation(for: row.project.id,
                    in: defaults, revision: revision) {
                    ReceiveValidationPolicy.current.sendingAllowed &&
                    authenticationService.contractEpoch?.isAvailable == true &&
                    authEpoch == (authenticationService.contractEpoch?.value ?? 0) &&
                    bindingEpoch == (projectBindingService.contractEpoch?.value ?? 0) &&
                    (projectBindingService.contractEpoch?.isAvailable ?? false) &&
                    localEpoch?.isAvailable == true && localEpoch?.value == localRevision &&
                    handshakeService.activityEpoch.isAvailable && handshakeService.activityEpoch.value == activityRevision &&
                    handshakeEpoch == handshakeService.authorizationEpoch.value
                }
                if opened { openContractPathProjectIDs.insert(row.project.id) }
                gateReport = opened ? "\(row.project.name) 관문: 열림" : "상태가 바뀌어 관문을 열지 않았습니다."
            } catch {
                guard ContractPathGate.revision(for: row.project.id, in: defaults) == revision else { return }
                gateReport = "서버 호환성을 확인하지 못해 동기화를 활성화하지 않았습니다. 연결 상태를 확인하고 다시 시도하세요."
            }
        }
    }

    /// A late server response must not opt a project in after leaving the settings UI.
    func cancelPendingGateOpenings() {
        generalRetryEpoch.advance()
        guard !openingContractPathProjectIDs.isEmpty else { return }
        for id in openingContractPathProjectIDs {
            ContractPathGate.close(for: id, in: defaults)
            openContractPathProjectIDs.remove(id)
        }
        gateReport = "동기화 활성화 확인을 취소했습니다. 다시 선택해 주세요."
    }

    func refreshGeneralQueueStatus(for row: SyncProjectRow) async {
        guard let contractStructureSender else { return }
        generalQueueStatuses[row.id] = try? await contractStructureSender.generalQueueStatus(localProjectID: row.id)
    }

    func retryGeneralSync(for row: SyncProjectRow,
        documentRepository: (any DocumentRepository)? = nil,
        documentStore: (any LocalDocumentStoring)? = nil,
        binderCommands: (any BinderCommanding)? = nil) async {
        guard !isWorking, let contractStructureSender else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        informationMessage = nil
        do {
            var deferredCount = 0
            if let documentRepository, let documentStore {
                deferredCount = try await retryProjectHandoffs(for: row, repository: documentRepository,
                    store: documentStore, binderCommands: binderCommands)
            }
            try await contractStructureSender.retryGeneralContract(localProjectID: row.id)
            if deferredCount == 0 {
                informationMessage = "저장된 변경의 재시도를 요청했습니다. 응답이 확인될 때까지 로컬 원본을 유지합니다."
            } else {
                errorMessage = "저장 기록 \(deferredCount)개는 아직 대기열에 연결하지 못했습니다. 본문과 기록은 유지되며, 서버 기준과 연결 상태를 확인한 뒤 다시 시도할 수 있습니다."
            }
        } catch SyncV2ContractStructureError.structureAuthorityUnavailable {
            errorMessage = "서버와 마지막 동기화 기준이 다르거나 기준을 확인하지 못했습니다. 본문과 저장 기록은 그대로 두었습니다. 서버 변경과 동기화 상태를 확인해 주세요."
        } catch { errorMessage = "재시도를 시작하지 못했습니다. 동기화 연결 상태를 확인해 주세요." }
        await refreshGeneralQueueStatus(for: row)
    }

    /// Queue retries alone cannot see per-document handoff files left while offline or opted out.
    /// Replay the selected project's existing records only; never save/rewrite manuscript text here.
    private func retryProjectHandoffs(for row: SyncProjectRow, repository: any DocumentRepository,
        store: any LocalDocumentStoring, binderCommands: (any BinderCommanding)?) async throws -> Int {
        guard let handshakeService, let contractStructureSender else {
            throw SyncV2ContractStructureError.unavailable
        }
        guard let binding = row.binding else { throw SyncV2ContractStructureError.projectNotConnected }
        let retryEpoch = generalRetryEpoch, generation = retryEpoch.value
        let deferred = try await SyncV2ProjectHandoffResumer(projectLister: projectLister,
            authenticationService: authenticationService, projectBindingService: projectBindingService,
            handshakeService: handshakeService, sender: contractStructureSender,
            repository: repository, store: store, defaults: ContractDefaults(value: defaults), binderCommands: binderCommands)
            .resume(localProjectID: row.id, expectedBinding: binding) {
                guard retryEpoch.value == generation else { throw CancellationError() }
            }
        guard retryEpoch.value == generation else { throw CancellationError() }
        SyncV2HandoffNotifications.postSettingsRetryFinished(for: row.id)
        return deferred
    }

#if DEBUG
    @Published private(set) var contractSendReport: String?
    @Published private(set) var contractPreparations: [ProjectID: SyncV2ContractPreparation] = [:]
    @Published private(set) var preparationExportURLs: [ProjectID: URL] = [:]
    @Published private(set) var preparationReport: String?

    func prepareEmptyVolume(for row: SyncProjectRow) async {
        guard !isWorking, let contractStructureSender else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let value = try await contractStructureSender.prepareEmptyVolume(localProjectID: row.id)
            try publishPreparation(value)
            preparationReport = "빈 2권과 원고 순서의 검토용 요청을 저장했습니다. 폴더 생성과 서버 전송은 하지 않았습니다."
        } catch {
            preparationReport = "준비를 완료하지 못했습니다: \(error)"
        }
    }

    func discardUnsentPreparation(for row: SyncProjectRow) async {
        guard !isWorking, let contractStructureSender else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await contractStructureSender.discardUnsentPreparation(localProjectID: row.id)
            contractPreparations.removeValue(forKey: row.id)
            preparationExportURLs.removeValue(forKey: row.id)
            preparationReport = "미전송 검토 요청을 폐기했습니다. 새 준비에는 새 식별자가 사용됩니다."
        } catch {
            preparationReport = "요청을 보존했습니다. 송신을 시도한 배치는 먼저 결과를 확인해야 합니다: \(error)"
        }
    }

    private func publishPreparation(_ value: SyncV2ContractPreparation) throws {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("ContractReviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(try value.request.batchID.uuidString.lowercased() + ".json")
        try value.exportData().write(to: url, options: .atomic)
        contractPreparations[value.localProjectID] = value
        preparationExportURLs[value.localProjectID] = url
    }

    func sendReviewedPreparation(for row: SyncProjectRow) async {
        guard !isWorking, let contractStructureSender, let value = contractPreparations[row.id] else { return }
        let authRevision = authenticationService.contractEpoch?.value
        let bindingRevision = projectBindingService.contractEpoch?.value
        isWorking = true
        defer {
            isWorking = false
            _ = setGateOpen(false, for: row)
        }
        do {
            let report = try await contractStructureSender.sendNext(localProjectID: row.id,
                preparedBatchID: value.request.batchID, reviewedRequestSHA256: value.requestSHA256)
            guard report.mayPresentCompletion, authRevision == authenticationService.contractEpoch?.value,
                  bindingRevision == projectBindingService.contractEpoch?.value else { return }
            contractSendReport = "검토 배치 응답: \(report.batchID.uuidString.lowercased()) / \(report.status.rawValue)"
        } catch {
            contractSendReport = "전송 완료를 확인하지 못했습니다. 같은 요청을 보존했습니다: \(error)"
        }
    }
    private var contractReportRequestID = UUID()

    func sendOneContractBatch(for row: SyncProjectRow) async {
        guard let contractStructureSender else {
            contractSendReport = "계약 구조 전송을 사용할 수 없습니다."
            return
        }
        let requestID = UUID()
        contractReportRequestID = requestID
        let authEpoch = authenticationService.contractEpoch?.value ?? 0
        let bindingEpoch = projectBindingService.contractEpoch?.value ?? 0
        let generation = handshakeService?.authorizationEpoch.value
        func isCurrent() -> Bool {
            !Task.isCancelled && contractReportRequestID == requestID && authEpoch == (authenticationService.contractEpoch?.value ?? 0) &&
            bindingEpoch == (projectBindingService.contractEpoch?.value ?? 0) &&
            generation == handshakeService?.authorizationEpoch.value
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let report = try await contractStructureSender.sendNext(
                localProjectID: row.project.id
            )
            guard isCurrent(), report.mayPresentCompletion else { return }
            contractSendReport = """
            서버 응답 검증 완료
            batch_id: \(report.batchID.uuidString.lowercased())
            status: \(report.status.rawValue)
            operations: \(report.operationCount)
            """
        } catch {
            guard isCurrent() else { return }
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
            authenticationState: await authenticationService.currentState(),
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            authenticationEpoch: authenticationService.contractEpoch?.value ?? 0,
            bindingEpoch: projectBindingService.contractEpoch?.value ?? 0
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
            조회 당시 관문: \(gateIsOpen ? "열림" : "닫힘")
            조회 당시 계약 경로: \(usesContractPath ? "사용" : "미사용")
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
        if ReceiveValidationPolicy.current.enabled {
            do { _ = try ReceiveValidationPolicy.current.beginAuthentication(foreground: UIApplication.shared.applicationState == .active,
                endpoint: ReceiveValidationPolicy.Configuration.staging) }
            catch { errorMessage = "수신 확인 설정을 준비하지 못했습니다."; return }
        }
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
        guard ReceiveValidationPolicy.current.sendingAllowed else { return }
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
        guard ReceiveValidationPolicy.current.sendingAllowed else { return }
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
#if DEBUG
            for row in rows where row.binding?.serverProjectID == SyncV2EmptyVolumeReview.projectID {
                if let value = try await contractStructureSender?.reviewedPreparation(localProjectID: row.id) {
                    try publishPreparation(value)
                }
            }

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
            case .validationAuthorizationEnded:
                return "인증 확인 권한이 만료되거나 취소되어 로그인을 완료하지 못했습니다. 승인된 시험 계정과 화면 이탈 여부를 확인해 주세요."
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
    let onSubmit: (() -> Void)?

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
        textField.returnKeyType = onSubmit != nil ? .go : (isNextEnabled ? .next : .done)
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
            parent.text = textField.text ?? ""
            if let onSubmit = parent.onSubmit {
                onSubmit()
            } else if parent.isNextEnabled {
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
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: SyncSettingsModel
    @State private var authenticationMode: AuthenticationFormMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var focusedAuthenticationField: AuthenticationField?
    @State private var isConfirmingEnableAll = false
    @State private var connectionRequest: ExistingConnectionRequest?
    @State private var disconnectTarget: SyncProjectRow?
    @State private var generalRecoveryTarget: SyncProjectRow?
    @State private var enableProjectSyncTarget: SyncProjectRow?
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
            if ReceiveValidationPolicy.current.enabled { Text("송신 잠김 · 선택한 서버 작품만 가져올 수 있습니다.") }
            accountSection
            if GeneralSyncValidationScope.current.restricted {
                if let general = environment.generalValidationModel { GeneralValidationSection(model: general) }
            } else if ReceiveValidationPolicy.current.bodyValidationEnabled { BodyValidationSection() }
            localGeneralRecoverySection.disabled(ReceiveValidationPolicy.current.enabled)
            if model.isAuthenticated {
                globalSyncSection.disabled(ReceiveValidationPolicy.current.enabled)
                projectConnectionsSection.disabled(ReceiveValidationPolicy.current.enabled)
#if DEBUG
                handshakeDiagnosticsSection.disabled(ReceiveValidationPolicy.current.enabled)
#endif
            } else {
                protectedCloudSection
            }
        }
        .navigationTitle("서버 동기화")
        .onDisappear {
            model.cancelPendingGateOpenings()
            if ReceiveValidationPolicy.current.enabled { ReceiveValidationPolicy.current.invalidate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.cancelPendingGateOpenings() }
        }
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
            "‘\(enableProjectSyncTarget?.project.name ?? "")’의 일반 동기화를 활성화할까요?",
            isPresented: Binding(get: { enableProjectSyncTarget != nil },
                set: { if !$0 { enableProjectSyncTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("서버 호환성 확인 후 활성화") {
                guard let row = enableProjectSyncTarget else { return }
                enableProjectSyncTarget = nil
                model.setGateOpen(true, for: row)
            }
            Button("취소", role: .cancel) { enableProjectSyncTarget = nil }
        } message: {
            Text("전체 동기화가 켜져 있으면 이 작품의 저장된 변경을 서버와 주고받을 수 있습니다. 서버 연결·본문·대기 기록은 초기화하지 않습니다.")
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
        .sheet(item: $generalRecoveryTarget) { row in
            if let reader = model.generalRecoveryReader {
                GeneralSyncRecoveryView(projectID: row.id, projectName: row.project.name, reader: reader)
            }
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
                            model.setGateOpen(newValue, for: row, requiresIDBased: false)
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
                if row.binding?.serverProjectID == SyncV2EmptyVolumeReview.projectID {
                    Button("빈 2권 시험 요청 준비 · 전송 없음") {
                        Task { await model.prepareEmptyVolume(for: row) }
                    }
                    .disabled(model.isWorking || model.isGateOpen(for: row))
                    if let value = model.contractPreparations[row.id] {
                        Text("검토 요청 SHA-256: \(value.requestSHA256)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                        if let url = model.preparationExportURLs[row.id] {
                            ShareLink("검토 요청 JSON 공유", item: url)
                        }
                        Button("미전송 검토 요청 폐기", role: .destructive) {
                            Task { await model.discardUnsentPreparation(for: row) }
                        }
                        .disabled(model.isWorking || model.isGateOpen(for: row))
                        Button("검토한 빈 2권 배치 1건 전송") {
                            Task { await model.sendReviewedPreparation(for: row) }
                        }
                        .disabled(model.isWorking || !model.isGateOpen(for: row))
                    }
                }
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
            if let report = model.preparationReport {
                Text(report).font(.footnote).textSelection(.enabled)
            }
            if let report = model.contractSendReport {
                Text(report)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            Text("요청 준비와 공유는 서버에 쓰지 않습니다. 관문을 열고 전송 버튼을 누르면 서버 구조를 씁니다. 검토 배치 전송 후에는 관문이 닫힙니다.")
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
                    onMove: { moveAuthenticationFocus(by: $0) },
                    onSubmit: nil
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
                    onMove: { moveAuthenticationFocus(by: $0) },
                    onSubmit: authenticationMode == .signIn
                        ? { submitAuthentication() } : nil
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
                        onMove: { moveAuthenticationFocus(by: $0) },
                        onSubmit: nil
                    )
                    .frame(maxWidth: .infinity, minHeight: 36)
                    Text("비밀번호는 6자 이상이어야 합니다. 서버의 보안 정책에 따라 더 강한 비밀번호가 필요할 수 있습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(authenticationMode.title) {
                    submitAuthentication()
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

    private func submitAuthentication() {
        guard !model.isWorking, canSubmitAuthentication else { return }
        let submittedMode = authenticationMode
        let submittedEmail = email
        let submittedPassword = password
        focusedAuthenticationField = nil
        password = ""
        passwordConfirmation = ""
        Task {
            if submittedMode == .signUp {
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

    @ViewBuilder
    private var localGeneralRecoverySection: some View {
        if model.generalRecoveryReader != nil, !model.projectRows.isEmpty {
            Section("보관된 동기화 변경") {
                ForEach(model.projectRows) { row in
                    Button(row.project.name + " · 변경 확인") { generalRecoveryTarget = row }
                        .accessibilityIdentifier("writerpad.general-recovery-" + row.id.rawValue.uuidString)
                }
                Text("충돌하거나 대기 중인 변경을 확인하고 저장 당시 원고를 꺼낼 수 있습니다. 이 iPad의 보관본만 읽습니다.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
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
                            Toggle("이 작품의 일반 동기화", isOn: Binding(
                                get: { model.isGateOpen(for: row) },
                                set: { enabled in
                                    if enabled { enableProjectSyncTarget = row }
                                    else { model.setGateOpen(false, for: row) }
                                }))
                                .disabled(model.openingContractPathProjectIDs.contains(row.id))
                                .accessibilityIdentifier("writerpad.project-sync-" + row.id.rawValue.uuidString)
                            if model.openingContractPathProjectIDs.contains(row.id) {
                                ProgressView("서버 호환성 확인 중…")
                            }
                            Text(model.isGateOpen(for: row)
                                ? "일반 동기화 활성화됨 · 자동 송수신은 전체 동기화 설정을 따릅니다."
                                : "서버 연결만 저장된 상태입니다. 일반 동기화를 활성화해야 새 계약 경로를 사용할 수 있습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let status = model.generalQueueStatuses[row.id], status.pendingCount > 0 {
                                Text(status.message).font(.caption).foregroundStyle(.secondary)
                            }
                            if model.isGateOpen(for: row) {
                                Button("저장 기록 연결 및 재시도") {
                                    Task { await model.retryGeneralSync(for: row,
                                        documentRepository: environment.documentRepository,
                                        documentStore: environment.localDocumentStore,
                                        binderCommands: environment.binderCommands) }
                                }
                                .disabled(model.isWorking || !model.isSyncAllEnabled ||
                                    (model.generalQueueStatuses[row.id]?.attentionCount ?? 0) > 0)
                                Text("문서별 저장 기록과 로컬 작업이 완료된 구조 변경 기록을 다시 연결합니다. 본문을 덮어쓰거나 미완료 파일 작업을 자동 복구하지 않습니다.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("동기화 상태 새로 고침") { Task { await model.refreshGeneralQueueStatus(for: row) } }
                                .task { await model.refreshGeneralQueueStatus(for: row) }
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
                if let report = model.gateReport { Text(report).font(.footnote) }
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
        case .validationAuthorizationEnded:
            return "인증 확인이 중단됐습니다. 승인된 시험 계정과 화면 이탈 여부를 확인해 주세요."
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
