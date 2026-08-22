import Foundation
import Supabase

enum ProjectBindingKind: String, Codable, Equatable, Sendable {
    case localOnly = "local_only"
    case newServerProject = "new_server_project"
    case existingServerProject = "existing_server_project"
    case windowsImport = "windows_import"
}

struct ProjectSyncBinding: Codable, Equatable, Sendable {
    let localProjectID: ProjectID
    let serverProjectID: UUID?
    let kind: ProjectBindingKind
    let projectName: String
    let ownerSubject: UUID?

    static func localOnly(
        projectID: ProjectID,
        name: String
    ) -> ProjectSyncBinding {
        ProjectSyncBinding(
            localProjectID: projectID,
            serverProjectID: nil,
            kind: .localOnly,
            projectName: name,
            ownerSubject: nil
        )
    }

    static func connected(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        kind: ProjectBindingKind,
        projectName: String,
        ownerSubject: UUID
    ) -> ProjectSyncBinding {
        ProjectSyncBinding(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: kind,
            projectName: projectName,
            ownerSubject: ownerSubject
        )
    }
}

enum ProjectBindingStoreAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum ProjectBindingStoreError: Error, Equatable, Sendable {
    case unavailable
    case invalidBinding
    case serverProjectAlreadyBound
}

protocol ProjectBindingStoring: Sendable {
    func availability() async -> ProjectBindingStoreAvailability
    func binding(for localProjectID: ProjectID) async throws
        -> ProjectSyncBinding?
    func binding(forServerProjectID serverProjectID: UUID) async throws
        -> ProjectSyncBinding?
    func allBindings() async throws -> [ProjectSyncBinding]
    func save(_ binding: ProjectSyncBinding) async throws
}

extension ProjectBindingStoring {
    func allBindings() async throws -> [ProjectSyncBinding] {
        []
    }
}

actor InMemoryProjectBindingStore: ProjectBindingStoring {
    private var bindings: [ProjectID: ProjectSyncBinding] = [:]

    func availability() -> ProjectBindingStoreAvailability {
        .available
    }

    func binding(
        for localProjectID: ProjectID
    ) -> ProjectSyncBinding? {
        bindings[localProjectID]
    }

    func binding(
        forServerProjectID serverProjectID: UUID
    ) -> ProjectSyncBinding? {
        bindings.values.first { $0.serverProjectID == serverProjectID }
    }

    func allBindings() async -> [ProjectSyncBinding] {
        Array(bindings.values)
    }

    func save(_ binding: ProjectSyncBinding) throws {
        try Self.validate(binding)
        if let serverProjectID = binding.serverProjectID,
           bindings.values.contains(where: {
               $0.serverProjectID == serverProjectID
                   && $0.localProjectID != binding.localProjectID
           }) {
            throw ProjectBindingStoreError.serverProjectAlreadyBound
        }
        bindings[binding.localProjectID] = binding
    }

    private static func validate(_ binding: ProjectSyncBinding) throws {
        let name = binding.projectName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !name.isEmpty else {
            throw ProjectBindingStoreError.invalidBinding
        }
        switch binding.kind {
        case .localOnly:
            guard
                binding.serverProjectID == nil,
                binding.ownerSubject == nil
            else {
                throw ProjectBindingStoreError.invalidBinding
            }
        case .newServerProject, .existingServerProject, .windowsImport:
            guard
                binding.serverProjectID != nil,
                binding.ownerSubject != nil
            else {
                throw ProjectBindingStoreError.invalidBinding
            }
        }
    }
}

actor UnavailableProjectBindingStore: ProjectBindingStoring {
    func availability() -> ProjectBindingStoreAvailability {
        .unavailable
    }

    func binding(
        for localProjectID: ProjectID
    ) throws -> ProjectSyncBinding? {
        _ = localProjectID
        throw ProjectBindingStoreError.unavailable
    }

    func binding(
        forServerProjectID serverProjectID: UUID
    ) throws -> ProjectSyncBinding? {
        _ = serverProjectID
        throw ProjectBindingStoreError.unavailable
    }

    func allBindings() async throws -> [ProjectSyncBinding] {
        throw ProjectBindingStoreError.unavailable
    }

    func save(_ binding: ProjectSyncBinding) throws {
        _ = binding
        throw ProjectBindingStoreError.unavailable
    }
}

