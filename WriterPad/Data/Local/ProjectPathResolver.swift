import Foundation

enum ProjectPathResolverError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case settingsPathIsNotFile(String)
    case settingsFileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support 경로를 찾을 수 없습니다."
        case let .settingsPathIsNotFile(path):
            "설정 경로가 파일이 아닙니다: \(path)"
        case let .settingsFileCreationFailed(path):
            "설정 파일을 만들 수 없습니다: \(path)"
        }
    }
}

struct StandardProjectPaths: Equatable {
    let projectContainerURL: URL
    let workspaceRootURL: URL
    let mainURL: URL
    let manuscriptURL: URL
    let charactersURL: URL
    let settingsCollectionURL: URL
    let notesURL: URL
    let flowURL: URL
    let foreshadowingURL: URL
    let placesURL: URL
    let trashURL: URL
    let backupsURL: URL
    let automaticBackupsURL: URL
    let beforeRestoreBackupsURL: URL
    let conflictBackupsURL: URL
    let settingsFileURL: URL

    var requiredDirectories: [URL] {
        [
            projectContainerURL,
            workspaceRootURL,
            mainURL,
            manuscriptURL,
            charactersURL,
            settingsCollectionURL,
            notesURL,
            flowURL,
            foreshadowingURL,
            placesURL,
            trashURL,
            backupsURL,
            automaticBackupsURL,
            beforeRestoreBackupsURL,
            conflictBackupsURL
        ]
    }
}

/// 작품 경로 생성을 한곳에 모으고 표준화 후 루트 포함 여부를 재검사한다.
struct ProjectPathResolver: @unchecked Sendable {
    static let legacyPlotPath = RelativeDocumentPath(rawValue: "메인/플롯")
    static let legacyPreMigrationBackupPath = RelativeDocumentPath(rawValue: "백업/전환직전")

    let projectsRootURL: URL
    let policy: PathPolicy
    private let fileManager: FileManager

    init(
        projectsRootURL: URL,
        policy: PathPolicy = PathPolicy(),
        fileManager: FileManager = .default
    ) {
        self.projectsRootURL = projectsRootURL.standardizedFileURL
        self.policy = policy
        self.fileManager = fileManager
    }

