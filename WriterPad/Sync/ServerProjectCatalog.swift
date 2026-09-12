import Foundation
import Supabase

struct ServerCatalogProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    enum CodingKeys: String, CodingKey { case id = "project_id", name }
}

struct ServerCatalogScope: Equatable, Sendable {
    let accountID: UUID
    let endpoint: String
    let authenticationEpoch: UInt64
}

enum ServerCatalogError: Error, LocalizedError, Equatable {
    case unavailable, authenticationRequired, staleContext, invalidResponse
    case alreadyRunning, bindingConflict, interrupted, localChanges, incompleteSnapshot
    var errorDescription: String? {
        switch self {
        case .unavailable: "서버 목록을 사용할 수 없습니다. 연결 설정을 확인하세요."
        case .authenticationRequired: "로그인한 뒤 서버 작품 목록을 열어 주세요."
        case .staleContext: "계정이나 연결이 바뀌었습니다. 목록을 새로 불러오세요."
        case .invalidResponse: "서버 작품 정보를 확인하지 못했습니다. 다시 불러오세요."
        case .alreadyRunning: "작품을 가져오는 중입니다. 완료되거나 중단될 때까지 기다려 주세요."
        case .bindingConflict: "이 작품은 다른 로컬 작품 또는 계정의 연결과 겹칩니다. 기존 자료를 보존했습니다."
        case .interrupted: "가져오기 기록을 확인하지 못했습니다. 기록과 원고를 보존했습니다."
        case .localChanges: "로컬 미완료 변경이 있어 가져오기를 중단했습니다."
        case .incompleteSnapshot: "일부 구조나 원고를 적용하지 못했습니다. 가져오기 기록을 보존했으며 다시 시도할 수 있습니다."
        }
    }
}

protocol ServerProjectCatalogTransporting: Sendable {
    var endpointID: String { get }
    func page(after: UUID?) async throws -> [ServerCatalogProject]
    func project(id: UUID) async throws -> ServerCatalogProject?
}

/// SELECT만 가진 전송 객체다. 등록·이름 변경·lease API를 받지 않는다.
struct LiveServerProjectCatalogTransport: ServerProjectCatalogTransporting {
    let client: SupabaseClient
    let endpointID: String
    var receiveClients: ReceiveValidationSDKClients? = nil
    func page(after: UUID?) async throws -> [ServerCatalogProject] {
        let client = try ReceiveValidationSDKClients.operationClient(client, pool: receiveClients)
        let query = client.from("projects").select("project_id,name").is("trashed_at", value: nil)
        if let after { _ = query.gt("project_id", value: after.uuidString.lowercased()) }
        return try await query.order("project_id").limit(200).execute().value
    }
    func project(id: UUID) async throws -> ServerCatalogProject? {
        let client = try ReceiveValidationSDKClients.operationClient(client, pool: receiveClients)
        let rows: [ServerCatalogProject] = try await client.from("projects")
            .select("project_id,name").eq("project_id", value: id.uuidString.lowercased())
            .is("trashed_at", value: nil).limit(2).execute().value
        guard rows.count <= 1 else { throw ServerCatalogError.invalidResponse }
        return rows.first
    }
}

struct ServerReceivingJournal: Codable, Equatable, Sendable {
    let version: Int
    let localIdentityPolicy: String
    let transactionID: UUID
    let project: Project
    let serverProjectID: UUID
    let accountID: UUID
    let endpoint: String
}

protocol ServerProjectReceiving: Sendable {
    func receivingJournals() async throws -> [ServerReceivingJournal]
    func beginReceiving(_ server: ServerCatalogProject, localName: String,
                        scope: ServerCatalogScope) async throws -> ServerReceivingJournal
    func validateReceiving(_ journal: ServerReceivingJournal) async throws
    func finishReceiving(_ journal: ServerReceivingJournal,
                         authorized: @Sendable () -> Bool) async throws -> ManagedProject
    func isReceiving(_ id: ProjectID) async throws -> Bool
    func receivedOriginMatches(_ id: ProjectID, scope: ServerCatalogScope) async throws -> Bool
}

enum ServerCatalogImportState: String, Sendable {
    case available = "미가져옴"
    case imported = "가져옴"
    case interrupted = "가져오기 중단"
    case conflict = "연결 충돌"
}

struct ServerCatalogEntry: Identifiable, Equatable, Sendable {
    let project: ServerCatalogProject
    let state: ServerCatalogImportState
    let localName: String?
    var id: UUID { project.id }
}

struct ServerCatalogSnapshot: Equatable, Sendable {
    let scope: ServerCatalogScope
    let entries: [ServerCatalogEntry]
}

