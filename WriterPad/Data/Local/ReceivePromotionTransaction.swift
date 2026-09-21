import Darwin
import Foundation

enum ReceivePromotionTransactionError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress
    case sourceChangedAfterInspection
    case duplicateProject(String)
    case sourceAlreadyPromoted
    case completedPromotionUnavailable
    case recoveryRequired(String)
    case injectedFailure(recoveryPending: Bool)

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "다른 승격 또는 복구 작업이 진행 중입니다. 완료 후 다시 시도하세요."
        case .sourceChangedAfterInspection:
            "검사 뒤 package가 변경되었습니다. 다시 검사하세요."
        case let .duplicateProject(name):
            "같은 이름으로 판단되는 작품이 이미 있습니다: \(name)"
        case .sourceAlreadyPromoted:
            "같은 수신 실행은 이미 다른 package로 승격되었습니다."
        case .completedPromotionUnavailable:
            "완료 영수증과 승격된 작품이 일치하지 않습니다."
        case let .recoveryRequired(path):
            "승격 거래를 자동 복구하지 못했습니다. 기록을 보존했습니다: \(path)"
        case let .injectedFailure(recoveryPending):
            recoveryPending
                ? "테스트용 중단이 발생해 복구할 거래를 보존했습니다."
                : "테스트용 승격 실패가 발생했습니다."
        }
    }
}

enum ReceivePromotionFaultPoint: Equatable, Sendable {
    case afterMarkerWrite
    case afterStaging
    case afterMetadataRegistration
    case afterPromotion
    case afterReceiptWrite
}

struct ReceivePromotionFaultPlan: Equatable, Sendable {
    let point: ReceivePromotionFaultPoint
    let leavesTransactionForRecovery: Bool
}

private struct ReceivePromotionProvenance: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let producerBundleID: String
        let localID: UUID
        let runID: UUID
        let folderName: String
        let editableIdentitySHA256: ContentHash
        let editableWorkspaceSHA256: ContentHash

        enum CodingKeys: String, CodingKey {
            case producerBundleID = "producer_bundle_id"
            case localID = "local_id"
            case runID = "run_id"
            case folderName = "folder_name"
            case editableIdentitySHA256 = "editable_identity_sha256"
            case editableWorkspaceSHA256 = "editable_workspace_sha256"
        }
    }

    struct Document: Codable, Equatable, Sendable {
        let sourceDocumentID: UUID
        let sourceName: String
        let sourceBodySHA256: ContentHash
        let editableRevision: Int
        let editableBodySHA256: ContentHash
        let byteCount: Int
        let writerPadDocumentID: DocumentID
        let writerPadRelativePath: RelativeDocumentPath

        enum CodingKeys: String, CodingKey {
            case sourceDocumentID = "source_document_id"
            case sourceName = "source_name"
            case sourceBodySHA256 = "source_body_sha256"
            case editableRevision = "editable_revision"
            case editableBodySHA256 = "editable_body_sha256"
            case byteCount = "byte_count"
            case writerPadDocumentID = "writerpad_document_id"
            case writerPadRelativePath = "writerpad_relative_path"
        }
    }

    let format: String
    let transactionID: UUID
    let packageID: UUID
    let packageFingerprint: ContentHash
    let sourceKey: ContentHash
    let source: Source
    let documents: [Document]

    enum CodingKeys: String, CodingKey {
        case format
        case transactionID = "transaction_id"
        case packageID = "package_id"
        case packageFingerprint = "package_fingerprint"
        case sourceKey = "source_key"
        case source
        case documents
    }
}

private struct ReceivePromotionMarker: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case copying
        case staged
        case metadataRegistered = "metadata_registered"
        case promoted
        case receiptWritten = "receipt_written"
    }

    let format: String
    let transactionID: UUID
    var phase: Phase
    let project: Project
    let stagingFolderName: String
    let sourceKey: ContentHash
    let packageFingerprint: ContentHash
    let packageID: UUID
    let provenance: ReceivePromotionProvenance
    let provenanceSHA256: ContentHash
    let nodes: [DocumentNode]

    enum CodingKeys: String, CodingKey {
        case format
        case transactionID = "transaction_id"
        case phase
        case project
        case stagingFolderName = "staging_folder_name"
        case sourceKey = "source_key"
        case packageFingerprint = "package_fingerprint"
        case packageID = "package_id"
        case provenance
        case provenanceSHA256 = "provenance_sha256"
        case nodes
    }
}

