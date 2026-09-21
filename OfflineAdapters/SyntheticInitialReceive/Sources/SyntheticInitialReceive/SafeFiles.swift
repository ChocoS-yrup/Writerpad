import Foundation
import Darwin

enum SafeFiles {
    static let fm = FileManager.default

    static func temporaryPath() throws -> String {
        guard let pointer = realpath(fm.temporaryDirectory.path, nil) else { throw ReceiveError.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func attributes(_ url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            let number = errno
            if number == ENOENT { return nil }
            throw StorageDiagnostics.posix(ReceiveError.io, .lstat, number)
        }
        return info
    }

    static func checked(_ url: URL) throws {
        // Foundation's standardizedFileURL rewrites /private/var back to the /var symlink.
        // Inspect components and lstat ancestors instead of using that lossy alias conversion.
        guard url.isFileURL else { throw StorageDiagnostics.reason(ReceiveError.path, .nonFileURL) }
        guard url.path.hasPrefix("/") else { throw StorageDiagnostics.reason(ReceiveError.path, .nonAbsolutePath) }
        guard !url.path.contains("\0") else { throw StorageDiagnostics.reason(ReceiveError.path, .nulByte) }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw StorageDiagnostics.reason(ReceiveError.path, .dotComponent)
        }
        guard !components.contains(where: { $0.isEmpty }) else {
            throw StorageDiagnostics.reason(ReceiveError.path, .emptyComponent)
        }
        var current = url
        while current.path != "/" {
            if let info = try attributes(current) {
                let type = info.st_mode & S_IFMT
                guard type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1) else {
                    throw StorageDiagnostics.reason(ReceiveError.path, .invalidAncestorType)
                }
            }
            current.deleteLastPathComponent()
        }
    }

    static func read(_ url: URL, limit: Int = 20 * 1024 * 1024) throws -> Data {
        try checked(url)
        guard let info = try attributes(url), info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw ReceiveError.path }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .openRead, errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        try require(data.count <= limit, .path)
        return data
    }

    static func parents(of paths: Set<String>) -> Set<String> {
        var result = Set<String>()
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 { components.removeLast(); result.insert(components.joined(separator: "/")) }
        }
        return result
    }

    static func inventory(_ root: URL) throws -> (files: Set<String>, directories: Set<String>) {
        try checked(root)
        guard let info = try attributes(root), info.st_mode & S_IFMT == S_IFDIR else { throw ReceiveError.path }
        var files = Set<String>(), directories = Set<String>()
        func visit(_ directory: URL, _ prefix: String, _ depth: Int) throws {
            try require(depth <= 70, .path)
            let names = try fm.contentsOfDirectory(atPath: directory.path)
            try require(names.count <= 300 && files.count + directories.count <= 700, .path)
            for name in names {
                try validateComponent(name)
                let path = prefix + name, url = directory.appendingPathComponent(name)
                try checked(url)
                guard let attr = try attributes(url) else { throw ReceiveError.io }
                if attr.st_mode & S_IFMT == S_IFDIR {
                    directories.insert(path)
                    try visit(url, path + "/", depth + 1)
                } else { files.insert(path) }
            }
        }
        try visit(root, "", 0)
        return (files, directories)
    }

    static func mkdir(_ url: URL) throws {
        try checked(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try checked(url)
    }

    // Pending files are deliberately not adopted after a crash. Their presence blocks recovery.
    static func write(_ data: Data, to url: URL, prepareFile: (URL) throws -> Void = { _ in }, checkpoint: (String) throws -> Void) throws {
        try mkdir(url.deletingLastPathComponent())
        try checked(url)
        let pending = url.appendingPathExtension("pending")
        try checked(pending)
        let fd = open(pending.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StorageDiagnostics.posix(ReceiveError.existingData, .openPending, errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Protected iOS route sets and verifies the class before the first payload byte.
        try prepareFile(pending)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try checkpoint("pending:" + url.lastPathComponent)
        try checked(url)
        guard rename(pending.path, url.path) == 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .rename, errno) }
        // fsync the parent for local host process recovery; this is not a power-loss guarantee.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .openDirectory, errno) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .fsync, errno) }
    }
}