actor ServerProjectCatalogService {
    private let transport: any ServerProjectCatalogTransporting
    private let authentication: any AuthenticationServicing
    private let receiver: any ServerProjectReceiving
    private let projects: any ProjectRepository
    private let bindings: any ProjectBindingStoring
    private let puller: any SyncV2SnapshotPulling
    private let queueIsEmpty: @Sendable (ProjectID) async throws -> Bool
    private let markFolderIdentity: @Sendable (ProjectID) async throws -> Void
    private var importing = false

    init(transport: any ServerProjectCatalogTransporting, authentication: any AuthenticationServicing,
         receiver: any ServerProjectReceiving, projects: any ProjectRepository,
         bindings: any ProjectBindingStoring, puller: any SyncV2SnapshotPulling,
         queueIsEmpty: @escaping @Sendable (ProjectID) async throws -> Bool,
         markFolderIdentity: @escaping @Sendable (ProjectID) async throws -> Void) {
        self.transport = transport; self.authentication = authentication; self.receiver = receiver
        self.projects = projects; self.bindings = bindings; self.puller = puller
        self.queueIsEmpty = queueIsEmpty; self.markFolderIdentity = markFolderIdentity
    }

    private func scope() async throws -> ServerCatalogScope {
        let epoch = authentication.contractEpoch?.value ?? 0
        guard case let .authenticated(account) = await authentication.currentState() else {
            throw ServerCatalogError.authenticationRequired
        }
        guard (authentication.contractEpoch?.value ?? 0) == epoch,
              authentication.contractEpoch?.isAvailable != false else { throw ServerCatalogError.staleContext }
        try ReceiveValidationPolicy.current.requireRead(account: account.userID, endpoint: transport.endpointID)
        return ServerCatalogScope(accountID: account.userID, endpoint: transport.endpointID,
                                  authenticationEpoch: epoch)
    }

    func validate(_ expected: ServerCatalogScope) async throws {
        try Task.checkCancellation()
        guard try await scope() == expected else { throw ServerCatalogError.staleContext }
    }

    func catalog() async throws -> ServerCatalogSnapshot {
        let ticket = try ReceiveValidationPolicy.current.authorization()
        return try await ReceiveValidationPolicy.$operation.withValue(ticket) { try await self.loadCatalog() }
    }

    private func loadCatalog() async throws -> ServerCatalogSnapshot {
        let current = try await scope()
        var rows: [ServerCatalogProject] = []
        var seen = Set<UUID>()
        var cursor: UUID?
        while true {
            let page = try await transport.page(after: cursor)
            try await validate(current)
            for row in page {
                guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(row.id).inserted,
                      cursor == nil || row.id.uuidString > cursor!.uuidString else {
                    throw ServerCatalogError.invalidResponse
                }
                rows.append(row)
            }
            if page.isEmpty { break }
            guard let next = page.map(\.id).max(by: { $0.uuidString < $1.uuidString }),
                  rows.count <= 100_000 else { throw ServerCatalogError.invalidResponse }
            cursor = next
        }
        let journals = try await receiver.receivingJournals()
        let allBindings = try await bindings.allBindings()
        let localProjects = try await projects.projects()
        var conflictingOrigins = Set<ProjectID>()
        for binding in allBindings where binding.serverProjectID != nil {
            if (try? await receiver.receivedOriginMatches(binding.localProjectID, scope: current)) != true {
                conflictingOrigins.insert(binding.localProjectID)
            }
        }
        try await validate(current)
        let entries = rows.map { row -> ServerCatalogEntry in
            let matching = allBindings.filter { $0.serverProjectID == row.id }
            let journal = journals.first { $0.serverProjectID == row.id }
            if let journal {
                let valid = journal.accountID == current.accountID && journal.endpoint == current.endpoint
                    && matching.allSatisfy { $0.localProjectID == journal.project.id && $0.ownerSubject == current.accountID }
                    && allBindings.filter { $0.localProjectID == journal.project.id }.allSatisfy {
                        $0.kind == .localOnly || ($0.kind == .existingServerProject
                            && $0.serverProjectID == row.id && $0.ownerSubject == current.accountID)
                    }
                return ServerCatalogEntry(project: row, state: valid ? .interrupted : .conflict,
                                          localName: journal.project.name)
            }
            if let binding = matching.first {
                let valid = matching.count == 1 && binding.ownerSubject == current.accountID
                    && localProjects.contains { $0.id == binding.localProjectID }
                    && !conflictingOrigins.contains(binding.localProjectID)
                return ServerCatalogEntry(project: row, state: valid ? .imported : .conflict,
                                          localName: binding.projectName)
            }
            let collision = localProjects.contains { $0.id.rawValue == row.id }
            return ServerCatalogEntry(project: row, state: collision ? .conflict : .available, localName: nil)
        }
        return ServerCatalogSnapshot(scope: current, entries: entries)
    }

    func receive(_ entry: ServerCatalogEntry, from snapshot: ServerCatalogSnapshot,
                 localName: String) async throws -> ManagedProject {
        let ticket = try ReceiveValidationPolicy.current.authorization()
        return try await ReceiveValidationPolicy.$operation.withValue(ticket) {
            try await ReceiveValidationPolicy.$localProject.withValue(entry.id) {
                try await self.performReceive(entry, from: snapshot, localName: localName)
            }
        }
    }

    private func performReceive(_ entry: ServerCatalogEntry, from snapshot: ServerCatalogSnapshot,
                                localName: String) async throws -> ManagedProject {
        guard !importing else { throw ServerCatalogError.alreadyRunning }
        importing = true
        defer { importing = false }
        try await validate(snapshot.scope)
        guard snapshot.entries.contains(entry), entry.state == .available || entry.state == .interrupted else {
            throw ServerCatalogError.bindingConflict
        }
        try ReceiveValidationPolicy.current.select(entry.id)
        guard let server = try await transport.project(id: entry.id), server.id == entry.id else {
            throw ServerCatalogError.invalidResponse
        }
        try await validate(snapshot.scope)
        let prior = try await receiver.receivingJournals().first { $0.serverProjectID == entry.id }
        if let binding = try await bindings.binding(forServerProjectID: entry.id) {
            guard let prior, prior.project.id == binding.localProjectID,
                  binding.ownerSubject == snapshot.scope.accountID else { throw ServerCatalogError.bindingConflict }
        }
        try await validate(snapshot.scope)
        let journal = try await receiver.beginReceiving(server, localName: localName, scope: snapshot.scope)
        try await validate(snapshot.scope)
        try await receiver.validateReceiving(journal)
        guard try await queueIsEmpty(journal.project.id) else { throw ServerCatalogError.localChanges }
        if let local = try await bindings.binding(for: journal.project.id) {
            guard local.kind == .localOnly || (local.kind == .existingServerProject
                && local.serverProjectID == journal.serverProjectID && local.ownerSubject == journal.accountID)
            else { throw ServerCatalogError.bindingConflict }
        }
        // snapshot 장부의 복합 FK는 서버 ID가 연결된 행을 요구한다. journal이
        // currentBinding/connectedBindings와 작품 목록을 차단하는 동안만 저장한다.
        // 기존 서버 binding 종류이므로 초기 업로드를 생성하지 않는다.
        try await validate(snapshot.scope)
        try await bindings.save(.connected(localProjectID: journal.project.id,
            serverProjectID: journal.serverProjectID, kind: .existingServerProject,
            projectName: journal.project.name, ownerSubject: journal.accountID))
        let receivingBinding = try await bindings.binding(for: journal.project.id)
        try await validate(snapshot.scope)
        // 전용 puller에는 lease나 이관 송신 recorder가 없다. 부분 결과는 숨겨진다.
        try ReceiveValidationPolicy.current.authorizeReceiving(journal)
        let report = try await puller.pull(localProjectID: journal.project.id,
                                          serverProjectID: journal.serverProjectID, editingGuards: [:])
        try await validate(snapshot.scope)
        guard report.contractStructureBaselineReady, report.rejectedStructureNames.isEmpty,
              report.pendingChildTombstoneFolderCount == 0, !report.hasDeferredLocalApplication,
              !report.outcomes.contains(where: { if case .mergeRequired = $0 { true } else { false } }) else {
            throw ServerCatalogError.incompleteSnapshot
        }
        try await receiver.validateReceiving(journal)
        guard try await queueIsEmpty(journal.project.id) else { throw ServerCatalogError.localChanges }
        try await validate(snapshot.scope)
        try await markFolderIdentity(journal.project.id)
        try await validate(snapshot.scope)
        guard try await bindings.binding(for: journal.project.id) == receivingBinding else {
            throw ServerCatalogError.bindingConflict
        }
        try await validate(snapshot.scope)
        let authentication = self.authentication, transport = self.transport, expected = snapshot.scope
        // binding을 저장한 뒤 중단돼도 journal이 남아 coordinator에 노출되지 않는다.
        return try await receiver.finishReceiving(journal, authorized: {
            (try? ReceiveValidationPolicy.current.requireRead(project: journal.serverProjectID)) != nil && !Task.isCancelled && (authentication.contractEpoch?.value ?? 0) == expected.authenticationEpoch
                && authentication.contractEpoch?.isAvailable != false && transport.endpointID == expected.endpoint
        })
    }
}
