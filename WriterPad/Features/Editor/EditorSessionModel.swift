import Foundation
import SwiftUI

@MainActor
final class EditorDraftStore {
    @MainActor
    struct Draft {
        let buffer: ManuscriptTextBuffer
        let cursor: TextCursorState

        init(text: String, cursor: TextCursorState) {
            self.buffer = ManuscriptTextBuffer(text)
            self.cursor = cursor
        }

        init(buffer: ManuscriptTextBuffer, cursor: TextCursorState) {
            self.buffer = buffer
            self.cursor = cursor
        }

        var text: String { buffer.snapshot() }
    }

    private var drafts: [DocumentID: Draft] = [:]

    func draft(for documentID: DocumentID) -> Draft? {
        drafts[documentID]
    }

    func store(_ draft: Draft, for documentID: DocumentID) {
        drafts[documentID] = draft
    }

    func removeIfMatching(text: String, for documentID: DocumentID) {
        guard drafts[documentID]?.buffer.snapshot() == text else { return }
        drafts[documentID] = nil
    }

    func removeIfMatching(
        buffer: ManuscriptTextBuffer,
        revision: UInt64,
        for documentID: DocumentID
    ) {
        guard let draft = drafts[documentID],
              draft.buffer === buffer,
              buffer.revision == revision
        else { return }
        drafts[documentID] = nil
    }
}

@MainActor
final class EditorSessionModel: ObservableObject {
    /// 같은 문서를 표시하는 두 세션도 실제 저장 제출 순서대로 generation을 공유한다.
    private static var nextSaveGeneration: UInt64 = 0

    @Published private(set) var text = ""
    private(set) var textBuffer = ManuscriptTextBuffer()
    @Published var cursor = TextCursorState.start
    @Published private(set) var statistics = ManuscriptStatistics.empty
    @Published private(set) var currentDocumentID: DocumentID?
    @Published private(set) var selectedDisplayName: String?
    @Published private(set) var externalVersion: UInt64 = 0
    private(set) var externalTextMutation: SharedEditorTextChange.VersionedMutation?
    @Published private(set) var focusRequest: UInt64 = 0
    @Published private(set) var compositionCommitRequest: UInt64 = 0
    @Published private(set) var undoRequest: UInt64 = 0
    @Published private(set) var redoRequest: UInt64 = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingDisplayName: String?
    @Published private(set) var isComposing = false
    @Published private(set) var focusPhase = EditorFocusPhase.idle
    @Published private(set) var saveState = SaveState.idle
    @Published private(set) var backupWarning: String?
    @Published private(set) var documentSearch = DocumentSearchState()
    @Published private(set) var searchNavigationRequest: UInt64 = 0
    @Published private(set) var selectionNavigationRequest: UInt64 = 0
    private(set) var statisticsCalculationCount: UInt64 = 0

    private let documentRepository: any DocumentRepository
    private let documentStore: any LocalDocumentStoring
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let draftStore: EditorDraftStore
    private let futureChangeNotifier: any FutureChangeNotifying
    private let backupStore: (any BackupStoring)?
    private let backupPolicyStore: (any BackupPolicyStoring)?
    private let autosaveDebouncer: AutosaveDebouncer
    private var selectionSequence: UInt64 = 0
    private var pendingSelection: BinderNode?
    private var pendingSearchNavigation: PendingSearchNavigation?
    private var focusStateMachine = EditorFocusStateMachine()
    private var isSceneActive = true
    private var saveGeneration: UInt64 = 0
    private var dirtyGeneration: UInt64 = 0
    private var lastSavedDirtyGeneration: UInt64 = 0
    private var pendingSaveAfterComposition = false
    private var statisticsGeneration: UInt64 = 0
    private var statisticsTask: Task<Void, Never>?
    private var statisticsBurstStartedAt: ContinuousClock.Instant?
    /// SwiftData의 문서 커서는 앱 재실행을 위한 최종 위치다. 같은 문서를 좌우 패널에
    /// 동시에 열 수 있으므로 실행 중 왕복에는 세션별 위치를 우선 사용한다.
    private var sessionCursors: [DocumentID: TextCursorState] = [:]

