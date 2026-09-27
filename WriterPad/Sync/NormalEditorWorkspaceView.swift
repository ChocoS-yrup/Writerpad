import SwiftUI
import UIKit

/// Normal writing surface, restricted to one existing document for this candidate.
/// It uses the same EditorSessionModel, native editor and idle/manual save path as the workspace.
struct NormalEditorWorkspaceView: View {
    @ObservedObject var session: NormalEditorSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var credentialFocus = NormalEditorCredentialFocus()
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(NormalEditorPlan.path).font(.headline)
                NormalEditorWritingPane(model: session.editor, enabled: session.opened && !session.busy)
                Text(session.message).font(.footnote).textSelection(.enabled)
                HStack {
                    NormalEditorCredentialField(text: $session.email, isSecure: false, focus: credentialFocus)
                    NormalEditorCredentialField(text: $session.password, isSecure: true, focus: credentialFocus,
                        onSubmit: { Task { await session.signIn() } })
                    Button("로그인") { Task { await session.signIn() } }.disabled(session.busy)
                }
                NormalEditorControls(session: session, editor: session.editor)
            }
            .padding()
            .navigationTitle("일반 집필 — Staging")
            .toolbar {
                Button("저장") { Task { await session.save() } }.keyboardShortcut("s", modifiers: .command)
                    .disabled(!session.opened || session.busy)
            }
        }
        .task { await session.open() }
        .onChange(of: scenePhase) { _, phase in Task { await session.setForeground(phase == .active) } }
        .onDisappear { Task { await session.setForeground(false) } }
    }
}

/// Keep credential traversal local to this form, never the manuscript's focus order.
@MainActor
final class NormalEditorCredentialFocus {
    private weak var email: UITextField?
    private weak var password: UITextField?

    func register(_ field: UITextField, secure: Bool) {
        if secure { password = field } else { email = field }
    }

    func unregister(_ field: UITextField) {
        if email === field { email = nil }
        if password === field { password = nil }
    }

    func move(from field: UITextField) {
        guard field.isFirstResponder, field.markedTextRange == nil else { return }
        let target = email === field ? password : (password === field ? email : nil)
        guard let target, let window = field.window, target.window === window,
              target.isEnabled, !target.isHidden, target.isUserInteractionEnabled else { return }
        target.becomeFirstResponder()
    }
}

final class NormalEditorCredentialTextField: UITextField {
    weak var credentialFocus: NormalEditorCredentialFocus?

    override var keyCommands: [UIKeyCommand]? {
        guard isFirstResponder, credentialFocus != nil else { return super.keyCommands }
        let commands = [UIKeyModifierFlags(), .shift].map { flags in
            let command = UIKeyCommand(input: "\t", modifierFlags: flags, action: #selector(moveCredentialFocus))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands + (super.keyCommands ?? []).filter {
            !($0.input == "\t" && ($0.modifierFlags.isEmpty || $0.modifierFlags == .shift))
        }
    }

    @objc func moveCredentialFocus(_ command: UIKeyCommand) {
        guard command.input == "\t", command.modifierFlags == [] || command.modifierFlags == .shift else { return }
        // Consume Tab even if the peer is unavailable; do not fall through into the manuscript.
        credentialFocus?.move(from: self)
    }
}

/// Diagnostic-screen-only workaround for the iPad input-assistant hosting crash.
/// Keep UIKit field identity/secure traits stable while SwiftUI publishes session changes.
/// No shared editor, authentication service, or system-wide appearance changes.
struct NormalEditorCredentialField: UIViewRepresentable {
    @Binding var text: String
    let isSecure: Bool
    var focus: NormalEditorCredentialFocus? = nil
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        makeTextField(coordinator: context.coordinator)
    }

