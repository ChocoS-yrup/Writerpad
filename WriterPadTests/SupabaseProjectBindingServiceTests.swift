import Foundation
import XCTest
@testable import WriterPad

final class SupabaseProjectBindingServiceTests: XCTestCase {
    func testBindingCompletedAfterWatchdogIsPublishedForConnectAndDisconnect() async throws {
        for disconnect in [true, false] {
            let project = makeProject(id: UUID().uuidString, name: "느린 연결 저장")
            let store = InMemoryProjectBindingStore()
            let barrier = BindingSaveBarrier()
            let delayed = DelayedBindingStore(store: store, barrier: barrier)
            let f = makeFixture(projects: [project], store: store, serviceBindingStore: delayed)
            let original = ProjectSyncBinding.connected(localProjectID: project.id, serverProjectID: UUID(),
                kind: .existingServerProject, projectName: project.name, ownerSubject: f.userID)
            try await store.save(original)
            let updates = await f.service.bindingUpdates(for: project.id)
            let probe = BindingUpdateProbe()
            let observer = Task { for await binding in updates { await probe.record(binding) } }
            defer { observer.cancel() }
            let target = UUID()
            let confirmation = try ConfirmedServerProjectID(expectedServerProjectID: target, userEnteredUUID: target.uuidString)
            let change = Task {
                if disconnect { return await f.service.disconnect(localProjectID: project.id) }
                return await f.service.connectExistingProject(localProjectID: project.id, confirmation: confirmation)
            }
            await barrier.waitUntilEntered()
            try await Task.sleep(for: .seconds(21))
            let before = await probe.values
            XCTAssertTrue(before.isEmpty, "미완료 저장을 공개하면 안 됨")
            await barrier.release()
            let result = await change.value
            guard case .failed = result else { return XCTFail("watchdog 결과는 유지해야 함") }
            for _ in 0..<100 { await Task.yield() }
            let durable = await store.binding(for: project.id)
            let published = await probe.values
            XCTAssertEqual(published, [durable], "늦게 완료된 실제 연결 상태의 알림이 누락됨")
            XCTAssertEqual(durable?.serverProjectID, disconnect ? nil : target)
        }
    }

