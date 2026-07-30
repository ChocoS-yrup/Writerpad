import SwiftUI

struct BackupHistoryView: View {
    let document: DocumentNode
    let backupStore: any BackupStoring
    let restoreCoordinator: DocumentRestoreCoordinator
    let currentText: () -> String
    let currentUTF16Length: () -> Int
    let onRestored: (String) -> Void
    let onCopyCreated: (DocumentBackupCopyResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [BackupSnapshot] = []
    @State private var selected: BackupSnapshot?
    @State private var preview = ""
    @State private var diff: [BackupDiffLine] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isPreviewLoading = false
    @State private var isRestoring = false
    @State private var isCopying = false
    @State private var confirmsRestore = false
    @State private var createdCopyPath: RelativeDocumentPath?
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
                            Section("복원 방식") {
                                Button(role: .destructive) {
                                    confirmsRestore = true
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("현재 문서에 복원")
                                            Text("현재 본문을 교체하고 모든 기기에 동기화합니다.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "arrow.counterclockwise")
                                    }
                                }
                                .accessibilityIdentifier("writerpad.backup-restore-current")

                                Button {
                                    Task { await restoreAsCopy() }
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("사본으로 복원")
                                            Text(copyDestinationDescription)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                }
                                .accessibilityIdentifier("writerpad.backup-restore-copy")

                                if isRestoring || isCopying {
                                    ProgressView(isRestoring ? "현재 문서 복원 중" : "백업 사본 생성 중")
                                }
                            }
                            .disabled(isRestoring || isCopying)

                            Section("미리보기") {
                                if isPreviewLoading {
                                    ProgressView("미리보기를 준비하는 중")
                                } else {
                                    Text(preview.isEmpty ? "빈 원고" : preview)
                                        .font(.body.monospaced())
                                        .lineLimit(10)
                                    ForEach(diff) { line in
                                        Text(line.text)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(line.color)
                                    }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                        .disabled(isRestoring || isCopying)
                }
            }
            .task { await reload() }
            .alert("현재 문서에 복원할까요?", isPresented: $confirmsRestore) {
                Button("현재 문서에 복원", role: .destructive) {
                    Task { await restore() }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text(
                    "선택한 백업이 이 문서의 최신본이 되어 다른 기기에도 동기화됩니다. 현재 원고는 ‘복원 전’ 백업으로 따로 보존됩니다."
                )
            }
            .alert("백업 사본을 만들었습니다", isPresented: Binding(
                get: { createdCopyPath != nil },
                set: { if !$0 { createdCopyPath = nil } }
            )) {
                Button("확인", role: .cancel) { createdCopyPath = nil }
            } message: {
                Text(
                    "현재 문서는 변경하지 않았습니다.\n저장 위치: \(createdCopyPath?.rawValue ?? "")"
                )
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
        } catch { errorMessage = error.localizedDescription; isLoading = false }
    }

    private func select(_ snapshot: BackupSnapshot) async {
        selected = snapshot
        preview = ""
        diff = []
        isPreviewLoading = true
        do {
            let text = try await backupStore.text(for: snapshot)
            let currentLength = currentUTF16Length()
            let presentation = await Task.detached(priority: .utility) {
                BackupPreviewContent(backup: text)
            }.value
            let calculatedDiff: [BackupDiffLine]
            if presentation.allowsDetailedDiff,
               currentLength <= BackupPreviewContent.maximumDiffUTF16Length {
                let current = currentText()
                calculatedDiff = await Task.detached(priority: .utility) {
                    BackupDiffLine.make(current: current, backup: text)
                }.value
            } else {
                calculatedDiff = [
                    .init(
                        kind: .unchanged,
                        text: "대용량 원고는 UI 응답성을 위해 앞부분만 미리보고 diff를 생략합니다."
                    )
                ]
            }
            guard selected?.id == snapshot.id else { return }
            preview = presentation.preview
            diff = calculatedDiff
            isPreviewLoading = false
        } catch {
            guard selected?.id == snapshot.id else { return }
            isPreviewLoading = false
            errorMessage = error.localizedDescription
        }
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
                isPreviewLoading = false
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

    private func restoreAsCopy() async {
        guard let selected else { return }
        isCopying = true
        do {
            let result = try await restoreCoordinator.restoreAsCopy(
                DocumentBackupCopyRequest(
                    document: document,
                    snapshot: selected,
                    saveGeneration: DispatchTime.now().uptimeNanoseconds
                )
            )
            onCopyCreated(result)
            createdCopyPath = result.document.relativePath
        } catch {
            errorMessage = error.localizedDescription
        }
        isCopying = false
    }

    private var copyDestinationDescription: String {
        let components = document.relativePath.rawValue.split(separator: "/")
        if components.count >= 2,
           String(components[0]).precomposedStringWithCanonicalMapping == "메인",
           String(components[1]).precomposedStringWithCanonicalMapping == "원고" {
            return "현재 문서는 그대로 두고 메모장에 새 TXT를 만듭니다."
        }
        return "현재 문서는 그대로 두고 같은 폴더에 새 TXT를 만듭니다."
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

struct BackupPreviewContent: Equatable, Sendable {
    static let maximumPreviewUTF16Length = 12_000
    static let maximumDiffUTF16Length = 262_144

    let preview: String
    let allowsDetailedDiff: Bool

    init(backup: String) {
        let source = backup as NSString
        allowsDetailedDiff = source.length <= Self.maximumDiffUTF16Length
        guard source.length > Self.maximumPreviewUTF16Length else {
            preview = backup
            return
        }
        let proposedRange = NSRange(
            location: 0,
            length: Self.maximumPreviewUTF16Length
        )
        let safeRange = source.rangeOfComposedCharacterSequences(for: proposedRange)
        preview = source.substring(with: safeRange) + "\n… (일부 미리보기)"
    }
}

struct BackupDiffLine: Identifiable, Sendable {
    enum Kind { case added, removed, unchanged }
    private static let maximumComparedUTF16Length = 65_536
    private static let maximumComparedLines = 400

    let id = UUID()
    let kind: Kind
    let text: String
    var color: Color { switch kind { case .added: .green; case .removed: .red; case .unchanged: .secondary } }

    static func make(current: String, backup: String) -> [BackupDiffLine] {
        let old = boundedLines(current)
        let new = boundedLines(backup)
        var rows: [BackupDiffLine] = []
        for change in new.difference(from: old) {
            switch change {
            case let .insert(_, element, _): rows.append(.init(kind: .added, text: "+ " + element))
            case let .remove(_, element, _): rows.append(.init(kind: .removed, text: "- " + element))
            }
        }
        return rows.isEmpty ? [.init(kind: .unchanged, text: "변경 사항 없음")] : rows
    }

    private static func boundedLines(_ text: String) -> [String] {
        let source = text as NSString
        let length = min(source.length, maximumComparedUTF16Length)
        let range = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: 0, length: length)
        )
        return source.substring(with: range)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maximumComparedLines)
            .map(String.init)
    }
}
