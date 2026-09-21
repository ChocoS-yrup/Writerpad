import XCTest
import Foundation
import Supabase
@testable import WriterPad

/// 핸드셰이크가 "서버가 뭐라 했는가"와 "우리가 계약 경로를 써도 되는가"를 끝까지
/// 갈라 두는지 본다. 둘이 붙는 순간, 서버가 답 하나로 우리 쓰기 경로를 바꿀 수
/// 있게 된다.
@MainActor
final class SyncV2HandshakeTests: XCTestCase {

    // MARK: - 도구

    private actor StubTransport: SyncV2HandshakeTransporting {
        private var results: [Result<SyncV2HandshakeResponse, Error>]
        private(set) var receivedParameters: [SyncV2HandshakeParameters] = []
        private let delay: Duration?

        init(
            results: [Result<SyncV2HandshakeResponse, Error>],
            delay: Duration? = nil
        ) {
            self.results = results
            self.delay = delay
        }

        var callCount: Int { receivedParameters.count }

        func fetchHandshake(
            parameters: SyncV2HandshakeParameters
        ) async throws -> SyncV2HandshakeResponse {
            receivedParameters.append(parameters)
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !results.isEmpty else {
                throw SyncV2HandshakeTransportError.serverRejected
            }
            return try results.removeFirst().get()
        }
    }

    /// 스테이징이 실제로 돌려준 모양 그대로다.
    private func supportedResponse(
        projectID: UUID,
        mode: SyncV2ProjectSyncMode = .legacy,
        epoch: Int = 0,
        contractVersion: String? = SyncV2Contract.version,
        canonicalDigest: String? = SyncV2Contract.canonicalSHA256,
        serverDigest: String? = SyncV2Contract.canonicalSHA256,
        serverProtocolVersion: Int? = SyncV2Contract.syncProtocolVersion,
        supportedProtocolVersions: [Int] = [SyncV2Contract.syncProtocolVersion],
        capabilities: [String]? = nil
    ) -> SyncV2HandshakeResponse {
        SyncV2HandshakeResponse(
            supported: true,
            projectID: projectID,
            projectSyncMode: mode,
            migrationEpoch: epoch,
            contractVersion: contractVersion,
            canonicalContractSHA256: canonicalDigest,
            serverContractSHA256: serverDigest,
            serverProtocolVersion: serverProtocolVersion,
            supportedProtocolVersions: supportedProtocolVersions,
            serverCapabilities: capabilities
                ?? SyncV2Contract.requiredServerCapabilities.sorted()
        )
    }

    private func context(
        localProjectID: ProjectID = ProjectID(rawValue: UUID()),
        serverProjectID: UUID,
        accountID: UUID = UUID()
    ) -> SyncV2HandshakeContext {
        SyncV2HandshakeContext(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: accountID
        )
    }

    // MARK: - 요청

    func testRequestCarriesProjectAndCanonicalDigest() async throws {
        let serverProjectID = UUID()
        let transport = StubTransport(
            results: [.success(supportedResponse(projectID: serverProjectID))]
        )
        let service = SyncV2HandshakeService(transport: transport)

        _ = try await service.refresh(
            context: context(serverProjectID: serverProjectID)
        )

        let parameters = await transport.receivedParameters
        XCTAssertEqual(parameters.count, 1)
        XCTAssertEqual(parameters.first?.projectID, serverProjectID)
        XCTAssertEqual(
            parameters.first?.contractSHA256,
            SyncV2Contract.canonicalSHA256
        )
    }

    func testParametersEncodeToContractArgumentNames() throws {
        let data = try JSONEncoder().encode(
            SyncV2HandshakeParameters(
                projectID: UUID(uuidString: "01c1b72f-34fb-4fd4-abec-cbe49bb1b3a2")!,
                contractSHA256: SyncV2Contract.canonicalSHA256
            )
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), ["p_project_id", "p_contract_sha256"])
    }

    func testResponseDecodesContractFieldNames() throws {
        let json = """
        {"supported":true,"project_id":"01c1b72f-34fb-4fd4-abec-cbe49bb1b3a2",
         "migration_epoch":0,"contract_version":"0.2.0","project_sync_mode":"LEGACY",
         "server_capabilities":["atomic_structure_commit"],
         "server_contract_sha256":"\(SyncV2Contract.canonicalSHA256)",
         "server_protocol_version":3,
         "canonical_contract_sha256":"\(SyncV2Contract.canonicalSHA256)",
         "supported_protocol_versions":[3]}
        """
        let response = try JSONDecoder().decode(
            SyncV2HandshakeResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.serverProtocolVersion, 3)
        XCTAssertEqual(response.projectSyncMode, .legacy)
        XCTAssertEqual(response.serverContractSHA256, SyncV2Contract.canonicalSHA256)
    }

    // MARK: - 응답 검증

    func testServerProtocolVersionComesFromTheServerNotFromUs() async throws {
        // 서버가 4를 쓴다고 답하면 저장되는 값도 4여야 한다. 로컬 상수 3을 대신
        // 넣으면 저장된 값이 서버 말인 척하는 우리 말이 된다.
        let serverProjectID = UUID()
        let transport = StubTransport(results: [
            .success(supportedResponse(
                projectID: serverProjectID,
                serverProtocolVersion: 4,
                supportedProtocolVersions: [3, 4]
            ))
        ])
        let service = SyncV2HandshakeService(transport: transport)

        let handshake = try await service.refresh(
            context: context(serverProjectID: serverProjectID)
        )

        XCTAssertEqual(handshake.serverProtocolVersion, 4)
        XCTAssertNotEqual(
            handshake.serverProtocolVersion,
            SyncV2Contract.syncProtocolVersion
        )
    }

    func testUnsupportedProjectIsNotUsable() async {
        let serverProjectID = UUID()
        var response = supportedResponse(projectID: serverProjectID)
        response = SyncV2HandshakeResponse(
            supported: false,
            projectID: serverProjectID,
            projectSyncMode: .legacy,
            migrationEpoch: 0,
            contractVersion: nil,
            canonicalContractSHA256: nil,
            serverContractSHA256: nil,
            serverProtocolVersion: nil,
            supportedProtocolVersions: [],
            serverCapabilities: []
        )
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [.success(response)])
        )
        let ctx = context(serverProjectID: serverProjectID)

        await assertThrows(.contractUnavailable) {
            _ = try await service.refresh(context: ctx)
        }
        let standing = await service.standingHandshake(for: ctx)
        XCTAssertNil(standing)
    }

    func testAnswerAboutAnotherProjectIsRejected() async {
        let asked = UUID()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: UUID()))
            ])
        )

        await assertThrows(.invalidResponse) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: asked)
            )
        }
    }

    func testDigestMismatchIsIncompatibleNotMalformed() async {
        let serverProjectID = UUID()
        let other = String(repeating: "a", count: 64)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    canonicalDigest: other,
                    serverDigest: other
                ))
            ])
        )

        await assertThrows(.incompatible(.contractDigestMismatch)) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    func testMissingCapabilityIsIncompatible() async {
        let serverProjectID = UUID()
        var capabilities = SyncV2Contract.requiredServerCapabilities.sorted()
        capabilities.removeLast()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    capabilities: capabilities
                ))
            ])
        )

        await assertThrows(.incompatible(.capabilityMismatch)) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    func testInvalidModeEpochPairIsRejected() async {
        let serverProjectID = UUID()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    mode: .idBased,
                    epoch: 0
                ))
            ])
        )

        await assertThrows(.incompatible(.staleMigrationEpoch)) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    /// protocol 번호의 네 갈래를 Windows와 같은 자리에서 갈라 놓는다.
    ///
    /// `server_protocol_version`은 천장일 뿐이라 `>=` 검사 하나로는 두 번째 줄이
    /// 새어 나간다. 3을 내리고 4로 답하는 서버는 `4 >= 3`을 통과하면서 우리가 할 수
    /// 있는 말은 전부 거절한다.
    func testProtocolVersionDecisionTable() async throws {
        let cases: [(Int, [Int], SyncV2HandshakeError?)] = [
            (4, [3, 4], nil),
            (4, [4], .incompatible(.protocolTooOld)),
            (2, [2], .incompatible(.protocolTooOld)),
            (4, [3], .invalidResponse),
        ]
        for (version, supported, expected) in cases {
            let serverProjectID = UUID()
            let service = SyncV2HandshakeService(
                transport: StubTransport(results: [
                    .success(supportedResponse(
                        projectID: serverProjectID,
                        serverProtocolVersion: version,
                        supportedProtocolVersions: supported
                    ))
                ])
            )
            let ctx = context(serverProjectID: serverProjectID)
            let label = "server=\(version) supported=\(supported)"

            if let expected {
                await assertThrows(expected) {
                    _ = try await service.refresh(context: ctx)
                }
                let standing = await service.standingHandshake(for: ctx)
                XCTAssertNil(standing, "\(label): 거절했는데 답이 남았다")
            } else {
                let handshake = try await service.refresh(context: ctx)
                XCTAssertEqual(
                    handshake.serverProtocolVersion,
                    version,
                    "\(label): 서버가 말한 번호가 저장되어야 한다"
                )
            }
        }
    }

    // MARK: - 자기모순 응답

    func testProtocolVersionOutsideSupportedListIsMalformed() async {
        let serverProjectID = UUID()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    serverProtocolVersion: 4,
                    supportedProtocolVersions: [3]
                ))
            ])
        )

        await assertThrows(.invalidResponse) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    func testDisagreeingDigestsAreMalformed() async {
        let serverProjectID = UUID()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    canonicalDigest: SyncV2Contract.canonicalSHA256,
                    serverDigest: String(repeating: "b", count: 64)
                ))
            ])
        )

        await assertThrows(.invalidResponse) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    func testSupportedAnswerMissingItsOwnFieldsIsMalformed() async {
        let serverProjectID = UUID()
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    serverProtocolVersion: nil
                ))
            ])
        )

        await assertThrows(.invalidResponse) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    func testDuplicateCapabilitiesAreMalformed() async {
        let serverProjectID = UUID()
        var capabilities = SyncV2Contract.requiredServerCapabilities.sorted()
        capabilities.append(capabilities[0])
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(
                    projectID: serverProjectID,
                    capabilities: capabilities
                ))
            ])
        )

        await assertThrows(.invalidResponse) {
            _ = try await service.refresh(
                context: self.context(serverProjectID: serverProjectID)
            )
        }
    }

    // MARK: - 신원

    func testUnknownIdentityCannotArm() async {
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: UUID()))
            ])
        )

        await assertThrows(.identityUnknown) {
            _ = try await service.refresh(context: nil)
        }
        let standing = await service.standingHandshake(for: nil)
        XCTAssertNil(standing)
    }

    func testContextIsNilUnlessAuthenticated() {
        let localProjectID = ProjectID(rawValue: UUID())
        let serverProjectID = UUID()
        let unauthenticated: [AuthenticationState] = [
            .localOnly,
            .restoring,
            .signedOut(.userInitiated),
            .signedOut(.sessionExpired),
        ]
        for state in unauthenticated {
            XCTAssertNil(
                SyncV2HandshakeContext.make(
                    authenticationState: state,
                    localProjectID: localProjectID,
                    serverProjectID: serverProjectID
                ),
                "\(state)에서 문맥이 만들어지면 안 된다"
            )
        }

        let account = AuthenticatedAccount(userID: UUID(), maskedEmail: nil)
        let made = SyncV2HandshakeContext.make(
            authenticationState: .authenticated(account),
            localProjectID: localProjectID,
            serverProjectID: serverProjectID
        )
        XCTAssertEqual(made?.accountID, account.userID)
    }

    // MARK: - 캐시 결합

    func testStandingAnswerDoesNotCrossAccounts() async throws {
        let serverProjectID = UUID()
        let localProjectID = ProjectID(rawValue: UUID())
        let first = context(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: UUID()
        )
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(context: first)
        var standing = await service.standingHandshake(for: first)
        XCTAssertNotNil(standing)

        let second = SyncV2HandshakeContext(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: UUID()
        )
        standing = await service.standingHandshake(for: second)
        XCTAssertNil(standing, "계정이 다르면 앞 계정의 답이 서면 안 된다")
    }

    func testStandingAnswerDoesNotCrossProjects() async throws {
        let serverProjectID = UUID()
        let accountID = UUID()
        let first = context(
            serverProjectID: serverProjectID,
            accountID: accountID
        )
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(context: first)

        let second = SyncV2HandshakeContext(
            localProjectID: ProjectID(rawValue: UUID()),
            serverProjectID: serverProjectID,
            accountID: accountID
        )
        let standing = await service.standingHandshake(for: second)
        XCTAssertNil(standing)
    }

    func testStandingAnswerDoesNotCrossClientDigests() async throws {
        let serverProjectID = UUID()
        let accountID = UUID()
        let localProjectID = ProjectID(rawValue: UUID())
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(
            context: context(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                accountID: accountID
            )
        )

        let otherDigest = SyncV2HandshakeContext(
            localProjectID: localProjectID,
            serverProjectID: serverProjectID,
            accountID: accountID,
            clientContractSHA256: String(repeating: "c", count: 64)
        )
        let standing = await service.standingHandshake(for: otherDigest)
        XCTAssertNil(standing)
    }

    func testAnswerNeverSurvivesARestart() async throws {
        // 저장소를 쓰지 않는다는 것을 새 인스턴스로 확인한다. 재시작은 곧 모름이다.
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(context: ctx)
        let beforeRestart = await service.standingHandshake(for: ctx)
        XCTAssertNotNil(beforeRestart)

        let restarted = SyncV2HandshakeService(
            transport: StubTransport(results: [])
        )
        let standing = await restarted.standingHandshake(for: ctx)
        XCTAssertNil(standing)
    }

    // MARK: - 무효화

    func testEachInvalidationDropsTheStandingAnswer() async throws {
        let drops: [(String, @Sendable (SyncV2HandshakeService) async -> Void)] = [
            ("projectChanged", { await $0.projectChanged() }),
            ("authenticationChanged", { await $0.authenticationChanged() }),
            ("gateClosed", { await $0.gateClosed() }),
            ("forgetIfStale", { await $0.forgetIfStale(.forbidden) }),
        ]
        for (name, drop) in drops {
            let serverProjectID = UUID()
            let ctx = context(serverProjectID: serverProjectID)
            let service = SyncV2HandshakeService(
                transport: StubTransport(results: [
                    .success(supportedResponse(projectID: serverProjectID))
                ])
            )
            _ = try await service.refresh(context: ctx)
            let armed = await service.standingHandshake(for: ctx)
            XCTAssertNotNil(armed, "\(name): 준비 상태가 서 있어야 한다")

            await drop(service)

            let afterDrop = await service.standingHandshake(for: ctx)
            XCTAssertNil(afterDrop, "\(name)이 답을 버리지 않았다")
        }
    }

    func testRecoverableErrorsKeepNothingButDoNotPretendToSucceed() async throws {
        // 네트워크 실패는 무효화 사유가 아니지만, 조회 전에 이미 버렸으므로
        // 실패 뒤에 쓸 수 있는 값이 남아서도 안 된다.
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID)),
                .failure(SyncV2HandshakeTransportError.networkUnavailable),
            ])
        )
        _ = try await service.refresh(context: ctx)
        let armed = await service.standingHandshake(for: ctx)
        XCTAssertNotNil(armed)

        await assertThrows(.networkUnavailable) {
            _ = try await service.refresh(context: ctx)
        }
        let afterFailure = await service.standingHandshake(for: ctx)
        XCTAssertNil(afterFailure)
    }

    func testLateAnswerFromAnEarlierGenerationIsDiscarded() async throws {
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let transport = StubTransport(
            results: [.success(supportedResponse(projectID: serverProjectID))],
            delay: .milliseconds(120)
        )
        let service = SyncV2HandshakeService(transport: transport)

        async let pending: Void = {
            do {
                _ = try await service.refresh(context: ctx)
                XCTFail("무효화 뒤에 도착한 답이 받아들여졌다")
            } catch {}
        }()

        try await Task.sleep(for: .milliseconds(30))
        await service.authenticationChanged()
        await pending

        let standing = await service.standingHandshake(for: ctx)
        XCTAssertNil(standing)
    }

    func testConcurrentAsksReachTheServerOnce() async throws {
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let transport = StubTransport(
            results: [.success(supportedResponse(projectID: serverProjectID))],
            delay: .milliseconds(60)
        )
        let service = SyncV2HandshakeService(transport: transport)

        async let first = service.refresh(context: ctx)
        try await Task.sleep(for: .milliseconds(10))
        async let second = service.refresh(context: ctx)
        _ = try await (first, second)

        let calls = await transport.callCount
        XCTAssertEqual(calls, 1, "같은 세대에 서버로 두 번 나갔다")
    }

    // MARK: - 관문

    func testGateIsClosedUntilItIsOpened() {
        let defaults = makeDefaults()
        let localProjectID = ProjectID(rawValue: UUID())

        XCTAssertFalse(ContractPathGate.isOpen(for: localProjectID, in: defaults))

        ContractPathGate.setOpen(true, for: localProjectID, in: defaults)
        XCTAssertTrue(ContractPathGate.isOpen(for: localProjectID, in: defaults))

        ContractPathGate.close(for: localProjectID, in: defaults)
        XCTAssertFalse(ContractPathGate.isOpen(for: localProjectID, in: defaults))
    }

    func testGateIsPerProject() {
        let defaults = makeDefaults()
        let opened = ProjectID(rawValue: UUID())
        let other = ProjectID(rawValue: UUID())

        ContractPathGate.setOpen(true, for: opened, in: defaults)

        XCTAssertTrue(ContractPathGate.isOpen(for: opened, in: defaults))
        XCTAssertFalse(ContractPathGate.isOpen(for: other, in: defaults))
    }

    func testSuccessfulHandshakeAloneDoesNotOpenTheContractPath() async throws {
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(context: ctx)

        let uses = await service.usesContractStructure(
            context: ctx,
            gateIsOpen: false
        )
        XCTAssertFalse(uses, "서버 답만으로 계약 경로가 열렸다")
    }

    func testOpenGateAloneDoesNotOpenTheContractPath() async {
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [])
        )
        let uses = await service.usesContractStructure(
            context: context(serverProjectID: UUID()),
            gateIsOpen: true
        )
        XCTAssertFalse(uses, "서 있는 답 없이 계약 경로가 열렸다")
    }

    func testContractPathNeedsGateAndStandingAnswerTogether() async throws {
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        _ = try await service.refresh(context: ctx)

        var uses = await service.usesContractStructure(
            context: ctx,
            gateIsOpen: true
        )
        XCTAssertTrue(uses)

        await service.gateClosed()
        uses = await service.usesContractStructure(context: ctx, gateIsOpen: true)
        XCTAssertFalse(uses, "관문을 닫은 뒤에도 답이 서 있었다")
    }

    /// 다리가 셋이라는 것을 셋째까지 확인한다.
    ///
    /// 셋째는 들고 있는 서버 상태를 쓸 때마다 다시 검사하는 것이다. 이 설계에서는
    /// 답이 메모리에 있고 잡은 뒤로 바뀌지 않아 부정 경로를 밖에서 만들 수 없다.
    /// 그래서 여기서는 통과한 답이 재검사도 통과한다는 것까지만 못 박는다.
    func testStandingAnswerIsRevalidatedOnEveryUse() async throws {
        let serverProjectID = UUID()
        let ctx = context(serverProjectID: serverProjectID)
        let service = SyncV2HandshakeService(
            transport: StubTransport(results: [
                .success(supportedResponse(projectID: serverProjectID))
            ])
        )
        let handshake = try await service.refresh(context: ctx)

        XCTAssertNoThrow(
            try SyncV2Contract.requireServerCompatibility(
                projectSyncMode: handshake.projectSyncMode,
                migrationEpoch: handshake.migrationEpoch,
                serverProtocolVersion: handshake.serverProtocolVersion,
                serverContractSHA256: handshake.contractSHA256,
                serverCapabilities: handshake.serverCapabilities
            )
        )
        let uses = await service.usesContractStructure(
            context: ctx,
            gateIsOpen: true
        )
        XCTAssertTrue(uses)
    }

    // MARK: - 보조

    private func makeDefaults(
        function: String = #function
    ) -> UserDefaults {
        let name = "SyncV2HandshakeTests.\(function)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func assertThrows(
        _ expected: SyncV2HandshakeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("\(expected)를 기대했는데 성공했다", file: file, line: line)
        } catch let error as SyncV2HandshakeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("예상 못 한 오류 \(error)", file: file, line: line)
        }
    }
}