    init(
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring,
        backupStore: (any BackupStoring)? = nil,
        backupPolicyStore: (any BackupPolicyStoring)? = nil,
        workspaceStateRepository: any WorkspaceStateRepository,
        draftStore: EditorDraftStore = EditorDraftStore(),
        futureChangeNotifier: any FutureChangeNotifying = NoOpFutureChangeNotifier(),
        autosaveDelay: Duration = AutosaveDebouncer.defaultDelay,
        autosaveSleep: @escaping AutosaveSleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.documentRepository = documentRepository
        self.documentStore = documentStore
        self.workspaceStateRepository = workspaceStateRepository
        self.draftStore = draftStore
        self.futureChangeNotifier = futureChangeNotifier
        self.backupStore = backupStore
        self.backupPolicyStore = backupPolicyStore
        self.autosaveDebouncer = AutosaveDebouncer(
            delay: autosaveDelay,
            sleep: autosaveSleep
        )
    }

    func requestSelection(_ node: BinderNode) async {
        pendingSearchNavigation = nil
        guard isSceneActive else {
            pendingSelection = node
            pendingDisplayName = node.displayName
            return
        }
        guard !isComposing else {
            pendingSelection = node
            pendingDisplayName = node.displayName
            compositionCommitRequest &+= 1
            return
        }
        pendingSelection = nil
        pendingDisplayName = nil
        await performSelection(node)
    }

    func updateAutosaveDelay(_ delay: Duration) {
        autosaveDebouncer.updateDelay(delay)
    }

    func requestSearchNavigation(
        documentID: DocumentID,
        displayName: String,
        cursor: TextCursorState
    ) async {
        let navigation = PendingSearchNavigation(
            documentID: documentID,
            displayName: displayName,
            cursor: cursor
        )
        pendingSelection = nil
        guard isSceneActive else {
            pendingSearchNavigation = navigation
            pendingDisplayName = displayName
            return
        }
        guard !isComposing else {
            pendingSearchNavigation = navigation
            pendingDisplayName = displayName
            compositionCommitRequest &+= 1
            return
        }
        pendingSearchNavigation = nil
        pendingDisplayName = nil
        await performSearchNavigation(navigation)
    }

    func updateText(_ updatedText: String) {
        guard setText(updatedText, statisticsUpdate: .deferred) else { return }
        storeCurrentDraft()
        markDirtyAndScheduleAutosave()
    }

    /// TextKit이 보고한 실제 UTF-16 변경만 참조형 버퍼에 반영한다. 정상 입력에서는
    /// `UITextView.text`와 SwiftUI `String`을 만들거나 게시하지 않는다.
    @discardableResult
    func applyTextMutation(_ mutation: SharedEditorTextChange.Mutation) -> Bool {
        guard textBuffer.apply(mutation) else { return false }
        refreshDocumentSearchAfterTextChange()
        statisticsTask?.cancel()
        statisticsGeneration &+= 1
        statisticsBurstStartedAt = nil
        statistics = textBuffer.statistics
        storeCurrentDraft()
        markDirtyAndScheduleAutosave()
        return true
    }

    var currentText: String { textBuffer.snapshot() }
    var currentUTF16Length: Int { textBuffer.utf16Length }
    var isCurrentTextEmpty: Bool { textBuffer.isEmpty }
    var textSnapshotCreationCount: Int { textBuffer.snapshotCreationCount }

    func selectedCharacterCount() -> Int? {
        textBuffer.selectedCharacterCount(cursor)
    }

    func updateCursor(_ updatedCursor: TextCursorState) {
        cursor = updatedCursor
        guard let currentDocumentID else { return }
        sessionCursors[currentDocumentID] = updatedCursor
    }