    func testFirstConnectionAndSaveSerializeInBothOrders() async throws {
        for scenario in 0..<3 {
            let saveFirst = scenario == 0
            let initialEnqueueTimesOut = scenario == 2
            let workspace = try LocalDocumentTestWorkspace.create()
            defer { workspace.remove() }
            try Data("연결 전 본문".utf8).write(to: workspace.fileURL)
            let project = makeProject(id: workspace.projectID.rawValue.uuidString, name: "첫 연결 경합")
            let store = InMemoryProjectBindingStore()
            let gate = SyncV2DocumentMutationGate()
            let barrier = BindingSaveBarrier()
            let durable = BindingRaceRecorder(store: store, initialBarrier: saveFirst ? nil : barrier)
            let initial = ProjectInitialSyncRecorder(documentRepository: BindingRaceDocuments(document: workspace.document()),
                workspaceLocator: FixedWorkspaceLocator(root: workspace.root), durableChangeRecorder: durable)
            let f = makeFixture(projects: [project], initialSyncRecorder: initial, store: store, projectSaveGate: gate)
            let updates = await f.service.bindingUpdates(for: project.id)
            let probe = BindingUpdateProbe()
            let observer = Task { for await binding in updates { await probe.record(binding) } }
            defer { observer.cancel() }
            let local = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace.root),
                metadataUpdater: BindingSaveMetadata(barrier: saveFirst ? barrier : nil),
                durableChangeRecorder: durable, projectSaveGate: gate)
            let save: Task<DocumentSaveReceipt, Error>
            let connect: Task<ProjectBindingResult, Never>
            if saveFirst {
                save = Task { try await local.save(workspace.request(text: "경합 중 새 본문", generation: 1)) }
                await barrier.waitUntilEntered()
                connect = Task { await f.service.createServerProject(for: project.id) }
                while await f.transport.receivedParameters().isEmpty { await Task.yield() }
                // The binding must not become durable while pre-TXT validation is suspended.
                for _ in 0..<30 { await Task.yield() }
                let binding = await store.binding(for: project.id)
                XCTAssertNil(binding)
            } else {
                connect = Task { await f.service.createServerProject(for: project.id) }
                await barrier.waitUntilEntered()
                // 실제 제품의 20초 watchdog을 넘겨도 비협조적 초기 기록의
                // 완료 전에는 후속 저장이 TXT/큐를 바꾸면 안 된다.
                if initialEnqueueTimesOut { try await Task.sleep(for: .seconds(21)) }
                save = Task { try await local.save(workspace.request(text: "경합 중 새 본문", generation: 1)) }
                for _ in 0..<30 { await Task.yield() }
                XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), "연결 전 본문")
            }
            await barrier.release()
            let receipt = try await save.value
            let connected = await connect.value
            let binding: ProjectSyncBinding
            if initialEnqueueTimesOut {
                guard case .failed = connected else { return XCTFail("시간 초과 결과 유실") }
                let stored = await store.binding(for: project.id)
                binding = try XCTUnwrap(stored)
            } else {
                guard case .connected(let value) = connected else { return XCTFail("\(connected)") }
                binding = value
            }
            let batches = await durable.batches
            for _ in 0..<100 { await Task.yield() }
            let published = await probe.values
            XCTAssertEqual(published, [binding], "초기 enqueue가 늦게 완료돼도 준비된 연결을 공개해야 함")
            if saveFirst {
                XCTAssertEqual(receipt.durableRecordResult, .localOnly)
                XCTAssertEqual(batches.count, 1)
                XCTAssertEqual(batches[0].kind, .projectBinding)
            } else {
                guard case .queued = receipt.durableRecordResult else { return XCTFail("새 저장 출처 유실") }
                XCTAssertEqual(batches.map(\.kind), [.projectBinding, .documentSave])
                XCTAssertEqual(batches.last?.handoffOrigin, LocalSyncHandoffOrigin(binding))
            }
            let latest = try XCTUnwrap(batches.last?.mutations.last(where: {
                if case .documentSnapshot = $0 { return true }; return false
            }))
            guard case let .documentSnapshot(_, _, _, content, _, _, _) = latest else { return XCTFail() }
            XCTAssertEqual(content, "경합 중 새 본문")
            XCTAssertEqual(try String(contentsOf: workspace.fileURL, encoding: .utf8), content)
            let markers = try FileManager.default.contentsOfDirectory(atPath: workspace.root.path)
            XCTAssertFalse(markers.contains { $0.hasPrefix(LocalDocumentStore.syncHandoffPrefix) })
        }
    }

    func testBindingChangesRevokeOptInButNameRefreshKeepsIt() async throws {
        for change in 0..<3 {
            let suite = "BindingGate-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let project = makeProject(id: UUID().uuidString, name: "연결 승인 시험")
            let f = makeFixture(projects: [project], contractDefaults: .init(value: defaults))
            let original = ProjectSyncBinding.connected(localProjectID: project.id, serverProjectID: UUID(),
                kind: .existingServerProject, projectName: project.name,
                ownerSubject: change == 2 ? UUID() : f.userID)
            try await f.store.save(original)
            ContractPathGate.setOpen(true, for: project.id, in: defaults)
            if change == 0 {
                _ = await f.service.refreshServerName(for: project.id)
                XCTAssertTrue(ContractPathGate.isOpen(for: project.id, in: defaults))
                _ = await f.service.disconnect(localProjectID: project.id)
                XCTAssertFalse(ContractPathGate.isOpen(for: project.id, in: defaults))
                let target = original.serverProjectID!
                _ = await f.service.connectExistingProject(localProjectID: project.id,
                    confirmation: try ConfirmedServerProjectID(expectedServerProjectID: target, userEnteredUUID: target.uuidString))
            } else {
                let target = change == 1 ? UUID() : original.serverProjectID!
                let confirmed = try ConfirmedServerProjectID(expectedServerProjectID: target, userEnteredUUID: target.uuidString)
                _ = await f.service.connectExistingProject(localProjectID: project.id, confirmation: confirmed)
            }
            XCTAssertFalse(ContractPathGate.isOpen(for: project.id, in: defaults), "change=\(change)")
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertFalse(ContractPathGate.isOpen(for: project.id, in: reopened))
        }
    }

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

    func testFailedInitialSnapshotIsNotReportedConnectedAndRecoversOnLookup()
        async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000496",
            name: "중단 복구"
        )
        let recorder = InitialSyncRecorderSpy(
            results: [
                .localSavedButNotQueued(reason: "injected"),
                .queued(operationIDs: [UUID()]),
            ]
        )
        let fixture = makeFixture(
            projects: [project],
            initialSyncRecorder: recorder
        )

        let first = await fixture.service.createServerProject(for: project.id)

        XCTAssertEqual(first, .failed(.initialSnapshotNotQueued))
        let storedAfterFailure = await fixture.store.binding(for: project.id)
        XCTAssertNotNil(storedAfterFailure)

        // 앱 재시작/dispatcher 뒤 coordinator가 수행하는 binding 조회가
        // 별도 사용자 재호출 없이 남은 initial handoff를 복구한다.
        let recovered = await fixture.service.currentBinding(for: project.id)
        XCTAssertEqual(recovered?.localProjectID, project.id)
        let calls = await recorder.calls()
        XCTAssertEqual(calls.count, 2)
    }

    private func serverDocument(
        path: String,
        isDeleted: Bool = false
    ) -> SyncV2RemoteDocumentSnapshot {
        SyncV2RemoteDocumentSnapshot(
            documentID: UUID(),
            relativePath: path,
            content: "서버 원고",
            revision: 1,
            isDeleted: isDeleted,
            deletedAt: isDeleted ? Date(timeIntervalSince1970: 5) : nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }

    /// Windows 가져오기 연결은 로컬 전체를 create로 올린다. 서버 작품에 이미
    /// 원고가 있으면 그 자리를 다른 UUID가 점유해 PATH_CONFLICT로 멈추므로
    /// 올리기 전에 막는다.
    func testWindowsImportIsRefusedWhenServerProjectHasDocuments()
        async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000601",
            name: "이미 원고가 있는 서버"
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000602"
        )!
        let recorder = InitialSyncRecorderSpy()
        let fixture = makeFixture(
            projects: [project],
            initialSyncRecorder: recorder,
            serverDocuments: [serverDocument(path: "원고/1권/001화.txt")]
        )
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )

        let result = await fixture.service.connectWindowsProject(
            localProjectID: project.id,
            confirmation: confirmation
        )

        XCTAssertEqual(result, .failed(.serverProjectNotEmpty))
        let calls = await recorder.calls()
        XCTAssertTrue(calls.isEmpty, "거부된 연결은 올리기를 예약하지 않는다.")
        let stored = await fixture.store.binding(for: project.id)
        XCTAssertNil(stored, "거부된 연결은 binding을 남기지 않는다.")
    }

    func testNewServerProjectIsRefusedWhenServerProjectHasDocuments()
        async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000603",
            name: "재사용된 서버 UUID"
        )
        let fixture = makeFixture(
            projects: [project],
            serverDocuments: [serverDocument(path: "원고/1권/001화.txt")]
        )

        let result = await fixture.service.createServerProject(
            for: project.id
        )

        XCTAssertEqual(result, .failed(.serverProjectNotEmpty))
    }

    /// tombstone만 남은 작품은 live 문서가 없어 충돌할 상대가 없다.
    func testConnectionIsAllowedWhenServerProjectHasOnlyTombstones()
        async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000604",
            name: "삭제만 남은 서버"
        )
        let fixture = makeFixture(
            projects: [project],
            serverDocuments: [
                serverDocument(
                    path: "원고/1권/001화.txt",
                    isDeleted: true
                ),
            ]
        )

        let result = await fixture.service.createServerProject(
            for: project.id
        )

        guard case .connected = result else {
            return XCTFail("tombstone만 있으면 연결할 수 있어야 한다.")
        }
    }

    /// 기존 서버 작품에 붙는 연결은 올리지 않고 pull로 받아오므로, 서버에
    /// 원고가 있는 것이 정상이다. 두 번째 기기를 붙이는 경로가 막히면 안 된다.
    func testExistingProjectConnectionIsAllowedWhenServerHasDocuments()
        async throws {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000605",
            name: "두 번째 기기"
        )
        let serverID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000606"
        )!
        let fixture = makeFixture(
            projects: [project],
            serverDocuments: [serverDocument(path: "원고/1권/001화.txt")]
        )
        let confirmation = try ConfirmedServerProjectID(
            expectedServerProjectID: serverID,
            userEnteredUUID: serverID.uuidString
        )

        let result = await fixture.service.connectExistingProject(
            localProjectID: project.id,
            confirmation: confirmation
        )

        guard case let .connected(binding) = result else {
            return XCTFail("기존 서버 작품 연결은 막히면 안 된다.")
        }
        XCTAssertEqual(binding.kind, .existingServerProject)
    }

    /// 서버 상태를 읽지 못했는데 비어 있다고 가정하고 올리면 기존 원고와
    /// 충돌한다. 확인 실패는 연결 실패로 다룬다.
    func testConnectionIsRefusedWhenServerStateCannotBeChecked() async {
        let project = makeProject(
            id: "00000000-0000-0000-0000-000000000607",
            name: "확인 실패"
        )
        let fixture = makeFixture(
            projects: [project],
            snapshotClientFails: true
        )

        let result = await fixture.service.createServerProject(
            for: project.id
        )

        XCTAssertEqual(result, .failed(.networkUnavailable))
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
            NoOpInitialProjectSyncRecorder(),
        serverDocuments: [SyncV2RemoteDocumentSnapshot] = [],
        snapshotClientFails: Bool = false,
        contractDefaults: ContractDefaults = .standard,
        store: InMemoryProjectBindingStore = InMemoryProjectBindingStore(),
        serviceBindingStore: (any ProjectBindingStoring)? = nil,
        projectSaveGate: SyncV2DocumentMutationGate = SyncV2DocumentMutationGate()
    ) -> BindingFixture {
        let transport = EnsureProjectTransportStub(result: transportResult)
        let auth = AuthenticationServiceStub(
            state: authenticationState ?? authenticatedState
        )
        let projectRepository = repository
            ?? ProjectRepositoryStub(projects: projects)
        let service = SupabaseProjectBindingService(
            transport: transport,
            bindingStore: serviceBindingStore ?? store,
            projectRepository: projectRepository,
            authenticationService: auth,
            initialSyncRecorder: initialSyncRecorder,
            snapshotClient: BindingSnapshotClientStub(
                documents: serverDocuments,
                shouldFail: snapshotClientFails
            ),
            contractDefaults: contractDefaults,
            projectSaveGate: projectSaveGate
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

private struct BindingSnapshotClientStubError: Error {}

private actor BindingUpdateProbe {
    private(set) var values: [ProjectSyncBinding?] = []
    func record(_ binding: ProjectSyncBinding?) { values.append(binding) }
}

private actor DelayedBindingStore: ProjectBindingStoring {
    let store: InMemoryProjectBindingStore
    let barrier: BindingSaveBarrier
    init(store: InMemoryProjectBindingStore, barrier: BindingSaveBarrier) {
        self.store = store; self.barrier = barrier
    }
    func availability() async -> ProjectBindingStoreAvailability { .available }
    func binding(for localProjectID: ProjectID) async throws -> ProjectSyncBinding? {
        await store.binding(for: localProjectID)
    }
    func binding(forServerProjectID serverProjectID: UUID) async throws -> ProjectSyncBinding? {
        await store.binding(forServerProjectID: serverProjectID)
    }
    func allBindings() async throws -> [ProjectSyncBinding] { await store.allBindings() }
    func save(_ binding: ProjectSyncBinding) async throws {
        await barrier.suspend() // Deliberately ignores task cancellation, like a slow durable write.
        try await store.save(binding)
    }
}

private actor BindingSaveBarrier {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct BindingSaveMetadata: DocumentFileMetadataUpdating {
    let barrier: BindingSaveBarrier?
    func validateBeforeFileSave(_ request: DocumentSaveRequest) async throws { await barrier?.suspend() }
    func updateAfterFileSave(_ receipt: DocumentSaveReceipt) async throws {}
}

private actor BindingRaceRecorder: DurableLocalChangeRecording {
    nonisolated let requiresHandoffOrigin = true
    let store: InMemoryProjectBindingStore
    let initialBarrier: BindingSaveBarrier?
    private(set) var batches: [LocalMutationBatch] = []
    init(store: InMemoryProjectBindingStore, initialBarrier: BindingSaveBarrier?) {
        self.store = store; self.initialBarrier = initialBarrier
    }
    func handoffOrigin(for projectID: ProjectID) async -> LocalSyncHandoffOrigin? {
        await store.binding(for: projectID).flatMap(LocalSyncHandoffOrigin.init)
    }
    func requirement(for projectID: ProjectID) async -> DurableRecordingRequirement {
        await handoffOrigin(for: projectID) == nil ? .localOnly : .durableQueue
    }
    func hasRecordedInitialSnapshot(for projectID: ProjectID, kind: DurableLocalBatchKind) async throws -> Bool {
        batches.contains { $0.projectID == projectID && $0.kind == kind }
    }
    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        if batch.kind == .projectBinding { await initialBarrier?.suspend() }
        batches.append(batch)
        return .queued(operationIDs: [batch.batchID])
    }
}

private actor BindingRaceDocuments: DocumentRepository {
    var document: DocumentNode
    init(document: DocumentNode) { self.document = document }
    func documents(in projectID: ProjectID) async throws -> [DocumentNode] { [document] }
    func document(id: DocumentID) async throws -> DocumentNode? { document }
    func save(_ document: DocumentNode) async throws { self.document = document }
    func removeMetadata(id: DocumentID) async throws {}
}

private actor BindingSnapshotClientStub: SyncV2SnapshotClienting {
    private let documents: [SyncV2RemoteDocumentSnapshot]
    private let shouldFail: Bool

    init(
        documents: [SyncV2RemoteDocumentSnapshot],
        shouldFail: Bool
    ) {
        self.documents = documents
        self.shouldFail = shouldFail
    }

    func fetchDocuments(
        projectID: UUID
    ) throws -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        if shouldFail { throw BindingSnapshotClientStubError() }
        return documents
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) throws -> SyncV2RemoteDocumentSnapshot? {
        _ = projectID
        if shouldFail { throw BindingSnapshotClientStubError() }
        return documents.first { $0.documentID == documentID }
    }

    /// 이 대역은 계약 순서를 다루지 않는다. 비어 있다고 답하는 것이 아니라
    /// 다루지 않음을 여기 적어 둔다 — 기본 구현에 기대면 전달자 누락이 성공으로
    /// 보인다.
    func fetchTreeOrders(
        projectID: UUID
    ) async throws -> [SyncV2RemoteTreeOrder] {
        []
    }
}

private actor InitialSyncRecorderSpy: InitialProjectSyncRecording {
    struct Call: Equatable, Sendable {
        let projectID: ProjectID
        let projectName: String
        let batchKind: DurableLocalBatchKind
    }

    private var values: [Call] = []
    private var results: [DurableRecordResult]

    init(results: [DurableRecordResult] = []) {
        self.results = results
    }

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
        guard !results.isEmpty else {
            return .queued(operationIDs: [])
        }
        return results.removeFirst()
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


extension SupabaseProjectBindingServiceTests {
    func testReceiveGuardBindingLookupDoesNotEnqueueInitialSnapshotOrEnsure() async throws {
        let project = makeProject(id: "00000000-0000-4000-8000-000000000499", name: "합성 기존 연결")
        let recorder = InitialSyncRecorderSpy()
        let fixture = makeFixture(projects: [project], initialSyncRecorder: recorder)
        let binding = ProjectSyncBinding.connected(localProjectID: project.id, serverProjectID: UUID(),
            kind: .newServerProject, projectName: project.name, ownerSubject: fixture.userID)
        try await fixture.store.save(binding)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: nil)
        await ReceiveValidationPolicy.$override.withValue(policy) {
            let current = await fixture.service.currentBinding(for: project.id)
            let all = await fixture.service.connectedBindings()
            XCTAssertEqual(current, binding)
            XCTAssertEqual(all, [binding])
            _ = await fixture.service.createServerProject(for: project.id)
        }
        let requests = await fixture.transport.receivedParameters()
        let calls = await recorder.calls()
        let after = await fixture.store.binding(for: project.id)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(after, binding)
    }
}