extension SyncV2HandshakeTests {
    private actor ControlledTransport: SyncV2HandshakeTransporting {
        private var waiters: [CheckedContinuation<SyncV2HandshakeResponse, Error>] = []
        private(set) var count = 0
        func fetchHandshake(parameters: SyncV2HandshakeParameters) async throws -> SyncV2HandshakeResponse {
            count += 1
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }
        func finish(_ result: Result<SyncV2HandshakeResponse, Error>) {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume(with: result)
        }
    }

    private actor LifecycleAuth: AuthenticationServicing {
        nonisolated let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
        var state: AuthenticationState
        var observers: [AsyncStream<AuthenticationState>.Continuation] = []
        init(account: UUID) { state = .authenticated(.init(userID: account, maskedEmail: nil)) }
        func currentState() -> AuthenticationState { state }
        func stateUpdates() -> AsyncStream<AuthenticationState> {
            AsyncStream { observers.append($0) }
        }
        func relogin() { contractEpoch?.advance(); observers.forEach { $0.yield(state) } }
        func restoreSession() -> AuthenticationState { state }
        func refreshSession(force: Bool) -> AuthenticationState { state }
        func signIn(email: String, password: String) -> AuthenticationState { relogin(); return state }
        func signOut() -> AuthenticationState {
            contractEpoch?.advance(); state = .signedOut(.userInitiated)
            observers.forEach { $0.yield(state) }; return state
        }
    }

    private actor LifecycleBindings: ProjectBindingServicing {
        nonisolated let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
        let bindings: [ProjectID: ProjectSyncBinding]
        init(_ bindings: [ProjectSyncBinding]) { self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.localProjectID, $0) }) }
        func currentBinding(for id: ProjectID) -> ProjectSyncBinding? { bindings[id] }
        func createServerProject(for id: ProjectID) -> ProjectBindingResult { .failed(.serverRejected) }
        func connectExistingProject(localProjectID: ProjectID, confirmation: ConfirmedServerProjectID) -> ProjectBindingResult { .failed(.serverRejected) }
        func connectWindowsProject(localProjectID: ProjectID, confirmation: ConfirmedServerProjectID) -> ProjectBindingResult { .failed(.serverRejected) }
        func refreshServerName(for id: ProjectID) -> ProjectBindingResult { .failed(.serverRejected) }
        func disconnect(localProjectID: ProjectID) -> ProjectBindingResult { .failed(.serverRejected) }
    }

    private func eventually(_ condition: @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("비동기 조건이 완료되지 않았습니다", file: file, line: line)
    }

    func testWrongContractVersionIsRejectedEvenWithCorrectDigest() async {
        let id = UUID()
        let service = SyncV2HandshakeService(transport: StubTransport(results: [
            .success(supportedResponse(projectID: id, contractVersion: "0.3.0"))
        ]))
        await assertThrows(.incompatible(.contractDigestMismatch)) {
            _ = try await service.refresh(context: context(serverProjectID: id))
        }
    }

    func testCoalescedLateFailureCannotSurviveInvalidationOrFreePhysicalSlot() async throws {
        let transport = ControlledTransport()
        let service = SyncV2HandshakeService(transport: transport)
        let ctx = context(serverProjectID: UUID())
        let first = Task { try await service.refresh(context: ctx) }
        await eventually { await transport.count == 1 }
        let joined = Task { try await service.refresh(context: ctx) }
        try await Task.sleep(for: .milliseconds(20))
        await service.authenticationChanged()
        await assertThrows(.superseded) { _ = try await service.refresh(context: ctx) }
        let count = await transport.count
        XCTAssertEqual(count, 1)
        await transport.finish(.failure(SyncV2HandshakeTransportError.forbidden))
        await assertThrows(.superseded) { _ = try await first.value }
        await assertThrows(.superseded) { _ = try await joined.value }
        let fresh = await service.isFresh(for: ctx)
        XCTAssertFalse(fresh)
    }

    func testTimeoutDoesNotReleasePhysicalSlotAndLateSuccessIsDiscarded() async {
        let transport = ControlledTransport()
        let service = SyncV2HandshakeService(transport: transport, timeout: .milliseconds(30))
        let ctx = context(serverProjectID: UUID())
        await assertThrows(.timedOut) { _ = try await service.refresh(context: ctx) }
        await service.projectChanged()
        await assertThrows(.superseded) { _ = try await service.refresh(context: ctx) }
        let count = await transport.count
        XCTAssertEqual(count, 1)
        await transport.finish(.success(supportedResponse(projectID: ctx.serverProjectID)))
        try? await Task.sleep(for: .milliseconds(20))
        let fresh = await service.isFresh(for: ctx)
        XCTAssertFalse(fresh)
    }

    func testAutomaticRetryRecoversSameProjectWithoutOpeningGate() async throws {
        let id = UUID(), account = UUID(), localID = ProjectID(rawValue: UUID())
        let auth = LifecycleAuth(account: account)
        let bindings = LifecycleBindings([.connected(localProjectID: localID, serverProjectID: id,
            kind: .existingServerProject, projectName: "회귀 시험", ownerSubject: account)])
        let transport = StubTransport(results: [.failure(SyncV2HandshakeTransportError.networkUnavailable),
                                                .success(supportedResponse(projectID: id))])
        let service = SyncV2HandshakeService(transport: transport, timeout: .seconds(120), sleep: { delay in
            try await Task.sleep(for: delay == .seconds(120) ? delay : .milliseconds(5))
        })
        let defaults = makeDefaults()
        await service.observeProject(localID, authentication: auth, bindings: bindings)
        let ctx = SyncV2HandshakeContext(localProjectID: localID, serverProjectID: id, accountID: account)
        await eventually { await service.isFresh(for: ctx) }
        let count = await transport.callCount
        XCTAssertEqual(count, 2)
        XCTAssertFalse(ContractPathGate.isOpen(for: localID, in: defaults))
        await service.networkRecovered()
        try await Task.sleep(for: .milliseconds(30))
        let afterRecovery = await transport.callCount
        XCTAssertEqual(afterRecovery, 2, "유효한 답을 네트워크 사건만으로 다시 조회하지 않는다")
        await service.stopObserving()
    }

    func testSameAccountReloginAndAToBToASelectFreshGenerations() async throws {
        let a = UUID(), b = UUID(), account = UUID()
        let localA = ProjectID(rawValue: UUID()), localB = ProjectID(rawValue: UUID())
        let auth = LifecycleAuth(account: account)
        let bindings = LifecycleBindings([
            .connected(localProjectID: localA, serverProjectID: a, kind: .existingServerProject, projectName: "A", ownerSubject: account),
            .connected(localProjectID: localB, serverProjectID: b, kind: .existingServerProject, projectName: "B", ownerSubject: account)
        ])
        let transport = StubTransport(results: [a, a, b, a].map { .success(supportedResponse(projectID: $0)) })
        let service = SyncV2HandshakeService(transport: transport)
        let contextA0 = SyncV2HandshakeContext(localProjectID: localA, serverProjectID: a, accountID: account, authenticationEpoch: 0)
        let contextA1 = SyncV2HandshakeContext(localProjectID: localA, serverProjectID: a, accountID: account, authenticationEpoch: 1)
        let contextB1 = SyncV2HandshakeContext(localProjectID: localB, serverProjectID: b, accountID: account, authenticationEpoch: 1)
        await service.observeProject(localA, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: contextA0) }
        await auth.relogin()
        await eventually { await service.isFresh(for: contextA1) }
        await service.observeProject(localB, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: contextB1) }
        await service.observeProject(localA, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: contextA1) }
        let count = await transport.callCount
        XCTAssertEqual(count, 4)
        await service.stopObserving()
    }

    func testTerminalHandshakeFailureDoesNotRetryOnNetworkEvents() async throws {
        let id = UUID(), account = UUID(), local = ProjectID(rawValue: UUID())
        let auth = LifecycleAuth(account: account)
        let bindings = LifecycleBindings([.connected(localProjectID: local, serverProjectID: id,
            kind: .existingServerProject, projectName: "시험", ownerSubject: account)])
        let transport = StubTransport(results: [.failure(SyncV2HandshakeTransportError.forbidden)])
        let service = SyncV2HandshakeService(transport: transport)
        await service.observeProject(local, authentication: auth, bindings: bindings)
        await eventually { await transport.callCount == 1 }
        try await Task.sleep(for: .milliseconds(30))
        await service.networkRecovered()
        try await Task.sleep(for: .milliseconds(30))
        let count = await transport.callCount
        XCTAssertEqual(count, 1)
        await service.stopObserving()
    }

    func testRetryBackoffIsCappedAndEpochsArePartOfContext() {
        XCTAssertEqual((0..<9).map(SyncV2HandshakeService.retryDelay), [2,4,8,16,32,60,60,60,60].map { .seconds($0) })
        let a = context(serverProjectID: UUID())
        let b = SyncV2HandshakeContext(localProjectID: a.localProjectID, serverProjectID: a.serverProjectID,
            accountID: a.accountID, authenticationEpoch: 1)
        XCTAssertNotEqual(a, b)
    }
}

