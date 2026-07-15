import Foundation

/// 메타데이터 오류는 원고 TXT를 수정하지 않고 호출자에게 그대로 전달된다.
enum MetadataRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case missingProject(ProjectID)
    case missingDocument(DocumentID)
    case missingParent(DocumentID)
    case parentIsSameDocument(DocumentID)
    case parentBelongsToAnotherProject(DocumentID)
    case parentIsNotFolder(DocumentID)
    case documentProjectCannotChange(DocumentID)
    case invalidCursor(DocumentID)
    case invalidBinderWidth(Double)
    case invalidEditorState(ProjectID)
    case corruptedRecord(entity: String, identifier: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .missingProject(id):
            "작품 메타데이터를 찾을 수 없습니다: \(id.rawValue)"
        case let .missingDocument(id):
            "문서 메타데이터를 찾을 수 없습니다: \(id.rawValue)"
        case let .missingParent(id):
            "부모 문서를 찾을 수 없습니다: \(id.rawValue)"
        case let .parentIsSameDocument(id):
            "문서가 자기 자신을 부모로 가리킵니다: \(id.rawValue)"
        case let .parentBelongsToAnotherProject(id):
            "부모 문서가 다른 작품에 속합니다: \(id.rawValue)"
        case let .parentIsNotFolder(id):
            "부모 문서가 폴더가 아닙니다: \(id.rawValue)"
        case let .documentProjectCannotChange(id):
            "기존 문서의 작품 ID를 변경할 수 없습니다: \(id.rawValue)"
        case let .invalidCursor(id):
            "커서 위치를 저장할 수 없습니다: \(id.rawValue)"
        case let .invalidBinderWidth(width):
            "바인더 너비가 올바르지 않습니다: \(width)"
        case let .invalidEditorState(id):
            "좌우 편집기 상태가 올바르지 않습니다: \(id.rawValue)"
        case let .corruptedRecord(entity, identifier, reason):
            "손상된 \(entity) 메타데이터(\(identifier)): \(reason)"
        }
    }
}
