import Foundation
import Darwin

/// Resolve only the OS-supplied application home, before constructing any storage paths.
/// The argument exists for disposable host fixtures; never pass a payload or child path.
enum BoundarySystemHome {
    static func resolve(systemHome: String = NSHomeDirectory()) throws -> URL {
        guard systemHome.hasPrefix("/") else { throw StorageDiagnostics.reason(ReceiveError.path, .nonAbsolutePath) }
        guard !systemHome.contains("\0") else { throw StorageDiagnostics.reason(ReceiveError.path, .nulByte) }
        guard let pointer = realpath(systemHome, nil) else {
            throw StorageDiagnostics.posix(ReceiveError.io, .realpath, errno)
        }
        defer { free(pointer) }
        // Foundation's resolvingSymlinksInPath can reintroduce /var or /tmp aliases.
        // Preserve the POSIX result; SafeFiles.checked still rejects links below home.
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }
}

enum ProtectedBoundaryError: String, Error {
    case inactive, protectedDataUnavailable, leaseRevoked, wrongContainer, incompleteContainer, protection
}

enum CompleteFileProtection {
    static func require(_ attribute: Any?) throws {
        // Foundation may expose an Objective-C attribute as its typed wrapper or raw string.
        let raw = (attribute as? FileProtectionType)?.rawValue ?? (attribute as? String)
        guard raw == FileProtectionType.complete.rawValue else { throw ProtectedBoundaryError.protection }
    }
}

/// Notifications revoke in-flight leases. Becoming active/unlocked never revives an old lease.
final class BoundaryLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false, available = false
    private var generation: UInt64 = 0
    func update(active: Bool, protectedDataAvailable: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.active = active; available = protectedDataAvailable
        generation &+= 1
    }
    func begin() throws -> BoundaryLease {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw ProtectedBoundaryError.inactive }
        guard available else { throw ProtectedBoundaryError.protectedDataUnavailable }
        return BoundaryLease(lifecycle: self, generation: generation)
    }
    fileprivate func check(_ expected: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { throw ProtectedBoundaryError.leaseRevoked }
        guard active else { throw ProtectedBoundaryError.inactive }
        guard available else { throw ProtectedBoundaryError.protectedDataUnavailable }
    }
}
struct BoundaryLease: Sendable {
    let lifecycle: BoundaryLifecycle
    let generation: UInt64
    func check() throws { try lifecycle.check(generation) }
}

/// Its production initializer is only called by the iOS controller with NSHomeDirectory().
/// Test code uses a fresh disposable fake home and a protection double, never another app home.
final class ProtectedBoundaryContainer {
    static let bundleID = "com.chocos.writerpad.receiveboundary"
    static let relativeWorkspace = "Library/Application Support/WriterPadReceiveBoundary-v1"
    struct Seal: Codable, Equatable { let version: Int; let bundleID: String; let workspace: String; let kind: String }
    let home: URL
    let workspace: URL
    private let access: PhysicalStorageAccess
    var journalAccess: PhysicalStorageAccess { access }
    private let seal: Seal

    init(home: URL, declaredBundle: String, access: PhysicalStorageAccess) throws {
        guard declaredBundle == Self.bundleID else { throw LocalBoundaryError.bundle }
        try SafeFiles.checked(home)
        guard let info = try SafeFiles.attributes(home), info.st_mode & S_IFMT == S_IFDIR else { throw ProtectedBoundaryError.wrongContainer }
        self.home = home; self.access = access
        workspace = home.appendingPathComponent(Self.relativeWorkspace, isDirectory: true)
        seal = Seal(version: 2, bundleID: Self.bundleID, workspace: Self.relativeWorkspace, kind: "dedicated-synthetic-container-v1")
    }