    /// 복원 완료 후 디스크와 편집기 표시를 같은 원고로 맞춘다.
    func applyRestoredText(_ restoredText: String) {
        autosaveDebouncer.cancel()
        setText(restoredText, statisticsUpdate: .immediate)
        dirtyGeneration = max(dirtyGeneration &+ 1, saveGeneration &+ 1)
        lastSavedDirtyGeneration = dirtyGeneration
        externalTextMutation = nil
        externalVersion &+= 1
        saveState = .idle
        if let currentDocumentID {
            draftStore.removeIfMatching(text: restoredText, for: currentDocumentID)
        }
    }

    /// 같은 문서를 표시 중인 반대 패널의 변경을 표시 버전으로만 반영한다.
    /// 패널별 커서·선택·Undo 상태는 건드리지 않는다.
    @discardableResult
    func receiveSharedMutation(_ mutation: SharedEditorTextChange.Mutation) -> Bool {
        guard !isComposing else { return false }
        updateCursor(SharedEditorTextChange.adjustedCursor(cursor, applying: mutation))
        guard textBuffer.apply(mutation) else { return false }
        refreshDocumentSearchAfterTextChange()
        statisticsTask?.cancel()
        statisticsGeneration &+= 1
        statisticsBurstStartedAt = nil
        statistics = textBuffer.statistics
        storeCurrentDraft()
        let baseVersion = externalVersion
        let nextVersion = externalVersion &+ 1
        externalTextMutation = SharedEditorTextChange.VersionedMutation(
                baseVersion: baseVersion,
                version: nextVersion,
                mutation: mutation
            )
        externalVersion = nextVersion
        markDirtyAndScheduleAutosave()
        return true
    }

    func receiveSharedTextSnapshot(_ sharedText: String) {
        guard !isComposing else { return }
        let previousText = textBuffer.snapshot()
        guard previousText != sharedText else { return }
        updateCursor(
            SharedEditorTextChange.adjustedCursor(
                cursor,
                from: previousText,
                to: sharedText
            )
        )
        guard setText(sharedText, statisticsUpdate: .immediate) else { return }
        storeCurrentDraft()
        externalTextMutation = nil
        externalVersion &+= 1
        markDirtyAndScheduleAutosave()
    }

    private func refreshDocumentSearchAfterTextChange() {
        guard !documentSearch.query.isEmpty else { return }
        documentSearch.recalculate(in: currentText)
    }

    func select(_ node: BinderNode) async {
        await requestSelection(node)
    }

    func updateCompositionState(_ composing: Bool) async {
        guard composing != isComposing else { return }
        isComposing = composing
        let effects = focusStateMachine.handle(
            composing ? .compositionStarted : .compositionEnded
        )
        focusPhase = focusStateMachine.phase
        await apply(effects)
        if !composing, pendingSaveAfterComposition {
            pendingSaveAfterComposition = false
            _ = await saveNow()
        }
    }

    func updateFocusState(_ hasFocus: Bool) {
        _ = focusStateMachine.handle(hasFocus ? .focusGained : .focusLost)
        focusPhase = focusStateMachine.phase
    }

    func requestFocus() {
        guard currentDocumentID != nil else { return }
        focusRequest &+= 1
    }

    func requestCompositionCommit() {
        guard currentDocumentID != nil, isComposing else { return }
        compositionCommitRequest &+= 1
    }

    func updateDocumentSearchQuery(_ query: String) {
        documentSearch.update(query: query, in: currentText)
        revealCurrentDocumentSearchMatch()
    }

    func selectNextDocumentSearchMatch() {
        documentSearch.selectNext()
        revealCurrentDocumentSearchMatch()
    }

    func selectPreviousDocumentSearchMatch() {
        documentSearch.selectPrevious()
        revealCurrentDocumentSearchMatch()
    }

    func clearDocumentSearch() {
        documentSearch.clear()
    }

    private func revealCurrentDocumentSearchMatch() {
        guard let match = documentSearch.currentMatch else { return }
        updateCursor(match)
        searchNavigationRequest &+= 1
    }

    func requestUndo() {
        guard currentDocumentID != nil else { return }
        undoRequest &+= 1
    }

    func requestRedo() {
        guard currentDocumentID != nil else { return }
        redoRequest &+= 1
    }

