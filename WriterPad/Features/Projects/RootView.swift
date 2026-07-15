import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List {
                Label("작품", systemImage: "books.vertical")
            }
            .navigationTitle("WriterPad")
        } detail: {
            ContentUnavailableView(
                "작품을 선택하세요",
                systemImage: "square.and.pencil",
                description: Text("로컬 집필 환경이 준비되었습니다.")
            )
            .accessibilityIdentifier("writerpad.empty-state")
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await environment.futureChangeNotifier.record(.appLaunched)
        }
    }
}

#Preview {
    RootView()
        .environmentObject(try! AppEnvironment.testing())
}
