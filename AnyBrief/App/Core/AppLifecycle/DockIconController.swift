import AppKit

enum DockIconController {
    @MainActor
    static func apply(hideDockIcon: Bool) {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }
}
