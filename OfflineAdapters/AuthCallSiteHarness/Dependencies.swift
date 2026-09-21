// Host-only environment doubles. No SDK, Keychain, diagnostics persistence or actual policy access.
import Foundation
struct StoredSessionTokens:Equatable,Sendable { let accessToken:String,refreshToken:String;let expiresAt:Date? }
protocol SessionTokenStoring:Sendable { func load() async throws -> StoredSessionTokens?;func save(_ tokens:StoredSessionTokens) async throws;func delete() async throws }
final class SyncV2ContractEpoch:@unchecked Sendable { private let lock=NSLock();private var epoch=0;func advance(){lock.lock();epoch+=1;lock.unlock()} }
enum GeneralValidationFailure:Error { case denied }
struct ReceiveValidationPolicy {
    struct Ticket:Equatable,Sendable { let id:Int }
    @TaskLocal static var operation:Ticket?
    static var current=Self()
    var enabled=false
    var generation=0
    var allowSending=false
    var sendingAllowed:Bool { allowSending } // No automatic refresh/retry jobs in this harness.
    func authorization() throws -> Ticket { .init(id:generation) }
    func requireRead(account:UUID) throws {}
    func withVerifiedAccount<T>(_ account:UUID,ticket:Ticket?,_ work:() throws -> T) throws -> T { guard ticket == (try authorization()) else { throw GeneralValidationFailure.denied };return try work() }
    func invalidate() { Self.current.generation += 1 }
}
enum SyncV2RecoveryDiagnostics {
    enum Stage { case authentication };enum Event { case available,unavailable,started,retryScheduled }
    static func record(stage:Stage,event:Event,operationID:UUID?,retryAt:Date? = nil) {}
}
enum SyncV2Diagnostics { static func supersededAuthOperation(operationID:UUID,activeOperationID:UUID?) {} }