    func updateSceneActivity(_ active: Bool) async {
        guard active != isSceneActive else { return }
        if !active {
            _ = await saveNow()
            _ = await persistSessionState()
        }
        isSceneActive = active
        let effects = focusStateMachine.handle(
            active
                ? .sceneBecameActive(hasDocument: currentDocumentID != nil)
                : .sceneBecameInactive
        )
        focusPhase = focusStateMachine.phase
        if active {
            await completePendingSelectionIfPossible()
        }
        await apply(effects)
    }

    private func performSelection(_ node: BinderNode) async {
        if node.kind == .text, currentDocumentID == node.id {
            focusRequest &+= 1
            return
        }
        rememberCurrentCursor()
        guard await saveNow(backupReason: .documentTransition),
              await persistSessionState() else { return }
        selectionSequence &+= 1
        let sequence = selectionSequence
        selectedDisplayName = node.displayName
        errorMessage = nil

        guard node.kind == .text else {
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            cursor = .start
            isLoading = false
            externalTextMutation = nil
            externalVersion &+= 1
            resetSaveTracking()
            return
        }

        if let draft = draftStore.draft(for: node.id) {
            apply(
                documentID: node.id,
                text: draft.text,
                cursor: draft.cursor,
                isUnsavedDraft: true
            )
            return
        }

        isLoading = true
        currentDocumentID = nil
        do {
            guard let document = try await documentRepository.document(id: node.id),
                  document.kind == .text
            else {
                throw EditorSessionError.documentNotFound(node.displayName)
            }
            let loadedText = try await documentStore.loadText(for: document)
            let persistedCursor: TextCursorState?
            do {
                persistedCursor = try await workspaceStateRepository.cursor(for: document.id)
            } catch {
                persistedCursor = nil
                errorMessage = "저장된 커서 위치를 불러오지 못해 문서 기본 위치를 사용합니다: \(error.localizedDescription)"
            }
            let restoredCursor = sessionCursors[document.id]
                ?? persistedCursor
                ?? document.cursor
            guard sequence == selectionSequence else { return }
            apply(
                documentID: document.id,
                text: loadedText,
                cursor: restoredCursor
            )
        } catch {
            guard sequence == selectionSequence else { return }
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            cursor = .start
            isLoading = false
            errorMessage = error.localizedDescription
            resetSaveTracking()
        }
    }

