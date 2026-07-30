import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

enum BinderTrashConfirmationKind {
    case move
    case empty
    case permanentDelete
}

struct BinderTrashConfirmationRequest {
    let kind: BinderTrashConfirmationKind
    let targetDocumentID: DocumentID?
    let confirm: () async -> Void
}

enum BinderEditOperation: String, CaseIterable, Identifiable {
    case reorder
    case moveToFolder

    var id: Self { self }
}

private extension UTType {
    static let writerPadBinderMove = UTType(
        exportedAs: "com.chocos.writerpad.binder-move"
    )
}

private struct BinderMovePayload: Codable, Transferable {
    let documentID: DocumentID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .writerPadBinderMove)
    }

    init(_ documentID: DocumentID) {
        self.documentID = documentID
    }
}

private struct BinderEditRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [DocumentID: CGRect] = [:]

    static func reduce(
        value: inout [DocumentID: CGRect],
        nextValue: () -> [DocumentID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct BinderReorderPreview: Equatable {
    let sourceID: DocumentID
    let targetID: DocumentID
    let placeAfter: Bool
}

struct BinderPanel: View {
    private static let editCoordinateSpace = "writerpad-binder-edit-space"
    private static let reorderEdgeTolerance: CGFloat = 108
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("writerpad.binder-font-bold-v2") private var isBinderBold = true
    @AppStorage("writerpad.binder-font-larger") private var isBinderFontLarger = false
    let projectID: ProjectID
    let allowsKeyboardFocus: Bool
    let refreshGeneration: UInt64
    let contentStateOverrides: [DocumentID: BinderTextContentState]
    let onSelection: (BinderNode) -> Void
    let onErrorChange: (String?) -> Void
    let onTrashConfirmation: (BinderTrashConfirmationRequest) -> Void
    let onExtractManuscript: () -> Void
    @Binding private var isOrderingMode: Bool
    @Binding private var editOperation: BinderEditOperation
    @StateObject private var model: BinderViewModel
    @State private var namePrompt: BinderNamePrompt?
    @State private var chapterRenamePrompt: ChapterRenamePrompt?
    @State private var promptName = ""
    @State private var targetedDropNodeID: DocumentID?
    @State private var targetedDropRowID: DocumentID?
    @State private var targetedDropFolderPath: String?
    @State private var isTopLevelDropTargeted = false
    @State private var bodyDragSourceID: DocumentID?
    @State private var isReorderCommitPending = false
    @State private var reorderDragSourceID: DocumentID?
    @State private var reorderPreview: BinderReorderPreview?
    @State private var binderEditRowFrames: [DocumentID: CGRect] = [:]
    @State private var reorderDragBaseFrames: [DocumentID: CGRect] = [:]
    /// 같은 작품을 백그라운드 갱신할 때 현재 읽던 바인더 행을 계속 화면에 둔다.
    @State private var scrollPosition: DocumentID?
    @State private var orderingEntryScrollPosition: DocumentID?

    init(
        projectID: ProjectID,
        repository: any BinderRepository,
        commands: any BinderCommanding,
        isOrderingMode: Binding<Bool>,
        editOperation: Binding<BinderEditOperation>,
        allowsKeyboardFocus: Bool = true,
        refreshGeneration: UInt64 = 0,
        contentStateOverrides: [DocumentID: BinderTextContentState] = [:],
        onSelection: @escaping (BinderNode) -> Void = { _ in },
        onErrorChange: @escaping (String?) -> Void = { _ in },
        onTrashConfirmation: @escaping (BinderTrashConfirmationRequest) -> Void = { _ in },
        onExtractManuscript: @escaping () -> Void = {}
    ) {
        self.projectID = projectID
        self.allowsKeyboardFocus = allowsKeyboardFocus
        self.refreshGeneration = refreshGeneration
        self.contentStateOverrides = contentStateOverrides
        self.onSelection = onSelection
        self.onErrorChange = onErrorChange
        self.onTrashConfirmation = onTrashConfirmation
        self.onExtractManuscript = onExtractManuscript
        _isOrderingMode = isOrderingMode
        _editOperation = editOperation
        _model = StateObject(
            wrappedValue: BinderViewModel(repository: repository, commands: commands)
        )
    }

    var body: some View {
        binderContent
        .sheet(item: $chapterRenamePrompt) { prompt in
            ChapterRenameSheet(
                prefix: prompt.name.displayPrefix,
                suffix: $promptName,
                onCancel: { chapterRenamePrompt = nil },
                onSave: {
                    Task {
                        if await model.renameChapter(prompt.node, titleSuffix: promptName) {
                            chapterRenamePrompt = nil
                        }
                    }
                }
            )
        }
        .onChange(of: model.errorMessage) { _, message in onErrorChange(message) }
        .onDisappear {
            onErrorChange(nil)
            isOrderingMode = false
            resetDragState()
        }
        .onChange(of: isOrderingMode) { _, isActive in
            resetDragState()
            if isActive {
                let retainedPosition = orderingEntryScrollPosition
                    ?? scrollPosition
                editOperation = .reorder
                restoreScrollPositionAfterOrderingActivation(retainedPosition)
            } else {
                orderingEntryScrollPosition = nil
            }
        }
        .onChange(of: editOperation) { _, operation in
            resetDragState()
            if operation == .reorder, isOrderingMode {
                restoreScrollPositionAfterOrderingActivation(scrollPosition)
            }
        }
        .task(id: model.errorMessage) {
            guard model.errorMessage != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.clearError()
        }
        .background(appBackground)
        .task(
            id: "\(projectID.rawValue.uuidString)-\(refreshGeneration)"
        ) {
            await model.load(projectID: projectID)
        }
        .alert(
            namePrompt?.title ?? "이름 입력",
            isPresented: Binding(
                get: { namePrompt != nil },
                set: { if !$0 { namePrompt = nil } }
            ),
            presenting: namePrompt
        ) { prompt in
            TextField(prompt.placeholder, text: $promptName)
                .id(prompt.id)
            Button("취소", role: .cancel) { namePrompt = nil }
            Button("확인") { submitNamePrompt() }
                .disabled(prompt.requiresTypedName && promptName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { prompt in
            if let message = prompt.message { Text(message) }
        }
    }

    @ViewBuilder
    private var binderContent: some View {
        if model.roots.isEmpty, model.errorMessage == nil {
            ProgressView("바인더 불러오는 중…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            binderScrollContent
        }
    }

    private var binderScrollContent: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.visibleRows) { row in
                    if isOrderingMode {
                        binderEditRow(row)
                    } else {
                        binderBrowseRow(row)
                    }
                }
                topLevelDropArea
                    .dropDestination(for: BinderMovePayload.self) {
                        payloads, _ in
                        receiveTopLevelMovePayloads(payloads)
                    } isTargeted: { isTargeted in
                        updateTopLevelDropTarget(isTargeted: isTargeted)
                    }
            }
            // 데이터가 이동 후 다시 로드되어도 현재 보이는 행 ID를 기준으로
            // ScrollView가 같은 위치를 복원할 수 있게 한다.
            .scrollTargetLayout()
            .padding(.horizontal, 8)
        }
        .coordinateSpace(name: Self.editCoordinateSpace)
        .onPreferenceChange(BinderEditRowFramePreferenceKey.self) {
            guard reorderDragSourceID == nil else { return }
            binderEditRowFrames = $0
        }
        .background(appBackground)
        .accessibilityIdentifier("writerpad.binder-list")
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
        .scrollPosition(id: $scrollPosition, anchor: .top)
    }

    private var isReordering: Bool {
        isOrderingMode && editOperation == .reorder
    }

    private var isMovingToFolder: Bool {
        isOrderingMode && editOperation == .moveToFolder
    }

    private var topLevelDropArea: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 180)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isTopLevelDropTargeted
                            ? Color.accentColor.opacity(0.14)
                            : Color.clear
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                isTopLevelDropTargeted
                                    ? Color.accentColor
                                    : Color.clear,
                                style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                            )
                    }
            }
            .contextMenu {
                Button("새 폴더", systemImage: "folder.badge.plus") {
                    beginPrompt(.createRootFolder)
                }
                Button("순서 정렬", systemImage: "line.3.horizontal.decrease.circle") {
                    beginOrderingMode()
                }
            }
            .accessibilityLabel("빈 영역, 길게 눌러 새 폴더 또는 순서 정렬")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func binderBrowseRow(_ row: BinderVisibleRow) -> some View {
        binderRow(row)
            .task(id: row.node.id) {
                await model.prepareDisclosureState(for: row.node)
            }
            .padding(.leading, CGFloat(row.depth * 14))
    }

    private func binderEditRow(_ row: BinderVisibleRow) -> some View {
        binderRow(row)
            .task(id: row.node.id) {
                await model.prepareDisclosureState(for: row.node)
            }
            .padding(.leading, CGFloat(row.depth * 14))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: BinderEditRowFramePreferenceKey.self,
                        value: [
                            row.node.id: proxy.frame(
                                in: .named(Self.editCoordinateSpace)
                            )
                        ]
                    )
                }
            }
            .dropDestination(for: BinderMovePayload.self) {
                payloads, location in
                if isReordering {
                    receiveReorderPayloads(
                        payloads,
                        relativeTo: row.node,
                        location: location
                    )
                } else if let target = moveTarget(for: row) {
                    receiveMovePayloads(payloads, onto: target)
                } else {
                    false
                }
            } isTargeted: { isTargeted in
                updateDropTarget(row, isTargeted: isTargeted)
            }
            .offset(y: reorderPreviewOffset(for: row.node.id))
            .zIndex(reorderDragSourceID == row.node.id ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: reorderPreview)
    }

    private func binderRow(_ row: BinderVisibleRow) -> some View {
        let isSelected = model.selectedNodeID == row.node.id
        return HStack(alignment: .center, spacing: 8) {
            rowMainContent(row, isSelected: isSelected)
            if isReordering, isOrderable(row.node) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                    .frame(width: 42, height: 32)
                    .contentShape(Rectangle())
                    .highPriorityGesture(reorderHandleGesture(for: row.node))
                    .allowsHitTesting(!isReorderCommitPending)
                    .accessibilityLabel("\(row.node.displayName) 순서 변경")
                    .accessibilityHint("손잡이를 바로 드래그해 같은 폴더의 다른 항목 위나 아래로 이동합니다.")
            }
        }
        .frame(minHeight: isBinderFontLarger ? 40 : 36)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectionBackground(for: row.node))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            model.selectedNodeID == row.node.id
                                ? Color.white.opacity(0.84)
                                : Color.clear,
                            lineWidth: 2
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isDropAreaHighlighted(row)
                                ? Color.accentColor.opacity(0.22)
                                : Color.clear
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isDropAreaHighlighted(row)
                                ? Color.accentColor
                                : Color.clear,
                            lineWidth: 2.5
                        )
                }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.14), value: targetedDropNodeID)
        .accessibilityIdentifier(
            "writerpad.binder-row-\(row.node.fixedCategory?.rawValue ?? "user")"
        )
        .focusable(allowsKeyboardFocus)
    }

    @ViewBuilder
    private func rowMainContent(_ row: BinderVisibleRow, isSelected: Bool) -> some View {
        let content = HStack(alignment: .center, spacing: 8) {
                Group {
                    if row.node.isFolder, model.hasChildren(row.node) {
                        Image(
                            systemName: row.node.isExpanded
                                ? "chevron.down"
                                : "chevron.right"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            isSelected
                                ? Color.white
                                : Color.primary.opacity(0.84)
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 12, height: 18)
                Image(systemName: iconName(for: row.node))
                    .font(.system(size: isBinderFontLarger ? 15 : 13, weight: .medium))
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(isSelected ? Color.white : iconColor(for: row.node))
                Text(row.node.displayName)
                    .font(
                        .system(
                            size: isBinderFontLarger ? 16 : 14,
                            weight: isSelected ? .bold : (isBinderBold ? .bold : .regular),
                            design: .default
                        )
                    )
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.84))
                    .tracking(-0.25)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if row.node.isFolder {
                    Task { await model.toggleExpansion(of: row.node) }
                } else {
                    guard !isOrderingMode else { return }
                    model.select(row.node)
                    onSelection(row.node)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: row.node))

        if isMovingToFolder,
           isOrderable(row.node),
           model.descriptor(.move, for: row.node).isEnabled {
            content
                .draggable(BinderMovePayload(row.node.id)) {
                    dragPreview(for: row.node, systemImage: "folder")
                        .onAppear {
                            beginBodyDrag(row.node.id)
                        }
                }
                .accessibilityHint("길게 누른 뒤 다른 폴더로 드래그하여 이동합니다.")
        } else if isOrderingMode {
            content
        } else {
            content.contextMenu { binderContextMenu(for: row.node) }
        }
    }

    private func dragPreview(for node: BinderNode, systemImage: String) -> some View {
        Label(node.displayName, systemImage: systemImage)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func beginBodyDrag(_ sourceID: DocumentID) {
        bodyDragSourceID = sourceID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard bodyDragSourceID == sourceID,
                  targetedDropNodeID == nil
            else { return }
            bodyDragSourceID = nil
        }
    }

    private func updateDropTarget(_ row: BinderVisibleRow, isTargeted: Bool) {
        let target = isReordering ? row.node : moveTarget(for: row)
        let isValidTarget = bodyDragSourceID.flatMap { sourceID in
            guard let target else { return false }
            if isReordering {
                return isReorderTarget(target, sourceID: sourceID)
            } else {
                return sourceID != target.id
            }
        } ?? false
        if isTargeted, isValidTarget, let target {
            targetedDropRowID = row.node.id
            targetedDropNodeID = target.id
            targetedDropFolderPath = isReordering
                ? nil
                : target.relativePath.rawValue
        } else if targetedDropRowID == row.node.id {
            targetedDropRowID = nil
            targetedDropNodeID = nil
            targetedDropFolderPath = nil
        }
    }

    private func moveTarget(for row: BinderVisibleRow) -> BinderNode? {
        if isMoveTarget(row.node) {
            return row.node
        }
        guard !row.node.isFolder else {
            return nil
        }
        let parentPath = parentPath(of: row.node)
        return model.visibleRows.first(where: {
            $0.node.relativePath.rawValue == parentPath
                && isMoveTarget($0.node)
        })?.node
    }

    private func isDropAreaHighlighted(_ row: BinderVisibleRow) -> Bool {
        guard let targetedDropNodeID else { return false }
        if isMovingToFolder {
            return row.node.id == targetedDropNodeID
                || (!row.node.isFolder
                    && parentPath(of: row.node) == targetedDropFolderPath)
        }
        return row.node.id == targetedDropNodeID
    }

    private func receiveMovePayloads(
        _ payloads: [BinderMovePayload],
        onto target: BinderNode
    ) -> Bool {
        guard isMovingToFolder,
              isMoveTarget(target),
              let payload = payloads.first,
              payload.documentID != target.id
        else { return false }
        preserveMoveScrollPosition(removing: payload.documentID)
        bodyDragSourceID = nil
        targetedDropRowID = nil
        targetedDropNodeID = nil
        targetedDropFolderPath = nil
        return receiveDrop(payload, onto: target)
    }

    private func receiveReorderPayloads(
        _ payloads: [BinderMovePayload],
        relativeTo target: BinderNode,
        location: CGPoint
    ) -> Bool {
        guard isReordering,
              !isReorderCommitPending,
              let payload = payloads.first,
              isReorderTarget(target, sourceID: payload.documentID)
        else { return false }

        let rowMidpoint = CGFloat(isBinderFontLarger ? 20 : 18)
        let placeAfter = location.y >= rowMidpoint
        bodyDragSourceID = nil
        targetedDropRowID = nil
        targetedDropNodeID = nil
        targetedDropFolderPath = nil
        isReorderCommitPending = true
        Task {
            _ = await model.reorder(
                payload.documentID,
                relativeTo: target.id,
                placeAfter: placeAfter
            )
            isReorderCommitPending = false
        }
        return true
    }

    private func reorderHandleGesture(for source: BinderNode) -> some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(Self.editCoordinateSpace)
        )
        .onChanged { value in
            guard isReordering, !isReorderCommitPending else { return }
            if reorderDragSourceID == nil {
                reorderDragBaseFrames = binderEditRowFrames
                reorderDragSourceID = source.id
            }
            let hovered = hoveredReorderNode(at: value.location)
            if let target = hovered,
               isReorderTarget(target, sourceID: source.id),
               let targetFrame = activeReorderFrames[target.id] {
                let preview = BinderReorderPreview(
                    sourceID: source.id,
                    targetID: target.id,
                    placeAfter: value.location.y >= targetFrame.midY
                )
                reorderPreview = preview
                targetedDropNodeID = source.id
            } else if let edgePreview = reorderEdgePreview(
                for: value.location.y,
                sourceID: source.id
            ) {
                reorderPreview = edgePreview
                targetedDropNodeID = source.id
            } else if let hovered,
                      isSourceOrDescendant(
                          hovered,
                          sourceID: source.id
                      ) {
                // 원본 항목이나 펼쳐진 하위 항목 위를 지나는 동안에는
                // 마지막으로 유효했던 미리보기를 유지한다.
            } else if hovered != nil {
                reorderPreview = nil
                targetedDropNodeID = source.id
            } else if !isWithinReorderDropBounds(
                value.location.y,
                sourceID: source.id
            ) {
                reorderPreview = nil
                targetedDropNodeID = source.id
            }
        }
        .onEnded { value in
            guard isReordering,
                  !isReorderCommitPending,
                  reorderDragSourceID == source.id,
                  isWithinReorderDropBounds(
                      value.location.y,
                      sourceID: source.id
                  ),
                  let preview = reorderPreview,
                  let target = model.visibleRows.first(where: {
                      $0.node.id == preview.targetID
                  })?.node
            else {
                resetReorderGestureState()
                return
            }

            resetReorderGestureState()
            isReorderCommitPending = true
            Task {
                _ = await model.reorder(
                    source.id,
                    relativeTo: target.id,
                    placeAfter: preview.placeAfter
                )
                isReorderCommitPending = false
            }
        }
    }

    private func hoveredReorderNode(at location: CGPoint) -> BinderNode? {
        model.visibleRows.first { row in
            guard let frame = activeReorderFrames[row.node.id],
                  frame.minY...frame.maxY ~= location.y
            else { return false }
            return true
        }?.node
    }

    private func reorderEdgePreview(
        for y: CGFloat,
        sourceID: DocumentID
    ) -> BinderReorderPreview? {
        let targets = reorderTargetsWithFrames(sourceID: sourceID)
        guard let first = targets.first,
              let last = targets.last
        else { return nil }

        if y < first.frame.minY,
           y >= first.frame.minY - Self.reorderEdgeTolerance {
            return BinderReorderPreview(
                sourceID: sourceID,
                targetID: first.node.id,
                placeAfter: false
            )
        }
        if y > last.frame.maxY,
           y <= last.frame.maxY + Self.reorderEdgeTolerance {
            return BinderReorderPreview(
                sourceID: sourceID,
                targetID: last.node.id,
                placeAfter: true
            )
        }
        return nil
    }

    private func isWithinReorderDropBounds(
        _ y: CGFloat,
        sourceID: DocumentID
    ) -> Bool {
        let targets = reorderTargetsWithFrames(sourceID: sourceID)
        guard let first = targets.first,
              let last = targets.last
        else { return false }
        let lowerBound = first.frame.minY - Self.reorderEdgeTolerance
        let upperBound = last.frame.maxY + Self.reorderEdgeTolerance
        return (lowerBound...upperBound).contains(y)
    }

    private func reorderTargetsWithFrames(
        sourceID: DocumentID
    ) -> [(node: BinderNode, frame: CGRect)] {
        model.visibleRows.compactMap { row in
            guard isReorderTarget(row.node, sourceID: sourceID),
                  let frame = activeReorderFrames[row.node.id]
            else { return nil }
            return (row.node, frame)
        }
        .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func isSourceOrDescendant(
        _ node: BinderNode,
        sourceID: DocumentID
    ) -> Bool {
        guard let source = model.visibleRows.first(where: {
            $0.node.id == sourceID
        })?.node else { return false }
        return node.id == sourceID
            || node.relativePath.rawValue.hasPrefix(
                source.relativePath.rawValue + "/"
            )
    }

    private var activeReorderFrames: [DocumentID: CGRect] {
        reorderDragBaseFrames.isEmpty
            ? binderEditRowFrames
            : reorderDragBaseFrames
    }

    private func reorderPreviewOffset(for rowID: DocumentID) -> CGFloat {
        guard let preview = reorderPreview else { return 0 }
        let rows = model.visibleRows
        guard let sourceIndex = rows.firstIndex(where: {
            $0.node.id == preview.sourceID
        }) else { return 0 }

        let sourceEnd = subtreeEndIndex(in: rows, from: sourceIndex)
        let sourceBlock = Array(rows[sourceIndex..<sourceEnd])
        var reordered = rows
        reordered.removeSubrange(sourceIndex..<sourceEnd)
        guard let targetIndex = reordered.firstIndex(where: {
            $0.node.id == preview.targetID
        }) else { return 0 }

        let insertionIndex = preview.placeAfter
            ? subtreeEndIndex(in: reordered, from: targetIndex)
            : targetIndex
        reordered.insert(contentsOf: sourceBlock, at: insertionIndex)

        guard let desiredIndex = reordered.firstIndex(where: {
            $0.node.id == rowID
        }),
        rows.indices.contains(desiredIndex),
        let currentFrame = activeReorderFrames[rowID],
        let desiredFrame = activeReorderFrames[rows[desiredIndex].node.id]
        else { return 0 }
        return desiredFrame.minY - currentFrame.minY
    }

    private func subtreeEndIndex(
        in rows: [BinderVisibleRow],
        from startIndex: Int
    ) -> Int {
        let depth = rows[startIndex].depth
        var endIndex = startIndex + 1
        while endIndex < rows.count, rows[endIndex].depth > depth {
            endIndex += 1
        }
        return endIndex
    }

    private func resetReorderGestureState() {
        reorderDragSourceID = nil
        reorderPreview = nil
        reorderDragBaseFrames = [:]
        targetedDropRowID = nil
        targetedDropNodeID = nil
        targetedDropFolderPath = nil
    }

    private func isReorderTarget(
        _ target: BinderNode,
        sourceID: DocumentID
    ) -> Bool {
        guard sourceID != target.id,
              isOrderable(target),
              let source = model.visibleRows.first(where: {
                  $0.node.id == sourceID
              })?.node,
              isOrderable(source)
        else { return false }
        return parentPath(of: source) == parentPath(of: target)
    }

    private func updateTopLevelDropTarget(isTargeted: Bool) {
        guard isMovingToFolder, isTargeted else {
            isTopLevelDropTargeted = false
            return
        }
        isTopLevelDropTargeted = bodyDragSourceID.flatMap { sourceID in
            model.visibleRows.first(where: { $0.node.id == sourceID })?.node
        }?.isFolder == true
    }

    private func receiveTopLevelMovePayloads(
        _ payloads: [BinderMovePayload]
    ) -> Bool {
        guard isMovingToFolder,
              isTopLevelDropTargeted,
              let payload = payloads.first
        else { return false }
        let sourceIsFolder = model.visibleRows.first {
            $0.node.id == payload.documentID
        }?.node.isFolder == true
        preserveMoveScrollPosition(removing: payload.documentID)
        bodyDragSourceID = nil
        isTopLevelDropTargeted = false
        guard sourceIsFolder else { return false }
        Task {
            await model.moveToTopLevel(payload.documentID)
        }
        return true
    }

    private func preserveMoveScrollPosition(removing sourceID: DocumentID) {
        guard scrollPosition == sourceID,
              let sourceIndex = model.visibleRows.firstIndex(where: {
                  $0.node.id == sourceID
              })
        else { return }

        let source = model.visibleRows[sourceIndex].node
        let descendantPrefix = source.relativePath.rawValue + "/"
        let remainsVisible: (BinderVisibleRow) -> Bool = { row in
            row.node.id != sourceID
                && !row.node.relativePath.rawValue.hasPrefix(descendantPrefix)
        }

        let followingRows = model.visibleRows.dropFirst(sourceIndex + 1)
        if let following = followingRows.first(where: remainsVisible) {
            scrollPosition = following.id
            return
        }
        if let preceding = model.visibleRows[..<sourceIndex]
            .last(where: remainsVisible) {
            scrollPosition = preceding.id
        }
    }

    private func parentPath(of node: BinderNode) -> String {
        node.relativePath.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .joined(separator: "/")
    }

    private func receiveDrop(_ payload: BinderMovePayload, onto target: BinderNode) -> Bool {
        targetedDropRowID = nil
        targetedDropNodeID = nil
        targetedDropFolderPath = nil
        guard isMovingToFolder, isMoveTarget(target) else { return false }
        Task { await model.move(payload.documentID, to: target) }
        return true
    }

    private func resetDragState() {
        bodyDragSourceID = nil
        reorderDragSourceID = nil
        reorderPreview = nil
        reorderDragBaseFrames = [:]
        targetedDropRowID = nil
        targetedDropNodeID = nil
        targetedDropFolderPath = nil
        isTopLevelDropTargeted = false
    }

    private func beginOrderingMode(fallback: DocumentID? = nil) {
        orderingEntryScrollPosition = scrollPosition ?? fallback
        editOperation = .reorder
        isOrderingMode = true
    }

    private func restoreScrollPositionAfterOrderingActivation(
        _ retainedPosition: DocumentID?
    ) {
        guard let retainedPosition else { return }
        Task { @MainActor in
            // EditMode가 시스템 손잡이를 구성한 다음 기존 행을 다시
            // 기준점으로 지정해야 정렬 진입 시 최상단으로 초기화되지 않는다.
            await Task.yield()
            guard isReordering else { return }
            scrollPosition = retainedPosition
            orderingEntryScrollPosition = nil
        }
    }

    @ViewBuilder
    private func binderContextMenu(for node: BinderNode) -> some View {
        if node.fixedCategory == .trash {
            Button("휴지통 비우기", systemImage: "trash", role: .destructive) {
                requestEmptyTrashConfirmation()
            }
        } else if isTrashNode(node) {
            Button("휴지통 복원", systemImage: "arrow.uturn.backward") {
                Task { await model.restoreFromTrash(node) }
            }
            Button("휴지통에서 삭제", systemImage: "trash", role: .destructive) {
                requestPermanentDeleteConfirmation(node)
            }
        } else if isOrderable(node) {
            Button("순서 정렬", systemImage: "line.3.horizontal.decrease.circle") {
                beginOrderingMode(fallback: node.id)
            }
            Divider()
            regularBinderContextMenu(for: node)
        } else if node.fixedCategory == .manuscript {
            commandButton(.addVolume, node: node, systemImage: "books.vertical.fill") {
                Task {
                    if let firstChapter = await model.addNewVolume(in: node) {
                        onSelection(firstChapter)
                    }
                }
            }
            Button("TXT 추출", systemImage: "square.and.arrow.up") {
                onExtractManuscript()
            }
        } else if isManuscriptDescendant(node) {
            commandButton(.rename, node: node, systemImage: "pencil") {
                beginPrompt(.rename(node))
            }
        } else {
            regularBinderContextMenu(for: node)
        }
    }

    @ViewBuilder
    private func regularBinderContextMenu(for node: BinderNode) -> some View {
            if node.isFolder {
                commandButton(.createFolder, node: node, systemImage: "folder.badge.plus") {
                    beginPrompt(.create(kind: .folder, parent: node))
                }
                commandButton(.createText, node: node, systemImage: "doc.badge.plus") {
                    beginPrompt(.create(kind: .text, parent: node))
                }
                Divider()
            }

            commandButton(.rename, node: node, systemImage: "pencil") {
                beginPrompt(.rename(node))
            }
            commandButton(.moveToTrash, node: node, systemImage: "trash", role: .destructive) {
                requestMoveToTrashConfirmation(node)
            }

            let disabledReasons = [
                model.descriptor(.rename, for: node),
                model.descriptor(.moveToTrash, for: node)
            ].compactMap { $0.isEnabled ? nil : $0.denialReason }
            if let reason = disabledReasons.first {
                Divider()
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .disabled(true)
            }
    }

    private func requestMoveToTrashConfirmation(_ node: BinderNode) {
        onTrashConfirmation(
            BinderTrashConfirmationRequest(kind: .move, targetDocumentID: node.id) {
                await model.moveToTrash(node)
            }
        )
    }

    private func requestEmptyTrashConfirmation() {
        onTrashConfirmation(
            BinderTrashConfirmationRequest(kind: .empty, targetDocumentID: nil) {
                await model.emptyTrash()
            }
        )
    }

    private func requestPermanentDeleteConfirmation(_ node: BinderNode) {
        onTrashConfirmation(
            BinderTrashConfirmationRequest(kind: .permanentDelete, targetDocumentID: node.id) {
                await model.permanentlyDelete(node)
            }
        )
    }

    private func isManuscriptDescendant(_ node: BinderNode) -> Bool {
        let manuscriptPath = BinderFixedCategory.manuscript.relativePath.rawValue + "/"
        return node.fixedCategory == nil && node.relativePath.rawValue.hasPrefix(manuscriptPath)
    }

    private func isTrashNode(_ node: BinderNode) -> Bool {
        node.fixedCategory == .trash || node.relativePath.rawValue.hasPrefix(
            BinderFixedCategory.trash.relativePath.rawValue + "/"
        )
    }

    private func isOrderable(_ node: BinderNode) -> Bool {
        node.fixedCategory != .manuscript
            && !isTrashNode(node)
            && !isManuscriptDescendant(node)
    }

    private func isMoveTarget(_ node: BinderNode) -> Bool {
        node.isFolder
            && !isTrashNode(node)
            && node.fixedCategory != .manuscript
            && !isManuscriptDescendant(node)
    }

    private func commandButton(
        _ kind: BinderCommandKind,
        node: BinderNode,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let descriptor = model.descriptor(kind, for: node)
        return Button(role: role, action: action) {
            Label(kind.displayName, systemImage: systemImage)
        }
        .disabled(!descriptor.isEnabled || model.workingDocumentIDs.contains(node.id))
        .help(descriptor.denialReason ?? "")
    }

    private func beginPrompt(_ action: BinderNamePrompt.Action) {
        switch action {
        case .create, .createRootFolder:
            promptName = ""
        case let .rename(node):
            if let chapterName = chapterRenameName(for: node) {
                promptName = chapterName.editableSuffix
                chapterRenamePrompt = ChapterRenamePrompt(node: node, name: chapterName)
                return
            }
            promptName = node.displayName
        }
        namePrompt = BinderNamePrompt(action: action)
    }

    /// 원고 계층의 텍스트 문서라는 모델 정보를 먼저 확인하고, 그 안에서만
    /// 기존 표시 이름의 회차 접두사를 보조 기준으로 사용한다.
    private func chapterRenameName(for node: BinderNode) -> ChapterRenameName? {
        guard node.kind == .text, isManuscriptDescendant(node) else { return nil }
        return ChapterRenameName.parse(displayName: node.displayName)
    }

    private func submitNamePrompt() {
        guard let prompt = namePrompt else { return }
        let typedName = promptName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = typedName.isEmpty ? prompt.defaultName : typedName
        namePrompt = nil
        Task {
            switch prompt.action {
            case let .create(kind, parent):
                await model.create(kind: kind, named: name, in: parent)
            case .createRootFolder:
                await model.createRootFolder(named: name)
            case let .rename(node):
                await model.rename(node, to: name)
            }
        }
    }

    private func iconName(for node: BinderNode) -> String {
        if node.kind == .text {
            return contentState(for: node) == .empty ? "doc" : "doc.text.fill"
        }
        if node.fixedCategory == nil, node.isFolder {
            return node.isExpanded ? "folder.fill" : "folder"
        }
        return switch node.fixedCategory {
        case .manuscript: "doc.text.fill"
        case .characters: "person.2"
        case .settings: "books.vertical"
        case .notes: "note.text"
        case .flow: "point.3.connected.trianglepath.dotted"
        case .foreshadowing: "link"
        case .places: "map"
        case .trash: "trash"
        case nil: node.isExpanded ? "folder.open" : "folder"
        }
    }

    private func iconColor(for node: BinderNode) -> Color {
        if node.fixedCategory == .trash {
            return colorScheme == .dark ? .writerPadWarning : .secondary
        }
        if node.kind == .text {
            return contentState(for: node) == .empty
                ? .writerPadEmptyDocumentTint
                : (colorScheme == .dark ? .writerPadWarning : .writerPadDocumentTint)
        }
        return .accentColor
    }

    private func selectionBackground(for node: BinderNode) -> Color {
        guard model.selectedNodeID == node.id else { return .clear }
        return colorScheme == .dark
            ? Color.writerPadAccent.opacity(0.42)
            : Color.writerPadAccent
    }

    private var appBackground: Color {
        colorScheme == .dark ? .writerPadDarkSurface : Color(uiColor: .systemBackground)
    }

    private func contentState(for node: BinderNode) -> BinderTextContentState {
        contentStateOverrides[node.id] ?? node.contentState
    }

    private func accessibilityLabel(for node: BinderNode) -> String {
        if node.kind == .folder {
            guard model.hasChildren(node) else {
                return "\(node.displayName), 빈 폴더"
            }
            return "\(node.displayName), 폴더, \(node.isExpanded ? "펼쳐짐" : "접힘"), 탭해서 \(node.isExpanded ? "접기" : "펼치기")"
        }
        return contentState(for: node) == .empty
            ? "\(node.displayName), 빈 문서"
            : "\(node.displayName), 작성된 문서"
    }
}

