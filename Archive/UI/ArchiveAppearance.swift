import UIKit
import SwiftUI

extension UIColor {
    /// Opaque secondary text maintains readable contrast on system backgrounds.
    static var archiveSecondaryLabel: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.38, alpha: 1)
        }
    }
}

extension Color {
    static var archiveSecondaryText: Color { Color(uiColor: .archiveSecondaryLabel) }
}
