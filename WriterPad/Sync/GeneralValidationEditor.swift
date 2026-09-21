import Foundation
import SwiftUI

/// The visible production editor owns the text. A submission freezes that draft;
/// prediction receives the same draft, never a replacement synthesized by Save.
@MainActor
final class GeneralValidationEditor: ObservableObject {
    struct Draft: Equatable, Sendable {
        let text: String
        let cursor: TextCursorState
    }
    let model: EditorSessionModel
    private let store: GeneralValidationEditorStore
    init(documents: any DocumentRepository, local: any LocalDocumentStoring) {
        store = GeneralValidationEditorStore(local: local)
        model = EditorSessionModel(documentRepository: documents, documentStore: store,
            workspaceStateRepository: GeneralValidationEditorWorkspace(), manualSaveOnly: true,
            saveGenerationProvider: {
                guard let values = GeneralValidationRuntimeValues.current else { throw Failure.notAuthorized }
                return values.editorGeneration
            })
    }
    enum Failure: String, Error { case wrongDocument, wrongDraft, composing, notAuthorized, duplicateSave, saveIncomplete }
    func open(_ node: DocumentNode) async throws {
        await model.requestSelection(.init(id: node.id, projectID: node.projectID, kind: .text,
            relativePath: node.relativePath, displayName: GeneralValidationPlan.name, fixedCategory: nil,
            userOrder: node.userOrder, contentState: .written, isExpanded: false))
        guard model.currentDocumentID?.rawValue == GeneralValidationPlan.document,
              Data(model.currentText.utf8) == Data(GeneralValidationPlan.incoming.utf8) else { throw Failure.wrongDocument }
    }
    func draft() throws -> Draft {
        guard model.currentDocumentID?.rawValue == GeneralValidationPlan.document else { throw Failure.wrongDocument }
        guard !model.isComposing else { throw Failure.composing }
        guard model.hasUnsavedChanges, Data(model.currentText.utf8) == Data(GeneralValidationPlan.outgoing.utf8) else { throw Failure.wrongDraft }
        return Draft(text: model.currentText, cursor: model.cursor)
    }
    func usePrediction(_ draft: Draft) {
        model.updateText(draft.text)
        model.updateCursor(draft.cursor)
    }
    func save(_ draft: Draft, authorize: @escaping @Sendable () throws -> Void) async throws -> DocumentSaveReceipt {
        guard try self.draft() == draft, let values = GeneralValidationRuntimeValues.current else { throw Failure.wrongDraft }
        try await store.arm(draft: draft, generation: values.editorGeneration, authorize: authorize)
        let saved = await model.saveNow()
        let receipt = try await store.finish()
        guard saved, !model.hasUnsavedChanges, model.currentText == draft.text else { throw Failure.saveIncomplete }
        return receipt
    }
}

/// Adds a comparison precondition to the ordinary save API. It preserves the
/// editor's bytes, cursor and generation, and never retries a pending handoff.
private actor GeneralValidationEditorStore: LocalDocumentStoring {
    let local: any LocalDocumentStoring
    private var draft: GeneralValidationEditor.Draft?
    private var generation: UInt64?
    private var authorize: (@Sendable () throws -> Void)?
    private var started = false
    private var result: Result<DocumentSaveReceipt, Error>?
    init(local: any LocalDocumentStoring) { self.local = local }
    func loadText(for document: DocumentNode) async throws -> String {
        guard document.id.rawValue == GeneralValidationPlan.document,
              document.projectID == GeneralValidationPlan.local,
              document.relativePath.rawValue == "메인/원고/" + GeneralValidationPlan.name else { throw GeneralValidationEditor.Failure.wrongDocument }
        return try await local.loadText(for: document)
    }
    func arm(draft: GeneralValidationEditor.Draft, generation: UInt64,
             authorize: @escaping @Sendable () throws -> Void) throws {
        guard !started, self.draft == nil else { throw GeneralValidationEditor.Failure.duplicateSave }
        try authorize()
        self.draft = draft; self.generation = generation; self.authorize = authorize
    }
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        guard !started, let draft, let authorize else { throw GeneralValidationEditor.Failure.notAuthorized }
        started = true
        do {
            try authorize()
            guard request.projectID == GeneralValidationPlan.local,
                  request.documentID.rawValue == GeneralValidationPlan.document,
                  request.relativePath.rawValue == "메인/원고/" + GeneralValidationPlan.name,
                  Data(request.text.utf8) == Data(draft.text.utf8), request.cursor == draft.cursor,
                  request.generation == generation else { throw GeneralValidationEditor.Failure.wrongDraft }
            // save() uses the same ordinary LocalDocumentStore pipeline. Its
            // optional comparison guard is enforced inside the document gate.
            let guarded = DocumentSaveRequest(projectID: request.projectID, documentID: request.documentID,
                relativePath: request.relativePath, text: request.text, generation: request.generation,
                cursor: request.cursor,
                expectedCurrentContentHash: SHA256ContentHasher().sha256(for: Data(GeneralValidationPlan.incoming.utf8)))
            let receipt = try await local.save(guarded)
            try authorize()
            result = .success(receipt)
            return receipt
        } catch { result = .failure(error); throw error }
    }
    func finish() throws -> DocumentSaveReceipt {
        authorize = nil
        guard let result else { throw GeneralValidationEditor.Failure.saveIncomplete }
        return try result.get()
    }
}

/// Selection/cursor state belongs to this temporary screen, so opening it does
/// not change persisted workspace restoration or unrelated project metadata.
private actor GeneralValidationEditorWorkspace: WorkspaceStateRepository {
    func lastProjectID() -> ProjectID? { nil }
    func setLastProjectID(_ projectID: ProjectID?) {}
    func editorState(for projectID: ProjectID) -> EditorWorkspaceState {
        .init(projectID: projectID, left: .init(documentID: nil, cursor: .start), right: nil, activePane: .left)
    }
    func saveEditorState(_ state: EditorWorkspaceState) {}
    func binderWidth(for projectID: ProjectID) -> Double { 280 }
    func setBinderWidth(_ width: Double, for projectID: ProjectID) {}
    func expandedFolderIDs(in projectID: ProjectID) -> Set<DocumentID> { [] }
    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) {}
    func cursor(for documentID: DocumentID) -> TextCursorState { .start }
    func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) {}
}

struct GeneralValidationEditorView: View {
    @ObservedObject var model: EditorSessionModel
    let enabled: Bool
    var body: some View {
        if let documentID = model.currentDocumentID {
            iPadTextEditor(text: Binding(get: { model.currentText }, set: { if enabled { model.updateText($0) } }),
                documentID: documentID, externalVersion: model.externalVersion,
                selection: Binding(get: { model.cursor }, set: { if enabled { model.updateCursor($0) } }),
                focusRequest: 0, isActive: enabled, isReadOnly: !enabled,
                onTextChange: { id, text, mutation in
                    guard enabled, id == model.currentDocumentID else { return }
                    if let mutation { model.applyTextMutation(mutation) }
                    else if let text { model.updateText(text) }
                }, onCompositionStateChange: { id, value in
                    guard id == model.currentDocumentID,
                          let generation = model.recordCompositionState(value) else { return }
                    Task { await model.finishCompositionStateUpdate(value, generation: generation) }
                }, onFocusChange: { model.updateFocusState($0) })
                .frame(minHeight: 260)
        }
    }
}
