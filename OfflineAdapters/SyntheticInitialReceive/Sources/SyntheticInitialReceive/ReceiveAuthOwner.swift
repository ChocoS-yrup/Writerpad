import Foundation

// Explicit mutation ownership. No client, subscription, storage or refresh is created here.
final class ReceiveAuthOwner: @unchecked Sendable {
    struct Change { fileprivate let owner: ObjectIdentifier; fileprivate let epoch: Int }
    private let lock = NSLock()
    private var epoch = 0, pending = false
    private var session: ReceiveCachedSession?
    func beginChange() throws -> Change {
        lock.lock(); defer { lock.unlock() }
        // Revoke before starting an async auth operation, even if it returns the same token.
        session = nil; pending = true
        epoch = try abAdd(epoch,1)
        return Change(owner:ObjectIdentifier(self),epoch:epoch)
    }
    func finish(_ change:Change,cachedSession:ReceiveCachedSession?) throws {
        lock.lock(); defer { lock.unlock() }
        try connectionNeed(change.owner == ObjectIdentifier(self) && change.epoch == epoch && pending,.changedSession)
        session = cachedSession; pending = false
    }
    // Called by an existing owner for an already obtained event; never subscribes to SDK events.
    func replaceCachedSession(_ value:ReceiveCachedSession?) throws {
        let change = try beginChange(); try finish(change,cachedSession:value)
    }
    func withChange(_ operation:() async throws -> ReceiveCachedSession?) async throws {
        let change = try beginChange()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            try Task.checkCancellation()
            try finish(change,cachedSession:value)
        } catch {
            // A superseded operation must never clear a newer successful session.
            try? finish(change,cachedSession:nil)
            throw error
        }
    }
    func invalidateCachedSession() throws {
        lock.lock();defer{lock.unlock()}
        guard pending || session != nil else {return}
        session=nil;pending=false;epoch=try abAdd(epoch,1)
    }
    private func current() -> ReceiveCachedSession? { lock.lock(); defer { lock.unlock() }; return pending ? nil : session }
    private func revision() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    var source: ReceiveSessionSource { ReceiveSessionSource(readCached:{ self.current() },ownerEpoch:{ self.revision() }) }
}

// Bridges the actual service's operation IDs to the cached owner's mutation tickets.
final class ReceiveAuthCallSiteObserver: ReceiveAuthObserving, @unchecked Sendable {
    let owner = ReceiveAuthOwner()
    private let lock = NSLock()
    private var operation: UUID?, change: ReceiveAuthOwner.Change?
    func begin(_ operationID:UUID) {
        lock.lock(); defer { lock.unlock() }
        operation = operationID; change = try? owner.beginChange()
    }
    func accept(_ operationID:UUID,account:UUID,accessToken:String,expiresAt:Date?) {
        lock.lock(); defer { lock.unlock() }
        guard operation == operationID,let change else { return }
        self.change = nil; operation = nil
        guard let expiresAt else { try? owner.finish(change,cachedSession:nil); return }
        let ms = (expiresAt.timeIntervalSince1970*1000).rounded(.down)
        guard ms.isFinite && ms > 0 && ms <= 9_007_199_254_740_991 else { try? owner.finish(change,cachedSession:nil); return }
        try? owner.finish(change,cachedSession:.init(account:account,accessToken:accessToken,expiresUTCMS:Int(ms)))
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        operation = nil; change = nil; try? owner.replaceCachedSession(nil)
    }
}

// Memory-only input. No Codable/loggable credential object or automatic auth operation.
struct ReceiveLoginInput:CustomStringConvertible,CustomDebugStringConvertible,CustomReflectable {
    let email:String, password:String
    var description:String {"ReceiveLoginInput(redacted)"}
    var debugDescription:String {description}
    var customMirror:Mirror {Mirror(self,children:EmptyCollection<(label:String?,value:Any)>())}
}

// Native UI orchestration only. An explicitly supplied adapter performs authentication;
// the default has no transport. Cancellation also rejects adapters that return late.
@MainActor
final class ReceiveDedicatedAuthentication {
    enum State:Equatable {case unavailable, signedOut, authenticating, signedIn, failed}
    typealias Authenticate = (ReceiveLoginInput) async throws -> ReceiveCachedSession
    let owner=ReceiveAuthOwner()
    let account:UUID
    let destination:String?
    private let clock:ABRuntimeClock, authenticate:Authenticate?
    private var task:Task<Void,Never>?, attempt:UUID?
    private(set) var state:State
    var onStateChange:((State)->Void)?
    var onInvalidate:(()->Void)?
    var isConfigured:Bool {authenticate != nil}
    init(account:UUID,clock:ABRuntimeClock=ABRuntimeClock(),destination:String?=nil,authenticate:Authenticate?=nil) {
        self.account=account;self.clock=clock;self.destination=destination;self.authenticate=authenticate
        state=authenticate == nil ? .unavailable : .signedOut
    }
    private func publish(_ value:State) {state=value;onStateChange?(value)}
    func signIn(_ input:ReceiveLoginInput) throws {
        guard let authenticate else {throw ReceiveConnectionError.closed}
        try connectionNeed(state != .authenticating,.busy)
        // Revoke old session and approval before input validation or any adapter invocation.
        let change=try owner.beginChange();onInvalidate?()
        guard !input.email.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              input.email.utf8.count<=320,!input.password.isEmpty,input.password.utf8.count<=4096 else {
            try owner.finish(change,cachedSession:nil);publish(.failed);throw ReceiveConnectionError.invalidCredential
        }
        let id=UUID();attempt=id;publish(.authenticating)
        task=Task { [weak self] in
            do {
                let session=try await authenticate(input)
                try Task.checkCancellation()
                guard let self,self.attempt==id else {return}
                // Validate through the same token/expiry/account boundary before publishing.
                let validator=ReceiveAuthOwner();try validator.replaceCachedSession(session)
                _ = try validator.source.capture(account:self.account,clock:self.clock)
                try self.owner.finish(change,cachedSession:session)
                self.attempt=nil;self.task=nil;self.publish(.signedIn)
            } catch {
                guard let self,self.attempt==id else {return}
                try? self.owner.finish(change,cachedSession:nil)
                self.attempt=nil;self.task=nil;self.publish(.failed)
            }
        }
    }
    func cancel() {
        attempt=nil;task?.cancel();task=nil
        try? owner.invalidateCachedSession()
        onInvalidate?();publish(isConfigured ? .signedOut:.unavailable)
    }
}
