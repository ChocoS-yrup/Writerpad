import Foundation

enum BinderCommandKind: String, CaseIterable, Codable, Sendable {
    case addVolume
    case createFolder
    case createText
    case rename
    case move
    case reorder
    case moveToTrash

    var displayName: String {
        switch self {
        case .addVolume: "새 권 추가"
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
    case topLevel
    case unresolved
    case outsideProject
}

struct BinderCommandResult: Equatable, Sendable {
    let affectedDocumentID: DocumentID
    let relativePath: RelativeDocumentPath
}

struct TrashDeletionResult: Equatable, Sendable {
    let deletedDocumentIDs: [DocumentID]
    let failures: [TrashDeletionFailure]
}

struct TrashDeletionFailure: Equatable, Sendable {
    let documentID: DocumentID
    let message: String
}

struct TrashRecord: Codable, Equatable, Sendable {
    let documentID: DocumentID
    let originalPath: RelativeDocumentPath
    let originalParentID: DocumentID
    let originalUserOrder: Int
    let deletedAt: Date
}

/// 새 권 생성 뒤 화면 계층이 수행할 의도를 명시적으로 전달한다.
struct BinderVolumeCreationResult: Equatable, Sendable {
    let volumeNumber: Int
    let volumeID: DocumentID
    let firstChapterID: DocumentID
    let chapterIDs: [DocumentID]
    let volumePath: RelativeDocumentPath
    let shouldRefreshBinder: Bool
    let folderToExpandID: DocumentID
    let documentToOpenID: DocumentID
}

enum BinderCommandError: Error, Equatable, LocalizedError, Sendable {
    case missingDocument(DocumentID)
    case destinationIsNotFolder(DocumentID)
    case fixedCategoryProtected(String)
    case openDocument(DocumentID)
    case unresolvedDropTarget
    case destinationOutsideProject
    case folderCannotMoveIntoItself
    case topLevelRequiresFolder
    case documentCannotRestoreToTopLevel
    case invalidOrder
    case ruleDenied(reason: String, suggestedName: String?)
    case sourceMissing(String)
    case destinationAlreadyExists(String, suggestedName: String?)
    case storyPlotMigrationConflict([String])
    case legacySyncFolderConflict([String])
    case recoveryRequired(String)
    case volumeCreationInProgress
    case missingManuscriptRoot
    case volumeNumberOverflow
    case chapterAlreadyExists(Int)
    case injectedFailure(recoveryPending: Bool)
    case trashRecordMissing(DocumentID)
    case trashConfirmationRequired

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
        case .topLevelRequiresFolder:
            "최상위 바인더에는 폴더만 배치할 수 있습니다."
        case .documentCannotRestoreToTopLevel:
            "문서 파일은 최상위 바인더에 복원할 수 없습니다."
        case .invalidOrder:
            "바인더 순서에 빠지거나 중복된 항목이 있습니다."
        case let .ruleDenied(reason, suggestion):
            suggestion.map { "\(reason) 대신 ‘\($0)’을(를) 사용해 보세요." } ?? reason
        case let .sourceMissing(path):
            "원본 항목을 찾을 수 없습니다: \(path)"
        case let .destinationAlreadyExists(path, suggestion):
            suggestion.map { "동일한 이름이 이미 있습니다. ‘\($0)’을(를) 사용해 보세요." }
                ?? "동일한 이름이 이미 있습니다: \(path)"
        case let .storyPlotMigrationConflict(paths):
            "스토리 플롯 폴더를 자동 전환할 수 없습니다. 병합하거나 삭제하지 않았습니다: \(paths.joined(separator: ", "))"
        case let .legacySyncFolderConflict(paths):
            "이전 동기화가 만든 중복 폴더를 안전하게 정리할 수 없습니다. 내용과 경로를 확인하세요: \(paths.joined(separator: ", "))"
        case let .recoveryRequired(path):
            "바인더 작업을 자동 복구하지 못했습니다. 복구 기록을 보존했습니다: \(path)"
        case .volumeCreationInProgress:
            "새 권을 만드는 중입니다. 현재 작업이 끝난 뒤 다시 시도해 주세요."
        case .missingManuscriptRoot:
            "원고 최상위 폴더를 찾을 수 없습니다."
        case .volumeNumberOverflow:
            "더 이상 새 권 번호를 계산할 수 없습니다."
        case let .chapterAlreadyExists(number):
            "기존 원고에 \(number)화가 있어 새 권을 만들 수 없습니다."
        case let .injectedFailure(recoveryPending):
            recoveryPending
                ? "테스트용 중단이 발생했으며 다음 실행에서 복구됩니다."
                : "테스트용 바인더 작업 실패가 발생했습니다."
        case .trashRecordMissing:
            "휴지통 항목의 원래 위치 기록을 찾을 수 없어 안전한 복원을 중단했습니다."
        case .trashConfirmationRequired:
            "영구 삭제에는 명시적인 확인이 필요합니다."
        }
    }
}

enum BinderCommandFaultPoint: Equatable, Sendable {
    case afterJournalWrite
    case afterVolumeChapterFile(Int)
    case afterFileMutation
    case afterMetadataSave
}

struct BinderCommandFaultPlan: Equatable, Sendable {
    let point: BinderCommandFaultPoint
    let leavesTransactionForRecovery: Bool
}
