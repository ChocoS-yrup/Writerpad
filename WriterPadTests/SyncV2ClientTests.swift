import Combine
import Foundation
import XCTest
@testable import WriterPad

final class SyncV2ClientTests: XCTestCase {
    func testCommitParametersUseExactSQLKeysIncludingNullLease() throws {
        let parameters = makeParameters()
        let data = try JSONEncoder().encode(parameters)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "p_document_id",
                "p_project_id",
                "p_base_revision",
                "p_operation_id",
                "p_device_id",
                "p_relative_path",
                "p_content",
                "p_is_deleted",
                "p_lease_token",
            ])
        )
        XCTAssertTrue(object["p_lease_token"] is NSNull)
    }

    func testCommitParametersCanonicalizeNFDKoreanPathToNFC() throws {
        let expected = "메인/원고/1권/001화.txt"
        let decomposed = expected.decomposedStringWithCanonicalMapping
        XCTAssertFalse(
            decomposed.utf8.elementsEqual(expected.utf8),
            "fixture가 NFD여야 합니다."
        )
        let base = makeParameters()
        let parameters = SyncV2CommitDocumentParameters(
            documentID: base.documentID,
            projectID: base.projectID,
            baseServerRevision: base.baseServerRevision,
            operationID: base.operationID,
            deviceID: base.deviceID,
            relativePath: decomposed,
            content: base.content,
            isDeleted: base.isDeleted,
            leaseToken: base.leaseToken
        )

        XCTAssertTrue(parameters.relativePath.utf8.elementsEqual(expected.utf8))
        let data = try JSONEncoder().encode(parameters)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedPath = try XCTUnwrap(
            object["p_relative_path"] as? String
        )
        XCTAssertTrue(encodedPath.utf8.elementsEqual(expected.utf8))
    }

    func testCommitResultDecodesFractionalTimestampAndRequiredFields() throws {
        let parameters = makeParameters()
        let hash = hash(parameters.content)
        let data = Data(
            """
            {
              "status":"committed",
              "document_id":"\(parameters.documentID.uuidString)",
              "version_id":"00000000-0000-0000-0000-000000000902",
              "operation_id":"\(parameters.operationID.uuidString)",
              "operation_kind":"create",
              "revision":1,
              "relative_path":"\(parameters.relativePath)",
              "is_deleted":false,
              "content_hash":"\(hash)",
              "committed_at":"2026-07-27T01:02:03.123456+00:00"
            }
            """.utf8
        )

        let result = try JSONDecoder().decode(
            SyncV2CommitDocumentResult.self,
            from: data
        )

        XCTAssertEqual(result.serverRevision, 1)
        XCTAssertEqual(result.contentHash, hash)
    }

    func testMissingRequiredResponseFieldFailsDecoding() {
        let data = Data(
            """
            {
              "status":"committed",
              "document_id":"00000000-0000-0000-0000-000000000901"
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SyncV2CommitDocumentResult.self,
                from: data
            )
        )
    }

    func testEveryStableServerErrorIsClassifiedWithoutStringSearch() async {
        for code in SyncV2RemoteErrorCode.allCases {
            let transport = SyncV2CommitTransportStub(
                result: .failure(.postgrest(
                    message: code.rawValue,
                    postgresCode: "P0001",
                    detail: #"{"fixture":true}"#
                ))
            )
            let client = SyncV2Client(transport: transport)

            do {
                _ = try await client.commitDocument(makeParameters())
                XCTFail("Expected \(code.rawValue).")
            } catch let error as SyncV2ClientError {
                XCTAssertEqual(
                    error,
                    .remote(
                        code: code,
                        detail: #"{"fixture":true}"#
                    )
                )
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRLSAndJWTPostgrestCodesRemainDistinct() async {
        let forbidden = await classifiedError(
            .postgrest(
                message: "permission denied",
                postgresCode: "42501",
                detail: nil
            )
        )
        let authentication = await classifiedError(
            .postgrest(
                message: "JWT expired",
                postgresCode: "PGRST301",
                detail: nil
            )
        )

        XCTAssertEqual(
            forbidden,
            .remote(code: .forbidden, detail: nil)
        )
        XCTAssertEqual(
            authentication,
            .remote(code: .authRequired, detail: nil)
        )
    }

    func testTimeoutNetworkAndUnknownServerFailureStayDistinct() async {
        let timeout = await classifiedError(.url(code: .timedOut))
        let offline = await classifiedError(
            .url(code: .notConnectedToInternet)
        )
        let unknown = await classifiedError(
            .postgrest(
                message: "UNRECOGNIZED_SERVER_ERROR",
                postgresCode: "XX000",
                detail: "original detail"
            )
        )

        XCTAssertEqual(timeout, .timedOut)
        XCTAssertEqual(offline, .networkUnavailable)
        XCTAssertEqual(
            unknown,
            .serverRejected(
                SyncV2RemoteRejection(
                    postgresCode: "XX000",
                    message: "UNRECOGNIZED_SERVER_ERROR",
                    detail: "original detail"
                )
            )
        )
    }

    func testMalformedSuccessfulResponseIsNeverAccepted() async {
        let parameters = makeParameters()
        let mismatched = makeResult(
            parameters: parameters,
            contentHash: String(repeating: "0", count: 64)
        )
        let transport = SyncV2CommitTransportStub(
            result: .success(mismatched)
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitDocument(parameters)
            XCTFail("A mismatched content hash must not be accepted.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCanonicallyEquivalentNFDResponseIsRejectedWhenNFCWasSent()
        async {
        let parameters = makeParameters()
        let result = SyncV2CommitDocumentResult(
            status: .committed,
            documentID: parameters.documentID,
            versionID: UUID(),
            operationID: parameters.operationID,
            operationKind: .create,
            serverRevision: 1,
            relativePath: parameters.relativePath
                .decomposedStringWithCanonicalMapping,
            isDeleted: false,
            contentHash: hash(parameters.content),
            committedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let client = SyncV2Client(
            transport: SyncV2CommitTransportStub(
                result: .success(result)
            )
        )

        do {
            _ = try await client.commitDocument(parameters)
            XCTFail("서버가 NFC 경로를 그대로 확정하지 않으면 안 됩니다.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommittedThenReplayedSameOperationConvergesToSameResult() async throws {
        let parameters = makeParameters()
        let committed = makeResult(parameters: parameters, status: .committed)
        let replayed = makeResult(parameters: parameters, status: .replayed)
        let transport = SyncV2CommitSequenceTransport(
            results: [committed, replayed]
        )
        let client = SyncV2Client(transport: transport)

        let first = try await client.commitDocument(parameters)
        let second = try await client.commitDocument(parameters)

        XCTAssertEqual(first.status, .committed)
        XCTAssertEqual(second.status, .replayed)
        XCTAssertEqual(first.versionID, second.versionID)
        XCTAssertEqual(first.serverRevision, second.serverRevision)
        XCTAssertEqual(first.committedAt, second.committedAt)
        let requests = await transport.requests()
        XCTAssertEqual(requests, [parameters, parameters])
    }

    func testInvalidCreateAndOversizedContentNeverReachTransport() async {
        let transport = SyncV2CommitTransportStub(
            result: .success(makeResult(parameters: makeParameters()))
        )
        let client = SyncV2Client(transport: transport)
        var invalidCreate = makeParameters()
        invalidCreate = SyncV2CommitDocumentParameters(
            documentID: invalidCreate.documentID,
            projectID: invalidCreate.projectID,
            baseServerRevision: 0,
            operationID: invalidCreate.operationID,
            deviceID: invalidCreate.deviceID,
            relativePath: invalidCreate.relativePath,
            content: invalidCreate.content,
            isDeleted: true,
            leaseToken: nil
        )

        do {
            _ = try await client.commitDocument(invalidCreate)
            XCTFail("Invalid create must be blocked locally.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(
                error,
                .remote(code: .invalidArgument, detail: nil)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let oversized = SyncV2CommitDocumentParameters(
            documentID: invalidCreate.documentID,
            projectID: invalidCreate.projectID,
            baseServerRevision: 0,
            operationID: UUID(),
            deviceID: invalidCreate.deviceID,
            relativePath: invalidCreate.relativePath,
            content: String(
                repeating: "a",
                count: SyncV2Store.maximumContentByteCount + 1
            ),
            isDeleted: false,
            leaseToken: nil
        )
        do {
            _ = try await client.commitDocument(oversized)
            XCTFail("Oversized content must be blocked locally.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(
                error,
                .remote(code: .invalidArgument, detail: nil)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testExistingRevisionWithoutLeaseNeverReachesTransport() async {
        let create = makeParameters()
        let existing = SyncV2CommitDocumentParameters(
            documentID: create.documentID,
            projectID: create.projectID,
            baseServerRevision: 1,
            operationID: create.operationID,
            deviceID: create.deviceID,
            relativePath: create.relativePath,
            content: create.content,
            isDeleted: false,
            leaseToken: nil
        )
        let transport = SyncV2CommitTransportStub(
            result: .success(makeResult(parameters: create))
        )

        do {
            _ = try await SyncV2Client(transport: transport)
                .commitDocument(existing)
            XCTFail("An existing revision must carry an edit lease.")
        } catch let error as SyncV2ClientError {
            XCTAssertEqual(
                error,
                .remote(code: .invalidArgument, detail: nil)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 0)
    }

    private func classifiedError(
        _ transportError: SyncV2CommitTransportError
    ) async -> SyncV2ClientError? {
        let transport = SyncV2CommitTransportStub(
            result: .failure(transportError)
        )
        let client = SyncV2Client(transport: transport)
        do {
            _ = try await client.commitDocument(makeParameters())
            return nil
        } catch let error as SyncV2ClientError {
            return error
        } catch {
            return nil
        }
    }

    private func makeParameters() -> SyncV2CommitDocumentParameters {
        SyncV2CommitDocumentParameters(
            documentID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000901"
            )!,
            projectID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000900"
            )!,
            baseServerRevision: 0,
            operationID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000903"
            )!,
            deviceID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000904"
            )!,
            relativePath: "메인/원고/1권/001화.txt",
            content: "서버 commit 원고🙂",
            isDeleted: false,
            leaseToken: nil
        )
    }

    private func makeResult(
        parameters: SyncV2CommitDocumentParameters,
        status: SyncV2CommitStatus = .committed,
        contentHash: String? = nil
    ) -> SyncV2CommitDocumentResult {
        SyncV2CommitDocumentResult(
            status: status,
            documentID: parameters.documentID,
            versionID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000902"
            )!,
            operationID: parameters.operationID,
            operationKind: .create,
            serverRevision: 1,
            relativePath: parameters.relativePath,
            isDeleted: parameters.isDeleted,
            contentHash: contentHash ?? hash(parameters.content),
            committedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func hash(_ content: String) -> String {
        SHA256ContentHasher()
            .sha256(for: Data(content.utf8))
            .rawValue
    }
}

final class EditLeaseManagerTests: XCTestCase {
    func testNewDocumentDoesNotAcquireLease() async throws {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 0),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        let state = await manager.beginEditing(documentID: documentID)
        let token = try await manager.leaseTokenForCommit(
            documentID: documentID,
            deviceID: deviceID,
            baseRevision: 0
        )
        await manager.endEditing(documentID: documentID)

        XCTAssertEqual(state, .localOnly)
        XCTAssertNil(token)
        let acquireCount = await client.acquireCount()
        let releaseCount = await client.releaseCount()
        XCTAssertEqual(acquireCount, 0)
        XCTAssertEqual(releaseCount, 0)
    }

    func testDisabledGlobalSyncNeverAcquiresLeaseOnEditorEntry() async {
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 4),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: UUID())
            ),
            isEnabled: { false }
        )

        let state = await manager.beginEditing(documentID: UUID())
        let acquireCount = await client.acquireCount()

        XCTAssertEqual(state, .localOnly)
        XCTAssertEqual(acquireCount, 0)
    }

    @MainActor
    func testViewingServerLiveDocumentAcquiresLeaseBeforeFirstMutation()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "읽기 중 잠금 없음"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository
            .document(id: volume.documentToOpenID)
        let document = try XCTUnwrap(
            loadedDocument
        )
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: UUID())
            )
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            editLeaseManager: manager,
            editLeaseConnectivityMonitor:
                EditLeaseConnectivityMonitorStub()
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )

        await model.select(node)
        await waitUntil {
            if case .held = model.editLeaseState {
                return true
            }
            return false
        }
        var acquireCount = await client.acquireCount()
        XCTAssertEqual(acquireCount, 1)

        model.updateText("첫 수정")
        await waitUntil {
            if case .held = model.editLeaseState {
                return true
            }
            return false
        }
        acquireCount = await client.acquireCount()
        XCTAssertEqual(acquireCount, 1)
    }

    @MainActor
    func testHeldByOtherDocumentTransitionKeepsChapterContentsIsolated()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "잠금 충돌 문서 전환"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let documents = try await environment.documentRepository
            .documents(in: project.id)
            .filter {
                $0.kind == .text
                    && $0.relativePath.rawValue.contains("/원고/")
            }
            .sorted { $0.userOrder < $1.userOrder }
        let chapters = Array(documents.prefix(3))
        XCTAssertEqual(chapters.count, 3)
        let initialContents = ["", "", ""]
        for (index, document) in chapters.enumerated() {
            _ = try await environment.localDocumentStore.save(
                DocumentSaveRequest(
                    projectID: project.id,
                    documentID: document.id,
                    relativePath: document.relativePath,
                    text: initialContents[index],
                    generation: 1
                )
            )
        }
        func node(
            _ document: DocumentNode,
            displayName: String
        ) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: displayName,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .written,
                isExpanded: false
            )
        }
        let client = EditLeaseClientStub(
            acquireError: .remote(
                code: .leaseConflict,
                detail: #"{"expires_at":"2030-01-02T03:04:05Z"}"#
            )
        )
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: UUID())
            )
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository:
                environment.workspaceStateRepository,
            editLeaseManager: manager,
            editLeaseConnectivityMonitor:
                EditLeaseConnectivityMonitorStub(),
            autosaveDelay: .seconds(60)
        )

        await model.select(node(chapters[0], displayName: "6화"))
        model.updateText("아아")
        await waitForLeaseState(model) {
            if case .heldByOther = $0 {
                return true
            }
            return false
        }

        await model.select(node(chapters[1], displayName: "7화"))
        XCTAssertEqual(model.currentDocumentID, chapters[1].id)
        XCTAssertEqual(model.currentText, "")
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.selectedDisplayName, "7화")

        await model.select(node(chapters[2], displayName: "8화"))
        XCTAssertEqual(model.currentDocumentID, chapters[2].id)
        XCTAssertEqual(model.currentText, "")
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.selectedDisplayName, "8화")

        var storedContents: [String] = []
        for chapter in chapters {
            storedContents.append(
                try await environment.localDocumentStore.loadText(
                    for: chapter
                )
            )
        }
        XCTAssertEqual(storedContents, ["아아", "", ""])
    }

    @MainActor
    func testHeldByOtherEmptyDraftAppearsBeforePreviousLeaseCleanupFinishes()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "잠금 정리 중 빈 문서 전환"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let documents = try await environment.documentRepository
            .documents(in: project.id)
            .filter {
                $0.kind == .text
                    && $0.relativePath.rawValue.contains("/원고/")
            }
            .sorted { $0.userOrder < $1.userOrder }
        let chapters = Array(documents.prefix(2))
        XCTAssertEqual(chapters.count, 2)
        func node(_ document: DocumentNode, name: String) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: name,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }
        let drafts = EditorDraftStore()
        drafts.store(
            EditorDraftStore.Draft(text: "", cursor: .start),
            for: chapters[1].id
        )
        let leaseManager = BlockingLeaseCleanupManager()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository:
                environment.workspaceStateRepository,
            draftStore: drafts,
            editLeaseManager: leaseManager,
            editLeaseConnectivityMonitor:
                EditLeaseConnectivityMonitorStub(),
            autosaveDelay: .seconds(60)
        )

        await model.select(node(chapters[0], name: "6화"))
        model.updateText("아아")
        await waitForLeaseState(model) {
            if case .heldByOther = $0 { return true }
            return false
        }

        let transition = Task { @MainActor in
            await model.select(node(chapters[1], name: "7화"))
        }
        await leaseManager.waitUntilCleanupStarts()

        XCTAssertEqual(model.currentDocumentID, chapters[1].id)
        XCTAssertEqual(model.selectedDisplayName, "7화")
        XCTAssertEqual(model.currentText, "")
        XCTAssertEqual(model.text, "")

        await leaseManager.finishCleanup()
        await transition.value
    }

    func testSessionRestoreNeverStartsLeaseRPCAndCommitAcquiresAfterAuth()
        async throws {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let authentication = MutableAuthenticationStateProvider(
            state: .restoring
        )
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 4),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            ),
            authenticationState: {
                await authentication.current()
            }
        )

        let startupState = await manager.beginEditing(
            documentID: documentID
        )
        let startupAcquireCount = await client.acquireCount()

        XCTAssertEqual(startupState, .localOnly)
        XCTAssertEqual(startupAcquireCount, 0)

        await authentication.set(
            .authenticated(
                AuthenticatedAccount(userID: UUID(), maskedEmail: nil)
            )
        )
        let token = try await manager.leaseTokenForCommit(
            documentID: documentID,
            deviceID: deviceID,
            baseRevision: 4
        )
        await manager.commitSucceeded(
            documentID: documentID,
            deviceID: deviceID,
            isDeleted: false
        )
        let acquireCount = await client.acquireCount()
        let releaseBeforeClosing = await client.releaseCount()

        XCTAssertNotNil(token)
        XCTAssertEqual(acquireCount, 1)
        XCTAssertEqual(releaseBeforeClosing, 0)

        await manager.endEditing(documentID: documentID)
        await waitForRelease(1, client: client)
        let finalReleaseCount = await client.releaseCount()
        XCTAssertEqual(finalReleaseCount, 1)
    }

    func testTwoPanesShareLeaseUntilLastPaneCloses() async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 3),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        _ = await manager.beginEditing(documentID: documentID)
        _ = await manager.beginEditing(documentID: documentID)
        await manager.endEditing(documentID: documentID)

        let acquireCount = await client.acquireCount()
        let firstReleaseCount = await client.releaseCount()
        XCTAssertEqual(acquireCount, 1)
        XCTAssertEqual(firstReleaseCount, 0)

        await manager.endEditing(documentID: documentID)
        await waitForRelease(1, client: client)

        let finalReleaseCount = await client.releaseCount()
        XCTAssertEqual(finalReleaseCount, 1)
    }

    func testLocalOnlyActiveReferencePromotesToLiveWithoutReferenceLeak()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 0),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        _ = await manager.beginEditing(documentID: documentID)
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: documentID,
            serverRevision: 4
        )
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: documentID,
            serverRevision: 4
        )
        let acquireCount = await client.acquireCount()
        XCTAssertEqual(acquireCount, 1)

        await manager.endEditing(documentID: documentID)
        await waitForRelease(1, client: client)
        let releaseCount = await client.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testTombstoneInvalidatesLeaseAndLiveRestoreReacquiresOnce()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 3),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        _ = await manager.beginEditing(documentID: documentID)
        await manager.documentBecameTombstone(documentID: documentID)
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: documentID,
            serverRevision: 4
        )
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: documentID,
            serverRevision: 4
        )

        let acquireCount = await client.acquireCount()
        XCTAssertEqual(acquireCount, 2)
        await manager.endEditing(documentID: documentID)
        await waitForRelease(1, client: client)
        let releaseCount = await client.releaseCount()
        XCTAssertEqual(releaseCount, 1)
    }

    func testStaleAcquireResponseCannotOverwriteRestoredLiveLease()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = ControlledAcquireLeaseClient()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 3),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        let initial = Task {
            await manager.beginEditing(documentID: documentID)
        }
        await client.waitForAcquireCount(1)
        await manager.documentBecameTombstone(documentID: documentID)
        let restored = Task {
            await manager.ensureLeaseForActiveLiveDocument(
                documentID: documentID,
                serverRevision: 4
            )
        }
        await client.waitForAcquireCount(2)

        await client.completeAcquire(2)
        await restored.value
        await client.completeAcquire(1)
        _ = await initial.value

        let state = await manager.state(
            documentID: documentID,
            deviceID: deviceID
        )
        if case .held = state {
            // expected
        } else {
            XCTFail("낡은 acquire 응답이 복원 lease를 덮었습니다: \(String(describing: state))")
        }
        await waitForControlledRelease(1, client: client)
        let staleReleaseCount = await client.releaseCount()
        XCTAssertEqual(staleReleaseCount, 1)
        await manager.endEditing(documentID: documentID)
        await waitForControlledRelease(2, client: client)
    }

    func testDocumentTransitionDoesNotWaitForLeaseReleaseNetwork()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let releaseGate = LeaseReleaseGate()
        let client = EditLeaseClientStub(releaseGate: releaseGate)
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 3),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )
        let completion = AsyncCompletionProbe()

        _ = await manager.beginEditing(documentID: documentID)
        Task {
            await manager.endEditing(documentID: documentID)
            await completion.markCompleted()
        }
        for _ in 0..<100 {
            if await completion.isCompleted() {
                break
            }
            await Task.yield()
        }

        let didComplete = await completion.isCompleted()
        XCTAssertTrue(
            didComplete,
            "문서 전환은 release RPC 응답을 기다리면 안 됩니다."
        )
        await releaseGate.open()
    }

    func testInactiveCommitAcquiresThenReleasesLease() async throws {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 7),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        let token = try await manager.leaseTokenForCommit(
            documentID: documentID,
            deviceID: deviceID,
            baseRevision: 7
        )
        await manager.commitSucceeded(
            documentID: documentID,
            deviceID: deviceID,
            isDeleted: false
        )
        await waitForRelease(1, client: client)

        XCTAssertNotNil(token)
        let acquireCount = await client.acquireCount()
        let releaseCount = await client.releaseCount()
        XCTAssertEqual(acquireCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testLeaseConflictBecomesHeldByOtherState() async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub(
            acquireError: .remote(
                code: .leaseConflict,
                detail: #"{"expires_at":"2030-01-02T03:04:05Z"}"#
            )
        )
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 1),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        let state = await manager.beginEditing(documentID: documentID)

        guard case .heldByOther(let expiresAt) = state else {
            return XCTFail("Expected heldByOther, got \(state).")
        }
        XCTAssertNotNil(expiresAt)
    }

    func testActiveEditorKeepsHeldByOtherStateAcrossCommitRetry()
        async throws {
        let documentID = UUID()
        let deviceID = UUID()
        let detail = #"{"expires_at":"2030-01-02T03:04:05Z"}"#
        let conflict = SyncV2ClientError.remote(
            code: .leaseConflict,
            detail: detail
        )
        let client = EditLeaseClientStub(acquireError: conflict)
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 1),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        _ = await manager.beginEditing(documentID: documentID)
        await manager.commitFailed(
            documentID: documentID,
            deviceID: deviceID,
            error: conflict
        )

        let lockedState = await manager.state(
            documentID: documentID,
            deviceID: deviceID
        )
        guard case .heldByOther = lockedState else {
            return XCTFail(
                "Expected active editor to retain heldByOther, got "
                    + String(describing: lockedState)
            )
        }

        await client.setAcquireError(nil)
        let token = try await manager.leaseTokenForCommit(
            documentID: documentID,
            deviceID: deviceID,
            baseRevision: 1
        )
        let recoveredState = await manager.state(
            documentID: documentID,
            deviceID: deviceID
        )

        XCTAssertNotNil(token)
        if case .held = recoveredState {
            // expected
        } else {
            XCTFail(
                "Expected held after the other device released, got "
                    + String(describing: recoveredState)
            )
        }
        await manager.endEditing(documentID: documentID)
    }

    func testMissingServerDocumentWaitsForLiveRestoreBeforeReacquiring()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub(
            acquireError: .remote(
                code: .documentNotFound,
                detail: nil
            )
        )
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 1),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )

        let missingState = await manager.beginEditing(
            documentID: documentID
        )
        await client.setAcquireError(nil)
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: documentID,
            serverRevision: 2
        )
        let recoveredState = await manager.state(
            documentID: documentID,
            deviceID: deviceID
        )
        let acquireCount = await client.acquireCount()
        await manager.endEditing(documentID: documentID)

        XCTAssertEqual(missingState, .unavailable)
        if case .held = recoveredState {
            // expected
        } else {
            XCTFail(
                "Expected held after recreate, got "
                    + String(describing: recoveredState)
            )
        }
        XCTAssertEqual(acquireCount, 2)
    }

    @MainActor
    func testEditorRefreshesLeaseAfterServerDocumentLiveRestore()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "서버 문서 복구 표시"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository
            .document(id: volume.documentToOpenID)
        let document = try XCTUnwrap(
            loadedDocument
        )
        let client = EditLeaseClientStub(
            acquireError: .remote(
                code: .documentNotFound,
                detail: nil
            )
        )
        let deviceID = UUID()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 1),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository:
                environment.workspaceStateRepository,
            editLeaseManager: manager,
            editLeaseConnectivityMonitor:
                EditLeaseConnectivityMonitorStub()
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )

        await model.select(node)
        for _ in 0..<100 {
            if model.editLeaseState == .unavailable {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.editLeaseState, .unavailable)

        await client.setAcquireError(nil)
        await manager.ensureLeaseForActiveLiveDocument(
            documentID: document.id.rawValue,
            serverRevision: 2
        )
        for _ in 0..<100 {
            if case .held = model.editLeaseState {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        if case .held = model.editLeaseState {
            // expected
        } else {
            XCTFail("복구된 잠금 상태가 편집기에 반영되지 않았습니다.")
        }
    }

    func testActiveDocumentRenewsLeaseOnHeartbeat() async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub()
        let sleeper = OneShotLeaseSleeper()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            ),
            sleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = await manager.beginEditing(documentID: documentID)
        await sleeper.waitUntilSleeping()
        await sleeper.wake()
        await client.waitForRenewal()
        let renewCount = await client.renewCount()
        await manager.endEditing(documentID: documentID)

        XCTAssertEqual(renewCount, 1)
    }

    func testHeartbeatLeaseExpiredReacquiresExactlyOnce() async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub(
            renewalErrors: [
                .remote(code: .leaseExpired, detail: nil),
            ]
        )
        let sleeper = OneShotLeaseSleeper()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            ),
            sleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = await manager.beginEditing(documentID: documentID)
        await sleeper.waitUntilSleeping()
        await sleeper.wake()
        await waitForAcquire(2, client: client)

        // RPC 호출 수 증가는 응답을 반영한 held 상태의 완료 사건이 아니다.
        let updates = await manager.stateUpdates(documentID: documentID)
        let reacquired = XCTestExpectation(description: "편집권 재획득 완료")
        let observation = Task {
            for await state in updates {
                if case .held = state { reacquired.fulfill(); return }
            }
        }
        await fulfillment(of: [reacquired], timeout: 2)
        observation.cancel()

        let acquireCount = await client.acquireCount()
        let state = await manager.state(
            documentID: documentID,
            deviceID: deviceID
        )
        XCTAssertEqual(acquireCount, 2)
        if case .held = state {
            // expected
        } else {
            XCTFail("leaseExpired 뒤 한 번 재획득해야 합니다: \(String(describing: state))")
        }
        await manager.endEditing(documentID: documentID)
    }

    func testHeartbeatLeaseConflictWaitsUntilExpiryBeforeSingleRetry()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub(
            renewalErrors: [
                .remote(
                    code: .leaseConflict,
                    detail: #"{"expires_at":"1970-01-01T00:16:50Z"}"#
                ),
            ]
        )
        let sleeper = ManualLeaseSleeper()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            ),
            now: { Date(timeIntervalSince1970: 1_000) },
            sleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = await manager.beginEditing(documentID: documentID)
        await sleeper.waitForCallCount(1)
        await sleeper.wakeNext()
        await sleeper.waitForCallCount(2)
        let beforeExpiry = await client.acquireCount()
        let delays = await sleeper.recordedDurations()
        XCTAssertEqual(beforeExpiry, 1)
        XCTAssertEqual(delays.last, .seconds(10))

        await sleeper.wakeNext()
        await waitForAcquire(2, client: client)
        let afterExpiry = await client.acquireCount()
        XCTAssertEqual(afterExpiry, 2)
        await manager.endEditing(documentID: documentID)
    }

    func testHeartbeatNetworkFailureRecoversWithoutConnectivityTransition()
        async {
        let documentID = UUID()
        let deviceID = UUID()
        let client = EditLeaseClientStub(
            renewalErrors: [.networkUnavailable]
        )
        let sleeper = ManualLeaseSleeper()
        let manager = EditLeaseManager(
            client: client,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            ),
            sleep: { duration in
                try await sleeper.sleep(duration)
            }
        )

        _ = await manager.beginEditing(documentID: documentID)
        await sleeper.waitForCallCount(1)
        await sleeper.wakeNext()
        await sleeper.waitForCallCount(2)
        let delays = await sleeper.recordedDurations()
        XCTAssertEqual(delays.last, .seconds(1))
        let beforeRetry = await client.acquireCount()
        XCTAssertEqual(beforeRetry, 1)

        await sleeper.wakeNext()
        await waitForAcquire(2, client: client)
        let afterRetry = await client.acquireCount()
        XCTAssertEqual(afterRetry, 2)
        await manager.endEditing(documentID: documentID)
    }

    @MainActor
    func testEditorShowsOfflineImmediatelyAndRefreshesOnReconnect()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "임대 네트워크 표시"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository
            .document(id: volume.documentToOpenID)
        let document = try XCTUnwrap(
            loadedDocument
        )
        let deviceID = UUID()
        let leaseClient = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: leaseClient,
            revisionProvider: FixedRevisionProvider(revision: 2),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )
        let connectivity = EditLeaseConnectivityMonitorStub()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            editLeaseManager: manager,
            editLeaseConnectivityMonitor: connectivity
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )

        await model.select(node)
        model.updateText("편집 시작")
        await waitForLeaseState(model) {
            if case .held = $0 {
                return true
            }
            return false
        }
        guard case .held = model.editLeaseState else {
            return XCTFail("Expected a held lease before airplane mode.")
        }

        connectivity.send(isConnected: false)
        await waitForLeaseState(model) {
            $0 == .offlineEditing
        }
        XCTAssertEqual(model.editLeaseState, .offlineEditing)

        connectivity.send(isConnected: true)
        await waitForLeaseState(model) {
            if case .held = $0 {
                return true
            }
            return false
        }
        guard case .held = model.editLeaseState else {
            return XCTFail("Expected the lease to refresh after reconnect.")
        }
    }

    @MainActor
    func testEditorShowsOfflineBeforeFirstServerRevision() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "최초 업로드 전 네트워크 표시"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository
            .document(id: volume.documentToOpenID)
        let document = try XCTUnwrap(loadedDocument)
        let manager = EditLeaseManager(
            client: EditLeaseClientStub(),
            revisionProvider: FixedRevisionProvider(revision: 0),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: UUID())
            )
        )
        let connectivity = EditLeaseConnectivityMonitorStub()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            editLeaseManager: manager,
            editLeaseConnectivityMonitor: connectivity
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )

        await model.select(node)
        model.updateText("편집 시작")
        await waitUntil {
            connectivity.isStarted()
        }
        XCTAssertEqual(model.editLeaseState, .localOnly)

        connectivity.send(isConnected: false)
        await waitForLeaseState(model) { $0 == .offlineEditing }

        XCTAssertEqual(model.editLeaseState, .offlineEditing)
    }

    @MainActor
    private func waitForLeaseState(
        _ model: EditorSessionModel,
        matching predicate: @escaping (EditLeaseDisplayState) -> Bool
    ) async {
        guard !predicate(model.editLeaseState) else { return }
        let expectation = XCTestExpectation(
            description: "Expected edit lease state"
        )
        let observation = model.$editLeaseState
            .filter(predicate)
            .prefix(1)
            .sink { _ in expectation.fulfill() }
        await fulfillment(of: [expectation], timeout: 2)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 where !condition() {
            await Task.yield()
        }
    }

    private func waitForRelease(
        _ expectedCount: Int,
        client: EditLeaseClientStub
    ) async {
        for _ in 0..<100 {
            if await client.releaseCount() >= expectedCount {
                return
            }
            await Task.yield()
        }
    }

    private func waitForAcquire(
        _ expectedCount: Int,
        client: EditLeaseClientStub
    ) async {
        for _ in 0..<200 {
            if await client.acquireCount() >= expectedCount {
                return
            }
            await Task.yield()
        }
    }

    private func waitForControlledRelease(
        _ expectedCount: Int,
        client: ControlledAcquireLeaseClient
    ) async {
        for _ in 0..<200 {
            if await client.releaseCount() >= expectedCount {
                return
            }
            await Task.yield()
        }
    }
}

private actor SyncV2CommitTransportStub: SyncV2CommitTransporting {
    private let result: Result<
        SyncV2CommitDocumentResult,
        SyncV2CommitTransportError
    >
    private var calls = 0

    init(
        result: Result<
            SyncV2CommitDocumentResult,
            SyncV2CommitTransportError
        >
    ) {
        self.result = result
    }

    func commitDocument(
        parameters: SyncV2CommitDocumentParameters
    ) throws -> SyncV2CommitDocumentResult {
        _ = parameters
        calls += 1
        return try result.get()
    }

    func commitFolder(
        parameters: SyncV2CommitFolderParameters
    ) throws -> SyncV2CommitFolderResult {
        _ = parameters
        throw SyncV2CommitTransportError.unknown(
            message: "This stub only serves documents."
        )
    }

    func callCount() -> Int {
        calls
    }
}

private actor SyncV2CommitSequenceTransport: SyncV2CommitTransporting {
    private var results: [SyncV2CommitDocumentResult]
    private var received: [SyncV2CommitDocumentParameters] = []

    init(results: [SyncV2CommitDocumentResult]) {
        self.results = results
    }

    func commitDocument(
        parameters: SyncV2CommitDocumentParameters
    ) throws -> SyncV2CommitDocumentResult {
        received.append(parameters)
        guard !results.isEmpty else {
            throw SyncV2CommitTransportError.unknown(
                message: "No scripted result."
            )
        }
        return results.removeFirst()
    }


    func commitFolder(
        parameters: SyncV2CommitFolderParameters
    ) throws -> SyncV2CommitFolderResult {
        _ = parameters
        throw SyncV2CommitTransportError.unknown(
            message: "This stub only serves documents."
        )
    }

    func requests() -> [SyncV2CommitDocumentParameters] {
        received
    }
}

private actor SyncV2CommitFolderTransportStub: SyncV2CommitTransporting {
    private let result: Result<
        SyncV2CommitFolderResult,
        SyncV2CommitTransportError
    >
    private var received: [SyncV2CommitFolderParameters] = []

    init(
        result: Result<
            SyncV2CommitFolderResult,
            SyncV2CommitTransportError
        >
    ) {
        self.result = result
    }

    func commitDocument(
        parameters: SyncV2CommitDocumentParameters
    ) throws -> SyncV2CommitDocumentResult {
        _ = parameters
        throw SyncV2CommitTransportError.unknown(
            message: "This stub only serves folders."
        )
    }

    func commitFolder(
        parameters: SyncV2CommitFolderParameters
    ) throws -> SyncV2CommitFolderResult {
        received.append(parameters)
        return try result.get()
    }

    func requests() -> [SyncV2CommitFolderParameters] {
        received
    }
}

final class SyncV2CommitFolderClientTests: XCTestCase {
    func testTopLevelFolderSendsParentAsExplicitNull() async throws {
        let folderID = UUID()
        let operationID = UUID()
        let transport = SyncV2CommitFolderTransportStub(
            result: .success(
                folderResult(
                    folderID: folderID,
                    operationID: operationID,
                    revision: 1,
                    parentFolderID: nil,
                    name: "가 나 다"
                )
            )
        )
        let client = SyncV2Client(transport: transport)
        let parameters = folderParameters(
            folderID: folderID,
            operationID: operationID,
            baseRevision: 0,
            parentFolderID: nil,
            name: "가 나 다"
        )

        _ = try await client.commitFolder(parameters)

        // PostgREST는 넘긴 인자 이름으로 함수를 고른다. 최상위 폴더라고
        // p_parent_folder_id를 빼면 서명이 달라져 함수를 못 찾는다.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try XCTUnwrap(
            String(data: try encoder.encode(parameters), encoding: .utf8)
        )
        XCTAssertTrue(json.contains("\"p_parent_folder_id\":null"))
        XCTAssertTrue(json.contains("\"p_name\":\"가 나 다\""))
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testRenameKeepsFolderIDAndCarriesCurrentRevision() async throws {
        let folderID = UUID()
        let operationID = UUID()
        let parentID = UUID()
        let transport = SyncV2CommitFolderTransportStub(
            result: .success(
                folderResult(
                    folderID: folderID,
                    operationID: operationID,
                    revision: 4,
                    parentFolderID: parentID,
                    name: "가 나 다 바"
                )
            )
        )
        let client = SyncV2Client(transport: transport)

        let result = try await client.commitFolder(
            folderParameters(
                folderID: folderID,
                operationID: operationID,
                baseRevision: 3,
                parentFolderID: parentID,
                name: "가 나 다 바"
            )
        )

        let requests = await transport.requests()
        XCTAssertEqual(requests.first?.folderID, folderID)
        XCTAssertEqual(requests.first?.baseServerRevision, 3)
        XCTAssertEqual(result.serverRevision, 4)
        XCTAssertEqual(result.status, .committed)
    }

    func testResponseForAnotherFolderIsRejected() async throws {
        let operationID = UUID()
        let transport = SyncV2CommitFolderTransportStub(
            result: .success(
                folderResult(
                    folderID: UUID(),
                    operationID: operationID,
                    revision: 1,
                    parentFolderID: nil,
                    name: "가 나 다"
                )
            )
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitFolder(
                folderParameters(
                    folderID: UUID(),
                    operationID: operationID,
                    baseRevision: 0,
                    parentFolderID: nil,
                    name: "가 나 다"
                )
            )
            XCTFail("A response for another folder must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2ClientError,
                .invalidResponse
            )
        }
    }

    func testUnexpectedRevisionJumpIsRejected() async throws {
        let folderID = UUID()
        let operationID = UUID()
        let transport = SyncV2CommitFolderTransportStub(
            result: .success(
                folderResult(
                    folderID: folderID,
                    operationID: operationID,
                    revision: 9,
                    parentFolderID: nil,
                    name: "가 나 다"
                )
            )
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitFolder(
                folderParameters(
                    folderID: folderID,
                    operationID: operationID,
                    baseRevision: 3,
                    parentFolderID: nil,
                    name: "가 나 다"
                )
            )
            XCTFail("A revision that is not base + 1 must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2ClientError,
                .invalidResponse
            )
        }
    }

    func testFolderNotEmptyIsReportedAsItsOwnCode() async throws {
        let transport = SyncV2CommitFolderTransportStub(
            result: .failure(
                .postgrest(
                    message: "FOLDER_NOT_EMPTY",
                    postgresCode: "P0001",
                    detail: "3 children"
                )
            )
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitFolder(
                folderParameters(
                    folderID: UUID(),
                    operationID: UUID(),
                    baseRevision: 2,
                    parentFolderID: nil,
                    name: "가 나 다",
                    isDeleted: true
                )
            )
            XCTFail("FOLDER_NOT_EMPTY must surface as a remote code.")
        } catch {
            // 재귀 삭제 순서를 고치려면 이 거절을 다른 실패와 구분해야 한다.
            XCTAssertEqual(
                error as? SyncV2ClientError,
                .remote(code: .folderNotEmpty, detail: "3 children")
            )
        }
    }

    func testCreatingAnAlreadyDeletedFolderNeverReachesTheServer()
        async throws {
        let transport = SyncV2CommitFolderTransportStub(
            result: .failure(.invalidResponse)
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitFolder(
                folderParameters(
                    folderID: UUID(),
                    operationID: UUID(),
                    baseRevision: 0,
                    parentFolderID: nil,
                    name: "가 나 다",
                    isDeleted: true
                )
            )
            XCTFail("Creating a tombstone must be rejected locally.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2ClientError,
                .remote(code: .invalidArgument, detail: nil)
            )
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testFolderNameWithSeparatorNeverReachesTheServer() async throws {
        let transport = SyncV2CommitFolderTransportStub(
            result: .failure(.invalidResponse)
        )
        let client = SyncV2Client(transport: transport)

        do {
            _ = try await client.commitFolder(
                folderParameters(
                    folderID: UUID(),
                    operationID: UUID(),
                    baseRevision: 0,
                    parentFolderID: nil,
                    name: "가 나/다"
                )
            )
            XCTFail("A folder name with a separator must be rejected.")
        } catch {
            XCTAssertEqual(
                error as? SyncV2ClientError,
                .remote(code: .invalidArgument, detail: nil)
            )
        }
        let requests = await transport.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testResponseWithoutOptionalFieldsStillDecodes() throws {
        // 서버가 version_id·operation_kind·name을 안 돌려주더라도 대기열을
        // 이어가는 데 필요한 값만 있으면 진행할 수 있어야 한다.
        let folderID = UUID()
        let operationID = UUID()
        let json = """
        {
          "status": "committed",
          "folder_id": "\(folderID.uuidString.lowercased())",
          "operation_id": "\(operationID.uuidString.lowercased())",
          "revision": 1,
          "is_deleted": false,
          "committed_at": "2026-08-03T12:00:00Z"
        }
        """

        let result = try JSONDecoder().decode(
            SyncV2CommitFolderResult.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(result.folderID, folderID)
        XCTAssertEqual(result.serverRevision, 1)
        XCTAssertNil(result.versionID)
        XCTAssertNil(result.operationKind)
        XCTAssertNil(result.name)
    }

    func testFolderRenameResponseDecodesServerOperationKind() throws {
        let folderID = UUID()
        let versionID = UUID()
        let operationID = UUID()
        let json = """
        {
          "status": "committed",
          "folder_id": "\(folderID.uuidString.lowercased())",
          "version_id": "\(versionID.uuidString.lowercased())",
          "operation_id": "\(operationID.uuidString.lowercased())",
          "operation_kind": "rename",
          "revision": 2,
          "parent_folder_id": null,
          "name": "가 나 다 바",
          "is_deleted": false,
          "committed_at": "2026-08-09T12:00:00Z"
        }
        """

        let result = try JSONDecoder().decode(
            SyncV2CommitFolderResult.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(result.folderID, folderID)
        XCTAssertEqual(result.versionID, versionID)
        XCTAssertEqual(result.operationID, operationID)
        XCTAssertEqual(result.operationKind, .rename)
        XCTAssertEqual(result.serverRevision, 2)
        XCTAssertEqual(result.name, "가 나 다 바")
    }

    private func folderParameters(
        folderID: UUID,
        operationID: UUID,
        baseRevision: Int64,
        parentFolderID: UUID?,
        name: String,
        isDeleted: Bool = false
    ) -> SyncV2CommitFolderParameters {
        SyncV2CommitFolderParameters(
            folderID: folderID,
            projectID: UUID(),
            baseServerRevision: baseRevision,
            operationID: operationID,
            deviceID: UUID(),
            parentFolderID: parentFolderID,
            name: name,
            isDeleted: isDeleted
        )
    }

    private func folderResult(
        folderID: UUID,
        operationID: UUID,
        revision: Int64,
        parentFolderID: UUID?,
        name: String,
        isDeleted: Bool = false
    ) -> SyncV2CommitFolderResult {
        SyncV2CommitFolderResult(
            status: .committed,
            folderID: folderID,
            versionID: UUID(),
            operationID: operationID,
            operationKind: revision == 1 ? .create : .update,
            serverRevision: revision,
            parentFolderID: parentFolderID,
            name: name,
            isDeleted: isDeleted,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }
}

/// 폴더 작업만 골라 응답을 짜 주는 client다. 문서 요청도 받아 두 줄이 같이
/// 흐르는지 볼 수 있게 한다.
private actor FolderDispatchClientStub: SyncV2CommitClienting {
    private var scriptedFolderErrors: [UUID: [SyncV2ClientError]]
    private var folderRequests: [SyncV2CommitFolderParameters] = []
    private var documentRequests: [SyncV2CommitDocumentParameters] = []

    init(scriptedFolderErrors: [UUID: [SyncV2ClientError]] = [:]) {
        self.scriptedFolderErrors = scriptedFolderErrors
    }

    func commitDocument(
        _ parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult {
        documentRequests.append(parameters)
        return SyncV2CommitDocumentResult(
            status: .committed,
            documentID: parameters.documentID,
            versionID: UUID(),
            operationID: parameters.operationID,
            operationKind: parameters.baseServerRevision == 0
                ? .create
                : .update,
            serverRevision: parameters.baseServerRevision + 1,
            relativePath: parameters.relativePath,
            isDeleted: parameters.isDeleted,
            contentHash: SHA256ContentHasher()
                .sha256(for: Data(parameters.content.utf8))
                .rawValue,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }

    func commitFolder(
        _ parameters: SyncV2CommitFolderParameters
    ) async throws -> SyncV2CommitFolderResult {
        folderRequests.append(parameters)
        if var pending = scriptedFolderErrors[parameters.operationID],
           !pending.isEmpty {
            let error = pending.removeFirst()
            scriptedFolderErrors[parameters.operationID] = pending
            throw error
        }
        return SyncV2CommitFolderResult(
            status: .committed,
            folderID: parameters.folderID,
            versionID: UUID(),
            operationID: parameters.operationID,
            operationKind: parameters.baseServerRevision == 0
                ? .create
                : .update,
            serverRevision: parameters.baseServerRevision + 1,
            parentFolderID: parameters.parentFolderID,
            name: parameters.name,
            isDeleted: parameters.isDeleted,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }

    func folderCalls() -> [SyncV2CommitFolderParameters] {
        folderRequests
    }

    func documentCalls() -> [SyncV2CommitDocumentParameters] {
        documentRequests
    }
}

final class SyncV2FolderDispatchTests: XCTestCase {
    func testCommittedRevisionUnblocksTheNextFolderOperation()
        async throws {
        let fixture = try await FolderDispatchFixture()
        let createID = UUID()
        let renameID = UUID()
        try await fixture.enqueueFolder(operationID: createID, name: "가 나 다")
        try await fixture.enqueueFolder(
            operationID: renameID,
            name: "가 나 다 바"
        )
        let client = FolderDispatchClientStub()
        let dispatcher = SyncV2Dispatcher(
            store: fixture.store,
            client: client
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10)
        )
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 20)
        )

        let calls = await client.folderCalls()
        XCTAssertEqual(calls.map(\.operationID), [createID, renameID])
        // 생성이 받아온 revision 위에서 이름 변경이 이어져야 한다. 0으로 다시
        // 보내면 서버가 이미 있는 폴더라며 거절한다.
        XCTAssertEqual(calls.map(\.baseServerRevision), [0, 1])
        XCTAssertEqual(calls.map(\.name), ["가 나 다", "가 나 다 바"])
        let renameStatus = try await fixture.store.operationStatus(
            operationID: renameID
        )
        XCTAssertEqual(
            renameStatus,
            SyncV2OperationStatus.completed.rawValue
        )
        await fixture.close()
    }

    func testRetryReusesTheSameOperationID() async throws {
        let fixture = try await FolderDispatchFixture()
        let operationID = UUID()
        try await fixture.enqueueFolder(
            operationID: operationID,
            name: "가 나 다"
        )
        let client = FolderDispatchClientStub(
            scriptedFolderErrors: [operationID: [.networkUnavailable]]
        )
        let dispatcher = SyncV2Dispatcher(
            store: fixture.store,
            client: client
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10)
        )
        // 재시도 대기가 풀릴 만큼 시간을 넘긴다.
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10_000)
        )

        let calls = await client.folderCalls()
        // 끊겼다 이어져도 새 operation_id를 만들면 서버가 다른 작업으로 보고
        // 폴더를 한 번 더 만든다.
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.operationID), [operationID, operationID])
        let status = try await fixture.store.operationStatus(
            operationID: operationID
        )
        XCTAssertEqual(status, SyncV2OperationStatus.completed.rawValue)
        await fixture.close()
    }

    func testFolderNotEmptyStopsTheLaneInsteadOfRetrying() async throws {
        let fixture = try await FolderDispatchFixture()
        let operationID = UUID()
        try await fixture.enqueueFolder(
            operationID: operationID,
            name: "가 나 다",
            isDeleted: true
        )
        let client = FolderDispatchClientStub(
            scriptedFolderErrors: [
                operationID: [
                    .remote(code: .folderNotEmpty, detail: "2 children"),
                    .remote(code: .folderNotEmpty, detail: "2 children"),
                ]
            ]
        )
        let dispatcher = SyncV2Dispatcher(
            store: fixture.store,
            client: client
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10)
        )
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10_000)
        )

        let calls = await client.folderCalls()
        // 순서를 잘못 잡았다는 뜻이라 그대로 다시 보내면 계속 거절당한다.
        XCTAssertEqual(calls.count, 1)
        let status = try await fixture.store.operationStatus(
            operationID: operationID
        )
        XCTAssertEqual(status, SyncV2OperationStatus.conflict.rawValue)
        await fixture.close()
    }

    func testFolderAndDocumentLanesDrainInTheSameCycle() async throws {
        let fixture = try await FolderDispatchFixture()
        let folderOperationID = UUID()
        let documentOperationID = UUID()
        try await fixture.enqueueFolder(
            operationID: folderOperationID,
            name: "가 나 다"
        )
        try await fixture.enqueueDocument(operationID: documentOperationID)
        let client = FolderDispatchClientStub()
        let dispatcher = SyncV2Dispatcher(
            store: fixture.store,
            client: client
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 10)
        )

        let folderCalls = await client.folderCalls()
        let documentCalls = await client.documentCalls()
        XCTAssertEqual(
            folderCalls.map(\.operationID),
            [folderOperationID]
        )
        XCTAssertEqual(
            documentCalls.map(\.operationID),
            [documentOperationID]
        )
        await fixture.close()
    }
}

/// 폴더 dispatch는 실제 저장소에 revision을 남기는 일이 핵심이라 stub 대신
/// 진짜 SyncV2Store를 쓴다.
private struct FolderDispatchFixture {
    let store: SyncV2Store
    let localProjectID = ProjectID(rawValue: UUID())
    let serverProjectID = UUID()
    let ownerSubject = UUID()
    let deviceID = UUID()
    let folderID = UUID()
    let documentID = UUID()
    private let directory: URL

    init() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-folder-dispatch-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("sync-v2.sqlite3")
        switch await SyncV2Store.open(at: url) {
        case .available(let opened):
            store = opened
        case .unavailable(let diagnostic):
            throw FolderDispatchFixtureError.openFailed(diagnostic)
        }
        try await store.save(
            .connected(
                localProjectID: localProjectID,
                serverProjectID: serverProjectID,
                kind: .newServerProject,
                projectName: "폴더 dispatch fixture",
                ownerSubject: ownerSubject
            )
        )
    }

    func enqueueFolder(
        operationID: UUID,
        name: String,
        isDeleted: Bool = false
    ) async throws {
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .structureChange,
                mutations: [
                    .folder(
                        SyncV2FolderMutation(
                            operationID: operationID,
                            folderID: folderID,
                            parentFolderID: nil,
                            deviceID: deviceID,
                            name: name,
                            isDeleted: isDeleted
                        )
                    )
                ]
            )
        )
    }

    func enqueueDocument(operationID: UUID) async throws {
        _ = try await store.enqueue(
            SyncV2EnqueueBatch(
                batchID: UUID(),
                localProjectID: localProjectID,
                localTransactionID: UUID(),
                kind: .documentSave,
                mutations: [
                    .document(
                        SyncV2DocumentMutation(
                            operationID: operationID,
                            documentID: documentID,
                            deviceID: deviceID,
                            localSaveGeneration: 1,
                            kind: .documentCommit,
                            localPath: "/fixture/원고/001화.txt",
                            relativePath: "원고/001화.txt",
                            content: "본문",
                            isDeleted: false
                        )
                    )
                ]
            )
        )
    }

    func close() async {
        await store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum FolderDispatchFixtureError: Error {
    case openFailed(SyncV2StoreDiagnostic)
}

final class SyncV2DispatcherTests: XCTestCase {
    func testRetryPolicyIsExponentialCappedAndJittered() {
        let policy = SyncV2RetryPolicy(
            initialDelay: 2,
            maximumDelay: 10,
            jitterFraction: 0.25
        )

        XCTAssertEqual(policy.delay(attempt: 1, randomUnit: 0), 1.5)
        XCTAssertEqual(policy.delay(attempt: 2, randomUnit: 0.5), 4)
        XCTAssertEqual(policy.delay(attempt: 3, randomUnit: 1), 10)
        XCTAssertEqual(policy.delay(attempt: 20, randomUnit: 0.5), 10)
    }

    func testLeaseConflictUsesShortFixedDelayInsteadOfBackoff() {
        let policy = SyncV2RetryPolicy(
            initialDelay: 2,
            maximumDelay: 5 * 60,
            jitterFraction: 0.2,
            leaseConflictDelay: 3
        )

        XCTAssertEqual(
            policy.delay(
                errorCode: "LEASE_CONFLICT",
                attempt: 1,
                randomUnit: 0
            ),
            3
        )
        XCTAssertEqual(
            policy.delay(
                errorCode: "LEASE_CONFLICT",
                attempt: 20,
                randomUnit: 1
            ),
            3
        )
        XCTAssertGreaterThan(
            policy.delay(
                errorCode: "NETWORK_UNAVAILABLE",
                attempt: 20,
                randomUnit: 0.5
            ),
            3
        )
    }

    func testNetworkRecoveryRequiresDisconnectedToConnectedTransition() {
        var initiallyOnline = SyncV2NetworkRecoveryDetector()
        XCTAssertFalse(initiallyOnline.receive(isSatisfied: true))
        XCTAssertFalse(initiallyOnline.receive(isSatisfied: true))

        var recovery = SyncV2NetworkRecoveryDetector()
        XCTAssertFalse(recovery.receive(isSatisfied: false))
        XCTAssertFalse(recovery.receive(isSatisfied: false))
        XCTAssertTrue(recovery.receive(isSatisfied: true))
        XCTAssertFalse(recovery.receive(isSatisfied: true))
    }

    func testRepeatedRecoverySignalsShareOneGlobalRecoveryFlight()
        async {
        let hub = SyncV2NetworkRecoveryHub()
        let probe = NetworkRecoveryProbe()
        await hub.install {
            await probe.run()
        }

        await hub.signal()
        await hub.signal()
        for _ in 0..<100 {
            if await probe.startedCount() == 1 {
                break
            }
            await Task.yield()
        }
        let startsWhileBlocked = await probe.startedCount()
        XCTAssertEqual(startsWhileBlocked, 1)

        await probe.finish()
        for _ in 0..<100 {
            if await probe.completedCount() == 1 {
                break
            }
            await Task.yield()
        }
        let completions = await probe.completedCount()
        XCTAssertEqual(completions, 1)
    }

    func testLimitedConcurrencyAndConflictIsolation() async {
        let localProjectID = ProjectID(rawValue: UUID())
        let operations = (0 ..< 4).map {
            dispatchOperation(
                documentID: UUID(),
                sequence: 1,
                suffix: $0,
                localProjectID: localProjectID
            )
        }
        let store = DispatcherStoreStub(operations: operations)
        let client = DispatcherClientStub(
            conflictOperationIDs: [operations[0].operationID],
            delayNanoseconds: 40_000_000
        )
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            maximumConcurrentDocuments: 2,
            randomUnit: { 0.5 }
        )

        await dispatcher.prioritizeProject(localProjectID)
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let maximumActive = await client.maximumActiveCalls()
        let completed = await store.completedOperationIDs()
        let conflicts = await store.conflictOperationIDs()
        XCTAssertEqual(maximumActive, 2)
        XCTAssertEqual(
            completed,
            Set(operations.dropFirst().map(\.operationID))
        )
        XCTAssertEqual(conflicts, [operations[0].operationID])
    }

    func testEveryImmediateOpportunityReleasesRetryWait() async throws {
        let operations = (0 ..< 4).map {
            dispatchOperation(
                documentID: UUID(),
                sequence: 1,
                suffix: 10 + $0
            )
        }
        let store = DispatcherStoreStub(
            operations: operations,
            initialStatus: .retryWait
        )
        let client = DispatcherClientStub()
        let dispatcher = SyncV2Dispatcher(store: store, client: client)
        await dispatcher.start()

        await dispatcher.loginSucceeded()
        try await waitUntilCompleted(operations[0], store: store)
        await store.resetToRetryWait(operation: operations[1])
        await dispatcher.appEnteredForeground()
        try await waitUntilCompleted(operations[1], store: store)
        await store.resetToRetryWait(operation: operations[2])
        await dispatcher.userRequestedRetry()
        try await waitUntilCompleted(operations[2], store: store)
        await store.resetToRetryWait(operation: operations[3])
        await dispatcher.networkRecovered()
        try await waitUntilCompleted(operations[3], store: store)
        await dispatcher.stop()

        let completed = await store.completedOperationIDs()
        let opportunityCount = await store.immediateOpportunityCount()
        XCTAssertEqual(completed, Set(operations.map(\.operationID)))
        XCTAssertEqual(opportunityCount, 4)
    }

    func testNewQueueSignalDispatchesWithoutForegroundOrManualRetry()
        async throws {
        let operation = dispatchOperation(
            documentID: UUID(),
            sequence: 1,
            suffix: 15
        )
        let store = DispatcherStoreStub(operations: [])
        let client = DispatcherClientStub()
        let wakeup = SyncV2DispatchWakeup()
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            wakeup: wakeup
        )
        await dispatcher.start()

        var completed = await store.completedOperationIDs()
        XCTAssertTrue(completed.isEmpty)

        await store.enqueue(operation)
        await wakeup.signal()
        for _ in 0..<100 where completed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            completed = await store.completedOperationIDs()
        }
        await dispatcher.stop()

        XCTAssertEqual(completed, Set([operation.operationID]))
    }

    func testStartDrainsOperationsPersistedBeforeLaunch() async throws {
        let operation = dispatchOperation(
            documentID: UUID(),
            sequence: 1,
            suffix: 16
        )
        let store = DispatcherStoreStub(operations: [operation])
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: DispatcherClientStub()
        )

        await dispatcher.start()
        try await waitUntilCompleted(operation, store: store)
        let completed = await store.completedOperationIDs()
        await dispatcher.stop()

        XCTAssertEqual(completed, Set([operation.operationID]))
    }

    func testSlowProjectDoesNotBlockAnotherProjectLane() async throws {
        let slowProjectID = ProjectID(rawValue: UUID())
        let fastProjectID = ProjectID(rawValue: UUID())
        let slow = dispatchOperation(
            documentID: UUID(),
            sequence: 1,
            suffix: 17,
            localProjectID: slowProjectID
        )
        let fast = dispatchOperation(
            documentID: UUID(),
            sequence: 1,
            suffix: 18,
            localProjectID: fastProjectID
        )
        let store = DispatcherStoreStub(operations: [slow, fast])
        let client = DispatcherClientStub(
            delayNanosecondsByOperation: [
                slow.operationID: 300_000_000
            ]
        )
        let dispatcher = SyncV2Dispatcher(store: store, client: client)

        await dispatcher.start()
        try await waitUntilCompleted(fast, store: store)

        var completed = await store.completedOperationIDs()
        XCTAssertTrue(completed.contains(fast.operationID))
        XCTAssertFalse(completed.contains(slow.operationID))

        try await waitUntilCompleted(slow, store: store)
        completed = await store.completedOperationIDs()
        await dispatcher.stop()
        XCTAssertEqual(
            completed,
            Set([slow.operationID, fast.operationID])
        )
    }

    private func waitUntilCompleted(
        _ operation: SyncV2DispatchOperation,
        store: DispatcherStoreStub
    ) async throws {
        for _ in 0..<100 {
            if await store.completedOperationIDs().contains(
                operation.operationID
            ) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("operation completion timeout: \(operation.operationID)")
    }

    func testTransientFailureUsesAttemptCountForBackoff() async {
        let operation = dispatchOperation(
            documentID: UUID(),
            sequence: 1,
            suffix: 20
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub(
            retryOperationIDs: [operation.operationID]
        )
        let policy = SyncV2RetryPolicy(
            initialDelay: 3,
            maximumDelay: 60,
            jitterFraction: 0
        )
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            retryPolicy: policy,
            randomUnit: { 0.5 }
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await dispatcher.dispatchReadyOperations(now: now)

        let retry = await store.retryRecord(
            operationID: operation.operationID
        )
        XCTAssertEqual(retry?.errorCode, "NETWORK_UNAVAILABLE")
        XCTAssertEqual(
            retry?.nextAttemptAt.timeIntervalSince1970,
            now.addingTimeInterval(3).timeIntervalSince1970
        )
    }

    /// 두 기기가 같은 작품에 처음 연결하면 tree-order의 document UUID는
    /// 양쪽이 같은 값으로 계산하므로 늦은 쪽은 base revision 0으로 보낸
    /// create가 DOCUMENT_ALREADY_EXISTS로 거절된다. Windows 클라이언트는 이
    /// 코드를 REVISION_CONFLICT와 같이 취급해 서버 최신 revision 위로
    /// rebase한다. iPad도 같은 경로를 타야 영구 정지가 생기지 않는다.
    func testDocumentAlreadyExistsRebasesTreeOrderInsteadOfBlocking() async {
        let projectID = UUID()
        let documentID = syncV2UUIDv5(
            namespace: projectID,
            name: syncV2TreeOrderPath
        )
        let localContent =
            "{\"tree_order\":{\"<root>\":[\"메모장\",\"휴지통\"],\"메인/메모장\":[\"둘째.txt\",\"첫째.txt\"]},\"version\":1}"
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            localProjectID: ProjectID(rawValue: projectID),
            projectID: projectID,
            documentID: documentID,
            deviceID: UUID(),
            documentSequence: 1,
            localSaveGeneration: 7,
            kind: .treeOrder,
            baseRevision: 0,
            baseContent: "",
            baseServerPath: syncV2TreeOrderPath,
            localPath: syncV2TreeOrderPath,
            relativePath: syncV2TreeOrderPath,
            content: localContent,
            isDeleted: false,
            attempts: 0
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub(
            alreadyExistsOperationIDs: [operation.operationID]
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remoteSnapshot(
                    documentID: documentID,
                    path: syncV2TreeOrderPath,
                    content:
                        "{\"folder_paths\":[\"메인/윈-빈폴더\",\"메인/윈-든폴더\"],\"tree_order\":{\"<root>\":[\"메모장\",\"윈-빈폴더\",\"윈-든폴더\",\"휴지통\"],\"메인/메모장\":[\"첫째.txt\"],\"메인/윈-빈폴더\":[],\"메인/윈-든폴더\":[\"윈-문서.txt\"]},\"version\":1}"
                )
            )
        )
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            automaticRebaser: rebaser
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let conflicts = await store.conflictOperationIDs()
        let rebase = await store.rebaseRecord(
            operationID: operation.operationID
        )
        XCTAssertFalse(conflicts.contains(operation.operationID))
        XCTAssertEqual(rebase?.remoteRevision, 4)
        XCTAssertEqual(rebase?.mergedPath, syncV2TreeOrderPath)
        let mergedData = try? XCTUnwrap(
            rebase?.mergedContent.data(using: .utf8)
        )
        let mergedObject = mergedData.flatMap {
            try? JSONSerialization.jsonObject(with: $0)
                as? [String: Any]
        }
        let mergedOrder = mergedObject?["tree_order"]
            as? [String: [String]]
        let folderPaths = mergedObject?["folder_paths"] as? [String]
        XCTAssertEqual(
            mergedOrder?["<root>"],
            ["메모장", "윈-빈폴더", "윈-든폴더", "휴지통"]
        )
        XCTAssertEqual(mergedOrder?["메인/윈-빈폴더"], [])
        XCTAssertEqual(
            mergedOrder?["메인/윈-든폴더"],
            ["윈-문서.txt"]
        )
        XCTAssertTrue(folderPaths?.contains("메인/윈-빈폴더") == true)
    }

    private func waitForRelease(
        _ expectedCount: Int,
        client: EditLeaseClientStub
    ) async {
        for _ in 0..<100 {
            if await client.releaseCount() >= expectedCount {
                return
            }
            await Task.yield()
        }
    }

    func testExistingCommitUsesLeaseTokenAndReleasesInactiveLease() async {
        let documentID = UUID()
        let deviceID = UUID()
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            projectID: UUID(),
            documentID: documentID,
            deviceID: deviceID,
            documentSequence: 1,
            kind: .documentCommit,
            baseRevision: 5,
            relativePath: "원고/1권/005.txt",
            content: "기존 문서 수정",
            isDeleted: false,
            attempts: 0
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub()
        let leaseClient = EditLeaseClientStub()
        let manager = EditLeaseManager(
            client: leaseClient,
            revisionProvider: FixedRevisionProvider(revision: 5),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: deviceID)
            )
        )
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            leaseManager: manager
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let request = (await client.receivedRequests()).first
        let acquireCount = await leaseClient.acquireCount()
        await waitForRelease(1, client: leaseClient)
        let releaseCount = await leaseClient.releaseCount()
        XCTAssertNotNil(request?.leaseToken)
        XCTAssertEqual(acquireCount, 1)
        XCTAssertEqual(releaseCount, 1)
    }

    func testLeaseConflictRetriesSameOperationAfterOtherDeviceReleases()
        async throws {
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "마지막 서버 기준본\n",
            content: "잠금 중 저장된 iPad 로컬 본문\n"
        )
        let store = DispatcherStoreStub(operations: [operation])
        let leaseClient = EditLeaseClientStub(
            acquireError: .remote(
                code: .leaseConflict,
                detail: #"{"expires_at":"2030-01-02T03:04:05Z"}"#
            )
        )
        let manager = EditLeaseManager(
            client: leaseClient,
            revisionProvider: FixedRevisionProvider(revision: 3),
            deviceIdentityProvider: FixedDeviceIdentityProvider(
                identifier: DeviceIdentifier(uuid: operation.deviceID)
            )
        )
        let client = DispatcherClientStub()
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            retryPolicy: SyncV2RetryPolicy(
                initialDelay: 2,
                maximumDelay: 10,
                jitterFraction: 0
            ),
            randomUnit: { 0.5 },
            leaseManager: manager
        )
        let firstAttempt = Date(timeIntervalSince1970: 1_800_000_000)

        await dispatcher.dispatchReadyOperations(now: firstAttempt)

        let retry = await store.retryRecord(
            operationID: operation.operationID
        )
        let conflicts = await store.conflictOperationIDs()
        let requestsWhileLocked = await client.receivedRequests()
        XCTAssertEqual(retry?.errorCode, "LEASE_CONFLICT")
        XCTAssertEqual(
            retry?.nextAttemptAt.timeIntervalSince1970,
            firstAttempt.addingTimeInterval(3).timeIntervalSince1970
        )
        XCTAssertTrue(conflicts.isEmpty)
        XCTAssertTrue(requestsWhileLocked.isEmpty)

        await leaseClient.setAcquireError(nil)
        await store.makeRetryWaitOperationsReady(localProjectID: nil)
        await dispatcher.dispatchReadyOperations(
            now: firstAttempt.addingTimeInterval(3)
        )

        let completed = await store.completedOperationIDs()
        let requests = await client.receivedRequests()
        XCTAssertEqual(completed, [operation.operationID])
        XCTAssertEqual(requests.map(\.operationID), [operation.operationID])
        XCTAssertNotNil(requests.first?.leaseToken)
        XCTAssertEqual(requests.first?.content, operation.content)
    }

    func testDocumentNotFoundIsRequeuedAsCreateInsteadOfConflict()
        async {
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            projectID: UUID(),
            documentID: UUID(),
            deviceID: UUID(),
            documentSequence: 1,
            kind: .documentCommit,
            baseRevision: 1,
            relativePath: "원고/1권/001화.txt",
            content: "서버에서 사라진 문서의 로컬 본문",
            isDeleted: false,
            attempts: 0
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub(
            missingOperationIDs: [operation.operationID]
        )
        let dispatcher = SyncV2Dispatcher(store: store, client: client)

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let requests = await client.receivedRequests()
        let recoveries = await store.missingRecoveryCount()
        let completed = await store.completedOperationIDs()
        let conflicts = await store.conflictOperationIDs()
        XCTAssertEqual(requests.map(\.baseServerRevision), [1, 0])
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(completed, [operation.operationID])
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testForbiddenCreateEnsuresMissingProjectBeforeRetry()
        async {
        let projectID = UUID()
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            projectID: projectID,
            documentID: UUID(),
            deviceID: UUID(),
            documentSequence: 1,
            kind: .documentCommit,
            baseRevision: 0,
            relativePath: "원고/1권/004화.txt",
            content: "작품 재생성 뒤 보낼 본문",
            isDeleted: false,
            attempts: 0
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub(
            forbiddenCreateOperationIDs: [operation.operationID]
        )
        let recovery = ProjectRecoveryTransportStub()
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            projectRecoveryTransport: recovery
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await store.makeRetryWaitOperationsReady(localProjectID: nil)
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        let ensured = await recovery.receivedParameters()
        let requests = await client.receivedRequests()
        let completed = await store.completedOperationIDs()
        let projectRecoveries = await store.missingProjectRecoveryCount()
        XCTAssertEqual(ensured.count, 1)
        XCTAssertEqual(ensured.first?.projectID, projectID)
        XCTAssertEqual(ensured.first?.name, "복구 작품")
        XCTAssertEqual(projectRecoveries, 1)
        XCTAssertEqual(requests.map(\.baseServerRevision), [0, 0])
        XCTAssertEqual(completed, [operation.operationID])
    }

    func testForbiddenUpdateRepairsOwnerMembershipBeforeRetry()
        async {
        let projectID = UUID()
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            projectID: projectID,
            documentID: UUID(),
            deviceID: UUID(),
            documentSequence: 1,
            kind: .documentCommit,
            baseRevision: 3,
            relativePath: "원고/1권/006화.txt",
            content: "오프라인에서 작성한 본문",
            isDeleted: false,
            attempts: 0
        )
        let store = DispatcherStoreStub(operations: [operation])
        let client = DispatcherClientStub(
            forbiddenCreateOperationIDs: [operation.operationID]
        )
        let recovery = ProjectRecoveryTransportStub()
        let dispatcher = SyncV2Dispatcher(
            store: store,
            client: client,
            projectRecoveryTransport: recovery
        )

        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await store.makeRetryWaitOperationsReady(localProjectID: nil)
        await dispatcher.dispatchReadyOperations(
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        let ensured = await recovery.receivedParameters()
        let requests = await client.receivedRequests()
        let completed = await store.completedOperationIDs()
        let projectRecoveries = await store.missingProjectRecoveryCount()
        XCTAssertEqual(ensured.count, 1)
        XCTAssertEqual(ensured.first?.projectID, projectID)
        XCTAssertEqual(ensured.first?.name, "복구 작품")
        XCTAssertEqual(projectRecoveries, 0)
        XCTAssertEqual(requests.map(\.baseServerRevision), [3, 3])
        XCTAssertEqual(completed, [operation.operationID])
    }

    func testAutomaticRebaseMergesNonOverlappingContentAndRemoteRename()
        async throws {
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "첫 줄\n둘째 줄\n셋째 줄\n",
            content: "로컬 첫 줄\n둘째 줄\n셋째 줄\n"
        )
        let remote = remoteSnapshot(
            documentID: documentID,
            path: "원고/1권/새이름.txt",
            content: "첫 줄\n둘째 줄\n서버 셋째 줄\n"
        )
        let store = AutomaticRebaseStoreStub(
            local: SyncV2RebaseLocalSnapshot(
                content: operation.content,
                localPath: operation.localPath,
                relativePath: operation.relativePath,
                localSaveGeneration: operation.localSaveGeneration
            )
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remote
            )
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()

        XCTAssertEqual(outcome, .rebased)
        XCTAssertEqual(recorded?.remote, remote)
        XCTAssertEqual(
            recorded?.mergedContent,
            "로컬 첫 줄\n둘째 줄\n서버 셋째 줄\n"
        )
        XCTAssertEqual(recorded?.mergedPath, remote.relativePath)
    }

    func testAutomaticRebaseKeepsLocalRenameWhenRemotePathIsUnchanged()
        async throws {
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "공통\n",
            content: "로컬 수정\n",
            relativePath: "원고/1권/로컬이름.txt"
        )
        let store = AutomaticRebaseStoreStub(
            local: SyncV2RebaseLocalSnapshot(
                content: operation.content,
                localPath: operation.localPath,
                relativePath: operation.relativePath,
                localSaveGeneration: operation.localSaveGeneration
            )
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remoteSnapshot(
                    documentID: documentID,
                    path: operation.baseServerPath,
                    content: "공통\n서버 삽입\n"
                )
            )
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()

        XCTAssertEqual(outcome, .rebased)
        XCTAssertEqual(
            recorded?.mergedPath,
            operation.relativePath
        )
    }

    func testTreeOrderRevisionConflictRebasesLatestLocalSnapshot()
        async throws {
        let projectID = UUID()
        let documentID = syncV2UUIDv5(
            namespace: projectID,
            name: syncV2TreeOrderPath
        )
        let localContent =
            "{\"tree_order\":{\"메인/메모장\":[\"둘째.txt\",\"첫째.txt\"]},\"version\":1}"
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            localProjectID: ProjectID(rawValue: UUID()),
            projectID: projectID,
            documentID: documentID,
            deviceID: UUID(),
            documentSequence: 2,
            localSaveGeneration: 20,
            kind: .treeOrder,
            baseRevision: 3,
            baseContent:
                "{\"tree_order\":{\"메인/메모장\":[\"첫째.txt\"]},\"version\":1}",
            baseServerPath: syncV2TreeOrderPath,
            localPath: syncV2TreeOrderPath,
            relativePath: syncV2TreeOrderPath,
            content: localContent,
            isDeleted: false,
            attempts: 1
        )
        let local = SyncV2RebaseLocalSnapshot(
            content: localContent,
            localPath: syncV2TreeOrderPath,
            relativePath: syncV2TreeOrderPath,
            localSaveGeneration: 20
        )
        let remote = remoteSnapshot(
            documentID: documentID,
            path: syncV2TreeOrderPath,
            content:
                "{\"tree_order\":{\"메인/메모장\":[\"첫째.txt\",\"둘째.txt\"]},\"version\":1}"
        )
        let store = AutomaticRebaseStoreStub(local: local)
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remote
            )
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()

        XCTAssertEqual(outcome, .rebased)
        XCTAssertEqual(recorded?.remote, remote)
        XCTAssertEqual(recorded?.mergedContent, localContent)
        XCTAssertEqual(recorded?.mergedPath, syncV2TreeOrderPath)
    }

    func testTrashPurgeRevisionConflictMergesMaximumsAndLocalGeneration()
        async throws {
        let projectID = UUID()
        let documentID = syncV2UUIDv5(
            namespace: projectID,
            name: syncV2TrashPurgePath
        )
        let firstID = UUID()
        let secondID = UUID()
        let localGeneration = UUID().uuidString.lowercased()
        let remoteGeneration = UUID().uuidString.lowercased()
        let localContent = try SyncV2TrashPurgePayload(
            purgedRevisions: [firstID: 5, secondID: 7],
            emptyGeneration: localGeneration
        ).canonicalContent()
        let remoteContent = try SyncV2TrashPurgePayload(
            purgedRevisions: [firstID: 6, secondID: 4],
            emptyGeneration: remoteGeneration
        ).canonicalContent()
        let operation = SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            localProjectID: ProjectID(rawValue: UUID()),
            projectID: projectID,
            documentID: documentID,
            deviceID: UUID(),
            documentSequence: 2,
            kind: .trashPurge,
            baseRevision: 3,
            baseContent: "",
            baseServerPath: syncV2TrashPurgePath,
            localPath: syncV2TrashPurgePath,
            relativePath: syncV2TrashPurgePath,
            content: localContent,
            isDeleted: false,
            attempts: 1
        )
        let local = SyncV2RebaseLocalSnapshot(
            content: localContent,
            localPath: syncV2TrashPurgePath,
            relativePath: syncV2TrashPurgePath,
            localSaveGeneration: nil
        )
        let remote = remoteSnapshot(
            documentID: documentID,
            path: syncV2TrashPurgePath,
            content: remoteContent
        )
        let store = AutomaticRebaseStoreStub(local: local)
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remote
            )
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()
        let merged = try XCTUnwrap(recorded).mergedContent
        let payload = try SyncV2TrashPurgePayload(strictContent: merged)

        XCTAssertEqual(outcome, .rebased)
        XCTAssertEqual(payload.purgedRevisions[firstID], 6)
        XCTAssertEqual(payload.purgedRevisions[secondID], 7)
        XCTAssertEqual(payload.emptyGeneration, localGeneration)
        XCTAssertEqual(recorded?.mergedPath, syncV2TrashPurgePath)
    }

    func testAutomaticRebaseLeavesOverlappingEditAsConflict()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WriterPad-conflict-local-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let localTXT = directory.appendingPathComponent("001화.txt")
        let originalLocalContent = "내 문장\n"
        try Data(originalLocalContent.utf8).write(
            to: localTXT,
            options: [.atomic]
        )
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "공통 문장\n",
            content: originalLocalContent
        )
        let store = AutomaticRebaseStoreStub(
            local: SyncV2RebaseLocalSnapshot(
                content: operation.content,
                localPath: operation.localPath,
                relativePath: operation.relativePath,
                localSaveGeneration: operation.localSaveGeneration
            )
        )
        let localApplier = AutomaticRebaseLocalApplierSpy(
            fileURL: localTXT
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remoteSnapshot(
                    documentID: documentID,
                    path: operation.relativePath,
                    content: "서버 문장\n"
                )
            ),
            localApplier: localApplier
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()
        let preserved = await store.recordedConflict()
        let applyCount = await localApplier.applyCount()

        XCTAssertEqual(outcome, .conflictPreserved)
        XCTAssertNil(recorded)
        XCTAssertEqual(preserved?.operation, operation)
        XCTAssertEqual(preserved?.remote.content, "서버 문장\n")
        XCTAssertEqual(preserved?.local.content, "내 문장\n")
        XCTAssertEqual(preserved?.conflictCount, 1)
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(
            try String(contentsOf: localTXT, encoding: .utf8),
            originalLocalContent
        )
    }

    func testAutomaticRebaseRejectsResultWhenOpenGenerationAdvances()
        async throws {
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "공통\n서버 대상\n",
            content: "로컬\n서버 대상\n"
        )
        let local = SyncV2RebaseLocalSnapshot(
            content: operation.content + "최신 입력\n",
            localPath: operation.localPath,
            relativePath: operation.relativePath,
            localSaveGeneration: 9
        )
        let store = AutomaticRebaseStoreStub(
            local: SyncV2RebaseLocalSnapshot(
                content: operation.content,
                localPath: operation.localPath,
                relativePath: operation.relativePath,
                localSaveGeneration: operation.localSaveGeneration
            )
        )
        let openProvider = AutomaticRebaseOpenProviderStub(
            snapshot: local,
            remainsCurrent: false
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remoteSnapshot(
                    documentID: documentID,
                    path: operation.relativePath,
                    content: "공통\n서버 수정\n"
                )
            ),
            openLocalProvider: openProvider
        )

        let outcome = try await rebaser.rebase(operation)
        let recorded = await store.recordedRebase()

        XCTAssertEqual(outcome, .generationAdvanced)
        XCTAssertNil(recorded)
    }

    func testAutomaticRebaseStopsWhenAnotherUUIDOccupiesDestinationPath()
        async throws {
        let documentID = UUID()
        let operation = rebaseOperation(
            documentID: documentID,
            baseContent: "공통\n둘째\n",
            content: "로컬\n둘째\n"
        )
        let store = AutomaticRebaseStoreStub(
            local: SyncV2RebaseLocalSnapshot(
                content: operation.content,
                localPath: operation.localPath,
                relativePath: operation.relativePath,
                localSaveGeneration: operation.localSaveGeneration
            ),
            result: .pathOccupiedByDifferentDocument
        )
        let rebaser = SyncV2AutomaticRebaser(
            store: store,
            snapshotClient: AutomaticRebaseSnapshotClientStub(
                snapshot: remoteSnapshot(
                    documentID: documentID,
                    path: "원고/1권/점유됨.txt",
                    content: "공통\n서버 둘째\n"
                )
            )
        )

        let outcome = try await rebaser.rebase(operation)

        guard case let .conflict(code, _) = outcome else {
            return XCTFail("점유 경로는 자동 rebase를 중단해야 합니다.")
        }
        XCTAssertEqual(code, "PATH_CONFLICT")
    }

    private func rebaseOperation(
        documentID: UUID,
        baseContent: String,
        content: String,
        relativePath: String = "원고/1권/001화.txt"
    ) -> SyncV2DispatchOperation {
        SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            localProjectID: ProjectID(rawValue: UUID()),
            projectID: UUID(),
            documentID: documentID,
            deviceID: UUID(),
            documentSequence: 1,
            localSaveGeneration: 5,
            kind: .documentCommit,
            baseRevision: 3,
            baseContent: baseContent,
            baseServerPath: "원고/1권/001화.txt",
            localPath: relativePath,
            relativePath: relativePath,
            content: content,
            isDeleted: false,
            attempts: 1
        )
    }

    private func remoteSnapshot(
        documentID: UUID,
        path: String,
        content: String
    ) -> SyncV2RemoteDocumentSnapshot {
        SyncV2RemoteDocumentSnapshot(
            documentID: documentID,
            relativePath: path,
            content: content,
            revision: 4,
            isDeleted: false,
            deletedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 400)
        )
    }

    private func dispatchOperation(
        documentID: UUID,
        sequence: Int,
        suffix: Int,
        localProjectID: ProjectID? = nil
    ) -> SyncV2DispatchOperation {
        let projectID = localProjectID?.rawValue ?? UUID()
        return SyncV2DispatchOperation(
            operationID: UUID(),
            batchID: UUID(),
            localProjectID:
                localProjectID ?? ProjectID(rawValue: projectID),
            projectID: projectID,
            documentID: documentID,
            deviceID: UUID(),
            documentSequence: sequence,
            kind: .documentCommit,
            baseRevision: 0,
            relativePath: "원고/1권/\(suffix).txt",
            content: "본문 \(suffix)",
            isDeleted: false,
            attempts: 0
        )
    }
}

private actor AutomaticRebaseSnapshotClientStub:
    SyncV2SnapshotClienting {
    private let snapshot: SyncV2RemoteDocumentSnapshot?

    init(snapshot: SyncV2RemoteDocumentSnapshot?) {
        self.snapshot = snapshot
    }

    func fetchDocuments(
        projectID: UUID
    ) -> [SyncV2RemoteDocumentSnapshot] {
        _ = projectID
        return snapshot.map { [$0] } ?? []
    }

    func fetchDocument(
        projectID: UUID,
        documentID: UUID
    ) -> SyncV2RemoteDocumentSnapshot? {
        _ = projectID
        guard snapshot?.documentID == documentID else { return nil }
        return snapshot
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

private actor AutomaticRebaseStoreStub: SyncV2DispatchStoring {
    func stalledFolderChanges(
        localProjectID: ProjectID
    ) async throws -> [SyncV2StalledFolderChange] {
        _ = localProjectID
        return []
    }

    struct Recorded: Equatable {
        let remote: SyncV2RemoteDocumentSnapshot
        let local: SyncV2RebaseLocalSnapshot
        let mergedContent: String
        let mergedPath: String
    }

    struct RecordedConflict: Equatable {
        let operation: SyncV2DispatchOperation
        let remote: SyncV2RemoteDocumentSnapshot
        let local: SyncV2RebaseLocalSnapshot
        let mergedContent: String
        let conflictCount: Int
    }

    private let local: SyncV2RebaseLocalSnapshot
    private let result: SyncV2AutomaticRebaseStoreResult
    private var recorded: Recorded?
    private var preservedConflict: RecordedConflict?

    init(
        local: SyncV2RebaseLocalSnapshot,
        result: SyncV2AutomaticRebaseStoreResult = .rebased
    ) {
        self.local = local
        self.result = result
    }

    func recoverInterruptedWork() {}

    func readyLocalProjectIDs(now: Date) -> [ProjectID] {
        _ = now
        return []
    }

    func claimReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) -> [SyncV2DispatchOperation] {
        _ = (localProjectID, limit, now)
        return []
    }

    func complete(
        _ operation: SyncV2DispatchOperation,
        result: SyncV2CommitDocumentResult
    ) {
        _ = (operation, result)
    }

    func deferRetry(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) {
        _ = (operation, errorCode, detail, nextAttemptAt)
    }

    func markConflict(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) {
        _ = (operation, errorCode, detail)
    }

    func preserveConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        conflictCount: Int,
        errorCode: String,
        detail: String?
    ) -> SyncV2ConflictPreservationResult {
        _ = (errorCode, detail)
        preservedConflict = RecordedConflict(
            operation: operation,
            remote: remote,
            local: local,
            mergedContent: mergedContent,
            conflictCount: conflictCount
        )
        return .preserved
    }

    func markBlocked(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) {
        _ = (operation, errorCode, detail)
    }

    func latestLocalSnapshot(
        for operation: SyncV2DispatchOperation
    ) -> SyncV2RebaseLocalSnapshot {
        _ = operation
        return local
    }

    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) -> SyncV2AutomaticRebaseStoreResult {
        _ = operation
        recorded = Recorded(
            remote: remote,
            local: local,
            mergedContent: mergedContent,
            mergedPath: mergedPath
        )
        return result
    }

    func makeRetryWaitOperationsReady(localProjectID: ProjectID?) {
        _ = localProjectID
    }
    func nextRetryDate(localProjectID: ProjectID?) -> Date? {
        _ = localProjectID
        return nil
    }
    func recordedRebase() -> Recorded? { recorded }
    func recordedConflict() -> RecordedConflict? { preservedConflict }

    // 이 대역은 문서 줄만 흉내 낸다. 폴더 작업은 claim하지 않으므로 아래 넷은
    // 불릴 일이 없다. 조용히 성공한 척하지 않고 막는다.
    func claimReadyFolderOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2FolderDispatchOperation] {
        _ = (localProjectID, limit, now)
        return []
    }

    func complete(
        _ operation: SyncV2FolderDispatchOperation,
        result: SyncV2CommitFolderResult
    ) async throws {
        _ = (operation, result)
        throw SyncV2DispatchStoreError.unavailable
    }

    func deferRetry(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws {
        _ = (operation, errorCode, detail, nextAttemptAt)
        throw SyncV2DispatchStoreError.unavailable
    }

    func markConflict(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        _ = (operation, errorCode, detail)
        throw SyncV2DispatchStoreError.unavailable
    }

    func markBlocked(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        _ = (operation, errorCode, detail)
        throw SyncV2DispatchStoreError.unavailable
    }
}

private actor AutomaticRebaseLocalApplierSpy:
    SyncV2LocalSnapshotApplying {
    private let fileURL: URL?
    private var count = 0

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func apply(
        localProjectID: ProjectID,
        snapshot: SyncV2RemoteDocumentSnapshot
    ) throws {
        _ = localProjectID
        count += 1
        if let fileURL {
            try Data(snapshot.content.utf8).write(
                to: fileURL,
                options: [.atomic]
            )
        }
    }

    func applyCount() -> Int { count }
}

private actor AutomaticRebaseOpenProviderStub:
    SyncV2OpenLocalSnapshotProviding {
    private let snapshot: SyncV2RebaseLocalSnapshot
    private let remainsCurrent: Bool

    init(
        snapshot: SyncV2RebaseLocalSnapshot,
        remainsCurrent: Bool
    ) {
        self.snapshot = snapshot
        self.remainsCurrent = remainsCurrent
    }

    func latestOpenSnapshot(
        documentID: UUID
    ) -> SyncV2RebaseLocalSnapshot? {
        _ = documentID
        return snapshot
    }

    func isCurrent(
        documentID: UUID,
        snapshot: SyncV2RebaseLocalSnapshot
    ) -> Bool {
        _ = (documentID, snapshot)
        return remainsCurrent
    }

    func applyMergedIfCurrent(
        documentID: UUID,
        expected: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) -> Bool {
        _ = (documentID, expected, mergedContent, mergedPath)
        return remainsCurrent
    }
}

private actor DispatcherStoreStub: SyncV2DispatchStoring {
    func stalledFolderChanges(
        localProjectID: ProjectID
    ) async throws -> [SyncV2StalledFolderChange] {
        _ = localProjectID
        return []
    }

    enum Status {
        case pending
        case inflight
        case retryWait
        case conflict
        case blocked
        case completed
    }

    struct RetryRecord {
        let errorCode: String
        let nextAttemptAt: Date
    }

    struct RebaseRecord: Equatable {
        let remoteRevision: Int64
        let mergedContent: String
        let mergedPath: String
    }

    private var operations: [UUID: SyncV2DispatchOperation]
    private var order: [UUID]
    private var statuses: [UUID: Status]
    private var retries: [UUID: RetryRecord] = [:]
    private var rebases: [UUID: RebaseRecord] = [:]
    private var opportunities = 0
    private var missingRecoveries = 0
    private var missingProjectRecoveries = 0

    init(
        operations: [SyncV2DispatchOperation],
        initialStatus: Status = .pending
    ) {
        self.operations = Dictionary(
            uniqueKeysWithValues: operations.map { ($0.operationID, $0) }
        )
        self.order = operations.map(\.operationID)
        self.statuses = Dictionary(
            uniqueKeysWithValues: operations.map {
                ($0.operationID, initialStatus)
            }
        )
    }

    func recoverInterruptedWork() {}

    func readyLocalProjectIDs(now: Date) -> [ProjectID] {
        _ = now
        var projectIDs: [ProjectID] = []
        for identifier in order {
            guard statuses[identifier] == .pending,
                  let operation = operations[identifier] else {
                continue
            }
            let projectID = operation.localProjectID
                ?? ProjectID(rawValue: operation.projectID)
            if !projectIDs.contains(projectID) {
                projectIDs.append(projectID)
            }
        }
        return projectIDs
    }

    func claimReadyOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) -> [SyncV2DispatchOperation] {
        var claimed: [SyncV2DispatchOperation] = []
        for identifier in order {
            guard claimed.count < limit,
                  statuses[identifier] == .pending,
                  let stored = operations[identifier],
                  (
                      stored.localProjectID
                          ?? ProjectID(rawValue: stored.projectID)
                  ) == localProjectID
            else { continue }
            let hasEarlierActive = operations.values.contains {
                $0.documentID == stored.documentID
                    && $0.documentSequence < stored.documentSequence
                    && statuses[$0.operationID] != .completed
            }
            guard !hasEarlierActive else { continue }
            let operation = SyncV2DispatchOperation(
                operationID: stored.operationID,
                batchID: stored.batchID,
                localProjectID: stored.localProjectID,
                projectID: stored.projectID,
                documentID: stored.documentID,
                deviceID: stored.deviceID,
                documentSequence: stored.documentSequence,
                localSaveGeneration: stored.localSaveGeneration,
                kind: stored.kind,
                baseRevision: stored.baseRevision,
                baseContent: stored.baseContent,
                baseServerPath: stored.baseServerPath,
                localPath: stored.localPath,
                relativePath: stored.relativePath,
                content: stored.content,
                isDeleted: stored.isDeleted,
                attempts: stored.attempts + 1
            )
            operations[identifier] = operation
            statuses[identifier] = .inflight
            claimed.append(operation)
        }
        return claimed
    }

    func complete(
        _ operation: SyncV2DispatchOperation,
        result: SyncV2CommitDocumentResult
    ) {
        _ = result
        statuses[operation.operationID] = .completed
    }

    func deferRetry(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) {
        _ = detail
        statuses[operation.operationID] = .retryWait
        retries[operation.operationID] = RetryRecord(
            errorCode: errorCode,
            nextAttemptAt: nextAttemptAt
        )
    }

    func markConflict(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) {
        _ = (errorCode, detail)
        statuses[operation.operationID] = .conflict
    }

    func preserveConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        conflictCount: Int,
        errorCode: String,
        detail: String?
    ) -> SyncV2ConflictPreservationResult {
        _ = (
            remote,
            local,
            mergedContent,
            conflictCount,
            errorCode,
            detail
        )
        statuses[operation.operationID] = .conflict
        return .preserved
    }

    func markBlocked(
        _ operation: SyncV2DispatchOperation,
        errorCode: String,
        detail: String?
    ) {
        _ = (errorCode, detail)
        statuses[operation.operationID] = .blocked
    }

    func recoverMissingRemoteDocument(
        _ operation: SyncV2DispatchOperation
    ) {
        guard statuses[operation.operationID] == .inflight else {
            return
        }
        operations[operation.operationID] = SyncV2DispatchOperation(
            operationID: operation.operationID,
            batchID: operation.batchID,
            localProjectID: operation.localProjectID,
            projectID: operation.projectID,
            documentID: operation.documentID,
            deviceID: operation.deviceID,
            documentSequence: operation.documentSequence,
            localSaveGeneration: operation.localSaveGeneration,
            kind: operation.kind,
            baseRevision: 0,
            baseContent: "",
            baseServerPath: operation.relativePath,
            localPath: operation.localPath,
            relativePath: operation.relativePath,
            content: operation.content,
            isDeleted: operation.isDeleted,
            attempts: 0
        )
        statuses[operation.operationID] = .pending
        missingRecoveries += 1
    }

    func recoverMissingRemoteProject(
        _ operation: SyncV2DispatchOperation
    ) {
        _ = operation
        missingProjectRecoveries += 1
    }

    func projectName(
        for operation: SyncV2DispatchOperation
    ) -> String {
        _ = operation
        return "복구 작품"
    }

    func makeRetryWaitOperationsReady(localProjectID: ProjectID?) {
        opportunities += 1
        for identifier in order where statuses[identifier] == .retryWait {
            if let localProjectID,
               let operation = operations[identifier],
               effectiveLocalProjectID(operation) != localProjectID {
                continue
            }
            statuses[identifier] = .pending
            retries[identifier] = nil
        }
    }

    func nextRetryDate(localProjectID: ProjectID?) -> Date? {
        retries.compactMap { operationID, record in
            if let localProjectID,
               let operation = operations[operationID],
               effectiveLocalProjectID(operation) != localProjectID {
                return nil
            }
            return record.nextAttemptAt
        }.min()
    }

    private func effectiveLocalProjectID(
        _ operation: SyncV2DispatchOperation
    ) -> ProjectID {
        operation.localProjectID
            ?? ProjectID(rawValue: operation.projectID)
    }

    func completedOperationIDs() -> Set<UUID> {
        Set(statuses.compactMap { key, status in
            status == .completed ? key : nil
        })
    }

    func conflictOperationIDs() -> Set<UUID> {
        Set(statuses.compactMap { key, status in
            status == .conflict ? key : nil
        })
    }

    func immediateOpportunityCount() -> Int {
        opportunities
    }

    func missingProjectRecoveryCount() -> Int {
        missingProjectRecoveries
    }

    func resetToRetryWait(operation: SyncV2DispatchOperation) {
        statuses[operation.operationID] = .retryWait
    }

    func enqueue(_ operation: SyncV2DispatchOperation) {
        operations[operation.operationID] = operation
        order.append(operation.operationID)
        statuses[operation.operationID] = .pending
    }

    func retryRecord(operationID: UUID) -> RetryRecord? {
        retries[operationID]
    }

    func rebaseRecord(operationID: UUID) -> RebaseRecord? {
        rebases[operationID]
    }

    /// 실제 저장소처럼 기준선을 서버 최신 revision으로 올린 뒤 다시 대기열에
    /// 넣는다. 기준선을 올리지 않으면 재시도가 계속 create로 나가 같은 거절이
    /// 무한 반복된다.
    func rebaseAfterRevisionConflict(
        _ operation: SyncV2DispatchOperation,
        remote: SyncV2RemoteDocumentSnapshot,
        local: SyncV2RebaseLocalSnapshot,
        mergedContent: String,
        mergedPath: String
    ) -> SyncV2AutomaticRebaseStoreResult {
        _ = local
        rebases[operation.operationID] = RebaseRecord(
            remoteRevision: remote.revision,
            mergedContent: mergedContent,
            mergedPath: mergedPath
        )
        operations[operation.operationID] = SyncV2DispatchOperation(
            operationID: operation.operationID,
            batchID: operation.batchID,
            localProjectID: operation.localProjectID,
            projectID: operation.projectID,
            documentID: operation.documentID,
            deviceID: operation.deviceID,
            documentSequence: operation.documentSequence,
            localSaveGeneration: operation.localSaveGeneration,
            kind: operation.kind,
            baseRevision: remote.revision,
            baseContent: remote.content,
            baseServerPath: remote.relativePath,
            localPath: operation.localPath,
            relativePath: mergedPath,
            content: mergedContent,
            isDeleted: operation.isDeleted,
            attempts: 0
        )
        statuses[operation.operationID] = .pending
        return .rebased
    }

    // 이 대역은 문서 줄만 흉내 낸다. 폴더 작업은 claim하지 않으므로 아래
    // 넷은 불릴 일이 없다. 조용히 성공한 척하지 않고 막는다.
    func claimReadyFolderOperations(
        localProjectID: ProjectID,
        limit: Int,
        now: Date
    ) async throws -> [SyncV2FolderDispatchOperation] {
        _ = (localProjectID, limit, now)
        return []
    }

    func complete(
        _ operation: SyncV2FolderDispatchOperation,
        result: SyncV2CommitFolderResult
    ) async throws {
        _ = (operation, result)
        throw SyncV2DispatchStoreError.unavailable
    }

    func deferRetry(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?,
        nextAttemptAt: Date
    ) async throws {
        _ = (operation, errorCode, detail, nextAttemptAt)
        throw SyncV2DispatchStoreError.unavailable
    }

    func markConflict(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        _ = (operation, errorCode, detail)
        throw SyncV2DispatchStoreError.unavailable
    }

    func markBlocked(
        _ operation: SyncV2FolderDispatchOperation,
        errorCode: String,
        detail: String?
    ) async throws {
        _ = (operation, errorCode, detail)
        throw SyncV2DispatchStoreError.unavailable
    }

    func missingRecoveryCount() -> Int {
        missingRecoveries
    }
}

private actor DispatcherClientStub: SyncV2CommitClienting {
    private let conflictOperationIDs: Set<UUID>
    private let alreadyExistsOperationIDs: Set<UUID>
    private let retryOperationIDs: Set<UUID>
    private let missingOperationIDs: Set<UUID>
    private let forbiddenOperationIDs: Set<UUID>
    private let delayNanoseconds: UInt64
    private let delayNanosecondsByOperation: [UUID: UInt64]
    private var activeCalls = 0
    private var maximumCalls = 0
    private var requests: [SyncV2CommitDocumentParameters] = []
    private var forbiddenAttempts: Set<UUID> = []

    init(
        conflictOperationIDs: Set<UUID> = [],
        alreadyExistsOperationIDs: Set<UUID> = [],
        retryOperationIDs: Set<UUID> = [],
        missingOperationIDs: Set<UUID> = [],
        forbiddenCreateOperationIDs: Set<UUID> = [],
        delayNanoseconds: UInt64 = 0,
        delayNanosecondsByOperation: [UUID: UInt64] = [:]
    ) {
        self.conflictOperationIDs = conflictOperationIDs
        self.alreadyExistsOperationIDs = alreadyExistsOperationIDs
        self.retryOperationIDs = retryOperationIDs
        self.missingOperationIDs = missingOperationIDs
        self.forbiddenOperationIDs =
            forbiddenCreateOperationIDs
        self.delayNanoseconds = delayNanoseconds
        self.delayNanosecondsByOperation =
            delayNanosecondsByOperation
    }

    func commitDocument(
        _ parameters: SyncV2CommitDocumentParameters
    ) async throws -> SyncV2CommitDocumentResult {
        requests.append(parameters)
        activeCalls += 1
        maximumCalls = max(maximumCalls, activeCalls)
        let operationDelay =
            delayNanosecondsByOperation[parameters.operationID]
            ?? delayNanoseconds
        if operationDelay > 0 {
            try? await Task.sleep(nanoseconds: operationDelay)
        }
        activeCalls -= 1
        if conflictOperationIDs.contains(parameters.operationID) {
            throw SyncV2ClientError.remote(
                code: .revisionConflict,
                detail: "fixture"
            )
        }
        // 서버는 base revision 0(= 새로 만들기)일 때 같은 document UUID가
        // 이미 있으면 DOCUMENT_ALREADY_EXISTS를 던진다. rebase로 기준선이
        // 올라간 뒤의 재시도는 update가 되므로 그대로 성공한다.
        if alreadyExistsOperationIDs.contains(parameters.operationID),
           parameters.baseServerRevision == 0 {
            throw SyncV2ClientError.remote(
                code: .documentAlreadyExists,
                detail: nil
            )
        }
        if missingOperationIDs.contains(parameters.operationID),
           parameters.baseServerRevision > 0 {
            throw SyncV2ClientError.remote(
                code: .documentNotFound,
                detail: nil
            )
        }
        if forbiddenOperationIDs.contains(
            parameters.operationID
        ),
           forbiddenAttempts.insert(
               parameters.operationID
           ).inserted {
            throw SyncV2ClientError.remote(
                code: .forbidden,
                detail: nil
            )
        }
        if retryOperationIDs.contains(parameters.operationID) {
            throw SyncV2ClientError.networkUnavailable
        }
        return SyncV2CommitDocumentResult(
            status: .committed,
            documentID: parameters.documentID,
            versionID: UUID(),
            operationID: parameters.operationID,
            operationKind: parameters.baseServerRevision == 0
                ? .create
                : .update,
            serverRevision: parameters.baseServerRevision + 1,
            relativePath: parameters.relativePath,
            isDeleted: parameters.isDeleted,
            contentHash: SHA256ContentHasher()
                .sha256(for: Data(parameters.content.utf8))
                .rawValue,
            committedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }

    func maximumActiveCalls() -> Int {
        maximumCalls
    }

    func receivedRequests() -> [SyncV2CommitDocumentParameters] {
        requests
    }

    func commitFolder(
        _ parameters: SyncV2CommitFolderParameters
    ) async throws -> SyncV2CommitFolderResult {
        _ = parameters
        throw SyncV2ClientError.remote(
            code: .invalidArgument,
            detail: "This stub only serves documents."
        )
    }
}

private actor ProjectRecoveryTransportStub:
    EnsureProjectTransporting {
    private var parameters: [EnsureProjectParameters] = []

    func ensureProject(
        parameters: EnsureProjectParameters
    ) -> EnsuredServerProject {
        self.parameters.append(parameters)
        return EnsuredServerProject(
            projectID: parameters.projectID,
            name: parameters.name
        )
    }

    func receivedParameters() -> [EnsureProjectParameters] {
        parameters
    }
}

private struct FixedRevisionProvider: SyncV2DocumentRevisionProviding {
    let revision: Int64?

    func serverRevision(for documentID: UUID) -> Int64? {
        _ = documentID
        return revision
    }
}

private struct FixedDeviceIdentityProvider: DeviceIdentityProviding {
    let identifier: DeviceIdentifier

    func currentState() async -> DeviceIdentityState {
        .ready(identifier)
    }

    func currentIdentifier() async throws -> DeviceIdentifier {
        identifier
    }

    func prepareIdentity() async {}
}

private actor ControlledAcquireLeaseClient: EditLeaseClienting {
    private var acquisitions = 0
    private var releases = 0
    private var acquireContinuations: [
        Int: CheckedContinuation<EditLeaseMutationResult, Never>
    ] = [:]
    private var countWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var requests: [Int: (documentID: UUID, deviceID: UUID)] = [:]

    func acquire(
        documentID: UUID,
        deviceID: UUID,
        ttlSeconds: Int
    ) async throws -> EditLeaseMutationResult {
        _ = ttlSeconds
        acquisitions += 1
        let index = acquisitions
        requests[index] = (documentID, deviceID)
        let ready = countWaiters.filter { acquisitions >= $0.count }
        countWaiters.removeAll { acquisitions >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return await withCheckedContinuation { continuation in
            acquireContinuations[index] = continuation
        }
    }

    func renew(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID,
        ttlSeconds: Int
    ) -> EditLeaseMutationResult {
        _ = (leaseToken, ttlSeconds)
        return result(documentID: documentID, deviceID: deviceID, index: 99)
    }

    func release(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID
    ) -> Bool {
        _ = (documentID, deviceID, leaseToken)
        releases += 1
        return true
    }

    func inspect(
        documentID: UUID,
        deviceID: UUID
    ) -> EditLeaseInspectionResult {
        EditLeaseInspectionResult(
            documentID: documentID,
            state: .available,
            expiresAt: nil
        )
    }

    func waitForAcquireCount(_ count: Int) async {
        guard acquisitions < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func completeAcquire(_ index: Int) {
        guard let request = requests[index] else { return }
        acquireContinuations.removeValue(forKey: index)?.resume(
            returning: result(
                documentID: request.documentID,
                deviceID: request.deviceID,
                index: index
            )
        )
    }

    func releaseCount() -> Int { releases }

    private func result(
        documentID: UUID,
        deviceID: UUID,
        index: Int
    ) -> EditLeaseMutationResult {
        EditLeaseMutationResult(
            documentID: documentID,
            leaseToken: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    index
                )
            )!,
            deviceID: deviceID,
            expiresAt: Date().addingTimeInterval(90)
        )
    }
}

private actor EditLeaseClientStub: EditLeaseClienting {
    private let token = UUID()
    private var acquireError: SyncV2ClientError?
    private var acquisitions = 0
    private var releases = 0
    private var renewals = 0
    private var renewalWaiters: [CheckedContinuation<Void, Never>] = []
    private var renewalErrors: [SyncV2ClientError]
    private let releaseGate: LeaseReleaseGate?

    init(
        acquireError: SyncV2ClientError? = nil,
        renewalErrors: [SyncV2ClientError] = [],
        releaseGate: LeaseReleaseGate? = nil
    ) {
        self.acquireError = acquireError
        self.renewalErrors = renewalErrors
        self.releaseGate = releaseGate
    }

    func acquire(
        documentID: UUID,
        deviceID: UUID,
        ttlSeconds: Int
    ) throws -> EditLeaseMutationResult {
        _ = ttlSeconds
        acquisitions += 1
        if let acquireError {
            throw acquireError
        }
        return result(documentID: documentID, deviceID: deviceID)
    }

    func renew(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID,
        ttlSeconds: Int
    ) throws -> EditLeaseMutationResult {
        _ = (leaseToken, ttlSeconds)
        renewals += 1
        let waiters = renewalWaiters
        renewalWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !renewalErrors.isEmpty {
            throw renewalErrors.removeFirst()
        }
        return result(documentID: documentID, deviceID: deviceID)
    }

    func release(
        documentID: UUID,
        deviceID: UUID,
        leaseToken: UUID
    ) async -> Bool {
        _ = (documentID, deviceID, leaseToken)
        releases += 1
        await releaseGate?.wait()
        return true
    }

    func inspect(
        documentID: UUID,
        deviceID: UUID
    ) -> EditLeaseInspectionResult {
        _ = deviceID
        return EditLeaseInspectionResult(
            documentID: documentID,
            state: .heldByMe,
            expiresAt: Date().addingTimeInterval(90)
        )
    }

    func acquireCount() -> Int {
        acquisitions
    }

    func releaseCount() -> Int {
        releases
    }

    func renewCount() -> Int {
        renewals
    }

    func waitForRenewal() async {
        guard renewals == 0 else { return }
        await withCheckedContinuation { continuation in
            renewalWaiters.append(continuation)
        }
    }

    func setAcquireError(_ error: SyncV2ClientError?) {
        acquireError = error
    }

    private func result(
        documentID: UUID,
        deviceID: UUID
    ) -> EditLeaseMutationResult {
        EditLeaseMutationResult(
            documentID: documentID,
            leaseToken: token,
            deviceID: deviceID,
            expiresAt: Date().addingTimeInterval(90)
        )
    }
}

private actor LeaseReleaseGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor BlockingLeaseCleanupManager: EditLeaseManaging {
    private var cleanupStarted = false
    private var cleanupCanFinish = false
    private var cleanupStartWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var cleanupFinishWaiters:
        [CheckedContinuation<Void, Never>] = []

    func stateUpdates(
        documentID: UUID
    ) -> AsyncStream<EditLeaseDisplayState> {
        _ = documentID
        return AsyncStream { _ in }
    }

    func beginEditing(documentID: UUID) -> EditLeaseDisplayState {
        _ = documentID
        return .heldByOther(expiresAt: nil)
    }

    func refreshEditing(documentID: UUID) -> EditLeaseDisplayState {
        _ = documentID
        return .heldByOther(expiresAt: nil)
    }

    func offlineDisplayState(
        documentID: UUID
    ) -> EditLeaseDisplayState {
        _ = documentID
        return .offlineEditing
    }

    func endEditing(documentID: UUID) async {
        _ = documentID
        cleanupStarted = true
        let startWaiters = cleanupStartWaiters
        cleanupStartWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !cleanupCanFinish else { return }
        await withCheckedContinuation { continuation in
            cleanupFinishWaiters.append(continuation)
        }
    }

    func leaseTokenForCommit(
        documentID: UUID,
        deviceID: UUID,
        baseRevision: Int64
    ) throws -> UUID? {
        _ = (documentID, deviceID, baseRevision)
        return nil
    }

    func commitSucceeded(
        documentID: UUID,
        deviceID: UUID,
        isDeleted: Bool
    ) {
        _ = (documentID, deviceID, isDeleted)
    }

    func commitFailed(
        documentID: UUID,
        deviceID: UUID,
        error: SyncV2ClientError
    ) {
        _ = (documentID, deviceID, error)
    }

    func releaseAll() {}

    func waitUntilCleanupStarts() async {
        guard !cleanupStarted else { return }
        await withCheckedContinuation { continuation in
            cleanupStartWaiters.append(continuation)
        }
    }

    func finishCleanup() {
        cleanupCanFinish = true
        let finishWaiters = cleanupFinishWaiters
        cleanupFinishWaiters.removeAll()
        finishWaiters.forEach { $0.resume() }
    }
}

private actor AsyncCompletionProbe {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private actor NetworkRecoveryProbe {
    private var starts = 0
    private var completions = 0
    private var finishWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var canFinish = false

    func run() async {
        starts += 1
        if !canFinish {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
            }
        }
        completions += 1
    }

    func finish() {
        canFinish = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func startedCount() -> Int {
        starts
    }

    func completedCount() -> Int {
        completions
    }
}

private actor OneShotLeaseSleeper {
    private var calls = 0
    private var sleepContinuation:
        CheckedContinuation<Void, any Error>?
    private var waitingContinuations:
        [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        _ = duration
        calls += 1
        if calls > 1 {
            throw CancellationError()
        }
        let waiters = waitingContinuations
        waitingContinuations.removeAll()
        waiters.forEach { $0.resume() }
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuation = continuation
        }
    }

    func waitUntilSleeping() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func wake() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }
}

private actor ManualLeaseSleeper {
    private var durations: [Duration] = []
    private var sleepContinuations:
        [CheckedContinuation<Void, any Error>] = []
    private var callCountWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        let ready = callCountWaiters.filter { durations.count >= $0.count }
        callCountWaiters.removeAll { durations.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
        try await withCheckedThrowingContinuation { continuation in
            sleepContinuations.append(continuation)
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func wakeNext() {
        guard !sleepContinuations.isEmpty else { return }
        sleepContinuations.removeFirst().resume()
    }

    func recordedDurations() -> [Duration] {
        durations
    }
}

private actor MutableAuthenticationStateProvider {
    private var state: AuthenticationState

    init(state: AuthenticationState) {
        self.state = state
    }

    func current() -> AuthenticationState {
        state
    }

    func set(_ state: AuthenticationState) {
        self.state = state
    }
}

private final class EditLeaseConnectivityMonitorStub:
    EditLeaseConnectivityMonitoring,
    @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    func start(
        handler: @escaping @Sendable (_ isConnected: Bool) -> Void
    ) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func send(isConnected: Bool) {
        lock.lock()
        let callback = handler
        lock.unlock()
        callback?(isConnected)
    }

    func isStarted() -> Bool {
        lock.lock()
        let started = handler != nil
        lock.unlock()
        return started
    }
}
