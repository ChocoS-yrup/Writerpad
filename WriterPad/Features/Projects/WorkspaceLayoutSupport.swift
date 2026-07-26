import SwiftUI
import UIKit

struct WorkspaceLayoutObserver: UIViewControllerRepresentable {
    let onLayoutChange: (CGSize, ScreenLayoutOrientation) -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        ObserverViewController(onLayoutChange: onLayoutChange)
    }

    func updateUIViewController(_ viewController: ObserverViewController, context: Context) {
        viewController.onLayoutChange = onLayoutChange
        viewController.reportCurrentLayout()
    }

    @MainActor
    final class ObserverViewController: UIViewController {
        var onLayoutChange: (CGSize, ScreenLayoutOrientation) -> Void

        init(
            onLayoutChange: @escaping (CGSize, ScreenLayoutOrientation) -> Void
        ) {
            self.onLayoutChange = onLayoutChange
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            reportCurrentLayout()
        }

        override func viewWillTransition(
            to size: CGSize,
            with coordinator: any UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.report(size: size)
            }
        }

        func reportCurrentLayout() {
            report(size: view.bounds.size)
        }

        private func report(size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            let screenBounds = view.window?.windowScene?.screen.coordinateSpace.bounds
            let screenOrientation: ScreenLayoutOrientation
            if let screenBounds, screenBounds.width > 0, screenBounds.height > 0 {
                screenOrientation =
                    screenBounds.height >= screenBounds.width ? .portrait : .landscape
            } else {
                screenOrientation = .unknown
            }
            DispatchQueue.main.async { [weak self] in
                self?.onLayoutChange(size, screenOrientation)
            }
        }
    }
}

enum SplitTransitionPhase: Equatable {
    case idle
    case closing
}

/// 작업 공간 전체가 아니라 실제 모델 값을 표시하는 하위 뷰만 구독한다.
struct EditorSessionObservedContent<Content: View>: View {
    @ObservedObject var model: EditorSessionModel
    let content: (EditorSessionModel) -> Content

    init(
        model: EditorSessionModel,
        @ViewBuilder content: @escaping (EditorSessionModel) -> Content
    ) {
        self.model = model
        self.content = content
    }

    var body: some View {
        content(model)
    }
}

/// 긴 검색어는 자동 줄바꿈하고 하드웨어 Return은 결과 이동으로 유지하는 검색 필드다.
/// marked text가 있는 동안 SwiftUI 상태를 다시 주입하지 않아 검색어의 한글 조합도 보존한다.
