import SwiftUI

struct SyncProjectTransitionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SyncV2ProjectTransitionModel
    @State private var confirmation: String?
    private let name: String

    init(row: SyncProjectRow, environment: AppEnvironment, transport: any SyncV2TransitionTransporting) {
        name = row.project.name
        let auth = environment.authenticationService
        let bindings = environment.projectBindingService
        let projects = environment.projectManager
        let device = environment.deviceIdentityService
        let handshake = environment.handshakeService
        let sender = environment.contractStructureSender
        _model = StateObject(wrappedValue: SyncV2ProjectTransitionModel(transport: transport, journal: .shared) { requiresIdleQueue in
            guard !GlobalSyncPreference.isEnabled(), !ContractPathGate.isOpen(for: row.id),
                  !ReceiveValidationPolicy.current.enabled, !GeneralSyncValidationScope.current.restricted,
                  let authEpoch = auth.contractEpoch, let bindingEpoch = bindings.contractEpoch,
                  let projectEpoch = projects.syncLifecycleEpoch,
                  let handshake, let sender, await handshake.canStartContractWrite() else {
                throw SyncV2ContractError("TRANSITION_REQUIRES_CLOSED_SYNC")
            }
            let activity = handshake.activityEpoch
            let revisions = [authEpoch.value, bindingEpoch.value, projectEpoch.value, activity.value]
            let gate = ContractPathGate.revision(for: row.id)
            let global = GlobalSyncPreference.contractEpoch.value
            guard case let .authenticated(account) = await auth.currentState(),
                  let binding = await bindings.storedBindingForInspection(for: row.id), binding == row.binding,
                  binding.ownerSubject == account.userID, let serverID = binding.serverProjectID,
                  (try await projects.projects()).contains(where: { $0.id == row.id && $0.isActive })
            else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            let deviceID = try await device.currentIdentifier().uuid
            guard let context = SyncV2HandshakeContext.make(authenticationState: .authenticated(account),
                localProjectID: row.id, serverProjectID: serverID,
                authenticationEpoch: revisions[0], bindingEpoch: revisions[1]) else {
                throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED")
            }
            _ = try await handshake.inspectCompatibility(context: context)
            let queueCheck: @Sendable () throws -> Void
            if requiresIdleQueue {
                queueCheck = try await sender.transitionQueueAuthorization(localProjectID: row.id)
            } else { queueCheck = {} }
            let check: @Sendable () throws -> Void = {
                try ReceiveValidationPolicy.current.requireSending()
                try queueCheck()
                guard zip([authEpoch, bindingEpoch, projectEpoch, activity], revisions).allSatisfy({ $0.0.isAvailable && $0.0.value == $0.1 }),
                      !GlobalSyncPreference.isEnabled(), GlobalSyncPreference.contractEpoch.value == global,
                      !ContractPathGate.isOpen(for: row.id), ContractPathGate.revision(for: row.id) == gate
                else { throw SyncV2ContractError("TRANSITION_CONTEXT_CHANGED") }
            }
            try check()
            return .init(identity: .init(localID: row.id.rawValue, serverID: serverID, accountID: account.userID, deviceID: deviceID), check: check)
        })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(name) {
                    Text(model.message)
                    Text("먼저 대기 중인 동기화를 마치고, 이 작품의 편집과 다른 기기의 동기화도 중지하세요. 서버 형식만 바꾸며 본문·과거 버전은 보존합니다. 일반 동기화를 자동으로 켜지 않습니다.")
                        .font(.footnote)
                    Button("계획·진행 상태 조회 · 변경 없음") { Task { await model.inspect() } }
                    if let plan = model.plan, plan.mode != .idBased {
                        Button(model.hasPendingRequest ? "저장된 요청 재시도" : "전환 시작 및 구조 준비…") { confirmation = "prepare" }
                        if plan.mode == .migrating {
                            Button("전환 검증 · 완료하지 않음") { Task { await model.validate() } }
                            Button("전환 완료…") { confirmation = "complete" }.disabled(!model.validated)
                        }
                    }
                    if model.busy { ProgressView("서버 확인 중…") }
                }.disabled(model.busy)
            }
            .navigationTitle("동기화 형식 전환")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .confirmationDialog(confirmation == "complete" ? "검증한 전환을 완료할까요?" : "전환을 시작·재개할까요?",
                isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button(confirmation == "complete" ? "ID_BASED 전환 완료" : "시작 및 구조 준비") {
                    let action = confirmation; confirmation = nil
                    Task { if action == "complete" { await model.complete() } else { await model.prepare() } }
                }
                Button("취소", role: .cancel) { confirmation = nil }
            } message: { Text("구조 준비와 최종 완료는 별도 단계입니다. 실패하거나 응답이 끊기면 상태를 다시 조회하고 같은 요청을 재시도하세요.") }
        }
        .onDisappear { model.invalidate() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.invalidate(); confirmation = nil } }
    }
}
