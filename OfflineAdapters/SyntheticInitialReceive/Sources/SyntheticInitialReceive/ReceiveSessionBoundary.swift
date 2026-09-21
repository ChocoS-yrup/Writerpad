import Foundation

enum ReceiveConnectionError: String, Error {
    case closed, missingSession, changedSession, expired, clock, invalidTarget, invalidCredential, invalidRequest
    case busy, reused, quota, reservation, cancelled, timeout, redirect, authentication, status, response, tooLarge, transport, unverified
}
func connectionNeed(_ value: @autoclosure () throws -> Bool,_ error: ReceiveConnectionError) throws { if try !value() { throw error } }

// Intentionally non-Codable, non-reflecting, and redacted in debugger descriptions.
struct ReceiveCachedSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let account: UUID, expiresUTCMS: Int
    fileprivate let token: String
    init(account: UUID,accessToken: String,expiresUTCMS: Int) { self.account = account;token = accessToken;self.expiresUTCMS = expiresUTCMS }
    var description: String { "ReceiveCachedSession(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self,children:EmptyCollection<(label:String?,value:Any)>()) }
}

// The owner must supply a monotonic epoch for every auth change, including same-token ABA.
// Construction is passive: neither callback is invoked until an explicitly authorized request.
final class ReceiveSessionSource {
    private let readCached: () throws -> ReceiveCachedSession?
    private let ownerEpoch: () throws -> Int
    init(readCached: @escaping () throws -> ReceiveCachedSession?,ownerEpoch: @escaping () throws -> Int) {
        self.readCached = readCached;self.ownerEpoch = ownerEpoch
    }
    fileprivate func snapshot() throws -> (ReceiveCachedSession,Int) {
        do {
            let before = try ownerEpoch();try connectionNeed(before >= 0,.changedSession)
            guard let session = try readCached() else { throw ReceiveConnectionError.missingSession }
            let after = try ownerEpoch();try connectionNeed(before == after,.changedSession)
            try connectionNeed(!session.token.isEmpty && session.token.utf8.count <= 16384 && session.token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) },.invalidCredential)
            try connectionNeed(session.expiresUTCMS > 0 && session.expiresUTCMS <= 9_007_199_254_740_991,.expired)
            return (session,before)
        } catch let error as ReceiveConnectionError { throw error }
        catch { throw ReceiveConnectionError.missingSession }
    }
    func capture(account: UUID,clock: ABRuntimeClock) throws -> ReceiveSessionLease {
        let (session,epoch) = try snapshot()
        try connectionNeed(session.account == account,.changedSession)
        let lease = ReceiveSessionLease(source:self,session:session,epoch:epoch,clock:clock)
        try lease.check();return lease
    }
    // Called by explicit preparation and again at confirmation. Reads only the supplied owner,
    // never an SDK or Keychain; session fields come from the same owner as execution.
    func approvalRuntime(local:UUID,bundle:String,boot:String,clock:ABRuntimeClock) throws -> ReceiveExecutionCandidate.RuntimeSnapshot {
        let (session,epoch)=try snapshot(),now=try clock.sample()
        try connectionNeed(now.utcMS<session.expiresUTCMS,.expired)
        return .init(account:session.account,localProjectID:local,bundleID:bundle,bootID:boot,sessionEpoch:epoch,sessionExpiresUTCMS:session.expiresUTCMS)
    }
}
final class ReceiveSessionLease: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let source: ReceiveSessionSource, session: ReceiveCachedSession, epoch: Int, clock: ABRuntimeClock
    private let lock = NSRecursiveLock()
    private var lastUTC: Int?, lastMono: Int?, failed: ReceiveConnectionError?
    fileprivate init(source:ReceiveSessionSource,session:ReceiveCachedSession,epoch:Int,clock:ABRuntimeClock) { self.source = source;self.session = session;self.epoch = epoch;self.clock = clock }
    func check() throws {
        lock.lock();defer { lock.unlock() }
        if let failed { throw failed }
        do {
            let now = try clock.sample(), (current,revision) = try source.snapshot()
            try connectionNeed(revision == epoch && current.account == session.account && current.token == session.token && current.expiresUTCMS == session.expiresUTCMS,.changedSession)
            if let lastUTC, let lastMono { try connectionNeed(now.utcMS >= lastUTC && now.monoMS >= lastMono,.clock) }
            try connectionNeed(now.utcMS < session.expiresUTCMS,.expired)
            lastUTC = now.utcMS;lastMono = now.monoMS
        } catch { let safe = (error as? ReceiveConnectionError) ?? .clock;failed = safe;throw safe }
    }
    // Compare non-secret context metadata with the captured owner lease; never export credentials.
    func requireContext(account:UUID,epoch:Int,expiresUTCMS:Int) throws {
        try check()
        try connectionNeed(session.account == account && self.epoch == epoch && session.expiresUTCMS == expiresUTCMS,.changedSession)
    }
    func authorization() throws -> String { try check();return "Bearer "+session.token }
    var description: String { "ReceiveSessionLease(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self,children:EmptyCollection<(label:String?,value:Any)>()) }
}
