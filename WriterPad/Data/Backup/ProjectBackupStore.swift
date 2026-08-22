import Foundation

struct ProjectBackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let project: ProjectEntry
    let nodes: [Node]

    struct ProjectEntry: Codable, Equatable, Sendable {
        let uuid: String
        let title: String
        let order: Int

        private enum CodingKeys: String, CodingKey {
            case uuid
            case title
            case order
        }

        init(uuid: String, title: String, order: Int = 0) {
            self.uuid = uuid
            self.title = title
            self.order = order
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try container.decode(String.self, forKey: .uuid)
            title = try container.decode(String.self, forKey: .title)
            order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uuid, forKey: .uuid)
            try container.encode(title, forKey: .title)
            try container.encode(order, forKey: .order)
        }
    }

    struct Node: Codable, Equatable, Sendable {
        let uuid: String
        let kind: String
        let parentUUID: String?
        let path: String
        let title: String
        let order: Int
        let bytes: Int?
        let sha256: String?

        private enum CodingKeys: String, CodingKey {
            case uuid
            case kind
            case parentUUID = "parent_uuid"
            case path
            case title
            case order
            case bytes
            case sha256
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(uuid, forKey: .uuid)
            try container.encode(kind, forKey: .kind)
            try container.encode(parentUUID, forKey: .parentUUID)
            try container.encode(path, forKey: .path)
            try container.encode(title, forKey: .title)
            try container.encode(order, forKey: .order)
            try container.encodeIfPresent(bytes, forKey: .bytes)
            try container.encodeIfPresent(sha256, forKey: .sha256)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case project
        case nodes
    }
}

struct ProjectBackupReceipt: Equatable, Sendable {
    let packageURL: URL
    let manifest: ProjectBackupManifest
}

struct ProjectRestoreReceipt: Equatable, Sendable {
    let workspaceURL: URL
    let manifest: ProjectBackupManifest
}

enum ProjectBackupError: Error, Equatable, LocalizedError {
    case sourceWorkspaceMissing
    case packageMissing
    case destinationAlreadyExists
    case destinationInsideSource
    case inconsistentProjectID
    case unsupportedFormatVersion(Int)
    case invalidManifest(String)
    case unexpectedPackageEntry(String)
    case invalidDocumentEntry(String)
    case fileVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceWorkspaceMissing:
            "백업할 작품 저장소를 찾을 수 없습니다."
        case .packageMissing:
            "WriterPad 백업 패키지를 찾을 수 없습니다."
        case .destinationAlreadyExists:
            "복원 대상 경로가 이미 존재합니다. 빈 폴더에도 덮어쓰지 않습니다."
        case .destinationInsideSource:
            "백업 원본 안에는 백업 또는 복원 대상을 만들 수 없습니다."
        case .inconsistentProjectID:
            "백업 노드의 작품 UUID가 서로 다릅니다."
        case let .unsupportedFormatVersion(version):
            "지원하지 않는 WriterPad 백업 형식입니다: \(version)"
        case let .invalidManifest(reason):
            "WriterPad 백업 manifest가 올바르지 않습니다: \(reason)"
        case let .unexpectedPackageEntry(name):
            "WriterPad 백업 패키지에 계약되지 않은 항목이 있습니다: \(name)"
        case let .invalidDocumentEntry(uuid):
            "문서 백업 정보가 완전하지 않습니다: \(uuid)"
        case let .fileVerificationFailed(uuid):
            "문서 백업의 크기 또는 SHA-256이 일치하지 않습니다: \(uuid)"
        }
    }
}

enum ProjectBackupCoordinatorError: Error, Equatable {
    case missingProject(ProjectID)
}

/// 로컬 UUID 메타데이터와 실제 집필모드 경로를 독립 프로젝트 백업에 연결한다.
actor ProjectBackupCoordinator {
    private let projectRepository: any ProjectRepository
    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let backupStore: ProjectBackupStore

    init(
        projectRepository: any ProjectRepository,
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        backupStore: ProjectBackupStore = ProjectBackupStore()
    ) {
        self.projectRepository = projectRepository
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.backupStore = backupStore
    }

    func createBackup(
        for projectID: ProjectID,
        at packageURL: URL
    ) async throws -> ProjectBackupReceipt {
        guard let project = try await projectRepository.project(id: projectID) else {
            throw ProjectBackupCoordinatorError.missingProject(projectID)
        }
        let documents = try await documentRepository.documents(in: projectID)
        let workspace = try await workspaceLocator.workspaceRoot(for: projectID)
        return try await backupStore.createBackup(
            project: project,
            documents: documents,
            workspaceURL: workspace,
            packageURL: packageURL
        )
    }

    func restoreBackup(
        at packageURL: URL,
        to emptyWorkspaceURL: URL
    ) async throws -> ProjectRestoreReceipt {
        try await backupStore.restoreBackup(
            at: packageURL,
            to: emptyWorkspaceURL
        )
    }
}

