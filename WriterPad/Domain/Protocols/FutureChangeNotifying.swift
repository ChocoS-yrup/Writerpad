enum LocalChangeEvent: Equatable, Sendable {
    case appLaunched
}

protocol FutureChangeNotifying: Sendable {
    func record(_ event: LocalChangeEvent) async
}
