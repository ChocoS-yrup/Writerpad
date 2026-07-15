import Foundation

/// WriterPad가 관리하는 한 작품의 경로 비의존 메타데이터다.
struct Project: Codable, Equatable, Sendable {
    let id: ProjectID
    let name: String
    let createdAt: Date
    let modifiedAt: Date

    init(id: ProjectID, name: String, createdAt: Date, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// 작품 ID는 유지하면서 표시 이름만 바꾼 새 값을 반환한다.
    func renamed(to name: String, at date: Date) -> Project {
        Project(id: id, name: name, createdAt: createdAt, modifiedAt: date)
    }

    private enum CodingKeys: String, CodingKey {
        case id = "project_id"
        case name
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