private struct BinderNamePrompt: Identifiable {
    enum Action {
        case create(kind: DocumentKind, parent: BinderNode)
        case createRootFolder
        case rename(BinderNode)
    }

    let id = UUID()
    let action: Action

    var title: String {
        switch action {
        case let .create(kind, _): kind == .folder ? "새 폴더" : "새 문서"
        case .createRootFolder: "새 폴더"
        case .rename: "이름 변경"
        }
    }

    var placeholder: String {
        switch action {
        case let .create(kind, _): kind == .folder ? "새 폴더" : "새 문서"
        case .createRootFolder: "새 폴더"
        case .rename: "새 이름"
        }
    }

    var defaultName: String {
        switch action {
        case let .create(kind, _): kind == .folder ? "새 폴더" : "새 문서"
        case .createRootFolder: "새 폴더"
        case .rename: ""
        }
    }

    var requiresTypedName: Bool {
        if case .rename = action { return true }
        return false
    }

    var message: String? {
        switch action {
        case .create(.text, _): "TXT 확장자는 자동으로 적용됩니다."
        case .create, .createRootFolder, .rename: nil
        }
    }
}

private struct ChapterRenamePrompt: Identifiable {
    let id = UUID()
    let node: BinderNode
    let name: ChapterRenameName
}

private struct ChapterRenameSheet: View {
    let prefix: String
    @Binding var suffix: String
    let onCancel: () -> Void
    let onSave: () -> Void
    @FocusState private var isSuffixFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("회차 제목과 메모")
                    .font(.headline)

                HStack(spacing: 0) {
                    Text(prefix)
                        .foregroundStyle(.secondary)
                    TextField("", text: $suffix)
                        .textFieldStyle(.plain)
                        .focused($isSuffixFocused)
                        .submitLabel(.done)
                        .onSubmit(onSave)
                        .accessibilityLabel("회차 제목과 메모")
                }
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Spacer()
            }
            .padding()
            .navigationTitle("이름 변경")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장", action: onSave)
                }
            }
        }
        .task { isSuffixFocused = true }
    }
}
