import Foundation

enum BinderHierarchyViolation: Equatable, Sendable {
    case documentAtTopLevel
}

/// 바인더의 부모-자식 종류 제약만 담당한다.
///
/// 이름, 원고 권·화 규칙, 휴지통 규칙과 분리해 모든 변경 경로가 같은
/// 최상위 계층 불변식을 사용하도록 한다.
struct BinderHierarchyPolicy: Sendable {
    static let topLevelPath = RelativeDocumentPath(rawValue: "메인")

    func placementViolation(
        for kind: DocumentKind,
        in destinationParent: DocumentNode
    ) -> BinderHierarchyViolation? {
        placementViolation(
            for: kind,
            destinationParentPath: destinationParent.relativePath
        )
    }

    func placementViolation(
        for kind: DocumentKind,
        destinationParentPath: RelativeDocumentPath
    ) -> BinderHierarchyViolation? {
        guard destinationParentPath.rawValue == Self.topLevelPath.rawValue,
              kind == .text
        else {
            return nil
        }
        return .documentAtTopLevel
    }

    func isTopLevelContainer(_ document: DocumentNode) -> Bool {
        document.kind == .folder
            && document.relativePath.rawValue == Self.topLevelPath.rawValue
    }

    func invalidTopLevelDocuments(
        in documents: [DocumentNode]
    ) -> [DocumentNode] {
        guard let root = documents.first(where: isTopLevelContainer) else {
            return []
        }
        return documents.filter {
            $0.parentID == root.id && $0.kind == .text
        }
    }
}
