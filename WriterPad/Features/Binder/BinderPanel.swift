import SwiftUI

struct BinderPanel: View {
    let projectID: ProjectID
    @StateObject private var model: BinderViewModel
    @State private var namePrompt: BinderNamePrompt?
    @State private var promptName = ""
    @State private var trashTarget: BinderNode?

    init(
        projectID: ProjectID,
        repository: any BinderRepository,
        commands: any BinderCommanding
    ) {
        self.projectID = projectID
        _model = StateObject(
            wrappedValue: BinderViewModel(repository: repository, commands: commands)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("바인더")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.roots.isEmpty, model.errorMessage == nil {
                ProgressView("바인더 불러오는 중…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleRows) { row in
                    commandRow(row)
                        .listRowInsets(
                            EdgeInsets(
                                top: 7,
                                leading: CGFloat(8 + row.depth * 18),
                                bottom: 7,
                                trailing: 8
                            )
                        )
                        .listRowBackground(
                            model.selectedNodeID == row.node.id
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("writerpad.binder-list")
            }

            if let errorMessage = model.errorMessage {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                        .font(.footnote)
                    Spacer()
                    Button("닫기") { model.clearError() }
                        .font(.footnote)
                }
                .foregroundStyle(.red)
                .padding(12)
            }
        }
        .task(id: projectID) {
            await model.load(projectID: projectID)
        }
        .alert(
            namePrompt?.title ?? "이름 입력",
            isPresented: Binding(
                get: { namePrompt != nil },
                set: { if !$0 { namePrompt = nil } }
            )
        ) {
            TextField(namePrompt?.placeholder ?? "이름", text: $promptName)
            Button("취소", role: .cancel) { namePrompt = nil }
            Button("확인") { submitNamePrompt() }
                .disabled(promptName.isEmpty)
        } message: {
            if let message = namePrompt?.message { Text(message) }
        }
        .confirmationDialog(
            "휴지통으로 이동할까요?",
            isPresented: Binding(
                get: { trashTarget != nil },
                set: { if !$0 { trashTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("휴지통으로 이동", role: .destructive) {
                guard let target = trashTarget else { return }
                trashTarget = nil
                Task { await model.moveToTrash(target) }
            }
            Button("취소", role: .cancel) { trashTarget = nil }
        } message: {
            Text("즉시 영구 삭제되지 않고 원래 위치가 기록됩니다.")
        }
    }

    @ViewBuilder
    private func commandRow(_ row: BinderVisibleRow) -> some View {
        let base = binderRow(row)
            .contextMenu { binderContextMenu(for: row.node) }
            .dropDestination(for: String.self) { items, _ in
                guard row.node.isFolder,
                      let rawID = items.first,
                      let uuid = UUID(uuidString: rawID)
                else {
                    return false
                }
                Task {
                    await model.move(
                        DocumentID(rawValue: uuid),
                        to: row.node
                    )
                }
                return true
            }

        if model.descriptor(.move, for: row.node).isEnabled {
            base.draggable(row.node.id.rawValue.uuidString)
        } else {
            base
        }
    }

    private func binderRow(_ row: BinderVisibleRow) -> some View {
        HStack(spacing: 7) {
            if row.node.isFolder {
                Button {
                    Task { await model.toggleExpansion(of: row.node) }
                } label: {
                    if model.loadingFolderIDs.contains(row.node.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: row.node.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    row.node.isExpanded
                        ? "\(row.node.displayName) 접기"
                        : "\(row.node.displayName) 펼치기"
                )
            } else {
                Color.clear.frame(width: 12, height: 12)
            }

            Image(systemName: iconName(for: row.node))
                .foregroundStyle(iconColor(for: row.node))
            Text(row.node.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if row.node.contentState == .empty {
                Text("빈 문서")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(row.node) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: row.node))
    }

    @ViewBuilder
    private func binderContextMenu(for node: BinderNode) -> some View {
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
            trashTarget = node
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
        case .create:
            promptName = ""
        case let .rename(node):
            promptName = node.displayName
        }
        namePrompt = BinderNamePrompt(action: action)
    }

    private func submitNamePrompt() {
        guard let prompt = namePrompt else { return }
        let name = promptName
        namePrompt = nil
        Task {
            switch prompt.action {
            case let .create(kind, parent):
                await model.create(kind: kind, named: name, in: parent)
            case let .rename(node):
                await model.rename(node, to: name)
            }
        }
    }

    private func iconName(for node: BinderNode) -> String {
        if node.kind == .text { return "doc.text" }
        return switch node.fixedCategory {
        case .manuscript: "doc.text.fill"
        case .characters: "person.2"
        case .settings: "books.vertical"
        case .notes: "note.text"
        case .flow: "point.3.connected.trianglepath.dotted"
        case .foreshadowing: "link"
        case .places: "map"
        case .trash: "trash"
        case nil: "folder"
        }
    }

    private func iconColor(for node: BinderNode) -> Color {
        node.fixedCategory == .trash ? .orange : .accentColor
    }

    private func accessibilityLabel(for node: BinderNode) -> String {
        if node.kind == .folder { return "\(node.displayName), 폴더" }
        return node.contentState == .empty
            ? "\(node.displayName), 빈 문서"
            : "\(node.displayName), 작성된 문서"
    }
}

private struct BinderNamePrompt: Identifiable {
    enum Action {
        case create(kind: DocumentKind, parent: BinderNode)
        case rename(BinderNode)
    }

    let id = UUID()
    let action: Action

    var title: String {
        switch action {
        case let .create(kind, _): kind == .folder ? "새 폴더" : "새 문서"
        case .rename: "이름 변경"
        }
    }

    var placeholder: String {
        switch action {
        case let .create(kind, _): kind == .folder ? "폴더 이름" : "문서 이름"
        case .rename: "새 이름"
        }
    }

    var message: String? {
        switch action {
        case let .create(.text, _): "TXT 확장자는 자동으로 적용됩니다."
        case .create, .rename: nil
        }
    }
}
