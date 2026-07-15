struct NoOpFutureChangeNotifier: FutureChangeNotifying {
    func record(_ event: LocalChangeEvent) async {
        // Windows v2가 확정되기 전까지 로컬 변경은 서버로 전송하지 않는다.
    }
}
