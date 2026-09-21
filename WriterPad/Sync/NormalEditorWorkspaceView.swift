import SwiftUI

/// Normal writing surface, restricted to one existing document for this candidate.
/// It uses the same EditorSessionModel, native editor and idle/manual save path as the workspace.
struct NormalEditorWorkspaceView: View {
    @ObservedObject var session: NormalEditorSession
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(NormalEditorPlan.path).font(.headline)
                NormalEditorWritingPane(model: session.editor, enabled: session.opened && !session.busy)
                Text(session.message).font(.footnote).textSelection(.enabled)
                HStack {
                    TextField("이메일", text: $session.email).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("비밀번호", text: $session.password).textContentType(.password).submitLabel(.go)
                        .onSubmit { Task { await session.signIn() } }
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
    var body: some View {
        let state = session.journal.state()
        let phase = state.head.map { state.saves[$0].phase }
        let locked = session.busy || !session.prepared
        HStack {
            Button("송수신 준비·권한 갱신") { Task { await session.prepare() } }.disabled(session.busy || !session.opened)
            Button("저장된 변경 송신 1회") { Task { await session.send() } }
                .disabled(locked || !(phase == .queued || phase == .freezing || phase == .frozen) || !state.conflicts.isEmpty)
            Button("서버 변경 수신·반영 재개") { Task { await session.receive() } }
                .disabled(locked || state.head != nil || editor.hasUnsavedChanges || editor.isComposing || !state.conflicts.isEmpty || state.error != nil)
            Button("미완료 송신 결과 확인") { Task { await session.recoverResult() } }
                .disabled(locked || !(phase == .httpStarted || phase == .responseStored))
        }
    }
}
