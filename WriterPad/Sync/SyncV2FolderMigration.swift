import Foundation

/// 이관 표식을 읽고 쓰는 경계다. 저장소 전체를 끌고 오지 않으려고 좁게 자른다.
protocol SyncV2FolderMigrationMarking: Sendable {
    func isFolderMigrationCompleted(
        localProjectID: ProjectID
    ) async throws -> Bool
    func markFolderMigrationCompleted(
        localProjectID: ProjectID
    ) async throws
    func foldersWithPendingOperations(
        localProjectID: ProjectID
    ) async throws -> Set<UUID>
}

/// tree_order로 받은 폴더 변경을 폴더 기록에도 올린다.
///
/// Windows는 아직 `folders` 표를 모르고 `tree_order`만 쓴다. 그쪽에서 온 이름
/// 변경을 여기서 올려 주지 않으면 서버 폴더 행이 옛 이름으로 남고, 그 낡은 행이
/// 다른 아이패드에서 최종 권위로 쓰여 방금 바뀐 이름을 되돌린다. 아이패드가 두
/// 방식 사이의 다리가 되어야 한다.
protocol SyncV2FolderIdentityPublishing: Sendable {
    func publishFolder(
        localProjectID: ProjectID,
        folderID: DocumentID,
        parentFolderID: DocumentID?,
        name: String
    ) async
}

struct DurableSyncV2FolderIdentityPublisher: SyncV2FolderIdentityPublishing {
    let changeRecorder: any DurableLocalChangeRecording
    let uuidGenerator: any UUIDGenerating

    init(
        changeRecorder: any DurableLocalChangeRecording,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator()
    ) {
        self.changeRecorder = changeRecorder
        self.uuidGenerator = uuidGenerator
    }

    func publishFolder(
        localProjectID: ProjectID,
        folderID: DocumentID,
        parentFolderID: DocumentID?,
        name: String
    ) async {
        guard await changeRecorder.requirement(for: localProjectID)
            == .durableQueue
        else {
            return
        }
        _ = await changeRecorder.record(
            LocalMutationBatch(
                batchID: uuidGenerator.makeUUID(),
                projectID: localProjectID,
                localTransactionID: uuidGenerator.makeUUID(),
                kind: .structureChange,
                mutations: [
                    .folderSnapshot(
                        operationID: uuidGenerator.makeUUID(),
                        folderID: folderID,
                        parentFolderID: parentFolderID,
                        name: name,
                        isDeleted: false
                    )
                ]
            )
        )
    }
}

enum SyncV2FolderMigrationResult: Equatable, Sendable {
    /// 이 작품은 이미 이관됐다. 다시 하지 않는다.
    case alreadyCompleted
    /// 바꿀 폴더가 없었다. 표식만 남긴다.
    case nothingToMigrate
    case migrated(folderCount: Int, queuedOperationIDs: [UUID])
    /// 표식을 남기지 않았으므로 다음 기회에 다시 시도한다.
    case postponed(reason: String)
}

