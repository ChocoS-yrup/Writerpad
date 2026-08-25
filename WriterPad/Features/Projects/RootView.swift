import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("writerpad.dark-mode-enabled") private var isDarkMode = true
    @AppStorage("writerpad.smart-pairs-enabled") private var smartPairsEnabled = true

    var body: some View {
        ProjectWorkspaceView(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter,
            binderRepository: environment.binderRepository,
            binderCommands: environment.binderCommands,
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            searchService: environment.searchService,
            exporter: environment.exporter,
            backupStore: environment.backupStore,
            backupPolicyStore: environment.backupPolicyStore,
            restoreCoordinator: environment.restoreCoordinator,
            workspaceStateRepository: environment.workspaceStateRepository,
            futureChangeNotifier: environment.futureChangeNotifier,
            authenticationService: environment.authenticationService,
            projectBindingService: environment.projectBindingService,
            syncDispatcher: environment.syncDispatcher,
            conflictResolutionService:
                environment.conflictResolutionService,
            snapshotPullService: environment.snapshotPullService,
            realtimeTrigger: environment.realtimeTrigger,
            backgroundSyncCoordinator:
                environment.backgroundSyncCoordinator,
            editLeaseManager: environment.editLeaseManager,
            handshakeService: environment.handshakeService,
            contractStructureSender: environment.contractStructureSender,
            snapshotPuller: environment.snapshotPullService,
            isDarkMode: $isDarkMode,
            smartPairsEnabled: $smartPairsEnabled
        )
        .tint(.writerPadAccent)
        .preferredColorScheme(isDarkMode ? .dark : nil)
            .task {
                await environment.futureChangeNotifier.record(.appLaunched)
            }
    }
}

#Preview {
    RootView()
        .environmentObject(try! AppEnvironment.testing())
}