extension SyncV2HandshakeTests {
    private actor ContractQueueStub: SyncV2ContractQueue, SyncV2GeneralConflictStoring, SyncV2GeneralRecoveryReading, SyncV2GeneralStructureStoring {
        func replaceGeneralStructureConflict(_ review: SyncV2GeneralStructureReview, adoptServer: Bool,
            authorize: @escaping @Sendable () throws -> Void) async throws -> UUID {
            try authorize(); resolutionCount += 1; completed = true
            return UUID()
        }
        func replaceGeneralRenameConflict(_ review: SyncV2GeneralRenameConflictReview,
            authorize: @escaping @Sendable () throws -> Void) async throws -> UUID {
            try authorize(); resolutionCount += 1; completed = true
            return UUID()
        }
        func replaceGeneralOrderConflict(_ review: SyncV2GeneralOrderConflictReview,
            authorize: @escaping @Sendable () throws -> Void) async throws -> UUID {
            try authorize(); resolutionCount += 1; completed = true
            return UUID()
        }
        var conflictLocal: SyncV2GeneralConflictLocal?
        private(set) var resolutionCount = 0
        private(set) var lastResolutionReview: SyncV2GeneralConflictReview?
        func setConflictLocal(_ value: SyncV2GeneralConflictLocal) { conflictLocal = value }
        func generalConflictLocal(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralConflictLocal {
            guard let conflictLocal, !completed else { throw SyncV2GeneralConflictError.changed }
            return conflictLocal
        }
        func replaceGeneralConflict(_ review: SyncV2GeneralConflictReview,
            authorize: @escaping @Sendable () throws -> Void) async throws -> UUID {
            try authorize(); lastResolutionReview = review; resolutionCount += 1; completed = true
            return UUID()
        }
        func generalRecoveryPage(localProjectID: ProjectID, after queueID: Int64?) async throws -> SyncV2GeneralRecoveryPage {
            .init(rows: conflictLocal.map { [$0.detail.row] } ?? [], nextCursor: nil)
        }
        func generalRecoveryDetail(localProjectID: ProjectID, batchID: UUID) async throws -> SyncV2GeneralRecoveryDetail {
            guard let conflictLocal else { throw SyncV2GeneralConflictError.unavailable }
            return conflictLocal.detail
        }
        var recoveryEligible = false
        private(set) var recoveryCount = 0
        func setRecoveryEligible() { recoveryEligible = true }
        func recoverableGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch? {
            recoveryEligible && !completed ? pending : nil
        }
        func recoverGeneralContract(_ pending: SyncV2PendingContractBatch, receipt: SyncV2GeneralCommitReceipt,
            accountID: UUID, authorize: @escaping @Sendable () throws -> Void) async throws {
            _ = try receipt.validatedResponse(for: pending, accountID: accountID)
            try authorize(); recoveryCount += 1; completed = true
        }
        var resumeBaseline: SyncV2PreparationSnapshot?
        func setResumeBaseline(_ value: SyncV2PreparationSnapshot) { resumeBaseline = value }
        func generalResumeBaseline(localProjectID: ProjectID) async throws -> SyncV2PreparationSnapshot {
            guard let resumeBaseline else { throw SyncV2ContractStructureError.unavailable }
            return resumeBaseline
        }
        let savedBinding: ProjectSyncBinding
        let pending: SyncV2PendingContractBatch
        var beforeClaim: (@Sendable () async -> Void)?
        private(set) var completed = false
        private(set) var generalClaims = 0
        func hasReadyGeneralContract(localProjectID: ProjectID) async throws -> Bool { !completed && conflictLocal == nil }
        func claimNextGeneralContract(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch {
            generalClaims += 1
            return try await claimNextContractStructure(localProjectID: localProjectID)
        }
        private(set) var failures: [SyncV2ContractStructureError] = []
        init(binding: ProjectSyncBinding, request: SyncV2ContractRequest) {
            savedBinding = binding
            pending = .init(localProjectID: binding.localProjectID, serverProjectID: binding.serverProjectID!, request: request)
        }
        func setBeforeClaim(_ hook: @escaping @Sendable () async -> Void) { beforeClaim = hook }
        func binding(for projectID: ProjectID) -> ProjectSyncBinding? { savedBinding }
        func contractQueueAuthorization(localProjectID: ProjectID) -> @Sendable () throws -> Void { {} }
        func uploadQueueSnapshot(localProjectID: ProjectID) -> SyncV2UploadQueueSnapshot { .init(pendingCount: completed ? 0 : 1) }
        func claimNextContractStructure(localProjectID: ProjectID) async throws -> SyncV2PendingContractBatch {
            if completed { throw SyncV2ContractStructureError.noReadyBatch }
            await beforeClaim?()
            return pending
        }
        func completeContractStructure(_ pending: SyncV2PendingContractBatch, response: SyncV2JSON) { completed = true }
        func failContractStructure(_ pending: SyncV2PendingContractBatch, error: Error, response: SyncV2JSON?) {
            if let error = error as? SyncV2ContractStructureError { failures.append(error) }
        }
    }

    private actor ContractTransportStub: SyncV2AtomicStructureTransporting {
        var conflictDocument: SyncV2JSON?
        var conflictDocuments: [UUID: SyncV2JSON] = [:]
        var conflictDocumentReads = 0
        var beforeConflictDocumentRead: (@Sendable (Int) async -> Void)?
        func setConflictDocuments(_ values: [UUID: SyncV2JSON]) { conflictDocuments = values }
        func setBeforeConflictDocumentRead(_ action: @escaping @Sendable (Int) async -> Void) { beforeConflictDocumentRead = action }
        func setConflictDocument(_ value: SyncV2JSON) { conflictDocument = value }
        func fetchGeneralConflictDocument(projectID: UUID, documentID: UUID) async throws -> SyncV2JSON {
            conflictDocumentReads += 1
            await beforeConflictDocumentRead?(conflictDocumentReads)
            if let value = conflictDocuments[documentID] { return value }
            guard let conflictDocument else { throw SyncV2GeneralConflictError.unavailable }
            return conflictDocument
        }
        var receipt: SyncV2GeneralCommitReceipt?
        var receiptReadFails = false
        func failReceiptRead() { receiptReadFails = true }
        private(set) var receiptReads = 0
        var beforeReceipt: (@Sendable () async -> Void)?
        func configureReceipt(_ value: SyncV2GeneralCommitReceipt?, before: (@Sendable () async -> Void)? = nil) {
            receipt = value; beforeReceipt = before
        }
        func fetchGeneralReceipt(projectID: UUID, batchID: UUID) async throws -> SyncV2GeneralCommitReceipt? {
            receiptReads += 1; await beforeReceipt?()
            if receiptReadFails { throw SyncV2HandshakeError.networkUnavailable }
            return receipt
        }
        private(set) var generalReads = 0
        var beforeGeneralRead: (@Sendable (Int) async -> Void)?
        func setBeforeGeneralRead(_ hook: @escaping @Sendable (Int) async -> Void) { beforeGeneralRead = hook }
        func fetchGeneralBaseline(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
            generalReads += 1
            await beforeGeneralRead?(generalReads)
            return try await fetchPreparationSnapshot(projectID: projectID)
        }
        var preparationSnapshot: SyncV2PreparationSnapshot?
        func setPreparationSnapshot(_ value: SyncV2PreparationSnapshot) { preparationSnapshot = value }
        func fetchPreparationSnapshot(projectID: UUID) async throws -> SyncV2PreparationSnapshot {
            guard let preparationSnapshot else { throw SyncV2ContractStructureError.unavailable }
            return preparationSnapshot
        }
        var beforeReservation: (@Sendable () async -> Void)?
        var afterReservation: (@Sendable () async -> Void)?
        private(set) var requests: [SyncV2JSON] = []
        var reject = false
        var projectState: SyncV2ContractServerProjectState = .active
        var beforeProjectRead: (@Sendable () async -> Void)?
        var projectReadFails = false
        func configureProjectRead(state: SyncV2ContractServerProjectState = .active, fails: Bool = false, before: (@Sendable () async -> Void)? = nil) {
            projectState = state; projectReadFails = fails; beforeProjectRead = before
        }
        func fetchProjectState(projectID: UUID) async throws -> SyncV2ContractServerProjectState {
            await beforeProjectRead?()
            if projectReadFails { throw SyncV2HandshakeError.networkUnavailable }
            return projectState
        }
        func configure(before: (@Sendable () async -> Void)? = nil,
                       after: (@Sendable () async -> Void)? = nil, reject: Bool = false) {
            beforeReservation = before; afterReservation = after; self.reject = reject
        }
        func commit(request: SyncV2JSON) async throws -> SyncV2JSON { throw SyncV2ContractStructureError.transmissionNotStarted }
        func commit(request: SyncV2JSON, authorize: @escaping @Sendable () throws -> Void) async throws -> SyncV2JSON {
            await beforeReservation?()
            try authorize()
            requests.append(request)
            await afterReservation?()
            if reject { throw SyncV2ContractStructureError.transportRejected }
            let fields = request.objectValue!, batch = fields["batch"]!.objectValue!
            if fields["kind"] == .string("document_commit_request") {
                let intent = fields["ordered_intents"]!.arrayValue![0].objectValue!, payload = fields["ordered_intents"]!.arrayValue![0].objectValue!["payload"]!.objectValue!
                var result: [String: SyncV2JSON] = ["sequence": .int(1), "operation_id": intent["operation_id"]!,
                    "document_id": intent["document_id"]!, "result_revision": .int(intent["base_revision"]!.intValue! + 1)]
                for key in ["structure_revision", "parent_folder_id", "name", "content_sha256", "content_byte_count", "is_deleted"] { result[key] = payload[key]! }
                return .object(["kind": .string("document_commit_success"), "batch_id": batch["batch_id"]!,
                    "batch_payload_sha256": batch["batch_payload_sha256"]!, "status": .string("committed"),
                    "applied": .bool(true), "results": .array([.object(result)])])
            }
            let results = fields["ordered_intents"]!.arrayValue!.map { intent -> SyncV2JSON in
                let f = intent.objectValue!
                return .object(["sequence": f["sequence"]!, "operation_id": f["operation_id"]!,
                    "entity_id": f["entity_id"]!, "result_revision": .int(1)])
            }
            return .object(["kind": .string("atomic_structure_commit_success"),
                "batch_id": batch["batch_id"]!, "batch_payload_sha256": batch["batch_payload_sha256"]!,
                "status": .string("committed"), "applied": .bool(true), "results": .array(results)])
        }
    }

    private struct SenderFixture: @unchecked Sendable {
        let coordinator: SyncV2ProjectUploadPullCoordinator
        let authority: SyncV2ContractStructureAuthority
        let context: SyncV2HandshakeContext
        let localEpoch: SyncV2ContractEpoch
        let sender: SyncV2ContractStructureSender
        let service: SyncV2HandshakeService
        let auth: LifecycleAuth
        let bindingEpoch: SyncV2ContractEpoch
        let queue: ContractQueueStub
        let transport: ContractTransportStub
        let localID: ProjectID
        let defaults: UserDefaults
        let request: SyncV2ContractRequest
    }

    private func senderFixture(deviceMismatch: Bool = false, localIsActive: Bool = true, serverID: UUID? = nil, generalDocument: Bool = false, generalAtomic: Bool = false) async throws -> SenderFixture {
        let local = ProjectID(rawValue: UUID()), server = serverID ?? UUID(), account = UUID(), device = UUID()
        let defaults = makeDefaults(function: UUID().uuidString)
        GlobalSyncPreference.setEnabled(true, in: defaults)
        ContractPathGate.setOpen(true, for: local, in: defaults)
        let auth = LifecycleAuth(account: account)
        let bindingEpoch = SyncV2ContractEpoch()
        let handshake = SyncV2HandshakeService(transport: StubTransport(results: Array(repeating: .success(supportedResponse(projectID: server, mode: (generalDocument || generalAtomic) ? .idBased : .legacy, epoch: (generalDocument || generalAtomic) ? 1 : 0)), count: 8)))
        _ = try await handshake.refresh(context: .init(localProjectID: local, serverProjectID: server, accountID: account))
        let request = generalDocument ? try SyncV2Contract.buildDocumentCommitRequest(projectID: server,
            projectSyncMode: .idBased, migrationEpoch: 1, writerDeviceID: device, documentID: UUID(),
            intentKind: .update, baseRevision: 2, parentFolderID: nil, name: "합성.txt", content: "합성 원고",
            isDeleted: false, structureRevision: 3) : try SyncV2Contract.buildAtomicStructureRequest(projectID: server,
            projectSyncMode: generalAtomic ? .idBased : .legacy, migrationEpoch: generalAtomic ? 1 : 0, writerDeviceID: device,
            orderedIntents: [.init(entityKind: .folder, entityID: UUID(), intentKind: .create,
                                  payload: .object(["name": .string("전송 시험")]))])
        let binding = ProjectSyncBinding.connected(localProjectID: local, serverProjectID: server,
            kind: .existingServerProject, projectName: "전송 시험", ownerSubject: account)
        let queue = ContractQueueStub(binding: binding, request: request)
        let transport = ContractTransportStub()
        let actualDevice = deviceMismatch ? UUID() : device
        let coordinator = SyncV2ProjectUploadPullCoordinator()
        let authority = coordinator.contractStructureAuthority
        let context = SyncV2HandshakeContext(localProjectID: local, serverProjectID: server, accountID: account)
        let token = authority.beginBaseline(context)
        authority.finishBaseline(context, token: token, allowed: true)
        let localEpoch = SyncV2ContractEpoch()
        let sender = SyncV2ContractStructureSender(store: queue, transport: transport,
            handshakeService: handshake, authenticationService: auth, uploadPullCoordinator: coordinator, defaults: ContractDefaults(value: defaults),
            bindingEpoch: bindingEpoch, deviceIdentityProvider: DeviceIdentityService(
                store: InMemoryDeviceIdentityStore(), generateUUID: { actualDevice }),
            structureAuthority: authority, localProjectEpoch: localEpoch, isLocalProjectActive: { _ in localIsActive })
        return SenderFixture(coordinator: coordinator, authority: authority, context: context, localEpoch: localEpoch, sender: sender, service: handshake, auth: auth, bindingEpoch: bindingEpoch,
            queue: queue, transport: transport, localID: local, defaults: defaults, request: request)
    }

    private func configureDocumentConflict(_ f: SenderFixture) async throws {
        let intent = f.request.orderedIntents[0].objectValue!, payload = intent["payload"]!.objectValue!
        let document = UUID(uuidString: intent["document_id"]!.stringValue!)!
        let operation = UUID(uuidString: intent["operation_id"]!.stringValue!)!
        let content = payload["content"]!.stringValue!
        let batch = LocalMutationBatch(batchID: f.request.batchID, projectID: f.localID, localTransactionID: nil,
            mutations: [.documentSnapshot(operationID: operation, documentID: .init(rawValue: document), relativePath: .init(rawValue: "합성.txt"),
                content: content, contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 1, isDeleted: false)])
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID,
            row: .init(queueID: 1, batchID: batch.batchID, sourceStatus: "materialized", requestStatus: "conflict", errorCode: "REVISION_CONFLICT", createdAt: "synthetic", isQueueHead: true),
            sourceJSON: String(decoding: JSONEncoder().encode(batch), as: UTF8.self), requestJSON: f.request.json.canonicalJSON(), responseJSON: nil)
        var fields: [String: SyncV2JSON] = ["document_id": .string(document.uuidString.lowercased()),
            "project_id": .string(f.context.serverProjectID.uuidString.lowercased()), "relative_path": .string("합성.txt"),
            "revision": .int(2), "is_deleted": .bool(false), "parent_folder_id": .null, "name": .string("합성.txt"), "structure_revision": .int(3)]
        await f.queue.setConflictLocal(.init(detail: detail, baseline: .init(folders: [], documents: [.object(fields)], treeOrders: [])))
        fields["revision"] = .int(3)
        await f.transport.setPreparationSnapshot(.init(folders: [], documents: [.object(fields)], treeOrders: []))
        fields["content"] = .string("서버 비교 본문")
        await f.transport.setConflictDocument(.object(fields))
    }

    private func configureRenameConflict(_ f: SenderFixture, previouslyBlocked: Bool = false) async throws -> UUID {
        try await configureDocumentConflict(f)
        let local = await f.queue.conflictLocal!
        let text = try local.detail.manuscripts()[0], batchID = UUID(), operation = UUID()
        let metadata = f.request.json.objectValue!["batch"]!.objectValue!
        let request = try SyncV2Contract.buildAtomicStructureRequest(projectID: f.context.serverProjectID,
            projectSyncMode: .idBased, migrationEpoch: 1, writerDeviceID: UUID(uuidString: metadata["writer_device_id"]!.stringValue!)!,
            orderedIntents: [.init(entityKind: .document, entityID: text.documentID.rawValue, intentKind: .rename, baseRevision: 3,
                payload: .object(["name": .string("iPad.txt")]), operationID: operation)], batchID: batchID)
        let node = DocumentNode(id: text.documentID, projectID: f.localID, kind: .text, parentID: nil,
            relativePath: .init(rawValue: "iPad.txt"), userOrder: 0, modifiedAt: Date(), contentHash: nil)
        let source = LocalMutationBatch(batchID: batchID, projectID: f.localID, localTransactionID: nil, kind: .structureChange,
            mutations: [.documentSnapshot(operationID: operation, documentID: text.documentID, relativePath: node.relativePath,
                content: text.content, contentHash: SHA256ContentHasher().sha256(for: Data(text.content.utf8)), localSaveGeneration: 1, isDeleted: false),
                .treeOrder(operationID: UUID(), content: "{}", generation: 1)], structureSnapshot: [node])
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID,
            row: .init(queueID: 1, batchID: batchID, sourceStatus: "materialized", requestStatus: previouslyBlocked ? "blocked" : "conflict", errorCode: "STRUCTURE_REVISION_CONFLICT",
                createdAt: "synthetic", isQueueHead: true), sourceJSON: String(decoding: JSONEncoder().encode(source), as: UTF8.self),
            requestJSON: request.json.canonicalJSON(), responseJSON: nil)
        await f.queue.setConflictLocal(.init(detail: detail, baseline: local.baseline))
        var remote = local.baseline.documents[0].objectValue!
        remote["name"] = .string("Windows.txt"); remote["relative_path"] = .string("Windows.txt"); remote["structure_revision"] = .int(5)
        await f.transport.setPreparationSnapshot(.init(folders: [], documents: [.object(remote)], treeOrders: []))
        remote["content"] = .string(text.content); await f.transport.setConflictDocument(.object(remote))
        return batchID
    }

