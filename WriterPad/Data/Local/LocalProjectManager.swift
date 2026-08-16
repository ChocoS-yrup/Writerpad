import Foundation

enum ProjectManagerError: Error, Equatable, LocalizedError, Sendable {
    case missingProject(ProjectID)
    case projectFolderMissing(String)
    case invalidOrder
    case deletionAlreadyRequested(ProjectID)
    case deletionNotRequested(ProjectID)
    case projectAlreadyInDeletedList(ProjectID)
    case projectNotInDeletedList(ProjectID)
    case projectAlreadyExists(ProjectID)
    case staleDeletionConfirmation
    case recoveryRequired(String)
    case injectedFailure(recoveryPending: Bool)

    var errorDescription: String? {
        switch self {
        case let .missingProject(id):
            "작품 정보를 찾을 수 없습니다: \(id.rawValue.uuidString)"
        case let .projectFolderMissing(name):
            "작품 폴더를 찾을 수 없습니다: \(name)"
        case .invalidOrder:
            "작품 순서에 빠지거나 중복된 항목이 있습니다."
        case let .deletionAlreadyRequested(id):
            "이미 삭제 대기 중인 작품입니다: \(id.rawValue.uuidString)"
        case let .deletionNotRequested(id):
            "삭제 대기 중인 작품만 삭제 목록으로 옮길 수 있습니다: \(id.rawValue.uuidString)"
        case let .projectAlreadyInDeletedList(id):
            "이미 삭제 목록에 있는 작품입니다: \(id.rawValue.uuidString)"
        case let .projectNotInDeletedList(id):
            "삭제 목록에 있는 작품만 영구 삭제할 수 있습니다: \(id.rawValue.uuidString)"
        case let .projectAlreadyExists(id):
            "같은 UUID의 작품이 이미 존재하여 복원하지 않았습니다: \(id.rawValue.uuidString)"
        case .staleDeletionConfirmation:
            "작품 정보가 바뀌어 삭제 확인을 다시 받아야 합니다."
        case let .recoveryRequired(path):
            "작품 작업을 자동 복구하지 못했습니다. 기록을 보존했습니다: \(path)"
        case let .injectedFailure(recoveryPending):
            recoveryPending
                ? "테스트용 중단이 발생했으며 다음 실행에서 복구됩니다."
                : "테스트용 작품 작업 실패가 발생했습니다."
        }
    }
}

enum ProjectManagerFaultPoint: Equatable, Sendable {
    case afterCreationJournalWrite
    case afterStaging
    case afterMetadataSave
    case afterFileMove
    case afterProjectQuarantine
    case afterProjectMetadataRemoval
    case afterRestoreJournalWrite
    case afterRestorePackageCopy
    case afterRestoreStaging
    case afterRestoreMetadataSave
    case afterRestoreFileMove
}

struct ProjectManagerFaultPlan: Equatable, Sendable {
    let point: ProjectManagerFaultPoint
    let leavesTransactionForRecovery: Bool
}

private struct ProjectCatalog: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var entries: [Entry] = []

    struct Entry: Codable, Equatable {
        let projectID: ProjectID
        var userOrder: Int
        var deletionRequestedAt: Date?
        var deletedListAt: Date?

        private enum CodingKeys: String, CodingKey {
            case projectID = "project_id"
            case userOrder = "user_order"
            case deletionRequestedAt = "deletion_requested_at"
            case deletedListAt = "deleted_list_at"
        }
    }
}

private struct ProjectTransactionJournal: Codable {
    enum Kind: String, Codable {
        case create
        case rename
        case delete
        case restoreBackup = "restore_backup"
    }

    enum Phase: String, Codable {
        case staged
        case metadataSaved = "metadata_saved"
        case fileMoved = "file_moved"
        case quarantined
        case metadataRemoved = "metadata_removed"
    }

    let transactionID: UUID
    let kind: Kind
    var phase: Phase
    let oldProject: Project?
    let newProject: Project
    let stagingFolderName: String?
    let standardNodes: [DocumentNode]?
    let backupPackageFolderName: String?
    let backupManifest: ProjectBackupManifest?

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case kind
        case phase
        case oldProject = "old_project"
        case newProject = "new_project"
        case stagingFolderName = "staging_folder_name"
        case standardNodes = "standard_nodes"
        case backupPackageFolderName = "backup_package_folder_name"
        case backupManifest = "backup_manifest"
    }

    init(
        transactionID: UUID,
        kind: Kind,
        phase: Phase,
        oldProject: Project?,
        newProject: Project,
        stagingFolderName: String?,
        standardNodes: [DocumentNode]?,
        backupPackageFolderName: String? = nil,
        backupManifest: ProjectBackupManifest? = nil
    ) {
        self.transactionID = transactionID
        self.kind = kind
        self.phase = phase
        self.oldProject = oldProject
        self.newProject = newProject
        self.stagingFolderName = stagingFolderName
        self.standardNodes = standardNodes
        self.backupPackageFolderName = backupPackageFolderName
        self.backupManifest = backupManifest
    }
}

private struct ProjectBackupRestorePlan: Equatable {
    let project: Project
    let nodes: [DocumentNode]
}

