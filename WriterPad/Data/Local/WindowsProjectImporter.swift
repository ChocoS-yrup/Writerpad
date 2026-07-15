import CryptoKit
import Foundation

enum WindowsProjectImporterError: Error, Equatable, LocalizedError, Sendable {
    case reportHasFatalErrors
    case warningConfirmationRequired
    case sourceChangedAfterInspection
    case importedProjectUnavailable
    case recoveryRequired(String)
    case injectedFailure

    var errorDescription: String? {
        switch self {
        case .reportHasFatalErrors:
            "치명 오류가 있는 작품은 가져올 수 없습니다. 검사 보고서를 확인하세요."
        case .warningConfirmationRequired:
            "경고를 확인한 뒤 가져오기를 다시 승인해야 합니다."
        case .sourceChangedAfterInspection:
            "검사 후 원본 작품이 변경되었습니다. 다시 검사하세요."
        case .importedProjectUnavailable:
            "가져온 작품을 작품 목록에서 찾을 수 없습니다."
        case let .recoveryRequired(path):
            "가져오기 작업을 자동 복구하지 못했습니다. 기록을 보존했습니다: \(path)"
        case .injectedFailure:
            "테스트용 가져오기 실패가 발생했습니다."
        }
    }
}

enum ImportFaultPoint: Equatable, Sendable {
    case unreadableItem(relativePath: String)
    case afterCopiedItem(Int)
    case afterMetadataRegistration
}

struct ImportFaultPlan: Equatable, Sendable {
    let point: ImportFaultPoint
}

private struct ImportScanEntry: Sendable {
    enum Kind: Equatable, Sendable {
        case directory
        case file
        case symbolicLink
    }

    let relativePath: String
    let sourceURL: URL
    let kind: Kind
    let byteCount: Int64
    let modifiedAt: Date
    let contentHash: ContentHash?
}

private struct ImportScanResult: Sendable {
    let report: ImportReport
    let entries: [ImportScanEntry]
}

private struct ImportTransactionMarker: Codable {
    enum Phase: String, Codable {
        case copying
        case staged
        case metadataRegistered = "metadata_registered"
        case promoted
    }

    let transactionID: UUID
    var phase: Phase
    let project: Project
    let stagingFolderName: String
    var expectedDocumentCount: Int

    private enum CodingKeys: String, CodingKey {
        case transactionID = "transaction_id"
        case phase
        case project
        case stagingFolderName = "staging_folder_name"
        case expectedDocumentCount = "expected_document_count"
    }
}

