import Foundation
import XCTest
@testable import WriterPad

@MainActor
final class SyncSettingsModelTests: XCTestCase {
#if DEBUG
    func testContractGateCannotOpenWithoutFreshHandshakeButStoredGateCanClose()
        async throws {
        let project = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000899",
            name: "관문 확인"
        )
        let defaults = makeDefaults()
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(projects: [project]),
            authenticationService: SyncSettingsAuthenticationStub(
                state: .signedOut(.noStoredSession)
            ),
            projectBindingService: SyncSettingsBindingStub(
                projects: [project],
                ownerSubject: UUID()
            ),
            defaults: defaults
        )

        await model.load()
        let row = try XCTUnwrap(model.projectRows.first)
        XCTAssertFalse(model.isGateOpen(for: row))

        await model.setGateOpen(true, for: row).value

        XCTAssertFalse(model.isGateOpen(for: row))
        XCTAssertFalse(ContractPathGate.isOpen(for: project.id, in: defaults))
        XCTAssertNotNil(model.gateReport)
        // 기존 설치에서 명시적으로 켜 두었던 값의 표시·닫힘을 별도로 확인한다.
        ContractPathGate.setOpen(true, for: project.id, in: defaults)

        let restoredModel = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(projects: [project]),
            authenticationService: SyncSettingsAuthenticationStub(
                state: .signedOut(.noStoredSession)
            ),
            projectBindingService: SyncSettingsBindingStub(
                projects: [project],
                ownerSubject: UUID()
            ),
            defaults: defaults
        )
        await restoredModel.load()
        let restoredRow = try XCTUnwrap(restoredModel.projectRows.first)
        XCTAssertTrue(restoredModel.isGateOpen(for: restoredRow))

        await restoredModel.setGateOpen(false, for: restoredRow).value

        XCTAssertFalse(restoredModel.isGateOpen(for: restoredRow))
        XCTAssertNil(
            defaults.object(
                forKey: ContractPathGate.storageKey(for: project.id)
            )
        )
        XCTAssertEqual(restoredModel.gateReport, "관문 확인 관문: 닫힘")
    }