/// 작품 폴더와 SwiftData 메타데이터 사이의 다단계 작업을 직렬화하고 복구한다.
actor LocalProjectManager: ProjectManaging {
    private static let catalogFileName = ".writerpad-project-catalog.json"
    private static let journalPrefix = ".writerpad-project-transaction-"
    private static let journalSuffix = ".json"

    private let projectRepository: any ProjectRepository
    private let creationMetadataStore: any ProjectCreationMetadataStoring
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let pathResolver: ProjectPathResolver
    private let clock: any AppClock
    private let fileManager: FileManager
    private let faultPlan: ProjectManagerFaultPlan?
    private let projectBackupStore: ProjectBackupStore

    init(
        projectRepository: any ProjectRepository,
        creationMetadataStore: any ProjectCreationMetadataStoring,
        workspaceStateRepository: any WorkspaceStateRepository,
        pathResolver: ProjectPathResolver,
        clock: any AppClock,
        fileManager: FileManager = .default,
        faultPlan: ProjectManagerFaultPlan? = nil,
        projectBackupStore: ProjectBackupStore = ProjectBackupStore()
    ) {
        self.projectRepository = projectRepository
        self.creationMetadataStore = creationMetadataStore
        self.workspaceStateRepository = workspaceStateRepository
        self.pathResolver = pathResolver
        self.clock = clock
        self.fileManager = fileManager
        self.faultPlan = faultPlan
        self.projectBackupStore = projectBackupStore
    }

    func projects() async throws -> [ManagedProject] {
        try await recoverPendingTransactions()
        return try await managedProjectsWithoutRecovery()
    }

    func createProject(named name: String) async throws -> ManagedProject {
        try await recoverPendingTransactions()
        try pathResolver.policy.validateName(name)
        try ensureProjectsRootExists()

        let existingProjects = try await projectRepository.projects()
        if let existing = try idempotentProjectOrThrow(
            named: name,
            existingProjects: existingProjects
        ) {
            return try await requireManagedProject(id: existing.id)
        }
        try validateFilesystemNameIsAvailable(name, excluding: nil)

        let now = clock.now()
        let project = Project(
            id: ProjectID(rawValue: UUID()),
            name: name,
            createdAt: now,
            modifiedAt: now
        )
        let standardNodes = makeStandardNodes(projectID: project.id, at: now)
        let transactionID = UUID()
        let stagingFolderName = ".writerpad-create-\(transactionID.uuidString).tmp"
        let stagingURL = pathResolver.projectsRootURL
            .appendingPathComponent(stagingFolderName, isDirectory: true)
        let finalURL = try pathResolver.standardPaths(forProjectNamed: name).projectContainerURL
        var journal = ProjectTransactionJournal(
            transactionID: transactionID,
            kind: .create,
            phase: .staged,
            oldProject: nil,
            newProject: project,
            stagingFolderName: stagingFolderName,
            standardNodes: standardNodes
        )
        let journalURL = transactionJournalURL(transactionID)

        do {
            try writeJournal(journal, to: journalURL)
            try inject(.afterCreationJournalWrite)
            _ = try pathResolver.createStandardStructure(
                atProjectContainer: stagingURL,
                projectName: name
            )
            try inject(.afterStaging)

            try await creationMetadataStore.saveProjectCreation(
                project,
                standardNodes: standardNodes
            )
            journal.phase = .metadataSaved
            try writeJournal(journal, to: journalURL)
            try inject(.afterMetadataSave)

            try fileManager.moveItem(at: stagingURL, to: finalURL)
            journal.phase = .fileMoved
            try writeJournal(journal, to: journalURL)
            try inject(.afterFileMove)

            var catalog = try loadCatalog()
            appendCatalogEntryIfNeeded(for: project.id, to: &catalog)
            try saveCatalog(catalog)
            try await workspaceStateRepository.setLastProjectID(project.id)
            try removeIfExists(journalURL)
            return try await requireManagedProject(id: project.id)
        } catch let error as ProjectManagerError {
            if case .injectedFailure(recoveryPending: true) = error {
                throw error
            }
            try await rollbackCreation(
                project: project,
                stagingURL: stagingURL,
                finalURL: finalURL,
                journalURL: journalURL
            )
            throw error
        } catch {
            try await rollbackCreation(
                project: project,
                stagingURL: stagingURL,
                finalURL: finalURL,
                journalURL: journalURL
            )
            throw error
        }
    }

    func restoreProjectBackup(at packageURL: URL) async throws -> ManagedProject {
        try await recoverPendingTransactions()
        try ensureProjectsRootExists()

        return try await withSecurityScopedAccess(to: packageURL) {
            let manifest = try await projectBackupStore.validatedManifest(at: packageURL)
            let now = clock.now()
            let plan = try makeRestorePlan(manifest: manifest, at: now)
            guard try await projectRepository.project(id: plan.project.id) == nil else {
                throw ProjectManagerError.projectAlreadyExists(plan.project.id)
            }
            try validateFilesystemNameIsAvailable(plan.project.name, excluding: nil)

            let transactionID = UUID()
            let stagingFolderName = ".writerpad-restore-\(transactionID.uuidString).tmp"
            let packageFolderName = ".writerpad-restore-\(transactionID.uuidString).package"
            let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
                stagingFolderName,
                isDirectory: true
            )
            let stagedPackageURL = pathResolver.projectsRootURL.appendingPathComponent(
                packageFolderName,
                isDirectory: true
            )
            let finalURL = try pathResolver.standardPaths(
                forProjectNamed: plan.project.name
            ).projectContainerURL
            var journal = ProjectTransactionJournal(
                transactionID: transactionID,
                kind: .restoreBackup,
                phase: .staged,
                oldProject: nil,
                newProject: plan.project,
                stagingFolderName: stagingFolderName,
                standardNodes: plan.nodes,
                backupPackageFolderName: packageFolderName,
                backupManifest: manifest
            )
            let journalURL = transactionJournalURL(transactionID)

            do {
                try writeJournal(journal, to: journalURL)
                try inject(.afterRestoreJournalWrite)
                try fileManager.copyItem(at: packageURL, to: stagedPackageURL)
                let stagedManifest = try await projectBackupStore.validatedManifest(
                    at: stagedPackageURL
                )
                guard stagedManifest == manifest else {
                    throw ProjectBackupError.invalidManifest(
                        "앱 내부 staging 복사본이 원본 manifest와 다릅니다."
                    )
                }
                try inject(.afterRestorePackageCopy)

                try materializeRestorePlan(
                    plan,
                    packageURL: stagedPackageURL,
                    stagingURL: stagingURL
                )
                try verifyRestoredProject(plan, manifest: manifest, at: stagingURL)
                try inject(.afterRestoreStaging)

                try await creationMetadataStore.saveProjectCreation(
                    plan.project,
                    standardNodes: plan.nodes
                )
                journal.phase = .metadataSaved
                try writeJournal(journal, to: journalURL)
                try inject(.afterRestoreMetadataSave)

                try fileManager.moveItem(at: stagingURL, to: finalURL)
                journal.phase = .fileMoved
                try writeJournal(journal, to: journalURL)
                try verifyRestoredProject(plan, manifest: manifest, at: finalURL)
                try inject(.afterRestoreFileMove)

                var catalog = try loadCatalog()
                appendCatalogEntryIfNeeded(for: plan.project.id, to: &catalog)
                try saveCatalog(catalog)
                try await workspaceStateRepository.setLastProjectID(plan.project.id)
                try removeIfExists(stagedPackageURL)
                try removeIfExists(journalURL)
                return try await requireManagedProject(id: plan.project.id)
            } catch let error as ProjectManagerError {
                if case .injectedFailure(recoveryPending: true) = error {
                    throw error
                }
                try await rollbackRestoration(
                    plan: plan,
                    manifest: manifest,
                    packageURL: stagedPackageURL,
                    stagingURL: stagingURL,
                    finalURL: finalURL,
                    journalURL: journalURL
                )
                throw error
            } catch {
                try await rollbackRestoration(
                    plan: plan,
                    manifest: manifest,
                    packageURL: stagedPackageURL,
                    stagingURL: stagingURL,
                    finalURL: finalURL,
                    journalURL: journalURL
                )
                throw error
            }
        }
    }

    func restoreLastProject() async throws -> ManagedProject? {
        let managed = try await projects()
        let active = managed.filter(\.isActive)
        guard !active.isEmpty else {
            try await workspaceStateRepository.setLastProjectID(nil)
            return nil
        }
        if let lastID = try await workspaceStateRepository.lastProjectID(),
           let last = active.first(where: { $0.id == lastID }) {
            return last
        }
        let fallback = active[0]
        try await workspaceStateRepository.setLastProjectID(fallback.id)
        return fallback
    }

    func selectProject(id: ProjectID) async throws {
        let project = try await requireManagedProject(id: id)
        guard project.isActive else {
            if project.isInDeletedList {
                throw ProjectManagerError.projectAlreadyInDeletedList(id)
            }
            throw ProjectManagerError.deletionAlreadyRequested(id)
        }
        try await workspaceStateRepository.setLastProjectID(id)
    }

    func renameProject(id: ProjectID, to newName: String) async throws -> ManagedProject {
        try await recoverPendingTransactions()
        try pathResolver.policy.validateName(newName)
        guard let oldProject = try await projectRepository.project(id: id) else {
            throw ProjectManagerError.missingProject(id)
        }
        if oldProject.name.utf8.elementsEqual(newName.utf8) {
            return try await requireManagedProject(id: id)
        }

        let allProjects = try await projectRepository.projects()
        for other in allProjects where other.id != id {
            if pathResolver.policy.collisionKey(for: other.name)
                == pathResolver.policy.collisionKey(for: newName) {
                throw PathPolicyError.nameCollision(other.name)
            }
        }
        try validateFilesystemNameIsAvailable(newName, excluding: oldProject.name)

        let oldURL = try pathResolver.standardPaths(
            forProjectNamed: oldProject.name
        ).projectContainerURL
        guard fileManager.fileExists(atPath: oldURL.path) else {
            throw ProjectManagerError.projectFolderMissing(oldProject.name)
        }
        let newURL = try pathResolver.standardPaths(
            forProjectNamed: newName
        ).projectContainerURL
        let renamed = oldProject.renamed(to: newName, at: clock.now())
        let transactionID = UUID()
        var journal = ProjectTransactionJournal(
            transactionID: transactionID,
            kind: .rename,
            phase: .staged,
            oldProject: oldProject,
            newProject: renamed,
            stagingFolderName: nil,
            standardNodes: nil
        )
        let journalURL = transactionJournalURL(transactionID)

        do {
            try writeJournal(journal, to: journalURL)
            try fileManager.moveItem(at: oldURL, to: newURL)
            try pathResolver.updateStoredProjectName(forProjectNamed: newName)
            journal.phase = .fileMoved
            try writeJournal(journal, to: journalURL)
            try inject(.afterFileMove)

            try await projectRepository.save(renamed)
            journal.phase = .metadataSaved
            try writeJournal(journal, to: journalURL)
            try inject(.afterMetadataSave)

            try removeIfExists(journalURL)
            return try await requireManagedProject(id: id)
        } catch let error as ProjectManagerError {
            if case .injectedFailure(recoveryPending: true) = error {
                throw error
            }
            try await rollbackRename(
                oldProject: oldProject,
                oldURL: oldURL,
                newURL: newURL,
                journalURL: journalURL
            )
            throw error
        } catch {
            try await rollbackRename(
                oldProject: oldProject,
                oldURL: oldURL,
                newURL: newURL,
                journalURL: journalURL
            )
            throw error
        }
    }

    func reorderProjects(_ orderedIDs: [ProjectID]) async throws -> [ManagedProject] {
        var catalog = try loadCatalog()
        let managed = try await managedProjectsWithoutRecovery()
        let visibleIDs = Set(managed.filter { !$0.isInDeletedList }.map(\.id))
        guard orderedIDs.count == visibleIDs.count,
              Set(orderedIDs) == visibleIDs
        else {
            throw ProjectManagerError.invalidOrder
        }
        for (index, id) in orderedIDs.enumerated() {
            guard let entryIndex = catalog.entries.firstIndex(
                where: { $0.projectID == id }
            ) else {
                throw ProjectManagerError.missingProject(id)
            }
            catalog.entries[entryIndex].userOrder = index
        }
        try saveCatalog(catalog)
        return try await managedProjectsWithoutRecovery()
    }

    func prepareDeletion(id: ProjectID) async throws -> ProjectDeletionConfirmation {
        let managed = try await requireManagedProject(id: id)
        guard managed.isActive else {
            if managed.isInDeletedList {
                throw ProjectManagerError.projectAlreadyInDeletedList(id)
            }
            throw ProjectManagerError.deletionAlreadyRequested(id)
        }
        return ProjectDeletionConfirmation(
            projectID: id,
            expectedName: managed.name
        )
    }

    func confirmDeletion(_ confirmation: ProjectDeletionConfirmation) async throws {
        let managed = try await requireManagedProject(id: confirmation.projectID)
        guard managed.name == confirmation.expectedName else {
            throw ProjectManagerError.staleDeletionConfirmation
        }
        guard managed.isActive else {
            if managed.isInDeletedList {
                throw ProjectManagerError.projectAlreadyInDeletedList(
                    confirmation.projectID
                )
            }
            throw ProjectManagerError.deletionAlreadyRequested(confirmation.projectID)
        }
        var catalog = try loadCatalog()
        guard let index = catalog.entries.firstIndex(
            where: { $0.projectID == confirmation.projectID }
        ) else {
            throw ProjectManagerError.missingProject(confirmation.projectID)
        }
        catalog.entries[index].deletionRequestedAt = clock.now()
        try saveCatalog(catalog)
        if try await workspaceStateRepository.lastProjectID() == confirmation.projectID {
            _ = try await selectLastActiveProject()
        }
    }

    func cancelDeletion(id: ProjectID) async throws {
        let managed = try await requireManagedProject(id: id)
        guard managed.isDeletionRequested else {
            throw ProjectManagerError.deletionNotRequested(id)
        }
        var catalog = try loadCatalog()
        guard let index = catalog.entries.firstIndex(where: { $0.projectID == id }) else {
            throw ProjectManagerError.missingProject(id)
        }
        catalog.entries[index].deletionRequestedAt = nil
        try saveCatalog(catalog)
    }

    func prepareMoveToDeletedList(
        id: ProjectID
    ) async throws -> ProjectDeletedListConfirmation {
        let managed = try await requireManagedProject(id: id)
        guard managed.isDeletionRequested else {
            if managed.isInDeletedList {
                throw ProjectManagerError.projectAlreadyInDeletedList(id)
            }
            throw ProjectManagerError.deletionNotRequested(id)
        }
        return ProjectDeletedListConfirmation(
            projectID: id,
            expectedName: managed.name
        )
    }

    @discardableResult
    func moveToDeletedList(
        _ confirmation: ProjectDeletedListConfirmation
    ) async throws -> ManagedProject? {
        let managed = try await requireManagedProject(id: confirmation.projectID)
        guard managed.name == confirmation.expectedName else {
            throw ProjectManagerError.staleDeletionConfirmation
        }
        guard managed.isDeletionRequested else {
            if managed.isInDeletedList {
                throw ProjectManagerError.projectAlreadyInDeletedList(
                    confirmation.projectID
                )
            }
            throw ProjectManagerError.deletionNotRequested(confirmation.projectID)
        }
        var catalog = try loadCatalog()
        guard let index = catalog.entries.firstIndex(
            where: { $0.projectID == confirmation.projectID }
        ) else {
            throw ProjectManagerError.missingProject(confirmation.projectID)
        }
        catalog.entries[index].deletionRequestedAt = nil
        catalog.entries[index].deletedListAt = clock.now()
        try saveCatalog(catalog)
        return try await selectLastActiveProject()
    }

    func restoreFromDeletedList(id: ProjectID) async throws {
        let managed = try await requireManagedProject(id: id)
        guard managed.isInDeletedList else {
            throw ProjectManagerError.projectNotInDeletedList(id)
        }
        var catalog = try loadCatalog()
        guard let index = catalog.entries.firstIndex(where: { $0.projectID == id }) else {
            throw ProjectManagerError.missingProject(id)
        }
        let lastVisibleOrder = catalog.entries
            .filter { $0.deletedListAt == nil && $0.projectID != id }
            .map(\.userOrder)
            .max() ?? -1
        catalog.entries[index].userOrder = lastVisibleOrder + 1
        catalog.entries[index].deletionRequestedAt = nil
        catalog.entries[index].deletedListAt = nil
        try saveCatalog(catalog)
    }

    func preparePermanentDeletion(
        id: ProjectID
    ) async throws -> ProjectPermanentDeletionConfirmation {
        let managed = try await requireManagedProject(id: id)
        guard managed.isInDeletedList else {
            throw ProjectManagerError.projectNotInDeletedList(id)
        }
        return ProjectPermanentDeletionConfirmation(
            projectID: id,
            expectedName: managed.name
        )
    }

    @discardableResult
    func permanentlyDelete(
        _ confirmation: ProjectPermanentDeletionConfirmation
    ) async throws -> ManagedProject? {
        let managed = try await requireManagedProject(id: confirmation.projectID)
        guard managed.name == confirmation.expectedName else {
            throw ProjectManagerError.staleDeletionConfirmation
        }
        guard managed.isInDeletedList else {
            throw ProjectManagerError.projectNotInDeletedList(confirmation.projectID)
        }

        let project = managed.project
        let projectURL = try pathResolver.standardPaths(
            forProjectNamed: project.name
        ).projectContainerURL
        guard fileManager.fileExists(atPath: projectURL.path) else {
            throw ProjectManagerError.projectFolderMissing(project.name)
        }

        let transactionID = UUID()
        let quarantineFolderName =
            ".writerpad-delete-\(transactionID.uuidString).quarantine"
        let quarantineURL = pathResolver.projectsRootURL.appendingPathComponent(
            quarantineFolderName,
            isDirectory: true
        )
        var journal = ProjectTransactionJournal(
            transactionID: transactionID,
            kind: .delete,
            phase: .staged,
            oldProject: nil,
            newProject: project,
            stagingFolderName: quarantineFolderName,
            standardNodes: nil
        )
        let journalURL = transactionJournalURL(transactionID)

        try writeJournal(journal, to: journalURL)
        try fileManager.moveItem(at: projectURL, to: quarantineURL)
        journal.phase = .quarantined
        try writeJournal(journal, to: journalURL)
        try inject(.afterProjectQuarantine)

        try await projectRepository.remove(id: project.id)
        journal.phase = .metadataRemoved
        try writeJournal(journal, to: journalURL)
        try inject(.afterProjectMetadataRemoval)

        try removeCatalogEntry(project.id)
        let replacement = try await selectLastActiveProject()
        try removeIfExists(quarantineURL)
        try removeIfExists(journalURL)
        return replacement
    }

    func exportDescriptor(id: ProjectID) async throws -> ProjectExportDescriptor {
        guard let project = try await projectRepository.project(id: id) else {
            throw ProjectManagerError.missingProject(id)
        }
        let paths = try pathResolver.standardPaths(forProjectNamed: project.name)
        guard fileManager.fileExists(atPath: paths.projectContainerURL.path) else {
            throw ProjectManagerError.projectFolderMissing(project.name)
        }
        return ProjectExportDescriptor(
            projectID: id,
            projectName: project.name,
            projectContainerURL: paths.projectContainerURL,
            suggestedArchiveName: "\(project.name).zip"
        )
    }

    func recoverPendingTransactions() async throws {
        guard fileManager.fileExists(atPath: pathResolver.projectsRootURL.path) else {
            return
        }
        let urls = try fileManager.contentsOfDirectory(
            at: pathResolver.projectsRootURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(Self.journalPrefix)
                && $0.lastPathComponent.hasSuffix(Self.journalSuffix)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for url in urls {
            let journal: ProjectTransactionJournal
            do {
                journal = try JSONDecoder.writerPad.decode(
                    ProjectTransactionJournal.self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw ProjectManagerError.recoveryRequired(url.path)
            }
            switch journal.kind {
            case .create:
                try await recoverCreation(journal, journalURL: url)
            case .rename:
                try await recoverRename(journal, journalURL: url)
            case .delete:
                try await recoverPermanentDeletion(journal, journalURL: url)
            case .restoreBackup:
                try await recoverBackupRestoration(journal, journalURL: url)
            }
        }
    }

    private func recoverBackupRestoration(
        _ journal: ProjectTransactionJournal,
        journalURL: URL
    ) async throws {
        guard let stagingFolderName = journal.stagingFolderName,
              let packageFolderName = journal.backupPackageFolderName,
              let manifest = journal.backupManifest,
              let expectedNodes = journal.standardNodes
        else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        let project = journal.newProject
        let plan = try makeRestorePlan(manifest: manifest, at: project.createdAt)
        guard plan.project == project, plan.nodes == expectedNodes else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }

        let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
            stagingFolderName,
            isDirectory: true
        )
        let packageURL = pathResolver.projectsRootURL.appendingPathComponent(
            packageFolderName,
            isDirectory: true
        )
        let finalURL = try pathResolver.standardPaths(
            forProjectNamed: project.name
        ).projectContainerURL
        var hasStaging = fileManager.fileExists(atPath: stagingURL.path)
        let hasFinal = fileManager.fileExists(atPath: finalURL.path)
        guard !(hasStaging && hasFinal) else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }

        if hasFinal {
            try verifyRestoredProject(plan, manifest: manifest, at: finalURL)
        } else {
            if hasStaging {
                do {
                    try verifyRestoredProject(plan, manifest: manifest, at: stagingURL)
                } catch {
                    guard try await projectRepository.project(id: project.id) == nil,
                          fileManager.fileExists(atPath: packageURL.path)
                    else {
                        throw ProjectManagerError.recoveryRequired(journalURL.path)
                    }
                    let stagedManifest = try await projectBackupStore.validatedManifest(
                        at: packageURL
                    )
                    guard stagedManifest == manifest else {
                        throw ProjectManagerError.recoveryRequired(journalURL.path)
                    }
                    try removeIfExists(stagingURL)
                    try materializeRestorePlan(
                        plan,
                        packageURL: packageURL,
                        stagingURL: stagingURL
                    )
                    hasStaging = true
                }
            }
            if !hasStaging {
                guard fileManager.fileExists(atPath: packageURL.path) else {
                    try await rollbackRestoration(
                        plan: plan,
                        manifest: manifest,
                        packageURL: packageURL,
                        stagingURL: stagingURL,
                        finalURL: finalURL,
                        journalURL: journalURL
                    )
                    return
                }
                do {
                    let stagedManifest = try await projectBackupStore.validatedManifest(
                        at: packageURL
                    )
                    guard stagedManifest == manifest else {
                        throw ProjectBackupError.invalidManifest("복구 staging manifest 불일치")
                    }
                    try materializeRestorePlan(
                        plan,
                        packageURL: packageURL,
                        stagingURL: stagingURL
                    )
                } catch {
                    try await rollbackRestoration(
                        plan: plan,
                        manifest: manifest,
                        packageURL: packageURL,
                        stagingURL: stagingURL,
                        finalURL: finalURL,
                        journalURL: journalURL
                    )
                    return
                }
            }
            try verifyRestoredProject(plan, manifest: manifest, at: stagingURL)
            try await creationMetadataStore.saveProjectCreation(
                project,
                standardNodes: plan.nodes
            )
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        }

        try await creationMetadataStore.saveProjectCreation(
            project,
            standardNodes: plan.nodes
        )
        var catalog = try loadCatalog()
        appendCatalogEntryIfNeeded(for: project.id, to: &catalog)
        try saveCatalog(catalog)
        try await workspaceStateRepository.setLastProjectID(project.id)
        try removeIfExists(packageURL)
        try removeIfExists(journalURL)
    }

    private func recoverCreation(
        _ journal: ProjectTransactionJournal,
        journalURL: URL
    ) async throws {
        guard let stagingFolderName = journal.stagingFolderName else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        let project = journal.newProject
        let stagingURL = pathResolver.projectsRootURL
            .appendingPathComponent(stagingFolderName, isDirectory: true)
        let finalURL = try pathResolver.standardPaths(
            forProjectNamed: project.name
        ).projectContainerURL
        let hasStaging = fileManager.fileExists(atPath: stagingURL.path)
        let hasFinal = fileManager.fileExists(atPath: finalURL.path)
        let hasMetadata = try await projectRepository.project(id: project.id) != nil
        guard let standardNodes = journal.standardNodes, !standardNodes.isEmpty,
              !(hasStaging && hasFinal)
        else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        if hasFinal {
            guard hasMetadata else {
                throw ProjectManagerError.recoveryRequired(journalURL.path)
            }
            try await creationMetadataStore.saveProjectCreation(
                project,
                standardNodes: standardNodes
            )
        } else {
            if !hasStaging {
                _ = try pathResolver.createStandardStructure(
                    atProjectContainer: stagingURL,
                    projectName: project.name
                )
            }
            try await creationMetadataStore.saveProjectCreation(
                project,
                standardNodes: standardNodes
            )
            try fileManager.moveItem(at: stagingURL, to: finalURL)
        }
        var catalog = try loadCatalog()
        appendCatalogEntryIfNeeded(for: project.id, to: &catalog)
        try saveCatalog(catalog)
        try await workspaceStateRepository.setLastProjectID(project.id)
        try removeIfExists(journalURL)
    }

    private func makeStandardNodes(
        projectID: ProjectID,
        at date: Date
    ) -> [DocumentNode] {
        let mainID = DocumentID(rawValue: UUID())
        let main = DocumentNode(
            id: mainID,
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: BinderHierarchyPolicy.topLevelPath,
            userOrder: 0,
            modifiedAt: date,
            contentHash: nil
        )
        let children = BinderFixedCategory.allCases.map { category in
            DocumentNode(
                id: DocumentID(rawValue: UUID()),
                projectID: projectID,
                kind: .folder,
                parentID: mainID,
                relativePath: category.relativePath,
                userOrder: category.fixedOrder,
                modifiedAt: date,
                contentHash: nil
            )
        }
        return [main] + children
    }

    private func recoverRename(
        _ journal: ProjectTransactionJournal,
        journalURL: URL
    ) async throws {
        guard let oldProject = journal.oldProject else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        let newProject = journal.newProject
        let oldURL = try pathResolver.standardPaths(
            forProjectNamed: oldProject.name
        ).projectContainerURL
        let newURL = try pathResolver.standardPaths(
            forProjectNamed: newProject.name
        ).projectContainerURL
        let hasOld = fileManager.fileExists(atPath: oldURL.path)
        let hasNew = fileManager.fileExists(atPath: newURL.path)

        guard hasOld != hasNew else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        if hasNew {
            try pathResolver.updateStoredProjectName(forProjectNamed: newProject.name)
            try await projectRepository.save(newProject)
        } else if let current = try await projectRepository.project(id: oldProject.id),
                  current.name == newProject.name || journal.phase == .metadataSaved {
            try fileManager.moveItem(at: oldURL, to: newURL)
            try pathResolver.updateStoredProjectName(forProjectNamed: newProject.name)
            try await projectRepository.save(newProject)
        } else {
            try pathResolver.updateStoredProjectName(forProjectNamed: oldProject.name)
            try await projectRepository.save(oldProject)
        }
        try removeIfExists(journalURL)
    }

    private func recoverPermanentDeletion(
        _ journal: ProjectTransactionJournal,
        journalURL: URL
    ) async throws {
        guard let quarantineFolderName = journal.stagingFolderName else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
        let project = journal.newProject
        let projectURL = try pathResolver.standardPaths(
            forProjectNamed: project.name
        ).projectContainerURL
        let quarantineURL = pathResolver.projectsRootURL.appendingPathComponent(
            quarantineFolderName,
            isDirectory: true
        )
        let hasProjectFolder = fileManager.fileExists(atPath: projectURL.path)
        let hasQuarantine = fileManager.fileExists(atPath: quarantineURL.path)

        guard !(hasProjectFolder && hasQuarantine) else {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }

        if hasProjectFolder {
            try fileManager.moveItem(at: projectURL, to: quarantineURL)
        } else if !hasQuarantine,
                  try await projectRepository.project(id: project.id) != nil {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }

        if try await projectRepository.project(id: project.id) != nil {
            try await projectRepository.remove(id: project.id)
        }
        try removeCatalogEntry(project.id)
        _ = try await selectLastActiveProject()
        try removeIfExists(quarantineURL)
        try removeIfExists(journalURL)
    }

    private func selectLastActiveProject() async throws -> ManagedProject? {
        let activeProjects = try await managedProjectsWithoutRecovery().filter(\.isActive)
        let currentID = try await workspaceStateRepository.lastProjectID()
        let selected = currentID.flatMap { id in
            activeProjects.first { $0.id == id }
        } ?? activeProjects.first
        try await workspaceStateRepository.setLastProjectID(selected?.id)
        return selected
    }

    private func managedProjectsWithoutRecovery() async throws -> [ManagedProject] {
        let projects = try await projectRepository.projects()
        var catalog = try loadCatalog()
        let validIDs = Set(projects.map(\.id))
        catalog.entries.removeAll { !validIDs.contains($0.projectID) }
        for project in projects {
            appendCatalogEntryIfNeeded(for: project.id, to: &catalog)
        }
        try saveCatalog(catalog)

        let entries = Dictionary(
            uniqueKeysWithValues: catalog.entries.map { ($0.projectID, $0) }
        )
        return projects.map { project in
            let entry = entries[project.id]!
            return ManagedProject(
                project: project,
                userOrder: entry.userOrder,
                lifecycleState: lifecycleState(for: entry)
            )
        }.sorted {
            if $0.userOrder == $1.userOrder {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.userOrder < $1.userOrder
        }
    }

    private func lifecycleState(
        for entry: ProjectCatalog.Entry
    ) -> ProjectLifecycleState {
        if let deletedListAt = entry.deletedListAt {
            return .deletedList(at: deletedListAt)
        }
        if let deletionRequestedAt = entry.deletionRequestedAt {
            return .deletionRequested(at: deletionRequestedAt)
        }
        return .active
    }

    private func requireManagedProject(id: ProjectID) async throws -> ManagedProject {
        guard let project = try await managedProjectsWithoutRecovery().first(
            where: { $0.id == id }
        ) else {
            throw ProjectManagerError.missingProject(id)
        }
        return project
    }

    private func idempotentProjectOrThrow(
        named name: String,
        existingProjects: [Project]
    ) throws -> Project? {
        let key = pathResolver.policy.collisionKey(for: name)
        for project in existingProjects
        where pathResolver.policy.collisionKey(for: project.name) == key {
            guard project.name.utf8.elementsEqual(name.utf8) else {
                throw PathPolicyError.nameCollision(project.name)
            }
            let url = try pathResolver.standardPaths(
                forProjectNamed: project.name
            ).projectContainerURL
            guard fileManager.fileExists(atPath: url.path) else {
                throw ProjectManagerError.projectFolderMissing(project.name)
            }
            return project
        }
        return nil
    }

    private func validateFilesystemNameIsAvailable(
        _ name: String,
        excluding excludedName: String?
    ) throws {
        let urls = try fileManager.contentsOfDirectory(
            at: pathResolver.projectsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let names = urls.map(\.lastPathComponent).filter { existing in
            guard let excludedName else { return true }
            return !existing.utf8.elementsEqual(excludedName.utf8)
        }
        try pathResolver.policy.validateUniqueName(name, among: names)
    }

    private func makeRestorePlan(
        manifest: ProjectBackupManifest,
        at date: Date
    ) throws -> ProjectBackupRestorePlan {
        guard let rawProjectID = UUID(uuidString: manifest.project.uuid) else {
            throw ProjectBackupError.invalidManifest("project.uuid")
        }
        let projectID = ProjectID(rawValue: rawProjectID)
        let project = Project(
            id: projectID,
            name: manifest.project.title,
            createdAt: date,
            modifiedAt: date
        )
        let entriesByID = Dictionary(
            uniqueKeysWithValues: manifest.nodes.map { ($0.uuid, $0) }
        )
        let roots = manifest.nodes.filter { $0.parentUUID == nil }
        guard roots.count == 1, let mainEntry = roots.first,
              mainEntry.kind == "folder", mainEntry.title == "메인",
              mainEntry.order == 0
        else {
            throw ProjectBackupError.invalidManifest(
                "루트는 order 0인 메인 폴더 하나여야 합니다."
            )
        }

        var pathsByID: [String: RelativeDocumentPath] = [:]
        var resolving: Set<String> = []
        func resolvePath(for id: String) throws -> RelativeDocumentPath {
            if let existing = pathsByID[id] { return existing }
            guard let entry = entriesByID[id] else {
                throw ProjectBackupError.invalidManifest("없는 node.uuid: \(id)")
            }
            guard resolving.insert(id).inserted else {
                throw ProjectBackupError.invalidManifest("순환 parent_uuid: \(id)")
            }
            let storedName: String
            if entry.kind == "document" {
                storedName = try pathResolver.policy.textFileName(
                    forDisplayName: entry.title
                )
            } else {
                try pathResolver.policy.validateName(entry.title)
                storedName = entry.title
            }
            let rawPath: String
            if let parentUUID = entry.parentUUID {
                let parentPath = try resolvePath(for: parentUUID)
                rawPath = parentPath.rawValue + "/" + storedName
            } else {
                rawPath = storedName
            }
            let path = RelativeDocumentPath(rawValue: rawPath)
            try pathResolver.policy.validateRelativePath(path)
            resolving.remove(id)
            pathsByID[id] = path
            return path
        }

        for id in entriesByID.keys {
            _ = try resolvePath(for: id)
        }
        var normalizedPaths: Set<String> = []
        for (id, path) in pathsByID {
            let key = path.rawValue.split(separator: "/").map {
                pathResolver.policy.collisionKey(for: String($0))
            }.joined(separator: "/")
            guard normalizedPaths.insert(key).inserted else {
                throw ProjectBackupError.invalidManifest(
                    "복원 저장 이름 충돌: \(id)"
                )
            }
        }

        let requiredStandardPaths = Set(
            [BinderHierarchyPolicy.topLevelPath.rawValue]
                + BinderFixedCategory.allCases.map(\.relativePath.rawValue)
        )
        let folderPaths = Set(manifest.nodes.compactMap { entry in
            entry.kind == "folder" ? pathsByID[entry.uuid]?.rawValue : nil
        })
        let missingStandardPaths = requiredStandardPaths.subtracting(folderPaths)
        guard missingStandardPaths.isEmpty else {
            throw ProjectBackupError.invalidManifest(
                "표준 identity 노드 누락: \(missingStandardPaths.sorted().joined(separator: ", "))"
            )
        }

        let trashPrefix = BinderFixedCategory.trash.relativePath.rawValue + "/"
        let nodes = try manifest.nodes.map { entry -> DocumentNode in
            guard let rawID = UUID(uuidString: entry.uuid),
                  let path = pathsByID[entry.uuid]
            else {
                throw ProjectBackupError.invalidManifest("node.uuid: \(entry.uuid)")
            }
            let kind: DocumentKind = entry.kind == "folder" ? .folder : .text
            let deletionStatus: DocumentDeletionStatus = path.rawValue.hasPrefix(trashPrefix)
                ? .trashed(originalPath: path, deletedAt: date)
                : .active
            return DocumentNode(
                id: DocumentID(rawValue: rawID),
                projectID: projectID,
                kind: kind,
                parentID: entry.parentUUID.flatMap(UUID.init(uuidString:)).map {
                    DocumentID(rawValue: $0)
                },
                relativePath: path,
                userOrder: entry.order,
                modifiedAt: date,
                contentHash: entry.sha256.flatMap(ContentHash.init(rawValue:)),
                deletionStatus: deletionStatus
            )
        }.sorted {
            let leftDepth = $0.relativePath.rawValue.split(separator: "/").count
            let rightDepth = $1.relativePath.rawValue.split(separator: "/").count
            if leftDepth == rightDepth {
                if $0.parentID == $1.parentID { return $0.userOrder < $1.userOrder }
                return $0.relativePath.rawValue < $1.relativePath.rawValue
            }
            return leftDepth < rightDepth
        }
        return ProjectBackupRestorePlan(project: project, nodes: nodes)
    }

    private func materializeRestorePlan(
        _ plan: ProjectBackupRestorePlan,
        packageURL: URL,
        stagingURL: URL
    ) throws {
        let paths = try pathResolver.createStandardStructure(
            atProjectContainer: stagingURL,
            projectName: plan.project.name
        )
        let payloadRoot = packageURL.appendingPathComponent(
            ProjectBackupStore.workspaceDirectoryName,
            isDirectory: true
        )
        for node in plan.nodes {
            let destination = paths.workspaceRootURL.appendingPathComponent(
                node.relativePath.rawValue,
                isDirectory: node.kind == .folder
            )
            if node.kind == .folder {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw ProjectBackupError.invalidManifest(
                            "폴더 위치에 파일이 있습니다: \(node.relativePath.rawValue)"
                        )
                    }
                } else {
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: false
                    )
                }
            } else {
                let source = payloadRoot.appendingPathComponent(
                    node.id.rawValue.uuidString.lowercased()
                )
                let data = try Data(contentsOf: source)
                try data.write(to: destination, options: [.atomic])
            }
        }
        try writeFallbackTrashRecords(for: plan.nodes, workspaceURL: paths.workspaceRootURL)
    }

    private func writeFallbackTrashRecords(
        for nodes: [DocumentNode],
        workspaceURL: URL
    ) throws {
        guard let trash = nodes.first(where: {
            $0.relativePath == BinderFixedCategory.trash.relativePath
        }) else { return }
        let roots = nodes.filter { $0.parentID == trash.id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for node in roots {
            let record = TrashRecord(
                documentID: node.id,
                originalPath: node.relativePath,
                originalParentID: trash.id,
                originalUserOrder: node.userOrder,
                deletedAt: node.modifiedAt
            )
            let url = workspaceURL.appendingPathComponent(
                ".writerpad-trash-" + node.id.rawValue.uuidString.lowercased() + ".json"
            )
            try encoder.encode(record).write(to: url, options: [.atomic])
        }
    }

    private func verifyRestoredProject(
        _ plan: ProjectBackupRestorePlan,
        manifest: ProjectBackupManifest,
        at projectContainerURL: URL
    ) throws {
        let workspaceURL = try pathResolver.standardPaths(
            atProjectContainer: projectContainerURL,
            projectName: plan.project.name
        ).workspaceRootURL
        let entriesByID = Dictionary(
            uniqueKeysWithValues: manifest.nodes.map { ($0.uuid, $0) }
        )
        let hasher = SHA256ContentHasher()
        for node in plan.nodes {
            let url = workspaceURL.appendingPathComponent(
                node.relativePath.rawValue,
                isDirectory: node.kind == .folder
            )
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue == (node.kind == .folder)
            else {
                throw ProjectBackupError.fileVerificationFailed(
                    node.id.rawValue.uuidString.lowercased()
                )
            }
            guard node.kind == .text else { continue }
            let id = node.id.rawValue.uuidString.lowercased()
            guard let entry = entriesByID[id],
                  let expectedBytes = entry.bytes,
                  let expectedHash = entry.sha256
            else {
                throw ProjectBackupError.invalidDocumentEntry(id)
            }
            let data = try Data(contentsOf: url)
            guard data.count == expectedBytes,
                  hasher.sha256(for: data).rawValue == expectedHash
            else {
                throw ProjectBackupError.fileVerificationFailed(id)
            }
        }
        if let trash = plan.nodes.first(where: {
            $0.relativePath == BinderFixedCategory.trash.relativePath
        }) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for node in plan.nodes where node.parentID == trash.id {
                let recordURL = workspaceURL.appendingPathComponent(
                    ".writerpad-trash-"
                        + node.id.rawValue.uuidString.lowercased()
                        + ".json"
                )
                let record = try decoder.decode(
                    TrashRecord.self,
                    from: Data(contentsOf: recordURL)
                )
                guard record.documentID == node.id,
                      record.originalPath == node.relativePath,
                      record.originalParentID == trash.id
                else {
                    throw ProjectBackupError.fileVerificationFailed(
                        node.id.rawValue.uuidString.lowercased()
                    )
                }
            }
        }
    }

    private func rollbackRestoration(
        plan: ProjectBackupRestorePlan,
        manifest: ProjectBackupManifest,
        packageURL: URL,
        stagingURL: URL,
        finalURL: URL,
        journalURL: URL
    ) async throws {
        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                do {
                    try verifyRestoredProject(plan, manifest: manifest, at: finalURL)
                } catch {
                    throw ProjectManagerError.recoveryRequired(journalURL.path)
                }
            }
            try removeIfExists(packageURL)
            try removeIfExists(stagingURL)
            try removeIfExists(finalURL)
            if try await projectRepository.project(id: plan.project.id) != nil {
                try await projectRepository.remove(id: plan.project.id)
            }
            try removeCatalogEntry(plan.project.id)
            try removeIfExists(journalURL)
        } catch {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
    }

    private func withSecurityScopedAccess<T: Sendable>(
        to url: URL,
        operation: () async throws -> T
    ) async throws -> T {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try await operation()
    }

    private func rollbackCreation(
        project: Project,
        stagingURL: URL,
        finalURL: URL,
        journalURL: URL
    ) async throws {
        do {
            try removeIfExists(stagingURL)
            try removeIfExists(finalURL)
            if try await projectRepository.project(id: project.id) != nil {
                try await projectRepository.remove(id: project.id)
            }
            try removeCatalogEntry(project.id)
            try removeIfExists(journalURL)
        } catch {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
    }

    private func rollbackRename(
        oldProject: Project,
        oldURL: URL,
        newURL: URL,
        journalURL: URL
    ) async throws {
        do {
            if fileManager.fileExists(atPath: newURL.path),
               !fileManager.fileExists(atPath: oldURL.path) {
                try fileManager.moveItem(at: newURL, to: oldURL)
            }
            if fileManager.fileExists(atPath: oldURL.path) {
                try pathResolver.updateStoredProjectName(forProjectNamed: oldProject.name)
            }
            try await projectRepository.save(oldProject)
            try removeIfExists(journalURL)
        } catch {
            throw ProjectManagerError.recoveryRequired(journalURL.path)
        }
    }

    private func ensureProjectsRootExists() throws {
        try fileManager.createDirectory(
            at: pathResolver.projectsRootURL,
            withIntermediateDirectories: true
        )
    }

    private var catalogURL: URL {
        pathResolver.projectsRootURL.appendingPathComponent(Self.catalogFileName)
    }

    private func transactionJournalURL(_ id: UUID) -> URL {
        pathResolver.projectsRootURL.appendingPathComponent(
            "\(Self.journalPrefix)\(id.uuidString)\(Self.journalSuffix)"
        )
    }

    private func loadCatalog() throws -> ProjectCatalog {
        try ensureProjectsRootExists()
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            return ProjectCatalog()
        }
        return try JSONDecoder.writerPad.decode(
            ProjectCatalog.self,
            from: Data(contentsOf: catalogURL)
        )
    }

    private func saveCatalog(_ catalog: ProjectCatalog) throws {
        try writeAtomically(catalog, to: catalogURL)
    }

    private func appendCatalogEntryIfNeeded(
        for id: ProjectID,
        to catalog: inout ProjectCatalog
    ) {
        guard !catalog.entries.contains(where: { $0.projectID == id }) else { return }
        let nextOrder = (catalog.entries.map(\.userOrder).max() ?? -1) + 1
        catalog.entries.append(
            ProjectCatalog.Entry(
                projectID: id,
                userOrder: nextOrder,
                deletionRequestedAt: nil,
                deletedListAt: nil
            )
        )
    }

    private func removeCatalogEntry(_ id: ProjectID) throws {
        var catalog = try loadCatalog()
        catalog.entries.removeAll { $0.projectID == id }
        try saveCatalog(catalog)
    }

    private func writeJournal(
        _ journal: ProjectTransactionJournal,
        to url: URL
    ) throws {
        try writeAtomically(journal, to: url)
    }

    private func writeAtomically<T: Encodable>(_ value: T, to url: URL) throws {
        var data = try JSONEncoder.writerPad.encode(value)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func inject(_ point: ProjectManagerFaultPoint) throws {
        guard let faultPlan, faultPlan.point == point else { return }
        throw ProjectManagerError.injectedFailure(
            recoveryPending: faultPlan.leavesTransactionForRecovery
        )
    }
}

private extension JSONEncoder {
    static var writerPad: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var writerPad: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
