import CryptoKit
import Foundation

/// An additional restriction, never an authentication or transmission grant.
/// The review build has no approved documents or RPC bytes. Existing receive/send
/// policy, account and lifecycle checks must still succeed independently.
struct GeneralSyncValidationScope: Sendable {
    struct Selection: Sendable {
        let local: ProjectID
        let server: UUID
        let documents: Set<UUID>
        let reviewedRPCs: Set<String>
        var requiresJournal: Bool = false
    }
    let restricted: Bool
    let selection: Selection?
    @TaskLocal static var override: GeneralSyncValidationScope?
    static var current: Self { override ?? built }
    static let built: Self = {
#if DEBUG && (WRITERPAD_GENERAL_VALIDATION || WRITERPAD_NORMAL_EDITOR || WRITERPAD_INTEGRATED_EDITOR)
        Self(restricted: true, selection: .init(
            local: ProjectID(rawValue: UUID(uuidString: "a9452cd1-4474-40b5-80ca-fbb7871e98e5")!),
            server: UUID(uuidString: "d8f50b5f-ae0e-42f8-9296-5d5885a5b304")!,
            documents: [], reviewedRPCs: [], requiresJournal: true))
#else
        Self(restricted: false, selection: nil)
#endif
    }()
    var dispatcherScope: SyncV2Dispatcher.ProjectScope {
        restricted ? .only(Set(selection.map { [$0.local] } ?? [])) : .all
    }
    func require(local: ProjectID, server: UUID? = nil) throws {
        guard restricted else { return }
        guard let selection, selection.local == local,
              server == nil || server == selection.server else { throw ReceiveValidationPolicy.Denied.locked }
    }
    func require(server: UUID) throws {
        guard restricted else { return }
        guard selection?.server == server else { throw ReceiveValidationPolicy.Denied.locked }
    }
    func require(document: UUID) throws {
        guard restricted else { return }
        guard selection?.documents.contains(document) == true else { throw ReceiveValidationPolicy.Denied.locked }
    }
    /// Current Realtime implementation subscribes to the entire publication and
    /// filters locally. It cannot be used for a restricted validation session.
    func requireRealtime() throws {
        if restricted { throw ReceiveValidationPolicy.Denied.locked }
    }
    static func fingerprint(_ request: URLRequest) -> String {
        var data = Data(((request.httpMethod ?? "GET") + "\n" + (request.url?.absoluteString ?? "") + "\n").utf8)
        data.append(request.httpBody ?? Data())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func authorize(_ request: URLRequest) throws {
        guard restricted else { return }
        if let integrated = IntegratedEditorAuthority.current { try integrated.authorize(request); return }
        if let normal = NormalEditorAuthority.current { try normal.authorize(request); return }
        guard let selection, let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil,
              parts.password == nil, parts.fragment == nil,
              "https://\(parts.host ?? "")" == ReceiveValidationPolicy.Configuration.staging,
              request.httpBodyStream == nil else { throw ReceiveValidationPolicy.Denied.locked }
        let method = request.httpMethod ?? "GET", items = parts.queryItems ?? []
        if url.path == "/auth/v1/token", method == "POST", items.count == 1,
           items[0].name == "grant_type", ["password", "refresh_token"].contains(items[0].value ?? "") { return }
        if url.path == "/auth/v1/user", method == "GET", items.isEmpty { return }
        if url.path.hasPrefix("/rest/v1/rpc/"), method == "POST", items.isEmpty,
           let capability = GeneralValidationCapability.current, try capability.authorizeRPC(request) { return }
        if url.path.hasPrefix("/rest/v1/rpc/"), method == "POST", items.isEmpty,
           selection.reviewedRPCs.contains(Self.fingerprint(request)) { return }
        guard method == "GET", request.httpBody == nil,
              ["projects", "documents", "folders", "tree_orders", "sync_batches"].contains(url.lastPathComponent),
              url.path == "/rest/v1/" + url.lastPathComponent,
              items.filter({ $0.name == "project_id" }).map(\.value) == ["eq." + selection.server.uuidString.lowercased()],
              Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["select", "project_id", "document_id", "batch_id", "is_deleted", "trashed_at", "order", "limit", "offset"].contains($0.name) }),
              let columns = items.first(where: { $0.name == "select" })?.value,
              !columns.isEmpty, columns.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ",") })
        else { throw ReceiveValidationPolicy.Denied.locked }
    }
}