    private func createDirectory(_ url: URL) throws {
        try access.check(); try SafeFiles.checked(url)
        guard mkdir(url.path,0o700) == 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .mkdir, errno) }
        try access.created(url); try access.verify(url); try access.check()
    }

    func prepare() throws {
        try access.check(); try SafeFiles.checked(workspace)
        if try SafeFiles.attributes(workspace) != nil {
            let existing = try checkedSeal(workspace)
            if existing != seal {
                guard existing.version == 1, existing.bundleID == seal.bundleID,
                      existing.kind == seal.kind, Self.validLegacyWorkspace(existing.workspace) else {
                    throw ProtectedBoundaryError.wrongContainer
                }
                // Validate every existing descendant before changing the seal. Never follow the
                // legacy absolute path; it is syntax evidence only, not a filesystem input.
                try verifyMigrationTree(workspace)
                try writeSeal()
            }
            try validate(workspace); return
        }
        let library = home.appendingPathComponent("Library",isDirectory:true)
        let support = library.appendingPathComponent("Application Support",isDirectory:true)
        for parent in [library,support] {
            if try SafeFiles.attributes(parent) == nil { try createDirectory(parent) }
            guard let attr = try SafeFiles.attributes(parent), attr.st_mode & S_IFMT == S_IFDIR else { throw ProtectedBoundaryError.wrongContainer }
        }
        try createDirectory(workspace)
        try writeSeal()
        let fd = open(support.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .openDirectory, errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw StorageDiagnostics.posix(ReceiveError.io, .fsync, errno) }
        try validate(workspace)
    }

    static func validLegacyWorkspace(_ path: String) -> Bool {
        let suffix = "/" + relativeWorkspace
        for prefix in ["/private/var/mobile/Containers/Data/Application/", "/var/mobile/Containers/Data/Application/"] {
            guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { continue }
            let id = String(path.dropFirst(prefix.count).dropLast(suffix.count))
            if let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id.lowercased() { return true }
        }
        return false
    }
    private func writeSeal() throws {
        try SafeFiles.write(try canonical(seal), to: workspace.appendingPathComponent("container.json"), prepareFile: { url in
            try self.access.check(); try self.access.created(url); try self.access.verify(url)
        }, checkpoint: { _ in try self.access.check() })
    }
    private func verifyMigrationTree(_ directory: URL) throws {
        try access.check(); try SafeFiles.checked(directory); try access.verify(directory)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let child = directory.appendingPathComponent(name)
            try access.check(); try SafeFiles.checked(child); try access.verify(child)
            guard let info = try SafeFiles.attributes(child) else { throw ProtectedBoundaryError.incompleteContainer }
            if info.st_mode & S_IFMT == S_IFDIR { try verifyMigrationTree(child) }
            else if info.st_mode & S_IFMT != S_IFREG { throw ProtectedBoundaryError.incompleteContainer }
        }
    }
    func validate(_ candidate: URL) throws {
        guard try checkedSeal(candidate) == seal else { throw ProtectedBoundaryError.wrongContainer }
        try access.check()
    }
    private func checkedSeal(_ candidate: URL) throws -> Seal {
        try access.check()
        guard candidate.path == workspace.path else { throw ProtectedBoundaryError.wrongContainer }
        guard workspace.path == home.appendingPathComponent(Self.relativeWorkspace).path else { throw ProtectedBoundaryError.wrongContainer }
        try SafeFiles.checked(home); try SafeFiles.checked(workspace); try access.verify(workspace)
        guard let info = try SafeFiles.attributes(workspace), info.st_mode & S_IFMT == S_IFDIR else { throw ProtectedBoundaryError.wrongContainer }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
        guard names.contains("container.json"), names.isSubset(of:["container.json","physical-boundary","physical-boundary.lock","execution-journal"]) else { throw ProtectedBoundaryError.incompleteContainer }
        for (name, expectedType) in [("physical-boundary", mode_t(S_IFDIR)), ("physical-boundary.lock", mode_t(S_IFREG))] {
            let child = workspace.appendingPathComponent(name)
            if let info = try SafeFiles.attributes(child) {
                try SafeFiles.checked(child); try access.verify(child)
                guard info.st_mode & S_IFMT == expectedType else { throw ProtectedBoundaryError.incompleteContainer }
            }
        }
        let journal = workspace.appendingPathComponent("execution-journal")
        if let info = try SafeFiles.attributes(journal) {
            try SafeFiles.checked(journal)
            guard info.st_mode & S_IFMT == S_IFDIR else { throw ProtectedBoundaryError.incompleteContainer }
            try access.verify(journal)
        }
        let file = workspace.appendingPathComponent("container.json")
        try access.verify(file)
        let result = try decodeExact(Seal.self,SafeFiles.read(file,limit:4096))
        try access.check(); return result
    }

    func session(input: SyntheticInput) throws -> LocalBoundarySession {
        try validate(workspace)
        let context = LocalBoundaryContext(declaredBundle: Self.bundleID,syntheticLocalIdentity: input.manifest.localIdentity,workspace: workspace)
        return try LocalBoundary.prepareProtected(context: context,input:.synthetic(input),container:self,access:access)
    }
}

enum BoundaryAppFixture {
    /// Stable synthetic labels permit explicit local resume, never issue a real project UUID.
    static func make() throws -> SyntheticInput {
        func id(_ prefix: String,_ n: Int) -> String { prefix + String(format:"ee260914-0000-4000-8000-%012d",n) }
        let root = id("node-",501), doc = id("node-",502)
        let bytes = Data("iOS synthetic boundary\n".utf8)
        let body = FixtureManifest.Body(node:doc,file:"bodies/\(doc).txt",bytes:bytes.count,sha256:byteHash(bytes))
        let manifest = FixtureManifest(version:1,kind:"synthetic-initial-receive-v1",fixtureID:id("fixture-",503),
            localIdentity:id("local-",504),sourceIdentity:id("source-",505),root:root,expectedNodes:[root,doc],
            expectedDocuments:[doc],expectedOrders:[root],nodes:[
                .init(id:root,kind:"folder",parent:nil,name:"Synthetic",path:"Synthetic",revision:1),
                .init(id:doc,kind:"document",parent:root,name:"example.txt",path:"Synthetic/example.txt",revision:1)],
            orders:[.init(parent:root,children:[doc],revision:1)],bodies:[body])
        return try SyntheticInput(files:["manifest.json":canonical(manifest),body.file:bytes])
    }
}
