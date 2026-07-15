import Foundation
import SwiftData

/// SwiftData 컨테이너 구동을 확인하기 위한 로컬 메타데이터다.
/// 원고 본문은 이 모델과 이후 SwiftData 모델에 저장하지 않는다.
@Model
final class BootstrapRecord {
    @Attribute(.unique) var id: UUID
    var createdAt: Date

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }
}