    @MainActor
    func testRenameConflictScreenComparesReadOnlyThenKeepsSavedName() async throws {
        let f = try await senderFixture(generalDocument: true)
        _ = try await configureRenameConflict(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        XCTAssertEqual(model.renameConflictReview?.savedName, "iPad.txt")
        XCTAssertEqual(model.renameConflictReview?.remoteName, "Windows.txt")
        XCTAssertNil(model.conflictReview); XCTAssertNil(model.orderConflictReview)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        await model.keepSavedName()
        XCTAssertNil(model.renameConflictReview); XCTAssertNotNil(model.resolutionMessage); XCTAssertFalse(model.isLoading)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
        let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
    }

    func testRenameSelectionRejectsLifecycleAndBodyChangesDuringFinalRead() async throws {
        for change in 0..<8 {
            let f = try await senderFixture(generalDocument: true)
            let batchID = try await configureRenameConflict(f)
            let review = try await f.sender.prepareGeneralRenameConflict(localProjectID: f.localID, batchID: batchID)
            await f.transport.setBeforeGeneralRead { count in
                guard count == 3 else { return }
                switch change {
                case 0: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 1: await f.auth.relogin()
                case 2: f.bindingEpoch.advance()
                case 3: f.localEpoch.advance()
                case 4: GlobalSyncPreference.setEnabled(false, in: f.defaults)
                case 5: await f.service.updateSceneActivity(false)
                default:
                    var remote = review.remote.objectValue!
                    if change == 6 { remote["content"] = .string("서버에서 새 입력") }
                    else { remote["name"] = .string("Again.txt"); remote["relative_path"] = .string("Again.txt"); remote["structure_revision"] = .int(7) }
                    await f.transport.setConflictDocument(.object(remote))
                    remote.removeValue(forKey: "content")
                    await f.transport.setPreparationSnapshot(.init(folders: [], documents: [.object(remote)], treeOrders: []))
                }
            }
            do { _ = try await f.sender.keepSavedGeneralRenameConflict(review); XCTFail("changed \(change)") } catch {}
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    @MainActor
    func testRenameComparisonBecomesStaleAfterTailAndClosingCancelsSelection() async throws {
        for closing in [false, true] {
            let f = try await senderFixture(generalDocument: true)
            _ = try await configureRenameConflict(f)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
            XCTAssertNotNil(model.renameConflictReview)
            if closing {
                await f.transport.setBeforeGeneralRead { count in if count == 3 { await MainActor.run { model.stop() } } }
            } else { try await appendStructureFollower(f) }
            await model.keepSavedName()
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            XCTAssertNil(model.renameConflictReview); XCTAssertNil(model.resolutionMessage); XCTAssertFalse(model.isLoading)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    private func configureFolderNameConflict(_ f: SenderFixture, populated: Bool = false) async throws -> UUID {
        let folder = UUID(), operation = UUID(), batchID = UUID()
        let metadata = f.request.json.objectValue!["batch"]!.objectValue!
        var intents: [SyncV2StructureIntent] = [.init(entityKind: .folder, entityID: folder, intentKind: .update, baseRevision: 1,
            payload: .object(["name": .string("iPad 폴더"), "parent_folder_id": .null]), operationID: operation)]
        let node = DocumentNode(id: .init(rawValue: folder), projectID: f.localID, kind: .folder, parentID: nil,
            relativePath: .init(rawValue: "iPad 폴더"), userOrder: 0, modifiedAt: Date(), contentHash: nil)
        var nodes = [node], documents: [SyncV2JSON] = [], remoteDocuments: [SyncV2JSON] = [], contents: [UUID: SyncV2JSON] = [:]
        var mutations: [DurableLocalMutation] = [.folderSnapshot(operationID: operation, folderID: node.id,
            parentFolderID: nil, name: "iPad 폴더", isDeleted: false)]
        if populated {
            for index in 0..<2 {
                let id = UUID(), childOperation = UUID(), name = "원고-\(index).txt", content = "합성 본문 \(index)"
                let child = DocumentNode(id: .init(rawValue: id), projectID: f.localID, kind: .text, parentID: node.id,
                    relativePath: .init(rawValue: "iPad 폴더/" + name), userOrder: index, modifiedAt: Date(), contentHash: nil)
                nodes.append(child)
                mutations.append(.documentSnapshot(operationID: childOperation, documentID: child.id, relativePath: child.relativePath,
                    content: content, contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 1, isDeleted: false))
                intents.append(.init(entityKind: .document, entityID: id, intentKind: .rename, baseRevision: 2,
                    payload: .object(["name": .string(name)]), operationID: childOperation))
                var row: [String: SyncV2JSON] = ["document_id": .string(id.uuidString.lowercased()),
                    "project_id": .string(f.context.serverProjectID.uuidString.lowercased()), "parent_folder_id": .string(folder.uuidString.lowercased()),
                    "name": .string(name), "relative_path": .string("이전 폴더/" + name), "revision": .int(1), "structure_revision": .int(2), "is_deleted": .bool(false)]
                documents.append(.object(row)); row["relative_path"] = .string("Windows 폴더/" + name); row["structure_revision"] = .int(4)
                remoteDocuments.append(.object(row)); row["content"] = .string(content); contents[id] = .object(row)
            }
        }
        mutations.append(.treeOrder(operationID: UUID(), content: "{}", generation: 1))
        let request = try SyncV2Contract.buildAtomicStructureRequest(projectID: f.context.serverProjectID,
            projectSyncMode: .idBased, migrationEpoch: 1, writerDeviceID: UUID(uuidString: metadata["writer_device_id"]!.stringValue!)!,
            orderedIntents: intents, batchID: batchID)
        let source = LocalMutationBatch(batchID: batchID, projectID: f.localID, localTransactionID: nil, kind: .structureChange,
            mutations: mutations, structureSnapshot: nodes)
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID,
            row: .init(queueID: 1, batchID: batchID, sourceStatus: "materialized", requestStatus: "conflict", errorCode: "REVISION_CONFLICT",
                createdAt: "synthetic", isQueueHead: true), sourceJSON: String(decoding: JSONEncoder().encode(source), as: UTF8.self),
            requestJSON: request.json.canonicalJSON(), responseJSON: nil)
        var folderRow: [String: SyncV2JSON] = ["folder_id": .string(folder.uuidString.lowercased()),
            "project_id": .string(f.context.serverProjectID.uuidString.lowercased()), "parent_folder_id": .null,
            "name": .string("이전 폴더"), "revision": .int(1), "is_deleted": .bool(false)]
        await f.queue.setConflictLocal(.init(detail: detail, baseline: .init(folders: [.object(folderRow)], documents: documents, treeOrders: [])))
        folderRow["name"] = .string("Windows 폴더"); folderRow["revision"] = .int(4)
        await f.transport.setPreparationSnapshot(.init(folders: [.object(folderRow)], documents: remoteDocuments, treeOrders: []))
        await f.transport.setConflictDocuments(contents)
        return batchID
    }

    private func configureGeneralStructureConflict(_ f: SenderFixture) async throws -> UUID {
        let id = try await configureFolderNameConflict(f, populated: true)
        let savedLocal = await f.queue.conflictLocal
        let local = try XCTUnwrap(savedLocal)
        let savedRemote = await f.transport.preparationSnapshot
        let remote = try XCTUnwrap(savedRemote)
        let folder = local.baseline.folders[0].objectValue!["folder_id"]!
        let orderRows: [SyncV2JSON] = [
            .object(["tree_order_id": .string(UUID().uuidString.lowercased()), "project_id": .string(f.context.serverProjectID.uuidString.lowercased()),
                     "parent_folder_id": .null, "children": .array([folder]), "revision": .int(1)]),
            .object(["tree_order_id": .string(UUID().uuidString.lowercased()), "project_id": .string(f.context.serverProjectID.uuidString.lowercased()),
                     "parent_folder_id": folder, "children": .array(local.baseline.documents.map { $0.objectValue!["document_id"]! }), "revision": .int(1)])]
        await f.queue.setConflictLocal(.init(detail: local.detail, baseline: .init(folders: local.baseline.folders, documents: local.baseline.documents, treeOrders: orderRows)))
        await f.transport.setPreparationSnapshot(.init(folders: remote.folders, documents: remote.documents, treeOrders: orderRows))
        return id
    }

    @MainActor
    func testGeneralStructureScreenComparesWithoutWritingThenValidatesAdoption() async throws {
        let f = try await senderFixture(generalAtomic: true)
        _ = try await configureGeneralStructureConflict(f)
        let validation = SyncV2ContractEpoch()
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender, validateStructureLocal: { _ in validation.advance() })
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareStructure()
        XCTAssertNotNil(model.structureConflictReview); XCTAssertTrue(model.canAdoptStructure)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        await model.resolveStructure(adoptServer: true)
        XCTAssertEqual(validation.value, 1); XCTAssertNil(model.structureConflictReview); XCTAssertNotNil(model.resolutionMessage)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
    }

    func testGeneralStructureSelectionRejectsLifecycleAndBodyChanges() async throws {
        for variant in 0..<4 {
            let f = try await senderFixture(generalAtomic: true)
            let id = try await configureGeneralStructureConflict(f)
            let review = try await f.sender.prepareGeneralStructureConflict(localProjectID: f.localID, batchID: id)
            await f.transport.setBeforeConflictDocumentRead { count in
                guard count == 3 else { return }
                switch variant {
                case 0: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 1: await f.auth.relogin()
                case 2: f.localEpoch.advance()
                default:
                    var bodies = await f.transport.conflictDocuments
                    for (id, value) in bodies { var row = value.objectValue!; row["content"] = .string("새 본문"); bodies[id] = .object(row) }
                    await f.transport.setConflictDocuments(bodies)
                }
            }
            do { _ = try await f.sender.resolveGeneralStructureConflict(review, adoptServer: false, validateLocal: nil); XCTFail("changed") } catch {}
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    @MainActor
    func testGeneralStructureAdoptionRejectsLocalValidationAndScreenCancellation() async throws {
        for cancel in [false, true] {
            let f = try await senderFixture(generalAtomic: true)
            _ = try await configureGeneralStructureConflict(f)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender, validateStructureLocal: { _ in throw SyncV2GeneralConflictError.changed })
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareStructure()
            XCTAssertNotNil(model.structureConflictReview)
            if cancel { await f.transport.setBeforeConflictDocumentRead { count in if count == 3 { await MainActor.run { model.stop() } } } }
            await model.resolveStructure(adoptServer: true)
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0); XCTAssertNil(model.resolutionMessage)
        }
    }

    @MainActor
    func testPopulatedFolderScreenReadsEveryBodyBeforeExplicitSelection() async throws {
        let f = try await senderFixture(generalAtomic: true)
        _ = try await configureFolderNameConflict(f, populated: true)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        let review = try XCTUnwrap(model.renameConflictReview)
        XCTAssertTrue(review.isFolder); XCTAssertEqual(review.descendantDocuments.count, 2)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        let reads = await f.transport.conflictDocumentReads; XCTAssertEqual(reads, 2)
        await model.keepSavedName()
        XCTAssertNotNil(model.resolutionMessage)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
        let allReads = await f.transport.conflictDocumentReads; XCTAssertEqual(allReads, 4)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
    }

    @MainActor
    func testPopulatedFolderSelectionRejectsChildReadFailureBodyChangeAndCancellation() async throws {
        for variant in 0..<4 {
            let f = try await senderFixture(generalAtomic: true)
            _ = try await configureFolderNameConflict(f, populated: true)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
            XCTAssertNotNil(model.renameConflictReview)
            await f.transport.setBeforeConflictDocumentRead { count in
                guard count == 3 else { return }
                switch variant {
                case 0: await f.transport.setConflictDocuments([:])
                case 1:
                    var documents = await f.transport.conflictDocuments
                    for (id, value) in documents {
                        var fields = value.objectValue!; fields["content"] = .string("서버에서 바뀐 본문"); documents[id] = .object(fields)
                    }
                    await f.transport.setConflictDocuments(documents)
                case 2: await MainActor.run { model.stop() }
                default: await f.auth.relogin()
                }
            }
            await model.keepSavedName()
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            XCTAssertNil(model.resolutionMessage)
            let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    @MainActor
    func testFolderNameScreenReadsMetadataThenExplicitlyResolves() async throws {
        let f = try await senderFixture(generalAtomic: true)
        _ = try await configureFolderNameConflict(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        let review = try XCTUnwrap(model.renameConflictReview)
        XCTAssertTrue(review.isFolder); XCTAssertEqual(review.savedName, "iPad 폴더"); XCTAssertEqual(review.remoteName, "Windows 폴더")
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        await model.keepSavedName()
        XCTAssertNil(model.renameConflictReview); XCTAssertNotNil(model.resolutionMessage)
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 1)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
    }

    @MainActor
    func testPreviouslyBlockedDocumentNameConflictRemainsAvailableInScreen() async throws {
        let f = try await senderFixture(generalDocument: true)
        _ = try await configureRenameConflict(f, previouslyBlocked: true)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); let row = try XCTUnwrap(model.rows.first)
        XCTAssertTrue(row.isConflictReviewCandidate); XCTAssertEqual(row.statusText, "충돌 확인 필요")
        await model.select(row); await model.compareConflict()
        XCTAssertNotNil(model.renameConflictReview); XCTAssertFalse(model.renameConflictReview!.isFolder)
        await model.keepSavedName()
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 1)
    }

    @MainActor
    func testFolderNameSelectionRejectsRemoteLifecycleTailAndCloseChanges() async throws {
        for change in 0..<5 {
            let f = try await senderFixture(generalAtomic: true)
            _ = try await configureFolderNameConflict(f)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
            let review = try XCTUnwrap(model.renameConflictReview)
            if change == 0 { try await appendStructureFollower(f) }
            else {
                await f.transport.setBeforeGeneralRead { count in
                    guard count == 3 else { return }
                    switch change {
                    case 1: await f.auth.relogin()
                    case 2: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                    case 3: await MainActor.run { model.stop() }
                    default:
                        var remote = review.remote.objectValue!; remote["name"] = .string("다시 바뀐 폴더"); remote["revision"] = .int(6)
                        await f.transport.setPreparationSnapshot(.init(folders: [.object(remote)], documents: [], treeOrders: []))
                    }
                }
            }
            await model.keepSavedName()
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            XCTAssertNil(model.renameConflictReview); XCTAssertNil(model.resolutionMessage)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    private func configureOrderConflict(_ f: SenderFixture) async throws -> UUID {
        let documents = [UUID(), UUID(), UUID()], orderID = UUID(), operation = UUID(), batchID = UUID()
        let saved = [documents[2], documents[0], documents[1]]
        let metadata = f.request.json.objectValue!["batch"]!.objectValue!
        let request = try SyncV2Contract.buildAtomicStructureRequest(projectID: f.context.serverProjectID,
            projectSyncMode: .idBased, migrationEpoch: 1,
            writerDeviceID: UUID(uuidString: metadata["writer_device_id"]!.stringValue!)!,
            orderedIntents: [.init(entityKind: .treeOrder, entityID: orderID, intentKind: .reorder, baseRevision: 2,
                payload: .object(["parent_folder_id": .null, "children": .array(saved.map { .string($0.uuidString.lowercased()) })]),
                operationID: syncV2UUIDv5(namespace: operation, name: orderID.uuidString.lowercased()))], batchID: batchID)
        let nodes = saved.enumerated().map { index, id in
            DocumentNode(id: .init(rawValue: id), projectID: f.localID, kind: .text, parentID: nil,
                relativePath: .init(rawValue: "합성-\(documents.firstIndex(of: id)!).txt"), userOrder: index, modifiedAt: Date(), contentHash: nil)
        }
        let source = LocalMutationBatch(batchID: batchID, projectID: f.localID, localTransactionID: nil, kind: .structureChange,
            mutations: [.treeOrder(operationID: operation, content: "{}", generation: 1)], structureSnapshot: nodes)
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID,
            row: .init(queueID: 1, batchID: batchID, sourceStatus: "materialized", requestStatus: "conflict",
                errorCode: "REVISION_CONFLICT", createdAt: "synthetic", isQueueHead: true),
            sourceJSON: String(decoding: JSONEncoder().encode(source), as: UTF8.self), requestJSON: request.json.canonicalJSON(), responseJSON: nil)
        let rows: [SyncV2JSON] = documents.enumerated().map { index, id in .object([
            "document_id": .string(id.uuidString.lowercased()), "project_id": .string(f.context.serverProjectID.uuidString.lowercased()),
            "relative_path": .string("합성-\(index).txt"), "name": .string("합성-\(index).txt"),
            "revision": .int(1), "structure_revision": .int(1), "is_deleted": .bool(false), "parent_folder_id": .null]) }
        var order: [String: SyncV2JSON] = ["tree_order_id": .string(orderID.uuidString.lowercased()),
            "project_id": .string(f.context.serverProjectID.uuidString.lowercased()), "parent_folder_id": .null,
            "children": .array(documents.map { .string($0.uuidString.lowercased()) }), "revision": .int(2)]
        await f.queue.setConflictLocal(.init(detail: detail, baseline: .init(folders: [], documents: rows, treeOrders: [.object(order)])))
        order["revision"] = .int(4)
        order["children"] = .array(documents.reversed().map { .string($0.uuidString.lowercased()) })
        await f.transport.setPreparationSnapshot(.init(folders: [], documents: rows, treeOrders: [.object(order)]))
        return batchID
    }

    @MainActor
    func testOrderConflictScreenComparesWithoutWritingThenExplicitlyResolves() async throws {
        let f = try await senderFixture(generalAtomic: true)
        _ = try await configureOrderConflict(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        let review = try XCTUnwrap(model.orderConflictReview)
        XCTAssertEqual(review.savedChildren.count, 3); XCTAssertNotEqual(review.savedChildren, review.remoteChildren)
        XCTAssertEqual(review.parentName, "작품 최상위"); XCTAssertEqual(review.name(for: review.savedChildren[0]), "합성-2.txt")
        XCTAssertNil(model.conflictReview)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        await model.keepSavedOrder()
        XCTAssertNil(model.orderConflictReview); XCTAssertNotNil(model.resolutionMessage); XCTAssertFalse(model.isLoading)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
        let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
    }

    func testOrderConflictSelectionRejectsServerAndLifecycleChangesAndReleasesPermit() async throws {
        for change in 0..<7 {
            let f = try await senderFixture(generalAtomic: true)
            let batchID = try await configureOrderConflict(f)
            let review = try await f.sender.prepareGeneralOrderConflict(localProjectID: f.localID, batchID: batchID)
            await f.transport.setBeforeGeneralRead { count in
                guard count == 3 else { return }
                switch change {
                case 0: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 1: await f.auth.relogin()
                case 2: f.bindingEpoch.advance()
                case 3: f.localEpoch.advance()
                case 4: GlobalSyncPreference.setEnabled(false, in: f.defaults)
                case 5: await f.service.updateSceneActivity(false)
                default:
                    var order = review.remoteOrder.objectValue!; order["revision"] = .int(9)
                    await f.transport.setPreparationSnapshot(.init(folders: review.remoteBaseline.folders,
                        documents: review.remoteBaseline.documents, treeOrders: [.object(order)]))
                }
            }
            do { _ = try await f.sender.keepSavedGeneralOrderConflict(review); XCTFail("changed \(change)") } catch {}
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
            let permit = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(permit.runningUploadCount, 0)
        }
    }

    func testOrderConflictRejectsChangedSecondReadAndAddedLocalTail() async throws {
        for addTail in [false, true] {
            let f = try await senderFixture(generalAtomic: true)
            let batchID = try await configureOrderConflict(f)
            let review = try await f.sender.prepareGeneralOrderConflict(localProjectID: f.localID, batchID: batchID)
            if addTail {
                try await appendStructureFollower(f)
            } else {
                await f.transport.setBeforeGeneralRead { count in
                    guard count == 4 else { return }
                    var order = review.remoteOrder.objectValue!; order["children"] = review.payload.objectValue!["children"]
                    await f.transport.setPreparationSnapshot(.init(folders: review.remoteBaseline.folders,
                        documents: review.remoteBaseline.documents, treeOrders: [.object(order)]))
                }
            }
            do { _ = try await f.sender.keepSavedGeneralOrderConflict(review); XCTFail("changed") } catch {}
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
        }
    }

    func testGeneralConflictComparisonIsReadOnlyAndSelectionIsExplicit() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        let review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(review.savedContent, "합성 원고"); XCTAssertEqual(review.remoteContent, "서버 비교 본문")
        _ = try await f.sender.keepSavedGeneralConflict(review)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
    }

    func testGeneralConflictSelectionRejectsChangedServerContentWithoutLocalMutation() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        let review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
        var changed = review.remote.objectValue!; changed["content"] = .string("비교 뒤 다시 변경")
        await f.transport.setConflictDocument(.object(changed))
        do { _ = try await f.sender.keepSavedGeneralConflict(review); XCTFail("stale review") } catch {}
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
        let snapshot = await f.coordinator.snapshot(localProjectID: f.localID)
        XCTAssertEqual(snapshot.runningUploadCount, 0)
    }

    func testGeneralConflictSelectionRejectsLifecycleChangesDuringFinalRead() async throws {
        for change in 0..<4 {
            let f = try await senderFixture(generalDocument: true)
            try await configureDocumentConflict(f)
            let review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
            await f.transport.setBeforeGeneralRead { count in
                guard count == 3 else { return }
                switch change {
                case 0: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 1: await f.auth.relogin()
                case 2: f.bindingEpoch.advance()
                default: f.localEpoch.advance()
                }
            }
            do { _ = try await f.sender.keepSavedGeneralConflict(review); XCTFail("stale lifecycle") } catch {}
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
        }
    }

    @MainActor
    func testGeneralConflictScreenDoesNotApplyOnCompareAndClearsReviewAfterSelection() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        XCTAssertNotNil(model.conflictReview)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        await model.keepSavedSelection()
        XCTAssertNil(model.conflictReview); XCTAssertNotNil(model.resolutionMessage); XCTAssertFalse(model.isLoading)
        let after = await f.queue.resolutionCount; XCTAssertEqual(after, 1)
    }

    @MainActor
    func testClosingGeneralConflictScreenCancelsPendingSelection() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        await f.transport.setBeforeGeneralRead { count in
            if count == 3 { await MainActor.run { model.stop() } }
        }
        await model.keepSavedSelection()
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
        XCTAssertNil(model.conflictReview); XCTAssertNil(model.resolutionMessage); XCTAssertFalse(model.isLoading)
    }

    @discardableResult
    private func appendConflictFollower(_ f: SenderFixture, content: String) async throws -> UUID {
        let stored = await f.queue.conflictLocal
        var local = try XCTUnwrap(stored)
        guard case let .documentSnapshot(_, document, path, _, _, _, _) = local.detail.source.mutations[0] else {
            throw SyncV2GeneralConflictError.unsupported
        }
        let operation = UUID()
        let batch = LocalMutationBatch(batchID: UUID(), projectID: f.localID, localTransactionID: nil,
            mutations: [.documentSnapshot(operationID: operation, documentID: document, relativePath: path, content: content,
                contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 2, isDeleted: false)])
        let row = SyncV2GeneralRecoveryRow(queueID: Int64(local.followers.count + 2), batchID: batch.batchID,
            sourceStatus: "waiting", requestStatus: nil, errorCode: nil, createdAt: "synthetic", isQueueHead: false)
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID, row: row,
            sourceJSON: String(decoding: JSONEncoder().encode(batch), as: UTF8.self), requestJSON: nil, responseJSON: nil)
        local.followers.append(detail)
        await f.queue.setConflictLocal(local)
        return operation
    }

