import Foundation
import SwiftUI

/// A local synthetic workspace, deliberately without an account, server binding or execution grant.
/// Its manifest is not a server snapshot and must never be used to seed a sync baseline.
enum AutoSaveIsolationError: String, Error, LocalizedError {
    case bundle = "ISOLATION_BUNDLE", manifest = "ISOLATION_MANIFEST"
    case path = "ISOLATION_PATH", corrupt = "ISOLATION_STATE_CORRUPT"
    case collision = "ISOLATION_EXISTING_DATA", incomplete = "ISOLATION_INCOMPLETE"
    case network = "ISOLATION_LOCAL_ONLY"
    var errorDescription: String? { rawValue }
}

struct AutoSaveIsolationManifest: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: DocumentID
        let name: String
        let seed: String
    }
    let version: Int
    let projectID: ProjectID
    let rootID: DocumentID
    let rootName: String
    let documents: [Entry]
    static let bundleID = "com.chocos.writerpad.autosavevalidation"
    static let directory = "AutoSaveIsolationV1"
    static let synthetic = Self(version: 1,
        projectID: .init(rawValue: UUID(uuidString: "9EC6330B-E7CE-451C-A1FB-79EA485F24C6")!),
        rootID: .init(rawValue: UUID(uuidString: "0F43B74F-3D01-4659-9090-4524E4DE6F65")!),
        rootName: "자동저장 격리 합성 시험",
        documents: [
            .init(id: .init(rawValue: UUID(uuidString: "B703F176-5A7A-4EE3-B9F6-6A7DC708164C")!), name: "입력 A.txt", seed: "합성 입력 A\n"),
            .init(id: .init(rawValue: UUID(uuidString: "396CE5F7-24AA-44F9-8781-BC69116E1CDD")!), name: "입력 B.txt", seed: "합성 입력 B\n")])

    func validate() throws {
        // Changing the target requires a reviewed new schema; never silently rebind an existing run.
        guard self == Self.synthetic else { throw AutoSaveIsolationError.manifest }
    }
    func path(_ entry: Entry) -> String { rootName + "/" + entry.name }
}

