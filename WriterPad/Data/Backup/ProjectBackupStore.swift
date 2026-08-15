import Foundation

struct ProjectBackupManifest: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let project: ProjectEntry
    let nodes: [Node]

    struct ProjectEntry: Codable, Equatable, Sendable {
        let uuid: String
        let title: String
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

enum ProjectBackupError: Error, Equatable {
    case sourceWorkspaceMissing
    case destinationAlreadyExists
    case destinationInsideSource
    case inconsistentProjectID
    case unsupportedFormatVersion(Int)
    case invalidDocumentEntry(String)
    case fileVerificationFailed(String)
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

        let workspace = package.appendingPathComponent(
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
                    title: nfc(project.name)
                ),
                nodes: entries
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: package.appendingPathComponent(Self.manifestFileName),
                options: [.atomic]
            )
            return ProjectBackupReceipt(packageURL: package, manifest: manifest)
        } catch {
            try? fileManager.removeItem(at: package)
            throw error
        }
    }

    func restoreBackup(
        at packageURL: URL,
        to workspaceURL: URL
    ) throws -> ProjectRestoreReceipt {
        let package = packageURL.standardizedFileURL
        let source = package.appendingPathComponent(
            Self.workspaceDirectoryName,
            isDirectory: true
        )
        let destination = workspaceURL.standardizedFileURL
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ProjectBackupError.destinationAlreadyExists
        }
        guard !contains(destination, in: source) else {
            throw ProjectBackupError.destinationInsideSource
        }

        let manifest = try JSONDecoder().decode(
            ProjectBackupManifest.self,
            from: Data(
                contentsOf: package.appendingPathComponent(Self.manifestFileName)
            )
        )
        guard manifest.formatVersion == ProjectBackupManifest.currentFormatVersion else {
            throw ProjectBackupError.unsupportedFormatVersion(manifest.formatVersion)
        }
        try verifyFiles(in: source, manifest: manifest)

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