    @MainActor
    func testConflictScreenComparesLatestFollowerAndRequiresNewReviewAfterAnotherSave() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        try await appendConflictFollower(f, content: "최근 저장")
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        XCTAssertEqual(model.conflictReview?.savedContent, "최근 저장")
        XCTAssertEqual(model.conflictReview?.local.records.count, 2)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        try await appendConflictFollower(f, content: "비교 이후 저장")
        await model.keepSavedSelection()
        XCTAssertNil(model.conflictReview); XCTAssertNotNil(model.errorMessage)
        let rejected = await f.queue.resolutionCount; XCTAssertEqual(rejected, 0)
        await model.compareConflict()
        XCTAssertEqual(model.conflictReview?.savedContent, "비교 이후 저장")
        await model.keepSavedSelection()
        let applied = await f.queue.resolutionCount; XCTAssertEqual(applied, 1)
    }

    @MainActor
    func testGeneralConflictAdoptsServerEmptyAndMergedContentThroughLocalSave() async throws {
        for content in ["서버 비교 본문", "", "직접 병합 👩‍💻\r\ne\u{301}"] {
            let f = try await senderFixture(generalDocument: true)
            try await configureDocumentConflict(f)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender, saveLocalSelection: { review, selected, authorize in
                try authorize()
                XCTAssertEqual(review.savedContent, "합성 원고")
                return try await self.appendConflictFollower(f, content: selected)
            })
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
            let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
            await model.selectContent(content)
            XCTAssertNil(model.errorMessage); XCTAssertNotNil(model.resolutionMessage)
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 1)
            let local = await f.queue.conflictLocal
            XCTAssertEqual(try local?.selected.manuscripts().first?.content, content)
        }
    }

    @MainActor
    func testGeneralConflictDoesNotSaveLocalContentAfterStaleReview() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        let review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
        try await appendConflictFollower(f, content: "새 입력")
        do {
            _ = try await f.sender.selectGeneralConflict(review, content: "선택") { _, _, _ in
                XCTFail("비교가 낡으면 TXT 저장을 시작하면 안 됩니다."); return UUID()
            }
            XCTFail("stale")
        } catch {}
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
    }

    @MainActor
    func testGeneralConflictPreservesLocalSelectionButStopsOnSaveBoundaryChanges() async throws {
        for change in 0..<6 {
            let f = try await senderFixture(generalDocument: true)
            try await configureDocumentConflict(f)
            let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender, saveLocalSelection: { review, content, authorize in
                try authorize()
                let operation = try await self.appendConflictFollower(f, content: content)
                switch change {
                case 0: try await self.appendConflictFollower(f, content: "저장 중 새 입력")
                case 1:
                    var fields = review.remote.objectValue!; fields["content"] = .string("저장 중 서버 변경")
                    await f.transport.setConflictDocument(.object(fields))
                case 2: await f.auth.relogin()
                case 3: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 4: return UUID()
                default: throw SyncV2GeneralConflictError.localSelectionSavedNeedsReview
                }
                return operation
            })
            await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
            await model.selectContent("선택 저장")
            XCTAssertTrue(model.errorMessage?.contains("iPad에 저장") == true)
            XCTAssertNil(model.resolutionMessage); XCTAssertNil(model.conflictReview)
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
            let local = await f.queue.conflictLocal; XCTAssertFalse(local?.followers.isEmpty ?? true)
            let gate = await f.coordinator.snapshot(localProjectID: f.localID); XCTAssertEqual(gate.runningUploadCount, 0)
            let sends = await f.transport.requests; XCTAssertTrue(sends.isEmpty)
        }
    }

    @MainActor
    func testGeneralConflictRejectsOversizedSelectionAndFullChainBeforeSaving() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        var review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
        do {
            _ = try await f.sender.selectGeneralConflict(review, content: String(repeating: "a", count: SyncV2Store.maximumContentByteCount + 1)) { _, _, _ in
                XCTFail("oversized"); return UUID()
            }
            XCTFail("oversized")
        } catch {}
        for _ in 0..<49 { try await appendConflictFollower(f, content: "후속") }
        review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
        do {
            _ = try await f.sender.selectGeneralConflict(review, content: "선택") { _, _, _ in
                XCTFail("full chain"); return UUID()
            }
            XCTFail("full chain")
        } catch {}
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
    }

    private actor ConflictEditorMetadata: DocumentRepository, WorkspaceStateRepository, DocumentFileMetadataUpdating {
        var value: DocumentNode
        var failUpdate = false
        init(_ document: DocumentNode, failUpdate: Bool = false) { value = document; self.failUpdate = failUpdate }
        func documents(in projectID: ProjectID) -> [DocumentNode] { [value] }
        func document(id: DocumentID) -> DocumentNode? { id == value.id ? value : nil }
        func save(_ document: DocumentNode) { value = document }
        func removeMetadata(id: DocumentID) {}
        func lastProjectID() -> ProjectID? { value.projectID }
        func setLastProjectID(_ projectID: ProjectID?) {}
        func editorState(for projectID: ProjectID) -> EditorWorkspaceState {
            .init(projectID: projectID, left: .init(documentID: nil, cursor: .start), right: nil, activePane: .left)
        }
        func saveEditorState(_ state: EditorWorkspaceState) {}
        func binderWidth(for projectID: ProjectID) -> Double { 248 }
        func setBinderWidth(_ width: Double, for projectID: ProjectID) {}
        func expandedFolderIDs(in projectID: ProjectID) -> Set<DocumentID> { [] }
        func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) {}
        func cursor(for documentID: DocumentID) -> TextCursorState { .start }
        func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) {}
        func updateAfterFileSave(_ receipt: DocumentSaveReceipt) throws {
            if failUpdate { throw SyncV2GeneralConflictError.unavailable }
        }
    }

    private actor ConflictSelectionRecorder: DurableLocalChangeRecording {
        let queue: ContractQueueStub
        var fails: Bool
        func setFails(_ value: Bool) { fails = value }
        var beforeRecord: (@MainActor @Sendable () -> Void)?
        init(queue: ContractQueueStub, fails: Bool) { self.queue = queue; self.fails = fails }
        func configure(_ hook: @escaping @MainActor @Sendable () -> Void) { beforeRecord = hook }
        func requirement(for projectID: ProjectID) -> DurableRecordingRequirement { .durableQueue }
        func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool { false }
        func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
            await beforeRecord?()
            if fails { return .localSavedButNotQueued(reason: "합성 실패") }
            guard var local = await queue.conflictLocal else { return .localOnly }
            do {
                let detail = try SyncV2GeneralRecoveryDetail(localProjectID: batch.projectID, serverProjectID: local.detail.serverProjectID,
                    row: .init(queueID: Int64(local.records.count + 1), batchID: batch.batchID, sourceStatus: "waiting", requestStatus: nil,
                        errorCode: nil, createdAt: "synthetic", isQueueHead: false),
                    sourceJSON: String(decoding: JSONEncoder().encode(batch), as: UTF8.self), requestJSON: nil, responseJSON: nil)
                local.followers.append(detail); await queue.setConflictLocal(local)
                guard case let .documentSnapshot(operation, _, _, _, _, _, _) = batch.mutations[0] else { return .localOnly }
                return .queued(operationIDs: [operation])
            } catch { return .localSavedButNotQueued(reason: "합성 검증 실패") }
        }
    }

    @MainActor
    func testGeneralConflictLocalWriterProtectsTwoEditorsAndDurableFailureBoundaries() async throws {
        for mode in 0..<7 {
            let f = try await senderFixture(generalDocument: true)
            try await configureDocumentConflict(f)
            var review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GeneralConflictWriter-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("합성.txt")
            try Data(review.savedContent.utf8).write(to: file)
            let document = DocumentNode(id: .init(rawValue: review.documentID), projectID: f.localID, kind: .text, parentID: nil,
                relativePath: .init(rawValue: "합성.txt"), userOrder: 0, modifiedAt: .distantPast, contentHash: nil)
            let metadata = ConflictEditorMetadata(document, failUpdate: mode == 4)
            let recorder = ConflictSelectionRecorder(queue: f.queue, fails: mode == 5)
            let store = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: root), metadataUpdater: metadata,
                durableChangeRecorder: recorder)
            let left = EditorSessionModel(documentRepository: metadata, documentStore: store, workspaceStateRepository: metadata,
                autosaveSleep: { _ in throw CancellationError() })
            let right = EditorSessionModel(documentRepository: metadata, documentStore: store, workspaceStateRepository: metadata,
                autosaveSleep: { _ in throw CancellationError() })
            let node = BinderNode(id: document.id, projectID: f.localID, kind: .text, relativePath: document.relativePath,
                displayName: "합성", fixedCategory: nil, userOrder: 0, contentState: .written, isExpanded: false)
            await left.select(node); await right.select(node)
            XCTAssertEqual(left.currentText, review.savedContent); XCTAssertEqual(right.currentText, review.savedContent)
            if mode == 6 {
                left.updateText("é"); let saved = await left.saveNow(); XCTAssertTrue(saved)
                _ = right.applyRemoteSnapshotIfClean(documentID: document.id, content: "é")
                review = try await f.sender.prepareGeneralConflict(localProjectID: f.localID, batchID: f.request.batchID)
            }
            let chosen = mode == 6 ? "e\u{301}" : review.remoteContent
            if mode == 1 { right.updateText("미저장 입력") }
            if mode == 2 { await right.updateCompositionState(true) }
            if mode == 3 { await recorder.configure { right.updateText("저장 중 새 입력") } }
            let writer = GeneralSyncConflictLocalWriter(projectID: f.localID, repository: metadata, store: store,
                editors: [left, right], notifier: NoOpFutureChangeNotifier())
            do {
                _ = try await f.sender.selectGeneralConflict(review, content: chosen) { value, content, authorize in
                    try await writer.save(value, content: content, authorize: authorize)
                }
                XCTAssertTrue(mode == 0 || mode == 6)
            } catch {
                XCTAssertTrue(mode != 0 && mode != 6)
                if mode >= 3 { XCTAssertTrue(error is SyncV2GeneralConflictError) }
            }
            let count = await f.queue.resolutionCount; XCTAssertEqual(count, (mode == 0 || mode == 6) ? 1 : 0)
            let expectedDisk = (mode == 1 || mode == 2) ? review.savedContent : chosen
            XCTAssertEqual(try Data(contentsOf: file), Data(expectedDisk.utf8))
            XCTAssertEqual(Data(left.currentText.utf8), Data(expectedDisk.utf8))
            if mode == 1 { XCTAssertEqual(right.currentText, "미저장 입력"); XCTAssertTrue(right.hasUnsavedChanges) }
            else if mode == 3 { XCTAssertEqual(right.currentText, "저장 중 새 입력"); XCTAssertTrue(right.hasUnsavedChanges) }
            else { XCTAssertEqual(Data(right.currentText.utf8), Data(expectedDisk.utf8)); XCTAssertFalse(right.hasUnsavedChanges) }
            if mode == 4 || mode == 5 {
                let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
                XCTAssertTrue(files.contains { $0.hasPrefix(mode == 4 ? LocalDocumentStore.reconciliationPrefix : LocalDocumentStore.syncHandoffPrefix) })
                guard case .failed = left.syncHandoffState else { return XCTFail("재시도 상태가 필요합니다.") }
                if mode == 5 {
                    await recorder.setFails(false)
                    let retried = await left.saveNow(); XCTAssertTrue(retried)
                    guard case .queued = left.syncHandoffState else { return XCTFail("기존 재시도로 handoff를 복구해야 합니다.") }
                    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
                    XCTAssertFalse(remaining.contains { $0.hasPrefix(LocalDocumentStore.syncHandoffPrefix) })
                }
            }
        }
    }

    private func appendStructureFollower(_ f: SenderFixture) async throws {
        let stored = await f.queue.conflictLocal
        var local = try XCTUnwrap(stored)
        let batch = LocalMutationBatch(batchID: UUID(), projectID: f.localID, localTransactionID: UUID(), kind: .structureChange,
            mutations: [.treeOrder(operationID: UUID(), content: "{}", generation: 1)], structureSnapshot: [])
        let detail = try SyncV2GeneralRecoveryDetail(localProjectID: f.localID, serverProjectID: f.context.serverProjectID,
            row: .init(queueID: Int64(local.records.count + 1), batchID: batch.batchID, sourceStatus: "waiting", requestStatus: nil,
                errorCode: nil, createdAt: "synthetic", isQueueHead: false),
            sourceJSON: String(decoding: JSONEncoder().encode(batch), as: UTF8.self), requestJSON: nil, responseJSON: nil)
        local.followers.append(detail); await f.queue.setConflictLocal(local)
    }

    @MainActor
    func testMixedRecoveryScreenKeepsStructureAndLaterBodyOutsideSelection() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        try await appendConflictFollower(f, content: "앞선 최신 원고")
        try await appendStructureFollower(f)
        try await appendConflictFollower(f, content: "구조 변경 이후 원고")
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender, saveLocalSelection: { _, _, _ in
            XCTFail("후속 변경이 있으면 채택·병합으로 순서를 바꾸면 안 됩니다."); return UUID()
        })
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        XCTAssertEqual(model.conflictReview?.savedContent, "앞선 최신 원고")
        XCTAssertEqual(model.conflictReview?.local.resolutionRecords.count, 2)
        XCTAssertEqual(model.conflictReview?.local.deferredRecords.count, 2)
        await model.selectContent("임의로 앞당길 원고")
        XCTAssertNotNil(model.errorMessage)
        let before = await f.queue.resolutionCount; XCTAssertEqual(before, 0)
        await model.compareConflict(); await model.keepSavedSelection()
        XCTAssertNil(model.errorMessage); XCTAssertNotNil(model.resolutionMessage)
        let resolved = await f.queue.lastResolutionReview
        XCTAssertEqual(resolved?.savedContent, "앞선 최신 원고")
        XCTAssertEqual(resolved?.local.deferredRecords.count, 2)
    }

    @MainActor
    func testMixedRecoveryReviewRejectsAddedTailBeforeResolution() async throws {
        let f = try await senderFixture(generalDocument: true)
        try await configureDocumentConflict(f)
        try await appendStructureFollower(f)
        let model = GeneralSyncRecoveryModel(projectID: f.localID, reader: f.sender)
        await model.load(); await model.select(try XCTUnwrap(model.rows.first)); await model.compareConflict()
        XCTAssertNotNil(model.conflictReview)
        try await appendConflictFollower(f, content: "비교 중 추가 원고")
        await model.keepSavedSelection()
        XCTAssertNotNil(model.errorMessage)
        let count = await f.queue.resolutionCount; XCTAssertEqual(count, 0)
        let writes = await f.transport.requests; XCTAssertTrue(writes.isEmpty)
    }

    private func prepareRestart(_ f: SenderFixture) async {
        await f.service.forget(reason: "합성 재시작")
        let token = f.authority.beginBaseline(f.context)
        f.authority.finishBaseline(f.context, token: token, allowed: false)
        let snapshot = SyncV2PreparationSnapshot(folders: [], documents: [.object(["revision": .int(2)])], treeOrders: [])
        await f.queue.setResumeBaseline(snapshot)
        await f.transport.setPreparationSnapshot(snapshot)
    }

    private func installLostReceipt(_ f: SenderFixture) async throws -> SyncV2GeneralCommitReceipt {
        let pending = f.queue.pending
        let receipt = try makeGeneralCommitReceiptForTesting(pending, accountID: f.context.accountID,
            response: makeGeneralCommitResponseForTesting(pending))
        await f.queue.setRecoveryEligible()
        await f.transport.configureReceipt(receipt)
        return receipt
    }

    func testLostReceiptRestartAcknowledgesDocumentAndAtomicWithoutWriteRPCOrC9Grant() async throws {
        for document in [true, false] {
            let f = try await senderFixture(generalDocument: document, generalAtomic: !document)
            await prepareRestart(f)
            _ = try await installLostReceipt(f)
            let report = try await f.sender.sendNext(localProjectID: f.localID, generalOnly: true)
            XCTAssertTrue(report.recoveredFromReceipt)
            let recovered = await f.queue.recoveryCount, claims = await f.queue.generalClaims,
                writes = await f.transport.requests, baselines = await f.transport.generalReads
            XCTAssertEqual(recovered, 1); XCTAssertEqual(claims, 0); XCTAssertTrue(writes.isEmpty); XCTAssertEqual(baselines, 0)
            XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
        }
    }

    func testMissingReceiptStillRequiresMatchingServerBaseline() async throws {
        let f = try await senderFixture(generalDocument: true)
        await prepareRestart(f)
        await f.queue.setRecoveryEligible()
        await f.transport.setPreparationSnapshot(.init(folders: [], documents: [], treeOrders: []))
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let reads = await f.transport.receiptReads, claims = await f.queue.generalClaims, writes = await f.transport.requests
        XCTAssertEqual(reads, 1); XCTAssertEqual(claims, 0); XCTAssertTrue(writes.isEmpty)
    }

    func testMismatchedReceiptDoesNotFallBackToWriteEvenWithExistingC9() async throws {
        let f = try await senderFixture(generalDocument: true)
        let valid = try await installLostReceipt(f)
        var batch = valid.batch.objectValue!; batch["request_sha256"] = .string(String(repeating: "0", count: 64))
        await f.transport.configureReceipt(.init(batch: .object(batch), result: valid.result))
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let recovered = await f.queue.recoveryCount, claims = await f.queue.generalClaims, writes = await f.transport.requests
        XCTAssertEqual(recovered, 0); XCTAssertEqual(claims, 0); XCTAssertTrue(writes.isEmpty)
    }

    func testReceiptReadCannotCompleteAfterGateAccountBindingOrLifecycleChanges() async throws {
        for change in 0..<6 {
            let f = try await senderFixture(generalDocument: true)
            await prepareRestart(f)
            let valid = try await installLostReceipt(f)
            await f.transport.configureReceipt(valid, before: {
                switch change {
                case 0: ContractPathGate.setOpen(false, for: f.localID, in: f.defaults)
                case 1: await f.auth.relogin()
                case 2: f.bindingEpoch.advance()
                case 3: f.localEpoch.advance()
                case 4: GlobalSyncPreference.setEnabled(false, in: f.defaults)
                default: await f.service.updateSceneActivity(false)
                }
            })
            let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
            XCTAssertFalse(completed)
            let recovered = await f.queue.recoveryCount, writes = await f.transport.requests
            XCTAssertEqual(recovered, 0); XCTAssertTrue(writes.isEmpty)
            let permit = await f.coordinator.beginUploadDrain(localProjectID: f.localID, queue: .init(pendingCount: 1))
            XCTAssertNotNil(permit)
            if let permit { await f.coordinator.finishUploadDrain(permit, queue: .init(pendingCount: 1)) }
        }
    }

    func testFailedReceiptReadPreservesTheQueueAndReleasesThePermit() async throws {
        let f = try await senderFixture(generalDocument: true)
        _ = try await installLostReceipt(f)
        await f.transport.failReceiptRead()
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let recovered = await f.queue.recoveryCount, claims = await f.queue.generalClaims, writes = await f.transport.requests
        XCTAssertEqual(recovered, 0); XCTAssertEqual(claims, 0); XCTAssertTrue(writes.isEmpty)
        let retry = await f.sender.nextGeneralRetryDate()
        XCTAssertNotNil(retry)
        let permit = await f.coordinator.beginUploadDrain(localProjectID: f.localID, queue: .init(pendingCount: 1))
        XCTAssertNotNil(permit)
        if let permit { await f.coordinator.finishUploadDrain(permit, queue: .init(pendingCount: 1)) }
    }

    func testWrongDeviceOrInactiveProjectCannotReadOrAcceptReceipt() async throws {
        for wrongDevice in [true, false] {
            let f = try await senderFixture(deviceMismatch: wrongDevice, generalDocument: true)
            _ = try await installLostReceipt(f)
            if !wrongDevice { await f.transport.configureProjectRead(state: .trashed) }
            let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
            XCTAssertFalse(completed)
            let reads = await f.transport.receiptReads, recovered = await f.queue.recoveryCount, writes = await f.transport.requests
            XCTAssertEqual(reads, 0); XCTAssertEqual(recovered, 0); XCTAssertTrue(writes.isEmpty)
        }
    }

    func testGeneralRestartRefreshesHandshakeAndBaselineBeforeOriginalRequest() async throws {
        let f = try await senderFixture(generalDocument: true)
        await prepareRestart(f)
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        let reads = await f.transport.generalReads, requests = await f.transport.requests
        XCTAssertTrue(completed)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(requests, [f.request.json])
        let fresh = await f.service.isFresh(for: f.context)
        XCTAssertTrue(fresh)
    }

    func testGeneralRestartMismatchPreservesUnclaimedRequestAndBacksOff() async throws {
        let f = try await senderFixture(generalDocument: true)
        await prepareRestart(f)
        await f.transport.setPreparationSnapshot(.init(folders: [], documents: [], treeOrders: []))
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let claims = await f.queue.generalClaims, requests = await f.transport.requests
        XCTAssertEqual(claims, 0); XCTAssertTrue(requests.isEmpty)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
        let retry = await f.sender.nextGeneralRetryDate()
        XCTAssertNotNil(retry)
        let again = await f.sender.drainGeneralContract(localProjectID: f.localID)
        let reads = await f.transport.generalReads
        XCTAssertFalse(again); XCTAssertEqual(reads, 2, "예약 전에는 읽기도 반복하지 않는다")
    }

    func testGeneralRestartChangedSecondReadCannotGrantBaseline() async throws {
        let f = try await senderFixture(generalDocument: true)
        await prepareRestart(f)
        await f.transport.setBeforeGeneralRead { count in
            if count == 2 { await f.transport.setPreparationSnapshot(.init(folders: [], documents: [], treeOrders: [])) }
        }
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let claims = await f.queue.generalClaims, requests = await f.transport.requests
        XCTAssertEqual(claims, 0); XCTAssertTrue(requests.isEmpty)
    }

    func testGeneralRestartGateCloseOrReloginDuringReadNeverClaimsOrSends() async throws {
        for relogin in [false, true] {
            let f = try await senderFixture(generalDocument: true)
            await prepareRestart(f)
            await f.transport.setBeforeGeneralRead { count in
                guard count == 1 else { return }
                if relogin { await f.auth.relogin() }
                else { ContractPathGate.setOpen(false, for: f.localID, in: f.defaults) }
            }
            let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
            XCTAssertFalse(completed)
            let claims = await f.queue.generalClaims, requests = await f.transport.requests
            XCTAssertEqual(claims, 0); XCTAssertTrue(requests.isEmpty)
        }
    }

    func testGeneralRestartFailedReadReleasesUploadPermitAndKeepsC9Closed() async throws {
        let f = try await senderFixture(generalDocument: true)
        await f.service.forget(reason: "합성 재시작")
        _ = f.authority.beginBaseline(f.context)
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        XCTAssertNil(f.authority.proof(f.context, requiresActiveServer: false))
        let permit = await f.coordinator.beginUploadDrain(localProjectID: f.localID, queue: .init(pendingCount: 1))
        XCTAssertNotNil(permit)
        if let permit { await f.coordinator.finishUploadDrain(permit, queue: .init(pendingCount: 1)) }
        let claims = await f.queue.generalClaims
        XCTAssertEqual(claims, 0)
    }

    func testGeneralSenderUsesDocumentResponseValidationAndDedicatedClaim() async throws {
        let f = try await senderFixture(generalDocument: true)
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertTrue(completed)
        let claims = await f.queue.generalClaims, requests = await f.transport.requests, saved = await f.queue.completed
        XCTAssertEqual(claims, 1); XCTAssertEqual(requests, [f.request.json]); XCTAssertTrue(saved)
    }

    func testGeneralSenderStopsAfterTransportFailureInsteadOfHotRetrying() async throws {
        let f = try await senderFixture(generalDocument: true)
        await f.transport.configure(reject: true)
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let requests = await f.transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testGeneralSenderHonorsGateClosureAtTransportReservation() async throws {
        let f = try await senderFixture(generalDocument: true)
        await f.transport.configure(before: { ContractPathGate.setOpen(false, for: f.localID, in: f.defaults) })
        let completed = await f.sender.drainGeneralContract(localProjectID: f.localID)
        XCTAssertFalse(completed)
        let requests = await f.transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSenderRechecksEveryAuthorityAfterClaimAndAtTransportReservation() async throws {
        for boundary in 0..<2 {
            for change in 0..<6 {
                let f = try await senderFixture()
                let mutation: @Sendable () async -> Void = {
                    switch change {
                    case 0: ContractPathGate.close(for: f.localID, in: f.defaults)
                    case 1: await f.auth.relogin()
                    case 2: f.bindingEpoch.advance()
                    case 3: await f.service.gateClosed()
                    case 4: await f.service.updateSceneActivity(false)
                    default: GlobalSyncPreference.setEnabled(false, in: f.defaults)
                    }
                }
                if boundary == 0 { await f.queue.setBeforeClaim(mutation) }
                else { await f.transport.configure(before: mutation) }
                do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("변경 뒤 송신됨") }
                catch { }
                let sent = await f.transport.requests
                let failures = await f.queue.failures
                let pending = f.queue.pending
                XCTAssertTrue(sent.isEmpty, "boundary=\(boundary), change=\(change)")
                XCTAssertEqual(failures, [.transmissionNotStarted])
                XCTAssertEqual(pending.request, f.request)
            }
        }
    }

    func testSenderRejectsDeviceMismatchWithoutRewritingBatch() async throws {
        let f = try await senderFixture(deviceMismatch: true)
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("기기가 바뀐 배치 송신됨") }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .invalidStoredRequest) }
        let requests = await f.transport.requests
        let pending = f.queue.pending
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(pending.request, f.request)
    }

    func testUnknownResultRetriesSameBatchAndLateSuccessStaysWithOriginalQueue() async throws {
        let f = try await senderFixture()
        await f.transport.configure(reject: true)
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("통신 실패 기대") } catch { }
        await f.transport.configure(after: { await f.auth.relogin() })
        let report = try await f.sender.sendNext(localProjectID: f.localID)
        let requests = await f.transport.requests
        let completed = await f.queue.completed
        XCTAssertEqual(requests, [f.request.json, f.request.json])
        XCTAssertEqual(report.batchID, f.request.batchID)
        XCTAssertTrue(completed)
        let count = requests.count
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("완료 배치 재송신") } catch { }
        let after = await f.transport.requests.count
        XCTAssertEqual(after, count)
    }

    func testClosingDuringFreshGateValidationPreventsLateOpening() throws {
        let defaults = makeDefaults(), id = ProjectID(rawValue: UUID())
        let revision = ContractPathGate.revision(for: id, in: defaults)
        ContractPathGate.close(for: id, in: defaults)
        XCTAssertFalse(ContractPathGate.openAfterValidation(for: id, in: defaults, revision: revision, validate: { true }))
        XCTAssertFalse(ContractPathGate.isOpen(for: id, in: defaults))
    }
}