/// All mutations serialize, including a second instance reopening the same container in tests.
/// The journal is committed before TXT replacement. A restart only replays an exact before/after pair.
final class AutoSaveIsolationStore: @unchecked Sendable {
    struct Pending: Codable {
        let before: String
        let text: String
        let generation: UInt64
    }
    struct Record: Codable {
        var hash: String
        var pending: Pending?
    }
    struct Draft: Codable {
        let text: String
        let cursor: TextCursorState
    }
    struct State: Codable {
        let manifest: AutoSaveIsolationManifest
        var ready: Bool
        var records: [DocumentID: Record]
        var drafts: [DocumentID: Draft]
        var diagnostic: EditorBoundaryDiagnostic?
    }
    private static let lock = NSRecursiveLock()
    let root: URL
    let manifest: AutoSaveIsolationManifest
    private let base: URL
#if DEBUG
    var checkpoint: (@Sendable (String) throws -> Void)?
#endif
    private func check(_ stage: String) throws {
#if DEBUG
        try checkpoint?(stage)
#endif
    }
    init(bundleID: String?, applicationSupport: URL, manifest: AutoSaveIsolationManifest = .synthetic) throws {
        guard bundleID == AutoSaveIsolationManifest.bundleID else { throw AutoSaveIsolationError.bundle }
        try manifest.validate()
        guard applicationSupport.isFileURL else { throw AutoSaveIsolationError.path }
        self.base = applicationSupport.standardizedFileURL
        self.root = base.appendingPathComponent(AutoSaveIsolationManifest.directory, isDirectory: true)
        self.manifest = manifest
        // Validation precedes every directory creation, DB, preferences and SDK construction.
        try Self.noLinks(base)
    }
    private static func noLinks(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw AutoSaveIsolationError.path }
            current.deleteLastPathComponent()
        }
    }
    private func checked(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw AutoSaveIsolationError.path
        }
        let url = root.appendingPathComponent(relative)
        try Self.noLinks(url)
        guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw AutoSaveIsolationError.path }
        return url
    }
    private func atomic<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: checked("state.json"), options: .atomic)
    }
    private func read() throws -> State {
        let state: State
        do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: checked("state.json"))) }
        catch let error as AutoSaveIsolationError { throw error }
        catch { throw AutoSaveIsolationError.corrupt }
        guard state.manifest == manifest, Set(state.records.keys) == Set(manifest.documents.map(\.id)),
              Set(state.drafts.keys).isSubset(of: Set(state.records.keys)),
              state.records.values.allSatisfy({ ContentHash(rawValue: $0.hash) != nil && ($0.pending == nil || $0.pending?.before == $0.hash) }),
              state.diagnostic.map({ state.records[$0.documentID] != nil }) ?? true else {
            throw AutoSaveIsolationError.corrupt
        }
        return state
    }
    private func bytes(_ entry: AutoSaveIsolationManifest.Entry) throws -> Data {
        try Data(contentsOf: checked(manifest.path(entry)))
    }
    private func requireReady(_ state: State) throws {
        guard state.ready else { throw AutoSaveIsolationError.incomplete }
    }
    func bootstrap() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try Self.noLinks(root)
        let fm = FileManager.default
        let stateURL = try checked("state.json")
        if !fm.fileExists(atPath: stateURL.path) {
            if fm.fileExists(atPath: root.path), !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty {
                throw AutoSaveIsolationError.collision
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let state = State(manifest: manifest, ready: false,
                records: Dictionary(uniqueKeysWithValues: manifest.documents.map { ($0.id, Record(hash: IntegratedEditorPlan.hash($0.seed))) }),
                drafts: [:])
            try atomic(state)
            try check("manifestCommitted")
        }
        var state = try read()
        if !state.ready {
            guard state.drafts.isEmpty, state.records.values.allSatisfy({ $0.pending == nil }),
                  manifest.documents.allSatisfy({ state.records[$0.id]?.hash == IntegratedEditorPlan.hash($0.seed) }) else { throw AutoSaveIsolationError.corrupt }
            try fm.createDirectory(at: checked(manifest.rootName), withIntermediateDirectories: true)
            for entry in manifest.documents {
                let url = try checked(manifest.path(entry))
                if fm.fileExists(atPath: url.path) {
                    guard try bytes(entry) == Data(entry.seed.utf8) else { throw AutoSaveIsolationError.collision }
                } else { try Data(entry.seed.utf8).write(to: url, options: .atomic) }
                try check("seedWritten")
            }
            state.ready = true
            try atomic(state)
            try check("readyCommitted")
        }
        try recover(&state)
    }
    private func recover(_ state: inout State) throws {
        try requireReady(state)
        for entry in manifest.documents {
            guard var record = state.records[entry.id] else { throw AutoSaveIsolationError.corrupt }
            let current = IntegratedEditorPlan.hash(try bytes(entry))
            if let pending = record.pending {
                let after = IntegratedEditorPlan.hash(pending.text)
                guard current == pending.before || current == after else { throw AutoSaveIsolationError.collision }
                if current != after { try Data(pending.text.utf8).write(to: checked(manifest.path(entry)), options: .atomic) }
                try check("textReplaced")
                record.hash = after; record.pending = nil; state.records[entry.id] = record
                // A newer draft belongs to later input and must survive an older save completing.
                if state.drafts[entry.id].map({ Data($0.text.utf8) == Data(pending.text.utf8) }) == true { state.drafts[entry.id] = nil }
                try atomic(state)
            } else if current != record.hash { throw AutoSaveIsolationError.collision }
        }
    }
    func snapshot() throws -> State {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let state = try read(); try requireReady(state); return state
    }
    func load(_ document: DocumentNode) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let entry = try target(document.id, project: document.projectID, path: document.relativePath)
        guard document.kind == .text, document.deletionStatus == .active else { throw AutoSaveIsolationError.manifest }
        var state = try read(); try recover(&state)
        guard let text = String(data: try bytes(entry), encoding: .utf8) else { throw AutoSaveIsolationError.corrupt }
        return text
    }
    private func target(_ id: DocumentID, project: ProjectID, path: RelativeDocumentPath) throws -> AutoSaveIsolationManifest.Entry {
        guard project == manifest.projectID, let entry = manifest.documents.first(where: { $0.id == id }),
              path.rawValue == manifest.path(entry) else { throw AutoSaveIsolationError.manifest }
        return entry
    }
    func save(_ request: DocumentSaveRequest) throws -> DocumentSaveReceipt {
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try target(request.documentID, project: request.projectID, path: request.relativePath)
        guard request.durableBatchKind == .documentSave, request.expectedCurrentContentHash == nil else { throw AutoSaveIsolationError.manifest }
        var state = try read(); try recover(&state)
        let before = state.records[request.documentID]!.hash
        state.records[request.documentID]?.pending = Pending(before: before, text: request.text, generation: request.generation)
        try atomic(state)
        try check("saveCommitted")
        try recover(&state)
        return .init(projectID: request.projectID, documentID: request.documentID, relativePath: request.relativePath,
            contentHash: ContentHash(rawValue: IntegratedEditorPlan.hash(request.text))!, modifiedAt: Date(),
            generation: request.generation, cursor: request.cursor, durableRecordResult: .localOnly)
    }
    func draft(_ id: DocumentID, text: String, cursor: TextCursorState) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try read(); try requireReady(state)
        guard state.records[id] != nil else { throw AutoSaveIsolationError.manifest }
        state.drafts[id] = .init(text: text, cursor: cursor); try atomic(state)
    }
    func diagnostic(_ event: EditorBoundaryDiagnostic) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var state = try read(); try requireReady(state)
        guard state.records[event.documentID] != nil else { throw AutoSaveIsolationError.manifest }
        state.diagnostic = event; try atomic(state)
    }
}

