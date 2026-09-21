import SwiftUI
import UniformTypeIdentifiers

/// TXT 교체 뒤에도 새 입력은 유지하고, 비교 당시 그대로인 열린 편집창만 갱신한다.
@MainActor
struct GeneralSyncConflictLocalWriter {
    let projectID: ProjectID
    let repository: any DocumentRepository
    let store: any LocalDocumentStoring
    let editors: [EditorSessionModel]
    let notifier: any FutureChangeNotifying

    func save(_ review: SyncV2GeneralConflictReview, content: String,
        authorize: @escaping @Sendable () throws -> Void) async throws -> UUID {
        try Task.checkCancellation()
        guard review.context.localProjectID == projectID, review.local.deferredRecords.isEmpty,
              content.utf8.count <= SyncV2Store.maximumContentByteCount,
              let manuscript = try review.local.selected.manuscripts().first,
              let document = try await repository.document(id: .init(rawValue: review.documentID)),
              document.projectID == projectID, document.kind == .text, case .active = document.deletionStatus,
              document.relativePath.rawValue == manuscript.relativePath else {
            throw SyncV2GeneralConflictError.changed
        }
        var snapshots: [ObjectIdentifier: (version: UInt64, snapshot: SyncV2RebaseLocalSnapshot)] = [:]
        for editor in editors where editor.currentDocumentID == document.id {
            guard !editor.hasUnsavedChanges, !editor.isComposing,
                  let snapshot = editor.automaticRebaseSnapshot(documentID: document.id),
                  snapshot.content == review.savedContent else { throw SyncV2GeneralConflictError.changed }
            snapshots[ObjectIdentifier(editor)] = (editor.externalVersion, snapshot)
        }
        let receipt: DocumentSaveReceipt
        var metadataFailed = false
        do {
            receipt = try await store.saveCompared(.init(projectID: projectID, documentID: document.id,
                relativePath: document.relativePath, text: content, generation: DispatchTime.now().uptimeNanoseconds,
                cursor: document.cursor,
                expectedCurrentContentHash: SHA256ContentHasher().sha256(for: Data(review.savedContent.utf8))), authorize: authorize)
        } catch let LocalDocumentStoreError.metadataUpdateFailed(saved, _, _) {
            // TXT 교체까지 성공한 경우 화면을 옛 본문에 남겨 두지 않는다. 복구 표식은 저장소가 유지한다.
            receipt = saved
            metadataFailed = true
        }
        var editorsUnchanged = true
        for editor in editors where editor.currentDocumentID == document.id {
            guard let expected = snapshots[ObjectIdentifier(editor)],
                  expected.version == editor.externalVersion, !editor.hasUnsavedChanges,
                  editor.canApplyAutomaticRebase(expected: expected.snapshot) else {
                editorsUnchanged = false
                continue
            }
            if !editor.applyComparedSave(receipt, content: content, expected: expected.snapshot) {
                editorsUnchanged = false
            }
        }
        await notifier.record(.documentSaved(projectID: projectID, documentID: document.id, contentHash: receipt.contentHash))
        guard !metadataFailed, editorsUnchanged,
              case let .queued(operationIDs) = receipt.durableRecordResult,
              operationIDs.count == 1, let operationID = operationIDs.first else {
            throw SyncV2GeneralConflictError.localSelectionSavedNeedsReview
        }
        return operationID
    }
}

@MainActor
final class GeneralSyncRecoveryModel: ObservableObject {
    let projectID: ProjectID
    private let reader: any SyncV2GeneralRecoveryReading
    @Published private(set) var rows: [SyncV2GeneralRecoveryRow] = []
    @Published private(set) var nextCursor: Int64?
    @Published private(set) var detail: SyncV2GeneralRecoveryDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    private var generation = UUID()
    @Published private(set) var structureConflictReview: SyncV2GeneralStructureReview?
    @Published private(set) var renameConflictReview: SyncV2GeneralRenameConflictReview?
    @Published private(set) var orderConflictReview: SyncV2GeneralOrderConflictReview?
    @Published private(set) var conflictReview: SyncV2GeneralConflictReview?
    @Published private(set) var resolutionMessage: String?
    private var resolutionTask: Task<UUID, Error>?
    private let validateStructureLocal: (@Sendable (SyncV2GeneralStructureReview) async throws -> Void)?
    private let saveLocalSelection: SyncV2GeneralConflictLocalSaving?
    var canResolve: Bool { reader is any SyncV2GeneralConflictResolving }
    var canSelectContent: Bool { canResolve && saveLocalSelection != nil }

