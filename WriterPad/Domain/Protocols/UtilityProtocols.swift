import Foundation

/// 결정적 테스트 ID를 주입할 수 있게 UUID 생성을 분리한다.
protocol UUIDGenerating: Sendable {
    func makeUUID() -> UUID
}

struct SystemUUIDGenerator: UUIDGenerating {
    func makeUUID() -> UUID {
        UUID()
    }
}

/// 파일 저장 결과의 SHA-256 계산 구현을 교체할 수 있는 경계다.
protocol ContentHashing: Sendable {
    func sha256(for data: Data) -> ContentHash
}
