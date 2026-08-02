import Foundation
import XCTest
@testable import WriterPad

final class SupabaseProjectBindingServiceTests: XCTestCase {
    func testNewServerProjectUsesLocalUUIDAndPersistsBinding() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000401",
            name: "  새 서버 작품  "
        )
        let fixture = makeFixture(projects: [project])

        let result = await fixture.service.createServerProject(for: project.id)

        let expected = ProjectSyncBinding.connected(
            localProjectID: project.id,
            serverProjectID: project.id.rawValue,
            kind: .newServerProject,
            projectName: "새 서버 작품",
            ownerSubject: fixture.userID
        )
        XCTAssertEqual(result, .connected(expected))
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertEqual(stored, expected)
        let parameters = await fixture.transport.receivedParameters()
        XCTAssertEqual(
            parameters,
            [EnsureProjectParameters(
                projectID: project.id.rawValue,
                name: "새 서버 작품"
            )]
        )
    }

    func testEnsureProjectParametersUseExactWireKeys() throws {
        let parameters = EnsureProjectParameters(
            projectID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000400"
            )!,
            name: "wire"
        )

        let data = try JSONEncoder().encode(parameters)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set(["p_project_id", "p_name"])
        )
        XCTAssertNil(object["projectID"])
    }

    func testSameNameNeverMergesDifferentLocalProjects() async {
        let first = makeProject(
            id: "00000000-0000-0000-0000-000000000402",
            name: "동일 이름"
        )
        let second = makeProject(
            id: "00000000-0000-0000-0000-000000000403",
            name: "동일 이름"
        )
        let fixture = makeFixture(projects: [first, second])

        let firstResult = await fixture.service.createServerProject(
            for: first.id
        )
        let secondResult = await fixture.service.createServerProject(
            for: second.id
        )

        guard
            case let .connected(firstBinding) = firstResult,
            case let .connected(secondBinding) = secondResult
        else {
            return XCTFail("Both explicit projects must be connected.")
        }
        XCTAssertNotEqual(
            firstBinding.serverProjectID,
            secondBinding.serverProjectID
        )
    }

    func testExistingProjectRequiresExactUUIDConfirmation() {
        let expected = UUID(
            uuidString: "00000000-0000-0000-0000-000000000404"
        )!

        XCTAssertThrowsError(
            try ConfirmedServerProjectID(
                expectedServerProjectID: expected,
                userEnteredUUID:
                    "00000000-0000-0000-0000-000000000405"
            )
        ) {
            XCTAssertEqual(
                $0 as? ProjectBindingConfirmationError,
                .mismatch
            )
        }
        XCTAssertThrowsError(
            try ConfirmedServerProjectID(
                expectedServerProjectID: expected,
                userEnteredUUID: "동일 이름"
            )
        ) {
            XCTAssertEqual(
                $0 as? ProjectBindingConfirmationError,
                .invalidUUID
            )
        }
    }

    func testConfirmedExistingProjectKeepsServerUUID() async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000406",
            name: "기존 연결"
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000407"
        )!
        let fixture = makeFixture(projects: [project])
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString.lowercased()
        )

        let result = await fixture.service.connectExistingProject(
            localProjectID: project.id,
            confirmation: confirmation
        )

        guard case let .connected(binding) = result else {
            return XCTFail("Expected a connected binding.")
        }
        XCTAssertEqual(binding.kind, .existingServerProject)
        XCTAssertEqual(binding.serverProjectID, serverID)
    }

    func testWindowsImportUsesDistinctBindingKind() async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000408",
            name: "Windows 가져오기"
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000409"
        )!
        let fixture = makeFixture(projects: [project])
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )

        let result = await fixture.service.connectWindowsProject(
            localProjectID: project.id,
            confirmation: confirmation
        )

        guard case let .connected(binding) = result else {
            return XCTFail("Expected a Windows binding.")
        }
        XCTAssertEqual(binding.kind, .windowsImport)
        XCTAssertEqual(binding.serverProjectID, serverID)
    }

    func testNewAndWindowsConnectionsRecordInitialSnapshotsWithDistinctKinds()
        async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000498",
            name: "명시 연결 snapshot"
        )
        let recorder = InitialSyncRecorderSpy()
        let fixture = makeFixture(
            projects: [project],
            initialSyncRecorder: recorder
        )

        _ = await fixture.service.createServerProject(for: project.id)
        let callsBeforeWindowsConnection = await recorder.calls()
        XCTAssertEqual(callsBeforeWindowsConnection.count, 1)
        XCTAssertEqual(
            callsBeforeWindowsConnection[0],
            InitialSyncRecorderSpy.Call(
                projectID: project.id,
                projectName: project.name,
                batchKind: .projectBinding
            )
        )

        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000497"
        )!
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )
        _ = await fixture.service.connectWindowsProject(
            localProjectID: project.id,
            confirmation: confirmation
        )

        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].projectID, project.id)
        XCTAssertEqual(calls[1].projectName, project.name)
        XCTAssertEqual(calls[1].batchKind, .windowsImport)
    }

    func testNameRefreshUsesSameServerUUID() async throws {
        let projectID = ProjectID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000410"
            )!
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000411"
        )!
        let repository = ProjectRepositoryStub(projects: [
            Project(
                id: projectID,
                name: "변경 전",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
        ])
        let fixture = makeFixture(
            projects: [],
            repository: repository
        )
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )
        _ = await fixture.service.connectExistingProject(
            localProjectID: projectID,
            confirmation: confirmation
        )
        await repository.replace(
            Project(
                id: projectID,
                name: "변경 후",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            )
        )

        let result = await fixture.service.refreshServerName(
            for: projectID
        )

        guard case let .connected(binding) = result else {
            return XCTFail("Expected the renamed binding.")
        }
        XCTAssertEqual(binding.serverProjectID, serverID)
        XCTAssertEqual(binding.projectName, "변경 후")
        let last = await fixture.transport.receivedParameters().last
        XCTAssertEqual(last?.projectID, serverID)
        XCTAssertEqual(last?.name, "변경 후")
    }

    func testForbiddenIsNotReportedAsEmptyOrNetworkFailure() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000412",
            name: "권한 거부"
        )
        let fixture = makeFixture(
            projects: [project],
            transportResult: .failure(.forbidden)
        )

        let result = await fixture.service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.forbidden))
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertNil(stored)
    }

    func testNetworkFailureIsDistinctAndDoesNotPersistBinding() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000413",
            name: "오프라인"
        )
        let fixture = makeFixture(
            projects: [project],
            transportResult: .failure(.networkUnavailable)
        )

        let result = await fixture.service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.networkUnavailable))
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertNil(stored)
    }

    func testUnauthenticatedStateDoesNotCallRPC() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000414",
            name: "로컬 전용"
        )
        let fixture = makeFixture(
            projects: [project],
            authenticationState: .signedOut(.noStoredSession)
        )

        let result = await fixture.service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.authenticationRequired))
        let callCount = await fixture.transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testMismatchedServerResponseIsRejectedWithoutBinding() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000415",
            name: "응답 검증"
        )
        let wrong = EnsuredServerProject(
            projectID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000416"
            )!,
            name: project.name
        )
        let fixture = makeFixture(
            projects: [project],
            transportResult: .success(wrong)
        )

        let result = await fixture.service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.invalidServerResponse))
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertNil(stored)
    }

    func testDisconnectOnlyChangesLocalBindingAndNeverCallsServer() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000417",
            name: "연결 해제"
        )
        let fixture = makeFixture(projects: [project])
        _ = await fixture.service.createServerProject(for: project.id)
        let before = await fixture.transport.callCount()

        let result = await fixture.service.disconnect(
            localProjectID: project.id
        )

        let expected = ProjectSyncBinding.localOnly(
            projectID: project.id,
            name: project.name
        )
        XCTAssertEqual(result, .disconnected(expected))
        let after = await fixture.transport.callCount()
        XCTAssertEqual(after, before)
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertEqual(stored, expected)
    }

    func testUnavailableDurableStoreBlocksRemoteMutation() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000418",
            name: "저장소 대기"
        )
        let transport = EnsureProjectTransportStub()
        let service = SupabaseProjectBindingService(
            transport: transport,
            bindingStore: UnavailableProjectBindingStore(),
            projectRepository: ProjectRepositoryStub(projects: [project]),
            authenticationService: AuthenticationServiceStub(
                state: authenticatedState
            )
        )

        let result = await service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.bindingStoreUnavailable))
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testMissingSupabaseConfigurationDoesNotTouchBindingStore() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000422",
            name: "설정 없음"
        )
        let store = InMemoryProjectBindingStore()
        let service = SupabaseProjectBindingService(
            transport: nil,
            bindingStore: store,
            projectRepository: ProjectRepositoryStub(projects: [project]),
            authenticationService: AuthenticationServiceStub(
                state: authenticatedState
            )
        )

        let result = await service.createServerProject(for: project.id)

        XCTAssertEqual(result, .failed(.configurationUnavailable))
        let stored = await store.binding(for: project.id)
        XCTAssertNil(stored)
    }

    func testOneServerProjectCannotBindToTwoLocalProjects() async throws {
        let first = makeProject(
            id: "00000000-0000-0000-0000-000000000419",
            name: "첫 로컬"
        )
        let second = makeProject(
            id: "00000000-0000-0000-0000-000000000420",
            name: "두 번째 로컬"
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000421"
        )!
        let fixture = makeFixture(projects: [first, second])
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )
        _ = await fixture.service.connectExistingProject(
            localProjectID: first.id,
            confirmation: confirmation
        )

        let secondResult = await fixture.service.connectExistingProject(
            localProjectID: second.id,
            confirmation: confirmation
        )

        XCTAssertEqual(
            secondResult,
            .failed(.serverProjectAlreadyBound)
        )
        let callCount = await fixture.transport.callCount()
        XCTAssertEqual(callCount, 1)
    }

    private var authenticatedState: AuthenticationState {
        .authenticated(
            AuthenticatedAccount(
                userID: UUID(
                    uuidString:
                        "00000000-0000-0000-0000-000000000499"
                )!,
                maskedEmail: "w***@example.com"
            )
        )
    }

    private func makeProject(id: String, name: String) -> Project {
        Project(
            id: ProjectID(rawValue: UUID(uuidString: id)!),
            name: name,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeFixture(
        projects: [Project],
        repository: ProjectRepositoryStub? = nil,
        authenticationState: AuthenticationState? = nil,
        transportResult: Result<
            EnsuredServerProject,
            EnsureProjectTransportError
        >? = nil,
        initialSyncRecorder: any InitialProjectSyncRecording =
            NoOpInitialProjectSyncRecorder()
    ) -> BindingFixture {
        let store = InMemoryProjectBindingStore()
        let transport = EnsureProjectTransportStub(result: transportResult)
        let auth = AuthenticationServiceStub(
            state: authenticationState ?? authenticatedState
        )
        let projectRepository = repository
            ?? ProjectRepositoryStub(projects: projects)
        let service = SupabaseProjectBindingService(
            transport: transport,
            bindingStore: store,
            projectRepository: projectRepository,
            authenticationService: auth,
            initialSyncRecorder: initialSyncRecorder
        )
        let userID: UUID
        if case let .authenticated(account) =
            authenticationState ?? authenticatedState {
            userID = account.userID
        } else {
            userID = UUID()
        }
        return BindingFixture(
            service: service,
            store: store,
            transport: transport,
            userID: userID
        )
    }
}

private actor InitialSyncRecorderSpy: InitialProjectSyncRecording {
    struct Call: Equatable, Sendable {
        let projectID: ProjectID
        let projectName: String
        let batchKind: DurableLocalBatchKind
    }

    private var values: [Call] = []

    func recordInitialSnapshot(
        projectID: ProjectID,
        projectName: String,
        batchKind: DurableLocalBatchKind
    ) async -> DurableRecordResult {
        values.append(
            Call(
                projectID: projectID,
                projectName: projectName,
                batchKind: batchKind
            )
        )
        return .queued(operationIDs: [])
    }

    func calls() -> [Call] {
        values
    }
}

private struct BindingFixture {
    let service: SupabaseProjectBindingService
    let store: InMemoryProjectBindingStore
    let transport: EnsureProjectTransportStub
    let userID: UUID
}

private actor ProjectRepositoryStub: ProjectRepository {
    private var stored: [ProjectID: Project]

    init(projects: [Project]) {
        stored = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    func projects() -> [Project] {
        Array(stored.values)
    }

    func project(id: ProjectID) -> Project? {
        stored[id]
    }

    func save(_ project: Project) {
        stored[project.id] = project
    }

    func remove(id: ProjectID) {
        stored[id] = nil
    }

    func replace(_ project: Project) {
        stored[project.id] = project
    }
}

private actor AuthenticationServiceStub: AuthenticationServicing {
    private var state: AuthenticationState

    init(state: AuthenticationState) {
        self.state = state
    }

    func currentState() -> AuthenticationState {
        state
    }

    func restoreSession() -> AuthenticationState {
        state
    }

    // 바인딩 테스트 더블은 refresh와 restore를 의도적으로 구분하지 않는다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return state
    }

    func signIn(email: String, password: String) -> AuthenticationState {
        _ = email
        _ = password
        return state
    }

    func signOut() -> AuthenticationState {
        state = .signedOut(.userInitiated)
        return state
    }
}

private actor EnsureProjectTransportStub: EnsureProjectTransporting {
    private let result: Result<
        EnsuredServerProject,
        EnsureProjectTransportError
    >?
    private var parameters: [EnsureProjectParameters] = []

    init(
        result: Result<
            EnsuredServerProject,
            EnsureProjectTransportError
        >? = nil
    ) {
        self.result = result
    }

    func ensureProject(
        parameters: EnsureProjectParameters
    ) throws -> EnsuredServerProject {
        self.parameters.append(parameters)
        if let result {
            return try result.get()
        }
        return EnsuredServerProject(
            projectID: parameters.projectID,
            name: parameters.name
        )
    }

    func receivedParameters() -> [EnsureProjectParameters] {
        parameters
    }

    func callCount() -> Int {
        parameters.count
    }
}