    init(projectID: ProjectID, reader: any SyncV2GeneralRecoveryReading,
         saveLocalSelection: SyncV2GeneralConflictLocalSaving? = nil,
         validateStructureLocal: (@Sendable (SyncV2GeneralStructureReview) async throws -> Void)? = nil) {
        self.projectID = projectID; self.reader = reader
        self.saveLocalSelection = saveLocalSelection; self.validateStructureLocal = validateStructureLocal
    }

    func load(more: Bool = false) async {
        guard !more || (!isLoading && nextCursor != nil) else { return }
        let token = UUID(); generation = token
        isLoading = true; errorMessage = nil
        if !more { rows = []; nextCursor = nil; detail = nil; conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil }
        defer { if generation == token { isLoading = false } }
        do {
            let page = try await reader.generalRecoveryPage(localProjectID: projectID, after: more ? nextCursor : nil)
            guard generation == token, !Task.isCancelled else { return }
            rows += page.rows.filter { row in !rows.contains(where: { $0.id == row.id }) }
            nextCursor = page.nextCursor
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            errorMessage = "보관된 변경을 읽지 못했습니다. 원본을 유지하고 있으니 다시 조회해 주세요."
        }
    }

    func select(_ row: SyncV2GeneralRecoveryRow) async {
        let token = UUID(); generation = token
        detail = nil; conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil; resolutionMessage = nil; errorMessage = nil; isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let value = try await reader.generalRecoveryDetail(localProjectID: projectID, batchID: row.batchID)
            guard generation == token, !Task.isCancelled else { return }
            guard value.localProjectID == projectID, value.row.batchID == row.batchID else { throw SyncV2GeneralRecoveryError.invalidRecord }
            detail = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            switch error {
            case SyncV2GeneralRecoveryError.recordTooLarge:
                errorMessage = "이 변경은 화면에서 꺼낼 수 있는 크기를 넘었습니다. 작품 전체 백업으로 원고를 먼저 보관해 주세요."
            case SyncV2GeneralRecoveryError.sourceChanged:
                errorMessage = "조회하는 동안 변경 상태가 바뀌었습니다. 목록을 새로 고침해 주세요."
            default:
                errorMessage = "보관된 변경의 무결성을 확인하지 못했습니다. 원본은 유지됩니다. 작품 전체 백업 후 확인이 필요합니다."
            }
        }
    }

    func compareConflict() async {
        guard let detail, !isLoading, let resolver = reader as? any SyncV2GeneralConflictResolving else { return }
        let token = UUID(); generation = token; isLoading = true; conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil; errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            if detail.source.kind == .structureChange, !(try detail.manuscripts()).isEmpty ||
                detail.source.mutations.contains(where: { if case .folderSnapshot = $0 { return true }; return false }) {
                let review = try await resolver.prepareGeneralRenameConflict(localProjectID: projectID, batchID: detail.row.batchID)
                guard generation == token, !Task.isCancelled else { return }
                guard review.context.localProjectID == projectID, review.local.detail.row.batchID == detail.row.batchID else {
                    throw SyncV2GeneralConflictError.changed
                }
                renameConflictReview = review
                return
            }
            if detail.source.kind == .structureChange {
                let review = try await resolver.prepareGeneralOrderConflict(localProjectID: projectID, batchID: detail.row.batchID)
                guard generation == token, !Task.isCancelled else { return }
                guard review.context.localProjectID == projectID, review.local.detail.row.batchID == detail.row.batchID else {
                    throw SyncV2GeneralConflictError.changed
                }
                orderConflictReview = review
                return
            }
            let review = try await resolver.prepareGeneralConflict(localProjectID: projectID, batchID: detail.row.batchID)
            guard generation == token, !Task.isCancelled else { return }
            guard review.context.localProjectID == projectID, review.local.detail.row.batchID == detail.row.batchID else {
                throw SyncV2GeneralConflictError.changed
            }
            conflictReview = review
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            errorMessage = "서버 비교를 준비하지 못했습니다. 로그인·동기화 연결을 확인해 주세요. 서버의 다른 원고나 구조도 함께 바뀌었거나 아직 지원하지 않는 변경이 있으면 보관본을 먼저 저장해 주세요."
        }
    }

    var canAdoptStructure: Bool { validateStructureLocal != nil && structureConflictReview?.canAdoptServer == true }

    func compareStructure() async {
        guard let detail, !isLoading, let resolver = reader as? any SyncV2GeneralStructureResolving else { return }
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil
        conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil
        defer { if generation == token { isLoading = false } }
        do {
            let review = try await resolver.prepareGeneralStructureConflict(localProjectID: projectID, batchID: detail.row.batchID)
            guard generation == token, !Task.isCancelled else { return }
            structureConflictReview = review
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            errorMessage = "구조 비교를 완료하지 못했습니다. 본문이나 항목 구성이 함께 바뀐 경우에는 보관 원고를 먼저 확인해 주세요. 원본 기록은 유지됩니다."
        }
    }

    func resolveStructure(adoptServer: Bool) async {
        guard let review = structureConflictReview, !isLoading, let resolver = reader as? any SyncV2GeneralStructureResolving else { return }
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil; resolutionMessage = nil
        let validator = validateStructureLocal
        let task = Task { try await resolver.resolveGeneralStructureConflict(review, adoptServer: adoptServer, validateLocal: validator) }
        resolutionTask = task
        defer { if generation == token { isLoading = false; resolutionTask = nil } }
        do {
            _ = try await task.value
            guard generation == token, !Task.isCancelled else { return }
            isLoading = false; resolutionTask = nil; await load()
            resolutionMessage = adoptServer ? "서버 구조를 선택했습니다. 일반 수신에서 이름·위치·순서를 반영하며, 원본 보관 기록은 유지됩니다. 새 입력이 있으면 수신을 보류합니다." : "보관 구조로 새 요청을 만들었습니다. 이전 원본과 후속 저장은 보존됩니다."
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            structureConflictReview = nil
            errorMessage = "구조 선택 중 서버·대기열 또는 편집 상태가 바뀌었습니다. 원본은 유지됩니다. 다시 비교해 주세요."
        }
    }

    func keepSavedOrder() async {
        guard let review = orderConflictReview, !isLoading, let resolver = reader as? any SyncV2GeneralConflictResolving else { return }
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil; resolutionMessage = nil
        let task = Task { try await resolver.keepSavedGeneralOrderConflict(review) }
        resolutionTask = task
        defer { if generation == token { isLoading = false; resolutionTask = nil } }
        do {
            _ = try await task.value
            guard generation == token, !Task.isCancelled else { return }
            orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil; isLoading = false; resolutionTask = nil
            await load()
            resolutionMessage = "보관된 순서로 새 동기화 요청을 만들었습니다. 후속 변경은 원래 순서대로 이어집니다. 이전 요청과 비교 기록도 계속 보관됩니다."
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil
            errorMessage = "순서 선택을 적용하지 못했습니다. 서버나 대기 상태가 바뀌었을 수 있습니다. 보관본을 유지하고 있으니 다시 비교해 주세요."
        }
    }

    func keepSavedName() async {
        guard let review = renameConflictReview, !isLoading, let resolver = reader as? any SyncV2GeneralConflictResolving else { return }
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil; resolutionMessage = nil
        let task = Task { try await resolver.keepSavedGeneralRenameConflict(review) }
        resolutionTask = task
        defer { if generation == token { isLoading = false; resolutionTask = nil } }
        do {
            _ = try await task.value
            guard generation == token, !Task.isCancelled else { return }
            renameConflictReview = nil; structureConflictReview = nil; isLoading = false; resolutionTask = nil
            await load()
            resolutionMessage = "보관된 이름으로 새 동기화 요청을 만들었습니다. 후속 변경은 원래 순서대로 이어집니다. 이전 요청과 비교 기록도 계속 보관됩니다."
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            renameConflictReview = nil; structureConflictReview = nil
            errorMessage = "이름 선택을 적용하지 못했습니다. 서버나 대기 상태가 바뀌었을 수 있습니다. 보관본을 유지하고 있으니 다시 비교해 주세요."
        }
    }

    func keepSavedSelection() async {
        await applySelection(content: nil)
    }

    func selectContent(_ content: String) async {
        guard canSelectContent else { return }
        await applySelection(content: content)
    }

    private func applySelection(content: String?) async {
        guard let review = conflictReview, !isLoading, let resolver = reader as? any SyncV2GeneralConflictResolving else { return }
        let token = UUID(); generation = token; isLoading = true; errorMessage = nil; resolutionMessage = nil
        let task = Task {
            if let content, let saveLocalSelection {
                return try await resolver.selectGeneralConflict(review, content: content, saveLocal: saveLocalSelection)
            }
            return try await resolver.keepSavedGeneralConflict(review)
        }
        resolutionTask = task
        defer { if generation == token { isLoading = false; resolutionTask = nil } }
        do {
            _ = try await task.value
            guard generation == token, !Task.isCancelled else { return }
            conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil; isLoading = false; resolutionTask = nil
            await load()
            resolutionMessage = content == nil
                ? "보관된 본문으로 새 동기화 요청을 만들었습니다. 전송 결과는 동기화 상태에서 확인해 주세요. 이전 원고와 비교 기록도 계속 꺼낼 수 있습니다."
                : "선택한 본문을 iPad 원고에 저장하고 새 동기화 요청을 만들었습니다. 전송 결과는 동기화 상태에서 확인해 주세요. 이전 보관본도 유지됩니다."
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil
            if case SyncV2GeneralConflictError.localSelectionSavedNeedsReview = error {
                errorMessage = "선택한 본문은 iPad에 저장했지만 동기화 재개를 완료하지 못했습니다. 새 입력과 복구 기록은 유지됩니다. 저장 상태를 확인한 뒤 다시 비교해 주세요."
            } else {
                errorMessage = "선택을 적용하지 못했습니다. 원본은 보관되어 있습니다. 편집기의 입력을 마치고 저장한 뒤 다시 비교해 주세요. 서버나 대기 상태가 바뀌었을 수도 있습니다."
            }
        }
    }

    func stop() {
        resolutionTask?.cancel(); resolutionTask = nil
        generation = UUID(); detail = nil; conflictReview = nil; orderConflictReview = nil; renameConflictReview = nil; structureConflictReview = nil; isLoading = false
    }
}

struct GeneralSyncRecoveryDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .plainText]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw SyncV2GeneralRecoveryError.invalidRecord }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct GeneralSyncRecoveryView: View {
    let projectName: String
    @StateObject private var model: GeneralSyncRecoveryModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportDocument: GeneralSyncRecoveryDocument?
    @State private var exportType: UTType = .json
    @State private var exportName = "sync-recovery.json"
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var isConfirmingResolution = false
    @State private var isConfirmingContent = false
    @State private var isConfirmingOrder = false
    @State private var isConfirmingName = false
    @State private var pendingNameFingerprint: String?
    @State private var pendingOrderFingerprint: String?
    @State private var pendingContent = ""
    @State private var pendingFingerprint: String?
    @State private var confirmServerStructure = false
    @State private var mergeDocumentID: UUID?
    @State private var mergeContent = ""

    init(projectID: ProjectID, projectName: String, reader: any SyncV2GeneralRecoveryReading,
         saveLocalSelection: SyncV2GeneralConflictLocalSaving? = nil,
         validateStructureLocal: (@Sendable (SyncV2GeneralStructureReview) async throws -> Void)? = nil) {
        self.projectName = projectName
        _model = StateObject(wrappedValue: GeneralSyncRecoveryModel(projectID: projectID, reader: reader, saveLocalSelection: saveLocalSelection, validateStructureLocal: validateStructureLocal))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(projectName) {
                    Text("이 iPad가 동기화를 위해 보관한 변경입니다. 로그인하거나 동기화를 켜지 않아도 확인할 수 있습니다.")
                    Text("내보내기는 보관본을 별도 파일로 저장합니다. 충돌 해결이나 동기화 재개는 실행하지 않습니다.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("대기 변경과 이전 보관본") {
                    if model.rows.isEmpty && !model.isLoading && model.errorMessage == nil {
                        Text("보관된 일반 변경이 없습니다.").foregroundStyle(.secondary)
                    }
                    ForEach(model.rows) { row in
                        Button { Task { await model.select(row) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.statusText).foregroundStyle(.primary)
                                if row.isQueueHead { Text("먼저 처리할 변경").font(.caption).foregroundStyle(.secondary) }
                                Text(row.createdAt).font(.caption).foregroundStyle(.secondary)
                                if model.detail?.row.id == row.id { Text("선택됨").font(.caption) }
                            }
                        }.disabled(model.isLoading)
                    }
                    if model.nextCursor != nil {
                        Button("이후 변경 더 보기") { Task { await model.load(more: true) } }.disabled(model.isLoading)
                    }
                }
                if model.isLoading { ProgressView("보관된 변경 읽는 중") }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
                if let detail = model.detail {
                    Section("선택한 변경") {
                        Text(detail.row.statusText).font(.headline)
                        Text(detail.row.guidance)
                        ForEach(Array(detail.structureDescriptions.enumerated()), id: \.offset) { _, value in Text(value) }
                        Text("조회 당시의 보관본입니다. 이후에 편집한 원고와 다를 수 있습니다. 작품 전체 백업은 작품 목록의 백업 메뉴에서 만들 수 있습니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach((try? detail.manuscripts()) ?? []) { manuscript in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(manuscript.relativePath).font(.subheadline).textSelection(.enabled)
                                Text("저장 당시 본문 \(manuscript.content.utf8.count)바이트").font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("원고 미리보기") {
                                    Text(String(manuscript.content.prefix(4000))).textSelection(.enabled)
                                    if manuscript.content.count > 4000 { Text("미리보기는 일부입니다. TXT 저장에는 본문 전체가 포함됩니다.").font(.caption) }
                                }
                                Button("이 보관본을 TXT로 저장") {
                                    beginExport(Data(manuscript.content.utf8), type: .plainText, name: manuscript.filename)
                                }
                            }
                        }
                        if detail.row.isConflictReviewCandidate, model.canResolve {
                            Button(detail.source.kind == .structureChange ? "서버 구조와 비교…" : "서버 원고와 비교…") { Task { await model.compareConflict() } }.disabled(model.isLoading)
                            Text("로그인과 동기화 연결이 필요합니다. 본문 충돌, 같은 폴더 안의 순서 충돌, 단일 문서 또는 폴더의 이름 충돌을 비교할 수 있습니다. 위치·항목 구성이나 여러 종류가 함께 바뀐 구조는 아직 지원하지 않습니다.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if detail.row.isStructureReviewCandidate {
                            Button("이동·복합 구조와 경로 복구 비교…") { Task { await model.compareStructure() } }.disabled(model.isLoading)
                        }
                        if let review = model.structureConflictReview {
                            Text(review.repairsHistoricalPath ? "과거 경로 갱신 복구" : "이름·위치·순서 비교").font(.headline)
                            Text("보관 구조")
                            ForEach(review.savedNodes, id: \.id) { node in Text("\(node.relativePath.rawValue) · 순서 \(node.userOrder + 1)").font(.caption) }
                            Text("서버 구조")
                            ForEach(review.serverNodes, id: \.id) { node in Text("\(node.relativePath.rawValue) · 순서 \(node.userOrder + 1)").font(.caption) }
                            Button("보관 구조로 동기화 재개") { Task { await model.resolveStructure(adoptServer: false) } }.disabled(model.isLoading)
                            if model.canAdoptStructure {
                                Button("서버 이름·위치·순서 채택") { confirmServerStructure = true }.disabled(model.isLoading)
                            }
                            Text("본문과 항목 구성이 같은 경우에만 구조를 선택합니다. 후속 작업이 있으면 보관 구조 재개만 가능합니다.").font(.caption)
                        }
                        if let review = model.renameConflictReview { nameComparison(review) }
                        if let review = model.orderConflictReview { orderComparison(review) }
                        if let review = model.conflictReview {
                            Text("먼저 해결할 보관본 · \(review.local.resolutionRecords.count)개 저장 기록").font(.headline)
                            DisclosureGroup("먼저 해결할 보관 원고 보기") {
                                Text(String(review.savedContent.prefix(4000))).textSelection(.enabled)
                                if review.savedContent.count > 4000 { Text("미리보기는 일부입니다. TXT에는 전체 본문이 포함됩니다.").font(.caption) }
                            }
                            Button("선택한 보관본을 TXT로 저장") {
                                beginExport(Data(review.savedContent.utf8), type: .plainText, name: "selected-manuscript-\(review.local.selected.row.batchID.uuidString.lowercased()).txt")
                            }
                            Text("비교한 서버 본문 · revision \(review.remoteRevision)").font(.headline)
                            DisclosureGroup("서버 원고 보기") {
                                Text(String(review.remoteContent.prefix(4000))).textSelection(.enabled)
                                if review.remoteContent.count > 4000 { Text("미리보기는 일부입니다. 서버 보관본 저장에는 전체 본문이 포함됩니다.").font(.caption) }
                            }
                            Button("비교한 서버 보관본을 TXT로 저장") {
                                beginExport(Data(review.remoteContent.utf8), type: .plainText, name: "server-manuscript-\(review.documentID.uuidString.lowercased()).txt")
                            }
                            Text("선택한 보관본으로 앞선 충돌을 먼저 해결합니다. 모든 원본을 보존하며 현재 iPad 원고 파일은 수정하지 않습니다.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("이 보관본으로 동기화 재개…") { isConfirmingResolution = true }.disabled(model.isLoading)
                            deferredChanges(review)
                            if model.canSelectContent, review.local.deferredRecords.isEmpty {
                                Button("서버 본문을 iPad 원고로 채택…") {
                                    confirmContent(review.remoteContent, review: review)
                                }.disabled(model.isLoading)
                                if mergeDocumentID != review.documentID {
                                    Button("직접 병합 시작") {
                                        mergeDocumentID = review.documentID; mergeContent = review.savedContent
                                    }.disabled(model.isLoading)
                                } else {
                                    Text("직접 병합할 본문").font(.headline)
                                    TextEditor(text: $mergeContent).frame(minHeight: 240).disabled(model.isLoading)
                                        .accessibilityLabel("병합할 원고 본문")
                                    Button("병합 초안을 TXT로 저장") {
                                        beginExport(Data(mergeContent.utf8), type: .plainText, name: "merge-\(review.documentID.uuidString.lowercased()).txt")
                                    }
                                    Button("이 병합 본문을 iPad 원고에 저장…") {
                                        confirmContent(mergeContent, review: review)
                                    }.disabled(model.isLoading || mergeContent.utf8.count > SyncV2Store.maximumContentByteCount)
                                }
                                Text("채택·병합은 현재 원고를 교체하고 새 요청을 만듭니다. 편집 중인 입력을 먼저 저장해 주세요. 빈 본문도 선택할 수 있으며, 이전 보관본은 유지됩니다.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if review.local.deferredRecords.isEmpty {
                                Text("서버 본문 채택·직접 병합은 작품 집필 화면의 더 보기 → 동기화 보관본에서 할 수 있습니다.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button("이 변경의 복구 기록 저장…") {
                            do { beginExport(try detail.exportData(), type: .json, name: "sync-recovery-\(detail.row.batchID.uuidString.lowercased()).json") }
                            catch { exportMessage = "복구 기록을 만들지 못했습니다. 보관된 원본은 유지됩니다." }
                        }
                        Text("복구 기록에는 저장 당시 원고·구조·요청 기록이 포함됩니다. 개인 보관용이며 작품 전체 백업을 대신하지 않습니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let message = model.resolutionMessage { Text(message).font(.footnote) }
                if model.conflictReview == nil, mergeDocumentID != nil {
                    Button("작성한 병합 초안을 TXT로 저장") {
                        beginExport(Data(mergeContent.utf8), type: .plainText, name: "merge-draft.txt")
                    }
                }
                if let exportMessage { Text(exportMessage).font(.footnote) }
            }
            .navigationTitle("보관된 동기화 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("새로 고침") { Task { await model.load() } }.disabled(model.isLoading) }
            }
        }
        .confirmationDialog("이 보관본으로 먼저 서버 원고를 갱신할까요?", isPresented: $isConfirmingResolution, titleVisibility: .visible) {
            Button("이 보관본 선택 후 동기화 재개") { Task { await model.keepSavedSelection() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("서버와 전체 대기열을 다시 확인합니다. 이후 변경은 원래 순서대로 이어서 적용되므로, 같은 원고의 후속 저장이 있으면 그 내용도 나중에 반영됩니다. 기존 보관본과 비교한 서버 본문은 유지됩니다.")
        }
        .confirmationDialog("보관된 이름으로 서버 이름을 갱신할까요?", isPresented: $isConfirmingName, titleVisibility: .visible) {
            Button("보관된 이름 선택 후 동기화 재개") {
                guard model.renameConflictReview?.fingerprint == pendingNameFingerprint else { return }
                Task { await model.keepSavedName() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("서버 본문·이름·구조와 전체 대기열을 다시 확인합니다. iPad 원고는 그대로 두며 후속 변경은 순서대로 이어집니다. 이전 요청과 비교 기록도 보관됩니다.")
        }
        .confirmationDialog("보관된 순서로 서버 순서를 갱신할까요?", isPresented: $isConfirmingOrder, titleVisibility: .visible) {
            Button("보관된 순서 선택 후 동기화 재개") {
                guard model.orderConflictReview?.fingerprint == pendingOrderFingerprint else { return }
                Task { await model.keepSavedOrder() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("비교한 서버 순서와 대기열을 다시 확인합니다. 후속 순서 변경이 있으면 나중에 이어서 반영됩니다. 기존 요청과 비교한 서버 순서는 계속 보관됩니다.")
        }
        .confirmationDialog("선택한 본문으로 iPad 원고를 교체할까요?", isPresented: $isConfirmingContent, titleVisibility: .visible) {
            Button(pendingContent.isEmpty ? "빈 원고로 저장 후 동기화 재개" : "선택한 본문 저장 후 동기화 재개") {
                guard model.conflictReview?.fingerprint == pendingFingerprint else { return }
                let selected = pendingContent
                Task { await model.selectContent(selected) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("비교한 원고가 그대로인지 다시 확인합니다. 저장 후 연결 상태가 바뀌면 원고를 보존하고 동기화 재개를 멈춥니다.")
        }
        .interactiveDismissDisabled(model.isLoading)
        .task { await model.load() }
        .onDisappear { model.stop(); exportDocument = nil }
        .confirmationDialog("서버의 이름·위치·순서를 선택할까요?", isPresented: $confirmServerStructure, titleVisibility: .visible) {
            Button("서버 구조 채택") { Task { await model.resolveStructure(adoptServer: true) } }
            Button("취소", role: .cancel) {}
        } message: { Text("보관된 로컬 변경 기록은 남습니다. 실제 구조 반영은 원고 보호 검사를 거치는 일반 수신에서 진행합니다.") }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            switch result {
            case .success: exportMessage = "별도 파일로 저장했습니다. 동기화 대기 상태는 유지됩니다."
            case .failure: exportMessage = "파일을 저장하지 못했습니다. 보관된 원본은 유지됩니다."
            }
            exportDocument = nil
        }
    }

    @ViewBuilder
    private func nameComparison(_ review: SyncV2GeneralRenameConflictReview) -> some View {
        Text(review.isFolder ? "폴더 이름 비교" : "문서 이름 비교").font(.headline)
        LabeledContent("iPad 보관 이름", value: review.savedName).textSelection(.enabled)
        LabeledContent("현재 서버 이름", value: review.remoteName).textSelection(.enabled)
        Text(review.isFolder ? "하위 원고 \(review.descendantDocuments.count)개의 본문·위치는 서버와 같습니다. 폴더 이름과 하위 경로를 함께 갱신합니다. 이후 변경 \(review.local.followers.count)건은 원래 순서대로 이어집니다. 현재 iPad 이름과 보관 이름이 다를 수 있습니다." : "보관 당시의 본문·위치·순서는 서버와 같습니다. 이후 변경 \(review.local.followers.count)건은 보관된 순서대로 이어집니다. 후속 이름 변경이 있으면 현재 iPad 이름과 이 보관본이 다를 수 있습니다.")
            .font(.footnote).foregroundStyle(.secondary)
        Button("보관된 이름 선택…") {
            pendingNameFingerprint = review.fingerprint
            isConfirmingName = true
        }.disabled(model.isLoading)
    }

    @ViewBuilder
    private func orderComparison(_ review: SyncV2GeneralOrderConflictReview) -> some View {
        Text("순서 비교 · \(review.parentName)").font(.headline)
        DisclosureGroup("iPad 보관 순서") {
            ForEach(Array(review.savedChildren.enumerated()), id: \.element) { index, id in
                Text("\(index + 1). \(review.name(for: id))").textSelection(.enabled)
            }
        }
        DisclosureGroup("현재 서버 순서") {
            ForEach(Array(review.remoteChildren.enumerated()), id: \.element) { index, id in
                Text("\(index + 1). \(review.name(for: id))").textSelection(.enabled)
            }
        }
        if !review.local.followers.isEmpty {
            Text("이후 변경 \(review.local.followers.count)건은 보관된 순서대로 이어집니다. 후속 변경이 있으면 현재 iPad 화면의 순서와 이 보관본이 다를 수 있습니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Button("보관된 순서 선택…") {
            pendingOrderFingerprint = review.fingerprint
            isConfirmingOrder = true
        }.disabled(model.isLoading)
    }

    @ViewBuilder
    private func deferredChanges(_ review: SyncV2GeneralConflictReview) -> some View {
        if !review.local.deferredRecords.isEmpty {
            DisclosureGroup("이후 순서대로 처리할 변경 · \(review.local.deferredRecords.count)건") {
                ForEach(review.local.deferredRecords, id: \.row.batchID) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.row.createdAt).font(.caption).foregroundStyle(.secondary)
                        ForEach((try? record.manuscripts()) ?? []) { manuscript in
                            Text(manuscript.relativePath).font(.subheadline)
                            Text("보관 본문 · \(manuscript.content.utf8.count)바이트").font(.caption)
                        }
                        ForEach(Array(record.structureDescriptions.enumerated()), id: \.offset) { _, description in
                            Text(description).font(.subheadline)
                        }
                    }
                }
            }
            Text("이후 변경은 이번 선택에 합치지 않습니다. 같은 원고의 후속 저장도 순서가 오면 적용됩니다. 서버 본문 채택·직접 병합은 후속 변경 처리를 마친 뒤 할 수 있습니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func confirmContent(_ content: String, review: SyncV2GeneralConflictReview) {
        pendingContent = content; pendingFingerprint = review.fingerprint; isConfirmingContent = true
    }

    private func beginExport(_ data: Data, type: UTType, name: String) {
        exportDocument = .init(data: data); exportType = type; exportName = name; exportMessage = nil; isExporting = true
    }
}
