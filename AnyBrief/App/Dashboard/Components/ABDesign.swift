
import SwiftUI

enum ABDesign {
    // Resolve against the drawing appearance so existing windows follow live theme changes.
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        func rgb(_ value: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
        }
        let lightColor = rgb(light)
        let darkColor = rgb(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    static let surface = adaptive(0xFFFFFF, 0x1E1F22)
    static let secondarySurface = adaptive(0xF8F8F9, 0x18191B)
    static let contentBackground = adaptive(0xFBFBFC, 0x1E1F22)
    static let chromeBackground = adaptive(0xF9F9FA, 0x1B1C1F)
    static let cardBackground = adaptive(0xFFFFFF, 0x28292D)
    static let controlBackground = adaptive(0xFFFFFF, 0x2D2F33)
    static let primaryText = adaptive(0x1A1A1A, 0xEEEEF0)
    static let secondaryText = adaptive(0x6B7280, 0xA7ACB7)
    static let disabledText = adaptive(0xA1A1A6, 0x777C87)
    static let accent = Color(red: 1.000, green: 0.416, blue: 0.000)
    static let selectedSidebarBackground = accent.opacity(0.12)
    static let red = adaptive(0xDC2626, 0xFF5C5C)
    static let green = adaptive(0x16A34A, 0x39C86A)
    static let yellow = adaptive(0xCA8A04, 0xE8B33F)
    static let info = adaptive(0x006AEE, 0x70AEFF)
    static let infoBackground = adaptive(0xF6FAFF, 0x202D3D)
    static let hairline = adaptive(0x000000, 0xFFFFFF).opacity(0.10)
    static let border = adaptive(0x000000, 0xFFFFFF).opacity(0.18)
    static let subtleBackground = adaptive(0x000000, 0xFFFFFF).opacity(0.035)
    static let mutedBackground = adaptive(0x000000, 0xFFFFFF).opacity(0.065)
    static let badgeBackground = adaptive(0x000000, 0xFFFFFF).opacity(0.12)
}

enum ABTypography {
    // Keep text and symbol sizing centralized here; views should use roles, not raw Font.system sizes.
    static let bodyPointSize: CGFloat = 14

    static let pageTitle = Font.system(size: 24, weight: .semibold)
    static let pageSubtitle = Font.system(size: 14)
    static let cardTitle = Font.system(size: 18, weight: .semibold)
    static let sectionTitle = cardTitle
    static let itemTitle = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: bodyPointSize)
    static let bodyMedium = Font.system(size: bodyPointSize, weight: .medium)
    static let bodySemibold = Font.system(size: bodyPointSize, weight: .semibold)
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
