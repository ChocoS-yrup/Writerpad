import SwiftUI
import SwiftData

@main
@MainActor
struct WriterPadApp: App {
    @StateObject private var environment: AppEnvironment

    init() {
        let liveEnvironment: AppEnvironment

        do {
            liveEnvironment = try AppEnvironment.live()
        } catch {
            fatalError("WriterPad 환경을 구성하지 못했습니다: \(error.localizedDescription)")
        }

        _environment = StateObject(wrappedValue: liveEnvironment)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
        .modelContainer(environment.modelContainer)
    }
}