/// Windows 작품을 읽기 전용으로 검사하고 내부 임시 프로젝트를 거쳐 등록한다.
actor WindowsProjectImporter: ProjectImporting {
    private static let markerPrefix = ".writerpad-import-transaction-"
    private static let markerSuffix = ".json"

    private let projectRepository: any ProjectRepository
    private let documentRepository: any DocumentRepository
    private let metadataRegistrar: any ProjectImportMetadataRegistering
    private let workspaceStateRepository: any WorkspaceStateRepository
    private let projectManager: any ProjectManaging
    private let pathResolver: ProjectPathResolver
    private let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let hasher: any ContentHashing
    private let binderRuleService: BinderRuleService
    private let fileManager: FileManager
    private let faultPlan: ImportFaultPlan?

    init(
        projectRepository: any ProjectRepository,
        documentRepository: any DocumentRepository,
        metadataRegistrar: any ProjectImportMetadataRegistering,
        workspaceStateRepository: any WorkspaceStateRepository,
        projectManager: any ProjectManaging,
        pathResolver: ProjectPathResolver,
        clock: any AppClock,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher(),
        fileManager: FileManager = .default,
        faultPlan: ImportFaultPlan? = nil
    ) {
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.metadataRegistrar = metadataRegistrar
        self.workspaceStateRepository = workspaceStateRepository
        self.projectManager = projectManager
        self.pathResolver = pathResolver
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
        self.binderRuleService = BinderRuleService(pathPolicy: pathResolver.policy)
        self.fileManager = fileManager
        self.faultPlan = faultPlan
    }

    func inspect(_ sourceURL: URL) async throws -> ImportReport {
        try await recoverPendingImports()
        return try await withSecurityScopedAccess(to: sourceURL) {
            try await self.scan(sourceURL)
        }.report
    }

    func importProject(
        from report: ImportReport,
        confirmsWarnings: Bool
    ) async throws -> ProjectImportResult {
        try await recoverPendingImports()
        guard report.canImport else {
            throw WindowsProjectImporterError.reportHasFatalErrors
        }
        guard report.warnings.isEmpty || confirmsWarnings else {
            throw WindowsProjectImporterError.warningConfirmationRequired
        }

        return try await withSecurityScopedAccess(to: report.sourceSelectionURL) {
            let currentScan = try await self.scan(report.sourceSelectionURL)
            guard currentScan.report.canImport,
                  currentScan.report.fingerprint == report.fingerprint,
                  currentScan.report.proposedProjectName == report.proposedProjectName,
                  currentScan.report.sourceWorkspaceURL.standardizedFileURL
                    == report.sourceWorkspaceURL.standardizedFileURL
            else {
                throw WindowsProjectImporterError.sourceChangedAfterInspection
            }
            return try await self.performImport(scan: currentScan)
        }
    }

    func recoverPendingImports() async throws {
        guard fileManager.fileExists(atPath: pathResolver.projectsRootURL.path) else {
            return
        }
        let markerURLs = try fileManager.contentsOfDirectory(
            at: pathResolver.projectsRootURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(Self.markerPrefix)
                && $0.lastPathComponent.hasSuffix(Self.markerSuffix)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for markerURL in markerURLs {
            let marker: ImportTransactionMarker
            do {
                marker = try JSONDecoder.importDecoder.decode(
                    ImportTransactionMarker.self,
                    from: Data(contentsOf: markerURL)
                )
            } catch {
                throw WindowsProjectImporterError.recoveryRequired(markerURL.path)
            }

            let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
                marker.stagingFolderName,
                isDirectory: true
            )
            let finalURL = try pathResolver.standardPaths(
                forProjectNamed: marker.project.name
            ).projectContainerURL
            do {
                let storedProject = try await projectRepository.project(id: marker.project.id)
                if fileManager.fileExists(atPath: finalURL.path),
                   storedProject != nil {
                    let documents = try await documentRepository.documents(in: marker.project.id)
                    if documents.count == marker.expectedDocumentCount,
                       marker.phase == .promoted || marker.phase == .metadataRegistered {
                        try removeIfExists(stagingURL)
                        try await workspaceStateRepository.setLastProjectID(marker.project.id)
                        try removeIfExists(markerURL)
                        continue
                    }
                }
                try removeIfExists(stagingURL)
                try removeIfExists(finalURL)
                if storedProject != nil {
                    try await projectRepository.remove(id: marker.project.id)
                }
                try removeIfExists(markerURL)
            } catch {
                throw WindowsProjectImporterError.recoveryRequired(markerURL.path)
            }
        }
    }

    private func performImport(scan: ImportScanResult) async throws -> ProjectImportResult {
        let name = scan.report.proposedProjectName
        let transactionID = uuidGenerator.makeUUID()
        let projectID = ProjectID(rawValue: uuidGenerator.makeUUID())
        let now = clock.now()
        let project = Project(
            id: projectID,
            name: name,
            createdAt: now,
            modifiedAt: now
        )
        let stagingFolderName = ".writerpad-import-\(transactionID.uuidString).tmp"
        let stagingURL = pathResolver.projectsRootURL.appendingPathComponent(
            stagingFolderName,
            isDirectory: true
        )
        let destinationWorkspaceURL = stagingURL.appendingPathComponent(
            "집필모드",
            isDirectory: true
        )
        let finalURL = try pathResolver.standardPaths(
            forProjectNamed: name
        ).projectContainerURL
        var marker = ImportTransactionMarker(
            transactionID: transactionID,
            phase: .copying,
            project: project,
            stagingFolderName: stagingFolderName,
            expectedDocumentCount: 0
        )
        let markerURL = markerURL(transactionID)

        try fileManager.createDirectory(
            at: pathResolver.projectsRootURL,
            withIntermediateDirectories: true
        )
        try writeMarker(marker, to: markerURL)

        do {
            try fileManager.createDirectory(
                at: destinationWorkspaceURL,
                withIntermediateDirectories: true
            )
            try copyEntries(
                scan.entries,
                to: destinationWorkspaceURL
            )
            _ = try pathResolver.createStandardStructure(
                atProjectContainer: stagingURL,
                projectName: name
            )
            try pathResolver.updateStoredProjectName(
                atProjectContainer: stagingURL,
                projectName: name
            )

            let documents = try buildDocumentMetadata(
                projectID: projectID,
                workspaceURL: destinationWorkspaceURL
            )
            marker.phase = .staged
            marker.expectedDocumentCount = documents.count
            try writeMarker(marker, to: markerURL)

            try await metadataRegistrar.registerImportedProject(
                project,
                documents: documents
            )
            marker.phase = .metadataRegistered
            try writeMarker(marker, to: markerURL)
            try injectAfterMetadataRegistration()

            try fileManager.moveItem(at: stagingURL, to: finalURL)
            marker.phase = .promoted
            try writeMarker(marker, to: markerURL)
            try await workspaceStateRepository.setLastProjectID(projectID)

            guard let managed = try await projectManager.projects().first(
                where: { $0.id == projectID }
            ) else {
                throw WindowsProjectImporterError.importedProjectUnavailable
            }
            try removeIfExists(markerURL)
            let legacyPaths = scan.report.issues.compactMap { issue -> RelativeDocumentPath? in
                switch issue.kind {
                case .legacyPlot, .legacyMainStory, .legacyPreMigrationBackup:
                    RelativeDocumentPath(rawValue: issue.relativePath)
                default:
                    nil
                }
            }
            return ProjectImportResult(
                project: managed,
                documentCount: documents.count,
                preservedLegacyPaths: legacyPaths
            )
        } catch {
            do {
                try removeIfExists(stagingURL)
                try removeIfExists(finalURL)
                if try await projectRepository.project(id: projectID) != nil {
                    try await projectRepository.remove(id: projectID)
                }
                try removeIfExists(markerURL)
            } catch {
                throw WindowsProjectImporterError.recoveryRequired(markerURL.path)
            }
            throw error
        }
    }

    private func scan(_ selectionURL: URL) async throws -> ImportScanResult {
        let selection = selectionURL.standardizedFileURL
        let resolution = resolveWorkspace(from: selection)
        guard let workspaceURL = resolution.workspaceURL else {
            let emptyHash = hasher.sha256(for: Data())
            let report = ImportReport(
                id: uuidGenerator.makeUUID(),
                sourceSelectionURL: selection,
                sourceWorkspaceURL: selection,
                proposedProjectName: resolution.projectName,
                scannedAt: clock.now(),
                fingerprint: emptyHash,
                directoryCount: 0,
                fileCount: 0,
                textFileCount: 0,
                totalBytes: 0,
                issues: [
                    ImportIssue(
                        severity: .fatal,
                        kind: .invalidSource,
                        relativePath: "",
                        message: "집필모드 폴더 또는 집필모드를 포함한 작품 폴더가 아닙니다."
                    )
                ]
            )
            return ImportScanResult(report: report, entries: [])
        }

        var projectName = storedProjectName(in: workspaceURL) ?? resolution.projectName
        if projectName.isEmpty { projectName = selection.lastPathComponent }
        var issues: [ImportIssue] = []
        do {
            try pathResolver.policy.validateName(projectName)
        } catch {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .invalidName,
                    relativePath: "",
                    message: "작품 이름을 사용할 수 없습니다: \(error.localizedDescription)"
                )
            )
        }

        let existingProjects = try await projectRepository.projects()
        let projectKey = pathResolver.policy.collisionKey(for: projectName)
        if let duplicate = existingProjects.first(where: {
            pathResolver.policy.collisionKey(for: $0.name) == projectKey
        }) {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .duplicateProject,
                    relativePath: "",
                    message: "같은 이름으로 판단되는 작품이 이미 있습니다: \(duplicate.name)"
                )
            )
        }
        if fileManager.fileExists(
            atPath: pathResolver.projectsRootURL
                .appendingPathComponent(projectName, isDirectory: true).path
        ) {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .duplicateProject,
                    relativePath: "",
                    message: "같은 이름의 작품 폴더가 이미 있습니다: \(projectName)"
                )
            )
        }

        var entries: [ImportScanEntry] = []
        var chapterPathsByNumber: [Int: String] = [:]
        try scanDirectory(
            workspaceURL,
            relativeComponents: [],
            entries: &entries,
            issues: &issues,
            chapterPathsByNumber: &chapterPathsByNumber
        )
        appendStructureIssues(
            workspaceURL: workspaceURL,
            existingPaths: Set(entries.map(\.relativePath)),
            issues: &issues
        )

        let manifest = entries.sorted { $0.relativePath < $1.relativePath }.map { entry in
            let kind: String
            switch entry.kind {
            case .directory: kind = "D"
            case .file: kind = "F"
            case .symbolicLink: kind = "L"
            }
            return "\(kind)\u{0}\(entry.relativePath)\u{0}\(entry.byteCount)\u{0}\(entry.contentHash?.rawValue ?? "-")\n"
        }.joined()
        let fingerprint = hasher.sha256(for: Data(manifest.utf8))
        let report = ImportReport(
            id: uuidGenerator.makeUUID(),
            sourceSelectionURL: selection,
            sourceWorkspaceURL: workspaceURL,
            proposedProjectName: projectName,
            scannedAt: clock.now(),
            fingerprint: fingerprint,
            directoryCount: entries.filter { $0.kind == .directory }.count,
            fileCount: entries.filter { $0.kind == .file }.count,
            textFileCount: entries.filter {
                $0.kind == .file && $0.relativePath.lowercased().hasSuffix(".txt")
            }.count,
            totalBytes: entries.reduce(0) { $0 + $1.byteCount },
            issues: issues.sorted {
                if $0.severity != $1.severity { return $0.severity == .fatal }
                if $0.relativePath != $1.relativePath {
                    return $0.relativePath.localizedStandardCompare($1.relativePath)
                        == .orderedAscending
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        )
        return ImportScanResult(report: report, entries: entries)
    }

    private func scanDirectory(
        _ directoryURL: URL,
        relativeComponents: [String],
        entries: inout [ImportScanEntry],
        issues: inout [ImportIssue],
        chapterPathsByNumber: inout [Int: String]
    ) throws {
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isReadableKey
                ]
            ).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        } catch {
            let path = relativeComponents.joined(separator: "/")
            issues.append(unreadableIssue(path))
            return
        }

        var namesByCollisionKey: [String: String] = [:]
        for child in children {
            let name = child.lastPathComponent
            let relative = (relativeComponents + [name]).joined(separator: "/")
            let collisionKey = pathResolver.policy.collisionKey(for: name)
            if let existing = namesByCollisionKey[collisionKey], existing != name {
                issues.append(
                    ImportIssue(
                        severity: .fatal,
                        kind: .nameCollision,
                        relativePath: relative,
                        message: "같은 폴더에서 정규화 후 충돌하는 이름이 있습니다: \(existing), \(name)"
                    )
                )
            } else {
                namesByCollisionKey[collisionKey] = name
            }
            do {
                try pathResolver.policy.validateName(name)
                try pathResolver.policy.validateRelativePath(
                    RelativeDocumentPath(rawValue: relative)
                )
            } catch {
                issues.append(
                    ImportIssue(
                        severity: .fatal,
                        kind: .invalidName,
                        relativePath: relative,
                        message: error.localizedDescription
                    )
                )
            }
            if name.hasPrefix(".") {
                issues.append(
                    ImportIssue(
                        severity: .warning,
                        kind: .hiddenItem,
                        relativePath: relative,
                        message: "숨김 항목을 원형 보존합니다."
                    )
                )
            }

            if let faultPlan,
               case let .unreadableItem(faultPath) = faultPlan.point,
               faultPath == relative {
                issues.append(unreadableIssue(relative))
                continue
            }

            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isReadableKey
                ])
            } catch {
                issues.append(unreadableIssue(relative))
                continue
            }
            if values.isReadable == false || !fileManager.isReadableFile(atPath: child.path) {
                issues.append(unreadableIssue(relative))
                continue
            }
            if values.isSymbolicLink == true {
                issues.append(
                    ImportIssue(
                        severity: .fatal,
                        kind: .symbolicLink,
                        relativePath: relative,
                        message: "작품 밖을 가리킬 수 있는 심볼릭 링크는 가져오지 않습니다."
                    )
                )
                entries.append(
                    ImportScanEntry(
                        relativePath: relative,
                        sourceURL: child,
                        kind: .symbolicLink,
                        byteCount: 0,
                        modifiedAt: values.contentModificationDate ?? clock.now(),
                        contentHash: nil
                    )
                )
                continue
            }

            if values.isDirectory == true {
                let entry = ImportScanEntry(
                    relativePath: relative,
                    sourceURL: child,
                    kind: .directory,
                    byteCount: 0,
                    modifiedAt: values.contentModificationDate ?? clock.now(),
                    contentHash: nil
                )
                entries.append(entry)
                inspectDirectoryRule(relative, issues: &issues)
                try scanDirectory(
                    child,
                    relativeComponents: relativeComponents + [name],
                    entries: &entries,
                    issues: &issues,
                    chapterPathsByNumber: &chapterPathsByNumber
                )
                continue
            }

            guard values.isRegularFile == true else {
                issues.append(
                    ImportIssue(
                        severity: .warning,
                        kind: .unknownItem,
                        relativePath: relative,
                        message: "일반 파일이나 폴더가 아닌 항목을 확인하세요."
                    )
                )
                continue
            }

            let data: Data
            do {
                data = try Data(contentsOf: child, options: .mappedIfSafe)
            } catch {
                issues.append(unreadableIssue(relative))
                continue
            }
            let contentHash = hasher.sha256(for: data)
            entries.append(
                ImportScanEntry(
                    relativePath: relative,
                    sourceURL: child,
                    kind: .file,
                    byteCount: Int64(values.fileSize ?? data.count),
                    modifiedAt: values.contentModificationDate ?? clock.now(),
                    contentHash: contentHash
                )
            )
            inspectFileRule(
                relative,
                data: data,
                issues: &issues,
                chapterPathsByNumber: &chapterPathsByNumber
            )
        }
    }

    private func inspectDirectoryRule(
        _ relativePath: String,
        issues: inout [ImportIssue]
    ) {
        let components = relativePath.split(separator: "/").map(String.init)
        if relativePath == "메인/플롯" {
            issues.append(legacyIssue(.legacyPlot, path: relativePath))
        } else if relativePath == "메인/메인 스토리 틀"
                    || relativePath == "메인 스토리 틀" {
            issues.append(legacyIssue(.legacyMainStory, path: relativePath))
        } else if relativePath == "백업/전환직전" {
            issues.append(legacyIssue(.legacyPreMigrationBackup, path: relativePath))
        }

        if components.count == 1,
           !["메인", "백업", "메인 스토리 틀"].contains(components[0]) {
            issues.append(
                ImportIssue(
                    severity: .warning,
                    kind: .unknownItem,
                    relativePath: relativePath,
                    message: "집필모드 최상위의 알 수 없는 폴더를 원형 보존합니다."
                )
            )
        }
        if components.count == 3,
           components[0] == "메인", components[1] == "원고",
           parseVolumeNumber(components[2]) == nil {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .invalidVolumeName,
                    relativePath: relativePath,
                    message: "원고 바로 아래 폴더는 1권 같은 N권 형식이어야 합니다."
                )
            )
        }
        if components.count > 3,
           components[0] == "메인", components[1] == "원고" {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .invalidChapterName,
                    relativePath: relativePath,
                    message: "권 폴더 안에는 NNN화.txt 파일만 둘 수 있습니다."
                )
            )
        }
    }

    private func inspectFileRule(
        _ relativePath: String,
        data: Data,
        issues: inout [ImportIssue],
        chapterPathsByNumber: inout [Int: String]
    ) {
        let components = relativePath.split(separator: "/").map(String.init)
        let isText = relativePath.lowercased().hasSuffix(".txt")
        if isText, String(data: data, encoding: .utf8) == nil {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .invalidUTF8,
                    relativePath: relativePath,
                    message: "UTF-8로 읽을 수 없는 TXT 파일입니다."
                )
            )
        }
        if components.count >= 2,
           components[0] == "메인", components[1] == "원고" {
            guard components.count == 4,
                  parseVolumeNumber(components[2]) != nil,
                  let chapterNumber = parseChapterNumber(components[3])
            else {
                issues.append(
                    ImportIssue(
                        severity: .fatal,
                        kind: .invalidChapterName,
                        relativePath: relativePath,
                        message: "원고 파일은 N권/NNN화.txt 형식이어야 합니다."
                    )
                )
                return
            }
            if let existing = chapterPathsByNumber[chapterNumber] {
                issues.append(
                    ImportIssue(
                        severity: .fatal,
                        kind: .duplicateChapterNumber,
                        relativePath: relativePath,
                        message: "같은 화 번호가 중복됩니다: \(existing), \(relativePath)"
                    )
                )
            } else {
                chapterPathsByNumber[chapterNumber] = relativePath
            }
            return
        }
        if !isText, relativePath != "설정.json" {
            issues.append(
                ImportIssue(
                    severity: .warning,
                    kind: .unknownItem,
                    relativePath: relativePath,
                    message: "TXT가 아닌 파일을 원형 보존합니다."
                )
            )
        }
    }

    private func appendStructureIssues(
        workspaceURL: URL,
        existingPaths: Set<String>,
        issues: inout [ImportIssue]
    ) {
        let required = ["메인", "메인/원고", "백업"]
        for path in required where !existingPaths.contains(path) {
            issues.append(
                ImportIssue(
                    severity: .fatal,
                    kind: .missingRequiredDirectory,
                    relativePath: path,
                    message: "필수 Windows 작품 폴더가 없습니다."
                )
            )
        }
        let optional = [
            "메인/캐릭터", "메인/설정집", "메인/메모장", "메인/흐름정리",
            "메인/복선", "메인/장소", "메인/휴지통", "백업/자동저장",
            "백업/복원전", "백업/충돌"
        ]
        for path in optional where !existingPaths.contains(path) {
            issues.append(
                ImportIssue(
                    severity: .warning,
                    kind: .missingOptionalDirectory,
                    relativePath: path,
                    message: "없는 표준 폴더는 가져오기 복사본에 새로 만듭니다."
                )
            )
        }
        let settingsPath = workspaceURL.appendingPathComponent("설정.json").path
        if !fileManager.fileExists(atPath: settingsPath) {
            issues.append(
                ImportIssue(
                    severity: .warning,
                    kind: .missingOptionalDirectory,
                    relativePath: "설정.json",
                    message: "설정.json이 없어 새 복사본에 기본 설정을 만듭니다."
                )
            )
        }
    }

    private func copyEntries(
        _ entries: [ImportScanEntry],
        to destinationWorkspaceURL: URL
    ) throws {
        let ordered = entries.sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
        var copiedCount = 0
        for entry in ordered {
            guard entry.kind != .symbolicLink else {
                throw WindowsProjectImporterError.reportHasFatalErrors
            }
            let relativePath = RelativeDocumentPath(rawValue: entry.relativePath)
            let destination = try pathResolver.validatedURL(
                for: relativePath,
                in: destinationWorkspaceURL
            )
            switch entry.kind {
            case .directory:
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
            case .file:
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: entry.sourceURL, to: destination)
            case .symbolicLink:
                break
            }
            copiedCount += 1
            if let faultPlan,
               case let .afterCopiedItem(targetCount) = faultPlan.point,
               copiedCount == targetCount {
                throw WindowsProjectImporterError.injectedFailure
            }
        }
    }

    private func buildDocumentMetadata(
        projectID: ProjectID,
        workspaceURL: URL
    ) throws -> [DocumentNode] {
        var candidates: [(path: String, kind: DocumentKind, modifiedAt: Date, hash: ContentHash?)] = []
        try collectMetadataCandidates(
            directoryURL: workspaceURL,
            relativeComponents: [],
            candidates: &candidates
        )
        candidates.sort {
            let leftDepth = $0.path.split(separator: "/").count
            let rightDepth = $1.path.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            if $0.kind != $1.kind { return $0.kind == .folder }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        var idByPath: [String: DocumentID] = [:]
        var orderByParent: [String: Int] = [:]
        var documents: [DocumentNode] = []
        for candidate in candidates {
            let id = DocumentID(rawValue: uuidGenerator.makeUUID())
            let parentPath = candidate.path.split(separator: "/").dropLast()
                .map(String.init).joined(separator: "/")
            let parentID = parentPath.isEmpty ? nil : idByPath[parentPath]
            let order = orderByParent[parentPath, default: 0]
            orderByParent[parentPath] = order + 1
            let node = DocumentNode(
                id: id,
                projectID: projectID,
                kind: candidate.kind,
                parentID: parentID,
                relativePath: RelativeDocumentPath(rawValue: candidate.path),
                userOrder: order,
                modifiedAt: candidate.modifiedAt,
                contentHash: candidate.hash
            )
            documents.append(node)
            idByPath[candidate.path] = id
        }
        return documents
    }

    private func collectMetadataCandidates(
        directoryURL: URL,
        relativeComponents: [String],
        candidates: inout [(path: String, kind: DocumentKind, modifiedAt: Date, hash: ContentHash?)]
    ) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]
        ).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
        for child in children {
            let components = relativeComponents + [child.lastPathComponent]
            let relative = components.joined(separator: "/")
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey
            ])
            if values.isDirectory == true {
                candidates.append((
                    relative,
                    .folder,
                    values.contentModificationDate ?? clock.now(),
                    nil
                ))
                try collectMetadataCandidates(
                    directoryURL: child,
                    relativeComponents: components,
                    candidates: &candidates
                )
            } else if values.isRegularFile == true,
                      relative.lowercased().hasSuffix(".txt") {
                let data = try Data(contentsOf: child, options: .mappedIfSafe)
                guard String(data: data, encoding: .utf8) != nil else {
                    throw WindowsProjectImporterError.sourceChangedAfterInspection
                }
                candidates.append((
                    relative,
                    .text,
                    values.contentModificationDate ?? clock.now(),
                    hasher.sha256(for: data)
                ))
            }
        }
    }

    private func resolveWorkspace(
        from selectionURL: URL
    ) -> (workspaceURL: URL?, projectName: String) {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selectionURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return (nil, selectionURL.deletingLastPathComponent().lastPathComponent)
        }
        if selectionURL.lastPathComponent == "집필모드" {
            return (selectionURL, selectionURL.deletingLastPathComponent().lastPathComponent)
        }
        let child = selectionURL.appendingPathComponent("집필모드", isDirectory: true)
        if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return (child, selectionURL.lastPathComponent)
        }
        let main = selectionURL.appendingPathComponent("메인", isDirectory: true)
        let backups = selectionURL.appendingPathComponent("백업", isDirectory: true)
        if fileManager.fileExists(atPath: main.path),
           fileManager.fileExists(atPath: backups.path) {
            return (selectionURL, selectionURL.deletingLastPathComponent().lastPathComponent)
        }
        return (nil, selectionURL.lastPathComponent)
    }

    private func storedProjectName(in workspaceURL: URL) -> String? {
        let settingsURL = workspaceURL.appendingPathComponent("설정.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["project_name"] as? String,
              !name.isEmpty
        else {
            return nil
        }
        return name
    }

    private func parseVolumeNumber(_ name: String) -> Int? {
        binderRuleService.volumeNumber(fromStoredName: name)
    }

    private func parseChapterNumber(_ name: String) -> Int? {
        binderRuleService.titledChapterIdentity(fromStoredName: name)?.number
    }

    private func unreadableIssue(_ relativePath: String) -> ImportIssue {
        ImportIssue(
            severity: .fatal,
            kind: .unreadableItem,
            relativePath: relativePath,
            message: "읽을 수 없는 파일 또는 폴더입니다."
        )
    }

    private func legacyIssue(
        _ kind: ImportIssueKind,
        path: String
    ) -> ImportIssue {
        ImportIssue(
            severity: .warning,
            kind: kind,
            relativePath: path,
            message: "고정 카테고리로 승격하거나 병합하지 않고 일반 레거시 자료로 보존합니다."
        )
    }

    private func injectAfterMetadataRegistration() throws {
        if faultPlan?.point == .afterMetadataRegistration {
            throw WindowsProjectImporterError.injectedFailure
        }
    }

    private func markerURL(_ id: UUID) -> URL {
        pathResolver.projectsRootURL.appendingPathComponent(
            "\(Self.markerPrefix)\(id.uuidString)\(Self.markerSuffix)"
        )
    }

    private func writeMarker(
        _ marker: ImportTransactionMarker,
        to url: URL
    ) throws {
        var data = try JSONEncoder.importEncoder.encode(marker)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
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
}

private extension JSONEncoder {
    static var importEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var importDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
