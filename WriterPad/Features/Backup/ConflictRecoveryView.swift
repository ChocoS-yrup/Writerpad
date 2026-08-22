import SwiftUI

struct ConflictRecoveryView: View {
    private struct Entry: Identifiable {
        let package: ConflictRecoveryPackage
        let exportURL: URL?
        var id: UUID { package.id }
    }

    let projectID: ProjectID
    let store: ConflictRecoveryStore
    let documentRepository: any DocumentRepository
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var restorePackage: ConflictRecoveryPackage?
    @State private var restoreName = ""
    @State private var discardPackage: ConflictRecoveryPackage?
    @State private var deletePayloadPackage: ConflictRecoveryPackage?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("보존된 항목을 확인하는 중…")
                } else if entries.isEmpty {
                    ContentUnavailableView(
                        "보존된 항목 없음",
                        systemImage: "archivebox",
                        description: Text("원격 삭제로 보존된 로컬 자료가 없습니다.")
                    )
                } else {
                    List(entries) { entry in
                        recoveryRow(entry)
                    }
                }
            }
            .navigationTitle("충돌 복구 백업")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.15).ignoresSafeArea()
                        ProgressView().controlSize(.large)
                    }
                }
            }
            .task { await reload() }
            .alert(
                "새 폴더로 복구",
                isPresented: Binding(
                    get: { restorePackage != nil },
                    set: { if !$0 { restorePackage = nil } }
                )
            ) {
                TextField("새 폴더 이름", text: $restoreName)
                Button("취소", role: .cancel) { restorePackage = nil }
                Button("복구") {
                    guard let package = restorePackage else { return }
                    restorePackage = nil
                    Task { await restore(package, name: restoreName) }
                }
            } message: {
                Text("기존 tombstone UUID는 쓰지 않고 모든 폴더와 TXT에 새 UUID를 부여합니다.")
            }
            .confirmationDialog(
                "복구하지 않고 로컬 보관을 삭제할까요?",
                isPresented: Binding(
                    get: { discardPackage != nil },
                    set: { if !$0 { discardPackage = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("백업 삭제", role: .destructive) {
                    guard let package = discardPackage else { return }
                    discardPackage = nil
                    Task { await discard(package) }
                }
                Button("취소", role: .cancel) { discardPackage = nil }
            } message: {
                Text("서버 삭제는 그대로 유지되고 이 기기에 보존된 TXT만 삭제됩니다.")
            }
            .confirmationDialog(
                "복구가 끝난 백업 파일을 삭제할까요?",
                isPresented: Binding(
                    get: { deletePayloadPackage != nil },
                    set: { if !$0 { deletePayloadPackage = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("백업 파일 삭제", role: .destructive) {
                    guard let package = deletePayloadPackage else { return }
                    deletePayloadPackage = nil
                    Task { await deletePayload(package) }
                }
                Button("취소", role: .cancel) { deletePayloadPackage = nil }
            }
            .alert(
                "충돌 복구를 완료하지 못했습니다",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "알 수 없는 오류")
            }
        }
    }

    @ViewBuilder
    private func recoveryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.package.displayName).font(.headline)
                    Text(statusText(entry.package))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.package.fileCount) TXT")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                if entry.package.state == .sourceResolved {
                    Button("새 폴더로 복구", systemImage: "arrow.uturn.backward.circle") {
                        restoreName = entry.package.displayName + " (복구됨)"
                        restorePackage = entry.package
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let exportURL = entry.exportURL,
                   entry.package.payloadDeletedAt == nil {
                    ShareLink(item: exportURL) {
                        Label("TXT 내보내기", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if entry.package.state == .sourceResolved {
                    Button("삭제", role: .destructive) {
                        discardPackage = entry.package
                    }
                } else if entry.package.state == .restored,
                          entry.package.payloadDeletedAt == nil {
                    Button("백업 정리", role: .destructive) {
                        deletePayloadPackage = entry.package
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ package: ConflictRecoveryPackage) -> String {
        switch package.state {
        case .preparing: "보존 준비 중"
        case .ready: "보존 완료 · 원본 작업 정리 대기"
        case .sourceResolved: "원격 삭제로 보존됨 · 결정 대기"
        case .restoreEnqueued: "새 신원으로 복구됨 · 서버 반영 중"
        case .restored: package.payloadDeletedAt == nil
            ? "서버 반영 완료 · 백업 유지 중"
            : "서버 반영 완료 · 백업 파일 정리됨"
        case .discarded: "사용자가 백업을 삭제함"
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        do {
            let packages = try await store.packages(localProjectID: projectID)
                .filter { $0.state != .discarded }
            var loaded: [Entry] = []
            for package in packages {
                loaded.append(
                    Entry(
                        package: package,
                        exportURL: package.payloadDeletedAt == nil
                            ? try? await store.exportURL(for: package)
                            : nil
                    )
                )
            }
            entries = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func restore(
        _ package: ConflictRecoveryPackage,
        name: String
    ) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let manifest = try await store.validatedManifest(for: package)
            let parentPath = (manifest.sourceRootRelativePath as NSString)
                .deletingLastPathComponent
                .precomposedStringWithCanonicalMapping
            let documents = try await documentRepository.documents(in: projectID)
            guard let parent = documents.first(where: {
                $0.kind == .folder
                    && $0.relativePath.rawValue.precomposedStringWithCanonicalMapping
                        == parentPath
            }) else { throw ConflictRecoveryStoreError.targetFolderMissing }
            _ = try await store.restoreAsNewFolder(
                package: package,
                targetParentID: parent.id,
                rootDisplayName: name
            )
            onChanged()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func discard(_ package: ConflictRecoveryPackage) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.discard(package: package, confirmsDeletion: true)
            onChanged()
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func deletePayload(_ package: ConflictRecoveryPackage) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.deleteRestoredPayload(
                package: package,
                confirmsDeletion: true
            )
            onChanged()
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }
}
