import Combine
import SwiftData

@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let projectRepository: any ProjectRepository
    let documentRepository: any DocumentRepository
    let workspaceStateRepository: any WorkspaceStateRepository
    let clock: any AppClock
    let futureChangeNotifier: any FutureChangeNotifying

    @Published private(set) var storageStatus: LocalStorageStatus = .ready

    init(
        modelContainer: ModelContainer,
        projectRepository: any ProjectRepository,
        documentRepository: any DocumentRepository,
        workspaceStateRepository: any WorkspaceStateRepository,
        clock: any AppClock,
        futureChangeNotifier: any FutureChangeNotifying
    ) {
        self.modelContainer = modelContainer
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.workspaceStateRepository = workspaceStateRepository
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

        return AppEnvironment(
            modelContainer: container,
            projectRepository: repository,
            documentRepository: repository,
            workspaceStateRepository: repository,
            clock: SystemClock(),
            futureChangeNotifier: NoOpFutureChangeNotifier()
        )
    }
}

enum LocalStorageStatus: String, Sendable {
    case ready
    case unavailable
}
