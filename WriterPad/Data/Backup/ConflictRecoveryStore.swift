import Foundation

struct ConflictRecoveryManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let packageID: UUID
    let localProjectID: ProjectID
    let serverProjectID: UUID
    let sourceOperationID: UUID
    let sourceFolderID: UUID
    let sourceBaseRevision: Int64
    let tombstoneRevision: Int64
    let displayName: String
    let sourceRootRelativePath: String
    let entities: [ConflictRecoveryEntity]
}

private struct ConflictRecoveryRestorePlan: Codable, Equatable, Sendable {
    let packageID: UUID
    let batchID: UUID
    let transactionID: UUID
    let targetParentID: DocumentID
    let rootDisplayName: String
    let nodes: [DocumentNode]
    let entityIDs: [UUID: UUID]
    let operationIDs: [UUID: UUID]
    let treeOrderOperationID: UUID
    let generation: UInt64
}

enum ConflictRecoveryStoreError: Error, Equatable, LocalizedError {
    case rootFolderMissing
    case sourceOutsideWorkspace
    case sourceFileMissing(String)
    case invalidUTF8(String)
    case invalidManifest
    case packageCorrupted(String)
    case unsupportedFormat(Int)
    case targetFolderMissing
    case nameCollision(String)
    case restoreRequestChanged
    case queueFailed(String)

    var errorDescription: String? {
        switch self {
        case .rootFolderMissing:
            "원격 삭제 충돌의 로컬 폴더를 찾을 수 없습니다."
        case .sourceOutsideWorkspace:
            "복구 원본이 작품 저장소 밖을 가리킵니다."
        case let .sourceFileMissing(path):
            "복구할 TXT를 찾을 수 없습니다: \(path)"
        case let .invalidUTF8(path):
            "복구할 파일이 UTF-8 TXT가 아닙니다: \(path)"
        case .invalidManifest:
            "충돌 복구 manifest가 올바르지 않습니다."
        case let .packageCorrupted(path):
            "충돌 복구 파일의 크기 또는 SHA-256이 다릅니다: \(path)"
        case let .unsupportedFormat(version):
            "지원하지 않는 충돌 복구 형식입니다: \(version)"
        case .targetFolderMissing:
            "복구 대상 폴더를 찾을 수 없습니다."
        case let .nameCollision(name):
            "같은 위치에 이미 '\(name)' 항목이 있습니다. 새 이름을 선택해 주세요."
        case .restoreRequestChanged:
            "이미 시작한 복구의 대상이나 이름을 바꿀 수 없습니다."
        case let .queueFailed(reason):
            "복구한 자료를 동기화 대기열에 기록하지 못했습니다: \(reason)"
        }
    }
}

enum ConflictRecoveryFaultPoint: Equatable, Sendable {
    case afterPayloadCopy
    case afterManifestWrite
    case afterReadyBeforeSourceResolution
    case afterSourceResolution
    case afterRestoreMaterialized
    case afterRestoreQueued
}

