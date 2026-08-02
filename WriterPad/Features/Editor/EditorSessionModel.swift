import Foundation
import SwiftUI

@MainActor
final class SyncV2EditorSessionRegistry:
    SyncV2OpenLocalSnapshotProviding {
    static let shared = SyncV2EditorSessionRegistry()

    private final class WeakSession {
        weak var value: EditorSessionModel?

        init(_ value: EditorSessionModel) {
            self.value = value
        }
    }

    private var sessions: [ObjectIdentifier: WeakSession] = [:]

    func register(_ session: EditorSessionModel) {
        compact()
        sessions[ObjectIdentifier(session)] = WeakSession(session)
    }

    func latestOpenSnapshot(
        documentID: UUID
    ) -> SyncV2RebaseLocalSnapshot? {
        compact()
        return sessions.values
            .compactMap(\.value)
            .compactMap {
                $0.automaticRebaseSnapshot(
                    documentID: DocumentID(rawValue: documentID)
                )
            }
            .max { lhs, rhs in
                (lhs.localSaveGeneration ?? 0)
                    < (rhs.localSaveGeneration ?? 0)
            }
    }

    func isCurrent(
        documentID: UUID,
        snapshot: SyncV2RebaseLocalSnapshot
    ) -> Bool {
        guard let current = latestOpenSnapshot(documentID: documentID)
        else {
            return false
        }
        return current.content == snapshot.content
            && current.localSaveGeneration
                == snapshot.localSaveGeneration
    }

    func applyMergedIfCurrent(
        documentID: UUID,
        expected: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) -> Bool {
        _ = mergedPath
        compact()
        let matching = sessions.values
            .compactMap(\.value)
            .filter {
                $0.currentDocumentID?.rawValue == documentID
            }
        guard !matching.isEmpty,
              matching.allSatisfy({
                  $0.canApplyAutomaticRebase(expected: expected)
              })
        else {
            return false
        }
        return matching.allSatisfy {
            $0.applyAutomaticRebase(
                expected: expected,
                mergedContent: mergedContent
            )
        }
    }

    private func compact() {
        sessions = sessions.filter { $0.value.value != nil }
    }
}

