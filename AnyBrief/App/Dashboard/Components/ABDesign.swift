
import SwiftUI

enum ABDesign {
    static let contentBackground = Color(red: 0.984, green: 0.984, blue: 0.988)
    static let chromeBackground = Color(red: 0.976, green: 0.976, blue: 0.982)
    static let cardBackground = Color.white.opacity(0.94)
    static let controlBackground = Color.white.opacity(0.82)
    static let selectedSidebarBackground = Color(red: 1.000, green: 0.416, blue: 0.000).opacity(0.10)
    static let primaryText = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let secondaryText = Color(red: 0.420, green: 0.447, blue: 0.502)
    static let disabledText = Color(red: 0.631, green: 0.631, blue: 0.651)
    static let accent = Color(red: 1.000, green: 0.416, blue: 0.000)
    static let red = Color(red: 0.863, green: 0.149, blue: 0.149)
    static let green = Color(red: 0.086, green: 0.639, blue: 0.290)
    static let yellow = Color(red: 0.792, green: 0.541, blue: 0.016)
    static let hairline = Color.black.opacity(0.08)
}

enum ABTypography {
    // Keep text and symbol sizing centralized here; views should use roles, not raw Font.system sizes.
    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let pageSubtitle = Font.system(size: 14)
    static let cardTitle = Font.system(size: 18, weight: .semibold)
    static let sectionTitle = cardTitle
    static let itemTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 14)
    static let bodyMedium = Font.system(size: 14, weight: .medium)
    static let bodySemibold = Font.system(size: 14, weight: .semibold)
    static let field = Font.system(size: 14)
    static let fieldSemibold = Font.system(size: 14, weight: .semibold)
    static let caption = Font.system(size: 12)
    static let captionMedium = Font.system(size: 12, weight: .medium)
    static let captionSemibold = Font.system(size: 12, weight: .semibold)
    static let badge = Font.system(size: 10, weight: .semibold)
    static let tooltip = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 13, design: .monospaced)
    static let logMono = mono

    static let iconTiny = Font.system(size: 10, weight: .semibold)
    static let iconSmall = Font.system(size: 11, weight: .semibold)
    static let iconMedium = Font.system(size: 20, weight: .semibold)
    static let iconLarge = Font.system(size: 32, weight: .light)
    static let iconHero = Font.system(size: 38, weight: .light)

    static func icon(inContainer size: CGFloat) -> Font {
        Font.system(size: size * 0.42, weight: .medium)
    }
}
