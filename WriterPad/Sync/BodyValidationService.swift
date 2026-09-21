import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// One foreground body-only validation. Uses the ordinary snapshot applier,
/// compared local save, durable operation journal, and upload/pull coordinator.
/// Failure intentionally leaves its journal pending/inflight for offline review.
actor BodyValidationService {
    enum Failure: Error { case baselineChanged, busy, incompleteSave, unsupportedMode, unavailable }
    private let store: LazySyncV2ProjectBindingStore
    private let documents: any DocumentRepository
    private let local: any LocalDocumentStoring
    private let puller: any SyncV2SnapshotPulling
    private let snapshot: any SyncV2SnapshotClienting
    private let commit: any SyncV2CommitClienting
    private let lease: any EditLeaseClienting
    private let handshake: any SyncV2HandshakeTransporting
    private let auth: any AuthenticationServicing
    private let identity: any DeviceIdentityProviding
    private let coordinator: SyncV2ProjectUploadPullCoordinator
    private let bindingEpoch: SyncV2ContractEpoch
    private var running = false
    private var received = false

    init(store: LazySyncV2ProjectBindingStore, documents: any DocumentRepository,
         local: any LocalDocumentStoring, puller: any SyncV2SnapshotPulling,
         snapshot: any SyncV2SnapshotClienting, commit: any SyncV2CommitClienting,
         lease: any EditLeaseClienting, handshake: any SyncV2HandshakeTransporting,
         auth: any AuthenticationServicing, identity: any DeviceIdentityProviding,
         coordinator: SyncV2ProjectUploadPullCoordinator, bindingEpoch: SyncV2ContractEpoch) {
        self.store = store; self.documents = documents; self.local = local; self.puller = puller
        self.snapshot = snapshot; self.commit = commit; self.lease = lease; self.handshake = handshake
        self.auth = auth; self.identity = identity; self.coordinator = coordinator; self.bindingEpoch = bindingEpoch
    }

    func run(send: Bool, foreground: Bool) async throws {
        guard !running else { throw Failure.busy }
        running = true
        defer { running = false }
        guard !send || received else { throw Failure.baselineChanged }
        let policy = ReceiveValidationPolicy.current
        let ticket = try policy.authorization()
        guard case let .authenticated(account) = await auth.currentState(),
              let binding = try await store.binding(for: BodyValidationPlan.local),
              binding.ownerSubject == account.userID,
              try await store.receivingQueueIsEmpty(BodyValidationPlan.local) else { throw Failure.baselineChanged }
        try policy.verifyAccount(account.userID, ticket: ticket)
        let device = try await identity.currentIdentifier().uuid
        guard let authEpoch = auth.contractEpoch else { throw Failure.unavailable }
        let authVersion = authEpoch.value, bindingVersion = bindingEpoch.value
        let bindingEpoch = self.bindingEpoch
        try await policy.withBodyValidation(binding: binding, device: device, foreground: foreground,
            epochIsCurrent: { authEpoch.isAvailable && authEpoch.value == authVersion
                && bindingEpoch.isAvailable && bindingEpoch.value == bindingVersion }) {
                try await self.perform(send: send, device: device)
            }
        received = !send
    }

    private func perform(send: Bool, device: UUID) async throws {
        let policy = ReceiveValidationPolicy.current
        // Never infer a lane from null folder metadata. Ask the existing read-only RPC.
        let answer = try await handshake.fetchHandshake(parameters: .init(
            projectID: BodyValidationPlan.project, contractSHA256: SyncV2Contract.canonicalSHA256))
        try policy.requireBody()
        guard answer.projectID == BodyValidationPlan.project, answer.projectSyncMode == .legacy else {
            throw Failure.unsupportedMode
        }
        let remote = try await snapshot.fetchDocument(projectID: BodyValidationPlan.project,
                                                       documentID: BodyValidationPlan.document)
        guard let remote, remote.revision == 2, BodyValidationPlan.matches(remote.content, BodyValidationPlan.incoming),
              remote.relativePath == BodyValidationPlan.path, !remote.isDeleted,
              remote.parentFolderID == nil, remote.name == nil, remote.structureRevision == nil else {
            throw Failure.baselineChanged
        }
        try policy.requireBody()
        guard let node = try await documents.document(id: DocumentID(rawValue: BodyValidationPlan.document)),
              node.projectID == BodyValidationPlan.local, node.kind == .text,
              node.deletionStatus == .active, node.relativePath.rawValue == BodyValidationPlan.path else {
            throw Failure.baselineChanged
        }
        let before = try await local.loadText(for: node)
        let state = try await store.snapshotState(localProjectID: BodyValidationPlan.local,
            serverProjectID: BodyValidationPlan.project, documentID: BodyValidationPlan.document)
        guard let state, !state.hasActiveOperation, !state.hasUnresolvedConflict,
              (state.serverRevision == 1 && BodyValidationPlan.matches(before, BodyValidationPlan.baseline) && !send)
                || (state.serverRevision == 2 && BodyValidationPlan.matches(before, BodyValidationPlan.incoming)) else {
            throw Failure.baselineChanged
        }
        if !send {
            let queue = try await store.uploadQueueSnapshot(localProjectID: BodyValidationPlan.local)
            guard queue == .idle, let permit = await coordinator.observeServerChange(
                localProjectID: BodyValidationPlan.local, queue: queue, bootstrapAllowed: false) else { throw Failure.busy }
            do {
                let report = try await puller.pull(localProjectID: BodyValidationPlan.local,
                    serverProjectID: BodyValidationPlan.project, editingGuards: [:])
                try policy.requireBody()
                guard report.contractStructureBaselineReady, !report.hasDeferredLocalApplication,
                      report.rejectedStructureNames.isEmpty, report.pendingChildTombstoneFolderCount == 0,
                      !report.outcomes.contains(where: { if case .mergeRequired = $0 { true } else { false } }),
                      BodyValidationPlan.matches(try await local.loadText(for: node), BodyValidationPlan.incoming),
                      try await store.snapshotState(localProjectID: BodyValidationPlan.local,
                        serverProjectID: BodyValidationPlan.project, documentID: BodyValidationPlan.document)?.serverRevision == 2
                else { throw Failure.baselineChanged }
                _ = await coordinator.finishPull(permit, succeeded: true, queue: .idle)
            } catch {
                _ = await coordinator.finishPull(permit, succeeded: false,
                    queue: (try? await store.uploadQueueSnapshot(localProjectID: BodyValidationPlan.local)) ?? .init(retryWaitingCount: 1))
                throw error
            }
            return
        }
        try policy.bodyPhase(.save)
        let receipt = try await local.saveCompared(.init(projectID: BodyValidationPlan.local,
            documentID: node.id, relativePath: node.relativePath, text: BodyValidationPlan.outgoing,
            generation: UInt64(Date().timeIntervalSince1970 * 1_000_000),
            expectedCurrentContentHash: SHA256ContentHasher().sha256(for: Data(BodyValidationPlan.incoming.utf8))),
            authorize: { try policy.requireBody() })
        guard case let .queued(ids) = receipt.durableRecordResult, ids.count == 1 else { throw Failure.incompleteSave }
        try policy.bodyPhase(.send)
        let queue = try await store.uploadQueueSnapshot(localProjectID: BodyValidationPlan.local)
        guard let permit = await coordinator.beginUploadDrain(localProjectID: BodyValidationPlan.local, queue: queue) else {
            throw Failure.busy
        }
        do {
            let operation = try await store.claimBodyValidation()
            try policy.requireBodyOperation(operation)
            let acquired = try await lease.acquire(documentID: operation.documentID, deviceID: device, ttlSeconds: 60)
            try policy.bodyLease(acquired.leaseToken)
            let result = try await commit.commitDocument(operation.commitParameters(leaseToken: acquired.leaseToken))
            try policy.requireBodyOperation(operation)
            try await store.complete(operation, result: result)
            // A failed release is reported without retry. The server controls expiry;
            // the preserved commit_document definition renews an accepted lease to 90 s.
            guard try await lease.release(documentID: operation.documentID, deviceID: device,
                                          leaseToken: acquired.leaseToken) else { throw Failure.unavailable }
            try policy.requireBody()
            await coordinator.finishUploadDrain(permit,
                queue: try await store.uploadQueueSnapshot(localProjectID: BodyValidationPlan.local))
        } catch {
            await coordinator.finishUploadDrain(permit,
                queue: (try? await store.uploadQueueSnapshot(localProjectID: BodyValidationPlan.local)) ?? .init(retryWaitingCount: 1))
            throw error
        }
    }
}

