import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("writerpad.dark-mode-enabled") private var isDarkMode = true
    @AppStorage("writerpad.smart-pairs-enabled") private var smartPairsEnabled = true

    var body: some View {
        if IntegratedEditorPlan.enabled {
            if let session = environment.integratedEditorSession { IntegratedEditorWorkspaceView(session: session) }
            else { Text("통합 집필 저장소를 열지 못했습니다.") }
        } else if NormalEditorPlan.enabled {
            if let session = environment.normalEditorSession { NormalEditorWorkspaceView(session: session) }
            else { Text("일반 집필 준비를 열지 못했습니다. 저장소와 후보 설정을 확인하세요.") }
        } else { ordinaryWorkspace }
    }
    private var ordinaryWorkspace: some View {
        ProjectWorkspaceView(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter,
            receivePromotionInspector: environment.receivePromotionInspector,
            receivePromotionTransaction: environment.receivePromotionTransaction,
            binderRepository: environment.binderRepository,
            binderCommands: environment.binderCommands,
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            searchService: environment.searchService,
            exporter: environment.exporter,
            backupStore: environment.backupStore,
            backupPolicyStore: environment.backupPolicyStore,
            projectBackupCoordinator: environment.projectBackupCoordinator,
            restoreCoordinator: environment.restoreCoordinator,
            workspaceStateRepository: environment.workspaceStateRepository,
            futureChangeNotifier: environment.futureChangeNotifier,
            authenticationService: environment.authenticationService,
            projectBindingService: environment.projectBindingService,
            syncDispatcher: environment.syncDispatcher,
            conflictResolutionService:
                environment.conflictResolutionService,
            conflictRecoveryStore: environment.conflictRecoveryStore,
            snapshotPullService: environment.snapshotPullService,
            realtimeTrigger: environment.realtimeTrigger,
            backgroundSyncCoordinator:
                environment.backgroundSyncCoordinator,
            editLeaseManager: environment.editLeaseManager,
            handshakeService: environment.handshakeService,
            contractStructureSender: environment.contractStructureSender,
            snapshotPuller: environment.snapshotPullService,
            serverProjectCatalog: environment.serverProjectCatalog,
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
