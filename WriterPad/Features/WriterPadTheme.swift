import SwiftUI
import UIKit

extension Color {
    /// 장시간 집필해도 눈의 피로가 적은 neutral charcoal 팔레트.
    static let writerPadDarkBackground = Color(red: 12 / 255, green: 14 / 255, blue: 18 / 255)
    static let writerPadDarkSurface = Color(red: 17 / 255, green: 20 / 255, blue: 25 / 255)
    static let writerPadDarkElevated = Color(red: 22 / 255, green: 25 / 255, blue: 31 / 255)
    static let writerPadDarkBorder = Color.white.opacity(0.10)
    static let writerPadAccent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 126 / 255, green: 156 / 255, blue: 1, alpha: 1)
                : UIColor(red: 58 / 255, green: 88 / 255, blue: 158 / 255, alpha: 1)
        }
    )
    static let writerPadDocumentTint = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 121 / 255, green: 183 / 255, blue: 212 / 255, alpha: 1)
                : UIColor(red: 45 / 255, green: 112 / 255, blue: 143 / 255, alpha: 1)
        }
    )
    static let writerPadEmptyDocumentTint = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.56, alpha: 1)
                : UIColor(red: 134 / 255, green: 145 / 255, blue: 162 / 255, alpha: 1)
        }
    )
    static let writerPadSelectionBorder = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 151 / 255, green: 177 / 255, blue: 1, alpha: 1)
                : UIColor(red: 42 / 255, green: 78 / 255, blue: 160 / 255, alpha: 1)
        }
    )
    static let writerPadWarning = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 240 / 255, green: 181 / 255, blue: 89 / 255, alpha: 1)
                : UIColor(red: 156 / 255, green: 91 / 255, blue: 14 / 255, alpha: 1)
        }
    )
}
