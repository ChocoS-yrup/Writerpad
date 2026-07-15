import Foundation

enum BinderCommandKind: String, CaseIterable, Codable, Sendable {
    case createFolder
    case createText
    case rename
    case move
    case reorder
    case moveToTrash

    var displayName: String {
        switch self {
        case .createFolder: "새 폴더"
        case .createText: "새 문서"
        case .rename: "이름 변경"
        case .move: "이동"
        case .reorder: "순서 변경"
        case .moveToTrash: "휴지통으로 이동"
        }
    }
}

struct BinderCommandDescriptor: Identifiable, Equatable, Sendable {
    let kind: BinderCommandKind
    let isEnabled: Bool
    let denialReason: String?

    var id: BinderCommandKind { kind }
}

enum BinderDropTarget: Equatable, Sendable {
    case folder(DocumentID)
    case unresolved
    case outsideProject
}

struct BinderCommandResult: Equatable, Sendable {
    let affectedDocumentID: DocumentID
    let relativePath: RelativeDocumentPath
}

enum BinderCommandError: Error, Equatable, LocalizedError, Sendable {
    case missingDocument(DocumentID)
    case destinationIsNotFolder(DocumentID)
    case fixedCategoryProtected(String)
    case openDocument(DocumentID)
    case unresolvedDropTarget
    case destinationOutsideProject
    case folderCannotMoveIntoItself
    case invalidOrder
    case ruleDenied(reason: String, suggestedName: String?)
    case sourceMissing(String)
    case destinationAlreadyExists(String, suggestedName: String?)
    case recoveryRequired(String)
    case injectedFailure(recoveryPending: Bool)

    var errorDescription: String? {
        switch self {
        case let .missingDocument(id):
            "바인더 항목을 찾을 수 없습니다: \(id.rawValue.uuidString)"
        case let .destinationIsNotFolder(id):
            "이동할 위치가 폴더가 아닙니다: \(id.rawValue.uuidString)"
        case let .fixedCategoryProtected(name):
            "고정 바인더 항목은 변경할 수 없습니다: \(name)"
        case .openDocument:
            "현재 편집기에 열려 있는 문서를 포함한 항목은 먼저 닫아야 이동할 수 있습니다."
        case .unresolvedDropTarget:
            "놓을 폴더가 확정되지 않았습니다."
        case .destinationOutsideProject:
            "작품 루트 밖으로는 이동할 수 없습니다."
        case .folderCannotMoveIntoItself:
            "폴더를 자기 자신이나 자신의 하위 폴더로 이동할 수 없습니다."
        case .invalidOrder:
            "바인더 순서에 빠지거나 중복된 항목이 있습니다."
        case let .ruleDenied(reason, suggestion):
            suggestion.map { "\(reason) 대신 ‘\($0)’을(를) 사용해 보세요." } ?? reason
        case let .sourceMissing(path):
            "원본 항목을 찾을 수 없습니다: \(path)"
        case let .destinationAlreadyExists(path, suggestion):
            suggestion.map { "동일한 이름이 이미 있습니다. ‘\($0)’을(를) 사용해 보세요." }
                ?? "동일한 이름이 이미 있습니다: \(path)"
        case let .recoveryRequired(path):
            "바인더 작업을 자동 복구하지 못했습니다. 복구 기록을 보존했습니다: \(path)"
        case let .injectedFailure(recoveryPending):
            recoveryPending
                ? "테스트용 중단이 발생했으며 다음 실행에서 복구됩니다."
                : "테스트용 바인더 작업 실패가 발생했습니다."
        }
    }
}

enum BinderCommandFaultPoint: Equatable, Sendable {
    case afterJournalWrite
    case afterFileMutation
    case afterMetadataSave
}

struct BinderCommandFaultPlan: Equatable, Sendable {
    let point: BinderCommandFaultPoint
    let leavesTransactionForRecovery: Bool
}