/// Immutable, fully checked input to the ordinary pull/applier. No live client is
/// retained, so hydration cannot fetch a different server row after validation.
struct BodyValidationSnapshot: SyncV2SnapshotClienting {
    static let control = UUID(uuidString: "ef6e1de1-a3d0-5959-96be-58f87a683cc0")!
    static let controlHash = "1cfe9438a3ff000c3af3b5593f973554b2966e9fd8c29e704e73143fda27b5be"
    static let expectedFolders: [SyncV2RemoteFolder] = [
        .init(folderID: UUID(uuidString: "0e741e1c-8480-47f7-8f4c-e9ce96c21580")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "휴지통", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "1de12e60-f998-48b9-aae9-7675b4b42fb9")!, parentFolderID: UUID(uuidString: "fb50368f-be10-4cef-b297-a25f953202e2")!, name: "1권", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "310d3cbb-9b89-4a4e-b50b-0a073dbbf43c")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "장소", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "39c1c33f-8cc2-456c-be56-ea7cacca43f9")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "흐름정리", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "6051187d-87a7-4947-97f8-85bd876f7901")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "스토리 플롯", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "673e2f6f-598a-4cc9-a97e-7795e5373a07")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "메모장", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "87c9544e-5760-401d-843b-11297e40f738")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "설정집", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "9bc8f266-5b7c-4819-b2cc-39728727f2c1")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "캐릭터", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "c30a1a00-94c1-4a46-baf1-66ac285e2925")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "복선", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
        .init(folderID: UUID(uuidString: "fb50368f-be10-4cef-b297-a25f953202e2")!, parentFolderID: UUID(uuidString: "d33aacee-0b30-4fc9-9178-8d844306ec0f")!, name: "원고", revision: 1, isDeleted: false, updatedAt: Date(timeIntervalSince1970: 0)),
    ]
    private let documents: [SyncV2RemoteDocumentSnapshot]
    private let folders: [SyncV2RemoteFolder]

    static func capture(from client: any SyncV2SnapshotClienting,
                        localProjectID: ProjectID, serverProjectID: UUID) async throws -> Self {
        let policy = ReceiveValidationPolicy.current
        try policy.requireBody(local: localProjectID)
        guard serverProjectID == BodyValidationPlan.project else { throw BodyValidationService.Failure.baselineChanged }
        async let docs = client.fetchDocuments(projectID: serverProjectID)
        async let dirs = client.fetchFolders(projectID: serverProjectID)
        async let orders = client.fetchTreeOrders(projectID: serverProjectID)
        let (documents, folders, treeOrders) = try await (docs, dirs, orders)
        try policy.requireBody(local: localProjectID)
        guard documents.count == 2,
              Set(documents.map(\.documentID)) == [BodyValidationPlan.document, control],
              folders.count == expectedFolders.count,
              Set(folders.map(\.folderID)) == Set(expectedFolders.map(\.folderID)),
              treeOrders.isEmpty else { throw BodyValidationService.Failure.baselineChanged }
        for document in documents {
            guard !document.isDeleted, document.deletedAt == nil,
                  document.parentFolderID == nil, document.name == nil, document.structureRevision == nil else {
                throw BodyValidationService.Failure.baselineChanged
            }
            if document.documentID == BodyValidationPlan.document {
                guard document.revision == 2, BodyValidationPlan.matches(document.relativePath, BodyValidationPlan.path),
                      BodyValidationPlan.matches(document.content, BodyValidationPlan.incoming) else {
                    throw BodyValidationService.Failure.baselineChanged
                }
            } else {
                guard document.revision == 1, document.relativePath == syncV2TreeOrderPath,
                      document.content.utf8.count == 385,
                      SHA256ContentHasher().sha256(for: Data(document.content.utf8)).rawValue == controlHash else {
                    throw BodyValidationService.Failure.baselineChanged
                }
            }
        }
        for expected in expectedFolders {
            guard let folder = folders.first(where: { $0.folderID == expected.folderID }),
                  folder.parentFolderID == expected.parentFolderID,
                  BodyValidationPlan.matches(folder.name, expected.name),
                  folder.revision == 1, !folder.isDeleted else { throw BodyValidationService.Failure.baselineChanged }
        }
        return Self(documents: documents, folders: folders)
    }
    private func check(_ projectID: UUID) throws {
        try ReceiveValidationPolicy.current.requireBody()
        guard projectID == BodyValidationPlan.project else { throw BodyValidationService.Failure.baselineChanged }
    }
    func fetchDocuments(projectID: UUID) async throws -> [SyncV2RemoteDocumentSnapshot] {
        try check(projectID); return documents
    }
    func fetchFolders(projectID: UUID) async throws -> [SyncV2RemoteFolder] {
        try check(projectID); return folders
    }
    func fetchTreeOrders(projectID: UUID) async throws -> [SyncV2RemoteTreeOrder] {
        try check(projectID); return []
    }
}

