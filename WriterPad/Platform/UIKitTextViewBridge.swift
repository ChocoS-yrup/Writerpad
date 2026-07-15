import SwiftUI
import UIKit

/// 4단계 네이티브 편집기를 위한 UIKit 연결 지점이다.
/// 지금은 TextKit 기반 UITextView가 SwiftUI 타깃에서 컴파일되는지만 보장한다.
struct UIKitTextViewBridge: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.isScrollEnabled = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.markedTextRange == nil, textView.text != text else {
            return
        }
        textView.text = text
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
