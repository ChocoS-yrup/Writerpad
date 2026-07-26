import SwiftUI

struct TrashManagementView: View {
    let projectID: ProjectID
    let documentRepository: any DocumentRepository
    let commands: any BinderCommanding

    @Environment(\.dismiss) private var dismiss
    @State private var documents: [DocumentNode] = []
    @State private var allDocuments: [DocumentNode] = []
    @State private var pendingDelete: DocumentNode?
    @State private var restoreRoute: TrashRestoreRoute?
    @State private var confirmsEmpty = false
    @State private var errorMessage: String?
    @State private var operationMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if documents.isEmpty {
                    ContentUnavailableView("휴지통이 비어 있습니다", systemImage: "trash")
                }
                ForEach(documents, id: \.id) { document in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? document.relativePath.rawValue)
                        if case let .trashed(originalPath, deletedAt) = document.deletionStatus {
                            Text("원래 위치: \(originalPath.rawValue) · \(deletedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("원래 위치로 복원") { Task { await restore(document) } }
                            Button("다른 위치로 복원") { presentRestoreDestinations(for: document) }
                                .accessibilityIdentifier("writerpad.trash-restore-elsewhere")
                            Button("영구 삭제", role: .destructive) { pendingDelete = document }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("휴지통")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("비우기", role: .destructive) { confirmsEmpty = true }.disabled(documents.isEmpty)
                }
            }
            .task { await reload() }
            .sheet(item: $restoreRoute) { route in
                TrashRestoreDestinationView(
                    document: route.document,
                    destinations: route.destinations,
                    onCancel: { restoreRoute = nil },
                    onSelect: { destination in
                        restoreRoute = nil
                        Task { await restore(route.document, toFolderID: destination.id) }
                    }
                )
            }
            .alert("이 항목을 영구 삭제할까요?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("삭제", role: .destructive) { if let document = pendingDelete { Task { await delete(document) } } }
                Button("취소", role: .cancel) {}
            } message: { Text("삭제 후에는 복구할 수 없습니다.") }
            .alert("휴지통을 비울까요?", isPresented: $confirmsEmpty) {
                Button("모두 삭제", role: .destructive) { Task { await empty() } }
                Button("취소", role: .cancel) {}
            } message: { Text("삭제 후에는 복구할 수 없습니다.") }
            .alert("휴지통 작업을 완료하지 못했습니다", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("확인", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .alert("휴지통 작업 결과", isPresented: Binding(
                get: { operationMessage != nil }, set: { if !$0 { operationMessage = nil } }
            )) { Button("확인", role: .cancel) {} } message: { Text(operationMessage ?? "") }
        }
    }

    private func reload() async {
        do {
            let loaded = try await documentRepository.documents(in: projectID)
            allDocuments = loaded
            documents = TrashPresentation.topLevelItems(from: loaded)
        } catch { errorMessage = error.localizedDescription }
    }

    private func presentRestoreDestinations(for document: DocumentNode) {
        let trashPrefix = BinderFixedCategory.trash.relativePath.rawValue + "/"
        let destinations = allDocuments.filter { candidate in
            guard candidate.kind == .folder else { return false }
            guard candidate.relativePath != BinderFixedCategory.trash.relativePath,
                  !candidate.relativePath.rawValue.hasPrefix(trashPrefix)
            else { return false }
            if case .trashed = candidate.deletionStatus { return false }
            if document.kind == .text && candidate.relativePath.rawValue == "메인" { return false }
            return true
        }.sorted { $0.relativePath.rawValue.localizedStandardCompare($1.relativePath.rawValue) == .orderedAscending }
        restoreRoute = TrashRestoreRoute(document: document, destinations: destinations)
    }

    private func restore(_ document: DocumentNode, toFolderID: DocumentID? = nil) async {
        do {
            _ = try await commands.restoreFromTrash(
                documentID: document.id,
                toFolderID: toFolderID,
                projectID: projectID
            )
            await reload()
        }
        catch { errorMessage = error.localizedDescription }
    }
    private func delete(_ document: DocumentNode) async {
        pendingDelete = nil
        do { try await commands.permanentlyDelete(documentID: document.id, projectID: projectID, confirmsPermanentDeletion: true); await reload() }
        catch { errorMessage = error.localizedDescription }
    }
    private func empty() async {
        do {
            let result = try await commands.emptyTrash(projectID: projectID, confirmsPermanentDeletion: true)
            if result.failures.isEmpty {
                operationMessage = "휴지통 항목 \(result.deletedDocumentIDs.count)개를 삭제했습니다."
            } else {
                let failures = result.failures.map(\.message).joined(separator: "\n")
                operationMessage = "성공 \(result.deletedDocumentIDs.count)개 · 실패 \(result.failures.count)개\n\(failures)"
            }
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}

enum TrashPresentation {
    static func topLevelItems(from documents: [DocumentNode]) -> [DocumentNode] {
        let prefix = BinderFixedCategory.trash.relativePath.rawValue + "/"
        return documents.filter { document in
            guard case .trashed = document.deletionStatus else { return false }
            let path = document.relativePath.rawValue
            guard path.hasPrefix(prefix) else { return false }
            let remainder = path.dropFirst(prefix.count)
            return !remainder.isEmpty && !remainder.contains("/")
        }.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

private struct TrashRestoreRoute: Identifiable {
    let document: DocumentNode
    let destinations: [DocumentNode]
    var id: DocumentID { document.id }
}

private struct TrashRestoreDestinationView: View {
    let document: DocumentNode
    let destinations: [DocumentNode]
    let onCancel: () -> Void
    let onSelect: (DocumentNode) -> Void

    var body: some View {
        NavigationStack {
            List(destinations, id: \.id) { destination in
                Button { onSelect(destination) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(destination.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? destination.relativePath.rawValue)
                        Text(destination.relativePath.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if destinations.isEmpty {
                    ContentUnavailableView("복원할 수 있는 폴더가 없습니다", systemImage: "folder.badge.questionmark")
                }
            }
            .navigationTitle("‘\(document.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? "항목")’ 복원 위치")
            .accessibilityIdentifier("writerpad.trash-restore-destinations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                }
            }
        }
    }
}
