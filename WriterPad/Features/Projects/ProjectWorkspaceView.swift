import SwiftUI
import UIKit
import UniformTypeIdentifiers

private extension UTType {
    static let writerPadReceivePromotion = UTType(
        importedAs: "com.chocos.writerpad.receive-promotion",
        conformingTo: .package
    )
}

struct ProjectWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase
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
    @State private var isSelectingReceivePromotion = false
    @State private var backupTarget: ManagedProject?
    @State private var isShowingSettings = false
    @State private var isShowingDeletedProjects = false
    @State private var isShowingServerCatalog = false
    private let serverProjectCatalog: ServerProjectCatalogService?
    private let binderRepository: any BinderRepository
    private let binderCommands: any BinderCommanding
    private let documentRepository: any DocumentRepository
    private let documentStore: any LocalDocumentStoring
    private let searchService: any Searching
    private let exporter: any Exporting
    private let backupStore: any BackupStoring
    private let backupPolicyStore: any BackupPolicyStoring
    private let projectBackupCoordinator: ProjectBackupCoordinator
    private let restoreCoordinator: DocumentRestoreCoordinator
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let futureChangeNotifier: any FutureChangeNotifying
    private let projectManager: any ProjectManaging
    private let authenticationService: any AuthenticationServicing
    private let projectBindingService: any ProjectBindingServicing
    private let syncDispatcher: SyncV2Dispatcher?
    private let conflictResolutionService:
        (any SyncV2ConflictResolving)?
    private let conflictRecoveryStore: ConflictRecoveryStore?
    private let snapshotPullService: SyncV2SnapshotPullService?
    private let realtimeTrigger: (any SyncV2RealtimeTriggering)?
    private let backgroundSyncCoordinator:
        SyncV2BackgroundSyncCoordinator?
    private let editLeaseManager: EditLeaseManager?
    private let handshakeService: SyncV2HandshakeService?
    private let contractStructureSender: SyncV2ContractStructureSender?
    private let snapshotPuller: (any SyncV2SnapshotPulling)?
    @Binding private var isDarkMode: Bool
    @Binding private var smartPairsEnabled: Bool

    init(
        projectManager: any ProjectManaging,
        projectImporter: any ProjectImporting,
        receivePromotionInspector: any ReceivePromotionPackageInspecting,
        receivePromotionTransaction: any ReceivePromotionTransacting,
        binderRepository: any BinderRepository,
        binderCommands: any BinderCommanding,
        documentRepository: any DocumentRepository,
        documentStore: any LocalDocumentStoring,
        searchService: any Searching,
        exporter: any Exporting,
        backupStore: any BackupStoring,
        backupPolicyStore: any BackupPolicyStoring,
        projectBackupCoordinator: ProjectBackupCoordinator,
        restoreCoordinator: DocumentRestoreCoordinator,
        workspaceStateRepository: any WorkspaceStateRepository,
        futureChangeNotifier: any FutureChangeNotifying,
        authenticationService: any AuthenticationServicing,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher?,
        conflictResolutionService:
            (any SyncV2ConflictResolving)? = nil,
        conflictRecoveryStore: ConflictRecoveryStore? = nil,
        snapshotPullService: SyncV2SnapshotPullService? = nil,
        realtimeTrigger: (any SyncV2RealtimeTriggering)? = nil,
        backgroundSyncCoordinator:
            SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: EditLeaseManager? = nil,
        handshakeService: SyncV2HandshakeService? = nil,
        contractStructureSender: SyncV2ContractStructureSender? = nil,
        snapshotPuller: (any SyncV2SnapshotPulling)? = nil,
        serverProjectCatalog: ServerProjectCatalogService? = nil,
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
        self.projectBackupCoordinator = projectBackupCoordinator
        self.restoreCoordinator = restoreCoordinator
        self.workspaceStateRepository = workspaceStateRepository
        self.futureChangeNotifier = futureChangeNotifier
        self.projectManager = projectManager
        self.authenticationService = authenticationService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.conflictResolutionService = conflictResolutionService
        self.conflictRecoveryStore = conflictRecoveryStore
        self.snapshotPullService = snapshotPullService
        self.realtimeTrigger = realtimeTrigger
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        self.handshakeService = handshakeService
        self.contractStructureSender = contractStructureSender
        self.snapshotPuller = snapshotPuller
        self.serverProjectCatalog = serverProjectCatalog
        _isDarkMode = isDarkMode
        _smartPairsEnabled = smartPairsEnabled
        _model = StateObject(
            wrappedValue: ProjectListModel(
                projectManager: projectManager,
                projectImporter: projectImporter,
                receivePromotionInspector: receivePromotionInspector,
                receivePromotionTransaction: receivePromotionTransaction,
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
                        conflictRecoveryStore: conflictRecoveryStore,
                        generalRecoveryReader: contractStructureSender,
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
            guard !Task.isCancelled else { return }
            await handshakeService?.observeProject(
                model.selectedProjectID,
                authentication: authenticationService,
                bindings: projectBindingService
            )
            await syncDispatcher?.prioritizeProject(
                model.selectedProjectID
            )
            await backgroundSyncCoordinator?.prioritizeProject(
                model.selectedProjectID
            )
        }
        .task(id: scenePhase) {
            guard !Task.isCancelled else { return }
            await handshakeService?.updateSceneActivity(scenePhase == .active)
        }
        .sheet(isPresented: $isShowingServerCatalog, onDismiss: {
            Task { await model.load(opensLastProject: false) }
        }) {
            if let serverProjectCatalog {
                ServerProjectCatalogView(service: serverProjectCatalog, authentication: authenticationService)
            }
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
                editLeaseManager: editLeaseManager,
                handshakeService: handshakeService,
                contractStructureSender: contractStructureSender,
                snapshotPuller: snapshotPuller
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
        .sheet(item: $backupTarget) { project in
            ProjectBackupCreationView(project: project, coordinator: projectBackupCoordinator)
        }
        .background(appBackground)
        .task {
            await model.load(opensLastProject: restoresLastProjectOnLaunch)
        }
        .fileImporter(
            isPresented: $isSelectingReceivePromotion,
            allowedContentTypes: [.writerPadReceivePromotion],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let packageURL = urls.first else { return }
                Task { await model.inspectReceivePromotion(at: packageURL) }
            case let .failure(error):
                model.present(error: error)
            }
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
            item: $model.receivePromotionReport,
            onDismiss: { model.dismissReceivePromotionReport() }
        ) { report in
            ReceivePromotionReviewView(
                report: report,
                isWorking: model.isWorking,
                onCancel: { model.dismissReceivePromotionReport() },
                onPromote: { name in
                    Task { await model.confirmReceivePromotion(projectName: name) }
                }
            )
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

                    Button("서버 작품 가져오기", systemImage: "icloud.and.arrow.down") {
                        isShowingServerCatalog = true
                    }
                    .disabled(model.isWorking || serverProjectCatalog == nil)
                    .accessibilityIdentifier("writerpad.server-project-catalog")

                    Button("Windows 폴더 가져오기", systemImage: "square.and.arrow.down") {
                        isSelectingImportFolder = true
                    }
                    .disabled(model.isWorking)

                    Button("수신 편집본을 로컬 작품으로 만들기", systemImage: "doc.badge.plus") {
                        isSelectingReceivePromotion = true
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("writerpad.receive-promotion")

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
        Button("원고·구조 백업…", systemImage: "externaldrive.badge.plus") {
            backupTarget = project
        }
        .disabled(model.isWorking)
        .accessibilityIdentifier("writerpad.create-project-backup")
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

private struct ReceivePromotionReviewView: View {
    let report: ReceivePromotionReport
    let isWorking: Bool
    let onCancel: () -> Void
    let onPromote: (String) -> Void
    @State private var projectName: String

    init(
        report: ReceivePromotionReport,
        isWorking: Bool,
        onCancel: @escaping () -> Void,
        onPromote: @escaping (String) -> Void
    ) {
        self.report = report
        self.isWorking = isWorking
        self.onCancel = onCancel
        self.onPromote = onPromote
        _projectName = State(initialValue: report.suggestedProjectName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("읽기 전용 검사 결과") {
                    LabeledContent("원본 폴더", value: report.sourceFolderName)
                    LabeledContent("문서", value: "\(report.documents.count)개")
                    LabeledContent("본문 크기", value: "\(report.totalBytes) bytes")
                    LabeledContent("package ID", value: report.packageID.uuidString.lowercased())
                    LabeledContent("package SHA-256", value: report.packageFingerprint.rawValue)
                }
                Section("포함 문서") {
                    ForEach(report.documents, id: \.sourceDocumentID) { document in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(document.sourceName)
                            Text("local revision \(document.editableRevision) · \(document.byteCount) bytes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("새 로컬 작품") {
                    TextField("작품 이름", text: $projectName)
                    Text("확정할 때 package를 다시 읽고 SHA-256을 대조한 뒤 새 로컬 작품을 원자적으로 만듭니다. 인증·서버 조회·서버 연결·전송은 하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("수신 편집본 검토")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소", action: onCancel)
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("로컬 작품 만들기") {
                        onPromote(projectName)
                    }
                    .disabled(isWorking || projectName.isEmpty)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }
}

private struct ProjectBackupCreationView: View {
    @Environment(\.dismiss) private var dismiss
    let project: ManagedProject
    @StateObject private var model: ProjectBackupExportModel
    @State private var isSelectingDestination = false
    @State private var exportTask: Task<Void, Never>?

    init(project: ManagedProject, coordinator: ProjectBackupCoordinator) {
        self.project = project
        _model = StateObject(wrappedValue: ProjectBackupExportModel(coordinator: coordinator))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(project.name) {
                    Text("저장된 원고와 구조를 새 백업 폴더로 보관합니다. 원본 작품 밖의 iCloud Drive·외장 저장소 등의 위치를 선택하세요.")
                }
                Section("포함되는 자료") {
                    Text("활성·휴지통 TXT 원고, 캐릭터·설정집·메모장 등의 등록된 TXT 자료, 빈 폴더, 제목, 부모 관계, 순서와 UUID")
                }
                Section("포함되지 않는 자료") {
                    Text("설정 JSON·별도 첨부 파일, 과거 자동저장·복원전·충돌 백업, 커서·창 배치·접힘 상태, 휴지통의 원래 위치·삭제 시각, 앱 환경 설정")
                    Text("로그인 정보와 서버 연결·송신 기록은 포함하지 않습니다.")
                }
                Section("복원 방법") {
                    Text("작품 목록의 ‘WriterPad 백업 복원’에서 생성된 백업 폴더를 선택합니다. UUID를 유지하며, 같은 UUID 또는 이름의 작품이 있으면 덮어쓰지 않고 중단합니다. 서버에는 자동 연결하지 않습니다.")
                    Text("휴지통 원고는 휴지통으로 복원됩니다. 원래 위치 정보가 없어 원하는 폴더로 직접 옮겨야 할 수 있습니다.")
                }
                Section {
                    if model.isWorking {
                        ProgressView("백업을 검증하고 저장하는 중…")
                        Button("취소", role: .cancel) { exportTask?.cancel() }
                    } else {
                        Button("보관 위치 선택…", systemImage: "folder") {
                            isSelectingDestination = true
                        }
                        .accessibilityIdentifier("writerpad.project-backup-destination")
                    }
                    if let url = model.savedPackageURL {
                        Label("선택한 위치에 백업을 저장했습니다.", systemImage: "checkmark.circle")
                        Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
                    }
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("원고·구조 백업")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }.disabled(model.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(model.isWorking)
        .fileImporter(isPresented: $isSelectingDestination, allowedContentTypes: [.folder]) { result in
            switch result {
            case let .success(folder):
                exportTask = Task { await model.save(projectID: project.id, in: folder) }
            case let .failure(error):
                model.present(error: error)
            }
        }
        .onDisappear { exportTask?.cancel() }
    }
}
