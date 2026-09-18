import AppKit

/// Applies the saved choice to windows, sheets and native controls. Nil follows macOS live.
enum AppAppearanceController {
    @MainActor
    static func apply(_ choice: AppAppearance) {
        switch choice {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
