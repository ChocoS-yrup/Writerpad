import Foundation
import SwiftData

@Model
final class BootstrapRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}
