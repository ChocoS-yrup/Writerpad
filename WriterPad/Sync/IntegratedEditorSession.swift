import Foundation
import SwiftUI
import Network

actor IntegratedEditorDocumentStore: LocalDocumentStoring {
    let local: any LocalDocumentStoring
    let journal: IntegratedEditorJournal
    init(local: any LocalDocumentStoring, journal: IntegratedEditorJournal) { self.local = local; self.journal = journal }
    func loadText(for document: DocumentNode) async throws -> String {
        guard document.projectID == IntegratedEditorPlan.local, journal.state().members.contains(document.id.rawValue),
              document.kind == .text, document.deletionStatus == .active,
              IntegratedEditorPlan.contains(document.relativePath.rawValue) else { throw IntegratedEditorError.scope }
        return try await local.loadText(for: document)
    }
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        guard !journal.diagnosticRestricted else { throw IntegratedEditorError.diagnostic }
        guard request.projectID == IntegratedEditorPlan.local, journal.state().members.contains(request.documentID.rawValue),
              request.documentID.rawValue != IntegratedEditorPlan.protectedDocument,
              IntegratedEditorPlan.contains(request.relativePath.rawValue), request.durableBatchKind == .documentSave,
              journal.state().receive == nil, !request.text.contains("\r") else { throw IntegratedEditorError.scope }
        let receipt = try await local.save(request)
        guard case .queued = receipt.durableRecordResult else { throw IntegratedEditorError.queue }
        return receipt
    }
}

