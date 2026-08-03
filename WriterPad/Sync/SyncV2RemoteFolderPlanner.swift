import Foundation

/// 원격 폴더 변경을 로컬에 어떻게 반영할지 정한다.
///
/// 파일을 건드리지 않는 순수 계산이다. 이 판단이 이번 전환의 핵심이라 실행부와
/// 떼어 두고 그대로 검증한다.
enum SyncV2RemoteFolderPlanner {
    enum ConflictReason: String, Equatable, Sendable {
        /// 목적지에 이미 다른 것이 있다. 덮어쓰거나 합치지 않고 그대로 둔다.
        case destinationOccupied
        /// 아직 서버에 못 보낸 로컬 작업이 걸린 폴더다. 원격 값으로 덮으면
        /// 사용자가 방금 한 일이 사라진다.
        case pendingLocalOperation
        /// 부모를 로컬에서도 서버 목록에서도 찾을 수 없다. 경로를 만들 수 없다.
        case unknownParent
        /// 부모 사슬이 고리를 이룬다. 서버가 보냈더라도 경로가 되지 않는다.
        case parentCycle
    }

    enum Action: Equatable, Sendable {
        /// 이름 변경과 이동을 모두 여기로 처리한다. 지우고 새로 만들면 받는
        /// 기기에서 폴더가 둘이 된다.
        case move(
            folderID: DocumentID,
            from: RelativeDocumentPath,
            to: RelativeDocumentPath
        )
        case create(
            folderID: DocumentID,
            parentID: DocumentID?,
            path: RelativeDocumentPath
        )
        /// tombstone을 받은 폴더만 지운다.
        case delete(folderID: DocumentID, path: RelativeDocumentPath)
        case conflict(
            folderID: DocumentID,
            path: RelativeDocumentPath?,
            reason: ConflictReason
        )
    }

    struct Plan: Equatable, Sendable {
        /// 부모가 먼저 오도록 정렬되어 있다. 부모를 옮기면 자식은 따라오므로
        /// 순서가 뒤집히면 자식이 옛 자리를 찾다 실패한다.
        let actions: [Action]

        var isEmpty: Bool { actions.isEmpty }
    }

