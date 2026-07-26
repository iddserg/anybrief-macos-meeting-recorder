import AppKit
import SwiftUI

/// Dashboard window showing current activity, recent meetings, editable settings, logs, and permissions.
@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: DashboardViewModel
    private let notificationStore: InAppNotificationStore
    private let onClose: () -> Void

    init(
        viewModel: DashboardViewModel,
        notificationStore: InAppNotificationStore,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.notificationStore = notificationStore
        self.onClose = onClose

        let contentView = DashboardView(viewModel: viewModel, notificationStore: notificationStore)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "AnyBrief Dashboard")
        window.appearance = NSAppearance(named: .aqua)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 900, height: 580)
        window.setContentSize(Self.defaultContentSize(fitting: window.screen ?? NSScreen.main, minSize: window.minSize))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A bit roomier than the old 940x620 default, but capped to 90% of the
    /// screen's visible area so it still fits on small/low-res displays.
    static func defaultContentSize(fitting screen: NSScreen?, minSize: NSSize) -> NSSize {
        let preferred = NSSize(width: 1100, height: 700)
        guard let visibleFrame = screen?.visibleFrame else {
            return preferred
        }
        let width = min(preferred.width, visibleFrame.width * 0.9)
        let height = min(preferred.height, visibleFrame.height * 0.9)
        return NSSize(width: max(width, minSize.width), height: max(height, minSize.height))
    }

    func show() {
        viewModel.startRefreshing()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.stopRefreshing()
        onClose()
    }
}