private struct AutoSaveIsolationDocumentStore: LocalDocumentStoring {
    let store: AutoSaveIsolationStore
    func loadText(for document: DocumentNode) async throws -> String { try store.load(document) }
    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt { try store.save(request) }
}

@MainActor
final class AutoSaveIsolationSession: ObservableObject {
    @Published private(set) var editor: EditorSessionModel?
    @Published private(set) var selectedID: DocumentID?
    @Published private(set) var message = "로컬 합성 시험 준비 중"
    @Published private(set) var opened = false
    @Published private(set) var busy = false
    let manifest = AutoSaveIsolationManifest.synthetic
    private var store: AutoSaveIsolationStore?
    private var editors: [DocumentID: EditorSessionModel] = [:]
    private let location: () throws -> (String?, URL)
    init(location: @escaping () throws -> (String?, URL) = {
        (Bundle.main.bundleIdentifier, URL.applicationSupportDirectory.resolvingSymlinksInPath())
    }) { self.location = location }
    func open() async {
        guard !opened, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let (bundle, root) = try location()
            let store = try AutoSaveIsolationStore(bundleID: bundle, applicationSupport: root)
            try store.bootstrap()
            // Metadata is rebuilt only in memory; no legacy SwiftData/SQLite/Keychain or cloud services.
            let repository = SwiftDataMetadataRepository(modelContainer: try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true))
            try await repository.save(Project(id: manifest.projectID, name: manifest.rootName, createdAt: Date(), modifiedAt: Date()))
            try await repository.save(DocumentNode(id: manifest.rootID, projectID: manifest.projectID, kind: .folder,
                parentID: nil, relativePath: .init(rawValue: manifest.rootName), userOrder: 0, modifiedAt: Date(), contentHash: nil))
            for (index, entry) in manifest.documents.enumerated() {
                let node = DocumentNode(id: entry.id, projectID: manifest.projectID, kind: .text,
                    parentID: manifest.rootID, relativePath: .init(rawValue: manifest.path(entry)), userOrder: index,
                    modifiedAt: Date(), contentHash: .init(rawValue: try store.snapshot().records[entry.id]!.hash))
                try await repository.save(node)
                var restoring = true
                let model = EditorSessionModel(documentRepository: repository, documentStore: AutoSaveIsolationDocumentStore(store: store),
                    workspaceStateRepository: repository, observeBoundary: { try store.diagnostic($0) },
                    preserveDraft: { id, text, cursor in
                        if !restoring { try store.draft(id, text: text, cursor: cursor) }
                    })
                let draft = try store.snapshot().drafts[entry.id]
                await model.requestSelection(.init(id: node.id, projectID: node.projectID, kind: .text,
                    relativePath: node.relativePath, displayName: entry.name, fixedCategory: nil, userOrder: index,
                    contentState: .written, isExpanded: false))
                guard model.currentDocumentID == node.id else { throw AutoSaveIsolationError.incomplete }
                restoring = false
                if let draft {
                    model.updateText(draft.text, source: .draftRestore); model.updateCursor(draft.cursor)
                }
                editors[entry.id] = model
            }
            self.store = store; opened = true
            select(manifest.documents[0].id)
            message = "로컬 합성 시험 · 자동 수신 꺼짐 · 서버 연결 없음"
        } catch { message = (error as? AutoSaveIsolationError)?.rawValue ?? "ISOLATION_OPEN_FAILED" }
    }
    func select(_ id: DocumentID) {
        guard opened, let next = editors[id], id != selectedID else { return }
        editor?.recordSaveBoundaryAttempt(.documentTransition, stage: editor?.hasUnsavedChanges == true ? "draftRetained" : "unchanged")
        editor = next; selectedID = id
    }
    func save(boundary: EditorSaveBoundary = .saveButton) async {
        guard opened, !busy else { return }
        busy = true; defer { busy = false }
        guard !editors.values.contains(where: { $0.isComposing || $0.draftPersistenceError != nil }) else {
            editor?.recordSaveBoundaryAttempt(boundary, stage: "blockedDraftOrComposition")
            message = "ISOLATION_SAVE_DEFERRED"; return
        }
        let cleanEditor = editor.flatMap { $0.hasUnsavedChanges ? nil : $0 }
        for model in editors.values where model.hasUnsavedChanges {
            guard await model.saveNow(boundary: boundary), !model.hasUnsavedChanges else { message = "ISOLATION_SAVE_FAILED"; return }
        }
        cleanEditor?.recordSaveBoundaryAttempt(boundary, stage: "unchanged")
        message = "로컬 저장 완료 · 서버 연결 없음"
    }
    func foreground(_ active: Bool) async {
        for model in editors.values { await model.updateSceneActivity(active) }
    }
}

struct AutoSaveIsolationView: View {
    @ObservedObject var session: AutoSaveIsolationSession
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ForEach(session.manifest.documents, id: \.id) { entry in
                        Button(entry.name) { session.select(entry.id) }.disabled(!session.opened || session.busy)
                    }
                }
                if let editor = session.editor {
                    NormalEditorWritingPane(model: editor, enabled: session.opened && !session.busy,
                        onSaveShortcut: { Task { await session.save(boundary: .saveShortcut) } })
                }
                Text(session.message).font(.footnote).textSelection(.enabled)
                if !session.opened { Button("다시 열기") { Task { await session.open() } }.disabled(session.busy) }
            }
            .padding().navigationTitle("자동저장 로컬 합성 시험")
            .toolbar { Button("저장") { Task { await session.save() } }.disabled(!session.opened || session.busy) }
        }
        .task { await session.open() }
        .onChange(of: scenePhase) { _, phase in Task { await session.foreground(phase == .active) } }
        .onDisappear { Task { await session.foreground(false) } }
    }
}