#endif

    func testSignUpConfirmationKeepsProtectedCloudRoutesLocked() async {
        let project = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000900",
            name: "확인 대기"
        )
        let auth = SyncSettingsAuthenticationStub(
            state: .signedOut(.noStoredSession),
            signUpResult: .confirmationRequired(
                maskedEmail: "n***@example.com"
            )
        )
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(
                projects: [project]
            ),
            authenticationService: auth,
            projectBindingService: SyncSettingsBindingStub(
                projects: [project],
                ownerSubject: UUID()
            ),
            defaults: makeDefaults()
        )

        await model.load()
        await model.signUp(
            email: "new@example.com",
            password: "safe-password"
        )

        XCTAssertFalse(model.isAuthenticated)
        XCTAssertEqual(
            model.informationMessage,
            "확인 이메일을 보냈습니다 (n***@example.com). 이메일을 확인한 뒤 로그인하세요."
        )
    }

    func testEnablingGlobalSyncConnectsOnlyUnboundProjects() async {
        let first = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000901",
            name: "이미 연결됨"
        )
        let second = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000902",
            name: "새로 연결"
        )
        let userID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000910"
        )!
        let existing = ProjectSyncBinding.connected(
            localProjectID: first.id,
            serverProjectID: first.id.rawValue,
            kind: .newServerProject,
            projectName: first.name,
            ownerSubject: userID
        )
        let auth = SyncSettingsAuthenticationStub(
            state: .authenticated(
                AuthenticatedAccount(userID: userID, maskedEmail: "t***@example.com")
            )
        )
        let bindings = SyncSettingsBindingStub(
            projects: [first, second],
            ownerSubject: userID,
            bindings: [first.id: existing]
        )
        let defaults = makeDefaults()
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(
                projects: [first, second]
            ),
            authenticationService: auth,
            projectBindingService: bindings,
            defaults: defaults
        )

        await model.load()
        await model.enableSyncForAllProjects()

        XCTAssertTrue(model.isSyncAllEnabled)
        XCTAssertTrue(
            defaults.bool(forKey: GlobalSyncPreference.storageKey)
        )
        let createdProjectIDs = await bindings.createdProjectIDs()
        XCTAssertEqual(createdProjectIDs, [second.id])
        XCTAssertTrue(model.projectRows.allSatisfy(\.isConnected))
    }

    func testDisablingGlobalSyncPreservesProjectBindings() async {
        let project = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000903",
            name: "연결 유지"
        )
        let userID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000911"
        )!
        let binding = ProjectSyncBinding.connected(
            localProjectID: project.id,
            serverProjectID: project.id.rawValue,
            kind: .newServerProject,
            projectName: project.name,
            ownerSubject: userID
        )
        let defaults = makeDefaults()
        GlobalSyncPreference.setEnabled(true, in: defaults)
        let bindings = SyncSettingsBindingStub(
            projects: [project],
            ownerSubject: userID,
            bindings: [project.id: binding]
        )
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(projects: [project]),
            authenticationService: SyncSettingsAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(
                        userID: userID,
                        maskedEmail: "t***@example.com"
                    )
                )
            ),
            projectBindingService: bindings,
            defaults: defaults
        )

        await model.load()
        await model.disableSyncForAllProjects()

        XCTAssertFalse(model.isSyncAllEnabled)
        XCTAssertFalse(
            defaults.bool(forKey: GlobalSyncPreference.storageKey)
        )
        let disconnectedProjectIDs = await bindings.disconnectedProjectIDs()
        XCTAssertEqual(disconnectedProjectIDs, [])
        XCTAssertTrue(model.projectRows.first?.isConnected == true)
    }

    func testExistingConnectionRejectsMismatchedConfirmationBeforeServiceCall()
        async {
        let project = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000904",
            name: "확인 필요"
        )
        let userID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000912"
        )!
        let bindings = SyncSettingsBindingStub(
            projects: [project],
            ownerSubject: userID
        )
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(projects: [project]),
            authenticationService: SyncSettingsAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(userID: userID, maskedEmail: nil)
                )
            ),
            projectBindingService: bindings,
            defaults: makeDefaults()
        )

        await model.load()
        await model.connectExistingServerProject(
            project.id,
            serverID: "00000000-0000-0000-0000-000000000920",
            confirmation: "00000000-0000-0000-0000-000000000921",
            isWindowsImport: false
        )

        XCTAssertEqual(
            model.errorMessage,
            "두 서버 작품 ID가 일치하지 않습니다."
        )
        let existingConnectionProjectIDs =
            await bindings.existingConnectionProjectIDs()
        XCTAssertEqual(existingConnectionProjectIDs, [])
    }

    func testLogoutKeepsBindingsAndOnlyChangesAuthenticationState() async {
        let project = makeManagedProject(
            id: "00000000-0000-0000-0000-000000000905",
            name: "로그아웃 후 유지"
        )
        let userID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000913"
        )!
        let binding = ProjectSyncBinding.connected(
            localProjectID: project.id,
            serverProjectID: project.id.rawValue,
            kind: .newServerProject,
            projectName: project.name,
            ownerSubject: userID
        )
        let defaults = makeDefaults()
        GlobalSyncPreference.setEnabled(true, in: defaults)
        let bindings = SyncSettingsBindingStub(
            projects: [project],
            ownerSubject: userID,
            bindings: [project.id: binding]
        )
        let model = SyncSettingsModel(
            projectLister: SyncSettingsProjectListerStub(projects: [project]),
            authenticationService: SyncSettingsAuthenticationStub(
                state: .authenticated(
                    AuthenticatedAccount(userID: userID, maskedEmail: nil)
                )
            ),
            projectBindingService: bindings,
            defaults: defaults
        )

        await model.load()
        await model.signOut()

        XCTAssertEqual(
            model.authenticationState,
            .signedOut(.userInitiated)
        )
        XCTAssertTrue(model.projectRows.first?.isConnected == true)
        XCTAssertTrue(model.isSyncAllEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SyncSettingsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeManagedProject(
        id: String,
        name: String
    ) -> ManagedProject {
        ManagedProject(
            project: Project(
                id: ProjectID(rawValue: UUID(uuidString: id)!),
                name: name,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            userOrder: 0,
            lifecycleState: .active
        )
    }
}

private actor SyncSettingsProjectListerStub: SyncProjectListing {
    let storedProjects: [ManagedProject]

    init(projects: [ManagedProject]) {
        storedProjects = projects
    }

    func projects() -> [ManagedProject] {
        storedProjects
    }
}

private actor SyncSettingsAuthenticationStub: AuthenticationServicing {
    private var state: AuthenticationState
    private let signUpResult: AuthenticationSignUpResult

    init(
        state: AuthenticationState,
        signUpResult: AuthenticationSignUpResult = .failed(.serverRejected)
    ) {
        self.state = state
        self.signUpResult = signUpResult
    }

    func currentState() -> AuthenticationState {
        state
    }

    func restoreSession() -> AuthenticationState {
        state
    }

    // 설정 화면용 더블은 refresh와 restore를 의도적으로 구분하지 않는다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return state
    }

    func signUp(
        email: String,
        password: String
    ) -> AuthenticationSignUpResult {
        _ = email
        _ = password
        if case let .authenticated(account) = signUpResult {
            state = .authenticated(account)
        }
        return signUpResult
    }

    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = email
        _ = password
        return state
    }

    func signOut() -> AuthenticationState {
        state = .signedOut(.userInitiated)
        return state
    }
}

