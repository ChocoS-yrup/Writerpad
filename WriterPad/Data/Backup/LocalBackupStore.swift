import Foundation

actor LocalBackupStore: BackupStoring {
    static let largeAutomaticSnapshotByteCount = 1_048_576
    static let largeAutomaticSnapshotMinimumInterval: TimeInterval = 5 * 60

    private let workspaceLocator: any ProjectWorkspaceLocating
    private let fileManager: FileManager
    private let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let hasher: any ContentHashing
    private let calendar: Calendar
    private(set) var directoryEnumerationCount = 0

    init(
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        calendar: Calendar = LocalBackupStore.utcCalendar
    ) {
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.calendar = calendar
    }

    func snapshots(
        for documentID: DocumentID,
        projectID: ProjectID
    ) async throws -> [BackupSnapshot] {
        let all = try await allSnapshots(projectID: projectID)
        return all.filter { $0.documentID == documentID }
            .sorted(by: Self.newestFirst)
    }

    func createSnapshot(
        for document: DocumentNode,
        reason: BackupReason
    ) async throws -> BackupSnapshot {
        guard document.kind == .text else { throw BackupStoreError.textDocumentRequired }
        let root = try await workspaceLocator.workspaceRoot(for: document.projectID)
        let source = try validatedURL(document.relativePath, workspaceRoot: root)
        let data = try Data(contentsOf: source)
        guard String(data: data, encoding: .utf8) != nil else {
            throw BackupStoreError.invalidUTF8(BackupID(rawValue: UUID()))
        }
        let hash = hasher.sha256(for: data)
        return try await createSnapshot(
            for: document,
            reason: reason,
            data: data,
            hash: hash,
            workspaceRoot: root
        )
    }

    func createSnapshotAndApplyRetention(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent,
        policy: BackupPolicy
    ) async throws -> BackupMaintenanceResult {
        guard document.kind == .text else { throw BackupStoreError.textDocumentRequired }
        let root = try await workspaceLocator.workspaceRoot(for: document.projectID)
        var inventory = try allSnapshots(projectID: document.projectID, workspaceRoot: root)
        let snapshot: BackupSnapshot
        if let reusable = Self.reusableLargeAutomaticSnapshot(
            in: inventory,
            documentID: document.id,
            reason: reason,
            byteCount: savedContent.utf8Data.count,
            now: clock.now()
        ) {
            snapshot = reusable
        } else if reason.mayCoalesceDuplicate,
           let latest = inventory
            .filter({ $0.documentID == document.id })
            .sorted(by: Self.newestFirst)
            .first,
           latest.contentHash == savedContent.contentHash {
            snapshot = latest
        } else {
            snapshot = try writeSnapshot(
                for: document,
                reason: reason,
                data: savedContent.utf8Data,
                hash: savedContent.contentHash,
                workspaceRoot: root
            )
            inventory.append(snapshot)
        }
        let cleanup = applyRetentionPolicy(
            policy,
            snapshots: inventory,
            workspaceRoot: root
        )
        return BackupMaintenanceResult(snapshot: snapshot, cleanup: cleanup)
    }

    static func reusableLargeAutomaticSnapshot(
        in snapshots: [BackupSnapshot],
        documentID: DocumentID,
        reason: BackupReason,
        byteCount: Int,
        now: Date
    ) -> BackupSnapshot? {
        guard reason == .automaticSave,
              byteCount >= largeAutomaticSnapshotByteCount,
              let latest = snapshots
                .filter({
                    $0.documentID == documentID && $0.reason == .automaticSave
                })
                .sorted(by: newestFirst)
                .first
        else { return nil }
        let age = now.timeIntervalSince(latest.createdAt)
        guard age >= 0, age < largeAutomaticSnapshotMinimumInterval else {
            return nil
        }
        return latest
    }

    func createSnapshot(
        for document: DocumentNode,
        reason: BackupReason,
        savedContent: SavedDocumentContent
    ) async throws -> BackupSnapshot {
        guard document.kind == .text else { throw BackupStoreError.textDocumentRequired }
        let root = try await workspaceLocator.workspaceRoot(for: document.projectID)
        return try await createSnapshot(
            for: document,
            reason: reason,
            data: savedContent.utf8Data,
            hash: savedContent.contentHash,
            workspaceRoot: root
        )
    }

    private func createSnapshot(
        for document: DocumentNode,
        reason: BackupReason,
        data: Data,
        hash: ContentHash,
        workspaceRoot root: URL
    ) async throws -> BackupSnapshot {
        if reason.mayCoalesceDuplicate,
           let latest = try allSnapshots(
            projectID: document.projectID,
            workspaceRoot: root
           )
            .filter({ $0.documentID == document.id })
            .sorted(by: Self.newestFirst)
            .first,
           latest.contentHash == hash {
            return latest
        }

        return try writeSnapshot(
            for: document,
            reason: reason,
            data: data,
            hash: hash,
            workspaceRoot: root
        )
    }

    private func writeSnapshot(
        for document: DocumentNode,
        reason: BackupReason,
        data: Data,
        hash: ContentHash,
        workspaceRoot root: URL
    ) throws -> BackupSnapshot {
        let snapshot = BackupSnapshot(
            id: BackupID(rawValue: uuidGenerator.makeUUID()),
            projectID: document.projectID,
            documentID: document.id,
            relativePath: document.relativePath,
            createdAt: clock.now(),
            contentHash: hash,
            reason: reason,
            isPinned: false
        )
        let directory = try backupDirectory(reason: reason, workspaceRoot: root, creates: true)
        let textURL = directory.appendingPathComponent(fileName(snapshot.id, extension: "txt"))
        let metadataURL = directory.appendingPathComponent(fileName(snapshot.id, extension: "json"))
        do {
            try data.write(to: textURL, options: [.atomic])
            try encoded(snapshot).write(to: metadataURL, options: [.atomic])
        } catch {
            try? fileManager.removeItem(at: textURL)
            try? fileManager.removeItem(at: metadataURL)
            throw error
        }
        return snapshot
    }

    func text(for snapshot: BackupSnapshot) async throws -> String {
        let root = try await workspaceLocator.workspaceRoot(for: snapshot.projectID)
        let url = try snapshotTextURL(snapshot, workspaceRoot: root)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BackupStoreError.snapshotNotFound(snapshot.id)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackupStoreError.invalidUTF8(snapshot.id)
        }
        guard hasher.sha256(for: data) == snapshot.contentHash else {
            throw BackupStoreError.hashMismatch(snapshot.id)
        }
        return text
    }

    func setPinned(
        _ isPinned: Bool,
        snapshot: BackupSnapshot
    ) async throws -> BackupSnapshot {
        let root = try await workspaceLocator.workspaceRoot(for: snapshot.projectID)
        _ = try await text(for: snapshot)
        let changed = BackupSnapshot(
            id: snapshot.id,
            projectID: snapshot.projectID,
            documentID: snapshot.documentID,
            relativePath: snapshot.relativePath,
            createdAt: snapshot.createdAt,
            contentHash: snapshot.contentHash,
            reason: snapshot.reason,
            isPinned: isPinned
        )
        try encoded(changed).write(
            to: try snapshotMetadataURL(snapshot, workspaceRoot: root),
            options: [.atomic]
        )
        return changed
    }

    func delete(_ snapshot: BackupSnapshot) async throws {
        let root = try await workspaceLocator.workspaceRoot(for: snapshot.projectID)
        try delete(snapshot, workspaceRoot: root)
    }

    private func delete(_ snapshot: BackupSnapshot, workspaceRoot root: URL) throws {
        let textURL = try snapshotTextURL(snapshot, workspaceRoot: root)
        let metadataURL = try snapshotMetadataURL(snapshot, workspaceRoot: root)
        if fileManager.fileExists(atPath: textURL.path) { try fileManager.removeItem(at: textURL) }
        if fileManager.fileExists(atPath: metadataURL.path) { try fileManager.removeItem(at: metadataURL) }
    }

    func applyRetentionPolicy(
        _ policy: BackupPolicy,
        projectID: ProjectID
    ) async throws -> BackupCleanupReport {
        let root = try await workspaceLocator.workspaceRoot(for: projectID)
        let snapshots = try allSnapshots(projectID: projectID, workspaceRoot: root)
        return applyRetentionPolicy(policy, snapshots: snapshots, workspaceRoot: root)
    }

    private func applyRetentionPolicy(
        _ policy: BackupPolicy,
        snapshots: [BackupSnapshot],
        workspaceRoot root: URL
    ) -> BackupCleanupReport {
        let deletion = Self.snapshotsToDelete(
            snapshots,
            now: clock.now(),
            policy: policy,
            calendar: calendar
        )
        var deleted: [BackupID] = []
        var issues: [BackupCleanupIssue] = []
        for snapshot in deletion {
            do {
                try delete(snapshot, workspaceRoot: root)
                deleted.append(snapshot.id)
            } catch {
                issues.append(.init(snapshotID: snapshot.id, reason: error.localizedDescription))
            }
        }
        return BackupCleanupReport(deletedSnapshotIDs: deleted, issues: issues)
    }

    static func snapshotsToDelete(
        _ snapshots: [BackupSnapshot],
        now: Date,
        policy: BackupPolicy,
        calendar: Calendar = utcCalendar
    ) -> [BackupSnapshot] {
        let day: TimeInterval = 24 * 60 * 60
        let recentCutoff = now.addingTimeInterval(-day)
        let retentionCutoff = now.addingTimeInterval(-day * Double(policy.retentionDays))
        let uniqueSnapshots = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: preferredDuplicate
        ).values
        var deletion: [BackupSnapshot] = []
        for group in Dictionary(grouping: uniqueSnapshots, by: \BackupSnapshot.documentID).values {
            let candidates = group.filter { !$0.isPinned }.sorted(by: newestFirst)
            let recent = candidates.filter { $0.createdAt >= recentCutoff && $0.createdAt <= now }
            deletion.append(contentsOf: recent.dropFirst(policy.maximumRecentSnapshots))

            let older = candidates.filter { $0.createdAt < recentCutoff }
            var keptDays: Set<Date> = []
            for snapshot in older {
                guard snapshot.createdAt >= retentionCutoff else {
                    deletion.append(snapshot)
                    continue
                }
                let key = calendar.startOfDay(for: snapshot.createdAt)
                if !keptDays.insert(key).inserted { deletion.append(snapshot) }
            }
        }
        return Array(
            Dictionary(
                deletion.map { ($0.id, $0) },
                uniquingKeysWith: preferredDuplicate
            ).values
        )
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func allSnapshots(projectID: ProjectID) async throws -> [BackupSnapshot] {
        let root = try await workspaceLocator.workspaceRoot(for: projectID)
        return try allSnapshots(projectID: projectID, workspaceRoot: root)
    }

    private func allSnapshots(
        projectID: ProjectID,
        workspaceRoot root: URL
    ) throws -> [BackupSnapshot] {
        var scannedDirectories: Set<String> = []
        var snapshotsByID: [BackupID: BackupSnapshot] = [:]
        for reason in BackupReason.allStorageReasons {
            let directory = try backupDirectory(reason: reason, workspaceRoot: root, creates: false)
            guard scannedDirectories.insert(directory.standardizedFileURL.path).inserted else {
                continue
            }
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            directoryEnumerationCount += 1
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for url in urls where url.pathExtension.lowercased() == "json" {
                if let snapshot = try? decoded(
                    BackupSnapshot.self,
                    from: Data(contentsOf: url)
                ) {
                    if let existing = snapshotsByID[snapshot.id] {
                        snapshotsByID[snapshot.id] = Self.preferredDuplicate(
                            existing,
                            snapshot
                        )
                    } else {
                        snapshotsByID[snapshot.id] = snapshot
                    }
                }
            }
        }
        return Array(snapshotsByID.values)
    }

    private func validatedURL(_ path: RelativeDocumentPath, workspaceRoot: URL) throws -> URL {
        let resolver = ProjectPathResolver(
            projectsRootURL: workspaceRoot.deletingLastPathComponent(),
            fileManager: fileManager
        )
        return try resolver.validatedURL(for: path, in: workspaceRoot)
    }

    private func backupDirectory(reason: BackupReason, workspaceRoot: URL, creates: Bool) throws -> URL {
        let directory = workspaceRoot.appendingPathComponent(reason.directoryPath, isDirectory: true)
        if creates { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }

    private func snapshotTextURL(_ snapshot: BackupSnapshot, workspaceRoot: URL) throws -> URL {
        try backupDirectory(reason: snapshot.reason, workspaceRoot: workspaceRoot, creates: false)
            .appendingPathComponent(fileName(snapshot.id, extension: "txt"))
    }

    private func snapshotMetadataURL(_ snapshot: BackupSnapshot, workspaceRoot: URL) throws -> URL {
        try backupDirectory(reason: snapshot.reason, workspaceRoot: workspaceRoot, creates: false)
            .appendingPathComponent(fileName(snapshot.id, extension: "json"))
    }

    private func fileName(_ id: BackupID, extension pathExtension: String) -> String {
        id.rawValue.uuidString.lowercased() + "." + pathExtension
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func newestFirst(_ lhs: BackupSnapshot, _ rhs: BackupSnapshot) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    /// 같은 ID의 메타데이터가 중복 발견되면 삭제보다 보존을 우선한다.
    private static func preferredDuplicate(
        _ lhs: BackupSnapshot,
        _ rhs: BackupSnapshot
    ) -> BackupSnapshot {
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned ? lhs : rhs
        }
        return newestFirst(lhs, rhs) ? lhs : rhs
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private extension BackupReason {
    static let allStorageReasons: [BackupReason] = [
        .automaticSave, .editingInterval, .documentTransition, .documentClose,
        .beforeStructureChange, .beforeRestore, .conflict, .manual
    ]

    var mayCoalesceDuplicate: Bool {
        switch self {
        case .automaticSave, .editingInterval, .documentTransition, .documentClose: true
        case .beforeStructureChange, .beforeRestore, .conflict, .manual: false
        }
    }

    var directoryPath: String {
        switch self {
        case .automaticSave, .editingInterval, .documentTransition,
             .documentClose, .beforeStructureChange, .manual:
            "백업/자동저장"
        case .beforeRestore: "백업/복원전"
        case .conflict: "백업/충돌"
        }
    }
}

actor DocumentRestoreCoordinator {
    private let documentStore: any LocalDocumentStoring
    private let backupStore: any BackupStoring
    private let documentRepository: (any DocumentRepository)?
    private let binderCommands: (any BinderCommanding)?
    private let futureChangeNotifier: any FutureChangeNotifying
    private let pathPolicy: PathPolicy

    init(
        documentStore: any LocalDocumentStoring,
        backupStore: any BackupStoring,
        documentRepository: (any DocumentRepository)? = nil,
        binderCommands: (any BinderCommanding)? = nil,
        futureChangeNotifier: any FutureChangeNotifying = NoOpFutureChangeNotifier(),
        pathPolicy: PathPolicy = PathPolicy()
    ) {
        self.documentStore = documentStore
        self.backupStore = backupStore
        self.documentRepository = documentRepository
        self.binderCommands = binderCommands
        self.futureChangeNotifier = futureChangeNotifier
        self.pathPolicy = pathPolicy
    }

    func restore(_ request: DocumentRestoreRequest) async throws -> DocumentRestoreResult {
        try validate(snapshot: request.snapshot, for: request.document)

        let currentReceipt = try await documentStore.save(
            DocumentSaveRequest(
                projectID: request.document.projectID,
                documentID: request.document.id,
                relativePath: request.document.relativePath,
                text: request.currentText,
                generation: request.saveGeneration
            )
        )
        if let savedContent = currentReceipt.savedContent {
            _ = try await backupStore.createSnapshot(
                for: request.document,
                reason: .beforeRestore,
                savedContent: savedContent
            )
        } else {
            _ = try await backupStore.createSnapshot(
                for: request.document,
                reason: .beforeRestore
            )
        }
        let restoredText = try await backupStore.text(for: request.snapshot)
        let receipt = try await documentStore.save(
            DocumentSaveRequest(
                projectID: request.document.projectID,
                documentID: request.document.id,
                relativePath: request.document.relativePath,
                text: restoredText,
                generation: request.saveGeneration &+ 1,
                durableBatchKind: .backupRestore
            )
        )
        await futureChangeNotifier.record(
            .documentRestored(
                projectID: receipt.projectID,
                documentID: receipt.documentID,
                contentHash: receipt.contentHash
            )
        )
        return DocumentRestoreResult(receipt: receipt, restoredText: restoredText)
    }

    func restoreAsCopy(
        _ request: DocumentBackupCopyRequest
    ) async throws -> DocumentBackupCopyResult {
        try validate(snapshot: request.snapshot, for: request.document)
        guard let documentRepository, let binderCommands else {
            throw BackupStoreError.copyServiceUnavailable
        }

        // 손상된 백업 때문에 빈 문서가 생기지 않도록 생성 작업보다 먼저 검증해 읽는다.
        let copiedText = try await backupStore.text(for: request.snapshot)
        let documents = try await documentRepository.documents(
            in: request.document.projectID
        )
        let destinationParentID = try copyDestinationParentID(
            for: request.document,
            documents: documents
        )
        let creation = try await binderCommands.create(
            kind: .text,
            named: copyDisplayName(for: request.document.relativePath),
            in: destinationParentID,
            projectID: request.document.projectID
        )
        guard let copiedDocument = try await documentRepository.document(
            id: creation.affectedDocumentID
        ) else {
            throw BackupStoreError.copyDestinationUnavailable
        }
        let receipt = try await documentStore.save(
            DocumentSaveRequest(
                projectID: copiedDocument.projectID,
                documentID: copiedDocument.id,
                relativePath: copiedDocument.relativePath,
                text: copiedText,
                generation: request.saveGeneration
            )
        )
        await futureChangeNotifier.record(
            .documentSaved(
                projectID: receipt.projectID,
                documentID: receipt.documentID,
                contentHash: receipt.contentHash
            )
        )
        return DocumentBackupCopyResult(
            document: copiedDocument,
            receipt: receipt,
            copiedText: copiedText
        )
    }

    private func validate(
        snapshot: BackupSnapshot,
        for document: DocumentNode
    ) throws {
        guard snapshot.projectID == document.projectID else {
            throw BackupStoreError.wrongProject
        }
        guard snapshot.documentID == document.id else {
            throw BackupStoreError.wrongDocument
        }
        do {
            try pathPolicy.validateRelativePath(snapshot.relativePath)
        } catch {
            throw BackupStoreError.wrongPath
        }
    }

    private func copyDestinationParentID(
        for document: DocumentNode,
        documents: [DocumentNode]
    ) throws -> DocumentID {
        if isInsideManuscript(document.relativePath) {
            guard let notes = documents.first(where: {
                $0.kind == .folder
                    && $0.relativePath == BinderFixedCategory.notes.relativePath
                    && $0.deletionStatus == .active
            }) else {
                throw BackupStoreError.copyDestinationUnavailable
            }
            return notes.id
        }
        guard let parentID = document.parentID,
              documents.contains(where: {
                  $0.id == parentID
                      && $0.kind == .folder
                      && $0.deletionStatus == .active
              })
        else {
            throw BackupStoreError.copyDestinationUnavailable
        }
        return parentID
    }

    private func isInsideManuscript(_ path: RelativeDocumentPath) -> Bool {
        let components = path.rawValue.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return false }
        return pathPolicy.collisionKey(for: components[0])
                == pathPolicy.collisionKey(for: "메인")
            && pathPolicy.collisionKey(for: components[1])
                == pathPolicy.collisionKey(for: "원고")
    }

    private func copyDisplayName(for path: RelativeDocumentPath) -> String {
        let storedName = path.rawValue.split(separator: "/").last.map(String.init)
            ?? "문서.txt"
        let original = pathPolicy.binderDisplayName(forStoredName: storedName)
        let suffix = " 백업 사본"
        let maximumOriginalLength = max(
            1,
            pathPolicy.limits.maximumNameUTF16Length
                - ".txt".utf16.count
                - suffix.utf16.count
        )
        let source = original as NSString
        guard source.length > maximumOriginalLength else {
            return original + suffix
        }
        let proposed = NSRange(location: 0, length: maximumOriginalLength)
        let safeRange = source.rangeOfComposedCharacterSequences(for: proposed)
        return source.substring(with: safeRange) + suffix
    }
}

actor LocalBackupPolicyStore: BackupPolicyStoring {
    private let globalPolicyURL: URL
    private let legacyWorkspaceLocator: (any ProjectWorkspaceLocating)?
    private let fileManager: FileManager

    init(
        globalPolicyURL: URL,
        legacyWorkspaceLocator: (any ProjectWorkspaceLocating)? = nil,
        fileManager: FileManager = .default
    ) {
        self.globalPolicyURL = globalPolicyURL.standardizedFileURL
        self.legacyWorkspaceLocator = legacyWorkspaceLocator
        self.fileManager = fileManager
    }

    func policy(for projectID: ProjectID) async throws -> BackupPolicy {
        if fileManager.fileExists(atPath: globalPolicyURL.path) {
            return decodedPolicy(at: globalPolicyURL)
        }

        // 6단계 초기 빌드의 작품별 설정이 있으면 첫 접근 작품의
        // 값을 전역 정책으로 한 번만 가져온다. 기존 파일은 복구를 위해 남긴다.
        if let legacyWorkspaceLocator {
            let legacyURL = try await legacyWorkspaceLocator.workspaceRoot(for: projectID)
                .appendingPathComponent(".writerpad-backup-policy.json")
            if fileManager.fileExists(atPath: legacyURL.path) {
                let migrated = decodedPolicy(at: legacyURL)
                try saveGlobally(migrated)
                return migrated
            }
        }
        return .default
    }

    func save(_ policy: BackupPolicy, for _: ProjectID) async throws {
        try saveGlobally(policy)
    }

    private func decodedPolicy(at url: URL) -> BackupPolicy {
        do {
            return try JSONDecoder().decode(BackupPolicy.self, from: Data(contentsOf: url))
        } catch {
            return .default
        }
    }

    private func saveGlobally(_ policy: BackupPolicy) throws {
        try fileManager.createDirectory(
            at: globalPolicyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(policy).write(to: globalPolicyURL, options: [.atomic])
    }
}
