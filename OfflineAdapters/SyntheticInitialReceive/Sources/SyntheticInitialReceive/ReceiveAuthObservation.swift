import Foundation

// A passive, synchronous injection seam. Implementations must not perform Auth or storage I/O.
protocol ReceiveAuthObserving: Sendable {
    func begin(_ operationID: UUID)
    func accept(_ operationID: UUID, account: UUID, accessToken: String, expiresAt: Date?)
    func invalidate()
}