actor EditLeaseRequestOutcome {
    private var result: EditLeaseDisplayState?
    private var waiters:
        [CheckedContinuation<EditLeaseDisplayState, Never>] = []

    func resolve(_ state: EditLeaseDisplayState) {
        guard result == nil else { return }
        result = state
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: state)
        }
    }

    func value() async -> EditLeaseDisplayState {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

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
    /// UIKit 조합·포커스 콜백은 SwiftUI 갱신 패스 안에서 동기로 되돌아올 수 있어
    /// `@Published`로 두면 갱신 도중 발행 경고가 난다. 값은 콜백 순간에 동기 반영하고
    /// 관찰자 통지만 미루므로 `@Published`를 쓰지 않는다. 자세한 규칙은
    /// `scheduleObservationNotice()` 주석을 참고한다.
    private(set) var isComposing = false
    private(set) var focusPhase = EditorFocusPhase.idle
    @Published private(set) var saveState = SaveState.idle
    @Published private(set) var syncHandoffState = SyncHandoffState.idle
    @Published private(set) var editLeaseState = EditLeaseDisplayState.localOnly
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
    private let editLeaseManager: (any EditLeaseManaging)?
    private let editLeaseConnectivityMonitor:
        (any EditLeaseConnectivityMonitoring)?
    private var selectionSequence: UInt64 = 0
    private var pendingSelection: BinderNode?
    private var pendingSearchNavigation: PendingSearchNavigation?
    private var focusStateMachine = EditorFocusStateMachine()
    private var isSceneActive = true
    private var saveGeneration: UInt64 = 0
    private var dirtyGeneration: UInt64 = 0
    private var lastSavedDirtyGeneration: UInt64 = 0
    private var pendingSaveAfterComposition = false
    private var compositionStateGeneration: UInt64 = 0
    private var observationNoticeGeneration: UInt64 = 0
    private var syncHandoffStates: [DocumentID: SyncHandoffState] = [:]
    private var statisticsGeneration: UInt64 = 0
    private var statisticsTask: Task<Void, Never>?
    private var statisticsBurstStartedAt: ContinuousClock.Instant?
    private var leaseTrackedDocumentID: DocumentID?
    private var isEditLeaseStartScheduled = false
    private var hasStartedEditLeaseConnectivityMonitor = false
    private var editLeaseRequestSequence: UInt64 = 0
    private var editLeaseStateObservationTask: Task<Void, Never>?
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
        editLeaseManager: (any EditLeaseManaging)? = nil,
        editLeaseConnectivityMonitor:
            (any EditLeaseConnectivityMonitoring)? = nil,
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
        self.editLeaseManager = editLeaseManager
        self.editLeaseConnectivityMonitor = editLeaseManager == nil
            ? nil
            : editLeaseConnectivityMonitor
                ?? EditLeaseConnectivityMonitor()
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
    var hasUnsavedChanges: Bool {
        dirtyGeneration > lastSavedDirtyGeneration
    }
    var textSnapshotCreationCount: Int { textBuffer.snapshotCreationCount }

    func automaticRebaseSnapshot(
        documentID: DocumentID
    ) -> SyncV2RebaseLocalSnapshot? {
        guard currentDocumentID == documentID else { return nil }
        return SyncV2RebaseLocalSnapshot(
            content: currentText,
            localPath: "",
            relativePath: "",
            localSaveGeneration: max(
                saveGeneration,
                dirtyGeneration
            )
        )
    }

    func canApplyAutomaticRebase(
        expected: SyncV2RebaseLocalSnapshot
    ) -> Bool {
        guard !isComposing,
              currentText == expected.content
        else {
            return false
        }
        let currentGeneration = max(saveGeneration, dirtyGeneration)
        return currentGeneration <= (expected.localSaveGeneration ?? 0)
    }

    @discardableResult
    func applyAutomaticRebase(
        expected: SyncV2RebaseLocalSnapshot,
        mergedContent: String
    ) -> Bool {
        guard canApplyAutomaticRebase(expected: expected) else {
            return false
        }
        let previous = currentText
        if previous != mergedContent {
            autosaveDebouncer.cancel()
            updateCursor(
                SharedEditorTextChange.adjustedCursor(
                    cursor,
                    from: previous,
                    to: mergedContent
                )
            )
            guard setText(
                mergedContent,
                statisticsUpdate: .immediate
            ) else {
                return false
            }
            externalTextMutation = nil
            externalVersion &+= 1
        }
        let generation = expected.localSaveGeneration ?? 0
        saveGeneration = max(saveGeneration, generation)
        dirtyGeneration = max(dirtyGeneration, generation)
        lastSavedDirtyGeneration = dirtyGeneration
        saveState = .saved(
            generation: saveGeneration,
            savedAt: Date(),
            contentHash: SHA256ContentHasher().sha256(
                for: Data(mergedContent.utf8)
            )
        )
        if let currentDocumentID {
            draftStore.removeIfMatching(
                text: previous,
                for: currentDocumentID
            )
        }
        return true
    }

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

    /// snapshot pull이 clean 열린 문서를 갱신할 때 사용하는 마지막 방어선이다.
    /// dirty 또는 marked-text 조합 중이면 서버 본문을 절대 표시 버퍼에 덮지 않는다.
    @discardableResult
    func applyRemoteSnapshotIfClean(
        documentID: DocumentID,
        content: String,
        relativePath: String? = nil
    ) -> Bool {
        guard currentDocumentID == documentID,
              !isComposing,
              !hasUnsavedChanges
        else { return false }
        if let relativePath {
            selectedDisplayName = Self.displayName(
                for: RelativeDocumentPath(rawValue: relativePath)
            )
        }
        let previous = textBuffer.snapshot()
        guard previous != content else { return true }
        autosaveDebouncer.cancel()
        updateCursor(
            SharedEditorTextChange.adjustedCursor(
                cursor,
                from: previous,
                to: content
            )
        )
        guard setText(content, statisticsUpdate: .immediate) else {
            return false
        }
        dirtyGeneration = max(dirtyGeneration, saveGeneration)
        lastSavedDirtyGeneration = dirtyGeneration
        externalTextMutation = nil
        externalVersion &+= 1
        saveState = .idle
        draftStore.removeIfMatching(
            text: previous,
            for: documentID
        )
        return true
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
        guard let generation = recordCompositionState(composing) else {
            return
        }
        _ = await finishCompositionStateUpdate(
            composing,
            generation: generation
        )
    }

    /// UIKit의 marked-text 콜백 순서를 그대로 보존하도록 조합 여부는 콜백
    /// 순간에 동기 반영한다. 문서 전환·저장처럼 await가 필요한 후처리만
    /// generation으로 보호해 별도 Task에서 이어간다.
    @discardableResult
    func recordCompositionState(_ composing: Bool) -> UInt64? {
        guard composing != isComposing else { return nil }
        compositionStateGeneration &+= 1
        let generation = compositionStateGeneration
        isComposing = composing
        _ = focusStateMachine.handle(
            composing ? .compositionStarted : .compositionEnded
        )
        synchronizeFocusPhase()
        // 조합 시작·종료로 phase가 그대로인 경우(backgrounded)에도 isComposing은
        // 바뀌었으므로 통지는 반드시 예약한다.
        scheduleObservationNotice()
        return generation
    }

    @discardableResult
    func finishCompositionStateUpdate(
        _ composing: Bool,
        generation: UInt64
    ) async -> Bool {
        guard generation == compositionStateGeneration,
              isComposing == composing
        else { return false }
        if !composing {
            await apply([.completePendingTransition])
        }
        guard generation == compositionStateGeneration,
              isComposing == composing
        else { return false }
        if !composing, pendingSaveAfterComposition {
            pendingSaveAfterComposition = false
            _ = await saveNow()
        }
        return true
    }

    func updateFocusState(_ hasFocus: Bool) {
        _ = focusStateMachine.handle(hasFocus ? .focusGained : .focusLost)
        synchronizeFocusPhase()
    }

    /// 상태 기계가 곧 진실이므로 발행용 사본만 맞춘다. 값 반영은 동기라서
    /// 콜백 직후 읽어도 항상 최신이고, 통지만 갱신 패스 밖으로 밀린다.
    private func synchronizeFocusPhase() {
        guard focusPhase != focusStateMachine.phase else { return }
        focusPhase = focusStateMachine.phase
        scheduleObservationNotice()
    }

    /// `textViewDidBeginEditing`/`textViewDidEndEditing` 같은 UIKit 콜백은
    /// `updateUIView`나 문서 전환 teardown 도중 동기로 불린다. 그 자리에서
    /// `objectWillChange`를 보내면 SwiftUI 갱신 패스에 재진입해 "Publishing changes
    /// from within view updates" 경고가 나므로, 통지만 다음 메인 루프로 미룬다.
    /// 미루는 사이 새 전이가 들어오면 generation이 어긋나 낡은 통지는 버려지고
    /// 마지막 한 번만 발행된다.
    private func scheduleObservationNotice() {
        observationNoticeGeneration &+= 1
        let generation = observationNoticeGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  generation == self.observationNoticeGeneration
            else { return }
            self.objectWillChange.send()
        }
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
            await synchronizeEditLease(to: nil)
        }
        isSceneActive = active
        let effects = focusStateMachine.handle(
            active
                ? .sceneBecameActive(hasDocument: currentDocumentID != nil)
                : .sceneBecameInactive
        )
        synchronizeFocusPhase()
        if active {
            if isComposing {
                // 백그라운드 전환 중 UIKit이 marked text를 끝냈지만 콜백이
                // 전달되지 않은 경우 현재 상태를 강제로 재확인한다.
                compositionCommitRequest &+= 1
            }
            await completePendingSelectionIfPossible()
            if hasUnsavedChanges {
                await synchronizeEditLease(to: currentDocumentID)
            }
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
            await synchronizeEditLease(to: nil)
            return
        }

        if let draft = draftStore.draft(for: node.id) {
            await apply(
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
            await apply(
                documentID: document.id,
                text: loadedText,
                cursor: restoredCursor
            )
            await recoverPendingSyncHandoff(
                for: document,
                selectionSequence: sequence
            )
        } catch {
            guard sequence == selectionSequence else { return }
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            cursor = .start
            isLoading = false
            errorMessage = error.localizedDescription
            resetSaveTracking()
            await synchronizeEditLease(to: nil)
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
            if case let .failed(generation, _) = syncHandoffState {
                if let document = try? await documentRepository.document(
                    id: currentDocumentID
                ) {
                    let result = await documentStore.retryPendingSyncHandoff(
                        for: document
                    )
                    apply(
                        durableRecordResult: result,
                        generation: generation,
                        documentID: currentDocumentID
                    )
                }
            }
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
            if let durableRecordResult = receipt.durableRecordResult {
                apply(
                    durableRecordResult: durableRecordResult,
                    generation: receipt.generation,
                    documentID: receipt.documentID
                )
            }
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
        startEditLeaseAfterFirstMutationIfNeeded()
        autosaveDebouncer.schedule { [weak self] in
            _ = await self?.performSaveNow()
        }
    }

    private func startEditLeaseAfterFirstMutationIfNeeded() {
        guard
            isSceneActive,
            !isEditLeaseStartScheduled,
            editLeaseManager != nil,
            let documentID = currentDocumentID,
            leaseTrackedDocumentID != documentID
        else { return }
        isEditLeaseStartScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isEditLeaseStartScheduled = false }
            guard
                self.isSceneActive,
                self.currentDocumentID == documentID,
                self.hasUnsavedChanges
            else { return }
            await self.synchronizeEditLease(to: documentID)
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
                await apply(
                    documentID: documentID,
                    text: draft.text,
                    cursor: draft.cursor,
                    isUnsavedDraft: true
                )
                return
            }
            let loadedText = try await documentStore.loadText(for: document)
            guard sequence == selectionSequence else { return }
            await apply(
                documentID: documentID,
                text: loadedText,
                cursor: cursor
            )
            await recoverPendingSyncHandoff(
                for: document,
                selectionSequence: sequence
            )
        } catch {
            guard sequence == selectionSequence else { return }
            currentDocumentID = nil
            setText("", statisticsUpdate: .immediate)
            self.cursor = .start
            isLoading = false
            errorMessage = error.localizedDescription
            resetSaveTracking()
            await synchronizeEditLease(to: nil)
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
        await synchronizeEditLease(to: nil)
        return true
    }

    private func apply(
        documentID: DocumentID,
        text: String,
        cursor: TextCursorState,
        isUnsavedDraft: Bool = false
    ) async {
        autosaveDebouncer.cancel()
        let shouldReleasePreviousLease =
            leaseTrackedDocumentID != nil
            && leaseTrackedDocumentID != documentID

        // 문서 본문 전환은 이전 문서의 네트워크 잠금 정리보다 먼저 끝낸다.
        // 특히 대상이 빈 draft일 때 잠금 해제를 기다리면 제목만 새 화로
        // 바뀐 채 이전 UITextView와 본문이 화면에 남을 수 있다.
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
        if shouldReleasePreviousLease {
            await synchronizeEditLease(to: nil)
        }
    }

    func releaseEditLease() async {
        await synchronizeEditLease(to: nil)
    }

    func resumeEditLease() async {
        guard isSceneActive, hasUnsavedChanges else { return }
        await synchronizeEditLease(to: currentDocumentID)
    }

    private func synchronizeEditLease(to documentID: DocumentID?) async {
        guard leaseTrackedDocumentID != documentID else { return }
        editLeaseRequestSequence &+= 1
        let requestSequence = editLeaseRequestSequence
        editLeaseStateObservationTask?.cancel()
        editLeaseStateObservationTask = nil
        let previousDocumentID = leaseTrackedDocumentID
        leaseTrackedDocumentID = documentID
        if documentID == nil || editLeaseManager == nil {
            editLeaseState = .localOnly
        } else {
            editLeaseState = .acquiring
        }
        if let previous = previousDocumentID {
            await editLeaseManager?.endEditing(
                documentID: previous.rawValue
            )
        }
        guard editLeaseRequestSequence == requestSequence,
              leaseTrackedDocumentID == documentID
        else { return }
        guard let documentID, let editLeaseManager else {
            return
        }
        editLeaseStateObservationTask = Task {
            [weak self, editLeaseManager] in
            let updates = await editLeaseManager.stateUpdates(
                documentID: documentID.rawValue
            )
            for await state in updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.editLeaseRequestSequence == requestSequence,
                          self.leaseTrackedDocumentID == documentID
                    else { return }
                    self.updateEditLeaseState(
                        state,
                        for: documentID
                    )
                }
            }
        }
        let outcome = EditLeaseRequestOutcome()
        Task {
            let state = await editLeaseManager.beginEditing(
                documentID: documentID.rawValue
            )
            await outcome.resolve(state)
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: .seconds(8))
            } catch {
                return
            }
            await outcome.resolve(.unavailable)
        }
        let state = await outcome.value()
        timeoutTask.cancel()
        guard editLeaseRequestSequence == requestSequence,
              leaseTrackedDocumentID == documentID
        else { return }
        updateEditLeaseState(state, for: documentID)
        startEditLeaseConnectivityMonitorIfNeeded()
    }

    private func updateEditLeaseState(
        _ state: EditLeaseDisplayState,
        for documentID: DocumentID
    ) {
        editLeaseState = state
        _ = documentID
    }

    private func startEditLeaseConnectivityMonitorIfNeeded() {
        guard
            !hasStartedEditLeaseConnectivityMonitor,
            let editLeaseConnectivityMonitor
        else { return }
        hasStartedEditLeaseConnectivityMonitor = true
        editLeaseConnectivityMonitor.start { [weak self] isConnected in
            Task { @MainActor [weak self] in
                await self?.editLeaseConnectivityChanged(
                    isConnected: isConnected
                )
            }
        }
    }

    private func editLeaseConnectivityChanged(
        isConnected: Bool
    ) async {
        guard let documentID = leaseTrackedDocumentID else { return }
        if !isConnected {
            if let editLeaseManager {
                let state = await editLeaseManager
                    .offlineDisplayState(
                        documentID: documentID.rawValue
                    )
                updateEditLeaseState(state, for: documentID)
            }
            return
        }
        guard editLeaseState == .offlineEditing,
              let editLeaseManager
        else { return }
        editLeaseState = .acquiring
        let state = await editLeaseManager.refreshEditing(
            documentID: documentID.rawValue
        )
        updateEditLeaseState(state, for: documentID)
    }

    private func resetSaveTracking() {
        autosaveDebouncer.cancel()
        saveGeneration = 0
        dirtyGeneration = 0
        lastSavedDirtyGeneration = 0
        pendingSaveAfterComposition = false
        saveState = .idle
        syncHandoffState = currentDocumentID.flatMap {
            syncHandoffStates[$0]
        } ?? .idle
    }

    private func apply(
        durableRecordResult: DurableRecordResult,
        generation: UInt64,
        documentID: DocumentID
    ) {
        let state: SyncHandoffState
        switch durableRecordResult {
        case .queued(let operationIDs):
            state = .queued(
                generation: generation,
                operationIDs: operationIDs
            )
        case .notNeeded:
            state = .upToDate(generation: generation)
        case let .serverSizeLimitExceeded(byteCount, limit):
            state = .serverSizeLimitExceeded(
                generation: generation,
                byteCount: byteCount,
                limit: limit
            )
        case .localOnly:
            state = .localOnly
        case .localSavedButNotQueued(let reason):
            state = .failed(generation: generation, message: reason)
        }
        syncHandoffStates[documentID] = state
        if currentDocumentID == documentID {
            syncHandoffState = state
        }
    }

    private func recoverPendingSyncHandoff(
        for document: DocumentNode,
        selectionSequence: UInt64
    ) async {
        let result = await documentStore.retryPendingSyncHandoff(for: document)
        guard selectionSequence == self.selectionSequence,
              currentDocumentID == document.id
        else { return }
        guard result != .localOnly else { return }
        let generation = syncHandoffState.generation ?? saveGeneration
        apply(
            durableRecordResult: result,
            generation: generation,
            documentID: document.id
        )
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
            // 새 버퍼가 초기화하며 이미 계산한 값을 재사용한다. 복원·문서 전환 때
            // 대용량 문자열을 메인 액터에서 두 번 순회하지 않는다.
            statistics = textBuffer.statistics
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
            await apply(
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
            await apply(
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
            await synchronizeEditLease(to: nil)
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
