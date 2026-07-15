import SwiftUI

struct BinderPanel: View {
    let projectID: ProjectID
    @StateObject private var model: BinderViewModel

    init(projectID: ProjectID, repository: any BinderRepository) {
        self.projectID = projectID
        _model = StateObject(wrappedValue: BinderViewModel(repository: repository))
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
                    binderRow(row)
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
