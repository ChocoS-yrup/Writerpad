import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        ProjectWorkspaceView(projectManager: environment.projectManager)
            .task {
                await environment.futureChangeNotifier.record(.appLaunched)
            }
    }
}

private struct ProjectWorkspaceView: View {
    @StateObject private var model: ProjectListModel
    @State private var isCreating = false
    @State private var newProjectName = ""
    @State private var renameTarget: ManagedProject?
    @State private var renameText = ""
    @State private var deleteTarget: ManagedProject?

    init(projectManager: any ProjectManaging) {
        _model = StateObject(
            wrappedValue: ProjectListModel(projectManager: projectManager)
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedProjectID) {
                ForEach(model.projects) { project in
                    projectRow(project)
                        .tag(project.id)
                        .contextMenu {
                            projectContextMenu(project)
                        }
                }
                .onMove { offsets, destination in
                    Task { await model.move(fromOffsets: offsets, toOffset: destination) }
                }
            }
            .overlay {
                if model.projects.isEmpty, !model.isWorking {
                    ContentUnavailableView(
                        "작품이 없습니다",
                        systemImage: "books.vertical",
                        description: Text("+ 버튼을 눌러 첫 작품을 만드세요.")
                    )
                }
            }
            .navigationTitle("WriterPad")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Button("새 작품", systemImage: "plus") {
                        newProjectName = ""
                        isCreating = true
                    }
                    .disabled(model.isWorking)
                }
            }
        } detail: {
            if let project = model.selectedProject {
                VStack(spacing: 14) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(project.name)
                        .font(.title2.weight(.semibold))
                    Text("작품 폴더와 메타데이터가 준비되었습니다.\n원고 목록과 편집기는 다음 단계에서 연결됩니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if project.isDeletionRequested {
                        Label("삭제 대기 중", systemImage: "trash")
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "작품을 선택하세요",
                    systemImage: "square.and.pencil",
                    description: Text("로컬 집필 환경이 준비되었습니다.")
                )
                .accessibilityIdentifier("writerpad.empty-state")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { await model.load() }
        .onChange(of: model.selectedProjectID) { _, id in
            Task { await model.select(id) }
        }
        .alert("새 작품", isPresented: $isCreating) {
            TextField("작품 이름", text: $newProjectName)
            Button("취소", role: .cancel) {}
            Button("만들기") {
                Task { await model.create(named: newProjectName) }
            }
        } message: {
            Text("Windows에서도 안전하게 사용할 수 있는 이름을 입력하세요.")
        }
        .alert(
            "작품 이름 변경",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("새 이름", text: $renameText)
            Button("취소", role: .cancel) { renameTarget = nil }
            Button("변경") {
                guard let target = renameTarget else { return }
                renameTarget = nil
                Task { await model.rename(target, to: renameText) }
            }
        }
        .confirmationDialog(
            "‘\(deleteTarget?.name ?? "")’ 작품을 삭제 대기 상태로 옮길까요?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제 대기로 이동", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task { await model.confirmDeletion(of: target) }
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("이 단계에서는 실제 폴더를 지우지 않습니다. 후속 휴지통 정책이 처리할 수 있도록 상태만 기록합니다.")
        }
        .alert(
            "작업을 완료하지 못했습니다",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("확인") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "알 수 없는 오류")
        }
    }

    @ViewBuilder
    private func projectRow(_ project: ManagedProject) -> some View {
        HStack {
            Label(project.name, systemImage: "book.closed")
            Spacer()
            if project.isDeletionRequested {
                Image(systemName: "trash")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("삭제 대기 중")
            }
        }
    }

    @ViewBuilder
    private func projectContextMenu(_ project: ManagedProject) -> some View {
        Button("이름 변경", systemImage: "pencil") {
            renameText = project.name
            renameTarget = project
        }
        if project.isDeletionRequested {
            Button("삭제 대기 취소", systemImage: "arrow.uturn.backward") {
                Task { await model.cancelDeletion(of: project) }
            }
        } else {
            Button("삭제…", systemImage: "trash", role: .destructive) {
                deleteTarget = project
            }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(try! AppEnvironment.testing())
}
