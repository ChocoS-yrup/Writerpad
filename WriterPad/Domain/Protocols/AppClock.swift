import Foundation

protocol AppClock: Sendable {
    func now() -> Date
}

struct SystemClock: AppClock {
    func now() -> Date {
        Date()
    }
}
