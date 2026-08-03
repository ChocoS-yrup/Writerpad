import Foundation

/// 폴더를 서버와 공유하는 UUID로 식별한다.
///
/// 폴더는 지금까지 서버에 실체가 없어 이름 목록으로만 전달됐고, 그래서 이름
/// 변경이 "옛 이름 사라짐 + 새 이름 생김"으로 도착해 받는 기기에 폴더가 둘
/// 남았다. UUID가 생기면 같은 폴더임을 알 수 있어 옮기기로 처리된다.
enum SyncV2FolderIdentity {
    /// 이미 존재하던 폴더에 부여하는 값이다. 두 기기가 각자 이관해도 같은
    /// 결과가 나와야 하므로 무작위가 아니라 서버 작품 ID와 경로에서 계산한다.
    /// 로컬 작품 ID는 기기마다 다를 수 있어 쓸 수 없다.
    static func derived(
        serverProjectID: UUID,
        relativePath: String
    ) -> DocumentID {
        DocumentID(
            rawValue: syncV2UUIDv5(
                namespace: serverProjectID,
                name: "writerpad-folder/" + canonicalPath(relativePath)
            )
        )
    }

    /// 경로 비교는 NFC로 맞춘다. Windows는 항상 NFC로 보내고 macOS 파일 이름은
    /// 분해된 형태로 들어올 수 있어, 정규화하지 않으면 같은 폴더가 다른 UUID를
    /// 받는다.
    static func canonicalPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).precomposedStringWithCanonicalMapping }
            .joined(separator: "/")
    }

    /// 이관 결과다. 문서는 건드리지 않고 폴더 식별자만 바꾼다.
    struct MigrationPlan: Equatable, Sendable {
        /// 저장해야 할 새 노드들이다. 식별자가 바뀐 폴더와, 그 폴더를 부모로
        /// 삼던 자식들이 함께 들어간다.
        let upserts: [DocumentNode]
        /// 옛 식별자로 남아 있는 폴더들이다. 새 노드를 넣기 전에 지워야
        /// 고유 제약과 부딪히지 않는다.
        let removedFolderIDs: [DocumentID]

        var isEmpty: Bool { upserts.isEmpty && removedFolderIDs.isEmpty }
    }

    /// 이관 계획을 만든다. 저장소를 건드리지 않는 순수 계산이라 그대로 검증할
    /// 수 있다.
    ///
    /// 고정 루트도 실제 저장 경로 이름으로 계산해 안정적인 값을 갖는다.
    /// 휴지통 안의 폴더는 되살아날 때 원래 경로로 돌아가므로 함께 이관한다.
    ///
    /// 서버에 이미 같은 경로의 폴더가 있으면 계산값 대신 그 UUID를 쓴다. 먼저
    /// 이관한 기기가 정한 값이 있는데 각자 계산한 값을 고집하면, 같은 폴더가
    /// 기기마다 다른 식별자를 갖게 된다.
    static func migrationPlan(
        documents: [DocumentNode],
        serverProjectID: UUID,
        serverFolderIDsByPath: [String: DocumentID] = [:]
    ) -> MigrationPlan {
        let serverIDs = Dictionary(
            serverFolderIDsByPath.map { (canonicalPath($0.key), $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let folders = documents.filter { $0.kind == .folder }
        var replacements: [DocumentID: DocumentID] = [:]
        for folder in folders {
            let targetID = serverIDs[
                canonicalPath(folder.relativePath.rawValue)
            ] ?? derived(
                serverProjectID: serverProjectID,
                relativePath: folder.relativePath.rawValue
            )
            guard targetID != folder.id else { continue }
            replacements[folder.id] = targetID
        }
        guard !replacements.isEmpty else {
            return MigrationPlan(upserts: [], removedFolderIDs: [])
        }

        // 서로 다른 두 폴더가 같은 값으로 계산되면 경로가 겹친다는 뜻이다.
        // 그대로 두면 한쪽이 사라지므로 이관하지 않는다.
        let derivedIDs = replacements.values
        guard Set(derivedIDs).count == derivedIDs.count else {
            return MigrationPlan(upserts: [], removedFolderIDs: [])
        }

        var upserts: [DocumentNode] = []
        for document in documents {
            let newID = replacements[document.id]
            let newParentID = document.parentID.flatMap { replacements[$0] }
            guard newID != nil || newParentID != nil else { continue }
            upserts.append(
                DocumentNode(
                    id: newID ?? document.id,
                    projectID: document.projectID,
                    kind: document.kind,
                    parentID: newParentID ?? document.parentID,
                    relativePath: document.relativePath,
                    userOrder: document.userOrder,
                    modifiedAt: document.modifiedAt,
                    contentHash: document.contentHash,
                    deletionStatus: document.deletionStatus,
                    cursor: document.cursor,
                    isExpanded: document.isExpanded
                )
            )
        }
        // 부모가 먼저 저장되어야 자식의 parentID가 가리킬 대상이 있다.
        upserts.sort {
            $0.relativePath.rawValue.split(separator: "/").count
                < $1.relativePath.rawValue.split(separator: "/").count
        }
        return MigrationPlan(
            upserts: upserts,
            removedFolderIDs: Array(replacements.keys)
        )
    }
}
