import Foundation

actor LocalBinderDirectoryScanner: BinderDirectoryScanning {
    private let pathResolver: ProjectPathResolver
    private let hasher: any ContentHashing
    private var scannedDirectories: [String] = []
    private var didPerformMainThreadIO = false

    init(
        pathResolver: ProjectPathResolver,
        hasher: any ContentHashing = SHA256ContentHasher()
    ) {
        self.pathResolver = pathResolver
        self.hasher = hasher
    }

    func children(
        in workspaceRootURL: URL,
        parentPath: RelativeDocumentPath
    ) async throws -> [BinderDiskEntry] {
        let parentURL = try pathResolver.validatedURL(
            for: parentPath,
            in: workspaceRootURL
        )
        let policy = pathResolver.policy
        let hasher = hasher
        let result = try await Task.detached(priority: .userInitiated) {
            try Self.scan(
                parentURL: parentURL,
                parentPath: parentPath,
                policy: policy,
                hasher: hasher
            )
        }.value
        scannedDirectories.append(parentPath.rawValue)
        didPerformMainThreadIO = didPerformMainThreadIO || result.performedOnMainThread
        return result.entries
    }

    func metrics() -> BinderScanMetrics {
        BinderScanMetrics(
            relativeDirectories: scannedDirectories,
            performedMainThreadIO: didPerformMainThreadIO
        )
    }

    func resetMetrics() {
        scannedDirectories = []
        didPerformMainThreadIO = false
    }

    private static func scan(
        parentURL: URL,
        parentPath: RelativeDocumentPath,
        policy: PathPolicy,
        hasher: any ContentHashing
    ) throws -> (entries: [BinderDiskEntry], performedOnMainThread: Bool) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            if parentPath.rawValue == "메인" {
                throw BinderRepositoryError.missingMainFolder
            }
            throw BinderRepositoryError.unreadableDirectory(parentPath.rawValue)
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: parentURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                    .fileSizeKey, .contentModificationDateKey, .isReadableKey
                ]
            )
        } catch {
            throw BinderRepositoryError.unreadableDirectory(parentPath.rawValue)
        }

        var collisionNames: [String: String] = [:]
        var entries: [BinderDiskEntry] = []
        for child in children {
            let name = child.lastPathComponent
            try policy.validateName(name)
            let collisionKey = policy.collisionKey(for: name)
            if let existing = collisionNames[collisionKey], existing != name {
                throw BinderRepositoryError.normalizedNameCollision(existing, name)
            }
            collisionNames[collisionKey] = name

            let relativePath = RelativeDocumentPath(
                rawValue: parentPath.rawValue + "/" + name
            )
            try policy.validateRelativePath(relativePath)
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .fileSizeKey, .contentModificationDateKey, .isReadableKey
            ])
            if values.isSymbolicLink == true {
                throw BinderRepositoryError.unsupportedSymbolicLink(relativePath.rawValue)
            }
            guard values.isReadable != false,
                  fileManager.isReadableFile(atPath: child.path)
            else {
                throw BinderRepositoryError.unreadableDirectory(relativePath.rawValue)
            }
            if values.isDirectory == true {
                entries.append(
                    BinderDiskEntry(
                        storedName: name,
                        relativePath: relativePath,
                        kind: .folder,
                        byteCount: 0,
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        contentHash: nil
                    )
                )
            } else if values.isRegularFile == true,
                      name.lowercased(with: Locale(identifier: "en_US_POSIX"))
                        .hasSuffix(".txt") {
                let data = try Data(contentsOf: child, options: .mappedIfSafe)
                guard String(data: data, encoding: .utf8) != nil else {
                    throw BinderRepositoryError.invalidUTF8(relativePath.rawValue)
                }
                entries.append(
                    BinderDiskEntry(
                        storedName: name,
                        relativePath: relativePath,
                        kind: .text,
                        byteCount: Int64(values.fileSize ?? data.count),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        contentHash: hasher.sha256(for: data)
                    )
                )
            }
        }
        entries.sort {
            $0.storedName.localizedStandardCompare($1.storedName) == .orderedAscending
        }
        return (entries, Thread.isMainThread)
    }
}