    /// - Parameters:
    ///   - remote: 서버가 준 폴더 목록이다. 여기 없는 로컬 폴더는 건드리지
    ///     않는다. 서버에 없다는 것과 지워졌다는 것은 다르다.
    ///   - documents: 로컬 트리 전체다. 폴더가 아닌 것도 목적지 충돌 판단에
    ///     쓰인다.
    ///   - blockedFolderIDs: 미전송 작업이나 편집이 걸려 원격 변경으로 덮으면
    ///     안 되는 폴더다.
    static func plan(
        remote: [SyncV2RemoteFolder],
        documents: [DocumentNode],
        blockedFolderIDs: Set<DocumentID> = []
    ) -> Plan {
        let remoteByID = Dictionary(
            remote.map { (DocumentID(rawValue: $0.folderID), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let localByID = Dictionary(
            documents.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let desired = desiredPaths(
            remoteByID: remoteByID,
            localByID: localByID
        )

        // 여러 폴더가 같은 자리를 원하면 어느 쪽도 옮기지 않는다. 먼저 처리한
        // 쪽이 이기게 두면 나머지 하나가 조용히 사라진다.
        var wanters: [String: Int] = [:]
        for path in desired.values {
            wanters[canonical(path), default: 0] += 1
        }

        // 옮겨 가는 폴더가 비우고 갈 자리는 목적지로 써도 된다.
        var vacated: Set<String> = []
        for (folderID, path) in desired {
            guard let local = localByID[folderID],
                  canonical(local.relativePath.rawValue) != canonical(path)
            else { continue }
            vacated.insert(canonical(local.relativePath.rawValue))
        }

        var moves: [Action] = []
        var creates: [Action] = []
        var deletes: [Action] = []
        var conflicts: [Action] = []

        for folderID in remoteByID.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard let folder = remoteByID[folderID] else { continue }
            let local = localByID[folderID]

            if blockedFolderIDs.contains(folderID) {
                conflicts.append(
                    .conflict(
                        folderID: folderID,
                        path: local?.relativePath,
                        reason: .pendingLocalOperation
                    )
                )
                continue
            }

            if folder.isDeleted {
                // 서버에 없는 폴더가 아니라, 지워졌다고 알려 온 폴더만 지운다.
                if let local {
                    deletes.append(
                        .delete(
                            folderID: folderID,
                            path: local.relativePath
                        )
                    )
                }
                continue
            }

            guard let path = desired[folderID] else {
                conflicts.append(
                    .conflict(
                        folderID: folderID,
                        path: local?.relativePath,
                        reason: unreachableReason(
                            folderID: folderID,
                            remoteByID: remoteByID
                        )
                    )
                )
                continue
            }

            if let local, canonical(local.relativePath.rawValue)
                == canonical(path) {
                continue
            }

            let occupied = wanters[canonical(path), default: 0] > 1
                || isOccupied(
                    path: path,
                    by: folderID,
                    documents: documents,
                    vacated: vacated
                )
            guard !occupied else {
                conflicts.append(
                    .conflict(
                        folderID: folderID,
                        path: RelativeDocumentPath(rawValue: path),
                        reason: .destinationOccupied
                    )
                )
                continue
            }

            if let local {
                moves.append(
                    .move(
                        folderID: folderID,
                        from: local.relativePath,
                        to: RelativeDocumentPath(rawValue: path)
                    )
                )
            } else {
                creates.append(
                    .create(
                        folderID: folderID,
                        parentID: folder.parentFolderID.map(
                            DocumentID.init(rawValue:)
                        ),
                        path: RelativeDocumentPath(rawValue: path)
                    )
                )
            }
        }

        // 부모를 옮기면 자식은 따라오므로 얕은 것부터 옮긴다. 삭제는 반대로
        // 깊은 것부터 해야 부모가 빈 뒤에 지워진다.
        moves.sort { depth(of: $0) < depth(of: $1) }
        creates.sort { depth(of: $0) < depth(of: $1) }
        deletes.sort { depth(of: $0) > depth(of: $1) }
        return Plan(actions: moves + creates + deletes + conflicts)
    }

    /// 이름을 사슬로 이어 붙여 각 폴더가 있어야 할 자리를 구한다. 서버는 경로를
    /// 보내지 않으므로 여기서 만든다.
    private static func desiredPaths(
        remoteByID: [DocumentID: SyncV2RemoteFolder],
        localByID: [DocumentID: DocumentNode]
    ) -> [DocumentID: String] {
        var resolved: [DocumentID: String] = [:]
        for (folderID, folder) in remoteByID where !folder.isDeleted {
            var components: [String] = []
            var current: DocumentID? = folderID
            var visited: Set<DocumentID> = []
            var reachedRoot = false
            while let cursor = current {
                guard visited.insert(cursor).inserted else {
                    // 고리다. 경로가 되지 않으므로 이 폴더는 접는다.
                    components = []
                    break
                }
                if let remoteFolder = remoteByID[cursor] {
                    guard !remoteFolder.isDeleted else {
                        components = []
                        break
                    }
                    components.append(remoteFolder.name)
                    current = remoteFolder.parentFolderID.map(
                        DocumentID.init(rawValue:)
                    )
                    if current == nil { reachedRoot = true }
                    continue
                }
                // 서버 목록에 없는 부모는 로컬에서 찾는다. 아직 이관되지 않은
                // 상위 폴더가 있어도 그 아래는 반영할 수 있어야 한다.
                guard let localFolder = localByID[cursor],
                      localFolder.kind == .folder else {
                    components = []
                    break
                }
                components.append(localFolder.relativePath.rawValue)
                reachedRoot = true
                current = nil
            }
            guard reachedRoot, !components.isEmpty else { continue }
            resolved[folderID] = components.reversed().joined(separator: "/")
        }
        return resolved
    }

    /// 경로를 만들지 못한 이유를 가른다. 고리와 "부모를 모르겠다"는 사용자가
    /// 할 일이 달라 뭉뚱그리면 안 된다.
    private static func unreachableReason(
        folderID: DocumentID,
        remoteByID: [DocumentID: SyncV2RemoteFolder]
    ) -> ConflictReason {
        var current: DocumentID? = folderID
        var visited: Set<DocumentID> = []
        while let cursor = current {
            guard visited.insert(cursor).inserted else { return .parentCycle }
            guard let folder = remoteByID[cursor] else {
                return .unknownParent
            }
            current = folder.parentFolderID.map(DocumentID.init(rawValue:))
        }
        return .unknownParent
    }

    /// 목적지가 이미 차 있는지 본다. 그 자리를 쓰던 것이 이번에 함께 비켜난다면
    /// 차 있는 것으로 보지 않는다.
    private static func isOccupied(
        path: String,
        by folderID: DocumentID,
        documents: [DocumentNode],
        vacated: Set<String>
    ) -> Bool {
        let target = canonical(path)
        guard !vacated.contains(target) else { return false }
        return documents.contains {
            $0.id != folderID
                && canonical($0.relativePath.rawValue) == target
        }
    }

    private static func depth(of action: Action) -> Int {
        let path: String
        switch action {
        case let .move(_, _, to):
            path = to.rawValue
        case let .create(_, _, created):
            path = created.rawValue
        case let .delete(_, deleted):
            path = deleted.rawValue
        case let .conflict(_, conflicted, _):
            path = conflicted?.rawValue ?? ""
        }
        return path.split(separator: "/").count
    }

    private static func canonical(_ path: String) -> String {
        SyncV2FolderIdentity.canonicalPath(path)
    }
}