    static func live(
        policy: PathPolicy = PathPolicy(),
        fileManager: FileManager = .default
    ) throws -> ProjectPathResolver {
        guard let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw ProjectPathResolverError.applicationSupportUnavailable
        }
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            throw ProjectPathResolverError.applicationSupportUnavailable
        }
        let legacyRoot = applicationSupport
            .appendingPathComponent("WriterPad", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        // iOS 파일 앱의 “나의 iPad > ChocoS”에는 Documents 폴더만 노출된다.
        // 작품 폴더를 바로 이 루트에 두어 목록을 별도 중간 폴더 없이 관리할 수 있게 한다.
        let root = documents
        try migrateLegacyProjectsIfNeeded(
            from: legacyRoot,
            to: root,
            fileManager: fileManager
        )
        return ProjectPathResolver(
            projectsRootURL: root,
            policy: policy,
            fileManager: fileManager
        )
    }

    /// 파일 앱 노출 전 Application Support에 저장된 기존 작품을 Documents로 옮긴다.
    /// 대상에 같은 이름이 있으면 덮어쓰지 않고 그대로 둬 사용자의 파일을 보존한다.
    private static func migrateLegacyProjectsIfNeeded(
        from legacyRoot: URL,
        to documentsRoot: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }
        try fileManager.createDirectory(
            at: documentsRoot,
            withIntermediateDirectories: true
        )
        let legacyItems = try fileManager.contentsOfDirectory(
            at: legacyRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in legacyItems {
            let destination = documentsRoot.appendingPathComponent(item.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: item, to: destination)
        }
        // 비어 있는 이전 저장소만 정리한다. 충돌 파일은 복구 여지를 위해 남긴다.
        if (try? fileManager.contentsOfDirectory(atPath: legacyRoot.path).isEmpty) == true {
            try? fileManager.removeItem(at: legacyRoot)
        }
    }

    func standardPaths(forProjectNamed projectName: String) throws -> StandardProjectPaths {
        try policy.validateName(projectName)
        let projectContainer = projectsRootURL
            .appendingPathComponent(projectName, isDirectory: true)
        return try standardPaths(
            atProjectContainer: projectContainer,
            projectName: projectName
        )
    }

    /// 거래용 임시 폴더처럼 최종 작품명과 다른 컨테이너에도 표준 구조를 계산한다.
    func standardPaths(
        atProjectContainer projectContainer: URL,
        projectName: String
    ) throws -> StandardProjectPaths {
        try policy.validateName(projectName)
        _ = try containedCanonicalURL(projectContainer, root: projectsRootURL)
        let workspace = projectContainer
            .appendingPathComponent("집필모드", isDirectory: true)
        let main = workspace.appendingPathComponent("메인", isDirectory: true)
        let backups = workspace.appendingPathComponent("백업", isDirectory: true)

        return StandardProjectPaths(
            projectContainerURL: projectContainer,
            workspaceRootURL: workspace,
            mainURL: main,
            manuscriptURL: main.appendingPathComponent("원고", isDirectory: true),
            charactersURL: main.appendingPathComponent("캐릭터", isDirectory: true),
            settingsCollectionURL: main.appendingPathComponent("설정집", isDirectory: true),
            notesURL: main.appendingPathComponent("메모장", isDirectory: true),
            flowURL: main.appendingPathComponent("흐름정리", isDirectory: true),
            foreshadowingURL: main.appendingPathComponent("복선", isDirectory: true),
            placesURL: main.appendingPathComponent("장소", isDirectory: true),
            trashURL: main.appendingPathComponent("휴지통", isDirectory: true),
            backupsURL: backups,
            automaticBackupsURL: backups.appendingPathComponent("자동저장", isDirectory: true),
            beforeRestoreBackupsURL: backups.appendingPathComponent("복원전", isDirectory: true),
            conflictBackupsURL: backups.appendingPathComponent("충돌", isDirectory: true),
            settingsFileURL: workspace.appendingPathComponent("설정.json", isDirectory: false)
        )
    }

    /// 새 작품의 고정 구조를 만들며 기존 정상 구조에는 아무 변경도 하지 않는다.
    func createStandardStructure(forProjectNamed projectName: String) throws -> StandardProjectPaths {
        try fileManager.createDirectory(
            at: projectsRootURL,
            withIntermediateDirectories: true
        )
        try policy.validateName(projectName)
        let existingProjects = try fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        try validateProjectNameForCreation(projectName, existingProjects: existingProjects)

        let paths = try standardPaths(forProjectNamed: projectName)
        try createDirectoriesAndSettings(paths: paths, projectName: projectName)
        return paths
    }

    /// 새 작품 거래가 사용하는 숨김 임시 컨테이너 안에 전체 구조를 만든다.
    func createStandardStructure(
        atProjectContainer projectContainer: URL,
        projectName: String
    ) throws -> StandardProjectPaths {
        try fileManager.createDirectory(
            at: projectsRootURL,
            withIntermediateDirectories: true
        )
        let paths = try standardPaths(
            atProjectContainer: projectContainer,
            projectName: projectName
        )
        try createDirectoriesAndSettings(paths: paths, projectName: projectName)
        return paths
    }

    /// 이름 변경 거래에서 설정 파일의 작품명도 원자적으로 맞춘다.
    func updateStoredProjectName(forProjectNamed projectName: String) throws {
        let settingsURL = try standardPaths(forProjectNamed: projectName).settingsFileURL
        try writeSettingsFile(at: settingsURL, projectName: projectName)
    }

    func updateStoredProjectName(
        atProjectContainer projectContainer: URL,
        projectName: String
    ) throws {
        let settingsURL = try standardPaths(
            atProjectContainer: projectContainer,
            projectName: projectName
        ).settingsFileURL
        try writeSettingsFile(at: settingsURL, projectName: projectName)
    }

    func storedProjectName(forProjectNamed projectName: String) throws -> String? {
        let paths = try standardPaths(forProjectNamed: projectName)
        return storedProjectName(from: paths.settingsFileURL)
    }

    private func createDirectoriesAndSettings(
        paths: StandardProjectPaths,
        projectName: String
    ) throws {
        _ = try containedCanonicalURL(paths.projectContainerURL, root: projectsRootURL)

        for directory in paths.requiredDirectories {
            let containmentRoot = directory == paths.projectContainerURL
                ? projectsRootURL
                : paths.projectContainerURL
            _ = try containedCanonicalURL(directory, root: containmentRoot)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        _ = try containedCanonicalURL(paths.settingsFileURL, root: paths.workspaceRootURL)
        try ensureSettingsFile(at: paths.settingsFileURL, projectName: projectName)
    }

    /// 검증된 상대 경로를 작품의 집필모드 루트 안 URL로 바꾼다.
    func validatedURL(
        for relativePath: RelativeDocumentPath,
        in workspaceRootURL: URL
    ) throws -> URL {
        try policy.validateRelativePath(relativePath)
        let candidate = relativePath.rawValue
            .split(separator: "/")
            .reduce(workspaceRootURL) { partial, component in
                partial.appendingPathComponent(String(component))
            }
        return try containedCanonicalURL(candidate, root: workspaceRootURL)
    }

    /// 외부 URL이 작품 안에 있는지 확인하고 안전한 상대 경로로 바꾼다.
    func validatedRelativePath(
        for externalURL: URL,
        in workspaceRootURL: URL
    ) throws -> RelativeDocumentPath {
        let root = canonicalURLAllowingMissingLeaf(workspaceRootURL)
        let candidate = try containedCanonicalURL(externalURL, root: workspaceRootURL)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw PathPolicyError.pathEscapesRoot(candidate.path)
        }
        let rawPath = String(candidate.path.dropFirst(rootPrefix.count))
        let relativePath = RelativeDocumentPath(rawValue: rawPath)
        try policy.validateRelativePath(relativePath)
        return relativePath
    }

    /// 같은 부모의 기존 이름과 비교해 안전한 새 하위 URL을 만든다.
    func validatedChildURL(
        named name: String,
        under parentURL: URL,
        in workspaceRootURL: URL
    ) throws -> URL {
        _ = try containedCanonicalURL(parentURL, root: workspaceRootURL)
        let existingNames: [String]
        if fileManager.fileExists(atPath: parentURL.path) {
            existingNames = try fileManager.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent)
        } else {
            existingNames = []
        }
        try policy.validateUniqueName(name, among: existingNames)
        let candidate = parentURL.appendingPathComponent(name)
        return try containedCanonicalURL(candidate, root: workspaceRootURL)
    }

    private func validateProjectNameForCreation(
        _ projectName: String,
        existingProjects: [URL]
    ) throws {
        let candidateKey = policy.collisionKey(for: projectName)
        for existingURL in existingProjects
        where policy.collisionKey(for: existingURL.lastPathComponent) == candidateKey {
            let settingsURL = existingURL
                .appendingPathComponent("집필모드", isDirectory: true)
                .appendingPathComponent("설정.json", isDirectory: false)
            if let storedName = storedProjectName(from: settingsURL) {
                guard hasExactUnicodeRepresentation(storedName, projectName) else {
                    throw PathPolicyError.nameCollision(storedName)
                }
                continue
            }
            guard hasExactUnicodeRepresentation(
                existingURL.lastPathComponent,
                projectName
            ) else {
                throw PathPolicyError.nameCollision(existingURL.lastPathComponent)
            }
        }
    }

    private func hasExactUnicodeRepresentation(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private func storedProjectName(from settingsURL: URL) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONSerialization.jsonObject(with: data),
              let object = decoded as? [String: Any]
        else {
            return nil
        }
        return object["project_name"] as? String
    }

    private func ensureSettingsFile(at url: URL, projectName: String) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw ProjectPathResolverError.settingsPathIsNotFile(url.path)
            }
            return
        }
        let settings = ["project_name": projectName]
        guard var data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys]
        ) else {
            throw ProjectPathResolverError.settingsFileCreationFailed(url.path)
        }
        data.append(0x0A)
        let created = fileManager.createFile(
            atPath: url.path,
            contents: data
        )
        guard created else {
            throw ProjectPathResolverError.settingsFileCreationFailed(url.path)
        }
    }

    private func writeSettingsFile(at url: URL, projectName: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ProjectPathResolverError.settingsPathIsNotFile(url.path)
        }
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONSerialization.jsonObject(with: data),
           let object = decoded as? [String: Any] {
            settings = object
        }
        settings["project_name"] = projectName
        guard var data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys]
        ) else {
            throw ProjectPathResolverError.settingsFileCreationFailed(url.path)
        }
        data.append(0x0A)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ProjectPathResolverError.settingsFileCreationFailed(url.path)
        }
    }

    private func containedCanonicalURL(_ candidateURL: URL, root rootURL: URL) throws -> URL {
        let root = canonicalURLAllowingMissingLeaf(rootURL)
        let candidate = canonicalURLAllowingMissingLeaf(candidateURL)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPrefix) else {
            throw PathPolicyError.pathEscapesRoot(candidate.path)
        }
        return candidate
    }

    private func canonicalURLAllowingMissingLeaf(_ url: URL) -> URL {
        var cursor = url.standardizedFileURL
        var missingComponents: [String] = []

        while !fileManager.fileExists(atPath: cursor.path), cursor.path != "/" {
            missingComponents.insert(cursor.lastPathComponent, at: 0)
            cursor.deleteLastPathComponent()
        }

        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }
}
