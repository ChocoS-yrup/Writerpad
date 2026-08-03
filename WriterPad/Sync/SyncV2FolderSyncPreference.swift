import Foundation

/// 폴더 UUID 동기화를 작품별로 켠다.
///
/// Windows 클라이언트는 아직 `folders` 표도 `commit_folder`도 모르고
/// `tree_order`만 쓴다. 그래서 폴더 UUID 기록이 최종 권위가 되면, Windows가
/// 바꾼 폴더 이름을 서버 폴더 행이 낡았다는 이유로 아이패드가 되돌린다.
///
/// 기본값은 꺼짐이다. 꺼져 있으면 폴더 작업을 보내지도, 이관하지도, 원격 폴더를
/// 반영하지도 않아 기존 `tree_order` 동작이 그대로 유지된다. 켠 작품에서만 전
/// 구간이 돈다. Windows가 폴더 UUID를 지원하면 기본값을 뒤집는다.
enum SyncV2FolderSyncPreference {
    static let storageKey = "writerpad.folder-uuid-sync-project-ids"

    static func enabledProjectIDs(
        in defaults: UserDefaults = .standard
    ) -> Set<ProjectID> {
        let stored = defaults.stringArray(forKey: storageKey) ?? []
        return Set(
            stored
                .compactMap(UUID.init(uuidString:))
                .map(ProjectID.init(rawValue:))
        )
    }

    static func isEnabled(
        for projectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        enabledProjectIDs(in: defaults).contains(projectID)
    }

    static func setEnabled(
        _ isEnabled: Bool,
        for projectID: ProjectID,
        in defaults: UserDefaults = .standard
    ) {
        var identifiers = enabledProjectIDs(in: defaults)
        if isEnabled {
            identifiers.insert(projectID)
        } else {
            identifiers.remove(projectID)
        }
        defaults.set(
            identifiers
                .map { $0.rawValue.uuidString.lowercased() }
                .sorted(),
            forKey: storageKey
        )
    }
}

/// 저장된 설정을 읽는 경계다. 테스트가 UserDefaults를 건드리지 않고도 켜고 끌
/// 수 있게 갈라 둔다.
protocol SyncV2FolderSyncGating: Sendable {
    func isFolderSyncEnabled(for projectID: ProjectID) -> Bool
}

struct StoredSyncV2FolderSyncGate: SyncV2FolderSyncGating {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isFolderSyncEnabled(for projectID: ProjectID) -> Bool {
        SyncV2FolderSyncPreference.isEnabled(
            for: projectID,
            in: defaults
        )
    }
}
