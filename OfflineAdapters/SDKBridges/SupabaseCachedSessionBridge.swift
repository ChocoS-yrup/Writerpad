import Foundation
import Supabase

// Typechecked against the retained 2.46.0 SDK. Never constructs a client, subscribes,
// restores, refreshes, signs in/out, or reads storage at factory creation time.
// The existing auth owner must supply its mutation epoch before live binding is possible.
func makeSupabaseCachedReceiveSessionSource(client:SupabaseClient,ownerEpoch:@escaping () throws -> Int) -> ReceiveSessionSource {
    ReceiveSessionSource(readCached:{
        guard let session = client.auth.currentSession else { return nil }
        let milliseconds = (session.expiresAt*1000).rounded(.down)
        try connectionNeed(milliseconds.isFinite && milliseconds > 0 && milliseconds <= 9_007_199_254_740_991,.expired)
        return .init(account:session.user.id,accessToken:session.accessToken,expiresUTCMS:Int(milliseconds))
    },ownerEpoch:ownerEpoch)
}

// An explicit owner hook: the caller supplies its already-authorized auth operation.
// This function neither creates an operation nor reads/subscribes to the SDK on its own.
func withReceiveSupabaseAuthChange(owner:ReceiveAuthOwner,operation:() async throws -> Session?) async throws {
    try await owner.withChange {
        guard let session = try await operation() else { return nil }
        let milliseconds = (session.expiresAt*1000).rounded(.down)
        try connectionNeed(milliseconds.isFinite && milliseconds > 0 && milliseconds <= 9_007_199_254_740_991,.expired)
        return .init(account:session.user.id,accessToken:session.accessToken,expiresUTCMS:Int(milliseconds))
    }
}