struct EnsureProjectParameters: Encodable, Equatable, Sendable {
    let projectID: UUID
    let name: String

    enum CodingKeys: String, CodingKey {
        case projectID = "p_project_id"
        case name = "p_name"
    }
}

struct EnsuredServerProject: Decodable, Equatable, Sendable {
    let projectID: UUID
    let name: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case name
    }
}

enum EnsureProjectTransportError: Error, Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case invalidArgument
    case networkUnavailable
    case invalidResponse
    case serverRejected
}

protocol EnsureProjectTransporting: Sendable {
    func ensureProject(
        parameters: EnsureProjectParameters
    ) async throws -> EnsuredServerProject
}

actor LiveEnsureProjectTransport: EnsureProjectTransporting {
    private let client: SupabaseClient

    init(client: SupabaseClient) {
        self.client = client
    }

    func ensureProject(
        parameters: EnsureProjectParameters
    ) async throws -> EnsuredServerProject {
        do {
            let response: PostgrestResponse<EnsuredServerProject> =
                try await client
                    .rpc("ensure_project", params: parameters)
                    .execute()
            return response.value
        } catch let error as PostgrestError {
            switch error.message {
            case "AUTH_REQUIRED":
                throw EnsureProjectTransportError.authenticationRequired
            case "FORBIDDEN":
                throw EnsureProjectTransportError.forbidden
            case "INVALID_ARGUMENT":
                throw EnsureProjectTransportError.invalidArgument
            default:
                throw EnsureProjectTransportError.serverRejected
            }
        } catch let error as URLError {
            if error.code != .userAuthenticationRequired {
                throw EnsureProjectTransportError.networkUnavailable
            }
            throw EnsureProjectTransportError.authenticationRequired
        } catch is DecodingError {
            throw EnsureProjectTransportError.invalidResponse
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                throw EnsureProjectTransportError.networkUnavailable
            }
            throw EnsureProjectTransportError.serverRejected
        }
    }
}

enum ProjectBindingConfirmationError: Error, Equatable, Sendable {
    case invalidUUID
    case mismatch
}

struct ConfirmedServerProjectID: Equatable, Sendable {
    let value: UUID

    init(
        expectedServerProjectID: UUID,
        userEnteredUUID: String
    ) throws {
        let trimmed = userEnteredUUID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let entered = UUID(uuidString: trimmed) else {
            throw ProjectBindingConfirmationError.invalidUUID
        }
        guard entered == expectedServerProjectID else {
            throw ProjectBindingConfirmationError.mismatch
        }
        value = expectedServerProjectID
    }
}

enum ProjectBindingFailure: Equatable, Sendable {
    case configurationUnavailable
    case authenticationRequired
    case bindingStoreUnavailable
    case localStorageUnavailable
    case localProjectNotFound
    case invalidProjectName
    case confirmationRequired
    case serverProjectAlreadyBound
    case serverProjectNotEmpty
    case forbidden
    case networkUnavailable
    case invalidServerResponse
    case serverRejected
    case initialSnapshotNotQueued
    case notBound
}

enum ProjectBindingResult: Equatable, Sendable {
    case connected(ProjectSyncBinding)
    case disconnected(ProjectSyncBinding)
    case failed(ProjectBindingFailure)
}

protocol InitialProjectSyncRecording: Sendable {
    func recordInitialSnapshot(
        projectID: ProjectID,
        projectName: String,
        batchKind: DurableLocalBatchKind
    ) async -> DurableRecordResult
}

struct NoOpInitialProjectSyncRecorder: InitialProjectSyncRecording {
    func recordInitialSnapshot(
        projectID: ProjectID,
        projectName: String,
        batchKind: DurableLocalBatchKind
    ) async -> DurableRecordResult {
        _ = batchKind
        return .notNeeded
    }
}

