import Combine
import Foundation
import SwiftData

@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let projectRepository: any ProjectRepository
    let documentRepository: any DocumentRepository
    let workspaceStateRepository: any WorkspaceStateRepository
    let projectManager: any ProjectManaging
    let projectImporter: any ProjectImporting
    let binderRepository: any BinderRepository
    let binderCommands: any BinderCommanding
    let localDocumentStore: any LocalDocumentStoring
    let searchService: any Searching
    let exporter: any Exporting
    let backupStore: any BackupStoring
    let backupPolicyStore: any BackupPolicyStoring
    let restoreCoordinator: DocumentRestoreCoordinator
    let clock: any AppClock
    let futureChangeNotifier: any FutureChangeNotifying

    @Published private(set) var storageStatus: LocalStorageStatus = .ready

    init(
        modelContainer: ModelContainer,
        projectRepository: any ProjectRepository,
        documentRepository: any DocumentRepository,
        workspaceStateRepository: any WorkspaceStateRepository,
        projectManager: any ProjectManaging,
        projectImporter: any ProjectImporting,
        binderRepository: any BinderRepository,
        binderCommands: any BinderCommanding,
        localDocumentStore: any LocalDocumentStoring,
        searchService: any Searching,
        backupStore: any BackupStoring,
        backupPolicyStore: any BackupPolicyStoring,
        restoreCoordinator: DocumentRestoreCoordinator,
        clock: any AppClock,
        futureChangeNotifier: any FutureChangeNotifying,
        exporter: (any Exporting)? = nil
    ) {
        self.modelContainer = modelContainer
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.workspaceStateRepository = workspaceStateRepository
        self.projectManager = projectManager
        self.projectImporter = projectImporter
        self.binderRepository = binderRepository
        self.binderCommands = binderCommands
        self.localDocumentStore = localDocumentStore
        self.searchService = searchService
        self.exporter = exporter ?? LocalManuscriptExporter(
            projectRepository: projectRepository,
            documentRepository: documentRepository,
            documentStore: localDocumentStore
        )
        self.backupStore = backupStore
        self.backupPolicyStore = backupPolicyStore
        self.restoreCoordinator = restoreCoordinator
        self.clock = clock
        self.futureChangeNotifier = futureChangeNotifier
    }

    static func live() throws -> AppEnvironment {
        try make(isStoredInMemoryOnly: false)
    }

    static func testing() throws -> AppEnvironment {
        try make(isStoredInMemoryOnly: true)
    }

    private static func make(isStoredInMemoryOnly: Bool) throws -> AppEnvironment {
        let container = try WriterPadMetadataStore.makeContainer(
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let pathResolver: ProjectPathResolver
        if isStoredInMemoryOnly {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WriterPad-Preview-\(UUID().uuidString)")
                .appendingPathComponent("Projects", isDirectory: true)
            pathResolver = ProjectPathResolver(projectsRootURL: root)
        } else {
            pathResolver = try ProjectPathResolver.live()
        }
        let clock = SystemClock()
        let projectManager = LocalProjectManager(
            projectRepository: repository,
            workspaceStateRepository: repository,
            pathResolver: pathResolver,
            clock: clock
        )
        let projectImporter = WindowsProjectImporter(
            projectRepository: repository,
            documentRepository: repository,
            metadataRegistrar: repository,
            workspaceStateRepository: repository,
            projectManager: projectManager,
            pathResolver: pathResolver,
            clock: clock
        )
        let workspaceLocator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: pathResolver
        )
        let binderScanner = LocalBinderDirectoryScanner(pathResolver: pathResolver)
        let binderRepository = LocalBinderRepository(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: workspaceLocator,
            scanner: binderScanner,
            pathPolicy: pathResolver.policy,
            clock: clock
        )
        let futureChangeNotifier = NoOpFutureChangeNotifier()
        let localDocumentStore = LocalDocumentStore(
            workspaceLocator: workspaceLocator,
            metadataUpdater: repository,
            clock: clock
        )
        let searchService = LocalProjectSearchService(
            documentRepository: repository,
            documentStore: localDocumentStore
        )
        let exporter = LocalManuscriptExporter(
            projectRepository: repository,
            documentRepository: repository,
            documentStore: localDocumentStore,
            pathPolicy: pathResolver.policy
        )
        let backupStore = LocalBackupStore(
            workspaceLocator: workspaceLocator,
            clock: clock
        )
        let backupPolicyStore = LocalBackupPolicyStore(
            globalPolicyURL: pathResolver.projectsRootURL
                .appendingPathComponent(".writerpad-backup-policy.json"),
            legacyWorkspaceLocator: workspaceLocator
        )
        let restoreCoordinator = DocumentRestoreCoordinator(
            documentStore: localDocumentStore,
            backupStore: backupStore,
            futureChangeNotifier: futureChangeNotifier,
            pathPolicy: pathResolver.policy
        )
        let binderCommands = LocalBinderCommandService(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: workspaceLocator,
            pathPolicy: pathResolver.policy,
            clock: clock,
            futureChangeNotifier: futureChangeNotifier,
            backupStore: backupStore,
            backupPolicyStore: backupPolicyStore
        )

        return AppEnvironment(
            modelContainer: container,
            projectRepository: repository,
            documentRepository: repository,
            workspaceStateRepository: repository,
            projectManager: projectManager,
            projectImporter: projectImporter,
            binderRepository: binderRepository,
            binderCommands: binderCommands,
            localDocumentStore: localDocumentStore,
            searchService: searchService,
            backupStore: backupStore,
            backupPolicyStore: backupPolicyStore,
            restoreCoordinator: restoreCoordinator,
            clock: clock,
            futureChangeNotifier: futureChangeNotifier,
            exporter: exporter
        )
    }
}

enum LocalStorageStatus: String, Sendable {
    case ready
    case unavailable
}
