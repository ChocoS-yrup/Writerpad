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
    let projectBackupCoordinator: ProjectBackupCoordinator
    let conflictRecoveryStore: ConflictRecoveryStore?
    let restoreCoordinator: DocumentRestoreCoordinator
    let clock: any AppClock
    let futureChangeNotifier: any FutureChangeNotifying
    let supabaseClientProvider: any SupabaseClientProviding
    let authenticationService: any AuthenticationServicing
    let deviceIdentityService: any DeviceIdentityProviding
    let projectBindingService: any ProjectBindingServicing
    let syncDispatcher: SyncV2Dispatcher?
    let conflictResolutionService: (any SyncV2ConflictResolving)?
    let snapshotPullService: SyncV2SnapshotPullService?
    let realtimeTrigger: (any SyncV2RealtimeTriggering)?
    let backgroundSyncCoordinator: SyncV2BackgroundSyncCoordinator?
    let editLeaseManager: EditLeaseManager?
    /// 계약 핸드셰이크는 답을 메모리에만 들고 있으므로 하나만 만들어 든다.
    /// 부를 때마다 새로 만들면 들고 있던 답이 매번 사라진다.
    let handshakeService: SyncV2HandshakeService?
    let contractStructureSender: SyncV2ContractStructureSender?

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
        projectBackupCoordinator: ProjectBackupCoordinator,
        conflictRecoveryStore: ConflictRecoveryStore? = nil,
        restoreCoordinator: DocumentRestoreCoordinator,
        clock: any AppClock,
        futureChangeNotifier: any FutureChangeNotifying,
        supabaseClientProvider: any SupabaseClientProviding,
        authenticationService: any AuthenticationServicing,
        deviceIdentityService: any DeviceIdentityProviding,
        projectBindingService: any ProjectBindingServicing,
        syncDispatcher: SyncV2Dispatcher? = nil,
        conflictResolutionService:
            (any SyncV2ConflictResolving)? = nil,
        snapshotPullService: SyncV2SnapshotPullService? = nil,
        realtimeTrigger: (any SyncV2RealtimeTriggering)? = nil,
        backgroundSyncCoordinator: SyncV2BackgroundSyncCoordinator? = nil,
        editLeaseManager: EditLeaseManager? = nil,
        handshakeService: SyncV2HandshakeService? = nil,
        contractStructureSender: SyncV2ContractStructureSender? = nil,
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
        self.projectBackupCoordinator = projectBackupCoordinator
        self.conflictRecoveryStore = conflictRecoveryStore
        self.restoreCoordinator = restoreCoordinator
        self.clock = clock
        self.futureChangeNotifier = futureChangeNotifier
        self.supabaseClientProvider = supabaseClientProvider
        self.authenticationService = authenticationService
        self.deviceIdentityService = deviceIdentityService
        self.projectBindingService = projectBindingService
        self.syncDispatcher = syncDispatcher
        self.conflictResolutionService = conflictResolutionService
        self.snapshotPullService = snapshotPullService
        self.realtimeTrigger = realtimeTrigger
        self.backgroundSyncCoordinator = backgroundSyncCoordinator
        self.editLeaseManager = editLeaseManager
        self.handshakeService = handshakeService
            ?? supabaseClientProvider.makeHandshakeTransport()
                .map { SyncV2HandshakeService(transport: $0) }
        self.contractStructureSender = contractStructureSender
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
            creationMetadataStore: repository,
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
        let syncMutationGate = SyncV2DocumentMutationGate()
        let backupStore = LocalBackupStore(
            workspaceLocator: workspaceLocator,
            clock: clock
        )
        let binderScanner = LocalBinderDirectoryScanner(pathResolver: pathResolver)
        let binderRepository = LocalBinderRepository(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: workspaceLocator,
            scanner: binderScanner,
            pathPolicy: pathResolver.policy,
            clock: clock,
            syncMutationGate: syncMutationGate
        )
        let futureChangeNotifier = NoOpFutureChangeNotifier()
        let supabaseClientProvider: any SupabaseClientProviding
        if isStoredInMemoryOnly {
            supabaseClientProvider = SupabaseClientProvider(
                configuration: .failure(.missing)
            )
        } else {
            supabaseClientProvider = SupabaseClientProvider()
        }
        let authenticationService = SupabaseAuthService(
            transport: supabaseClientProvider.makeAuthTransport(),
            sessionStore: KeychainSessionStore()
        )
        let handshakeService = supabaseClientProvider
            .makeHandshakeTransport()
            .map { SyncV2HandshakeService(transport: $0) }
        let projectBindingTransport =
            supabaseClientProvider.makeProjectBindingTransport()
        let deviceIdentityStore: any DeviceIdentityStoring
        if isStoredInMemoryOnly {
            deviceIdentityStore = InMemoryDeviceIdentityStore()
        } else {
            deviceIdentityStore = KeychainDeviceIdentityStore()
        }
        let deviceIdentityService = DeviceIdentityService(
            store: deviceIdentityStore
        )
        let projectBindingStore: any ProjectBindingStoring
        let durableChangeRecorder: any DurableLocalChangeRecording
        let syncDispatcher: SyncV2Dispatcher?
        let networkRecoveryHub: SyncV2NetworkRecoveryHub?
        let conflictResolutionService: (any SyncV2ConflictResolving)?
        let snapshotStateStore: (any SyncV2SnapshotStateStoring)?
        let folderMigrationMarker: (any SyncV2FolderMigrationMarking)?
        let conflictRecoveryStore: ConflictRecoveryStore?
        // 이관을 마친 폴더는 서버와 공유하는 UUID를 갖는다. tree_order로만 온
        // 이름 변경을 폴더 기록에도 올려야 그 기록이 낡지 않는다.
        let localSnapshotApplier: LocalSyncV2SnapshotApplier
        let editLeaseManager: EditLeaseManager?
        let contractStructureSender: SyncV2ContractStructureSender?
        if isStoredInMemoryOnly {
            projectBindingStore = InMemoryProjectBindingStore()
            durableChangeRecorder = NoOpDurableLocalChangeRecorder()
            syncDispatcher = nil
            networkRecoveryHub = nil
            conflictResolutionService = nil
            snapshotStateStore = nil
            folderMigrationMarker = nil
            conflictRecoveryStore = nil
            localSnapshotApplier = LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: workspaceLocator,
                backupStore: backupStore
            )
            editLeaseManager = nil
            contractStructureSender = nil
        } else {
            let dispatchWakeup = SyncV2DispatchWakeup()
            networkRecoveryHub = SyncV2NetworkRecoveryHub()
            let syncV2Store = LazySyncV2ProjectBindingStore(
                databaseURL: SyncV2Store.defaultDatabaseURL(),
                deviceIdentityProvider: deviceIdentityService,
                dispatchWakeup: dispatchWakeup
            )
            projectBindingStore = syncV2Store
            durableChangeRecorder = SyncV2ContractPathRecorder(
                store: syncV2Store,
                handshakeService: handshakeService,
                authenticationService: authenticationService
            )
            conflictResolutionService = syncV2Store
            snapshotStateStore = syncV2Store
            folderMigrationMarker = syncV2Store
            conflictRecoveryStore = ConflictRecoveryStore
                .defaultPackagesRootURL()
                .map {
                    ConflictRecoveryStore(
                        ledger: syncV2Store,
                        documentRepository: repository,
                        workspaceLocator: workspaceLocator,
                        packagesRootURL: $0,
                        durableChangeRecorder: syncV2Store
                    )
                }
            localSnapshotApplier = LocalSyncV2SnapshotApplier(
                documentRepository: repository,
                workspaceLocator: workspaceLocator,
                backupStore: backupStore,
                folderIdentityPublisher:
                    DurableSyncV2FolderIdentityPublisher(
                        changeRecorder: durableChangeRecorder
                    )
            )
            editLeaseManager = supabaseClientProvider
                .makeEditLeaseClient()
                .map {
                    EditLeaseManager(
                        client: $0,
                        revisionProvider: syncV2Store,
                        deviceIdentityProvider: deviceIdentityService,
                        isEnabled: {
                            GlobalSyncPreference.isEnabled()
                        },
                        authenticationState: {
                            await authenticationService.currentState()
                        }
                    )
                }
            if let handshakeService,
               let transport = supabaseClientProvider
                   .makeAtomicStructureTransport() {
                contractStructureSender = SyncV2ContractStructureSender(
                    store: syncV2Store,
                    transport: transport,
                    handshakeService: handshakeService,
                    authenticationService: authenticationService
                )
            } else {
                contractStructureSender = nil
            }
            let snapshotClient =
                supabaseClientProvider.makeSnapshotClient()
            syncDispatcher = supabaseClientProvider.makeSyncV2Client().map {
                let automaticRebaser = snapshotClient.map {
                    SyncV2AutomaticRebaser(
                        store: syncV2Store,
                        snapshotClient: $0,
                        localApplier: localSnapshotApplier,
                        openLocalProvider:
                            SyncV2EditorSessionRegistry.shared,
                        conflictRecoveryStore: conflictRecoveryStore
                    )
                }
                return SyncV2Dispatcher(
                    store: syncV2Store,
                    client: $0,
                    leaseManager: editLeaseManager,
                    projectRecoveryTransport: projectBindingTransport,
                    automaticRebaser: automaticRebaser,
                    wakeup: dispatchWakeup,
                    networkRecoveryHub: networkRecoveryHub
                )
            }
        }
        let initialSyncRecorder = ProjectInitialSyncRecorder(
            documentRepository: repository,
            workspaceLocator: workspaceLocator,
            durableChangeRecorder: durableChangeRecorder
        )
        let projectBindingService = SupabaseProjectBindingService(
            transport: projectBindingTransport,
            bindingStore: projectBindingStore,
            projectRepository: repository,
            authenticationService: authenticationService,
            initialSyncRecorder: initialSyncRecorder,
            // 초기 snapshot을 올리기 전에 서버 작품이 비어 있는지 확인한다.
            snapshotClient: supabaseClientProvider.makeSnapshotClient()
        )
        let localDocumentStore = LocalDocumentStore(
            workspaceLocator: workspaceLocator,
            metadataUpdater: repository,
            durableChangeRecorder: durableChangeRecorder,
            clock: clock,
            syncMutationGate: syncMutationGate
        )
        let snapshotPullService: SyncV2SnapshotPullService?
        if let snapshotStateStore,
           let snapshotClient = supabaseClientProvider.makeSnapshotClient() {
            snapshotPullService = SyncV2SnapshotPullService(
                client: snapshotClient,
                stateStore: snapshotStateStore,
                localApplier: localSnapshotApplier,
                mergeStore: LocalSyncV2SnapshotMergeStore(
                    workspaceLocator: workspaceLocator
                ),
                folderApplier: SyncV2RemoteFolderApplier(
                    documentRepository: repository,
                    workspaceLocator: workspaceLocator
                ),
                folderMigration: folderMigrationMarker.map {
                    SyncV2FolderMigration(
                        documentRepository: repository,
                        marker: $0,
                        changeRecorder: durableChangeRecorder
                    )
                },
                folderMarker: folderMigrationMarker,
                folderDocuments: repository,
                mutationGate: syncMutationGate
            )
        } else {
            snapshotPullService = nil
        }
        // 두 trigger는 같은 SupabaseClientProvider가 보유한 subscription gate를
        // 공유해 workspace/background 채널의 동시 subscribe를 직렬화한다.
        let workspaceRealtimeTrigger =
            supabaseClientProvider.makeRealtimeTrigger()
        let backgroundSyncCoordinator: SyncV2BackgroundSyncCoordinator?
        if let snapshotPullService,
           let backgroundRealtimeTrigger =
               supabaseClientProvider.makeRealtimeTrigger() {
            backgroundSyncCoordinator = SyncV2BackgroundSyncCoordinator(
                puller: snapshotPullService,
                realtime: backgroundRealtimeTrigger,
                projectBindingService: projectBindingService,
                authenticationService: authenticationService
            )
        } else {
            backgroundSyncCoordinator = nil
        }
        if let networkRecoveryHub {
            Task {
                await networkRecoveryHub.install {
                    guard GlobalSyncPreference.isEnabled() else { return }
                    let state = await authenticationService
                        .restoreSession()
                    guard state.isAuthenticated else { return }
                    await backgroundSyncCoordinator?.start()
                    await backgroundSyncCoordinator?
                        .appEnteredForeground()
                }
            }
        }
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
        let backupPolicyStore = LocalBackupPolicyStore(
            globalPolicyURL: pathResolver.projectsRootURL
                .appendingPathComponent(".writerpad-backup-policy.json"),
            legacyWorkspaceLocator: workspaceLocator
        )
        let projectBackupCoordinator = ProjectBackupCoordinator(
            projectRepository: repository,
            documentRepository: repository,
            workspaceLocator: workspaceLocator
        )
        let binderCommands = LocalBinderCommandService(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: workspaceLocator,
            pathPolicy: pathResolver.policy,
            clock: clock,
            futureChangeNotifier: futureChangeNotifier,
            durableChangeRecorder: durableChangeRecorder,
            syncMutationGate: syncMutationGate,
            backupStore: backupStore,
            backupPolicyStore: backupPolicyStore
        )
        let restoreCoordinator = DocumentRestoreCoordinator(
            documentStore: localDocumentStore,
            backupStore: backupStore,
            documentRepository: repository,
            binderCommands: binderCommands,
            futureChangeNotifier: futureChangeNotifier,
            pathPolicy: pathResolver.policy
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
            projectBackupCoordinator: projectBackupCoordinator,
            conflictRecoveryStore: conflictRecoveryStore,
            restoreCoordinator: restoreCoordinator,
            clock: clock,
            futureChangeNotifier: futureChangeNotifier,
            supabaseClientProvider: supabaseClientProvider,
            authenticationService: authenticationService,
            deviceIdentityService: deviceIdentityService,
            projectBindingService: projectBindingService,
            syncDispatcher: syncDispatcher,
            conflictResolutionService: conflictResolutionService,
            snapshotPullService: snapshotPullService,
            realtimeTrigger: workspaceRealtimeTrigger,
            backgroundSyncCoordinator: backgroundSyncCoordinator,
            editLeaseManager: editLeaseManager,
            handshakeService: handshakeService,
            contractStructureSender: contractStructureSender,
            exporter: exporter
        )
    }
}

enum LocalStorageStatus: String, Sendable {
    case ready
    case unavailable
}
