import XCTest
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
