import SwiftUI

struct IntegratedEditorWorkspaceView: View {
    @ObservedObject var session: IntegratedEditorSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var name = ""
    @State private var destination: DocumentID?
    var body: some View {
        NavigationSplitView {
            VStack {
                List(session.rows, id: \.id) { node in
                    Button { Task { await session.select(node.id) } } label: {
                        HStack {
                            Image(systemName: node.deletionStatus != .active ? "trash" : node.kind == .folder ? "folder" : "doc.text")
                            Text(node.relativePath.rawValue.replacingOccurrences(of: IntegratedEditorPlan.rootPath, with: "검증 폴더"))
                                .font(.callout)
                            if session.selectedID == node.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                if session.root == nil {
                    Button("검증 폴더 만들기") { Task { await session.createRoot() } }
                }
                TextField("이름", text: $name).textFieldStyle(.roundedBorder)
                Picker("대상 폴더", selection: $destination) {
                    Text("폴더 선택").tag(nil as DocumentID?)
                    ForEach(session.folders, id: \.id) { folder in
                        Text(folder.relativePath.rawValue).tag(Optional(folder.id))
                    }
                }
                HStack {
                    Button("새 문서") { if let destination { Task { await session.create(kind: .text, name: name, parent: destination) } } }
                    Button("새 폴더") { if let destination { Task { await session.create(kind: .folder, name: name, parent: destination) } } }
                }.disabled(destination == nil || name.isEmpty)
                HStack {
                    Button("이름 변경") { Task { await session.rename(name) } }.disabled(name.isEmpty)
                    Button("이동") { if let destination { Task { await session.move(to: destination) } } }.disabled(destination == nil)
                }
                HStack {
                    Button("위로") { Task { await session.reorder(delta: -1) } }
                    Button("아래로") { Task { await session.reorder(delta: 1) } }
                    Button("휴지통") { Task { await session.trash() } }
                    Button("복원") { if let destination { Task { await session.restore(to: destination) } } }.disabled(destination == nil)
                }
            }.padding(8).disabled(session.busy || session.journal.state().receive != nil || session.journal.diagnosticRestricted)
                .navigationTitle("통합 집필 · Staging")
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                if let editor = session.editor {
                    NormalEditorWritingPane(model: editor, enabled: session.opened && !session.busy && session.journal.state().receive == nil,
                        onSaveShortcut: { Task { await session.save(boundary: .saveShortcut) } })
                } else { ContentUnavailableView(session.journal.diagnosticRestricted ? "원래 요청의 복구 진단 대기" : "문서를 선택하세요", systemImage: "doc.text") }
                Text(session.message).font(.footnote).textSelection(.enabled)
                let state = session.journal.state()
                if let run = state.execution {
                    Text("요청 \(state.usedRequests)/\(run.maximumRequests) · 쓰기 \(state.usedWrites)/\(run.maximumWrites) · 자동 \(session.automatic ? "켜짐" : "꺼짐")")
                        .font(.caption)
                }
                if let reason = session.journal.automaticBlockReason(), state.execution != nil {
                    Text(reason == .automaticLimit ? "자동 수신 한도에 도달해 자동 실행이 중지됐습니다." : "자동 실행 정책이 없거나 기록이 유효하지 않아 자동 실행을 차단했습니다.")
                        .font(.caption)
                }
                if let used = state.empty_cycles_used, let policy = state.execution?.automatic_policy {
                    Text("빈 자동 주기 \(used)/\(policy.maxEmptyCycles)").font(.caption)
                }
                HStack {
                    TextField("이메일", text: $session.email).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("비밀번호", text: $session.password).textContentType(.password).submitLabel(.go)
                        .onSubmit { Task { await session.signIn() } }
                    Button("로그인") { Task { await session.signIn() } }
                }.disabled(session.busy || state.execution == nil)
                HStack {
                    Button("저장") { Task { await session.save() } }.disabled(session.journal.diagnosticRestricted)
                    Button("연결 준비") { Task { await session.prepare() } }.disabled(state.execution == nil || session.journal.diagnosticRestricted)
                    Button("송수신·복구") { Task { await session.synchronize() } }.disabled(state.execution == nil)
                    Button(session.automatic ? "자동 일시정지" : "자동 재개") { Task { await session.toggleAutomatic() } }.disabled(state.execution == nil || session.journal.diagnosticRestricted || (!session.automatic && session.journal.automaticBlockReason() != nil))
                }.disabled(session.busy)
            }.padding()
        }
        .task { await session.open() }
        .onChange(of: scenePhase) { _, phase in Task { await session.setForeground(phase == .active) } }
        .onDisappear { Task { await session.setForeground(false) } }
    }
}
