import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ProjectWorkspaceView(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter,
            binderRepository: environment.binderRepository,
            binderCommands: environment.binderCommands
        )
            .task {
                await environment.futureChangeNotifier.record(.appLaunched)
            }
    }
}

private struct ProjectWorkspaceView: View {
    @StateObject private var model: ProjectListModel
    @State private var isCreating = false
    @State private var newProjectName = ""
    @State private var renameTarget: ManagedProject?
    @State private var renameText = ""
    @State private var deleteTarget: ManagedProject?
    @State private var isSelectingImportFolder = false
    private let binderRepository: any BinderRepository
    private let binderCommands: any BinderCommanding

    init(
        projectManager: any ProjectManaging,
        projectImporter: any ProjectImporting,
        binderRepository: any BinderRepository,
        binderCommands: any BinderCommanding
    ) {
        self.binderRepository = binderRepository
        self.binderCommands = binderCommands
        _model = StateObject(
            wrappedValue: ProjectListModel(
                projectManager: projectManager,
                projectImporter: projectImporter
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedProjectID) {
                ForEach(model.projects) { project in
                    projectRow(project)
                        .tag(project.id)
                        .contextMenu {
                            projectContextMenu(project)
                        }
                }
                .onMove { offsets, destination in
                    Task { await model.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .overlay {
                if model.projects.isEmpty, !model.isWorking {
                    ContentUnavailableView(
                        "작품이 없습니다",
                        systemImage: "books.vertical",
                        description: Text("+ 버튼을 눌러 첫 작품을 만드세요.")
                    )
                }
            }
            .navigationTitle("WriterPad")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button("Windows 작품 가져오기", systemImage: "square.and.arrow.down") {
                        isSelectingImportFolder = true
                    }
                    .disabled(model.isWorking)
                    Button("새 작품", systemImage: "plus") {
                        newProjectName = ""
                        isCreating = true
                    }
                    .disabled(model.isWorking)
                }
            }
        } detail: {
            if let project = model.selectedProject {
                HStack(spacing: 0) {
                    BinderPanel(
                        projectID: project.id,
                        repository: binderRepository,
                        commands: binderCommands
                    )
                    .frame(minWidth: 250, idealWidth: 310, maxWidth: 380)

                    Divider()

                    VStack(spacing: 14) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text(project.name)
                            .font(.title2.weight(.semibold))
                        Text("바인더 항목을 펼쳐 작품 구조를 확인할 수 있습니다.\n원고 편집기는 후속 단계에서 연결됩니다.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if project.isDeletionRequested {
                            Label("삭제 대기 중", systemImage: "trash")
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            } else {
                ContentUnavailableView(
                    "작품을 선택하세요",
                    systemImage: "square.and.pencil",
                    description: Text("로컬 집필 환경이 준비되었습니다.")
                )
                .accessibilityIdentifier("writerpad.empty-state")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { await model.load() }
        .fileImporter(
            isPresented: $isSelectingImportFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let sourceURL = urls.first else { return }
                Task { await model.inspectImport(at: sourceURL) }
            case let .failure(error):
                model.present(error: error)
            }
        }
        .sheet(
            item: $model.importReport,
            onDismiss: { model.dismissImportReport() }
        ) { report in
            ImportReportView(
                report: report,
                isWorking: model.isWorking,
                onCancel: { model.dismissImportReport() },
                onImport: { Task { await model.confirmImport() } }
            )
        }
        .onChange(of: model.selectedProjectID) { _, id in
            Task { await model.select(id) }
        }
        .alert("새 작품", isPresented: $isCreating) {
            TextField("작품 이름", text: $newProjectName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                Task { await model.create(named: newProjectName) }
            }
        } message: {
            Text("Windows에서도 안전하게 사용할 수 있는 이름을 입력하세요.")
        }
        .alert(
            "작품 이름 변경",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("새 이름", text: $renameText)
            Button("취소", role: .cancel) { renameTarget = nil }
            Button("변경") {
                guard let target = renameTarget else { return }
                renameTarget = nil
                Task { await model.rename(target, to: renameText) }
            }
        }
        .confirmationDialog(
            "‘\(deleteTarget?.name ?? "")’ 작품을 삭제 대기 상태로 옮길까요?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제 대기로 이동", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await model.confirmDeletion(of: target) }
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("이 단계에서는 실제 폴더를 지우지 않습니다. 후속 휴지통 정책이 처리할 수 있도록 상태만 기록합니다.")
        }
        .alert(
            "작업을 완료하지 못했습니다",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("확인") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류")
        }
        .alert(
            "가져오기 완료",
            isPresented: Binding(
                get: { model.importSuccessMessage != nil },
                set: { if !$0 { model.clearImportSuccess() } }
            )
        ) {
            Button("확인") { model.clearImportSuccess() }
        } message: {
            Text(model.importSuccessMessage ?? "작품을 가져왔습니다.")
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ManagedProject) -> some View {
        HStack {
            Label(project.name, systemImage: "book.closed")
            Spacer()
            if project.isDeletionRequested {
                Image(systemName: "trash")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("삭제 대기 중")
            }
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ project: ManagedProject) -> some View {
        Button("이름 변경", systemImage: "pencil") {
            renameText = project.name
            renameTarget = project
        }
        if project.isDeletionRequested {
            Button("삭제 대기 취소", systemImage: "arrow.uturn.backward") {
                Task { await model.cancelDeletion(of: project) }
            }
        } else {
            Button("삭제…", systemImage: "trash", role: .destructive) {
                deleteTarget = project
            }
        }
    }
}

private struct ImportReportView: View {
    let report: ImportReport
    let isWorking: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("검사 결과") {
                    LabeledContent("작품 이름", value: report.proposedProjectName)
                    LabeledContent("폴더", value: "\(report.directoryCount)개")
                    LabeledContent("파일", value: "\(report.fileCount)개")
                    LabeledContent("TXT 파일", value: "\(report.textFileCount)개")
                }

                if report.issues.isEmpty {
                    Section {
                        Label("가져올 수 있습니다", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    issueSection(
                        title: "치명 오류 \(report.fatalIssues.count)개",
                        issues: report.fatalIssues,
                        color: .red
                    )
                    issueSection(
                        title: "확인할 경고 \(report.warnings.count)개",
                        issues: report.warnings,
                        color: .orange
                    )
                }

                Section {
                    Text("원본 폴더는 수정하지 않습니다. 플롯·메인 스토리 틀·레거시 백업은 일반 사용자 폴더로 그대로 보존됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Windows 작품 검사")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onCancel)
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(report.warnings.isEmpty ? "가져오기" : "경고 확인 후 가져오기") {
                        onImport()
                    }
                    .disabled(!report.canImport || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("가져오는 중…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @ViewBuilder
    private func issueSection(
        title: String,
        issues: [ImportIssue],
        color: Color
    ) -> some View {
        if !issues.isEmpty {
            Section(title) {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.message)
                        if !issue.relativePath.isEmpty {
                            Text(issue.relativePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(color)
                }
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(try! AppEnvironment.testing())
}
