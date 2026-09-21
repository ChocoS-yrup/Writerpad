import Foundation

/// Fixed vocabulary only. Never stores URLs, raw NSError descriptions/userInfo, or payloads.
enum StorageDiagnosticStage: String, Codable, CaseIterable {
    case entry, container, prepare, input, apply, snapshot, publish
    case protectionSet, protectionRead
}
enum StorageDiagnosticOperation: String, Codable {
    case realpath, lstat, openRead, openPending, openLock, mkdir, rename, openDirectory, fsync, fstat, flock
}
/// Fixed, non-sensitive reasons for rejecting a storage URL before any write.
/// These values deliberately do not contain the rejected path or filesystem metadata.
enum StorageDiagnosticReason: String, Codable {
    case nonFileURL
    case nonAbsolutePath
    case nulByte
    case dotComponent
    case emptyComponent
    case invalidAncestorType
}
public struct StorageFailureDiagnostic: Codable, Equatable, Sendable {
    public let phase: String
    public let stage: String
    public let category: String
    public let code: String
    public let operation: String?
    public let posixCode: Int32?
    public let reason: String?
    public var displayText: String {
        var text = "진단 · \(phase).\(stage) / \(category):\(code)"
        if let operation, let posixCode { text += " / \(operation):\(posixCode)" }
        if let reason { text += " / reason:\(reason)" }
        return text
    }
}

/// First failure is sticky in memory. Capturing diagnostics never writes to the failed store.
final class StorageFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var first: StorageFailureDiagnostic?
    var failure: StorageFailureDiagnostic? { lock.lock(); defer { lock.unlock() }; return first }
    func capture(_ error: Error, stage: StorageDiagnosticStage,
                 operation: StorageDiagnosticOperation? = nil, posix: Int32? = nil,
                 phase: StorageDiagnosticStage? = nil, reason: StorageDiagnosticReason? = nil) {
        let category: String, code: String
        switch error {
        case let value as ReceiveError: category = "receive"; code = value.rawValue
        case let value as LocalBoundaryError: category = "boundary"; code = value.rawValue
        case let value as PhysicalStorageError: category = "physical"; code = value.rawValue
        case let value as ProtectedBoundaryError: category = "protection"; code = value.rawValue
        case is CancellationError: category = "task"; code = "cancelled"
        default:
            let value = error as NSError
            // An arbitrary domain can itself contain secrets. Allow only Foundation domains.
            if value.domain == NSCocoaErrorDomain { category = "cocoa"; code = String(value.code) }
            else if value.domain == NSPOSIXErrorDomain { category = "posix"; code = String(value.code) }
            else { category = "unknown"; code = "unclassified" }
        }
        let diagnostic = StorageFailureDiagnostic(phase:(phase ?? stage).rawValue,stage:stage.rawValue,category:category,code:code,
            operation:operation?.rawValue,posixCode:posix,reason:reason?.rawValue)
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = diagnostic }
    }
}

enum StorageDiagnostics {
    @TaskLocal static var recorder: StorageFailureRecorder?
    @TaskLocal static var stage: StorageDiagnosticStage = .entry
    @TaskLocal static var phase: StorageDiagnosticStage = .entry

    static func at<T>(_ value: StorageDiagnosticStage, _ operation: () throws -> T) rethrows -> T {
        let enclosing = (value == .protectionSet || value == .protectionRead) ? phase : value
        return try $phase.withValue(enclosing) {
            try $stage.withValue(value) {
                do { return try operation() }
                catch { recorder?.capture(error,stage:value,phase:enclosing); throw error }
            }
        }
    }

    /// Capture errno immediately at the failed syscall, but return the exact legacy error.
    /// Callers outside a diagnostic scope retain their original behavior and error identity.
    static func posix<E: Error>(_ error: E, _ operation: StorageDiagnosticOperation, _ number: Int32) -> E {
        recorder?.capture(error,stage:stage,operation:operation,posix:number,phase:phase)
        return error
    }

    /// Record a fixed path-validation reason while returning the exact legacy error.
    static func reason<E: Error>(_ error: E, _ value: StorageDiagnosticReason) -> E {
        recorder?.capture(error,stage:stage,phase:phase,reason:value)
        return error
    }
}

/// Shared by the actual iOS button and host protection doubles. No transport or real input.
enum SyntheticStorageDiagnosticWork {
    static func run(home: URL, bundle: String, access: PhysicalStorageAccess) throws -> LocalBoundaryReceipt {
        let container = try StorageDiagnostics.at(.container) {
            try ProtectedBoundaryContainer(home:home,declaredBundle:bundle,access:access)
        }
        try StorageDiagnostics.at(.prepare) { try container.prepare() }
        let session = try StorageDiagnostics.at(.input) { try container.session(input:BoundaryAppFixture.make()) }
        let receipt = try StorageDiagnostics.at(.apply) { try session.apply() }
        _ = try StorageDiagnostics.at(.snapshot) { try session.snapshot() }
        try StorageDiagnostics.at(.publish) { try access.check() }
        return receipt
    }
}