/// 제목 기반 원본을 UUID 파일과 논리 트리 manifest로 독립 보존한다.
actor ProjectBackupStore {
    static let manifestFileName = "manifest.json"
    static let workspaceDirectoryName = "workspace"

    private let fileManager = FileManager.default
    private let hasher = SHA256ContentHasher()

    func createBackup(
        project: Project,
        documents: [DocumentNode],
        workspaceURL: URL,
        packageURL: URL
    ) throws -> ProjectBackupReceipt {
        guard documents.allSatisfy({ $0.projectID == project.id }) else {
            throw ProjectBackupError.inconsistentProjectID
        }

        let source = workspaceURL.standardizedFileURL
        let package = packageURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ProjectBackupError.sourceWorkspaceMissing
        }
        guard !fileManager.fileExists(atPath: package.path) else {
            throw ProjectBackupError.destinationAlreadyExists
        }
        guard !contains(package, in: source) else {
            throw ProjectBackupError.destinationInsideSource
        }

        // 사용자가 고른 이름에 직접 짓지 않는다. 짓는 중에 앱이 죽으면
        // manifest 없는 반쪽 디렉터리가 그 이름 그대로 남고, 같은 이름으로
        // 다시 시도하면 destinationAlreadyExists 로 막힌다. 옆에 임시로 짓고
        // 다 된 것만 옮긴다.
        let staging = package
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(package.lastPathComponent).partial-\(UUID().uuidString)",
                isDirectory: true
            )
        let workspace = staging.appendingPathComponent(
            Self.workspaceDirectoryName,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            var entries: [ProjectBackupManifest.Node] = []
            for document in documents {
                entries.append(
                    try backupEntry(
                        for: document,
                        sourceWorkspace: source,
                        backupWorkspace: workspace
                    )
                )
            }
            let manifest = ProjectBackupManifest(
                formatVersion: ProjectBackupManifest.currentFormatVersion,
                project: .init(
                    uuid: uuidString(project.id.rawValue),
                    title: nfc(project.name),
                    order: 0
                ),
                nodes: entries
            )
            // 복원이 거부할 manifest 를 만들어 놓고 "백업 성공"이라고 말하지
            // 않는다. 중복 UUID·없는 부모·순환처럼 읽기 시점에만 걸리던 것을
            // 여기서 먼저 막는다. 그러지 않으면 사용자는 복원하려는 날에야
            // 그 백업이 쓸 수 없다는 것을 안다.
            try validateManifest(manifest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(Self.manifestFileName),
                options: [.atomic]
            )
            try fileManager.moveItem(at: staging, to: package)
            return ProjectBackupReceipt(packageURL: package, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    func restoreBackup(
        at packageURL: URL,
        to workspaceURL: URL
    ) throws -> ProjectRestoreReceipt {
        let package = packageURL.standardizedFileURL
        let destination = workspaceURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProjectBackupError.destinationAlreadyExists
        }
        let manifest = try validatedManifest(at: package)
        let source = package.appendingPathComponent(
            Self.workspaceDirectoryName,
            isDirectory: true
        )
        guard !contains(destination, in: source) else {
            throw ProjectBackupError.destinationInsideSource
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
            try verifyFiles(in: destination, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return ProjectRestoreReceipt(
            workspaceURL: destination,
            manifest: manifest
        )
    }

    /// 외부 패키지를 제품 저장소에 반영하기 전에 구조와 모든 payload를 읽기 전용으로 검증한다.
    func validatedManifest(at packageURL: URL) throws -> ProjectBackupManifest {
        let package = packageURL.standardizedFileURL
        let packageValues = try? package.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: package.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              packageValues?.isSymbolicLink != true
        else {
            throw ProjectBackupError.packageMissing
        }

        let allowedRootEntries = Set([Self.manifestFileName, Self.workspaceDirectoryName])
        let rootEntries = try fileManager.contentsOfDirectory(
            at: package,
            includingPropertiesForKeys: nil,
            options: []
        )
        if let unexpected = rootEntries.first(where: {
            !allowedRootEntries.contains($0.lastPathComponent)
        }) {
            throw ProjectBackupError.unexpectedPackageEntry(unexpected.lastPathComponent)
        }

        let manifestURL = package.appendingPathComponent(Self.manifestFileName)
        let workspaceURL = package.appendingPathComponent(
            Self.workspaceDirectoryName,
            isDirectory: true
        )
        var workspaceIsDirectory: ObjCBool = false
        let manifestValues = try? manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let workspaceValues = try? workspaceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard fileManager.fileExists(
            atPath: workspaceURL.path,
            isDirectory: &workspaceIsDirectory
        ), workspaceIsDirectory.boolValue,
              manifestValues?.isRegularFile == true,
              manifestValues?.isSymbolicLink != true,
              workspaceValues?.isDirectory == true,
              workspaceValues?.isSymbolicLink != true
        else {
            throw ProjectBackupError.packageMissing
        }

        let manifest: ProjectBackupManifest
        do {
            manifest = try JSONDecoder().decode(
                ProjectBackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw ProjectBackupError.invalidManifest("manifest.json을 해석할 수 없습니다.")
        }
        guard manifest.formatVersion == ProjectBackupManifest.currentFormatVersion else {
            throw ProjectBackupError.unsupportedFormatVersion(manifest.formatVersion)
        }
        try validateManifest(manifest)
        try verifyExactPayloadSet(in: workspaceURL, manifest: manifest)
        try verifyFiles(in: workspaceURL, manifest: manifest)
        return manifest
    }

    private func backupEntry(
        for document: DocumentNode,
        sourceWorkspace: URL,
        backupWorkspace: URL
    ) throws -> ProjectBackupManifest.Node {
        let uuid = uuidString(document.id.rawValue)
        let parentUUID = document.parentID.map { uuidString($0.rawValue) }
        let path = nfc(document.relativePath.rawValue)
        let title = nfc(title(for: document))
        guard document.kind == .text else {
            return .init(
                uuid: uuid,
                kind: "folder",
                parentUUID: parentUUID,
                path: path,
                title: title,
                order: document.userOrder,
                bytes: nil,
                sha256: nil
            )
        }

        let data = try Data(
            contentsOf: sourceWorkspace.appendingPathComponent(
                document.relativePath.rawValue
            )
        )
        let hash = hasher.sha256(for: data).rawValue
        try data.write(
            to: backupWorkspace.appendingPathComponent(uuid),
            options: [.atomic]
        )
        return .init(
            uuid: uuid,
            kind: "document",
            parentUUID: parentUUID,
            path: path,
            title: title,
            order: document.userOrder,
            bytes: data.count,
            sha256: hash
        )
    }

    private func verifyFiles(
        in workspace: URL,
        manifest: ProjectBackupManifest
    ) throws {
        for node in manifest.nodes where node.kind == "document" {
            guard let byteCount = node.bytes, let expectedHash = node.sha256 else {
                throw ProjectBackupError.invalidDocumentEntry(node.uuid)
            }
            let data = try Data(
                contentsOf: workspace.appendingPathComponent(node.uuid)
            )
            guard data.count == byteCount,
                  hasher.sha256(for: data).rawValue == expectedHash
            else {
                throw ProjectBackupError.fileVerificationFailed(node.uuid)
            }
        }
    }

    private func validateManifest(_ manifest: ProjectBackupManifest) throws {
        let policy = PathPolicy()
        guard canonicalUUID(manifest.project.uuid) != nil else {
            throw ProjectBackupError.invalidManifest("project.uuid")
        }
        guard manifest.project.title == nfc(manifest.project.title) else {
            throw ProjectBackupError.invalidManifest("project.title은 NFC여야 합니다.")
        }
        guard manifest.project.order == 0 else {
            throw ProjectBackupError.invalidManifest("project.order는 0이어야 합니다.")
        }
        do {
            try policy.validateName(manifest.project.title)
        } catch {
            throw ProjectBackupError.invalidManifest("project.title: \(error.localizedDescription)")
        }

        var nodesByID: [String: ProjectBackupManifest.Node] = [:]
        for node in manifest.nodes {
            guard canonicalUUID(node.uuid) != nil else {
                throw ProjectBackupError.invalidManifest("node.uuid: \(node.uuid)")
            }
            guard nodesByID.updateValue(node, forKey: node.uuid) == nil else {
                throw ProjectBackupError.invalidManifest("중복 node.uuid: \(node.uuid)")
            }
            if let parentUUID = node.parentUUID, canonicalUUID(parentUUID) == nil {
                throw ProjectBackupError.invalidManifest("parent_uuid: \(parentUUID)")
            }
            guard node.order >= 0 else {
                throw ProjectBackupError.invalidManifest("음수 order: \(node.uuid)")
            }
            guard node.title == nfc(node.title), node.path == nfc(node.path) else {
                throw ProjectBackupError.invalidManifest("title/path는 NFC여야 합니다: \(node.uuid)")
            }
            do {
                try policy.validateRelativePath(
                    RelativeDocumentPath(rawValue: node.path)
                )
                switch node.kind {
                case "folder":
                    try policy.validateName(node.title)
                    guard node.bytes == nil, node.sha256 == nil else {
                        throw ProjectBackupError.invalidManifest(
                            "folder에 bytes/sha256이 있습니다: \(node.uuid)"
                        )
                    }
                case "document":
                    _ = try policy.textFileName(forDisplayName: node.title)
                    guard let bytes = node.bytes, bytes >= 0,
                          let hash = node.sha256,
                          ContentHash(rawValue: hash) != nil
                    else {
                        throw ProjectBackupError.invalidDocumentEntry(node.uuid)
                    }
                default:
                    throw ProjectBackupError.invalidManifest(
                        "알 수 없는 kind: \(node.kind)"
                    )
                }
            } catch let error as ProjectBackupError {
                throw error
            } catch {
                throw ProjectBackupError.invalidManifest(
                    "node.title \(node.uuid): \(error.localizedDescription)"
                )
            }
        }

        var siblingOrders: [String: Set<Int>] = [:]
        for node in manifest.nodes {
            if let parentUUID = node.parentUUID {
                guard let parent = nodesByID[parentUUID], parent.kind == "folder" else {
                    throw ProjectBackupError.invalidManifest(
                        "없는 폴더 parent_uuid: \(node.uuid)"
                    )
                }
            }
            let parentKey = node.parentUUID ?? "<root>"
            guard siblingOrders[parentKey, default: []].insert(node.order).inserted else {
                throw ProjectBackupError.invalidManifest(
                    "같은 부모 아래 중복 order: \(parentKey)"
                )
            }
        }

        var visited: Set<String> = []
        var visiting: Set<String> = []
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            guard visiting.insert(id).inserted else {
                throw ProjectBackupError.invalidManifest("순환 parent_uuid: \(id)")
            }
            if let parent = nodesByID[id]?.parentUUID {
                try visit(parent)
            }
            visiting.remove(id)
            visited.insert(id)
        }
        for id in nodesByID.keys {
            try visit(id)
        }
    }

    private func verifyExactPayloadSet(
        in workspace: URL,
        manifest: ProjectBackupManifest
    ) throws {
        let expected = Set(
            manifest.nodes.filter { $0.kind == "document" }.map(\.uuid)
        )
        let entries = try fileManager.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        var actual: Set<String> = []
        for entry in entries {
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  canonicalUUID(entry.lastPathComponent) != nil
            else {
                throw ProjectBackupError.unexpectedPackageEntry(
                    "workspace/\(entry.lastPathComponent)"
                )
            }
            actual.insert(entry.lastPathComponent)
        }
        guard actual == expected else {
            let difference = expected.symmetricDifference(actual).sorted().joined(separator: ", ")
            throw ProjectBackupError.unexpectedPackageEntry("workspace: \(difference)")
        }
    }

    private func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else { return nil }
        return uuid
    }

    private func title(for document: DocumentNode) -> String {
        let component = (document.relativePath.rawValue as NSString).lastPathComponent
        return document.kind == .text
            ? (component as NSString).deletingPathExtension
            : component
    }

    private func uuidString(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    private func nfc(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
