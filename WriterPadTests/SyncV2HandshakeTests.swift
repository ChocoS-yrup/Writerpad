import XCTest
import Supabase
@testable import WriterPad

/// 핸드셰이크가 "서버가 뭐라 했는가"와 "우리가 계약 경로를 써도 되는가"를 끝까지
/// 갈라 두는지 본다. 둘이 붙는 순간, 서버가 답 하나로 우리 쓰기 경로를 바꿀 수
/// 있게 된다.
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
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
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

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
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
        func ctx(_ local: ProjectID, _ server: UUID, _ epoch: UInt64) -> SyncV2HandshakeContext {
            .init(localProjectID: local, serverProjectID: server, accountID: account, authenticationEpoch: epoch)
        }
        await service.observeProject(localA, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: ctx(localA, a, 0)) }
        await auth.relogin()
        await eventually { await service.isFresh(for: ctx(localA, a, 1)) }
        await service.observeProject(localB, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: ctx(localB, b, 1)) }
        await service.observeProject(localA, authentication: auth, bindings: bindings)
        await eventually { await service.isFresh(for: ctx(localA, a, 1)) }
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
    private actor ContractQueueStub: SyncV2ContractQueue {
        let savedBinding: ProjectSyncBinding
        let pending: SyncV2PendingContractBatch
        var beforeClaim: (@Sendable () async -> Void)?
        private(set) var completed = false
        private(set) var failures: [SyncV2ContractStructureError] = []
        init(binding: ProjectSyncBinding, request: SyncV2ContractRequest) {
            savedBinding = binding
            pending = .init(localProjectID: binding.localProjectID, serverProjectID: binding.serverProjectID!, request: request)
        }
        func setBeforeClaim(_ hook: @escaping @Sendable () async -> Void) { beforeClaim = hook }
        func binding(for projectID: ProjectID) -> ProjectSyncBinding? { savedBinding }
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

    private func senderFixture(deviceMismatch: Bool = false, localIsActive: Bool = true) async throws -> SenderFixture {
        let local = ProjectID(rawValue: UUID()), server = UUID(), account = UUID(), device = UUID()
        let defaults = makeDefaults(function: UUID().uuidString)
        GlobalSyncPreference.setEnabled(true, in: defaults)
        ContractPathGate.setOpen(true, for: local, in: defaults)
        let auth = LifecycleAuth(account: account)
        let bindingEpoch = SyncV2ContractEpoch()
        let handshake = SyncV2HandshakeService(transport: StubTransport(results: [.success(supportedResponse(projectID: server))]))
        _ = try await handshake.refresh(context: .init(localProjectID: local, serverProjectID: server, accountID: account))
        let request = try SyncV2Contract.buildAtomicStructureRequest(projectID: server,
            projectSyncMode: .legacy, migrationEpoch: 0, writerDeviceID: device,
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
            handshakeService: handshake, authenticationService: auth, uploadPullCoordinator: coordinator, defaults: defaults,
            bindingEpoch: bindingEpoch, deviceIdentityProvider: DeviceIdentityService(
                store: InMemoryDeviceIdentityStore(), generateUUID: { actualDevice }),
            structureAuthority: authority, localProjectEpoch: localEpoch, isLocalProjectActive: { _ in localIsActive })
        return SenderFixture(coordinator: coordinator, authority: authority, context: context, localEpoch: localEpoch, sender: sender, service: handshake, auth: auth, bindingEpoch: bindingEpoch,
            queue: queue, transport: transport, localID: local, defaults: defaults, request: request)
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
