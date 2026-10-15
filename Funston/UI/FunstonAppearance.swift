import UIKit
import SwiftUI

extension UIColor {
    /// Opaque secondary text maintains readable contrast on system backgrounds.
    static var funstonSecondaryLabel: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.72, alpha: 1) : UIColor(white: 0.38, alpha: 1)
        }
    }
}

extension Color {
    static var funstonSecondaryText: Color { Color(uiColor: .funstonSecondaryLabel) }
}

/// Measurements shared across screens, so the same role looks the same everywhere.
enum FunstonMetrics {
    /// Space between the screen edge and content, on both sides.
    static let sideInset: CGFloat = 20
    /// Cover art corners in lists and shelves.
    static let artworkCornerRadius: CGFloat = 4
    static let minimumTouchTarget: CGFloat = 44
}