    func makeTextField(coordinator: Coordinator) -> UITextField {
        let field = NormalEditorCredentialTextField(frame: .zero)
        field.credentialFocus = focus
        focus?.register(field, secure: isSecure)
        field.isSecureTextEntry = isSecure
        field.textContentType = isSecure ? .password : .username
        field.keyboardType = isSecure ? .default : .emailAddress
        field.returnKeyType = onSubmit != nil ? .go : (focus != nil && !isSecure ? .next : .done)
        field.placeholder = isSecure ? "비밀번호" : "이메일"
        field.accessibilityLabel = field.placeholder
        field.accessibilityIdentifier = isSecure ? "writerpad.normal.password" : "writerpad.normal.email"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        // Public UIKit API: suppress shortcut groups before first-responder transitions.
        // Do not install/reparent an accessory view or modify the shared manuscript editor.
        field.inputAssistantItem.leadingBarButtonGroups = []
        field.inputAssistantItem.trailingBarButtonGroups = []
        field.text = text
        field.delegate = coordinator
        field.addTarget(coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        updateTextField(field, coordinator: context.coordinator)
    }

    func updateTextField(_ field: UITextField, coordinator: Coordinator) {
        if let field = field as? NormalEditorCredentialTextField {
            if field.credentialFocus !== focus { field.credentialFocus?.unregister(field) }
            field.credentialFocus = focus
            focus?.register(field, secure: isSecure)
        }
        coordinator.parent = self
        // Avoid resetting selection/secure entry on unrelated session publications.
        if field.text != text { field.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: max(44, uiView.intrinsicContentSize.height))
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        if let field = field as? NormalEditorCredentialTextField {
            field.credentialFocus?.unregister(field)
            field.credentialFocus = nil
        }
        field.removeTarget(coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.delegate = nil
        field.text = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NormalEditorCredentialField
        init(parent: NormalEditorCredentialField) { self.parent = parent }

        @objc func textChanged(_ field: UITextField) { parent.text = field.text ?? "" }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            guard field.markedTextRange == nil else { return false }
            parent.text = field.text ?? ""
            if let submit = parent.onSubmit { submit() }
            else if let focus = parent.focus { focus.move(from: field) }
            else { field.resignFirstResponder() }
            return false
        }
    }
}

struct NormalEditorWritingPane: View {
    @ObservedObject var model: EditorSessionModel
    let enabled: Bool
    var onSaveShortcut: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading) {
            if let error = model.draftPersistenceError ?? model.errorMessage ?? model.boundaryDiagnosticError { Text(error).foregroundStyle(.red) }
            Text(model.hasUnsavedChanges ? "편집 중 · 유휴 자동저장 대기" : "로컬 저장됨").font(.caption)
            if let documentID = model.currentDocumentID {
                iPadTextEditor(text: Binding(get: { model.currentText }, set: { if enabled { model.updateText($0) } }),
                    documentID: documentID, externalVersion: model.externalVersion,
                    selection: Binding(get: { model.cursor }, set: { if enabled { model.updateCursor($0) } }),
                    focusRequest: model.focusRequest, isActive: enabled, isReadOnly: !enabled,
                    onTextChange: { id, text, mutation in
                        guard enabled, id == model.currentDocumentID else { return }
                        if let mutation { model.applyTextMutation(mutation, source: model.observedInputSource) } else if let text { model.updateText(text, source: model.observedInputSource) }
                    }, onEditorCommand: { if $0 == .save { onSaveShortcut?() } }, onCompositionStateChange: { id, composing in
                        guard id == model.currentDocumentID, let generation = model.recordCompositionState(composing) else { return }
                        Task { await model.finishCompositionStateUpdate(composing, generation: generation) }
                    }, onFocusChange: { model.updateFocusState($0) },
                    onInputSource: model.observesInputBoundaries ? { id, source in
                        if id == model.currentDocumentID { model.noteInputSource(source) }
                    } : nil)
            }
        }
    }
}

private struct NormalEditorControls: View {
    @ObservedObject var session: NormalEditorSession
    @ObservedObject var editor: EditorSessionModel
    @State private var confirmsTestRetirement = false
    var body: some View {
        let state = session.journal.state()
        let phase = state.head.map { state.saves[$0].phase }
        let locked = session.busy || !session.prepared
        VStack(alignment: .leading) {
            if NormalEditorDuplicateSaveResolution(state) != nil {
                Button("동일 본문 중복 대기 정리 · 기록 유지") { Task { await session.reconcileDuplicateSaves() } }
                    .disabled(session.busy || !session.opened || editor.hasUnsavedChanges || editor.isComposing || editor.draftPersistenceError != nil)
            }
            if NormalEditorTestQueueRetirement.canRetire(state) {
                Button("이전 테스트 송신 대기 2건 취소") { confirmsTestRetirement = true }
                    .disabled(locked || editor.hasUnsavedChanges || editor.isComposing || editor.draftPersistenceError != nil)
                    .confirmationDialog("확인된 이전 테스트 대기 2건만 취소합니다. 본문과 기록은 유지하며 서버로 전송하지 않습니다.", isPresented: $confirmsTestRetirement, titleVisibility: .visible) {
                        Button("이전 테스트 2건 취소", role: .destructive) { Task { await session.retireUnsentTestQueue() } }
                        Button("돌아가기", role: .cancel) {}
                    }
            }
            if NormalEditorStructureReference.canRefresh(state) {
                Button("구조 비교 기준 갱신 · 본문 유지") { Task { await session.refreshStructureReference() } }
                    .disabled(locked || editor.hasUnsavedChanges || editor.isComposing || editor.draftPersistenceError != nil)
            }
            HStack {
                Button("송수신 준비·권한 갱신") { Task { await session.prepare() } }.disabled(session.busy || !session.opened)
                Button("저장된 변경 송신 1회") { Task { await session.send() } }
                    .disabled(locked || !(phase == .queued || phase == .freezing || phase == .frozen) || !state.conflicts.isEmpty)
                Button("서버 변경 수신·반영 재개") { Task { await session.receive() } }
                    .disabled(locked || state.head != nil || editor.hasUnsavedChanges || editor.isComposing || !state.conflicts.isEmpty || state.error != nil)
                Button("미완료 송신 결과 확인") { Task { await session.recoverResult() } }
                    .disabled(locked || !(phase == .httpStarted || phase == .responseStored))
            }
            if state.recoveryRuns?.last?.isActive == true {
                Button("진단 준비 취소 · 본문과 기록 보존") { Task { await session.cancelPreparedRecoveryRun() } }
                    .disabled(session.busy || !session.opened || !NormalEditorRecoveryInjection.canCancelPreparedRun(state))
            }
        }
    }
}
