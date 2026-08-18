import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("writerpad.restore-last-project-on-launch")
    private var restoresLastProjectOnLaunch = true
    @StateObject private var model: ProjectListModel
    @State private var projectEditMode: EditMode = .inactive
    @State private var isCreating = false
    @State private var isSubmittingNewProject = false
    @State private var newProjectName = ""
    @State private var highlightedProjectID: ProjectID?
    @State private var renameTarget: ManagedProject?
    @State private var renameText = ""
    @State private var deleteTarget: ManagedProject?
    @State private var deletedListTarget: ManagedProject?
    @State private var isSelectingImportFolder = false
    @State private var isSelectingBackupPackage = false
    @State private var isShowingSettings = false
    @State private var isShowingDeletedProjects = false
    private let binderRepository: any BinderRepository
    private let binderCommands: any BinderCommanding
    private let documentRepository: any DocumentRepository
    private let documentStore: any LocalDocumentStoring
    private let searchService: any Searching
    private let exporter: any Exporting
    private let backupStore: any BackupStoring
    private let backupPolicyStore: any BackupPolicyStoring
    private let restoreCoordinator: DocumentRestoreCoordinator
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let futureChangeNotifier: any FutureChangeNotifying
    private let projectManager: any ProjectManaging
    private let authenticationService: any AuthenticationServicing
    private let projectBindingService: any ProjectBindingServicing
    private let syncDispatcher: SyncV2Dispatcher?
    private let conflictResolutionService:
        (any SyncV2ConflictResolving)?
    private let snapshotPullService: SyncV2SnapshotPullService?
    private let realtimeTrigger: (any SyncV2RealtimeTriggering)?
    private let backgroundSyncCoordinator:
        SyncV2BackgroundSyncCoordinator?
    private let editLeaseManager: EditLeaseManager?
    @Binding private var isDarkMode: Bool
    @Binding private var smartPairsEnabled: Bool

    init(
        projectManager: any ProjectManaging,
        projectImporter: any ProjectImporting,
        binderRepository: any BinderRepository,
        binderCommands: any BinderCommanding,
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring,
        searchService: any Searching,
        exporter: any Exporting,
        backupStore: any BackupStoring,
        backupPolicyStore: any BackupPolicyStoring,
        restoreCoordinator: DocumentRestoreCoordinator,
        workspaceStateRepository: any WorkspaceStateRepository,
        futureChangeNotifier: any FutureChangeNotifying,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        conflictResolutionService:
            (any SyncV2ConflictResolving)? = nil,
        snapshotPullService: SyncV2SnapshotPullService? = nil,
        realtimeTrigger: (any SyncV2RealtimeTriggering)? = nil,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: EditLeaseManager? = nil,
        isDarkMode: Binding<Bool>,
        smartPairsEnabled: Binding<Bool>
    ) {
        self.binderRepository = binderRepository
        self.binderCommands = binderCommands
        self.documentRepository = documentRepository
        self.documentStore = documentStore
        self.searchService = searchService
        self.exporter = exporter
        self.backupStore = backupStore
        self.backupPolicyStore = backupPolicyStore
        self.restoreCoordinator = restoreCoordinator
        self.workspaceStateRepository = workspaceStateRepository
        self.futureChangeNotifier = futureChangeNotifier
        self.projectManager = projectManager
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.conflictResolutionService = conflictResolutionService
        self.snapshotPullService = snapshotPullService
        self.realtimeTrigger = realtimeTrigger
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        _isDarkMode = isDarkMode
        _smartPairsEnabled = smartPairsEnabled
        _model = StateObject(
            wrappedValue: ProjectListModel(
                projectManager: projectManager,
                projectImporter: projectImporter,
                authenticationService: authenticationService,
                projectBindingService: projectBindingService
            )
        )
    }

    var body: some View {
        Group {
            if let project = model.selectedProject {
                NavigationStack {
                    WritingWorkspaceShell(
                        project: project,
                        repository: binderRepository,
                        commands: binderCommands,
                        documentRepository: documentRepository,
                        documentStore: documentStore,
                        searchService: searchService,
                        exporter: exporter,
                        backupStore: backupStore,
                        backupPolicyStore: backupPolicyStore,
                        restoreCoordinator: restoreCoordinator,
                        workspaceStateRepository: workspaceStateRepository,
                        futureChangeNotifier: futureChangeNotifier,
                        authenticationService: authenticationService,
                        projectBindingService: projectBindingService,
                        syncDispatcher: syncDispatcher,
                        conflictResolutionService:
                            conflictResolutionService,
                        snapshotPullService: snapshotPullService,
                        realtimeTrigger: realtimeTrigger,
                        editLeaseManager: editLeaseManager,
                        isShowingSettings: $isShowingSettings,
                        smartPairsEnabled: $smartPairsEnabled,
                        onChangeProject: { await model.returnToLibrary() }
                    )
                    .id(project.id)
                }
            } else {
                NavigationStack {
                    projectLibrary
                }
            }
        }
        .task(id: model.selectedProjectID) {
            await syncDispatcher?.prioritizeProject(
                model.selectedProjectID
            )
            await backgroundSyncCoordinator?.prioritizeProject(
                model.selectedProjectID
            )
        }
        .sheet(isPresented: $isShowingSettings) {
            AppearanceSettingsView(
                isDarkMode: $isDarkMode,
                smartPairsEnabled: $smartPairsEnabled,
                projectID: model.selectedProject?.id,
                backupStore: backupStore,
                backupPolicyStore: backupPolicyStore,
                projectManager: projectManager,
                authenticationService: authenticationService,
                projectBindingService: projectBindingService,
                syncDispatcher: syncDispatcher,
                backgroundSyncCoordinator:
                    backgroundSyncCoordinator,
                editLeaseManager: editLeaseManager
            )
        }
        .sheet(isPresented: $isShowingDeletedProjects) {
            DeletedProjectsView(
                projects: model.deletedProjects,
                isWorking: model.isWorking,
                onRestore: { project in
                    Task { await model.restoreFromDeletedList(project) }
                },
                onPermanentlyDelete: { project in
                    Task { await model.permanentlyDelete(project) }
                }
            )
        }
        .background(appBackground)
        .task {
            await model.load(opensLastProject: restoresLastProjectOnLaunch)
        }
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
        .fileImporter(
            isPresented: $isSelectingBackupPackage,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let packageURL = urls.first else { return }
                Task { await model.restoreBackup(at: packageURL) }
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
        .background {
            NewProjectAlertPresenter(
                isPresented: $isCreating,
                name: $newProjectName,
                isSubmitting: isSubmittingNewProject,
                onSubmit: submitNewProject(named:)
            )
        }
        .alert(
            "작품 이름 변경",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("새 이름", text: $renameText)
                .submitLabel(.done)
                .onSubmit(submitProjectRename)
            Button("취소", role: .cancel) { renameTarget = nil }
                .keyboardShortcut(.cancelAction)
            Button("변경") {
                submitProjectRename()
            }
            .disabled(
                renameText.isEmpty
                    || renameText == renameTarget?.name
                    || model.isWorking
            )
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
        .confirmationDialog(
            "‘\(deletedListTarget?.name ?? "")’ 작품을 삭제 목록으로 옮길까요?",
            isPresented: Binding(
                get: { deletedListTarget != nil },
                set: { if !$0 { deletedListTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제 목록으로 이동", role: .destructive) {
                guard let target = deletedListTarget else { return }
                deletedListTarget = nil
                highlightedProjectID = nil
                Task { await model.moveToDeletedList(target) }
            }
            Button("취소", role: .cancel) { deletedListTarget = nil }
        } message: {
            Text("작품 목록에서는 사라지지만 삭제 목록에서 복원할 수 있습니다. 원고와 백업은 아직 지우지 않습니다.")
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

    private var projectLibrary: some View {
        List(selection: highlightedProjectSelection) {
            ForEach(model.libraryProjects) { project in
                projectRow(project)
                    .tag(project.id)
                    .listRowInsets(
                        EdgeInsets(top: 5, leading: 18, bottom: 5, trailing: 18)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onTapGesture {
                        highlightedProjectID = project.id
                        openHighlightedProject()
                    }
                    .contextMenu {
                        projectContextMenu(project)
                    }
            }
            .onMove { offsets, destination in
                Task { await model.move(fromOffsets: offsets, toOffset: destination) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(appBackground)
        .listRowSpacing(4)
        .environment(\.editMode, $projectEditMode)
        .onKeyPress(.return) {
            openHighlightedProject()
            return .handled
        }
        .onKeyPress(.space) {
            openHighlightedProject()
            return .handled
        }
        .disabled(model.isWorking || isSubmittingNewProject)
        .overlay {
            if model.libraryProjects.isEmpty, !model.isWorking {
                ContentUnavailableView(
                    "작품이 없습니다",
                    systemImage: "books.vertical",
                    description: Text("+ 버튼을 눌러 첫 작품을 만드세요.")
                )
            }
        }
        .navigationTitle("ChocoS")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button(projectEditMode.isEditing ? "완료" : "편집") {
                        withAnimation {
                            projectEditMode = projectEditMode.isEditing ? .inactive : .active
                        }
                    }
                    .accessibilityIdentifier("writerpad.project-edit")

                    Button("삭제 목록", systemImage: "trash") {
                        isShowingDeletedProjects = true
                    }
                    .disabled(!isEditingProjects || model.isWorking)
                    .accessibilityIdentifier("writerpad.deleted-projects")

                    Button("Windows 작품 가져오기", systemImage: "square.and.arrow.down") {
                        isSelectingImportFolder = true
                    }
                    .disabled(model.isWorking)

                    Button("WriterPad 백업 복원", systemImage: "arrow.counterclockwise.icloud") {
                        isSelectingBackupPackage = true
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("writerpad.restore-project-backup")

                    Button("설정", systemImage: "gearshape") {
                        isShowingSettings = true
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("writerpad.library-settings")

                    Button("새 작품", systemImage: "plus") {
                        newProjectName = ""
                        isCreating = true
                    }
                    .disabled(model.isWorking)
                }
            }
        }
        .accessibilityIdentifier("writerpad.project-library")
    }

    private var isEditingProjects: Bool {
        projectEditMode.isEditing
    }

    private var highlightedProjectSelection: Binding<ProjectID?> {
        Binding(
            get: { highlightedProjectID },
            set: { selectedID in
                guard !isSubmittingNewProject, !model.isWorking else { return }
                highlightedProjectID = selectedID
            }
        )
    }

    private func openHighlightedProject() {
        guard let highlightedProjectID,
              !projectEditMode.isEditing,
              !isSubmittingNewProject,
              !model.isWorking else { return }
        projectEditMode = .inactive
        Task { await model.open(highlightedProjectID) }
    }

    private var appBackground: Color {
        colorScheme == .dark ? .writerPadDarkBackground : Color(uiColor: .systemBackground)
    }

    private var rowSurface: Color {
        colorScheme == .dark ? .writerPadDarkSurface : Color(uiColor: .secondarySystemBackground)
    }

    private var rowBorder: Color {
        colorScheme == .dark ? .writerPadDarkBorder : Color.black.opacity(0.07)
    }

    private func projectRowSurface(for projectID: ProjectID) -> Color {
        guard highlightedProjectID == projectID else { return rowSurface }
        return colorScheme == .dark
            ? .writerPadDarkElevated
            : Color.accentColor.opacity(0.10)
    }

    private func projectRowBorder(for projectID: ProjectID) -> Color {
        highlightedProjectID == projectID
            ? Color.writerPadSelectionBorder
            : rowBorder
    }

    private func submitNewProject(named name: String) {
        guard !isSubmittingNewProject else { return }
        guard !name.isEmpty else { return }
        isSubmittingNewProject = true
        Task {
            await model.create(named: name)
            isSubmittingNewProject = false
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ManagedProject) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.writerPadDarkElevated
                            : Color.accentColor.opacity(0.10)
                    )
                    .frame(width: 48, height: 48)
                Image(systemName: "book.closed")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.writerPadAccent : Color.accentColor
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(project.isDeletionRequested ? "삭제 대기 중" : "로컬 작품")
                    .font(.caption)
                    .foregroundStyle(
                        project.isDeletionRequested ? Color.writerPadWarning : Color.secondary
                    )
            }

            Spacer()
            if project.isDeletionRequested {
                Image(systemName: "trash")
                    .foregroundStyle(Color.writerPadWarning)
                    .accessibilityLabel("삭제 대기 중")
            }
            if isEditingProjects {
                Button {
                    beginProjectRename(project)
                } label: {
                    Image(systemName: "pencil")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("‘\(project.name)’ 작품명 수정")
                .accessibilityHint("작품 이름 입력 창을 엽니다.")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(minHeight: 58)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(projectRowSurface(for: project.id))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    projectRowBorder(for: project.id),
                    lineWidth: highlightedProjectID == project.id ? 2.5 : 0.5
                )
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func projectContextMenu(_ project: ManagedProject) -> some View {
        Button("이름 변경", systemImage: "pencil") {
            beginProjectRename(project)
        }
        if project.isDeletionRequested {
            Button("삭제 대기 취소", systemImage: "arrow.uturn.backward") {
                Task { await model.cancelDeletion(of: project) }
            }
            Button("작품 목록에서 삭제…", systemImage: "trash.slash", role: .destructive) {
                deletedListTarget = project
            }
        } else {
            Button("삭제…", systemImage: "trash", role: .destructive) {
                deleteTarget = project
            }
        }
    }

    private func beginProjectRename(_ project: ManagedProject) {
        renameText = project.name
        renameTarget = project
    }

    private func submitProjectRename() {
        guard let target = renameTarget,
              !renameText.isEmpty,
              renameText != target.name,
              !model.isWorking
        else { return }
        let submittedName = renameText
        renameTarget = nil
        Task {
            await model.rename(target, to: submittedName)
        }
    }
}
