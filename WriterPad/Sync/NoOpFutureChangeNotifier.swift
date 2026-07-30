struct NoOpFutureChangeNotifier: FutureChangeNotifying {
    let mode: FutureSyncMode = .localOnly

    func record(_ event: LocalChangeEvent) async {
        // Windows v2가 확정되기 전까지 로컬 변경은 서버로 전송하지 않는다.
    }
}

struct NoOpDurableLocalChangeRecorder: DurableLocalChangeRecording {
    func requirement(for projectID: ProjectID) async -> DurableRecordingRequirement {
        .localOnly
    }

    func record(_ batch: LocalMutationBatch) async -> DurableRecordResult {
        .localOnly
    }
}