extension SyncV2HandshakeTests {
    func testHTTPStatusAndNestedErrorsPreserveRetryPolicy() throws {
        func http(_ status: Int, body: String = "{}") -> HTTPError {
            HTTPError(data: Data(body.utf8), response: HTTPURLResponse(url: URL(string: "https://example.invalid")!,
                statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        for status in [429, 500, 502, 503] {
            let error = http(status, body: "{\"message\":\"temporary service failure\",\"code\":\"PGRST000\"}")
            XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(error), .networkUnavailable)
        }
        XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(http(401)), .authenticationRequired)
        XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(http(403)), .forbidden)
        XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(http(400)), .serverRejected)
        let wrapped = NSError(domain: "transport-wrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(wrapped), .timedOut)
        let rejected = http(500, body: "{\"message\":\"CONTRACT_NOT_ALLOWED\",\"code\":\"P0001\"}")
        XCTAssertEqual(LiveSyncV2HandshakeTransport.classify(rejected), .contractRejected("CONTRACT_NOT_ALLOWED"))
        XCTAssertEqual(LiveSupabaseAuthTransport.map(wrapped, isRestore: true), .networkUnavailable)
        XCTAssertEqual(LiveSupabaseAuthTransport.map(http(403), isRestore: true), .serverRejected)
    }

    func testExplicitGateOpeningRequiresANewReading() async throws {
        let ctx = context(serverProjectID: UUID())
        let transport = StubTransport(results: [
            .success(supportedResponse(projectID: ctx.serverProjectID)),
            .failure(SyncV2HandshakeTransportError.networkUnavailable)
        ])
        let service = SyncV2HandshakeService(transport: transport)
        _ = try await service.refresh(context: ctx)
        await assertThrows(.networkUnavailable) { _ = try await service.refreshForGate(context: ctx) }
        let count = await transport.callCount
        let fresh = await service.isFresh(for: ctx)
        XCTAssertEqual(count, 2)
        XCTAssertFalse(fresh)
    }

    func testSameProjectSenderIsSingleFlightAcrossReservationWait() async throws {
        let f = try await senderFixture()
        let gate = SyncV2OneShotRace<Bool>()
        await f.transport.configure(before: { _ = await gate.value() })
        let first = Task { try await f.sender.sendNext(localProjectID: f.localID) }
        // 첫 전송은 transport 안에서 기다리는 동안에도 슬롯을 점유한다.
        try await Task.sleep(for: .milliseconds(30))
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("중복 송신") }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .uploadPullGateBusy) }
        await gate.resolve(true)
        _ = try await first.value
        let count = await f.transport.requests.count
        XCTAssertEqual(count, 1)
    }
}

extension SyncV2HandshakeTests {
    private actor BackoffSleeper {
        private(set) var delays: [Duration] = []
        func sleep(_ delay: Duration) async throws {
            if delay == .seconds(120) { try await Task.sleep(for: delay) }
            else { delays.append(delay); await Task.yield() }
        }
    }

    func testAutomaticBackoffReachesCapAndResetsOnRelogin() async throws {
        let local = ProjectID(rawValue: UUID()), server = UUID(), account = UUID()
        let auth = LifecycleAuth(account: account)
        let bindings = LifecycleBindings([.connected(localProjectID: local, serverProjectID: server,
            kind: .existingServerProject, projectName: "지연 시험", ownerSubject: account)])
        let transient: Result<SyncV2HandshakeResponse, Error> = .failure(SyncV2HandshakeTransportError.networkUnavailable)
        let success: Result<SyncV2HandshakeResponse, Error> = .success(supportedResponse(projectID: server))
        let transport = StubTransport(results: Array(repeating: transient, count: 7) + [success, transient, success])
        let sleeper = BackoffSleeper()
        let service = SyncV2HandshakeService(transport: transport, now: { Date(timeIntervalSince1970: 100) },
            timeout: .seconds(120), sleep: { try await sleeper.sleep($0) })
        await service.observeProject(local, authentication: auth, bindings: bindings)
        let original = SyncV2HandshakeContext(localProjectID: local, serverProjectID: server, accountID: account)
        await eventually { await service.isFresh(for: original) }
        await auth.relogin()
        let renewed = SyncV2HandshakeContext(localProjectID: local, serverProjectID: server, accountID: account, authenticationEpoch: 1)
        await eventually { await service.isFresh(for: renewed) }
        let delays = await sleeper.delays
        XCTAssertEqual(delays, [2,4,8,16,32,60,60,2].map { .seconds($0) })
        await service.stopObserving()
    }

    @MainActor
    func testLocalWritingCompletesWhileAutomaticHandshakeWaitsForNetwork() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "오프라인 시험")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let loaded = try await environment.documentRepository.document(id: volume.documentToOpenID)
        let document = try XCTUnwrap(loaded)
        let server = UUID(), account = UUID()
        let auth = LifecycleAuth(account: account)
        let bindings = LifecycleBindings([.connected(localProjectID: project.id, serverProjectID: server,
            kind: .existingServerProject, projectName: project.name, ownerSubject: account)])
        let transport = ControlledTransport(), service: SyncV2HandshakeService
        service = SyncV2HandshakeService(transport: transport)
        await service.observeProject(project.id, authentication: auth, bindings: bindings)
        await eventually { await transport.count == 1 }
        _ = try await environment.localDocumentStore.save(.init(projectID: project.id, documentID: document.id,
            relativePath: document.relativePath, text: "통신 대기 중 저장한 시험 문장", generation: 1))
        let text = try await environment.localDocumentStore.loadText(for: document)
        XCTAssertEqual(text, "통신 대기 중 저장한 시험 문장")
        await transport.finish(.success(supportedResponse(projectID: server)))
        let context = SyncV2HandshakeContext(localProjectID: project.id, serverProjectID: server, accountID: account)
        await eventually { await service.isFresh(for: context) }
        await service.stopObserving()
    }
}

extension SyncV2HandshakeTests {
    @MainActor
    func testSettingsOpensOnlyAfterFreshResponseAndClosingWinsAgainstLateResponse() async throws {
        for closeDuringWait in [false, true] {
            let environment = try AppEnvironment.testing()
            let project = try await environment.projectManager.createProject(named: "관문 화면 시험")
            let server = UUID(), account = UUID()
            let auth = LifecycleAuth(account: account)
            let binding = ProjectSyncBinding.connected(localProjectID: project.id, serverProjectID: server,
                kind: .existingServerProject, projectName: project.name, ownerSubject: account)
            let bindings = LifecycleBindings([binding])
            let transport = ControlledTransport()
            let service = SyncV2HandshakeService(transport: transport)
            let defaults = makeDefaults(function: UUID().uuidString)
            let model = SyncSettingsModel(projectManager: environment.projectManager, authenticationService: auth,
                projectBindingService: bindings, syncDispatcher: nil, handshakeService: service, defaults: defaults)
            let row = SyncProjectRow(project: project, binding: binding)
            let opening = model.setGateOpen(true, for: row)
            await eventually { await transport.count == 1 }
            XCTAssertFalse(ContractPathGate.isOpen(for: project.id, in: defaults))
            if closeDuringWait { await model.setGateOpen(false, for: row).value }
            await transport.finish(.success(supportedResponse(projectID: server)))
            await opening.value
            XCTAssertEqual(model.isGateOpen(for: row), !closeDuringWait)
            XCTAssertEqual(ContractPathGate.isOpen(for: project.id, in: defaults), !closeDuringWait)
            if closeDuringWait { XCTAssertEqual(model.gateReport, "관문 화면 시험 관문: 닫힘") }
        }
    }
}

extension SyncV2HandshakeTests {
    func testLateContractRejectionCannotInvalidateNewHandshake() async throws {
        let server = UUID(), ctx = context(serverProjectID: UUID())
        let transport = StubTransport(results: [
            .success(supportedResponse(projectID: ctx.serverProjectID)),
            .success(supportedResponse(projectID: server))
        ])
        let service = SyncV2HandshakeService(transport: transport)
        _ = try await service.refresh(context: ctx)
        let originalGeneration = service.authorizationEpoch.value
        let next = context(serverProjectID: server)
        _ = try await service.refresh(context: next)
        await service.forgetIfStale(.forbidden, expectedGeneration: originalGeneration)
        let fresh = await service.isFresh(for: next)
        XCTAssertTrue(fresh)
    }
}

extension SyncV2HandshakeTests {
    @MainActor
    func testLateContractReceiptIsStoredWithoutPublishingIntoChangedScreen() async throws {
        for changeAccount in [false, true] {
            let f = try await senderFixture()
            let environment = try AppEnvironment.testing()
            let bindings = LifecycleBindings([f.queue.savedBinding])
            let model = SyncSettingsModel(projectManager: environment.projectManager, authenticationService: f.auth,
                projectBindingService: bindings, syncDispatcher: nil, handshakeService: f.service,
                contractStructureSender: f.sender, defaults: f.defaults)
            let project = ManagedProject(project: Project(id: f.localID, name: "원래 작품", createdAt: Date(), modifiedAt: Date()), userOrder: 0, lifecycleState: .active)
            await f.transport.configure(after: {
                if changeAccount { await f.auth.relogin() }
                else { await f.service.projectChanged() }
            })
            await model.sendOneContractBatch(for: SyncProjectRow(project: project, binding: f.queue.savedBinding))
            let completed = await f.queue.completed
            XCTAssertTrue(completed)
            XCTAssertNil(model.contractSendReport)
        }
    }
}