/// 서버 tombstone을 받아들여야 할 때 사용자 파일을 일반 동기화 트리 밖에
/// 먼저 보존한다. payload가 전부 검증되기 전에는 원본 작업을 종료하지 않는다.
actor ConflictRecoveryStore {
    static let manifestFileName = "manifest.json"
    static let payloadDirectoryName = "payload"

    private let ledger: any ConflictRecoveryLedger
    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let packagesRootURL: URL
    private let fileManager: FileManager
    private let hasher: any ContentHashing
    private let durableChangeRecorder: (any DurableLocalChangeRecording)?
    private let injectFault: (@Sendable (ConflictRecoveryFaultPoint) throws -> Void)?

    init(
        ledger: any ConflictRecoveryLedger,
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        packagesRootURL: URL,
        fileManager: FileManager = .default,
        hasher: any ContentHashing = SHA256ContentHasher(),
        durableChangeRecorder: (any DurableLocalChangeRecording)? = nil,
        injectFault:
            (@Sendable (ConflictRecoveryFaultPoint) throws -> Void)? = nil
    ) {
        self.ledger = ledger
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.packagesRootURL = packagesRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.hasher = hasher
        self.durableChangeRecorder = durableChangeRecorder
        self.injectFault = injectFault
    }

    static func defaultPackagesRootURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return applicationSupport
            .appendingPathComponent("WriterPad", isDirectory: true)
            .appendingPathComponent("ConflictRecovery", isDirectory: true)
    }

    /// `(source operation, tombstone revision)`은 ledger의 UNIQUE 키다. 같은
    /// 버튼·같은 dispatcher 결과가 다시 와도 한 패키지만 완성한다.
    @discardableResult
    func preserveRemoteDeletion(
        operation: SyncV2FolderDispatchOperation,
        tombstoneRevision: Int64
    ) async throws -> ConflictRecoveryPackage {
        guard tombstoneRevision > operation.baseRevision else {
            throw ConflictRecoveryLedgerError.invalidRemoteDeletion
        }
        let packageDirectoryName = Self.packageDirectoryName(
            operationID: operation.operationID,
            tombstoneRevision: tombstoneRevision
        )
        let package = try await ledger.beginRemoteDeletionRecovery(
            operation: operation,
            tombstoneRevision: tombstoneRevision,
            displayName: operation.name,
            payloadRelativePath: packageDirectoryName
        )
        switch package.state {
        case .sourceResolved, .restoreEnqueued, .restored, .discarded:
            return package
        case .ready:
            try await ledger.resolveRemoteDeletionSource(packageID: package.id)
            return try await requirePackage(package.id)
        case .preparing:
            break
        }

        try fileManager.createDirectory(
            at: packagesRootURL,
            withIntermediateDirectories: true
        )
        let finalURL = packageURL(for: package)
        let manifest: ConflictRecoveryManifest
        if fileManager.fileExists(atPath: finalURL.path) {
            manifest = try validatedManifest(at: finalURL, expected: package)
        } else {
            manifest = try await createPackage(package, at: finalURL)
        }
        let manifestData = try Self.encodedManifest(manifest)
        let documents = manifest.entities.filter { $0.kind == .document }
        try await ledger.markConflictRecoveryReady(
            packageID: package.id,
            manifestSHA256: hasher.sha256(for: manifestData).rawValue,
            fileCount: documents.count,
            totalBytes: documents.reduce(0) { $0 + ($1.byteCount ?? 0) },
            entities: manifest.entities
        )
        try injectFault?(.afterReadyBeforeSourceResolution)
        try await ledger.resolveRemoteDeletionSource(packageID: package.id)
        try injectFault?(.afterSourceResolution)
        return try await requirePackage(package.id)
    }

    func packages(
        localProjectID: ProjectID? = nil
    ) async throws -> [ConflictRecoveryPackage] {
        try await ledger.conflictRecoveryPackages(
            localProjectID: localProjectID
        )
    }

    func validatedManifest(
        for package: ConflictRecoveryPackage
    ) throws -> ConflictRecoveryManifest {
        try validatedManifest(at: packageURL(for: package), expected: package)
    }

    func exportURL(for package: ConflictRecoveryPackage) throws -> URL {
        _ = try validatedManifest(for: package)
        return packageURL(for: package)
    }

    func payloadData(
        package: ConflictRecoveryPackage,
        sourceDocumentID: UUID
    ) throws -> Data {
        let manifest = try validatedManifest(for: package)
        guard let entity = manifest.entities.first(where: {
            $0.kind == .document && $0.sourceEntityID == sourceDocumentID
        }) else {
            throw ConflictRecoveryStoreError.invalidManifest
        }
        return try verifiedData(for: entity, in: packageURL(for: package))
    }

    /// 사용자가 명시적으로 선택한 위치에만 새 신원으로 복구한다. plan을 먼저
    /// 원자적으로 기록하므로 앱이 어느 지점에서 종료돼도 같은 UUID와 batch를
    /// 재사용하고, 큐의 exact replay가 중복 생성을 막는다.
    @discardableResult
    func restoreAsNewFolder(
        package: ConflictRecoveryPackage,
        targetParentID: DocumentID,
        rootDisplayName: String
    ) async throws -> ConflictRecoveryPackage {
        if package.state == .restored || package.state == .restoreEnqueued {
            return package
        }
        guard package.state == .sourceResolved else {
            throw ConflictRecoveryLedgerError.invalidState
        }
        guard let durableChangeRecorder else {
            throw ConflictRecoveryStoreError.queueFailed("동기화 장부를 사용할 수 없습니다.")
        }
        let manifest = try validatedManifest(for: package)
        let current = try await documentRepository.documents(
            in: package.localProjectID
        )
        guard let parent = current.first(where: {
            $0.id == targetParentID && $0.kind == .folder
        }) else { throw ConflictRecoveryStoreError.targetFolderMissing }
        let normalizedName = rootDisplayName.precomposedStringWithCanonicalMapping
        try PathPolicy().validateName(normalizedName)

        let packageURL = packageURL(for: package)
        let planURL = packageURL.appendingPathComponent("restore-plan.json")
        let plan: ConflictRecoveryRestorePlan
        if fileManager.fileExists(atPath: planURL.path) {
            plan = try JSONDecoder().decode(
                ConflictRecoveryRestorePlan.self,
                from: Data(contentsOf: planURL)
            )
            guard plan.packageID == package.id,
                  plan.targetParentID == targetParentID,
                  plan.rootDisplayName == normalizedName
            else { throw ConflictRecoveryStoreError.restoreRequestChanged }
        } else {
            let candidatePath = Self.appending(
                normalizedName,
                to: parent.relativePath.rawValue
            )
            guard !current.contains(where: {
                $0.relativePath.rawValue.precomposedStringWithCanonicalMapping
                    == candidatePath.precomposedStringWithCanonicalMapping
            }) else {
                throw ConflictRecoveryStoreError.nameCollision(normalizedName)
            }
            plan = try makeRestorePlan(
                package: package,
                manifest: manifest,
                targetParent: parent,
                rootDisplayName: normalizedName,
                currentDocuments: current
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: planURL, options: [.atomic])
        }

        let workspaceURL = try await workspaceLocator.workspaceRoot(
            for: package.localProjectID
        ).standardizedFileURL
        try materialize(
            plan: plan,
            manifest: manifest,
            packageURL: packageURL,
            workspaceURL: workspaceURL
        )
        try injectFault?(.afterRestoreMaterialized)
        for node in plan.nodes.sorted(by: {
            Self.depth($0.relativePath.rawValue) < Self.depth($1.relativePath.rawValue)
        }) {
            try await documentRepository.save(node)
        }
        let allDocuments = try await documentRepository.documents(
            in: package.localProjectID
        )
        let batch = try restoreBatch(
            plan: plan,
            documents: allDocuments,
            manifest: manifest,
            packageURL: packageURL
        )
        switch await durableChangeRecorder.record(batch) {
        case .queued, .notNeeded:
            break
        case .localOnly:
            throw ConflictRecoveryStoreError.queueFailed("서버 연결이 해제되었습니다.")
        case let .serverSizeLimitExceeded(byteCount, limit):
            throw ConflictRecoveryStoreError.queueFailed(
                "서버 크기 제한 초과 (\(byteCount) / \(limit)바이트)"
            )
        case let .localSavedButNotQueued(reason):
            throw ConflictRecoveryStoreError.queueFailed(reason)
        }
        try injectFault?(.afterRestoreQueued)
        guard plan.entityIDs.count == manifest.entities.count else {
            throw ConflictRecoveryStoreError.invalidManifest
        }
        try await ledger.markConflictRecoveryRestoreEnqueued(
            packageID: package.id,
            restoreBatchID: plan.batchID,
            restoredEntityIDs: plan.entityIDs
        )
        return try await requirePackage(package.id)
    }

    func discard(
        package: ConflictRecoveryPackage,
        confirmsDeletion: Bool
    ) async throws {
        guard confirmsDeletion else { return }
        guard package.state == .sourceResolved else {
            throw ConflictRecoveryLedgerError.invalidState
        }
        try fileManager.removeItem(at: packageURL(for: package))
        try await ledger.discardConflictRecoveryPackage(packageID: package.id)
    }

    func deleteRestoredPayload(
        package: ConflictRecoveryPackage,
        confirmsDeletion: Bool
    ) async throws {
        guard confirmsDeletion else { return }
        guard package.state == .restored else {
            throw ConflictRecoveryLedgerError.invalidState
        }
        let url = packageURL(for: package)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try await ledger.markConflictRecoveryPayloadDeleted(packageID: package.id)
    }

    private func makeRestorePlan(
        package: ConflictRecoveryPackage,
        manifest: ConflictRecoveryManifest,
        targetParent: DocumentNode,
        rootDisplayName: String,
        currentDocuments: [DocumentNode]
    ) throws -> ConflictRecoveryRestorePlan {
        guard let root = manifest.entities.first(where: {
            $0.sourceEntityID == package.sourceFolderID
                && $0.kind == .folder
                && $0.parentSourceEntityID == nil
        }) else { throw ConflictRecoveryStoreError.invalidManifest }
        let entityIDs = Dictionary(
            uniqueKeysWithValues: manifest.entities.map {
                ($0.sourceEntityID, UUID())
            }
        )
        let operationIDs = Dictionary(
            uniqueKeysWithValues: manifest.entities.map {
                ($0.sourceEntityID, UUID())
            }
        )
        let entitiesByID = Dictionary(
            uniqueKeysWithValues: manifest.entities.map {
                ($0.sourceEntityID, $0)
            }
        )
        let rootPath = Self.appending(
            rootDisplayName,
            to: targetParent.relativePath.rawValue
        )
        var paths: [UUID: String] = [root.sourceEntityID: rootPath]
        func resolvedPath(for entity: ConflictRecoveryEntity) throws -> String {
            if let path = paths[entity.sourceEntityID] { return path }
            guard let parentSourceID = entity.parentSourceEntityID,
                  let parent = entitiesByID[parentSourceID]
            else { throw ConflictRecoveryStoreError.invalidManifest }
            let parentPath = try resolvedPath(for: parent)
            let storedName = entity.kind == .document
                ? try PathPolicy().textFileName(forDisplayName: entity.title)
                : entity.title
            let path = Self.appending(storedName, to: parentPath)
            paths[entity.sourceEntityID] = path
            return path
        }
        let now = Date()
        let rootOrder = (currentDocuments
            .filter { $0.parentID == targetParent.id }
            .map(\.userOrder).max() ?? -1) + 1
        var nodes: [DocumentNode] = []
        for entity in manifest.entities {
            guard let newRawID = entityIDs[entity.sourceEntityID] else {
                throw ConflictRecoveryStoreError.invalidManifest
            }
            let path = try resolvedPath(for: entity)
            try PathPolicy().validateRelativePath(.init(rawValue: path))
            let parentID: DocumentID?
            if entity.sourceEntityID == root.sourceEntityID {
                parentID = targetParent.id
            } else if let sourceParent = entity.parentSourceEntityID,
                      let newParent = entityIDs[sourceParent] {
                parentID = DocumentID(rawValue: newParent)
            } else {
                throw ConflictRecoveryStoreError.invalidManifest
            }
            nodes.append(
                DocumentNode(
                    id: DocumentID(rawValue: newRawID),
                    projectID: package.localProjectID,
                    kind: entity.kind == .folder ? .folder : .text,
                    parentID: parentID,
                    relativePath: .init(rawValue: path),
                    userOrder: entity.sourceEntityID == root.sourceEntityID
                        ? rootOrder : entity.userOrder,
                    modifiedAt: now,
                    contentHash: entity.sha256.flatMap(ContentHash.init(rawValue:))
                )
            )
        }
        return ConflictRecoveryRestorePlan(
            packageID: package.id,
            batchID: UUID(),
            transactionID: UUID(),
            targetParentID: targetParent.id,
            rootDisplayName: rootDisplayName,
            nodes: nodes,
            entityIDs: entityIDs,
            operationIDs: operationIDs,
            treeOrderOperationID: UUID(),
            generation: UInt64(max(0, Int(now.timeIntervalSince1970 * 1_000)))
        )
    }

    private func materialize(
        plan: ConflictRecoveryRestorePlan,
        manifest: ConflictRecoveryManifest,
        packageURL: URL,
        workspaceURL: URL
    ) throws {
        guard let newRootID = plan.entityIDs[manifest.sourceFolderID],
              let rootNode = plan.nodes.first(where: {
                  $0.id == DocumentID(rawValue: newRootID)
              })
        else { throw ConflictRecoveryStoreError.invalidManifest }
        let finalRootURL = workspaceURL.appendingPathComponent(
            rootNode.relativePath.rawValue,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: finalRootURL.path) {
            try verifyMaterialized(plan: plan, manifest: manifest, workspaceURL: workspaceURL)
            return
        }
        let stagingRootURL = workspaceURL.appendingPathComponent(
            ".writerpad-recovery-\(plan.packageID.uuidString.lowercased()).partial",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: stagingRootURL.path) {
            try fileManager.removeItem(at: stagingRootURL)
        }
        do {
            try fileManager.createDirectory(
                at: stagingRootURL,
                withIntermediateDirectories: true
            )
            let rootPrefix = rootNode.relativePath.rawValue + "/"
            for node in plan.nodes.sorted(by: {
                Self.depth($0.relativePath.rawValue) < Self.depth($1.relativePath.rawValue)
            }) {
                let relativeInsideRoot = node.relativePath.rawValue == rootNode.relativePath.rawValue
                    ? "" : String(node.relativePath.rawValue.dropFirst(rootPrefix.count))
                let destination = relativeInsideRoot.isEmpty
                    ? stagingRootURL
                    : stagingRootURL.appendingPathComponent(relativeInsideRoot)
                if node.kind == .folder {
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                    continue
                }
                guard let sourceID = plan.entityIDs.first(where: {
                    $0.value == node.id.rawValue
                })?.key,
                let entity = manifest.entities.first(where: {
                    $0.sourceEntityID == sourceID
                }) else { throw ConflictRecoveryStoreError.invalidManifest }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try verifiedData(for: entity, in: packageURL).write(
                    to: destination,
                    options: [.atomic]
                )
            }
            try fileManager.moveItem(at: stagingRootURL, to: finalRootURL)
            try verifyMaterialized(plan: plan, manifest: manifest, workspaceURL: workspaceURL)
        } catch {
            try? fileManager.removeItem(at: stagingRootURL)
            throw error
        }
    }

    private func verifyMaterialized(
        plan: ConflictRecoveryRestorePlan,
        manifest: ConflictRecoveryManifest,
        workspaceURL: URL
    ) throws {
        for node in plan.nodes where node.kind == .text {
            guard let sourceID = plan.entityIDs.first(where: {
                $0.value == node.id.rawValue
            })?.key,
            let entity = manifest.entities.first(where: {
                $0.sourceEntityID == sourceID
            }),
            let byteCount = entity.byteCount,
            let sha256 = entity.sha256
            else { throw ConflictRecoveryStoreError.invalidManifest }
            let data = try Data(
                contentsOf: workspaceURL.appendingPathComponent(node.relativePath.rawValue)
            )
            guard data.count == byteCount,
                  hasher.sha256(for: data).rawValue == sha256
            else {
                throw ConflictRecoveryStoreError.packageCorrupted(node.relativePath.rawValue)
            }
        }
    }

    private func restoreBatch(
        plan: ConflictRecoveryRestorePlan,
        documents: [DocumentNode],
        manifest: ConflictRecoveryManifest,
        packageURL: URL
    ) throws -> LocalMutationBatch {
        var mutations: [DurableLocalMutation] = []
        let sourceByRestoredID = Dictionary(
            uniqueKeysWithValues: plan.entityIDs.map { ($0.value, $0.key) }
        )
        for node in plan.nodes.filter({ $0.kind == .folder }).sorted(by: {
            Self.depth($0.relativePath.rawValue) < Self.depth($1.relativePath.rawValue)
        }) {
            guard let sourceID = sourceByRestoredID[node.id.rawValue],
                  let operationID = plan.operationIDs[sourceID]
            else { throw ConflictRecoveryStoreError.invalidManifest }
            mutations.append(
                .folderSnapshot(
                    operationID: operationID,
                    folderID: node.id,
                    parentFolderID: node.parentID,
                    name: (node.relativePath.rawValue as NSString).lastPathComponent,
                    isDeleted: false
                )
            )
        }
        for node in plan.nodes.filter({ $0.kind == .text }).sorted(by: {
            $0.relativePath.rawValue < $1.relativePath.rawValue
        }) {
            guard let sourceID = sourceByRestoredID[node.id.rawValue],
                  let operationID = plan.operationIDs[sourceID],
                  let entity = manifest.entities.first(where: {
                      $0.sourceEntityID == sourceID
                  }),
                  let hash = entity.sha256.flatMap(ContentHash.init(rawValue:))
            else { throw ConflictRecoveryStoreError.invalidManifest }
            let data = try verifiedData(for: entity, in: packageURL)
            guard let content = String(data: data, encoding: .utf8) else {
                throw ConflictRecoveryStoreError.invalidUTF8(entity.relativePath)
            }
            mutations.append(
                .documentSnapshot(
                    operationID: operationID,
                    documentID: node.id,
                    relativePath: node.relativePath,
                    content: content,
                    contentHash: hash,
                    localSaveGeneration: plan.generation,
                    isDeleted: false
                )
            )
        }
        mutations.append(
            .treeOrder(
                operationID: plan.treeOrderOperationID,
                content: try Self.treeOrderContent(documents),
                generation: plan.generation
            )
        )
        return LocalMutationBatch(
            batchID: plan.batchID,
            projectID: plan.nodes.first?.projectID
                ?? manifest.localProjectID,
            localTransactionID: plan.transactionID,
            kind: .backupRestore,
            mutations: mutations
        )
    }

    private func createPackage(
        _ package: ConflictRecoveryPackage,
        at finalURL: URL
    ) async throws -> ConflictRecoveryManifest {
        let documents = try await documentRepository.documents(
            in: package.localProjectID
        )
        guard let root = documents.first(where: {
            $0.id.rawValue == package.sourceFolderID && $0.kind == .folder
        }) else {
            throw ConflictRecoveryStoreError.rootFolderMissing
        }
        let subtree = Self.subtree(root: root, documents: documents)
        let workspace = try await workspaceLocator.workspaceRoot(
            for: package.localProjectID
        ).standardizedFileURL
        let stagingURL = packagesRootURL.appendingPathComponent(
            ".\(package.payloadRelativePath).partial",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }
        let payloadURL = stagingURL.appendingPathComponent(
            Self.payloadDirectoryName,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: payloadURL,
                withIntermediateDirectories: true
            )
            var entities: [ConflictRecoveryEntity] = []
            for node in subtree.sorted(by: {
                $0.relativePath.rawValue < $1.relativePath.rawValue
            }) {
                let relative = Self.relativePath(
                    node.relativePath.rawValue,
                    below: root.relativePath.rawValue
                )
                let title = Self.title(for: node)
                if node.kind == .folder {
                    entities.append(
                        ConflictRecoveryEntity(
                            kind: .folder,
                            sourceEntityID: node.id.rawValue,
                            restoredEntityID: nil,
                            parentSourceEntityID: subtree.contains(where: {
                                $0.id == node.parentID
                            }) ? node.parentID?.rawValue : nil,
                            relativePath: relative,
                            title: title,
                            userOrder: node.userOrder,
                            byteCount: nil,
                            sha256: nil,
                            restoreStatus: .pending
                        )
                    )
                    continue
                }
                let sourceURL = workspace.appendingPathComponent(
                    node.relativePath.rawValue,
                    isDirectory: false
                ).standardizedFileURL
                guard Self.contains(sourceURL, in: workspace) else {
                    throw ConflictRecoveryStoreError.sourceOutsideWorkspace
                }
                let values = try? sourceURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true,
                      fileManager.fileExists(atPath: sourceURL.path)
                else {
                    throw ConflictRecoveryStoreError.sourceFileMissing(
                        node.relativePath.rawValue
                    )
                }
                let data = try Data(contentsOf: sourceURL)
                guard String(data: data, encoding: .utf8) != nil else {
                    throw ConflictRecoveryStoreError.invalidUTF8(
                        node.relativePath.rawValue
                    )
                }
                let hash = hasher.sha256(for: data).rawValue
                try data.write(
                    to: payloadURL.appendingPathComponent(
                        node.id.rawValue.uuidString.lowercased()
                    ),
                    options: [.atomic]
                )
                try injectFault?(.afterPayloadCopy)
                entities.append(
                    ConflictRecoveryEntity(
                        kind: .document,
                        sourceEntityID: node.id.rawValue,
                        restoredEntityID: nil,
                        parentSourceEntityID: node.parentID?.rawValue,
                        relativePath: relative,
                        title: title,
                        userOrder: node.userOrder,
                        byteCount: data.count,
                        sha256: hash,
                        restoreStatus: .pending
                    )
                )
            }
            let manifest = ConflictRecoveryManifest(
                formatVersion: ConflictRecoveryManifest.currentFormatVersion,
                packageID: package.id,
                localProjectID: package.localProjectID,
                serverProjectID: package.serverProjectID,
                sourceOperationID: package.sourceOperationID,
                sourceFolderID: package.sourceFolderID,
                sourceBaseRevision: package.sourceBaseRevision,
                tombstoneRevision: package.tombstoneRevision,
                displayName: package.displayName,
                sourceRootRelativePath: root.relativePath.rawValue,
                entities: entities
            )
            let data = try Self.encodedManifest(manifest)
            try data.write(
                to: stagingURL.appendingPathComponent(Self.manifestFileName),
                options: [.atomic]
            )
            try injectFault?(.afterManifestWrite)
            _ = try validatedManifest(at: stagingURL, expected: package)
            try fileManager.moveItem(at: stagingURL, to: finalURL)
            return manifest
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    private func validatedManifest(
        at packageURL: URL,
        expected package: ConflictRecoveryPackage
    ) throws -> ConflictRecoveryManifest {
        let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
        let data = try Data(contentsOf: manifestURL)
        guard let manifest = try? JSONDecoder().decode(
            ConflictRecoveryManifest.self,
            from: data
        ) else { throw ConflictRecoveryStoreError.invalidManifest }
        guard manifest.formatVersion == ConflictRecoveryManifest.currentFormatVersion else {
            throw ConflictRecoveryStoreError.unsupportedFormat(manifest.formatVersion)
        }
        guard manifest.packageID == package.id,
              manifest.localProjectID == package.localProjectID,
              manifest.serverProjectID == package.serverProjectID,
              manifest.sourceOperationID == package.sourceOperationID,
              manifest.sourceFolderID == package.sourceFolderID,
              manifest.sourceBaseRevision == package.sourceBaseRevision,
              manifest.tombstoneRevision == package.tombstoneRevision,
              manifest.displayName == package.displayName,
              !manifest.sourceRootRelativePath.isEmpty,
              Set(manifest.entities.map(\.sourceEntityID)).count == manifest.entities.count,
              manifest.entities.contains(where: {
                  $0.kind == .folder
                      && $0.sourceEntityID == package.sourceFolderID
                      && $0.parentSourceEntityID == nil
              })
        else { throw ConflictRecoveryStoreError.invalidManifest }

        let expectedFiles = Set(
            manifest.entities.filter { $0.kind == .document }.map {
                $0.sourceEntityID.uuidString.lowercased()
            }
        )
        let payloadURL = packageURL.appendingPathComponent(
            Self.payloadDirectoryName,
            isDirectory: true
        )
        let payloadEntries = try fileManager.contentsOfDirectory(
            at: payloadURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var actualFiles: Set<String> = []
        for url in payloadEntries {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ConflictRecoveryStoreError.invalidManifest
            }
            actualFiles.insert(url.lastPathComponent)
        }
        guard actualFiles == expectedFiles else {
            throw ConflictRecoveryStoreError.invalidManifest
        }
        for entity in manifest.entities where entity.kind == .document {
            _ = try verifiedData(for: entity, in: packageURL)
        }
        return manifest
    }

    private func verifiedData(
        for entity: ConflictRecoveryEntity,
        in packageURL: URL
    ) throws -> Data {
        guard let byteCount = entity.byteCount, let expectedHash = entity.sha256 else {
            throw ConflictRecoveryStoreError.invalidManifest
        }
        let url = packageURL
            .appendingPathComponent(Self.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent(entity.sourceEntityID.uuidString.lowercased())
        let data = try Data(contentsOf: url)
        guard data.count == byteCount,
              hasher.sha256(for: data).rawValue == expectedHash
        else {
            throw ConflictRecoveryStoreError.packageCorrupted(entity.relativePath)
        }
        return data
    }

    private func requirePackage(_ id: UUID) async throws -> ConflictRecoveryPackage {
        guard let package = try await ledger.conflictRecoveryPackages(
            localProjectID: nil
        ).first(where: { $0.id == id }) else {
            throw ConflictRecoveryLedgerError.packageNotFound
        }
        return package
    }

    private func packageURL(for package: ConflictRecoveryPackage) -> URL {
        packagesRootURL.appendingPathComponent(
            package.payloadRelativePath,
            isDirectory: true
        )
    }

    private static func packageDirectoryName(
        operationID: UUID,
        tombstoneRevision: Int64
    ) -> String {
        "\(operationID.uuidString.lowercased())-r\(tombstoneRevision).writerpad-recovery"
    }

    private static func subtree(
        root: DocumentNode,
        documents: [DocumentNode]
    ) -> [DocumentNode] {
        var accepted: Set<DocumentID> = [root.id]
        var changed = true
        while changed {
            changed = false
            for node in documents where !accepted.contains(node.id) {
                if let parentID = node.parentID, accepted.contains(parentID) {
                    accepted.insert(node.id)
                    changed = true
                }
            }
        }
        return documents.filter { accepted.contains($0.id) }
    }

    private static func relativePath(_ path: String, below root: String) -> String {
        if path == root { return (path as NSString).lastPathComponent }
        let prefix = root.hasSuffix("/") ? root : "\(root)/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func title(for node: DocumentNode) -> String {
        let component = (node.relativePath.rawValue as NSString).lastPathComponent
        return node.kind == .text
            ? (component as NSString).deletingPathExtension
            : component
    }

    private static func encodedManifest(
        _ manifest: ConflictRecoveryManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func appending(_ component: String, to parent: String) -> String {
        parent.isEmpty ? component : "\(parent)/\(component)"
    }

    private static func depth(_ path: String) -> Int {
        path.split(separator: "/").count
    }

    private static func treeOrderContent(
        _ documents: [DocumentNode]
    ) throws -> String {
        let live = documents.filter {
            if case .active = $0.deletionStatus { return true }
            return false
        }
        let hierarchy = BinderHierarchyPolicy()
        var order: [String: [String]] = [:]
        for folder in live where folder.kind == .folder {
            let key = hierarchy.isTopLevelContainer(folder)
                ? "<root>"
                : SyncV2ServerPath.canonical(folder.relativePath.rawValue)
            order[key] = live
                .filter { $0.parentID == folder.id }
                .sorted {
                    if $0.userOrder != $1.userOrder {
                        return $0.userOrder < $1.userOrder
                    }
                    return $0.relativePath.rawValue < $1.relativePath.rawValue
                }
                .map {
                    SyncV2ServerPath.canonical(
                        ($0.relativePath.rawValue as NSString).lastPathComponent
                    )
                }
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "tree_order": order],
            options: [.sortedKeys]
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw ConflictRecoveryStoreError.invalidManifest
        }
        return content
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
