import SwiftUI
import UIKit

struct NewProjectAlertPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var name: String
    let isSubmitting: Bool
    let onSubmit: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.parent = self

        guard isPresented else {
            context.coordinator.dismissIfNeeded()
            return
        }
        guard !isSubmitting,
              context.coordinator.alert == nil,
              !context.coordinator.isSchedulingPresentation else { return }
        context.coordinator.schedulePresentation(from: viewController)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NewProjectAlertPresenter
        weak var alert: UIAlertController?
        weak var createAction: UIAlertAction?
        var isSchedulingPresentation = false

        init(parent: NewProjectAlertPresenter) {
            self.parent = parent
        }

        func schedulePresentation(from viewController: UIViewController) {
            isSchedulingPresentation = true
            attemptPresentation(from: viewController)
        }

        private func attemptPresentation(from viewController: UIViewController) {
            DispatchQueue.main.async { [weak self, weak viewController] in
                guard let self, let viewController else { return }
                guard parent.isPresented else {
                    isSchedulingPresentation = false
                    return
                }
                guard alert == nil else {
                    isSchedulingPresentation = false
                    return
                }
                guard viewController.viewIfLoaded?.window != nil else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak viewController] in
                        guard let self, let viewController else { return }
                        self.attemptPresentation(from: viewController)
                    }
                    return
                }
                guard viewController.presentedViewController == nil else {
                    isSchedulingPresentation = false
                    return
                }
                isSchedulingPresentation = false
                present(from: viewController)
            }
        }

        func present(from viewController: UIViewController) {
            let alert = UIAlertController(
                title: "새 작품",
                message: "Windows에서도 안전하게 사용할 수 있는 이름을 입력하세요.",
                preferredStyle: .alert
            )
            alert.addTextField { [weak self] textField in
                guard let self else { return }
                textField.placeholder = "작품 이름"
                textField.text = parent.name
                textField.returnKeyType = .done
                textField.enablesReturnKeyAutomatically = true
                textField.delegate = self
                textField.addTarget(self, action: #selector(nameDidChange(_:)), for: .editingChanged)
                textField.addTarget(self, action: #selector(returnKeyPressed(_:)), for: .editingDidEndOnExit)
            }
            alert.addAction(UIAlertAction(title: "취소", style: .cancel) { [weak self] _ in
                self?.cancel()
            })
            let createAction = UIAlertAction(title: "만들기", style: .default) { [weak self] _ in
                self?.complete()
            }
            createAction.isEnabled = !parent.name.isEmpty
            alert.addAction(createAction)
            alert.preferredAction = createAction

            self.alert = alert
            self.createAction = createAction
            viewController.present(alert, animated: true) { [weak self, weak alert] in
                alert?.textFields?.first?.delegate = self
            }
        }

        @objc private func nameDidChange(_ textField: UITextField) {
            let text = textField.text ?? ""
            parent.name = text
            createAction?.isEnabled = !text.isEmpty
        }

        @objc private func returnKeyPressed(_ textField: UITextField) {
            guard !(textField.text ?? "").isEmpty else { return }
            complete()
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard !(textField.text ?? "").isEmpty else { return false }
            complete()
            return false
        }

        func complete() {
            let text = (alert?.textFields?.first?.text ?? parent.name)
                .trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { return }
            parent.name = text
            parent.isPresented = false
            alert?.dismiss(animated: true)
            alert = nil
            parent.onSubmit(text)
        }

        func cancel() {
            parent.isPresented = false
            alert = nil
        }

        func dismissIfNeeded() {
            guard let alert else { return }
            alert.dismiss(animated: true)
            self.alert = nil
        }
    }
}

/// SwiftUI 레이아웃 갱신이 지연되는 회전 전환에서도 실제 scene 방향과 목표 크기를 전달한다.