protocol ProjectBindingServicing: Sendable {
    func bindingUpdates(
        for localProjectID: ProjectID
    ) async -> AsyncStream<ProjectSyncBinding?>
    func currentBinding(for localProjectID: ProjectID) async
        -> ProjectSyncBinding?
    func connectedBindings() async -> [ProjectSyncBinding]
    func createServerProject(for localProjectID: ProjectID) async
        -> ProjectBindingResult
    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) async -> ProjectBindingResult
    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) async -> ProjectBindingResult
    func refreshServerName(for localProjectID: ProjectID) async
        -> ProjectBindingResult
    func disconnect(localProjectID: ProjectID) async -> ProjectBindingResult
}

extension ProjectBindingServicing {
    func bindingUpdates(
        for localProjectID: ProjectID
    ) async -> AsyncStream<ProjectSyncBinding?> {
        _ = localProjectID
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func currentBinding(
        for localProjectID: ProjectID
    ) async -> ProjectSyncBinding? {
        _ = localProjectID
        return nil
    }

    func connectedBindings() async -> [ProjectSyncBinding] {
        []
    }
}

actor SupabaseProjectBindingService: ProjectBindingServicing {
    private let transport: (any EnsureProjectTransporting)?
    private let bindingStore: any ProjectBindingStoring
    private let projectRepository: any ProjectRepository
    private let authenticationService: any AuthenticationServicing
    private let initialSyncRecorder: any InitialProjectSyncRecording
    private let snapshotClient: (any SyncV2SnapshotClienting)?
    private var bindingObservers: [
        ProjectID: [UUID: AsyncStream<ProjectSyncBinding?>.Continuation]
    ] = [:]

    init(
        transport: (any EnsureProjectTransporting)?,
        bindingStore: any ProjectBindingStoring,
        projectRepository: any ProjectRepository,
        authenticationService: any AuthenticationServicing,
        initialSyncRecorder: any InitialProjectSyncRecording =
            NoOpInitialProjectSyncRecorder(),
        snapshotClient: (any SyncV2SnapshotClienting)? = nil
    ) {
        self.transport = transport
        self.bindingStore = bindingStore
        self.projectRepository = projectRepository
        self.authenticationService = authenticationService
        self.initialSyncRecorder = initialSyncRecorder
        self.snapshotClient = snapshotClient
    }

    func currentBinding(
        for localProjectID: ProjectID
    ) async -> ProjectSyncBinding? {
        guard await bindingStore.availability() == .available else {
            return nil
        }
        guard let binding = try? await bindingStore.binding(
            for: localProjectID
        ) else {
            return nil
        }
        return await prepareInitialSnapshotIfNeeded(for: binding)
            ? binding
            : nil
    }

    func bindingUpdates(
        for localProjectID: ProjectID
    ) -> AsyncStream<ProjectSyncBinding?> {
        let observerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            bindingObservers[localProjectID, default: [:]][observerID] =
                continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeBindingObserver(
                        localProjectID: localProjectID,
                        observerID: observerID
                    )
                }
            }
        }
    }

    func connectedBindings() async -> [ProjectSyncBinding] {
        guard await bindingStore.availability() == .available else {
            return []
        }
        let bindings = (try? await bindingStore.allBindings())?
            .filter { $0.serverProjectID != nil } ?? []
        var prepared: [ProjectSyncBinding] = []
        for binding in bindings {
            if await prepareInitialSnapshotIfNeeded(for: binding) {
                prepared.append(binding)
            }
        }
        return prepared
    }

    func createServerProject(
        for localProjectID: ProjectID
    ) async -> ProjectBindingResult {
        await connect(
            localProjectID: localProjectID,
            serverProjectID: localProjectID.rawValue,
            kind: .newServerProject
        )
    }

    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) async -> ProjectBindingResult {
        await connect(
            localProjectID: localProjectID,
            serverProjectID: confirmation.value,
            kind: .existingServerProject
        )
    }

    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) async -> ProjectBindingResult {
        await connect(
            localProjectID: localProjectID,
            serverProjectID: confirmation.value,
            kind: .windowsImport
        )
    }

    func refreshServerName(
        for localProjectID: ProjectID
    ) async -> ProjectBindingResult {
        guard await bindingStore.availability() == .available else {
            return .failed(.bindingStoreUnavailable)
        }
        let existing: ProjectSyncBinding
        let serverProjectID: UUID
        do {
            guard
                let binding = try await bindingStore.binding(
                    for: localProjectID
                ),
                binding.kind != .localOnly,
                let storedServerProjectID = binding.serverProjectID
            else {
                return .failed(.notBound)
            }
            existing = binding
            serverProjectID = storedServerProjectID
        } catch {
            return .failed(storeFailure(error))
        }
        return await connect(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: existing.kind
        )
    }

    func disconnect(
        localProjectID: ProjectID
    ) async -> ProjectBindingResult {
        guard await bindingStore.availability() == .available else {
            return .failed(.bindingStoreUnavailable)
        }
        let project: Project
        do {
            guard
                let storedProject = try await projectRepository.project(
                    id: localProjectID
                )
            else {
                return .failed(.localProjectNotFound)
            }
            project = storedProject
        } catch {
            return .failed(.localStorageUnavailable)
        }
        let name = normalizedName(project.name)
        guard !name.isEmpty else {
            return .failed(.invalidProjectName)
        }
        let localOnly = ProjectSyncBinding.localOnly(
            projectID: localProjectID,
            name: name
        )
        do {
            try await bindingStore.save(localOnly)
            publish(localOnly, localProjectID: localProjectID)
            return .disconnected(localOnly)
        } catch {
            return .failed(storeFailure(error))
        }
    }

    private enum ServerProjectEmptiness {
        case empty
        case notEmpty
        /// 서버 상태를 확인하지 못한 경우다. 비어 있다고 가정하고 올리면 기존
        /// 원고와 충돌하므로 확인 실패는 연결 실패로 다룬다.
        case unknown
    }

    /// tombstone만 남은 작품은 live 문서가 없으므로 초기 snapshot을 올려도
    /// 충돌하지 않는다. 삭제된 문서는 비어 있음 판정에서 제외한다.
    private func serverProjectEmptiness(
        _ serverProjectID: UUID
    ) async -> ServerProjectEmptiness {
        guard let snapshotClient else { return .unknown }
        do {
            let documents = try await snapshotClient.fetchDocuments(
                projectID: serverProjectID
            )
            return documents.contains { !$0.isDeleted } ? .notEmpty : .empty
        } catch {
            return .unknown
        }
    }

    private func connect(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        kind: ProjectBindingKind
    ) async -> ProjectBindingResult {
        guard let transport else {
            return .failed(.configurationUnavailable)
        }
        guard await bindingStore.availability() == .available else {
            return .failed(.bindingStoreUnavailable)
        }
        let project: Project
        do {
            guard
                let storedProject = try await projectRepository.project(
                    id: localProjectID
                )
            else {
                return .failed(.localProjectNotFound)
            }
            project = storedProject
        } catch {
            return .failed(.localStorageUnavailable)
        }
        let name = normalizedName(project.name)
        guard !name.isEmpty else {
            return .failed(.invalidProjectName)
        }
        guard
            case let .authenticated(account) =
                await authenticationService.currentState()
        else {
            return .failed(.authenticationRequired)
        }

        // 같은 로컬 작품이 이미 이 서버 작품에 붙어 있으면 최초 연결이 아니라
        // 이름 새로고침 같은 재확인이다. 이때 서버에 원고가 있는 것은 이 기기가
        // 올린 정상 상태이므로 아래 비어 있음 검사를 하지 않는다.
        let isReconnect: Bool
        do {
            let existing = try await bindingStore.binding(
                forServerProjectID: serverProjectID
            )
            if let existing, existing.localProjectID != localProjectID {
                return .failed(.serverProjectAlreadyBound)
            }
            isReconnect = existing != nil
        } catch {
            return .failed(storeFailure(error))
        }

        let ensured: EnsuredServerProject
        do {
            ensured = try await transport.ensureProject(
                parameters: EnsureProjectParameters(
                    projectID: serverProjectID,
                    name: name
                )
            )
        } catch let error as EnsureProjectTransportError {
            return .failed(transportFailure(error))
        } catch {
            return .failed(.serverRejected)
        }
        guard
            ensured.projectID == serverProjectID,
            normalizedName(ensured.name) == name
        else {
            return .failed(.invalidServerResponse)
        }

        // 초기 snapshot을 올리는 연결은 서버의 모든 live 문서를 create로 보낸다.
        // 서버 작품에 이미 문서가 있으면 tree-order는 document UUID가 겹쳐
        // DOCUMENT_ALREADY_EXISTS, 본문은 같은 경로를 다른 UUID가 점유해
        // PATH_CONFLICT가 된다. 어느 쪽도 기존 원고를 덮어쓰지는 않지만 연결이
        // 그 자리에서 멈추므로, 올리기 전에 비어 있는지 확인하고 막는다.
        // 기존 서버 작품에 붙는 연결(.existingServerProject)은 올리지 않고
        // pull로 받아오므로 이 검사를 하지 않는다.
        if !isReconnect,
           kind == .newServerProject || kind == .windowsImport {
            switch await serverProjectEmptiness(serverProjectID) {
            case .empty:
                break
            case .notEmpty:
                return .failed(.serverProjectNotEmpty)
            case .unknown:
                return .failed(.networkUnavailable)
            }
        }

        let binding = ProjectSyncBinding.connected(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            kind: kind,
            projectName: name,
            ownerSubject: account.userID
        )
        do {
            try await bindingStore.save(binding)
            guard await prepareInitialSnapshotIfNeeded(for: binding) else {
                return .failed(.initialSnapshotNotQueued)
            }
            publish(binding, localProjectID: localProjectID)
            return .connected(binding)
        } catch {
            return .failed(storeFailure(error))
        }
    }

    /// Native identity 연결은 초기 batch가 durable queue에 들어가기 전까지 다른
    /// coordinator에 노출하지 않는다. 앱 재시작 때 current/allBindings 조회가
    /// marker 또는 binding 직후 중단을 자동으로 재개한다.
    private func prepareInitialSnapshotIfNeeded(
        for binding: ProjectSyncBinding
    ) async -> Bool {
        let batchKind: DurableLocalBatchKind
        switch binding.kind {
        case .newServerProject:
            batchKind = .projectBinding
        case .windowsImport:
            batchKind = .windowsImport
        case .localOnly, .existingServerProject:
            return true
        }
        let result = await initialSyncRecorder.recordInitialSnapshot(
            projectID: binding.localProjectID,
            projectName: binding.projectName,
            batchKind: batchKind
        )
        switch result {
        case .queued, .notNeeded:
            return true
        case .serverSizeLimitExceeded, .localOnly,
             .localSavedButNotQueued:
            return false
        }
    }

    private func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publish(
        _ binding: ProjectSyncBinding?,
        localProjectID: ProjectID
    ) {
        bindingObservers[localProjectID]?.values.forEach {
            $0.yield(binding)
        }
    }

    private func removeBindingObserver(
        localProjectID: ProjectID,
        observerID: UUID
    ) {
        bindingObservers[localProjectID]?[observerID] = nil
        if bindingObservers[localProjectID]?.isEmpty == true {
            bindingObservers[localProjectID] = nil
        }
    }

    private func storeFailure(_ error: any Error) -> ProjectBindingFailure {
        switch error as? ProjectBindingStoreError {
        case .serverProjectAlreadyBound:
            return .serverProjectAlreadyBound
        case .unavailable:
            return .bindingStoreUnavailable
        case .invalidBinding:
            return .serverRejected
        case nil:
            return .bindingStoreUnavailable
        }
    }

    private func transportFailure(
        _ error: EnsureProjectTransportError
    ) -> ProjectBindingFailure {
        switch error {
        case .authenticationRequired:
            return .authenticationRequired
        case .forbidden:
            return .forbidden
        case .invalidArgument:
            return .invalidProjectName
        case .networkUnavailable:
            return .networkUnavailable
        case .invalidResponse:
            return .invalidServerResponse
        case .serverRejected:
            return .serverRejected
        }
    }
}
