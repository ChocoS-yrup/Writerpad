import SwiftUI

struct BackupHistoryView: View {
    let document: DocumentNode
    let backupStore: any BackupStoring
    let restoreCoordinator: DocumentRestoreCoordinator
    let currentText: () -> String
    let onRestored: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [BackupSnapshot] = []
    @State private var selected: BackupSnapshot?
    @State private var preview = ""
    @State private var diff: [BackupDiffLine] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isRestoring = false
    @State private var confirmsRestore = false
    @State private var pendingDelete: BackupSnapshot?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("백업 이력을 불러오는 중")
                } else if snapshots.isEmpty {
                    ContentUnavailableView("백업 이력이 없습니다", systemImage: "archivebox")
                } else {
                    List {
                        Section("스냅샷") {
                            ForEach(snapshots, id: \.id) { snapshot in
                                Button { Task { await select(snapshot) } } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(snapshot.reason.displayName)
                                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if snapshot.isPinned {
                                            Image(systemName: "pin.fill")
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel("보관 지정됨")
                                        }
                                    }
                                }
                                .accessibilityIdentifier("writerpad.backup-snapshot")
                                .swipeActions(edge: .leading) {
                                    Button {
                                        Task { await setPinned(!snapshot.isPinned, snapshot: snapshot) }
                                    } label: {
                                        Label(snapshot.isPinned ? "보관 해제" : "보관 지정", systemImage: snapshot.isPinned ? "pin.slash" : "pin")
                                    }
                                    .tint(.orange)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = snapshot } label: {
                                        Label("백업 삭제", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        if let selected {
                            Section("미리보기") {
                                Text(preview.isEmpty ? "빈 원고" : preview)
                                    .font(.body.monospaced())
                                    .lineLimit(10)
                                ForEach(diff) { line in
                                    Text(line.text)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(line.color)
                                }
                            }
                            Section("선택한 백업") {
                                Button(selected.isPinned ? "보관 지정 해제" : "보관 지정") {
                                    Task { await setPinned(!selected.isPinned, snapshot: selected) }
                                }
                                .accessibilityIdentifier("writerpad.backup-pin")
                                Button("백업 삭제", role: .destructive) { pendingDelete = selected }
                                    .accessibilityIdentifier("writerpad.backup-delete")
                            }
                        }
                    }
                }
            }
            .navigationTitle("백업 이력")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이 백업으로 복원", role: .destructive) { confirmsRestore = true }
                        .disabled(selected == nil || isRestoring)
                }
            }
            .task { await reload() }
            .alert("선택한 백업으로 복원할까요?", isPresented: $confirmsRestore) {
                Button("복원", role: .destructive) { Task { await restore() } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("현재 원고는 복원 전 백업으로 따로 보존됩니다.")
            }
            .alert("선택한 백업을 삭제할까요?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("삭제", role: .destructive) {
                    guard let snapshot = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await delete(snapshot) }
                }
                Button("취소", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("삭제한 백업은 복구할 수 없습니다. 현재 원고는 변경되지 않습니다.")
            }
            .alert("백업 작업을 완료하지 못했습니다", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("확인", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }

    private func reload() async {
        do {
            snapshots = try await backupStore.snapshots(for: document.id, projectID: document.projectID)
            isLoading = false
            if let first = snapshots.first { await select(first) }
        } catch { errorMessage = error.localizedDescription; isLoading = false }
    }

    private func select(_ snapshot: BackupSnapshot) async {
        selected = snapshot
        do {
            let text = try await backupStore.text(for: snapshot)
            let current = currentText()
            let calculatedDiff = await Task.detached {
                BackupDiffLine.make(current: current, backup: text)
            }.value
            guard selected?.id == snapshot.id else { return }
            preview = text
            diff = calculatedDiff
        } catch { errorMessage = error.localizedDescription }
    }

    private func setPinned(_ isPinned: Bool, snapshot: BackupSnapshot) async {
        do {
            let changed = try await backupStore.setPinned(isPinned, snapshot: snapshot)
            if let index = snapshots.firstIndex(where: { $0.id == changed.id }) {
                snapshots[index] = changed
            }
            if selected?.id == changed.id { selected = changed }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ snapshot: BackupSnapshot) async {
        do {
            try await backupStore.delete(snapshot)
            snapshots.removeAll { $0.id == snapshot.id }
            if selected?.id == snapshot.id {
                selected = nil
                preview = ""
                diff = []
                if let first = snapshots.first { await select(first) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        guard let selected else { return }
        isRestoring = true
        do {
            let generation = DispatchTime.now().uptimeNanoseconds
            let result = try await restoreCoordinator.restore(DocumentRestoreRequest(
                document: document, snapshot: selected, currentText: currentText(), saveGeneration: generation
            ))
            onRestored(result.restoredText)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
        isRestoring = false
    }
}

private extension BackupReason {
    var displayName: String {
        switch self {
        case .automaticSave: "자동 저장"; case .editingInterval: "편집 중"; case .documentTransition: "문서 전환"
        case .documentClose: "문서 닫기"; case .beforeStructureChange: "구조 변경 전"; case .beforeRestore: "복원 전"
        case .conflict: "충돌 보존"; case .manual: "수동 백업"
        }
    }
}

private struct BackupDiffLine: Identifiable, Sendable {
    enum Kind { case added, removed, unchanged }
    let id = UUID()
    let kind: Kind
    let text: String
    var color: Color { switch kind { case .added: .green; case .removed: .red; case .unchanged: .secondary } }

    static func make(current: String, backup: String) -> [BackupDiffLine] {
        let old = current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = backup.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rows: [BackupDiffLine] = []
        for change in new.difference(from: old) {
            switch change {
            case let .insert(_, element, _): rows.append(.init(kind: .added, text: "+ " + element))
            case let .remove(_, element, _): rows.append(.init(kind: .removed, text: "- " + element))
            }
        }
        return rows.isEmpty ? [.init(kind: .unchanged, text: "변경 사항 없음")] : rows
    }
}