struct BodyValidationSection: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var phase
    @State private var operation: Task<Void, Never>?
    @State private var busy = false
    @State private var received = false
    @State private var message = "Windows 변경안을 먼저 대조하고 승인된 단계만 실행하세요."
    var body: some View {
        Section("시험 작품 양방향 검증") {
            Text("본문수신검증 20260911")
            Text(BodyValidationPlan.project.uuidString.lowercased()).font(.caption).textSelection(.enabled)
            Text("본문 1개 · Windows 수신 1→2 · iPad 송신 2→3")
            Button("인증 준비") {
                guard !busy else { return }
                busy = true
                operation = Task {
                    do {
                        _ = try ReceiveValidationPolicy.current.beginAuthentication(
                            foreground: UIApplication.shared.applicationState == .active,
                            endpoint: ReceiveValidationPolicy.Configuration.staging)
                        let state = await environment.authenticationService.restoreSession()
                        message = state.isAuthenticated ? "인증 준비 완료. 승인된 단계만 실행하세요." : "계정 항목에서 로그인을 완료하세요."
                    } catch { message = "인증 준비를 중단했습니다." }
                    busy = false
                }
            }.disabled(busy)
            Button("1. Windows 변경 수신") { start(send: false) }.disabled(busy)
            Button("2. 합성 본문 저장·송신 1회") { start(send: true) }.disabled(busy || !received)
            if busy { Button("중단") { cancel() } }
            Text(message).font(.footnote)
        }
        .onDisappear { cancel() }
        .onChange(of: phase) { _, new in if new != .active { cancel() } }
    }
    private func cancel() {
        ReceiveValidationPolicy.current.invalidate(); operation?.cancel(); received = false
    }
    private func start(send: Bool) {
        guard !busy, let service = environment.bodyValidationService else { return }
        busy = true
        operation = Task {
            do {
                try await service.run(send: send, foreground: UIApplication.shared.applicationState == .active)
                if !Task.isCancelled {
                    received = !send
                    message = send ? "iPad 송신 완료. Windows의 revision 3·본문 대조가 남았습니다." : "Windows 본문 revision 2 수신 완료."
                }
            } catch {
                received = false
                message = "검증을 중단했습니다. 저장·송신 여부와 남은 기록을 확인한 뒤 다시 준비하세요."
            }
            busy = false
        }
    }
}