extension SyncV2HandshakeTests {
    func testC9BlocksStructureAndProjectTransitionsAtBothDispatchBoundaries() async throws {
        for boundary in 0..<2 {
            for change in 0..<7 {
                let f = try await senderFixture()
                let mutation: @Sendable () async -> Void = {
                    switch change {
                    case 0: _ = f.authority.beginBaseline(f.context)
                    case 1:
                        let token = f.authority.beginBaseline(f.context)
                        f.authority.finishBaseline(f.context, token: token, allowed: false)
                    case 2: await f.coordinator.restore(localProjectID: f.localID, queue: .init(blockedCount: 1))
                    case 3: await f.coordinator.restore(localProjectID: f.localID, queue: .init(conflictCount: 1))
                    case 4: f.localEpoch.beginTransition()
                    case 5:
                        let token = f.authority.beginServerRead(f.context)
                        f.authority.finishServerRead(f.context, token: token, state: .trashed)
                    default: _ = f.authority.beginServerRead(f.context)
                    }
                }
                if boundary == 0 { await f.queue.setBeforeClaim(mutation) }
                else { await f.transport.configure(before: mutation) }
                do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("차단 후 송신") }
                catch { }
                let requests = await f.transport.requests
                let failures = await f.queue.failures
                XCTAssertTrue(requests.isEmpty, "boundary=\(boundary) change=\(change)")
                XCTAssertEqual(failures, [.transmissionNotStarted])
                XCTAssertEqual(f.queue.pending.request, f.request)
            }
        }
    }

    func testC9RejectsUnknownBaselineAndInactiveServerBeforeClaim() async throws {
        for change in 0..<5 {
            let f = try await senderFixture(localIsActive: change != 3)
            if change == 0 { _ = f.authority.beginBaseline(f.context) }
            else if change == 1 || change == 2 { await f.transport.configureProjectRead(state: change == 1 ? .trashed : .purged) }
            else if change == 4 { await f.transport.configureProjectRead(fails: true) }
            do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("미확인/비활성 작품 송신") }
            catch { }
            let requests = await f.transport.requests
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(f.queue.pending.request, f.request)
        }
    }

    func testC9LateActiveServerReadingCannotClearNewStructureBlock() async throws {
        let f = try await senderFixture()
        await f.transport.configureProjectRead(before: {
            await f.coordinator.restore(localProjectID: f.localID, queue: .init(blockedCount: 1))
            await f.coordinator.restore(localProjectID: f.localID, queue: .idle)
        })
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("차단 수명이 바뀐 요청 송신") }
        catch { }
        let requests = await f.transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testC9BaselineIsScopedAndLatePullCannotReplaceNewBlock() throws {
        let authority = SyncV2ContractStructureAuthority()
        let first = context(serverProjectID: UUID())
        let old = authority.beginBaseline(first)
        let current = authority.beginBaseline(first)
        authority.finishBaseline(first, token: current, allowed: false)
        authority.finishBaseline(first, token: old, allowed: true)
        XCTAssertNil(authority.proof(first, requiresActiveServer: false))
        let fresh = authority.beginBaseline(first)
        authority.finishBaseline(first, token: fresh, allowed: true)
        XCTAssertNotNil(authority.proof(first, requiresActiveServer: false))
        let relogin = SyncV2HandshakeContext(localProjectID: first.localProjectID, serverProjectID: first.serverProjectID,
            accountID: first.accountID, authenticationEpoch: 1)
        XCTAssertNil(authority.proof(relogin, requiresActiveServer: false))
    }

    func testC9LocalEnqueueDoesNotInvalidateConfirmedStructureBaseline() async throws {
        let f = try await senderFixture()
        let reservation = await f.coordinator.beginEnqueue(localProjectID: f.localID)
        await f.coordinator.finishEnqueue(reservation, queue: .init(pendingCount: 1))
        let snapshot = await f.coordinator.snapshot(localProjectID: f.localID)
        XCTAssertFalse(snapshot.lastPullSucceeded)
        _ = try await f.sender.sendNext(localProjectID: f.localID)
        let requests = await f.transport.requests
        XCTAssertEqual(requests, [f.request.json])
    }

    func testC9StartedReceiptRemainsValidAfterStructureAndProjectBlock() async throws {
        let f = try await senderFixture()
        await f.transport.configure(after: {
            _ = f.authority.beginBaseline(f.context)
            f.localEpoch.advance()
            let token = f.authority.beginServerRead(f.context)
            f.authority.finishServerRead(f.context, token: token, state: .purged)
        })
        let receipt = try await f.sender.sendNext(localProjectID: f.localID)
        let completed = await f.queue.completed
        XCTAssertTrue(completed)
        XCTAssertEqual(receipt.batchID, f.request.batchID)
        XCTAssertFalse(receipt.mayPresentCompletion)
    }

    func testC9RestoredServerProjectIsReadAgainAndUsesSamePendingBatch() async throws {
        let f = try await senderFixture()
        await f.transport.configureProjectRead(state: .trashed)
        do { _ = try await f.sender.sendNext(localProjectID: f.localID); XCTFail("삭제 작품 전송") } catch { }
        await f.transport.configureProjectRead(state: .active)
        let receipt = try await f.sender.sendNext(localProjectID: f.localID)
        let requests = await f.transport.requests
        XCTAssertEqual(requests, [f.request.json])
        XCTAssertEqual(receipt.batchID, f.request.batchID)
    }

    func testC9ProjectStatusDecodingFailsClosed() throws {
        let id = UUID()
        for state in ["active", "trashed", "purged"] {
            let data = try JSONEncoder().encode(["project_id": id.uuidString, "state": state])
            XCTAssertEqual(try SyncV2ContractProjectStatus.decode(data, expectedProjectID: id).rawValue, state)
        }
        for fields in [["state": "active"], ["project_id": id.uuidString, "state": "unknown"],
                       ["project_id": UUID().uuidString, "state": "active"]] {
            XCTAssertThrowsError(try SyncV2ContractProjectStatus.decode(JSONEncoder().encode(fields), expectedProjectID: id))
        }
    }

    func testRecoveryDiagnosticSchemaContainsOnlyTimingAndOpaqueIdentifiers() throws {
        let event = SyncV2RecoveryDiagnostics.Entry(sessionID: UUID(), timestamp: Date(), uptime: 1,
            stage: .handshake, event: .retryScheduled, projectID: UUID(), operationID: UUID(), attempt: 2, retryAt: Date())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["sessionID", "timestamp", "uptime", "stage", "event", "projectID", "operationID", "attempt", "retryAt"]))
    }

    func testRecoveryDiagnosticActuallyPersistsWithinSizeLimit() async throws {
        let operation = UUID()
        SyncV2RecoveryDiagnostics.record(stage: .handshake, event: .retryScheduled, operationID: operation, attempt: 2)
        let files = await SyncV2RecoveryDiagnostics.persistedDataForTesting()
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.count <= 524_288 })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entries = try files.flatMap { data in
            try data.split(separator: 0x0A).map { try decoder.decode(SyncV2RecoveryDiagnostics.Entry.self, from: Data($0)) }
        }
        XCTAssertTrue(entries.contains { $0.operationID == operation && $0.attempt == 2 })
    }
}

extension SyncV2HandshakeTests {
    private struct DurableSenderFixture: @unchecked Sendable {
        let base: SenderFixture
        let store: LazySyncV2ProjectBindingStore
        let secondStore: SyncV2Store
        let recorder: SyncV2ContractPathRecorder
        let sender: SyncV2ContractStructureSender
        let request: SyncV2ContractRequest
        let deviceID: UUID
    }

    private func durableSenderFixture() async throws -> DurableSenderFixture {
        let f = try await senderFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite3")
        let deviceID = UUID(uuidString: f.request.json.objectValue!["batch"]!.objectValue!["writer_device_id"]!.stringValue!)!
        let device = DeviceIdentityService(store: InMemoryDeviceIdentityStore(), generateUUID: { deviceID })
        let store = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: device,
                                                 uploadPullCoordinator: f.coordinator)
        try await store.save(f.queue.savedBinding)
        guard case .available(let secondStore) = await SyncV2Store.open(at: url) else {
            throw SyncV2DispatchStoreError.unavailable
        }
        addTeardownBlock { await secondStore.close() }
        try await store.applyTreeOrderSnapshotBaselines(localProjectID: f.localID,
            serverProjectID: f.context.serverProjectID,
            treeOrders: [.init(treeOrderID: UUID(), parentFolderID: nil, children: [], revision: 1, updatedAt: Date())])
        let recorder = SyncV2ContractPathRecorder(store: store, handshakeService: f.service,
            authenticationService: f.auth, defaults: ContractDefaults(value: f.defaults), bindingEpoch: f.bindingEpoch,
            structureAuthority: f.authority, localProjectEpoch: f.localEpoch, isLocalProjectActive: { _ in true })
        let batch = LocalMutationBatch(batchID: UUID(), projectID: f.localID, localTransactionID: nil,
            kind: .structureChange, mutations: [
                .folderSnapshot(operationID: UUID(), folderID: .init(rawValue: UUID()), parentFolderID: nil,
                                name: "격리 계약 폴더", isDeleted: false),
                .treeOrder(operationID: UUID(), content: "{\"tree_order\":{},\"version\":1}", generation: 1)])
        guard case .queued = await recorder.record(batch) else { throw SyncV2ContractStructureError.invalidStoredRequest }
        let pending = try await store.claimNextContractStructure(localProjectID: f.localID)
        await store.failContractStructure(pending, error: SyncV2ContractStructureError.transmissionNotStarted, response: nil)
        let sender = SyncV2ContractStructureSender(store: store, transport: f.transport,
            handshakeService: f.service, authenticationService: f.auth, uploadPullCoordinator: f.coordinator,
            defaults: ContractDefaults(value: f.defaults), bindingEpoch: f.bindingEpoch, deviceIdentityProvider: device,
            structureAuthority: f.authority, localProjectEpoch: f.localEpoch, isLocalProjectActive: { _ in true })
        return .init(base: f, store: store, secondStore: secondStore, recorder: recorder,
                     sender: sender, request: pending.request, deviceID: deviceID)
    }

    /// 첫 작업의 오류는 실제 dispatcher가 기록한다. 다음 작업의 응답을 만들 때
    /// 다른 DB 인스턴스에서 첫 작업을 해소하므로 coordinator에는 최종 상태만 간다.
    private actor ResolvingDispatchClient: SyncV2CommitClienting {
        let store: SyncV2Store
        let code: SyncV2RemoteErrorCode
        var firstOperationID: UUID?
        var calls = 0
        init(store: SyncV2Store, code: SyncV2RemoteErrorCode) { self.store = store; self.code = code }
        func advance(_ operationID: UUID) async throws {
            calls += 1
            if firstOperationID == nil {
                firstOperationID = operationID
                throw SyncV2ClientError.remote(code: code, detail: nil)
            }
            let events = try await store.operationEvents(operationID: firstOperationID!)
            guard events.last?.type == (code == .forbidden ? .blocked : .conflictDetected) else {
                throw SyncV2DispatchStoreError.integrityFailure
            }
            try await store.cancelOperation(operationID: firstOperationID!, cancelEventID: UUID())
        }
        func commitDocument(_ p: SyncV2CommitDocumentParameters) async throws -> SyncV2CommitDocumentResult {
            try await advance(p.operationID)
            return .init(status: .committed, documentID: p.documentID, versionID: UUID(), operationID: p.operationID,
                operationKind: .create, serverRevision: 1, relativePath: p.relativePath, isDeleted: false,
                contentHash: SHA256ContentHasher().sha256(for: Data(p.content.utf8)).rawValue, committedAt: Date())
        }
        func commitFolder(_ p: SyncV2CommitFolderParameters) async throws -> SyncV2CommitFolderResult {
            try await advance(p.operationID)
            return .init(status: .committed, folderID: p.folderID, operationID: p.operationID,
                serverRevision: 1, parentFolderID: p.parentFolderID, name: p.name, isDeleted: false, committedAt: Date())
        }
    }

    func testC9UnobservedDurableTransitionsDuringStatusReadPreventWrite() async throws {
        for folder in [false, true] {
            for conflict in [false, true] {
                let f = try await durableSenderFixture()
                // 폴더의 기존 전송도 실제 저장소/dispatcher 경로를 거친다.
                let operations = (0..<2).map { index -> SyncV2Mutation in
                    if folder { return .folder(.init(operationID: UUID(), folderID: UUID(), parentFolderID: nil,
                        deviceID: f.deviceID, name: "기존 폴더 \(index)", isDeleted: false)) }
                    return .document(.init(operationID: UUID(), documentID: UUID(), deviceID: f.deviceID,
                        localSaveGeneration: 1, kind: .documentCommit, localPath: "원고/\(index).txt",
                        relativePath: "원고/\(index).txt", content: "격리 시험", isDeleted: false))
                }
                _ = try await f.secondStore.enqueue(.init(batchID: UUID(), localProjectID: f.base.localID,
                    localTransactionID: nil, kind: .documentSave, mutations: operations))
                let client = ResolvingDispatchClient(store: f.secondStore, code: conflict ? .pathConflict : .forbidden)
                let dispatcher = SyncV2Dispatcher(store: f.store, client: client, maximumConcurrentDocuments: 1,
                                                  uploadPullCoordinator: f.base.coordinator)
                await f.base.transport.configureProjectRead(before: {
                    await dispatcher.dispatchReadyOperations(now: Date())
                })
                do { _ = try await f.sender.sendNext(localProjectID: f.base.localID); XCTFail("미관측 차단·해소 뒤 이전 준비로 송신됨") }
                catch { }
                let requests = await f.base.transport.requests
                let calls = await client.calls
                let queue = try await f.store.uploadQueueSnapshot(localProjectID: f.base.localID)
                XCTAssertEqual(calls, 2)
                XCTAssertEqual(queue.blockedCount + queue.conflictCount, 0)
                XCTAssertTrue(requests.isEmpty, "folder=\(folder), conflict=\(conflict)")
                guard requests.isEmpty else { continue }
                let pending = try await f.store.claimNextContractStructure(localProjectID: f.base.localID)
                XCTAssertEqual(pending.request, f.request)
                await f.store.failContractStructure(pending, error: SyncV2ContractStructureError.transmissionNotStarted, response: nil)
                await f.base.transport.configureProjectRead()
                let report = try await f.sender.sendNext(localProjectID: f.base.localID)
                XCTAssertEqual(report.batchID, f.request.batchID)
                let resumed = await f.base.transport.requests
                XCTAssertEqual(resumed, [f.request.json])
            }
        }
    }
}

extension SyncV2HandshakeTests {
    private static func enqueueDurableDocument(_ f: DurableSenderFixture) async throws -> UUID {
        let operationID = UUID(), documentID = DocumentID(rawValue: UUID())
        let content = "일반 저장 시험"
        let batch = LocalMutationBatch(batchID: UUID(), projectID: f.base.localID, localTransactionID: nil,
            mutations: [.documentSnapshot(operationID: operationID, documentID: documentID,
                relativePath: .init(rawValue: "원고/\(documentID.rawValue).txt"), content: content,
                contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 1, isDeleted: false)])
        guard case .queued = await f.recorder.record(batch) else { throw SyncV2DispatchStoreError.integrityFailure }
        return operationID
    }

    func testC9DurableTransitionsAtFinalTransportPreserveAndResumeBatch() async throws {
        for conflict in [false, true] {
            let f = try await durableSenderFixture()
            let operationID = try await Self.enqueueDurableDocument(f)
            let claimed = try await f.store.claimReadyOperations(localProjectID: f.base.localID, limit: 1, now: Date())
            let operation = try XCTUnwrap(claimed.first)
            XCTAssertEqual(operation.operationID, operationID)
            await f.base.transport.configure(before: {
                do {
                    if conflict { try await f.store.markConflict(operation, errorCode: "PATH_CONFLICT", detail: nil) }
                    else { try await f.store.markBlocked(operation, errorCode: "FORBIDDEN", detail: nil) }
                    try await f.secondStore.cancelOperation(operationID: operationID, cancelEventID: UUID())
                } catch { XCTFail("실제 저장소 전이 실패: \(error)") }
            })
            do { _ = try await f.sender.sendNext(localProjectID: f.base.localID); XCTFail("최종 경계의 미관측 전이 누락") }
            catch { }
            let requests = await f.base.transport.requests
            XCTAssertTrue(requests.isEmpty)
            let pending = try await f.store.claimNextContractStructure(localProjectID: f.base.localID)
            XCTAssertEqual(pending.request, f.request)
            await f.store.failContractStructure(pending, error: SyncV2ContractStructureError.transmissionNotStarted, response: nil)
            await f.base.transport.configure()
            let report = try await f.sender.sendNext(localProjectID: f.base.localID)
            XCTAssertEqual(report.batchID, f.request.batchID)
            let resumed = await f.base.transport.requests
            XCTAssertEqual(resumed, [f.request.json])
        }
    }

    func testC9ActualNormalRecorderEnqueueDoesNotInvalidatePreparedSend() async throws {
        for finalBoundary in [false, true] {
            let f = try await durableSenderFixture()
            let mutation: @Sendable () async -> Void = {
                do { _ = try await Self.enqueueDurableDocument(f) }
                catch { XCTFail("일반 저장 실패: \(error)") }
            }
            if finalBoundary { await f.base.transport.configure(before: mutation) }
            else { await f.base.transport.configureProjectRead(before: mutation) }
            let report = try await f.sender.sendNext(localProjectID: f.base.localID)
            XCTAssertEqual(report.batchID, f.request.batchID)
            let requests = await f.base.transport.requests
            XCTAssertEqual(requests, [f.request.json])
        }
    }