    @discardableResult
    func persistSessionState() async -> Bool {
        guard let currentDocumentID else { return true }
        sessionCursors[currentDocumentID] = cursor
        if dirtyGeneration > lastSavedDirtyGeneration {
            storeCurrentDraft()
        }
        do {
            try await workspaceStateRepository.saveCursor(cursor, for: currentDocumentID)
            return true
        } catch {
            errorMessage = "커서 위치를 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func saveNow(backupReason: BackupReason = .automaticSave) async -> Bool {
        autosaveDebouncer.cancel()
        return await performSaveNow(backupReason: backupReason)
    }

    @discardableResult
    private func performSaveNow(backupReason: BackupReason = .automaticSave) async -> Bool {
        guard let currentDocumentID else { return true }
        guard !isComposing else {
            pendingSaveAfterComposition = true
            return true
        }
        guard dirtyGeneration > lastSavedDirtyGeneration else {
            return await persistSessionState()
        }
        let snapshotBuffer = textBuffer
        let snapshotRevision = snapshotBuffer.revision
        let snapshotText = snapshotBuffer.snapshot()
        let snapshotCursor = cursor
        let snapshotDirtyGeneration = dirtyGeneration
        do {
            guard let document = try await documentRepository.document(id: currentDocumentID),
                  document.kind == .text
            else {
                throw EditorSessionError.documentNotFound(
                    selectedDisplayName ?? currentDocumentID.rawValue.uuidString
                )
            }
            Self.nextSaveGeneration = max(
                Self.nextSaveGeneration &+ 1,
                snapshotDirtyGeneration,
                DispatchTime.now().uptimeNanoseconds
            )
            saveGeneration = Self.nextSaveGeneration
            let generation = saveGeneration
            saveState = SaveStateMachine.reduce(
                saveState,
                event: .saveStarted(generation: generation)
            )
            let receipt = try await documentStore.save(
                DocumentSaveRequest(
                    projectID: document.projectID,
                    documentID: document.id,
                    relativePath: document.relativePath,
                    text: snapshotText,
                    generation: generation,
                    cursor: snapshotCursor
                )
            )
            if self.currentDocumentID == currentDocumentID,
               dirtyGeneration == snapshotDirtyGeneration {
                lastSavedDirtyGeneration = snapshotDirtyGeneration
                saveState = SaveStateMachine.reduce(
                    saveState,
                    event: .saveSucceeded(
                        generation: receipt.generation,
                        savedAt: receipt.modifiedAt,
                        contentHash: receipt.contentHash
                    )
                )
            }
            await futureChangeNotifier.record(
                .documentSaved(
                    projectID: receipt.projectID,
                    documentID: receipt.documentID,
                    contentHash: receipt.contentHash
                )
            )
            await createBackupIfNeeded(
                for: document,
                reason: backupReason,
                savedContent: receipt.savedContent
            )
            draftStore.removeIfMatching(
                buffer: snapshotBuffer,
                revision: snapshotRevision,
                for: currentDocumentID
            )
            // 저장 I/O를 기다리는 동안 새 입력이 들어왔다면 최신 스냅샷까지
            // 로컬 저장을 완료해야 문서 전환 호출자에 성공을 반환한다.
            if self.currentDocumentID == currentDocumentID,
               dirtyGeneration > snapshotDirtyGeneration {
                return await performSaveNow(backupReason: backupReason)
            }
            return true
        } catch {
            saveState = SaveStateMachine.reduce(
                saveState,
                event: .saveFailed(generation: saveGeneration, message: error.localizedDescription)
            )
            errorMessage = "원고를 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    private func markDirtyAndScheduleAutosave() {
        dirtyGeneration = max(
            dirtyGeneration &+ 1,
            saveGeneration &+ 1,
            DispatchTime.now().uptimeNanoseconds
        )
        saveState = SaveStateMachine.reduce(
            saveState,
            event: .edited(generation: dirtyGeneration)
        )
        autosaveDebouncer.schedule { [weak self] in
            _ = await self?.performSaveNow()
        }
    }

    private func createBackupIfNeeded(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent?
    ) async {
        guard let backupStore, let backupPolicyStore else { return }
        do {
            let policy = try await backupPolicyStore.policy(for: document.projectID)
            guard policy.isAutomaticBackupEnabled else { return }
            let cleanup: BackupCleanupReport
            if let savedContent {
                let result = try await backupStore.createSnapshotAndApplyRetention(
                    for: document,
                    reason: reason,
                    savedContent: savedContent,
                    policy: policy
                )
                cleanup = result.cleanup
            } else {
                _ = try await backupStore.createSnapshot(for: document, reason: reason)
                cleanup = try await backupStore.applyRetentionPolicy(
                    policy,
                    projectID: document.projectID
                )
            }
            backupWarning = cleanup.issues.first.map {
                "백업 정리 일부를 완료하지 못했습니다: \($0.reason)"
            }
        } catch {
            // 원고의 로컬 저장 성공은 백업 실패와 분리한다.
            backupWarning = "자동 백업을 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func storeCurrentDraft() {
        guard let currentDocumentID else { return }
        draftStore.store(
            EditorDraftStore.Draft(buffer: textBuffer, cursor: cursor),
            for: currentDocumentID
        )
    }

    var paneState: EditorPaneState {
        EditorPaneState(documentID: currentDocumentID, cursor: cursor)
    }

    func restore(documentID: DocumentID?, cursor: TextCursorState) async {
        guard let documentID else {
            await clearSelection()
            return
        }
        selectionSequence &+= 1
        let sequence = selectionSequence
        errorMessage = nil
        isLoading = true
        do {
            guard let document = try await documentRepository.document(id: documentID),
                  document.kind == .text
            else {
                throw EditorSessionError.documentNotFound(documentID.rawValue.uuidString)
            }
            selectedDisplayName = Self.displayName(for: document.relativePath)
            if let draft = draftStore.draft(for: documentID) {
                apply(
                    documentID: documentID,
                    text: draft.text,
                    cursor: draft.cursor,
                    isUnsavedDraft: true
                )
                return
            }
            let loadedText = try await documentStore.loadText(for: document)
            guard sequence == selectionSequence else { return }
            apply(documentID: documentID, text: loadedText, cursor: cursor)
        } catch {
            guard sequence == selectionSequence else { return }
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            self.cursor = .start
            isLoading = false
            errorMessage = error.localizedDescription
            resetSaveTracking()
        }
    }

    @discardableResult
    func clearSelection() async -> Bool {
        guard await saveNow(), await persistSessionState() else { return false }
        selectionSequence &+= 1
        pendingSelection = nil
        pendingDisplayName = nil
        selectedDisplayName = nil
        currentDocumentID = nil
        setText("", statisticsUpdate: .immediate)
        cursor = .start
        isLoading = false
        externalTextMutation = nil
        externalVersion &+= 1
        resetSaveTracking()
        return true
    }

    private func apply(
        documentID: DocumentID,
        text: String,
        cursor: TextCursorState,
        isUnsavedDraft: Bool = false
    ) {
        autosaveDebouncer.cancel()
        currentDocumentID = documentID
        setText(text, statisticsUpdate: .immediate)
        self.cursor = cursor
        sessionCursors[documentID] = cursor
        isLoading = false
        externalTextMutation = nil
        externalVersion &+= 1
        focusRequest &+= 1
        resetSaveTracking()
        if isUnsavedDraft {
            markDirtyAndScheduleAutosave()
        }
    }

    private func resetSaveTracking() {
        autosaveDebouncer.cancel()
        saveGeneration = 0
        dirtyGeneration = 0
        lastSavedDirtyGeneration = 0
        pendingSaveAfterComposition = false
        saveState = .idle
    }

    private func rememberCurrentCursor() {
        guard let currentDocumentID else { return }
        sessionCursors[currentDocumentID] = cursor
    }

    private enum StatisticsUpdate {
        case immediate
        case deferred
    }

    @discardableResult
    private func setText(
        _ updatedText: String,
        statisticsUpdate: StatisticsUpdate
    ) -> Bool {
        guard textBuffer.snapshot() != updatedText else { return false }
        text = updatedText
        textBuffer = ManuscriptTextBuffer(updatedText)
        if !documentSearch.query.isEmpty {
            documentSearch.recalculate(in: updatedText)
        }
        switch statisticsUpdate {
        case .immediate:
            statisticsTask?.cancel()
            statisticsGeneration &+= 1
            statisticsBurstStartedAt = nil
            statistics = ManuscriptStatistics(text: updatedText)
            statisticsCalculationCount &+= 1
        case .deferred:
            scheduleStatisticsUpdate(for: updatedText)
        }
        return true
    }

    /// 입력이 잠시 멈추면 빠르게 최신 값을 반영하고, 계속 입력하는 동안에도
    /// 최대 지연을 넘기지 않도록 주기적으로 최신 원고만 센다.
    /// 실제 `String.count`는 detached task에서 실행해 메인 액터를 점유하지 않는다.
    private func scheduleStatisticsUpdate(for snapshot: String) {
        statisticsTask?.cancel()
        statisticsGeneration &+= 1
        let generation = statisticsGeneration
        let clock = ContinuousClock()
        let now = clock.now
        let burstStartedAt = statisticsBurstStartedAt ?? now
        statisticsBurstStartedAt = burstStartedAt
        let elapsed = burstStartedAt.duration(to: now)
        let debounceDelay = Duration.milliseconds(80)
        let maximumLatency = Duration.milliseconds(300)
        let delay = elapsed >= maximumLatency
            ? Duration.zero
            : min(debounceDelay, maximumLatency - elapsed)
        statisticsTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                let calculated = await Task.detached(priority: .utility) {
                    ManuscriptStatistics(text: snapshot)
                }.value
                try Task.checkCancellation()
                guard let self,
                      generation == self.statisticsGeneration
                else { return }
                self.statistics = calculated
                self.statisticsCalculationCount &+= 1
                self.statisticsBurstStartedAt = nil
                self.statisticsTask = nil
            } catch {
                // 다음 입력이나 문서 전환이 오래된 통계 계산을 취소한 정상 경로다.
            }
        }
    }

    private func apply(_ effects: [EditorFocusEffect]) async {
        for effect in effects {
            switch effect {
            case .requestFocus:
                if currentDocumentID != nil {
                    focusRequest &+= 1
                }
            case .completePendingTransition:
                await completePendingSelectionIfPossible()
            }
        }
    }

    private func completePendingSelectionIfPossible() async {
        guard !isComposing, isSceneActive else { return }
        if let pendingSearchNavigation {
            self.pendingSearchNavigation = nil
            pendingDisplayName = nil
            await performSearchNavigation(pendingSearchNavigation)
        } else if let pendingSelection {
            self.pendingSelection = nil
            pendingDisplayName = nil
            await performSelection(pendingSelection)
        }
    }

    private func performSearchNavigation(_ navigation: PendingSearchNavigation) async {
        if currentDocumentID == navigation.documentID {
            updateCursor(clamped(navigation.cursor, toUTF16Length: currentUTF16Length))
            selectionNavigationRequest &+= 1
            focusRequest &+= 1
            return
        }

        rememberCurrentCursor()
        guard await saveNow(backupReason: .documentTransition),
              await persistSessionState()
        else {
            return
        }
        selectionSequence &+= 1
        let sequence = selectionSequence
        selectedDisplayName = navigation.displayName
        errorMessage = nil

        if let draft = draftStore.draft(for: navigation.documentID) {
            let target = clamped(navigation.cursor, toUTF16Length: draft.buffer.utf16Length)
            apply(
                documentID: navigation.documentID,
                text: draft.text,
                cursor: target,
                isUnsavedDraft: true
            )
            selectionNavigationRequest &+= 1
            return
        }

        isLoading = true
        currentDocumentID = nil
        do {
            guard let document = try await documentRepository.document(
                id: navigation.documentID
            ), document.kind == .text else {
                throw EditorSessionError.documentNotFound(navigation.displayName)
            }
            let loadedText = try await documentStore.loadText(for: document)
            guard sequence == selectionSequence else { return }
            let target = clamped(
                navigation.cursor,
                toUTF16Length: (loadedText as NSString).length
            )
            apply(
                documentID: document.id,
                text: loadedText,
                cursor: target
            )
            selectionNavigationRequest &+= 1
        } catch {
            guard sequence == selectionSequence else { return }
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            cursor = .start
            isLoading = false
            errorMessage = error.localizedDescription
            resetSaveTracking()
        }
    }

    private func clamped(
        _ cursor: TextCursorState,
        toUTF16Length length: Int
    ) -> TextCursorState {
        let location = min(Int(cursor.location), length)
        let selectionLength = min(Int(cursor.selectionLength), length - location)
        return TextCursorState(
            location: UInt(location),
            selectionLength: UInt(selectionLength)
        )
    }

    private static func displayName(for path: RelativeDocumentPath) -> String {
        let component = path.rawValue.split(separator: "/").last.map(String.init) ?? path.rawValue
        return component.hasSuffix(".txt") ? String(component.dropLast(4)) : component
    }

    private struct PendingSearchNavigation {
        let documentID: DocumentID
        let displayName: String
        let cursor: TextCursorState
    }
}

private enum EditorSessionError: LocalizedError {
    case documentNotFound(String)

    var errorDescription: String? {
        switch self {
        case let .documentNotFound(name):
            "‘\(name)’ 문서 메타데이터를 찾을 수 없습니다."
        }
    }
}
