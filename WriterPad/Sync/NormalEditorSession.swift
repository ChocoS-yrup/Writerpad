import Foundation
import SwiftUI

/// All transport and original-store effects have explicit boundaries, allowing offline fault injection.
protocol NormalEditorBackend: Sendable {
    func localBaseline() async throws -> SyncV2RemoteDocumentSnapshot
    func localText() async throws -> String
    func prepare() async throws
    func invalidate() async
    func remote() async throws -> SyncV2RemoteDocumentSnapshot
    func freeze(_ source: LocalMutationBatch) async throws -> SyncV2ContractRequest
    func transmit(_ request: SyncV2ContractRequest, willStart: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON
    func receipt(_ request: SyncV2ContractRequest) async throws -> SyncV2JSON?
    func complete(_ request: SyncV2ContractRequest, response: SyncV2JSON) async throws
    func apply(_ receive: NormalEditorJournal.Receive, willApply: @escaping @Sendable () throws -> Void) async throws
}

/// One explicit action per tap. No timer, network callback or restart invokes another action.
@MainActor
final class NormalEditorSession: ObservableObject {
    @Published private(set) var message: String
    @Published private(set) var busy = false
    @Published private(set) var opened = false
    @Published private(set) var prepared = false
    @Published var email = ""
    @Published var password = ""
    let editor: EditorSessionModel
    let journal: NormalEditorJournal
    private let backend: any NormalEditorBackend
    private let documents: any DocumentRepository
    private let auth: (any AuthenticationServicing)?
    private var foreground = true
    private var epoch: UInt64 = 0
    init(editor: EditorSessionModel, journal: NormalEditorJournal, backend: any NormalEditorBackend,
         documents: any DocumentRepository, auth: (any AuthenticationServicing)? = nil) {
        self.editor = editor; self.journal = journal; self.backend = backend; self.documents = documents; self.auth = auth
        message = journal.state().message
    }
    func open() async {
        guard !opened, !busy else { return }
        await perform {
            _ = try NormalEditorRecoveryInjection.configuration()
            let base = try await self.backend.localBaseline()
            try NormalEditorPlan.validate(base)
            if self.journal.state().baseline == nil {
                guard base.revision == 6, base.content.utf8.count == 269,
                      NormalEditorPlan.hash(base.content) == NormalEditorPlan.initialHash,
                      Data(try await self.backend.localText().utf8) == Data(base.content.utf8) else { throw NormalEditorError.baseline }
                try self.journal.update("initialLocalBaseline") { $0.baseline = base }
            }
            guard let node = try await self.documents.document(id: .init(rawValue: NormalEditorPlan.document)) else { throw NormalEditorError.target }
            try NormalEditorPlan.validate(node)
            let draft = try self.journal.draft()
            await self.editor.requestSelection(.init(id: node.id, projectID: node.projectID, kind: .text,
                relativePath: node.relativePath, displayName: GeneralValidationPlan.name, fixedCategory: nil,
                userOrder: node.userOrder, contentState: .written, isExpanded: false))
            guard self.editor.currentDocumentID == node.id else { throw NormalEditorError.target }
            if self.journal.state().receive == nil, let draft, Data(draft.text.utf8) != Data(self.editor.currentText.utf8) {
                self.editor.updateText(draft.text); self.editor.updateCursor(draft.cursor)
            }
            self.opened = true
        }
    }
    func signIn() async {
        guard let auth, foreground, !busy else { return }
        prepared = false
        await backend.invalidate()
        await perform {
            let policy = ReceiveValidationPolicy.current
            let ticket = try policy.beginAuthentication(foreground: self.foreground, endpoint: ReceiveValidationPolicy.Configuration.staging)
            let result = await ReceiveValidationPolicy.$operation.withValue(ticket) {
                await auth.signIn(email: self.email.trimmingCharacters(in: .whitespacesAndNewlines), password: self.password)
            }
            self.password = ""
            guard self.foreground, case let .authenticated(account) = result else { throw NormalEditorError.locked }
            try policy.verifyAccount(account.userID, ticket: ticket)
            self.message = "로그인했습니다. 송수신 준비를 확인하세요."
        }
    }
    func prepare() async {
        guard opened, foreground, !busy else { return }
        await perform {
            self.prepared = false
            let version = self.epoch
            try await self.validateRecoveryRun()
            guard self.foreground, self.epoch == version else { throw NormalEditorError.locked }
            try await self.backend.prepare()
            guard self.foreground, self.epoch == version else { throw NormalEditorError.locked }
            self.prepared = true
            self.message = "송수신 준비 완료. 실행할 동작을 직접 선택하세요."
        }
    }
    func save() async {
        guard opened else { return }
        // Saving is deliberately independent of network busy/authentication.
        _ = await editor.saveNow()
    }
    func send() async {
        guard opened, prepared, !busy else { return }
        await perform {
            try await self.validateRecoveryRun()
            guard self.foreground, self.prepared else { throw NormalEditorError.locked }
            try NormalEditorRecoveryInjection.checkAction(self.journal, receiving: false)
            let state = self.journal.state()
            guard state.receive == nil, state.conflicts.isEmpty else { throw NormalEditorError.conflict }
            guard self.editor.draftPersistenceError == nil else { throw NormalEditorError.storage }
            guard let index = state.head else { throw NormalEditorError.noChange }
            let item = state.saves[index]
            guard item.phase == .queued || item.phase == .freezing || item.phase == .frozen else { throw NormalEditorError.unknown }
            guard !(try NormalEditorPlan.content(item.source)).isEmpty else { throw NormalEditorError.empty }
            let remote = try await self.backend.remote()
            guard let base = state.baseline else { throw NormalEditorError.baseline }
            guard remote.revision == base.revision, Data(remote.content.utf8) == Data(base.content.utf8) else {
                try await self.preserveConflict(remote); throw NormalEditorError.conflict
            }
            try self.journal.update("freezeStarted") {
                guard $0.head == index, [.queued, .freezing, .frozen].contains($0.saves[index].phase) else { throw NormalEditorError.busy }
                if $0.saves[index].phase != .frozen { $0.saves[index].phase = .freezing }
            }
            let request = try await self.backend.freeze(item.source)
            try NormalEditorPlan.validate(request, source: item.source)
            let hash = try request.json.sha256Hex()
            if let old = item.requestHash { guard old == hash else { throw NormalEditorError.request } }
            try self.journal.update("requestFrozen") {
                guard $0.saves[index].source.batchID == item.source.batchID else { throw NormalEditorError.request }
                $0.saves[index].request = request.json; $0.saves[index].requestHash = hash; $0.saves[index].phase = .frozen
            }
            let journal = self.journal
            let response = try await self.backend.transmit(request) {
                try journal.update("httpStarted") {
                    guard $0.saves[index].phase == .frozen, $0.saves[index].requestHash == hash else { throw NormalEditorError.unknown }
                    $0.saves[index].phase = .httpStarted; $0.saves[index].attempts.append(UUID())
                }
            }
            try self.storeResponse(index, request: request, response: response)
            try await self.finish(index, request: request, response: response)
        }
    }
    func recoverResult() async {
        guard opened, prepared, !busy else { return }
        await perform {
            try await self.validateRecoveryRun()
            guard self.foreground, self.prepared else { throw NormalEditorError.locked }
            try NormalEditorRecoveryInjection.checkAction(self.journal, receiving: false)
            let state = self.journal.state()
            guard let index = state.head, let json = state.saves[index].request else { throw NormalEditorError.noChange }
            let item = state.saves[index], request = try SyncV2ContractRequest(storedJSON: json)
            guard item.phase == .httpStarted || item.phase == .responseStored else { throw NormalEditorError.unknown }
            let response: SyncV2JSON
            if let stored = item.response { response = stored }
            else {
                guard let result = try await self.backend.receipt(request) else { throw NormalEditorError.unknown }
                response = result
                try self.storeResponse(index, request: request, response: result)
            }
            try await self.finish(index, request: request, response: response)
        }
    }
    private func storeResponse(_ index: Int, request: SyncV2ContractRequest, response: SyncV2JSON) throws {
        _ = try SyncV2Contract.validateDocumentCommitResponse(request: request, response: response)
        guard let revision = response.objectValue?["results"]?.arrayValue?.first?.objectValue?["result_revision"]?.intValue,
              revision == (request.orderedIntents[0].objectValue?["base_revision"]?.intValue ?? -1) + 1 else { throw NormalEditorError.request }
        try journal.update("responseStored") { $0.saves[index].response = response; $0.saves[index].phase = .responseStored }
    }
    private func finish(_ index: Int, request: SyncV2ContractRequest, response: SyncV2JSON) async throws {
        try NormalEditorRecoveryInjection.hit(.afterStoredResponse, journal: journal)
        try await backend.complete(request, response: response)
        let base = try await backend.localBaseline(), content = try NormalEditorPlan.content(journal.state().saves[index].source)
        guard Data(base.content.utf8) == Data(content.utf8) else { throw NormalEditorError.baseline }
        let result = "송신 완료. revision \(base.revision) · \(content.utf8.count)바이트 · SHA-256 \(NormalEditorPlan.hash(content))"
        try journal.update("sendCompleted") {
            $0.saves[index].phase = .completed; $0.baseline = base; $0.message = result
            NormalEditorRecoveryInjection.completeRun(&$0)
        }
        message = result
    }
    func receive() async {
        guard opened, prepared, !busy else { return }
        await perform {
            try await self.validateRecoveryRun()
            guard self.foreground, self.prepared else { throw NormalEditorError.locked }
            try NormalEditorRecoveryInjection.checkAction(self.journal, receiving: true)
            try self.requireCleanReceive()
            let state = self.journal.state()
            guard let base = state.baseline else { throw NormalEditorError.baseline }
            if state.receive == nil {
                let remote = try await self.backend.remote()
                try NormalEditorPlan.validate(remote)
                if let configuration = try NormalEditorRecoveryInjection.effectiveConfiguration(self.journal) {
                    try NormalEditorRecoveryInjection.validateIncoming(remote, configuration: configuration)
                }
                try self.requireCleanReceive()
                guard remote.revision >= base.revision else { throw NormalEditorError.baseline }
                let current = try await self.backend.localText()
                guard Data(current.utf8) == Data(base.content.utf8) else {
                    try await self.preserveConflict(remote); throw NormalEditorError.conflict
                }
                if remote.revision == base.revision {
                    guard Data(remote.content.utf8) == Data(base.content.utf8) else { throw NormalEditorError.baseline }
                    self.message = "수신 확인 완료. revision \(base.revision) · 변경 없음."; return
                }
                try self.journal.update("receiveResponseStored") { $0.receive = .init(id: UUID(), baseline: base, remote: remote) }
            }
            guard let receive = self.journal.state().receive else { throw NormalEditorError.partial }
            let journal = self.journal
            try await self.backend.apply(receive) {
                try journal.update("originalApplyStarted") { $0.receive?.phase = "originalApplyStarted" }
            }
            let latest = try await self.backend.localBaseline(), text = try await self.backend.localText()
            guard latest.revision == receive.remote.revision,
                  Data(text.utf8) == Data(receive.remote.content.utf8) else { throw NormalEditorError.partial }
            let result = "수신 완료. revision \(latest.revision) · \(text.utf8.count)바이트 · SHA-256 \(NormalEditorPlan.hash(text))"
            // Old draft must not be restored over an accepted receive after a crash.
            try self.journal.saveDraft(text: text, cursor: .start)
            try self.journal.update("receiveCompleted") {
                $0.baseline = latest; $0.receive = nil; $0.message = result
                NormalEditorRecoveryInjection.completeRun(&$0)
            }
            await self.editor.restore(documentID: .init(rawValue: NormalEditorPlan.document), cursor: .start)
            self.message = result
        }
    }
    private func requireCleanReceive() throws {
        let state = journal.state()
        guard !editor.hasUnsavedChanges, !editor.isComposing, editor.draftPersistenceError == nil,
              state.head == nil, state.conflicts.isEmpty, state.error == nil else { throw NormalEditorError.dirty }
    }
    private func validateRecoveryRun() async throws {
        guard try NormalEditorRecoveryInjection.effectiveConfiguration(journal)?.run != nil else { return }
        let baseline = try await backend.localBaseline(), text = try await backend.localText()
        try NormalEditorRecoveryInjection.preflight(journal: journal, baseline: baseline, localText: text,
            dirty: editor.hasUnsavedChanges, composing: editor.isComposing, draftFailed: editor.draftPersistenceError != nil)
    }
    private func preserveConflict(_ remote: SyncV2RemoteDocumentSnapshot) async throws {
        guard let base = journal.state().baseline else { throw NormalEditorError.baseline }
        let text = editor.currentText
        try journal.update("conflictPreserved") { $0.conflicts.append(.init(baseline: base.content, local: text, remote: remote)) }
    }
    func setForeground(_ active: Bool) async {
        foreground = active
        if !active { epoch &+= 1; prepared = false; await backend.invalidate() }
        // Verified completion messages outlive authentication and foreground authority.
    }
    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await operation() }
        catch {
            let code = (error as? NormalEditorError)?.rawValue ?? (error as? SyncV2ContractError)?.code
                ?? "\((error as NSError).domain):\((error as NSError).code)"
            message = "중단: \(code). 기록과 본문을 보존했습니다."
            let originalHash = journal.state().receive == nil ? nil : (try? await backend.localText()).map(NormalEditorPlan.hash)
            try? journal.update("actionStopped") { state in
                if state.receive != nil { state.receive?.observedOriginalHash = originalHash ?? "unreadable" }
                state.lastFailure = code
                if let index = state.head { state.saves[index].error = code }
            }
            if ["REVISION_CONFLICT", "STRUCTURE_REVISION_CONFLICT"].contains(code), let remote = try? await backend.remote() {
                try? await preserveConflict(remote)
            }
            prepared = false
            await backend.invalidate()
        }
    }
}