private struct ReceivePromotionReceipt: Codable, Equatable, Sendable {
    let format: String
    let sourceKey: ContentHash
    let packageFingerprint: ContentHash
    let transactionID: UUID
    let managedProject: ManagedProject
    let provenanceSHA256: ContentHash
    let documents: [ReceivePromotionProvenance.Document]
    let nodes: [DocumentNode]

    enum CodingKeys: String, CodingKey {
        case format
        case sourceKey = "source_key"
        case packageFingerprint = "package_fingerprint"
        case transactionID = "transaction_id"
        case managedProject = "managed_project"
        case provenanceSHA256 = "provenance_sha256"
        case documents
        case nodes
    }
}

/// Creates a new local-only WriterPad project from one validated package.
/// No sync, authentication, or transport dependency is reachable from here.
actor ReceivePromotionTransaction: ReceivePromotionTransacting {
    private static let markerFormat = "writerpad-receive-promotion-transaction-v1"
    private static let provenanceFormat = "writerpad-receive-provenance-v1"
    private static let receiptFormat = "writerpad-receive-promotion-receipt-v1"
    private static let markerPrefix = ".writerpad-promotion-transaction-"
    private static let receiptFolderName = ".writerpad-promotion-receipts"
    private static let provenanceFileName = ".writerpad-receive-provenance-v1.json"

    private let packageReader: any ReceivePromotionPackageMaterializing
    private let metadataStore: any ReceivePromotionMetadataStoring
    private let projectPublisher: any ReceivePromotionProjectPublishing
    private let pathResolver: ProjectPathResolver
    private let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let hasher: any ContentHashing
    private let fileManager: FileManager
    private let atomicWriter: POSIXAtomicFileWriter
    private let faultPlan: ReceivePromotionFaultPlan?
    // Actor isolation does not prevent re-entry while metadata calls await.
    private var operationInProgress = false

    init(
        packageReader: any ReceivePromotionPackageMaterializing,
        metadataStore: any ReceivePromotionMetadataStoring,
        projectPublisher: any ReceivePromotionProjectPublishing,
        pathResolver: ProjectPathResolver,
        clock: any AppClock,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        fileManager: FileManager = .default,
        atomicWriter: POSIXAtomicFileWriter = POSIXAtomicFileWriter(),
        faultPlan: ReceivePromotionFaultPlan? = nil
    ) {
        self.packageReader = packageReader
        self.metadataStore = metadataStore
        self.projectPublisher = projectPublisher
        self.pathResolver = pathResolver
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.fileManager = fileManager
        self.atomicWriter = atomicWriter
        self.faultPlan = faultPlan
    }

    func promote(
        from report: ReceivePromotionReport,
        projectName: String
    ) async throws -> ReceivePromotionResult {
        try beginOperation()
        defer { operationInProgress = false }
        try await recoverPendingPromotionsWhileLocked()
        try pathResolver.policy.validateName(projectName)

        let current = try await packageReader.materialize(report.sourceSelectionURL)
        guard current.report == report else {
            throw ReceivePromotionTransactionError.sourceChangedAfterInspection
        }
        if let completed = try await completedResult(
            sourceKey: report.sourceKey,
            expectedFingerprint: report.packageFingerprint
        ) {
            return completed
        }
        try await requireAvailableProjectName(projectName)
        try ensureRoot()

        let transactionID = uuidGenerator.makeUUID()
        let projectID = ProjectID(rawValue: uuidGenerator.makeUUID())
        // The durable marker uses ISO-8601 seconds. Metadata must use the same
        // precision so a decoded marker still matches after process restart.
        let now = Date(timeIntervalSince1970: floor(clock.now().timeIntervalSince1970))
        let project = Project(
            id: projectID,
            name: projectName,
            createdAt: now,
            modifiedAt: now
        )
        let plan = makeNodesAndProvenance(
            package: current,
            transactionID: transactionID,
            project: project,
            date: now
        )
        let provenanceData = try canonical(plan.provenance)
        let stagingFolderName = ".writerpad-promotion-\(canonical(transactionID)).tmp"
        let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
            stagingFolderName,
            isDirectory: true
        )
        let finalURL = try pathResolver.standardPaths(
            forProjectNamed: projectName
        ).projectContainerURL
        var marker = ReceivePromotionMarker(
            format: Self.markerFormat,
            transactionID: transactionID,
            phase: .copying,
            project: project,
            stagingFolderName: stagingFolderName,
            sourceKey: report.sourceKey,
            packageFingerprint: report.packageFingerprint,
            packageID: report.packageID,
            provenance: plan.provenance,
            provenanceSHA256: hasher.sha256(for: provenanceData),
            nodes: plan.nodes
        )
        let markerURL = markerURL(transactionID)

        try writeCanonical(marker, to: markerURL)
        do {
            try inject(.afterMarkerWrite)
            let paths = try pathResolver.createStandardStructure(
                atProjectContainer: stagingURL,
                projectName: projectName
            )
            for document in plan.payloads {
                let destination = try pathResolver.validatedURL(
                    for: document.path,
                    in: paths.workspaceRootURL
                )
                try writeData(document.data, to: destination)
            }
            try writeData(
                provenanceData,
                to: stagingURL.appendingPathComponent(Self.provenanceFileName)
            )
            try verifyProject(
                marker: marker,
                projectURL: stagingURL,
                expectedPayloads: plan.payloads
            )
            try synchronizeProjectTree(paths: paths, projectURL: stagingURL)
            marker.phase = .staged
            try writeCanonical(marker, to: markerURL)
            try inject(.afterStaging)

            try await metadataStore.registerImportedProject(
                project,
                documents: plan.nodes
            )
            marker.phase = .metadataRegistered
            try writeCanonical(marker, to: markerURL)
            try inject(.afterMetadataRegistration)

            try fileManager.moveItem(at: stagingURL, to: finalURL)
            try atomicWriter.synchronizeDirectory(at: pathResolver.projectsRootURL)
            marker.phase = .promoted
            try writeCanonical(marker, to: markerURL)
            try verifyProject(
                marker: marker,
                projectURL: finalURL,
                expectedPayloads: plan.payloads
            )
            try await verifyMetadata(marker)
            try inject(.afterPromotion)

            let managed = try await projectPublisher.publishPromotedProject(project)
            let receipt = ReceivePromotionReceipt(
                format: Self.receiptFormat,
                sourceKey: marker.sourceKey,
                packageFingerprint: marker.packageFingerprint,
                transactionID: marker.transactionID,
                managedProject: managed,
                provenanceSHA256: marker.provenanceSHA256,
                documents: marker.provenance.documents,
                nodes: marker.nodes
            )
            try writeReceipt(receipt)
            marker.phase = .receiptWritten
            try writeCanonical(marker, to: markerURL)
            try inject(.afterReceiptWrite)
            try remove(markerURL)
            return result(receipt, wasAlreadyCompleted: false)
        } catch let error as ReceivePromotionTransactionError {
            if case .injectedFailure(recoveryPending: true) = error {
                throw error
            }
            if marker.phase == .promoted || marker.phase == .receiptWritten {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
            try await rollback(
                marker: marker,
                stagingURL: stagingURL,
                finalURL: finalURL,
                markerURL: markerURL
            )
            throw error
        } catch {
            if marker.phase == .promoted || marker.phase == .receiptWritten {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
            try await rollback(
                marker: marker,
                stagingURL: stagingURL,
                finalURL: finalURL,
                markerURL: markerURL
            )
            throw error
        }
    }

    func recoverPendingPromotions() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await recoverPendingPromotionsWhileLocked()
    }

    private func beginOperation() throws {
        guard !operationInProgress else {
            throw ReceivePromotionTransactionError.operationInProgress
        }
        operationInProgress = true
    }

    private func recoverPendingPromotionsWhileLocked() async throws {
        guard fileManager.fileExists(atPath: pathResolver.projectsRootURL.path) else {
            return
        }
        try requireDirectory(pathResolver.projectsRootURL)
        let markerURLs = try fileManager.contentsOfDirectory(
            at: pathResolver.projectsRootURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ).filter {
            $0.lastPathComponent.hasPrefix(Self.markerPrefix)
                && $0.lastPathComponent.hasSuffix(".json")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for markerURL in markerURLs {
            let marker: ReceivePromotionMarker
            do {
                let values = try markerURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadInvalidFileName) }
                marker = try decodeCanonical(ReceivePromotionMarker.self, from: markerURL)
                try pathResolver.policy.validateName(marker.project.name)
                guard marker.format == Self.markerFormat,
                      markerURL.lastPathComponent
                        == "\(Self.markerPrefix)\(canonical(marker.transactionID)).json",
                      marker.stagingFolderName
                        == ".writerpad-promotion-\(canonical(marker.transactionID)).tmp",
                      marker.provenance.format == Self.provenanceFormat,
                      marker.provenance.transactionID == marker.transactionID,
                      marker.sourceKey == marker.provenance.sourceKey,
                      marker.packageFingerprint == marker.provenance.packageFingerprint,
                      marker.packageID == marker.provenance.packageID,
                      marker.provenanceSHA256 == hasher.sha256(for: try canonical(marker.provenance))
                else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }

            let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
                marker.stagingFolderName,
                isDirectory: true
            )
            let finalURL = try pathResolver.standardPaths(
                forProjectNamed: marker.project.name
            ).projectContainerURL
            let hasStaging = fileManager.fileExists(atPath: stagingURL.path)
            let hasFinal = fileManager.fileExists(atPath: finalURL.path)
            guard !(hasStaging && hasFinal) else {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }

            if hasFinal {
                do {
                    try verifyProject(marker: marker, projectURL: finalURL)
                    try await verifyMetadata(marker)
                    let receipt: ReceivePromotionReceipt
                    if let existing = try loadReceipt(sourceKey: marker.sourceKey) {
                        try validate(existing, against: marker)
                        receipt = existing
                    } else {
                        let managed = try await projectPublisher.publishPromotedProject(
                            marker.project
                        )
                        receipt = ReceivePromotionReceipt(
                            format: Self.receiptFormat,
                            sourceKey: marker.sourceKey,
                            packageFingerprint: marker.packageFingerprint,
                            transactionID: marker.transactionID,
                            managedProject: managed,
                            provenanceSHA256: marker.provenanceSHA256,
                            documents: marker.provenance.documents,
                            nodes: marker.nodes
                        )
                        try writeReceipt(receipt)
                    }
                    _ = receipt
                    try remove(markerURL)
                } catch {
                    throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
                }
                continue
            }

            if try loadReceipt(sourceKey: marker.sourceKey) != nil {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
            if marker.phase == .promoted || marker.phase == .receiptWritten {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
            do {
                try await rollback(
                    marker: marker,
                    stagingURL: stagingURL,
                    finalURL: finalURL,
                    markerURL: markerURL
                )
            } catch {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
        }
    }
}

private extension ReceivePromotionTransaction {
    struct PayloadPlan {
        let path: RelativeDocumentPath
        let data: Data
        let hash: ContentHash
    }

    struct Plan {
        let nodes: [DocumentNode]
        let provenance: ReceivePromotionProvenance
        let payloads: [PayloadPlan]
    }

    func makeNodesAndProvenance(
        package: ReceivePromotionValidatedPackage,
        transactionID: UUID,
        project: Project,
        date: Date
    ) -> Plan {
        let mainID = DocumentID(rawValue: uuidGenerator.makeUUID())
        var nodes = [DocumentNode(
            id: mainID,
            projectID: project.id,
            kind: .folder,
            parentID: nil,
            relativePath: BinderHierarchyPolicy.topLevelPath,
            userOrder: 0,
            modifiedAt: date,
            contentHash: nil
        )]
        var categoryIDs: [BinderFixedCategory: DocumentID] = [:]
        for category in BinderFixedCategory.allCases {
            let id = DocumentID(rawValue: uuidGenerator.makeUUID())
            categoryIDs[category] = id
            nodes.append(DocumentNode(
                id: id,
                projectID: project.id,
                kind: .folder,
                parentID: mainID,
                relativePath: category.relativePath,
                userOrder: category.fixedOrder,
                modifiedAt: date,
                contentHash: nil
            ))
        }
        let notesID = categoryIDs[.notes]!
        var provenanceDocuments: [ReceivePromotionProvenance.Document] = []
        var payloads: [PayloadPlan] = []
        for (index, payload) in package.documents.enumerated() {
            let id = DocumentID(rawValue: uuidGenerator.makeUUID())
            let relativePath = RelativeDocumentPath(
                rawValue: "메인/메모장/\(payload.review.sourceName)"
            )
            nodes.append(DocumentNode(
                id: id,
                projectID: project.id,
                kind: .text,
                parentID: notesID,
                relativePath: relativePath,
                userOrder: index,
                modifiedAt: date,
                contentHash: payload.review.editableBodyHash
            ))
            provenanceDocuments.append(.init(
                sourceDocumentID: payload.review.sourceDocumentID,
                sourceName: payload.review.sourceName,
                sourceBodySHA256: payload.review.sourceBodyHash,
                editableRevision: payload.review.editableRevision,
                editableBodySHA256: payload.review.editableBodyHash,
                byteCount: payload.review.byteCount,
                writerPadDocumentID: id,
                writerPadRelativePath: relativePath
            ))
            payloads.append(.init(
                path: relativePath,
                data: payload.data,
                hash: payload.review.editableBodyHash
            ))
        }
        let report = package.report
        let provenance = ReceivePromotionProvenance(
            format: Self.provenanceFormat,
            transactionID: transactionID,
            packageID: report.packageID,
            packageFingerprint: report.packageFingerprint,
            sourceKey: report.sourceKey,
            source: .init(
                producerBundleID: report.producerBundleID,
                localID: report.sourceLocalID,
                runID: report.sourceRunID,
                folderName: report.sourceFolderName,
                editableIdentitySHA256: report.editableIdentityHash,
                editableWorkspaceSHA256: report.editableWorkspaceHash
            ),
            documents: provenanceDocuments
        )
        return Plan(nodes: nodes, provenance: provenance, payloads: payloads)
    }

    func requireAvailableProjectName(_ name: String) async throws {
        let key = pathResolver.policy.collisionKey(for: name)
        if let duplicate = try await metadataStore.projects().first(where: {
            pathResolver.policy.collisionKey(for: $0.name) == key
        }) {
            throw ReceivePromotionTransactionError.duplicateProject(duplicate.name)
        }
        if fileManager.fileExists(atPath: pathResolver.projectsRootURL.path) {
            let names = try fileManager.contentsOfDirectory(
                at: pathResolver.projectsRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)
            if let duplicate = names.first(where: {
                pathResolver.policy.collisionKey(for: $0) == key
            }) {
                throw ReceivePromotionTransactionError.duplicateProject(duplicate)
            }
        }
    }

    func ensureRoot() throws {
        try fileManager.createDirectory(
            at: pathResolver.projectsRootURL,
            withIntermediateDirectories: true
        )
        try requireDirectory(pathResolver.projectsRootURL)
        try atomicWriter.synchronizeDirectory(
            at: pathResolver.projectsRootURL.deletingLastPathComponent()
        )
    }

    func markerURL(_ id: UUID) -> URL {
        pathResolver.projectsRootURL.appendingPathComponent(
            "\(Self.markerPrefix)\(canonical(id)).json"
        )
    }

    func receiptURL(_ sourceKey: ContentHash) -> URL {
        pathResolver.projectsRootURL
            .appendingPathComponent(Self.receiptFolderName, isDirectory: true)
            .appendingPathComponent(sourceKey.rawValue + ".json")
    }

    func writeReceipt(_ receipt: ReceivePromotionReceipt) throws {
        let folder = receiptURL(receipt.sourceKey).deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try requireDirectory(folder)
        try atomicWriter.synchronizeDirectory(at: pathResolver.projectsRootURL)
        try writeCanonical(receipt, to: receiptURL(receipt.sourceKey))
    }

    func loadReceipt(
        sourceKey: ContentHash
    ) throws -> ReceivePromotionReceipt? {
        let url = receiptURL(sourceKey)
        do {
            let folder = url.deletingLastPathComponent()
            // fileExists follows links: a dangling receipt must not be treated
            // as a new source and overwritten by a second promotion.
            guard try entryExistsWithoutFollowingLinks(folder) else { return nil }
            try requireDirectory(folder)
            guard try entryExistsWithoutFollowingLinks(url) else { return nil }
            let receipt = try decodeCanonical(ReceivePromotionReceipt.self, from: url)
            guard receipt.format == Self.receiptFormat,
                  receipt.sourceKey == sourceKey else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return receipt
        } catch {
            throw ReceivePromotionTransactionError.recoveryRequired(url.path)
        }
    }

    func entryExistsWithoutFollowingLinks(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        return false
    }

    func completedResult(
        sourceKey: ContentHash,
        expectedFingerprint: ContentHash
    ) async throws -> ReceivePromotionResult? {
        guard let receipt = try loadReceipt(sourceKey: sourceKey) else { return nil }
        guard receipt.packageFingerprint == expectedFingerprint else {
            throw ReceivePromotionTransactionError.sourceAlreadyPromoted
        }
        let currentProject: Project
        do {
            currentProject = try await validateCompletedReceipt(receipt)
        } catch {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        let currentManagedProject = ManagedProject(
            project: currentProject,
            userOrder: receipt.managedProject.userOrder,
            lifecycleState: receipt.managedProject.lifecycleState
        )
        return result(
            receipt,
            managedProject: currentManagedProject,
            wasAlreadyCompleted: true
        )
    }

    /// A completion receipt proves that one source was promoted once. The
    /// resulting project is intentionally editable, so presentation state,
    /// paths, timestamps and body hashes may legitimately change afterwards.
    /// Replays therefore validate durable identity and immutable provenance,
    /// while the stricter transaction/recovery checks remain unchanged.
    func validateCompletedReceipt(
        _ receipt: ReceivePromotionReceipt
    ) async throws -> Project {
        guard let currentProject = try await metadataStore.project(
            id: receipt.managedProject.id
        ) else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        let projectURL = try pathResolver.standardPaths(
            forProjectNamed: currentProject.name
        ).projectContainerURL
        try requireDirectory(projectURL)
        let provenance = try decodeCanonical(
            ReceivePromotionProvenance.self,
            from: projectURL.appendingPathComponent(Self.provenanceFileName)
        )
        guard provenance.sourceKey == receipt.sourceKey,
              provenance.packageFingerprint == receipt.packageFingerprint,
              provenance.transactionID == receipt.transactionID,
              provenance.documents == receipt.documents,
              hasher.sha256(for: try canonical(provenance)) == receipt.provenanceSHA256
        else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        let currentDocuments = try await metadataStore.documents(in: currentProject.id)
        let documentsByID = Dictionary(
            currentDocuments.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let promotedDocumentIDs = receipt.documents.map(\.writerPadDocumentID)
        guard Set(promotedDocumentIDs).count == promotedDocumentIDs.count,
              promotedDocumentIDs.allSatisfy({ id in
                  guard let document = documentsByID[id] else { return false }
                  return document.projectID == currentProject.id && document.kind == .text
              }) else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        return currentProject
    }

    func validate(
        _ receipt: ReceivePromotionReceipt,
        against marker: ReceivePromotionMarker
    ) throws {
        guard receipt.format == Self.receiptFormat,
              receipt.sourceKey == marker.sourceKey,
              receipt.packageFingerprint == marker.packageFingerprint,
              receipt.transactionID == marker.transactionID,
              receipt.managedProject.project == marker.project,
              receipt.provenanceSHA256 == marker.provenanceSHA256,
              receipt.documents == marker.provenance.documents,
              sorted(receipt.nodes) == sorted(marker.nodes) else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
    }

    func result(
        _ receipt: ReceivePromotionReceipt,
        managedProject: ManagedProject? = nil,
        wasAlreadyCompleted: Bool
    ) -> ReceivePromotionResult {
        ReceivePromotionResult(
            transactionID: receipt.transactionID,
            project: managedProject ?? receipt.managedProject,
            sourceKey: receipt.sourceKey,
            packageFingerprint: receipt.packageFingerprint,
            documentMappings: receipt.documents.map {
                ReceivePromotionDocumentMapping(
                    sourceDocumentID: $0.sourceDocumentID,
                    writerPadDocumentID: $0.writerPadDocumentID
                )
            },
            wasAlreadyCompleted: wasAlreadyCompleted
        )
    }

    func verifyMetadata(_ marker: ReceivePromotionMarker) async throws {
        guard try await metadataStore.project(id: marker.project.id) == marker.project else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        let actual = try await metadataStore.documents(in: marker.project.id)
        guard sorted(actual) == sorted(marker.nodes) else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
    }

    func verifyProject(
        marker: ReceivePromotionMarker,
        projectURL: URL,
        expectedPayloads: [PayloadPlan]? = nil
    ) throws {
        try requireDirectory(projectURL)
        try requireDirectory(projectURL.appendingPathComponent("집필모드"))
        try requireDirectory(projectURL.appendingPathComponent("집필모드/메인/메모장"))
        let provenanceURL = projectURL.appendingPathComponent(Self.provenanceFileName)
        let provenance = try decodeCanonical(
            ReceivePromotionProvenance.self,
            from: provenanceURL
        )
        guard provenance == marker.provenance,
              hasher.sha256(for: try canonical(provenance)) == marker.provenanceSHA256 else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        if let expectedPayloads {
            for payload in expectedPayloads {
                let url = projectURL.appendingPathComponent("집필모드")
                    .appendingPathComponent(payload.path.rawValue)
                let data = try readRegularFile(url)
                guard data == payload.data,
                      hasher.sha256(for: data) == payload.hash else {
                    throw ReceivePromotionTransactionError.completedPromotionUnavailable
                }
            }
        }
        try verifyPayloads(provenance.documents, projectURL: projectURL)
    }

    func verifyPayloads(
        _ documents: [ReceivePromotionProvenance.Document],
        projectURL: URL
    ) throws {
        let notesURL = projectURL.appendingPathComponent("집필모드/메인/메모장")
        let expectedNames = Set(documents.map {
            $0.writerPadRelativePath.rawValue.split(separator: "/").last.map(String.init)!
        })
        let actualNames = Set(try fileManager.contentsOfDirectory(
            at: notesURL,
            includingPropertiesForKeys: nil,
            options: []
        ).map(\.lastPathComponent))
        guard actualNames == expectedNames else {
            throw ReceivePromotionTransactionError.completedPromotionUnavailable
        }
        for document in documents {
            let url = projectURL.appendingPathComponent("집필모드")
                .appendingPathComponent(document.writerPadRelativePath.rawValue)
            let data = try readRegularFile(url)
            guard data.count == document.byteCount,
                  hasher.sha256(for: data) == document.editableBodySHA256,
                  String(data: data, encoding: .utf8) != nil else {
                throw ReceivePromotionTransactionError.completedPromotionUnavailable
            }
        }
    }

    func synchronizeProjectTree(
        paths: StandardProjectPaths,
        projectURL: URL
    ) throws {
        try atomicWriter.synchronizeFile(at: paths.settingsFileURL)
        for directory in paths.requiredDirectories.reversed() {
            try atomicWriter.synchronizeDirectory(at: directory)
        }
        try atomicWriter.synchronizeDirectory(at: projectURL)
        try atomicWriter.synchronizeDirectory(at: pathResolver.projectsRootURL)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try atomicWriter.writeTemporaryFile(data: data, at: temporary)
        try atomicWriter.replaceItem(at: url, with: temporary)
        try atomicWriter.synchronizeDirectory(at: url.deletingLastPathComponent())
    }

    func writeCanonical<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(try canonical(value), to: url)
    }

    func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    func decodeCanonical<T: Codable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try readRegularFile(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(type, from: data)
        guard try canonical(decoded) == data else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return decoded
    }

    func readRegularFile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 20 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            guard data.count + count <= 20 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(contentsOf: buffer[0..<count])
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    func requireDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_nlink >= 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func rollback(
        marker: ReceivePromotionMarker,
        stagingURL: URL,
        finalURL: URL,
        markerURL: URL
    ) async throws {
        if fileManager.fileExists(atPath: finalURL.path) {
            throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
        }
        let existing = try await metadataStore.project(id: marker.project.id)
        if let existing {
            let documents = try await metadataStore.documents(in: marker.project.id)
            guard existing == marker.project,
                  sorted(documents) == sorted(marker.nodes) else {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
        } else {
            if try await metadataStore.hasDocumentsForPromotionRecovery(in: marker.project.id) {
                throw ReceivePromotionTransactionError.recoveryRequired(markerURL.path)
            }
        }
        // Keep all evidence when ownership/metadata validation fails.
        try remove(stagingURL)
        if existing != nil {
            try await metadataStore.remove(id: marker.project.id)
        }
        try remove(markerURL)
    }

    func remove(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try atomicWriter.synchronizeDirectory(at: url.deletingLastPathComponent())
        }
    }

    func sorted(_ documents: [DocumentNode]) -> [DocumentNode] {
        documents.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    func canonical(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    func inject(_ point: ReceivePromotionFaultPoint) throws {
        guard let faultPlan, faultPlan.point == point else { return }
        throw ReceivePromotionTransactionError.injectedFailure(
            recoveryPending: faultPlan.leavesTransactionForRecovery
        )
    }
}
