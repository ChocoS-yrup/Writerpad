import Foundation

enum BinderOrderingPolicy {
    /// 기존 고정 바인더 순서를 유지하면서 사용자가 루트 순서를 처음 바꾼 시점을 구분한다.
    static let customizedRootOrderOffset = 1_000_000
}

enum BinderFixedCategory: String, CaseIterable, Codable, Sendable {
    case manuscript
    case characters
    case settings
    case notes
    case flow
    case foreshadowing
    case places
    case trash

    var displayName: String {
        switch self {
        case .manuscript: "원고"
        case .characters: "캐릭터"
        case .settings: "설정집"
        case .notes: "메모장"
        case .flow: "흐름 정리"
        case .foreshadowing: "복선"
        case .places: "장소"
        case .trash: "휴지통"
        }
    }

    var relativePath: RelativeDocumentPath {
        let storedName = switch self {
        case .manuscript: "원고"
        case .characters: "캐릭터"
        case .settings: "설정집"
        case .notes: "메모장"
        case .flow: "흐름정리"
        case .foreshadowing: "복선"
        case .places: "장소"
        case .trash: "휴지통"
        }
        return RelativeDocumentPath(rawValue: "메인/\(storedName)")
    }

    var fixedOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Int.max
    }

}

enum BinderTextContentState: String, Codable, Equatable, Sendable {
    case notText
    case empty
    case written
}

struct BinderNode: Identifiable, Codable, Equatable, Sendable {
    let id: DocumentID
    let projectID: ProjectID
    let kind: DocumentKind
    let relativePath: RelativeDocumentPath
    let displayName: String
    let fixedCategory: BinderFixedCategory?
    let userOrder: Int
    let contentState: BinderTextContentState
    var isExpanded: Bool

    var isFolder: Bool { kind == .folder }
}

struct BinderDiskEntry: Equatable, Sendable {
    let storedName: String
    let relativePath: RelativeDocumentPath
    let kind: DocumentKind
    let byteCount: Int64
    let modifiedAt: Date
    let contentHash: ContentHash?
}

struct BinderScanMetrics: Equatable, Sendable {
    let relativeDirectories: [String]
    let performedMainThreadIO: Bool
}

enum BinderRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case missingMainFolder
    case missingFixedCategory(String)
    case missingNode(DocumentID)
    case nodeIsNotFolder(DocumentID)
    case invalidUTF8(String)
    case unsupportedSymbolicLink(String)
    case unreadableDirectory(String)
    case normalizedNameCollision(String, String)
    case documentAtTopLevel(String)

    var errorDescription: String? {
        switch self {
        case .missingMainFolder:
            "작품의 메인 폴더를 찾을 수 없습니다."
        case let .missingFixedCategory(name):
            "고정 바인더 폴더를 찾을 수 없습니다: \(name)"
        case let .missingNode(id):
            "바인더 항목을 찾을 수 없습니다: \(id.rawValue.uuidString)"
        case let .nodeIsNotFolder(id):
            "폴더가 아닌 항목은 펼칠 수 없습니다: \(id.rawValue.uuidString)"
        case let .invalidUTF8(path):
            "UTF-8로 읽을 수 없는 TXT 파일입니다: \(path)"
        case let .unsupportedSymbolicLink(path):
            "심볼릭 링크는 바인더에서 열 수 없습니다: \(path)"
        case let .unreadableDirectory(path):
            "폴더를 읽을 수 없습니다: \(path)"
        case let .normalizedNameCollision(first, second):
            "대소문자 또는 Unicode 정규화 후 이름이 충돌합니다: \(first), \(second)"
        case let .documentAtTopLevel(path):
            "최상위 바인더에는 문서 파일을 배치할 수 없습니다: \(path)"
        }
    }
}
