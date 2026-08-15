import Foundation

enum IndependentProjectBackupError: Error, Equatable, LocalizedError {
    case destinationParentMissing(String)
    case destinationAlreadyExists(String)
    case destinationInsideWorkspace(String)
    case invalidProject(String)
    case duplicateDocumentID(String)
    case duplicateRelativePath(String)
    case invalidRelativePath(String)
    case missingParent(String)
    case parentIsNotFolder(String)
    case parentPathMismatch(String)
    case sourceMissing(String)
    case sourceTypeMismatch(String)
    case symbolicLinkNotAllowed(String)
    case invalidUTF8(String)
    case contentHashMismatch(String)
    case manifestMissing
    case manifestInvalid(String)
    case unsupportedFormat(String, Int)
    case unexpectedPackageFile(String)
    case restoreVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .destinationParentMissing(path):
            "백업 또는 복구 대상의 부모 폴더를 찾을 수 없습니다: \(path)"
        case let .destinationAlreadyExists(path):
            "기존 파일이나 폴더를 덮어쓰지 않습니다: \(path)"
        case let .destinationInsideWorkspace(path):
            "독립 백업은 원본 workspace 밖에 저장해야 합니다: \(path)"
        case let .invalidProject(detail):
            "프로젝트 메타데이터가 일치하지 않습니다: \(detail)"
        case let .duplicateDocumentID(value):
            "중복 문서 ID가 있습니다: \(value)"
        case let .duplicateRelativePath(path):
            "중복 상대 경로가 있습니다: \(path)"
        case let .invalidRelativePath(path):
            "안전하지 않은 상대 경로입니다: \(path)"
        case let .missingParent(value):
            "부모 폴더 ID를 찾을 수 없습니다: \(value)"
        case let .parentIsNotFolder(value):
            "부모 ID가 폴더를 가리키지 않습니다: \(value)"
        case let .parentPathMismatch(path):
            "부모 ID와 상대 경로의 구조가 다릅니다: \(path)"
        case let .sourceMissing(path):
            "백업할 원본을 찾을 수 없습니다: \(path)"
        case let .sourceTypeMismatch(path):
            "원본의 파일 종류가 메타데이터와 다릅니다: \(path)"
        case let .symbolicLinkNotAllowed(path):
            "백업과 복구 경로에는 symbolic link를 허용하지 않습니다: \(path)"
        case let .invalidUTF8(path):
            "UTF-8 원문으로 읽을 수 없습니다: \(path)"
        case let .contentHashMismatch(path):
            "본문 SHA-256이 일치하지 않습니다: \(path)"
        case .manifestMissing:
            "manifest.json을 찾을 수 없습니다."
        case let .manifestInvalid(detail):
            "백업 manifest가 유효하지 않습니다: \(detail)"
        case let .unsupportedFormat(format, version):
            "지원하지 않는 백업 형식입니다: \(format) v\(version)"
        case let .unexpectedPackageFile(path):
            "manifest에 없는 파일이 백업 패키지에 있습니다: \(path)"
        case let .restoreVerificationFailed(detail):
            "복구 결과 검증에 실패했습니다: \(detail)"
        }
    }
}
/// 프로젝트 전체를 원본 workspace 밖의 새 디렉터리에 보존하고,
/// 빈 임시 위치에 구조를 다시 만든 뒤 hash와 UUID manifest를 검증한다.
actor IndependentProjectBackupStore {
    static let manifestFileName = "manifest.json"
    static let contentDirectoryName = "files"
    static let restoredIdentityManifestFileName = "writerpad-project-manifest.json"

    private let workspaceLocator: any ProjectWorkspaceLocating
    private let fileManager: FileManager
    private let clock: any AppClock
    private let uuidGenerator: any UUIDGenerating
    private let hasher: any ContentHashing

    init(
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default,
        clock: any AppClock = SystemClock(),
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator(),
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
        self.clock = clock
        self.uuidGenerator = uuidGenerator
        self.hasher = hasher
    }

    func createBackup(
        project: Project,
        documents: [DocumentNode],
        at packageURL: URL
    ) async throws -> IndependentProjectBackupReceipt {
        let workspaceRoot = try await workspaceLocator.workspaceRoot(for: project.id)
        let canonicalWorkspace = workspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        try requireExistingDirectory(canonicalWorkspace)
        try requireNoSymbolicLinks(at: workspaceRoot, relativeTo: workspaceRoot)

        let canonicalPackage = try canonicalNewDestination(packageURL)
        if Self.isContained(canonicalPackage, in: canonicalWorkspace) {
            throw IndependentProjectBackupError.destinationInsideWorkspace(
                canonicalPackage.path
            )
        }

        try validate(project: project, documents: documents)
        let backupID = uuidGenerator.makeUUID()
        let stagingURL = canonicalPackage.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(canonicalPackage.lastPathComponent).partial-\(backupID.uuidString.lowercased())",
                isDirectory: true
            )
        guard !fileManager.fileExists(atPath: stagingURL.path) else {
            throw IndependentProjectBackupError.destinationAlreadyExists(stagingURL.path)
        }

        var createdStaging = false
        do {
            try fileManager.createDirectory(
                at: stagingURL.appendingPathComponent(Self.contentDirectoryName),
                withIntermediateDirectories: true
            )
            createdStaging = true

            var entries: [IndependentProjectBackupManifest.Entry] = []
            for document in Self.sorted(documents) {
                let sourceURL = try sourceURL(
                    for: document.relativePath,
                    workspaceRoot: canonicalWorkspace
                )
                try requireNoSymbolicLinks(at: sourceURL, relativeTo: canonicalWorkspace)
                switch document.kind {
                case .folder:
                    try requireType(.typeDirectory, at: sourceURL)
                    let destination = contentURL(
                        for: document.relativePath,
                        packageRoot: stagingURL
                    )
                    try fileManager.createDirectory(
                        at: destination,
                        withIntermediateDirectories: true
                    )
                    entries.append(.init(node: document, content: nil))
                case .text:
                    try requireType(.typeRegular, at: sourceURL)
                    let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
                    guard String(data: data, encoding: .utf8) != nil else {
                        throw IndependentProjectBackupError.invalidUTF8(
                            document.relativePath.rawValue
                        )
                    }
                    let hash = hasher.sha256(for: data)
                    if let recorded = document.contentHash, recorded != hash {
                        throw IndependentProjectBackupError.contentHashMismatch(
                            document.relativePath.rawValue
                        )
                    }
                    let destination = contentURL(
                        for: document.relativePath,
                        packageRoot: stagingURL
                    )
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destination, options: [.atomic])
                    entries.append(
                        .init(
                            node: document,
                            content: .init(
                                packagePath: Self.packagePath(
                                    for: document.relativePath
                                ),
                                utf8ByteCount: data.count,
                                sha256: hash
                            )
                        )
                    )
                }
            }

            let manifest = IndependentProjectBackupManifest(
                backupID: backupID,
                createdAt: clock.now(),
                project: project,
                entries: entries
            )
            try encoded(manifest).write(
                to: stagingURL.appendingPathComponent(Self.manifestFileName),
                options: [.atomic]
            )
            _ = try verifyBackup(at: stagingURL)
            try fileManager.moveItem(at: stagingURL, to: canonicalPackage)
            let verified = try verifyBackup(at: canonicalPackage)
            return .init(packageURL: canonicalPackage, manifest: verified)
        } catch {
            if createdStaging, fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    func verifyBackup(
        at packageURL: URL
    ) throws -> IndependentProjectBackupManifest {
        let root = packageURL.standardizedFileURL
        try requireExistingDirectory(root)
        try requireNoSymbolicLinks(at: root, relativeTo: root)
        let manifestURL = root.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw IndependentProjectBackupError.manifestMissing
        }
        try requireType(.typeRegular, at: manifestURL)

        let manifest: IndependentProjectBackupManifest
        do {
            manifest = try decoded(
                IndependentProjectBackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch let error as IndependentProjectBackupError {
            throw error
        } catch {
            throw IndependentProjectBackupError.manifestInvalid(
                String(describing: error)
            )
        }
        try validate(manifest: manifest)

        var expectedFiles: Set<String> = [Self.manifestFileName]
        for entry in manifest.entries {
            let path = entry.node.relativePath
            let itemURL = contentURL(for: path, packageRoot: root)
            try requireNoSymbolicLinks(at: itemURL, relativeTo: root)
            switch entry.node.kind {
            case .folder:
                try requireType(.typeDirectory, at: itemURL)
            case .text:
                guard let content = entry.content else {
                    throw IndependentProjectBackupError.manifestInvalid(
                        "text entry has no content: \(path.rawValue)"
                    )
                }
                try requireType(.typeRegular, at: itemURL)
                let data = try Data(contentsOf: itemURL, options: [.mappedIfSafe])
                guard String(data: data, encoding: .utf8) != nil else {
                    throw IndependentProjectBackupError.invalidUTF8(path.rawValue)
                }
                guard data.count == content.utf8ByteCount,
                      hasher.sha256(for: data) == content.sha256
                else {
                    throw IndependentProjectBackupError.contentHashMismatch(
                        path.rawValue
                    )
                }
                expectedFiles.insert(content.packagePath)
            }
        }

        let actualFiles = try regularFiles(relativeTo: root)
        if let unexpected = actualFiles.subtracting(expectedFiles).sorted().first {
            throw IndependentProjectBackupError.unexpectedPackageFile(unexpected)
        }
        if let missing = expectedFiles.subtracting(actualFiles).sorted().first {
            throw IndependentProjectBackupError.sourceMissing(missing)
        }
        return manifest
    }

    func restoreVerifiedBackup(
        at packageURL: URL,
        to restoredWorkspaceURL: URL
    ) throws -> IndependentProjectRestoreReceipt {
        let packageRoot = packageURL.standardizedFileURL
        let manifest = try verifyBackup(at: packageRoot)
        let destination = try canonicalNewDestination(restoredWorkspaceURL)
        if Self.isContained(destination, in: packageRoot) {
            throw IndependentProjectBackupError.destinationInsideWorkspace(
                destination.path
            )
        }

        let stagingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).restore-\(manifest.backupID.uuidString.lowercased())",
                isDirectory: true
            )
        guard !fileManager.fileExists(atPath: stagingURL.path) else {
            throw IndependentProjectBackupError.destinationAlreadyExists(stagingURL.path)
        }

        var createdStaging = false
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
            createdStaging = true
            for entry in manifest.entries where entry.node.kind == .folder {
                let destinationURL = try restoredURL(
                    for: entry.node.relativePath,
                    restoredRoot: stagingURL
                )
                try fileManager.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
            }
            for entry in manifest.entries where entry.node.kind == .text {
                guard let content = entry.content else {
                    throw IndependentProjectBackupError.manifestInvalid(
                        "text entry has no content: \(entry.node.relativePath.rawValue)"
                    )
                }
                let source = packageRoot.appendingPathComponent(content.packagePath)
                let destinationURL = try restoredURL(
                    for: entry.node.relativePath,
                    restoredRoot: stagingURL
                )
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(contentsOf: source).write(to: destinationURL, options: [.atomic])
            }

            let identityURL = stagingURL.appendingPathComponent(
                Self.restoredIdentityManifestFileName
            )
            try encoded(manifest).write(to: identityURL, options: [.atomic])
            try verifyRestoredWorkspace(at: stagingURL, manifest: manifest)
            try fileManager.moveItem(at: stagingURL, to: destination)
            try verifyRestoredWorkspace(at: destination, manifest: manifest)
            return .init(
                restoredWorkspaceURL: destination,
                identityManifestURL: destination.appendingPathComponent(
                    Self.restoredIdentityManifestFileName
                ),
                manifest: manifest
            )
        } catch {
            if createdStaging, fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            throw error
        }
    }

    private func verifyRestoredWorkspace(
        at root: URL,
        manifest: IndependentProjectBackupManifest
    ) throws {
        try requireExistingDirectory(root)
        try requireNoSymbolicLinks(at: root, relativeTo: root)
        let identityURL = root.appendingPathComponent(
            Self.restoredIdentityManifestFileName
        )
        try requireType(.typeRegular, at: identityURL)
        let restoredManifest: IndependentProjectBackupManifest
        do {
            restoredManifest = try decoded(
                IndependentProjectBackupManifest.self,
                from: Data(contentsOf: identityURL)
            )
        } catch {
            throw IndependentProjectBackupError.restoreVerificationFailed(
                "identity manifest decode: \(error)"
            )
        }
        guard restoredManifest == manifest else {
            throw IndependentProjectBackupError.restoreVerificationFailed(
                "identity manifest mismatch"
            )
        }

        var expectedFiles: Set<String> = [Self.restoredIdentityManifestFileName]
        for entry in manifest.entries {
            let itemURL = try restoredURL(
                for: entry.node.relativePath,
                restoredRoot: root
            )
            try requireNoSymbolicLinks(at: itemURL, relativeTo: root)
            switch entry.node.kind {
            case .folder:
                try requireType(.typeDirectory, at: itemURL)
            case .text:
                guard let content = entry.content else {
                    throw IndependentProjectBackupError.restoreVerificationFailed(
                        "missing content descriptor: \(entry.node.relativePath.rawValue)"
                    )
                }
                try requireType(.typeRegular, at: itemURL)
                let data = try Data(contentsOf: itemURL, options: [.mappedIfSafe])
                guard String(data: data, encoding: .utf8) != nil,
                      data.count == content.utf8ByteCount,
                      hasher.sha256(for: data) == content.sha256
                else {
                    throw IndependentProjectBackupError.restoreVerificationFailed(
                        entry.node.relativePath.rawValue
                    )
                }
                expectedFiles.insert(entry.node.relativePath.rawValue)
            }
        }

        let actualFiles = try regularFiles(relativeTo: root)
        guard actualFiles == expectedFiles else {
            let detail = actualFiles.symmetricDifference(expectedFiles)
                .sorted().joined(separator: ", ")
            throw IndependentProjectBackupError.restoreVerificationFailed(detail)
        }
    }

    private func validate(
        project: Project,
        documents: [DocumentNode]
    ) throws {
        try validateEntries(project: project, entries: documents.map { ($0, nil) })
    }

    private func validate(
        manifest: IndependentProjectBackupManifest
    ) throws {
        guard manifest.format == IndependentProjectBackupManifest.formatName,
              manifest.formatVersion == IndependentProjectBackupManifest.currentFormatVersion
        else {
            throw IndependentProjectBackupError.unsupportedFormat(
                manifest.format,
                manifest.formatVersion
            )
        }
        try validateEntries(
            project: manifest.project,
            entries: manifest.entries.map { ($0.node, $0.content) }
        )
        for entry in manifest.entries {
            switch (entry.node.kind, entry.content) {
            case (.folder, nil):
                break
            case let (.text, content?):
                let expected = Self.packagePath(for: entry.node.relativePath)
                guard content.packagePath == expected,
                      content.utf8ByteCount >= 0
                else {
                    throw IndependentProjectBackupError.manifestInvalid(
                        entry.node.relativePath.rawValue
                    )
                }
            default:
                throw IndependentProjectBackupError.manifestInvalid(
                    entry.node.relativePath.rawValue
                )
            }
        }
    }

    private func validateEntries(
        project: Project,
        entries: [(DocumentNode, IndependentProjectBackupManifest.Content?)]
    ) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndependentProjectBackupError.invalidProject("empty name")
        }
        var ids: Set<DocumentID> = []
        var paths: Set<String> = []
        var byID: [DocumentID: DocumentNode] = [:]
        for (node, _) in entries {
            guard node.projectID == project.id else {
                throw IndependentProjectBackupError.invalidProject(
                    node.id.rawValue.uuidString.lowercased()
                )
            }
            guard ids.insert(node.id).inserted else {
                throw IndependentProjectBackupError.duplicateDocumentID(
                    node.id.rawValue.uuidString.lowercased()
                )
            }
            try Self.validateRelativePath(node.relativePath.rawValue)
            guard paths.insert(node.relativePath.rawValue).inserted else {
                throw IndependentProjectBackupError.duplicateRelativePath(
                    node.relativePath.rawValue
                )
            }
            byID[node.id] = node
        }
        for (node, _) in entries {
            guard let parentID = node.parentID else { continue }
            guard let parent = byID[parentID] else {
                throw IndependentProjectBackupError.missingParent(
                    parentID.rawValue.uuidString.lowercased()
                )
            }
            guard parent.kind == .folder else {
                throw IndependentProjectBackupError.parentIsNotFolder(
                    parentID.rawValue.uuidString.lowercased()
                )
            }
            let parentPath = node.relativePath.rawValue
                .split(separator: "/", omittingEmptySubsequences: false)
                .dropLast().joined(separator: "/")
            guard parentPath == parent.relativePath.rawValue else {
                throw IndependentProjectBackupError.parentPathMismatch(
                    node.relativePath.rawValue
                )
            }
        }
    }

    private func sourceURL(
        for path: RelativeDocumentPath,
        workspaceRoot: URL
    ) throws -> URL {
        try Self.validateRelativePath(path.rawValue)
        let candidate = workspaceRoot.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        guard Self.isContained(candidate, in: workspaceRoot) else {
            throw IndependentProjectBackupError.invalidRelativePath(path.rawValue)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw IndependentProjectBackupError.sourceMissing(path.rawValue)
        }
        return candidate
    }

    private func contentURL(
        for path: RelativeDocumentPath,
        packageRoot: URL
    ) -> URL {
        packageRoot.appendingPathComponent(Self.contentDirectoryName, isDirectory: true)
            .appendingPathComponent(path.rawValue)
    }

    private func restoredURL(
        for path: RelativeDocumentPath,
        restoredRoot: URL
    ) throws -> URL {
        try Self.validateRelativePath(path.rawValue)
        let candidate = restoredRoot.appendingPathComponent(path.rawValue)
            .standardizedFileURL
        guard Self.isContained(candidate, in: restoredRoot) else {
            throw IndependentProjectBackupError.invalidRelativePath(path.rawValue)
        }
        return candidate
    }

    private func canonicalNewDestination(_ requested: URL) throws -> URL {
        let parent = requested.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
        try requireExistingDirectory(parent)
        guard !requested.lastPathComponent.isEmpty else {
            throw IndependentProjectBackupError.invalidRelativePath(requested.path)
        }
        let destination = parent.appendingPathComponent(
            requested.lastPathComponent,
            isDirectory: true
        ).standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw IndependentProjectBackupError.destinationAlreadyExists(destination.path)
        }
        return destination
    }

    private func requireExistingDirectory(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw IndependentProjectBackupError.destinationParentMissing(url.path)
        }
        try requireType(.typeDirectory, at: url)
    }

    private func requireType(
        _ expected: FileAttributeType,
        at url: URL
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw IndependentProjectBackupError.sourceMissing(url.path)
        }
        let type = try fileManager.attributesOfItem(atPath: url.path)[.type]
            as? FileAttributeType
        if type == .typeSymbolicLink {
            throw IndependentProjectBackupError.symbolicLinkNotAllowed(url.path)
        }
        guard type == expected else {
            throw IndependentProjectBackupError.sourceTypeMismatch(url.path)
        }
    }

    private func requireNoSymbolicLinks(
        at url: URL,
        relativeTo root: URL
    ) throws {
        let standardizedRoot = root.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        guard Self.isContained(standardizedURL, in: standardizedRoot) else {
            throw IndependentProjectBackupError.invalidRelativePath(url.path)
        }
        let relative: String
        if standardizedURL.path == standardizedRoot.path {
            relative = ""
        } else {
            relative = String(
                standardizedURL.path.dropFirst(standardizedRoot.path.count + 1)
            )
        }
        var current = standardizedRoot
        let paths = [""] + relative.split(separator: "/").map(String.init)
        for component in paths {
            if !component.isEmpty {
                current.appendPathComponent(component)
            }
            guard fileManager.fileExists(atPath: current.path) else { continue }
            let type = try fileManager.attributesOfItem(atPath: current.path)[.type]
                as? FileAttributeType
            if type == .typeSymbolicLink {
                throw IndependentProjectBackupError.symbolicLinkNotAllowed(
                    current.path
                )
            }
        }
    }

    private func regularFiles(relativeTo root: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil
        ) else {
            throw IndependentProjectBackupError.sourceMissing(root.path)
        }
        var result: Set<String> = []
        for case let item as URL in enumerator {
            let type = try fileManager.attributesOfItem(atPath: item.path)[.type]
                as? FileAttributeType
            if type == .typeSymbolicLink {
                throw IndependentProjectBackupError.symbolicLinkNotAllowed(
                    item.path
                )
            }
            guard type == .typeRegular else { continue }
            result.insert(
                String(item.path.dropFirst(root.path.count + 1))
            )
        }
        return result
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decoded<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private static func sorted(_ documents: [DocumentNode]) -> [DocumentNode] {
        documents.sorted {
            let left = $0.relativePath.rawValue
            let right = $1.relativePath.rawValue
            if left != right { return left < right }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
    }

    private static func packagePath(for path: RelativeDocumentPath) -> String {
        "\(contentDirectoryName)/\(path.rawValue)"
    }

    private static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else {
            throw IndependentProjectBackupError.invalidRelativePath(path)
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw IndependentProjectBackupError.invalidRelativePath(path)
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
