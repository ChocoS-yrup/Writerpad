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
        clock: any AppClock,
        futureChangeNotifier: any FutureChangeNotifying
    ) {
        self.modelContainer = modelContainer
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.workspaceStateRepository = workspaceStateRepository
        self.projectManager = projectManager
        self.projectImporter = projectImporter
        self.binderRepository = binderRepository
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

        return AppEnvironment(
            modelContainer: container,
            projectRepository: repository,
            documentRepository: repository,
            workspaceStateRepository: repository,
            projectManager: projectManager,
            projectImporter: projectImporter,
            binderRepository: binderRepository,
            clock: clock,
            futureChangeNotifier: NoOpFutureChangeNotifier()
        )
    }
}

enum LocalStorageStatus: String, Sendable {
    case ready
    case unavailable
}