private actor SyncSettingsBindingStub: ProjectBindingServicing {
    private let projectNames: [ProjectID: String]
    private let ownerSubject: UUID
    private var bindings: [ProjectID: ProjectSyncBinding]
    private var createdIDs: [ProjectID] = []
    private var disconnectedIDs: [ProjectID] = []
    private var existingIDs: [ProjectID] = []

    init(
        projects: [ManagedProject],
        ownerSubject: UUID,
        bindings: [ProjectID: ProjectSyncBinding] = [:]
    ) {
        projectNames = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.name) }
        )
        self.ownerSubject = ownerSubject
        self.bindings = bindings
    }

    func currentBinding(
        for localProjectID: ProjectID
    ) -> ProjectSyncBinding? {
        bindings[localProjectID]
    }

    func createServerProject(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        createdIDs.append(localProjectID)
        return connect(
            localProjectID,
            serverID: localProjectID.rawValue,
            kind: .newServerProject
        )
    }

    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        existingIDs.append(localProjectID)
        return connect(
            localProjectID,
            serverID: confirmation.value,
            kind: .existingServerProject
        )
    }

    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        existingIDs.append(localProjectID)
        return connect(
            localProjectID,
            serverID: confirmation.value,
            kind: .windowsImport
        )
    }

    func refreshServerName(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        guard let binding = bindings[localProjectID] else {
            return .failed(.notBound)
        }
        return .connected(binding)
    }

    func disconnect(
        localProjectID: ProjectID
    ) -> ProjectBindingResult {
        disconnectedIDs.append(localProjectID)
        let localOnly = ProjectSyncBinding.localOnly(
            projectID: localProjectID,
            name: projectNames[localProjectID] ?? "작품"
        )
        bindings[localProjectID] = localOnly
        return .disconnected(localOnly)
    }

    func createdProjectIDs() -> [ProjectID] {
        createdIDs
    }

    func disconnectedProjectIDs() -> [ProjectID] {
        disconnectedIDs
    }

    func existingConnectionProjectIDs() -> [ProjectID] {
        existingIDs
    }

    private func connect(
        _ localProjectID: ProjectID,
        serverID: UUID,
        kind: ProjectBindingKind
    ) -> ProjectBindingResult {
        let binding = ProjectSyncBinding.connected(
            localProjectID: localProjectID,
            serverProjectID: serverID,
            kind: kind,
            projectName: projectNames[localProjectID] ?? "작품",
            ownerSubject: ownerSubject
        )
        bindings[localProjectID] = binding
        return .connected(binding)
    }
}
