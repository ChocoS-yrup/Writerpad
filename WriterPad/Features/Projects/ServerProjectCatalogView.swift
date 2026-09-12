import SwiftUI

@MainActor
final class ServerProjectCatalogModel: ObservableObject {
    @Published private(set) var snapshot: ServerCatalogSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    private let service: ServerProjectCatalogService
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(service: ServerProjectCatalogService) { self.service = service }

    func invalidate() {
        ReceiveValidationPolicy.current.invalidate()
        generation = UUID()
        operation?.cancel()
        snapshot = nil
        message = nil
        // 실행 중 취소가 반환될 때까지 다음 수신을 막는다.
    }

    func prepare(authentication: any AuthenticationServicing) {
        guard !isWorking else { return }
        do { _ = try ReceiveValidationPolicy.current.beginAuthentication(
            foreground: UIApplication.shared.applicationState == .active,
            endpoint: ReceiveValidationPolicy.Configuration.staging) }
        catch { message = "수신 확인 설정을 준비하지 못했습니다."; return }
        isWorking = true
        operation = Task {
            _ = await authentication.restoreSession()
            isWorking = false
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    func refresh() {
        guard !isWorking else { return }
        let request = UUID()
        generation = request
        snapshot = nil
        message = nil
        isWorking = true
        operation = Task {
            defer { isWorking = false }
            do {
                let result = try await service.catalog()
                guard request == generation, !Task.isCancelled else { return }
                snapshot = result
            } catch { if request == generation { show(error) } }
        }
    }

    func receive(_ entry: ServerCatalogEntry, localName: String) {
        guard !isWorking, let source = snapshot else { return }
        let request = UUID()
        generation = request
        isWorking = true
        message = nil
        operation = Task {
            defer { isWorking = false }
            do {
                _ = try await service.receive(entry, from: source, localName: localName)
                guard request == generation, !Task.isCancelled else { return }
                snapshot = try await service.catalog()
                guard request == generation, !Task.isCancelled else { snapshot = nil; return }
                message = "가져오기를 완료했습니다. 작품 목록에서 열 수 있습니다."
            } catch {
                guard request == generation else { return }
                show(error)
                snapshot = nil
            }
        }
    }

    func observeAuthentication(_ authentication: any AuthenticationServicing) async {
        var previous = await authentication.currentState()
        let updates = await authentication.stateUpdates()
        for await state in updates {
            guard !Task.isCancelled else { return }
            if state != previous, !ReceiveValidationPolicy.current.enabled || previous.isAuthenticated { invalidate() }
            previous = state
        }
    }

    private func show(_ error: Error) {
        if error is CancellationError { message = "가져오기를 중단했습니다. 같은 작품에서 다시 시도할 수 있습니다." }
        else if let known = error as? ServerCatalogError { message = known.localizedDescription }
        else if error is PathPolicyError { message = "이 iPad에서 사용할 다른 작품 이름을 입력해 주세요." }
        else { message = "작품을 불러오지 못했습니다. 연결과 저장 공간을 확인한 뒤 목록을 새로 불러오세요. 기존 자료는 보존했습니다." }
    }
}

struct ServerProjectCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: ServerProjectCatalogModel
    @State private var localNames: [UUID: String] = [:]
    private let authentication: any AuthenticationServicing

    init(service: ServerProjectCatalogService, authentication: any AuthenticationServicing) {
        _model = StateObject(wrappedValue: ServerProjectCatalogModel(service: service))
        self.authentication = authentication
    }

    var body: some View {
        NavigationStack {
            List {
                if ReceiveValidationPolicy.current.enabled {
                    Text("송신 잠김 · 선택한 작품만 가져옵니다.")
                    Button("수신 준비") { model.prepare(authentication: authentication) }.disabled(model.isWorking)
                }
                Section {
                    Text("서버 작품을 이 iPad로 가져옵니다. 같은 이름이어도 작품 UUID가 다르면 별개의 작품입니다.")
                    Text("이 iPad 이름만 따로 정할 수 있습니다. 가져오는 동안 작품은 열리지 않으며 중단한 작업은 같은 UUID로 재개합니다.")
                        .foregroundStyle(.secondary)
                }
                if let message = model.message { Text(message).accessibilityIdentifier("writerpad.server-catalog-message") }
                if model.isWorking { ProgressView("서버 작품 확인 중…") }
                if let snapshot = model.snapshot {
                    if snapshot.entries.isEmpty { Text("접근 가능한 서버 작품이 없습니다.") }
                    ForEach(snapshot.entries) { entry in
                        Section {
                            Text(entry.project.name).font(.headline)
                            Text(entry.id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                            Text(entry.state.rawValue)
                            if entry.state == .available {
                                TextField("이 iPad에서 사용할 이름", text: Binding(
                                    get: { localNames[entry.id] ?? entry.project.name },
                                    set: { localNames[entry.id] = $0 }))
                                    .disabled(model.isWorking)
                            } else if let name = entry.localName { Text("이 iPad 이름: \(name)") }
                            if entry.state == .available || entry.state == .interrupted {
                                Button(entry.state == .interrupted ? "가져오기 재개" : "이 iPad로 가져오기") {
                                    model.receive(entry, localName: entry.localName ?? localNames[entry.id] ?? entry.project.name)
                                }.disabled(model.isWorking)
                            }
                        }
                    }
                }
            }
            .navigationTitle("서버 작품 가져오기")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.isWorking ? "중단하고 닫기" : "닫기") { model.invalidate(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("새로고침") { model.refresh() }.disabled(model.isWorking)
                }
            }
            .task { if !ReceiveValidationPolicy.current.enabled { model.refresh() } }
            .onChange(of: scenePhase) { _, phase in if ReceiveValidationPolicy.current.enabled, phase != .active { model.invalidate() } }
            .task { await model.observeAuthentication(authentication) }
            .onDisappear { model.invalidate() }
        }
    }
}
