import Foundation

struct SyncV2RemoteFolderApplyReport: Equatable, Sendable {
    var movedFolderIDs: [DocumentID] = []
    var createdFolderIDs: [DocumentID] = []
    var deletedFolderIDs: [DocumentID] = []
    var rejectedFolderIDs: Set<DocumentID> = []
    /// 반영하지 못한 것들이다. 사용자가 무엇을 고쳐야 하는지 알 수 있게 이름을
    /// 함께 싣는다.
    var rejectedNames: [SyncV2RejectedStructureName] = []

    var isEmpty: Bool {
        movedFolderIDs.isEmpty
            && createdFolderIDs.isEmpty
            && deletedFolderIDs.isEmpty
            && rejectedFolderIDs.isEmpty
            && rejectedNames.isEmpty
    }
}

protocol SyncV2RemoteFolderApplying: Sendable {
    func applyRemoteFolders(
        localProjectID: ProjectID,
        remote: [SyncV2RemoteFolder],
        blockedFolderIDs: Set<DocumentID>
    ) async -> SyncV2RemoteFolderApplyReport
}

/// 계획대로 폴더를 옮기고 만들고 지운다.
///
/// 이름 변경도 이동으로 처리한다. 지우고 새로 만들면 받는 기기에 옛 이름과 새
/// 이름의 폴더가 함께 남는데, 그것이 이번 전환이 없애려는 증상이다.
actor SyncV2RemoteFolderApplier: SyncV2RemoteFolderApplying {
    private let documentRepository: any DocumentRepository
    private let workspaceLocator: any ProjectWorkspaceLocating
    private let fileManager: FileManager
    private let pathPolicy = PathPolicy()

    init(
        documentRepository: any DocumentRepository,
        workspaceLocator: any ProjectWorkspaceLocating,
        fileManager: FileManager = .default
    ) {
        self.documentRepository = documentRepository
        self.workspaceLocator = workspaceLocator
        self.fileManager = fileManager
    }

    func applyRemoteFolders(
        localProjectID: ProjectID,
        remote: [SyncV2RemoteFolder],
        blockedFolderIDs: Set<DocumentID> = []
    ) async -> SyncV2RemoteFolderApplyReport {
        var report = SyncV2RemoteFolderApplyReport()
        guard !remote.isEmpty else { return report }
        guard
            let root = try? await workspaceLocator.workspaceRoot(
                for: localProjectID
            ),
            var documents = try? await documentRepository.documents(
                in: localProjectID
            )
        else {
            return report
        }

        let plan = SyncV2RemoteFolderPlanner.plan(
            remote: remote,
            documents: documents,
            blockedFolderIDs: blockedFolderIDs
        )
        for action in plan.actions {
            switch action {
            case let .move(folderID, parentID, from, to):
                documents = await move(
                    folderID: folderID,
                    parentID: parentID,
                    from: from,
                    to: to,
                    documents: documents,
                    root: root,
                    report: &report
                )
            case let .create(folderID, parentID, path):
                documents = await create(
                    folderID: folderID,
                    parentID: parentID,
                    path: path,
                    localProjectID: localProjectID,
                    documents: documents,
                    root: root,
                    report: &report
                )
            case let .delete(folderID, path):
                documents = await delete(
                    folderID: folderID,
                    path: path,
                    documents: documents,
                    root: root,
                    report: &report
                )
            case let .conflict(folderID, path, reason):
                // 목적지 점유·미전송 작업·부모 없음·고리. 넷 다 이름 문제가
                // 아니다.
                report.rejectedFolderIDs.insert(folderID)
                report.rejectedNames.append(
                    rejection(path: path, reason: reason, kind: .notApplied)
                )
            }
        }
        return report
    }

    private func move(
        folderID: DocumentID,
        parentID: DocumentID?,
        from: RelativeDocumentPath,
        to: RelativeDocumentPath,
        documents: [DocumentNode],
        root: URL,
        report: inout SyncV2RemoteFolderApplyReport
    ) async -> [DocumentNode] {
        guard let source = documents.first(where: { $0.id == folderID })
        else {
            report.rejectedFolderIDs.insert(folderID)
            return documents
        }
        guard isNameAllowed(to) else {
            report.rejectedFolderIDs.insert(folderID)
            report.rejectedNames.append(
                rejection(
                    path: to,
                    reason: nil,
                    detail: "허용되지 않는 이름",
                    kind: .unusableName
                )
            )
            return documents
        }

        let sourceURL = url(root: root, path: from)
        let destinationURL = url(root: root, path: to)
        let reactivatesInPlace = from == to
        guard reactivatesInPlace
                || !fileManager.fileExists(atPath: destinationURL.path)
        else {
            report.rejectedFolderIDs.insert(folderID)
            // 계획을 세운 뒤에 누군가 그 자리를 차지했다. 덮어쓰지 않는다.
            report.rejectedNames.append(
                rejection(
                    path: to,
                    reason: .destinationOccupied,
                    kind: .notApplied
                )
            )
            return documents
        }
        do {
            if reactivatesInPlace {
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
            } else {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try fileManager.moveItem(
                        at: sourceURL,
                        to: destinationURL
                    )
                } else {
                    // 빈 폴더는 디스크에 없을 수 있다. 그래도 메타데이터는
                    // 옮겨야 화면에서 폴더가 둘로 보이지 않는다.
                    try fileManager.createDirectory(
                        at: destinationURL,
                        withIntermediateDirectories: true
                    )
                }
            }
        } catch {
            report.rejectedFolderIDs.insert(folderID)
            report.rejectedNames.append(
                rejection(
                    path: to,
                    reason: nil,
                    detail: "옮길 수 없음",
                    kind: .notApplied
                )
            )
            return documents
        }

        // 폴더가 통째로 움직였으므로 그 아래 것들의 경로도 함께 바뀐다.
        var updated = documents
        let oldPrefix = canonical(from.rawValue)
        for (index, document) in documents.enumerated() {
            let path = canonical(document.relativePath.rawValue)
            let isSelf = document.id == folderID
            let isDescendant = path.hasPrefix(oldPrefix + "/")
            guard isSelf || isDescendant else { continue }
            let newPath = isSelf
                ? to.rawValue
                : to.rawValue + String(path.dropFirst(oldPrefix.count))
            let node = DocumentNode(
                id: document.id,
                projectID: document.projectID,
                kind: document.kind,
                parentID: isSelf ? parentID ?? source.parentID
                    : document.parentID,
                relativePath: RelativeDocumentPath(rawValue: newPath),
                userOrder: document.userOrder,
                modifiedAt: document.modifiedAt,
                contentHash: document.contentHash,
                // 서버에서 live로 돌아온 폴더 자체는 활성화한다.
                // 단, 폴더 이동에 물리적으로 따라온 자식은 각자의
                // document/folder snapshot이 live를 확정할 때까지 tombstone을
                // 유지해야 중간 상태에서 자료를 부활시키지 않는다.
                deletionStatus: isSelf ? .active : document.deletionStatus,
                cursor: document.cursor,
                isExpanded: document.isExpanded
            )
            guard (try? await documentRepository.save(node)) != nil else {
                continue
            }
            updated[index] = node
        }
        report.movedFolderIDs.append(folderID)
        return updated
    }

    private func create(
        folderID: DocumentID,
        parentID: DocumentID?,
        path: RelativeDocumentPath,
        localProjectID: ProjectID,
        documents: [DocumentNode],
        root: URL,
        report: inout SyncV2RemoteFolderApplyReport
    ) async -> [DocumentNode] {
        guard isNameAllowed(path) else {
            report.rejectedFolderIDs.insert(folderID)
            report.rejectedNames.append(
                rejection(
                    path: path,
                    reason: nil,
                    detail: "허용되지 않는 이름",
                    kind: .unusableName
                )
            )
            return documents
        }
        let destinationURL = url(root: root, path: path)
        do {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true
            )
        } catch {
            report.rejectedFolderIDs.insert(folderID)
            report.rejectedNames.append(
                rejection(
                    path: path,
                    reason: nil,
                    detail: "만들 수 없음",
                    kind: .notApplied
                )
            )
            return documents
        }
        let node = DocumentNode(
            id: folderID,
            projectID: localProjectID,
            kind: .folder,
            parentID: parentID,
            relativePath: path,
            userOrder: 0,
            modifiedAt: Date(),
            contentHash: nil
        )
        guard (try? await documentRepository.save(node)) != nil else {
            report.rejectedFolderIDs.insert(folderID)
            return documents
        }
        report.createdFolderIDs.append(folderID)
        return documents + [node]
    }

    private func delete(
        folderID: DocumentID,
        path: RelativeDocumentPath,
        documents: [DocumentNode],
        root: URL,
        report: inout SyncV2RemoteFolderApplyReport
    ) async -> [DocumentNode] {
        // 휴지통 안의 폴더는 이 기기에서 삭제를 이미 표현한 보존본이다.
        // 안의 TXT를 지우면 복구할 수 없고, 남아 있다고 tombstone을 거부하면
        // 다른 기기가 복원하기 직전의 중간 삭제 상태가 최종 오류로 남는다.
        // 로컬 보존본은 그대로 두고 folder baseline만 진전시킨다. 나중에
        // 서버가 live로 복원하면 같은 folder_id를 휴지통에서 원래 자리로
        // 옮긴다. 활성 경로의 미전송 내용 보호는 아래에서 그대로 유지한다.
        if isInTrash(path) {
            return documents
        }
        // 서버가 지웠다고 알려도 로컬에 아직 내용이 남아 있으면 지우지 않는다.
        // 그 내용은 아직 서버로 못 간 사용자의 자료일 수 있다.
        let prefix = canonical(path.rawValue) + "/"
        let hasLocalContent = documents.contains {
            $0.id != folderID
                && canonical($0.relativePath.rawValue).hasPrefix(prefix)
        }
        guard !hasLocalContent else {
            report.rejectedFolderIDs.insert(folderID)
            report.rejectedNames.append(
                rejection(
                    path: path,
                    reason: nil,
                    detail: "아직 내용이 남아 있어 지우지 않음",
                    kind: .notApplied
                )
            )
            return documents
        }

        let target = url(root: root, path: path)
        if fileManager.fileExists(atPath: target.path) {
            guard
                let contents = try? fileManager.contentsOfDirectory(
                    atPath: target.path
                ),
                contents.isEmpty
            else {
                report.rejectedFolderIDs.insert(folderID)
                report.rejectedNames.append(
                    rejection(
                        path: path,
                        reason: nil,
                        detail: "아직 내용이 남아 있어 지우지 않음",
                        kind: .notApplied
                    )
                )
                return documents
            }
            try? fileManager.removeItem(at: target)
        }
        guard
            (try? await documentRepository.removeMetadata(id: folderID))
                != nil
        else {
            report.rejectedFolderIDs.insert(folderID)
            return documents
        }
        report.deletedFolderIDs.append(folderID)
        return documents.filter { $0.id != folderID }
    }

    private func isNameAllowed(_ path: RelativeDocumentPath) -> Bool {
        guard let name = path.rawValue
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        else { return false }
        do {
            try pathPolicy.validateName(name)
            try pathPolicy.validateRelativePath(path)
            return true
        } catch {
            return false
        }
    }

    private func isInTrash(_ path: RelativeDocumentPath) -> Bool {
        let value = canonical(path.rawValue)
        let trash = canonical(
            BinderFixedCategory.trash.relativePath.rawValue
        )
        return value.hasPrefix(trash + "/")
    }

    private func rejection(
        path: RelativeDocumentPath?,
        reason: SyncV2RemoteFolderPlanner.ConflictReason?,
        detail: String? = nil,
        kind: SyncV2RejectedStructureKind
    ) -> SyncV2RejectedStructureName {
        let value = path?.rawValue ?? ""
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        return SyncV2RejectedStructureName(
            name: components.last.map(String.init) ?? value,
            parent: components.dropLast().joined(separator: "/"),
            reason: detail ?? reason?.rawValue ?? "unknown",
            kind: kind
        )
    }

    private func url(root: URL, path: RelativeDocumentPath) -> URL {
        root.appendingPathComponent(path.rawValue).standardizedFileURL
    }

    private func canonical(_ path: String) -> String {
        SyncV2FolderIdentity.canonicalPath(path)
    }
}
