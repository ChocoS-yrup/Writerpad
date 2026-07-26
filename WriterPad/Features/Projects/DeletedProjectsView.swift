import SwiftUI

struct DeletedProjectsView: View {
    @Environment(\.dismiss) private var dismiss

    let projects: [ManagedProject]
    let isWorking: Bool
    let onRestore: (ManagedProject) -> Void
    let onPermanentlyDelete: (ManagedProject) -> Void

    @State private var permanentDeleteTarget: ManagedProject?

    var body: some View {
        NavigationStack {
            List {
                ForEach(projects) { project in
                    deletedProjectRow(project)
                }
            }
            .overlay {
                if projects.isEmpty, !isWorking {
                    ContentUnavailableView(
                        "삭제된 작품이 없습니다",
                        systemImage: "trash",
                        description: Text("작품 목록에서 삭제한 작품이 여기에 표시됩니다.")
                    )
                }
            }
            .navigationTitle("삭제 목록")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .disabled(isWorking)
        }
        .confirmationDialog(
            "‘\(permanentDeleteTarget?.name ?? "")’ 작품을 영구 삭제할까요?",
            isPresented: Binding(
                get: { permanentDeleteTarget != nil },
                set: { if !$0 { permanentDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("영구 삭제", role: .destructive) {
                guard let target = permanentDeleteTarget else { return }
                permanentDeleteTarget = nil
                onPermanentlyDelete(target)
            }
            Button("취소", role: .cancel) { permanentDeleteTarget = nil }
        } message: {
            Text("원고, 보조 문서, 백업과 저장된 화면 상태가 모두 삭제되며 복구할 수 없습니다.")
        }
    }

    private func deletedProjectRow(_ project: ManagedProject) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                if let deletedAt = deletedAt(for: project) {
                    Text(deletedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("복원", systemImage: "arrow.uturn.backward") {
                onRestore(project)
            }
            .buttonStyle(.bordered)

            Button("삭제", systemImage: "trash", role: .destructive) {
                permanentDeleteTarget = project
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("작품 목록으로 복원", systemImage: "arrow.uturn.backward") {
                onRestore(project)
            }
            Button("영구 삭제…", systemImage: "trash", role: .destructive) {
                permanentDeleteTarget = project
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func deletedAt(for project: ManagedProject) -> Date? {
        guard case let .deletedList(at) = project.lifecycleState else { return nil }
        return at
    }
}
