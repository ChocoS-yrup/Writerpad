import Combine
import SwiftData

@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let clock: any AppClock
    let futureChangeNotifier: any FutureChangeNotifying

    @Published private(set) var storageStatus: LocalStorageStatus = .ready

    init(
        modelContainer: ModelContainer,
        clock: any AppClock,
        futureChangeNotifier: any FutureChangeNotifying
    ) {
        self.modelContainer = modelContainer
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
        let schema = Schema([BootstrapRecord.self])
        let configuration = ModelConfiguration(
            "WriterPadMetadata",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )

        return AppEnvironment(
            modelContainer: container,
            clock: SystemClock(),
            futureChangeNotifier: NoOpFutureChangeNotifier()
        )
    }
}

enum LocalStorageStatus: String, Sendable {
    case ready
    case unavailable
}
