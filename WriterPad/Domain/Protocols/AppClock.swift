import Foundation

/// 시간 의존 로직에 고정 시계를 주입할 수 있게 현재 시각을 분리한다.
protocol AppClock: Sendable {
    func now() -> Date
}

struct SystemClock: AppClock {
    func now() -> Date {
        Date()
    }
}
