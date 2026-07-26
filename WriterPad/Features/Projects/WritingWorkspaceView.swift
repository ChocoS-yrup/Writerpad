import Foundation
import SwiftUI
import UIKit

struct WritingWorkspaceShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("writerpad.editor-font-family")
    private var editorFontFamilyRawValue = EditorFontFamily.system.rawValue
    @AppStorage("writerpad.editor-font-size") private var editorFontSize = 17.0
    @AppStorage("writerpad.editor-line-spacing") private var editorLineSpacing = 6.0
    @AppStorage("writerpad.editor-horizontal-inset") private var editorHorizontalInset = 64.0
    @AppStorage("writerpad.editor-vertical-inset") private var editorVerticalInset = 30.0
    @AppStorage("writerpad.editor-bold") private var editorBold = false
    @AppStorage("writerpad.editor-typewriter-scrolling")
    private var editorTypewriterScrolling = false
    @AppStorage("writerpad.workspace-binder-width")
    private var preferredBinderWidth = 248.0
    @AppStorage(AutosaveDelaySetting.storageKey)
    private var autosaveDelayMilliseconds = AutosaveDelaySetting.defaultMilliseconds
    @AppStorage("writerpad.smart-ellipsis-enabled")
    private var smartEllipsisEnabled = true
    @AppStorage("writerpad.smart-quotation-shortcuts-enabled")
    private var smartQuotationShortcutsEnabled = true
    @AppStorage("writerpad.smart-scene-break-enabled")
    private var smartSceneBreakEnabled = true
    let project: ManagedProject
    let repository: any BinderRepository
    let commands: any BinderCommanding
    let documentRepository: any DocumentRepository
    let searchService: any Searching
    let exporter: any Exporting
    let workspaceStateRepository: any WorkspaceStateRepository
    let backupStore: any BackupStoring
    let backupPolicyStore: any BackupPolicyStoring
    let restoreCoordinator: DocumentRestoreCoordinator
    let futureChangeNotifier: any FutureChangeNotifying
    private let storageCoordinator: WorkspaceStorageCoordinator
    @Binding var isShowingSettings: Bool
    @Binding var smartPairsEnabled: Bool
    let onChangeProject: () async -> Void

    /// 모델 인스턴스의 수명만 소유한다. 변경 구독은 패널과 저장 배지 경계에서 수행한다.
    @State private var leftEditorModel: EditorSessionModel
    @State private var rightEditorModel: EditorSessionModel
    @State private var isBinderVisible = true
    @State private var binderDragStartWidth: CGFloat?
    /// 드래그 중에는 UserDefaults에 기록하지 않고 화면 폭만 갱신한다.
    @State private var liveBinderWidth: CGFloat?
    @State private var binderContentStateOverrides: [DocumentID: BinderTextContentState] = [:]
    /// 방향 관찰자가 첫 값을 전달하기 전에는 분할을 노출하지 않는 안전한 기본값을 사용한다.
    @State private var usesCompactLayout = true
    /// 사용자가 선택한 분할 선호다. 세로·좁은 창에서는 표시만 숨기고 이 값은 보존한다.
    @State private var isSplitPreferred = false
    @State private var splitTransitionPhase = SplitTransitionPhase.idle
    @State private var activePane = EditorPane.left
    @State private var hasRestoredWorkspace = false
    @State private var isRestoringWorkspace = false
    @State private var presentedSheet: WorkspaceSheet?
    @State private var backupDocument: BackupHistoryRoute?
    @State private var binderErrorMessage: String?
    @State private var isBinderOrdering = false
    @State private var binderEditOperation = BinderEditOperation.reorder
    @State private var trashConfirmationRequest: BinderTrashConfirmationRequest?
    @State private var notice: WorkspaceNotice?
    @State private var isDocumentSearchPresented = false
    @State private var pendingDocumentSearchPane: EditorPane?
    @State private var isDocumentSearchFieldFocused = false
    @State private var isProjectSearchPresented = false
    @State private var isProjectSearchFieldFocused = false
    @State private var projectSearchQuery = ""
    @State private var projectSearchHits: [DocumentSearchHit] = []
    @State private var projectSearchIssues: [DocumentSearchIssue] = []
    @State private var projectSearchProgress: DocumentSearchProgress?
    @State private var projectSearchErrorMessage: String?
    @State private var isProjectSearching = false
    @State private var projectSearchGeneration: UInt64 = 0
    @State private var projectSearchTask: Task<Void, Never>?

    init(
        project: ManagedProject,
        repository: any BinderRepository,
        commands: any BinderCommanding,
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring,
        searchService: any Searching,
        exporter: any Exporting,
        backupStore: any BackupStoring,
        backupPolicyStore: any BackupPolicyStoring,
        restoreCoordinator: DocumentRestoreCoordinator,
        workspaceStateRepository: any WorkspaceStateRepository,
        futureChangeNotifier: any FutureChangeNotifying,
        isShowingSettings: Binding<Bool>,
        smartPairsEnabled: Binding<Bool>,
        onChangeProject: @escaping () async -> Void
    ) {
        self.project = project
        self.repository = repository
        self.commands = commands
        self.documentRepository = documentRepository
        self.searchService = searchService
        self.exporter = exporter
        self.workspaceStateRepository = workspaceStateRepository
        self.backupStore = backupStore
        self.backupPolicyStore = backupPolicyStore
        self.restoreCoordinator = restoreCoordinator
        self.futureChangeNotifier = futureChangeNotifier
        self.storageCoordinator = WorkspaceStorageCoordinator(
            projectID: project.id,
            binderRepository: repository,
            documentRepository: documentRepository,
            workspaceStateRepository: workspaceStateRepository
        )
        self.onChangeProject = onChangeProject
        _isShowingSettings = isShowingSettings
        _smartPairsEnabled = smartPairsEnabled
        let draftStore = EditorDraftStore()
        _leftEditorModel = State(
            initialValue: EditorSessionModel(
                documentRepository: documentRepository,
                documentStore: documentStore,
                backupStore: backupStore,
                backupPolicyStore: backupPolicyStore,
                workspaceStateRepository: workspaceStateRepository,
                draftStore: draftStore,
                futureChangeNotifier: futureChangeNotifier
            )
        )
        _rightEditorModel = State(
            initialValue: EditorSessionModel(
                documentRepository: documentRepository,
                documentStore: documentStore,
                backupStore: backupStore,
                backupPolicyStore: backupPolicyStore,
                workspaceStateRepository: workspaceStateRepository,
                draftStore: draftStore,
                futureChangeNotifier: futureChangeNotifier
            )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactLayoutForCurrentSize = usesCompactLayout

            Group {
                if hasRestoredWorkspace {
                    HStack(spacing: 0) {
                        if isBinderVisible {
                            BinderPanel(
                                projectID: project.id,
                                repository: repository,
                                commands: commands,
                                isOrderingMode: $isBinderOrdering,
                                editOperation: $binderEditOperation,
                                allowsKeyboardFocus: !shouldPresentSplit
                                    || usesCompactLayoutForCurrentSize,
                                contentStateOverrides: binderContentStateOverrides,
                                onSelection: { node in
                                    Task { await handleBinderSelection(node) }
                                },
                                onErrorChange: { message in
                                    binderErrorMessage = message
                                },
                                onTrashConfirmation: { request in
                                    trashConfirmationRequest = request
                                },
                                onExtractManuscript: {
                                    presentedSheet = .export
                                }
                            )
                            .frame(width: binderWidth(for: proxy.size))
                            .overlay(alignment: .trailing) {
                                Rectangle()
                                    .fill(binderDivider)
                                    .frame(width: 2)
                                    .allowsHitTesting(false)
                            }
                            .overlay(alignment: .trailing) {
                                Color.clear
                                    .frame(width: 56)
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        DragGesture(minimumDistance: 1)
                                            .onChanged { value in
                                                resizeBinder(
                                                    from: binderWidth(for: proxy.size),
                                                    translation: value.translation.width
                                                )
                                            }
                                            .onEnded { _ in
                                                if let liveBinderWidth {
                                                    preferredBinderWidth = Double(liveBinderWidth)
                                                }
                                                liveBinderWidth = nil
                                                binderDragStartWidth = nil
                                            }
                                    )
                                    .accessibilityIdentifier("writerpad.binder-resizer")
                                    .accessibilityLabel("바인더 폭 조절선")
                                    .accessibilityValue("\(Int(binderWidth(for: proxy.size)))")
                                    .allowsHitTesting(!isBinderOrdering)
                            }
                        }

                        editorArea(usesCompactLayout: usesCompactLayoutForCurrentSize)
                            .allowsHitTesting(!isBinderOrdering)
                    }
                } else {
                    ProgressView("작업 공간 불러오는 중")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(appBackground)
            .background {
                WorkspaceLayoutObserver { size, screenOrientation in
                    updateLayout(
                        for: size,
                        screenOrientation: screenOrientation
                    )
                }
            }
            .toolbar {
                workspaceToolbar(usesCompactLayout: usesCompactLayoutForCurrentSize)
            }
        }
        .overlay {
            ZStack {
                if isProjectSearchPresented {
                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.18)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { dismissProjectSearch() }

                    projectSearchPopup
                        .padding(28)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                        .zIndex(2)
                }

                if let trashConfirmationRequest {
                    workspaceTrashConfirmationPopup(trashConfirmationRequest)
                } else if let binderErrorMessage {
                    workspaceErrorPopup(binderErrorMessage)
                } else if isBinderOrdering {
                    VStack {
                        workspaceOrderingBanner
                            .padding(.top, 12)
                        Spacer()
                    }
                }

                if trashConfirmationRequest != nil || binderErrorMessage != nil {
                    WorkspacePopupKeyCommandCapture(
                        primaryAction: handleWorkspacePopupPrimaryKey,
                        cancelAction: dismissWorkspacePopup
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
                }
            }
        }
        .toolbarBackground(appBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .focusedSceneValue(
            \.writerPadCommandActions,
            WriterPadCommandActions(
                perform: handleEditorCommand,
                canToggleEditorPane: shouldPresentSplit && !usesCompactLayout
            )
        )
        .onAppear {
            applyAutosaveDelaySetting(autosaveDelayMilliseconds)
            Task {
                await restoreWorkspaceIfNeeded()
                await updateSceneActivity(scenePhase == .active)
            }
        }
        .onChange(of: autosaveDelayMilliseconds) { _, milliseconds in
            applyAutosaveDelaySetting(milliseconds)
        }
        .onChange(of: scenePhase) { _, phase in
            Task { await updateSceneActivity(phase == .active) }
        }
        .onDisappear {
            projectSearchTask?.cancel()
        }
        .sheet(item: $presentedSheet) { sheet in
            if sheet == .trash {
                TrashManagementView(
                    projectID: project.id,
                    documentRepository: documentRepository,
                    commands: commands
                )
            } else {
                ManuscriptExportView(
                    projectID: project.id,
                    exporter: exporter,
                    prepareForExport: prepareEditorsForExport,
                    loadLastChapterNumber: loadLastManuscriptChapterNumber
                )
            }
        }
        .sheet(item: $backupDocument) { route in
            BackupHistoryView(
                document: route.document,
                backupStore: backupStore,
                restoreCoordinator: restoreCoordinator,
                currentText: { activeEditorModel.currentText },
                onRestored: { restoredText in
                    activeEditorModel.applyRestoredText(restoredText)
                }
            )
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("확인"))
            )
        }
    }

    private func editorArea(usesCompactLayout: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if shouldPresentSplit, !usesCompactLayout {
                    editorPane(leftEditorModel, pane: .left)
                    Rectangle()
                        .fill(sidebarDivider)
                        .frame(width: 1)
                    editorPane(rightEditorModel, pane: .right)
                } else {
                    editorPane(activeEditorModel, pane: activePane)
                }
            }
            if project.isDeletionRequested {
                Label("삭제 대기 중인 작품입니다", systemImage: "trash")
                    .foregroundStyle(Color.writerPadWarning)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func applyAutosaveDelaySetting(_ milliseconds: Int) {
        let normalized = AutosaveDelaySetting.normalized(milliseconds)
        if normalized != milliseconds {
            autosaveDelayMilliseconds = normalized
        }
        leftEditorModel.updateAutosaveDelay(.milliseconds(normalized))
        rightEditorModel.updateAutosaveDelay(.milliseconds(normalized))
    }

    private func editorPane(_ model: EditorSessionModel, pane: EditorPane) -> some View {
        EditorSessionObservedContent(model: model) { observedModel in
            editorPaneContent(observedModel, pane: pane)
        }
    }

    private func editorPaneContent(_ model: EditorSessionModel, pane: EditorPane) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(model.selectedDisplayName ?? "문서를 선택하세요")
                    .font(.system(size: 18, weight: .semibold, design: .default))
                    .tracking(-0.35)
                    .lineLimit(2)
                    .accessibilityIdentifier("writerpad.editor-pane-\(pane.rawValue)")
                    .accessibilityLabel(pane == .left ? "왼쪽 편집기" : "오른쪽 편집기")
                    .accessibilityValue(pane == activePane ? "활성" : "비활성")
                Spacer(minLength: 8)
                if model.currentDocumentID != nil {
                    HStack(spacing: 6) {
                        if let selectionCharacterCount = selectionCharacterCount(in: model) {
                            Text("( 선택 : \(selectionCharacterCount.formatted())자 )")
                                .foregroundStyle(.secondary)
                        }
                        Text("\(model.statistics.characterCount.formatted())자")
                    }
                    .font(.caption.monospacedDigit())
                        .accessibilityIdentifier(
                            pane == activePane
                                ? "writerpad.character-count"
                                : "writerpad.character-count-\(pane.rawValue)"
                        )
                        .accessibilityLabel(characterCountAccessibilityLabel(for: model))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(
                pane == activePane
                    ? "writerpad.selection-summary"
                    : "writerpad.selection-summary-\(pane.rawValue)"
            )
            .padding(.horizontal, shouldPresentSplit ? 22 : 32)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .contentShape(Rectangle())
            .onTapGesture {
                activate(pane)
            }

            if model.isLoading {
                ProgressView("원고 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let documentID = model.currentDocumentID {
                iPadTextEditor(
                    text: Binding(
                        get: { model.text },
                        set: { updatedText in
                            model.updateText(updatedText)
                            updateBinderContentState(for: model)
                        }
                    ),
                    documentID: documentID,
                    externalVersion: model.externalVersion,
                    externalTextMutation: model.externalTextMutation,
                    externalUTF16Length: model.currentUTF16Length,
                    selection: Binding(
                        get: { model.cursor },
                        set: { model.updateCursor($0) }
                    ),
                    focusRequest: model.focusRequest,
                    compositionCommitRequest: model.compositionCommitRequest,
                    undoRequest: model.undoRequest,
                    redoRequest: model.redoRequest,
                    isActive: pane == activePane,
                    appearance: editorAppearance,
                    searchHighlightRanges: searchHighlightRanges(for: model, pane: pane),
                    currentSearchHighlightRange: currentSearchHighlightRange(
                        for: model,
                        pane: pane
                    ),
                    searchNavigationRequest: model.searchNavigationRequest,
                    selectionNavigationRequest: model.selectionNavigationRequest,
                    textRuleSettings: TextRuleSettings(
                        smartPairsEnabled: smartPairsEnabled,
                        ellipsisConversionEnabled: smartEllipsisEnabled,
                        specialQuotationShortcutsEnabled: smartQuotationShortcutsEnabled,
                        sceneBreakEnabled: smartSceneBreakEnabled
                    ),
                    onTextChange: { recoverySnapshot, mutation in
                        if let mutation,
                           model.applyTextMutation(mutation) {
                            updateBinderContentState(for: model)
                            synchronizeSharedMutation(
                                mutation,
                                sourcePane: pane
                            )
                        } else if let recoverySnapshot {
                            model.updateText(recoverySnapshot)
                            updateBinderContentState(for: model)
                            synchronizeSharedSnapshot(
                                recoverySnapshot,
                                sourcePane: pane
                            )
                        }
                    },
                    onEditorCommand: handleEditorCommand,
                    onCompositionStateChange: { isComposing in
                        Task {
                            await model.updateCompositionState(isComposing)
                            if !isComposing {
                                completePendingDocumentSearch(for: pane)
                                await persistWorkspaceState()
                            }
                        }
                    },
                    onFocusChange: { hasFocus in
                        model.updateFocusState(hasFocus)
                        if hasFocus {
                            activate(pane)
                        }
                    }
                )
                .background(editorSurface)
            } else {
                ContentUnavailableView(
                    "문서를 선택하세요",
                    systemImage: "text.cursor",
                    description: Text("바인더에서 TXT 문서를 선택하면 편집할 수 있습니다.")
                )
                .frame(maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    activate(pane)
                }
                .accessibilityIdentifier("writerpad.editor-placeholder")
                .accessibilityHint("이 편집기 패널을 활성화합니다.")
            }

            if let pendingDisplayName = model.pendingDisplayName {
                Label(
                    "한글 조합 완료 후 ‘\(pendingDisplayName)’(으)로 전환합니다.",
                    systemImage: "keyboard"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("writerpad.pending-document-transition")
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .overlay(alignment: .top) {
            if isDocumentSearchPresented, pane == activePane {
                documentSearchPopup(model)
                    .padding(.top, 118)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: isDocumentSearchPresented)
        .background {
            if shouldPresentSplit, pane == activePane {
                Color.writerPadAccent.opacity(colorScheme == .dark ? 0.085 : 0.065)
            } else {
                Color.clear
            }
        }
        .overlay {
            if shouldPresentSplit, pane == activePane {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.writerPadAccent.opacity(colorScheme == .dark ? 0.78 : 0.72))
                        .frame(width: 1)
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Color.writerPadAccent.opacity(colorScheme == .dark ? 0.78 : 0.72))
                        .frame(width: 1)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func workspaceToolbar(usesCompactLayout: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                isBinderVisible.toggle()
            } label: {
                Label(
                    isBinderVisible ? "바인더 닫기" : "바인더 열기",
                    systemImage: "sidebar.left"
                )
            }
            .accessibilityIdentifier("writerpad.binder-toggle")
            .accessibilityHint("바인더를 \(isBinderVisible ? "닫거나" : "열거나") 합니다.")
            .focusable()
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            projectSwitcherButton

            Button {
                presentDocumentSearch()
            } label: {
                Label("검색", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("writerpad.search-button")
            .accessibilityHint("활성 편집기의 현재 문서에서 찾습니다.")
            .focusable()

            Button {
                Task { await toggleSplitEditor(usesCompactLayout: usesCompactLayout) }
            } label: {
                Label(
                    isSplitVisible(usesCompactLayout: usesCompactLayout) ? "분할 닫기" : "좌우 분할",
                    systemImage: isSplitVisible(usesCompactLayout: usesCompactLayout)
                        ? "rectangle"
                        : "rectangle.split.2x1"
                )
            }
            .accessibilityIdentifier("writerpad.split-button")
            .accessibilityHint(
                isSplitVisible(usesCompactLayout: usesCompactLayout)
                    ? "활성 편집기만 남깁니다."
                    : "가로 화면에서 두 문서를 나란히 엽니다."
            )
            .disabled(!hasRestoredWorkspace || usesCompactLayout)
            .disabled(splitTransitionPhase != .idle)
            .focusable()

            EditorSaveStatusBadge(model: activeEditorModel) {
                Task {
                    guard await activeEditorModel.saveNow() else {
                        notice = .localSaveFailure
                        return
                    }
                }
            }

            Menu {
                Button("설정", systemImage: "gearshape") {
                    isShowingSettings = true
                }
                .accessibilityIdentifier("writerpad.settings-button")
                Divider()
                Button("원고 내보내기", systemImage: "square.and.arrow.up") {
                    presentedSheet = .export
                }
                .accessibilityIdentifier("writerpad.manuscript-export")
                Button("백업") { Task { await presentBackupHistory() } }
                    .accessibilityIdentifier("writerpad.backup-history")
                Button("작품 전체 검색", systemImage: "doc.text.magnifyingglass") {
                    presentProjectSearch()
                }
                .accessibilityIdentifier("writerpad.project-search")
                Button("휴지통", systemImage: "trash") { presentedSheet = .trash }
                    .accessibilityIdentifier("writerpad.trash-management")
            } label: {
                Label("더보기", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("writerpad.workspace-more")
        }
    }

    private func updateLayout(
        for size: CGSize,
        screenOrientation: ScreenLayoutOrientation = .unknown
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let shouldUseCompactLayout = shouldUseCompactLayout(
            for: size,
            screenOrientation: screenOrientation
        )
        if shouldUseCompactLayout != usesCompactLayout {
            usesCompactLayout = shouldUseCompactLayout
            isBinderVisible = !shouldUseCompactLayout
            // 홈 화면으로 전환하는 동안에는 시스템이 잠시 세로로 보고하는 경우가 있다.
            // 그 중에 새 경고를 만들지 않고, 다시 넓은 화면이 되면 남은 경고도 제거한다.
            if !shouldUseCompactLayout, case .splitRequiresWidth? = notice {
                notice = nil
            }
        }
    }

    private var workspaceOrderingBanner: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text("바인더 편집")
                        .font(.headline)
                    Text(
                        binderEditOperation == .reorder
                            ? "오른쪽 손잡이로 같은 폴더 안의 순서를 변경합니다."
                            : "행 본문을 드래그해 다른 폴더 또는 최상위로 이동합니다."
                    )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("완료") {
                    isBinderOrdering = false
                    binderEditOperation = .reorder
                }
                .buttonStyle(.borderedProminent)
            }

            Picker("바인더 편집 작업", selection: $binderEditOperation) {
                Text("순서 변경").tag(BinderEditOperation.reorder)
                Text("폴더 이동").tag(BinderEditOperation.moveToFolder)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("writerpad.binder-edit-operation")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("writerpad.binder-ordering-banner")
    }

    private func workspaceErrorPopup(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(Color.writerPadWarning)
            Text(message)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                binderErrorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("닫기")
            .accessibilityHint("오류 안내를 즉시 닫습니다.")
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.writerPadWarning.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("writerpad.binder-error-popup")
    }

    private func workspaceTrashConfirmationPopup(
        _ request: BinderTrashConfirmationRequest
    ) -> some View {
        ZStack {
            Color.black.opacity(0.34)
                .contentShape(Rectangle())
                .onTapGesture { trashConfirmationRequest = nil }

            VStack(alignment: .leading, spacing: 16) {
                Label(trashConfirmationTitle(request.kind), systemImage: "trash")
                    .font(.title3.weight(.semibold))

                Text(trashConfirmationMessage(request.kind))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button("취소", role: .cancel) {
                        trashConfirmationRequest = nil
                    }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(trashConfirmationActionTitle(request.kind), role: .destructive) {
                        confirmWorkspaceTrashAction()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.30), radius: 22, y: 10)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("writerpad.trash-confirmation")
    }

    private func confirmWorkspaceTrashAction() {
        guard let request = trashConfirmationRequest else { return }
        trashConfirmationRequest = nil
        Task {
            guard await closeEditorsBeforeTrashAction(request) else { return }
            await request.confirm()
        }
    }

    private func handleWorkspacePopupPrimaryKey() {
        if trashConfirmationRequest != nil {
            confirmWorkspaceTrashAction()
        } else {
            binderErrorMessage = nil
            activeEditorModel.requestFocus()
        }
    }

    private func dismissWorkspacePopup() {
        if trashConfirmationRequest != nil {
            trashConfirmationRequest = nil
        } else {
            binderErrorMessage = nil
        }
        activeEditorModel.requestFocus()
    }

    private func closeEditorsBeforeTrashAction(
        _ request: BinderTrashConfirmationRequest
    ) async -> Bool {
        let affectedIDs: Set<DocumentID>
        do {
            let documents = try await storageCoordinator.documents()
            affectedIDs = trashAffectedDocumentIDs(for: request, in: documents)
        } catch {
            notice = .workspaceStateFailure
            return false
        }

        let modelsToClose = [leftEditorModel, rightEditorModel].filter { model in
            guard let documentID = model.currentDocumentID else { return false }
            return affectedIDs.contains(documentID)
        }
        guard !modelsToClose.isEmpty else { return true }
        guard modelsToClose.allSatisfy({ !$0.isComposing }) else {
            notice = .finishComposition
            return false
        }
        for model in modelsToClose {
            guard await model.clearSelection() else {
                notice = .localSaveFailure
                return false
            }
        }
        do {
            try await saveWorkspaceState(isSplitEnabled: isSplitPreferred)
            return true
        } catch {
            notice = .workspaceStateFailure
            return false
        }
    }

    private func trashAffectedDocumentIDs(
        for request: BinderTrashConfirmationRequest,
        in documents: [DocumentNode]
    ) -> Set<DocumentID> {
        let rootIDs: Set<DocumentID>
        if let targetDocumentID = request.targetDocumentID {
            rootIDs = [targetDocumentID]
        } else if request.kind == .empty,
                  let trash = documents.first(where: {
                      $0.relativePath == BinderFixedCategory.trash.relativePath
                  }) {
            rootIDs = [trash.id]
        } else {
            return []
        }

        var affectedIDs = rootIDs
        var addedDescendant = true
        while addedDescendant {
            addedDescendant = false
            for document in documents
            where !affectedIDs.contains(document.id)
                && document.parentID.map(affectedIDs.contains) == true {
                affectedIDs.insert(document.id)
                addedDescendant = true
            }
        }
        return affectedIDs
    }

    private func trashConfirmationTitle(_ kind: BinderTrashConfirmationKind) -> String {
        switch kind {
        case .move: "휴지통으로 이동할까요?"
        case .empty: "휴지통을 비울까요?"
        case .permanentDelete: "휴지통에서 영구 삭제할까요?"
        }
    }

    private func trashConfirmationMessage(_ kind: BinderTrashConfirmationKind) -> String {
        switch kind {
        case .move: "즉시 영구 삭제되지 않고 원래 위치가 기록됩니다."
        case .empty: "휴지통의 모든 항목을 영구 삭제하며 복구할 수 없습니다."
        case .permanentDelete: "삭제 후에는 복구할 수 없습니다."
        }
    }

    private func trashConfirmationActionTitle(_ kind: BinderTrashConfirmationKind) -> String {
        switch kind {
        case .move: "휴지통으로 이동"
        case .empty: "휴지통 비우기"
        case .permanentDelete: "휴지통에서 삭제"
        }
    }

    private func presentBackupHistory() async {
        guard let documentID = activeEditorModel.currentDocumentID else {
            notice = .backupRequiresDocument
            return
        }
        do {
            guard let document = try await storageCoordinator.document(id: documentID),
                  document.kind == .text
            else {
                notice = .backupRequiresDocument
                return
            }
            backupDocument = BackupHistoryRoute(document: document)
        } catch {
            notice = .contentReadFailure
        }
    }

    private func shouldUseCompactLayout(
        for size: CGSize,
        screenOrientation: ScreenLayoutOrientation = .unknown
    ) -> Bool {
        return DualEditorLayoutPolicy.usesCompactLayout(
            width: size.width,
            height: size.height,
            screenOrientation: screenOrientation
        )
    }

    private func binderWidth(for size: CGSize) -> CGFloat {
        let requestedWidth = liveBinderWidth ?? binderWidthValue
        return min(max(requestedWidth, minimumBinderWidth), maximumBinderWidth)
    }

    private var minimumBinderWidth: CGFloat { 164 }
    private var maximumBinderWidth: CGFloat { 420 }
    private var binderWidthValue: CGFloat { CGFloat(preferredBinderWidth) }

    private var appBackground: Color {
        colorScheme == .dark ? .writerPadDarkBackground : Color(uiColor: .systemBackground)
    }

    private var editorSurface: Color {
        colorScheme == .dark ? .writerPadDarkBackground : Color(uiColor: .systemBackground)
    }

    private var sidebarDivider: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }

    private var binderDivider: Color {
        colorScheme == .dark ? Color.white.opacity(0.20) : Color.black.opacity(0.16)
    }

    private var projectSwitcherButton: some View {
        Button {
            Task {
                guard !leftEditorModel.isComposing,
                      !rightEditorModel.isComposing
                else {
                    notice = .finishComposition
                    return
                }
                guard await persistAllSessionState() else {
                    notice = .localSaveFailure
                    return
                }
                await onChangeProject()
            }
        } label: {
            Label("작품 목록", systemImage: "books.vertical")
                .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("writerpad.project-switcher")
        .accessibilityLabel("작품 목록으로 돌아가기")
        .disabled(!hasRestoredWorkspace)
    }

    private func selectionCharacterCount(in model: EditorSessionModel) -> Int? {
        guard model.cursor.selectionLength > 0,
              model.cursor.location <= UInt(Int.max),
              model.cursor.selectionLength <= UInt(Int.max)
        else {
            return nil
        }

        return model.selectedCharacterCount()
    }

    private func characterCountAccessibilityLabel(for model: EditorSessionModel) -> String {
        if let selectionCharacterCount = selectionCharacterCount(in: model) {
            return "선택한 글자 수 \(selectionCharacterCount)자, 전체 글자 수 \(model.statistics.characterCount)자"
        }
        return "글자 수 \(model.statistics.characterCount)자"
    }

    private func resizeBinder(from currentWidth: CGFloat, translation: CGFloat) {
        let startWidth = binderDragStartWidth ?? currentWidth
        binderDragStartWidth = startWidth
        liveBinderWidth = min(max(startWidth + translation, minimumBinderWidth), maximumBinderWidth)
    }

    private func updateBinderContentState(for model: EditorSessionModel) {
        guard let documentID = model.currentDocumentID else { return }
        let updatedState: BinderTextContentState = model.isCurrentTextEmpty ? .empty : .written
        guard binderContentStateOverrides[documentID] != updatedState else { return }
        binderContentStateOverrides[documentID] = updatedState
    }

    private var activeEditorModel: EditorSessionModel {
        activePane == .left ? leftEditorModel : rightEditorModel
    }

    private var shouldPresentSplit: Bool {
        isSplitPreferred && !usesCompactLayout
    }

    private func isSplitVisible(usesCompactLayout: Bool) -> Bool {
        isSplitPreferred && !usesCompactLayout
    }

    private func editorModel(for pane: EditorPane) -> EditorSessionModel {
        pane == .left ? leftEditorModel : rightEditorModel
    }

    private func activate(_ pane: EditorPane) {
        guard pane != activePane else { return }
        guard !activeEditorModel.isComposing else {
            notice = .finishComposition
            return
        }
        activePane = pane
        Task { await persistWorkspaceState() }
    }

    private func handleBinderSelection(_ node: BinderNode) async {
        if node.kind == .text {
            let route = DualEditorRouter.route(
                selectedDocumentID: node.id,
                isSplitEnabled: isSplitPreferred,
                activePane: activePane,
                leftDocumentID: leftEditorModel.currentDocumentID,
                rightDocumentID: rightEditorModel.currentDocumentID
            )
            switch route {
            case let .activate(pane):
                guard !activeEditorModel.isComposing else {
                    notice = .finishComposition
                    return
                }
                activePane = pane
                editorModel(for: pane).requestFocus()
                notice = .documentAlreadyOpen
            case let .openIn(pane):
                await editorModel(for: pane).requestSelection(node)
            }
        } else {
            await activeEditorModel.requestSelection(node)
        }
        await persistWorkspaceState()
    }

    private func synchronizeSharedMutation(
        _ mutation: SharedEditorTextChange.Mutation,
        sourcePane: EditorPane
    ) {
        let source = editorModel(for: sourcePane)
        let target = editorModel(for: sourcePane == .left ? .right : .left)
        guard let documentID = source.currentDocumentID,
              target.currentDocumentID == documentID
        else { return }
        if !target.receiveSharedMutation(mutation) {
            target.receiveSharedTextSnapshot(source.currentText)
        }
    }

    private func synchronizeSharedSnapshot(
        _ snapshot: String,
        sourcePane: EditorPane
    ) {
        let source = editorModel(for: sourcePane)
        let target = editorModel(for: sourcePane == .left ? .right : .left)
        guard let documentID = source.currentDocumentID,
              target.currentDocumentID == documentID
        else { return }
        target.receiveSharedTextSnapshot(snapshot)
    }

    private func closeSplitEditor() async {
        guard isSplitPreferred else { return }
        guard splitTransitionPhase == .idle else { return }
        guard !leftEditorModel.isComposing, !rightEditorModel.isComposing else {
            notice = .finishComposition
            return
        }

        splitTransitionPhase = .closing
        defer { splitTransitionPhase = .idle }

        guard await leftEditorModel.saveNow(),
              await rightEditorModel.saveNow(),
              await leftEditorModel.persistSessionState(),
              await rightEditorModel.persistSessionState()
        else {
            notice = .localSaveFailure
            return
        }
        do {
            try await saveWorkspaceState(isSplitEnabled: false)
            isSplitPreferred = false
        } catch {
            notice = .workspaceStateFailure
        }
    }

    private func toggleSplitEditor(usesCompactLayout: Bool? = nil) async {
        if isSplitPreferred {
            await closeSplitEditor()
            return
        }

        guard splitTransitionPhase == .idle else { return }
        guard !leftEditorModel.isComposing, !rightEditorModel.isComposing else {
            notice = .finishComposition
            return
        }
        guard !(usesCompactLayout ?? self.usesCompactLayout) else {
            notice = .splitRequiresWidth
            return
        }
        let openingPane: EditorPane = activePane == .left ? .right : .left
        let openingModel = editorModel(for: openingPane)
        if openingModel.currentDocumentID == activeEditorModel.currentDocumentID,
           openingModel.currentDocumentID != nil {
            guard await openingModel.clearSelection() else {
                notice = .workspaceStateFailure
                return
            }
        }
        isSplitPreferred = true
        // 분할 표시를 다시 열어도 닫기 직전에 작업하던 패널을 유지한다.
        await persistWorkspaceState()
    }

    private func handleEditorCommand(_ command: WriterPadEditorCommand) {
        switch command {
        case .save:
            Task {
                guard await activeEditorModel.saveNow() else { return }
                await persistWorkspaceState()
                activeEditorModel.requestFocus()
            }
        case .undo:
            activeEditorModel.requestUndo()
        case .redo:
            activeEditorModel.requestRedo()
        case .find:
            presentDocumentSearch()
        case .findInProject:
            presentProjectSearch()
        case .closeFind:
            if isProjectSearchPresented {
                dismissProjectSearch()
            } else if isDocumentSearchPresented {
                dismissDocumentSearch()
            }
        case .toggleBinder:
            isBinderVisible.toggle()
        case .toggleSplit:
            Task { await toggleSplitEditor() }
        case .toggleEditorPane:
            guard isSplitPreferred, !usesCompactLayout else { return }
            guard !isProjectSearchPresented else { return }
            activePane = activePane == .left ? .right : .left
            if isDocumentSearchPresented {
                DispatchQueue.main.async {
                    isDocumentSearchFieldFocused = true
                }
            } else {
                editorModel(for: activePane).requestFocus()
            }
        case .previousChapter:
            Task { await selectAdjacentChapter(offset: -1) }
        case .nextChapter:
            Task { await selectAdjacentChapter(offset: 1) }
        }
    }

    private func presentDocumentSearch() {
        let model = activeEditorModel
        guard model.currentDocumentID != nil else { return }
        if model.isComposing {
            pendingDocumentSearchPane = activePane
            model.requestCompositionCommit()
            return
        }
        pendingDocumentSearchPane = nil
        isDocumentSearchPresented = true
        DispatchQueue.main.async {
            isDocumentSearchFieldFocused = true
        }
    }

    private func completePendingDocumentSearch(for pane: EditorPane) {
        guard pendingDocumentSearchPane == pane else { return }
        pendingDocumentSearchPane = nil
        guard activePane == pane else { return }
        isDocumentSearchPresented = true
        DispatchQueue.main.async {
            isDocumentSearchFieldFocused = true
        }
    }

    private func dismissDocumentSearch() {
        isDocumentSearchFieldFocused = false
        isDocumentSearchPresented = false
        leftEditorModel.clearDocumentSearch()
        rightEditorModel.clearDocumentSearch()
        activeEditorModel.requestFocus()
    }

    private func documentSearchPopup(_ model: EditorSessionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.writerPadAccent)
            DocumentSearchTextField(
                text: Binding(
                    get: { model.documentSearch.query },
                    set: { model.updateDocumentSearchQuery($0) }
                ),
                isFocused: $isDocumentSearchFieldFocused,
                onSubmit: model.selectNextDocumentSearchMatch,
                onCancel: dismissDocumentSearch
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32, maxHeight: 88)
            .padding(.horizontal, 10)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .accessibilityIdentifier("writerpad.document-search-field")

            Text(documentSearchCountText(model.documentSearch))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)
                .accessibilityIdentifier("writerpad.document-search-count")

            Button { model.selectPreviousDocumentSearchMatch() } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(model.documentSearch.matches.isEmpty)
            .accessibilityLabel("이전 검색 결과")

            Button { model.selectNextDocumentSearchMatch() } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(model.documentSearch.matches.isEmpty)
            .accessibilityLabel("다음 검색 결과")

            Button(action: dismissDocumentSearch) {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("검색 닫기")
            .accessibilityIdentifier("writerpad.document-search-close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: shouldPresentSplit ? 356 : 408)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(sidebarDivider.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.14), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("현재 화 찾기")
    }

    private var projectSearchPopup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("작품 전체 검색")
                        .font(.title3.weight(.semibold))
                    Text("원고와 보조 문서를 한 번에 찾습니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismissProjectSearch) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("전체 검색 닫기")
                .accessibilityIdentifier("writerpad.project-search-close")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.writerPadAccent)

                DocumentSearchTextField(
                    text: Binding(
                        get: { projectSearchQuery },
                        set: { updateProjectSearchQuery($0) }
                    ),
                    isFocused: $isProjectSearchFieldFocused,
                    placeholder: "작품 전체에서 찾기",
                    accessibilityIdentifier: "writerpad.project-search-field",
                    minimumHeight: 22,
                    maximumHeight: 88,
                    verticalTextInset: 0,
                    onSubmit: { startProjectSearch(debounce: false) },
                    onCancel: dismissProjectSearch
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 22, maxHeight: 88)

                if isProjectSearching {
                    Button(action: cancelProjectSearch) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.writerPadWarning)
                    .accessibilityLabel("검색 중지")
                }
            }
            .padding(.horizontal, 14)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            projectSearchStatusBar

            Divider()

            Group {
                if projectSearchQuery.isEmpty {
                    ContentUnavailableView(
                        "검색어를 입력하세요",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("원고, 인물표, 설정과 메모에서 검색합니다.")
                    )
                } else if !isProjectSearching,
                          projectSearchHits.isEmpty,
                          projectSearchErrorMessage == nil {
                    ContentUnavailableView.search(text: projectSearchQuery)
                } else {
                    projectSearchResults
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 760, minHeight: 460, maxHeight: 620)
        .background(
            Color(uiColor: .systemBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(sidebarDivider.opacity(0.95), lineWidth: 1)
        }
        .shadow(
            color: .black.opacity(colorScheme == .dark ? 0.42 : 0.20),
            radius: 30,
            y: 14
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("writerpad.project-search-popup")
    }

    @ViewBuilder
    private var projectSearchStatusBar: some View {
        HStack(spacing: 10) {
            if isProjectSearching {
                ProgressView()
                    .controlSize(.small)
                if let progress = projectSearchProgress {
                    Text(
                        "\(progress.completedDocumentCount.formatted())"
                            + " / \(progress.totalDocumentCount.formatted())개 문서"
                    )
                } else {
                    Text("검색 준비 중…")
                }
            } else {
                Text("\(projectSearchHits.count.formatted())개 결과")
            }
            Spacer()
            if !projectSearchIssues.isEmpty {
                Label(
                    "\(projectSearchIssues.count.formatted())개 문서를 읽지 못함",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Color.writerPadWarning)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 22)
        .padding(.bottom, 10)
        .accessibilityIdentifier("writerpad.project-search-status")
    }

    private var projectSearchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                if let projectSearchErrorMessage {
                    Label(projectSearchErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 22)
                }

                ForEach(projectSearchGroups) { group in
                    Section {
                        ForEach(group.hits) { hit in
                            Button {
                                selectProjectSearchHit(hit)
                            } label: {
                                projectSearchResultRow(hit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("writerpad.project-search-result")
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Color.writerPadDocumentTint)
                            Text(group.displayPath)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.hits.count.formatted())")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .systemBackground).opacity(0.96))
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func projectSearchResultRow(_ hit: DocumentSearchHit) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.writerPadAccent.opacity(0.65))
                .frame(width: 3)
            Text(hit.preview)
                .font(.body)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var projectSearchGroups: [ProjectSearchResultGroup] {
        Dictionary(grouping: projectSearchHits, by: \.relativePath)
            .map { ProjectSearchResultGroup(relativePath: $0.key, hits: $0.value) }
            .sorted {
                $0.relativePath.rawValue.localizedStandardCompare(
                    $1.relativePath.rawValue
                ) == .orderedAscending
            }
    }

    private func presentProjectSearch() {
        if isDocumentSearchPresented {
            isDocumentSearchFieldFocused = false
            isDocumentSearchPresented = false
            leftEditorModel.clearDocumentSearch()
            rightEditorModel.clearDocumentSearch()
        }
        isProjectSearchPresented = true
        if !projectSearchQuery.isEmpty {
            startProjectSearch(debounce: false)
        }
        DispatchQueue.main.async {
            guard isProjectSearchPresented else { return }
            isProjectSearchFieldFocused = true
        }
    }

    private func dismissProjectSearch() {
        guard isProjectSearchPresented else { return }
        // 빈 검색어에서는 취소할 검색 Task가 없어 팝업 제거와 에디터 강제
        // 포커스가 같은 responder 갱신 주기에 충돌할 수 있다. 검색 필드의
        // dismantle 단계가 responder를 정리하게 두고 포커스를 강제 이동하지 않는다.
        isProjectSearchPresented = false
        isProjectSearchFieldFocused = false
        cancelProjectSearch()
    }

    private func cancelProjectSearch() {
        projectSearchGeneration &+= 1
        projectSearchTask?.cancel()
        projectSearchTask = nil
        isProjectSearching = false
    }

    private func updateProjectSearchQuery(_ query: String) {
        projectSearchQuery = query
        startProjectSearch(debounce: true)
    }

    private func startProjectSearch(debounce: Bool) {
        projectSearchGeneration &+= 1
        let generation = projectSearchGeneration
        projectSearchTask?.cancel()
        projectSearchErrorMessage = nil

        guard !projectSearchQuery.isEmpty else {
            projectSearchHits = []
            projectSearchIssues = []
            projectSearchProgress = nil
            isProjectSearching = false
            projectSearchTask = nil
            return
        }

        let request = DocumentSearchRequest(
            projectID: project.id,
            query: projectSearchQuery,
            textOverrides: projectSearchTextOverrides()
        )
        isProjectSearching = true
        projectSearchProgress = nil
        projectSearchTask = Task {
            do {
                if debounce {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let report = try await searchService.search(
                    request,
                    progress: { progress in
                        Task { @MainActor in
                            guard generation == projectSearchGeneration else { return }
                            projectSearchProgress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                guard generation == projectSearchGeneration else { return }
                projectSearchHits = report.hits
                projectSearchIssues = report.issues
                projectSearchProgress = DocumentSearchProgress(
                    completedDocumentCount: report.searchedDocumentCount + report.issues.count,
                    totalDocumentCount: report.totalDocumentCount,
                    hitCount: report.hits.count
                )
                isProjectSearching = false
                projectSearchTask = nil
            } catch is CancellationError {
                guard generation == projectSearchGeneration else { return }
                isProjectSearching = false
                projectSearchTask = nil
            } catch {
                guard generation == projectSearchGeneration else { return }
                projectSearchErrorMessage = error.localizedDescription
                isProjectSearching = false
                projectSearchTask = nil
            }
        }
    }

    private func projectSearchTextOverrides() -> [DocumentID: String] {
        var overrides: [DocumentID: String] = [:]
        if let documentID = leftEditorModel.currentDocumentID {
            overrides[documentID] = leftEditorModel.currentText
        }
        if let documentID = rightEditorModel.currentDocumentID {
            overrides[documentID] = rightEditorModel.currentText
        }
        if let documentID = activeEditorModel.currentDocumentID {
            overrides[documentID] = activeEditorModel.currentText
        }
        return overrides
    }

    private func selectProjectSearchHit(_ hit: DocumentSearchHit) {
        cancelProjectSearch()
        isProjectSearchFieldFocused = false
        isProjectSearchPresented = false
        let model = activeEditorModel
        Task {
            await model.requestSearchNavigation(
                documentID: hit.documentID,
                displayName: ProjectSearchResultGroup.displayName(for: hit.relativePath),
                cursor: TextCursorState(
                    location: hit.utf16Location,
                    selectionLength: hit.utf16Length
                )
            )
            updateBinderContentState(for: model)
            await persistWorkspaceState()
        }
    }

    private func documentSearchCountText(_ state: DocumentSearchState) -> String {
        guard let index = state.selectedIndex else { return "0 / 0" }
        return "\(index + 1) / \(state.matches.count)"
    }

    private func searchHighlightRanges(
        for model: EditorSessionModel,
        pane: EditorPane
    ) -> [NSRange] {
        guard isDocumentSearchPresented, pane == activePane else { return [] }
        return model.documentSearch.matches.map {
            NSRange(location: Int($0.location), length: Int($0.selectionLength))
        }
    }

    private func currentSearchHighlightRange(
        for model: EditorSessionModel,
        pane: EditorPane
    ) -> NSRange? {
        guard isDocumentSearchPresented,
              pane == activePane,
              let match = model.documentSearch.currentMatch
        else { return nil }
        return NSRange(
            location: Int(match.location),
            length: Int(match.selectionLength)
        )
    }

    private func selectAdjacentChapter(offset: Int) async {
        guard let currentID = activeEditorModel.currentDocumentID else { return }
        do {
            let textNodes = try await storageCoordinator.manuscriptTextNodes()
            guard let textIndex = textNodes.firstIndex(where: { $0.id == currentID }) else {
                return
            }
            let targetIndex = textIndex + offset
            guard textNodes.indices.contains(targetIndex) else { return }
            await handleBinderSelection(textNodes[targetIndex])
        } catch {
            notice = .contentReadFailure
        }
    }

    private func loadLastManuscriptChapterNumber() async throws -> Int {
        try await storageCoordinator.lastManuscriptChapterNumber()
    }

    private func restoreWorkspaceIfNeeded() async {
        guard !hasRestoredWorkspace, !isRestoringWorkspace else { return }
        isRestoringWorkspace = true
        defer {
            isRestoringWorkspace = false
            hasRestoredWorkspace = true
        }
        do {
            let restoration = try await storageCoordinator.restoration()
            let savedState = restoration.savedState
            let state = restoration.resolvedState
            await leftEditorModel.restore(
                documentID: state.left.documentID,
                cursor: state.left.cursor
            )
            if let right = state.right {
                await rightEditorModel.restore(
                    documentID: right.documentID,
                    cursor: right.cursor
                )
                isSplitPreferred = true
                activePane = state.activePane
            } else {
                isSplitPreferred = false
                activePane = .left
            }
            if state != savedState {
                try await storageCoordinator.saveWorkspaceState(state)
            }
        } catch {
            notice = .workspaceStateFailure
        }
    }

    private func updateSceneActivity(_ active: Bool) async {
        await leftEditorModel.updateSceneActivity(active)
        await rightEditorModel.updateSceneActivity(active)
        if !active {
            await persistWorkspaceState()
        }
    }

    private func persistAllSessionState() async -> Bool {
        guard await leftEditorModel.saveNow(),
              await rightEditorModel.saveNow(),
              await leftEditorModel.persistSessionState(),
              await rightEditorModel.persistSessionState()
        else { return false }
        do {
            try await saveWorkspaceState(isSplitEnabled: isSplitPreferred)
            return true
        } catch {
            return false
        }
    }

    private func prepareEditorsForExport() async throws {
        guard !leftEditorModel.isComposing,
              !rightEditorModel.isComposing
        else {
            throw ManuscriptExportPreparationError.compositionActive
        }

        let leftSaved = await leftEditorModel.saveNow()
        let rightSaved = await rightEditorModel.saveNow()
        guard leftSaved, rightSaved else {
            throw ManuscriptExportPreparationError.saveFailed
        }
    }

    private func persistWorkspaceState() async {
        guard splitTransitionPhase == .idle else { return }
        do {
            try await saveWorkspaceState(isSplitEnabled: isSplitPreferred)
        } catch {
            notice = .workspaceStateFailure
        }
    }

    private func saveWorkspaceState(isSplitEnabled: Bool) async throws {
        let state: EditorWorkspaceState
        if isSplitEnabled {
            state = EditorWorkspaceState(
                projectID: project.id,
                left: leftEditorModel.paneState,
                right: rightEditorModel.paneState,
                activePane: activePane
            )
        } else {
            state = EditorWorkspaceState(
                projectID: project.id,
                left: activeEditorModel.paneState,
                right: nil,
                activePane: .left
            )
        }
        try await storageCoordinator.saveWorkspaceState(state)
    }

    private var editorAppearance: EditorAppearanceSettings {
        EditorAppearanceSettings(
            fontFamily: EditorFontFamily(rawValue: editorFontFamilyRawValue) ?? .system,
            fontSize: editorFontSize,
            lineSpacing: editorLineSpacing,
            horizontalInset: shouldPresentSplit && !usesCompactLayout
                ? min(max(editorHorizontalInset, 32), 44)
                : max(editorHorizontalInset, 48),
            verticalInset: editorVerticalInset,
            isBold: editorBold,
            typewriterScrolling: editorTypewriterScrolling
        )
    }
}

/// 저장 상태 변경이 작업 공간 전체가 아닌 배지만 다시 그리도록 구독 범위를 제한한다.
private struct EditorSaveStatusBadge: View {
    @ObservedObject var model: EditorSessionModel
    let onRetry: () -> Void

    var body: some View {
        SaveStatusBadge(state: model.saveState, onRetry: onRetry)
    }
}

private struct SaveStatusBadge: View {
    let state: SaveState
    let onRetry: () -> Void

    private var presentation: LocalSaveStatusPresentation {
        SaveStateMachine.presentation(for: state)
    }

    var body: some View {
        Group {
            if presentation.allowsRetry {
                Button(action: onRetry) {
                    badgeLabel
                }
                .buttonStyle(.plain)
                .accessibilityHint("최신 원고의 로컬 저장을 다시 시도합니다.")
            } else {
                badgeLabel
            }
        }
        .accessibilityIdentifier("writerpad.save-status")
        .accessibilityLabel("저장 상태: \(presentation.label)")
    }

    private var badgeLabel: some View {
        Label(presentation.label, systemImage: presentation.systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var foregroundStyle: Color {
        presentation.allowsRetry ? .red : .secondary
    }
}

private struct BackupHistoryRoute: Identifiable {
    let document: DocumentNode
    var id: DocumentID { document.id }
}

private struct ProjectSearchResultGroup: Identifiable {
    let relativePath: RelativeDocumentPath
    let hits: [DocumentSearchHit]

    var id: RelativeDocumentPath { relativePath }

    var displayPath: String {
        let path = relativePath.rawValue
        return path.hasSuffix(".txt") ? String(path.dropLast(4)) : path
    }

    static func displayName(for path: RelativeDocumentPath) -> String {
        let component = path.rawValue.split(separator: "/").last.map(String.init)
            ?? path.rawValue
        return component.hasSuffix(".txt")
            ? String(component.dropLast(4))
            : component
    }
}

private enum WorkspaceSheet: String, Identifiable {
    case export
    case trash

    var id: String { rawValue }
}

private struct WorkspacePopupKeyCommandCapture: UIViewRepresentable {
    let primaryAction: () -> Void
    let cancelAction: () -> Void

    func makeUIView(context: Context) -> PopupKeyCommandView {
        let view = PopupKeyCommandView()
        view.primaryAction = primaryAction
        view.cancelAction = cancelAction
        return view
    }

    func updateUIView(_ view: PopupKeyCommandView, context: Context) {
        view.primaryAction = primaryAction
        view.cancelAction = cancelAction
        view.captureKeyboard()
    }

    static func dismantleUIView(_ view: PopupKeyCommandView, coordinator: Void) {
        view.resignFirstResponder()
    }

    final class PopupKeyCommandView: UIView {
        var primaryAction: () -> Void = {}
        var cancelAction: () -> Void = {}

        override var canBecomeFirstResponder: Bool { true }

        override var keyCommands: [UIKeyCommand]? {
            [
                command(input: "\r", action: #selector(performPrimaryAction)),
                command(input: " ", action: #selector(performPrimaryAction)),
                command(input: UIKeyCommand.inputEscape, action: #selector(performCancelAction))
            ]
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            captureKeyboard()
        }

        func captureKeyboard() {
            guard window != nil, !isFirstResponder else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.becomeFirstResponder()
            }
        }

        private func command(input: String, action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(
                input: input,
                modifierFlags: [],
                action: action
            )
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        @objc private func performPrimaryAction() {
            primaryAction()
        }

        @objc private func performCancelAction() {
            cancelAction()
        }
    }
}

private enum WorkspaceNotice: String, Identifiable {
    case splitRequiresWidth
    case documentAlreadyOpen
    case duplicateWorkspaceDocument
    case workspaceStateFailure
    case localSaveFailure
    case finishComposition
    case backupRequiresDocument
    case contentReadFailure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .splitRequiresWidth: "화면 너비가 부족합니다"
        case .documentAlreadyOpen: "이미 열린 문서"
        case .duplicateWorkspaceDocument: "중복 문서 복원 차단"
        case .workspaceStateFailure: "편집 상태를 보존하지 못했습니다"
        case .localSaveFailure: "원고를 저장하지 못했습니다"
        case .finishComposition: "한글 입력을 마무리해 주세요"
        case .backupRequiresDocument: "백업할 원고를 먼저 열어 주세요"
        case .contentReadFailure: "작품 내용을 불러오지 못했습니다"
        }
    }

    var message: String {
        switch self {
        case .splitRequiresWidth:
            "세로 또는 좁은 화면에서는 활성 편집기 하나만 표시합니다. 가로 화면에서 좌우 분할을 열어 주세요."
        case .documentAlreadyOpen:
            "선택한 문서는 반대쪽 편집기에 이미 열려 있어 해당 편집기를 활성화했습니다."
        case .duplicateWorkspaceDocument:
            "같은 문서가 양쪽에 저장된 잘못된 상태를 발견해 왼쪽 문서 하나만 안전하게 복원했습니다."
        case .workspaceStateFailure:
            "커서나 분할 상태 저장에 실패해 닫기 또는 화면 전환을 중단했습니다. 다시 시도해 주세요."
        case .localSaveFailure:
            "최신 원고의 로컬 저장이 완료되지 않아 화면 전환을 중단했습니다. 저장 상태를 확인한 뒤 다시 시도해 주세요."
        case .finishComposition:
            "조합 중인 글자를 확정한 뒤 편집기 전환이나 분할 변경을 다시 시도해 주세요."
        case .backupRequiresDocument:
            "TXT 원고를 연 상태에서 백업 이력을 확인할 수 있습니다."
        case .contentReadFailure:
            "저장소를 읽는 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
        }
    }
}