    func testC9QueueHistoryFailsClosedAndDetectsCrossConnectionResolution() async throws {
        let f = try await durableSenderFixture()
        // 존재하지 않는 경로는 빈 이력으로 승인되어서는 안 된다.
        let unavailable = SyncV2ContractQueueHistory(databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.sqlite3"), localProjectID: f.base.localID)
        XCTAssertThrowsError(try unavailable.authorization())
        let operationID = try await Self.enqueueDurableDocument(f)
        let operations = try await f.store.claimReadyOperations(localProjectID: f.base.localID, limit: 1, now: Date())
        let operation = try XCTUnwrap(operations.first)
        let old = try await f.store.contractQueueAuthorization(localProjectID: f.base.localID)
        try await f.store.markBlocked(operation, errorCode: "FORBIDDEN", detail: nil)
        XCTAssertThrowsError(try old())
        do { _ = try await f.store.contractQueueAuthorization(localProjectID: f.base.localID); XCTFail("현재 차단 승인") }
        catch { }
        try await f.secondStore.cancelOperation(operationID: operationID, cancelEventID: UUID())
        XCTAssertThrowsError(try old())
        let fresh = try await f.store.contractQueueAuthorization(localProjectID: f.base.localID)
        XCTAssertNoThrow(try fresh())
    }
}

extension SyncV2HandshakeTests {
    func testC9ActualConflictPreservationAndResolutionInvalidateOldPreparation() async throws {
        let f = try await durableSenderFixture()
        _ = try await Self.enqueueDurableDocument(f)
        let claimed = try await f.store.claimReadyOperations(localProjectID: f.base.localID, limit: 1, now: Date())
        let operation = try XCTUnwrap(claimed.first)
        let local = try await f.store.latestLocalSnapshot(for: operation)
        await f.base.transport.configureProjectRead(before: {
            do {
                let remote = SyncV2RemoteDocumentSnapshot(documentID: operation.documentID,
                    relativePath: operation.relativePath, content: "서버 시험 문장", revision: 1,
                    isDeleted: false, deletedAt: nil, updatedAt: Date())
                _ = try await f.store.preserveConflict(operation, remote: remote, local: local,
                    mergedContent: "충돌 시험", conflictCount: 1, errorCode: "REVISION_CONFLICT", detail: nil)
                let found = try await f.store.unresolvedConflict(documentID: operation.documentID)
                let conflict = try XCTUnwrap(found)
                let resolvedID = UUID(), resolvedContent = "해소한 시험 문장"
                // 화면의 중간 snapshot 전달 없이 저장소의 실제 해소 경로를 검증한다.
                _ = try await f.secondStore.enqueue(.init(batchID: UUID(), localProjectID: f.base.localID,
                    localTransactionID: nil, kind: .documentSave, mutations: [.document(.init(operationID: resolvedID,
                        documentID: operation.documentID, deviceID: f.deviceID, localSaveGeneration: 2,
                        kind: .documentCommit, localPath: operation.localPath, relativePath: operation.relativePath,
                        content: resolvedContent, isDeleted: false))]))
                try await f.store.resolveConflict(.init(conflictID: conflict.conflictID, documentID: operation.documentID,
                    resolutionOperationID: resolvedID, resolvedContent: resolvedContent, kind: .manualMerge))
            } catch { XCTFail("실제 충돌 해소 실패: \(error)") }
        })
        do { _ = try await f.sender.sendNext(localProjectID: f.base.localID); XCTFail("충돌 보존·해소 뒤 옛 준비 승인") }
        catch { }
        let requests = await f.base.transport.requests
        XCTAssertTrue(requests.isEmpty)
        let queue = try await f.store.uploadQueueSnapshot(localProjectID: f.base.localID)
        XCTAssertEqual(queue.blockedCount + queue.conflictCount, 0)
        let pending = try await f.store.claimNextContractStructure(localProjectID: f.base.localID)
        XCTAssertEqual(pending.request, f.request)
        await f.store.failContractStructure(pending, error: SyncV2ContractStructureError.transmissionNotStarted, response: nil)
        await f.base.transport.configureProjectRead()
        let report = try await f.sender.sendNext(localProjectID: f.base.localID)
        XCTAssertEqual(report.batchID, f.request.batchID)
    }
}

extension SyncV2HandshakeTests {
    private actor PreparationNodes {
        var nodes: [DocumentNode]
        init(_ nodes: [DocumentNode]) { self.nodes = nodes }
        func read() -> [DocumentNode] { nodes }
        func removeLast() { nodes.removeLast() }
    }

    private struct PreparationFixture {
        let base: SenderFixture
        let store: LazySyncV2ProjectBindingStore
        let sender: SyncV2ContractStructureSender
        let nodes: PreparationNodes
        let snapshot: SyncV2PreparationSnapshot
        let url: URL
    }

    private func preparationFixture() async throws -> PreparationFixture {
        let scope = SyncV2EmptyVolumeReview.self
        let f = try await senderFixture(serverID: scope.projectID)
        ContractPathGate.close(for: f.localID, in: f.defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sync.sqlite3")
        let deviceID = UUID(uuidString: f.request.json.objectValue!["batch"]!.objectValue!["writer_device_id"]!.stringValue!)!
        let device = DeviceIdentityService(store: InMemoryDeviceIdentityStore(), generateUUID: { deviceID })
        let store = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: device, uploadPullCoordinator: f.coordinator)
        try await store.save(f.queue.savedBinding)
        let mainID = UUID()
        var folderInfo: [(UUID, UUID?, String, String)] = [(mainID, nil, "메인", "메인")]
        for category in BinderFixedCategory.allCases {
            let id = category == .manuscript ? scope.parentID : UUID()
            let path = category.relativePath.rawValue
            folderInfo.append((id, mainID, String(path.split(separator: "/").last!), path))
        }
        folderInfo.append((scope.volumeID, scope.parentID, "1권", "메인/원고/1권"))
        let folders: [SyncV2JSON] = folderInfo.map { id, parent, name, _ in
            .object(["folder_id": .string(id.uuidString.lowercased()), "project_id": .string(scope.projectID.uuidString.lowercased()),
                "parent_folder_id": parent.map { .string($0.uuidString.lowercased()) } ?? .null,
                "name": .string(name), "revision": .int(1), "is_deleted": .bool(false)])
        }
        var nodes = folderInfo.enumerated().map { index, info in
            DocumentNode(id: .init(rawValue: info.0), projectID: f.localID, kind: .folder,
                parentID: info.1.map { .init(rawValue: $0) }, relativePath: .init(rawValue: info.3),
                userOrder: index, modifiedAt: Date(), contentHash: nil)
        }
        var documents: [SyncV2JSON] = []
        for index in 1...26 {
            let id = UUID(), path = index == 26 ? syncV2TreeOrderPath : "메인/원고/1권/\(String(format: "%03d", index))화.txt"
            documents.append(.object(["document_id": .string(id.uuidString.lowercased()),
                "project_id": .string(scope.projectID.uuidString.lowercased()), "relative_path": .string(path),
                "revision": .int(1), "parent_folder_id": .null, "name": .null, "structure_revision": .null, "is_deleted": .bool(false)]))
            if index < 26 {
                nodes.append(.init(id: .init(rawValue: id), projectID: f.localID, kind: .text,
                    parentID: .init(rawValue: scope.volumeID), relativePath: .init(rawValue: path),
                    userOrder: index, modifiedAt: Date(), contentHash: nil))
            }
        }
        let snapshot = SyncV2PreparationSnapshot(folders: folders, documents: documents, treeOrders: [])
        let local = PreparationNodes(nodes)
        await f.transport.setPreparationSnapshot(snapshot)
        try await store.applyFolderSnapshotBaselines(localProjectID: f.localID, serverProjectID: scope.projectID,
            folders: folderInfo.map { .init(folderID: $0.0, parentFolderID: $0.1, name: $0.2, revision: 1, isDeleted: false, updatedAt: Date()) }, excluding: [])
        let sender = SyncV2ContractStructureSender(store: store, transport: f.transport,
            handshakeService: f.service, authenticationService: f.auth, uploadPullCoordinator: f.coordinator,
            defaults: ContractDefaults(value: f.defaults), bindingEpoch: f.bindingEpoch, deviceIdentityProvider: device,
            structureAuthority: f.authority, localProjectEpoch: f.localEpoch, isLocalProjectActive: { _ in true },
            localDocuments: { _ in await local.read() })
        return .init(base: f, store: store, sender: sender, nodes: local, snapshot: snapshot, url: url)
    }

    func testClosedGatePreparationPersistsExportsAndNeverEntersOrdinaryQueue() async throws {
        let f = try await preparationFixture()
        let before = await f.nodes.read()
        let value = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        let again = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        XCTAssertEqual(value, again)
        XCTAssertEqual(try value.exportData(), try again.exportData())
        XCTAssertFalse(ContractPathGate.isOpen(for: f.base.localID, in: f.base.defaults))
        let requests = await f.base.transport.requests
        XCTAssertTrue(requests.isEmpty)
        let after = await f.nodes.read()
        XCTAssertEqual(before, after)
        let queue = try await f.store.uploadQueueSnapshot(localProjectID: f.base.localID)
        XCTAssertEqual(queue, .idle)
        let order = try await f.store.storedTreeOrder(localProjectID: f.base.localID, parentFolderID: SyncV2EmptyVolumeReview.parentID)
        XCTAssertNil(order)
        do { _ = try await f.store.claimNextContractStructure(localProjectID: f.base.localID); XCTFail("검토 배치가 일반 claim에 나타남") }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .noReadyBatch) }
        let reopened = LazySyncV2ProjectBindingStore(databaseURL: f.url)
        let restored = try await reopened.contractPreparation(localProjectID: f.base.localID)
        XCTAssertEqual(restored, value)
        let exported = try JSONDecoder().decode(SyncV2JSON.self, from: value.exportData())
        XCTAssertEqual(exported.objectValue?["request"], value.requestJSON)
        XCTAssertNil(exported.objectValue?["accountID"])
        XCTAssertFalse(String(decoding: try value.exportData(), as: UTF8.self).contains("001화"))
    }

    func testReviewedPreparationUsesExactRequestThroughRealStoreAndSender() async throws {
        let f = try await preparationFixture()
        let value = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
        do { _ = try await f.sender.sendNext(localProjectID: f.base.localID); XCTFail("일반 송신이 검토 배치를 claim함") }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .noReadyBatch) }
        let report = try await f.sender.sendNext(localProjectID: f.base.localID,
            preparedBatchID: value.request.batchID, reviewedRequestSHA256: value.requestSHA256)
        XCTAssertEqual(report.operationCount, 2)
        let requests = await f.base.transport.requests
        XCTAssertEqual(requests, [value.requestJSON])
        let order = try await f.store.storedTreeOrder(localProjectID: f.base.localID, parentFolderID: SyncV2EmptyVolumeReview.parentID)
        XCTAssertEqual(order?.serverRevision, 1)
        XCTAssertEqual(order?.children.first, SyncV2EmptyVolumeReview.volumeID)
        XCTAssertEqual(order?.children.count, 2)
        let nodes = await f.nodes.read()
        XCTAssertEqual(nodes.count, 36)
    }

    func testPreparationRejectsChangedLocalAndServerBaselinesAndWrongReviewHash() async throws {
        for condition in 0..<3 {
            let f = try await preparationFixture()
            let value = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
            if condition == 0 { await f.nodes.removeLast() }
            if condition == 1 {
                await f.base.transport.setPreparationSnapshot(.init(folders: f.snapshot.folders,
                    documents: Array(f.snapshot.documents.dropLast()), treeOrders: []))
            }
            ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
            do {
                _ = try await f.sender.sendNext(localProjectID: f.base.localID,
                    preparedBatchID: value.request.batchID,
                    reviewedRequestSHA256: condition == 2 ? String(repeating: "0", count: 64) : value.requestSHA256)
                XCTFail("바뀐 기준/해시로 전송함")
            } catch {}
            let requests = await f.base.transport.requests
            XCTAssertTrue(requests.isEmpty)
            let saved = try await f.store.contractPreparation(localProjectID: f.base.localID)
            XCTAssertEqual(saved, value)
        }
    }

    func testPreparationRejectsOpenGateAndIncompleteMetadata() async throws {
        let f = try await preparationFixture()
        ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
        do { _ = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .preparationRequiresClosedGate) }
        ContractPathGate.close(for: f.base.localID, in: f.base.defaults)
        await f.base.transport.setPreparationSnapshot(.init(folders: Array(f.snapshot.folders.dropLast()), documents: f.snapshot.documents, treeOrders: []))
        do { _ = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .unsupportedPreparationBaseline) }
        let saved = try await f.store.contractPreparation(localProjectID: f.base.localID)
        XCTAssertNil(saved)
    }

    func testReviewedPreparationC9FinalBlockKeepsSameRequestForExplicitRetry() async throws {
        let f = try await preparationFixture()
        let value = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
        await f.base.transport.configure(before: { _ = f.base.authority.beginBaseline(f.base.context) })
        do {
            _ = try await f.sender.sendNext(localProjectID: f.base.localID,
                preparedBatchID: value.request.batchID, reviewedRequestSHA256: value.requestSHA256)
            XCTFail()
        } catch {}
        let requests = await f.base.transport.requests
        XCTAssertTrue(requests.isEmpty)
        do { _ = try await f.store.claimNextContractStructure(localProjectID: f.base.localID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .noReadyBatch) }
        let token = f.base.authority.beginBaseline(f.base.context)
        f.base.authority.finishBaseline(f.base.context, token: token, allowed: true)
        await f.base.transport.configure()
        _ = try await f.sender.sendNext(localProjectID: f.base.localID,
            preparedBatchID: value.request.batchID, reviewedRequestSHA256: value.requestSHA256)
        let retried = await f.base.transport.requests
        XCTAssertEqual(retried, [value.requestJSON])
    }
}

extension SyncV2HandshakeTests {
    func testReviewedPreparationRejectsNewDurableEnqueueAtFinalHTTPBoundary() async throws {
        let f = try await preparationFixture()
        let value = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
        await f.base.transport.configure(before: {
            let id = DocumentID(rawValue: UUID()), content = "합성 원고"
            let result = await f.store.record(.init(batchID: UUID(), projectID: f.base.localID, localTransactionID: nil,
                mutations: [.documentSnapshot(operationID: UUID(), documentID: id,
                    relativePath: .init(rawValue: "메인/원고/1권/099화.txt"), content: content,
                    contentHash: SHA256ContentHasher().sha256(for: Data(content.utf8)), localSaveGeneration: 1, isDeleted: false)]))
            guard case .queued = result else { XCTFail("실제 일반 enqueue 실패"); return }
        })
        do {
            _ = try await f.sender.sendNext(localProjectID: f.base.localID,
                preparedBatchID: value.request.batchID, reviewedRequestSHA256: value.requestSHA256)
            XCTFail("검토 후 새 일반 저장이 있었는데도 송신함")
        } catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .preparationChanged) }
        let requests = await f.base.transport.requests
        XCTAssertTrue(requests.isEmpty)
        let saved = try await f.store.contractPreparation(localProjectID: f.base.localID)
        XCTAssertEqual(saved, value)
    }

    func testUnsentPreparationCanBeDiscardedButAttemptedRequestCannot() async throws {
        let f = try await preparationFixture()
        let first = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        try await f.sender.discardUnsentPreparation(localProjectID: f.base.localID)
        let second = try await f.sender.prepareEmptyVolume(localProjectID: f.base.localID)
        XCTAssertNotEqual(try first.request.batchID, try second.request.batchID)
        ContractPathGate.setOpen(true, for: f.base.localID, in: f.base.defaults)
        await f.base.transport.configure(reject: true)
        do {
            _ = try await f.sender.sendNext(localProjectID: f.base.localID,
                preparedBatchID: second.request.batchID, reviewedRequestSHA256: second.requestSHA256)
            XCTFail()
        } catch {}
        ContractPathGate.close(for: f.base.localID, in: f.base.defaults)
        do { try await f.sender.discardUnsentPreparation(localProjectID: f.base.localID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .preparationChanged) }
        let preserved = try await f.store.contractPreparation(localProjectID: f.base.localID)
        XCTAssertEqual(preserved, second)
        do { _ = try await f.store.claimNextContractStructure(localProjectID: f.base.localID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .noReadyBatch) }
    }
}

extension SyncV2HandshakeTests {
    private struct PreparationProjectList: SyncProjectListing {
        let project: ManagedProject
        func projects() async throws -> [ManagedProject] { [project] }
    }

    @MainActor
    func testSettingsPreparesSharesAndRestoresTheStoredRequestWithGateClosed() async throws {
        let f = try await preparationFixture()
        let project = ManagedProject(project: .init(id: f.base.localID, name: "최종검증03",
            createdAt: Date(), modifiedAt: Date()), userOrder: 0, lifecycleState: .active)
        let bindings = LifecycleBindings([f.base.queue.savedBinding])
        func model() -> SyncSettingsModel {
            .init(projectLister: PreparationProjectList(project: project), authenticationService: f.base.auth,
                projectBindingService: bindings, handshakeService: f.base.service,
                contractStructureSender: f.sender, defaults: f.base.defaults)
        }
        let first = model()
        await first.load()
        let row = try XCTUnwrap(first.projectRows.first)
        await first.prepareEmptyVolume(for: row)
        let value = try XCTUnwrap(first.contractPreparations[row.id], first.preparationReport ?? "")
        let url = try XCTUnwrap(first.preparationExportURLs[row.id])
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), try value.exportData())
        let reopened = model()
        await reopened.load()
        XCTAssertEqual(reopened.contractPreparations[row.id], value)
        XCTAssertFalse(reopened.isGateOpen(for: row))
        let requests = await f.base.transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPreparationRejectsCustomizedFixedRootOrderAndWrongLiveServer() async throws {
        let f = try await preparationFixture()
        var nodes = await f.nodes.read()
        nodes[0] = nodes[0].relocated(to: nodes[0].relativePath, parentID: nil,
            userOrder: BinderOrderingPolicy.customizedRootOrderOffset, at: Date())
        XCTAssertThrowsError(try f.snapshot.validate(local: nodes))
        let url = URL(string: "https://unreviewed.example.com")!
        let client = SupabaseClient(supabaseURL: url, supabaseKey: "test-only")
        let metadata = LiveSyncV2PreparationMetadata(client: client, serverURL: url)
        do { _ = try await metadata.fetch(projectID: SyncV2EmptyVolumeReview.projectID); XCTFail() }
        catch { XCTAssertEqual(error as? SyncV2ContractStructureError, .projectNotConnected) }
    }
}