/// 기존 작품의 폴더에 서버와 공유하는 UUID를 붙인다.
///
/// 지금까지 폴더는 서버에 실체가 없어 tree-order의 이름 목록으로만 전달됐다.
/// 동기화가 만든 폴더는 경로에서 계산한 값을 식별자로 쓰고 있어 이름이 바뀌면
/// 값도 바뀌었다. 그래서 이름 변경이 "옛 이름 사라짐 + 새 이름 생김"으로 도착해
/// 받는 기기에 폴더가 둘 남았다.
///
/// 작품마다 한 번만 돈다. 이관된 폴더의 이름이 바뀌면 경로와 UUID가 어긋나므로
/// 경로를 다시 계산해 이관 여부를 판단할 수 없고, 끝났다는 사실을 적어 두는
/// 수밖에 없다.
actor SyncV2FolderMigration {
    private let documentRepository: any DocumentRepository
    private let marker: any SyncV2FolderMigrationMarking
    private let changeRecorder: any DurableLocalChangeRecording
    private let uuidGenerator: any UUIDGenerating

    init(
        documentRepository: any DocumentRepository,
        marker: any SyncV2FolderMigrationMarking,
        changeRecorder: any DurableLocalChangeRecording,
        uuidGenerator: any UUIDGenerating = SystemUUIDGenerator()
    ) {
        self.documentRepository = documentRepository
        self.marker = marker
        self.changeRecorder = changeRecorder
        self.uuidGenerator = uuidGenerator
    }

    /// - Parameter serverFolderIDsByPath: 서버가 이미 아는 폴더다. 같은 경로가
    ///   있으면 계산값 대신 서버 UUID를 쓰고, 그 폴더는 다시 만들지 않는다.
    func migrateIfNeeded(
        localProjectID: ProjectID,
        serverProjectID: UUID,
        serverFolderIDsByPath: [String: DocumentID] = [:]
    ) async -> SyncV2FolderMigrationResult {
        do {
            guard try await !marker.isFolderMigrationCompleted(
                localProjectID: localProjectID
            ) else {
                return .alreadyCompleted
            }
        } catch {
            return .postponed(reason: "이관 표식을 읽을 수 없습니다.")
        }

        let documents: [DocumentNode]
        do {
            documents = try await documentRepository.documents(
                in: localProjectID
            )
        } catch {
            return .postponed(reason: "작품의 폴더 목록을 읽을 수 없습니다.")
        }

        let plan = SyncV2FolderIdentity.migrationPlan(
            documents: documents,
            serverProjectID: serverProjectID,
            serverFolderIDsByPath: serverFolderIDsByPath
        )
        // 계획이 비는 경우는 둘이다. 이미 다 맞는 값이거나, 두 폴더가 같은
        // 값으로 계산돼 이관을 접었거나. 뒤쪽은 표식을 남기면 안 되므로 갈라
        // 본다.
        guard !plan.isEmpty else {
            if hasUnmigratedFolder(
                documents: documents,
                serverProjectID: serverProjectID,
                serverFolderIDsByPath: serverFolderIDsByPath
            ) {
                return .postponed(
                    reason: "두 폴더가 같은 식별자로 계산됩니다."
                )
            }
            return await complete(
                localProjectID: localProjectID,
                result: .nothingToMigrate
            )
        }

        do {
            // 옛 식별자를 먼저 지운다. 새 노드가 같은 경로를 차지하므로 남겨
            // 두면 고유 제약과 부딪힌다.
            for folderID in plan.removedFolderIDs {
                try await documentRepository.removeMetadata(id: folderID)
            }
            // 계획은 부모가 먼저 오도록 정렬되어 있다.
            for document in plan.upserts {
                try await documentRepository.save(document)
            }
        } catch {
            return .postponed(reason: "폴더 식별자를 저장할 수 없습니다.")
        }

        let queued = await queueFolderCommits(
            localProjectID: localProjectID,
            plan: plan,
            serverFolderIDsByPath: serverFolderIDsByPath
        )
        return await complete(
            localProjectID: localProjectID,
            result: .migrated(
                folderCount: plan.removedFolderIDs.count,
                queuedOperationIDs: queued
            )
        )
    }

    /// 서버가 모르는 폴더만 알린다. 서버 UUID를 그대로 받은 폴더는 이미 서버에
    /// 있으므로 다시 만들면 안 된다.
    private func queueFolderCommits(
        localProjectID: ProjectID,
        plan: SyncV2FolderIdentity.MigrationPlan,
        serverFolderIDsByPath: [String: DocumentID]
    ) async -> [UUID] {
        let known = Set(serverFolderIDsByPath.values)
        let folders = plan.upserts.filter {
            $0.kind == .folder && !known.contains($0.id)
        }
        guard !folders.isEmpty else { return [] }

        let mutations = folders.map { folder in
            DurableLocalMutation.folderSnapshot(
                operationID: uuidGenerator.makeUUID(),
                folderID: folder.id,
                parentFolderID: folder.parentID,
                name: Self.folderName(folder.relativePath),
                isDeleted: false
            )
        }
        let result = await changeRecorder.record(
            LocalMutationBatch(
                batchID: uuidGenerator.makeUUID(),
                projectID: localProjectID,
                localTransactionID: uuidGenerator.makeUUID(),
                kind: .structureChange,
                mutations: mutations
            )
        )
        if case let .queued(operationIDs) = result {
            return operationIDs
        }
        return []
    }

    private func complete(
        localProjectID: ProjectID,
        result: SyncV2FolderMigrationResult
    ) async -> SyncV2FolderMigrationResult {
        do {
            try await marker.markFolderMigrationCompleted(
                localProjectID: localProjectID
            )
        } catch {
            // 표식을 남기지 못했으면 다음 실행에서 한 번 더 돈다. 계산이
            // 같은 값을 내므로 두 번 돌아도 결과는 같다.
            return .postponed(reason: "이관 표식을 남길 수 없습니다.")
        }
        return result
    }

    /// 폴더 이름은 경로의 마지막 칸이다. 식별자 계산과 같은 NFC로 맞춰야 같은
    /// 이름이 기기마다 다른 바이트로 서버에 올라가지 않는다.
    static func folderName(_ path: RelativeDocumentPath) -> String {
        SyncV2FolderIdentity.canonicalPath(path.rawValue)
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
    }

    private func hasUnmigratedFolder(
        documents: [DocumentNode],
        serverProjectID: UUID,
        serverFolderIDsByPath: [String: DocumentID]
    ) -> Bool {
        let serverIDs = Dictionary(
            serverFolderIDsByPath.map {
                (SyncV2FolderIdentity.canonicalPath($0.key), $0.value)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return documents.contains { document in
            guard document.kind == .folder else { return false }
            let path = SyncV2FolderIdentity.canonicalPath(
                document.relativePath.rawValue
            )
            let target = serverIDs[path] ?? SyncV2FolderIdentity.derived(
                serverProjectID: serverProjectID,
                relativePath: document.relativePath.rawValue
            )
            return target != document.id
        }
    }
}