@MainActor
final class IntegratedEditorSession: ObservableObject {
    @Published private(set) var rows: [DocumentNode] = []
    @Published private(set) var editor: EditorSessionModel?
    @Published private(set) var selectedID: DocumentID?
    @Published private(set) var message: String
    @Published private(set) var busy = false
    @Published private(set) var opened = false
    @Published private(set) var prepared = false
    @Published var email = ""
    @Published var password = ""
    let journal: IntegratedEditorJournal
    private let backend: IntegratedEditorBackend
    private let documents: any DocumentRepository
    private let local: any LocalDocumentStoring
    private let workspace: any WorkspaceStateRepository
    private let commands: any BinderCommanding
    private var editors: [DocumentID: EditorSessionModel] = [:]
    private var foreground = true
    private var connected = false
    private var lifecycle: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var scheduled: Task<Void, Never>?
    private var scheduleID: UUID?
    private let network = NWPathMonitor()
    private var networkStarted = false
    init(journal: IntegratedEditorJournal, backend: IntegratedEditorBackend, documents: any DocumentRepository,
         local: any LocalDocumentStoring, workspace: any WorkspaceStateRepository, commands: any BinderCommanding,
         wakeup: IntegratedEditorWakeup) {
        self.journal = journal; self.backend = backend; self.documents = documents
        self.local = local; self.workspace = workspace; self.commands = commands; message = journal.state().message
        wakeup.install { [weak self] in Task { @MainActor in self?.schedule() } }
    }
    var selected: DocumentNode? { rows.first { $0.id == selectedID } }
    var folders: [DocumentNode] { rows.filter { $0.kind == .folder && $0.deletionStatus == .active } }
    var root: DocumentNode? { folders.first { $0.relativePath.rawValue == IntegratedEditorPlan.rootPath } }
    var automatic: Bool { journal.state().automatic && journal.automaticBlockReason() == nil }
    func open() async {
        guard !opened else { return }
        await perform {
            if let raw = ProcessInfo.processInfo.environment["WRITERPAD_INTEGRATED_EXECUTION"] {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let execution = try decoder.decode(IntegratedExecution.self, from: Data(raw.utf8))
                if let amendment = ProcessInfo.processInfo.environment["WRITERPAD_INTEGRATED_AMENDMENT"] {
                    try self.journal.amend(execution, approval: decoder.decode(IntegratedExecutionAmendment.self, from: Data(amendment.utf8)))
                } else { try self.journal.configure(execution) }
            }
            if let raw = ProcessInfo.processInfo.environment["WRITERPAD_INTEGRATED_RECEIPT_RECOVERY"] {
                guard ProcessInfo.processInfo.environment["WRITERPAD_INTEGRATED_DIAGNOSTIC_RESUME"] == nil else { throw IntegratedEditorError.configuration }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                try self.journal.authorizeReceiptRecovery(decoder.decode(IntegratedReceiptRecoveryApproval.self, from: Data(raw.utf8)))
            }
            if let raw = ProcessInfo.processInfo.environment["WRITERPAD_INTEGRATED_DIAGNOSTIC_RESUME"] {
                let fields = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
                guard Set(fields.keys) == ["journalSHA256", "approvalSHA256"] else { throw IntegratedEditorError.configuration }
                try self.journal.releaseDiagnostic(journalSHA256: fields["journalSHA256"]!, approvalSHA256: fields["approvalSHA256"]!)
            }
            if !self.journal.diagnosticRestricted { try await self.commands.recoverPendingTransactions(in: IntegratedEditorPlan.local) }
            try await self.refresh()
            if self.journal.state().receive == nil && !self.journal.diagnosticRestricted {
                for node in self.rows where node.kind == .text && node.deletionStatus == .active && self.journal.state().drafts[node.id.rawValue] != nil {
                    try await self.selectNode(node)
                }
            }
            self.opened = true
        }
        #if !WRITERPAD_ISOLATED_TESTS
        if !networkStarted {
            networkStarted = true
            network.pathUpdateHandler = { [weak self] path in
                Task { @MainActor in self?.setConnected(path.status == .satisfied) }
            }
            network.start(queue: DispatchQueue(label: "WriterPad.IntegratedConnectivity"))
        }
        #endif
        startTimer(); schedule()
    }
    private func refresh() async throws {
        let members = journal.state().members
        rows = try await documents.documents(in: IntegratedEditorPlan.local).filter {
            members.contains($0.id.rawValue) || IntegratedEditorPlan.contains($0.relativePath.rawValue)
        }.sorted { a, b in
            if a.parentID == b.parentID { return a.userOrder == b.userOrder ? a.relativePath.rawValue < b.relativePath.rawValue : a.userOrder < b.userOrder }
            return a.relativePath.rawValue < b.relativePath.rawValue
        }
        let found = Set(rows.map { $0.id.rawValue })
        guard !found.contains(IntegratedEditorPlan.protectedDocument), !found.contains(IntegratedEditorPlan.parent) else { throw IntegratedEditorError.scope }
        if !found.isSubset(of: members) {
            guard !journal.diagnosticRestricted else { throw IntegratedEditorError.scope }
            try journal.update("localMembers") { $0.members.formUnion(found) }
        }
    }
    private func binder(_ node: DocumentNode) -> BinderNode {
        .init(id: node.id, projectID: node.projectID, kind: node.kind, relativePath: node.relativePath,
              displayName: URL(fileURLWithPath: node.relativePath.rawValue).deletingPathExtension().lastPathComponent,
              fixedCategory: nil, userOrder: node.userOrder, contentState: .written, isExpanded: false)
    }
    func select(_ id: DocumentID) async {
        guard !busy, journal.state().receive == nil, let node = rows.first(where: { $0.id == id }) else { return }
        await perform {
            if self.selectedID != id, let current = self.editor {
                current.recordSaveBoundaryAttempt(.documentTransition, stage: current.hasUnsavedChanges ? "draftRetained" : "unchanged")
            }
            try await self.selectNode(node)
        }
    }
    private func selectNode(_ node: DocumentNode) async throws {
        guard !journal.diagnosticRestricted else { throw IntegratedEditorError.diagnostic }
        selectedID = node.id
        guard node.kind == .text, node.deletionStatus == .active else { editor = nil; return }
        if let existing = editors[node.id] { editor = existing; return }
        let journal = journal
        var restoring = true
        let model = EditorSessionModel(documentRepository: documents, documentStore: local,
            workspaceStateRepository: workspace, observeBoundary: { try journal.recordSaveDiagnostic($0) }, preserveDraft: { id, text, cursor in
                guard !restoring else { return }
                try journal.draft(id: id.rawValue, text: text, cursor: cursor)
            })
        let draft = journal.state().drafts[node.id.rawValue]
        await model.requestSelection(binder(node))
        guard model.currentDocumentID == node.id else { throw IntegratedEditorError.scope }
        restoring = false
        model.noteInputSource(draft?.inputSource ?? .localLoad)
        if let draft {
            if Data(draft.text.utf8) != Data(model.currentText.utf8) { model.updateText(draft.text, source: .draftRestore) }
            model.updateCursor(draft.cursor)
        }
        editors[node.id] = model; editor = model
    }
    private func saveAll(boundary: EditorSaveBoundary = .synchronization) async throws {
        let blocked = editors.values.filter { $0.isComposing || $0.draftPersistenceError != nil }
        guard blocked.isEmpty else {
            for model in blocked { model.recordSaveBoundaryAttempt(boundary, stage: model.isComposing ? "blockedComposition" : "blockedDraft") }
            throw IntegratedEditorError.dirty
        }
        let cleanEditor = editor.flatMap { $0.hasUnsavedChanges ? nil : $0 }
        for model in editors.values where model.hasUnsavedChanges {
            guard await model.saveNow(boundary: boundary), !model.hasUnsavedChanges else { throw IntegratedEditorError.dirty }
        }
        if let editor = cleanEditor {
            // A clean save button used to do no I/O; diagnostics must not add a queue retry.
            editor.recordSaveBoundaryAttempt(boundary, stage: "unchanged")
        }
    }
    func save(boundary: EditorSaveBoundary = .saveButton) async { guard !busy else { return }; await perform { try await self.saveAll(boundary: boundary); self.message = "로컬 저장 완료" }; schedule() }
    private func closeEditors() async throws {
        try await saveAll()
        for model in editors.values { await model.updateSceneActivity(false) }
        editors.removeAll(); editor = nil
        // Clear only this candidate's view references before the normal binder rule evaluates open documents.
        try await workspace.saveEditorState(.init(projectID: IntegratedEditorPlan.local,
            left: .init(documentID: nil, cursor: .start), right: nil, activePane: .left))
    }
    func createRoot() async {
        guard root == nil else { return }
        await command {
            _ = try await self.commands.create(kind: .folder, named: IntegratedEditorPlan.rootName,
                in: .init(rawValue: IntegratedEditorPlan.parent), projectID: IntegratedEditorPlan.local)
        }
    }
    func create(kind: DocumentKind, name: String, parent: DocumentID) async {
        guard folders.contains(where: { $0.id == parent }) else { return }
        await command { _ = try await self.commands.create(kind: kind, named: name, in: parent, projectID: IntegratedEditorPlan.local) }
    }
    func rename(_ name: String) async {
        guard let node = selected, node.id != root?.id else { return }
        await command { _ = try await self.commands.rename(documentID: node.id, to: name, projectID: IntegratedEditorPlan.local) }
    }
    func move(to parent: DocumentID) async {
        guard let node = selected, node.id != root?.id, folders.contains(where: { $0.id == parent }) else { return }
        await command { _ = try await self.commands.move(documentID: node.id, to: .folder(parent), projectID: IntegratedEditorPlan.local) }
    }
    func reorder(delta: Int) async {
        guard let node = selected, let parent = node.parentID, folders.contains(where: { $0.id == parent }) else { return }
        var siblings = rows.filter { $0.parentID == parent && $0.deletionStatus == .active }.sorted { $0.userOrder < $1.userOrder }.map(\.id)
        guard let from = siblings.firstIndex(of: node.id), siblings.indices.contains(from + delta) else { return }
        siblings.swapAt(from, from + delta)
        let ordered = siblings
        await command { try await self.commands.reorder(childIDs: ordered, in: parent, projectID: IntegratedEditorPlan.local) }
    }
    func trash() async {
        guard let node = selected, node.id != root?.id, node.deletionStatus == .active else { return }
        await command { _ = try await self.commands.moveToTrash(documentID: node.id, projectID: IntegratedEditorPlan.local) }
    }
    func restore(to parent: DocumentID) async {
        guard let node = selected, node.deletionStatus != .active, folders.contains(where: { $0.id == parent }) else { return }
        await command { _ = try await self.commands.restoreFromTrash(documentID: node.id, toFolderID: parent, projectID: IntegratedEditorPlan.local) }
    }
    private func command(_ operation: () async throws -> Void) async {
        guard opened, !busy, journal.state().receive == nil else { return }
        await perform {
            guard !self.journal.diagnosticRestricted else { throw IntegratedEditorError.diagnostic }
            try await self.closeEditors(); try await operation(); try await self.refresh()
            if let node = self.selected { try await self.selectNode(node) }
            self.message = "본문과 구조를 로컬에 저장했습니다."
        }
        schedule()
    }
    func signIn() async {
        guard !busy, foreground else { return }
        await perform { defer { self.password = "" }; try await self.backend.signIn(email: self.email, password: self.password); self.message = "로그인 완료" }
    }
    func prepare() async {
        guard !busy, foreground else { return }
        await perform { try await self.backend.prepare(); self.prepared = true; self.message = "송수신 준비 완료" }
        schedule()
    }
    func synchronize(automatic requestedAutomatic: Bool = false) async {
        guard opened, foreground, !busy, !requestedAutomatic || (connected && automatic) else { return }
        scheduled?.cancel(); scheduled = nil; scheduleID = nil
        await perform {
            if self.journal.diagnosticRestricted {
                try await self.backend.diagnoseReceipt()
                return
            }
            try await self.closeEditors()
            // Every new cycle refreshes its short-lived capability and active-project check.
            try await self.backend.runCycle(automatic: requestedAutomatic); self.prepared = true
            try await self.refresh()
            if let node = self.selected, self.journal.state().receive == nil { try await self.selectNode(node) }
            self.message = self.journal.state().message
        }
        if !automatic { timer?.cancel(); timer = nil }
    }
    func toggleAutomatic() async {
        await perform {
            guard !self.journal.diagnosticRestricted else { throw IntegratedEditorError.diagnostic }
            try self.journal.checkTime()
            try self.journal.setAutomatic(!self.automatic)
        }
        startTimer(); schedule()
    }
    private func startTimer() {
        timer?.cancel(); timer = nil
        guard foreground, automatic, let run = journal.state().execution else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(run.pollingSeconds)) } catch { return }
                self?.schedule()
            }
        }
    }
    private func schedule() {
        guard opened, foreground, connected, automatic, !busy, scheduled == nil else { return }
        let id = UUID(); scheduleID = id
        scheduled = Task { [weak self] in
            defer { if self?.scheduleID == id { self?.scheduled = nil; self?.scheduleID = nil } }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.foreground, self.connected, self.automatic, !self.busy,
                  !self.editors.values.contains(where: { $0.hasUnsavedChanges || $0.isComposing || $0.draftPersistenceError != nil }) else { return }
            self.scheduled = nil; self.scheduleID = nil
            await self.synchronize(automatic: true)
        }
    }
    func setConnected(_ available: Bool) {
        connected = available
        if available { schedule() } else { scheduled?.cancel(); scheduled = nil; scheduleID = nil }
    }
    func setForeground(_ active: Bool) async {
        foreground = active
        if !active {
            lifecycle &+= 1
            timer?.cancel(); scheduled?.cancel(); prepared = false
            await backend.invalidate()
            for model in editors.values { await model.updateSceneActivity(false) }
        } else {
            for model in editors.values { await model.updateSceneActivity(true) }
            startTimer(); schedule()
        }
    }
    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true
        let version = lifecycle
        defer { busy = false; if version != lifecycle { schedule() } }
        do { try await action() }
        catch {
            if version != lifecycle {
                prepared = false
                message = "앱 복귀 후 저장된 중단 위치에서 이어갑니다."
                return
            }
            let code = (error as? IntegratedEditorError)?.rawValue ?? (error as? SyncV2ContractError)?.code ?? "LOCAL_OR_TRANSPORT_FAILURE"
            message = "중단: \(code). 초안과 요청 기록을 보존했습니다."
            try? journal.update("stopped") {
                $0.automatic = false; $0.message = message
                if let failure = error as? IntegratedEditorError, [.budget, .expired, .clock].contains(failure) { $0.stopped = true }
            }
            timer?.cancel(); prepared = false; await backend.invalidate()
        }
    }
}
